// OpenDuckFrame - container recovery: MP4/MOV/fMP4 (box walk, mdat before trailing moov, bad-trak isolation, table counts and entries, fragment chains and re-anchoring, ctts, no-moov extraction, track ownership / sample sizes / tfdt)
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
// ───────────────────────── ISO BMFF ─────────────────────────

struct Box {
    int64_t pos = 0;
    uint64_t size = 0;
    int hdr = 8;
    char type[5] = {0};
    bool sizeFieldZero = false;
    bool largeSizeZero = false;
    int64_t end() const { return pos + (int64_t)size; }
    bool is(const char* t) const { return std::memcmp(type, t, 4) == 0; }
};

inline bool readBox(const Reader& read, int64_t pos, int64_t limit, Box& b) {
    if (pos < 0 || pos + 8 > limit) return false;
    uint8_t h[16];
    const int64_t got = read(pos, h, 16);
    if (got < 8) return false;
    b = Box{};
    b.pos = pos;
    uint64_t size = be32(h);
    std::memcpy(b.type, h + 4, 4);
    b.hdr = 8;
    if (size == 1) {
        if (got < 16) return false;
        size = be64(h + 8);
        b.hdr = 16;
        if (size == 0) { b.largeSizeZero = true; size = (uint64_t)(limit - pos); }
    } else if (size == 0) {
        b.sizeFieldZero = true;
        size = (uint64_t)(limit - pos);
    }
    if (!isBoxType((const uint8_t*)b.type) || size < (uint64_t)b.hdr) return false;

    if (size > (uint64_t)(INT64_MAX - pos)) return false;
    b.size = size;
    return true;
}

inline bool mp4TableFits(const Box& b, uint64_t bodyOff, uint64_t n, uint64_t stride) {
    if (b.size < (uint64_t)b.hdr + bodyOff) return false;
    const uint64_t body = b.size - (uint64_t)b.hdr - bodyOff;
    return stride == 0 || n <= body / stride;
}

inline bool boxChildrenClose(const Reader& read, int64_t from, int64_t to, std::vector<std::string>* types,
                             std::vector<Box>* boxes, const AbortFn* abort) {
    int64_t pos = from;
    int hops = 0;
    while (pos < to) {
        if (aborted(abort) || ++hops > 256) return false;
        Box b;
        if (!readBox(read, pos, to, b)) return false;
        if (b.sizeFieldZero || b.largeSizeZero) return false;
        if (b.end() > to) return false;
        if (types && types->size() < 64) types->push_back(std::string(b.type, 4));
        if (boxes && boxes->size() < 64) boxes->push_back(b);
        pos = b.end();
    }
    return pos == to;
}

inline bool mp4FindChild(const Reader& read, const Box& parent, const char* type, Box& out, const AbortFn* abort) {
    std::vector<Box> kids;
    if (!boxChildrenClose(read, parent.pos + parent.hdr, parent.end(), nullptr, &kids, abort)) return false;
    for (const Box& k : kids) if (k.is(type)) { out = k; return true; }
    return false;
}

inline bool hasType(const std::vector<std::string>& v, const char* t) {
    for (const auto& s : v) if (s == t) return true;
    return false;
}

inline bool validateMoov(const Reader& read, int64_t pos, int64_t fileSize, const AbortFn* abort, int64_t* endOut) {
    Box b;
    if (!readBox(read, pos, fileSize, b) || !b.is("moov") || b.sizeFieldZero || b.largeSizeZero) return false;
    if (b.end() > fileSize || b.size < 16) return false;
    std::vector<std::string> types;
    if (!boxChildrenClose(read, pos + b.hdr, b.end(), &types, nullptr, abort)) return false;
    if (!hasType(types, "mvhd") || !hasType(types, "trak")) return false;
    if (endOut) *endOut = b.end();
    return true;
}

inline bool mp4FindTopMoov(const Reader& read, int64_t fileSize, const AbortFn* abort, Box& moov, bool stopAtMoof = false) {
    int64_t pos = 0;
    for (int hops = 0; hops < 64 && pos + 8 <= fileSize; ++hops) {
        if (aborted(abort)) return false;
        Box b;
        if (!readBox(read, pos, fileSize, b) || b.end() > fileSize) return false;
        if (b.is("moov")) { moov = b; return true; }
        if (stopAtMoof && b.is("moof")) return false;
        if (b.sizeFieldZero || b.largeSizeZero) return false;
        pos = b.end();
    }
    return false;
}

inline std::vector<uint32_t> mp4ReadTrackIds(const Reader& read, int64_t fileSize, const AbortFn* abort) {
    std::vector<uint32_t> ids;
    Box b;
    if (!mp4FindTopMoov(read, fileSize, abort, b)) return ids;
    std::vector<Box> kids;
    if (!boxChildrenClose(read, b.pos + b.hdr, b.end(), nullptr, &kids, abort)) return ids;
    for (const Box& k : kids) {
        std::vector<Box> sub;
        if (!k.is("trak") && !k.is("mvex")) continue;
        if (!boxChildrenClose(read, k.pos + k.hdr, k.end(), nullptr, &sub, abort)) continue;
        for (const Box& c : sub) {
            if (k.is("trak") && c.is("tkhd")) {
                auto h = readSpan(read, c.pos + c.hdr, 24);
                if (h.size() < 24) continue;
                ids.push_back(be32(h.data() + (h[0] == 1 ? 20 : 12)));
            } else if (k.is("mvex") && c.is("trex")) {
                auto h = readSpan(read, c.pos + c.hdr, 8);
                if (h.size() >= 8) ids.push_back(be32(h.data() + 4));
            }
        }
    }
    return ids;
}

inline bool validateTraf(const Reader& read, const Box& traf, const std::vector<uint32_t>* trackIds, const AbortFn* abort) {
    std::vector<Box> kids;
    if (!boxChildrenClose(read, traf.pos + traf.hdr, traf.end(), nullptr, &kids, abort)) return false;
    bool sawTfhd = false;
    for (const Box& c : kids) {
        if (c.is("tfhd")) {
            sawTfhd = true;
            auto h = readSpan(read, c.pos + c.hdr, 8);
            if (h.size() < 8) return false;
            const uint32_t flags = be32(h.data()) & 0xFFFFFF;
            const uint32_t trackId = be32(h.data() + 4);
            if (trackId == 0) return false;
            if (trackIds && !trackIds->empty()) {
                bool known = false;
                for (uint32_t t : *trackIds) if (t == trackId) known = true;
                if (!known) return false;
            }
            uint64_t want = 8; // version/flags + track_ID
            if (flags & 0x000001) want += 8;
            if (flags & 0x000002) want += 4;
            if (flags & 0x000008) want += 4;
            if (flags & 0x000010) want += 4;
            if (flags & 0x000020) want += 4;
            if (c.size - c.hdr != want) return false;
        } else if (c.is("trun")) {
            auto h = readSpan(read, c.pos + c.hdr, 8);
            if (h.size() < 8) return false;
            const uint32_t flags = be32(h.data()) & 0xFFFFFF;
            const uint64_t count = be32(h.data() + 4);
            uint64_t per = 0;
            if (flags & 0x000100) per += 4;
            if (flags & 0x000200) per += 4;
            if (flags & 0x000400) per += 4;
            if (flags & 0x000800) per += 4;
            uint64_t want = 8;
            if (flags & 0x000001) want += 4;
            if (flags & 0x000004) want += 4;
            want += count * per;
            if (c.size - c.hdr != want) return false;
            if (per == 0 && count > 1u << 24) return false;
        }
    }
    return sawTfhd;
}

inline bool validateMoof(const Reader& read, int64_t pos, int64_t fileSize, const AbortFn* abort, int64_t* endOut,
                         const std::vector<uint32_t>* trackIds = nullptr, bool* innerOk = nullptr) {
    Box b;
    if (innerOk) *innerOk = false;
    if (!readBox(read, pos, fileSize, b) || !b.is("moof") || b.sizeFieldZero || b.largeSizeZero) return false;
    if (b.end() > fileSize || b.size < 24 || b.size > 64ull * 1024 * 1024) return false;
    std::vector<std::string> types;
    std::vector<Box> kids;
    if (!boxChildrenClose(read, pos + b.hdr, b.end(), &types, &kids, abort)) return false;
    if (kids.empty() || !kids[0].is("mfhd") || kids[0].size != 16 || !hasType(types, "traf")) return false;
    Box next;
    if (!readBox(read, b.end(), fileSize, next) || !next.is("mdat")) return false;
    bool inner = true;
    for (const Box& k : kids) {
        if (k.is("traf") && !validateTraf(read, k, trackIds, abort)) { inner = false; break; }
    }
    if (innerOk) *innerOk = inner;
    if (endOut) *endOut = b.end();
    return inner || innerOk != nullptr;
}

inline int64_t findNextValidMoof(const Reader& read, int64_t from, int64_t fileSize, int64_t window,
                                 const AbortFn* abort, const std::vector<uint32_t>* trackIds = nullptr) {
    static const uint8_t pat[4] = {'m', 'o', 'o', 'f'};
    int64_t cur = from;
    const int64_t limit = std::min(fileSize, from + window);
    FindCursor fc;
    for (int tries = 0; tries < 4096 && cur < limit; ++tries) {
        int64_t hit = -1;
        if (!findBytes(read, cur, limit, pat, 4, hit, abort, &fc)) return -1;
        const int64_t boxPos = hit - 4;
        bool inner = false;
        if (boxPos >= from && validateMoof(read, boxPos, fileSize, abort, nullptr, trackIds, &inner) && inner) return boxPos;
        cur = hit + 1;
    }
    return -1;
}

inline RecoveryPlan planMp4MdatTailMoov(const Reader& read, int64_t fileSize, const AbortFn* abort) {
    RecoveryPlan p;
    int64_t pos = 0;
    for (int hops = 0; hops < 64 && pos + 8 <= fileSize; ++hops) {
        if (aborted(abort)) return p;
        Box b;
        if (!readBox(read, pos, fileSize, b)) return p;
        if (b.is("moov")) return p;
        if (b.is("mdat") && (b.sizeFieldZero || b.largeSizeZero) && b.end() >= fileSize) {

            static const uint8_t pat[4] = {'m', 'o', 'o', 'v'};
            const int64_t winFrom = std::max<int64_t>(pos + b.hdr, fileSize - 8ll * 1024 * 1024);
            int64_t cur = winFrom;
            FindCursor fc;
            for (int tries = 0; tries < 4096 && cur < fileSize; ++tries) {
                int64_t hit = -1;
                if (!findBytes(read, cur, fileSize, pat, 4, hit, abort, &fc)) break;
                const int64_t moovPos = hit - 4;
                int64_t moovEnd = 0;
                if (moovPos > pos && validateMoov(read, moovPos, fileSize, abort, &moovEnd)) {

                    if (moovEnd < fileSize && !boxChildrenClose(read, moovEnd, fileSize, nullptr, nullptr, abort)) {
                        cur = hit + 1;
                        continue;
                    }
                    const uint64_t mdatLen = (uint64_t)(moovPos - pos);
                    Patch pt;
                    if (b.hdr == 16) {
                        pt.offset = pos + 8;
                        putBe64(pt.bytes, mdatLen);
                    } else {
                        if (mdatLen > 0xFFFFFFFFull) return p;
                        pt.offset = pos;
                        putBe32(pt.bytes, (uint32_t)mdatLen);
                    }
                    p.patches.push_back(pt);
                    p.kind = "mp4-mdat-tail-moov";
                    p.detail = "mdat 长度字段为 0，尾部 moov 完整：校正 mdat 长度";
                    p.damagedFrom = pos; p.damagedUntil = pos + b.hdr;
                    return p;
                }
                cur = hit + 1;
            }
            return p;
        }
        if (b.end() > fileSize) return p;
        pos = b.end();
    }
    return p;
}

inline RecoveryPlan planMp4ZeroHeadTailMoov(const Reader& read, int64_t fileSize, const AbortFn* abort) {
    RecoveryPlan p;
    constexpr int64_t kMinZeroHead = 64 * 1024;
    constexpr int64_t kTailWindow = 64ll * 1024 * 1024;
    if (fileSize < kMinZeroHead * 2) return p;
    {
        const std::vector<uint8_t> head = readSpan(read, 0, (size_t)kMinZeroHead);
        if ((int64_t)head.size() < kMinZeroHead || !allZero(head.data(), head.size())) return p;
    }
    static const uint8_t pat[4] = {'m', 'o', 'o', 'v'};
    int64_t cur = std::max<int64_t>(kMinZeroHead, fileSize - kTailWindow);
    FindCursor fc;
    for (int tries = 0; tries < 4096 && cur < fileSize; ++tries) {
        if (aborted(abort)) return p;
        int64_t hit = -1;
        if (!findBytes(read, cur, fileSize, pat, 4, hit, abort, &fc)) return p;
        const int64_t moovPos = hit - 4;
        int64_t moovEnd = 0;
        if (moovPos >= kMinZeroHead && validateMoov(read, moovPos, fileSize, abort, &moovEnd) &&
            (moovEnd >= fileSize || boxChildrenClose(read, moovEnd, fileSize, nullptr, nullptr, abort))) {

            Patch pt;
            pt.offset = 0;
            const uint8_t ftyp[24] = {0, 0, 0, 24, 'f', 't', 'y', 'p', 'i', 's', 'o', 'm', 0, 0, 2, 0,
                                      'i', 's', 'o', 'm', 'm', 'p', '4', '1'};
            pt.bytes.assign(ftyp, ftyp + 24);
            const uint64_t mdatLen = (uint64_t)(moovPos - 24);
            if (mdatLen <= 0xFFFFFFFFull) {
                putBe32(pt.bytes, (uint32_t)mdatLen);
                pt.bytes.insert(pt.bytes.end(), {'m', 'd', 'a', 't'});
            } else {
                putBe32(pt.bytes, 1);
                pt.bytes.insert(pt.bytes.end(), {'m', 'd', 'a', 't'});
                putBe64(pt.bytes, mdatLen);
            }
            p.patches.push_back(pt);
            p.kind = "mp4-zero-head-tail-moov";
            p.detail = "文件开头整段为零（至少 64 KiB），尾部 moov 完整：合成文件头，零区样本按没有内容跳过";
            p.damagedFrom = 0;
            p.damagedUntil = kMinZeroHead;
            return p;
        }
        cur = hit + 1;
    }
    return p;
}

inline bool validateTrak(const Reader& read, const Box& trak, const AbortFn* abort) {
    Box mdia, minf, stbl, stsd;
    if (!mp4FindChild(read, trak, "mdia", mdia, abort)) return false;
    if (!mp4FindChild(read, mdia, "minf", minf, abort)) return false;
    if (!mp4FindChild(read, minf, "stbl", stbl, abort)) return false;
    if (!mp4FindChild(read, stbl, "stsd", stsd, abort)) return false;
    if (stsd.size < 16) return false;
    auto h = readSpan(read, stsd.pos + stsd.hdr, 8);
    if (h.size() < 8) return false;
    const uint32_t count = be32(h.data() + 4);
    if (count == 0 || count > 64) return false;
    int64_t pos = stsd.pos + stsd.hdr + 8;
    for (uint32_t i = 0; i < count; ++i) {
        auto e = readSpan(read, pos, 8);
        if (e.size() < 8) return false;
        const uint32_t esz = be32(e.data());
        if (esz < 16 || pos + (int64_t)esz > stsd.end()) return false;
        pos += esz;
    }
    return pos == stsd.end();
}

