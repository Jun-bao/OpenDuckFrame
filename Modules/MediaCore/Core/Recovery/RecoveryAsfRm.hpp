// OpenDuckFrame - container recovery: ASF (packet geometry, payload counts, object size copies / fragment offsets) and RealMedia MDPR
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

inline constexpr std::array<uint8_t, 16> kAsfFilePropsGuid = {0xA1, 0xDC, 0xAB, 0x8C, 0x47, 0xA9, 0xCF, 0x11, 0x8E, 0xE4, 0x00, 0xC0, 0x0C, 0x20, 0x53, 0x65};
inline constexpr std::array<uint8_t, 16> kAsfStreamPropsGuid = {0x91, 0x07, 0xDC, 0xB7, 0xB7, 0xA9, 0xCF, 0x11, 0x8E, 0xE6, 0x00, 0xC0, 0x0C, 0x20, 0x53, 0x65};
inline constexpr std::array<uint8_t, 16> kAsfDataGuid = {0x36, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C};

struct AsfLayout {
    int64_t filePropsPos = -1;
    uint64_t fpPacketCount = 0;
    uint32_t minPkt = 0, maxPkt = 0;
    int64_t dataPos = -1;
    uint64_t dataSize = 0;
    uint64_t dataPacketCount = 0;
    std::set<int> streams;
    bool broadcast = false;      // File Properties flags bit0
    uint64_t prerollMs = 0;
};

inline bool asfFixedGeometry(const AsfLayout& L) {
    if (L.minPkt < 64 || L.minPkt > 65536 || L.minPkt != L.maxPkt || L.fpPacketCount == 0) return false;
    if (L.fpPacketCount > (UINT64_MAX - 50) / L.minPkt) return false;
    return L.dataSize == 50 + L.fpPacketCount * (uint64_t)L.minPkt;
}

inline bool asfLocate(const Reader& read, int64_t fileSize, AsfLayout& L) {
    auto h = readSpan(read, 0, 30);
    if (h.size() < 30 || std::memcmp(h.data(), kAsfHeaderGuid.data(), 16) != 0) return false;
    const uint64_t headerSize = le64(h.data() + 16);
    if (headerSize < 30 || headerSize > 16ull * 1024 * 1024 || (int64_t)headerSize + 50 > fileSize) return false;
    auto body = readSpan(read, 30, (size_t)(headerSize - 30));
    if (body.size() != headerSize - 30) return false;
    size_t off = 0; int fp = 0;
    while (off + 24 <= body.size()) {
        const uint64_t osz = le64(body.data() + off + 16);
        if (osz < 24 || osz > body.size() - off) return false;
        if (std::memcmp(body.data() + off, kAsfFilePropsGuid.data(), 16) == 0) {
            if (osz < 104) return false;
            ++fp;
            L.filePropsPos = 30 + (int64_t)off;
            L.fpPacketCount = le64(body.data() + off + 56);
            L.broadcast = (le32(body.data() + off + 88) & 1) != 0;
            L.prerollMs = le64(body.data() + off + 80);
            L.minPkt = le32(body.data() + off + 92);
            L.maxPkt = le32(body.data() + off + 96);
        } else if (std::memcmp(body.data() + off, kAsfStreamPropsGuid.data(), 16) == 0) {
            if (osz >= 74) L.streams.insert(body[off + 72] & 0x7f);
        }
        off += (size_t)osz;
    }
    if (off != body.size() || fp != 1 || L.streams.empty()) return false;
    L.dataPos = (int64_t)headerSize;
    auto d = readSpan(read, L.dataPos, 50);
    if (d.size() < 50 || std::memcmp(d.data(), kAsfDataGuid.data(), 16) != 0) return false;
    L.dataSize = le64(d.data() + 16);
    L.dataPacketCount = le64(d.data() + 40);
    return true;
}

struct AsfPacketInfo {
    bool ok = false;
    int64_t countPos = -1;
    int declared = 0;
    int actual = 0;
    bool compressed = false;
};

struct AsfPayloadRef { int sid = 0; uint32_t objNum = 0, fo = 0; int foWidth = 0; size_t foPos = 0; uint32_t objSize = 0; size_t sizePos = 0; uint32_t pts = 0; uint32_t frag = 0; size_t dataPos = 0; };
inline int asfFieldWidth(int code) { code &= 3; return code == 0 ? 0 : code == 1 ? 1 : code == 2 ? 2 : 4; }

