#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import "SPLivePixelProbeCV.h"
#include <cassert>
#include <cstdio>
#include <cstring>

static void exercise(OSType format, BOOL planar) {
    CVPixelBufferRef buffer = nullptr;
    CVReturn created = CVPixelBufferCreate(kCFAllocatorDefault, 640, 360, format, nullptr, &buffer);
    assert(created == kCVReturnSuccess && buffer);
    assert(CVPixelBufferLockBaseAddress(buffer, 0) == kCVReturnSuccess);
    uint8_t *base = (uint8_t *)(planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer));
    size_t stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer);
    assert(base && stride > 0);
    memset(base, 0, stride * 360);
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    NSDictionary *first = SPPixelFingerprintBuffer(buffer);
    assert([first[@"status"] isEqual:@"ok"] && [first[@"sampleCount"] unsignedLongLongValue] == 320 * 180);
    assert([first[@"costMs"] doubleValue] >= 0 && [first[@"sampledHost"] unsignedLongLongValue] > 0);
    assert(CVPixelBufferLockBaseAddress(buffer, 0) == kCVReturnSuccess);
    base = (uint8_t *)(planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer));
    base[stride + (planar ? 1 : 4)] = 200; // sampled pixel (1,1)
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    NSDictionary *second = SPPixelFingerprintBuffer(buffer);
    assert([second[@"status"] isEqual:@"ok"] && ![first[@"hash"] isEqual:second[@"hash"]]);
    CVPixelBufferRelease(buffer);
}

int main() { @autoreleasepool {
    assert([SPPixelFingerprintBuffer(nullptr)[@"status"] isEqual:@"buffer_missing"]);
    exercise(kCVPixelFormatType_32BGRA, NO);
    exercise(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, YES);
    std::puts("Live pixel CoreVideo tests passed (real BGRA/NV12 buffers, cost and changed pixels)");
    return 0;
} }
