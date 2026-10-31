#pragma once
#include <algorithm>
#include <cstdint>
#include <deque>

namespace sp {
inline bool nativePresentationBudget(bool multiplier, double refreshHz, double sourceRate, double arrivalRate) {
    return multiplier && refreshHz > 1 && sourceRate >= refreshHz * 0.98 && arrivalRate >= refreshHz * 0.95;
}

struct NativeCadenceSnapshot {
    bool active = false, configured = false;
    uint64_t generation = 0, displayID = 0, callbacks = 0, entries = 0, exits = 0;
    int width = 0, height = 0, captureLimit = 0;
    double refreshHz = 0, ptsFPS = -1, hostFPS = -1;
    int64_t ageNs = -1;
    size_t samples = 0;
    const char *reason = "warming";
};

// Caller serializes access. Observe the raw complete callback before copying or
// queue admission, so model/pump pressure cannot create a false low source rate.
// A 500 ms aggregate enters; three slow intervals among the latest six exit.
// A lone delayed or dropped callback is tolerated. query() also expires on an
// idle stream without requiring a new callback or a scheduler event.
class NativeCadenceGate {
    struct Point { int64_t pts, host; bool slow; };
    std::deque<Point> points_;
    uint64_t generation_ = 0, displayID_ = 0, callbacks_ = 0, entries_ = 0, exits_ = 0;
    int width_ = 0, height_ = 0, captureLimit_ = 0;
    double refreshHz_ = 0;
    int64_t lastObservationHost_ = 0;
    bool active_ = false, configured_ = false;
    const char *reason_ = "warming";
    static constexpr int64_t windowNs = 650000000, enterNs = 500000000, staleNs = 150000000;
    void clear(const char *reason) {
        if (active_) ++exits_;
        active_ = false; points_.clear(); reason_ = reason;
    }
public:
    void reset(const char *reason = "reset") {
        clear(reason); generation_ = 0; width_ = height_ = 0; lastObservationHost_ = 0;
    }
    void configure(double refreshHz, int captureLimit, uint64_t displayID = 0) {
        const bool valid = refreshHz > 1;
        if (refreshHz_ != refreshHz || captureLimit_ != captureLimit || displayID_ != displayID || configured_ != valid) {
            clear("configuration_changed"); refreshHz_ = refreshHz; captureLimit_ = captureLimit; displayID_ = displayID;
            configured_ = valid;
        }
    }
    void observe(int64_t pts, int64_t host, uint64_t generation, int width, int height, bool timestampValid = true) {
        if (generation < generation_) return; // A retired callback cannot reset a newer source.
        if (generation != generation_) {
            clear("source_changed"); generation_ = generation; width_ = height_ = 0; lastObservationHost_ = 0;
        }
        ++callbacks_;
        if (!timestampValid || width <= 0 || height <= 0 || host <= 0 || refreshHz_ <= 1) {
            clear("invalid_sample"); return;
        }
        if (width_ != width || height_ != height) {
            clear("size_changed"); width_ = width; height_ = height;
        }
        if (!points_.empty()) {
            const __int128 dp = (__int128)pts - points_.back().pts;
            const __int128 dh = (__int128)host - points_.back().host;
            if (dp <= 0 || dh <= 0 || dp > 250000000 || dh > staleNs) {
                clear("timestamp_discontinuity");
            } else {
                const double slowLimit = 1.35e9 / refreshHz_;
                const bool slow = (double)dp > slowLimit || (double)dh > slowLimit;
                points_.push_back({pts, host, slow});
                lastObservationHost_ = host;
                while (points_.size() > 2 && host - points_.front().host > windowNs) points_.pop_front();
                while (points_.size() > 256) points_.pop_front();
                if (active_) {
                    int slowCount = 0, n = 0;
                    for (auto it = points_.rbegin(); it != points_.rend() && n < 6; ++it, ++n) slowCount += it->slow;
                    bool sustainedSlow = false;
                    const double nominal = 1e9 / refreshHz_;
                    double maxPTSExcess = 0, maxHostExcess = 0;
                    int64_t previousPTS = pts, previousHost = host;
                    for (auto it = points_.rbegin(); it != points_.rend(); ++it) {
                        maxPTSExcess = std::max(maxPTSExcess, (double)((__int128)previousPTS - it->pts) - nominal);
                        maxHostExcess = std::max(maxHostExcess, (double)((__int128)previousHost - it->host) - nominal);
                        previousPTS = it->pts; previousHost = it->host;
                        const int64_t spanHost = host - it->host;
                        if (spanHost < 250000000) continue;
                        const __int128 spanPTS = (__int128)pts - it->pts;
                        const auto count = (size_t)(it - points_.rbegin());
                        // One delayed callback may be followed by catch-up.
                        // Discount at most one interval's excess, capped at
                        // three periods; repeated slower cadence remains in
                        // the rolling aggregate and triggers the hysteresis.
                        const double ptsAdjusted = (double)spanPTS - std::min(maxPTSExcess, 3*nominal);
                        const double hostAdjusted = (double)spanHost - std::min(maxHostExcess, 3*nominal);
                        sustainedSlow = ptsAdjusted <= 0 || hostAdjusted <= 0 ||
                            count*1e9/ptsAdjusted < refreshHz_ * 0.94 ||
                            count*1e9/hostAdjusted < refreshHz_ * 0.94;
                        break;
                    }
                    // The short window may forgive one isolated delay, but a
                    // recurring delay must not be forgiven anew forever.
                    // Check the bounded long window without any discount.
                    bool longWindowSlow = false;
                    const auto &first = points_.front();
                    const int64_t longHostSpan = host - first.host;
                    const __int128 longPTSSpan = (__int128)pts - first.pts;
                    if (longHostSpan >= enterNs) {
                        const auto intervals = points_.size() - 1;
                        longWindowSlow = longPTSSpan <= 0 ||
                            intervals*1e9/(double)longPTSSpan < refreshHz_ * 0.94 ||
                            intervals*1e9/(double)longHostSpan < refreshHz_ * 0.94;
                    }
                    if (slowCount >= 3 || sustainedSlow || longWindowSlow) {
                        clear("cadence_slow"); points_.push_back({pts, host, false});
                    }
                } else if (points_.size() >= 31) {
                    const auto &first = points_.front();
                    const int64_t hostSpan = host - first.host;
                    const __int128 ptsSpan = (__int128)pts - first.pts;
                    if (hostSpan >= enterNs && ptsSpan >= enterNs &&
                        nativePresentationBudget(true, refreshHz_, (points_.size()-1)*1e9/(double)ptsSpan,
                                                 (points_.size()-1)*1e9/(double)hostSpan)) {
                        active_ = true; ++entries_; reason_ = "sustained_native";
                    }
                }
                return;
            }
        }
        points_.push_back({pts, host, false}); lastObservationHost_ = host;
    }
    NativeCadenceSnapshot query(int64_t now) {
        int64_t age = lastObservationHost_ > 0 && now >= lastObservationHost_ ? now - lastObservationHost_ : -1;
        if (!points_.empty() && (age < 0 || age > staleNs)) clear("stale");
        NativeCadenceSnapshot result;
        result.active=active_; result.configured=configured_; result.generation=generation_; result.displayID=displayID_; result.callbacks=callbacks_;
        result.entries=entries_; result.exits=exits_; result.width=width_; result.height=height_;
        result.captureLimit=captureLimit_; result.refreshHz=refreshHz_; result.ageNs=age;
        result.samples=points_.size(); result.reason=reason_;
        if (points_.size() >= 2) {
            const auto &first=points_.front(), &last=points_.back();
            const __int128 ptsSpan=(__int128)last.pts-first.pts;
            int64_t hostSpan=last.host-first.host;
            if (ptsSpan > 0) result.ptsFPS=(points_.size()-1)*1e9/(double)ptsSpan;
            if (hostSpan > 0) result.hostFPS=(points_.size()-1)*1e9/(double)hostSpan;
        }
        return result;
    }
};
}
