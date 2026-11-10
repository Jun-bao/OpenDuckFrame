#import <AppKit/AppKit.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <Metal/Metal.h>
#if ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC
#import "SPAirFusedPreprocessor.h"
#endif

NS_ASSUME_NONNULL_BEGIN

@class SPPresentedVideoRecorder;
@class SPAirRetainedPayloadBudget;

typedef NS_ENUM(NSInteger, SPLiveRateKind) {
    SPLiveRateFixedFPS = 1,
    SPLiveRateMultiplier = 2,
};

typedef NS_ENUM(NSInteger, SPLiveCaptureSourceKind) {
    SPLiveCaptureSourceKindUnknown = 0,
    SPLiveCaptureSourceKindWindow = 1,
    SPLiveCaptureSourceKindDisplay = 2,
    SPLiveCaptureSourceKindFile = 3,
};

typedef NS_ENUM(NSInteger, SPLiveScaleEngine) {
    SPLiveScaleLanczos = 1,
    SPLiveScaleMetalFX = 2,
    SPLiveScaleAppleLowLatencySR = 3,
    SPLiveScaleAppleVideoSR = 4,
    SPLiveScaleAnime4K = 5,
    SPLiveScaleRealCUGAN = 6,
};

typedef NS_ENUM(NSInteger, SPLiveViewMode) {
    SPLiveViewEnhanced = 0,
    SPLiveViewOriginal = 1,
    SPLiveViewCompare = 2,
};

/// Maximum-box preset: 0 keeps capture size, otherwise 480, 720 or 1080.
FOUNDATION_EXPORT NSSize SPLiveSRInputSize(int width, int height, int preset);
FOUNDATION_EXPORT BOOL SPLiveCanPrepareMetalFX(int width, int height);
/// Private beta gates and shared sizing bridge. Ordinary builds return disabled.
FOUNDATION_EXPORT BOOL SPAirBetaEnabled(void);
FOUNDATION_EXPORT NSSize SPAirBetaProcessingSize(int captureWidth, int captureHeight);
FOUNDATION_EXPORT NSString *_Nullable SPAirBetaSizingReason(int captureWidth, int captureHeight);

/// Synchronous spatial scaler. Callers serialize access on their own worker queue.
@interface SPSpatialScaler : NSObject
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                inputW:(int)inputW
                                inputH:(int)inputH
                               outputW:(int)outputW
                               outputH:(int)outputH
                                engine:(SPLiveScaleEngine)engine
                                 error:(NSError **)error;
- (nullable CVPixelBufferRef)scaleBuffer:(CVPixelBufferRef)source error:(NSError **)error CF_RETURNS_RETAINED;
@property (nonatomic, readonly) SPLiveScaleEngine engine;
@end

@interface SPLivePlanRequest : NSObject <NSCopying>
@property (nonatomic) uint64_t requestID;
@property (nonatomic) SPLiveCaptureSourceKind captureSourceKind;
@property (nonatomic) BOOL interpolationEnabled;
@property (nonatomic) NSInteger quality;
@property (nonatomic) SPLiveRateKind rateKind;
@property (nonatomic) int64_t fpsNumerator;
@property (nonatomic) int64_t fpsDenominator;
@property (nonatomic) NSInteger multiplier;
@property (nonatomic) BOOL scaleEnabled;
@property (nonatomic) SPLiveScaleEngine scaleEngine;
@property (nonatomic, copy) NSString *scaleQualityID;
@property (nonatomic) int srInputPreset;
/// Exact live-window source guard; all zero for ordinary capture.
@property (nonatomic) int requiredSourceWidth;
@property (nonatomic) int requiredSourceHeight;
@property (nonatomic) uint32_t requiredSourceWindowID;
@property (nonatomic) int32_t requiredSourcePID;
@property (nonatomic) uint64_t requiredSourceAfterHost;
@property (nonatomic) int outputWidth;
@property (nonatomic) int outputHeight;
@property (nonatomic) SPLiveViewMode viewMode;
@property (nonatomic) double displayRefreshHz;
/// 0 means automatic. 30 or 60 is a capture ceiling, not the output frame rate.
@property (nonatomic) int captureCapFPS;
/// apple.frc, apple.lowlatency, or rife.metal. The processor does not rewrite this.
@property (nonatomic, copy) NSString *engineID;
/// vt.frc.normal, vt.frc.quality, vt.llfi.temporal.1, vt.llfi.temporal.2, rife-v4.25, or rife-v4.26.
@property (nonatomic, copy) NSString *modelID;
/// normal, quality, fast, balanced, or hq. The value belongs to the selected engine.
@property (nonatomic, copy) NSString *qualityID;
/// Opt-in RIFE live stream cache. Other engines and file playback are unaffected.
@property (nonatomic) BOOL rifeStreamEnabled;
@end

