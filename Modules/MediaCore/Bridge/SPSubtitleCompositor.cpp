#include "SPSubtitleCompositor.hpp"

#if defined(__aarch64__)
#include <arm_neon.h>
#endif

namespace sp {
namespace {

inline unsigned div255(unsigned value) {
    return (value + 1 + (value >> 8)) >> 8;
}

inline void compositeScalar(uint8_t *destination, std::ptrdiff_t destinationStride,
                            const uint8_t *mask, std::ptrdiff_t maskStride,
                            int width, int height, uint32_t color) {
    const uint8_t red = (uint8_t)((color >> 24) & 0xff);
    const uint8_t green = (uint8_t)((color >> 16) & 0xff);
    const uint8_t blue = (uint8_t)((color >> 8) & 0xff);
    const uint8_t opacity = (uint8_t)(255 - (color & 0xff));
    if (!destination || !mask || width <= 0 || height <= 0 || opacity == 0) return;

    for (int y = 0; y < height; ++y) {
        const uint8_t *sourcePixel = mask + (std::ptrdiff_t)y * maskStride;
        uint8_t *pixel = destination + (std::ptrdiff_t)y * destinationStride;
        for (int x = 0; x < width; ++x) {
            const uint8_t luminance = *sourcePixel++;
            if (luminance == 0) {
                pixel += 4;
                continue;
            }
            const unsigned alpha = opacity == 255
                ? luminance : div255((unsigned)luminance * opacity);
            if (alpha == 0) {
                pixel += 4;
                continue;
            }
            if (alpha == 255) {
                pixel[0] = blue;
                pixel[1] = green;
                pixel[2] = red;
                pixel[3] = 255;
            } else if (pixel[3] == 0) {
                pixel[0] = (uint8_t)div255((unsigned)blue * alpha);
                pixel[1] = (uint8_t)div255((unsigned)green * alpha);
                pixel[2] = (uint8_t)div255((unsigned)red * alpha);
                pixel[3] = (uint8_t)alpha;
            } else {
                const unsigned inverse = 255 - alpha;
                pixel[0] = (uint8_t)div255((unsigned)blue * alpha + pixel[0] * inverse);
                pixel[1] = (uint8_t)div255((unsigned)green * alpha + pixel[1] * inverse);
                pixel[2] = (uint8_t)div255((unsigned)red * alpha + pixel[2] * inverse);
                pixel[3] = (uint8_t)(alpha + div255((unsigned)pixel[3] * inverse));
            }
            pixel += 4;
        }
    }
}

#if defined(__aarch64__)
inline uint16x8_t div255Vector(uint16x8_t value) {
    const uint16x8_t rounded = vaddq_u16(
        vaddq_u16(value, vdupq_n_u16(1)), vshrq_n_u16(value, 8));
    return vshrq_n_u16(rounded, 8);
}

inline void compositeNeon(uint8_t *destination, std::ptrdiff_t destinationStride,
                          const uint8_t *mask, std::ptrdiff_t maskStride,
                          int width, int height, uint32_t color) {
    const uint8_t red = (uint8_t)((color >> 24) & 0xff);
    const uint8_t green = (uint8_t)((color >> 16) & 0xff);
    const uint8_t blue = (uint8_t)((color >> 8) & 0xff);
    const uint8_t opacity = (uint8_t)(255 - (color & 0xff));
    if (!destination || !mask || width <= 0 || height <= 0 || opacity == 0) return;

    const uint16x8_t zero = vdupq_n_u16(0);
    const uint16x8_t full = vdupq_n_u16(255);
    for (int y = 0; y < height; ++y) {
        const uint8_t *sourcePixel = mask + (std::ptrdiff_t)y * maskStride;
        uint8_t *pixel = destination + (std::ptrdiff_t)y * destinationStride;
        int x = 0;
        for (; x + 8 <= width; x += 8, sourcePixel += 8, pixel += 32) {
            const uint8x8_t luminance8 = vld1_u8(sourcePixel);
            if (vmaxv_u8(luminance8) == 0) continue;

            uint16x8_t alpha = vmovl_u8(luminance8);
            if (opacity != 255) {
                alpha = div255Vector(vmulq_n_u16(alpha, opacity));
            }
            const uint16x8_t inverse = vsubq_u16(full, alpha);
            const uint8x8x4_t destination8 = vld4_u8(pixel);
            uint16x8_t destinationBlue = vmovl_u8(destination8.val[0]);
            uint16x8_t destinationGreen = vmovl_u8(destination8.val[1]);
            uint16x8_t destinationRed = vmovl_u8(destination8.val[2]);
            const uint16x8_t destinationAlpha = vmovl_u8(destination8.val[3]);

            // Preserve the legacy empty-pixel branch even for an arbitrary
            // non-premultiplied destination: when alpha>0 and dstA==0, stale
            // destination RGB must not participate. alpha==0 keeps dst intact.
            const uint16x8_t clearDestination = vandq_u16(
                vcgtq_u16(alpha, zero), vceqq_u16(destinationAlpha, zero));
            destinationBlue = vbicq_u16(destinationBlue, clearDestination);
            destinationGreen = vbicq_u16(destinationGreen, clearDestination);
            destinationRed = vbicq_u16(destinationRed, clearDestination);

            const uint16x8_t outBlue = div255Vector(vaddq_u16(
                vmulq_n_u16(alpha, blue), vmulq_u16(destinationBlue, inverse)));
            const uint16x8_t outGreen = div255Vector(vaddq_u16(
                vmulq_n_u16(alpha, green), vmulq_u16(destinationGreen, inverse)));
            const uint16x8_t outRed = div255Vector(vaddq_u16(
                vmulq_n_u16(alpha, red), vmulq_u16(destinationRed, inverse)));
            const uint16x8_t outAlpha = vaddq_u16(
                alpha, div255Vector(vmulq_u16(destinationAlpha, inverse)));

            uint8x8x4_t output;
            output.val[0] = vmovn_u16(outBlue);
            output.val[1] = vmovn_u16(outGreen);
            output.val[2] = vmovn_u16(outRed);
            output.val[3] = vmovn_u16(outAlpha);
            vst4_u8(pixel, output);
        }

        if (x < width) {
            compositeScalar(pixel, 0, sourcePixel, 0, width - x, 1, color);
        }
    }
}
#endif

} // namespace

void compositeSubtitleBitmap(uint8_t *destination, std::ptrdiff_t destinationStride,
                             const uint8_t *mask, std::ptrdiff_t maskStride,
                             int width, int height, uint32_t color) {
#if defined(__aarch64__)
    compositeNeon(destination, destinationStride, mask, maskStride,
                  width, height, color);
#else
    compositeScalar(destination, destinationStride, mask, maskStride,
                    width, height, color);
#endif
}

#if defined(SP_SUBTITLE_COMPOSITOR_TESTING)
__attribute__((noinline))
void compositeSubtitleBitmapScalarForTesting(
    uint8_t *destination, std::ptrdiff_t destinationStride,
    const uint8_t *mask, std::ptrdiff_t maskStride,
    int width, int height, uint32_t color) {
    compositeScalar(destination, destinationStride, mask, maskStride,
                    width, height, color);
}
#endif

} // namespace sp