inline AsfPacketInfo asfParsePacket(const uint8_t* b, size_t size, const std::set<int>& streams, std::vector<AsfPayloadRef>* out = nullptr) {
    AsfPacketInfo r;
    size_t p = 0;
    if (size < 12) return r;
    if (b[0] & 0x80) {
        if ((b[0] & 0x8f) != 0x82 || b[1] != 0 || b[2] != 0) return r;
        p = 3;
    }
    const uint8_t flags = b[p], prop = b[p + 1];
    p += 2;
    auto take = [&](int code, uint32_t def, uint32_t& out) -> bool {
        const int w = (code & 3) == 0 ? 0 : (code & 3) == 1 ? 1 : (code & 3) == 2 ? 2 : 4;
        if (w == 0) { out = def; return true; }
        if (p + (size_t)w > size) return false;
        out = w == 1 ? b[p] : w == 2 ? (uint32_t)(b[p] | (b[p + 1] << 8)) : le32(b + p);
        p += (size_t)w;
        return true;
    };
    uint32_t length = 0, seq = 0, pad = 0;
    if (!take(flags >> 5, (uint32_t)size, length) || !take(flags >> 1, 0, seq) || !take(flags >> 3, 0, pad)) return r;
    if (length != size || pad >= size) return r;
    if (p + 6 > size) return r;
    p += 6; // send time + duration
    uint8_t segType = 0x80; int count = 1;
    if (flags & 1) {
        if (p >= size) return r;
        r.countPos = (int64_t)p;
        segType = b[p++];
        count = segType & 0x3f;
        if ((segType >> 6) == 0) return r;
    }
    r.declared = count;
    const size_t end = size - pad;
    int actual = 0;
    while (p < end && actual < 63) {
        const int sid = b[p] & 0x7f;
        if (!streams.count(sid)) return r;
        ++p;
        uint32_t mo = 0, fo = 0, rl = 0;
        if (!take(prop >> 4, 0, mo)) return r;
        const size_t foPos = p; const int foWidth = asfFieldWidth(prop >> 2);
        if (!take(prop >> 2, 0, fo) || !take(prop, 0, rl)) return r;
        if (rl == 1) { r.compressed = true; return r; }
        if (rl < 8 || p + rl > end) return r;
        const uint32_t objSize = le32(b + p);
        const uint32_t pts = le32(b + p + 4);
        const size_t sizePos = p;
        p += rl;
        uint32_t frag = 0;
        if (flags & 1) { if (!take(segType >> 6, 0, frag)) return r; }
        else frag = (uint32_t)(end - p);
        if (frag == 0 || p + frag > end) return r;
        if ((uint64_t)fo + frag > objSize && !out) return r;
        if (out) out->push_back({sid, mo, fo, foWidth, foPos, objSize, sizePos, pts, frag, p});
        p += frag;
        ++actual;
    }
    if (p != end || actual == 0) return r;
    for (size_t i = end; i < size; ++i) if (b[i] != 0) return r;
    r.actual = actual;
    r.ok = true;
    return r;
}

inline RecoveryPlan planAsfPacketGeometry(const Reader& read, int64_t fileSize, const AbortFn* abort) {
    RecoveryPlan p;
    AsfLayout L;
    if (!asfLocate(read, fileSize, L)) return p;
    if (L.broadcast || L.fpPacketCount == 0 || L.fpPacketCount != L.dataPacketCount) return p;
    if (L.dataSize < 50 + L.fpPacketCount || (uint64_t)L.dataPos + L.dataSize > (uint64_t)fileSize) return p;
    if ((L.dataSize - 50) % L.fpPacketCount != 0) return p;
    const uint64_t size = (L.dataSize - 50) / L.fpPacketCount;
    if (size < 64 || size > 65536) return p;
    if (L.minPkt == size && L.maxPkt == size) return p;
    const int64_t start = L.dataPos + 50;
    std::vector<uint64_t> idx;
    if (L.fpPacketCount <= 4096) { for (uint64_t i = 0; i < L.fpPacketCount; ++i) idx.push_back(i); }
    else {
        for (uint64_t i = 0; i < 2048; ++i) idx.push_back(i);
        for (int k = 0; k < 64; ++k) idx.push_back(2048 + (L.fpPacketCount - 2048 - 16) * (uint64_t)k / 64);
        for (uint64_t i = L.fpPacketCount - 16; i < L.fpPacketCount; ++i) idx.push_back(i);
    }
    std::vector<uint8_t> buf;
    for (uint64_t i : idx) {
        if (aborted(abort)) return p;
        buf = readSpan(read, start + (int64_t)(i * size), (size_t)size);
        if (buf.size() != size) return p;
        const AsfPacketInfo pi = asfParsePacket(buf.data(), buf.size(), L.streams);
        if (!pi.ok && !pi.compressed) return p;
    }
    Patch pt; pt.offset = L.filePropsPos + 92; putLe32(pt.bytes, (uint32_t)size); putLe32(pt.bytes, (uint32_t)size);
    p.patches.push_back(pt);
    p.kind = "asf-packet-size";
    p.detail = "File Properties 包长 " + std::to_string(L.minPkt) + "/" + std::to_string(L.maxPkt) + " 与 Data 范围÷包数 " + std::to_string(size) +
               " 矛盾（两份包数 " + std::to_string(L.fpPacketCount) + " 一致，验证 " + std::to_string(idx.size()) + " 个包闭合）→ 改写包长";
    p.damagedFrom = pt.offset; p.damagedUntil = pt.offset + 8;
    return p;
}