@interface SPLiveResolvedPlan : NSObject
@property (nonatomic) BOOL committed;
@property (nonatomic) BOOL interpolationActive;
@property (nonatomic) BOOL scaleActive;
@property (nonatomic, copy) NSString *engineID;
@property (nonatomic, copy) NSString *modelID;
@property (nonatomic, copy) NSString *scaleEngineID;
@property (nonatomic, copy) NSString *scaleQualityID;
@property (nonatomic, copy) NSString *unavailableReason;
@property (nonatomic, copy) NSString *requestedSummary;
@property (nonatomic, copy) NSString *activeSummary;
@property (nonatomic) int64_t targetNumerator;
@property (nonatomic) int64_t targetDenominator;
@property (nonatomic) int outputWidth;
@property (nonatomic) int outputHeight;
@property (nonatomic, copy) NSString *colorPath;
@property (nonatomic) uint64_t configVersion;
@property (nonatomic) BOOL presentationLimited;
@end

@interface SPLivePreviewView : NSView
/// Returns NO on synchronous rejection and reports its reason. The presented dictionary is
/// filled only from the drawable presented handler.
- (BOOL)presentEnhanced:(nullable CVPixelBufferRef)enhanced
               original:(nullable CVPixelBufferRef)original
                   mode:(SPLiveViewMode)mode
            captureHost:(int64_t)captureHost
             generation:(uint64_t)generation
                 ptsNum:(int64_t)ptsNum
                 ptsDen:(int64_t)ptsDen
              synthetic:(BOOL)synthetic
                frameID:(uint64_t)frameID
                 counts:(BOOL)counts
         captureGeometry:(nullable NSDictionary<NSString *, id> *)captureGeometry
                 reason:(NSString * _Nullable * _Nullable)reason;
@property (nonatomic, copy, nullable) void (^presented)(NSDictionary<NSString *, id> *info);
/// Asynchronous post-admission failures, tagged with submission identity.
@property (nonatomic, copy, nullable) void (^presentationFailure)(NSDictionary<NSString *, id> *info);
/// Successful GPU completion for a drawable submission; does not imply physical presentation.
@property (nonatomic, copy, nullable) void (^surfaceReady)(NSDictionary<NSString *, id> *info);
- (void)setGeneration:(uint64_t)generation;
- (void)setDiagnosticsConfig:(uint64_t)config epoch:(uint64_t)epoch;
- (void)setSurfaceToken:(uint64_t)token;
/// Fill the selected target content rectangle for same-geometry window output.
- (void)setFollowTargetContent:(BOOL)follow;
/// Per-instance window recipe. A false return leaves this view on its ordinary path.
- (BOOL)setAirPerformanceEnabled:(BOOL)enabled captureWidth:(int)width captureHeight:(int)height;
- (BOOL)airPerformanceEnabled;
- (int64_t)selectionGuardNs;
/// Refreshes the atomically read visibility snapshot on the AppKit main thread.
- (void)refreshVisibilitySnapshot;
/// Geometry is valid only for a verified target and a matching, visible
/// presented drawable. This bridge does not intercept or forward input.
- (void)observeVerifiedWindowGeometry:(nullable NSDictionary<NSString *, id> *)geometry;
- (void)invalidateSharedGeometry;
- (NSDictionary<NSString *, id> *)sharedGeometrySnapshot;
- (nullable NSDictionary<NSString *, NSNumber *> *)mapOutputPixel:(NSPoint)point geometryVersion:(uint64_t)version;
- (nullable NSDictionary<NSString *, NSNumber *> *)mapQuartzOutputPoint:(CGPoint)point geometryVersion:(uint64_t)version clamp:(BOOL)clamp;
@property (nonatomic, readonly) BOOL windowVisibleSnapshot;
@property (nonatomic, readonly) BOOL drawableVisibleSnapshot;
@property (nonatomic, readonly) BOOL exposedSnapshot;
/// CPU-only bridge/state contract; no window or drawable is presented.
+ (NSDictionary<NSString *, id> *)runSharedGeometryBridgeContract;
@end

