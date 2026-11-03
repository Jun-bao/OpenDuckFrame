// OpenDuckFrame - container recovery: AVI (idx1, chunk sizes, ODML, undeclared stream ids)
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
// ───────────────────────── AVI idx1 ─────────────────────────

struct AviLayout {
    int64_t moviPos = -1, idx1Pos = -1, hdrlPos = -1;
    uint32_t idx1Size = 0, hdrlSize = 0;
};

inline bool aviLocate(const Reader& read, int64_t fileSize, AviLayout& out, const AbortFn* abort) {
    auto h = readSpan(read, 0, 12);
    if (h.size() < 12 || std::memcmp(h.data(), "RIFF", 4) != 0 || std::memcmp(h.data() + 8, "AVI ", 4) != 0) return false;
    int64_t pos = 12;
    for (int hops = 0; hops < 256 && pos + 8 <= fileSize; ++hops) {
        if (aborted(abort)) return false;
        auto c = readSpan(read, pos, 12);
        if (c.size() < 8) break;
        const uint32_t size = le32(c.data() + 4);
        if (std::memcmp(c.data(), "LIST", 4) == 0) {
            if (c.size() >= 12 && std::memcmp(c.data() + 8, "movi", 4) == 0) out.moviPos = pos;
            if (c.size() >= 12 && std::memcmp(c.data() + 8, "hdrl", 4) == 0) { out.hdrlPos = pos; out.hdrlSize = size; }
        } else if (std::memcmp(c.data(), "idx1", 4) == 0) {
            out.idx1Pos = pos; out.idx1Size = size;
            break;
        }
        pos += 8 + (int64_t)size + (size & 1);
        if (pos > fileSize) break;
    }
    return out.moviPos >= 0;
}

inline int aviIdx1Sample(const Reader& read, int64_t fileSize, const AviLayout& L, int& matchRel, int& matchAbs,
                         int* sizeMismatchOut = nullptr, int* idMismatchOut = nullptr, uint32_t maxSamples = 32, bool lazyBase = false) {
    matchRel = matchAbs = 0;
    if (sizeMismatchOut) *sizeMismatchOut = 0;
    if (idMismatchOut) *idMismatchOut = 0;
    if (L.idx1Pos < 0 || L.idx1Size < 16) return 0;
    const uint32_t entries = L.idx1Size / 16;
    const uint32_t sample = std::min<uint32_t>(entries, std::max<uint32_t>(maxSamples, 1));
    auto tbl = readSpan(read, L.idx1Pos + 8, std::min<size_t>((size_t)L.idx1Size, 64 * 1024));
    if (tbl.size() < 16) return 0;
    const uint32_t avail = (uint32_t)(tbl.size() / 16);
    int tested = 0;
    auto entryAt = [&](uint32_t i) { return tbl.data() + (size_t)((uint64_t)i * (avail - 1) / std::max<uint32_t>(sample - 1, 1)) * 16; };
    auto check = [&](const uint8_t* e, int64_t at) -> bool {
        const uint32_t sz = le32(e + 12);
        if (at < 0 || at + 8 > fileSize) return false;
        auto ch = readSpan(read, at, 8);
        if (ch.size() != 8) return false;
        if (std::memcmp(ch.data(), e, 4) != 0) { if (idMismatchOut && le32(ch.data() + 4) == sz) ++*idMismatchOut; return false; }
        if (le32(ch.data() + 4) == sz) return true;
        if (sizeMismatchOut) ++*sizeMismatchOut;
        return false;
    };
    auto relAt = [&](const uint8_t* e) { return L.moviPos + 8 + (int64_t)le32(e + 8); };
    auto absAt = [&](const uint8_t* e) { return (int64_t)le32(e + 8); };

    int primary = 0;
    for (uint32_t i = 0; i < sample; ++i) {
        const uint8_t* e = entryAt(i);
        ++tested;
        if (primary != 2 && check(e, relAt(e))) ++matchRel;
        if (primary != 1 && check(e, absAt(e))) ++matchAbs;
        if (lazyBase && i == 0) primary = matchRel > 0 ? 1 : (matchAbs > 0 ? 2 : 0);
    }
    if (primary != 0 && (primary == 1 ? matchRel : matchAbs) * 2 < tested) {
        for (uint32_t i = 1; i < sample; ++i) {
            const uint8_t* e = entryAt(i);
            if (primary == 1 ? check(e, absAt(e)) : check(e, relAt(e))) ++(primary == 1 ? matchAbs : matchRel);
        }
    }
    return tested;
}