inline RecoveryPlan planMp4IsolateBadTrak(const Reader& read, int64_t fileSize, const AbortFn* abort) {
    RecoveryPlan p;
    Box b;
    if (!mp4FindTopMoov(read, fileSize, abort, b)) return p;
    std::vector<Box> kids;
    if (!boxChildrenClose(read, b.pos + b.hdr, b.end(), nullptr, &kids, abort)) return p;
    int good = 0;
    std::vector<Box> bad;
    for (const Box& k : kids) {
        if (!k.is("trak")) continue;
        if (validateTrak(read, k, abort)) ++good; else bad.push_back(k);
    }
    if (good == 0 || bad.empty()) return p;
    for (const Box& k : bad) p.patches.push_back({k.pos + 4, {'f', 'r', 'e', 'e'}});
    p.kind = "mp4-isolate-trak";
    p.detail = "隔离 " + std::to_string(bad.size()) + " 条结构损坏的 trak（保留 " + std::to_string(good) + " 条）";
    p.damagedFrom = bad[0].pos; p.damagedUntil = bad[0].end();
    return p;
}

inline RecoveryPlan planMp4TableCounts(const Reader& read, int64_t fileSize, const AbortFn* abort) {
    RecoveryPlan p;
    Box moov;
    if (!mp4FindTopMoov(read, fileSize, abort, moov)) return p;
    std::vector<Box> traks;
    if (!boxChildrenClose(read, moov.pos + moov.hdr, moov.end(), nullptr, &traks, abort)) return p;
    for (const Box& trak : traks) {
        if (!trak.is("trak")) continue;
        Box mdia, minf, stbl;
        if (!mp4FindChild(read, trak, "mdia", mdia, abort) || !mp4FindChild(read, mdia, "minf", minf, abort) || !mp4FindChild(read, minf, "stbl", stbl, abort)) continue;
        std::vector<Box> tables;
        if (!boxChildrenClose(read, stbl.pos + stbl.hdr, stbl.end(), nullptr, &tables, abort)) continue;
        std::vector<Patch> trakPatches;
        int64_t sttsSum = -1;
        int64_t stszCount = -1;
        Box stsz; bool haveStsz = false;
        bool conflict = false;
        for (const Box& t : tables) {
            int width = 0, countOff = 4;
            if (t.is("stts") || t.is("ctts")) width = 8;
            else if (t.is("stsc")) width = 12;
            else if (t.is("stss") || t.is("stco")) width = 4;
            else if (t.is("co64")) width = 8;
            else if (t.is("stsz")) { width = 4; countOff = 8; }
            else continue;
            const int64_t data = t.pos + t.hdr;
            const int64_t body = (int64_t)t.size - t.hdr - countOff - 4;
            if (body < 0) { conflict = true; break; }
            auto h = readSpan(read, data, (size_t)countOff + 4);
            if (h.size() < (size_t)countOff + 4) { conflict = true; break; }
            const uint32_t declared = be32(h.data() + countOff);
            int64_t count = declared;
            const bool stszFixed = t.is("stsz") && be32(h.data() + 4) != 0;
            if (stszFixed) {

            } else if ((int64_t)declared * width != body) {
                if (body % width != 0 || body / width > 50000000) { conflict = true; break; }
                count = body / width;
                Patch pt;
                pt.offset = data + countOff;
                putBe32(pt.bytes, (uint32_t)count);
                trakPatches.push_back(pt);
                p.detail += std::string(t.type, 4) + " 计数 " + std::to_string(declared) + "→" + std::to_string(count) + "; ";
            }
            if (t.is("stts") && count > 0 && count * 8 <= 8ll * 1024 * 1024) {
                auto tbl = readSpan(read, data + 8, (size_t)(count * 8));
                if ((int64_t)tbl.size() == count * 8) {
                    int64_t sum = 0;
                    for (int64_t i = 0; i < count; ++i) sum += be32(tbl.data() + (size_t)i * 8);
                    sttsSum = sum;
                }
            }
            if (t.is("stsz")) { stsz = t; haveStsz = true; stszCount = stszFixed ? -2 : count; }
        }
        if (conflict) continue;

        if (haveStsz && sttsSum >= 0) {
            if (stszCount == -2) {
                auto h = readSpan(read, stsz.pos + stsz.hdr, 12);
                if (h.size() == 12 && be32(h.data() + 8) != (uint32_t)sttsSum && sttsSum <= 50000000) {
                    Patch pt;
                    pt.offset = stsz.pos + stsz.hdr + 8;
                    putBe32(pt.bytes, (uint32_t)sttsSum);
                    trakPatches.push_back(pt);
                    p.detail += "stsz 计数 " + std::to_string(be32(h.data() + 8)) + "→" + std::to_string(sttsSum) + "（stts 样本和）; ";
                }
            } else if (stszCount >= 0 && stszCount != sttsSum) {
                continue;
            }
        }
        if (trakPatches.empty()) continue;
        p.patches.insert(p.patches.end(), trakPatches.begin(), trakPatches.end());
        if (p.damagedFrom < 0) { p.damagedFrom = trakPatches[0].offset; p.damagedUntil = trakPatches[0].offset + 4; }
    }
    if (!p.patches.empty()) p.kind = "mp4-table-count";
    return p;
}

struct Mp4TrackTables {
    Box trak, mdia, mdhd, hdlr, minf, stbl, stsd, stts, stsc, stsz, stco, tkhd, elst;
    bool haveMdhd = false, haveStsd = false, haveStts = false, haveStsc = false, haveStsz = false, haveStco = false, haveTkhd = false, haveElst = false;
    bool co64 = false;
    char handler[5] = {0};
};

inline bool mp4TrackTables(const Reader& read, const Box& trak, Mp4TrackTables& t, const AbortFn* abort) {
    t = Mp4TrackTables{};
    t.trak = trak;
    t.haveTkhd = mp4FindChild(read, trak, "tkhd", t.tkhd, abort);
    Box edts;
    if (mp4FindChild(read, trak, "edts", edts, abort)) t.haveElst = mp4FindChild(read, edts, "elst", t.elst, abort);
    if (!mp4FindChild(read, trak, "mdia", t.mdia, abort)) return false;
    t.haveMdhd = mp4FindChild(read, t.mdia, "mdhd", t.mdhd, abort);
    if (mp4FindChild(read, t.mdia, "hdlr", t.hdlr, abort)) {
        auto h = readSpan(read, t.hdlr.pos + t.hdlr.hdr + 8, 4);
        if (h.size() == 4) std::memcpy(t.handler, h.data(), 4);
    }
    if (!mp4FindChild(read, t.mdia, "minf", t.minf, abort) || !mp4FindChild(read, t.minf, "stbl", t.stbl, abort)) return false;
    std::vector<Box> tables;
    if (!boxChildrenClose(read, t.stbl.pos + t.stbl.hdr, t.stbl.end(), nullptr, &tables, abort)) return false;
    for (const Box& b : tables) {
        if (b.is("stsd")) { t.stsd = b; t.haveStsd = true; }
        else if (b.is("stts")) { t.stts = b; t.haveStts = true; }
        else if (b.is("stsc")) { t.stsc = b; t.haveStsc = true; }
        else if (b.is("stsz")) { t.stsz = b; t.haveStsz = true; }
        else if (b.is("stco")) { t.stco = b; t.haveStco = true; t.co64 = false; }
        else if (b.is("co64")) { t.stco = b; t.haveStco = true; t.co64 = true; }
    }
    return t.haveStsd && t.haveStts && t.haveStsc && t.haveStsz && t.haveStco;
}

inline int64_t mp4ChunkOffset(const Reader& read, const Mp4TrackTables& t, uint32_t i) {
    auto h = readSpan(read, t.stco.pos + t.stco.hdr + 4, 4);
    if (h.size() < 4 || i >= be32(h.data())) return -1;
    if (t.co64) { auto e = readSpan(read, t.stco.pos + t.stco.hdr + 8 + (int64_t)i * 8, 8); return e.size() == 8 ? (int64_t)be64(e.data()) : -1; }
    auto e = readSpan(read, t.stco.pos + t.stco.hdr + 8 + (int64_t)i * 4, 4);
    return e.size() == 4 ? (int64_t)be32(e.data()) : -1;
}

inline int64_t mp4SampleSize(const Reader& read, const Mp4TrackTables& t, uint32_t i) {
    auto h = readSpan(read, t.stsz.pos + t.stsz.hdr, 12);
    if (h.size() < 12) return -1;
    const uint32_t fixed = be32(h.data() + 4), count = be32(h.data() + 8);
    if (i >= count) return -1;
    if (fixed) return fixed;
    auto e = readSpan(read, t.stsz.pos + t.stsz.hdr + 12 + (int64_t)i * 4, 4);
    return e.size() == 4 ? (int64_t)be32(e.data()) : -1;
}

inline void mp4ReadChunkOffsets(const Reader& read, const Mp4TrackTables& t, uint32_t count, std::vector<int64_t>& out) {
    const size_t w = t.co64 ? 8 : 4;
    auto body = readSpan(read, t.stco.pos + t.stco.hdr + 8, (size_t)count * w);
    out.assign(count, -1);
    for (uint32_t i = 0; i < count && ((size_t)i + 1) * w <= body.size(); ++i)
        out[i] = t.co64 ? (int64_t)be64(body.data() + (size_t)i * 8) : (int64_t)be32(body.data() + (size_t)i * 4);
}

