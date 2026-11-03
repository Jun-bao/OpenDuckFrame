// Seek and catch-up targets in microseconds. Nonnegative values are valid,
// including an exact seek to zero; -1 is the unset sentinel.
#pragma once

#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>

namespace sp {

// Floating-point and timestamp quantization can place a precise target just
// before its keyframe and force decoding the previous GOP. Add a bounded
// tolerance only to the backward demux lookup; keep presentation, catch-up and
// audio-trim targets unchanged. A tolerance smaller than one frame interval
// cannot skip the first frame eligible for presentation in the PTS domain.
// Coarse seeks, forward keyframe stepping and audio-only seeks use no tolerance.
inline int64_t spSeekGridToleranceUs(int64_t frameIntervalUs) {
    if (frameIntervalUs <= 0) return 0;
    // Bound tolerance by one quarter of a frame and at most four milliseconds.
    int64_t tol = frameIntervalUs / 4;
    if (tol > 4000) tol = 4000;
    return tol;
}

// Demux lookup tolerance requires index timestamps in the presentation domain.
// Accept the known PTS-indexed container families; otherwise require no frame
// reordering so DTS and PTS coincide. TS/PS use their separate PTS-based RAP path.
inline bool spSeekTsIsPtsDomain(const std::string &container, int videoDelay) {
    if (container.find("mov,mp4") != std::string::npos ||
        container.find("matroska") != std::string::npos ||
        container.find("webm") != std::string::npos) return true;
    return videoDelay <= 0;
}

// Sequentially consistent target with one publishing/clearing thread and
// read-only observers. No consumer can race a later publication while clearing.
struct SPSeekTargetUs {
    void set(int64_t us) { us_.store(us); }
    void clear() { us_.store(-1); }
    int64_t us() const { return us_.load(); }
    bool valid() const { return us_.load() >= 0; }

private:
    std::atomic<int64_t> us_{-1};
};

// Consumable audio-trim target. A publication sequence distinguishes equal
// values from different seeks and prevents ABA consumption. Both set and clear
// advance identity; consume succeeds only for the sampled publication.
struct SPConsumableSeekTargetUs {
    static_assert(std::atomic<bool>::is_always_lock_free,
                  "Background admission must not acquire the playback target mutex");
    struct Sample {
        int64_t us = -1;
        uint64_t seq = 0;
        bool valid() const { return us >= 0; }
    };

    void set(int64_t us) {
        std::lock_guard<std::mutex> lk(mtx_);
        us_ = us;
        seq_++;
        pending_.store(us >= 0, std::memory_order_release);
    }
    void clear() {
        std::lock_guard<std::mutex> lk(mtx_);
        us_ = -1;
        seq_++;
        pending_.store(false, std::memory_order_release);
    }
    Sample sample() const {
        std::lock_guard<std::mutex> lk(mtx_);
        return {us_, seq_};
    }
    // Admission probes only need presence, never the consumable identity.
    // Keep them off the seek/audio mutex; all writes remain inside the existing
    // state-change critical sections. This does not grant consumption rights.
    bool hasPending() const noexcept {
        return pending_.load(std::memory_order_acquire);
    }
    // Consume exactly once only if the sampled publication identity still matches.
    bool consumeIfStill(const Sample &sample) {
        std::lock_guard<std::mutex> lk(mtx_);
        if (seq_ != sample.seq) return false;
        us_ = -1;
        seq_++;
        pending_.store(false, std::memory_order_release);
        return true;
    }

private:
    mutable std::mutex mtx_;
    int64_t us_ = -1;
    uint64_t seq_ = 0;
    std::atomic<bool> pending_{false};
};

// Coarse landing trim is published by the demux thread after seek completion,
// when the actual landing packet is known. Stamp it with the seek generation
// so an earlier landing cannot trim a later audio segment.
struct SPLandingTrimTargetUs {
    struct Sample {
        int64_t us = -1;
        int64_t gen = -1;
    };

