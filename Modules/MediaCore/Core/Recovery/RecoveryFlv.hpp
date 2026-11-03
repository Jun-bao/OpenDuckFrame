// OpenDuckFrame - container recovery: FLV (PreviousTagSize, DataSize reverse chain, AVCPacketType)
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
// ───────────────────────── FLV PreviousTagSize ─────────────────────────

inline RecoveryPlan planFlvPrevTagAt(const Reader& read, int64_t fileSize, int64_t fromPos, const AbortFn* abort) {
    RecoveryPlan p;
    if (fromPos < 9) return p;
    int64_t pos = fromPos;
    int valid = 0, mismatches = 0;
    uint32_t prevDataSize = 0;
    bool havePrev = false;
    for (int i = 0; i < 64 && pos + 15 <= fileSize; ++i) {
        if (aborted(abort)) return p;
        auto t = readSpan(read, pos, 15);
        if (t.size() < 15) break;
        const uint32_t prevSize = be32(t.data());
        const uint8_t type = t[4] & 0x1f;
        const uint32_t dataSize = be24(t.data() + 5);
        const uint32_t streamId = be24(t.data() + 12);
        if ((type != 8 && type != 9 && type != 18) || dataSize == 0 || streamId != 0) break;
        if (pos + 4 + 11 + (int64_t)dataSize > fileSize) break;
        if (havePrev && prevSize != 11 + prevDataSize) ++mismatches;
        ++valid;
        prevDataSize = dataSize;
        havePrev = true;
        pos += 4 + 11 + dataSize;
    }
    if (valid < 8 || mismatches == 0) return p;
    p.flvIgnorePrevTag = true;
    p.kind = "flv-prevtag";
    p.detail = "标签链闭合 " + std::to_string(valid) + " 个、PreviousTagSize 失配 " + std::to_string(mismatches) +
               " 处：以 flv_ignore_prevtag 重开";
    p.damagedFrom = fromPos; p.damagedUntil = pos;
    return p;
}

inline RecoveryPlan planFlvPrevTag(const Reader& read, int64_t fileSize, int64_t fromPos, const AbortFn* abort) {
    RecoveryPlan p = planFlvPrevTagAt(read, fileSize, fromPos, abort);
    if (p.empty() && fromPos >= 13) p = planFlvPrevTagAt(read, fileSize, fromPos - 4, abort);
    return p;
}

struct FlvTagHead { uint8_t type = 0; uint32_t dataSize = 0; uint32_t ts = 0; uint32_t streamId = 0; };

inline bool flvParseTagHead(const uint8_t* t, FlvTagHead& h) {
    h.type = t[0]; h.dataSize = be24(t + 1);
    h.ts = be24(t + 4) | ((uint32_t)t[7] << 24);
    h.streamId = be24(t + 8);
    const uint8_t kind = h.type & 0x1f;
    return (h.type & 0xC0) == 0 && (kind == 8 || kind == 9 || kind == 18) && h.streamId == 0;
}
inline bool flvReadTagHead(const Reader& read, int64_t pos, FlvTagHead& h) {
    auto t = readSpan(read, pos, 11);
    if (t.size() < 11) return false;
    return flvParseTagHead(t.data(), h);
}

constexpr int64_t kFlvMaxPrevTagSize = 0xFFFFFF + 11;

