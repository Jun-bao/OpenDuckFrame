#pragma once

#include "RecoveryMkvContentMap.hpp"

namespace spresil {

struct TsContentScanParams {
    int64_t stride = 8ll * 1024 * 1024;
    int64_t probe = 4096;
    int minSync = 16;
    int videoPid = -1;
    int64_t ptsWindow = 1024 * 1024;
};

inline bool tsProbeSync(const uint8_t* d, size_t n, int minSync, int* strideOut, size_t* offOut) {
    static const int strides[] = {188, 192, 204};
    for (int s : strides) {
        if (minSync < 1 || n < (size_t)s * (size_t)(minSync - 1) + 1) continue;
        for (size_t o = 0; o + (size_t)s * (size_t)(minSync - 1) < n; ++o) {
            if (d[o] != 0x47) continue;
            int run = 1;
            while (run < minSync && d[o + (size_t)run * (size_t)s] == 0x47) ++run;
            if (run >= minSync) { if (strideOut) *strideOut = s; if (offOut) *offOut = o; return true; }
        }
    }
    return false;
}

inline int64_t tsPesPtsUs(const uint8_t* p, size_t n) {
    if (n < 14 || p[0] != 0 || p[1] != 0 || p[2] != 1) return -1;
    const uint8_t sid = p[3];
    if (sid == 0xBC || sid == 0xBE || sid == 0xBF || sid == 0xF0 || sid == 0xF1 || sid == 0xF2 || sid == 0xF8 || sid == 0xFF) return -1;
    if ((p[6] & 0xC0) != 0x80 || !(p[7] & 0x80)) return -1;
    const uint8_t* q = p + 9;
    if ((q[0] & 0xF1) != 0x21 && (q[0] & 0xF1) != 0x31) return -1;
    if (!(q[2] & 1) || !(q[4] & 1)) return -1;
    const int64_t pts = ((int64_t)(q[0] >> 1 & 7) << 30) | ((int64_t)q[1] << 22) | ((int64_t)(q[2] >> 1) << 15) | ((int64_t)q[3] << 7) | (q[4] >> 1);
    return pts * 1000 / 90;
}

inline int64_t tsIslandPtsUs(const Reader& read, int64_t from, int64_t to, int videoPid, int64_t window, int minSync, bool last) {
    if (to <= from) return -1;
    int64_t a = from, b = to;
    if (last) a = std::max(from, to - window); else b = std::min(to, from + window);
    auto buf = readSpan(read, a, (size_t)std::max<int64_t>(0, b - a));
    int stride = 0; size_t off = 0;
    if (buf.empty() || !tsProbeSync(buf.data(), buf.size(), minSync, &stride, &off)) return -1;
    int64_t found = -1;
    for (; off + (size_t)stride <= buf.size(); off += (size_t)stride) {
        const uint8_t* q = buf.data() + off;
        if (q[0] != 0x47) {
            int st2 = 0; size_t o2 = 0;
            if (!tsProbeSync(q, buf.size() - off, minSync, &st2, &o2)) break;
            off += o2; stride = st2;
            q = buf.data() + off;
        }
        if (!(q[1] & 0x40)) continue;
        const int pid = ((q[1] & 0x1f) << 8) | q[2];
        if (videoPid >= 0 && pid != videoPid) continue;
        const int afc = (q[3] >> 4) & 3;
        if (!(afc & 1)) continue;
        const int pl = (afc & 2) ? 5 + q[4] : 4;
        if (pl >= 188) continue;
        const int64_t pts = tsPesPtsUs(q + pl, 188 - (size_t)pl);
        if (pts < 0) continue;
        found = pts;
        if (!last) return found;
    }
    return found;
}

inline int64_t tsBoundarySearch(const Reader& read, int64_t lo, int64_t hi, const TsContentScanParams& p, const AbortFn* abort,
                                bool loHasSync, int64_t* bytesRead, int* probes) {
    while (hi - lo > p.probe) {
        if (aborted(abort)) return -1;
        const int64_t mid = lo + (hi - lo) / 2;
        auto buf = readSpan(read, mid, (size_t)p.probe);
        if (bytesRead) *bytesRead += (int64_t)buf.size();
        if (probes) ++*probes;
        const bool sync = !buf.empty() && tsProbeSync(buf.data(), buf.size(), p.minSync, nullptr, nullptr);
        if (sync == loHasSync) lo = mid; else hi = mid;
    }
    return loHasSync ? hi : lo;
}

inline bool tsScanContent(const Reader& read, int64_t fileSize, int64_t from, int64_t limit, const TsContentScanParams& p,
                          const AbortFn* abort, bool stopAfterIsland, MkvContentMap& map) {
    limit = std::min(limit, fileSize);
    int64_t pos = std::max<int64_t>(0, from);
    int64_t segStart = pos;
    int64_t lastMiss = -1;
    auto commit = [&](int64_t until) { if (until > segStart) map.addScanned(segStart, until); segStart = until; };
    while (pos < limit) {
        if (aborted(abort)) { commit(pos); return false; }
        bool skipped = false;
        for (const auto& r : map.scanned) {
            if (pos >= r.first && pos < r.second) { commit(pos); pos = r.second; segStart = pos; lastMiss = -1; skipped = true; break; }
        }
        if (skipped) continue;
        const int is = map.islandAtPos(pos);
        if (is >= 0) { commit(pos); pos = map.islands[(size_t)is].to; segStart = pos; lastMiss = -1; continue; }
        auto buf = readSpan(read, pos, (size_t)std::min<int64_t>(p.probe, limit - pos));
        map.bytesRead += (int64_t)buf.size();
        ++map.probes;
        if (buf.empty()) { commit(pos); return true; }
        if (!tsProbeSync(buf.data(), buf.size(), p.minSync, nullptr, nullptr)) { lastMiss = pos; pos += p.stride; continue; }

        int64_t start = pos;
        if (lastMiss >= 0 && lastMiss >= segStart) {
            const int64_t b = tsBoundarySearch(read, lastMiss, pos, p, abort, false, &map.bytesRead, &map.probes);
            if (b < 0) { commit(pos); return false; }
            start = b;
        } else if (segStart < pos) start = segStart;

        int64_t good = pos, bad = -1;
        for (int64_t q = pos + p.stride; q < fileSize; q += p.stride) {
            if (aborted(abort)) { commit(pos); return false; }
            auto w = readSpan(read, q, (size_t)std::min<int64_t>(p.probe, fileSize - q));
            map.bytesRead += (int64_t)w.size();
            ++map.probes;
            if (!w.empty() && tsProbeSync(w.data(), w.size(), p.minSync, nullptr, nullptr)) { good = q; continue; }
            bad = q;
            break;
        }
        int64_t end = fileSize;
        if (bad >= 0) {
            end = tsBoundarySearch(read, good, bad, p, abort, true, &map.bytesRead, &map.probes);
            if (end < 0) { commit(pos); return false; }
        }
        MkvIsland island;
        island.from = start;
        island.to = end;
        const int64_t first = tsIslandPtsUs(read, start, end, p.videoPid, p.ptsWindow, p.minSync, false);
        const int64_t lastPts = tsIslandPtsUs(read, start, end, p.videoPid, p.ptsWindow, p.minSync, true);
        map.bytesRead += 2 * std::min<int64_t>(p.ptsWindow, end - start);
        island.firstTimecode = first >= 0 ? first : 0;
        island.lastTimecode = lastPts >= 0 ? lastPts : island.firstTimecode;
        island.endTimecode = island.lastTimecode + 40000;
        MkvIslandCluster c;
        c.pos = start; c.end = end; c.timecode = island.firstTimecode; c.keyTimecode = island.firstTimecode;
        island.clusters.push_back(c);
        commit(end);
        map.insertIsland(std::move(island));
        pos = end;
        segStart = pos;
        lastMiss = -1;
        if (stopAfterIsland) return true;
    }
    commit(std::min(pos, limit));
    return true;
}

} // namespace spresil
