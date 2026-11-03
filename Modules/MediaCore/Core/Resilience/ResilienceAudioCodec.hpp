// OpenDuckFrame - resilient playback: audio frame structure and configuration evidence (FLAC, AC-3/E-AC-3, ADTS, MKV FLAC lacing, Matroska audio CodecPrivate)
//
// Split out of the umbrella header by section; function bodies, constants and inline
// attributes are unchanged. Callers keep including the umbrella; this file only guarantees
// that it compiles on its own.
#pragma once

#include "ResilienceVideoCodec.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <functional>
#include <string>
#include <utility>
#include <vector>

namespace spresil {

struct FlacFrameHeader {
    uint32_t blockSize = 0;
    uint32_t sampleRate = 0;
    int channels = 0;
    int bps = 0;
    bool variable = false;
    uint64_t number = 0;
    size_t headerSize = 0;
};

inline uint8_t flacCrc8(const uint8_t* d, size_t n) {
    uint8_t c = 0;
    for (size_t i = 0; i < n; ++i) { c ^= d[i]; for (int k = 0; k < 8; ++k) c = (uint8_t)((c & 0x80) ? (c << 1) ^ 0x07 : (c << 1)); }
    return c;
}

struct FlacCrc16Tbl {
    uint16_t t[256];
    constexpr FlacCrc16Tbl() : t{} {
        for (unsigned i = 0; i < 256; ++i) { uint16_t c = (uint16_t)(i << 8); for (int k = 0; k < 8; ++k) c = (uint16_t)((c & 0x8000) ? (c << 1) ^ 0x8005 : (c << 1)); t[i] = c; }
    }
};
inline constexpr FlacCrc16Tbl kFlacCrc16Tbl{};
inline const uint16_t* flacCrc16Table() { return kFlacCrc16Tbl.t; }
inline uint16_t flacCrc16Update(uint16_t c, const uint8_t* d, size_t n) {
    const uint16_t* t = flacCrc16Table();
    for (size_t i = 0; i < n; ++i) c = (uint16_t)((c << 8) ^ t[(c >> 8) ^ d[i]]);
    return c;
}
inline uint16_t flacCrc16(const uint8_t* d, size_t n) { return flacCrc16Update(0, d, n); }

inline bool flacParseFrameHeader(const uint8_t* b, size_t n, FlacFrameHeader& h) {
    h = FlacFrameHeader{};
    if (!b || n < 6 || b[0] != 0xFF || (b[1] & 0xFE) != 0xF8 || (b[3] & 1)) return false;
    const int bc = b[2] >> 4, rc = b[2] & 15, ch = b[3] >> 4, bp = (b[3] >> 1) & 7;
    if (bc == 0 || rc == 15 || ch > 10 || bp == 3) return false;
    size_t p = 4;

    {
        const uint8_t x = b[p++];
        if (x < 0x80) h.number = x;
        else {
            int lead = 0; while (lead < 8 && (x & (0x80 >> lead))) ++lead;
            if (lead < 2 || lead > 7) return false;
            uint64_t v = x & (uint8_t)((1u << (7 - lead)) - 1);
            for (int i = 1; i < lead; ++i) { if (p >= n || (b[p] & 0xC0) != 0x80) return false; v = (v << 6) | (b[p] & 0x3f); ++p; }
            h.number = v;
        }
    }
    if (bc == 6) { if (p >= n) return false; h.blockSize = (uint32_t)b[p] + 1; p += 1; }
    else if (bc == 7) { if (p + 1 >= n) return false; h.blockSize = (((uint32_t)b[p] << 8) | b[p + 1]) + 1; p += 2; }
    else { static const uint32_t tbl[16] = {0, 192, 576, 1152, 2304, 4608, 0, 0, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768}; h.blockSize = tbl[bc]; }
    static const uint32_t rates[12] = {0, 88200, 176400, 192000, 8000, 16000, 22050, 24000, 32000, 44100, 48000, 96000};
    if (rc < 12) h.sampleRate = rates[rc];
    else if (rc == 12) { if (p >= n) return false; h.sampleRate = (uint32_t)b[p] * 1000; p += 1; }
    else { if (p + 1 >= n) return false; h.sampleRate = (((uint32_t)b[p] << 8) | b[p + 1]) * (rc == 14 ? 10u : 1u); p += 2; }
    if (p >= n) return false;
    if (flacCrc8(b, p + 1) != 0) return false;
    static const int bpsTbl[8] = {0, 8, 12, 0, 16, 20, 24, 32};
    h.bps = bpsTbl[bp];
    h.channels = ch < 8 ? ch + 1 : 2;
    h.variable = (b[1] & 1) != 0;
    h.headerSize = p + 1;
    return true;
}

inline bool flacFrameCrc16Ok(const uint8_t* d, size_t n) { return d && n >= 2 && flacCrc16(d, n) == 0; }

struct FlacStreamInfo {
    uint32_t minBlock = 0, maxBlock = 0, minFrame = 0, maxFrame = 0, sampleRate = 0;
    int channels = 0, bps = 0;
    uint64_t totalSamples = 0;
    uint8_t md5[16] = {0};
    bool md5Present() const { for (uint8_t x : md5) if (x) return true; return false; }
};

inline bool flacParseStreamInfo(const uint8_t* s, size_t n, FlacStreamInfo& out) {
    if (!s || n < 34) return false;
    out.minBlock = ((uint32_t)s[0] << 8) | s[1];
    out.maxBlock = ((uint32_t)s[2] << 8) | s[3];
    out.minFrame = ((uint32_t)s[4] << 16) | ((uint32_t)s[5] << 8) | s[6];
    out.maxFrame = ((uint32_t)s[7] << 16) | ((uint32_t)s[8] << 8) | s[9];
    uint64_t v = 0; for (int i = 0; i < 8; ++i) v = (v << 8) | s[10 + i];
    out.sampleRate = (uint32_t)(v >> 44);
    out.channels = (int)((v >> 41) & 7) + 1;
    out.bps = (int)((v >> 36) & 31) + 1;
    out.totalSamples = v & ((1ull << 36) - 1);
    std::memcpy(out.md5, s + 18, 16);
    return true;
}

inline constexpr int kFlacTailMaxCandidates = 4;

inline size_t flacFrameLenBound(const FlacStreamInfo& info) {
    const uint64_t block = info.maxBlock ? info.maxBlock : 65535;
    const uint64_t ch = (uint64_t)std::clamp(info.channels, 1, 8);
    const uint64_t bps = (uint64_t)std::clamp(info.bps, 1, 32);
    return (size_t)(19 + ch * (5 + (block * (bps + 1) + 7) / 8));
}

inline size_t flacTailSearchSpan(const FlacStreamInfo& info) {
    const size_t bound = flacFrameLenBound(info);
    return info.maxFrame && info.maxFrame < bound ? (size_t)info.maxFrame : bound;
}

inline bool flacTailLastFrameEnd(const uint8_t* tail, size_t n, const FlacStreamInfo& info, uint64_t& endSample,
                                 const AbortFn* abort = nullptr, size_t* crcBytes = nullptr) {
    if (!tail || n < 16) return false;
    size_t end = n;
    if (end >= 128 && std::memcmp(tail + end - 128, "TAG", 3) == 0) end -= 128;
    if (end >= 32 && std::memcmp(tail + end - 32, "APETAGEX", 8) == 0) {
        const uint8_t* f = tail + end - 32;
        const uint64_t size = (uint64_t)f[12] | ((uint64_t)f[13] << 8) | ((uint64_t)f[14] << 16) | ((uint64_t)f[15] << 24);
        const bool hasHeader = (f[23] & 0x80) != 0;
        const uint64_t total = size + (hasHeader ? 32 : 0);
        if (size < 32 || total > end) return false;
        end -= (size_t)total;
    }
    if (end < 16) return false;
    const size_t maxLen = flacTailSearchSpan(info);
    int candidates = 0;
    for (size_t p = end - 8; p-- > 0;) {
        if (end - p > maxLen) break;
        if (tail[p] != 0xFF || (tail[p + 1] & 0xFE) != 0xF8) continue;
        FlacFrameHeader h;
        if (!flacParseFrameHeader(tail + p, end - p, h) || h.headerSize + 2 > end - p) continue;
        if (++candidates > kFlacTailMaxCandidates) return false;
        if (abort && *abort && (*abort)()) return false;
        if (crcBytes) *crcBytes += end - p;
        if (flacCrc16(tail + p, end - p) != 0) continue;
        if (h.channels != info.channels || (h.sampleRate && h.sampleRate != info.sampleRate) || (h.bps && h.bps != info.bps)) return false;
        uint64_t first;
        if (h.variable) first = h.number;
        else {
            if (info.minBlock != info.maxBlock || info.maxBlock == 0) return false;
            first = h.number * info.maxBlock;
        }
        endSample = first + h.blockSize;
        return true;
    }
    return false;
}

inline bool flacStreamInfoCandidate(const uint8_t* si, size_t n, const std::vector<FlacFrameHeader>& frames, std::vector<uint8_t>& out, std::string& what) {
    FlacStreamInfo info;
    if (!flacParseStreamInfo(si, n, info) || frames.empty()) return false;
    uint32_t maxBlock = 0; int bps = frames[0].bps, channels = frames[0].channels; uint32_t rate = frames[0].sampleRate;
    for (size_t i = 0; i < frames.size(); ++i) {
        const FlacFrameHeader& f = frames[i];
        if (f.variable || f.number != frames[0].number + i) return false;
        if (f.bps != bps || f.channels != channels || f.sampleRate != rate) return false;
        if (i + 1 < frames.size() && f.blockSize != frames[0].blockSize) return false;
        maxBlock = std::max(maxBlock, f.blockSize);
    }
    if (bps == 0 || maxBlock == 0) return false;
    out.assign(si, si + 34);
    what.clear();
    if (info.maxBlock < maxBlock) {
        out[2] = (uint8_t)(maxBlock >> 8); out[3] = (uint8_t)maxBlock;
        what += "max_blocksize " + std::to_string(info.maxBlock) + "→" + std::to_string(maxBlock);
    }
    if (info.bps != bps) {
        uint64_t v = 0; for (int i = 0; i < 8; ++i) v = (v << 8) | out[10 + i];
        v = (v & ~(31ull << 36)) | ((uint64_t)(bps - 1) << 36);
        for (int i = 0; i < 8; ++i) out[10 + i] = (uint8_t)(v >> (8 * (7 - i)));
        what += std::string(what.empty() ? "" : "，") + "bps " + std::to_string(info.bps) + "→" + std::to_string(bps);
    }
    return !what.empty();
}

struct Ac3Header {
    bool eac3 = false;
    uint32_t frameSize = 0;
    int sampleRate = 0;
    int bsid = 0;
};

inline bool ac3ParseHeader(const uint8_t* d, size_t n, Ac3Header& h) {
    h = Ac3Header{};
    if (!d || n < 6 || d[0] != 0x0B || d[1] != 0x77) return false;
    h.bsid = d[5] >> 3;
    if (h.bsid <= 10) {
        static const uint16_t words[19][3] = {{64, 69, 96},     {80, 87, 120},    {96, 104, 144},   {112, 121, 168},  {128, 139, 192},
                                              {160, 174, 240},  {192, 208, 288},  {224, 243, 336},  {256, 278, 384},  {320, 348, 480},
                                              {384, 417, 576},  {448, 487, 672},  {512, 557, 768},  {640, 696, 960},  {768, 835, 1152},
                                              {896, 975, 1344}, {1024, 1114, 1536}, {1152, 1253, 1728}, {1280, 1393, 1920}};
        const int fscod = d[4] >> 6, code = d[4] & 0x3f;
        if (fscod == 3 || code >= 38) return false;
        uint32_t w = words[code >> 1][fscod];
        if (fscod == 1) w += (uint32_t)(code & 1);
        static const int rates[3] = {48000, 44100, 32000};
        h.frameSize = w * 2;
        h.sampleRate = rates[fscod] >> (h.bsid > 8 ? h.bsid - 8 : 0);
        return true;
    }
    if (h.bsid > 16) return false;
    h.eac3 = true;
    const int strmtyp = d[2] >> 6;
    if (strmtyp == 3) return false;
    const uint32_t frmsiz = ((uint32_t)(d[2] & 7) << 8) | d[3];
    h.frameSize = (frmsiz + 1) * 2;
    if (h.frameSize < 8) return false;
    const int fscod = d[4] >> 6;
    if (fscod == 3) {
        const int fscod2 = (d[4] >> 4) & 3;
        if (fscod2 == 3) return false;
        static const int r2[3] = {24000, 22050, 16000};
        h.sampleRate = r2[fscod2];
    } else {
        static const int rates[3] = {48000, 44100, 32000};
        h.sampleRate = rates[fscod];
    }
    return true;
}

inline bool ac3FrameCrcOk(const uint8_t* d, size_t n, const Ac3Header& h) {
    if (!d || h.frameSize < 8 || n < h.frameSize) return false;
    if (h.eac3) return flacCrc16(d + 2, h.frameSize - 2) == 0;
    const size_t split = (((size_t)h.frameSize >> 2) + ((size_t)h.frameSize >> 4)) * 2;
    if (split <= 2 || split >= h.frameSize) return false;
    return flacCrc16(d + 2, split - 2) == 0 && flacCrc16(d + split, h.frameSize - split) == 0;
}

inline bool ac3SizeConsistent(const uint8_t* d, size_t n, bool exact, bool atEof, uint32_t size) {
    if (exact) return size == n;
    if (size > n) return false;

    if ((size_t)size + 2 > n) return size == n && atEof;
    return d[size] == 0x0B && d[size + 1] == 0x77;
}

inline bool ac3FrameSizeFix(const uint8_t* d, size_t n, bool exact, bool atEof, int expectedRate, ByteFix& fix, uint32_t* sizeOut = nullptr) {
    if (!d || n < 8 || d[0] != 0x0B || d[1] != 0x77) return false;
    Ac3Header cur;
    const bool curOk = ac3ParseHeader(d, n, cur);
    if (curOk && ac3SizeConsistent(d, n, exact, atEof, cur.frameSize) && ac3FrameCrcOk(d, n, cur) &&
        (expectedRate <= 0 || cur.sampleRate == expectedRate)) {
        if (sizeOut) *sizeOut = cur.frameSize;
        return false;
    }

    if (exact && curOk && (size_t)cur.frameSize + 8 <= n && d[cur.frameSize] == 0x0B && d[cur.frameSize + 1] == 0x77) {
        Ac3Header next;
        if (ac3ParseHeader(d + cur.frameSize, n - cur.frameSize, next) && next.eac3 == cur.eac3) return false;
    }
    const bool eac3 = (d[5] >> 3) > 10;
    std::vector<uint8_t> buf(d, d + std::min<size_t>(n, 4096 + 2));
    int found = 0;
    ByteFix best;
    uint32_t bestSize = 0;
    auto tryCand = [&](size_t at, uint8_t mask) {
        buf[at] ^= mask;
        Ac3Header h;
        bool ok = ac3ParseHeader(buf.data(), buf.size(), h) && h.eac3 == eac3 && h.frameSize <= n &&
                  ac3SizeConsistent(d, n, exact, atEof, h.frameSize) && (expectedRate <= 0 || h.sampleRate == expectedRate) &&
                  h.frameSize <= buf.size() && ac3FrameCrcOk(buf.data(), buf.size(), h);
        if (ok) { ++found; best.at = at; best.value = buf[at]; bestSize = h.frameSize; }
        buf[at] ^= mask;
    };
    if (eac3) {
        for (int k = 0; k < 3; ++k) tryCand(2, (uint8_t)(1u << k));
        for (int k = 0; k < 8; ++k) tryCand(3, (uint8_t)(1u << k));
    } else {
        for (int k = 0; k < 8; ++k) tryCand(4, (uint8_t)(1u << k));
    }
    if (found != 1) return false;
    fix = best;
    if (sizeOut) *sizeOut = bestSize;
    return true;
}

inline void ac3ChainFix(const uint8_t* d, size_t n, bool atEof, std::vector<ByteFix>& fixes, size_t& consumed, int& badFrames) {
    size_t pos = 0;
    int prevRate = 0;
    consumed = 0;
    badFrames = 0;
    std::vector<uint8_t> patched;
    for (int frames = 0; frames < 1000000 && pos + 8 <= n; ++frames) {
        if (d[pos] != 0x0B || d[pos + 1] != 0x77) break;
        if (!atEof && n - pos < 4096 + 2) break;
        const size_t avail = n - pos;
        ByteFix fx;
        uint32_t size = 0;
        Ac3Header h;
        if (ac3FrameSizeFix(d + pos, avail, false, atEof, prevRate, fx, &size)) {
            fixes.push_back({pos + fx.at, fx.value});
            patched.assign(d + pos, d + pos + 8);
            patched[fx.at] = fx.value;
            ac3ParseHeader(patched.data(), patched.size(), h);
            prevRate = h.sampleRate;
            pos += size;
            consumed = pos;
            continue;
        }
        if (size > 0) {
            ac3ParseHeader(d + pos, avail, h);
            prevRate = h.sampleRate;
            pos += size;
            consumed = pos;
            continue;
        }

        ++badFrames;
        size_t q = pos + 2;
        while (q + 1 < n && q - pos <= 4096 && !(d[q] == 0x0B && d[q + 1] == 0x77)) ++q;
        if (q + 1 >= n || q - pos > 4096) break;
        pos = q;
        consumed = pos;
    }
}

struct AdtsHeader {
    uint32_t frameLength = 0;
    int profile = 0, sfIndex = 0, channels = 0;
    bool protectionAbsent = true;
    size_t headerSize = 7;
};

inline bool adtsParseHeader(const uint8_t* d, size_t n, AdtsHeader& h) {
    h = AdtsHeader{};
    if (!d || n < 7 || d[0] != 0xFF || (d[1] & 0xF6) != 0xF0) return false; // sync + layer=00
    h.protectionAbsent = (d[1] & 1) != 0;
    h.profile = d[2] >> 6;
    h.sfIndex = (d[2] >> 2) & 0x0F;
    if (h.sfIndex >= 13) return false;
    h.channels = ((d[2] & 1) << 2) | (d[3] >> 6);
    h.frameLength = ((uint32_t)(d[3] & 3) << 11) | ((uint32_t)d[4] << 3) | (d[5] >> 5);
    h.headerSize = h.protectionAbsent ? 7 : 9;
    return h.frameLength >= h.headerSize;
}

inline bool adtsBoundaryOk(const uint8_t* d, size_t n, bool atEof, size_t end, const AdtsHeader& h) {
    if (end == n) return atEof;
    if (end > n || n - end < 7) return false;
    AdtsHeader nx;
    return adtsParseHeader(d + end, n - end, nx) && nx.profile == h.profile && nx.sfIndex == h.sfIndex && nx.channels == h.channels;
}

inline bool adtsFrameLengthFix(const uint8_t* d, size_t n, bool atEof, ByteFix& fix, uint32_t* lenOut = nullptr) {
    AdtsHeader h;
    if (!adtsParseHeader(d, n, h)) return false;
    if (adtsBoundaryOk(d, n, atEof, h.frameLength, h)) { if (lenOut) *lenOut = h.frameLength; return false; }
    int found = 0;
    ByteFix best;
    uint32_t bestLen = 0;
    for (int k = 0; k < 13; ++k) {
        const uint32_t cand = h.frameLength ^ (1u << k);
        if (cand < h.headerSize || cand > 8191 || cand > n) continue;
        if (!adtsBoundaryOk(d, n, atEof, cand, h)) continue;
        ++found;
        if (k < 3) { best.at = 5; best.value = (uint8_t)(d[5] ^ (1u << (k + 5))); }
        else if (k < 11) { best.at = 4; best.value = (uint8_t)(d[4] ^ (1u << (k - 3))); }
        else { best.at = 3; best.value = (uint8_t)(d[3] ^ (1u << (k - 11))); }
        bestLen = cand;
    }
    if (found != 1) return false;
    fix = best;
    if (lenOut) *lenOut = bestLen;
    return true;
}

inline void adtsChainFix(const uint8_t* d, size_t n, bool atEof, std::vector<ByteFix>& fixes, size_t& consumed, int& badFrames) {
    size_t pos = 0;
    consumed = 0;
    badFrames = 0;
    for (int frames = 0; frames < 1000000 && pos + 7 <= n; ++frames) {
        AdtsHeader h;
        if (!adtsParseHeader(d + pos, n - pos, h)) break;
        if (!atEof && n - pos < 8191 + 7) break;
        ByteFix fx;
        uint32_t len = 0;
        const bool fixed = adtsFrameLengthFix(d + pos, n - pos, atEof, fx, &len);
        if (len == 0) {

            ++badFrames;
            size_t q = pos + 1;
            while (q + 1 < n && q - pos <= 8192 && !(d[q] == 0xFF && (d[q + 1] & 0xF6) == 0xF0)) ++q;
            if (q + 1 >= n || q - pos > 8192) break;
            pos = q;
            consumed = pos;
            continue;
        }
        if (fixed) fixes.push_back({pos + fx.at, fx.value});
        pos += len;
        consumed = pos;
    }
}

inline bool flacLaceVerify(const uint8_t* lace, size_t n, FlacFrameHeader& h, const FlacFrameHeader* prev) {
    if (!lace || n < 10 || !flacParseFrameHeader(lace, n, h) || h.headerSize + 2 > n) return false;
    if (prev) {
        if (h.variable != prev->variable || h.channels != prev->channels || h.bps != prev->bps || h.sampleRate != prev->sampleRate) return false;
        if (!h.variable && h.number != prev->number + 1) return false;
        if (h.variable && h.number != prev->number + prev->blockSize) return false;
    }

    const uint16_t* t = flacCrc16Table();
    uint16_t c = 0;
    for (size_t i = 0; i < n; ++i) {
        if (c == 0 && i >= h.headerSize && i + 10 <= n && lace[i] == 0xFF && (lace[i + 1] & 0xFE) == 0xF8) {
            FlacFrameHeader nx;
            if (flacParseFrameHeader(lace + i, n - i, nx) && nx.variable == h.variable && nx.channels == h.channels && nx.bps == h.bps &&
                nx.sampleRate == h.sampleRate && (h.variable ? nx.number == h.number + h.blockSize : nx.number == h.number + 1))
                return false;
        }
        c = (uint16_t)((c << 8) ^ t[(c >> 8) ^ lace[i]]);
    }
    return c == 0;
}

inline bool mkvLaceLayout(const uint8_t* b, size_t bn, size_t flagsOff, uint8_t flags, std::vector<std::pair<size_t, size_t>>& laces) {
    laces.clear();
    const int lacing = (flags >> 1) & 3;
    size_t off = flagsOff + 1;
    if (lacing == 0) { if (off >= bn) return false; laces.push_back({off, bn - off}); return true; }
    if (off >= bn) return false;
    const int frames = b[off++] + 1;
    std::vector<size_t> sizes;
    if (lacing == 2) {
        const size_t remain = bn - off;
        if (remain % (size_t)frames != 0) return false;
        sizes.assign((size_t)frames, remain / (size_t)frames);
    } else if (lacing == 1) {
        uint64_t sum = 0;
        for (int f = 0; f < frames - 1; ++f) {
            uint64_t len = 0;
            while (true) { if (off >= bn) return false; const uint8_t v = b[off++]; len += v; if (v != 255) break; }
            sizes.push_back((size_t)len); sum += len;
        }
        if (off + sum > bn) return false;
        sizes.push_back((size_t)(bn - off - (size_t)sum));
    } else {
        if (off >= bn) return false;
        if (frames == 1) { laces.push_back({off, bn - off}); return true; }
        uint64_t first = 0;
        int fl = 0;
        {
            const uint8_t x = b[off];
            int len = 0; while (len < 8 && !(x & (0x80 >> len))) ++len;
            if (len >= 8) return false;
            fl = len + 1;
            if (off + (size_t)fl > bn) return false;
            first = x & (uint8_t)(0x7F >> len);
            for (int i = 1; i < fl; ++i) first = (first << 8) | b[off + (size_t)i];
        }
        off += (size_t)fl;
        int64_t prev = (int64_t)first, sum = (int64_t)first;
        sizes.push_back((size_t)first);
        for (int f = 1; f < frames - 1; ++f) {
            if (off >= bn) return false;
            const uint8_t x = b[off];
            int len = 0; while (len < 8 && !(x & (0x80 >> len))) ++len;
            if (len >= 8) return false;
            const int rl = len + 1;
            if (off + (size_t)rl > bn) return false;
            uint64_t raw = x & (uint8_t)(0x7F >> len);
            for (int i = 1; i < rl; ++i) raw = (raw << 8) | b[off + (size_t)i];
            off += (size_t)rl;
            const int64_t bias = (int64_t)((1ull << (7 * rl - 1)) - 1);
            const int64_t cur = prev + ((int64_t)raw - bias);
            if (cur < 0) return false;
            sizes.push_back((size_t)cur); sum += cur; prev = cur;
        }
        if (sum < 0 || off + (uint64_t)sum > bn) return false;
        sizes.push_back((size_t)(bn - off - (size_t)sum));
    }
    for (size_t s : sizes) { if (s == 0) return false; laces.push_back({off, s}); off += s; }
    return off == bn;
}

inline bool mkvFlacLacesVerified(const uint8_t* b, size_t bn, size_t flagsOff, uint8_t flags, const FlacFrameHeader* prevBlock, FlacFrameHeader* lastOut) {
    std::vector<std::pair<size_t, size_t>> laces;
    if (!mkvLaceLayout(b, bn, flagsOff, flags, laces) || laces.empty()) return false;
    FlacFrameHeader prev, h;
    bool havePrev = false;
    if (prevBlock) { prev = *prevBlock; havePrev = true; }
    bool shortSeen = false;
    for (const auto& l : laces) {
        if (shortSeen) return false;
        if (!flacLaceVerify(b + l.first, l.second, h, havePrev ? &prev : nullptr)) return false;
        if (havePrev && !h.variable && h.blockSize != prev.blockSize) { if (h.blockSize > prev.blockSize) return false; shortSeen = true; }
        prev = h; havePrev = true;
    }
    if (lastOut) *lastOut = prev;
    return true;
}

inline bool mkvFlacLacingFix(const uint8_t* b, size_t bn, size_t flagsOff, const FlacFrameHeader* prevBlock, ByteFix& fix, bool* verifiedOut,
                             FlacFrameHeader* lastOut = nullptr) {
    if (verifiedOut) *verifiedOut = false;
    if (!b || flagsOff + 1 >= bn) return false;
    if (mkvFlacLacesVerified(b, bn, flagsOff, b[flagsOff], prevBlock, lastOut)) { if (verifiedOut) *verifiedOut = true; return false; }
    std::vector<uint8_t> whole(b, b + bn);
    const size_t region = std::min(bn, flagsOff + 1 + 64);
    int found = 0;
    ByteFix best;
    FlacFrameHeader bestLast;
    for (size_t at = flagsOff; at < region; ++at) {
        for (int k = 0; k < 8; ++k) {
            const uint8_t mask = (uint8_t)(1u << k);
            if (at == flagsOff && (mask & 0x06) == 0) continue;
            whole[at] ^= mask;
            const uint8_t flags = whole[flagsOff];
            if ((flags & 0x70) == 0) {
                FlacFrameHeader last;
                if (mkvFlacLacesVerified(whole.data(), whole.size(), flagsOff, flags, prevBlock, &last)) { ++found; best.at = at; best.value = whole[at]; bestLast = last; }
            }
            whole[at] ^= mask;
            if (found > 1) return false;
        }
    }
    if (found != 1) return false;
    fix = best;
    if (lastOut) *lastOut = bestLast;
    return true;
}

struct AacAscFields { int aot = 0, sfi = 0, chanConfig = 0; bool frameLength960 = false, dependsOnCore = false, extension = false; };
inline bool aacParseAscFields(const uint8_t* d, size_t n, AacAscFields& f) {
    if (!d || n < 2) return false;
    f.aot = d[0] >> 3;
    if (f.aot == 31) return false;
    f.sfi = ((d[0] & 7) << 1) | (d[1] >> 7);
    if (f.sfi == 15) return false;
    f.chanConfig = (d[1] >> 3) & 15;
    f.frameLength960 = (d[1] & 4) != 0; f.dependsOnCore = (d[1] & 2) != 0; f.extension = (d[1] & 1) != 0;
    return true;
}
inline int aacSampleRateForIndex(int sfi) { static const int r[13] = {96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350}; return sfi >= 0 && sfi < 13 ? r[sfi] : 0; }
inline int aacChannelsForConfig(int c) { static const int ch[8] = {0, 1, 2, 3, 4, 5, 6, 8}; return c >= 1 && c <= 7 ? ch[c] : 0; }

inline bool aacAscImpossible(const uint8_t* d, size_t n) {
    AacAscFields f;
    if (!aacParseAscFields(d, n, f)) return false;
    return f.aot == 2 && ((f.chanConfig >= 8 && f.chanConfig <= 10) || f.chanConfig == 15 || f.sfi == 13 || f.sfi == 14);
}

inline bool aacAscLcConsistent(const uint8_t* d, size_t n, int channels, double rateHz) {
    AacAscFields f;
    if (!aacParseAscFields(d, n, f)) return false;
    if (f.aot != 2 || f.frameLength960 || f.dependsOnCore || f.extension) return false;
    const int ch = aacChannelsForConfig(f.chanConfig), rate = aacSampleRateForIndex(f.sfi);
    if (ch == 0 || rate == 0) return false;
    if (channels > 0 && ch != channels) return false;
    if (rateHz > 0 && std::fabs((double)rate - rateHz) > 1.0) return false;
    return true;
}

inline bool opusHeadConsistent(const uint8_t* d, size_t n, int channels) {
    if (!d || n < 19 || std::memcmp(d, "OpusHead", 8) != 0 || d[8] >= 16 || d[9] == 0) return false;
    if (channels > 0 && d[9] != channels) return false;
    const int ch = d[9], fam = d[18];
    if (fam == 0) return ch <= 2 && n == 19;
    if (fam != 1 && fam != 2 && fam != 3 && fam != 255) return false;
    if (n < 21u + (size_t)ch) return false;
    const int streams = d[19], coupled = d[20];
    if (streams < 1 || coupled > streams || streams + coupled > 255) return false;
    for (int i = 0; i < ch; ++i) { const int m = d[21 + i]; if (m != 255 && m >= streams + coupled) return false; }
    return true;
}

inline bool vorbisCodecPrivateConsistent(const uint8_t* d, size_t n, int channels, double rateHz, size_t* tableEndOut = nullptr) {
    if (!d || n < 3 || d[0] != 2) return false;
    size_t p = 1; size_t len[2] = {0, 0};
    for (int i = 0; i < 2; ++i) {
        bool closed = false;
        while (p < n) { const uint8_t v = d[p++]; len[i] += v; if (v != 255) { closed = true; break; } }
        if (!closed) return false;
    }
    if (tableEndOut) *tableEndOut = p;
    if (p + len[0] + len[1] >= n) return false;
    const uint8_t* a = d + p; const uint8_t* c = a + len[0]; const uint8_t* s = c + len[1];
    const size_t sLen = n - (size_t)(s - d);
    if (len[0] != 30 || std::memcmp(a, "\x01vorbis", 7) != 0 || a[7] || a[8] || a[9] || a[10] || a[11] == 0 || a[29] != 1) return false;
    const uint32_t rate = (uint32_t)a[12] | ((uint32_t)a[13] << 8) | ((uint32_t)a[14] << 16) | ((uint32_t)a[15] << 24);
    const int small = a[28] & 15, big = a[28] >> 4;
    if (rate == 0 || !(small >= 6 && small <= big && big <= 13)) return false;
    if (channels > 0 && a[11] != channels) return false;
    if (rateHz > 0 && std::fabs((double)rate - rateHz) > 1.0) return false;
    if (len[1] < 16 || std::memcmp(c, "\x03vorbis", 7) != 0 || sLen < 8 || std::memcmp(s, "\x05vorbis", 7) != 0) return false;
    size_t o = 7;
    auto rd32 = [&](uint32_t& v) { if (o + 4 > len[1]) return false; v = (uint32_t)c[o] | ((uint32_t)c[o + 1] << 8) | ((uint32_t)c[o + 2] << 16) | ((uint32_t)c[o + 3] << 24); o += 4; return true; };
    uint32_t vlen = 0; if (!rd32(vlen) || vlen > len[1] - o) return false;
    o += vlen;
    uint32_t cnt = 0; if (!rd32(cnt) || cnt > 10000) return false;
    for (uint32_t i = 0; i < cnt; ++i) { uint32_t l = 0; if (!rd32(l) || l > len[1] - o) return false; o += l; }
    return o + 1 == len[1] && (c[o] & 1);
}

} // namespace spresil