inline RecoveryPlan planMp4MetadataSanity(const Reader& read, int64_t fileSize, const AbortFn* abort) {
    RecoveryPlan p;
    Box moov;
    if (!mp4FindTopMoov(read, fileSize, abort, moov, /*stopAtMoof=*/true)) return p;
    std::vector<Box> kids;
    if (!boxChildrenClose(read, moov.pos + moov.hdr, moov.end(), nullptr, &kids, abort)) return p;
    uint32_t mvhdTs = 0;
    for (const Box& k : kids) {
        if (!k.is("mvhd")) continue;
        auto h = readSpan(read, k.pos + k.hdr, 24);
        if (h.size() >= 24) mvhdTs = h[0] == 1 ? be32(h.data() + 20) : be32(h.data() + 12);
    }
    std::string kinds;
    for (const Box& trak : kids) {
        if (!trak.is("trak")) continue;
        if (aborted(abort)) return p;
        Mp4TrackTables t;
        if (!mp4TrackTables(read, trak, t, abort)) continue;
        const bool video = std::memcmp(t.handler, "vide", 4) == 0;

        auto sd = readSpan(read, t.stsd.pos + t.stsd.hdr, 16);
        if (sd.size() < 16) continue;
        const uint32_t stsdCount = be32(sd.data() + 4);
        Box entry;
        const bool entryOk = stsdCount >= 1 && readBox(read, t.stsd.pos + t.stsd.hdr + 8, t.stsd.end(), entry) && entry.end() <= t.stsd.end();

        if (stsdCount == 1) {
            auto sc = readSpan(read, t.stsc.pos + t.stsc.hdr + 4, 4);
            const uint32_t n = sc.size() == 4 ? be32(sc.data()) : 0;
            const uint32_t take = mp4TableFits(t.stsc, 8, n, 12) ? std::min<uint32_t>(n, 4096) : 0;
            auto tbl = readSpan(read, t.stsc.pos + t.stsc.hdr + 8, (size_t)take * 12);
            int fixed = 0;
            for (uint32_t i = 0; i + 1 <= tbl.size() / 12; ++i) {
                if (be32(tbl.data() + i * 12 + 8) == 1) continue;
                Patch pt; pt.offset = t.stsc.pos + t.stsc.hdr + 8 + (int64_t)i * 12 + 8; putBe32(pt.bytes, 1);
                p.patches.push_back(pt); ++fixed;
            }
            if (fixed) { kinds += (kinds.empty() ? "" : "+") + std::string("mp4-stsc-desc"); p.detail += std::to_string(fixed) + " 条 stsc 引用不存在的 sample description（stsd 只有 1 项）→ 1; "; }
        }

        if (video && entryOk && stsdCount == 1 && !entry.is("encv") && entry.size > 86 + 8) {
            std::vector<Box> cfg;
            if (boxChildrenClose(read, entry.pos + 86, entry.end(), nullptr, &cfg, abort)) {
                int candidates = 0; const char* want = nullptr; int nalLen = 4; bool hevc = false, av1 = false;
                for (const Box& c : cfg) {
                    if (c.size > 64 * 1024 || c.size <= (uint64_t)c.hdr) continue;
                    auto body = readSpan(read, c.pos + c.hdr, (size_t)(c.size - c.hdr));
                    if (c.is("avcC") && avccRecordValid(body.data(), (int)body.size())) { ++candidates; want = "avc1"; nalLen = (body[4] & 3) + 1; hevc = false; }
                    else if (c.is("hvcC") && hvccRecordValid(body.data(), (int)body.size())) { ++candidates; want = "hvc1"; nalLen = body.size() >= 23 ? (body[21] & 3) + 1 : 4; hevc = true; }
                    else if (c.is("av1C") && body.size() >= 4 && body[0] == 0x81) { ++candidates; want = "av01"; av1 = true; }
                }
                const bool tagMatches = want && ((std::strcmp(want, "avc1") == 0 && (entry.is("avc1") || entry.is("avc2") || entry.is("avc3") || entry.is("avc4") || entry.is("dvav") || entry.is("dva1"))) ||
                                                 (std::strcmp(want, "hvc1") == 0 && (entry.is("hvc1") || entry.is("hev1") || entry.is("hvc2") || entry.is("hev2") || entry.is("dvh1") || entry.is("dvhe"))) ||
                                                 (std::strcmp(want, "av01") == 0 && entry.is("av01")));
                if (candidates == 1 && !tagMatches) {

                    const int64_t off0 = mp4ChunkOffset(read, t, 0), sz0 = mp4SampleSize(read, t, 0);
                    bool sampleOk = false;
                    if (off0 >= 0 && sz0 > 0 && sz0 <= 8 * 1024 * 1024 && off0 + sz0 <= fileSize) {
                        auto s = readSpan(read, off0, (size_t)sz0);
                        if ((int64_t)s.size() == sz0) {
                            if (av1) sampleOk = inspectAv1(s.data(), s.size()).structure == PacketStructure::Intact;
                            else { bool vcl = false; sampleOk = nalChainIntact(s.data(), s.size(), nalLen, hevc, &vcl) && vcl; }
                        }
                    }
                    if (sampleOk) {
                        Patch pt; pt.offset = entry.pos + 4; pt.bytes.assign(want, want + 4);
                        p.patches.push_back(pt);
                        kinds += (kinds.empty() ? "" : "+") + std::string("mp4-codec-tag");
                        p.detail += std::string("sample entry '") + std::string(entry.type, 4) + "' 与其唯一合法的配置记录（" + (av1 ? "av1C" : hevc ? "hvcC" : "avcC") + "）及首样本码流不符 → '" + want + "'; ";
                    }
                }
            }
        }

        if (video && entryOk && t.haveMdhd && t.haveTkhd && mvhdTs > 0) {
            auto mh = readSpan(read, t.mdhd.pos + t.mdhd.hdr, 32);
            auto th = readSpan(read, t.tkhd.pos + t.tkhd.hdr, 40);
            if (mh.size() >= 24 && th.size() >= 40) {
                const bool v1 = mh[0] == 1;
                const int64_t tsAt = t.mdhd.pos + t.mdhd.hdr + (v1 ? 20 : 12);
                const uint32_t mdhdTs = v1 ? be32(mh.data() + 20) : be32(mh.data() + 12);
                const uint64_t mdhdDur = v1 ? (mh.size() >= 32 ? be64(mh.data() + 24) : 0) : be32(mh.data() + 16);
                const uint64_t tkhdDur = th[0] == 1 ? be64(th.data() + 28) : be32(th.data() + 20);
                // stts
                auto sh = readSpan(read, t.stts.pos + t.stts.hdr + 4, 4);
                const uint32_t sttsN = sh.size() == 4 ? be32(sh.data()) : 0;
                auto stts = sttsN > 0 && sttsN <= 65536 && mp4TableFits(t.stts, 8, sttsN, 8)
                    ? readSpan(read, t.stts.pos + t.stts.hdr + 8, (size_t)sttsN * 8) : std::vector<uint8_t>{};
                uint64_t sampleCount = 0; bool allZero = sttsN > 0, singleDelta = sttsN > 0; uint32_t delta = 0;
                for (uint32_t i = 0; i + 1 <= stts.size() / 8; ++i) {
                    const uint32_t c = be32(stts.data() + i * 8), d = be32(stts.data() + i * 8 + 4);
                    sampleCount += c;
                    if (d != 0) allZero = false;
                    if (i == 0) delta = d; else if (d != delta) singleDelta = false;
                }

                uint32_t nu = 0, tsc = 0; bool haveFps = false;
                {
                    std::vector<Box> cfg;
                    if (entry.size > 86 + 8 && boxChildrenClose(read, entry.pos + 86, entry.end(), nullptr, &cfg, abort)) {
                        for (const Box& c : cfg) {
                            if (!c.is("avcC") || c.size > 64 * 1024) continue;
                            auto body = readSpan(read, c.pos + c.hdr, (size_t)(c.size - c.hdr));
                            if (!avccRecordValid(body.data(), (int)body.size())) continue;
                            const size_t spsLen = ((size_t)body[6] << 8) | body[7];
                            if (8 + spsLen <= body.size()) haveFps = h264SpsTiming(body.data() + 8, spsLen, nu, tsc);
                        }
                    }
                }

                double trackSec = tkhdDur > 0 ? (double)tkhdDur / mvhdTs : 0.0;
                uint64_t mediaOffset = 0;
                if (t.haveElst) {
                    auto eh = readSpan(read, t.elst.pos + t.elst.hdr, 28);
                    if (eh.size() >= 20) {
                        const uint32_t ne = be32(eh.data() + 4);
                        if (ne == 1) {
                            uint64_t seg = 0;
                            if (eh[0] == 1 && eh.size() >= 28) { seg = be64(eh.data() + 8); const int64_t mt = (int64_t)be64(eh.data() + 16); mediaOffset = mt > 0 ? (uint64_t)mt : 0; }
                            else { seg = be32(eh.data() + 8); const int32_t mt = (int32_t)be32(eh.data() + 12); mediaOffset = mt > 0 ? (uint32_t)mt : 0; }

                            const double a = (double)seg, b = (double)tkhdDur;
                            trackSec = (seg > 0 && std::fabs(a - b) <= 0.02 * std::max(a, b)) ? a / mvhdTs : 0.0;
                        } else trackSec = 0.0;
                    }
                }
                const double fps = haveFps ? (double)tsc / (2.0 * nu) : 0.0;
                auto close = [](double a, double b, double tol) { return a > 0 && b > 0 && std::fabs(a - b) <= tol * std::max(a, b); };
                if (mdhdTs == 0 && haveFps && singleDelta && delta > 0 && sampleCount > 0 && trackSec > 0) {

                    const double tsD = (double)delta * fps;
                    const uint32_t ts = (uint32_t)std::llround(tsD);
                    if (ts > 0 && std::fabs(tsD - ts) < 1e-6 * tsD + 1e-3) {
                        const double mediaSec = ((double)sampleCount * delta - (double)mediaOffset) / ts;
                        if (close(mediaSec, trackSec, 0.02)) {
                            Patch pt; pt.offset = tsAt; putBe32(pt.bytes, ts);
                            p.patches.push_back(pt);
                            kinds += (kinds.empty() ? "" : "+") + std::string("mp4-timescale");
                            p.detail += "mdhd.timescale=0 → " + std::to_string(ts) + "（stts delta " + std::to_string(delta) + " × VUI 帧率 " + std::to_string(fps) + "，与 tkhd/mvhd 轨时长 " + std::to_string(trackSec) + "s 互证）; ";
                        }
                    }
                } else if (mdhdTs > 0 && allZero && haveFps && sampleCount > 0) {

                    const double dD = (double)mdhdTs / fps;
                    const uint32_t d = (uint32_t)std::llround(dD);
                    if (d > 0 && std::fabs(dD - d) < 1e-6 * dD + 1e-3) {
                        const double byCount = (double)sampleCount * d;
                        const bool durOk = mdhdDur > 0 && std::fabs(byCount - (double)mdhdDur) <= 2.0 * d;
                        const bool trackOk = trackSec > 0 && close((byCount - (double)mediaOffset) / mdhdTs, trackSec, 0.02);
                        if (durOk && trackOk) {
                            for (uint32_t i = 0; i + 1 <= stts.size() / 8; ++i) {
                                Patch pt; pt.offset = t.stts.pos + t.stts.hdr + 8 + (int64_t)i * 8 + 4; putBe32(pt.bytes, d);
                                p.patches.push_back(pt);
                            }
                            kinds += (kinds.empty() ? "" : "+") + std::string("mp4-time-infer");
                            p.detail += "stts 全部 delta=0 → 推断 " + std::to_string(d) + "（timescale " + std::to_string(mdhdTs) + " / VUI 帧率 " + std::to_string(fps) + "，count×delta 与 mdhd.duration " + std::to_string(mdhdDur) + " 及 tkhd/mvhd 轨时长互证；时间为推断值）; ";
                        }
                    }
                }
            }
        }
    }
    if (p.patches.empty()) return p;
    p.kind = kinds;
    p.damagedFrom = p.patches.front().offset; p.damagedUntil = p.patches.front().offset + (int64_t)p.patches.front().bytes.size();
    return p;
}

inline bool mp4NalHeaderOk(const uint8_t* h, bool hevc, int& typeOut) {
    if (h[0] & 0x80) return false;
    const int type = hevc ? (h[0] >> 1) & 0x3f : (h[0] & 0x1f);
    if (hevc ? (type > 40 || (h[1] & 0x07) == 0) : (type == 0 || type > 23)) return false;
    typeOut = type;
    return true;
}

inline bool mp4WalkAccessUnits(const uint8_t* d, size_t n, int nalLen, bool hevc, std::vector<size_t>& aus) {
    aus.clear();
    size_t off = 0, auStart = 0;
    bool seenVcl = false;
    while (off < n) {
        if (n - off < (size_t)nalLen + 2) return false;
        uint32_t len = 0;
        for (int i = 0; i < nalLen; ++i) len = (len << 8) | d[off + (size_t)i];
        if (len < 2 || len > n - off - (size_t)nalLen) return false;
        const uint8_t* h = d + off + (size_t)nalLen;
        int type = 0;
        if (!mp4NalHeaderOk(h, hevc, type)) return false;
        const bool vcl = hevc ? type <= 31 : (type >= 1 && type <= 5);
        bool startsNew = false;
        if (seenVcl) {
            if (!vcl) startsNew = hevc ? ((type >= 32 && type <= 35) || type == 39) : (type == 9 || type == 7 || type == 8 || type == 6);
            else startsNew = detail::firstSliceHeaderPlausible(h, len, hevc);
        }
        if (startsNew) { aus.push_back(off - auStart); auStart = off; seenVcl = false; }
        if (vcl) seenVcl = true;
        off += (size_t)nalLen + len;
    }
    if (off != n) return false;
    aus.push_back(n - auStart);
    return true;
}

inline bool mp4SizesChain(const uint8_t* d, size_t n, const std::vector<uint32_t>& sizes, size_t from, size_t count, int nalLen, bool hevc) {
    size_t off = 0;
    for (size_t s = from; s < from + count; ++s) {
        const size_t sz = sizes[s];
        if (sz == 0 || off + sz > n) return false;
        bool vcl = false;
        if (!nalChainIntact(d + off, sz, nalLen, hevc, &vcl)) return false;
        off += sz;
    }
    return off == n;
}

