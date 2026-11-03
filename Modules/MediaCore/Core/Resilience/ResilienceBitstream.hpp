// OpenDuckFrame - resilient playback basics: bitstream structure checks, MJPEG/VP9 in-packet structure, shared bit helpers
//
// Split out of the umbrella header by section; function bodies, constants and inline
// attributes are unchanged. Callers keep including the umbrella; this file only guarantees
// that it compiles on its own.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <functional>
#include <new>
#include <string>
#include <utility>
#include <vector>

namespace spresil {

inline uint32_t be16(const uint8_t* p) { return ((uint32_t)p[0] << 8) | p[1]; }
inline uint32_t be24(const uint8_t* p) { return ((uint32_t)p[0] << 16) | ((uint32_t)p[1] << 8) | p[2]; }
inline uint32_t be32(const uint8_t* p) { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]; }
inline uint64_t be64(const uint8_t* p) { return ((uint64_t)be32(p) << 32) | be32(p + 4); }
inline uint32_t le32(const uint8_t* p) { return ((uint32_t)p[3] << 24) | ((uint32_t)p[2] << 16) | ((uint32_t)p[1] << 8) | p[0]; }
inline uint64_t le64(const uint8_t* p) { return ((uint64_t)le32(p + 4) << 32) | le32(p); }

enum class Bitstream : uint8_t {
    Other = 0,
    LengthPrefixed,
    StartCode,
    Av1Obu,
};

enum class PacketStructure : uint8_t {
    Unknown = 0,
    Intact,
    AllZero,
    Broken,
};

enum class StartCodeCodec : uint8_t { Unknown = 0, Mpeg12, Mpeg4, H264, Hevc };

struct BitstreamLayout {
    Bitstream kind = Bitstream::Other;
    int nalLengthSize = 4;
    bool hevc = false;
    StartCodeCodec sc = StartCodeCodec::Unknown;
};

inline bool startsWithStartCode(const uint8_t* d, size_t n);
namespace detail {

struct H264BitReader {
    std::vector<uint8_t> b;
    size_t pos = 0; // bit
    bool bad = false;
    explicit H264BitReader(const uint8_t* d, size_t n, size_t cap = 64) {
        b.reserve(std::min(n, cap));
        size_t zeros = 0;
        for (size_t i = 0; i < n && b.size() < cap; ++i) {
            if (zeros >= 2 && d[i] == 3) { zeros = 0; continue; }
            b.push_back(d[i]);
            zeros = d[i] == 0 ? zeros + 1 : 0;
        }
    }
    uint32_t bits(int k) {
        uint32_t v = 0;
        for (int i = 0; i < k; ++i) {
            const size_t byte = pos >> 3;
            if (byte >= b.size()) { bad = true; return 0; }
            v = (v << 1) | ((b[byte] >> (7 - (pos & 7))) & 1);
            ++pos;
        }
        return v;
    }
    uint32_t ue() {
        int lead = 0;
        while (!bad && bits(1) == 0) { if (++lead > 31) { bad = true; return 0; } }
        if (bad) return 0;
        return ((1u << lead) - 1) + bits(lead);
    }
    void skip(size_t k) { pos += k; if (pos > b.size() * 8) bad = true; }
    int32_t se() { const uint32_t k = ue(); return (k & 1) ? (int32_t)((k + 1) / 2) : -(int32_t)(k / 2); }
};

inline bool firstSliceHeaderPlausible(const uint8_t* n, size_t len, bool hevc) {
    if (hevc) {
        if (len < 3) return false;
        const int type = (n[0] >> 1) & 0x3f;
        H264BitReader br(n + 2, len - 2);
        if (br.bits(1) != 1) return false;
        if (type >= 16 && type <= 23) br.bits(1);
        const uint32_t pps = br.ue();
        return !br.bad && pps <= 63;
    }
    if (len < 2) return false;
    H264BitReader br(n + 1, len - 1);
    const uint32_t firstMb = br.ue(), sliceType = br.ue(), pps = br.ue();
    return !br.bad && firstMb == 0 && sliceType <= 9 && pps <= 255;
}
} // namespace detail