inline RecoveryPlan planFlvDataSize(const Reader& read, int64_t fileSize, const AbortFn* abort) {
    RecoveryPlan p;
    auto hdr = readSpan(read, 0, 13);
    if (hdr.size() < 13 || std::memcmp(hdr.data(), "FLV", 3) != 0 || be32(hdr.data() + 5) != 9 || be32(hdr.data() + 9) != 0) return p;

    auto anchorAt = [&](int64_t f, int64_t* startOut) -> bool {
        if (f < 13 + 4) return false;
        auto s = readSpan(read, f, 4);
        if (s.size() < 4) return false;
        const int64_t pts = be32(s.data());
        if (pts < 12 || pts > kFlvMaxPrevTagSize || f - pts < 13) return false;
        FlvTagHead h;
        if (!flvReadTagHead(read, f - pts, h)) return false;
        if (startOut) *startOut = f - pts;
        return true;
    };
    int64_t footer = -1;
    {
        int64_t start = 0;
        if (anchorAt(fileSize - 4, &start) && anchorAt(start - 4, nullptr)) footer = fileSize - 4;
        else {

            const int64_t winFrom = std::max<int64_t>(13, fileSize - 1024 * 1024);
            auto win = readSpan(read, winFrom, (size_t)(fileSize - winFrom));

            if (win.size() != (size_t)(fileSize - winFrom)) return p;
            for (int64_t f = fileSize - 4; f >= winFrom + 16 && footer < 0; --f) {
                if (aborted(abort)) return p;
                const int64_t pts = be32(win.data() + (f - winFrom));
                if (pts < 12 || pts > kFlvMaxPrevTagSize || f - pts < 13) continue;
                int64_t s1 = 0;
                if (!anchorAt(f, &s1) || !anchorAt(s1 - 4, nullptr)) continue;
                footer = f;
            }
        }
    }
    if (footer < 0) return p;
    int64_t f = footer;
    int tags = 0, mismatches = 0;
    uint32_t laterTs = 0xFFFFFFFFu;
    int64_t firstBad = -1, lastBad = -1;
    std::vector<Patch> patches;

    std::vector<uint8_t> walk;
    int64_t walkFrom = 0, walkTo = 0;
    auto bytesAt = [&](int64_t at, size_t n) -> const uint8_t* {
        if (at < 0 || at + (int64_t)n > fileSize) return nullptr;
        if (at < walkFrom || at + (int64_t)n > walkTo) {
            walkTo = at + (int64_t)n;
            walkFrom = std::max<int64_t>(0, walkTo - 1024 * 1024);
            if (walkTo - walkFrom < (int64_t)n) walkFrom = at;
            walk = readSpan(read, walkFrom, (size_t)(walkTo - walkFrom));
            if ((int64_t)walk.size() != walkTo - walkFrom) { walkFrom = walkTo = 0; walk.clear(); return nullptr; }
        }
        return walk.data() + (at - walkFrom);
    };
    for (;;) {
        if (aborted(abort) || ++tags > 400000) return p;
        const uint8_t* s = bytesAt(f, 4);
        if (!s) return p;
        const int64_t pts = be32(s);
        if (f == 9) { if (pts != 0) return p; break; }
        if (pts < 12 || pts > kFlvMaxPrevTagSize || f - pts < 13) return p;
        const int64_t tagStart = f - pts;
        FlvTagHead h;
        const uint8_t* th = bytesAt(tagStart, 11);
        if (!th || !flvParseTagHead(th, h)) return p;
        if (laterTs != 0xFFFFFFFFu && h.ts > laterTs && h.ts - laterTs > 10000) return p;
        if ((int64_t)h.dataSize + 11 != pts) {
            Patch pt; pt.offset = tagStart + 1;
            const uint32_t want = (uint32_t)(pts - 11);
            pt.bytes = {(uint8_t)(want >> 16), (uint8_t)(want >> 8), (uint8_t)want};
            patches.push_back(pt);
            ++mismatches;
            if (lastBad < 0) lastBad = tagStart + 11 + (int64_t)want;
            firstBad = tagStart;
        }
        laterTs = h.ts;
        f = tagStart - 4;
    }
    if (mismatches == 0) return p;
    std::reverse(patches.begin(), patches.end());
    p.patches = std::move(patches);
    p.kind = "flv-datasize";
    p.detail = "PreviousTagSize 反向链闭合到文件头（" + std::to_string(tags) + " 个标签）、DataSize 失配 " + std::to_string(mismatches) +
               " 处：按 PreviousTagSize−11 覆盖" + (footer != fileSize - 4 ? "（尾部截断，锚点取最后自洽标签）" : "");
    p.damagedFrom = firstBad; p.damagedUntil = lastBad;
    return p;
}

