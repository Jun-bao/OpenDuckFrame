#pragma once

#include "SPLiveDisplayQueue.h"
#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace spAirDisplayPolicyB {

constexpr std::size_t refreshHistoryCapacity = 8;

enum class Branch {
    original = 0,
    emptyPrefix = 1,
    boundedLag = 2,
    allStaleLatest = 3,
    unknownRefreshPeriod = 4
};

struct Decision {
    std::size_t selected = 0;
    std::size_t originalSelected = 0;
    std::size_t prefixCount = 0;
    int64_t refreshPeriodNs = 0;
    Branch branch = Branch::original;
};

// recentIntervals contains the last at most eight adjacent actual display-time
// differences. Nonpositive differences occupy history entries but are not V.
// The caller supplies its actual post-stale, PTS-ordered pending queue.
inline Decision decide(const std::vector<sp::DisplayQueueFrame> &pending,
                       int64_t scheduledDisplayNs,
                       const std::array<int64_t, refreshHistoryCapacity> &recentIntervals,
                       std::size_t intervalCount,
                       bool enabled) {
    Decision result;
    result.originalSelected = sp::chooseDisplayFrame(pending, scheduledDisplayNs);
    result.selected = result.originalSelected;
    if (result.originalSelected != pending.size()) result.prefixCount = result.originalSelected + 1;
    if (!enabled) return result;

    // intervalCount is bounded by refreshHistoryCapacity at the call boundary.
    for (std::size_t index = 0; index < intervalCount; ++index) {
        const int64_t interval = recentIntervals[index];
        if (interval > 0 && (result.refreshPeriodNs == 0 || interval < result.refreshPeriodNs))
            result.refreshPeriodNs = interval;
    }
    if (result.prefixCount == 0) {
        result.branch = Branch::emptyPrefix;
        return result;
    }
    if (result.refreshPeriodNs == 0) {
        result.branch = Branch::unknownRefreshPeriod;
        return result;
    }

    // A wider intermediate preserves the exact strict integer comparison.
    const __int128 oldestAllowedTarget = static_cast<__int128>(scheduledDisplayNs) -
        static_cast<__int128>(2) * result.refreshPeriodNs;
    for (std::size_t index = 0; index < result.prefixCount; ++index) {
        if (static_cast<__int128>(pending[index].logicalTargetNs) > oldestAllowedTarget) {
            result.selected = index;
            result.branch = Branch::boundedLag;
            return result;
        }
    }
    result.branch = Branch::allStaleLatest;
    return result;
}

// Updated only for actual newly created display-slot tokens. Each slot keeps
// its own copy so later observations cannot change that slot's policy input.
struct RefreshHistory {
    std::array<int64_t, refreshHistoryCapacity> intervals{};
    std::size_t count = 0, next = 0;
    int64_t lastDisplayNs = 0;
    bool haveLastDisplay = false;

    void reset() { *this = {}; }

    void observe(int64_t displayNs) {
        if (haveLastDisplay) {
            intervals[next] = displayNs - lastDisplayNs;
            next = (next + 1) % refreshHistoryCapacity;
            if (count < refreshHistoryCapacity) ++count;
        }
        lastDisplayNs = displayNs;
        haveLastDisplay = true;
    }
};

} // namespace spAirDisplayPolicyB
