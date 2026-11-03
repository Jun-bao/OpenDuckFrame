#pragma once

#include "RecoveryMkvContentMap.hpp"

namespace spresil {

struct Mp4KeyEntry {
    int64_t pos = -1;
    int32_t size = 0;
    int64_t tsUs = 0;
};

struct Mp4ContentScanParams {
    int nalLen = 4;
    bool hevc = false;
    size_t prefix = 4096;
};

inline bool mp4SamplePrefixValid(const uint8_t* d, size_t n, int64_t sampleSize, int nalLen, bool /*hevc*/) {
    auto lengthOk = [&](int L) -> bool {
        if (L < 1 || L > 4 || n < (size_t)L || sampleSize <= L) return false;
        uint64_t len = 0;
        bool zero = true;
        for (int i = 0; i < L; ++i) { len = (len << 8) | d[i]; if (d[i]) zero = false; }
        if (zero) return true;
        return len >= 1 && (int64_t)len <= sampleSize - L;
    };
    if (lengthOk(nalLen)) return true;
    return nalLen != 4 && lengthOk(4);
}

inline bool mp4ScanContent(const Reader& read, int64_t fileSize, int64_t from, int64_t limit, const std::vector<Mp4KeyEntry>& entries,
                           const Mp4ContentScanParams& p, const AbortFn* abort, bool stopAfterIsland, MkvContentMap& map) {
    limit = std::min(limit, fileSize);
    if (from >= limit) return true;

    auto lower = std::lower_bound(entries.begin(), entries.end(), from, [](const Mp4KeyEntry& e, int64_t v) { return e.pos < v; });
    MkvIsland island;
    bool inIsland = false;
    int64_t scannedFrom = from;
    auto closeIsland = [&](int64_t endPos, int64_t endTs) {
        if (!inIsland) return;
        island.to = endPos;
        if (endTs >= 0) island.endTimecode = endTs;
        else if (island.clusters.size() >= 2) island.endTimecode = island.lastTimecode + (island.lastTimecode - island.clusters[island.clusters.size() - 2].timecode);
        else island.endTimecode = island.lastTimecode + 2000000;
        map.insertIsland(std::move(island));
        island = MkvIsland{};
        inIsland = false;
    };
    for (auto it = lower; it != entries.end() && it->pos < limit; ++it) {
        if (aborted(abort)) { map.addScanned(scannedFrom, it->pos); return false; }
        if (map.isScanned(it->pos)) {

            closeIsland(it->pos, it->tsUs);
            map.addScanned(scannedFrom, it->pos);
            scannedFrom = it->pos;
            continue;
        }
        if (it->size <= 0) continue;
        auto buf = readSpan(read, it->pos, std::min<size_t>(p.prefix, (size_t)it->size));
        map.bytesRead += (int64_t)buf.size();
        ++map.probes;
        const bool valid = !buf.empty() && mp4SamplePrefixValid(buf.data(), buf.size(), it->size, p.nalLen, p.hevc);
        if (valid) {
            if (!inIsland) { inIsland = true; island.from = it->pos; island.firstTimecode = it->tsUs; }
            MkvIslandCluster c;
            c.pos = it->pos; c.end = it->pos + it->size; c.timecode = it->tsUs; c.keyTimecode = it->tsUs;
            island.lastTimecode = it->tsUs;
            island.clusters.push_back(c);
            continue;
        }
        if (inIsland) {
            closeIsland(it->pos, it->tsUs);
            if (stopAfterIsland) { map.addScanned(scannedFrom, it->pos); return true; }
        }
    }

    if (inIsland) {
        auto next = std::lower_bound(entries.begin(), entries.end(), limit, [](const Mp4KeyEntry& e, int64_t v) { return e.pos < v; });
        closeIsland(next != entries.end() ? next->pos : fileSize, next != entries.end() ? next->tsUs : -1);
    }
    map.addScanned(scannedFrom, limit);
    return true;
}

inline int64_t mp4EstimatePos(const std::vector<Mp4KeyEntry>& entries, int64_t tUs) {
    if (entries.empty()) return 0;
    int64_t pos = entries.front().pos;
    for (const Mp4KeyEntry& e : entries) { if (e.tsUs <= tUs) pos = e.pos; else break; }
    return pos;
}

} // namespace spresil