inline BitstreamLayout classifyLayout(bool isH264, bool isHevc, bool isAv1, bool isMpegStartCodeCodec,
                                      const uint8_t* extradata, int extradataSize, bool isMpeg4Part2 = false) {
    BitstreamLayout l;
    if (isAv1) { l.kind = Bitstream::Av1Obu; return l; }
    if (isH264 || isHevc) {
        const bool configRecord = extradata && extradataSize >= 7 && extradata[0] == 1;
        l.hevc = isHevc;
        l.sc = isHevc ? StartCodeCodec::Hevc : StartCodeCodec::H264;
        if (configRecord) {
            l.kind = Bitstream::LengthPrefixed;
            if (isH264) l.nalLengthSize = (extradata[4] & 3) + 1;
            else if (extradataSize >= 23) l.nalLengthSize = (extradata[21] & 3) + 1;
            return l;
        }
        if (extradata && extradataSize > 0 && !startsWithStartCode(extradata, (size_t)extradataSize)) { l.kind = Bitstream::Other; return l; }
        l.kind = Bitstream::StartCode;
        return l;
    }
    if (isMpegStartCodeCodec) { l.kind = Bitstream::StartCode; l.sc = isMpeg4Part2 ? StartCodeCodec::Mpeg4 : StartCodeCodec::Mpeg12; return l; }
    return l;
}

inline bool allZero(const uint8_t* d, size_t n) {
    if (!d || n == 0) return false;
    size_t i = 0;
    for (; i + 8 <= n; i += 8) {
        uint64_t w;
        std::memcpy(&w, d + i, 8);
        if (w != 0) return false;
    }
    for (; i < n; ++i) if (d[i] != 0) return false;
    return true;
}

inline bool startsWithStartCode(const uint8_t* d, size_t n) {
    size_t z = 0;
    while (z < n && z < 4 && d[z] == 0) ++z;
    return z >= 2 && z < n && d[z] == 1;
}

struct JpegLengthFix { size_t at = 0; uint16_t len = 0; };

