// OpenDuckFrame - container recovery: Matroska (cluster block chains, parent CRC sizes, Info/Tracks single-bit fields, FLAC lacing, ContentEncodings)
//
// Split out of the umbrella header by section; function bodies, constants and inline
// attributes are unchanged. Callers keep including the umbrella; this file only guarantees
// that it compiles on its own.
#pragma once

#include "RecoveryBase.hpp"
#include "RecoveryTypes.hpp"

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

struct MkvCluster { int64_t pos; int64_t timecode; };

inline int64_t mkvReadClusterTimecode(const Reader& read, int64_t pos) {
    auto h = readSpan(read, pos, 64);
    if (h.size() < 12 || !(h[0] == 0x1F && h[1] == 0x43 && h[2] == 0xB6 && h[3] == 0x75)) return -1;
    uint64_t sz = 0; bool un = false;
    const int sl = ebmlReadSize(h.data() + 4, h.size() - 4, sz, un);
    if (sl == 0) return -1;
    size_t off = 4 + (size_t)sl;
    for (int child = 0; child < 4 && off + 2 <= h.size(); ++child) {
        const int idLen = ebmlVintLen(h[off]);
        if (idLen == 0 || idLen > 4 || off + (size_t)idLen >= h.size()) return -1;
        uint64_t csz = 0; bool cun = false;
        const int csl = ebmlReadSize(h.data() + off + idLen, h.size() - off - idLen, csz, cun);
        if (csl == 0 || cun) return -1;
        const size_t data = off + (size_t)idLen + (size_t)csl;
        if (idLen == 1 && h[off] == 0xE7) {
            if (csz < 1 || csz > 8 || data + csz > h.size()) return -1;
            int64_t tc = 0;
            for (uint64_t k = 0; k < csz; ++k) tc = (tc << 8) | h[data + k];
            return tc;
        }
        if (csz > 32) return -1;
        off = data + (size_t)csz;
    }
    return -1;
}

inline std::vector<int> mkvReadTrackNumbers(const Reader& read, int64_t fileSize, const AbortFn* abort) {
    std::vector<int> out;
    static const uint8_t tid[4] = {0x16, 0x54, 0xAE, 0x6B};
    int64_t cur = 0, hit = -1;
    const int64_t limit = std::min<int64_t>(fileSize, 8ll * 1024 * 1024);
    FindCursor fc;
    for (int tries = 0; tries < 64 && findBytes(read, cur, limit, tid, 4, hit, abort, &fc); ++tries) {
        cur = hit + 1;
        auto h = readSpan(read, hit + 4, 8);
        uint64_t sz = 0; bool un = false;
        const int sl = h.size() >= 1 ? ebmlReadSize(h.data(), h.size(), sz, un) : 0;
        if (sl == 0 || un || sz < 8 || sz > 4ll * 1024 * 1024) continue;
        auto body = readSpan(read, hit + 4 + sl, (size_t)sz);
        if (body.size() != sz) continue;

        size_t off = 0;
        while (off + 2 < body.size() && (body[off] == 0xBF || body[off] == 0xEC)) {
            uint64_t s0 = 0; bool u0 = false;
            const int l0 = ebmlReadSize(body.data() + off + 1, body.size() - off - 1, s0, u0);
            if (l0 == 0 || u0 || off + 1 + (size_t)l0 + s0 > body.size()) break;
            off += 1 + (size_t)l0 + (size_t)s0;
        }
        if (off >= body.size() || body[off] != 0xAE) continue;
        bool ok = true;
        while (off < body.size()) {
            const int idLen = ebmlVintLen(body[off]);
            if (idLen == 0 || idLen > 4 || off + (size_t)idLen >= body.size()) { ok = false; break; }
            uint64_t esz = 0; bool eun = false;
            const int esl = ebmlReadSize(body.data() + off + idLen, body.size() - off - idLen, esz, eun);
            if (esl == 0 || eun) { ok = false; break; }
            const size_t data = off + (size_t)idLen + (size_t)esl;
            if (data + esz > body.size()) { ok = false; break; }
            if (idLen == 1 && body[off] == 0xAE) {

                size_t o2 = data;
                const size_t end2 = data + (size_t)esz;
                while (o2 < end2) {
                    const int il = ebmlVintLen(body[o2]);
                    if (il == 0 || il > 4 || o2 + (size_t)il >= end2) break;
                    uint64_t s2 = 0; bool u2 = false;
                    const int sl2 = ebmlReadSize(body.data() + o2 + il, end2 - o2 - il, s2, u2);
                    if (sl2 == 0 || u2) break;
                    const size_t d2 = o2 + (size_t)il + (size_t)sl2;
                    if (d2 + s2 > end2) break;
                    if (il == 1 && body[o2] == 0xD7 && s2 >= 1 && s2 <= 4) {
                        int v = 0;
                        for (uint64_t k = 0; k < s2; ++k) v = (v << 8) | body[d2 + k];
                        if (v > 0) out.push_back(v);
                    }
                    o2 = d2 + (size_t)s2;
                }
            }
            off = data + (size_t)esz;
        }
        if (ok && !out.empty()) return out;
        out.clear();
    }
    return out;
}

inline int64_t mkvFindEnclosingCluster(const Reader& read, int64_t from, int64_t maxBack, int64_t* timecodeOut,
                                       const AbortFn* abort) {
    constexpr int64_t kChunk = 1024 * 1024;
    const int64_t stop = std::max<int64_t>(0, from - maxBack);
    int64_t hi = from;
    while (hi > stop) {
        if (aborted(abort)) return -1;
        const int64_t lo = std::max(stop, hi - kChunk);
        auto buf = readSpan(read, lo, (size_t)(hi - lo + 3));
        for (int64_t i = (int64_t)buf.size() - 4; i >= 0; --i) {
            if (buf[(size_t)i] != 0x1F || buf[(size_t)i + 1] != 0x43 || buf[(size_t)i + 2] != 0xB6 || buf[(size_t)i + 3] != 0x75) continue;
            const int64_t pos = lo + i;
            if (pos >= from) continue;
            const int64_t tc = mkvReadClusterTimecode(read, pos);
            if (tc >= 0) { if (timecodeOut) *timecodeOut = tc; return pos; }
        }
        hi = lo;
    }
    return -1;
}

struct MkvBlockInfo {
    int64_t total = 0;
    int track = 0;
    int16_t relTc = 0;
    uint8_t flags = 0;
    bool group = false;  // BlockGroup（A0）
};

inline bool mkvParseBlock(const uint8_t* d, size_t n, const std::vector<int>& tracks, int64_t limitLen, MkvBlockInfo& out) {
    out = MkvBlockInfo{};
    if (n < 6) return false;
    const uint8_t id = d[0];
    if (id != 0xA3 && id != 0xA0 && id != 0xEC) return false;
    uint64_t size = 0; bool unknown = false;
    const int sl = ebmlReadSize(d + 1, n - 1, size, unknown);
    if (sl == 0 || unknown) return false;
    const int64_t total = 1 + sl + (int64_t)size;
    if (total > limitLen || size > 32ull * 1024 * 1024) return false;
    out.total = total;
    if (id == 0xEC) return true; // Void
    const uint8_t* b = d + 1 + sl;
    size_t bn = std::min<size_t>(n - 1 - (size_t)sl, (size_t)size);
    if (bn < size) return false;
    if (id == 0xA0) {

        size_t off = 0;
        const uint8_t* blk = nullptr; size_t blkLen = 0; int found = 0;
        for (int k = 0; k < 16 && off < bn; ++k) {
            const int idLen = ebmlVintLen(b[off]);
            if (idLen == 0 || idLen > 4 || off + (size_t)idLen >= bn) return false;
            uint64_t es = 0; bool eu = false;
            const int esl = ebmlReadSize(b + off + idLen, bn - off - idLen, es, eu);
            if (esl == 0 || eu) return false;
            const size_t data = off + (size_t)idLen + (size_t)esl;
            if (data + es > bn) return false;
            if (idLen == 1 && b[off] == 0xA1) { ++found; blk = b + data; blkLen = (size_t)es; }
            off = data + (size_t)es;
        }
        if (found != 1 || off != bn) return false;
        b = blk; bn = blkLen; out.group = true;
    }
    if (bn < 4) return false;
    uint64_t track = 0; bool tu = false;
    const int tl = ebmlReadSize(b, bn, track, tu);
    if (tl == 0 || tl > 4 || tu) return false;
    bool known = false;
    for (int t : tracks) if ((uint64_t)t == track) known = true;
    if (!known) return false;
    if (bn < (size_t)tl + 3) return false;
    const uint8_t flags = b[tl + 2];
    if (id == 0xA3 ? (flags & 0x70) != 0 : (flags & 0xF1) != 0) return false;
    out.track = (int)track;
    out.relTc = (int16_t)(((uint16_t)b[tl] << 8) | b[tl + 1]);
    out.flags = flags;

    const int lacing = (flags >> 1) & 3;
    if (lacing != 0) {
        size_t off = (size_t)tl + 3;
        if (off >= bn) return false;
        const int frames = b[off++] + 1;
        const size_t remain = bn - off;
        if (lacing == 2) {
            if (remain % (size_t)frames != 0) return false;
        } else if (lacing == 1) { // Xiph
            uint64_t sum = 0;
            for (int f = 0; f < frames - 1; ++f) {
                uint64_t len = 0;
                while (true) {
                    if (off >= bn) return false;
                    const uint8_t v = b[off++];
                    len += v;
                    if (v != 255) break;
                }
                sum += len;
            }
            if (off + sum > bn) return false;
        } else { // EBML
            if (off >= bn) return false;
            uint64_t first = 0; bool fu = false;
            const int fl = ebmlReadSize(b + off, bn - off, first, fu);
            if (fl == 0 || fu || first > bn) return false;
            off += (size_t)fl;
            int64_t prev = (int64_t)first, sum = (int64_t)first;
            for (int f = 1; f < frames - 1; ++f) {
                if (off >= bn) return false;
                uint64_t raw = 0; bool ru = false;
                const int rl = ebmlReadSize(b + off, bn - off, raw, ru);
                if (rl == 0 || ru) return false;
                off += (size_t)rl;
                const int64_t bias = (int64_t)((1ull << (7 * rl - 1)) - 1);
                const int64_t cur = prev + ((int64_t)raw - bias);
                if (cur < 0 || (uint64_t)cur > bn) return false;
                sum += cur; prev = cur;
            }
            if (sum < 0 || off + (uint64_t)sum > bn) return false;
        }
    }
    return true;
}

