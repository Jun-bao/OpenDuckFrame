#pragma once

// Adapt the shared rational scheduler to the player's microsecond media clock.
// The caller owns original frames and must reset at every seek/policy boundary.
#include "SPRateSchedule.hpp"
#include <limits>
#include <vector>

namespace sp {
struct SPFileCadenceEvent {
    int64_t ptsUs = 0;
    SPScheduleAction action = SPScheduleAction::PresentSource;
    SPScheduleSkipReason skipReason = SPScheduleSkipReason::None;
    uint64_t sourceIdentity = 0, frameA = 0, frameB = 0;
    SPRational phase{0, 1};
};
struct SPFileCadenceResult {
    SPScheduleReject reject = SPScheduleReject::None;
    std::vector<SPFileCadenceEvent> events;
};
class SPFileCadence {
public:
    bool reset(const SPRateRequest &request, uint64_t generation) {
        if (request.kind == SPRateKind::FixedFPS &&
            (request.fps.den <= 0 || request.fps.num <= 0 ||
             (__int128)request.fps.num > (__int128)240 * request.fps.den)) return false;
        if (!scheduler_.reset(request, generation, spMake(1, 2))) return false;
        generation_ = generation;
        haveLast_ = false;
        return true;
    }
    SPFileCadenceResult push(int64_t ptsUs, uint64_t identity, uint64_t generation, bool cutBefore = false) {
        SPFileCadenceResult result;
        if (ptsUs == INT64_MIN) { result.reject = SPScheduleReject::BadRate; return result; }
        SPScheduleInput input;
        input.pts = spMake(ptsUs, 1000000);
        input.identity = identity;
        input.generation = generation;
        input.sceneCutBefore = cutBefore;
        const auto scheduled = scheduler_.push(input);
        result.reject = scheduled.reject;
        if (result.reject != SPScheduleReject::None) return result;
        for (const auto &event : scheduled.events) {
            __int128 scaled = (__int128)event.pts.num * 1000000;
            const __int128 den = event.pts.den;
            // Nearest microsecond, symmetric around zero; no float clock drift.
            scaled = scaled >= 0 ? (scaled + den / 2) / den : -((-scaled + den / 2) / den);
            if (scaled > INT64_MAX || scaled < INT64_MIN || (haveLast_ && scaled <= lastUs_)) {
                result.events.clear(); result.reject = SPScheduleReject::Overflow; return result;
            }
            SPFileCadenceEvent output;
            output.ptsUs = (int64_t)scaled;
            output.action = event.action;
            output.skipReason = event.skipReason;
            output.sourceIdentity = event.sourceIdentity;
            output.frameA = event.frameA;
            output.frameB = event.frameB;
            output.phase = event.phase;
            result.events.push_back(output);
            lastUs_ = output.ptsUs;
            haveLast_ = true;
        }
        return result;
    }
    void noteBoundary() { scheduler_.noteBoundary(); }
    void cancel() { scheduler_.cancel(); }
private:
    SPRateScheduler scheduler_;
    uint64_t generation_ = 0;
    int64_t lastUs_ = 0;
    bool haveLast_ = false;
};
} // namespace sp