inline bool jpegRepairSegmentLengths(const uint8_t* d, size_t n, std::vector<JpegLengthFix>& fixes) {
    fixes.clear();
    if (!d || n < 4 || d[0] != 0xFF || d[1] != 0xD8) return false;
    auto markerAt = [&](size_t p) -> int {
        if (p + 1 >= n || d[p] != 0xFF || d[p + 1] == 0x00 || d[p + 1] == 0xFF) return -1;
        return d[p + 1];
    };
    size_t pos = 2;
    int nf = 0;
    uint8_t compIds[4] = {0, 0, 0, 0};
    bool haveSof = false, qtSeen[4] = {false, false, false, false};
    bool dcSeen[4] = {false, false, false, false}, acSeen[4] = {false, false, false, false};
    for (int seg = 0; seg < 64; ++seg) {
        while (pos + 1 < n && d[pos] == 0xFF && d[pos + 1] == 0xFF) ++pos; // fill bytes
        const int m = markerAt(pos);
        if (m < 0) return false;
        if (m == 0xD9) return false;
        if ((m >= 0xD0 && m <= 0xD7) || m == 0x01) { pos += 2; continue; }
        if (pos + 4 > n) return false;
        const size_t lenAt = pos + 2;
        const uint16_t declared = (uint16_t)((d[lenAt] << 8) | d[lenAt + 1]);
        size_t derived = 0;
        const size_t body = lenAt + 2;
        if (m == 0xDB) { // DQT
            size_t q = body;
            int tables = 0;
            while (tables < 4) {
                if (q >= n) return false;
                const int pq = d[q] >> 4, tq = d[q] & 15;
                if (pq > 1 || tq > 3) return false;
                const size_t tl = 1 + 64 * (size_t)(pq + 1);
                if (q + tl > n) return false;
                for (size_t i = 0; i < 64; ++i) {
                    const size_t at = q + 1 + i * (size_t)(pq + 1);
                    const unsigned v = pq ? ((unsigned)d[at] << 8) | d[at + 1] : d[at];
                    if (v == 0) return false;
                }
                qtSeen[tq] = true;
                q += tl; ++tables;
                if (markerAt(q) >= 0) break;
            }
            if (markerAt(q) < 0) return false;
            derived = q - lenAt;
        } else if (m == 0xC4) { // DHT
            size_t q = body;
            int tables = 0;
            while (tables < 8) {
                if (q + 17 > n) return false;
                const int tc = d[q] >> 4, th = d[q] & 15;
                if (tc > 1 || th > 3) return false;
                size_t total = 0; uint64_t kraft = 0;
                for (int i = 0; i < 16; ++i) { total += d[q + 1 + (size_t)i]; kraft += (uint64_t)d[q + 1 + (size_t)i] << (15 - i); }
                if (total == 0 || total > 256 || kraft > 65536) return false;
                if (q + 17 + total > n) return false;
                (tc ? acSeen : dcSeen)[th] = true;
                q += 17 + total; ++tables;
                if (markerAt(q) >= 0) break;
            }
            if (markerAt(q) < 0) return false;
            derived = q - lenAt;
        } else if (m == 0xC0 || m == 0xC1) { // SOF0/SOF1
            if (haveSof || body + 6 > n) return false;
            const int p = d[body];
            const unsigned y = ((unsigned)d[body + 1] << 8) | d[body + 2], x = ((unsigned)d[body + 3] << 8) | d[body + 4];
            nf = d[body + 5];
            if ((p != 8 && p != 12) || x == 0 || nf < 1 || nf > 4) return false;
            (void)y;
            if (body + 6 + 3 * (size_t)nf > n) return false;
            for (int c = 0; c < nf; ++c) {
                const uint8_t* comp = d + body + 6 + 3 * (size_t)c;
                const int h = comp[1] >> 4, v = comp[1] & 15;
                if (h < 1 || h > 4 || v < 1 || v > 4 || comp[2] > 3) return false;
                for (int k = 0; k < c; ++k) if (compIds[k] == comp[0]) return false;
                compIds[c] = comp[0];
            }
            haveSof = true;
            derived = 8 + 3 * (size_t)nf;
        } else if (m == 0xC2 || m == 0xC3 || (m >= 0xC5 && m <= 0xC7) || (m >= 0xC9 && m <= 0xCB) || (m >= 0xCD && m <= 0xCF)) {
            return false;
        } else if (m == 0xDA) { // SOS
            if (!haveSof || body + 1 > n) return false;
            const int ns = d[body];
            if (ns < 1 || ns > nf || body + 1 + 2 * (size_t)ns + 3 > n) return false;
            for (int c = 0; c < ns; ++c) {
                const uint8_t* sc = d + body + 1 + 2 * (size_t)c;
                bool known = false;
                for (int k = 0; k < nf; ++k) if (compIds[k] == sc[0]) known = true;
                if (!known) return false;
                const int td = sc[1] >> 4, ta = sc[1] & 15;
                if (td > 3 || ta > 3) return false;

                const bool anyDht = dcSeen[0] || dcSeen[1] || dcSeen[2] || dcSeen[3] || acSeen[0] || acSeen[1] || acSeen[2] || acSeen[3];
                if (anyDht && (!dcSeen[td] || !acSeen[ta])) return false;
            }
            const uint8_t* sp = d + body + 1 + 2 * (size_t)ns;
            if (sp[0] != 0 || sp[1] != 63 || sp[2] != 0) return false; // baseline：Ss=0 Se=63 Ah=Al=0
            derived = 6 + 2 * (size_t)ns;
            const size_t entropy = lenAt + derived;
            if (declared != derived) fixes.push_back({lenAt, (uint16_t)derived});

            if (fixes.empty()) return false;

            for (size_t q = entropy; q + 1 < n; ++q) {
                if (d[q] != 0xFF) continue;
                const uint8_t nx = d[q + 1];
                if (nx == 0x00 || (nx >= 0xD0 && nx <= 0xD7) || nx == 0xFF) continue;
                if (nx == 0xD9) return true;
                return false;
            }
            return false;
        } else if (m == 0xDD) { // DRI
            derived = 4;
        } else {

            if (declared < 2 || lenAt + declared > n || markerAt(lenAt + declared) < 0) return false;
            pos = lenAt + declared;
            continue;
        }
        if (derived < 2 || lenAt + derived > n || markerAt(lenAt + derived) < 0) return false;
        if (declared != derived) {

            if (declared >= 2 && lenAt + declared <= n && markerAt(lenAt + declared) >= 0) return false;
            fixes.push_back({lenAt, (uint16_t)derived});
        }
        pos = lenAt + derived;
    }
    return false;
}

struct Vp9SuperframeFix { size_t idxLen = 0; uint8_t marker = 0; bool fixStart = false; bool fixEnd = false; };

