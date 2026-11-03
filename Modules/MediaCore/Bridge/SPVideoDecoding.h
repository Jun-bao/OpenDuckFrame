#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#include <stdbool.h>
#include <stdint.h>

struct AVCodecParameters;
struct AVPacket;

NS_ASSUME_NONNULL_BEGIN

// Decoder-neutral, per-output scan verdict.  Unknown is deliberately
// fail-closed for interpolation.  Progressive is usable only when
// scanCovered is also true; Interlaced is a negative session verdict and does
// not require progressive coverage.
typedef NS_ENUM(uint8_t, SPDecodedVideoScanVerdict) {
    SPDecodedVideoScanVerdictUnknown = 0,
    SPDecodedVideoScanVerdictProgressive = 1,
    SPDecodedVideoScanVerdictInterlaced = 2,
};

// Stable implementation capability used where Core genuinely needs to choose
// VT-session recovery behavior. This replaces concrete-class downcasts without
// conflating "VideoToolbox pipeline" with VT's best-effort hardware flag.
typedef NS_ENUM(uint8_t, SPVideoDecodingBackend) {
    SPVideoDecodingBackendFFmpegSoftware = 0,
    SPVideoDecodingBackendVideoToolbox = 1,
};

// Value returned for one concrete decoded output. pixelBuffer, ptsUs and scan
// metadata always travel together through decoder reorder/pending queues.
//
// Ownership: a non-null pixelBuffer is transferred to the caller at +1. The
// caller must eventually call CVPixelBufferRelease exactly once (or transfer
// that ownership onward). Empty/no-output results carry pixelBuffer == NULL.
// Passing/assigning the struct copies only the handle and metadata; it does not
// retain the buffer. Treat such copies as aliases of one transferred ownership
// and release the buffer exactly once across all copies.
typedef struct SPDecodedVideoOutput {
    CVPixelBufferRef _Nullable pixelBuffer;
    int64_t ptsUs;
    SPDecodedVideoScanVerdict scanVerdict;
    bool scanCovered;
} SPDecodedVideoOutput;

NS_INLINE SPDecodedVideoOutput SPDecodedVideoOutputMake(
    CVPixelBufferRef _Nullable pixelBuffer,
    int64_t ptsUs,
    SPDecodedVideoScanVerdict scanVerdict,
    bool scanCovered) {
    SPDecodedVideoOutput output = {
        .pixelBuffer = pixelBuffer,
        .ptsUs = ptsUs,
        .scanVerdict = scanVerdict,
        .scanCovered = scanCovered,
    };
    return output;
}

NS_INLINE SPDecodedVideoOutput SPDecodedVideoOutputEmpty(void) {
    return SPDecodedVideoOutputMake(NULL, INT64_MIN,
                                    SPDecodedVideoScanVerdictUnknown, NO);
}

@protocol SPVideoDecoding <NSObject>

- (int)setupWithCodecParameters:(const struct AVCodecParameters *)par
              timeBaseNumerator:(int64_t)tbNum
            timeBaseDenominator:(int64_t)tbDen;

- (SPDecodedVideoOutput)decodePacketOutput:
    (const struct AVPacket * _Nullable)pkt;
- (void)flush;
- (void)shutdown;

- (void)setCatchUpTargetUs:(int64_t)targetUs;

- (void)setInterpolationScanEnabled:(BOOL)enabled
                    codecParameters:
                        (const struct AVCodecParameters * _Nullable)par;
@property (nonatomic, readonly) BOOL isHardwareDecoding;
@property (nonatomic, readonly) SPVideoDecodingBackend decodingBackend;
@property (nonatomic, readonly, copy) NSString *decoderName;

@property (nonatomic, readonly) int lastError;

@property (nonatomic) unsigned spLogId;
@end

NS_ASSUME_NONNULL_END
