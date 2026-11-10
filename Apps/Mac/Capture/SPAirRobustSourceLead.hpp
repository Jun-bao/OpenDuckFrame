#pragma once

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>

namespace sp {

struct AirSourceLeadEvaluation {
    double oldLeadSeconds;
    double leadSeconds;
    double p95IntervalSeconds;
    size_t historyCount;
    uint64_t observedIntervals;
};

// The caller supplies positive intervals from actual, monotonically observed
// source PTS. The original host-clock EWMA is maintained separately.
class AirRobustSourceLead {
    std::array<double, 32> intervals_{};
    size_t count_ = 0;
    size_t next_ = 0;
    uint64_t observed_ = 0;

public:
    void reset() { count_ = 0; next_ = 0; observed_ = 0; }

    void observePositiveInterval(double seconds) {
        if (!(seconds > 0)) return;
        intervals_[next_] = seconds;
        next_ = (next_ + 1) % intervals_.size();
        count_ = std::min(count_ + 1, intervals_.size());
        ++observed_;
    }

    size_t historyCount() const { return count_; }
    uint64_t observedIntervals() const { return observed_; }

    AirSourceLeadEvaluation evaluate(double oldLeadSeconds, bool enabled) const {
        AirSourceLeadEvaluation result{oldLeadSeconds, oldLeadSeconds, 0, count_, observed_};
        if (!enabled || count_ == 0) return result;
        auto ordered = intervals_;
        std::sort(ordered.begin(), ordered.begin() + count_);
        const size_t rankNumerator = (count_ - 1) * 95;
        const size_t lower = rankNumerator / 100;
        const size_t upper = std::min(lower + 1, count_ - 1);
        const double fraction = (rankNumerator % 100) / 100.0;
        result.p95IntervalSeconds = ordered[lower] + (ordered[upper] - ordered[lower]) * fraction;
        result.leadSeconds = std::max(oldLeadSeconds, result.p95IntervalSeconds / 2);
        return result;
    }
};

} // namespace sp