inline bool aviHexDigit(uint8_t c) { return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'F') || (c >= 'a' && c <= 'f'); }
inline bool aviMediaChunkId(const uint8_t* id) {
    if (!aviHexDigit(id[0]) || !aviHexDigit(id[1])) return false;
    static const char* kinds[] = {"dc", "db", "wb", "tx", "pc"};
    for (const char* k : kinds) if (id[2] == (uint8_t)k[0] && id[3] == (uint8_t)k[1]) return true;
    return false;
}
inline bool aviOtherChunkId(const uint8_t* id) {
    return std::memcmp(id, "JUNK", 4) == 0 || std::memcmp(id, "LIST", 4) == 0 || (id[0] == 'i' && id[1] == 'x' && aviHexDigit(id[2]) && aviHexDigit(id[3]));
}

inline bool aviPhysicalChainCloses(const Reader& read, int64_t from, int64_t to, int maxChunks, const AbortFn* abort) {
    std::vector<uint8_t> win;
    int64_t winStart = -1;
    int64_t cur = from;
    for (int n = 0; n < maxChunks && cur < to; ++n) {
        if (aborted(abort)) return false;
        if (winStart < 0 || cur < winStart || cur + 8 > winStart + (int64_t)win.size()) {
            win = readSpan(read, cur, (size_t)std::min<int64_t>(64 * 1024, to - cur));
            winStart = cur;
            if (win.size() < 8) return false;
        }
        const uint8_t* h = win.data() + (cur - winStart);
        if (!aviMediaChunkId(h) && !aviOtherChunkId(h)) return false;
        const uint32_t size = le32(h + 4);
        cur += 8 + (int64_t)size + (size & 1);
        if (cur > to) return cur - (size & 1) == to;
    }
    return cur == to;
}

inline RecoveryPlan planAviChunkSizes(const Reader& read, int64_t fileSize, const AbortFn* abort) {
    RecoveryPlan p;
    AviLayout L;
    if (!aviLocate(read, fileSize, L, abort) || L.idx1Pos < 0 || L.idx1Size < 16 || L.idx1Size > 16u * 1024 * 1024) return p;
    auto mh = readSpan(read, L.moviPos, 12);
    if (mh.size() < 12) return p;
    const int64_t moviEnd = L.idx1Pos;
    const int64_t chainFrom = L.moviPos + 12;
    if (moviEnd <= chainFrom) return p;
    if (aviPhysicalChainCloses(read, chainFrom, moviEnd, 1 << 20, abort)) return p;
    auto tbl = readSpan(read, L.idx1Pos + 8, (size_t)L.idx1Size);
    if (tbl.size() != L.idx1Size) return p;
    const size_t entries = tbl.size() / 16;
    if (entries == 0) return p;

    auto hdrAt = [&](int64_t at, uint8_t* out) -> bool {
        if (at < 0 || at + 8 > fileSize) return false;
        auto h = readSpan(read, at, 8);
        if (h.size() != 8) return false;
        std::memcpy(out, h.data(), 8);
        return true;
    };
    int64_t base = -1;
    {
        uint8_t h[8];
        const int64_t off0 = le32(tbl.data() + 8);
        if (hdrAt(L.moviPos + 8 + off0, h) && std::memcmp(h, tbl.data(), 4) == 0) base = L.moviPos + 8;
        else if (hdrAt(off0, h) && std::memcmp(h, tbl.data(), 4) == 0) base = 0;
    }
    if (base < 0) return p;
    int64_t cur = -1;
    std::vector<Patch> patches;
    for (size_t i = 0; i < entries; ++i) {
        if (aborted(abort)) return p;
        const uint8_t* e = tbl.data() + i * 16;
        const uint32_t flags = le32(e + 4);
        if (flags & 0x01) return p;
        if (!aviMediaChunkId(e)) return p;
        const int64_t pos = base + (int64_t)le32(e + 8);
        const uint32_t sz = le32(e + 12);
        if (pos < chainFrom || pos + 8 + (int64_t)sz > moviEnd) return p;
        if (cur >= 0 && pos != cur) {

            if (pos < cur) return p;
            int64_t g = cur;
            for (int k = 0; k < 16 && g < pos; ++k) {
                uint8_t h[8];
                if (!hdrAt(g, h) || !aviOtherChunkId(h)) return p;
                const uint32_t gs = le32(h + 4);
                g += 8 + (int64_t)gs + (gs & 1);
            }
            if (g != pos) return p;
        }
        uint8_t h[8];
        if (!hdrAt(pos, h) || std::memcmp(h, e, 4) != 0) return p;
        if (le32(h + 4) != sz) {
            Patch pt;
            pt.offset = pos + 4;
            putLe32(pt.bytes, sz);
            patches.push_back(pt);
        }
        cur = pos + 8 + (int64_t)sz + (sz & 1);
    }
    if (cur != moviEnd && cur - 1 != moviEnd) return p;
    if (patches.empty()) return p;
    p.patches = std::move(patches);
    p.kind = "avi-chunk-size";
    p.detail = "movi 物理 chunk 链不闭合而 idx1 " + std::to_string(entries) + " 条逐条闭合到 movi 末：以索引长度覆盖 " +
               std::to_string(p.patches.size()) + " 个 chunk 的长度字段";
    p.damagedFrom = p.patches.front().offset; p.damagedUntil = p.patches.back().offset + 4;
    return p;
}

