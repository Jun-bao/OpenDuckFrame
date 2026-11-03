// Thumbnail black-border detector. It preserves the original quarter-sampled
// integer predicate, including P010's high-byte reduction and threshold equality.
#pragma once
#include <cstddef>
#include <cstdint>

namespace spthumb {
struct BlackBorders { size_t top = 0, bottom = 0, left = 0, right = 0; };

template<bool TenBit>
inline bool sampledLineIsBlack(const uint8_t *base, size_t step,
                                size_t count, unsigned threshold) {
    const uint64_t limit = uint64_t(threshold) * count;
    uint64_t sum = 0;
    size_t i = 0;
    // A bounded prefix catches ordinary bright edges without inserting a
    // branch into every sample of dark/letterboxed pictures. The remainder is
    // still a straight reduction, so the compiler can vectorize it as before.
    const size_t prefix = count < 16 ? count : 16;
    for (; i < prefix; ++i) {
        if constexpr (TenBit) sum += *reinterpret_cast<const uint16_t *>(base + i * step) >> 8;
        else sum += base[i * step];
    }
    // Samples are non-negative. Only strict > is conclusive; equality remains
    // black if every unread sample is zero. The limit uses the FULL count.
    if (sum > limit) return false;
    for (; i < count; ++i) {
        if constexpr (TenBit) sum += *reinterpret_cast<const uint16_t *>(base + i * step) >> 8;
        else sum += base[i * step];
    }
    return sum <= limit;
}

template<bool TenBit>
inline BlackBorders findBlackBorders(const uint8_t *base, size_t width,
                                      size_t height, size_t stride,
                                      unsigned threshold) {
    // The caller owns a readable, locked Y plane. P010's base/stride are
    // uint16_t-aligned, as required by the original CVPixelBuffer path too.
    BlackBorders b;
    constexpr size_t pixelBytes = TenBit ? 2 : 1;
    const size_t rowCount = width / 4 + (width % 4 != 0);
    const size_t colCount = height / 4 + (height % 4 != 0);
    const auto rowBlack = [&](size_t y) {
        return sampledLineIsBlack<TenBit>(base + y * stride, 4 * pixelBytes,
                                          rowCount, threshold);
    };
    const auto colBlack = [&](size_t x) {
        return sampledLineIsBlack<TenBit>(base + x * pixelBytes, 4 * stride,
                                          colCount, threshold);
    };
    while (b.top < height / 4 && rowBlack(b.top)) ++b.top;
    while (b.bottom < height / 4 && rowBlack(height - 1 - b.bottom)) ++b.bottom;
    while (b.left < width / 4 && colBlack(b.left)) ++b.left;
    while (b.right < width / 4 && colBlack(width - 1 - b.right)) ++b.right;
    return b;
}
} // namespace spthumb
