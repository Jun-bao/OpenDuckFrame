#pragma once

#include "RecoveryMatroska.hpp"

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <utility>
#include <vector>

namespace spresil {

struct MkvIslandCluster {
    int64_t pos = -1;
    int64_t end = -1;
    int64_t timecode = -1;
    int64_t keyTimecode = -1;
};

struct MkvIsland {
    int64_t from = -1;
    int64_t to = -1;
    int64_t firstTimecode = -1;
    int64_t lastTimecode = -1;
    int64_t endTimecode = -1;
    bool endsAtLevel1 = false;
    std::vector<MkvIslandCluster> clusters;

    const MkvIslandCluster& entryCluster() const {
        for (const MkvIslandCluster& c : clusters) if (c.keyTimecode >= 0) return c;
        return clusters.front();
    }
    bool hasKey() const { for (const MkvIslandCluster& c : clusters) if (c.keyTimecode >= 0) return true; return false; }
};

struct MkvContentMap {
    std::vector<MkvIsland> islands;
    std::vector<std::pair<int64_t, int64_t>> scanned;
    int64_t bytesRead = 0;
    int probes = 0;
    int64_t timestampScale = 1000000;

    bool isScanned(int64_t pos) const {
        for (const auto& r : scanned) if (pos >= r.first && pos < r.second) return true;
        return false;
    }
    void addScanned(int64_t a, int64_t b) {
        if (b <= a) return;
        scanned.push_back({a, b});
        std::sort(scanned.begin(), scanned.end());
        std::vector<std::pair<int64_t, int64_t>> m;
        for (const auto& r : scanned) {
            if (!m.empty() && r.first <= m.back().second) m.back().second = std::max(m.back().second, r.second);
            else m.push_back(r);
        }
        scanned.swap(m);
    }

    void removeScanned(int64_t a, int64_t b) {
        if (b <= a) return;
        std::vector<std::pair<int64_t, int64_t>> m;
        for (const auto& r : scanned) {
            if (r.second <= a || r.first >= b) { m.push_back(r); continue; }
            if (r.first < a) m.push_back({r.first, a});
            if (r.second > b) m.push_back({b, r.second});
        }
        scanned.swap(m);
    }
    int islandAtPos(int64_t pos) const {
        for (size_t i = 0; i < islands.size(); ++i) if (pos >= islands[i].from && pos < islands[i].to) return (int)i;
        return -1;
    }
    int firstIslandAtOrAfterPos(int64_t pos) const {
        for (size_t i = 0; i < islands.size(); ++i) if (islands[i].to > pos) return (int)i;
        return -1;
    }

    int64_t islandEndTimecode(const MkvIsland& is) const {
        if (is.endTimecode >= 0) return is.endTimecode;
        int64_t dur = 5000000000LL / std::max<int64_t>(1, timestampScale); // 5 s
        if (is.clusters.size() >= 2) {
            const int64_t d = is.clusters.back().timecode - is.clusters[is.clusters.size() - 2].timecode;
            if (d > 0) dur = d;
        }
        return is.lastTimecode + dur;
    }
    int islandAtTimecode(int64_t tc) const {
        for (size_t i = 0; i < islands.size(); ++i)
            if (tc >= islands[i].firstTimecode && tc < islandEndTimecode(islands[i])) return (int)i;
        return -1;
    }
    int firstIslandAfterTimecode(int64_t tc) const {
        for (size_t i = 0; i < islands.size(); ++i) if (islands[i].firstTimecode > tc) return (int)i;
        return -1;
    }
    int lastIslandBeforeTimecode(int64_t tc) const {
        for (size_t i = islands.size(); i-- > 0;) if (islands[i].firstTimecode <= tc) return (int)i;
        return -1;
    }

    void insertIsland(MkvIsland is) {
        for (size_t i = 0; i < islands.size();) {
            const MkvIsland& x = islands[i];
            if (x.from < is.to && is.from < x.to) {
                if (x.from <= is.from && x.to >= is.to) return;
                islands.erase(islands.begin() + (long)i);
            } else ++i;
        }
        auto it = std::lower_bound(islands.begin(), islands.end(), is.from,
                                   [](const MkvIsland& a, int64_t p) { return a.from < p; });
        islands.insert(it, std::move(is));
    }
};

struct MkvContentScanParams {