inline RecoveryPlan planAviIdx1(const Reader& read, int64_t fileSize, const AbortFn* abort) {
    RecoveryPlan p;
    AviLayout L;
    if (!aviLocate(read, fileSize, L, abort) || L.idx1Pos < 0 || L.idx1Size < 16) return p;
    const int64_t idx1Pos = L.idx1Pos;
    const uint32_t idx1Size = L.idx1Size;
    int matchRel = 0, matchAbs = 0;
    const int tested = aviIdx1Sample(read, fileSize, L, matchRel, matchAbs);
    if (tested == 0) return p;
    if (matchRel * 2 >= tested || matchAbs * 2 >= tested) return p;
    p.patches.push_back({idx1Pos, {'J', 'U', 'N', 'K'}});
    p.kind = "avi-idx1";
    p.detail = "idx1 抽样 " + std::to_string(tested) + " 条与 movi chunk 不符（相对 " + std::to_string(matchRel) +
               " / 绝对 " + std::to_string(matchAbs) + " 命中）：屏蔽为 JUNK，顺序读 movi";
    p.damagedFrom = idx1Pos; p.damagedUntil = idx1Pos + 8 + idx1Size;
    return p;
}

inline int aviOdmlStdIndexSample(const Reader& read, int64_t fileSize, int64_t indxPos, uint32_t indxSize, int& match) {
    match = 0;
    auto h = readSpan(read, indxPos + 8, 24);
    if (h.size() < 24) return 0;
    const uint16_t longsPerEntry = (uint16_t)(h[0] | (h[1] << 8));
    const uint8_t indexType = h[3];
    const uint32_t inUse = le32(h.data() + 4);
    const uint8_t* chunkId = h.data() + 8;
    const int64_t base = (int64_t)le64(h.data() + 12);
    if (indexType != 1 || longsPerEntry != 2 || inUse == 0 || indxSize < 24) return 0;
    const uint32_t avail = std::min<uint32_t>(inUse, (indxSize - 24) / 8);
    if (avail == 0) return 0;
    const uint32_t sample = std::min<uint32_t>(avail, 32);
    auto tbl = readSpan(read, indxPos + 8 + 24, std::min<size_t>((size_t)avail * 8, 64 * 1024));
    const uint32_t have = (uint32_t)(tbl.size() / 8);
    if (have == 0) return 0;
    int tested = 0;
    for (uint32_t i = 0; i < sample; ++i) {
        const uint32_t idx = (uint32_t)((uint64_t)i * (have - 1) / std::max<uint32_t>(sample - 1, 1));
        const uint8_t* e = tbl.data() + (size_t)idx * 8;
        const uint32_t off = le32(e), sz = le32(e + 4) & 0x7FFFFFFF;
        ++tested;
        const int64_t at = base + (int64_t)off - 8;
        if (at < 0 || at + 8 > fileSize) continue;
        auto ch = readSpan(read, at, 8);
        if (ch.size() == 8 && std::memcmp(ch.data(), chunkId, 4) == 0 && le32(ch.data() + 4) == sz) ++match;
    }
    return tested;
}

