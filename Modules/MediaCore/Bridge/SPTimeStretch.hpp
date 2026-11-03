#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

#if defined(__aarch64__)
#include <arm_neon.h>
#endif

namespace sp_time_stretch_detail {

// Kept as the reference implementation for non-stereo/non-arm64 builds and
// differential tests. The product Release build contracts each accumulation
// to one FP64 FMA.
inline double scoreScalar(const float *mid, const float *candidate, size_t samples) {
    double corr = 0.0;
    double energy = 1e-9;
    for (size_t k = 0; k < samples; ++k) {
        corr += (double)mid[k] * candidate[k];
        energy += (double)candidate[k] * candidate[k];
    }
    return corr / std::sqrt(energy);
}

inline int bestOffsetScalar(const float *mid, const float *window,
                            size_t samples, int seekFrames, int channels) {
    int best = 0;
    double bestScore = -1e300;
    for (int off = 0; off < seekFrames; ++off) {
        const double score = scoreScalar(mid, window + (size_t)off * channels, samples);
        if (score > bestScore) {
            bestScore = score;
            best = off;
        }
    }
    return best;
}

#if defined(__aarch64__)
// Four consecutive stereo candidates occupy four independent FP64 lanes.
// Each lane still accumulates L, R, then the next frame, exactly matching the
// scalar operation order; only work from different candidates is interleaved.
inline int bestOffsetNeonStereo(const float *mid, const float *window,
                                size_t samples, int seekFrames) {
    int best = 0;
    double bestScore = -1e300;
    int off = 0;
    for (; off + 4 <= seekFrames; off += 4) {
        const float *candidate = window + (size_t)off * 2;
        float64x2_t corr01 = vdupq_n_f64(0.0);
        float64x2_t corr23 = vdupq_n_f64(0.0);
        float64x2_t energy01 = vdupq_n_f64(1e-9);
        float64x2_t energy23 = vdupq_n_f64(1e-9);

        for (size_t k = 0; k < samples; k += 2) {
            const float32x2_t midLR = vld1_f32(mid + k);
            const float32x4_t candidate01 = vld1q_f32(candidate + k);
            const float32x4_t candidate23 = vld1q_f32(candidate + k + 4);
            const float32x4x2_t lr = vuzpq_f32(candidate01, candidate23);
            const float64x2_t left01 = vcvt_f64_f32(vget_low_f32(lr.val[0]));
            const float64x2_t left23 = vcvt_high_f64_f32(lr.val[0]);
            const float64x2_t right01 = vcvt_f64_f32(vget_low_f32(lr.val[1]));
            const float64x2_t right23 = vcvt_high_f64_f32(lr.val[1]);
            const float64x2_t midLeft = vdupq_n_f64((double)vget_lane_f32(midLR, 0));
            const float64x2_t midRight = vdupq_n_f64((double)vget_lane_f32(midLR, 1));

            corr01 = vfmaq_f64(corr01, midLeft, left01);
            corr23 = vfmaq_f64(corr23, midLeft, left23);
            energy01 = vfmaq_f64(energy01, left01, left01);
            energy23 = vfmaq_f64(energy23, left23, left23);
            corr01 = vfmaq_f64(corr01, midRight, right01);
            corr23 = vfmaq_f64(corr23, midRight, right23);
            energy01 = vfmaq_f64(energy01, right01, right01);
            energy23 = vfmaq_f64(energy23, right23, right23);
        }

        const float64x2_t score01 = vdivq_f64(corr01, vsqrtq_f64(energy01));
        const float64x2_t score23 = vdivq_f64(corr23, vsqrtq_f64(energy23));
        const double scores[4] = {
            vgetq_lane_f64(score01, 0), vgetq_lane_f64(score01, 1),
            vgetq_lane_f64(score23, 0), vgetq_lane_f64(score23, 1),
        };
        // Preserve scalar tie and NaN behavior by comparing in offset order.
        for (int lane = 0; lane < 4; ++lane) {
            if (scores[lane] > bestScore) {
                bestScore = scores[lane];
                best = off + lane;
            }
        }
    }

    for (; off < seekFrames; ++off) {
        const double score = scoreScalar(mid, window + (size_t)off * 2, samples);
        if (score > bestScore) {
            bestScore = score;
            best = off;
        }
    }
    return best;
}
#endif

inline int bestOffset(const float *mid, const float *window,
                      size_t samples, int seekFrames, int channels) {
#if defined(__aarch64__)
    if (channels == 2) return bestOffsetNeonStereo(mid, window, samples, seekFrames);
#endif
    return bestOffsetScalar(mid, window, samples, seekFrames, channels);
}

} // namespace sp_time_stretch_detail

class SPTimeStretcher {
public:
    SPTimeStretcher(int channels, int sampleRate,
                    double overlapMs = 8.0, double seqMs = 40.0, double seekMs = 15.0)
        : ch_(channels),
          overlap_(std::max(8, (int)(sampleRate * overlapMs / 1000.0))),
          seq_(std::max(overlap_ * 3, (int)(sampleRate * seqMs / 1000.0))),
          seek_(std::max(1, (int)(sampleRate * seekMs / 1000.0))) {
        mid_.assign((size_t)overlap_ * ch_, 0.0f);
        out_.resize((size_t)(seq_ - overlap_) * ch_);
        fifo_.reserve((size_t)(seq_ + seek_ + 8192) * ch_);
    }

    int channels() const { return ch_; }
    int overlapFrames() const { return overlap_; }
    int windowFrames() const { return seq_ + seek_; }