    int64_t stride = 8ll * 1024 * 1024;
    int64_t probe = 1024 * 1024;
    int minChain = 3;
    int64_t maxClusterBytes = 64ll * 1024 * 1024;
    int64_t maxIslandBytes = 0;
    int videoTrack = 0;

    int64_t clusterPrefix = 0;
};

inline bool mkvProbeHasBlockChain(const uint8_t* d, size_t n, const std::vector<int>& tracks, int minChain, size_t* firstOff) {
    if (n < 9) return false;

    for (size_t i = 0; i + 8 < n; ++i) {
        const uint8_t* a3 = (const uint8_t*)memchr(d + i, 0xA3, n - 8 - i);
        const uint8_t* a0 = (const uint8_t*)memchr(d + i, 0xA0, a3 ? (size_t)(a3 - d - i) : n - 8 - i);
        const uint8_t* c = a0 ? a0 : a3;
        if (!c) return false;
        i = (size_t)(c - d);
        if (*c == 0xA3) {

            const int sl = ebmlVintLen(d[i + 1]);
            if (sl == 0 || sl > 4 || i + 1 + (size_t)sl + 3 >= n) continue;
            const uint8_t t = d[i + 1 + (size_t)sl];
            if ((t & 0xF0) != 0x80 || (t & 0x0F) == 0 || (d[i + 1 + (size_t)sl + 3] & 0x70) != 0) continue;
        }
        size_t off = i;
        int links = 0;
        while (off + 6 < n && links < minChain) {
            const uint8_t bid = d[off];
            if (bid != 0xA3 && bid != 0xA0) break;
            const int64_t total = mkvValidBlockAt(d + off, n - off, tracks, (int64_t)(n - off));
            if (total <= 0) break;
            ++links;
            off += (size_t)total;
        }
        if (links >= minChain) { if (firstOff) *firstOff = i; return true; }
    }
    return false;
}

inline int64_t mkvProbeClusterHeadOffset(const uint8_t* d, size_t n) {
    static const uint8_t cid[4] = {0x1F, 0x43, 0xB6, 0x75};
    for (size_t i = 0; i + 8 < n; ++i) {
        const uint8_t* c = (const uint8_t*)memchr(d + i, 0x1F, n - 8 - i);
        if (!c) return -1;
        i = (size_t)(c - d);
        if (std::memcmp(d + i, cid, 4) != 0) continue;
        uint64_t sz = 0; bool un = false;
        const int sl = ebmlReadSize(d + i + 4, n - i - 4, sz, un);
        if (sl == 0) continue;
        const size_t o = i + 4 + (size_t)sl;
        if (o + 2 >= n) continue;
        size_t p = o;
        if (d[p] == 0xBF && p + 6 < n && d[p + 1] == 0x84) p += 6;
        if (d[p] != 0xE7) continue;
        uint64_t tl = 0; bool tu = false;
        const int tsl = ebmlReadSize(d + p + 1, n - p - 1, tl, tu);
        if (tsl == 0 || tu || tl == 0 || tl > 8) continue;
        return (int64_t)i;
    }
    return -1;
}

inline int64_t mkvReadTimestampScale(const Reader& read, int64_t fileSize) {
    auto head = readSpan(read, 0, (size_t)std::min<int64_t>(fileSize, 1024 * 1024));
    static const uint8_t infoId[4] = {0x15, 0x49, 0xA9, 0x66};
    for (size_t i = 0; i + 4 < head.size(); ++i) {
        if (std::memcmp(head.data() + i, infoId, 4) != 0) continue;
        uint64_t sz = 0; bool un = false;
        const int sl = ebmlReadSize(head.data() + i + 4, head.size() - i - 4, sz, un);
        if (sl == 0 || un || sz > 65536) continue;
        const size_t body = i + 4 + (size_t)sl;
        const size_t end = std::min(head.size(), body + (size_t)sz);
        for (size_t j = body; j + 4 < end; ++j) {
            if (head[j] != 0x2A || head[j + 1] != 0xD7 || head[j + 2] != 0xB1) continue;
            uint64_t vl = 0; bool vu = false;
            const int vsl = ebmlReadSize(head.data() + j + 3, end - j - 3, vl, vu);
            if (vsl == 0 || vu || vl == 0 || vl > 8 || j + 3 + (size_t)vsl + vl > end) continue;
            uint64_t v = 0;
            for (uint64_t k = 0; k < vl; ++k) v = (v << 8) | head[j + 3 + (size_t)vsl + k];
            return v > 0 ? (int64_t)v : 1000000;
        }
        break;
    }
    return 1000000;
}

inline int32_t mkvClusterFirstVideoKeyRelTc(const uint8_t* buf, size_t len, const std::vector<int>& tracks, int videoTrack) {
    size_t off = 0;
    while (off < len) {
        const uint8_t id0 = buf[off];
        int64_t total = 0;
        if (id0 == 0xA3 || id0 == 0xA0 || id0 == 0xEC) {
            MkvBlockInfo bi;
            if (!mkvParseBlock(buf + off, len - off, tracks, (int64_t)(len - off), bi)) return INT32_MIN;
            total = bi.total;
            if (id0 != 0xEC && bi.track == videoTrack) {
                bool key = false;
                if (!bi.group) key = (bi.flags & 0x80) != 0;
                else {

                    uint64_t gs = 0; bool gu = false;
                    const int gsl = ebmlReadSize(buf + off + 1, len - off - 1, gs, gu);
                    const size_t gb = off + 1 + (size_t)gsl, ge = std::min(len, gb + (size_t)gs);
                    bool ref = false;
                    size_t o = gb;
                    for (int k = 0; k < 16 && o < ge; ++k) {
                        const int idLen = ebmlVintLen(buf[o]);
                        if (idLen == 0 || o + (size_t)idLen >= ge) break;
                        uint64_t es = 0; bool eu = false;
                        const int esl = ebmlReadSize(buf + o + idLen, ge - o - idLen, es, eu);
                        if (esl == 0 || eu) break;
                        if (idLen == 1 && buf[o] == 0xFB) ref = true;
                        o += (size_t)idLen + (size_t)esl + (size_t)es;
                    }
                    key = !ref;
                }
                if (key) return bi.relTc;
            }
        } else {
            const int idLen = ebmlVintLen(id0);
            const bool known = (idLen == 1 && (id0 == 0xBF || id0 == 0xE7 || id0 == 0xA7 || id0 == 0xAB || id0 == 0xAF)) ||
                               (idLen == 2 && off + 1 < len && id0 == 0x58 && buf[off + 1] == 0x54);
            if (!known || off + (size_t)idLen >= len) return INT32_MIN;
            uint64_t es = 0; bool eu = false;
            const int esl = ebmlReadSize(buf + off + idLen, len - off - idLen, es, eu);
            if (esl == 0 || eu) return INT32_MIN;
            total = idLen + esl + (int64_t)es;
        }
        if (total <= 0) return INT32_MIN;
        off += (size_t)total;
    }
    return INT32_MIN;
}

inline bool mkvClusterPrefixWalk(const uint8_t* buf, size_t n, int64_t bodyLen, const std::vector<int>& tracks, int videoTrack,
                                 int32_t* keyRel) {
    if (keyRel) *keyRel = INT32_MIN;
    size_t off = 0;
    int blocks = 0;
    while (off < n) {
        const uint8_t id0 = buf[off];
        if (id0 == 0xA3 || id0 == 0xA0 || id0 == 0xEC) {
            if (off + 6 > n) return blocks > 0;
            uint64_t size = 0; bool un = false;
            const int sl = ebmlReadSize(buf + off + 1, n - off - 1, size, un);
            if (sl == 0 || un) return false;
            const int64_t total = 1 + sl + (int64_t)size;
            if (total > bodyLen - (int64_t)off || size > 32ull * 1024 * 1024) return false;
            if ((size_t)total <= n - off) {
                MkvBlockInfo bi;
                if (!mkvParseBlock(buf + off, n - off, tracks, (int64_t)(n - off), bi)) return false;
                if (id0 != 0xEC) ++blocks;
                if (keyRel && *keyRel == INT32_MIN && id0 == 0xA3 && bi.track == videoTrack && (bi.flags & 0x80)) *keyRel = bi.relTc;
                if (keyRel && *keyRel == INT32_MIN && id0 == 0xA0 && bi.track == videoTrack) {

                    const size_t gb = off + 1 + (size_t)sl, ge = gb + (size_t)size;
                    bool ref = false;
                    for (size_t o = gb; o < ge;) {
                        const int idLen = ebmlVintLen(buf[o]);
                        if (idLen == 0 || o + (size_t)idLen >= ge) break;
                        uint64_t es = 0; bool eu = false;
                        const int esl = ebmlReadSize(buf + o + idLen, ge - o - idLen, es, eu);
                        if (esl == 0 || eu) break;
                        if (idLen == 1 && buf[o] == 0xFB) ref = true;
                        o += (size_t)idLen + (size_t)esl + (size_t)es;
                    }
                    if (!ref) *keyRel = bi.relTc;
                }
                off += (size_t)total;
                continue;
            }

            if (id0 == 0xA3) {
                const size_t b = off + 1 + (size_t)sl;
                if (b + 4 > n) return blocks > 0;
                uint64_t track = 0; bool tu = false;
                const int tl = ebmlReadSize(buf + b, n - b, track, tu);
                if (tl == 0 || tl > 4 || tu || b + (size_t)tl + 3 > n) return blocks > 0;
                bool known = false;
                for (int t : tracks) if ((uint64_t)t == track) known = true;
                if (!known || (buf[b + tl + 2] & 0x70) != 0) return false;
                if (keyRel && *keyRel == INT32_MIN && (int)track == videoTrack && (buf[b + tl + 2] & 0x80))
                    *keyRel = (int16_t)(((uint16_t)buf[b + tl] << 8) | buf[b + tl + 1]);
                ++blocks;
            }
            return true;
        }
        const int idLen = ebmlVintLen(id0);
        const bool known = (idLen == 1 && (id0 == 0xBF || id0 == 0xE7 || id0 == 0xA7 || id0 == 0xAB || id0 == 0xAF)) ||
                           (idLen == 2 && off + 1 < n && id0 == 0x58 && buf[off + 1] == 0x54);
        if (!known || off + (size_t)idLen >= n) return false;
        uint64_t es = 0; bool eu = false;
        const int esl = ebmlReadSize(buf + off + idLen, n - off - idLen, es, eu);
        if (esl == 0 || eu || (int64_t)idLen + esl + (int64_t)es > bodyLen - (int64_t)off) return false;
        off += (size_t)idLen + (size_t)esl + (size_t)es;
    }
    return true;
}

inline bool mkvIsLevel1Id(const uint8_t* p) {
    static const uint8_t ids[][4] = {{0x1C, 0x53, 0xBB, 0x6B}, {0x12, 0x54, 0xC3, 0x67}, {0x11, 0x4D, 0x9B, 0x74}, {0x19, 0x41, 0xA4, 0x69},
                                     {0x10, 0x43, 0xA7, 0x70}, {0x15, 0x49, 0xA9, 0x66}, {0x16, 0x54, 0xAE, 0x6B}};
    for (const auto& id : ids) if (std::memcmp(p, id, 4) == 0) return true;
    return false;
}

inline bool mkvWalkIsland(const Reader& read, int64_t fileSize, int64_t cpos, const std::vector<int>& tracks,
                          const MkvContentScanParams& p, const AbortFn* abort, MkvIsland& out, int64_t* bytesRead) {
    out = MkvIsland{};
    out.from = cpos;
    int64_t cur = cpos;
    for (int n = 0; n < 1000000 && cur + 8 <= fileSize; ++n) {
        if (aborted(abort)) return false;
        MkvClusterHead h;
        if (!mkvReadClusterHead(read, cur, h)) { out.to = cur; break; }
        const int64_t tc = mkvReadClusterTimecode(read, cur);
        if (tc < 0) { out.to = cur; break; }
        int64_t end = h.unknownSize ? -1 : h.dataStart + (int64_t)h.size;
        if (h.unknownSize) {

            const int64_t nxt = mkvFindNextClusterHead(read, h.dataStart, fileSize, p.maxClusterBytes, abort);
            if (nxt < 0) { out.to = cur; break; }
            end = nxt;
        }
        if (end <= h.dataStart || end - h.dataStart > p.maxClusterBytes || end > fileSize) { out.to = cur; break; }
        const int64_t bodyLen = end - h.dataStart;
        MkvIslandCluster c;
        c.pos = cur; c.end = end; c.timecode = tc;
        bool closed = false;
        std::vector<uint8_t> nid;
        if (p.clusterPrefix > 0 && !h.unknownSize && bodyLen > p.clusterPrefix) {

            auto pre = readSpan(read, h.dataStart, (size_t)p.clusterPrefix);
            if (bytesRead) *bytesRead += (int64_t)pre.size();
            int32_t rel = INT32_MIN;
            bool ok = (int64_t)pre.size() == p.clusterPrefix && mkvClusterPrefixWalk(pre.data(), pre.size(), bodyLen, tracks, p.videoTrack, &rel);
            if (ok && end + 4 <= fileSize) {
                nid = readSpan(read, end, 4);
                ok = nid.size() == 4 && (std::memcmp(nid.data(), "\x1F\x43\xB6\x75", 4) == 0 || mkvIsLevel1Id(nid.data()));
            }
            if (ok) {
                closed = true;
                if (p.videoTrack > 0 && rel != INT32_MIN) c.keyTimecode = tc + rel;
            }
        }
        if (!closed) {
            auto body = readSpan(read, h.dataStart, (size_t)bodyLen);
            if (bytesRead) *bytesRead += (int64_t)body.size();
            if ((int64_t)body.size() != bodyLen) { out.to = cur; break; }
            size_t brokenAt = 0, lastOk = 0;
            closed = mkvClusterChildrenClose(body.data(), body.size(), 0, tracks, &brokenAt, &lastOk);
            if (p.videoTrack > 0) {
                const int32_t rel = mkvClusterFirstVideoKeyRelTc(body.data(), closed ? body.size() : brokenAt, tracks, p.videoTrack);
                if (rel != INT32_MIN) c.keyTimecode = tc + rel;
            }
            if (out.clusters.empty()) out.firstTimecode = tc;
            out.lastTimecode = tc;
            out.clusters.push_back(c);
            if (!closed) { out.to = h.dataStart + (int64_t)brokenAt; break; }
        } else {
            if (out.clusters.empty()) out.firstTimecode = tc;
            out.lastTimecode = tc;
            out.clusters.push_back(c);
        }
        out.to = end;
        cur = end;
        if (p.maxIslandBytes > 0 && cur - out.from >= p.maxIslandBytes) break;
        if (cur + 4 > fileSize) break;
        if (nid.size() < 4) nid = readSpan(read, cur, 4);
        if (nid.size() < 4) break;
        if (std::memcmp(nid.data(), "\x1F\x43\xB6\x75", 4) == 0) continue;
        out.endsAtLevel1 = mkvIsLevel1Id(nid.data());
        break;
    }
    return !out.clusters.empty();
}

inline bool mkvScanContent(const Reader& read, int64_t fileSize, int64_t from, int64_t limit, const std::vector<int>& tracks,
                           const MkvContentScanParams& p, const AbortFn* abort, bool stopAfterIsland, MkvContentMap& map) {
    limit = std::min(limit, fileSize);
    int64_t pos = std::max<int64_t>(0, from);
    int64_t segStart = pos;
    int64_t lastMiss = pos;
    auto commit = [&](int64_t until) { if (until > segStart) map.addScanned(segStart, until); segStart = until; };
    while (pos < limit) {
        if (aborted(abort)) { commit(pos); return false; }

        bool skipped = false;
        for (const auto& r : map.scanned) {
            if (pos >= r.first && pos < r.second) { commit(pos); pos = r.second; segStart = pos; lastMiss = pos; skipped = true; break; }
        }
        if (skipped) continue;
        const int64_t is = map.islandAtPos(pos);
        if (is >= 0) { commit(pos); pos = map.islands[(size_t)is].to; segStart = pos; lastMiss = pos; continue; }
        const size_t want = (size_t)std::min<int64_t>(p.probe, limit - pos);
        auto buf = readSpan(read, pos, want);
        map.bytesRead += (int64_t)buf.size();
        ++map.probes;
        if (buf.empty()) { commit(pos); return true; }
        size_t chainOff = 0;
        const int64_t headOff = mkvProbeClusterHeadOffset(buf.data(), buf.size());
        const bool chain = mkvProbeHasBlockChain(buf.data(), buf.size(), tracks, p.minChain, &chainOff);
        if (headOff < 0 && !chain) {
            lastMiss = pos + (int64_t)buf.size();
            pos += p.stride;
            continue;
        }

        int64_t cpos = headOff >= 0 ? pos + headOff : -1;
        {
            const int64_t searchFrom = std::max<int64_t>(segStart, lastMiss);
            const int64_t earlier = mkvFindNextClusterHead(read, searchFrom, fileSize, (cpos >= 0 ? cpos : pos + (int64_t)buf.size()) - searchFrom + 4, abort);
            if (aborted(abort)) { commit(pos); return false; }
            if (earlier >= 0 && (cpos < 0 || earlier < cpos)) cpos = earlier;
        }
        if (cpos < 0) {

            cpos = mkvFindNextClusterHead(read, pos + (int64_t)buf.size(), fileSize, p.stride * 2, abort);
            if (aborted(abort)) { commit(pos); return false; }
        }
        if (cpos < 0) { lastMiss = pos + (int64_t)buf.size(); pos += p.stride; continue; }
        MkvIsland island;
        if (!mkvWalkIsland(read, fileSize, cpos, tracks, p, abort, island, &map.bytesRead)) {
            if (aborted(abort)) { commit(pos); return false; }
            lastMiss = cpos + 4;
            pos = cpos + 4;
            continue;
        }
        const int64_t islandEnd = island.to;
        commit(islandEnd);
        map.insertIsland(std::move(island));
        pos = islandEnd;
        segStart = pos;
        lastMiss = pos;
        if (stopAfterIsland) return true;
    }
    commit(std::min(pos, limit));
    return true;
}

inline std::vector<std::pair<int64_t, int64_t>> mkvContentGaps(const MkvContentMap& map, int64_t fileSize,
                                                                const std::vector<std::pair<int64_t, int64_t>>& exclude,
                                                                int64_t floorPos = -1) {
    std::vector<std::pair<int64_t, int64_t>> gaps;
    if (map.islands.empty()) return gaps;
    const int64_t floor = floorPos >= 0 ? floorPos : map.islands.front().from;
    for (const auto& r : map.scanned) {
        int64_t a = std::max(r.first, floor);
        const int64_t b = std::min(r.second, fileSize);
        while (a < b) {
            const int is = map.islandAtPos(a);
            if (is >= 0) { a = map.islands[(size_t)is].to; continue; }
            int64_t e = b;
            for (const MkvIsland& x : map.islands) if (x.from > a && x.from < e) e = x.from;

            int64_t s = a;
            std::vector<std::pair<int64_t, int64_t>> pieces = {{s, e}};
            for (const auto& ex : exclude) {
                std::vector<std::pair<int64_t, int64_t>> next;
                for (const auto& pc : pieces) {
                    if (ex.second <= pc.first || ex.first >= pc.second) { next.push_back(pc); continue; }
                    if (pc.first < ex.first) next.push_back({pc.first, ex.first});
                    if (ex.second < pc.second) next.push_back({ex.second, pc.second});
                }
                pieces.swap(next);
            }
            for (const auto& pc : pieces) if (pc.second > pc.first) gaps.push_back(pc);
            a = e;
        }
    }
    std::sort(gaps.begin(), gaps.end());
    return gaps;
}

inline std::vector<std::pair<int64_t, int64_t>> mkvNoContentSpans(const MkvContentMap& map, int64_t fileSize, int64_t durationTc) {
    std::vector<std::pair<int64_t, int64_t>> out;
    if (map.islands.empty()) return out;
    auto fullyScanned = [&](int64_t a, int64_t b) {
        for (int64_t p = a; p < b;) {
            bool in = false;
            for (const auto& r : map.scanned) if (p >= r.first && p < r.second) { p = r.second; in = true; break; }
            if (!in) return false;
        }
        return true;
    };
    const MkvIsland& first = map.islands.front();
    if (first.firstTimecode > 0 && fullyScanned(0, first.from)) out.push_back({0, first.firstTimecode});
    for (size_t i = 0; i + 1 < map.islands.size(); ++i) {
        const MkvIsland& a = map.islands[i];
        const MkvIsland& b = map.islands[i + 1];
        if (a.to >= b.from || !fullyScanned(a.to, b.from)) continue;
        const int64_t t0 = map.islandEndTimecode(a), t1 = b.firstTimecode;
        if (t1 > t0) out.push_back({t0, t1});
    }
    const MkvIsland& last = map.islands.back();
    if (durationTc > 0 && last.to < fileSize && fullyScanned(last.to, fileSize)) {
        const int64_t t0 = map.islandEndTimecode(last);
        if (durationTc > t0) out.push_back({t0, durationTc});
    }
    return out;
}

} // namespace spresil