inline int64_t mkvValidBlockAt(const uint8_t* d, size_t n, const std::vector<int>& tracks, int64_t limitLen) {
    MkvBlockInfo i;
    return mkvParseBlock(d, n, tracks, limitLen, i) ? i.total : 0;
}

inline RecoveryPlan planMkvClusterChains(const Reader& read, int64_t from, int64_t to, const std::vector<int>& tracks,
                                         const std::vector<MkvCluster>& clusters, const AbortFn* abort,
                                         int64_t minRelTcForEnclosing = INT64_MIN) {
    RecoveryPlan p;
    if (tracks.empty() || clusters.empty() || to <= from) return p;
    constexpr int64_t kHeader = 22;
    constexpr int kMinChain = 3;
    constexpr int64_t kMaxScan = 32ll * 1024 * 1024;
    const int64_t scanTo = std::min(to, from + kMaxScan);

    auto buf = readSpan(read, from, (size_t)(scanTo - from));
    if (buf.size() < (size_t)kHeader + 8) return p;
    const int64_t bufEnd = from + (int64_t)buf.size();
    int64_t cur = from + kHeader;
    int64_t lastChainEnd = from;
    while (cur < bufEnd && p.patches.size() < 8) {
        if (aborted(abort)) break;

        int64_t chainStart = -1, chainEnd = -1;
        int chainLen = 0;
        for (int64_t o = cur; o < bufEnd; ++o) {
            const uint8_t c = buf[(size_t)(o - from)];
            if (c != 0xA3 && c != 0xA0) continue;

            int64_t q = o;
            int cnt = 0;
            while (q < bufEnd) {
                const int64_t len = mkvValidBlockAt(buf.data() + (q - from), (size_t)(bufEnd - q), tracks, bufEnd - q);
                if (len <= 0) break;
                ++cnt;
                q += len;
            }
            if (cnt >= kMinChain || (cnt >= 1 && q == to)) { chainStart = o; chainEnd = q; chainLen = cnt; break; }
        }
        if (chainStart < 0) break;
        if (chainStart - kHeader < lastChainEnd) {

            cur = chainStart + 1;
            continue;
        }

        int64_t timecode = -1, bestPos = INT64_MIN;
        for (const MkvCluster& c : clusters) {
            if (c.pos <= chainStart && c.pos > bestPos) { bestPos = c.pos; timecode = c.timecode; }
        }
        if (timecode < 0) break;
        if (bestPos < from && minRelTcForEnclosing != INT64_MIN) {

            MkvBlockInfo info;
            mkvParseBlock(buf.data() + (chainStart - from), (size_t)(bufEnd - chainStart), tracks, bufEnd - chainStart, info);
            const int16_t rel = info.relTc;
            if ((int64_t)rel < minRelTcForEnclosing) {

                cur = chainEnd + kHeader;
                lastChainEnd = chainEnd;
                continue;
            }
        }
        Patch pt;
        pt.offset = chainStart - kHeader;
        pt.bytes = {0x1F, 0x43, 0xB6, 0x75, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xE7, 0x88};
        putBe64(pt.bytes, (uint64_t)timecode);
        p.patches.push_back(pt);
        if (p.damagedFrom < 0) p.damagedFrom = from;
        p.damagedUntil = chainStart;
        p.detail += "块链@" + std::to_string(chainStart) + "(" + std::to_string(chainLen) + " 块, 簇 tc=" +
                    std::to_string(timecode) + "); ";
        lastChainEnd = chainEnd;
        cur = chainEnd + kHeader;
        if (chainEnd >= to) break;
    }
    if (!p.patches.empty()) p.kind = "mkv-cluster";
    return p;
}

inline const std::array<uint32_t, 256>& ieeeCrcTable() {
    static const std::array<uint32_t, 256> table = [] {
        std::array<uint32_t, 256> t{};
        for (uint32_t i = 0; i < 256; ++i) {
            uint32_t r = i;
            for (int k = 0; k < 8; ++k) r = (r & 1) ? (r >> 1) ^ 0xEDB88320u : (r >> 1);
            t[i] = r;
        }
        return t;
    }();
    return table;
}

inline uint32_t ieeeCrcUpdate(uint32_t state, const uint8_t* d, size_t n) {
    return ~(uint32_t)crc32_z(~state, d, n);
}
inline uint32_t ieeeCrc32(const uint8_t* d, size_t n) { return ~ieeeCrcUpdate(0xFFFFFFFFu, d, n); }

struct MkvClusterHead {
    int64_t pos = -1;
    int sizeLen = 0;
    uint64_t size = 0;
    bool unknownSize = false;
    int64_t dataStart = -1;
    bool hasCrc = false;
    uint32_t crc = 0;
    int64_t crcEnd = -1;
};

inline bool mkvReadClusterHead(const Reader& read, int64_t pos, MkvClusterHead& out) {
    out = MkvClusterHead{};
    auto h = readSpan(read, pos, 24);
    if (h.size() < 12 || !(h[0] == 0x1F && h[1] == 0x43 && h[2] == 0xB6 && h[3] == 0x75)) return false;
    uint64_t sz = 0; bool un = false;
    const int sl = ebmlReadSize(h.data() + 4, h.size() - 4, sz, un);
    if (sl == 0) return false;
    out.pos = pos; out.sizeLen = sl; out.size = sz; out.unknownSize = un;
    out.dataStart = pos + 4 + sl;
    const size_t o = 4 + (size_t)sl;
    if (o + 6 <= h.size() && h[o] == 0xBF && h[o + 1] == 0x84) {
        out.hasCrc = true;
        out.crc = le32(h.data() + o + 2);
        out.crcEnd = out.dataStart + 6;
    }
    return mkvReadClusterTimecode(read, pos) >= 0;
}

inline bool mkvClusterChildrenClose(const uint8_t* buf, size_t len, size_t from, const std::vector<int>& tracks, size_t* brokenAt,
                                    size_t* lastOk) {
    size_t off = from;
    size_t last = from;
    while (off < len) {
        const uint8_t id0 = buf[off];
        int64_t total = 0;
        if (id0 == 0xA3 || id0 == 0xA0 || id0 == 0xEC) {
            total = mkvValidBlockAt(buf + off, len - off, tracks, (int64_t)(len - off));
        } else {
            const int idLen = ebmlVintLen(id0);

            const bool known = (idLen == 1 && (id0 == 0xBF || id0 == 0xE7 || id0 == 0xA7 || id0 == 0xAB || id0 == 0xAF)) ||
                               (idLen == 2 && off + 1 < len && id0 == 0x58 && buf[off + 1] == 0x54);
            if (known && off + (size_t)idLen < len) {
                uint64_t es = 0; bool eu = false;
                const int esl = ebmlReadSize(buf + off + idLen, len - off - idLen, es, eu);
                if (esl > 0 && !eu && (uint64_t)idLen + (uint64_t)esl + es <= len - off) total = idLen + esl + (int64_t)es;
            }
        }
        if (total <= 0) { if (brokenAt) *brokenAt = off; if (lastOk) *lastOk = last; return false; }
        last = off;
        off += (size_t)total;
    }
    if (brokenAt) *brokenAt = len;
    if (lastOk) *lastOk = last;
    return off == len;
}

inline int64_t mkvFindNextClusterHead(const Reader& read, int64_t from, int64_t fileSize, int64_t window, const AbortFn* abort) {
    static const uint8_t cid[4] = {0x1F, 0x43, 0xB6, 0x75};
    int64_t cur = from, hit = -1;
    const int64_t limit = std::min(fileSize, from + window);
    FindCursor fc;
    for (int tries = 0; tries < 4096 && cur < limit; ++tries) {
        if (aborted(abort)) return -1;
        if (!findBytes(read, cur, limit, cid, 4, hit, abort, &fc)) return -1;
        if (mkvReadClusterTimecode(read, hit) >= 0) return hit;
        cur = hit + 1;
    }
    return -1;
}

inline RecoveryPlan planMkvCrcSizeFixAt(const Reader& read, int64_t fileSize, int64_t cpos, const std::vector<int>& tracks,
                                        const AbortFn* abort);

