#pragma once

#include <cstdint>

namespace sp {

struct ContentCoverage {
    static constexpr int kMaxHoles = 16;
    int64_t startUs = -1;
    int64_t maxPtsUs = -1;
    int holeCount = 0;
    int64_t holeFrom[kMaxHoles] = {};
    int64_t holeTo[kMaxHoles] = {};

    void reset(int64_t start) {
        startUs = start;
        maxPtsUs = start;
        holeCount = 0;
    }

    void note(int64_t ptsUs, int64_t gapTolUs) {
        if (ptsUs < 0) return;
        if (maxPtsUs >= 0 && ptsUs > maxPtsUs + gapTolUs) push(maxPtsUs, ptsUs);
        if (ptsUs > maxPtsUs) maxPtsUs = ptsUs;
    }

    bool coveredThrough(int64_t us, int64_t tolUs) const { return maxPtsUs >= 0 && maxPtsUs >= us - tolUs; }

    bool gapIsHole(int64_t fromUs, int64_t toUs, int64_t tolUs) const {
        for (int i = 0; i < holeCount; ++i)
            if (holeFrom[i] <= fromUs + tolUs && holeTo[i] >= toUs - tolUs) return true;
        return false;
    }

    bool longestHoleOverlap(int64_t fromUs, int64_t toUs, int64_t* outFrom, int64_t* outTo) const {
        int64_t best = 0;
        for (int i = 0; i < holeCount; ++i) {
            const int64_t a = holeFrom[i] > fromUs ? holeFrom[i] : fromUs;
            const int64_t b = holeTo[i] < toUs ? holeTo[i] : toUs;
            if (b - a > best) { best = b - a; *outFrom = a; *outTo = b; }
        }
        return best > 0;
    }

private:
    void push(int64_t from, int64_t to) {
        if (holeCount == kMaxHoles) {
            for (int i = 1; i < kMaxHoles; ++i) { holeFrom[i - 1] = holeFrom[i]; holeTo[i - 1] = holeTo[i]; }
            holeCount--;
        }
        holeFrom[holeCount] = from;
        holeTo[holeCount] = to;
        holeCount++;
    }
};

enum class GapVerdict : uint8_t { FillSilence = 0, SkipHole = 1, Undecided = 2 };

struct GapPlan {
    GapVerdict verdict = GapVerdict::FillSilence;
    int64_t skipFromUs = 0;
    int64_t skipToUs = 0;
};

inline GapPlan planSkip(int64_t fromUs, int64_t toUs, int64_t s0, int64_t s1, int64_t gapTolUs, int64_t tolUs) {
    if (s0 <= fromUs + tolUs) s0 = fromUs;
    if (s1 >= toUs - tolUs) s1 = toUs;
    if (s1 - s0 < gapTolUs) return {};
    return {GapVerdict::SkipHole, s0, s1};
}

inline GapPlan judgeAudioGap(int64_t fromUs, int64_t toUs, int64_t gapTolUs, bool hasVideo,
                             const ContentCoverage& video, int64_t tolUs) {
    if (toUs - fromUs < gapTolUs) return {};
    if (!hasVideo) return {GapVerdict::SkipHole, fromUs, toUs};
    if (!video.coveredThrough(toUs, tolUs)) return {GapVerdict::Undecided, 0, 0};
    int64_t s0 = 0, s1 = 0;
    if (!video.longestHoleOverlap(fromUs, toUs, &s0, &s1)) return {};
    return planSkip(fromUs, toUs, s0, s1, gapTolUs, tolUs);
}

inline GapPlan planTrailingHole(int64_t fromUs, int64_t toUs, int64_t maxPtsUs, int64_t gapTolUs, int64_t tolUs) {
    const int64_t s0 = maxPtsUs > fromUs ? maxPtsUs : fromUs;
    return planSkip(fromUs, toUs, s0, toUs, gapTolUs, tolUs);
}

} // namespace sp
