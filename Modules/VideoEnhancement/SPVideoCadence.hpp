#pragma once

#include "SPRateSchedule.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <deque>

namespace sp {

// This estimates visible picture timing, never decoder metadata. Sampling is
// used for detection only; the retimer chooses full captured pictures.
using VideoLumaSamples = std::array<std::array<uint8_t, 144>, 6>;

class VideoCadenceDetector {
    std::array<std::deque<double>, 6> changes_;
    VideoLumaSamples previous_{};
    bool havePrevious_ = false;
    double lastTime_ = 0, evaluated_ = -1, candidateSince_ = 0, supported_ = 0;
    int candidate_ = 0;
    int fps_ = 0;
    int64_t phaseNs_ = 0;
public:
    int fps() const { return fps_; }
    int64_t phaseNs() const { return phaseNs_; }
    void reset() { *this = {}; }

    void observe(const VideoLumaSamples &samples, int64_t timeNs) {
        std::array<bool, 6> changed{};
        if (havePrevious_) for (size_t zone = 0; zone < samples.size(); ++zone) {
            unsigned total = 0, count = 0;
            for (size_t i = 0; i < samples[zone].size(); ++i) {
                int delta = std::abs(int(samples[zone][i]) - int(previous_[zone][i]));
                total += delta;
                count += delta > 3;
            }
            changed[zone] = count >= 8 && total >= samples[zone].size();
        }
        previous_ = samples; havePrevious_ = true;
        observeChanges(changed, timeNs);
    }

    void observeChanges(const std::array<bool, 6> &changed, int64_t timeNs) {
        const double time = double(timeNs) / 1e9;
        if (lastTime_ > 0 && time <= lastTime_) { reset(); lastTime_ = time; return; }
        lastTime_ = time;
        for (size_t zone = 0; zone < changed.size(); ++zone) {
            auto &history = changes_[zone];
            if (changed[zone]) history.push_back(time);
            while (!history.empty() && time - history.front() > 3.2) history.pop_front();
        }
        if (time - evaluated_ < 0.4) return;
        evaluated_ = time;
        constexpr std::array<int, 3> rates{24, 25, 30};
        std::array<unsigned, 3> votes{};
        std::array<double, 3> weights{}, phaseX{}, phaseY{};
        unsigned active = 0;
        constexpr double tau = 6.283185307179586;
        for (const auto &history : changes_) {
            unsigned recent = 0;
            for (double t : history) recent += time - t < 1.0;
            active += recent >= 18;
            if (history.size() < 32 || history.back() - history.front() < 1.3) continue;
            const double measured = double(history.size() - 1) / (history.back() - history.front());
            std::array<double, 3> score{}, x{}, y{};
            for (size_t c = 0; c < rates.size(); ++c) {
                if (measured < rates[c] * 0.7 || measured > rates[c] * 1.12) continue;
                for (double t : history) {
                    const double angle = tau * std::remainder(t * rates[c], 1.0);
                    x[c] += std::cos(angle); y[c] += std::sin(angle);
                }
                score[c] = std::hypot(x[c], y[c]) / history.size();
            }
            size_t best = 0;
            for (size_t c = 1; c < rates.size(); ++c) if (score[c] > score[best]) best = c;
            double next = 0;
            for (size_t c = 0; c < rates.size(); ++c) if (c != best) next = std::max(next, score[c]);
            if (score[best] < 0.48 || score[best] - next < 0.15) continue;
            ++votes[best]; weights[best] += score[best];
            phaseX[best] += x[best] / history.size(); phaseY[best] += y[best] / history.size();
        }
        size_t winner = 0;
        for (size_t c = 1; c < rates.size(); ++c) if (weights[c] > weights[winner]) winner = c;
        if (votes[winner] >= 2) {
            const int next = rates[winner];
            if (next == fps_) { supported_ = time; candidate_ = 0; return; }
            if (candidate_ != next) { candidate_ = next; candidateSince_ = time; }
            if (time - candidateSince_ >= 1.0) {
                fps_ = next; supported_ = time; candidate_ = 0;
                phaseNs_ = std::llround(std::atan2(phaseY[winner], phaseX[winner]) / (tau * next) * 1e9);
            }
        } else {
            candidate_ = 0;
            // Still scenes retain the last lock. Sustained incompatible motion
            // returns to source pictures while a new cadence is established.
            if (fps_ && active >= 2 && time - supported_ > 3.2) fps_ = 0;
        }
    }
};

// Buckets are centered on the observed picture-change phase. The caller keeps
// the latest full capture in a bucket until its closing boundary. This avoids
// an early page-control update consuming a video picture's time slot.
class VideoCadenceClock {
    int fps_ = 0;
    int64_t anchorTicks_ = 0;
public:
    void reset() { fps_ = 0; anchorTicks_ = 0; }
    void start(int fps, int64_t captureNs, int64_t phaseNs) {
        fps_ = fps;
        const long double periods = std::round((static_cast<long double>(captureNs) - phaseNs) * fps / 1e9L);
        anchorTicks_ = std::llround((phaseNs / 1e9L + periods / fps) * 60000);
    }
    int64_t index(int64_t captureNs) const {
        return std::llround((captureNs / 1e9L - anchorTicks_ / 60000.0L) * fps_);
    }
    SPRational pts(int64_t index) const { return spMake(anchorTicks_ + index * (60000 / fps_), 60000); }
    int64_t closesNs(int64_t index) const {
        return std::llround((anchorTicks_ / 60000.0L + (index + 0.5L) / fps_) * 1e9L);
    }
};

} // namespace sp
