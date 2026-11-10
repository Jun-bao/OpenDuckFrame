#pragma once

// Output timetable for enhancement. Rational times only: 30000/1001 is not
// rounded to 30, and a fixed frame rate is not "multiply then drop".
// Multiplier phases are taken from the original pair, never from a frame
// this scheduler already synthesized.

#include <stdint.h>

#include <vector>

namespace sp {

struct SPRational {
    int64_t num = 0;
    int64_t den = 1;
};

enum class SPRateKind : uint8_t { FixedFPS = 1, Multiplier = 2 };

struct SPRateRequest {
    SPRateKind kind = SPRateKind::Multiplier;
    SPRational fps{60, 1};
    int multiplier = 2;
    // Live presentation may reuse a source within half an output period.
    // File conversion retains exact motion timestamps by default.
    bool reuseSources = false;
};

struct SPScheduleInput {
    SPRational pts{};
    uint64_t identity = 0;
    uint64_t generation = 0;
    bool sceneCutAfter = false;
    // Cut between the previous accepted frame and this one. Known only once
    // this frame has been sampled, so live capture sets it here.
    bool sceneCutBefore = false;
    // Identical pixels with a new timestamp are kept. This flag is intentionally
    // ignored by the timetable.
    bool contentDuplicate = false;
};

enum class SPScheduleAction : uint8_t { PresentSource = 1, Interpolate = 2, Hold = 3 };

enum class SPScheduleSkipReason : uint8_t { None = 0, SceneCut = 1, Gap = 2, Boundary = 3 };

enum class SPScheduleReject : uint8_t {
    None = 0,
    OutOfOrder,
    DuplicatePTS,
    Cancelled,
    GenerationMismatch,
    BadRate,
    Overflow
};

struct SPScheduleOutput {
    SPRational pts{};
    SPScheduleAction action = SPScheduleAction::PresentSource;
    uint64_t sourceIdentity = 0;
    uint64_t frameA = 0;
    uint64_t frameB = 0;
    SPRational phase{0, 1};
    SPScheduleSkipReason skipReason = SPScheduleSkipReason::None;
    uint64_t generation = 0;
};

struct SPSchedulePushResult {
    SPScheduleReject reject = SPScheduleReject::None;
    std::vector<SPScheduleOutput> events;
};

inline int64_t spGcd(int64_t a, int64_t b) {
    if (a < 0) a = -a;
    if (b < 0) b = -b;
    while (b != 0) {
        int64_t t = a % b;
        a = b;
        b = t;
    }
    return a == 0 ? 1 : a;
}

inline void spReduce128(__int128 &n, __int128 &d) {
    if (d < 0) {
        n = -n;
        d = -d;
    }
    if (d == 0) d = 1;
    __int128 a = n < 0 ? -n : n;
    __int128 b = d;
    while (b != 0) {
        __int128 t = a % b;
        a = b;
        b = t;
    }
    if (a == 0) a = 1;
    n /= a;
    d /= a;
}

inline bool spFit64(__int128 v, int64_t &out) {
    if (v > INT64_MAX || v < INT64_MIN) return false;
    out = (int64_t)v;
    return true;
}

inline bool spFrom128(__int128 n, __int128 d, SPRational &out) {
    spReduce128(n, d);
    int64_t nn = 0, dd = 0;
    if (!spFit64(n, nn) || !spFit64(d, dd) || dd == 0) return false;
    out = SPRational{nn, dd};
    return true;
}

inline SPRational spMake(int64_t n, int64_t d) {
    SPRational out{0, 1};
    spFrom128(n, d, out);
    return out;
}

inline int spCmp(SPRational a, SPRational b) {
    __int128 left = (__int128)a.num * b.den;
    __int128 right = (__int128)b.num * a.den;
    if (left < right) return -1;
    if (left > right) return 1;
    return 0;
}

inline bool spSub(SPRational a, SPRational b, SPRational &out) {
    __int128 n = (__int128)a.num * b.den - (__int128)b.num * a.den;
    __int128 d = (__int128)a.den * b.den;
    return spFrom128(n, d, out);
}

inline bool spAdd(SPRational a, SPRational b, SPRational &out) {
    __int128 n = (__int128)a.num * b.den + (__int128)b.num * a.den;
    __int128 d = (__int128)a.den * b.den;
    return spFrom128(n, d, out);
}

inline bool spMul(SPRational a, SPRational b, SPRational &out) {
    return spFrom128((__int128)a.num * b.num, (__int128)a.den * b.den, out);
}

inline bool spDiv(SPRational a, SPRational b, SPRational &out) {
    return spFrom128((__int128)a.num * b.den, (__int128)a.den * b.num, out);
}

inline bool spRateValid(const SPRateRequest &request) {
    if (request.kind == SPRateKind::Multiplier) {
        return request.multiplier == 2 || request.multiplier == 3 || request.multiplier == 4;
    }
    if (request.kind == SPRateKind::FixedFPS) {
        return request.fps.num > 0 && request.fps.den > 0;
    }
    return false;
}

// target(k) = anchor + k / fps, with fps = numerator/denominator.
inline bool spFixedTarget(SPRational anchor, int64_t k, SPRational fps, SPRational &out) {
    SPRational step{};
    if (!spFrom128((__int128)k * fps.den, fps.num, step)) return false;
    return spAdd(anchor, step, out);
}

class SPRateScheduler {
public:
    bool reset(SPRateRequest request, uint64_t generation, SPRational maxGap) {
        if (!spRateValid(request) || maxGap.den == 0 || spCmp(maxGap, SPRational{0, 1}) < 0) return false;
        request_ = request;
        generation_ = generation;
        maxGap_ = maxGap;
        cancelled_ = false;
        havePrevious_ = false;
        haveAnchor_ = false;
        haveLast_ = false;
        boundaryPending_ = false;
        nextIndex_ = 0;
        lastReusedIdentity_ = 0;
        previous_ = {};
        anchor_ = {};
        lastPts_ = {};
        return true;
    }

