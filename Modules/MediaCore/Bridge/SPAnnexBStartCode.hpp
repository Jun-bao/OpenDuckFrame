#pragma once

#include <cstddef>
#include <cstdint>
#if defined(__aarch64__)
#include <arm_neon.h>
#endif

namespace spvideo {

// Short NALs and non-arm64 retain the three-byte skip scanner. No padding is
// required; `from` may point inside a prefix or at/past the end of the buffer.
inline size_t findStartCodeScalar(const uint8_t *d, size_t size, size_t from) {
    if (from > size || size - from < 3) return SIZE_MAX;
    size_t i = from;
    const size_t last = size - 3;
    while (i <= last) {
        const uint8_t c = d[i + 2];
        if (c > 1) { i += 3; continue; }
        if (c == 1) {
            if (d[i] == 0 && d[i + 1] == 0) return i;
            i += 3;
            continue;
        }
        if (d[i] == 0 && d[i + 1] == 0 && i < last && d[i + 3] == 1)
            return i;
        ++i;
    }
    return SIZE_MAX;
}

// Locate 00 00 01, returning the preceding zero for a four-byte prefix, but
// never before `from`. Three overlapping loads inspect 16 candidate positions
// using exactly 18 readable bytes. This also handles prefixes across blocks.
inline size_t findStartCode(const uint8_t *d, size_t size, size_t from) {
#if defined(__aarch64__)
    if (from > size || size - from < 256)
        return findStartCodeScalar(d, size, from);
    // Small NALs also occur inside large packets. Probe the first 32 positions
    // with the cheap skip loop before paying SIMD setup/reduction costs.
    const size_t early = findStartCodeScalar(d, from + 34, from);
    if (early != SIZE_MAX) return early;
    const uint8x16_t zero = vdupq_n_u8(0), one = vdupq_n_u8(1);
    const uint8x16_t indexes = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15};
    size_t i = from + 32;
    while (size - i >= 18) {
        uint8x16_t match = vandq_u8(vceqq_u8(vld1q_u8(d + i), zero),
                                   vceqq_u8(vld1q_u8(d + i + 1), zero));
        match = vandq_u8(match, vceqq_u8(vld1q_u8(d + i + 2), one));
        if (vmaxvq_u8(match)) {
            const size_t p = i + vminvq_u8(vorrq_u8(vmvnq_u8(match), indexes));
            return p > from && d[p - 1] == 0 ? p - 1 : p;
        }
        i += 16;
    }
    // The zero of a four-byte prefix can be in the previous SIMD block.
    // A fresh scalar search starting at i alone would lose that zero.
    while (size - i >= 3) {
        if (d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1)
            return i > from && d[i - 1] == 0 ? i - 1 : i;
        ++i;
    }
    return SIZE_MAX;
#else
    return findStartCodeScalar(d, size, from);
#endif
}

} // namespace spvideo
