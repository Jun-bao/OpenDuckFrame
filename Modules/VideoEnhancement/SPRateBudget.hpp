#pragma once
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace sp {
inline bool shouldAdmitRife(int inflight, std::size_t sampleCount,
                            double serviceMs, double elapsedMs, double remainingMs) {
    if (inflight >= 2) return false;
    if (inflight == 0) return true;
    if (sampleCount < 8) return true;
    return std::max(0.0, serviceMs - elapsedMs) + serviceMs <= remainingMs;
}

struct RateBudgetInput {
    double nowSeconds = 0, contentFPS = 0;
    int requestedMultiplier = 1;
    double medianTaskMs = 0;
    uint64_t plannedPhases = 0, droppedPhases = 0;
    uint64_t freshSamples = 0;
};
struct RateBudgetSnapshot {
    int requestedMultiplier = 1, effectiveMultiplier = 1;
    double phaseCostMs = 0;
    uint64_t downgrades = 0, upgrades = 0;
};

// The caller supplies a current-multiplier task median and rolling phase
// counts and valid completions in the past two seconds. It clears task
// samples after applying an effective-rate change.
class RateBudget {
    struct Cooldown { double fps, until; };
    RateBudgetSnapshot state_;
    double lastNow_ = -1, downSince_ = -1, upSince_ = -1;
    double warmupAt_ = -1;
    double upgradeAt_ = -1;
    int upgradeFrom_ = 1;
    std::vector<Cooldown> cooldowns_;
    void clearTimers() { downSince_ = upSince_ = -1; }
public:
    void reset(int requestedMultiplier = 1) {
        state_ = {};
        state_.requestedMultiplier = state_.effectiveMultiplier = std::clamp(requestedMultiplier, 1, 4);
        lastNow_ = upgradeAt_ = warmupAt_ = -1;
        upgradeFrom_ = 1;
        cooldowns_.clear();
        clearTimers();
    }
    RateBudgetSnapshot snapshot() const { return state_; }

    // Re-arm after the processor has actually applied a pending rate change.
    // Draining work must not consume the next rate's downgrade warmup.
    void markRateApplied(double nowSeconds) {
        if (!std::isfinite(nowSeconds) || nowSeconds < 0) return;
        warmupAt_ = nowSeconds;
        downSince_ = -1;
    }

    // The caller excludes the first probe group and normalizes by its actual
    // phase count. Updating P preserves upgrade persistence and cooldown.
    bool recordProbePhaseCost(double phaseCostMs) {
        if (state_.effectiveMultiplier != 1 || state_.requestedMultiplier < 2 ||
            !std::isfinite(phaseCostMs) || phaseCostMs <= 0) return false;
        state_.phaseCostMs = phaseCostMs;
        return true;
    }

    RateBudgetSnapshot update(const RateBudgetInput &input) {
        const int requested = std::clamp(input.requestedMultiplier, 1, 4);
        if (requested != state_.requestedMultiplier) reset(requested);
        const double now = input.nowSeconds;
        if (!std::isfinite(now) || now < 0 || (lastNow_ >= 0 && now < lastNow_)) {
            clearTimers();
            return state_;
        }
        lastNow_ = now;
        if (!std::isfinite(input.contentFPS) || input.contentFPS <= 0) {
            clearTimers();
            return state_;
        }
        const double interval = 1000.0 / input.contentFPS;
        if (!std::isfinite(interval)) { clearTimers(); return state_; }
        if (warmupAt_ < 0) warmupAt_ = now;
        const int effective = state_.effectiveMultiplier;
        if (effective > 1) {
            if (!std::isfinite(input.medianTaskMs) || input.medianTaskMs <= 0) {
                clearTimers();
                return state_;
            }
            state_.phaseCostMs = input.medianTaskMs / (effective - 1);
        }
        const double phaseCost = state_.phaseCostMs;
        if (!std::isfinite(phaseCost) || phaseCost <= 0) { clearTimers(); return state_; }
        cooldowns_.erase(std::remove_if(cooldowns_.begin(), cooldowns_.end(),
            [now](const Cooldown &item) { return now >= item.until; }), cooldowns_.end());

        const bool enoughDrops = input.plannedPhases > 0 &&
            static_cast<double>(input.droppedPhases) / input.plannedPhases >= 0.20;
        const bool overloaded = effective > 1 && now - warmupAt_ >= 3.0 &&
            input.freshSamples >= 8 && enoughDrops &&
            input.medianTaskMs > 0.90 * interval;
        if (overloaded) {
            if (downSince_ < 0) downSince_ = now;
            if (now - downSince_ >= 2.0) {
                int next = 1;
                for (int m = 2; m <= requested; ++m)
                    if ((m - 1) * phaseCost <= 0.90 * interval) next = m;
                if (next < effective) {
                    if (upgradeAt_ >= 0 && now - upgradeAt_ <= 10.0 && next <= upgradeFrom_)
                        cooldowns_.push_back({input.contentFPS, now + 30.0});
                    state_.effectiveMultiplier = next;
                    ++state_.downgrades;
                    upgradeAt_ = -1;
                    markRateApplied(now);
                    clearTimers();
                    return state_;
                }
            }
        } else downSince_ = -1;

        const bool cooling = std::any_of(cooldowns_.begin(), cooldowns_.end(),
            [&](const Cooldown &item) { return std::abs(input.contentFPS - item.fps) <= 2.0; });
        const bool canUpgrade = effective < requested && !cooling &&
            effective * phaseCost <= 0.85 * interval;
        if (canUpgrade) {
            if (upSince_ < 0) upSince_ = now;
            if (now - upSince_ >= 3.0) {
                upgradeAt_ = now;
                upgradeFrom_ = effective;
                ++state_.effectiveMultiplier;
                ++state_.upgrades;
                markRateApplied(now);
                clearTimers();
            }
        } else upSince_ = -1;
        return state_;
    }
};
}
