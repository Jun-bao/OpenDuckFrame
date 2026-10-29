#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import "SPFRCEngine.h"

NS_ASSUME_NONNULL_BEGIN

/// Temporal Apple low-latency interpolation. Spatial 2x stays on the existing scaler.
/// Supported phases are only the ones verified against the SDK: 1/2, and with two
/// interpolation slots also 1/4 and 3/4. Other fractions are rejected, not rounded.
@interface SPLowLatencyEngine : NSObject

@property (class, nonatomic, readonly, getter=isSupported) BOOL supported;
@property (nonatomic, readonly) NSInteger frames;
@property (nonatomic, readonly) int width;
@property (nonatomic, readonly) int height;
@property (nonatomic, readonly, copy) NSString *modelID;

+ (BOOL)supportsPhaseNumerator:(int64_t)numerator
                   denominator:(int64_t)denominator
                        frames:(NSInteger)frames
                      outFloat:(float *_Nullable)outFloat;

- (BOOL)prepareWidth:(int)width height:(int)height frames:(NSInteger)frames error:(NSError *_Nullable *_Nullable)error;

/// Previous frame is A and source frame is B. Outputs follow `phases` and each owns a +1 buffer.
/// The completion runs once. Source buffers must stay alive until then.
- (BOOL)submitPrevious:(CVPixelBufferRef)previous
               current:(CVPixelBufferRef)current
                phases:(NSArray<NSNumber *> *)phases
                 token:(uint64_t)token
            completion:(SPFRCPhasesCompletion)completion;

/// Actual media timestamps for both original frames. The output timestamp is
/// interpolated between them; callers must still schedule using their exact PTS.
- (BOOL)submitPrevious:(CVPixelBufferRef)previous
               current:(CVPixelBufferRef)current
           previousPTS:(CMTime)previousPTS
            currentPTS:(CMTime)currentPTS
                phases:(NSArray<NSNumber *> *)phases
                 token:(uint64_t)token
            completion:(SPFRCPhasesCompletion)completion;

- (void)invalidate;

/// Real session plus a white-bar center check. Does not change the supported-phase set.
+ (NSDictionary<NSString *, id> *)probePhases;

@end

NS_ASSUME_NONNULL_END
