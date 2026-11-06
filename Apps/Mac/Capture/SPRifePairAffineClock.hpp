#pragma once

#include "SPRateSchedule.hpp"

namespace sp {

struct RifePairClockContext {
    uint64_t generation = 0, config = 0, measurement = 0, clock = 0;
};
inline bool sameRifePairClockContext(RifePairClockContext a, RifePairClockContext b) {
    return a.generation == b.generation && a.config == b.config &&
        a.measurement == b.measurement && a.clock == b.clock;
}

struct RifeSourceClockTarget {
    bool frozen = false;
    RifePairClockContext context{};
    SPRational pts{};
    int64_t targetHost = 0, delayHost = 0;
};
// An existing source identity is never rewritten, including after a context
// change. A stale endpoint is evidence of an unbound pair, not a new endpoint.
inline bool freezeRifeSourceClockTarget(RifeSourceClockTarget &target, RifePairClockContext context,
                                         SPRational pts, int64_t candidate, int64_t delay) {
    if (target.frozen || !context.generation || pts.den <= 0 || candidate <= 0) return false;
    target = {true, context, pts, candidate, delay};
    return true;
}

enum class RifePairClockBinding { bound, missingEndpoint, contextMismatch, unorderedEndpoints, invalidPhase, overflow, frozenOnly };
struct RifePairClockTarget {
    bool recorded = false, deadlineOverride = false, alphaTimeValid = false;
    RifePairClockContext context{};
    SPRational pts{}, alphaTime{};
    int64_t legacyTargetHost = 0, selectedTargetHost = 0, legacyDelayHost = 0;
    RifeSourceClockTarget endpointA{}, endpointB{};
    RifePairClockBinding binding = RifePairClockBinding::missingEndpoint;
};

inline RifePairClockTarget rifePairClockTarget(RifePairClockContext context, SPRational pts,
    int64_t legacyTarget, int64_t delay, const RifeSourceClockTarget *a, const RifeSourceClockTarget *b) {
    RifePairClockTarget result;
    result.recorded = true; result.context = context; result.pts = pts;
    result.legacyTargetHost = result.selectedTargetHost = legacyTarget; result.legacyDelayHost = delay;
    if (a) result.endpointA = *a;
    if (b) result.endpointB = *b;
    if (!a || !b || !a->frozen || !b->frozen) return result;
    if (!sameRifePairClockContext(a->context, context) || !sameRifePairClockContext(b->context, context)) {
        result.binding = RifePairClockBinding::contextMismatch; return result;
    }
    if (a->targetHost >= b->targetHost || a->pts.den <= 0 || b->pts.den <= 0 || spCmp(a->pts, b->pts) >= 0) {
        result.binding = RifePairClockBinding::unorderedEndpoints; return result;
    }
    SPRational numerator{}, denominator{};
    if (pts.den <= 0 || !spSub(pts, a->pts, numerator) || !spSub(b->pts, a->pts, denominator) ||
        denominator.num <= 0 || !spDiv(numerator, denominator, result.alphaTime) ||
        result.alphaTime.den <= 0 || result.alphaTime.num <= 0 || result.alphaTime.num >= result.alphaTime.den) {
        result.binding = RifePairClockBinding::invalidPhase; return result;
    }
    result.alphaTimeValid = true;
    // Round the absolute affine expression once, in host ticks. No float model
    // alpha/timestep is changed or used to reconstruct the source-time ratio.
    __int128 den = result.alphaTime.den;
    __int128 n = (__int128)a->targetHost * den +
        ((__int128)b->targetHost - a->targetHost) * result.alphaTime.num;
    __int128 rounded = n / den + ((n % den) * 2 >= den ? 1 : 0);
    if (!spFit64(rounded, result.selectedTargetHost)) {
        result.selectedTargetHost = legacyTarget; result.binding = RifePairClockBinding::overflow; return result;
    }
    result.binding = RifePairClockBinding::bound;
    return result;
}

// Retry consumes the original complete snapshot. It cannot inspect endpoints,
// current D or the current anchor. Explicit frozenDeadline keeps precedence.
inline RifePairClockTarget reuseRifePairClockTarget(const RifePairClockTarget *frozen,
    RifePairClockContext context, SPRational pts, int64_t frozenDeadline) {
    RifePairClockTarget result;
    if (frozen) result = *frozen;
    else { result.recorded = true; result.context = context; result.pts = pts; result.binding = RifePairClockBinding::frozenOnly; }
    result.deadlineOverride = true; result.selectedTargetHost = frozenDeadline;
    return result;
}

} // namespace sp