inline RecoveryPlan planAsfPayloadCounts(const Reader& read, int64_t fileSize, int64_t fromPos, int64_t window, const AbortFn* abort,
                                         int64_t* scannedUntil = nullptr) {
    RecoveryPlan p;
    AsfLayout L;
    if (!asfLocate(read, fileSize, L)) return p;
    if (!asfFixedGeometry(L)) return p;
    const uint64_t size = L.minPkt;
    const int64_t start = L.dataPos + 50, dataEnd = std::min<int64_t>(fileSize, L.dataPos + (int64_t)L.dataSize);
    if (fromPos < start) fromPos = start;
    uint64_t i = (uint64_t)(fromPos - start) / size;
    const int64_t limit = std::min(dataEnd, fromPos + window);
    std::vector<uint8_t> buf;
    int64_t pos = start + (int64_t)(i * size);
    for (; pos + (int64_t)size <= limit; pos += (int64_t)size) {
        if (aborted(abort)) break;
        buf = readSpan(read, pos, (size_t)size);
        if (buf.size() != size) break;
        const AsfPacketInfo pi = asfParsePacket(buf.data(), buf.size(), L.streams);
        if (!pi.ok || pi.countPos < 0 || pi.actual == pi.declared) continue;
        Patch pt; pt.offset = pos + pi.countPos; pt.bytes = {(uint8_t)((buf[(size_t)pi.countPos] & 0xC0) | (uint8_t)pi.actual)};
        p.patches.push_back(pt);
        if (p.damagedFrom < 0) p.damagedFrom = pos;
        p.damagedUntil = pos + (int64_t)size;
        if (p.patches.size() >= 65536) break;
    }
    if (scannedUntil) *scannedUntil = pos;
    if (p.patches.empty()) return p;
    p.kind = "asf-payload-count";
    p.detail = std::to_string(p.patches.size()) + " 个包的 payload 数量与显式长度链矛盾（链恰好闭合到 packet_end−padding）→ 改写低 6 位";
    return p;
}

struct RmMdpr { int64_t pos = 0; uint32_t size = 0; int streamNumber = 0; std::string mime; std::string fourcc; };

inline bool rmGetNum(const uint8_t* b, size_t n, size_t& p, uint32_t& v) {
    if (p + 2 > n) return false;
    uint32_t x = ((uint32_t)b[p] << 8) | b[p + 1];
    p += 2;
    x &= 0x7FFF;
    if (x >= 0x4000) { v = x - 0x4000; return true; }
    if (p + 2 > n) return false;
    v = (x << 16) | ((uint32_t)b[p] << 8) | b[p + 1];
    p += 2;
    return true;
}

inline bool rmVideoPayloadPlausible(const uint8_t* b, size_t have, size_t total, bool* frameStart = nullptr) {
    if (have < 3 || total < have) return false;
    size_t p = 0;
    const uint8_t hdr = b[p++];
    const int type = hdr >> 6;
    if (frameStart) *frameStart = type != 1;
    if (type != 3) { if (p >= have) return false; ++p; }
    uint32_t len2 = 0, pos = 0;
    if (type != 1) {
        if (!rmGetNum(b, have, p, len2) || !rmGetNum(b, have, p, pos)) return false;
        if (p >= have) return false;
        ++p; // pic_num
    }
    const size_t remaining = total - p;
    if (remaining == 0) return false;
    switch (type) {
    case 2: return pos == remaining && len2 >= pos;
    case 3: return len2 <= remaining;
    case 0: return pos == 0 && len2 > remaining;
    default: return true;
    }
}