inline RecoveryPlan planAviOdml(const Reader& read, int64_t fileSize, const AbortFn* abort) {
    RecoveryPlan p;
    AviLayout L;
    if (!aviLocate(read, fileSize, L, abort) || L.hdrlPos < 0 || L.idx1Pos < 0 || L.idx1Size < 16) return p;
    if (L.hdrlSize < 12 || L.hdrlSize > 16u * 1024 * 1024) return p;
    // hdrl → strl → indx
    std::vector<std::pair<int64_t, uint32_t>> indxes;
    int64_t pos = L.hdrlPos + 12;
    const int64_t hdrlEnd = L.hdrlPos + 8 + L.hdrlSize;
    for (int hops = 0; hops < 64 && pos + 8 <= hdrlEnd; ++hops) {
        if (aborted(abort)) return p;
        auto c = readSpan(read, pos, 12);
        if (c.size() < 8) break;
        const uint32_t size = le32(c.data() + 4);
        if (std::memcmp(c.data(), "LIST", 4) == 0 && c.size() >= 12 && std::memcmp(c.data() + 8, "strl", 4) == 0) {
            int64_t q = pos + 12;
            const int64_t strlEnd = std::min<int64_t>(hdrlEnd, pos + 8 + size);
            for (int k = 0; k < 64 && q + 8 <= strlEnd; ++k) {
                auto d = readSpan(read, q, 8);
                if (d.size() < 8) break;
                const uint32_t dsz = le32(d.data() + 4);
                if (std::memcmp(d.data(), "indx", 4) == 0 && dsz >= 24) indxes.push_back({q, dsz});
                q += 8 + (int64_t)dsz + (dsz & 1);
            }
        }
        pos += 8 + (int64_t)size + (size & 1);
    }
    if (indxes.empty()) return p;
    int badIndexes = 0, checked = 0;
    for (const auto& ix : indxes) {
        auto h = readSpan(read, ix.first + 8, 24);
        if (h.size() < 24) continue;
        const uint8_t indexType = h[3];
        if (indexType == 1) {
            int match = 0;
            const int tested = aviOdmlStdIndexSample(read, fileSize, ix.first, ix.second, match);
            if (tested == 0) continue;
            ++checked;
            if (match * 2 < tested) ++badIndexes;
        } else if (indexType == 0) {

            const uint32_t inUse = le32(h.data() + 4);
            const uint32_t avail = std::min<uint32_t>(std::min<uint32_t>(inUse, (ix.second - 24) / 16), 8);
            auto tbl = readSpan(read, ix.first + 8 + 24, (size_t)avail * 16);
            int subBad = 0, subChecked = 0;
            for (uint32_t i = 0; i + 1 <= tbl.size() / 16; ++i) {
                const int64_t subPos = (int64_t)le64(tbl.data() + (size_t)i * 16);
                if (subPos < 0 || subPos + 32 > fileSize) { ++subBad; ++subChecked; continue; }
                auto sh = readSpan(read, subPos, 8);
                if (sh.size() < 8 || sh[0] != 'i' || sh[1] != 'x') { ++subBad; ++subChecked; continue; }
                const uint32_t subSize = le32(sh.data() + 4);
                if (subSize < 24) { ++subBad; ++subChecked; continue; }
                int match = 0;
                const int tested = aviOdmlStdIndexSample(read, fileSize, subPos, subSize, match);
                if (tested == 0) continue;
                ++subChecked;
                if (match * 2 < tested) ++subBad;
            }
            if (subChecked == 0) continue;
            ++checked;
            if (subBad > 0) ++badIndexes;
        }
    }
    if (checked == 0 || badIndexes == 0) return p;
    int matchRel = 0, matchAbs = 0;
    const int tested = aviIdx1Sample(read, fileSize, L, matchRel, matchAbs);
    if (tested == 0 || !(matchRel * 2 >= tested || matchAbs * 2 >= tested)) return p;
    for (const auto& ix : indxes) p.patches.push_back({ix.first, {'J', 'U', 'N', 'K'}});
    p.kind = "avi-odml";
    p.detail = "OpenDML 索引 " + std::to_string(badIndexes) + "/" + std::to_string(checked) + " 个抽样与 chunk 不符、idx1 抽样相符（" +
               std::to_string(std::max(matchRel, matchAbs)) + "/" + std::to_string(tested) + "）：屏蔽 " +
               std::to_string(indxes.size()) + " 个 indx 回落 idx1";
    p.damagedFrom = indxes[0].first; p.damagedUntil = indxes[0].first + 8 + indxes[0].second;
    return p;
}

struct AviTrackDecl { std::string type, codec; uint32_t width = 0, height = 0; };