inline int vp9HeaderPrefixProfile(const uint8_t* d, size_t n) {
    size_t pos = 0;
    bool bad = false;
    auto get = [&](int k) -> uint32_t {
        uint32_t v = 0;
        while (k-- > 0) {
            if (pos >= n * 8) { bad = true; return 0; }
            v = (v << 1) | ((d[pos >> 3] >> (7 - (pos & 7))) & 1u);
            ++pos;
        }
        return v;
    };
    if (!d || n == 0 || get(2) != 2) return -1;

    const uint32_t profileLow = get(1);
    const uint32_t profileHigh = get(1);
    const uint32_t profile = profileLow | (profileHigh << 1);
    if (profile == 3 && get(1) != 0) return -1;
    if (get(1)) { get(3); return bad ? -1 : (int)profile; } // show_existing_frame
    const uint32_t frameType = get(1), showFrame = get(1), errorRes = get(1);
    bool sync = frameType == 0;
    if (!sync) {
        const uint32_t intraOnly = showFrame ? 0 : get(1);
        if (!errorRes) get(2);                           // reset_frame_context
        sync = intraOnly != 0;
    }
    if (sync && get(24) != 0x498342u) return -1;
    return bad ? -1 : (int)profile;
}

inline bool vp9SuperframeIndexCandidate(const uint8_t* d, size_t n, Vp9SuperframeFix& out) {
    if (!d || n < 4) return false;
    auto layoutOk = [&](uint8_t m, size_t& idxLenOut) -> bool {
        const int frames = (m & 7) + 1, szBytes = ((m >> 3) & 3) + 1;
        const size_t idxLen = 2 + (size_t)frames * (size_t)szBytes;
        if (idxLen + 1 > n) return false;
        const size_t start = n - idxLen;
        size_t sum = 0, off = 0;
        for (int f = 0; f < frames; ++f) {
            size_t sz = 0;
            for (int b = 0; b < szBytes; ++b) sz |= (size_t)d[start + 1 + (size_t)f * (size_t)szBytes + (size_t)b] << (8 * b);
            if (sz == 0 || sz > start - sum) return false;
            if ((d[off] & 0xC0) != 0x80) return false; // frame_marker
            sum += sz; off += sz;
        }
        if (sum != start) return false;
        idxLenOut = idxLen;
        return true;
    };
    const uint8_t last = d[n - 1];
    const uint8_t top = (uint8_t)(last & 0xE0);
    if (top == 0xC0) {
        size_t il = 0;
        if (layoutOk(last, il) && d[n - il] == last) return false;
    } else if (top != 0x40 && top != 0x80 && top != 0xE0) {
        return false;
    }
    int hits = 0;
    Vp9SuperframeFix hit;
    for (int m = 0; m < 32; ++m) {
        const uint8_t marker = (uint8_t)(0xC0 | m);
        const int frames = (m & 7) + 1, szBytes = ((m >> 3) & 3) + 1;
        const size_t idxLen = 2 + (size_t)frames * (size_t)szBytes;
        if (idxLen + 1 > n) continue;
        const bool endOk = d[n - 1] == marker, startOk = d[n - idxLen] == marker;
        if (!endOk && !startOk) continue;
        size_t il = 0;
        if (!layoutOk(marker, il)) continue;
        ++hits;
        hit.idxLen = idxLen; hit.marker = marker; hit.fixStart = !startOk; hit.fixEnd = !endOk;
    }
    if (hits != 1 || (!hit.fixStart && !hit.fixEnd)) return false;

    const uint8_t damaged = hit.fixEnd ? d[n - 1] : d[n - hit.idxLen];
    if (__builtin_popcount((unsigned)(uint8_t)(damaged ^ hit.marker)) != 1) return false;
    const int frames = (hit.marker & 7) + 1, szBytes = ((hit.marker >> 3) & 3) + 1;
    if (frames < 2) return false;
    const size_t start = n - hit.idxLen;
    size_t off = 0;
    int profile = -1;
    for (int f = 0; f < frames; ++f) {
        size_t sz = 0;
        for (int b = 0; b < szBytes; ++b) sz |= (size_t)d[start + 1 + (size_t)f * (size_t)szBytes + (size_t)b] << (8 * b);
        const int p = vp9HeaderPrefixProfile(d + off, sz);
        if (p < 0 || (profile >= 0 && p != profile)) return false;
        profile = p;
        off += sz;
    }
    out = hit;
    return true;
}

struct PacketInspection {
    PacketStructure structure = PacketStructure::Unknown;
    size_t safePrefix = 0;
    int units = 0;
    bool badUnitHeader = false;
    bool tailBroken = false;
    bool hasVcl = false;

