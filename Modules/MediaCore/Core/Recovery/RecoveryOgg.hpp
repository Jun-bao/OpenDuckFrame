// OpenDuckFrame - container recovery: Ogg page CRC / whole-page single-bit fixes
//
// Split out of the umbrella header by section; function bodies, constants and inline
// attributes are unchanged. Callers keep including the umbrella; this file only guarantees
// that it compiles on its own.
#pragma once

#include "RecoveryBase.hpp"

#include "SPResilience.hpp"
#include <algorithm>
#include <array>
#include <climits>
#include <cmath>
#include <map>
#include <set>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include <zlib.h>

namespace spresil {

inline uint32_t oggCrcAdvanceZeros(uint32_t s, size_t k) {
    const auto& table = oggCrcTable();
    for (size_t i = 0; i < k; ++i) s = (s << 8) ^ table[s >> 24];
    return s;
}

inline bool oggHeaderConsistent(const uint8_t* h, size_t n, int64_t len, int64_t* lenOut) {
    if (n < 27 || std::memcmp(h, "OggS", 4) != 0 || h[4] != 0 || (h[5] & ~0x07)) return false;
    const int nseg = h[26];
    if (n < (size_t)27 + nseg) return false;
    int64_t body = 0;
    for (int i = 0; i < nseg; ++i) body += h[27 + i];
    const int64_t pageLen = 27 + nseg + body;
    if (len >= 0 && pageLen != len) return false;
    if (lenOut) *lenOut = pageLen;
    return true;
}

inline bool oggPageCrcOk(const uint8_t* page, size_t n) {
    if (n < 27) return false;
    const uint32_t stored = le32(page + 22);
    uint32_t crc = oggCrc32(page, 22);
    crc = oggCrcAdvanceZeros(crc, 4);
    crc = oggCrc32(page + 26, n - 26, crc);
    return crc == stored;
}
inline bool oggPageCrcOk(const std::vector<uint8_t>& page) { return oggPageCrcOk(page.data(), page.size()); }

inline bool oggGapIsValidPages(const Reader& read, int64_t from, int64_t to, int64_t maxBytes, const AbortFn* abort) {
    if (from < 0 || to <= from || to - from > maxBytes) return false;
    int64_t pos = from;
    while (pos < to) {
        if (aborted(abort)) return false;
        const auto h = readSpan(read, pos, 27 + 255);
        int64_t pageLen = 0;
        if (!oggHeaderConsistent(h.data(), h.size(), -1, &pageLen) || pos + pageLen > to) return false;
        if (!oggPageCrcOk(readSpan(read, pos, (size_t)pageLen))) return false;
        pos += pageLen;
    }
    return pos == to;
}

struct OggBitFix { size_t byteAt = 0; uint8_t bit = 0; bool crcField = false; };

inline bool oggPageSingleBitFix(const std::vector<uint8_t>& page, OggBitFix& out) {
    if (page.size() < 27 || page.size() > 1024 * 1024) return false;
    const size_t n = page.size();
    const uint32_t stored = le32(page.data() + 22);
    std::vector<uint8_t> work = page;
    std::memset(work.data() + 22, 0, 4);
    const size_t hdrLen = std::min<size_t>(n, 27 + (size_t)page[26]);
    const uint32_t base = oggCrc32(work.data(), n);
    const uint32_t syndrome = base ^ stored;
    if (syndrome == 0) return false;
    const auto& table = oggCrcTable();
    int hits = 0;
    OggBitFix hit;
    if ((syndrome & (syndrome - 1)) == 0) { ++hits; hit.crcField = true; }
    uint32_t state[8];
    for (int k = 0; k < 8; ++k) state[k] = table[1u << k]; // j = n−1
    for (size_t jj = n; jj-- > 0;) {
        if (!(jj >= 22 && jj < 26)) {
            for (int k = 0; k < 8; ++k) {
                if (state[k] != syndrome) continue;
                bool ok = true;
                if (jj < hdrLen) {
                    work[jj] ^= (uint8_t)(1 << k);
                    ok = oggHeaderConsistent(work.data(), n, (int64_t)n, nullptr);
                    work[jj] ^= (uint8_t)(1 << k);
                }
                if (ok) { ++hits; hit.byteAt = jj; hit.bit = (uint8_t)(1 << k); hit.crcField = false; }
            }
        }
        if (jj == 0) break;
        for (int k = 0; k < 8; ++k) state[k] = (state[k] << 8) ^ table[state[k] >> 24];
    }
    if (hits != 1) return false;
    out = hit;
    return true;
}

inline int64_t oggFindNextSelfValidPage(const Reader& read, int64_t from, int64_t fileSize, int64_t window, const AbortFn* abort) {
    static const uint8_t pat[4] = {'O', 'g', 'g', 'S'};
    int64_t cur = from;
    const int64_t limit = std::min(fileSize, from + window);
    FindCursor fc;
    for (int tries = 0; tries < 4096 && cur < limit; ++tries) {
        if (aborted(abort)) return -1;
        int64_t hit = -1;
        if (!findBytes(read, cur, limit, pat, 4, hit, abort, &fc)) return -1;
        auto h = readSpan(read, hit, 27 + 255);
        int64_t len = 0;
        if (oggHeaderConsistent(h.data(), h.size(), -1, &len) && hit + len <= fileSize && len <= 1024 * 1024) {
            auto page = readSpan(read, hit, (size_t)len);
            if ((int64_t)page.size() == len && oggPageCrcOk(page)) return hit;
        }
        cur = hit + 1;
    }
    return -1;
}

inline RecoveryPlan planOggCrc(const Reader& read, int64_t fileSize, int64_t fromPos, int64_t windowBytes,
                               const AbortFn* abort) {
    RecoveryPlan p;
    int64_t pos = fromPos;
    const int64_t limit = std::min(fileSize, fromPos + windowBytes);
    int pages = 0, headerFixes = 0, payloadFixes = 0, crcFieldFixes = 0, crcRewrites = 0;
    while (pos + 27 <= fileSize && pos < limit && pages < 4096 && p.patches.size() < 256) {
        if (aborted(abort)) break;
        auto h = readSpan(read, pos, 27 + 255);
        int64_t pageLen = 0;
        bool structural = oggHeaderConsistent(h.data(), h.size(), -1, &pageLen) && pos + pageLen <= fileSize;
        if (structural) {

            auto self = readSpan(read, pos, (size_t)pageLen);
            if ((int64_t)self.size() == pageLen && oggPageCrcOk(self)) { ++pages; pos += pageLen; continue; }
        }
        if (structural && pos + pageLen < fileSize) {
            auto nx = readSpan(read, pos + pageLen, 4);
            structural = nx.size() == 4 && std::memcmp(nx.data(), "OggS", 4) == 0;
        }
        if (!structural) {
            const int64_t next = oggFindNextSelfValidPage(read, pos + 27, fileSize, 1024 * 1024, abort);
            if (next < 0) break;
            pageLen = next - pos;
        }
        if (pageLen < 27 || pageLen > 1024 * 1024) break;
        auto page = readSpan(read, pos, (size_t)pageLen);
        if ((int64_t)page.size() != pageLen) break;
        if (!oggPageCrcOk(page)) {
            OggBitFix fx;
            if (oggPageSingleBitFix(page, fx)) {
                if (fx.crcField) {
                    std::vector<uint8_t> work = page;
                    std::memset(work.data() + 22, 0, 4);
                    Patch pt;
                    pt.offset = pos + 22;
                    putLe32(pt.bytes, oggCrc32(work.data(), work.size()));
                    p.patches.push_back(pt);
                    ++crcFieldFixes;
                } else {
                    p.patches.push_back({pos + (int64_t)fx.byteAt, {(uint8_t)(page[fx.byteAt] ^ fx.bit)}});
                    if (fx.byteAt < (size_t)27 + page[26]) ++headerFixes; else ++payloadFixes;
                }
            } else if (structural) {
                std::vector<uint8_t> work = page;
                std::memset(work.data() + 22, 0, 4);
                Patch pt;
                pt.offset = pos + 22;
                putLe32(pt.bytes, oggCrc32(work.data(), work.size()));
                p.patches.push_back(pt);
                ++crcRewrites;
            } else {
                break;
            }
            if (p.damagedFrom < 0) p.damagedFrom = pos;
            p.damagedUntil = pos + pageLen;
        } else if (!structural) {
            break;
        }
        ++pages;
        pos += pageLen;
    }
    if (!p.patches.empty()) {
        p.kind = "ogg-crc";
        p.detail = std::to_string(headerFixes) + " 页页头单比特纠正、" + std::to_string(payloadFixes) + " 页载荷单比特纠正、" +
                   std::to_string(crcFieldFixes) + " 页仅 CRC 字段一位坏、" + std::to_string(crcRewrites) +
                   " 页 CRC 字段与结构完好的页内容不符（无唯一单比特候选，重算后试解）";
    }
    return p;
}

} // namespace spresil
