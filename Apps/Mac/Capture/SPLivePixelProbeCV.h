#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <mach/mach_time.h>
#include <cmath>
#include <initializer_list>
#import "SPLivePixelProbe.hpp"

static double SPPixelProbeCostMs(uint64_t started) {
    static mach_timebase_info_data_t info;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&info); });
    return (double)(mach_absolute_time() - started) * (double)info.numer / (double)info.denom / 1e6;
}

// Sample existing CPU-visible buffers only on an explicit isolated test run.
// The fingerprint covers a grid, not the entire image or the final screen.
static NSDictionary *SPPixelFingerprintBuffer(CVPixelBufferRef buffer) {
    const uint64_t started = mach_absolute_time();
    if (!buffer) return @{ @"status": @"buffer_missing", @"costMs": @(SPPixelProbeCostMs(started)) };
    OSType format = CVPixelBufferGetPixelFormatType(buffer);
    BOOL bgra = format == kCVPixelFormatType_32BGRA;
    BOOL yuv = (format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) && CVPixelBufferGetPlaneCount(buffer) > 0;
    size_t width = bgra ? CVPixelBufferGetWidth(buffer) : (yuv ? CVPixelBufferGetWidthOfPlane(buffer, 0) : 0);
    size_t height = bgra ? CVPixelBufferGetHeight(buffer) : (yuv ? CVPixelBufferGetHeightOfPlane(buffer, 0) : 0);
    NSMutableDictionary *result = [@{ @"pixelFormat": @(format), @"width": @(width), @"height": @(height),
        @"sampledHost": @(started), @"method": bgra ? @"grid-BGR" : (yuv ? @"grid-Y" : @"unsupported") } mutableCopy];
    if (!bgra && !yuv) {
        result[@"status"] = @"unsupported_pixel_format";
        result[@"costMs"] = @(SPPixelProbeCostMs(started));
        return result;
    }
    CVReturn locked = CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    if (locked != kCVReturnSuccess) {
        result[@"status"] = @"lock_failed"; result[@"lockError"] = @(locked);
        result[@"costMs"] = @(SPPixelProbeCostMs(started));
        return result;
    }
    const uint8_t *base = (const uint8_t *)(bgra ? CVPixelBufferGetBaseAddress(buffer) : CVPixelBufferGetBaseAddressOfPlane(buffer, 0));
    size_t stride = bgra ? CVPixelBufferGetBytesPerRow(buffer) : CVPixelBufferGetBytesPerRowOfPlane(buffer, 0);
    sp::PixelFingerprint fingerprint;
    BOOL ok = sp::fingerprintPixels(base, stride, width, height, bgra ? 4 : 1, bgra ? 3 : 1, fingerprint);
    // Explicit diagnostics only: a few column averages reveal surface padding
    // without recording an image. BGRA luma and video-range Y use different scales.
    NSMutableArray *columns = [NSMutableArray array];
    if (base && width > 1 && height > 1) {
        for (double fraction : {0.01, 0.50, 0.90, 0.94, 0.96, 0.99}) {
            size_t x = (size_t)llround(fraction * (width-1)); double total=0; int count=0, minimum=255, maximum=0;
            for (int i=0; i<32; ++i) {
                size_t y=(size_t)((i+0.5)*height/32.0); if(y>=height)y=height-1;
                const uint8_t *px=base+y*stride+x*(bgra ? 4 : 1);
                int value=bgra ? (int)llround(0.114*px[0]+0.587*px[1]+0.299*px[2]) : px[0];
                total+=value; minimum=MIN(minimum,value); maximum=MAX(maximum,value); count++;
            }
            [columns addObject:@{ @"xFraction":@(fraction), @"x":@(x), @"mean":@(total/count), @"min":@(minimum), @"max":@(maximum), @"samples":@(count) }];
        }
    }
    result[@"columnLumaSamples"] = columns;
    result[@"columnLumaScope"] = bgra ? @"BT.601-style luma estimate from BGRA bytes" : @"raw Y bytes; video/full range follows pixelFormat";
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    result[@"status"] = ok ? @"ok" : @"invalid_buffer_layout";
    result[@"sampleCount"] = @(fingerprint.samples);
    if (ok) result[@"hash"] = [NSString stringWithFormat:@"%016llx", (unsigned long long)fingerprint.hash];
    result[@"costMs"] = @(SPPixelProbeCostMs(started));
    return result;
}