inline RecoveryPlan planMkvCrcSizeFix(const Reader& read, int64_t fileSize, int64_t damagePos, const std::vector<int>& tracks,
                                      const AbortFn* abort) {
    RecoveryPlan p;
    if (tracks.empty() || damagePos <= 0) return p;
    constexpr int64_t kMaxCluster = 64ll * 1024 * 1024;
    int64_t tc = -1;
    int64_t cpos = mkvFindEnclosingCluster(read, damagePos, kMaxCluster, &tc, abort);
    for (int back = 0; back < 2 && cpos >= 0; ++back) {
        RecoveryPlan one = planMkvCrcSizeFixAt(read, fileSize, cpos, tracks, abort);
        if (!one.empty()) return one;

        cpos = mkvFindEnclosingCluster(read, cpos, kMaxCluster, &tc, abort);
    }
    return p;
}

inline RecoveryPlan planMkvCrcSizeFixAt(const Reader& read, int64_t fileSize, int64_t cpos, const std::vector<int>& tracks,
                                        const AbortFn* abort) {
    RecoveryPlan p;
    constexpr int64_t kMaxCluster = 64ll * 1024 * 1024;
    MkvClusterHead head;
    if (!mkvReadClusterHead(read, cpos, head) || !head.hasCrc) return p;

    int64_t anchor = mkvFindNextClusterHead(read, head.dataStart, fileSize, kMaxCluster, abort);
    if (anchor < 0) { if (fileSize - head.dataStart <= kMaxCluster) anchor = fileSize; else return p; }
    if (anchor <= head.crcEnd) return p;
    auto buf = readSpan(read, head.dataStart, (size_t)(anchor - head.dataStart));
    if ((int64_t)buf.size() != anchor - head.dataStart) return p;
    const size_t len = buf.size();
    const size_t crcFrom = (size_t)(head.crcEnd - head.dataStart);
    const uint64_t actualSize = (uint64_t)len;
    const bool declaredMatches = head.unknownSize || head.size == actualSize;
    size_t brokenAt = 0, lastOk = 0;
    if (mkvClusterChildrenClose(buf.data(), len, crcFrom, tracks, &brokenAt, &lastOk)) {
        if (declaredMatches) return p;
        if (ieeeCrc32(buf.data() + crcFrom, len - crcFrom) != head.crc) return p;

        if (head.sizeLen < 1 || head.sizeLen > 8) return p;
        const uint64_t maxVal = (1ull << (7 * head.sizeLen)) - 2;
        if (actualSize > maxVal) return p;
        Patch pt;
        pt.offset = cpos + 4;
        uint64_t v = actualSize;
        std::vector<uint8_t> enc((size_t)head.sizeLen, 0);
        for (int i = head.sizeLen - 1; i >= 0; --i) { enc[(size_t)i] = (uint8_t)(v & 0xff); v >>= 8; }
        enc[0] |= (uint8_t)(0x80 >> (head.sizeLen - 1));
        pt.bytes = enc;
        p.patches.push_back(pt);
        p.kind = "mkv-crc-size";
        p.detail = "簇@" + std::to_string(cpos) + " 声明 size " + std::to_string(head.size) + " ≠ 子链闭合到后继簇头的 " +
                   std::to_string(actualSize) + "（原存 CRC-32 相符）：只改 size";
        p.damagedFrom = cpos; p.damagedUntil = head.dataStart;
        return p;
    }

    if (!declaredMatches) return p;
    if (lastOk < crcFrom || lastOk >= len) return p;
    const int idLen = ebmlVintLen(buf[lastOk]);
    if (idLen == 0 || idLen > 4 || lastOk + (size_t)idLen >= len) return p;
    uint64_t es = 0; bool eu = false;
    const int esl = ebmlReadSize(buf.data() + lastOk + idLen, len - lastOk - idLen, es, eu);
    if (esl == 0 || eu) return p;
    const size_t sizeAt = lastOk + (size_t)idLen;
    const uint32_t prefixState = ieeeCrcUpdate(0xFFFFFFFFu, buf.data() + crcFrom, sizeAt - crcFrom);
    std::vector<uint8_t> work = buf;
    int hits = 0; std::vector<uint8_t> hitBytes; uint64_t hitSize = 0;
    const uint64_t maxVal = (1ull << (7 * esl)) - 2;
    for (int bit = 0; bit < 7 * esl; ++bit) {
        if (aborted(abort)) return p;
        const uint64_t cand = es ^ (1ull << bit);
        if (cand > maxVal) continue;
        uint64_t v = cand;
        for (int i = esl - 1; i >= 0; --i) { work[sizeAt + (size_t)i] = (uint8_t)(v & 0xff); v >>= 8; }
        work[sizeAt] |= (uint8_t)(0x80 >> (esl - 1));
        if (!mkvClusterChildrenClose(work.data(), len, lastOk, tracks, nullptr, nullptr)) continue;
        if ((~ieeeCrcUpdate(prefixState, work.data() + sizeAt, len - sizeAt)) != head.crc) continue;
        ++hits;
        hitBytes.assign(work.begin() + (long)sizeAt, work.begin() + (long)(sizeAt + (size_t)esl));
        hitSize = cand;
    }
    for (int i = 0; i < esl; ++i) work[sizeAt + (size_t)i] = buf[sizeAt + (size_t)i];
    if (hits != 1) return p;
    Patch pt;
    pt.offset = head.dataStart + (int64_t)sizeAt;
    pt.bytes = hitBytes;
    p.patches.push_back(pt);
    p.kind = "mkv-crc-size";
    p.detail = "簇@" + std::to_string(cpos) + " 内元素@" + std::to_string(head.dataStart + (int64_t)lastOk) + " size " +
               std::to_string(es) + "→" + std::to_string(hitSize) + "（唯一单比特候选，改后子链闭合且原存 CRC-32 相符）";
    p.damagedFrom = pt.offset; p.damagedUntil = pt.offset + esl;
    return p;
}

struct MkvEl { uint32_t id = 0; size_t pos = 0; size_t dataPos = 0; size_t size = 0; };

struct MkvElHead { uint32_t id = 0; int64_t dataPos = -1; uint64_t size = 0; bool unknown = false; };
inline bool mkvElHeadAt(const Reader& read, int64_t pos, size_t minRead, MkvElHead& e) {
    e = MkvElHead{};
    auto h = readSpan(read, pos, 16);
    if (h.size() < minRead) return false;
    const int il = ebmlVintLen(h[0]);
    if (il == 0 || il > 4 || (size_t)il >= h.size()) return false;
    for (int i = 0; i < il; ++i) e.id = (e.id << 8) | h[(size_t)i];
    const int sl = ebmlReadSize(h.data() + il, h.size() - il, e.size, e.unknown);
    if (sl == 0) return false;
    e.dataPos = pos + il + sl;
    return true;
}

inline bool mkvGroupBlockAt(const Reader& read, int64_t groupPos, int64_t groupEnd, int64_t& blockPos, size_t& blockLen) {
    int64_t c2 = groupPos;
    for (int k = 0; k < 16 && c2 + 2 < groupEnd; ++k) {
        MkvElHead g;
        if (!mkvElHeadAt(read, c2, 2, g) || g.unknown) return false;
        if (g.dataPos + (int64_t)g.size > groupEnd) return false;
        if (g.id == 0xA1) { blockPos = g.dataPos; blockLen = (size_t)g.size; return true; }
        c2 = g.dataPos + (int64_t)g.size;
    }
    return false;
}

inline bool mkvClusterMetaId(uint32_t id) { return id == 0xE7 || id == 0xBF || id == 0xEC || id == 0xA7 || id == 0xAB || id == 0xAF || id == 0x5854; }

inline bool mkvReadEl(const uint8_t* p, size_t n, size_t off, MkvEl& e) {
    if (off >= n) return false;
    const int il = ebmlVintLen(p[off]);
    if (il == 0 || il > 4 || off + (size_t)il >= n) return false;
    uint32_t id = 0;
    for (int i = 0; i < il; ++i) id = (id << 8) | p[off + (size_t)i];
    uint64_t sz = 0; bool un = false;
    const int sl = ebmlReadSize(p + off + il, n - off - (size_t)il, sz, un);
    if (sl == 0 || un) return false;
    const size_t data = off + (size_t)il + (size_t)sl;
    if (sz > n - data) return false;
    e.id = id; e.pos = off; e.dataPos = data; e.size = (size_t)sz;
    return true;
}
inline uint64_t mkvUint(const uint8_t* p, size_t n) { uint64_t v = 0; for (size_t i = 0; i < n && i < 8; ++i) v = (v << 8) | p[i]; return v; }
inline double mkvFloat(const uint8_t* p, size_t n) {
    if (n == 4) { uint32_t u = be32(p); float f; std::memcpy(&f, &u, 4); return f; }
    if (n == 8) { uint64_t u = be64(p); double d; std::memcpy(&d, &u, 8); return d; }
    return 0.0;
}

inline void ieeeSingleBitCandidates(size_t n, uint32_t delta, std::vector<std::pair<size_t, uint8_t>>& out, size_t cap = 4) {
    const auto& t = ieeeCrcTable();
    uint32_t st[8];
    for (int k = 0; k < 8; ++k) st[k] = t[1u << k];
    for (size_t i = n; i-- > 0;) {
        for (int k = 0; k < 8; ++k) {
            if (st[k] == delta) { out.push_back({i, (uint8_t)(1u << k)}); if (out.size() >= cap) return; }
        }
        for (int k = 0; k < 8; ++k) st[k] = (st[k] >> 8) ^ t[st[k] & 0xff];
    }
}

