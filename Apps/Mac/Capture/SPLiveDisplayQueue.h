#pragma once

// CPU-only policy shared by the live presenter and its headless tests.
#include "SPRateSchedule.hpp"
#include <cstddef>
#include <vector>

namespace sp {

struct DisplayQueueFrame {
    SPRational pts{};
    int64_t logicalTargetNs = 0;
    uint64_t frameID = 0;
    bool counts = true;
    bool redraw = false;
};

constexpr std::size_t displayQueueCapacity = 4;
enum class DisplayAdmission { accepted, invalidPTS, stalePTS, duplicatePTS, redrawNotCurrent, full };

inline DisplayAdmission admitDisplayFrame(const std::vector<DisplayQueueFrame> &pending,
                                         DisplayQueueFrame frame, bool haveSubmitted,
                                         SPRational lastSubmitted) {
    if (frame.pts.den <= 0) return DisplayAdmission::invalidPTS;
    if (frame.redraw && (!haveSubmitted || spCmp(frame.pts, lastSubmitted) != 0))
        return DisplayAdmission::redrawNotCurrent;
    if (!frame.redraw && haveSubmitted && spCmp(frame.pts, lastSubmitted) <= 0)
        return DisplayAdmission::stalePTS;
    for (const auto &other : pending)
        if (!frame.redraw && !other.redraw && spCmp(frame.pts, other.pts) == 0)
            return DisplayAdmission::duplicatePTS;
    return pending.size() >= displayQueueCapacity ? DisplayAdmission::full : DisplayAdmission::accepted;
}

inline std::size_t displayFrameInsertionIndex(const std::vector<DisplayQueueFrame> &pending,
                                             DisplayQueueFrame frame) {
    std::size_t index = 0;
    while (index < pending.size() && spCmp(pending[index].pts, frame.pts) <= 0) ++index;
    return index;
}

// Merge only at the real prospective display slot, never a prepare-lead
// window. Older eligible frames have missed their slots; callers report every
// displaced identity as a drop. Future targets remain queued.
inline std::size_t chooseDisplayFrame(const std::vector<DisplayQueueFrame> &pending,
                                     int64_t scheduledDisplayNs) {
    std::size_t eligible = 0;
    while (eligible < pending.size() &&
           (pending[eligible].logicalTargetNs <= 0 || pending[eligible].logicalTargetNs <= scheduledDisplayNs)) ++eligible;
    return eligible ? eligible - 1 : pending.size();
}

} // namespace sp