    size_t resyncFrom = 0;

    bool resyncLossless = false;

    size_t prefixFixAt = (size_t)-1;
    uint8_t prefixFixByte = 0;
};

inline size_t findNalResync(const uint8_t* d, size_t n, size_t from, int nalLen, bool hevc, bool allowFirstSlice = false,
                            bool* startsAtFirstSlice = nullptr) {
    size_t hit = 0;
    bool hitFirstSlice = false;
    std::vector<size_t> hitBounds;
    const size_t limit = std::min(n, from + 256 * 1024);
    const int minUnits = (allowFirstSlice && nalLen == 4) ? 1 : 2;
    if (startsAtFirstSlice) *startsAtFirstSlice = false;
    for (size_t o = from; o + (size_t)nalLen + 2 <= limit; ++o) {
        size_t off = o;
        int units = 0;
        bool vcl = false, bad = false, firstVclIsFirstSlice = false;
        std::vector<size_t> bounds;
        while (off < n) {
            if (n - off < (size_t)nalLen + 2) { bad = true; break; }
            uint32_t len = 0;
            for (int i = 0; i < nalLen; ++i) len = (len << 8) | d[off + (size_t)i];

            if (len < (uint32_t)(hevc ? 3 : 2) || len > n - off - (size_t)nalLen) { bad = true; break; }
            const uint8_t* h = d + off + (size_t)nalLen;
            if (h[0] & 0x80) { bad = true; break; }
            const int type = hevc ? (h[0] >> 1) & 0x3f : (h[0] & 0x1f);
            if (hevc ? (type > 40 || (h[1] & 0x07) == 0) : (type == 0 || type > 23)) { bad = true; break; }
            const bool isVcl = hevc ? type <= 31 : (type >= 1 && type <= 5);
            if (isVcl) {
                const uint8_t first = h[hevc ? 2 : 1];
                if (first & 0x80) {

                    if (!allowFirstSlice || !detail::firstSliceHeaderPlausible(h, (size_t)len, hevc)) { bad = true; break; }
                    if (!vcl) firstVclIsFirstSlice = true;
                }
                vcl = true;
            }
            bounds.push_back(off);
            off += (size_t)nalLen + len;
            ++units;
        }
        if (bad || off != n || units < minUnits || !vcl) continue;
        if (hit == 0) { hit = o; hitBounds = bounds; hitFirstSlice = firstVclIsFirstSlice; continue; }
        bool nested = false;
        for (size_t b : hitBounds) if (b == o) nested = true;
        if (!nested) return 0;
    }
    if (startsAtFirstSlice) *startsAtFirstSlice = hitFirstSlice;
    return hit;
}

inline bool nalChainIntact(const uint8_t* d, size_t n, int nalLen, bool hevc, bool* hasVcl) {
    size_t off = 0;
    int units = 0;
    bool vcl = false;
    while (off < n) {
        if (n - off < (size_t)nalLen + 1) return false;
        uint32_t len = 0;
        for (int i = 0; i < nalLen; ++i) len = (len << 8) | d[off + (size_t)i];
        if (len == 0 || len > n - off - (size_t)nalLen) return false;
        const uint8_t h = d[off + (size_t)nalLen];
        if (h & 0x80) return false;
        const int type = hevc ? (h >> 1) & 0x3f : (h & 0x1f);
        if (hevc ? type > 40 : (type == 0 || type > 23)) return false;
        if (hevc ? type <= 31 : (type >= 1 && type <= 5)) vcl = true;
        off += (size_t)nalLen + len;
        ++units;
    }
    if (hasVcl) *hasVcl = vcl;
    return units > 0 && off == n;
}