inline RecoveryPlan planRmStreamMap(const Reader& read, int64_t fileSize, const AbortFn* abort) {
    RecoveryPlan p;
    auto h = readSpan(read, 0, 8);
    if (h.size() < 8 || std::memcmp(h.data(), ".RMF", 4) != 0) return p;
    std::vector<RmMdpr> mdprs;
    int64_t pos = 0, dataPos = -1;
    for (int hops = 0; hops < 64 && pos + 10 <= fileSize; ++hops) {
        auto c = readSpan(read, pos, 10);
        if (c.size() < 10) return p;
        const uint32_t sz = be32(c.data() + 4);
        if (sz < 10) return p;
        if (std::memcmp(c.data(), "DATA", 4) == 0) { dataPos = pos; break; }
        if (pos + (int64_t)sz > fileSize) return p;
        if (std::memcmp(c.data(), "MDPR", 4) == 0 && sz >= 46) {
            auto m = readSpan(read, pos, std::min<size_t>(sz, 4096));
            if (m.size() < 46) return p;
            RmMdpr d; d.pos = pos; d.size = sz;
            d.streamNumber = (m[10] << 8) | m[11];
            size_t o = 40;
            const size_t nameLen = m[o++];
            if (o + nameLen >= m.size()) return p;
            o += nameLen;
            const size_t mimeLen = m[o++];
            if (o + mimeLen > m.size()) return p;
            d.mime.assign((const char*)m.data() + o, mimeLen);
            o += mimeLen;
            if (o + 4 <= m.size()) {
                const uint32_t codecLen = be32(m.data() + o);
                o += 4;
                if (codecLen >= 8 && o + codecLen <= m.size()) {

                    const std::string cd((const char*)m.data() + o, codecLen);
                    for (const char* f : {"RV10", "RV20", "RV30", "RV40", "dnet", "cook", "sipr", "atrc", "raac", "racp", "ralf", "28_8", "14_4"}) {
                        if (cd.find(f) != std::string::npos) { d.fourcc = f; break; }
                    }
                }
            }
            mdprs.push_back(d);
        }
        pos += sz;
    }
    if (dataPos < 0 || mdprs.empty() || mdprs.size() > 8) return p;

    bool dupDecl = false;
    for (size_t i = 0; i < mdprs.size(); ++i) for (size_t j = i + 1; j < mdprs.size(); ++j) if (mdprs[i].streamNumber == mdprs[j].streamNumber) dupDecl = true;

    auto dh = readSpan(read, dataPos, 18);
    if (dh.size() < 18) return p;
    const uint32_t nPkts = be32(dh.data() + 10);
    struct Group { int packets = 0; int frameStarts = 0; bool videoOk = true; bool ac3 = true; bool constLen = true; int len = -1; };
    std::map<int, Group> groups;
    {
        int64_t q = dataPos + 18;
        const int64_t limit = std::min(fileSize, dataPos + 18 + 4ll * 1024 * 1024);
        for (uint32_t k = 0; k < nPkts && k < 512 && q + 12 <= limit; ++k) {
            if (aborted(abort)) return p;
            auto ph = readSpan(read, q, 13);
            if (ph.size() < 12) break;
            const int ver = (ph[0] << 8) | ph[1];
            const uint32_t len = (ph[2] << 8) | ph[3];
            const int sid = (ph[4] << 8) | ph[5];
            const size_t hdr = ver == 0 ? 12 : ver == 1 ? 13 : 0;
            if (hdr == 0 || len < hdr || q + (int64_t)len > fileSize) break;
            auto body = readSpan(read, q + (int64_t)hdr, std::min<size_t>(len - hdr, 64));
            Group& g = groups[sid];
            ++g.packets;
            bool fs = false;
            if (!rmVideoPayloadPlausible(body.data(), body.size(), len - hdr, &fs)) g.videoOk = false;
            if (fs) ++g.frameStarts;
            if (!(body.size() >= 2 && body[0] == 0x77 && body[1] == 0x0B)) g.ac3 = false;
            if (g.len < 0) g.len = (int)(len - hdr); else if (g.len != (int)(len - hdr)) g.constLen = false;
            q += len;
        }
    }
    if (groups.empty()) return p;
    bool orphanDecl = false, orphanGroup = false;
    for (const RmMdpr& m : mdprs) if (!groups.count(m.streamNumber)) orphanDecl = true;
    for (const auto& kv : groups) { bool declared = false; for (const RmMdpr& m : mdprs) if (m.streamNumber == kv.first) declared = true; if (!declared && kv.second.packets >= 3) orphanGroup = true; }
    if (!dupDecl && !(orphanDecl && orphanGroup)) return p;

    std::vector<int> videoGroups, audioGroups;
    for (const auto& kv : groups) {
        if (kv.second.packets < 3) continue;

        if (kv.second.videoOk && kv.second.frameStarts * 2 >= kv.second.packets) videoGroups.push_back(kv.first);
        else if (kv.second.ac3 || kv.second.constLen) audioGroups.push_back(kv.first);
    }
    std::vector<size_t> videoDecls, audioDecls;
    for (size_t i = 0; i < mdprs.size(); ++i) {
        if (mdprs[i].mime.find("video") != std::string::npos) videoDecls.push_back(i);
        else if (mdprs[i].mime.find("audio") != std::string::npos) audioDecls.push_back(i);
    }

    if (videoDecls.size() != 1 || audioDecls.size() != 1 || videoGroups.size() != 1 || audioGroups.size() != 1) return p;
    size_t declaredGroups = 0;
    for (const auto& kv : groups) if (kv.second.packets >= 3) ++declaredGroups;
    if (declaredGroups != 2) return p;
    if (audioGroups[0] == videoGroups[0]) return p;

    if (mdprs[audioDecls[0]].fourcc == "dnet" && !groups[audioGroups[0]].ac3) return p;
    for (auto pr : {std::make_pair(videoDecls[0], videoGroups[0]), std::make_pair(audioDecls[0], audioGroups[0])}) {
        const RmMdpr& m = mdprs[pr.first];
        if (m.streamNumber == pr.second) continue;
        Patch pt; pt.offset = m.pos + 10; pt.bytes = {(uint8_t)(pr.second >> 8), (uint8_t)pr.second};
        p.patches.push_back(pt);
        p.detail += m.mime + " MDPR 流号 " + std::to_string(m.streamNumber) + "→" + std::to_string(pr.second) + "；";
    }
    if (p.patches.empty()) return p;
    p.kind = "rm-stream-map";
    p.detail = std::string(dupDecl ? "MDPR 流号重复" : "声明轨零包而未声明编号稳定有包") + "：按载荷语法与 MIME 唯一配对 → " + p.detail;
    p.damagedFrom = mdprs.front().pos; p.damagedUntil = dataPos;
    return p;
}