inline bool mkvKnownCodecId(const std::string& s) {
    static const char* const known[] = {
        "V_MPEG4/ISO/AVC", "V_MPEGH/ISO/HEVC", "V_AV1", "V_VP9", "V_VP8", "V_MPEG4/ISO/ASP", "V_MPEG4/ISO/SP", "V_MPEG4/ISO/AP",
        "V_MPEG2", "V_MPEG1", "V_THEORA", "V_PRORES", "V_FFV1", "V_MJPEG", "V_MS/VFW/FOURCC", "V_REAL/RV10", "V_REAL/RV20",
        "V_REAL/RV30", "V_REAL/RV40", "V_MPEGI/ISO/VVC", "V_QUICKTIME", "V_UNCOMPRESSED",
        "A_AAC", "A_AC3", "A_EAC3", "A_DTS", "A_OPUS", "A_VORBIS", "A_FLAC", "A_MPEG/L3", "A_MPEG/L2", "A_MPEG/L1",
        "A_PCM/INT/LIT", "A_PCM/INT/BIG", "A_PCM/FLOAT/IEEE", "A_TRUEHD", "A_MLP", "A_ALAC", "A_MS/ACM", "A_REAL/COOK",
        "A_REAL/SIPR", "A_REAL/ATRC", "A_REAL/14_4", "A_REAL/28_8", "A_QUICKTIME", "A_WAVPACK4", "A_TTA1",
        "S_TEXT/UTF8", "S_TEXT/ASS", "S_TEXT/SSA", "S_ASS", "S_SSA", "S_TEXT/USF", "S_TEXT/WEBVTT", "S_HDMV/PGS", "S_HDMV/TEXTST",
        "S_VOBSUB", "S_DVBSUB", "S_KATE", "S_IMAGE/BMP",
    };
    for (const char* k : known) if (s == k) return true;

    for (const char* pre : {"A_AAC/", "A_DTS/", "V_MS/VFW/", "S_TEXT/"}) if (s.rfind(pre, 0) == 0 && s.size() > std::strlen(pre)) return true;
    return false;
}

inline std::vector<MkvTrackDecl> mkvParseTracks(const uint8_t* b, size_t n) {
    std::vector<MkvTrackDecl> out;
    size_t off = 0;
    MkvEl e;
    while (mkvReadEl(b, n, off, e)) {
        if (e.id == 0xAE) {
            MkvTrackDecl t; t.entryPos = e.pos; t.entrySize = e.dataPos + e.size - e.pos;
            size_t o2 = e.dataPos; MkvEl c;
            while (o2 < e.dataPos + e.size && mkvReadEl(b, e.dataPos + e.size, o2, c)) {
                const uint8_t* d = b + c.dataPos;
                if (c.id == 0xD7) t.number = mkvUint(d, c.size);
                else if (c.id == 0x83) t.type = mkvUint(d, c.size);
                else if (c.id == 0x86) t.codecId.assign((const char*)d, c.size);
                else if (c.id == 0x23E383) t.defaultDurationNs = mkvUint(d, c.size);
                else if (c.id == 0xE1) { // Audio
                    size_t o3 = c.dataPos; MkvEl a;
                    while (o3 < c.dataPos + c.size && mkvReadEl(b, c.dataPos + c.size, o3, a)) {
                        if (a.id == 0xB5) t.samplingHz = mkvFloat(b + a.dataPos, a.size);
                        else if (a.id == 0x9F) t.channels = (int)mkvUint(b + a.dataPos, a.size);
                        o3 = a.dataPos + a.size;
                    }
                }
                o2 = c.dataPos + c.size;
            }
            out.push_back(t);
        }
        off = e.dataPos + e.size;
    }
    return out;
}

struct MkvBlockStats {
    std::map<uint64_t, int> refs;
    std::map<uint64_t, std::vector<int64_t>> ts;
    int blocks = 0;
};

inline MkvBlockStats mkvSampleBlocks(const Reader& read, int64_t fileSize, int64_t clusterPos, int maxBlocks, const AbortFn* abort) {
    MkvBlockStats s;
    int64_t pos = clusterPos;
    for (int clusters = 0; clusters < 16 && pos + 8 < fileSize && s.blocks < maxBlocks; ++clusters) {
        if (aborted(abort)) break;
        auto h = readSpan(read, pos, 16);
        if (h.size() < 8 || !(h[0] == 0x1F && h[1] == 0x43 && h[2] == 0xB6 && h[3] == 0x75)) break;
        uint64_t csz = 0; bool cun = false;
        const int csl = ebmlReadSize(h.data() + 4, h.size() - 4, csz, cun);
        if (csl == 0) break;
        const int64_t dataStart = pos + 4 + csl;
        const int64_t declaredEnd = cun ? fileSize : std::min<int64_t>(fileSize, dataStart + (int64_t)csz);
        const size_t want = (size_t)std::min<int64_t>(declaredEnd - dataStart, 4ll * 1024 * 1024);
        auto body = readSpan(read, dataStart, want);
        int64_t ctime = 0;
        size_t off = 0; MkvEl e;
        bool advanced = false;
        while (off < body.size() && s.blocks < maxBlocks && mkvReadEl(body.data(), body.size(), off, e)) {
            const uint8_t* d = body.data() + e.dataPos;
            if (e.id == 0xE7) ctime = (int64_t)mkvUint(d, e.size);
            else if (e.id == 0xA3 || e.id == 0xA0) {
                const uint8_t* blk = d; size_t bn = e.size;
                if (e.id == 0xA0) { // BlockGroup → Block(A1)
                    MkvEl g; bool found = false;
                    size_t o2 = e.dataPos;
                    while (o2 < e.dataPos + e.size && mkvReadEl(body.data(), e.dataPos + e.size, o2, g)) { if (g.id == 0xA1) { blk = body.data() + g.dataPos; bn = g.size; found = true; break; } o2 = g.dataPos + g.size; }
                    if (!found) { blk = nullptr; }
                }
                if (blk && bn >= 4) {
                    uint64_t tn = 0; bool un = false;
                    const int tl = ebmlReadSize(blk, bn, tn, un);
                    if (tl > 0 && !un && (size_t)tl + 3 <= bn) {
                        const int16_t rel = (int16_t)(((uint16_t)blk[tl] << 8) | blk[tl + 1]);
                        s.refs[tn]++;
                        auto& v = s.ts[tn];
                        if (v.size() < 128) v.push_back(ctime + rel);
                        ++s.blocks;
                    }
                }
            } else if (!mkvClusterMetaId(e.id)) {
                break;
            }
            off = e.dataPos + e.size;
            advanced = true;
        }
        if (!advanced) break;
        if (cun) pos = dataStart + (int64_t)off; else pos = declaredEnd;
    }
    return s;
}

inline int64_t mkvMedianDelta(std::vector<int64_t> v) {
    if (v.size() < 3) return -1;
    std::sort(v.begin(), v.end());
    std::vector<int64_t> d;
    for (size_t i = 1; i < v.size(); ++i) if (v[i] > v[i - 1]) d.push_back(v[i] - v[i - 1]);
    if (d.size() < 2) return -1;
    std::sort(d.begin(), d.end());
    return d[d.size() / 2];
}

struct MkvContentEncoding { int count = 0; uint64_t type = 0, scope = 1, algo = 0; bool hasSettings = false; };
inline MkvContentEncoding mkvParseContentEncoding(const uint8_t* b, size_t n, const MkvTrackDecl& t);
inline bool mkvTrackEntryChild(const uint8_t* b, size_t n, const MkvTrackDecl& t, uint32_t id, const uint8_t*& data, size_t& len);
inline int mkvTrackBlocksInflate(const Reader& read, int64_t fileSize, int64_t clusterPos, int track, int nalLen, bool hevc, int maxBlocks, const AbortFn* abort);