@interface SPLiveProcessor : NSObject
@property (nonatomic, weak) SPLivePreviewView *preview;
@property (nonatomic, weak) SPLivePreviewView *outputPreview;
@property (nonatomic, copy, nullable) void (^statsHandler)(NSDictionary<NSString *, id> *stats);
@property (nonatomic, copy, nullable) void (^statusHandler)(NSString *status, BOOL failed, uint64_t requestID);
/// 0 keeps the previous plan, 1 is still preparing, 2 is the plan now in effect.
@property (nonatomic, copy, nullable) void (^planHandler)(NSInteger state, NSString *engineID, NSString *modelID, NSString *reason, uint64_t requestID);
/// One-shot notification when a current-plan output drawable has completed
/// GPU rendering. This is a warmup signal, not evidence of physical display.
@property (nonatomic, copy, nullable) void (^outputSurfaceHandler)(uint64_t generation, uint64_t configVersion, uint64_t token);
@property (nonatomic, readonly) SPLiveResolvedPlan *resolvedPlan;
@property (nonatomic, readonly) NSDictionary<NSString *, id> *stats;
/// Diagnostic consumer. Samples asynchronously on the processor queue, then
/// delivers the immutable result asynchronously on replyQueue.
- (void)requestStatsSnapshotOnQueue:(dispatch_queue_t)replyQueue completion:(void (^)(NSDictionary<NSString *, id> *stats))completion;
/// Reads only the existing immutable cache under its short mutex. No queue wait.
- (NSDictionary<NSString *, id> *)cachedStatsSnapshot;
/// Diagnostic boundary scalars from actual atomics. No stats computation,
/// queue wait, AppKit query, or history copy.
- (NSDictionary<NSString *, id> *)statsBoundaryCountersSnapshot;
/// Session-only observation. Resets diagnostic storage and leaves all
/// processing, scheduling, geometry and lifetime counters intact.
- (void)beginAirTraceRecordingSession:(NSString *)sessionID
    keeperJournal:(nullable NSObject *)keeperJournal
    payloadBudget:(SPAirRetainedPayloadBudget *)payloadBudget
    retiredServiceHandler:(nullable void (^)(NSObject *snapshot, NSDictionary<NSString *, id> *context))retiredServiceHandler
    replyQueue:(dispatch_queue_t)replyQueue completion:(void (^)(NSDictionary<NSString *, id> *receipt))completion
    NS_SWIFT_NAME(beginAirTraceRecordingSession(_:keeperJournal:payloadBudget:retiredServiceHandler:replyQueue:completion:));
/// Main-owned callback POD is frozen at the request. Other collectors are
/// sampled asynchronously with the real cutoff and exclusion witnesses.
- (void)captureAirTraceCheckpointAtCutoffHostTicks:(uint64_t)cutoff
    replyQueue:(dispatch_queue_t)replyQueue completion:(void (^)(NSDictionary<NSString *, id> *receipt))completion
    NS_SWIFT_NAME(captureAirTraceCheckpoint(cutoffHostTicks:replyQueue:completion:));
/// Seals recording only, including the ordinary720s observation limit.
- (void)sealAirTraceRecordingForReason:(NSString *)reason replyQueue:(dispatch_queue_t)replyQueue
    completion:(void (^)(NSDictionary<NSString *, id> *receipt))completion
    NS_SWIFT_NAME(sealAirTraceRecording(reason:replyQueue:completion:));
/// Produces an immutable CPU snapshot for the utility writer after sealing.
- (void)captureSealedAirTraceSnapshotOnQueue:(dispatch_queue_t)replyQueue
    completion:(void (^)(NSDictionary<NSString *, id> *receipt))completion
    NS_SWIFT_NAME(captureSealedAirTraceSnapshot(replyQueue:completion:));
/// Applies the existing stop and observes real pending jobs, rendering and
/// service exec-tail handoff. Keeper readiness is observed separately by the
/// session journal. Completion never waits on the calling thread.
- (void)stopAirTraceSessionWithDeadlineHostTicks:(uint64_t)deadline replyQueue:(dispatch_queue_t)replyQueue
    completion:(void (^)(NSDictionary<NSString *, id> *receipt))completion
    NS_SWIFT_NAME(stopAirTraceSession(deadlineHostTicks:replyQueue:completion:));
/// Utility-only session service export. Each actual producer store keeps its
/// original sequence and frozen formal/final versions.
- (nullable NSDictionary *)writeRetiredAirServiceTraces:(NSArray<NSDictionary *> *)entries formal:(nullable id)formal association:(nullable id)association
    toDirectory:(NSString *)directory progressPath:(NSString *)progressPath error:(NSError *_Nullable *_Nullable)error;