    void cancel() { cancelled_ = true; }

    // The next accepted frame will not be interpolated against the previous one.
    void noteBoundary() {
        if (!cancelled_) boundaryPending_ = true;
    }

    uint64_t generation() const { return generation_; }

    SPSchedulePushResult push(const SPScheduleInput &frame) {
        SPSchedulePushResult result;
        if (!spRateValid(request_)) {
            result.reject = SPScheduleReject::BadRate;
            return result;
        }
        if (cancelled_) {
            result.reject = SPScheduleReject::Cancelled;
            return result;
        }
        if (frame.generation != generation_) {
            result.reject = SPScheduleReject::GenerationMismatch;
            return result;
        }
        if (frame.pts.den == 0 || frame.identity == 0) {
            result.reject = SPScheduleReject::BadRate;
            return result;
        }
        if (havePrevious_) {
            const int order = spCmp(frame.pts, previous_.pts);
            if (order < 0) {
                result.reject = SPScheduleReject::OutOfOrder;
                return result;
            }
            if (order == 0) {
                result.reject = SPScheduleReject::DuplicatePTS;
                return result;
            }
        }
        if (!havePrevious_) {
            if (!emitSource(frame, result.events)) {
                result.reject = SPScheduleReject::Overflow;
                return result;
            }
            if (request_.kind == SPRateKind::FixedFPS) {
                anchor_ = frame.pts;
                haveAnchor_ = true;
                nextIndex_ = 1;
            }
            previous_ = frame;
            havePrevious_ = true;
            boundaryPending_ = false;
            return result;
        }

        const bool boundary = boundaryPending_;
        boundaryPending_ = false;
        SPRational delta{};
        if (!spSub(frame.pts, previous_.pts, delta)) {
            result.reject = SPScheduleReject::Overflow;
            return result;
        }
        const bool gap = spCmp(delta, maxGap_) > 0;
        const bool cut = previous_.sceneCutAfter || frame.sceneCutBefore;
        const bool blocked = cut || gap || boundary;
        SPScheduleSkipReason reason = SPScheduleSkipReason::None;
        if (cut) reason = SPScheduleSkipReason::SceneCut;
        else if (gap) reason = SPScheduleSkipReason::Gap;
        else if (boundary) reason = SPScheduleSkipReason::Boundary;

        if (request_.kind == SPRateKind::Multiplier) {
            if (!emitMultiplier(previous_, frame, blocked, reason, result.events)) {
                result.reject = SPScheduleReject::Overflow;
                return result;
            }
        } else if (!emitFixed(previous_, frame, blocked, reason, result.events)) {
            result.reject = SPScheduleReject::Overflow;
            return result;
        }
        previous_ = frame;
        havePrevious_ = true;
        return result;
    }