inline RecoveryPlan planMp4SampleTables(const Reader& read, int64_t fileSize, const AbortFn* abort) {
    RecoveryPlan p;
    int64_t pos = 0;
    Box moov;
    bool haveMoov = false;
    std::vector<int64_t> bounds;
    for (int hops = 0; hops < 64 && pos + 8 <= fileSize; ++hops) {
        if (aborted(abort)) return p;
        Box b;
        if (!readBox(read, pos, fileSize, b) || b.end() > fileSize) break;
        if (b.is("moov")) { moov = b; haveMoov = true; }
        if (b.is("moof")) return p;
        if (b.is("mdat")) bounds.push_back(b.end());
        if (b.sizeFieldZero || b.largeSizeZero) break;
        pos = b.end();
    }
    if (!haveMoov) return p;
    bounds.push_back(fileSize);
    std::vector<Box> kids;
    if (!boxChildrenClose(read, moov.pos + moov.hdr, moov.end(), nullptr, &kids, abort)) return p;
    constexpr uint32_t kMax = 16384;

    std::vector<Mp4TrackTables> all;
    for (const Box& trak : kids) {
        if (!trak.is("trak")) continue;
        Mp4TrackTables t;
        if (!mp4TrackTables(read, trak, t, abort)) continue;
        auto ch = readSpan(read, t.stco.pos + t.stco.hdr + 4, 4);
        const uint32_t nc = ch.size() == 4 ? be32(ch.data()) : 0;
        if (nc > kMax) return p;
        std::vector<int64_t> offs;
        mp4ReadChunkOffsets(read, t, nc, offs);
        for (const int64_t o : offs) if (o > 0 && o < fileSize) bounds.push_back(o);
        all.push_back(t);
    }
    std::sort(bounds.begin(), bounds.end());
    bounds.erase(std::unique(bounds.begin(), bounds.end()), bounds.end());
    auto nextBound = [&](int64_t o) -> int64_t { auto it = std::upper_bound(bounds.begin(), bounds.end(), o); return it == bounds.end() ? fileSize : *it; };
    for (const Mp4TrackTables& t : all) {
        if (std::memcmp(t.handler, "vide", 4) != 0) continue;
        if (aborted(abort)) return p;

        auto sd = readSpan(read, t.stsd.pos + t.stsd.hdr, 8);
        if (sd.size() < 8 || be32(sd.data() + 4) != 1) continue;
        Box entry;
        if (!readBox(read, t.stsd.pos + t.stsd.hdr + 8, t.stsd.end(), entry) || entry.size <= 86 + 8) continue;
        std::vector<Box> cfg;
        if (!boxChildrenClose(read, entry.pos + 86, entry.end(), nullptr, &cfg, abort)) continue;
        int nalLen = 0; bool hevc = false;
        for (const Box& c : cfg) {
            if (c.size > 64 * 1024 || c.size <= (uint64_t)c.hdr) continue;
            auto body = readSpan(read, c.pos + c.hdr, (size_t)(c.size - c.hdr));
            if (c.is("avcC") && avccRecordValid(body.data(), (int)body.size())) { nalLen = (body[4] & 3) + 1; hevc = false; }
            else if (c.is("hvcC") && hvccRecordValid(body.data(), (int)body.size()) && body.size() >= 23) { nalLen = (body[21] & 3) + 1; hevc = true; }
        }
        if (nalLen == 0) continue;

        auto zh = readSpan(read, t.stsz.pos + t.stsz.hdr, 12);
        if (zh.size() < 12 || be32(zh.data() + 4) != 0) continue;
        const uint32_t sampleCount = be32(zh.data() + 8);
        if (sampleCount == 0 || sampleCount > kMax || !mp4TableFits(t.stsz, 12, sampleCount, 4)) continue;
        auto ztbl = readSpan(read, t.stsz.pos + t.stsz.hdr + 12, (size_t)sampleCount * 4);
        if (ztbl.size() != (size_t)sampleCount * 4) continue;
        std::vector<uint32_t> sizes(sampleCount);
        for (uint32_t i = 0; i < sampleCount; ++i) sizes[i] = be32(ztbl.data() + i * 4);
        auto ch = readSpan(read, t.stco.pos + t.stco.hdr + 4, 4);
        const uint32_t chunkCount = ch.size() == 4 ? be32(ch.data()) : 0;
        if (chunkCount == 0 || chunkCount > kMax || !mp4TableFits(t.stco, 8, chunkCount, t.co64 ? 8 : 4)) continue;
        std::vector<int64_t> offsets;
        mp4ReadChunkOffsets(read, t, chunkCount, offsets);
        auto sh = readSpan(read, t.stsc.pos + t.stsc.hdr + 4, 4);
        const uint32_t stscN = sh.size() == 4 ? be32(sh.data()) : 0;
        if (stscN == 0 || stscN > kMax || !mp4TableFits(t.stsc, 8, stscN, 12)) continue;
        auto stbl = readSpan(read, t.stsc.pos + t.stsc.hdr + 8, (size_t)stscN * 12);
        if (stbl.size() != (size_t)stscN * 12) continue;
        struct StscRun { uint32_t first, count, id; };
        std::vector<StscRun> runs(stscN);
        for (uint32_t i = 0; i < stscN; ++i) runs[i] = {be32(stbl.data() + i * 12), be32(stbl.data() + i * 12 + 4), be32(stbl.data() + i * 12 + 8)};

        std::vector<uint32_t> perChunk(chunkCount, 0);
        {
            bool ok = true;
            for (uint32_t r = 0; r < stscN && ok; ++r) {
                const uint32_t from = runs[r].first, to = r + 1 < stscN ? runs[r + 1].first : chunkCount + 1;
                if (from < 1 || from > to || to > chunkCount + 1) { ok = false; break; }
                for (uint32_t c = from; c < to; ++c) perChunk[c - 1] = runs[r].count;
            }
            if (!ok) continue;
        }
        uint64_t declaredTotal = 0;
        for (uint32_t c : perChunk) declaredTotal += c;

        struct ChunkBytes { int64_t off; std::vector<uint8_t> bytes; };
        std::vector<ChunkBytes> cb(chunkCount);
        int64_t budget = 64ll * 1024 * 1024;
        bool readOk = true;
        for (uint32_t c = 0; c < chunkCount && readOk; ++c) {
            if (aborted(abort)) return p;
            const int64_t o = offsets[c];
            if (o <= 0 || o >= fileSize) { readOk = false; break; }
            const int64_t lim = nextBound(o);
            const int64_t len = std::min<int64_t>(lim - o + 8, fileSize - std::max<int64_t>(0, o - 8));
            if (len <= 0 || (budget -= len) < 0) { readOk = false; break; }
            cb[c].off = std::max<int64_t>(0, o - 8);
            cb[c].bytes = readSpan(read, cb[c].off, (size_t)len);
            if ((int64_t)cb[c].bytes.size() != len) { readOk = false; break; }
        }
        if (!readOk) continue;
        auto chunkView = [&](uint32_t c, int64_t at, const uint8_t*& d, size_t& n) -> bool {
            const int64_t lim = nextBound(offsets[c]);
            if (at < cb[c].off || at >= lim || at + 1 > cb[c].off + (int64_t)cb[c].bytes.size()) return false;
            d = cb[c].bytes.data() + (at - cb[c].off);
            n = (size_t)std::min<int64_t>(lim - at, cb[c].off + (int64_t)cb[c].bytes.size() - at);
            return true;
        };
        int hypotheses = 0;
        RecoveryPlan best;
        // H1：stco
        if (declaredTotal == sampleCount) {
            std::vector<Patch> patches; bool ok = true; uint32_t s = 0;
            for (uint32_t c = 0; c < chunkCount && ok; ++c) {
                const uint8_t* d = nullptr; size_t n = 0;
                uint64_t need = 0; for (uint32_t k = 0; k < perChunk[c]; ++k) need += sizes[s + k];
                auto closesAt = [&](int64_t at) -> bool { return chunkView(c, at, d, n) && need <= n && mp4SizesChain(d, (size_t)need, sizes, s, perChunk[c], nalLen, hevc); };
                if (perChunk[c] > 0 && !closesAt(offsets[c])) {
                    int hits = 0; int64_t hit = 0;
                    for (int64_t delta = -8; delta <= 8; ++delta) { if (delta != 0 && closesAt(offsets[c] + delta)) { ++hits; hit = offsets[c] + delta; } }
                    if (hits != 1) { ok = false; break; }
                    Patch pt; pt.offset = t.stco.pos + t.stco.hdr + 8 + (int64_t)c * (t.co64 ? 8 : 4);
                    if (t.co64) putBe64(pt.bytes, (uint64_t)hit); else putBe32(pt.bytes, (uint32_t)hit);
                    patches.push_back(pt);
                }
                s += perChunk[c];
            }
            if (ok && !patches.empty()) { ++hypotheses; best.patches = patches; best.kind = "mp4-stco-entries"; best.detail = std::to_string(patches.size()) + " 个 chunk 偏移在 ±8 字节内唯一重锚定（声明的样本长度链闭合）; "; }
        }

        {
            std::vector<std::vector<size_t>> aus(chunkCount);
            bool walkOk = true;
            for (uint32_t c = 0; c < chunkCount && walkOk; ++c) {
                const uint8_t* d = nullptr; size_t n = 0;
                if (!chunkView(c, offsets[c], d, n) || !mp4WalkAccessUnits(d, n, nalLen, hevc, aus[c])) walkOk = false;
            }
            if (walkOk) {

                if (declaredTotal == sampleCount) {
                    std::vector<Patch> patches; bool ok = true; uint32_t s = 0;
                    for (uint32_t c = 0; c < chunkCount && ok; ++c) {
                        if (aus[c].size() != perChunk[c]) { ok = false; break; }
                        for (uint32_t k = 0; k < perChunk[c]; ++k) {
                            if (sizes[s + k] == aus[c][k]) continue;
                            Patch pt; pt.offset = t.stsz.pos + t.stsz.hdr + 12 + (int64_t)(s + k) * 4; putBe32(pt.bytes, (uint32_t)aus[c][k]);
                            patches.push_back(pt);
                        }
                        s += perChunk[c];
                    }
                    if (ok && !patches.empty()) { ++hypotheses; best.patches = patches; best.kind = "mp4-stsz-entries"; best.detail = std::to_string(patches.size()) + " 个样本长度按 AU 边界重建（chunk 走查闭合到物理边界，AU 数与声明一致）; "; }
                }

                {
                    bool ok = true; uint32_t s = 0; bool differs = false;
                    for (uint32_t c = 0; c < chunkCount && ok; ++c) {
                        for (size_t k = 0; k < aus[c].size(); ++k) { if (s >= sampleCount || sizes[s] != aus[c][k]) { ok = false; break; } ++s; }
                        if (aus[c].size() != perChunk[c]) differs = true;
                    }
                    if (ok && s == sampleCount && differs) {
                        std::vector<StscRun> nr;
                        for (uint32_t c = 0; c < chunkCount; ++c) {
                            const uint32_t cnt = (uint32_t)aus[c].size();
                            if (nr.empty() || nr.back().count != cnt) nr.push_back({c + 1, cnt, 1});
                        }
                        const size_t slots = (size_t)((t.stsc.size - t.stsc.hdr - 8) / 12);
                        if (nr.size() <= slots) {
                            std::vector<Patch> patches;
                            Patch cnt; cnt.offset = t.stsc.pos + t.stsc.hdr + 4; putBe32(cnt.bytes, (uint32_t)nr.size()); patches.push_back(cnt);
                            Patch body; body.offset = t.stsc.pos + t.stsc.hdr + 8;
                            for (const StscRun& r : nr) { putBe32(body.bytes, r.first); putBe32(body.bytes, r.count); putBe32(body.bytes, 1); }
                            patches.push_back(body);
                            ++hypotheses; best.patches = patches; best.kind = "mp4-stsc-entries"; best.detail = "stsc 按各 chunk 实际 AU 数重写为 " + std::to_string(nr.size()) + " 段（AU 长度序列与 stsz 一致）; ";
                        }
                    }
                }
            }
        }
        if (hypotheses != 1) continue;
        p.patches.insert(p.patches.end(), best.patches.begin(), best.patches.end());
        p.kind = p.kind.empty() ? best.kind : p.kind + "+" + best.kind;
        p.detail += best.detail;
        if (p.damagedFrom < 0) { p.damagedFrom = best.patches.front().offset; p.damagedUntil = best.patches.back().offset + (int64_t)best.patches.back().bytes.size(); }
    }
    return p;
}

inline RecoveryPlan planFmp4Chain(const Reader& read, int64_t fileSize, const AbortFn* abort) {
    RecoveryPlan p;
    int64_t pos = 0;
    bool sawMoof = false;
    const int64_t window = 64ll * 1024 * 1024;
    const std::vector<uint32_t> trackIds = mp4ReadTrackIds(read, fileSize, abort);
    for (int hops = 0; hops < 200000 && pos + 8 <= fileSize && p.patches.size() < 16; ++hops) {
        if (aborted(abort)) return p;
        Box b;
        const bool ok = readBox(read, pos, fileSize, b);
        if (ok && b.is("moof")) {
            sawMoof = true;
            int64_t end = 0;
            bool inner = false;
            const bool outerOk = !b.sizeFieldZero && !b.largeSizeZero && b.end() <= fileSize &&
                                 validateMoof(read, pos, fileSize, abort, &end, &trackIds, &inner);
            if (outerOk && inner) {
                pos = end;
                continue;
            }

            if (!outerOk) {
                int64_t cur = pos + b.hdr;
                std::vector<Box> kids;
                bool chain = true;
                for (int k = 0; k < 64; ++k) {
                    Box c;
                    if (!readBox(read, cur, fileSize, c) || c.sizeFieldZero || c.largeSizeZero) { chain = false; break; }
                    if (c.is("mdat")) break;
                    if (k == 0 && !(c.is("mfhd") && c.size == 16)) { chain = false; break; }
                    kids.push_back(c);
                    cur = c.end();
                    if (cur >= fileSize) { chain = false; break; }
                }
                if (chain && !kids.empty() && cur - pos <= 64ll * 1024 * 1024) {
                    Patch pt;
                    pt.offset = pos;
                    putBe32(pt.bytes, (uint32_t)(cur - pos));
                    p.patches.push_back(pt);
                    if (p.damagedFrom < 0) { p.damagedFrom = pos; p.damagedUntil = pos + b.hdr; }
                    p.detail += "moof@" + std::to_string(pos) + " 长度校正; ";
                    pos = cur;
                    continue;
                }
            }

            const int64_t next = findNextValidMoof(read, pos + 8, fileSize, window, abort, &trackIds);
            if (next < 0 || next - pos < 8) return p;
            Patch pt;
            pt.offset = pos;
            putBe32(pt.bytes, (uint32_t)(next - pos));
            pt.bytes.insert(pt.bytes.end(), {'f', 'r', 'e', 'e'});
            p.patches.push_back(pt);
            if (p.damagedFrom < 0) { p.damagedFrom = pos; p.damagedUntil = next; }
            p.detail += std::string(outerOk ? "片段@" : "断链片段@") + std::to_string(pos) + " 屏蔽到 " + std::to_string(next) +
                        (outerOk ? "（traf 内层语义坏）; " : "; ");
            pos = next;
            continue;
        }
        if (ok && b.is("mdat") && (b.sizeFieldZero || b.largeSizeZero) && sawMoof) {

            const int64_t next = findNextValidMoof(read, pos + b.hdr, fileSize, window, abort, &trackIds);
            if (next < 0) return p;
            Patch pt;
            if (b.hdr == 16) { pt.offset = pos + 8; putBe64(pt.bytes, (uint64_t)(next - pos)); }
            else {
                if ((uint64_t)(next - pos) > 0xFFFFFFFFull) return p;
                pt.offset = pos; putBe32(pt.bytes, (uint32_t)(next - pos));
            }
            p.patches.push_back(pt);
            if (p.damagedFrom < 0) { p.damagedFrom = pos; p.damagedUntil = pos + b.hdr; }
            p.detail += "mdat@" + std::to_string(pos) + " 长度校正; ";
            pos = next;
            continue;
        }
        if (ok && !b.sizeFieldZero && !b.largeSizeZero && b.end() <= fileSize) {
            pos = b.end();
            continue;
        }
        if (ok && (b.sizeFieldZero || b.largeSizeZero)) break;

        if (!sawMoof) return p;
        const int64_t next = findNextValidMoof(read, pos + 1, fileSize, window, abort, &trackIds);
        if (next < 0 || next - pos < 8) return p;
        Patch pt;
        pt.offset = pos;
        putBe32(pt.bytes, (uint32_t)(next - pos));
        pt.bytes.insert(pt.bytes.end(), {'f', 'r', 'e', 'e'});
        p.patches.push_back(pt);
        if (p.damagedFrom < 0) { p.damagedFrom = pos; p.damagedUntil = next; }
        p.detail += "垃圾区@" + std::to_string(pos) + " 屏蔽到 " + std::to_string(next) + "; ";
        pos = next;
    }
    if (!p.patches.empty()) p.kind = "fmp4-chain";
    return p;
}

struct Fmp4Run {
    int64_t trunPos = 0;
    int trunHdr = 8;
    int64_t base = 0;
    int64_t declaredStart = 0;
    std::vector<uint32_t> sizes;

    int64_t tfhdPos = 0;
    int64_t sizeFieldBase = -1;
    size_t sizeStride = 0;
    bool hasCto = false;
};

inline bool fmp4VideoRuns(const Reader& read, const Box& moof, uint32_t trackId, std::vector<Fmp4Run>& runs, const AbortFn* abort) {

    if (moof.size > 64ll * 1024 * 1024) return false;
    constexpr int64_t kTfhdMax = 4096;
    constexpr int64_t kTrunMax = 16ll * 1024 * 1024 + 64;
    std::vector<Box> kids;
    if (!boxChildrenClose(read, moof.pos + moof.hdr, moof.end(), nullptr, &kids, abort)) return false;
    bool firstTraf = true;
    for (const Box& t : kids) {
        if (!t.is("traf")) continue;
        std::vector<Box> tk;
        if (!boxChildrenClose(read, t.pos + t.hdr, t.end(), nullptr, &tk, abort)) return false;
        int64_t base = -1, tfhdPos = 0;
        uint32_t tid = 0, defSize = 0;
        bool have = false, match = false;
        for (const Box& c : tk) {
            if (c.is("tfhd")) {
                tfhdPos = c.pos;
                if (c.size - c.hdr > kTfhdMax) return false;
                auto h = readSpan(read, c.pos + c.hdr, (size_t)(c.size - c.hdr));
                if (h.size() < 8) return false;
                const uint32_t flags = be32(h.data()) & 0xFFFFFF;
                tid = be32(h.data() + 4);
                size_t off = 8;
                if (flags & 1) { if (h.size() < off + 8) return false; base = (int64_t)be64(h.data() + off); off += 8; }
                if (flags & 2) off += 4;
                if (flags & 8) off += 4;
                if (flags & 0x10) { if (h.size() < off + 4) return false; defSize = be32(h.data() + off); off += 4; }
                if (base < 0 && ((flags & 0x020000) || firstTraf)) base = moof.pos;
                have = true;
                match = tid == trackId;
            } else if (c.is("trun") && have && match) {
                if (base < 0) return false;
                if (c.size - c.hdr > kTrunMax) return false;
                auto h = readSpan(read, c.pos + c.hdr, (size_t)(c.size - c.hdr));
                if (h.size() < 8) return false;
                const uint32_t flags = be32(h.data()) & 0xFFFFFF;
                const uint32_t count = be32(h.data() + 4);
                if (!(flags & 1)) continue;
                size_t off = 8;
                if (h.size() < off + 4) return false;
                const int32_t dataOffset = (int32_t)be32(h.data() + off);
                off += 4;
                if (flags & 4) off += 4;
                Fmp4Run r;
                r.trunPos = c.pos; r.trunHdr = c.hdr; r.base = base; r.declaredStart = base + dataOffset; r.tfhdPos = tfhdPos;
                if (count > 1u << 20) return false;
                r.sizeStride = (flags & 0x100 ? 4 : 0) + (flags & 0x200 ? 4 : 0) + (flags & 0x400 ? 4 : 0) + (flags & 0x800 ? 4 : 0);
                r.sizeFieldBase = (flags & 0x200) ? c.pos + c.hdr + (int64_t)off + (flags & 0x100 ? 4 : 0) : -1;
                for (uint32_t i = 0; i < count; ++i) {
                    if (flags & 0x100) off += 4;
                    uint32_t sz = defSize;
                    if (flags & 0x200) { if (h.size() < off + 4) return false; sz = be32(h.data() + off); off += 4; }
                    if (flags & 0x400) off += 4;
                    if (flags & 0x800) { if (h.size() < off + 4) return false; if (be32(h.data() + off) != 0) r.hasCto = true; off += 4; }
                    if (sz == 0) return false;
                    r.sizes.push_back(sz);
                }
                if (off > h.size()) return false;
                runs.push_back(std::move(r));
            }
        }
        firstTraf = false;
    }
    return true;
}

