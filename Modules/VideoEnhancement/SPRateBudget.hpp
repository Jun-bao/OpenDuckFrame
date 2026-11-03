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
    double refreshHz = 0;
};
enum class RateBudgetLimit { None, Display, Compute };
inline const char *rateBudgetLimitName(RateBudgetLimit limit) {
    switch (limit) {
        case RateBudgetLimit::Display: return "display";
        case RateBudgetLimit::Compute: return "compute";
        case RateBudgetLimit::None: return "none";
    }
    return "none";
}
struct RateBudgetSnapshot {
    int requestedMultiplier = 1, effectiveMultiplier = 1;
    double phaseCostMs = 0;
    uint64_t downgrades = 0, upgrades = 0;
    int displayCap = 1;
    uint64_t displayCapChanges = 0;
    RateBudgetLimit limit = RateBudgetLimit::None;
};

// The caller supplies a current-multiplier task median and rolling phase
// counts and valid completions in the past two seconds. It clears task
// samples after applying an effective-rate change.
class RateBudget {
    struct Cooldown { double fps, until; };
    RateBudgetSnapshot state_;
    double lastNow_ = -1, downSince_ = -1, upSince_ = -1;
    double displayDownSince_ = -1, displayUpSince_ = -1;
    bool displayRecovery_ = false;
    double warmupAt_ = -1;
    double upgradeAt_ = -1;
    int upgradeFrom_ = 1;
    std::vector<Cooldown> cooldowns_;
    void clearComputeTimers() { downSince_ = upSince_ = -1; }
    void clearTimers() {
        clearComputeTimers();
        displayDownSince_ = displayUpSince_ = -1;
    }
    void updateLimit() {
        state_.limit = state_.effectiveMultiplier == state_.requestedMultiplier ? RateBudgetLimit::None
            : state_.effectiveMultiplier == state_.displayCap ? RateBudgetLimit::Display : RateBudgetLimit::Compute;
    }
public:
    void reset(int requestedMultiplier = 1) {
        state_ = {};
        state_.requestedMultiplier = state_.effectiveMultiplier = std::clamp(requestedMultiplier, 1, 4);
        state_.displayCap = state_.requestedMultiplier;
        lastNow_ = upgradeAt_ = warmupAt_ = -1;
        displayRecovery_ = false;
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
        const bool validTaskCost = std::isfinite(input.medianTaskMs) && input.medianTaskMs > 0;
        if (effective > 1 && validTaskCost)
            state_.phaseCostMs = input.medianTaskMs / (effective - 1);

        // Keep the origin of a display-limited rate while the current cap
        // moves upward. The public limit describes the current cap, so it
        // cannot itself retain that origin through the recovery debounce.
        if (state_.limit == RateBudgetLimit::Display) displayRecovery_ = true;
        state_.displayCap = requested;
        if (std::isfinite(input.refreshHz) && input.refreshHz > 1)
            state_.displayCap = static_cast<int>(std::clamp(
                std::floor(input.refreshHz * 1.02 / input.contentFPS), 1.0, static_cast<double>(requested)));
        const int upper = std::min(requested, state_.displayCap);
        updateLimit();
        if (state_.limit == RateBudgetLimit::Display) displayRecovery_ = true;
        if (effective > upper) {
            displayUpSince_ = -1;
            clearComputeTimers();
            if (displayDownSince_ < 0) displayDownSince_ = now;
            if (now - displayDownSince_ >= 1.0) {
                state_.effectiveMultiplier = upper;
                ++state_.displayCapChanges;
                displayRecovery_ = true;
                upgradeAt_ = -1;
                markRateApplied(now);
                clearTimers();
                updateLimit();
            }
            return state_;
        }
        displayDownSince_ = -1;
        if (effective < upper && displayRecovery_) {
            clearComputeTimers();
            if (displayUpSince_ < 0) displayUpSince_ = now;
            if (now - displayUpSince_ >= 1.0) {
                state_.effectiveMultiplier = upper;
                ++state_.displayCapChanges;
                displayRecovery_ = upper < requested;
                // This is a display-cap recovery, not a compute upgrade;
                // a later overload must not turn it into a failed upgrade.
                upgradeAt_ = -1;
                markRateApplied(now);
                clearTimers();
                updateLimit();
            }
            return state_;
        }
        displayUpSince_ = -1;
        if (effective > 1 && !validTaskCost) { clearComputeTimers(); return state_; }
        const double phaseCost = state_.phaseCostMs;
        if (!std::isfinite(phaseCost) || phaseCost <= 0) { clearComputeTimers(); return state_; }
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
                for (int m = 2; m <= upper; ++m)
                    if ((m - 1) * phaseCost <= 0.90 * interval) next = m;
                if (next < effective) {
                    if (upgradeAt_ >= 0 && now - upgradeAt_ <= 10.0 && next <= upgradeFrom_)
                        cooldowns_.push_back({input.contentFPS, now + 30.0});
                    state_.effectiveMultiplier = next;
                    displayRecovery_ = false;
                    ++state_.downgrades;
                    upgradeAt_ = -1;
                    markRateApplied(now);
                    clearTimers();
                    updateLimit();
                    return state_;
                }
            }
        } else downSince_ = -1;

        const bool cooling = std::any_of(cooldowns_.begin(), cooldowns_.end(),
            [&](const Cooldown &item) { return std::abs(input.contentFPS - item.fps) <= 2.0; });
        const bool canUpgrade = effective < upper && !cooling &&
            effective * phaseCost <= 0.85 * interval;
        if (canUpgrade) {
            if (upSince_ < 0) upSince_ = now;
            if (now - upSince_ >= 3.0) {
                upgradeAt_ = now;
                upgradeFrom_ = effective;
                ++state_.effectiveMultiplier;
                displayRecovery_ = false;
                ++state_.upgrades;
                markRateApplied(now);
                clearTimers();
                updateLimit();
            }
        } else upSince_ = -1;
        return state_;
    }
};
}
