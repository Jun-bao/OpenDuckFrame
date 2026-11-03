// OpenDuckFrame — pure CPU compositor for libass grayscale masks.
#pragma once

#include <cstddef>
#include <cstdint>

namespace sp {

// Composite one already-clipped ASS bitmap into a premultiplied BGRA8 canvas.
// color is libass RGBT (low byte is transparency, not opacity).
void compositeSubtitleBitmap(uint8_t *destination, std::ptrdiff_t destinationStride,
                             const uint8_t *mask, std::ptrdiff_t maskStride,
                             int width, int height, uint32_t color);

#if defined(SP_SUBTITLE_COMPOSITOR_TESTING)
// Literal scalar backend retained only for differential tests/benchmarks.
void compositeSubtitleBitmapScalarForTesting(
    uint8_t *destination, std::ptrdiff_t destinationStride,
    const uint8_t *mask, std::ptrdiff_t maskStride,
    int width, int height, uint32_t color);
#endif

} // namespace sp
