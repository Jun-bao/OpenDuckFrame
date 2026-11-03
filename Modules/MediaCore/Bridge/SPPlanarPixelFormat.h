#pragma once

#import <CoreVideo/CoreVideo.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

enum : OSType {
    kSPPixelFormat420Planar16VideoRange = 'Y3LV',
    kSPPixelFormat420Planar16FullRange = 'Y3LF',
};

void spRegisterPlanarPixelFormats(void);

static inline bool spPixelFormatIsPlanar3(OSType f) {
    return f == kCVPixelFormatType_420YpCbCr8Planar ||
           f == kCVPixelFormatType_420YpCbCr8PlanarFullRange ||
           f == kSPPixelFormat420Planar16VideoRange ||
           f == kSPPixelFormat420Planar16FullRange;
}

static inline bool spPixelFormatIsTenBit(OSType f) {
    return f == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
           f == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange ||
           f == kSPPixelFormat420Planar16VideoRange ||
           f == kSPPixelFormat420Planar16FullRange;
}

static inline bool spPixelFormatIsFullRange(OSType f) {
    return f == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
           f == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange ||
           f == kCVPixelFormatType_420YpCbCr8PlanarFullRange ||
           f == kSPPixelFormat420Planar16FullRange;
}

static inline OSType spPixelFormatBiPlanarEquivalent(OSType f) {
    switch (f) {
        case kCVPixelFormatType_420YpCbCr8Planar:
            return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
        case kCVPixelFormatType_420YpCbCr8PlanarFullRange:
            return kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
        case kSPPixelFormat420Planar16VideoRange:
            return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
        case kSPPixelFormat420Planar16FullRange:
            return kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
        default:
            return f;
    }
}

static inline OSType spPlanarPixelFormat(bool tenBit, bool fullRange) {
    if (tenBit) {
        return fullRange ? kSPPixelFormat420Planar16FullRange
                         : kSPPixelFormat420Planar16VideoRange;
    }
    return fullRange ? kCVPixelFormatType_420YpCbCr8PlanarFullRange
                     : kCVPixelFormatType_420YpCbCr8Planar;
}

CVPixelBufferRef _Nullable spCreateBiPlanarCopy(CVPixelBufferRef _Nonnull planar);

#ifdef __cplusplus
}
#endif