inline RecoveryPlan planFlvAvcSubtype(const Reader& read, int64_t fileSize, int64_t from, int64_t window, FlvAvcScanState& st, const AbortFn* abort) {
    RecoveryPlan p;
    if (from < 13 || from >= fileSize || window <= 0) return p;
    const int64_t limit = std::min(fileSize, from + window);
    int64_t pos = from;
    int contradictions = 0, configs = 0;
    for (int tags = 0; tags < 200000 && pos + 11 <= fileSize; ++tags) {
        if (aborted(abort)) break;
        FlvTagHead h;
        if (!flvReadTagHead(read, pos, h)) break;
        const int64_t next = pos + 11 + (int64_t)h.dataSize + 4;
        if (next > fileSize) break;
        if (pos >= limit) break;
        if ((h.type & 0x1f) == 9 && h.dataSize >= 5) {
            auto vh = readSpan(read, pos + 11, 5);
            if (vh.size() == 5 && (vh[0] & 0x0f) == 7 && (vh[0] >> 4) != 5) {
                const uint8_t subtype = vh[1];
                const int64_t bodyPos = pos + 11 + 5;
                const size_t bodyLen = (size_t)h.dataSize - 5;
                if (subtype == 0 && bodyLen >= 7 && bodyLen <= 1u << 20) {
                    auto body = readSpan(read, bodyPos, bodyLen);
                    if (body.size() == bodyLen) {
                        if (avccStrictValid(body.data(), (int)body.size())) { st.nalLen = (body[4] & 3) + 1; st.haveConfig = true; ++configs; }
                        else if (st.haveConfig) {
                            bool vcl = false;
                            if (nalChainIntact(body.data(), body.size(), st.nalLen, false, &vcl) && vcl) {
                                Patch pt; pt.offset = pos + 11 + 1; pt.bytes = {1}; p.patches.push_back(pt); ++contradictions;
                                if (p.damagedFrom < 0) p.damagedFrom = pos;
                                p.damagedUntil = next;
                            }
                        }
                    }
                } else if (subtype == 1 && bodyLen >= (size_t)st.nalLen + 1 && bodyLen <= 1u << 20) {
                    auto head = readSpan(read, bodyPos, (size_t)st.nalLen + 1);
                    bool plausible = false;
                    if (head.size() == (size_t)st.nalLen + 1) {
                        uint32_t len = 0; for (int i = 0; i < st.nalLen; ++i) len = (len << 8) | head[(size_t)i];
                        const uint8_t nh = head[(size_t)st.nalLen];
                        plausible = len > 0 && len <= bodyLen - (size_t)st.nalLen && !(nh & 0x80) && (nh & 0x1f) >= 1 && (nh & 0x1f) <= 23;
                    }
                    if (!plausible && bodyLen >= 7) {
                        auto body = readSpan(read, bodyPos, bodyLen);
                        bool vcl = false;
                        if (body.size() == bodyLen && !nalChainIntact(body.data(), body.size(), st.nalLen, false, &vcl) && avccStrictValid(body.data(), (int)body.size())) {
                            Patch pt; pt.offset = pos + 11 + 1; pt.bytes = {0}; p.patches.push_back(pt); ++contradictions;
                            st.nalLen = (body[4] & 3) + 1; st.haveConfig = true;
                            if (p.damagedFrom < 0) p.damagedFrom = pos;
                            p.damagedUntil = next;
                        }
                    }
                }
            }
        }
        pos = next;
        ++st.tags;
    }
    st.scannedUntil = pos;
    if (p.patches.empty()) return p;
    p.kind = "flv-avc-subtype";
    p.detail = "AVC 标签的 AVCPacketType 与体语法矛盾（配置记录 ↔ NAL 链互斥）：" + std::to_string(contradictions) + " 处改回（合法配置 " +
               std::to_string(configs) + " 个不动）";
    return p;
}

} // namespace spresil