inline bool fmp4RunChainsAt(const uint8_t* buf, size_t bufLen, int64_t bufStart, int64_t start, const std::vector<uint32_t>& sizes,
                            size_t maxSamples, int nalLen, bool hevc, bool* vclOut) {
    int64_t q = start;
    bool vcl = false;
    for (size_t i = 0; i < sizes.size() && i < maxSamples; ++i) {
        if (q < bufStart || q + (int64_t)sizes[i] > bufStart + (int64_t)bufLen) return false;
        bool v = false;
        if (!nalChainIntact(buf + (q - bufStart), sizes[i], nalLen, hevc, &v)) return false;
        vcl = vcl || v;
        q += sizes[i];
    }
    if (vclOut) *vclOut = vcl;
    return true;
}

inline int fmp4RealignMoof(const Reader& read, int64_t fileSize, const Box& moof, const Box& mdat, uint32_t trackId, int nalLen, bool hevc,
                           std::vector<Patch>& patches, const AbortFn* abort, int* sizeFixes = nullptr) {
    std::vector<Fmp4Run> runs;
    if (!fmp4VideoRuns(read, moof, trackId, runs, abort) || runs.empty()) return 0;
    const int64_t dataFrom = mdat.pos + mdat.hdr, dataTo = std::min(mdat.end(), fileSize);
    if (dataTo - dataFrom <= 0 || dataTo - dataFrom > 64ll * 1024 * 1024) return 0;
    std::vector<uint8_t> buf;
    int realigned = 0;

    std::vector<int64_t> allStarts;
    {
        std::vector<Box> mk;
        if (boxChildrenClose(read, moof.pos + moof.hdr, moof.end(), nullptr, &mk, abort)) {
            for (const Box& t : mk) {
                if (!t.is("traf")) continue;
                Box tfhd;
                if (!mp4FindChild(read, t, "tfhd", tfhd, abort)) continue;
                auto h = readSpan(read, tfhd.pos + tfhd.hdr, 8);
                if (h.size() < 8) continue;
                const uint32_t tid = be32(h.data() + 4);
                if (tid == trackId) continue;
                std::vector<Fmp4Run> other;
                if (fmp4VideoRuns(read, moof, tid, other, abort)) for (const Fmp4Run& o : other) allStarts.push_back(o.declaredStart);
            }
        }
        for (const Fmp4Run& o : runs) allStarts.push_back(o.declaredStart);
    }
    for (const Fmp4Run& r : runs) {
        int64_t total = 0;
        for (uint32_t s : r.sizes) total += s;
        bool vcl = false;
        {
            const size_t head = (size_t)std::min<int64_t>(total, 1 << 20);
            auto probe = readSpan(read, r.declaredStart, head);
            if ((int64_t)probe.size() == (int64_t)head &&
                fmp4RunChainsAt(probe.data(), probe.size(), r.declaredStart, r.declaredStart, r.sizes, 3, nalLen, hevc, &vcl)) {

                if (r.declaredStart < dataFrom || r.declaredStart + total > dataTo) continue;
                auto run = readSpan(read, r.declaredStart, (size_t)total);
                if ((int64_t)run.size() != total) continue;
                size_t k = 0; int64_t q = 0; bool broken = false;
                for (; k < r.sizes.size(); ++k) { bool v = false; if (!nalChainIntact(run.data() + q, r.sizes[k], nalLen, hevc, &v)) { broken = true; break; } q += r.sizes[k]; }
                if (!broken || k < 3 || r.sizeFieldBase < 0) continue;
                int64_t runEnd = dataTo;
                for (int64_t s : allStarts) if (s > r.declaredStart && s < runEnd) runEnd = s;
                const int64_t before = q;
                int nCand = 0; uint32_t candSize = 0;
                for (int bit = 0; bit < 32 && nCand < 2; ++bit) {
                    const uint32_t c = r.sizes[k] ^ (1u << bit);
                    if (c == 0) continue;
                    const int64_t newTotal = total - (int64_t)r.sizes[k] + (int64_t)c;
                    if (r.declaredStart + newTotal != runEnd) continue;
                    auto rest = readSpan(read, r.declaredStart + before, (size_t)(newTotal - before));
                    if ((int64_t)rest.size() != newTotal - before) continue;
                    std::vector<uint32_t> sz(r.sizes.begin() + (long)k, r.sizes.end());
                    sz[0] = c;
                    bool v = false;
                    if (!fmp4RunChainsAt(rest.data(), rest.size(), 0, 0, sz, sz.size(), nalLen, hevc, &v)) continue;
                    ++nCand; candSize = c;
                }
                if (nCand != 1) return -1;
                Patch pt;
                pt.offset = r.sizeFieldBase + (int64_t)(k * r.sizeStride);
                putBe32(pt.bytes, candSize);
                patches.push_back(pt);
                ++realigned;
                if (sizeFixes) ++*sizeFixes;
                continue;
            }
        }
        if (buf.empty()) {
            buf = readSpan(read, dataFrom, (size_t)(dataTo - dataFrom));
            if ((int64_t)buf.size() != dataTo - dataFrom) return -1;
        }
        int64_t cand = -1;
        int nCand = 0;
        for (int64_t c = dataFrom; c + total <= dataTo && nCand < 2; ++c) {
            if ((c & 0xFFFF) == 0 && aborted(abort)) return -1;
            if (!fmp4RunChainsAt(buf.data(), buf.size(), dataFrom, c, r.sizes, 3, nalLen, hevc, &vcl) || !vcl) continue;
            cand = c;
            ++nCand;
        }
        if (nCand != 1) return -1;
        if (!fmp4RunChainsAt(buf.data(), buf.size(), dataFrom, cand, r.sizes, r.sizes.size(), nalLen, hevc, nullptr)) return -1;
        const int64_t newOff = cand - r.base;
        if (newOff < INT32_MIN || newOff > INT32_MAX) return -1;
        Patch pt;
        pt.offset = r.trunPos + r.trunHdr + 8;
        putBe32(pt.bytes, (uint32_t)(int32_t)newOff);
        patches.push_back(pt);
        ++realigned;
    }
    return realigned > 0 ? 1 : 0;
}

inline RecoveryPlan planFmp4Realign(const Reader& read, int64_t fileSize, int64_t samplePos, uint32_t trackId, int nalLen, bool hevc,
                                    const AbortFn* abort) {
    RecoveryPlan p;
    if (nalLen < 1 || nalLen > 4 || samplePos < 0) return p;
    int64_t pos = 0;
    Box moof;
    bool haveMoof = false, found = false;
    int fragments = 0, realignedFrags = 0, sizeFixes = 0;
    int64_t budget = 256ll * 1024 * 1024, firstMoof = -1, lastEnd = -1;
    for (int hops = 0; hops < 65536 && pos + 8 <= fileSize; ++hops) {
        if (aborted(abort)) return p;
        Box b;
        if (!readBox(read, pos, fileSize, b) || b.sizeFieldZero || b.largeSizeZero || b.end() > fileSize) break;
        if (b.is("moof")) { moof = b; haveMoof = true; }
        else if (b.is("mdat") && haveMoof) {
            if (!found && samplePos >= b.pos && samplePos < b.end()) found = true;
            if (found) {
                if (fragments >= 64 || budget < (int64_t)b.size) break;
                budget -= (int64_t)b.size;
                ++fragments;
                const int r = fmp4RealignMoof(read, fileSize, moof, b, trackId, nalLen, hevc, p.patches, abort, &sizeFixes);
                if (r < 0) { if (fragments == 1) { p.patches.clear(); return p; } break; }
                if (r > 0) { ++realignedFrags; if (firstMoof < 0) firstMoof = moof.pos; lastEnd = b.end(); }
            }
            haveMoof = false;
        }
        pos = b.end();
    }
    if (!found || realignedFrags == 0) { p.patches.clear(); return p; }
    p.kind = "fmp4-realign";
    p.detail = sizeFixes > 0 && sizeFixes == (int)p.patches.size()
                   ? "Validated video run start with a broken sample chain: repaired " + std::to_string(sizeFixes) + " sample_size fields using unique single-bit candidates that align the run end with the next run or mdat boundary; all subsequent samples validate"
                   : "视频 trun 声明起点的样本链不闭合，mdat 内唯一重锚定 " + std::to_string(realignedFrags) + "/" + std::to_string(fragments) +
                         " 片（整 run 样本链已验证）：覆盖 data_offset" + (sizeFixes > 0 ? "，另 " + std::to_string(sizeFixes) + " 条 sample_size 单比特改回" : "");
    p.damagedFrom = firstMoof; p.damagedUntil = lastEnd;
    return p;
}

struct Mp4CttsPlan {
    bool candidate = false;
    spresil::Mp4CttsCandidate c;
    int64_t patchOffset = -1;
    bool version1 = false;
    std::vector<int64_t> dts, cts, ctsNew;
    std::vector<std::pair<int64_t, uint32_t>> samples;
    std::vector<uint8_t> keyframe;
    uint32_t timescale = 0;
    std::string detail;
    int screen = 0;
};

inline bool mp4ReadFullBox(const Reader& read, const Box& b, std::vector<uint8_t>& out, size_t cap = 64u * 1024 * 1024) {
    if (b.size < (uint64_t)b.hdr + 4 || b.size > cap) return false;
    out = readSpan(read, b.pos + b.hdr, (size_t)(b.size - (uint64_t)b.hdr));
    return out.size() == (size_t)(b.size - (uint64_t)b.hdr);
}

inline Mp4CttsPlan planMp4CttsReorder(const Reader& read, int64_t fileSize, const AbortFn* abort) {
    Mp4CttsPlan plan;
    Box moov;
    if (!mp4FindTopMoov(read, fileSize, abort, moov, /*stopAtMoof=*/true)) return plan;
    std::vector<Box> kids;
    if (!boxChildrenClose(read, moov.pos + moov.hdr, moov.end(), nullptr, &kids, abort)) return plan;
    Mp4TrackTables t; bool haveVideo = false;
    for (const Box& k : kids) {
        if (!k.is("trak")) continue;
        Mp4TrackTables tt;
        if (!mp4TrackTables(read, k, tt, abort) || std::memcmp(tt.handler, "vide", 4) != 0) continue;
        if (haveVideo) return plan;
        t = tt; haveVideo = true;
    }
    if (!haveVideo) return plan;
    Box ctts;
    if (!mp4FindChild(read, t.stbl, "ctts", ctts, abort)) return plan;

    std::vector<uint8_t> sttsB, cttsB, stszB, stscB, stcoB, stssB, mdhdB;
    if (!mp4ReadFullBox(read, t.stts, sttsB) || !mp4ReadFullBox(read, ctts, cttsB)) return plan;
    if (sttsB.size() < 8 || cttsB.size() < 8) return plan;
    const uint32_t sttsN = be32(sttsB.data() + 4), cttsN = be32(cttsB.data() + 4);
    if (sttsB.size() < 8 + 8ull * sttsN || cttsB.size() < 8 + 8ull * cttsN || cttsN == 0 || cttsN > 2000000) return plan;
    plan.version1 = cttsB[0] == 1;

    {
        uint64_t samples = 0; uint32_t minDelta = UINT32_MAX;
        for (uint32_t i = 0; i < sttsN; ++i) {
            const uint32_t cnt = be32(sttsB.data() + 8 + 8 * i), d = be32(sttsB.data() + 12 + 8 * i);
            if (cnt > 0) { samples += cnt; minDelta = std::min(minDelta, d); }
        }
        int64_t lo = INT64_MAX, hi = INT64_MIN;
        for (uint32_t i = 0; i < cttsN; ++i) {
            const uint32_t raw = be32(cttsB.data() + 12 + 8 * i);
            const int64_t v = plan.version1 ? (int64_t)(int32_t)raw : (int64_t)raw;
            lo = std::min(lo, v); hi = std::max(hi, v);
        }
        if (samples > 0 && samples <= 4000000 && (int64_t)minDelta * 17 >= hi - lo) { plan.screen = 1; return plan; }
    }
    std::vector<std::pair<uint32_t, uint32_t>> runs;
    runs.reserve(cttsN);
    for (uint32_t i = 0; i < cttsN; ++i) runs.push_back({be32(cttsB.data() + 8 + 8 * i), be32(cttsB.data() + 12 + 8 * i)});
    std::vector<uint32_t> deltas;
    for (uint32_t i = 0; i < sttsN; ++i) {
        const uint32_t cnt = be32(sttsB.data() + 8 + 8 * i), d = be32(sttsB.data() + 12 + 8 * i);
        if (deltas.size() + cnt > 4000000) return plan;
        deltas.insert(deltas.end(), cnt, d);
    }
    if (abort && *abort && (*abort)()) return plan;

    if (mp4CttsConflictImpossible(deltas, mp4CttsOffsetSpan(runs, plan.version1), 16)) { plan.screen = 2; return plan; }
    plan.screen = 3;
    if (!spresil::mp4CttsSingleBitCandidate(deltas, runs, plan.version1, 16, plan.c, abort)) return plan;
    if (!mp4ReadFullBox(read, t.stsz, stszB) || !mp4ReadFullBox(read, t.stsc, stscB) || !mp4ReadFullBox(read, t.stco, stcoB)) return plan;
    if (t.haveMdhd && mp4ReadFullBox(read, t.mdhd, mdhdB) && mdhdB.size() >= 20) plan.timescale = mdhdB[0] == 1 ? be32(mdhdB.data() + 20) : be32(mdhdB.data() + 12);
    if (stszB.size() < 12 || stscB.size() < 8 || stcoB.size() < 8) return plan;

    const uint32_t fixedSize = be32(stszB.data() + 4), count = be32(stszB.data() + 8);
    if (count != deltas.size() || (fixedSize == 0 && stszB.size() < 12 + 4ull * count)) return plan;
    const uint32_t stscN = be32(stscB.data() + 4), chunks = be32(stcoB.data() + 4);
    if (stscB.size() < 8 + 12ull * stscN || stcoB.size() < 8 + (t.co64 ? 8ull : 4ull) * chunks || stscN == 0) return plan;
    plan.samples.reserve(count);
    uint32_t idx = 0;
    for (uint32_t ci = 1; ci <= chunks && idx < count; ++ci) {
        uint32_t per = 0;
        for (uint32_t r = 0; r < stscN; ++r) { if (be32(stscB.data() + 8 + 12 * r) <= ci) per = be32(stscB.data() + 12 + 12 * r); else break; }
        int64_t off = t.co64 ? (int64_t)be64(stcoB.data() + 8 + 8 * (ci - 1)) : (int64_t)be32(stcoB.data() + 8 + 4 * (ci - 1));
        for (uint32_t k = 0; k < per && idx < count; ++k, ++idx) {
            const uint32_t sz = fixedSize ? fixedSize : be32(stszB.data() + 12 + 4 * idx);
            plan.samples.push_back({off, sz});
            off += sz;
        }
    }
    if (plan.samples.size() != count) return plan;
    Box stss;
    if (mp4FindChild(read, t.stbl, "stss", stss, abort) && mp4ReadFullBox(read, stss, stssB) && stssB.size() >= 8) {
        const uint32_t sn = be32(stssB.data() + 4);
        if (stssB.size() >= 8 + 4ull * sn) {
            plan.keyframe.assign(count, 0);
            for (uint32_t i = 0; i < sn; ++i) { const uint32_t s = be32(stssB.data() + 8 + 4 * i); if (s >= 1 && s <= count) plan.keyframe[s - 1] = 1; }
        }
    }

    plan.dts.resize(count); plan.cts.resize(count); plan.ctsNew.resize(count);
    { int64_t tt = 0; for (uint32_t i = 0; i < count; ++i) { plan.dts[i] = tt; tt += deltas[i]; } }
    auto ctsOf = [&](uint32_t raw) -> int64_t { return plan.version1 ? (int64_t)(int32_t)raw : (int64_t)raw; };
    { size_t i = 0; for (size_t r = 0; r < runs.size(); ++r) for (uint32_t k = 0; k < runs[r].first; ++k, ++i) { plan.cts[i] = plan.dts[i] + ctsOf(runs[r].second); plan.ctsNew[i] = plan.dts[i] + ctsOf(r == plan.c.run ? plan.c.newValue : runs[r].second); } }
    plan.patchOffset = ctts.pos + ctts.hdr + 8 + 8 * (int64_t)plan.c.run + 4;
    plan.candidate = true;
    plan.detail = "ctts run#" + std::to_string(plan.c.run) + " offset " + std::to_string(plan.c.oldValue) + " → " + std::to_string(plan.c.newValue) +
                  "（样本 " + std::to_string(plan.c.runFirst + 1) + "–" + std::to_string(plan.c.runLast + 1) + "，解码序重排深度超出 DPB 上限，候选值在其他 run 已有支持且唯一）";
    return plan;
}