inline RecoveryPlan planMkvHeaderCrc(const Reader& read, int64_t fileSize, const AbortFn* abort) {
    RecoveryPlan p;
    auto head = readSpan(read, 0, 64);
    if (head.size() < 16 || !(head[0] == 0x1A && head[1] == 0x45 && head[2] == 0xDF && head[3] == 0xA3)) return p;
    uint64_t hsz = 0; bool hun = false;
    const int hsl = ebmlReadSize(head.data() + 4, head.size() - 4, hsz, hun);
    if (hsl == 0 || hun || hsz > 4096) return p;
    int64_t segPos = 4 + hsl + (int64_t)hsz;
    auto sh = readSpan(read, segPos, 16);
    if (sh.size() < 8 || !(sh[0] == 0x18 && sh[1] == 0x53 && sh[2] == 0x80 && sh[3] == 0x67)) return p;
    uint64_t ssz = 0; bool sun = false;
    const int ssl = ebmlReadSize(sh.data() + 4, sh.size() - 4, ssz, sun);
    if (ssl == 0) return p;
    const int64_t segData = segPos + 4 + ssl;

    int64_t infoPos = -1, infoData = -1, tracksPos = -1, tracksData = -1, cuesPos = -1, clusterPos = -1;
    size_t infoSize = 0, tracksSize = 0, cuesSize = 0;

    struct CuesSource { int64_t seekAt = -1; int64_t dataPos = -1; size_t size = 0; };
    std::vector<CuesSource> cuesSources;
    bool walkCuesSeen = false;
    {
        int64_t pos = segData;
        const int64_t limit = std::min(fileSize, segData + 16ll * 1024 * 1024);
        for (int hops = 0; hops < 64 && pos + 4 < limit; ++hops) {
            if (aborted(abort)) return p;
            MkvElHead el;
            if (!mkvElHeadAt(read, pos, 8, el)) break;
            const uint32_t id = el.id;
            const uint64_t sz = el.size;
            const int64_t data = el.dataPos;
            if (id == 0x1F43B675) { clusterPos = pos; break; }
            if (el.unknown) break;
            if (id == 0x1549A966 && infoPos < 0) { infoPos = pos; infoData = data; infoSize = (size_t)sz; }
            else if (id == 0x1654AE6B && tracksPos < 0) { tracksPos = pos; tracksData = data; tracksSize = (size_t)sz; }
            else if (id == 0x1C53BB6B && !walkCuesSeen) { walkCuesSeen = true; cuesSources.push_back({-1, data, (size_t)sz}); }
            else if (id == 0x114D9B74) {
                auto body = readSpan(read, data, (size_t)std::min<uint64_t>(sz, 4096));
                size_t off = 0; MkvEl e;
                while (mkvReadEl(body.data(), body.size(), off, e)) {
                    if (e.id == 0x4DBB) {
                        size_t o2 = e.dataPos; MkvEl c; bool isCues = false; int64_t sp = -1;
                        while (o2 < e.dataPos + e.size && mkvReadEl(body.data(), e.dataPos + e.size, o2, c)) {
                            if (c.id == 0x53AB && c.size == 4 && be32(body.data() + c.dataPos) == 0x1C53BB6B) isCues = true;
                            if (c.id == 0x53AC) sp = (int64_t)mkvUint(body.data() + c.dataPos, c.size);
                            o2 = c.dataPos + c.size;
                        }
                        if (isCues && sp >= 0 && !walkCuesSeen) cuesSources.push_back({segData + sp, -1, 0});
                    }
                    off = e.dataPos + e.size;
                }
            }
            pos = data + (int64_t)sz;
        }
    }
    if (tracksPos < 0 || tracksSize < 8 || tracksSize > 1024 * 1024) return p;
    auto tracksBody = readSpan(read, tracksData, tracksSize);
    if (tracksBody.size() != tracksSize) return p;
    std::vector<uint8_t> infoBody;
    if (infoPos >= 0 && infoSize >= 8 && infoSize <= 1024 * 1024) { infoBody = readSpan(read, infoData, infoSize); if (infoBody.size() != infoSize) infoBody.clear(); }
    const std::vector<MkvTrackDecl> decls = mkvParseTracks(tracksBody.data(), tracksBody.size());
    if (decls.empty()) return p;

    struct Cand { bool tracks; size_t at; uint8_t mask; };
    std::vector<Cand> cands;
    bool crcFieldOnly = false;
    for (int which = 0; which < 2; ++which) {
        const std::vector<uint8_t>& body = which == 0 ? tracksBody : infoBody;
        if (body.size() < 8) continue;
        MkvEl first;
        if (!mkvReadEl(body.data(), body.size(), 0, first) || first.id != 0xBF || first.size != 4) continue;
        const uint32_t stored = le32(body.data() + first.dataPos);
        const size_t from = first.dataPos + 4;
        const uint32_t calc = ieeeCrc32(body.data() + from, body.size() - from);
        if (stored == calc) continue;
        const uint32_t delta = stored ^ calc;
        std::vector<std::pair<size_t, uint8_t>> bits;
        ieeeSingleBitCandidates(body.size() - from, delta, bits, 4);
        int crcField = __builtin_popcount(delta) == 1 ? 1 : 0;
        if (bits.size() + (size_t)crcField != 1) { p.detail += std::string(which == 0 ? "Tracks" : "Info") + " CRC 不符但单比特候选 " + std::to_string(bits.size() + crcField) + " 个；"; continue; }
        if (crcField) { crcFieldOnly = true; continue; }
        cands.push_back({which == 0, from + bits[0].first, bits[0].second});
    }
    if (cands.size() != 1) { if (crcFieldOnly && cands.empty()) p.detail += "只有 CRC 字段自身一位坏（内容自洽），不改；"; return p; }
    const Cand c = cands[0];
    const std::vector<uint8_t>& body = c.tracks ? tracksBody : infoBody;

    MkvEl leaf; bool leafOk = false; int trackIdx = -1;
    {
        size_t off = 0; MkvEl e;
        while (mkvReadEl(body.data(), body.size(), off, e)) {
            if (c.at >= e.dataPos && c.at < e.dataPos + e.size) {
                if (c.tracks && e.id == 0xAE) {
                    for (size_t i = 0; i < decls.size(); ++i) if (decls[i].entryPos == e.pos) trackIdx = (int)i;

                    std::function<void(size_t, size_t)> descend = [&](size_t from, size_t to) {
                        size_t o2 = from; MkvEl f;
                        while (o2 < to && mkvReadEl(body.data(), to, o2, f)) {
                            if (c.at >= f.dataPos && c.at < f.dataPos + f.size) {
                                if (f.id == 0xE0 || f.id == 0xE1 || f.id == 0x6D80 || f.id == 0x6240 || f.id == 0x5034) descend(f.dataPos, f.dataPos + f.size);
                                else { leaf = f; leafOk = true; }
                                return;
                            }
                            o2 = f.dataPos + f.size;
                        }
                    };
                    descend(e.dataPos, e.dataPos + e.size);
                } else if (!c.tracks) { leaf = e; leafOk = true; }
                break;
            }
            off = e.dataPos + e.size;
        }
    }
    if (!leafOk) { p.detail += "唯一候选落在 EBML 结构字段上，不改；"; return p; }
    std::vector<uint8_t> cur(body.begin() + (long)leaf.dataPos, body.begin() + (long)(leaf.dataPos + leaf.size));
    std::vector<uint8_t> cand = cur;
    cand[c.at - leaf.dataPos] ^= c.mask;
    const uint8_t* cd = cand.data(); const uint8_t* od = cur.data();
    std::string field;
    bool accept = false;
    const int64_t base = c.tracks ? tracksData : infoData;

    uint64_t scaleNs = 1000000;
    for (size_t off = 0; off < infoBody.size();) { MkvEl e; if (!mkvReadEl(infoBody.data(), infoBody.size(), off, e)) break; if (e.id == 0x2AD7B1) scaleNs = mkvUint(infoBody.data() + e.dataPos, e.size); off = e.dataPos + e.size; }
    if (scaleNs == 0) scaleNs = 1000000;
    MkvBlockStats blocks;
    bool blocksLoaded = false;
    auto loadBlocks = [&] { if (!blocksLoaded && clusterPos >= 0) { blocks = mkvSampleBlocks(read, fileSize, clusterPos, 512, abort); blocksLoaded = true; } };
    if (c.tracks && trackIdx >= 0 && leaf.id == 0xD7) {
        field = "TrackNumber";
        const uint64_t curN = mkvUint(od, cur.size()), candN = mkvUint(cd, cand.size());
        loadBlocks();
        bool declaredElsewhere = false;
        for (size_t i = 0; i < decls.size(); ++i) if ((int)i != trackIdx && decls[i].number == candN) declaredElsewhere = true;
        const int curRefs = blocks.refs.count(curN) ? blocks.refs[curN] : 0, candRefs = blocks.refs.count(candN) ? blocks.refs[candN] : 0;
        accept = blocks.blocks > 0 && curRefs == 0 && candRefs > 0 && !declaredElsewhere;
        p.detail += "TrackNumber " + std::to_string(curN) + "→" + std::to_string(candN) + "：首簇 Block 引用 现值 " + std::to_string(curRefs) + " / 候选 " + std::to_string(candRefs) + "；";
    } else if (c.tracks && trackIdx >= 0 && leaf.id == 0x83) {
        field = "TrackType";
        const uint64_t curT = mkvUint(od, cur.size()), candT = mkvUint(cd, cand.size());
        const std::string& cid = decls[(size_t)trackIdx].codecId;
        const uint64_t want = cid.rfind("V_", 0) == 0 ? 1 : cid.rfind("A_", 0) == 0 ? 2 : cid.rfind("S_", 0) == 0 ? 17 : 0;
        accept = want != 0 && candT == want && curT != want;
        p.detail += "TrackType " + std::to_string(curT) + "→" + std::to_string(candT) + "（CodecID " + cid + "）；";
    } else if (c.tracks && trackIdx >= 0 && leaf.id == 0x86) {
        field = "CodecID";
        const std::string curS((const char*)od, cur.size()), candS((const char*)cd, cand.size());
        const uint64_t t = decls[(size_t)trackIdx].type;
        const bool prefixOk = (t == 1 && candS.rfind("V_", 0) == 0) || (t == 2 && candS.rfind("A_", 0) == 0) || (t == 17 && candS.rfind("S_", 0) == 0);
        accept = mkvKnownCodecId(candS) && !mkvKnownCodecId(curS) && prefixOk;
        p.detail += "CodecID " + curS + "→" + candS + "；";
    } else if (c.tracks && trackIdx >= 0 && leaf.id == 0x63A2) {
        field = "CodecPrivate";
        const std::string& cid = decls[(size_t)trackIdx].codecId;

        const size_t rel = c.at - leaf.dataPos;
        const MkvTrackDecl& td = decls[(size_t)trackIdx];
        if (cid == "V_MPEG4/ISO/AVC") accept = avccStrictValid(cd, (int)cand.size()) && !avccStrictValid(od, (int)cur.size());
        else if (cid == "V_MPEGH/ISO/HEVC") accept = hvccStrictValid(cd, (int)cand.size()) && !hvccStrictValid(od, (int)cur.size());

        else if (cid == "A_AAC" || cid.rfind("A_AAC/", 0) == 0) {
            accept = rel < 2 && aacAscImpossible(od, cur.size()) && aacAscLcConsistent(cd, cand.size(), td.channels, td.samplingHz);
        } else if (cid == "A_OPUS") {
            accept = (rel == 9 || rel == 18) && !opusHeadConsistent(od, cur.size(), td.channels) && opusHeadConsistent(cd, cand.size(), td.channels);
        } else if (cid == "A_VORBIS") {
            size_t tableEnd = 0;
            accept = !vorbisCodecPrivateConsistent(od, cur.size(), td.channels, td.samplingHz) &&
                     vorbisCodecPrivateConsistent(cd, cand.size(), td.channels, td.samplingHz, &tableEnd) && rel < tableEnd;
        }
        p.detail += "CodecPrivate（" + cid + "）@" + std::to_string(rel) + " 一位；";
    } else if (c.tracks && trackIdx >= 0 && (leaf.id == 0x4254 || leaf.id == 0x5032)) {

        const bool algo = leaf.id == 0x4254;
        field = algo ? "ContentCompAlgo" : "ContentEncodingScope";
        const MkvTrackDecl& td = decls[(size_t)trackIdx];
        const MkvContentEncoding ce = mkvParseContentEncoding(tracksBody.data(), tracksBody.size(), td);
        const uint64_t curV = mkvUint(od, cur.size()), candV = mkvUint(cd, cand.size());
        bool structural = ce.count == 1 && ce.type == 0 && !ce.hasSettings;
        if (algo) structural = structural && candV == 0 && curV != 0 && (ce.scope & 1);
        else structural = structural && ce.algo == 0 && (candV & 1) && !(curV & 1) && candV <= 3;
        int nalLen = 0; bool hevc = false;
        const uint8_t* cp = nullptr; size_t cpLen = 0;
        if (td.codecId == "V_MPEG4/ISO/AVC" && mkvTrackEntryChild(tracksBody.data(), tracksBody.size(), td, 0x63A2, cp, cpLen) && avccRecordValid(cp, (int)cpLen)) nalLen = (cp[4] & 3) + 1;
        else if (td.codecId == "V_MPEGH/ISO/HEVC" && mkvTrackEntryChild(tracksBody.data(), tracksBody.size(), td, 0x63A2, cp, cpLen) && hvccRecordValid(cp, (int)cpLen) && cpLen >= 23) { nalLen = (cp[21] & 3) + 1; hevc = true; }
        int inflated = 0;
        if (structural && clusterPos >= 0) inflated = mkvTrackBlocksInflate(read, fileSize, clusterPos, (int)td.number, nalLen, hevc, 8, abort);
        accept = structural && inflated >= 2;
        p.detail += field + " " + std::to_string(curV) + "→" + std::to_string(candV) + "：轨 " + std::to_string(td.number) + " 首簇块体 zlib 闭合 " + std::to_string(inflated) + " 块；";
    } else if (!c.tracks && leaf.id == 0x2AD7B1) {
        field = "TimestampScale";
        const uint64_t curS = mkvUint(od, cur.size()), candS = mkvUint(cd, cand.size());
        loadBlocks();

        double refNs = 0; uint64_t refTrack = 0;
        for (const MkvTrackDecl& t : decls) {
            if (t.type == 1 && t.defaultDurationNs > 0) { refNs = (double)t.defaultDurationNs; refTrack = t.number; break; }
        }
        if (refNs <= 0) {
            for (const MkvTrackDecl& t : decls) {
                if (t.type != 2 || t.samplingHz <= 0) continue;
                int frame = 0;
                if (t.codecId.rfind("A_AAC", 0) == 0) frame = 1024; else if (t.codecId == "A_AC3" || t.codecId == "A_EAC3") frame = 1536;
                else if (t.codecId == "A_MPEG/L3" || t.codecId == "A_MPEG/L2") frame = 1152;
                if (frame) { refNs = 1e9 * frame / t.samplingHz; refTrack = t.number; break; }
            }
        }
        const int64_t med = refTrack && blocks.ts.count(refTrack) ? mkvMedianDelta(blocks.ts[refTrack]) : -1;
        if (refNs > 0 && med > 0 && curS > 0 && candS > 0) {
            const double curNs = (double)med * (double)curS, candNs = (double)med * (double)candS;
            const bool candOk = std::fabs(candNs - refNs) <= refNs * 0.05, curOk = std::fabs(curNs - refNs) <= refNs * 0.05;
            accept = candOk && !curOk;
            p.detail += "TimestampScale " + std::to_string(curS) + "→" + std::to_string(candS) + "：块间距 " + std::to_string(med) + " 单位 vs 参考 " + std::to_string((long long)refNs) + " ns；";
        } else p.detail += "TimestampScale 候选但无独立时钟证据；";
    } else if (!c.tracks && leaf.id == 0x4489) {
        field = "Duration";
        const double curD = mkvFloat(od, cur.size()) * (double)scaleNs / 1e9, candD = mkvFloat(cd, cand.size()) * (double)scaleNs / 1e9;

        double endS = -1;
        for (const CuesSource& s : cuesSources) {
            if (s.seekAt < 0) { cuesPos = s.dataPos; cuesSize = s.size; break; }
            auto ch = readSpan(read, s.seekAt, 16);
            if (ch.size() >= 8 && be32(ch.data()) == 0x1C53BB6B) {
                uint64_t cz = 0; bool cu = false;
                const int cl = ebmlReadSize(ch.data() + 4, ch.size() - 4, cz, cu);
                if (cl > 0 && !cu) { cuesPos = s.seekAt + 4 + cl; cuesSize = (size_t)cz; break; }
            }
        }
        if (cuesPos >= 0 && cuesSize > 0 && cuesSize <= 4 * 1024 * 1024) {
            auto cb = readSpan(read, cuesPos, cuesSize);
            size_t off = 0; MkvEl e; uint64_t mx = 0; bool any = false;
            while (mkvReadEl(cb.data(), cb.size(), off, e)) {
                if (e.id == 0xBB) { size_t o2 = e.dataPos; MkvEl t; while (o2 < e.dataPos + e.size && mkvReadEl(cb.data(), e.dataPos + e.size, o2, t)) { if (t.id == 0xB3) { mx = std::max(mx, mkvUint(cb.data() + t.dataPos, t.size)); any = true; } o2 = t.dataPos + t.size; } }
                off = e.dataPos + e.size;
            }
            if (any) endS = (double)mx * (double)scaleNs / 1e9;
        }
        if (endS < 0) {
            static const uint8_t cid[4] = {0x1F, 0x43, 0xB6, 0x75};
            const int64_t from = std::max<int64_t>(clusterPos >= 0 ? clusterPos : 0, fileSize - 8ll * 1024 * 1024);
            int64_t cur2 = from, hit = -1, lastGood = -1;
            FindCursor fc;
            for (int tries = 0; tries < 4096 && findBytes(read, cur2, fileSize, cid, 4, hit, abort, &fc); ++tries) { if (mkvReadClusterTimecode(read, hit) >= 0) lastGood = hit; cur2 = hit + 1; }
            if (lastGood >= 0) endS = (double)mkvReadClusterTimecode(read, lastGood) * (double)scaleNs / 1e9;
        }
        if (endS >= 0) {
            auto inWindow = [&](double d) { return d >= endS - 1.0 && d <= endS + 600.0; };
            accept = inWindow(candD) && !inWindow(curD);
            p.detail += "Duration " + std::to_string(curD) + "s→" + std::to_string(candD) + "s（末端证据 " + std::to_string(endS) + "s）；";
        } else p.detail += "Duration 候选但无末端证据；";
    } else {
        p.detail += "唯一候选落在无独立证据的字段（ID 0x" + std::to_string(leaf.id) + "），不改；";
        return p;
    }
    if (!accept) { p.detail += "独立证据不支持，不改"; return p; }
    Patch pt; pt.offset = base + (int64_t)c.at; pt.bytes = {(uint8_t)(body[c.at] ^ c.mask)};
    p.patches.push_back(pt);
    p.kind = "mkv-header-crc-" + field;
    p.detail = std::string(c.tracks ? "Tracks" : "Info") + " 原存 CRC-32 唯一单比特候选 + 独立证据：" + p.detail;
    p.damagedFrom = pt.offset; p.damagedUntil = pt.offset + 1;
    return p;
}

