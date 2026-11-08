#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import "SPFRCEngine.h"

NS_ASSUME_NONNULL_BEGIN

/// Transient backpressure: output buffers are still held by consumers.
static const NSInteger SPRifeBridgeErrorOutputPoolExhausted = 10;

/// ObjC face of the RIFE Metal adapter. The Swift class owns the interpolator.
/// Calls return immediately; inference runs on the adapter queue, not the live queue.
@interface SPRifeBridge : NSObject
- (instancetype)initWithResourceBundle:(NSBundle *)bundle;
@property (nonatomic) BOOL liveStreamEnabled;
/// Trace-only process gate; false in normal builds. No trace arrays in streamDiagnostics.
@property (nonatomic, readonly) BOOL serviceTraceEnabled;
- (void)setServiceTraceToken:(uint64_t)token configVersion:(uint64_t)configVersion
           measurementEpoch:(uint64_t)measurementEpoch probe:(BOOL)probe
                 probeIndex:(NSInteger)probeIndex probeRound:(uint64_t)probeRound;
/// Controlled post-capture export; copies bounded scalar records without waiting for exec/GPU.
- (NSDictionary<NSString *, id> *)serviceTraceSnapshotAtCutoffHostTicks:(uint64_t)cutoffHostTicks;

- (BOOL)prepareModelID:(NSString *)modelID
               quality:(NSString *)quality
                 width:(int)width
                height:(int)height
                 error:(NSError *_Nullable *_Nullable)error;
- (BOOL)submitPrevious:(CVPixelBufferRef)previous
               current:(CVPixelBufferRef)current
             timesteps:(NSArray<NSNumber *> *)timesteps
                 token:(uint64_t)token
            completion:(SPFRCPhasesCompletion)completion;
/// Streaming opt-in path. Identities and epochs identify immutable source frames.
- (BOOL)submitLivePrevious:(CVPixelBufferRef)previous current:(CVPixelBufferRef)current
               previousID:(uint64_t)previousID currentID:(uint64_t)currentID
              previousPTS:(CMTime)previousPTS currentPTS:(CMTime)currentPTS
               generation:(uint64_t)generation clockEpoch:(uint64_t)clockEpoch
                timesteps:(NSArray<NSNumber *> *)timesteps token:(uint64_t)token
               completion:(SPFRCPhasesCompletion)completion;
- (NSDictionary<NSString *, id> *)streamDiagnostics;
/// Controlled failure injection for the headless bridge contract only.
- (void)injectStreamFailureForContract;
/// Asynchronously discard the cached input after all earlier GPU work.
- (void)relieveCapturePressure;
- (void)invalidate;
+ (NSDictionary<NSString *, id> *)probe;

@end

NS_ASSUME_NONNULL_END