inline PacketInspection inspectLengthPrefixed(const uint8_t* d, size_t n, int nalLen, bool hevc) {
    PacketInspection r;
    if (nalLen < 1 || nalLen > 4) return r;
    size_t off = 0;
    while (off < n) {
        if (n - off < (size_t)nalLen + 1) { r.tailBroken = true; break; }
        uint32_t len = 0;
        for (int i = 0; i < nalLen; ++i) len = (len << 8) | d[off + (size_t)i];
        if (len == 0 || len > n - off - (size_t)nalLen) { r.tailBroken = true; break; }
        const uint8_t h = d[off + (size_t)nalLen];
        if (h & 0x80) {
            r.badUnitHeader = true;
        } else {
            const int type = hevc ? (h >> 1) & 0x3f : (h & 0x1f);
            if (hevc ? type <= 31 : (type >= 1 && type <= 5)) r.hasVcl = true;
        }
        off += (size_t)nalLen + len;
        r.units++;
        r.safePrefix = off;
    }
    if (r.tailBroken && off + (size_t)nalLen + 1 < n) {

        const uint8_t bh = d[off + (size_t)nalLen];
        bool metadataUnit = false;
        if (!(bh & 0x80)) {
            const int bt = hevc ? (bh >> 1) & 0x3f : (bh & 0x1f);
            metadataUnit = hevc ? (bt >= 32 && bt <= 40) : (bt >= 6 && bt <= 15);
        }
        bool firstSlice = false;
        r.resyncFrom = findNalResync(d, n, off + (size_t)nalLen + 1, nalLen, hevc, metadataUnit, &firstSlice);
        if (r.resyncFrom > 0 && r.resyncFrom < r.safePrefix) r.resyncFrom = 0;
        r.resyncLossless = r.resyncFrom > 0 && metadataUnit && firstSlice;
    }
    if (r.units == 0 && r.resyncFrom == 0) { r.structure = PacketStructure::Broken; r.safePrefix = 0; return r; }
    r.structure = (r.tailBroken || r.badUnitHeader) ? PacketStructure::Broken : PacketStructure::Intact;
    return r;
}

inline bool readLeb128(const uint8_t* d, size_t n, size_t& off, uint64_t& out) {
    out = 0;
    for (int i = 0; i < 8; ++i) {
        if (off >= n) return false;
        const uint8_t b = d[off++];
        out |= (uint64_t)(b & 0x7f) << (7 * i);
        if (!(b & 0x80)) return true;
    }
    return false;
}

inline PacketInspection inspectAv1(const uint8_t* d, size_t n) {
    PacketInspection r;
    size_t off = 0;
    while (off < n) {
        const size_t unitStart = off;
        const uint8_t h = d[off++];
        if (h & 0x80) { r.tailBroken = true; off = unitStart; break; }
        const bool reservedBit = (h & 0x01) != 0;
        const int type = (h >> 3) & 0xF;
        const bool ext = (h >> 2) & 1;
        const bool hasSize = (h >> 1) & 1;
        const bool reserved = type == 0 || (type >= 9 && type <= 14);
        if (ext) { if (off >= n) { r.tailBroken = true; off = unitStart; break; } ++off; }
        if (!hasSize) {
            if (reserved || reservedBit) { r.tailBroken = true; off = unitStart; break; }
            off = n;
        } else {
            uint64_t size = 0;
            if (!readLeb128(d, n, off, size) || size > n - off) { r.tailBroken = true; off = unitStart; break; }
            off += (size_t)size;
        }
        if (reservedBit) r.badUnitHeader = true;
        if (type == 3 || type == 4 || type == 6) r.hasVcl = true; // FRAME_HEADER / TILE_GROUP / FRAME
        r.units++;
        r.safePrefix = off;
    }
    if (r.units == 0) { r.structure = PacketStructure::Broken; r.safePrefix = 0; return r; }
    r.structure = (r.tailBroken || r.badUnitHeader) ? PacketStructure::Broken : PacketStructure::Intact;
    return r;
}

struct Av1ObuSpan { size_t start = 0, len = 0; };

inline bool av1FindObu(const uint8_t* d, size_t n, int wantType, Av1ObuSpan& out) {
    size_t off = 0;
    while (off < n) {
        const size_t unitStart = off;
        const uint8_t h = d[off++];
        if (h & 0x80) return false;
        const int type = (h >> 3) & 0xF;
        const bool ext = (h >> 2) & 1, hasSize = (h >> 1) & 1;
        if (ext) { if (off >= n) return false; ++off; }
        size_t end = n;
        if (hasSize) {
            uint64_t size = 0;
            if (!readLeb128(d, n, off, size) || size > n - off) return false;
            end = off + (size_t)size;
        }
        if (type == wantType) { out.start = unitStart; out.len = end - unitStart; return true; }
        off = end;
    }
    return false;
}