inline bool asfFragsCover(std::vector<std::pair<uint32_t, uint32_t>> iv, uint32_t size) {
    std::sort(iv.begin(), iv.end());
    uint64_t cur = 0;
    for (const auto& x : iv) { if (x.first != cur) return false; cur += x.second; }
    return cur == size;
}

inline void asfJudgeObject(const AsfObjectAcc& o, std::vector<Patch>& patches, int& sizeFixes, int& offsetFixes, int& verified, int& rejected,
                           int64_t* earliestPtsMs = nullptr) {
    if (o.frags.size() < 2) return;
    auto notePts = [&] { if (earliestPtsMs && (*earliestPtsMs < 0 || (int64_t)o.frags[0].pts < *earliestPtsMs)) *earliestPtsMs = o.frags[0].pts; };
    for (size_t i = 1; i < o.frags.size(); ++i) if (o.frags[i].pts != o.frags[0].pts) { ++rejected; return; }
    std::vector<std::pair<uint32_t, uint32_t>> iv;
    uint64_t sum = 0; bool sizesAgree = true;
    for (const AsfObjectFrag& f : o.frags) { iv.push_back({f.fo, f.len}); sum += f.len; if (f.objSize != o.frags[0].objSize) sizesAgree = false; }
    if (!sizesAgree) {
        if (sum == 0 || sum > 0xFFFFFFFFull) { ++rejected; return; }
        const uint32_t canon = (uint32_t)sum;
        int bad = -1, good = 0;
        for (size_t i = 0; i < o.frags.size(); ++i) {
            if (o.frags[i].objSize == canon) ++good;
            else if (bad < 0) bad = (int)i;
            else { ++rejected; return; }
        }
        if (bad < 0 || good == 0 || __builtin_popcount(o.frags[(size_t)bad].objSize ^ canon) != 1 || !asfFragsCover(iv, canon)) { ++rejected; return; }
        Patch pt; pt.offset = o.frags[(size_t)bad].pkt + (int64_t)o.frags[(size_t)bad].sizePos; putLe32(pt.bytes, canon);
        patches.push_back(pt); ++sizeFixes; notePts();
        return;
    }
    const uint32_t size = o.frags[0].objSize;
    if (asfFragsCover(iv, size)) { ++verified; return; }
    if (size == 0 || sum != size) { ++rejected; return; }
    int hits = 0; size_t hitIdx = 0; uint32_t hitFo = 0;
    for (size_t i = 0; i < o.frags.size(); ++i) {
        const AsfObjectFrag& f = o.frags[i];
        for (int bit = 0; bit < f.foWidth * 8; ++bit) {
            std::vector<std::pair<uint32_t, uint32_t>> v = iv;
            v[i].first = f.fo ^ (1u << bit);
            if (asfFragsCover(v, size)) { ++hits; hitIdx = i; hitFo = v[i].first; }
        }
    }
    if (hits != 1) { ++rejected; return; }
    const AsfObjectFrag& f = o.frags[hitIdx];
    Patch pt; pt.offset = f.pkt + (int64_t)f.foPos;
    for (int k = 0; k < f.foWidth; ++k) pt.bytes.push_back((uint8_t)(hitFo >> (8 * k)));
    patches.push_back(pt); ++offsetFixes; notePts();
}