    int hopFrames() const { return seq_ - overlap_; }

#if defined(SP_TIMESTRETCH_TESTING)
    void forceScalarSearchForTesting(bool enabled) { forceScalarSearchForTesting_ = enabled; }
    int scalarBestOffsetForTesting(const float *mid, const float *window) const {
        return sp_time_stretch_detail::bestOffsetScalar(
            mid, window, (size_t)overlap_ * ch_, seek_, ch_);
    }
    int optimizedBestOffsetForTesting(const float *mid, const float *window) const {
        return sp_time_stretch_detail::bestOffset(
            mid, window, (size_t)overlap_ * ch_, seek_, ch_);
    }
    int searchFramesForTesting() const { return seek_; }
#endif

    void setRate(double rate) { rate_ = rate > 0.0 ? rate : 1.0; }
    double rate() const { return rate_; }

    void reset() {
        fifo_.clear();
        head_ = 0;
        skipFract_ = 0.0;
        skipRemaining_ = 0;
        std::fill(mid_.begin(), mid_.end(), 0.0f);
        midValid_ = false;
    }

    int64_t pendingInputFrames() const {
        return (int64_t)(fifo_.size() / ch_) - (int64_t)head_ - skipRemaining_;
    }

    void primeTail(const float *data, int frames) {
        if (frames <= 0) return;
        if (frames >= overlap_) {
            std::memcpy(mid_.data(), data + (size_t)(frames - overlap_) * ch_,
                        (size_t)overlap_ * ch_ * sizeof(float));
        } else {
            size_t keep = (size_t)(overlap_ - frames) * ch_;
            std::memmove(mid_.data(), mid_.data() + (size_t)frames * ch_, keep * sizeof(float));
            std::memcpy(mid_.data() + keep, data, (size_t)frames * ch_ * sizeof(float));
        }
        midValid_ = true;
    }

    template <class Sink>
    void process(const float *in, int frames, Sink &&sink) {
        if (frames > 0 && in) {

            int64_t drop = std::min<int64_t>(skipRemaining_, frames);
            skipRemaining_ -= drop;
            in += drop * ch_;
            frames -= (int)drop;
            if (frames > 0) {
                compact();
                fifo_.insert(fifo_.end(), in, in + (size_t)frames * ch_);
            }
        }
        while (available() >= seq_ + seek_) {
            const float *win = fifo_.data() + head_ * ch_;
            int offset = midValid_ ? bestOffset(win) : 0;
            const float *src = win + (size_t)offset * ch_;

            for (int i = 0; i < overlap_; i++) {
                float t = (i + 0.5f) / overlap_;
                for (int c = 0; c < ch_; c++) {
                    size_t k = (size_t)i * ch_ + c;
                    out_[k] = mid_[k] * (1.0f - t) + src[k] * t;
                }
            }
            std::memcpy(out_.data() + (size_t)overlap_ * ch_, src + (size_t)overlap_ * ch_,
                        (size_t)(seq_ - 2 * overlap_) * ch_ * sizeof(float));
            std::memcpy(mid_.data(), src + (size_t)(seq_ - overlap_) * ch_,
                        (size_t)overlap_ * ch_ * sizeof(float));
            midValid_ = true;
            const bool go = sink((const float *)out_.data(), seq_ - overlap_);

            skipFract_ += rate_ * (seq_ - overlap_);
            int64_t skip = (int64_t)skipFract_;
            skipFract_ -= (double)skip;
            int64_t avail = available();
            int64_t consume = std::min<int64_t>(skip, avail);
            head_ += (size_t)consume;
            skipRemaining_ += skip - consume;
            if (!go) break;
            if (skipRemaining_ > 0) break;
        }
    }

    template <class Sink>
    void finish(Sink &&sink) {
        const int64_t pending = pendingInputFrames();
        if (pending <= 0) { reset(); return; }
        const int64_t expectOut = (int64_t)std::llround((double)pending / rate_);
        std::vector<float> zeros((size_t)(seq_ + seek_) * ch_, 0.0f);
        int64_t emitted = 0;
        process(zeros.data(), seq_ + seek_, [&](const float *o, int n) {
            const int take = (int)std::min<int64_t>(n, expectOut - emitted);
            if (take > 0) {
                if (!sink(o, take)) return false;
                emitted += take;
            }
            return emitted < expectOut;
        });
        reset();
    }

    template <class Sink>
    void flushRaw(Sink &&sink) {
        int64_t n = available();
        if (n > 0) (void)sink((const float *)(fifo_.data() + head_ * ch_), (int)n);
        reset();
    }

private:
    int64_t available() const { return (int64_t)(fifo_.size() / ch_) - (int64_t)head_; }

    void compact() {
        if (head_ == 0) return;
        size_t keep = fifo_.size() - head_ * ch_;
        if (keep) std::memmove(fifo_.data(), fifo_.data() + head_ * ch_, keep * sizeof(float));
        fifo_.resize(keep);
        head_ = 0;
    }

    int bestOffset(const float *win) const {
        const size_t n = (size_t)overlap_ * ch_;
#if defined(SP_TIMESTRETCH_TESTING)
        if (forceScalarSearchForTesting_) {
            return sp_time_stretch_detail::bestOffsetScalar(
                mid_.data(), win, n, seek_, ch_);
        }
#endif
        return sp_time_stretch_detail::bestOffset(mid_.data(), win, n, seek_, ch_);
    }

    const int ch_;
    const int overlap_;
    const int seq_;
    const int seek_;
    double rate_ = 1.0;
    double skipFract_ = 0.0;
    int64_t skipRemaining_ = 0;
    std::vector<float> fifo_;
    size_t head_ = 0;
    std::vector<float> mid_;
    bool midValid_ = false;
    std::vector<float> out_;
#if defined(SP_TIMESTRETCH_TESTING)
    bool forceScalarSearchForTesting_ = false;
#endif
};
