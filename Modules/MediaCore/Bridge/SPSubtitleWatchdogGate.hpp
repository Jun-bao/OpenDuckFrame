#pragma once

#include <cstdint>

namespace sp {

// Pure state machine for the subtitle render watchdog. The Objective-C wrapper
// serializes mutations with its watchdog lock; keeping token/deadline policy
// here makes stale timer delivery deterministic to test without libass/GCD.
enum class SPSubtitleWatchdogDecision : uint8_t {
    Idle,
    Wait,
    Fire,
};

struct SPSubtitleWatchdogInspection {
    SPSubtitleWatchdogDecision decision = SPSubtitleWatchdogDecision::Idle;
    double waitMs = 0.0;
    uint64_t token = 0;
    uint64_t startTicks = 0;
    uint64_t generation = 0;
};

class SPSubtitleWatchdogGate {
public:
    uint64_t arm(uint64_t startTicks, uint64_t generation) noexcept {
        ++token_;
        startTicks_ = startTicks;
        generation_ = generation;
        return token_;
    }

    // Only the render that opened the current window may close it. This keeps
    // a stale completion from disarming a newer render's one-shot deadline.
    bool complete(uint64_t startTicks) noexcept {
        if (startTicks_ == 0 || startTicks_ != startTicks) return false;
        ++token_;
        startTicks_ = 0;
        return true;
    }

    SPSubtitleWatchdogInspection inspect(double elapsedMs,
                                         double deadlineMs) const noexcept {
        SPSubtitleWatchdogInspection out;
        out.token = token_;
        out.startTicks = startTicks_;
        out.generation = generation_;
        if (startTicks_ == 0) return out;
        if (elapsedMs < deadlineMs) {
            out.decision = SPSubtitleWatchdogDecision::Wait;
            out.waitMs = deadlineMs - elapsedMs;
        } else {
            out.decision = SPSubtitleWatchdogDecision::Fire;
        }
        return out;
    }

    // A timer event may already be queued when complete()+arm() moves the
    // source to a newer deadline. Claim succeeds only for the exact inspected
    // window, preventing that stale event from poisoning the new render.
    bool claim(const SPSubtitleWatchdogInspection &inspection) noexcept {
        if (inspection.decision != SPSubtitleWatchdogDecision::Fire ||
            inspection.token != token_ ||
            inspection.startTicks == 0 ||
            inspection.startTicks != startTicks_ ||
            inspection.generation != generation_) {
            return false;
        }
        ++token_;
        startTicks_ = 0;
        return true;
    }

private:
    uint64_t token_ = 0;
    uint64_t startTicks_ = 0;
    uint64_t generation_ = 0;
};

class SPSubtitlePoisonState {
public:
    static constexpr uint64_t kNone = UINT64_MAX;

    bool poison(uint64_t generation) noexcept {
        if (poisoned_ == generation) return false;
        poisoned_ = generation;
        return true;
    }
    void reset() noexcept { poisoned_ = kNone; }
    bool poisoned(uint64_t currentGeneration) const noexcept {
        return poisoned_ == currentGeneration;
    }

private:
    uint64_t poisoned_ = kNone;
};

} // namespace sp
