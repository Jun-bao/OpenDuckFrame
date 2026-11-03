#pragma once
#include <cstdint>
#include <cmath>

namespace sp {
// Serialized on the live processor queue. Explicitly separates backend
// capacity from budget feasibility; probes are rate-limited while infeasible.
class FRCBudgetGate {
    int64_t nextProbeNs_ = 0;
    bool limited_ = false;
public:
    enum class Decision { admit, probe, backendBusy, budgetLimited };
    void reset() { nextProbeNs_ = 0; limited_ = false; }
    bool limited() const { return limited_; }
    Decision decide(double requiredMs, double allowedMs, bool measured, bool backendAvailable, int64_t nowNs) {
        if (!backendAvailable) return Decision::backendBusy;
        if (!measured || !std::isfinite(requiredMs) || !std::isfinite(allowedMs)) {
            limited_ = false; return Decision::admit;
        }
        if (requiredMs <= allowedMs) { limited_ = false; nextProbeNs_ = 0; return Decision::admit; }
        limited_ = true;
        if (nowNs > 0 && nowNs >= nextProbeNs_) {
            nextProbeNs_ = nowNs + 2'000'000'000LL;
            return Decision::probe;
        }
        return Decision::budgetLimited;
    }
};
}
