// Platform-independent frame-budget planner. Useful consecutive pairs form
// segments, selected by value when their jobs fit the measured session timeline.
// Started segments stay pinned. The next job is the earliest planned pair;
// memory and concurrency policies keep lookahead bounded.
#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <vector>

namespace sp {

enum class SPBudgetPairState : uint8_t {
    Idle = 0,
    Planned = 1,
    InFlight = 2,
    Ready = 3,
    Skipped = 4,
};

struct SPBudgetPair {
    float benefit = 0.0f;
    bool cut = false;
    bool eligible = true;
    bool probed = false;
    SPBudgetPairState state = SPBudgetPairState::Idle;
};

struct SPBudgetPlanConfig {
    size_t maxSegmentPairs = 48;
    size_t minSegmentPairs = 4;
    double marginSec = 0.030;
};

struct SPBudgetPlanContext {

    double pairIntervalSec = 1.0 / 24.0;

    double headOffsetSec = 0.0;

    uint64_t headSeq = 0;

    bool paused = false;

    double latencySec = 0.150;

    unsigned sessions = 1;
    double slotBusyUntilSec[8] = {0, 0, 0, 0, 0, 0, 0, 0};
};

struct SPBudgetPlanResult {
    bool hasNext = false;
    size_t nextPair = std::numeric_limits<size_t>::max();
    size_t plannedPairs = 0;
    size_t selectedSegments = 0;
    size_t rejectedSegments = 0;
};

struct SPBudgetSegment {
    size_t begin = 0;   // [begin, end)
    size_t end = 0;
    double value = 0.0;
    bool pinned = false;
};

inline bool spBudgetPairUsable(const SPBudgetPair &p) {
    return p.eligible && p.probed && !p.cut && p.benefit > 0.0f &&
           p.state != SPBudgetPairState::Skipped;
}

// Use absolute pair sequence numbers so sliding the ring cannot grow a pinned
// segment into rejected content. A short unstarted prefix joins the next block;
// a started prefix keeps its existing boundary.
inline std::vector<SPBudgetSegment> spBudgetSegments(const std::vector<SPBudgetPair> &pairs,
                                                     const SPBudgetPlanConfig &config,
                                                     uint64_t headSeq = 0) {
    std::vector<SPBudgetSegment> segments;
    const size_t maxLen = std::max<size_t>(1, config.maxSegmentPairs);
    const size_t minLen = std::max<size_t>(1, config.minSegmentPairs);
    auto pinnedIn = [&](size_t b, size_t e) {
        for (size_t k = b; k < e; ++k) {
            const SPBudgetPairState st = pairs[k].state;
            if (st == SPBudgetPairState::InFlight || st == SPBudgetPairState::Ready) return true;
        }
        return false;
    };
    size_t i = 0;
    while (i < pairs.size()) {
        if (!spBudgetPairUsable(pairs[i])) { ++i; continue; }
        const size_t runBegin = i;
        size_t runEnd = i;
        while (runEnd < pairs.size() && spBudgetPairUsable(pairs[runEnd])) ++runEnd;
        size_t begin = runBegin;
        while (begin < runEnd) {
            const uint64_t abs = headSeq + (uint64_t)begin;
            size_t end = std::min(runEnd, begin + (size_t)(maxLen - (size_t)(abs % maxLen)));
            if (begin == runBegin && end < runEnd && end - begin < minLen && !pinnedIn(begin, end)) {
                end = std::min(runEnd, end + maxLen);
            }
            SPBudgetSegment seg;
            seg.begin = begin;
            seg.end = end;
            for (size_t k = begin; k < end; ++k) seg.value += pairs[k].benefit;

            seg.pinned = pinnedIn(begin, end);
            segments.push_back(seg);
            begin = end;
        }
        i = runEnd;
    }
    return segments;
}

namespace detail {

inline double spBudgetDeadline(size_t index, const SPBudgetPlanContext &ctx, const SPBudgetPlanConfig &config) {
    if (ctx.paused) return std::numeric_limits<double>::infinity();
    return (double)index * ctx.pairIntervalSec + std::max(ctx.headOffsetSec, 0.0) - config.marginSec;
}

// Simulate jobs in timestamp order on the earliest available slot. Strict mode
// rejects a missed unpinned deadline; otherwise record it as expired.
inline bool spBudgetSimulate(const std::vector<SPBudgetPair> &pairs,
                             const std::vector<SPBudgetSegment> &segments,
                             const std::vector<bool> &selected,
                             const SPBudgetPlanContext &ctx,
                             const SPBudgetPlanConfig &config,
                             bool strict,
                             std::vector<size_t> *expired) {
    const unsigned slots = std::min<unsigned>(std::max<unsigned>(ctx.sessions, 1), 8);
    double busy[8];
    for (unsigned s = 0; s < slots; ++s) busy[s] = std::max(0.0, ctx.slotBusyUntilSec[s]);
    const double latency = std::max(ctx.latencySec, 0.0);
    for (size_t si = 0; si < segments.size(); ++si) {
        if (!selected[si]) continue;
        for (size_t i = segments[si].begin; i < segments[si].end; ++i) {
            const SPBudgetPairState st = pairs[i].state;
            if (st != SPBudgetPairState::Idle && st != SPBudgetPairState::Planned) continue;
            unsigned best = 0;
            for (unsigned s = 1; s < slots; ++s) if (busy[s] < busy[best]) best = s;
            const double finish = busy[best] + latency;
            const double deadline = spBudgetDeadline(i, ctx, config);
            if (finish > deadline) {

                if (strict && !segments[si].pinned) return false;
                if (expired) expired->push_back(i);
                continue;
            }
            busy[best] = finish;
        }
    }
    return true;
}

} // namespace detail

// Update Planned/Idle states without altering completed or in-flight jobs.
inline SPBudgetPlanResult spBudgetPlan(std::vector<SPBudgetPair> &pairs,
                                       const SPBudgetPlanContext &ctx,
                                       const SPBudgetPlanConfig &config) {
    SPBudgetPlanResult result;

    const double latency = std::max(ctx.latencySec, 0.0);
    for (size_t i = 0; i < pairs.size(); ++i) {
        SPBudgetPair &p = pairs[i];
        if (p.state != SPBudgetPairState::Idle && p.state != SPBudgetPairState::Planned) continue;
        if (latency > detail::spBudgetDeadline(i, ctx, config)) p.state = SPBudgetPairState::Skipped;
    }
    std::vector<SPBudgetSegment> segments = spBudgetSegments(pairs, config, ctx.headSeq);
    std::vector<bool> selected(segments.size(), false);

    for (size_t si = 0; si < segments.size(); ++si) selected[si] = segments[si].pinned;

    std::vector<size_t> order;
    for (size_t si = 0; si < segments.size(); ++si) {
        if (segments[si].pinned) continue;
        if (segments[si].end - segments[si].begin < std::max<size_t>(1, config.minSegmentPairs)) continue;
        order.push_back(si);
    }
    std::stable_sort(order.begin(), order.end(), [&](size_t a, size_t b) {
        if (segments[a].value != segments[b].value) return segments[a].value > segments[b].value;
        return segments[a].begin < segments[b].begin;
    });
    for (size_t si : order) {
        selected[si] = true;
        if (!detail::spBudgetSimulate(pairs, segments, selected, ctx, config, true, nullptr)) {
            selected[si] = false;
            result.rejectedSegments++;
        }
    }

    std::vector<size_t> expired;
    (void)detail::spBudgetSimulate(pairs, segments, selected, ctx, config, false, &expired);
    for (size_t i : expired) {
        if (pairs[i].state == SPBudgetPairState::Idle || pairs[i].state == SPBudgetPairState::Planned) {
            pairs[i].state = SPBudgetPairState::Skipped;
        }
    }
    for (size_t si = 0; si < segments.size(); ++si) {
        for (size_t i = segments[si].begin; i < segments[si].end; ++i) {
            SPBudgetPair &p = pairs[i];
            if (p.state == SPBudgetPairState::Idle && selected[si]) p.state = SPBudgetPairState::Planned;
            else if (p.state == SPBudgetPairState::Planned && !selected[si]) p.state = SPBudgetPairState::Idle;
        }
        if (selected[si]) result.selectedSegments++;
    }
    for (size_t i = 0; i < pairs.size(); ++i) {
        if (pairs[i].state != SPBudgetPairState::Planned) continue;
        result.plannedPairs++;
        if (!result.hasNext) { result.hasNext = true; result.nextPair = i; }
    }
    return result;
}

inline float spBudgetMotionBenefit(float motionPx1080) {
    const float m = motionPx1080;
    if (m < 0.75f) return 0.0f;
    if (m < 5.0f) return std::max(0.0f, (m - 0.75f) / (5.0f - 0.75f));
    if (m <= 28.0f) return 1.0f;
    if (m <= 70.0f) return 1.0f - 0.7f * (m - 28.0f) / (70.0f - 28.0f);
    if (m <= 96.0f) return 0.3f;
    return 0.0f;
}

// Budget includes session working sets, process baseline, and original/generated
// ring frames. Reduce sessions until the minimum ring fits; fail if one session
// cannot fit. Warning pressure shortens the ring; critical pressure selects
// one session and minimum lookahead.
enum class SPBudgetMemoryPressure : uint8_t { Normal = 0, Warn = 1, Critical = 2 };

struct SPBudgetMemoryPolicy {
    double requestedSeconds = 5.0;
    double minSeconds = 1.0;
    double budgetFraction = 0.25;
    uint64_t budgetCapBytes = 12ULL << 30;
    uint64_t baseBytes = 300ULL << 20;
    double perSessionBytesPerPixel = 190.0;
    double warnFactor = 0.6;
};

struct SPBudgetMemoryPlan {
    unsigned sessions = 1;
    double seconds = 1.0;
    bool fits = true;
    double requiredGB = 0.0;
};

inline SPBudgetMemoryPlan spBudgetAllocate(uint64_t physicalBytes, uint64_t bytesPerFrame, uint64_t pixels, double fps,
                                           unsigned desiredSessions, SPBudgetMemoryPressure pressure,
                                           const SPBudgetMemoryPolicy &policy) {
    SPBudgetMemoryPlan plan;
    const double f = fps > 1.0 ? fps : 24.0;
    const double budget = std::min((double)physicalBytes * policy.budgetFraction, (double)policy.budgetCapBytes);
    const double perSession = (double)pixels * policy.perSessionBytesPerPixel;
    const double perPair = (double)std::max<uint64_t>(bytesPerFrame, 1) * 2.0;
    const double minSec = std::min(policy.minSeconds, policy.requestedSeconds);
    const unsigned want = std::max(1u, std::min(desiredSessions, 8u));
    plan.sessions = 1;
    plan.seconds = minSec;
    plan.fits = false;
    for (unsigned s = want; s >= 1; --s) {
        const double remaining = budget - (double)policy.baseBytes - perSession * (double)s;
        const double seconds = remaining / perPair / f;
        if (seconds >= minSec) {
            plan.sessions = s;
            plan.seconds = std::min(seconds, policy.requestedSeconds);
            plan.fits = true;
            break;
        }
    }
    plan.requiredGB = ((double)policy.baseBytes + perSession + perPair * f * minSec) / 1073741824.0;
    if (pressure == SPBudgetMemoryPressure::Warn) {
        plan.seconds = std::max(minSec, plan.seconds * policy.warnFactor);
    } else if (pressure == SPBudgetMemoryPressure::Critical) {
        plan.sessions = 1;
        plan.seconds = minSec;
    }
    return plan;
}

struct SPBudgetCalibSample { unsigned sessions = 0; double pairsPerSec = 0.0; };

// Add a session for at least 10% more throughput; prefer one fewer if throughput
// stays within 3%, avoiding extra memory for measurement noise.
inline unsigned spBudgetCalibrationBest(const std::vector<SPBudgetCalibSample> &samples, unsigned fallback) {
    unsigned best = fallback;
    double bestTp = 0.0;
    for (const auto &s : samples) {
        if (s.pairsPerSec <= 0.0) continue;
        if (bestTp == 0.0) { best = s.sessions; bestTp = s.pairsPerSec; continue; }
        const bool more = s.sessions > best;
        if ((more && s.pairsPerSec > bestTp * 1.10) || (!more && s.pairsPerSec >= bestTp * 0.97)) {
            best = s.sessions; bestTp = s.pairsPerSec;
        }
    }
    return best;
}

// Recalibrate if throughput differs from its persisted value by more than 25%.
inline bool spBudgetCalibrationStale(double measuredPairsPerSec, double persistedPairsPerSec) {
    if (persistedPairsPerSec <= 0.0 || measuredPairsPerSec <= 0.0) return true;
    const double r = measuredPairsPerSec / persistedPairsPerSec;
    return r < 0.75 || r > 1.33;
}

// Recheck concurrency after sustained latency deviation above 40%; callers
// require 30 seconds of deviation before triggering.
inline bool spBudgetLatencyDrifted(double latencySec, double calibratedLatencySec) {
    if (calibratedLatencySec <= 0.0 || latencySec <= 0.0) return false;
    const double r = latencySec / calibratedLatencySec;
    return r > 1.40 || r < 0.70;
}

} // namespace sp
