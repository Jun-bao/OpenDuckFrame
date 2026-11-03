#include "SPLivePixelProbe.hpp"
#include <cassert>
#include <cstdio>
#include <vector>

int main() {
    constexpr size_t width = 640, height = 360, stride = width * 4;
    std::vector<uint8_t> pixels(stride * height, 0);
    sp::PixelFingerprint a, b, c;
    assert(sp::fingerprintPixels(pixels.data(), stride, width, height, 4, 3, a));
    assert(a.samples == 320 * 180);
    assert(sp::fingerprintPixels(pixels.data(), stride, width, height, 4, 3, b));
    assert(a.hash == b.hash);
    // At this size the sample grid starts at (1,1); a changed sampled pixel
    // changes the fingerprint, while alpha alone is intentionally ignored.
    pixels[stride + 4] = 123;
    assert(sp::fingerprintPixels(pixels.data(), stride, width, height, 4, 3, b));
    assert(a.hash != b.hash);
    pixels[stride + 4 + 3] = 255;
    assert(sp::fingerprintPixels(pixels.data(), stride, width, height, 4, 3, c));
    assert(b.hash == c.hash);
    assert(!sp::fingerprintPixels(nullptr, stride, width, height, 4, 3, c));
    assert(!sp::fingerprintPixels(pixels.data(), 12, width, height, 4, 3, c));
    assert(sp::fingerprintPixels(pixels.data(), width, width, height, 1, 1, c));
    std::puts("Live pixel fingerprint tests passed (BGRA, luma, sampled change, bounds)");
}