enum class Av1SeqHeaderAction { Keep, Adopt, Replace, Trial };
inline Av1SeqHeaderAction av1SeqHeaderAction(bool parses, bool haveCandidate, bool sameLength, bool sameBytes,
                                             bool dimsDiffer, bool trialAvailable) {
    const bool pairable = haveCandidate && sameLength;
    if (pairable && sameBytes) return Av1SeqHeaderAction::Keep;
    if (!parses) return pairable ? Av1SeqHeaderAction::Replace : Av1SeqHeaderAction::Keep;
    if (pairable && dimsDiffer && trialAvailable) return Av1SeqHeaderAction::Trial;
    return Av1SeqHeaderAction::Adopt;
}

inline Av1SeqHeaderAction av1SeqHeaderTrialVerdict(bool ownDecodes, bool candidateDecodes) {
    if (ownDecodes) return Av1SeqHeaderAction::Adopt;
    return candidateDecodes ? Av1SeqHeaderAction::Replace : Av1SeqHeaderAction::Keep;
}

struct Av1SeqVerdictMemo {
    struct Entry {
        std::vector<uint8_t> hdr, cand;
        Av1SeqHeaderAction act = Av1SeqHeaderAction::Keep;
        int trials = 0;
    };
    std::vector<Entry> entries;
    static bool same(const std::vector<uint8_t>& v, const uint8_t* d, size_t n) {
        return v.size() == n && (n == 0 || std::memcmp(v.data(), d, n) == 0);
    }
    Entry* find(const uint8_t* hdr, size_t len, const std::vector<uint8_t>& cand) {
        Entry* exact = nullptr;
        for (Entry& e : entries) {
            if (!same(e.hdr, hdr, len)) continue;
            if (e.act == Av1SeqHeaderAction::Adopt) return &e;
            if (!exact && e.cand == cand) exact = &e;
        }
        return exact;
    }

    bool lookup(const uint8_t* hdr, size_t len, const std::vector<uint8_t>& cand, Av1SeqHeaderAction& act) {
        const Entry* e = find(hdr, len, cand);
        if (!e || (e->act == Av1SeqHeaderAction::Keep && e->trials < 2)) return false;
        act = e->act;
        return true;
    }
    void record(const uint8_t* hdr, size_t len, const std::vector<uint8_t>& cand, Av1SeqHeaderAction act) {
        try {
            if (Entry* e = find(hdr, len, cand)) {
                e->act = act;
                e->cand = cand;
                ++e->trials;
                return;
            }
            if (entries.size() >= 8) entries.erase(entries.begin());
            Entry e;
            e.hdr.assign(hdr, hdr + len);
            e.cand = cand;
            e.act = act;
            e.trials = 1;
            entries.push_back(std::move(e));
        } catch (const std::bad_alloc&) {
        }
    }
    void clear() { entries.clear(); }
};

