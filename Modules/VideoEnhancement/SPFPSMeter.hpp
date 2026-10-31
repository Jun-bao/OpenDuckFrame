#pragma once
#include <algorithm>
#include <cstdint>
#include <deque>

// A short rolling estimate: input uses unique stream PTS; output uses actual
// drawable presentation time and ignores redraws, holds and duplicate PTS.
namespace sp {
class FPSMeter {
    struct Point { int64_t pts = 0, host = 0; uint64_t id = 0; };
    std::deque<Point> input_, output_;
    static constexpr int64_t window = 2000000000LL, stale = 1500000000LL;
    static void trim(std::deque<Point> &q, int64_t now) {
        while (!q.empty() && now - q.front().host > window) q.pop_front();
        while (q.size() > 512) q.pop_front();
    }
public:
    void reset() { input_.clear(); output_.clear(); }
    void resetOutput() { output_.clear(); }
    void input(int64_t ptsNs, int64_t hostNs) {
        if (hostNs <= 0 || (!input_.empty() && (ptsNs <= input_.back().pts || hostNs < input_.back().host))) return;
        if (!input_.empty() && ((__int128)ptsNs - input_.back().pts > 1000000000LL || hostNs - input_.back().host > stale)) input_.clear();
        input_.push_back({ptsNs, hostNs, 0}); trim(input_,hostNs);
    }
    void presented(int64_t ptsNs, int64_t hostNs, uint64_t id, bool held, bool originalSynthetic, bool visible) {
        if (!visible || held || originalSynthetic || !id || hostNs <= 0) return;
        // Callbacks may arrive out of order. Keep the window in actual
        // presentation-time order; never discard a PTS reversal here.
        if (!output_.empty()) {
            const int64_t newest = output_.back().host;
            if (hostNs > newest && hostNs - newest > stale) output_.clear();
            else if (hostNs < newest && newest - hostNs > stale) return;
        }
        Point point{ptsNs, hostNs, id};
        auto less = [](const Point &a, const Point &b) {
            if (a.host != b.host) return a.host < b.host;
            if (a.pts != b.pts) return a.pts < b.pts;
            return a.id < b.id;
        };
        // Duplicate IDs, PTS and identical presentation timestamps must not
        // occupy the bounded window. Prefer the earliest physical timestamp.
        for (const auto &existing : output_) {
            if ((existing.id == id || existing.pts == ptsNs || existing.host == hostNs) && !less(point, existing)) return;
        }
        output_.erase(std::remove_if(output_.begin(), output_.end(), [&](const Point &existing) {
            return existing.id == id || existing.pts == ptsNs || existing.host == hostNs;
        }), output_.end());
        auto at = std::lower_bound(output_.begin(), output_.end(), point, [](const Point &a, const Point &b) {
            if (a.host != b.host) return a.host < b.host;
            if (a.pts != b.pts) return a.pts < b.pts;
            return a.id < b.id;
        });
        output_.insert(at, point);
        trim(output_, output_.back().host);
    }
    double inputRate(int64_t now) {
        trim(input_,now);
        if (input_.size()<2 || now<input_.back().host || now-input_.back().host>stale) return -1;
        __int128 elapsed=(__int128)input_.back().pts-input_.front().pts;
        return elapsed>0 ? (double)(input_.size()-1)*1e9/(double)elapsed : -1;
    }
    // Arrival rate uses callback host time, not stream timestamps. Require a
    // sustained sample before using it to suppress inference.
    double inputArrivalRate(int64_t now) {
        trim(input_,now);
        if (input_.size() < 30 || now < input_.back().host || now - input_.back().host > stale) return -1;
        int64_t elapsed = input_.back().host - input_.front().host;
        return elapsed >= 500000000LL ? (double)(input_.size()-1)*1e9/(double)elapsed : -1;
    }
    double outputRate(int64_t now) {
        trim(output_,now);
        if (output_.size()<2 || now<output_.back().host || now-output_.back().host>stale) return -1;
        const int64_t elapsed = output_.back().host - output_.front().host;
        return elapsed > 0 ? (double)(output_.size() - 1)*1e9/(double)elapsed : -1;
    }
};
}
