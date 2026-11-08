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

struct DisplaySlotContext {
    uint64_t generation = 0, config = 0, measurementEpoch = 0, clockEpoch = 0;
};

inline bool sameDisplaySlotContext(DisplaySlotContext a, DisplaySlotContext b) {
    return a.generation == b.generation && a.config == b.config &&
        a.measurementEpoch == b.measurementEpoch && a.clockEpoch == b.clockEpoch;
}

struct DisplaySlotWindow {
    uint64_t token = 0;
    DisplaySlotContext context{};
    int64_t deadlineNs = 0, displayNs = 0;
};

// Isolated diagnostic build: measured preparation plus timer overhead needs
// about 1.75 ms in the tested scene. Keep the normal policy until validation.
#if defined(ODF_AIR_PRESENTATION_GUARD_DIAGNOSTIC) && ODF_AIR_PRESENTATION_GUARD_DIAGNOSTIC == 1
constexpr int64_t displaySelectionGuardNs = 2000000;
#else
constexpr int64_t displaySelectionGuardNs = 1000000;
#endif
enum class DisplaySlotDecision { staleToken, retired, waiting, ready, expired };

inline bool canArmDisplaySlot(DisplaySlotWindow slot, uint64_t token, DisplaySlotContext current) {
    return token && slot.token == token && sameDisplaySlotContext(slot.context, current);
}

inline DisplaySlotDecision displaySlotDecision(DisplaySlotWindow slot, uint64_t token,
                                               DisplaySlotContext current, int64_t nowNs) {
    if (!token || slot.token != token) return DisplaySlotDecision::staleToken;
    if (!sameDisplaySlotContext(slot.context, current)) return DisplaySlotDecision::retired;
    if (nowNs >= slot.deadlineNs) return DisplaySlotDecision::expired;
    return nowNs < slot.deadlineNs - displaySelectionGuardNs ? DisplaySlotDecision::waiting : DisplaySlotDecision::ready;
}

inline bool canReplaceDisplaySlot(DisplaySlotWindow slot, DisplaySlotContext current, int64_t nowNs) {
    return !slot.token || !sameDisplaySlotContext(slot.context, current) || nowNs >= slot.deadlineNs;
}

inline int64_t displayPreparationLeadNs(DisplaySlotWindow slot) {
    // Preparation only: preserve the old floor and add handoff room to the
    // observed display-minus-submission-deadline interval, never to callback time.
    const int64_t observed = slot.displayNs > slot.deadlineNs ? slot.displayNs - slot.deadlineNs + 2000000 : 0;
    return observed > 16000000 ? observed : 16000000;
}

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
