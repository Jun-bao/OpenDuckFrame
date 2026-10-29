#import <AppKit/AppKit.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPLiveRateKind) {
    SPLiveRateFixedFPS = 1,
    SPLiveRateMultiplier = 2,
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

@interface SPLivePlanRequest : NSObject <NSCopying>
@property (nonatomic) uint64_t requestID;
@property (nonatomic) BOOL interpolationEnabled;
@property (nonatomic) NSInteger quality;
@property (nonatomic) SPLiveRateKind rateKind;
@property (nonatomic) int64_t fpsNumerator;
@property (nonatomic) int64_t fpsDenominator;
@property (nonatomic) NSInteger multiplier;
@property (nonatomic) BOOL scaleEnabled;
@property (nonatomic) SPLiveScaleEngine scaleEngine;
@property (nonatomic, copy) NSString *scaleQualityID;
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
/// Returns NO when the draw queue is already full. The presented dictionary is
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
                 counts:(BOOL)counts;
@property (nonatomic, copy, nullable) void (^presented)(NSDictionary<NSString *, id> *info);
/// Successful GPU completion for a drawable submission; does not imply physical presentation.
@property (nonatomic, copy, nullable) void (^surfaceReady)(NSDictionary<NSString *, id> *info);
- (void)setGeneration:(uint64_t)generation;
- (void)setDiagnosticsConfig:(uint64_t)config epoch:(uint64_t)epoch;
- (void)setSurfaceToken:(uint64_t)token;
/// Fill the selected target content rectangle for same-geometry window output.
- (void)setFollowTargetContent:(BOOL)follow;
/// Refreshes the atomically read visibility snapshot on the AppKit main thread.
- (void)refreshVisibilitySnapshot;
@property (nonatomic, readonly) BOOL windowVisibleSnapshot;
@property (nonatomic, readonly) BOOL drawableVisibleSnapshot;
@property (nonatomic, readonly) BOOL exposedSnapshot;
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
/// Install once after assigning both views, on the main thread.
- (void)installPresentationHooks;
- (void)awaitOutputSurfaceWithToken:(uint64_t)token;

- (void)updateRequest:(SPLivePlanRequest *)request;
- (void)setViewMode:(SPLiveViewMode)mode;
/// Clear FPS samples when the visible endpoint or pause state changes.
- (void)resetFPSObservations;
- (void)adoptSourceGeneration:(uint64_t)generation;
- (uint64_t)resumeSource;
- (void)stop;
- (void)noteCaptureStatus:(NSInteger)statusCode;
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
/// Blocks until queued GPU work for this probe finishes. Not for the main thread of a live session.
+ (NSDictionary<NSString *, id> *)runProbe;
/// Generation ownership and absolute-PTS scheduling. Does not start a capture stream.
+ (NSDictionary<NSString *, id> *)runSessionContract;
+ (NSDictionary<NSString *, id> *)runSRPipelineContract;
+ (NSDictionary<NSString *, id> *)runVideoSRPipelineContract;
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
+ (NSDictionary<NSString *, id> *)runStaticHoldContract;
@end

NS_ASSUME_NONNULL_END