    SPSchedulePushResult finish() {
        SPSchedulePushResult result;
        if (cancelled_) result.reject = SPScheduleReject::Cancelled;
        return result;
    }

private:
    bool emit(SPScheduleOutput event, std::vector<SPScheduleOutput> &out) {
        if (haveLast_) {
            const int order = spCmp(event.pts, lastPts_);
            if (order == 0) return true;
            if (order < 0) return false;
        }
        lastPts_ = event.pts;
        haveLast_ = true;
        out.push_back(event);
        return true;
    }

    bool emitSource(const SPScheduleInput &frame, std::vector<SPScheduleOutput> &out) {
        return emitSourceAt(frame, frame.pts, out);
    }

    bool emitSourceAt(const SPScheduleInput &frame, SPRational pts, std::vector<SPScheduleOutput> &out) {
        SPScheduleOutput event;
        event.pts = pts;
        event.action = SPScheduleAction::PresentSource;
        event.sourceIdentity = frame.identity;
        event.frameA = frame.identity;
        event.phase = SPRational{0, 1};
        event.generation = generation_;
        if (!emit(event, out)) return false;
        lastReusedIdentity_ = frame.identity;
        return true;
    }

    bool emitHold(const SPScheduleInput &frame, SPRational pts, SPScheduleSkipReason reason,
                  std::vector<SPScheduleOutput> &out) {
        SPScheduleOutput event;
        event.pts = pts;
        event.action = SPScheduleAction::Hold;
        event.sourceIdentity = frame.identity;
        event.frameA = frame.identity;
        event.phase = SPRational{0, 1};
        event.skipReason = reason;
        event.generation = generation_;
        return emit(event, out);
    }

    bool emitInterpolate(const SPScheduleInput &a, const SPScheduleInput &b, SPRational pts, SPRational phase,
                         std::vector<SPScheduleOutput> &out) {
        SPScheduleOutput event;
        event.pts = pts;
        event.action = SPScheduleAction::Interpolate;
        event.sourceIdentity = 0;
        event.frameA = a.identity;
        event.frameB = b.identity;
        event.phase = phase;
        event.generation = generation_;
        return emit(event, out);
    }

    bool emitMultiplier(const SPScheduleInput &a, const SPScheduleInput &b, bool blocked,
                        SPScheduleSkipReason reason, std::vector<SPScheduleOutput> &out) {
        const int m = request_.multiplier;
        SPRational span{};
        if (!spSub(b.pts, a.pts, span)) return false;
        for (int i = 1; i < m; ++i) {
            SPRational phase = spMake(i, m);
            SPRational offset{};
            SPRational pts{};
            if (!spMul(span, phase, offset) || !spAdd(a.pts, offset, pts)) return false;
            if (blocked) {
                if (!emitHold(a, pts, reason, out)) return false;
            } else if (!emitInterpolate(a, b, pts, phase, out)) {
                return false;
            }
        }
        return emitSource(b, out);
    }