inline std::vector<AviTrackDecl> aviReadTracks(const Reader& read, int64_t fileSize, const AviLayout& L) {
    std::vector<AviTrackDecl> out;
    if (L.hdrlPos < 0 || L.hdrlSize < 4 || L.hdrlSize > 4u * 1024 * 1024 || L.hdrlPos + 8 + (int64_t)L.hdrlSize > fileSize) return out;
    auto body = readSpan(read, L.hdrlPos + 12, (size_t)L.hdrlSize - 4);
    if (body.size() + 4 != L.hdrlSize) return out;
    size_t pos = 0;
    while (pos + 12 <= body.size() && out.size() < 64) {
        const uint32_t sz = le32(body.data() + pos + 4);
        if (sz > body.size() - pos - 8) break;
        if (std::memcmp(body.data() + pos, "LIST", 4) == 0 && std::memcmp(body.data() + pos + 8, "strl", 4) == 0) {
            AviTrackDecl t;
            size_t q = pos + 12; const size_t end = pos + 8 + sz;
            while (q + 8 <= end) {
                const uint32_t cs = le32(body.data() + q + 4);
                if (cs > end - q - 8) break;
                const uint8_t* d = body.data() + q + 8;
                if (std::memcmp(body.data() + q, "strh", 4) == 0 && cs >= 8) t.type.assign((const char*)d, 4);
                else if (std::memcmp(body.data() + q, "strf", 4) == 0 && cs >= 20 && t.type == "vids") {
                    t.width = le32(d + 4); const uint32_t h = le32(d + 8); t.height = (h & 0x80000000u) ? (uint32_t)(0u - h) : h;
                    t.codec.assign((const char*)d + 16, 4);
                }
                q += 8 + cs + (cs & 1);
            }
            out.push_back(t);
        }
        pos += 8 + sz + (sz & 1);
    }
    return out;
}

inline int aviChunkStreamNumber(const uint8_t* id) {
    if (id[0] < '0' || id[0] > '9' || id[1] < '0' || id[1] > '9') return -1;
    return (id[0] - '0') * 10 + (id[1] - '0');
}

inline bool aviJpegFrameComplete(const uint8_t* d, size_t n, uint32_t w, uint32_t h) {
    while (n > 0 && d[n - 1] == 0) --n;
    if (n < 4 || d[0] != 0xFF || d[1] != 0xD8 || d[n - 2] != 0xFF || d[n - 1] != 0xD9) return false;
    size_t p = 2; bool sof = false, sos = false;
    while (p < n) {
        if (d[p] != 0xFF) return false;
        while (p < n && d[p] == 0xFF) ++p;
        if (p >= n) return false;
        const uint8_t marker = d[p++];
        if (marker == 0xD9) return p == n && sof && sos;
        if (marker == 0xD8 || marker == 0x00 || (marker >= 0xD0 && marker <= 0xD7)) return false;
        if (p + 2 > n) return false;
        const size_t len = ((size_t)d[p] << 8) | d[p + 1];
        if (len < 2 || p + len > n) return false;
        if (marker == 0xC0 || marker == 0xC1) {
            if (sof || len < 11 || d[p + 2] != 8) return false;
            const uint32_t fh = ((uint32_t)d[p + 3] << 8) | d[p + 4], fw = ((uint32_t)d[p + 5] << 8) | d[p + 6];
            if ((w && fw != w) || (h && fh != h) || len != 8u + 3u * d[p + 7]) return false;
            sof = true;
        } else if (marker == 0xC2 || marker == 0xC3 || (marker >= 0xC5 && marker <= 0xC7) || (marker >= 0xC9 && marker <= 0xCB) || (marker >= 0xCD && marker <= 0xCF)) return false;
        p += len;
        if (marker == 0xDA) {
            if (!sof || sos) return false;
            sos = true;
            while (p + 1 < n) {
                if (d[p] != 0xFF) { ++p; continue; }
                if (d[p + 1] == 0 || (d[p + 1] >= 0xD0 && d[p + 1] <= 0xD7)) { p += 2; continue; }
                break;
            }
        }
    }
    return false;
}