struct MkvFlacLaceResult { int blocks = 0, verified = 0, unfixable = 0; int64_t scannedUntil = -1; };

inline RecoveryPlan planMkvFlacLacing(const Reader& read, int64_t fileSize, int64_t clusterPos, int64_t windowBytes, const std::vector<int>& flacTracks,
                                      int maxBlocks, const AbortFn* abort, MkvFlacLaceResult* res) {
    RecoveryPlan p;
    MkvFlacLaceResult r;
    if (clusterPos < 0 || flacTracks.empty()) return p;
    std::map<int, FlacFrameHeader> prevByTrack;
    std::set<int> prevKnown;
    const int64_t limit = std::min(fileSize, clusterPos + windowBytes);
    int64_t pos = clusterPos;
    auto isFlac = [&](int t) { for (int x : flacTracks) if (x == t) return true; return false; };

    auto checkBlock = [&](int64_t blockPos, size_t blockLen) {
        if (blockLen < 8 || blockLen > 8u * 1024 * 1024) return;
        auto hd = readSpan(read, blockPos, std::min<size_t>(blockLen, 12));
        if (hd.size() < 4) return;
        uint64_t tn = 0; bool un = false;
        const int tl = ebmlReadSize(hd.data(), hd.size(), tn, un);
        if (tl == 0 || un || tn > 1000000 || !isFlac((int)tn)) return;
        auto body = readSpan(read, blockPos, blockLen);
        if (body.size() != blockLen) return;
        ++r.blocks;
        const int t = (int)tn;
        const bool havePrev = prevKnown.count(t) > 0;
        ByteFix fx; bool verified = false; FlacFrameHeader last;
        const bool fixed = mkvFlacLacingFix(body.data(), body.size(), (size_t)tl + 2, havePrev ? &prevByTrack[t] : nullptr, fx, &verified, &last);
        if (!fixed && !verified && havePrev) {
            const bool fixed2 = mkvFlacLacingFix(body.data(), body.size(), (size_t)tl + 2, nullptr, fx, &verified, &last);
            if (fixed2) { Patch pt; pt.offset = blockPos + (int64_t)fx.at; pt.bytes = {fx.value}; p.patches.push_back(pt); prevByTrack[t] = last; prevKnown.insert(t); return; }
        }
        if (fixed) { Patch pt; pt.offset = blockPos + (int64_t)fx.at; pt.bytes = {fx.value}; p.patches.push_back(pt); prevByTrack[t] = last; prevKnown.insert(t); return; }
        if (verified) { ++r.verified; prevByTrack[t] = last; prevKnown.insert(t); return; }
        ++r.unfixable;
        prevKnown.erase(t);
    };
    for (int clusters = 0; clusters < 4096 && pos + 8 < limit && r.blocks < maxBlocks; ++clusters) {
        if (aborted(abort)) break;
        auto h = readSpan(read, pos, 16);
        if (h.size() < 8 || !(h[0] == 0x1F && h[1] == 0x43 && h[2] == 0xB6 && h[3] == 0x75)) break;
        uint64_t csz = 0; bool cun = false;
        const int csl = ebmlReadSize(h.data() + 4, h.size() - 4, csz, cun);
        if (csl == 0) break;
        int64_t cur = pos + 4 + csl;
        const int64_t cend = cun ? fileSize : std::min<int64_t>(fileSize, cur + (int64_t)csz);
        bool advanced = false;
        for (int els = 0; els < 200000 && cur + 2 < cend && r.blocks < maxBlocks; ++els) {
            if (aborted(abort)) { r.scannedUntil = cur; if (res) *res = r; return p; }
            MkvElHead el;
            const bool headOk = mkvElHeadAt(read, cur, 2, el);
            if (el.id == 0x1F43B675) break;
            if (!headOk || el.unknown) { cur = cend; break; }
            const int64_t data = el.dataPos, esz = (int64_t)el.size;
            if (data + esz > cend) { cur = cend; break; }
            if (el.id == 0xA3) checkBlock(data, (size_t)esz);
            else if (el.id == 0xA0) {
                int64_t blk = -1; size_t blen = 0;
                if (mkvGroupBlockAt(read, data, data + esz, blk, blen)) checkBlock(blk, blen);
            } else if (!mkvClusterMetaId(el.id)) { cur = cend; break; }
            cur = data + esz;
            advanced = true;
        }
        if (!advanced && cur >= cend) { pos = cend; if (cun) break; continue; }
        pos = cun ? cur : cend;
        if (!advanced) break;
    }
    r.scannedUntil = pos;
    if (res) *res = r;
    if (p.patches.empty()) return p;
    p.kind = "mkv-flac-lacing";
    p.detail = "FLAC 块的 lacing 表与帧链（CRC-8/CRC-16/编号/参数）矛盾，唯一单比特候选改回 " + std::to_string(p.patches.size()) + " 块（核对 " +
               std::to_string(r.blocks) + " 块、" + std::to_string(r.unfixable) + " 块无法裁决）";
    p.damagedFrom = p.patches.front().offset; p.damagedUntil = p.patches.back().offset + 1;
    return p;
}