/// Explicit bounded diagnostic export; events remain in callback arrival order.
- (NSDictionary<NSString *, id> *)presentationOrderDiagnostics;
/// Install once after assigning both views, on the main thread.
- (void)installPresentationHooks;
/// Private quality-only recording attachment. Ordinary builds ignore it.
- (void)setPresentedVideoRecorder:(nullable SPPresentedVideoRecorder *)recorder;
/// Quality-only preparation. Enable after formal measurement and before attachment.
- (void)setPresentedVideoReadbackEnabled:(BOOL)enabled;
- (void)awaitOutputSurfaceWithToken:(uint64_t)token;
/// Require the revealed output to originate at or after this mach host time.
- (void)awaitOutputSurfaceWithToken:(uint64_t)token minimumCaptureHost:(int64_t)captureHost;
/// Opt-in isolated-test sampling; records fingerprints, never image files.
- (void)enablePixelDiagnostics;
/// Isolated keeper probe controls. No GPU waits; normal builds report disabled.
- (void)markResidentKeepAlivePhase:(NSString *)phase;
- (void)requestStopResidentKeepAliveForDiagnostics:(NSString *)reason;
/// Full records are for post-capture background export only.
- (NSDictionary<NSString *, id> *)residentKeepAliveSnapshotAtCutoffHostTicks:(uint64_t)cutoff
                                                           includeRecords:(BOOL)includeRecords;

- (void)updateRequest:(SPLivePlanRequest *)request;
- (void)setViewMode:(SPLiveViewMode)mode;
/// Clear FPS samples when the visible endpoint or pause state changes.
- (void)resetFPSObservations;
- (void)adoptSourceGeneration:(uint64_t)generation;
- (uint64_t)resumeSource;
- (void)stop;
- (void)noteCaptureStatus:(NSInteger)statusCode;
/// Capture-queue metadata update; nil invalidates the matching source epoch.
- (void)observeCaptureGeometry:(nullable NSDictionary<NSString *, id> *)geometry generation:(uint64_t)generation;
/// Thread-safe read-only geometry access for the bounded input router.
- (NSDictionary<NSString *, id> *)inputGeometrySnapshot;
- (nullable NSDictionary<NSString *, NSNumber *> *)mapQuartzOutputPoint:(CGPoint)point geometryVersion:(uint64_t)version clamp:(BOOL)clamp;
/// Release only idle capture-owned history in response to actual pool pressure.
- (void)noteCapturePoolPressureForGeneration:(uint64_t)generation;
/// Update the physical capture/display context independently of model state.
- (void)setRawCadenceRefreshHz:(double)refreshHz captureLimit:(int)captureLimit displayID:(uint64_t)displayID
    NS_SWIFT_NAME(setRawCadence(refreshHz:captureLimit:displayID:));
/// The active output display changed physical refresh rate.
- (void)updateDisplayRefreshHz:(double)refreshHz;
- (void)updateCaptureLimitFPS:(int)captureLimit;
/// Complete capture callback metadata, before the borrowed surface is copied.
- (void)noteRawCapturePTSNum:(int64_t)ptsNum ptsDen:(int64_t)ptsDen host:(int64_t)host
                       width:(int)width height:(int)height generation:(uint64_t)generation
    NS_SWIFT_NAME(noteRawCapture(ptsNum:ptsDen:host:width:height:generation:));
- (void)pushPixelBuffer:(CVPixelBufferRef)buffer
                 ptsNum:(int64_t)ptsNum
                 ptsDen:(int64_t)ptsDen
                   host:(int64_t)host
             generation:(uint64_t)generation;
/// host is the capture-callback entry. readyHost is after the owned-buffer copy.
- (void)pushPixelBuffer:(CVPixelBufferRef)buffer
                 ptsNum:(int64_t)ptsNum
                 ptsDen:(int64_t)ptsDen
                   host:(int64_t)host
              readyHost:(int64_t)readyHost
             generation:(uint64_t)generation;
/// Headless contract hooks. Call only from the isolated capture contract.
- (NSDictionary<NSString *, id> *)ownedContractFence;
- (void)ownedContractAsyncFence:(void (^)(NSDictionary<NSString *, id> *))completion;
- (void)ownedContractConfigureNativeWidth:(int)width height:(int)height
    NS_SWIFT_NAME(ownedContractConfigureNative(width:height:));
