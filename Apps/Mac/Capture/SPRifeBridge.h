#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import "SPFRCEngine.h"

NS_ASSUME_NONNULL_BEGIN

/// Transient backpressure: output buffers are still held by consumers.
static const NSInteger SPRifeBridgeErrorOutputPoolExhausted = 10;

/// Shared session-only CPU payload accounting. Reservations precede copying
/// retained rows and are released with their actual opaque snapshot owners.
@interface SPAirRetainedPayloadBudget : NSObject
- (instancetype)initWithLimitBytes:(uint64_t)limitBytes;
- (BOOL)reserveBytes:(uint64_t)bytes;
- (void)releaseBytes:(uint64_t)bytes;
- (NSDictionary<NSString *, id> *)snapshot;
@end

/// ObjC face of the RIFE Metal adapter. The Swift class owns the interpolator.
/// Calls return immediately; inference runs on the adapter queue, not the live queue.
@interface SPRifeBridge : NSObject
- (instancetype)initWithResourceBundle:(NSBundle *)bundle;
@property (nonatomic) BOOL liveStreamEnabled;
/// Set before prepare for the supported automatic window configuration.
@property (nonatomic) BOOL airPerformanceEnabled;
+ (NSDictionary<NSString *, id> *)airPerformanceSelectionStatus;
+ (uint64_t)windowCaptureByteLimit;
+ (BOOL)windowOptimizationCapabilitiesSupported;
/// Prepares full-size first; only a measured budget miss or preparation failure
/// selects the bounded window fallback. File callers keep prepareModelID unchanged.
- (BOOL)prepareWindowModelID:(NSString *)modelID quality:(NSString *)quality
                      width:(int32_t)width height:(int32_t)height
                  refreshHz:(double)refreshHz error:(NSError **)error;
@property (nonatomic, readonly) NSDictionary<NSString *, id> *windowPreparationDiagnostics;
/// Trace-only process gate; false in normal builds. No trace arrays in streamDiagnostics.
@property (nonatomic, readonly) BOOL serviceTraceEnabled;
- (void)setServiceTraceToken:(uint64_t)token configVersion:(uint64_t)configVersion
           measurementEpoch:(uint64_t)measurementEpoch probe:(BOOL)probe
                 probeIndex:(NSInteger)probeIndex probeRound:(uint64_t)probeRound;
/// Controlled post-capture export; copies bounded scalar records without waiting for exec/GPU.
- (NSDictionary<NSString *, id> *)serviceTraceSnapshotAtCutoffHostTicks:(uint64_t)cutoffHostTicks;
/// Candidate04 scalar checkpoint and bounded post-formal row enumeration.
- (NSObject *)captureServiceTraceAtCutoffHostTicks:(uint64_t)cutoffHostTicks;
- (NSDictionary<NSString *, id> *)serviceTraceMetadataForSnapshot:(NSObject *)snapshot;
- (NSDictionary<NSString *, id> *)sealServiceTraceForDiagnostics;
- (BOOL)enumerateServiceGPUBodyForSnapshot:(NSObject *)snapshot
                              usingBlock:(BOOL (^)(uint64_t sequence, NSDictionary *row))block;

- (BOOL)enumerateServiceTraceSnapshot:(NSObject *)snapshot ring:(NSString *)ring
                         usingBlock:(BOOL (^)(uint64_t sequence, NSDictionary *row))block;
/// Session observers own CPU records only. Completion runs after the existing
/// exec queue tail and transfers the sealed producer to utility compaction.
- (void)finishServiceTraceForSessionWithCompletion:(void (^)(NSObject *_Nullable snapshot))completion;
- (NSObject *)captureServicePrefixForSessionAtCutoffHostTicks:(uint64_t)cutoff;
- (NSObject *)captureServicePrefixForSessionAtCutoffHostTicks:(uint64_t)cutoff budget:(SPAirRetainedPayloadBudget *)budget;
+ (NSDictionary<NSString *, id> *)compactDetachedServiceTraceSnapshot:(NSObject *)snapshot;
+ (NSDictionary<NSString *, id> *)compactDetachedServiceTraceSnapshot:(NSObject *)snapshot budget:(SPAirRetainedPayloadBudget *)budget;
+ (NSDictionary<NSString *, id> *)serviceTraceMetadataForDetachedSnapshot:(NSObject *)snapshot;
+ (BOOL)enumerateDetachedServiceTraceSnapshot:(NSObject *)snapshot ring:(NSString *)ring
    usingBlock:(BOOL (^)(uint64_t sequence, NSDictionary *row))block;
+ (BOOL)enumerateDetachedServiceGPUBodyForSnapshot:(NSObject *)snapshot
    usingBlock:(BOOL (^)(uint64_t sequence, NSDictionary *row))block;
- (void)setKeeperSessionJournal:(nullable NSObject *)journal;
- (void)recordKeeperRetirementForDiagnostics:(NSString *)reason;
/// Private diagnostic only. False when its compile gate or environment gate is off.
@property (nonatomic, readonly) BOOL residentKeepAliveEnabled;
/// Private full-capture RIFE prescale diagnostic; false in ordinary builds.
@property (nonatomic, readonly) BOOL rifePrescaleEnabled;
@property (nonatomic, readonly) BOOL fusedRifePresentEnabled;
@property (nonatomic, readonly) int processingWidth;
@property (nonatomic, readonly) int processingHeight;
/// Lightweight beta keeper/failure state, without per-command records.
- (NSDictionary<NSString *, id> *)airBetaRuntimeState;
/// Observe the actual original-frame enqueue buffer, never a requested size.
- (void)recordPrescaleOriginalWidth:(int)width height:(int)height;
/// Call once after a validated X2 RIFE plan is installed. Acceptance never waits for GPU/worker.
- (BOOL)startKeeperForPlanToken:(uint64_t)planToken generation:(uint64_t)generation
                 configVersion:(uint64_t)configVersion;
/// Token zero also retires an unbound prepared keeper. No caller-side GPU wait or join.
- (void)requestStopKeeperForPlanToken:(uint64_t)planToken reason:(NSString *)reason;
/// Controlled phase boundary only, without draining or pausing the keeper.
- (void)markKeeperPhase:(NSString *)phase forPlanToken:(uint64_t)planToken;
/// Full scalar records are exported only on a post-capture background caller.
- (NSDictionary<NSString *, id> *)snapshotKeeperAtCutoffHostTicks:(uint64_t)cutoffHostTicks
                                                 includeRecords:(BOOL)includeRecords;

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