inline RecoveryPlan planAviUnknownStreamIds(const Reader& read, int64_t fileSize, const AbortFn* abort) {
    RecoveryPlan p;
    AviLayout L;
    if (!aviLocate(read, fileSize, L, abort) || L.idx1Pos < 0 || L.idx1Size < 16 || L.idx1Size > 16u * 1024 * 1024 || L.hdrlPos < 0) return p;
    const std::vector<AviTrackDecl> tracks = aviReadTracks(read, fileSize, L);
    if (tracks.empty()) return p;
    auto tbl = readSpan(read, L.idx1Pos + 8, (size_t)L.idx1Size);
    if (tbl.size() != L.idx1Size) return p;
    const size_t entries = tbl.size() / 16;
    auto hdrAt = [&](int64_t at, uint8_t* out) -> bool {
        if (at < 0 || at + 8 > fileSize) return false;
        auto h = readSpan(read, at, 8);
        if (h.size() != 8) return false;
        std::memcpy(out, h.data(), 8);
        return true;
    };
    int64_t base = -1;
    for (size_t i = 0; i < entries && base < 0; ++i) {
        const uint8_t* e = tbl.data() + i * 16;
        if (!aviMediaChunkId(e) || (le32(e + 4) & 1)) continue;
        const uint32_t off = le32(e + 8), sz = le32(e + 12);
        uint8_t h[8];
        if (hdrAt(L.moviPos + 8 + (int64_t)off, h) && le32(h + 4) == sz) base = L.moviPos + 8;
        else if (hdrAt(off, h) && le32(h + 4) == sz) base = 0;
    }
    if (base < 0) return p;
    static const char* kStartCodeCodecs[] = {"H264", "h264", "avc1", "AVC1", "x264", "X264", "XVID", "xvid", "DIVX", "divx", "DX50", "FMP4",
                                             "MP4V", "mp4v", "MPG1", "mpg1", "MPG2", "mpg2", "MPEG", "mpeg", "HEVC", "hevc", "H265", "h265"};
    static const char* kJpegCodecs[] = {"MJPG", "mjpg", "JPEG", "jpeg", "dmb1", "MJPA", "mjpa"};
    int checked = 0;
    for (size_t i = 0; i < entries; ++i) {
        if (aborted(abort)) return RecoveryPlan{};
        const uint8_t* e = tbl.data() + i * 16;
        if (!aviMediaChunkId(e) || (le32(e + 4) & 1)) continue;
        const int64_t pos = base + (int64_t)le32(e + 8);
        const uint32_t sz = le32(e + 12);
        uint8_t h[8];
        if (!hdrAt(pos, h) || le32(h + 4) != sz) continue;
        if (std::memcmp(h, e, 4) == 0) continue;
        ++checked;
        const int physSid = aviChunkStreamNumber(h);
        if (physSid >= 0 && physSid < (int)tracks.size()) return RecoveryPlan{};
        const int idxSid = aviChunkStreamNumber(e);
        if (idxSid < 0 || idxSid >= (int)tracks.size()) continue;
        if (h[2] != e[2] || h[3] != e[3] || !((e[2] == 'd' && (e[3] == 'c' || e[3] == 'b')))) continue;
        int bits = 0;
        for (int k = 0; k < 4; ++k) bits += popcount8((uint8_t)(h[k] ^ e[k]));
        if (bits != 1) continue;
        const AviTrackDecl& t = tracks[(size_t)idxSid];
        if (t.type != "vids" || sz < 8 || sz > 32u * 1024 * 1024) continue;
        auto body = readSpan(read, pos + 8, (size_t)sz);
        if (body.size() != sz) continue;
        bool jpeg = false, sc = false;
        for (const char* c : kJpegCodecs) if (t.codec == c) jpeg = true;
        for (const char* c : kStartCodeCodecs) if (t.codec == c) sc = true;
        bool bodyOk = false;
        if (jpeg) bodyOk = aviJpegFrameComplete(body.data(), body.size(), t.width, t.height);
        else if (sc) bodyOk = body[0] == 0 && body[1] == 0 && (body[2] == 1 || (body[2] == 0 && body[3] == 1));
        if (!bodyOk) continue;
        Patch pt; pt.offset = pos; pt.bytes.assign(e, e + 4);
        p.patches.push_back(pt);
        if (p.patches.size() >= 65536) break;
    }
    if (p.patches.empty()) return p;
    p.kind = "avi-chunk-stream";
    p.detail = "movi 里 " + std::to_string(p.patches.size()) + " 个媒体 chunk 的流号未声明（idx1 同位置条目指向已声明视频轨、id 只差一位、长度相符、媒体体自描述完整）→ 改回索引里的 id（核对 " +
               std::to_string(checked) + " 处 id 不符）";
    p.damagedFrom = p.patches.front().offset; p.damagedUntil = p.patches.back().offset + 4;
    return p;
}

} // namespace spresil
