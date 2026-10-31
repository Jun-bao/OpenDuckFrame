#pragma once
#include <algorithm>
#include <cstddef>
#include <cstdint>

// A bounded, non-cryptographic fingerprint of regularly spaced pixels.
// Equality is not proof of an identical frame: unsampled pixels can change.
namespace sp {
struct PixelFingerprint {
    uint64_t hash = 0;
    size_t samples = 0;
};

inline bool fingerprintPixels(const uint8_t *base, size_t stride, size_t width, size_t height,
                              size_t pixelBytes, size_t usedBytes, PixelFingerprint &out) {
    out = {};
    if (!base || !width || !height || !pixelBytes || !usedBytes || usedBytes > pixelBytes ||
        width > stride / pixelBytes) return false;
    const size_t dx = std::max<size_t>(1, (width + 319) / 320);
    const size_t dy = std::max<size_t>(1, (height + 179) / 180);
    uint64_t hash = 14695981039346656037ull;
    for (size_t y = dy / 2; y < height; y += dy) {
        const uint8_t *row = base + y * stride;
        for (size_t x = dx / 2; x < width; x += dx) {
            const uint8_t *pixel = row + x * pixelBytes;
            for (size_t c = 0; c < usedBytes; ++c) {
                hash ^= pixel[c];
                hash *= 1099511628211ull;
            }
            ++out.samples;
        }
    }
    out.hash = hash;
    return out.samples != 0;
}
}