inline std::vector<Mp4TrackCfg> mp4ReadTrackConfigs(const Reader& read, int64_t fileSize, const AbortFn* abort) {
    std::vector<Mp4TrackCfg> out;
    Box b;
    if (!mp4FindTopMoov(read, fileSize, abort, b)) return out;
    std::vector<Box> kids;
    if (!boxChildrenClose(read, b.pos + b.hdr, b.end(), nullptr, &kids, abort)) return out;
    for (const Box& k : kids) {
        if (!k.is("trak")) continue;
        Mp4TrackCfg c;
        Box tkhd, mdia, mdhd, hdlr, minf, stbl, stsd;
        if (!mp4FindChild(read, k, "tkhd", tkhd, abort) || !mp4FindChild(read, k, "mdia", mdia, abort)) continue;
        { auto h = readSpan(read, tkhd.pos + tkhd.hdr, 24); if (h.size() < 24) continue; c.id = be32(h.data() + (h[0] == 1 ? 20 : 12)); }
        if (mp4FindChild(read, mdia, "mdhd", mdhd, abort)) { auto h = readSpan(read, mdhd.pos + mdhd.hdr, 24); if (h.size() >= 24) c.timescale = be32(h.data() + (h[0] == 1 ? 20 : 12)); }
        if (mp4FindChild(read, mdia, "hdlr", hdlr, abort)) {
            auto h = readSpan(read, hdlr.pos + hdlr.hdr + 8, 4);
            if (h.size() == 4) { c.video = std::memcmp(h.data(), "vide", 4) == 0; c.audio = std::memcmp(h.data(), "soun", 4) == 0; }
        }
        if (mp4FindChild(read, mdia, "minf", minf, abort) && mp4FindChild(read, minf, "stbl", stbl, abort) && mp4FindChild(read, stbl, "stsd", stsd, abort)) {
            auto sd = readSpan(read, stsd.pos + stsd.hdr, 8);
            Box entry;
            if (sd.size() == 8 && be32(sd.data() + 4) == 1 && readBox(read, stsd.pos + stsd.hdr + 8, stsd.end(), entry) && entry.size > 86 + 8) {
                std::vector<Box> cfg;
                if (boxChildrenClose(read, entry.pos + 86, entry.end(), nullptr, &cfg, abort)) {
                    for (const Box& cb : cfg) {
                        if (cb.size > 64 * 1024 || cb.size <= (uint64_t)cb.hdr) continue;
                        auto body = readSpan(read, cb.pos + cb.hdr, (size_t)(cb.size - cb.hdr));
                        if (cb.is("avcC") && avccRecordValid(body.data(), (int)body.size())) { c.nalLen = (body[4] & 3) + 1; c.hevc = false; }
                        else if (cb.is("hvcC") && hvccRecordValid(body.data(), (int)body.size()) && body.size() >= 23) { c.nalLen = (body[21] & 3) + 1; c.hevc = true; }
                    }
                }
            }
        }
        out.push_back(c);
    }
    return out;
}

inline Mp4FragAnchors mp4ReadFragAnchors(const Reader& read, int64_t fileSize, uint32_t trackId, const AbortFn* abort) {
    Mp4FragAnchors a;
    int64_t pos = 0;
    for (int hops = 0; hops < 64 && pos + 8 <= fileSize; ++hops) {
        if (aborted(abort)) return a;
        Box b;
        if (!readBox(read, pos, fileSize, b) || b.end() > fileSize) break;
        if (b.is("moof") || b.is("mdat")) break;
        if (b.is("sidx") && b.size >= 32 && b.size <= 1u << 20) {
            auto body = readSpan(read, b.pos + b.hdr, (size_t)(b.size - b.hdr));
            if (body.size() >= 24 && be32(body.data() + 4) == trackId) {
                const int ver = body[0];
                const uint32_t ts = be32(body.data() + 8);
                size_t off = 12;
                uint64_t ept, first;
                if (ver == 0) { ept = be32(body.data() + off); first = be32(body.data() + off + 4); off += 8; }
                else { if (body.size() < off + 16) break; ept = be64(body.data() + off); first = be64(body.data() + off + 8); off += 16; }
                if (body.size() < off + 4) break;
                const uint32_t count = ((uint32_t)body[off + 2] << 8) | body[off + 3];
                off += 4;
                int64_t mpos = b.end() + (int64_t)first;
                uint64_t t = ept;
                for (uint32_t i = 0; i < count && off + 12 <= body.size(); ++i, off += 12) {
                    const uint32_t r = be32(body.data() + off), dur = be32(body.data() + off + 4);
                    if (r & 0x80000000u) break;
                    a.sidx.push_back({mpos, t});
                    mpos += (int64_t)(r & 0x7fffffffu);
                    t += dur;
                }
                a.sidxTimescale = ts;
            }
        }
        if (b.sizeFieldZero || b.largeSizeZero) break;
        pos = b.end();
    }

    auto tail = readSpan(read, fileSize - 16, 16);
    if (tail.size() == 16 && be32(tail.data()) == 16 && std::memcmp(tail.data() + 4, "mfro", 4) == 0) {
        const uint32_t mfraSize = be32(tail.data() + 12);
        Box mfra;
        if (mfraSize >= 16 && (int64_t)mfraSize <= fileSize && readBox(read, fileSize - (int64_t)mfraSize, fileSize, mfra) && mfra.is("mfra")) {
            std::vector<Box> kids;
            if (boxChildrenClose(read, mfra.pos + mfra.hdr, mfra.end(), nullptr, &kids, abort)) {
                for (const Box& k : kids) {
                    if (!k.is("tfra") || k.size > 1u << 24) continue;
                    auto body = readSpan(read, k.pos + k.hdr, (size_t)(k.size - k.hdr));
                    if (body.size() < 16 || be32(body.data() + 4) != trackId) continue;
                    const int ver = body[0];
                    const uint32_t lens = be32(body.data() + 8);
                    const size_t lt = ((lens >> 4) & 3) + 1, lu = ((lens >> 2) & 3) + 1, ls = (lens & 3) + 1;
                    const uint32_t n = be32(body.data() + 12);
                    size_t off = 16;
                    for (uint32_t i = 0; i < n; ++i) {
                        const size_t rec = (ver == 1 ? 16 : 8) + lt + lu + ls;
                        if (off + rec > body.size()) break;
                        uint64_t t, m;
                        if (ver == 1) { t = be64(body.data() + off); m = be64(body.data() + off + 8); off += 16; } else { t = be32(body.data() + off); m = be32(body.data() + off + 4); off += 8; }
                        off += lt + lu + ls;
                        a.tfra.push_back({(int64_t)m, t});
                    }
                }
            }
        }
    }
    return a;
}

inline RecoveryPlan planFmp4FragmentCheck(const Reader& read, int64_t fileSize, const Box& moof, const Box& mdat, const std::vector<Mp4TrackCfg>& cfgs,
                                          const Mp4FragAnchors& anchors, const AbortFn* abort) {
    RecoveryPlan p;
    const Mp4TrackCfg* video = nullptr;
    int videos = 0;
    for (const Mp4TrackCfg& c : cfgs) if (c.video) { ++videos; video = &c; }
    if (videos != 1 || !video || video->nalLen == 0) return p;
    std::vector<Box> kids;
    if (!boxChildrenClose(read, moof.pos + moof.hdr, moof.end(), nullptr, &kids, abort)) return p;
    bool videoTraf = false;
    for (const Box& t : kids) {
        if (!t.is("traf")) continue;
        Box tfhd;
        if (!mp4FindChild(read, t, "tfhd", tfhd, abort)) return p;
        auto h = readSpan(read, tfhd.pos + tfhd.hdr, 8);
        if (h.size() < 8) return p;
        if (be32(h.data() + 4) == video->id) videoTraf = true;
    }
    const int64_t dataFrom = mdat.pos + mdat.hdr, dataTo = std::min(mdat.end(), fileSize);
    if (!videoTraf) {

        for (const Mp4TrackCfg& c : cfgs) {
            if (c.id == video->id || aborted(abort)) continue;
            std::vector<Fmp4Run> runs;
            if (!fmp4VideoRuns(read, moof, c.id, runs, abort)) continue;
            for (const Fmp4Run& r : runs) {
                if (r.sizes.empty() || r.declaredStart < dataFrom) continue;
                int64_t total = 0; for (uint32_t s : r.sizes) total += s;
                if (r.declaredStart + total > dataTo || total > 64ll * 1024 * 1024) continue;
                auto head = readSpan(read, r.declaredStart, std::min<size_t>(r.sizes[0], 64));
                bool vcl = false;
                if (head.size() < (size_t)video->nalLen + 1) continue;
                uint32_t len = 0; for (int i = 0; i < video->nalLen; ++i) len = (len << 8) | head[(size_t)i];
                const uint8_t nh = head[(size_t)video->nalLen];
                if (len == 0 || len > r.sizes[0] - (uint32_t)video->nalLen || (nh & 0x80)) continue;
                auto buf = readSpan(read, r.declaredStart, (size_t)total);
                if ((int64_t)buf.size() != total || !fmp4RunChainsAt(buf.data(), buf.size(), r.declaredStart, r.declaredStart, r.sizes, r.sizes.size(), video->nalLen, video->hevc, &vcl) || !vcl) continue;
                Patch pt; pt.offset = r.tfhdPos + 8 + 4; putBe32(pt.bytes, video->id);
                p.patches.push_back(pt);
                p.kind = "fmp4-traf-track";
                p.detail = "moof@" + std::to_string(moof.pos) + " 的 traf 声明轨 " + std::to_string(c.id) + "（非视频）而其 " + std::to_string(r.sizes.size()) +
                           " 个样本全是视频轨配置下的闭合 NAL 链，且本片无视频轨 traf：track_ID → " + std::to_string(video->id);
                p.damagedFrom = dataFrom; p.damagedUntil = dataTo;
                return p;
            }
        }
        return p;
    }
    // tfdt
    if (!anchors.any() || anchors.sidxTimescale == 0 || anchors.sidxTimescale != video->timescale) return p;
    size_t si = anchors.sidx.size();
    for (size_t i = 0; i < anchors.sidx.size(); ++i) if (anchors.sidx[i].first == moof.pos) { si = i; break; }
    if (si == anchors.sidx.size()) return p;
    bool haveTfra = false; uint64_t tfraT = 0;
    for (const auto& e : anchors.tfra) if (e.first == moof.pos && (!haveTfra || e.second < tfraT)) { haveTfra = true; tfraT = e.second; }
    if (!haveTfra || tfraT != anchors.sidx[si].second) return p;
    const uint64_t anchor = tfraT;
    int videoTrafs = 0;
    Box vtraf;
    for (const Box& t : kids) {
        if (!t.is("traf")) continue;
        Box tfhd;
        if (!mp4FindChild(read, t, "tfhd", tfhd, abort)) return p;
        auto h = readSpan(read, tfhd.pos + tfhd.hdr, 8);
        if (h.size() == 8 && be32(h.data() + 4) == video->id) { ++videoTrafs; vtraf = t; }
    }
    if (videoTrafs != 1) return p;
    Box tfdt;
    if (!mp4FindChild(read, vtraf, "tfdt", tfdt, abort)) return p;
    auto th = readSpan(read, tfdt.pos + tfdt.hdr, 12);
    if (th.size() < 8) return p;
    const int ver = th[0];
    const uint64_t cur = ver == 1 ? (th.size() >= 12 ? be64(th.data() + 4) : 0) : be32(th.data() + 4);
    if (ver == 1 && th.size() < 12) return p;
    if (cur == anchor || __builtin_popcountll(cur ^ anchor) != 1) return p;
    if (ver == 0 && anchor > 0xFFFFFFFFull) return p;

    const bool next = si + 1 < anchors.sidx.size();
    if (!(cur < anchor || (next && cur >= anchors.sidx[si + 1].second))) return p;

    std::vector<Fmp4Run> runs;
    if (!fmp4VideoRuns(read, moof, video->id, runs, abort) || runs.empty()) return p;
    for (const Fmp4Run& r : runs) {
        if (r.hasCto) return p;
        if (r.sizes.empty()) return p;
        int64_t total = 0; for (size_t i = 0; i < r.sizes.size() && i < 3; ++i) total += r.sizes[i];
        auto buf = readSpan(read, r.declaredStart, (size_t)total);
        bool vcl = false;
        if ((int64_t)buf.size() != total || !fmp4RunChainsAt(buf.data(), buf.size(), r.declaredStart, r.declaredStart, r.sizes, 3, video->nalLen, video->hevc, &vcl)) return p;
    }
    Patch pt; pt.offset = tfdt.pos + tfdt.hdr + 4;
    if (ver == 1) putBe64(pt.bytes, anchor); else putBe32(pt.bytes, (uint32_t)anchor);
    p.patches.push_back(pt);
    p.kind = "fmp4-tfdt";
    p.detail = "moof@" + std::to_string(moof.pos) + " 视频 tfdt " + std::to_string(cur) + " 与 sidx/tfra 一致锚 " + std::to_string(anchor) +
               " 恰差一位且" + (cur < anchor ? "倒退到本片之前" : "越过后片起点") + "（run 无组合偏移、样本链闭合）：改回锚值";
    p.damagedFrom = dataFrom; p.damagedUntil = dataTo;
    return p;
}