    bool emitFixed(const SPScheduleInput &a, const SPScheduleInput &b, bool blocked,
                   SPScheduleSkipReason reason, std::vector<SPScheduleOutput> &out) {
        int guard = 0;
        while (guard++ < 8192) {
            SPRational t{};
            if (!spFixedTarget(anchor_, nextIndex_, request_.fps, t)) return false;
            const int againstB = spCmp(t, b.pts);
            if (againstB > 0) {
                if (request_.reuseSources && lastReusedIdentity_ != b.identity) {
                    SPRational untilTick{}, span{}, period{}, halfPeriod{};
                    if (!spSub(t,b.pts,untilTick) || !spSub(b.pts,a.pts,span) ||
                        !spFrom128(request_.fps.den,request_.fps.num,period) ||
                        !spFrom128(request_.fps.den,(__int128)2*request_.fps.num,halfPeriod)) return false;
                    // A slow source must not wait for frame C before its
                    // already-captured frame B can occupy the nearest tick.
                    // Faster sources keep normal downsampling lookahead.
                    if (spCmp(span,period)>=0 && spCmp(untilTick,halfPeriod)<=0) {
                        if (!emitSourceAt(b,t,out)) return false;
                        ++nextIndex_;
                    }
                }
                return true;
            }
            if (request_.reuseSources && !blocked && spCmp(t, a.pts) >= 0) {
                SPRational fromA{}, toB{}, halfPeriod{};
                if (!spSub(t, a.pts, fromA) || !spSub(b.pts, t, toB) ||
                    !spFrom128(request_.fps.den, (__int128)2 * request_.fps.num, halfPeriod)) return false;
                const bool nearerB = spCmp(toB, fromA) <= 0;
                const auto &nearest = nearerB ? b : a;
                // Reuse each source once. A tie on the next output tick must
                // generate its own phase rather than repeat that same source.
                if (nearest.identity != lastReusedIdentity_ &&
                    spCmp(nearerB ? toB : fromA, halfPeriod) <= 0) {
                    if (!emitSourceAt(nearest, t, out)) return false;
                    ++nextIndex_;
                    continue;
                }
            }
            if (againstB == 0) {
                if (!emitSource(b, out)) return false;
                nextIndex_ += 1;
                return true;
            }
            const int againstA = spCmp(t, a.pts);
            if (againstA <= 0) {
                if (againstA == 0 && !emitSource(a, out)) return false;
                nextIndex_ += 1;
                continue;
            }
            if (blocked) {
                if (!emitHold(a, t, reason, out)) return false;
            } else {
                SPRational span{};
                SPRational into{};
                SPRational phase{};
                if (!spSub(b.pts, a.pts, span) || !spSub(t, a.pts, into) || !spDiv(into, span, phase)) return false;
                if (!emitInterpolate(a, b, t, phase, out)) return false;
            }
            nextIndex_ += 1;
        }
        return false;
    }

    SPRateRequest request_{};
    SPRational maxGap_{1, 2};
    SPRational anchor_{};
    SPRational lastPts_{};
    SPScheduleInput previous_{};
    uint64_t generation_ = 0;
    int64_t nextIndex_ = 0;
    bool cancelled_ = false;
    bool havePrevious_ = false;
    bool haveAnchor_ = false;
    bool haveLast_ = false;
    bool boundaryPending_ = false;
    uint64_t lastReusedIdentity_ = 0;
};

// Mean absolute difference above 48 and a majority of samples jumping by more
// than 40. Small motion and identical frames are not cuts.
inline bool spDetectSceneCut(const uint8_t *a, const uint8_t *b, int count) {
    if (!a || !b || count <= 0) return false;
    int64_t mad = 0;
    int strong = 0;
    for (int i = 0; i < count; ++i) {
        int delta = (int)a[i] - (int)b[i];
        if (delta < 0) delta = -delta;
        mad += delta;
        if (delta > 40) strong += 1;
    }
    const double mean = (double)mad / (double)count;
    return mean > 48.0 && strong * 20 > count * 11;
}

inline bool spPhaseFitsFloat(SPRational phase, float &out) {
    if (phase.den <= 0) return false;
    const double exact = (double)phase.num / (double)phase.den;
    if (!(exact > 0.0 && exact < 1.0)) return false;
    out = (float)exact;
    const double back = (double)out;
    if (back <= 0.0 || back >= 1.0) return false;
    const double err = back > exact ? back - exact : exact - back;
    return err < 1e-5;
}

} // namespace sp