inline std::vector<MkvTrackDecl> mkvReadTrackDecls(const Reader& read, int64_t fileSize, const AbortFn* abort, int64_t* firstClusterOut) {
    std::vector<MkvTrackDecl> out;
    if (firstClusterOut) *firstClusterOut = -1;
    auto head = readSpan(read, 0, 64);
    if (head.size() < 16 || !(head[0] == 0x1A && head[1] == 0x45 && head[2] == 0xDF && head[3] == 0xA3)) return out;
    uint64_t hsz = 0; bool hun = false;
    const int hsl = ebmlReadSize(head.data() + 4, head.size() - 4, hsz, hun);
    if (hsl == 0 || hun || hsz > 4096) return out;
    const int64_t segPos = 4 + hsl + (int64_t)hsz;
    auto sh = readSpan(read, segPos, 16);
    if (sh.size() < 8 || !(sh[0] == 0x18 && sh[1] == 0x53 && sh[2] == 0x80 && sh[3] == 0x67)) return out;
    uint64_t ssz = 0; bool sun = false;
    const int ssl = ebmlReadSize(sh.data() + 4, sh.size() - 4, ssz, sun);
    if (ssl == 0) return out;
    int64_t pos = segPos + 4 + ssl;
    const int64_t limit = std::min(fileSize, pos + 16ll * 1024 * 1024);
    for (int hops = 0; hops < 64 && pos + 4 < limit; ++hops) {
        if (aborted(abort)) return out;
        MkvElHead el;
        if (!mkvElHeadAt(read, pos, 8, el)) break;
        if (el.id == 0x1F43B675) { if (firstClusterOut) *firstClusterOut = pos; break; }
        if (el.unknown) break;
        if (el.id == 0x1654AE6B && out.empty() && el.size >= 8 && el.size <= 1024 * 1024) {
            auto body = readSpan(read, el.dataPos, (size_t)el.size);
            if (body.size() == el.size) out = mkvParseTracks(body.data(), body.size());
        }
        pos = el.dataPos + (int64_t)el.size;
    }
    return out;
}

inline bool mkvSkippableTrackNumbers(const std::vector<MkvTrackDecl>& decls, const std::string& streamKinds,
                                     const std::vector<bool>& streamDiscarded, std::vector<uint64_t>& out) {
    out.clear();
    if (decls.empty() || streamKinds.size() != streamDiscarded.size()) return false;
    size_t k = 0;
    for (const MkvTrackDecl& t : decls) {
        const char c0 = t.codecId.empty() ? 0 : t.codecId[0];
        const bool text = t.type == 0x11 || t.type == 0x21;
        const bool builds = (t.type == 1 && c0 == 'V') || (t.type == 2 && c0 == 'A') || (text && (c0 == 'D' || c0 == 'S'));
        if (!builds) { out.push_back(t.number); continue; }
        if (k >= streamKinds.size()) return false;
        const char kind = streamKinds[k];
        const bool kindOk = t.type == 1 ? kind == 'v' : t.type == 2 ? kind == 'a' : (kind != 'v' && kind != 'a');
        if (!kindOk) return false;
        if (streamDiscarded[k]) out.push_back(t.number);
        ++k;
    }
    return true;
}

inline bool mkvGapIsSkippedTrackData(const Reader& read, int64_t from, int64_t to, const std::vector<uint64_t>& skippable,
                                     const AbortFn* abort, int maxElements = 4096) {
    auto skippableTrack = [&](const uint8_t* p, size_t n) {
        uint64_t track = 0; bool un = false;
        const int tl = ebmlReadSize(p, n, track, un);
        if (tl == 0 || tl > 4 || un) return false;
        return std::find(skippable.begin(), skippable.end(), track) != skippable.end();
    };
    int64_t pos = from;
    for (int n = 0; n < maxElements && pos < to; ++n) {
        if (aborted(abort)) return false;
        const auto h = readSpan(read, pos, 16);
        if (h.size() < 2) return false;
        const int il = ebmlVintLen(h[0]);
        if (il == 0 || il > 4 || (size_t)il >= h.size()) return false;
        uint32_t id = 0;
        for (int i = 0; i < il; ++i) id = (id << 8) | h[(size_t)i];
        uint64_t sz = 0; bool un = false;
        const int sl = ebmlReadSize(h.data() + il, h.size() - (size_t)il, sz, un);
        if (sl == 0) return false;
        const int64_t data = pos + il + sl;
        if (data == to) return id == 0xA3;
        if (id == 0x1F43B675) { pos = data; continue; }
        if (un || sz > (uint64_t)INT64_MAX - (uint64_t)data) return false;
        const int64_t end = data + (int64_t)sz;
        switch (id) {
        case 0xE7: case 0xA7: case 0xAB: case 0xEC: case 0xBF: case 0x5854:
        case 0x1C53BB6B: case 0x1254C367: case 0x1043A770: case 0x1941A469:     // Cues / Tags / Chapters / Attachments
        case 0x114D9B74: case 0x1549A966: case 0x1654AE6B:                      // SeekHead / Info / Tracks
            if (end > to) return false;
            pos = end;
            continue;
        case 0xA3: {
            if (end > to || (size_t)(il + sl) >= h.size()) return false;
            if (!skippableTrack(h.data() + il + sl, h.size() - (size_t)(il + sl))) return false;
            pos = end;
            continue;
        }
        case 0xA0: {
            const auto g = readSpan(read, data, (size_t)std::min<uint64_t>(sz, 256));
            size_t off = 0;
            bool found = false;
            while (off < g.size() && data + (int64_t)off < end) {
                const int cil = ebmlVintLen(g[off]);
                if (cil == 0 || cil > 4 || off + (size_t)cil >= g.size()) return false;
                uint32_t cid = 0;
                for (int i = 0; i < cil; ++i) cid = (cid << 8) | g[off + (size_t)i];
                const int64_t childPos = data + (int64_t)off;
                if (cid == 0xA1) {
                    uint64_t csz = 0; bool cun = false;
                    const int csl = ebmlReadSize(g.data() + off + cil, g.size() - off - (size_t)cil, csz, cun);
                    if (csl == 0 || cun) return false;
                    if (childPos + cil + csl == to) return true;
                    if (off + (size_t)(cil + csl) >= g.size()) return false;
                    if (!skippableTrack(g.data() + off + cil + csl, g.size() - off - (size_t)(cil + csl))) return false;
                    found = true;
                    break;
                }
                uint64_t csz = 0; bool cun = false;
                const int csl = ebmlReadSize(g.data() + off + cil, g.size() - off - (size_t)cil, csz, cun);
                if (csl == 0 || cun) return false;
                off += (size_t)(cil + csl) + (size_t)csz;
            }
            if (!found || end > to) return false;
            pos = end;
            continue;
        }
        default:
            return false;
        }
    }
    return false;
}