struct CarvedSamples {
    std::vector<std::pair<int64_t, uint32_t>> samples;
    int width = 0, height = 0;
    char tag[5] = {0};
    int fpsNum = 0, fpsDen = 1;
    bool fpsFromStream = false;
    bool containsB = false;
    std::vector<int32_t> compositionOffsets; // optional checked ctts v1, one per sample
    std::string codec; // "prores" / "mjpeg" / "h264" / "hevc"
    std::vector<uint32_t> keyframes;
    std::vector<uint8_t> configBox;
};

inline bool proresFrameHeaderAt(const uint8_t* h, size_t n, int64_t limitLen, uint32_t& size, int& w, int& hgt, int& chroma, int& fpsCode) {
    if (n < 24) return false;
    size = be32(h);
    if (std::memcmp(h + 4, "icpf", 4) != 0) return false;
    const uint16_t hdr = (uint16_t)((h[8] << 8) | h[9]);
    const uint16_t ver = (uint16_t)((h[10] << 8) | h[11]);
    w = (h[16] << 8) | h[17];
    hgt = (h[18] << 8) | h[19];
    chroma = (h[20] >> 6) & 3;

    fpsCode = h[21] & 0x0f;
    if (size < 32 || size > 64u * 1024 * 1024 || (int64_t)size > limitLen) return false;
    if (hdr < 20 || hdr > size - 8 || ver > 1) return false;
    if (w <= 0 || hgt <= 0 || w > 16384 || hgt > 16384) return false;
    if (chroma != 2 && chroma != 3) return false;
    return true;
}

inline bool proresFpsFromCode(int code, int& num, int& den) {
    switch (code) {
        case 1: num = 24000; den = 1001; return true;
        case 2: num = 24; den = 1; return true;
        case 3: num = 25; den = 1; return true;
        case 4: num = 30000; den = 1001; return true;
        case 5: num = 30; den = 1; return true;
        case 6: num = 50; den = 1; return true;
        case 7: num = 60000; den = 1001; return true;
        case 8: num = 60; den = 1; return true;
        case 9: num = 100; den = 1; return true;
        case 10: num = 120000; den = 1001; return true;
        case 11: num = 120; den = 1; return true;
        default: return false;
    }
}

inline bool carveProres(const Reader& read, int64_t from, int64_t to, CarvedSamples& out, const AbortFn* abort) {
    int64_t pos = from;
    int firstW = 0, firstH = 0, firstChroma = 0, fpsCode = 0, fpsDisagree = 0;
    int failed = 0;
    static const uint8_t pat[4] = {'i', 'c', 'p', 'f'};
    FindCursor fc;
    while (pos + 24 <= to && out.samples.size() < 200000) {
        if (aborted(abort)) return false;
        auto h = readSpan(read, pos, 24);
        uint32_t size = 0; int w = 0, hgt = 0, chroma = 0, code = 0;
        bool ok = proresFrameHeaderAt(h.data(), h.size(), to - pos, size, w, hgt, chroma, code);
        if (ok && !out.samples.empty() && (w != firstW || hgt != firstH)) ok = false;
        if (!ok) {
            if (++failed > 4096) break;
            int64_t hit = -1;
            if (!findBytes(read, pos + 5, std::min(to, pos + 8ll * 1024 * 1024), pat, 4, hit, abort, &fc) || hit - 4 <= pos) break;
            pos = hit - 4;
            continue;
        }
        if (out.samples.empty()) { firstW = w; firstH = hgt; firstChroma = chroma; fpsCode = code; }
        else if (code != fpsCode) ++fpsDisagree;
        out.samples.push_back({pos, size});
        pos += size;
    }
    if (out.samples.size() < 2) return false;
    out.width = firstW; out.height = firstH;
    std::memcpy(out.tag, firstChroma == 3 ? "ap4h" : "apch", 5);
    out.fpsFromStream = fpsDisagree == 0 && proresFpsFromCode(fpsCode, out.fpsNum, out.fpsDen);
    if (!out.fpsFromStream) { out.fpsNum = 24; out.fpsDen = 1; }
    out.codec = "prores";
    return true;
}

inline size_t jpegFrameLen(const uint8_t* d, size_t n, int& w, int& h) {
    if (n < 4 || d[0] != 0xFF || d[1] != 0xD8) return 0;
    size_t off = 2;
    w = h = 0;
    while (off + 4 <= n) {
        if (d[off] != 0xFF) return 0;
        const uint8_t m = d[off + 1];
        if (m == 0xFF) { ++off; continue; }
        if (m == 0xD8 || (m >= 0xD0 && m <= 0xD7)) { off += 2; continue; }
        if (m == 0xD9) return 0;
        const size_t len = ((size_t)d[off + 2] << 8) | d[off + 3];
        if (len < 2 || off + 2 + len > n) return 0;
        if ((m >= 0xC0 && m <= 0xC3) || (m >= 0xC5 && m <= 0xC7) || (m >= 0xC9 && m <= 0xCB) || (m >= 0xCD && m <= 0xCF)) {
            if (len >= 7) { h = (d[off + 5] << 8) | d[off + 6]; w = (d[off + 7] << 8) | d[off + 8]; }
        }
        off += 2 + len;
        if (m == 0xDA) {

            while (off + 1 < n) {
                if (d[off] != 0xFF) { ++off; continue; }
                const uint8_t m2 = d[off + 1];
                if (m2 == 0x00 || (m2 >= 0xD0 && m2 <= 0xD7) || m2 == 0xFF) { off += (m2 == 0xFF) ? 1 : 2; continue; }
                if (m2 == 0xD9) return (w > 0 && h > 0) ? off + 2 : 0;
                if (m2 == 0xDA || m2 == 0xC4 || m2 == 0xDB || m2 == 0xDC || m2 == 0xDD) {

                    if (off + 4 > n) return 0;
                    const size_t l2 = ((size_t)d[off + 2] << 8) | d[off + 3];
                    if (l2 < 2 || off + 2 + l2 > n) return 0;
                    off += 2 + l2;
                    continue;
                }
                return 0;
            }
            return 0;
        }
    }
    return 0;
}

inline bool carveMjpeg(const Reader& read, int64_t from, int64_t to, CarvedSamples& out, const AbortFn* abort) {
    int64_t pos = from;
    int firstW = 0, firstH = 0;
    const int64_t scanLimit = std::min(to, from + 1024ll * 1024 * 1024);

    constexpr size_t kWin = 4u * 1024 * 1024;
    std::vector<uint8_t> win;
    int64_t winPos = -1;
    auto load = [&](int64_t at, size_t want) -> bool {
        want = (size_t)std::min<int64_t>((int64_t)want, to - at);
        win = readSpan(read, at, want);
        winPos = at;
        return !win.empty();
    };
    auto covers = [&](int64_t at, size_t n) { return winPos >= 0 && at >= winPos && at + (int64_t)n <= winPos + (int64_t)win.size(); };

    auto findSoi = [&](int64_t at, int64_t limit) -> int64_t {
        while (at + 3 <= limit) {
            if (aborted(abort)) return -1;
            if (!covers(at, 3) && !load(at, kWin)) return -1;
            const uint8_t* p = win.data();
            const size_t n = win.size();
            for (size_t k = (size_t)(at - winPos); k + 3 <= n; ++k)
                if (p[k] == 0xFF && p[k + 1] == 0xD8 && p[k + 2] == 0xFF) return winPos + (int64_t)k < limit ? winPos + (int64_t)k : -1;
            const int64_t next = winPos + (int64_t)n - 2;
            if (winPos + (int64_t)n >= limit || next <= at) return -1;
            at = next;
        }
        return -1;
    };
    while (pos + 4 <= scanLimit && out.samples.size() < 200000) {
        if (aborted(abort)) return false;
        const int64_t hit = findSoi(pos, std::min(scanLimit, pos + 8ll * 1024 * 1024));
        if (hit < 0) break;

        size_t len = 0; int w = 0, h = 0;
        size_t cap = kWin;
        for (int grow = 0; grow < 4; ++grow) {
            size_t avail = covers(hit, 1) ? win.size() - (size_t)(hit - winPos) : 0;
            if (avail < cap && hit + (int64_t)avail < to) { if (!load(hit, cap)) break; avail = win.size(); }
            len = jpegFrameLen(win.data() + (hit - winPos), avail, w, h);
            if (len > 0 || avail < cap) break;
            cap *= 2;
        }
        if (len == 0 || (!out.samples.empty() && (w != firstW || h != firstH))) { pos = hit + 2; continue; }
        if (out.samples.empty()) { firstW = w; firstH = h; }
        out.samples.push_back({hit, (uint32_t)len});
        pos = hit + (int64_t)len;
    }
    if (out.samples.size() < 2) return false;
    out.width = firstW; out.height = firstH;
    std::memcpy(out.tag, "jpeg", 5);
    out.fpsNum = 25; out.fpsDen = 1; out.fpsFromStream = false;
    out.codec = "mjpeg";
    return true;
}

inline bool hevcSpsDims(const uint8_t* n, size_t len, int& width, int& height) {
    if (!n || len < 16 || ((n[0] >> 1) & 0x3f) != 33) return false;
    const detail::HevcSpsInfo s = detail::parseHevcSps(n, len);
    if (!s.geomOk) return false;
    const uint32_t subW = (s.chroma == 1 || s.chroma == 2) ? 2 : 1, subH = s.chroma == 1 ? 2 : 1;
    const int64_t ww = (int64_t)s.width - (int64_t)(s.cropL + s.cropR) * subW, hh = (int64_t)s.height - (int64_t)(s.cropT + s.cropB) * subH;
    if (ww <= 0 || hh <= 0) return false;
    width = (int)ww; height = (int)hh;
    return true;
}

inline bool carveAvcHevc(const Reader& read, int64_t from, int64_t to, CarvedSamples& out, const AbortFn* abort, bool allowB = false, uint32_t maxSamples = 200000, bool* sampleLimitHit = nullptr) {
    if (sampleLimitHit) *sampleLimitHit = false;
    if (to - from < 64) return false;
    struct Win { std::vector<uint8_t> buf; int64_t start = -1; } w;
    auto fetch = [&](int64_t pos, size_t n) -> const uint8_t* {
        if (pos < from || pos >= to) return nullptr;
        n = (size_t)std::min<int64_t>((int64_t)n, to - pos);
        if (w.start < 0 || pos < w.start || pos + (int64_t)n > w.start + (int64_t)w.buf.size()) {
            const size_t want = (size_t)std::min<int64_t>(4ll * 1024 * 1024, to - pos);
            w.buf = readSpan(read, pos, want); w.start = pos;
            if (w.buf.size() < n) return nullptr;
        }
        return w.buf.data() + (pos - w.start);
    };
    struct Result {
        bool hevc = false; int width = 4;
        std::vector<std::pair<int64_t, uint32_t>> samples;
        std::vector<uint32_t> keys;
        std::vector<uint8_t> sps;
        bool hasB = false;
    };
    std::vector<Result> found;
    for (int hv = 0; hv < 2; ++hv) {
        for (int width = 4; width >= 1; --width) {
            if (aborted(abort)) return false;
            const bool hevc = hv == 1;
            Result r; r.hevc = hevc; r.width = width;
            int64_t pos = from; bool ok = true;
            int64_t auStart = -1; bool auHasVcl = false, auKey = false, sawVclInAu = false;
            bool haveSps = false, havePps = false, haveVps = false, firstVclSeen = false, paramsBeforeFirstVcl = false;
            std::vector<std::pair<uint32_t, int>> ppsExtra;
            size_t nals = 0;
            while (pos < to) {
                if ((nals & 0xFFFF) == 0 && aborted(abort)) return false;
                const uint8_t* p = fetch(pos, (size_t)width);
                if (!p) { ok = false; break; }
                uint32_t len = 0;
                for (int i = 0; i < width; ++i) len = (len << 8) | p[i];
                const int64_t nalPos = pos + width;

                if (len < (uint32_t)(hevc ? 3 : 2) || (int64_t)len > to - nalPos) { ok = false; break; }
                const size_t peek = std::min<size_t>(len, 64);
                const uint8_t* n = fetch(nalPos, peek);
                if (!n) { ok = false; break; }
                bool vcl = false, key = false, aud = false, paramOrSei = false, firstSlice = false;
                if (!hevc) {
                    if (n[0] & 0x80) { ok = false; break; }
                    const int type = n[0] & 0x1f;
                    if (type == 0 || type > 23) { ok = false; break; }
                    vcl = type >= 1 && type <= 5; key = type == 5; aud = type == 9;
                    paramOrSei = type == 6 || type == 7 || type == 8 || type == 14 || type == 15;
                    if (vcl) { firstSlice = (n[1] & 0x80) != 0; const int st = h264SliceType(n, peek); if (st == 1 || st == 6) r.hasB = true; }
                    if (type == 7) { haveSps = true; if (r.sps.empty()) { const uint8_t* full = fetch(nalPos, std::min<size_t>(len, 4096)); if (full) r.sps.assign(full, full + std::min<size_t>(len, 4096)); } }
                    if (type == 8) havePps = true;
                } else {
                    if ((n[0] & 0x80) || (n[1] & 0x07) == 0) { ok = false; break; }
                    const int type = (n[0] >> 1) & 0x3f;
                    if (type > 40) { ok = false; break; }
                    vcl = type <= 31; key = type >= 16 && type <= 21; aud = type == 35;
                    paramOrSei = type == 32 || type == 33 || type == 34 || type == 39;
                    if (type == 34) { uint32_t id = 0; bool dep = false; int extra = 0; if (hevcPpsSliceFields(n, peek, id, dep, extra)) { ppsExtra.push_back({id, extra}); havePps = true; } }
                    if (type == 33) { haveSps = true; if (r.sps.empty()) { const uint8_t* full = fetch(nalPos, std::min<size_t>(len, 4096)); if (full) r.sps.assign(full, full + std::min<size_t>(len, 4096)); } }
                    if (type == 32) haveVps = true;
                    if (vcl) { firstSlice = (n[2] & 0x80) != 0; if (firstSlice) { const int st = hevcFirstSliceType(n, peek, ppsExtra); if (st == 0) r.hasB = true; } }
                }
                const bool boundary = aud || (sawVclInAu && (paramOrSei || (vcl && firstSlice)));

                if (boundary && auStart >= 0 && auHasVcl) {
                    if (auKey) r.keys.push_back((uint32_t)r.samples.size());
                    r.samples.push_back({auStart, (uint32_t)(pos - auStart)});
                    auStart = -1;
                }
                if (auStart < 0) { auStart = pos; auHasVcl = false; auKey = false; sawVclInAu = false; }
                if (vcl) {
                    if (!firstVclSeen) { firstVclSeen = true; paramsBeforeFirstVcl = haveSps && havePps && (!hevc || haveVps); }
                    auHasVcl = true; sawVclInAu = true;
                    if (key) auKey = true;
                }
                pos = nalPos + len;
                if (r.samples.size() > maxSamples && sampleLimitHit) *sampleLimitHit = true;
                if (++nals > 4000000 || r.samples.size() > maxSamples || pos - auStart > 64ll * 1024 * 1024) { ok = false; break; }
            }
            if (ok && pos == to && auStart >= 0 && auHasVcl) {
                if (auKey) r.keys.push_back((uint32_t)r.samples.size());
                r.samples.push_back({auStart, (uint32_t)(pos - auStart)});
            }
            if (!ok || pos != to || r.samples.size() < 2 || !paramsBeforeFirstVcl || r.keys.empty() || r.keys[0] != 0 || r.sps.empty()) continue;
            found.push_back(std::move(r));
        }
    }
    if (found.size() != 1) return false;
    Result& r = found[0];
    if (r.samples.size() > maxSamples && sampleLimitHit) *sampleLimitHit = true;
    if ((r.hasB && !allowB) || r.samples.size() > maxSamples) return false;
    out.containsB = r.hasB;

    const auto first = readSpan(read, r.samples[0].first, (size_t)std::min<uint32_t>(r.samples[0].second, 4u * 1024 * 1024));
    if (first.size() != r.samples[0].second) return false;
    std::vector<uint8_t> extradata;
    if (!r.hevc) {
        const H264ConfigBootstrap b = bootstrapH264Config(first.data(), first.size(), nullptr, 0);
        if (!b.ok || b.layout.kind != Bitstream::LengthPrefixed || b.layout.nalLengthSize != r.width) return false;
        extradata = b.extradata;
        if (!h264SpsDims(r.sps.data(), r.sps.size(), out.width, out.height)) return false;
        uint32_t nu = 0, ts = 0;
        if (h264SpsTiming(r.sps.data(), r.sps.size(), nu, ts) && ts / (2.0 * nu) >= 1.0 && ts / (2.0 * nu) <= 240.0) { out.fpsNum = (int)ts; out.fpsDen = (int)(2 * nu); out.fpsFromStream = true; }
        else { out.fpsNum = 25; out.fpsDen = 1; out.fpsFromStream = false; }
        std::memcpy(out.tag, "avc1", 5);
        out.codec = "h264";
    } else {
        const HevcConfigBootstrap b = bootstrapHevcConfig(first.data(), first.size(), nullptr, 0);
        if (!b.ok || b.layout.kind != Bitstream::LengthPrefixed || b.layout.nalLengthSize != r.width) return false;
        extradata = b.extradata;
        if (!hevcSpsDims(r.sps.data(), r.sps.size(), out.width, out.height)) return false;
        uint32_t nu = 0, ts = 0;
        if (hevcSpsTiming(r.sps.data(), r.sps.size(), nu, ts) && (double)ts / nu >= 1.0 && (double)ts / nu <= 240.0) { out.fpsNum = (int)ts; out.fpsDen = (int)nu; out.fpsFromStream = true; }
        else { out.fpsNum = 25; out.fpsDen = 1; out.fpsFromStream = false; }
        std::memcpy(out.tag, "hvc1", 5);
        out.codec = "hevc";
    }
    if (extradata.empty() || extradata.size() > 0xFFFF) return false;
    out.samples = std::move(r.samples);
    out.keyframes = std::move(r.keys);
    out.configBox.clear();
    putBe32(out.configBox, (uint32_t)(8 + extradata.size()));
    const char* cb = r.hevc ? "hvcC" : "avcC";
    out.configBox.insert(out.configBox.end(), cb, cb + 4);
    out.configBox.insert(out.configBox.end(), extradata.begin(), extradata.end());
    return true;
}

