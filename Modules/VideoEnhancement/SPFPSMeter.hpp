#pragma once
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
        if (!visible || held || originalSynthetic || !id || hostNs <= 0 ||
            (!output_.empty() && (ptsNs <= output_.back().pts || hostNs <= output_.back().host || id == output_.back().id))) return;
        if (!output_.empty() && hostNs - output_.back().host > stale) output_.clear();
        output_.push_back({ptsNs, hostNs, id}); trim(output_,hostNs);
    }
    double inputRate(int64_t now) {
        trim(input_,now);
        if (input_.size()<2 || now<input_.back().host || now-input_.back().host>stale) return -1;
        __int128 elapsed=(__int128)input_.back().pts-input_.front().pts;
        return elapsed>0 ? (double)(input_.size()-1)*1e9/(double)elapsed : -1;
    }
    double outputRate(int64_t now) {
        trim(output_,now);
        if (output_.size()<2 || now<output_.back().host || now-output_.back().host>stale) return -1;
        int64_t elapsed=output_.back().host-output_.front().host;
        return elapsed>0 ? (double)(output_.size()-1)*1e9/(double)elapsed : -1;
    }
};
}
