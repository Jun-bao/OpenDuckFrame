#pragma once

#include <cstddef>
#include <cstdint>

namespace spthumb {

inline int64_t hoverQuietUs(bool remote) { return remote ? 700000 : 300000; }

inline int64_t sweepQuietUs(bool remote) { return remote ? 2500000 : 700000; }

inline int64_t seekBusyPollUs() { return 25000; }

inline int64_t hoverQuietEffUs(bool remote, int64_t settleObservedUs) {
    const int64_t cap = hoverQuietUs(remote);
    if (settleObservedUs < 0) return cap;
    const int64_t scaled = 2 * settleObservedUs;
    if (scaled >= cap) return cap;
    const int64_t floorUs = seekBusyPollUs();
    return scaled < floorUs ? floorUs : scaled;
}

inline int64_t hoverGateWaitUs(bool everInteracted, bool remote,
                               int64_t sinceYieldUs, bool seekBusyNow,
                               int64_t settleObservedUs) {
    if (everInteracted) {
        if (settleObservedUs < 0) {

            if (seekBusyNow) return seekBusyPollUs();
            const int64_t quiet = hoverQuietUs(remote);
            if (sinceYieldUs < quiet) return quiet - sinceYieldUs;
            return 0;
        }
        const int64_t quiet = hoverQuietEffUs(remote, settleObservedUs);
        if (sinceYieldUs < quiet) return quiet - sinceYieldUs;
    }
    return seekBusyNow ? seekBusyPollUs() : 0;
}

enum class SPThumbHoldVerdict {
    Drop,
    Requeue,
    Wait,
};
struct SPThumbHoldDecision {
    SPThumbHoldVerdict verdict;
    int64_t waitUs;
};

inline SPThumbHoldDecision holdDecision(bool stopped, bool newerRequestPending,
                                        bool superseded, bool remote,
                                        int64_t sinceYieldUs) {
    if (stopped || newerRequestPending || superseded)
        return {SPThumbHoldVerdict::Drop, 0};
    const int64_t left = hoverQuietUs(remote) - sinceYieldUs;
    if (left <= 0) return {SPThumbHoldVerdict::Requeue, 0};
    return {SPThumbHoldVerdict::Wait, left};
}

inline bool sweepQuietSatisfied(bool remote, int64_t sinceYieldUs) {
    return sinceYieldUs > sweepQuietUs(remote);
}

enum class SPThumbOpenResult {
    Ready,
    Preempted,
    Failed,
};

inline constexpr uint64_t kImmuneBase = UINT64_MAX;

enum class SPThumbTaskKind { None, Hover, Sweep };
struct SPThumbClaim {
    SPThumbTaskKind kind = SPThumbTaskKind::None;
    int64_t targetAbsUs = 0;
    uint64_t hoverBase = kImmuneBase;
    uint64_t yieldBase = 0;
    uint64_t cancelBase = kImmuneBase;
};

inline bool taskInterrupted(bool stopped,
                            uint64_t curYield, uint64_t yieldBase,
                            uint64_t curHover, uint64_t hoverBase,
                            uint64_t curCancel, uint64_t cancelBase) {
    if (stopped || curYield != yieldBase) return true;
    if (cancelBase != kImmuneBase && curCancel != cancelBase) return true;
    return hoverBase != kImmuneBase && curHover != hoverBase;
}

enum class SPThumbIOTier { Throttle, Utility, Standard };

inline SPThumbIOTier ioTierForClaim(SPThumbTaskKind kind, bool remote) {
    if (kind != SPThumbTaskKind::Hover) return SPThumbIOTier::Throttle;
    return remote ? SPThumbIOTier::Utility : SPThumbIOTier::Standard;
}

inline bool discardDecodedFrame(bool stopped, uint64_t curYield, uint64_t yieldBase,
                                uint64_t curCancel, uint64_t cancelBase) {
    if (stopped || curYield != yieldBase) return true;
    return cancelBase != kImmuneBase && curCancel != cancelBase;
}

inline int sweepWaitMs(double lastCostMs, bool remote) {
    (void)remote;
    const int cap = 300;
    const double w = 4.0 * lastCostMs;
    if (w < 60) return 60;
    if (w > cap) return cap;
    return (int)w;
}

inline size_t decodedLruCap(bool sawHDR) { return sawHDR ? 32 : 12; }

} // namespace spthumb
