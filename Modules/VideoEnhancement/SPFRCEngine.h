// Apple frame-rate conversion session pool. Slots own a processor and reusable
// RGBA16F buffers. Metal converts input/output formats. In-flight requests
// finish after invalidation but discard their results. The planner uses
// measured end-to-end latency to check presentation deadlines.
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import "SPFrameBudgetMetal.h"

NS_ASSUME_NONNULL_BEGIN

/// Success transfers a +1 midpoint reference to the caller. Failure returns
/// NULL with an error. The callback may run on any thread; do not block.
typedef void (^SPFRCEngineCompletion)(uint64_t token, CVPixelBufferRef _Nullable midpoint,
                                      double latencySec, NSError *_Nullable error);

/// Matches the VideoToolbox quality values without exposing that header here.
typedef NS_ENUM(NSInteger, SPFRCQuality) {
    SPFRCQualityNormal = 1,
    SPFRCQualityHigh = 2,
};

/// Owns one +1 CVPixelBuffer and releases it.
@interface SPOwnedPixelBuffer : NSObject
- (instancetype)initWithBufferNoCopy:(CVPixelBufferRef)buffer;
/// Retains `buffer`, then takes that extra retain. Safe for Swift ARC callers.
- (instancetype)initRetainingBuffer:(CVPixelBufferRef)buffer;
@property (nonatomic, readonly) CVPixelBufferRef buffer;
@end

/// `outputs` elements each own a +1 buffer. The callback may run on any thread.
typedef void (^SPFRCPhasesCompletion)(uint64_t token,
                                      NSArray<SPOwnedPixelBuffer *> *_Nullable outputs,
                                      double latencySec,
                                      NSError *_Nullable error);

@interface SPFRCEngine : NSObject

/// Requires macOS 15.4 or later and local frame-rate conversion support.
@property (class, nonatomic, readonly, getter=isAvailable) BOOL available;
/// Returns 0/1 if resolved, or -1 without resolving or blocking.
+ (int)availabilityIfResolved;
/// Resolves capability on a utility queue; no work if already resolved.
+ (void)resolveAvailabilityAsync;

/// sessions is in [1,8]. Exceeding outputCapacity fails that pair.
/// The quality initializer is designated. The original initializer uses Normal.
- (nullable instancetype)initWithMetal:(SPFrameBudgetMetal *)metal
                              sessions:(unsigned)sessions
                        outputCapacity:(NSUInteger)outputCapacity
                               quality:(SPFRCQuality)quality
                                 error:(NSError **)error NS_DESIGNATED_INITIALIZER;
- (nullable instancetype)initWithMetal:(SPFrameBudgetMetal *)metal
                              sessions:(unsigned)sessions
                        outputCapacity:(NSUInteger)outputCapacity
                                 error:(NSError **)error;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) SPFrameBudgetMetal *metal;
@property (nonatomic, readonly) unsigned sessionCount;
/// Opt-in per-live-task diagnostics; callback is observational and may be on any thread.
@property (atomic, copy, nullable) void (^diagnosticHandler)(NSDictionary<NSString *, id> *event);
@property (nonatomic, readonly) unsigned busyCount;
/// End-to-end latency in seconds; initially an estimate.
@property (nonatomic, readonly) double latencyEstimateSec;
/// EWMA seconds in frame conversion and the three GPU format conversions.
@property (nonatomic, readonly) double frcCoreEstimateSec;
@property (nonatomic, readonly) double conversionGPUEstimateSec;
@property (nonatomic, readonly) uint64_t completedPairs;
@property (nonatomic, readonly) uint64_t failedPairs;
/// Throughput since resetThroughputWindow, used for session calibration.
- (void)resetThroughputWindow;
- (double)throughputWindowPairsPerSecond;
- (uint64_t)throughputWindowPairs;

/// Adds sessions immediately and retires excess sessions when idle.
/// Failure returns NO and preserves the previous count.
- (BOOL)setSessionCount:(unsigned)sessions error:(NSError **)error;
/// Thread-safe release of idle output buffers after memory pressure or ring shrink.
- (void)flushIdleOutputBuffers;

/// Keep A/B alive until completion. NO means no free slot or invalidation.
/// This path always requests the single 1/2 phase used by file playback.
- (BOOL)submitPairWithFrameA:(CVPixelBufferRef)frameA
                      frameB:(CVPixelBufferRef)frameB
                       token:(uint64_t)token
                  completion:(SPFRCEngineCompletion)completion;

- (BOOL)submitPairWithFrameA:(CVPixelBufferRef)frameA
                      frameB:(CVPixelBufferRef)frameB
                        ptsA:(CMTime)ptsA
                        ptsB:(CMTime)ptsB
                       token:(uint64_t)token
                  completion:(SPFRCEngineCompletion)completion;

/// One original pair, up to three phases, one destination each. Phases must be
/// in (0,1). Sequential is only valid when this pair continues the previous one.
- (BOOL)submitPhasesWithFrameA:(CVPixelBufferRef)frameA
                        frameB:(CVPixelBufferRef)frameB
                        phases:(NSArray<NSNumber *> *)phases
                    sequential:(BOOL)sequential
                         token:(uint64_t)token
                    completion:(SPFRCPhasesCompletion)completion;

/// Live-only continuity candidate; mode is derived inside the owning session.
- (BOOL)submitLivePhasesWithFrameA:(CVPixelBufferRef)frameA frameB:(CVPixelBufferRef)frameB
                              ptsA:(CMTime)ptsA ptsB:(CMTime)ptsB
                           frameIDA:(uint64_t)frameIDA frameIDB:(uint64_t)frameIDB
                         generation:(uint64_t)generation clockEpoch:(uint64_t)clockEpoch
                             phases:(NSArray<NSNumber *> *)phases token:(uint64_t)token
                         completion:(SPFRCPhasesCompletion)completion;
- (NSDictionary<NSString *, NSNumber *> *)continuityDiagnostics;

- (BOOL)submitPhasesWithFrameA:(CVPixelBufferRef)frameA
                        frameB:(CVPixelBufferRef)frameB
                          ptsA:(CMTime)ptsA
                          ptsB:(CMTime)ptsB
                        phases:(NSArray<NSNumber *> *)phases
                    sequential:(BOOL)sequential
                         token:(uint64_t)token
                    completion:(SPFRCPhasesCompletion)completion;

/// Remaining in-flight seconds per slot (idle is zero); count is at most 8.
- (void)copySlotBusyRemaining:(double *)out count:(unsigned)count;

/// Ends all sessions. In-flight requests complete with an error.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
