// OpenDuckFrame — exact, allocation-free peak predicate for the audio RT callback.
#pragma once

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#if defined(__aarch64__) && !defined(SP_AUDIO_PEAK_FORCE_SCALAR)
#include <arm_neon.h>
#endif

namespace sp {

// Same Boolean decision as the scalar fabs(sample) > ceiling early-exit scan.
// NaN comparisons remain false; infinity exceeds any finite
// ceiling. This only chooses the existing DSP bypass; it never changes samples.
inline bool audioBlockWithinCeiling(const float *samples, std::size_t count,
                                   float ceiling) {
    std::size_t k = 0;
#if defined(__aarch64__) && !defined(SP_AUDIO_PEAK_FORCE_SCALAR)
    uint32_t ceilingBits;
    std::memcpy(&ceilingBits, &ceiling, sizeof(ceilingBits));
    // The production ceiling (1.0f) folds this guard away. Other thresholds keep
    // the original scalar semantics, including subnormal flushing under FPCR.FZ.
    // Integer ordering below is valid for positive, normal, finite thresholds.
    if (ceilingBits >= 0x00800000u && ceilingBits < 0x7f800000u) {
        // Keep the cheapest exit for an already-clipping first sample. Unaligned
        // vector loads stay within count, including very short blocks.
        if (count) {
            if (std::fabs(samples[0]) > ceiling) return false;
            k = 1;
        }
        const uint32x4_t limit = vdupq_n_u32(ceilingBits);
        const uint32x4_t infinity = vdupq_n_u32(0x7f800000u);
        const uint32x4_t magnitude = vdupq_n_u32(0x7fffffffu);
        const auto exceeds = [&](const float *p) {
            const uint32x4_t absolute = vandq_u32(vreinterpretq_u32_f32(vld1q_f32(p)), magnitude);
            // Exclude NaNs, include +/-infinity, exactly as fabs(x) > ceiling.
            return vandq_u32(vcgtq_u32(absolute, limit), vcleq_u32(absolute, infinity));
        };
        for (; count - k >= 16; k += 16) {
            const uint32x4_t a = exceeds(samples + k);
            const uint32x4_t b = exceeds(samples + k + 4);
            const uint32x4_t c = exceeds(samples + k + 8);
            const uint32x4_t d = exceeds(samples + k + 12);
            // Integer comparisons, not only masks: LLVM can rewrite ORs of
            // floating comparisons into FMAXNM, where sNaN can hide a peak.
            if (vmaxvq_u32(vorrq_u32(vorrq_u32(a, b), vorrq_u32(c, d)))) return false;
        }
        for (; count - k >= 4; k += 4) {
            const uint32x4_t mask = exceeds(samples + k);
            if (vmaxvq_u32(mask)) return false;
        }
    }
#endif
    for (; k < count; ++k) {
        if (std::fabs(samples[k]) > ceiling) return false;
    }
    return true;
}

} // namespace sp