inline RecoveryPlan planAsfObjectFragments(const Reader& read, int64_t fileSize, int64_t fromPos, int64_t window, const AbortFn* abort,
                                           AsfObjectScanState& st, int64_t* scannedUntil = nullptr, int64_t* earliestPtsMs = nullptr) {
    RecoveryPlan p;
    AsfLayout L;
    int64_t earliest = -1;
    if (!asfLocate(read, fileSize, L)) return p;
    if (!asfFixedGeometry(L)) return p;
    const uint64_t size = L.minPkt;
    const int64_t start = L.dataPos + 50, dataEnd = std::min<int64_t>(fileSize, L.dataPos + (int64_t)L.dataSize);
    if (fromPos < start) fromPos = start;
    uint64_t i = (uint64_t)(fromPos - start) / size;
    const int64_t limit = std::min(dataEnd, fromPos + window);
    std::vector<uint8_t> buf;
    std::vector<AsfPayloadRef> refs;
    int sizeFixes = 0, offsetFixes = 0;
    auto close = [&](AsfObjectAcc& acc) { asfJudgeObject(acc, p.patches, sizeFixes, offsetFixes, st.verified, st.rejected, &earliest); acc.frags.clear(); };
    int64_t pos = start + (int64_t)(i * size);
    for (; pos + (int64_t)size <= limit; pos += (int64_t)size) {
        if (aborted(abort)) break;
        buf = readSpan(read, pos, (size_t)size);
        if (buf.size() != size) break;
        refs.clear();
        const AsfPacketInfo pi = asfParsePacket(buf.data(), buf.size(), L.streams, &refs);
        if (!pi.ok) continue;
        for (const AsfPayloadRef& r : refs) {
            AsfObjectAcc& acc = st.open[r.sid];
            if (!acc.frags.empty() && acc.objNum != r.objNum) close(acc);
            acc.objNum = r.objNum;
            AsfObjectFrag f; f.pkt = pos; f.sizePos = r.sizePos; f.foPos = r.foPos; f.foWidth = r.foWidth; f.fo = r.fo; f.len = r.frag; f.objSize = r.objSize; f.pts = r.pts;
            if (acc.frags.size() < 256) acc.frags.push_back(f);
        }
    }
    if (pos >= dataEnd) for (auto& kv : st.open) close(kv.second);
    if (scannedUntil) *scannedUntil = pos;
    if (earliestPtsMs) *earliestPtsMs = earliest >= 0 ? earliest - (int64_t)L.prerollMs : -1;
    if (p.patches.empty()) return p;
    p.kind = "asf-object-fragments";
    p.detail = "ASF 媒体对象跨片证据：" + std::to_string(sizeFixes) + " 份对象大小副本与其余副本 / 片段区间矛盾、" + std::to_string(offsetFixes) +
               " 个片段 offset 让区间不完整 → 单比特唯一候选改回（" + std::to_string(st.verified) + " 个对象核对通过、" + std::to_string(st.rejected) + " 个无法裁决）";
    p.damagedFrom = p.patches.front().offset; p.damagedUntil = p.patches.front().offset;
    for (const Patch& pt : p.patches) { p.damagedFrom = std::min(p.damagedFrom, pt.offset); p.damagedUntil = std::max(p.damagedUntil, pt.offset + (int64_t)pt.bytes.size()); }
    return p;
}

} // namespace spresil