inline std::vector<uint8_t> buildSyntheticMoov(const CarvedSamples& c) {
    auto box = [](const char* type, const std::vector<uint8_t>& payload) {
        std::vector<uint8_t> v;
        putBe32(v, (uint32_t)(8 + payload.size()));
        v.insert(v.end(), type, type + 4);
        v.insert(v.end(), payload.begin(), payload.end());
        return v;
    };
    auto cat = [](std::initializer_list<std::vector<uint8_t>> parts) {
        std::vector<uint8_t> v;
        for (auto& p : parts) v.insert(v.end(), p.begin(), p.end());
        return v;
    };
    const uint32_t n = (uint32_t)c.samples.size();
    const uint32_t timescale = (uint32_t)c.fpsNum, delta = (uint32_t)c.fpsDen;
    const uint64_t dur = (uint64_t)n * delta;
    const uint32_t dur32 = dur > 0xFFFFFFFFull ? 0xFFFFFFFFu : (uint32_t)dur;
    std::vector<uint8_t> mvhd = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    putBe32(mvhd, timescale); putBe32(mvhd, dur32); putBe32(mvhd, 0x00010000); mvhd.push_back(1); mvhd.push_back(0);
    mvhd.insert(mvhd.end(), 10, 0);
    static const uint8_t matrix[36] = {0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x40, 0, 0, 0};
    mvhd.insert(mvhd.end(), matrix, matrix + 36);
    mvhd.insert(mvhd.end(), 24, 0);
    putBe32(mvhd, 2);
    std::vector<uint8_t> tkhd = {0, 0, 0, 0x0F, 0, 0, 0, 0, 0, 0, 0, 0};
    putBe32(tkhd, 1); putBe32(tkhd, 0); putBe32(tkhd, dur32);
    tkhd.insert(tkhd.end(), 16, 0); // reserved 8 + layer/alt/volume/reserved 8
    tkhd.insert(tkhd.end(), matrix, matrix + 36);
    putBe32(tkhd, (uint32_t)c.width << 16); putBe32(tkhd, (uint32_t)c.height << 16);
    std::vector<uint8_t> mdhd = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    putBe32(mdhd, timescale); putBe32(mdhd, dur32); mdhd.push_back(0x55); mdhd.push_back(0xC4); mdhd.push_back(0); mdhd.push_back(0);
    std::vector<uint8_t> hdlr = {0, 0, 0, 0, 0, 0, 0, 0, 'v', 'i', 'd', 'e'};
    hdlr.insert(hdlr.end(), 12, 0); hdlr.push_back(0);
    std::vector<uint8_t> vmhd = {0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0};
    std::vector<uint8_t> url = box("url ", {0, 0, 0, 1});
    std::vector<uint8_t> drefPayload = {0, 0, 0, 0, 0, 0, 0, 1};
    drefPayload.insert(drefPayload.end(), url.begin(), url.end());
    std::vector<uint8_t> dinf = box("dinf", box("dref", drefPayload));
    // VisualSampleEntry
    std::vector<uint8_t> entry(6, 0);
    entry.push_back(0); entry.push_back(1); // data_reference_index
    entry.insert(entry.end(), 16, 0);
    entry.push_back((uint8_t)(c.width >> 8)); entry.push_back((uint8_t)c.width);
    entry.push_back((uint8_t)(c.height >> 8)); entry.push_back((uint8_t)c.height);
    putBe32(entry, 0x00480000); putBe32(entry, 0x00480000); putBe32(entry, 0);
    entry.push_back(0); entry.push_back(1);
    entry.insert(entry.end(), 32, 0);
    entry.push_back(0); entry.push_back(24);
    entry.push_back(0xFF); entry.push_back(0xFF);
    entry.insert(entry.end(), c.configBox.begin(), c.configBox.end());
    std::vector<uint8_t> stsdPayload = {0, 0, 0, 0, 0, 0, 0, 1};
    auto entryBox = box(c.tag, entry);
    stsdPayload.insert(stsdPayload.end(), entryBox.begin(), entryBox.end());
    std::vector<uint8_t> stts = {0, 0, 0, 0}; putBe32(stts, 1); putBe32(stts, n); putBe32(stts, delta);
    std::vector<uint8_t> stsc = {0, 0, 0, 0}; putBe32(stsc, 1); putBe32(stsc, 1); putBe32(stsc, 1); putBe32(stsc, 1);
    std::vector<uint8_t> stsz = {0, 0, 0, 0}; putBe32(stsz, 0); putBe32(stsz, n);
    std::vector<uint8_t> co64 = {0, 0, 0, 0}; putBe32(co64, n);
    stsz.reserve(stsz.size() + 4 * n); co64.reserve(co64.size() + 8 * n);
    for (const auto& sm : c.samples) { putBe32(stsz, sm.second); putBe64(co64, (uint64_t)sm.first); }
    std::vector<uint8_t> stssBox;
    if (!c.keyframes.empty() && c.keyframes.size() < c.samples.size()) {
        std::vector<uint8_t> stss = {0, 0, 0, 0}; putBe32(stss, (uint32_t)c.keyframes.size());
        for (uint32_t k : c.keyframes) putBe32(stss, k + 1);
        stssBox = box("stss", stss);
    }
    std::vector<uint8_t> cttsBox;
    if (!c.compositionOffsets.empty()) {
        if (c.compositionOffsets.size() != n) return {};
        std::vector<uint8_t> ctts = {1, 0, 0, 0};
        std::vector<std::pair<uint32_t, int32_t>> runs;
        for (int32_t off : c.compositionOffsets) {
            if (!runs.empty() && runs.back().second == off) ++runs.back().first;
            else runs.push_back({1, off});
        }
        putBe32(ctts, (uint32_t)runs.size());
        for (const auto& run : runs) { putBe32(ctts, run.first); putBe32(ctts, (uint32_t)run.second); }
        cttsBox = box("ctts", ctts);
    }
    auto stbl = box("stbl", cat({box("stsd", stsdPayload), box("stts", stts), cttsBox, stssBox, box("stsc", stsc), box("stsz", stsz), box("co64", co64)}));
    auto minf = box("minf", cat({box("vmhd", vmhd), dinf, stbl}));
    auto mdia = box("mdia", cat({box("mdhd", mdhd), box("hdlr", hdlr), minf}));
    auto trak = box("trak", cat({box("tkhd", tkhd), mdia}));
    return box("moov", cat({box("mvhd", mvhd), trak}));
}

inline RecoveryPlan planMp4CarveFrames(const Reader& read, int64_t fileSize, const AbortFn* abort) {
    RecoveryPlan p;
    int64_t pos = 0;
    Box mdat; bool haveMdat = false;
    bool badMoov = false;
    int64_t coverFrom = fileSize;
    for (int hops = 0; hops < 64 && pos + 8 <= fileSize; ++hops) {
        if (aborted(abort)) return p;
        Box b;
        if (!readBox(read, pos, fileSize, b)) { if (haveMdat) { coverFrom = pos; break; } return p; }
        if (b.is("moof")) return p;
        if (b.is("moov")) {
            if (validateMoov(read, pos, fileSize, abort, nullptr)) return p;
            if (badMoov) return p;
            badMoov = true;
            coverFrom = pos;
            break;
        }
        if (b.is("mdat")) {
            if (haveMdat) return p;
            mdat = b; haveMdat = true;
            if (b.sizeFieldZero || b.largeSizeZero || b.end() >= fileSize) break;
            pos = b.end();
            continue;
        }
        if (!(b.is("ftyp") || b.is("wide") || b.is("free") || b.is("skip"))) { if (haveMdat) { coverFrom = pos; break; } return p; }
        if (b.sizeFieldZero || b.largeSizeZero || b.end() > fileSize) return p;
        pos = b.end();
    }
    if (!haveMdat) return p;
    if (pos + 8 > fileSize && pos < fileSize && coverFrom == fileSize && haveMdat && mdat.end() < fileSize) coverFrom = pos;
    const bool mdatOverruns = mdat.end() > fileSize;
    const int64_t dataFrom = mdat.pos + mdat.hdr, dataTo = std::min<int64_t>(mdat.end(), fileSize);
    if (dataTo - dataFrom < 32) return p;
    CarvedSamples c;
    auto head = readSpan(read, dataFrom, 8);
    bool ok = false;
    if (head.size() >= 8 && std::memcmp(head.data() + 4, "icpf", 4) == 0) ok = carveProres(read, dataFrom, dataTo, c, abort);
    if (!ok) { c = CarvedSamples{}; ok = carveAvcHevc(read, dataFrom, dataTo, c, abort); }
    if (!ok) {

        static const uint8_t pat[4] = {'i', 'c', 'p', 'f'};
        int64_t hit = -1;
        if (findBytes(read, dataFrom, std::min(dataTo, dataFrom + 8ll * 1024 * 1024), pat, 4, hit, abort) && hit - 4 >= dataFrom) {
            c = CarvedSamples{};
            ok = carveProres(read, hit - 4, dataTo, c, abort);
        }
    }
    if (!ok) { c = CarvedSamples{}; ok = carveMjpeg(read, dataFrom, dataTo, c, abort); }
    if (!ok || c.samples.size() < 2) return p;
    if (mdat.sizeFieldZero || mdat.largeSizeZero || mdatOverruns) {

        Patch pt;
        if (mdat.hdr == 16) { pt.offset = mdat.pos + 8; putBe64(pt.bytes, (uint64_t)(fileSize - mdat.pos)); }
        else {
            if ((uint64_t)(fileSize - mdat.pos) > 0xFFFFFFFFull) return p;
            pt.offset = mdat.pos; putBe32(pt.bytes, (uint32_t)(fileSize - mdat.pos));
        }
        p.patches.push_back(pt);
    }
    Patch moov;
    moov.offset = coverFrom;
    moov.bytes = buildSyntheticMoov(c);
    if (coverFrom + (int64_t)moov.bytes.size() < fileSize) {

        const uint64_t pad = std::max<uint64_t>(8, (uint64_t)(fileSize - coverFrom) - moov.bytes.size());
        if (pad > 0xFFFFFFFFull) return p;
        putBe32(moov.bytes, (uint32_t)pad);
        moov.bytes.insert(moov.bytes.end(), {'f', 'r', 'e', 'e'});
        moov.bytes.resize(moov.bytes.size() + (size_t)pad - 8, 0);
    }
    p.patches.push_back(moov);
    p.kind = "mp4-carve-" + c.codec;
    p.detail = std::string(badMoov ? "moov 残片不可用" : "moov 丢失") + (mdatOverruns ? "、mdat 在媒体区内截断" : "") + "：从 mdat 提取 " +
               std::to_string(c.samples.size()) + " 个 " + c.codec + " 帧（" + std::to_string(c.width) + "×" +
               std::to_string(c.height) + (c.keyframes.empty() ? "" : "，关键帧 " + std::to_string(c.keyframes.size())) +
               "），合成 moov 虚拟追加；帧率 " + std::to_string(c.fpsNum) + "/" + std::to_string(c.fpsDen) +
               (c.fpsFromStream ? "（码流给出）" : "（无帧率信息，估计值）") + "；音轨未恢复";
    p.damagedFrom = std::min(coverFrom, mdatOverruns ? fileSize : mdat.end()); p.damagedUntil = fileSize;
    return p;
}

} // namespace spresil

// Bounded fault-local sample table recovery; no healthy-path work.
#include "RecoveryMp4Window.hpp"
