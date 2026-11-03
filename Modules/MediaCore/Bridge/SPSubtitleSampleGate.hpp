#pragma once

#include <cstdint>

namespace sp {

// Pure state machine for the subtitle renderer's media-time cache and dynamic
// ASS sampling throttle. The renderer serializes access on its _assQueue serial queue; keeping
// the policy free of libass/Metal dependencies also makes paused seek/step
// semantics deterministic to test without launching the app or creating GPU
// resources.
enum class SPSubtitleSampleDecision : uint8_t {
    Sample,
    ReuseSameTime,
    ReuseThrottled,
};

class SPSubtitleSampleGate {
public:
    // Full lifetime reset (new track/shutdown). Unlike invalidateTimeline(),
    // this deliberately drops a pending one-shot force request.
    void reset() noexcept {
        lastRenderedUs_ = -1;
        lastSampleUs_ = -1;
        intervalUs_ = 0;
        forceNext_ = false;
    }

    // Cue/style/viewport changes invalidate both caches, but must not consume a
    // force request that was already armed by a paused seek.
    void invalidateTimeline() noexcept {
        lastRenderedUs_ = -1;
        lastSampleUs_ = -1;
        intervalUs_ = 0;
    }

    void forceNextSample() noexcept {
        forceNext_ = true;
        // A throttled reuse records the skipped PTS in the outer time cache.
        // Clearing it is essential when a 60fps step requests that same PTS.
        lastRenderedUs_ = -1;
    }

    SPSubtitleSampleDecision begin(int64_t mediaTimeUs,
                                   bool hasReusableTexture) noexcept {
        if (mediaTimeUs == lastRenderedUs_) {
            return SPSubtitleSampleDecision::ReuseSameTime;
        }

        const bool forced = forceNext_;
        forceNext_ = false;
        if (!forced && intervalUs_ > 0 && hasReusableTexture &&
            mediaTimeUs >= 0 && lastSampleUs_ >= 0 &&
            mediaTimeUs > lastSampleUs_ &&
            mediaTimeUs - lastSampleUs_ < intervalUs_) {
            // Cache only the requested media time. lastSampleUs_ intentionally
            // remains the last real libass call, so repeated display ticks
            // cannot slide the throttle window forward forever.
            lastRenderedUs_ = mediaTimeUs;
            return SPSubtitleSampleDecision::ReuseThrottled;
        }
        return SPSubtitleSampleDecision::Sample;
    }

    void markSampled(int64_t mediaTimeUs) noexcept {
        lastSampleUs_ = mediaTimeUs;
    }

    void markRendered(int64_t mediaTimeUs) noexcept {
        lastRenderedUs_ = mediaTimeUs;
    }

    void markRenderRetryRequired() noexcept {
        lastRenderedUs_ = -1;
    }

    void setAdaptiveIntervalUs(int64_t intervalUs) noexcept {
        intervalUs_ = intervalUs > 0 ? intervalUs : 0;
    }

    int64_t lastRenderedUs() const noexcept { return lastRenderedUs_; }
    int64_t lastSampleUs() const noexcept { return lastSampleUs_; }
    int64_t adaptiveIntervalUs() const noexcept { return intervalUs_; }

private:
    int64_t lastRenderedUs_ = -1;
    int64_t lastSampleUs_ = -1;
    int64_t intervalUs_ = 0;
    bool forceNext_ = false;
};

} // namespace sp