    // Demux-published landing timestamp in zero-based microseconds.
    void publish(int64_t gen, int64_t us) {
        std::lock_guard<std::mutex> lk(mtx_);
        us_ = us;
        gen_ = gen;
    }
    // Clear at each new session because seek generations restart at zero.
    void clearForNewSession() {
        std::lock_guard<std::mutex> lk(mtx_);
        us_ = -1;
        gen_ = -1;
    }
    Sample sample() const {
        std::lock_guard<std::mutex> lk(mtx_);
        return {us_, gen_};
    }

private:
    mutable std::mutex mtx_;
    int64_t us_ = -1;
    int64_t gen_ = -1;
};

// Pure first-audio-packet landing-trim policy. Existing segment content,
// mismatched generations or excessive timestamp gaps prohibit trimming.
struct SPLandingTrimDecision {
    enum Action { Pass, TrimHead, DropWhole };
    Action action = Pass;
    int skipFrames = 0;   // Number of 48 kHz frames skipped by TrimHead.
    int64_t contentUs = 0; // New audio-content start for TrimHead.
};

// Decoded packet timestamp and 48 kHz frame count. Supply the caller's missing
// timestamp sentinel so this header remains independent of FFmpeg.
inline SPLandingTrimDecision spEvaluateLandingAudioTrim(
    int64_t contentUs, int frames, int64_t nextPtsUs,
    const SPLandingTrimTargetUs::Sample &land, int64_t pktGen,
    int64_t maxTrimUs, int64_t noPtsSentinel) noexcept {
    SPLandingTrimDecision d;
    if (frames <= 0) return d;
    if (nextPtsUs >= 0) return d;              // Existing segment content.
    if (contentUs == noPtsSentinel) return d;  // Missing timestamp cannot be compared.
    if (land.us < 0 || land.gen != pktGen) return d;
    if (land.us <= contentUs) return d;        // Audio at or after the landing requires no trim.
    if (land.us - contentUs > maxTrimUs) return d;
    const int64_t endUs = contentUs + (int64_t)frames * 1000000 / 48000;
    if (endUs <= land.us) {
        d.action = SPLandingTrimDecision::DropWhole;
        return d;
    }
    int64_t skip = (land.us - contentUs) * 48 / 1000; // 48 frames per millisecond.
    if (skip > frames) skip = frames;
    d.action = SPLandingTrimDecision::TrimHead;
    d.skipFrames = (int)skip;
    d.contentUs = land.us;
    return d;
}

// Coarse-seek clock anchoring uses the real audio ring's content start and
// the output-frame counter captured when that content was enqueued. Until this
// pair is published, use the landing timestamp provisionally and register adoption.
// Accept only current-generation, continuous audio; reject implausibly distant
// timestamps. The provisional frame baseline is captured at seek time, not at
// later adoption, so already-played progress is preserved.
struct SPCoarseAnchorDecision {
    enum Source { Candidate, RingStart };
    Source source = Candidate;
    int64_t baseUs = 0;       // → _audioClockBaseUs
    int64_t baseFrames = 0;   // → _audioBasePlayedFrames
    bool pendingAdoption = false; // Await publication, then reevaluate with the exact ring anchor.
};

// Audio publishes ring generation, content start and frame counter together.
// segmentStartFrames is the output-frame counter captured by the seek.
inline SPCoarseAnchorDecision spEvaluateCoarseSeekAnchor(
    int64_t candidatePtsUs, int64_t ringStartGen, int64_t ringStartUs,
    int64_t ringStartFrames, int64_t currentGen, int64_t segmentStartFrames,
    int64_t continuityTolUs) noexcept {
    SPCoarseAnchorDecision d;
    if (ringStartGen == currentGen && ringStartUs >= 0) {
        const int64_t delta = ringStartUs > candidatePtsUs
                                  ? ringStartUs - candidatePtsUs
                                  : candidatePtsUs - ringStartUs;
        if (delta <= continuityTolUs) {
            d.source = SPCoarseAnchorDecision::RingStart;
            d.baseUs = ringStartUs;
            d.baseFrames = ringStartFrames;
            return d;
        }
        // Reject a published but untrustworthy anchor without waiting again this generation.
        d.baseUs = candidatePtsUs;
        d.baseFrames = segmentStartFrames;
        return d;
    }
    d.baseUs = candidatePtsUs;
    d.baseFrames = segmentStartFrames;
    d.pendingAdoption = true;
    return d;
}

// Publish only a verified coarse-seek landing from the current generation.
// Require successful frame acceptance and an exact match to the demuxer's
// current-generation key packet. Precise seeks and stale frames cannot provide
// this UI correction value. Return Confirmed, Rejected or Pending accordingly.
struct SPCoarseLandingDecision {
    enum Outcome { Pending, Confirmed, Rejected };
    Outcome outcome = Pending;
    int64_t landingUs = -1;
};

inline SPCoarseLandingDecision spConfirmCoarseSeekLanding(
    int64_t frameGen, int64_t framePtsUs, bool submitted, int64_t currentGen,
    int64_t coarseLandingGen, const SPLandingTrimTargetUs::Sample &key) noexcept {
    SPCoarseLandingDecision d;
    if (coarseLandingGen < 0 || coarseLandingGen != currentGen) {
        d.outcome = SPCoarseLandingDecision::Rejected; // Not the current coarse-seek generation.
        return d;
    }
    if (frameGen != currentGen) return d;   // An old frame cannot confirm this generation.
    if (!submitted) return d;               // Wait for a successful submission retry.
    if (key.gen != frameGen || key.us < 0 || key.us != framePtsUs) {
        // The first accepted frame does not match the demuxer's landing packet.
        // Publication precedes queuing, so no later landing proof can arrive.
        d.outcome = SPCoarseLandingDecision::Rejected;
        return d;
    }
    d.outcome = SPCoarseLandingDecision::Confirmed;
    d.landingUs = key.us;
    return d;
}

} // namespace sp