- (uint64_t)ownedContractPinOldest;
- (int)ownedContractByteForIdentity:(uint64_t)identity;
- (BOOL)ownedContractInstallRedrawForIdentity:(uint64_t)identity;
- (void)ownedContractInstallRedrawBuffer:(CVPixelBufferRef)buffer;
- (void)ownedContractStabilizePlayout;
- (uint64_t)ownedContractRedrawIdentity;
- (void)ownedContractCompleteIdentity:(uint64_t)identity stale:(BOOL)stale;
- (void)ownedContractQueueCurrentThenStalePressure;
/// Deterministic probe completion/cancellation with synthetic source leases; no model is run.
- (NSDictionary<NSString *, id> *)ownedContractRateBudgetProbeCancellation:(NSString *)scenario;
/// Blocks until queued GPU work for this probe finishes. Not for the main thread of a live session.
+ (NSDictionary<NSString *, id> *)runProbe;
/// Generation ownership and absolute-PTS scheduling. Does not start a capture stream.
+ (NSDictionary<NSString *, id> *)runSessionContract;
+ (NSDictionary<NSString *, id> *)runSRPipelineContract;
+ (NSDictionary<NSString *, id> *)runVideoSRPipelineContract;
+ (NSDictionary<NSString *, id> *)runSRInputPipelineContract;
+ (NSDictionary<NSString *, id> *)runAnime4KPipelineContract;
+ (NSDictionary<NSString *, id> *)runRealCUGANPipelineContract;
/// One real low-latency session and one real RIFE session. Not part of the short contract.
+ (NSDictionary<NSString *, id> *)runEngineProbe;
/// Headless production scheduling and warmup callback contract; no drawable/window.
+ (NSDictionary<NSString *, id> *)runOutputRepairContractWithBundle:(NSBundle *)bundle;
/// Controlled 60 fps input against the real low-latency engine; no window.
+ (NSDictionary<NSString *, id> *)runLowLatency120Smoke;
+ (NSDictionary<NSString *, id> *)runLowLatencyPrescaleSmoke;
+ (NSDictionary<NSString *, id> *)runLiveSwitchContract;
+ (NSDictionary<NSString *, id> *)runLiveQualityProbe;
/// Explicit synthetic, headless comparison through the application bridges.
+ (NSDictionary<NSString *, id> *)runNativeBridgeQualityProbeWithBundle:(NSBundle *)bundle;
+ (NSDictionary<NSString *, id> *)runStaticHoldContract;
/// Real FRC setup and synthetic buffer dimension lifecycle; no window.
+ (NSDictionary<NSString *, id> *)runSourceSizeLifecycleContract;
/// Deterministic source clock, phase deadlines and stale-work contract.
+ (NSDictionary<NSString *, id> *)runSourceClockSchedulingContract;
+ (NSDictionary<NSString *, id> *)runFixedRateContract;
+ (NSDictionary<NSString *, id> *)runFixedRateModelProbeWithBundle:(NSBundle *)bundle;
+ (NSDictionary<NSString *, id> *)runPendingReplacementContract;
+ (NSDictionary<NSString *, id> *)runRejectedPTSContract;
+ (NSDictionary<NSString *, id> *)runPresentationBudgetContract;
/// CPU-only production-queue budget, recovery and stale callback contract.
+ (NSDictionary<NSString *, id> *)runR9FRCBudgetContract;
@end

@interface SPLiveProcessor (SPAirCapacityExport)
- (id)captureAirTraceSnapshotAtCutoffHostTicks:(uint64_t)cutoff;
- (id)captureAndSealAirTraceSnapshotAtCutoffHostTicks:(uint64_t)cutoff;
- (NSDictionary *)airTraceSnapshotMetadata:(id)snapshot;
@end
@interface SPLiveProcessor (SPAirCapacityWriteExport)
- (nullable NSDictionary *)writeAirTraceSnapshotsToDirectory:(NSString *)directory
    formal:(id)formal association:(id)association final:(id)final
    progressPath:(NSString *)progressPath error:(NSError * _Nullable * _Nullable)error;
@end

@interface SPAirDiagnosticWriteBudget : NSObject
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithDeadlineHostTicks:(uint64_t)deadline NS_SWIFT_NAME(init(deadlineHostTicks:));
- (void)cancel;
- (BOOL)isCancelled NS_SWIFT_NAME(isCancelled());
- (BOOL)isExpired NS_SWIFT_NAME(isExpired());
@end

/// Implemented by the shared session export bridge. All serialization and IO
/// run on utility. The returned budget is a nonblocking cancellation handle.
@interface SPAirBetaSessionExportBridge : NSObject
+ (SPAirDiagnosticWriteBudget *)writeDocumentWithOptions:(NSDictionary<NSString *, id> *)options
    completion:(void (^)(NSDictionary<NSString *, id> *receipt))completion
    NS_SWIFT_NAME(write(options:completion:));
@end

#ifdef __cplusplus
namespace spAirDiagnostic { struct WriteBudget; }
@interface SPAirDiagnosticWriteBudget (SPAirNativeBudget)
- (spAirDiagnostic::WriteBudget *)nativeWriteBudget;
@end
#endif

NS_ASSUME_NONNULL_END