inline PacketInspection inspectStartCode(const uint8_t* d, size_t n, StartCodeCodec sc) {
    PacketInspection r;
    if (startsWithStartCode(d, n)) {
        r.structure = PacketStructure::Intact; r.safePrefix = n; r.units = 1; r.hasVcl = true;
        return r;
    }
    r.structure = PacketStructure::Broken;
    if (sc == StartCodeCodec::Unknown || n < 8) return r;
    const size_t lim = std::min(n, (size_t)4096);
    size_t k = n;
    for (size_t i = 1; i + 3 < lim; ++i) { if (d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1) { k = i; break; } }
    if (k >= n || k + 5 >= n) return r;
    struct Code { size_t at; uint8_t type; };
    std::vector<Code> codes;
    for (size_t i = k; i + 3 < n && codes.size() < 4096; ++i) {
        if (d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1) { codes.push_back({i, d[i + 3]}); i += 2; }
    }
    if (codes.empty()) return r;
    bool ok = false;
    switch (sc) {
    case StartCodeCodec::Mpeg12: {
        const uint8_t first = codes[0].type;
        if (!(first == 0x00 || first == 0xB3 || first == 0xB5 || first == 0xB8)) break;
        bool pic = false, slice = false;
        for (const Code& c : codes) {
            if (c.type == 0x00) {
                const int pct = c.at + 5 < n ? (d[c.at + 5] >> 3) & 7 : 0;
                pic = pct >= 1 && pct <= 3;
            } else if (c.type >= 0x01 && c.type <= 0xAF) {
                if (pic) slice = true;
            }
        }
        ok = pic && slice;
        break;
    }
    case StartCodeCodec::Mpeg4: {
        const uint8_t first = codes[0].type;
        if (!(first == 0xB0 || first == 0xB5 || first <= 0x2F || first == 0xB3 || first == 0xB6)) break;
        for (const Code& c : codes) if (c.type == 0xB6) ok = true;
        break;
    }
    case StartCodeCodec::H264: {
        bool vclFirst = false; ok = true;
        for (const Code& c : codes) {
            const uint8_t h = c.type;
            const int type = h & 0x1f;
            const bool legal = !(h & 0x80) && ((type >= 1 && type <= 12) || type == 14 || type == 15 || type == 19 || type == 20);
            if (!legal) { ok = false; break; }
            if ((type == 1 || type == 5) && c.at + 4 < n && (d[c.at + 4] & 0x80)) vclFirst = true; // first_mb_in_slice = ue(0)
        }
        ok = ok && vclFirst;
        break;
    }
    case StartCodeCodec::Hevc: {
        bool vclFirst = false; ok = true;
        for (const Code& c : codes) {
            if (c.at + 4 >= n) { ok = false; break; }
            const uint8_t h0 = d[c.at + 3], h1 = d[c.at + 4];
            const int type = (h0 >> 1) & 0x3f;
            const bool legal = !(h0 & 0x80) && (h1 & 0x07) != 0 && type <= 40;
            if (!legal) { ok = false; break; }
            if (type <= 21 && c.at + 5 < n && (d[c.at + 5] & 0x80)) vclFirst = true; // first_slice_segment_in_pic_flag
        }
        ok = ok && vclFirst;
        break;
    }
    case StartCodeCodec::Unknown: break;
    }
    if (!ok) return r;
    r.resyncFrom = k;
    r.safePrefix = 0;
    r.hasVcl = true;
    r.units = (int)codes.size();

    if (sc == StartCodeCodec::Mpeg12 && k == 12 && d[3] == 0xB3) {
        static const uint8_t sc3[3] = {0, 0, 1};
        int diff = -1, diffs = 0;
        for (int i = 0; i < 3; ++i) if (d[i] != sc3[i]) { diff = i; ++diffs; }
        const uint32_t w = ((uint32_t)d[4] << 4) | (d[5] >> 4), hgt = ((uint32_t)(d[5] & 0x0F) << 8) | d[6];
        const int aspect = d[7] >> 4, frc = d[7] & 0x0F;
        const bool marker = (d[10] & 0x20) != 0;
        if (diffs == 1 && w > 0 && hgt > 0 && w <= 4096 && hgt <= 4096 && aspect >= 1 && aspect <= 4 && frc >= 1 && frc <= 8 && marker) {
            r.prefixFixAt = (size_t)diff;
            r.prefixFixByte = sc3[diff];
            r.resyncLossless = true;
        }
    }
    return r;
}

inline PacketInspection inspect(const uint8_t* d, size_t n, BitstreamLayout layout, int knownAllZero) {
    PacketInspection r;
    if (!d || n == 0) return r;

    if (knownAllZero == 1 || (knownAllZero < 0 && allZero(d, n))) {
        if (layout.kind != Bitstream::Other) r.structure = PacketStructure::AllZero;
        return r;
    }
    switch (layout.kind) {
    case Bitstream::LengthPrefixed: return inspectLengthPrefixed(d, n, layout.nalLengthSize, layout.hevc);
    case Bitstream::StartCode: return inspectStartCode(d, n, layout.sc);
    case Bitstream::Av1Obu: return inspectAv1(d, n);
    case Bitstream::Other: return r;
    }
    return r;
}
inline PacketInspection inspect(const uint8_t* d, size_t n, BitstreamLayout layout) { return inspect(d, n, layout, -1); }

inline bool isDamageEvidence(PacketStructure s) {
    return s == PacketStructure::AllZero || s == PacketStructure::Broken;
}

inline bool deliverable(const PacketInspection& pi) {
    if (pi.structure == PacketStructure::Intact) return true;
    if (pi.structure == PacketStructure::Broken && pi.resyncFrom > 0) return true;
    return pi.structure == PacketStructure::Broken && pi.safePrefix > 0 && pi.hasVcl;
}

inline int popcount8(uint8_t x) { int c = 0; while (x) { c += x & 1; x >>= 1; } return c; }
inline int popcount32(uint32_t x) { int c = 0; while (x) { c += (int)(x & 1); x >>= 1; } return c; }

struct ByteFix { size_t at = 0; uint8_t value = 0; };

} // namespace spresil