inline int64_t rawAudioSyncAt(const Reader& read, int64_t fileSize, int64_t from, bool adts) {
    if (from < 0 || from >= fileSize) return -1;
    auto buf = readSpan(read, from, (size_t)std::min<int64_t>(fileSize - from, 64 * 1024 + 8192));
    for (size_t i = 0; i + 16 <= buf.size() && i < 64 * 1024; ++i) {
        if (adts) {
            AdtsHeader h, nx;
            if (!adtsParseHeader(buf.data() + i, buf.size() - i, h) || i + h.frameLength + 7 > buf.size()) continue;
            if (adtsParseHeader(buf.data() + i + h.frameLength, buf.size() - i - h.frameLength, nx) && nx.sfIndex == h.sfIndex && nx.channels == h.channels) return from + (int64_t)i;
        } else {
            Ac3Header h;
            if (buf[i] != 0x0B || buf[i + 1] != 0x77 || !ac3ParseHeader(buf.data() + i, buf.size() - i, h) || i + h.frameSize + 2 > buf.size()) continue;
            if (buf[i + h.frameSize] == 0x0B && buf[i + h.frameSize + 1] == 0x77 && ac3FrameCrcOk(buf.data() + i, buf.size() - i, h)) return from + (int64_t)i;
        }
    }
    return -1;
}

inline bool zlibInflateClosed(const uint8_t* in, size_t n, std::vector<uint8_t>& out, size_t cap) {
    out.clear();
    if (!in || n < 2) return false;
    z_stream zs;
    std::memset(&zs, 0, sizeof(zs));
    if (inflateInit(&zs) != Z_OK) return false;
    zs.next_in = const_cast<Bytef*>(in);
    zs.avail_in = (uInt)n;
    std::vector<uint8_t> chunk(65536);
    int ret;
    do {
        zs.next_out = chunk.data();
        zs.avail_out = (uInt)chunk.size();
        ret = inflate(&zs, Z_NO_FLUSH);
        if (ret != Z_OK && ret != Z_STREAM_END) { inflateEnd(&zs); return false; }
        out.insert(out.end(), chunk.begin(), chunk.begin() + (long)(chunk.size() - zs.avail_out));
        if (out.size() > cap) { inflateEnd(&zs); return false; }
        if (ret == Z_OK && zs.avail_out != 0 && zs.avail_in == 0) { inflateEnd(&zs); return false; }
    } while (ret != Z_STREAM_END);
    const bool ok = zs.avail_in == 0;
    inflateEnd(&zs);
    return ok;
}

inline MkvContentEncoding mkvParseContentEncoding(const uint8_t* b, size_t n, const MkvTrackDecl& t) {
    MkvContentEncoding ce;
    if (t.entryPos + t.entrySize > n) return ce;
    MkvEl e;
    if (!mkvReadEl(b, n, t.entryPos, e) || e.id != 0xAE) return ce;
    size_t o = e.dataPos; MkvEl c;
    while (o < e.dataPos + e.size && mkvReadEl(b, e.dataPos + e.size, o, c)) {
        if (c.id == 0x6D80) {
            size_t o2 = c.dataPos; MkvEl enc;
            while (o2 < c.dataPos + c.size && mkvReadEl(b, c.dataPos + c.size, o2, enc)) {
                if (enc.id == 0x6240) {
                    ++ce.count;
                    size_t o3 = enc.dataPos; MkvEl f;
                    while (o3 < enc.dataPos + enc.size && mkvReadEl(b, enc.dataPos + enc.size, o3, f)) {
                        if (f.id == 0x5032) ce.scope = mkvUint(b + f.dataPos, f.size);
                        else if (f.id == 0x5033) ce.type = mkvUint(b + f.dataPos, f.size);
                        else if (f.id == 0x5034) {
                            size_t o4 = f.dataPos; MkvEl g;
                            while (o4 < f.dataPos + f.size && mkvReadEl(b, f.dataPos + f.size, o4, g)) {
                                if (g.id == 0x4254) ce.algo = mkvUint(b + g.dataPos, g.size);
                                else if (g.id == 0x4255) ce.hasSettings = true;
                                o4 = g.dataPos + g.size;
                            }
                        }
                        o3 = f.dataPos + f.size;
                    }
                }
                o2 = enc.dataPos + enc.size;
            }
        }
        o = c.dataPos + c.size;
    }
    return ce;
}

inline bool mkvTrackEntryChild(const uint8_t* b, size_t n, const MkvTrackDecl& t, uint32_t id, const uint8_t*& data, size_t& len) {
    MkvEl e;
    if (t.entryPos + t.entrySize > n || !mkvReadEl(b, n, t.entryPos, e) || e.id != 0xAE) return false;
    size_t o = e.dataPos; MkvEl c;
    while (o < e.dataPos + e.size && mkvReadEl(b, e.dataPos + e.size, o, c)) {
        if (c.id == id) { data = b + c.dataPos; len = c.size; return true; }
        o = c.dataPos + c.size;
    }
    return false;
}

inline int mkvTrackBlocksInflate(const Reader& read, int64_t fileSize, int64_t clusterPos, int track, int nalLen, bool hevc, int maxBlocks, const AbortFn* abort) {
    int checked = 0;
    int64_t pos = clusterPos;
    for (int clusters = 0; clusters < 16 && pos + 8 < fileSize && checked < maxBlocks; ++clusters) {
        if (aborted(abort)) return -1;
        auto h = readSpan(read, pos, 16);
        if (h.size() < 8 || !(h[0] == 0x1F && h[1] == 0x43 && h[2] == 0xB6 && h[3] == 0x75)) break;
        uint64_t csz = 0; bool cun = false;
        const int csl = ebmlReadSize(h.data() + 4, h.size() - 4, csz, cun);
        if (csl == 0) break;
        int64_t cur = pos + 4 + csl;
        const int64_t cend = cun ? fileSize : std::min<int64_t>(fileSize, cur + (int64_t)csz);
        bool advanced = false;
        for (int els = 0; els < 100000 && cur + 2 < cend && checked < maxBlocks; ++els) {
            MkvElHead el;
            const bool headOk = mkvElHeadAt(read, cur, 2, el);
            if (el.id == 0x1F43B675) break;
            if (!headOk || el.unknown) { cur = cend; break; }
            const int64_t data = el.dataPos, esz = (int64_t)el.size;
            if (data + esz > cend) { cur = cend; break; }
            int64_t blk = -1; size_t blen = 0;
            if (el.id == 0xA3) { blk = data; blen = (size_t)esz; }
            else if (el.id == 0xA0) mkvGroupBlockAt(read, data, data + esz, blk, blen);
            else if (!mkvClusterMetaId(el.id)) { cur = cend; break; }
            if (blk >= 0 && blen >= 6 && blen <= 16u * 1024 * 1024) {
                auto hd = readSpan(read, blk, std::min<size_t>(blen, 8));
                uint64_t tn = 0; bool un = false;
                const int tl = hd.size() >= 4 ? ebmlReadSize(hd.data(), hd.size(), tn, un) : 0;
                if (tl > 0 && !un && (int)tn == track && (size_t)tl + 3 <= hd.size() && ((hd[(size_t)tl + 2] >> 1) & 3) == 0) {
                    auto body = readSpan(read, blk + tl + 3, blen - (size_t)tl - 3);
                    std::vector<uint8_t> out;
                    if (body.size() != blen - (size_t)tl - 3 || !zlibInflateClosed(body.data(), body.size(), out, std::max<size_t>(body.size() * 64, 1u << 20))) return -1;
                    if (nalLen > 0) { bool vcl = false; if (!nalChainIntact(out.data(), out.size(), nalLen, hevc, &vcl)) return -1; }
                    ++checked;
                }
            }
            cur = data + esz;
            advanced = true;
        }
        pos = cun ? cur : cend;
        if (!advanced) break;
    }
    return checked;
}

} // namespace spresil
