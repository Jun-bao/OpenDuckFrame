// OpenDuckFrame - container recovery basics: Patch/RecoveryPlan, byte helpers, fixed signatures and wrapper headers
//
// Split out of the umbrella header by section; function bodies, constants and inline
// attributes are unchanged. Callers keep including the umbrella; this file only guarantees
// that it compiles on its own.
#pragma once

#include "SPResilience.hpp"
#include "RecoveryTypes.hpp"
#include <algorithm>
#include <array>
#include <climits>
#include <cmath>
#include <map>
#include <memory>
#include <set>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include <zlib.h>

namespace spresil {

inline std::vector<uint8_t> readSpan(const Reader& read, int64_t pos, size_t n) {
    std::vector<uint8_t> b(n);
    if (pos < 0 || n == 0) { b.clear(); return b; }
    int64_t got = read(pos, b.data(), n);
    if (got < 0) got = 0;
    b.resize((size_t)got);
    return b;
}

inline void putBe32(std::vector<uint8_t>& v, uint32_t x) { v.push_back((uint8_t)(x >> 24)); v.push_back((uint8_t)(x >> 16)); v.push_back((uint8_t)(x >> 8)); v.push_back((uint8_t)x); }
inline void putBe64(std::vector<uint8_t>& v, uint64_t x) { putBe32(v, (uint32_t)(x >> 32)); putBe32(v, (uint32_t)x); }
inline void putLe32(std::vector<uint8_t>& v, uint32_t x) { v.push_back((uint8_t)x); v.push_back((uint8_t)(x >> 8)); v.push_back((uint8_t)(x >> 16)); v.push_back((uint8_t)(x >> 24)); }
inline bool aborted(const AbortFn* abort) { return abort && *abort && (*abort)(); }

inline Reader patchedReader(const Reader& base, const std::vector<Patch>& patches) {
    if (patches.empty()) return base;
    return [base, patches](int64_t pos, uint8_t* buf, size_t n) -> int64_t {
        const int64_t got = base(pos, buf, n);
        if (got <= 0) return got;
        for (const Patch& pt : patches) {
            const int64_t ps = pt.offset, pe = pt.offset + (int64_t)pt.bytes.size();
            const int64_t s0 = std::max(pos, ps), e0 = std::min(pos + got, pe);
            if (s0 < e0) std::memcpy(buf + (s0 - pos), pt.bytes.data() + (s0 - ps), (size_t)(e0 - s0));
        }
        return got;
    };
}

inline Reader patchedReader(const Reader& base, const PatchOverlay& overlay) {
    if (overlay.empty()) return base;
    return [base, snap = overlay.shared()](int64_t pos, uint8_t* buf, size_t n) -> int64_t {
        const int64_t got = base(pos, buf, n);
        if (got <= 0) return got;
        for (const Patch& pt : *snap) {
            const int64_t ps = pt.offset, pe = pt.offset + (int64_t)pt.bytes.size();
            const int64_t s0 = std::max(pos, ps), e0 = std::min(pos + got, pe);
            if (s0 < e0) std::memcpy(buf + (s0 - pos), pt.bytes.data() + (s0 - ps), (size_t)(e0 - s0));
        }
        return got;
    };
}

inline const std::array<uint32_t, 256>& oggCrcTable() {
    static const std::array<uint32_t, 256> table = [] {
        std::array<uint32_t, 256> t{};
        for (uint32_t i = 0; i < 256; ++i) {
            uint32_t r = i << 24;
            for (int k = 0; k < 8; ++k) r = (r & 0x80000000u) ? (r << 1) ^ 0x04c11db7u : (r << 1);
            t[i] = r;
        }
        return t;
    }();
    return table;
}

inline uint32_t oggCrc32(const uint8_t* d, size_t n, uint32_t crc = 0) {
    const auto& table = oggCrcTable();
    for (size_t i = 0; i < n; ++i) crc = (crc << 8) ^ table[((crc >> 24) ^ d[i]) & 0xff];
    return crc;
}

struct FindCursor {
    std::vector<uint8_t> buf;
    int64_t winPos = -1;
    size_t winLen = 0;
    size_t chunk = 64 * 1024;
};

inline bool findBytes(const Reader& read, int64_t from, int64_t to, const uint8_t* pat, size_t n,
                      int64_t& out, const AbortFn* abort, FindCursor* cur = nullptr) {
    if (n == 0 || from < 0 || to <= from) return false;
    constexpr size_t kMaxChunk = 1024 * 1024;

    thread_local FindCursor local;
    FindCursor& c = cur ? *cur : local;
    if (!cur) { c.winPos = -1; c.winLen = 0; c.chunk = 64 * 1024; }
    if (c.buf.size() < kMaxChunk + 64) c.buf.resize(kMaxChunk + 64);
    int64_t pos = from;
    size_t carry = 0;

    if (c.winPos >= 0 && from >= c.winPos && from < c.winPos + (int64_t)c.winLen) {
        const size_t off = (size_t)(from - c.winPos);
        const size_t end = (size_t)std::min<int64_t>((int64_t)c.winLen, to - c.winPos);
        for (size_t i = off; i + n <= end; ++i) {
            if (c.buf[i] == pat[0] && std::memcmp(c.buf.data() + i, pat, n) == 0) { out = c.winPos + (int64_t)i; return true; }
        }
        pos = c.winPos + (int64_t)end;
        if (pos >= to) return false;
        carry = end >= n - 1 ? n - 1 : end;
        if (carry) std::memmove(c.buf.data(), c.buf.data() + end - carry, carry);
    }
    while (pos < to) {
        if (aborted(abort)) return false;
        const size_t want = (size_t)std::min<int64_t>((int64_t)c.chunk, to - pos);
        const int64_t got = read(pos, c.buf.data() + carry, want);
        if (got <= 0) { c.winPos = -1; c.winLen = 0; return false; }
        const size_t len = carry + (size_t)got;
        c.winPos = pos - (int64_t)carry;
        c.winLen = len;
        if (c.chunk < kMaxChunk) c.chunk *= 2;
        if (len >= n) {
            for (size_t i = 0; i + n <= len; ++i) {
                if (c.buf[i] == pat[0] && std::memcmp(c.buf.data() + i, pat, n) == 0) {
                    out = c.winPos + (int64_t)i;
                    return true;
                }
            }
        }
        pos += got;

        carry = len >= n - 1 ? n - 1 : len;
        if (carry) std::memmove(c.buf.data(), c.buf.data() + len - carry, carry);
    }
    return false;
}

inline bool zeroFilledTail(const Reader& read, int64_t from, int64_t size, const AbortFn* abort) {
    constexpr int64_t kBlock = 4096, kMinTail = 16 * 1024;
    constexpr int kSamples = 8;
    if (from < 0 || size - from < kMinTail) return false;
    uint8_t b[kBlock];
    auto zeroAt = [&](int64_t pos) -> bool {
        if (aborted(abort) || read(pos, b, (size_t)kBlock) != kBlock) return false;
        for (int64_t i = 0; i < kBlock; ++i) if (b[i]) return false;
        return true;
    };
    const int64_t last = size - kBlock;
    if (!zeroAt(last)) return false;
    int zeros = 1;
    for (int i = 0; i < kSamples - 1; ++i) {
        if (zeroAt(from + (last - from) * i / (kSamples - 1))) ++zeros;
        if (aborted(abort)) return false;
    }
    return zeros * 2 > kSamples;
}

inline constexpr std::array<uint8_t, 16> kAsfHeaderGuid = {0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11,
                                                           0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C};

inline RecoveryPlan planRiffSignature(const Reader& read, int64_t fileSize) {
    RecoveryPlan p;
    auto h = readSpan(read, 0, 24);
    if (h.size() < 24) return p;
    if (std::memcmp(h.data(), "RIFF", 4) == 0) return p;
    if (std::memcmp(h.data() + 8, "AVI ", 4) != 0 || std::memcmp(h.data() + 12, "LIST", 4) != 0) return p;

    const uint32_t listSize = le32(h.data() + 16);
    if (listSize < 4 || (int64_t)listSize + 20 > fileSize || std::memcmp(h.data() + 20, "hdrl", 4) != 0) return p;
    Patch sig{0, {'R', 'I', 'F', 'F'}};
    const uint32_t riffSize = le32(h.data() + 4);
    if (riffSize < 12 || (int64_t)riffSize + 8 > fileSize + 8) {
        putLe32(sig.bytes, (uint32_t)std::min<int64_t>(fileSize - 8, 0xFFFFFFFFll));
    }
    p.patches.push_back(sig);
    p.kind = "riff-signature";
    p.detail = "RIFF 签名重建（AVI /LIST hdrl 印证）";
    p.damagedFrom = 0; p.damagedUntil = 4;
    return p;
}

inline RecoveryPlan planAsfGuid(const Reader& read, int64_t fileSize) {
    RecoveryPlan p;
    auto h = readSpan(read, 0, 54);
    if (h.size() < 54) return p;
    if (std::memcmp(h.data(), kAsfHeaderGuid.data(), 16) == 0) return p;
    const uint64_t headerSize = le64(h.data() + 16);
    const uint32_t objCount = le32(h.data() + 24);
    if (h[28] != 0x01 || h[29] != 0x02) return p;
    if (headerSize < 30 || headerSize > (uint64_t)fileSize || objCount < 1 || objCount > 256) return p;
    const uint64_t firstObjSize = le64(h.data() + 46);
    if (firstObjSize < 24 || firstObjSize > headerSize) return p;
    Patch g{0, std::vector<uint8_t>(kAsfHeaderGuid.begin(), kAsfHeaderGuid.end())};
    p.patches.push_back(g);
    p.kind = "asf-guid";
    p.detail = "ASF Header GUID 重建（reserved/对象链印证）";
    p.damagedFrom = 0; p.damagedUntil = 16;
    return p;
}

inline std::vector<uint8_t> buildEbmlHeader(size_t total) {
    static const std::vector<uint8_t> full = {0x42, 0x86, 0x81, 0x01, 0x42, 0xF7, 0x81, 0x01, 0x42, 0xF2, 0x81, 0x04,
                                              0x42, 0xF3, 0x81, 0x08, 0x42, 0x82, 0x88, 'm', 'a', 't', 'r', 'o', 's',
                                              'k', 'a', 0x42, 0x87, 0x81, 0x04, 0x42, 0x85, 0x81, 0x02};
    static const std::vector<uint8_t> mid = {0x42, 0x86, 0x81, 0x01, 0x42, 0xF7, 0x81, 0x01, 0x42, 0x82, 0x88,
                                             'm', 'a', 't', 'r', 'o', 's', 'k', 'a'};
    static const std::vector<uint8_t> minimal = {0x42, 0x82, 0x88, 'm', 'a', 't', 'r', 'o', 's', 'k', 'a'};
    for (int k : {1, 8}) {
        if (total < 4 + (size_t)k + minimal.size()) continue;
        const size_t body = total - 4 - (size_t)k;
        if (k == 1 && body > 126) continue;
        for (const auto* c : {&full, &mid, &minimal}) {
            if (body < c->size()) continue;
            const size_t pad = body - c->size();
            std::vector<uint8_t> voidEl;
            if (pad == 1) continue;
            if (pad >= 2) {
                voidEl.push_back(0xEC);
                const size_t data = pad - 2;
                if (data <= 126) {
                    voidEl.push_back((uint8_t)(0x80 | data));
                } else {
                    if (pad < 10) continue;
                    const size_t data8 = pad - 9;
                    voidEl.push_back(0x01);
                    for (int i = 6; i >= 0; --i) voidEl.push_back((uint8_t)(data8 >> (8 * i)));
                }
                voidEl.resize(pad, 0);
            }
            std::vector<uint8_t> out = {0x1A, 0x45, 0xDF, 0xA3};
            if (k == 1) {
                out.push_back((uint8_t)(0x80 | body));
            } else {
                out.push_back(0x01);
                for (int i = 6; i >= 0; --i) out.push_back((uint8_t)(body >> (8 * i)));
            }
            out.insert(out.end(), c->begin(), c->end());
            out.insert(out.end(), voidEl.begin(), voidEl.end());
            if (out.size() == total) return out;
        }
    }
    return {};
}

inline int ebmlVintLen(uint8_t b) {
    for (int i = 0; i < 8; ++i) if (b & (0x80 >> i)) return i + 1;
    return 0;
}

inline int ebmlReadSize(const uint8_t* p, size_t n, uint64_t& val, bool& unknown) {
    if (n == 0) return 0;
    const int len = ebmlVintLen(p[0]);
    if (len == 0 || (size_t)len > n) return 0;
    uint64_t v = p[0] & (0xFF >> len);
    uint64_t all = (uint64_t)(0xFF >> len);
    for (int i = 1; i < len; ++i) { v = (v << 8) | p[i]; all = (all << 8) | 0xFF; }
    val = v;
    unknown = v == all;
    return len;
}

inline RecoveryPlan planEbmlHeader(const Reader& read, int64_t fileSize) {
    RecoveryPlan p;
    auto h = readSpan(read, 0, 4096);
    if (h.size() < 32) return p;
    static const uint8_t magic[4] = {0x1A, 0x45, 0xDF, 0xA3};
    if (std::memcmp(h.data(), magic, 4) == 0) return p;
    static const uint8_t segId[4] = {0x18, 0x53, 0x80, 0x67};
    for (size_t s = 16; s + 12 <= h.size(); ++s) {
        if (std::memcmp(h.data() + s, segId, 4) != 0) continue;
        uint64_t segSize = 0; bool unknown = false;
        const int sl = ebmlReadSize(h.data() + s + 4, h.size() - s - 4, segSize, unknown);
        if (sl == 0) continue;
        if (!unknown && (int64_t)segSize > fileSize) continue;
        const size_t child = s + 4 + (size_t)sl;
        if (child + 4 > h.size()) continue;
        const uint8_t* c = h.data() + child;
        const bool known4 = (c[0] == 0x11 && c[1] == 0x4D && c[2] == 0x9B && c[3] == 0x74) || // SeekHead
                            (c[0] == 0x15 && c[1] == 0x49 && c[2] == 0xA9 && c[3] == 0x66) || // Info
                            (c[0] == 0x16 && c[1] == 0x54 && c[2] == 0xAE && c[3] == 0x6B) || // Tracks
                            (c[0] == 0x1F && c[1] == 0x43 && c[2] == 0xB6 && c[3] == 0x75);   // Cluster
        const bool known1 = c[0] == 0xEC || c[0] == 0xBF; // Void / CRC-32
        if (!known4 && !known1) continue;
        auto hdr = buildEbmlHeader(s);
        if (hdr.empty()) return p;
        p.patches.push_back({0, hdr});
        p.kind = "ebml-header";
        p.detail = "EBML 头重建（Segment 与首子元素印证），长度 " + std::to_string(s);
        p.damagedFrom = 0; p.damagedUntil = (int64_t)s;
        return p;
    }
    return p;
}

inline RecoveryPlan planFixedHeader(const Reader& read, int64_t fileSize) {
    RecoveryPlan p = planRiffSignature(read, fileSize);
    if (!p.empty()) return p;
    p = planAsfGuid(read, fileSize);
    if (!p.empty()) return p;
    return planEbmlHeader(read, fileSize);
}

inline bool isRawFormatName(const std::string& n) {
    static const char* raw[] = {"h264", "hevc", "m4v", "mpegvideo", "mjpeg", "vc1", "av1", "obu", "mp3", "aac",
                                "ac3", "eac3", "dts", "truehd", "mlp", "rawvideo", "yuv4mpegpipe", "data", "bin"};
    for (const char* r : raw) if (n == r) return true;
    return false;
}

inline bool avccStrictValid(const uint8_t* e, int n) {

    return avccForEachParamSet(e, n, [](const uint8_t* nal, size_t, bool sps) { return (nal[0] & 0x9f) == (sps ? 0x07 : 0x08); });
}
inline bool hvccStrictValid(const uint8_t* e, int n) {
    if (!hvccRecordValid(e, n)) return false;
    return hvccForEachNal(e, n, [](int type, const uint8_t* nal, size_t) {
        return !(nal[0] & 0x80) && ((nal[0] >> 1) & 0x3f) == type && (nal[1] & 7) != 0;
    });
}

} // namespace spresil
