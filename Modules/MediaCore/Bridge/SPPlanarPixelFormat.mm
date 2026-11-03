#import "SPPlanarPixelFormat.h"

#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>
#include <cstring>

static void spRegisterOne(OSType fmt, CFStringRef range, NSString *name) {
    NSDictionary *luma = @{
        (__bridge NSString *)kCVPixelFormatBlockWidth : @1,
        (__bridge NSString *)kCVPixelFormatBlockHeight : @1,
        (__bridge NSString *)kCVPixelFormatBitsPerBlock : @16,
        (__bridge NSString *)kCVPixelFormatHorizontalSubsampling : @1,
        (__bridge NSString *)kCVPixelFormatVerticalSubsampling : @1,
    };
    NSDictionary *chroma = @{
        (__bridge NSString *)kCVPixelFormatBlockWidth : @1,
        (__bridge NSString *)kCVPixelFormatBlockHeight : @1,
        (__bridge NSString *)kCVPixelFormatBitsPerBlock : @16,
        (__bridge NSString *)kCVPixelFormatHorizontalSubsampling : @2,
        (__bridge NSString *)kCVPixelFormatVerticalSubsampling : @2,
    };
    NSDictionary *desc = @{
        (__bridge NSString *)kCVPixelFormatName : name,
        (__bridge NSString *)kCVPixelFormatConstant : @(fmt),
        (__bridge NSString *)kCVPixelFormatPlanes : @[ luma, chroma, chroma ],
        (__bridge NSString *)kCVPixelFormatContainsYCbCr : @YES,
        (__bridge NSString *)kCVPixelFormatComponentRange : (__bridge id)range,
        (__bridge NSString *)kCVPixelFormatBitsPerBlock : @16,
    };
    CVPixelFormatDescriptionRegisterDescriptionWithPixelFormatType(
        (__bridge CFDictionaryRef)desc, fmt);
}

void spRegisterPlanarPixelFormats(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        spRegisterOne(kSPPixelFormat420Planar16VideoRange,
                      kCVPixelFormatComponentRange_VideoRange,
                      @"OpenDuckFrame 4:2:0 planar 16-bit (video range)");
        spRegisterOne(kSPPixelFormat420Planar16FullRange,
                      kCVPixelFormatComponentRange_FullRange,
                      @"OpenDuckFrame 4:2:0 planar 16-bit (full range)");
    });
}

CVPixelBufferRef spCreateBiPlanarCopy(CVPixelBufferRef planar) {
    if (!planar) return NULL;
    const OSType fmt = CVPixelBufferGetPixelFormatType(planar);
    if (!spPixelFormatIsPlanar3(fmt) || CVPixelBufferGetPlaneCount(planar) != 3) {
        return CVPixelBufferRetain(planar);
    }
    const bool tenBit = spPixelFormatIsTenBit(fmt);
    const size_t w = CVPixelBufferGetWidth(planar), h = CVPixelBufferGetHeight(planar);
    NSDictionary *attrs = @{
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{},
    };
    CVPixelBufferRef out = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, spPixelFormatBiPlanarEquivalent(fmt),
                            (__bridge CFDictionaryRef)attrs, &out) != kCVReturnSuccess || !out) {
        return NULL;
    }
    if (CVPixelBufferLockBaseAddress(planar, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        CVPixelBufferRelease(out);
        return NULL;
    }
    CVPixelBufferLockBaseAddress(out, 0);
    const size_t cw = CVPixelBufferGetWidthOfPlane(planar, 1);
    const size_t ch = CVPixelBufferGetHeightOfPlane(planar, 1);
    const uint8_t *sy = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(planar, 0);
    const uint8_t *su = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(planar, 1);
    const uint8_t *sv = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(planar, 2);
    const size_t syStride = CVPixelBufferGetBytesPerRowOfPlane(planar, 0);
    const size_t scStride = CVPixelBufferGetBytesPerRowOfPlane(planar, 1);
    uint8_t *dy = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(out, 0);
    uint8_t *duv = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(out, 1);
    const size_t dyStride = CVPixelBufferGetBytesPerRowOfPlane(out, 0);
    const size_t duvStride = CVPixelBufferGetBytesPerRowOfPlane(out, 1);
    if (tenBit) {
        for (size_t y = 0; y < h; y++) {
            const uint16_t *s = (const uint16_t *)(sy + y * syStride);
            uint16_t *d = (uint16_t *)(dy + y * dyStride);
            for (size_t x = 0; x < w; x++) d[x] = (uint16_t)(s[x] << 6);
        }
        for (size_t y = 0; y < ch; y++) {
            const uint16_t *u = (const uint16_t *)(su + y * scStride);
            const uint16_t *v = (const uint16_t *)(sv + y * scStride);
            uint16_t *d = (uint16_t *)(duv + y * duvStride);
            for (size_t x = 0; x < cw; x++) {
                d[2 * x] = (uint16_t)(u[x] << 6);
                d[2 * x + 1] = (uint16_t)(v[x] << 6);
            }
        }
    } else {
        for (size_t y = 0; y < h; y++) memcpy(dy + y * dyStride, sy + y * syStride, w);
        for (size_t y = 0; y < ch; y++) {
            const uint8_t *u = su + y * scStride, *v = sv + y * scStride;
            uint8_t *d = duv + y * duvStride;
            for (size_t x = 0; x < cw; x++) {
                d[2 * x] = u[x];
                d[2 * x + 1] = v[x];
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(out, 0);
    CVPixelBufferUnlockBaseAddress(planar, kCVPixelBufferLock_ReadOnly);
    CVBufferPropagateAttachments(planar, out);
    return out;
}
