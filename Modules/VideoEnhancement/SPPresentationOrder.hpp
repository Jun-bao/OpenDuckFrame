#pragma once
#include <algorithm>
#include <cstdint>
#include <deque>
#include <vector>

// Retains callback arrival order. Physical order is reconstructed only from
// positive presentation timestamps, independently for each endpoint.
namespace sp {
struct PresentationEvent {
    int64_t pts, presented;
    uint64_t frame;
    bool output, visible, held, originalSynthetic;
};
struct PresentationSummary {
    uint64_t backwards = 0, duplicates = 0, ambiguousTimes = 0, invalidTimes = 0, invisible = 0, excluded = 0;
};
class PresentationOrder {
    std::deque<PresentationEvent> events_;
    uint64_t evicted_ = 0, generation_ = 0, config_ = 0, epoch_ = 0;
public:
    static constexpr size_t capacity = 512;
    void reset(uint64_t generation, uint64_t config, uint64_t epoch) { events_.clear(); evicted_ = 0; generation_ = generation; config_ = config; epoch_ = epoch; }
    void add(PresentationEvent e, uint64_t generation, uint64_t config, uint64_t epoch) {
        if (generation != generation_ || config != config_ || epoch != epoch_) return;
        if (events_.size() == capacity) { events_.pop_front(); ++evicted_; }
        events_.push_back(e);
    }
    // Compatibility for callers which do not use identity gating.
    void add(PresentationEvent e) { add(e, generation_, config_, epoch_); }
    const std::deque<PresentationEvent>& events() const { return events_; }
    uint64_t evicted() const { return evicted_; }
    PresentationSummary summary(bool output) const {
        PresentationSummary s; std::vector<PresentationEvent> valid;
        for (auto e : events_) {
            if (e.output != output) continue;
            if (e.presented <= 0) { ++s.invalidTimes; continue; }
            if (!e.visible) { ++s.invisible; continue; }
            if (e.held || e.originalSynthetic || !e.frame) { ++s.excluded; continue; }
            valid.push_back(e);
        }
        std::stable_sort(valid.begin(), valid.end(), [](auto a, auto b) { return a.presented < b.presented; });
        for (size_t i = 1; i < valid.size(); ++i) {
            if (valid[i].presented == valid[i-1].presented) { ++s.ambiguousTimes; continue; }
            // A tied group has no known internal order, so neither boundary
            // comparison can prove a reversal.
            if ((i > 1 && valid[i-2].presented == valid[i-1].presented) ||
                (i+1 < valid.size() && valid[i].presented == valid[i+1].presented)) continue;
            if (valid[i].pts < valid[i-1].pts) ++s.backwards;
            if (valid[i].pts == valid[i-1].pts) ++s.duplicates;
        }
        return s;
    }
};
}
