// Budgeted frame generation with a bounded lookahead ring and segment scheduling.
// Decode-thread entry points own submission, resets, and engine destruction.
// An emission worker returns originals and ready generated frames in order.
// A serial work queue handles analysis, planning, and session calibration.
// Original frames remain the fallback when generated frames miss deadlines.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import "SPFrameGeneration.h"
#import "SPFileFrameProvider.h"

NS_ASSUME_NONNULL_BEGIN

@interface SPFrameBudgetGenerator : NSObject

/// Cached system capability; initial resolution may load plugins and must
/// stay off the bootstrap and first-frame paths.
@property (class, nonatomic, readonly, getter=isAvailable) BOOL available;
/// Returns 0/1 if resolved, or -1 without resolving or blocking.
+ (int)availabilityIfResolved;
/// Resolves capability asynchronously and idempotently.
+ (void)resolveAvailabilityAsync;

#ifdef __cplusplus
- (instancetype)initWithDevice:(id<MTLDevice>)device
                          logId:(unsigned)logId
                      liveState:(const sp::SPFrameGeneratorLiveState &)liveState
                        enqueue:(SPFrameGeneratorEnqueue)enqueue
                         status:(SPFrameGeneratorStatus)status
                     queueDepth:(SPFrameGeneratorQueueDepth)queueDepth
    NS_DESIGNATED_INITIALIZER;

@property (nonatomic, readonly) sp::SPFrameGeneratorCounters *counters;
/// Starts a media session by resetting counters, static facts, and the ring.
- (void)resetForNewMediaWithInfo:(const sp::SPFrameGeneratorMediaInfo &)info;
/// Queue a file cadence for the next decode-thread mode reset. A failed request
/// leaves the pending cadence unchanged. mode=1 fixed FPS, 2/3/4 multiplier.
- (BOOL)configureFileCadenceMode:(NSInteger)mode numerator:(int64_t)numerator denominator:(int64_t)denominator;
/// Pending provider changes take effect only on the next mode reset. nil selects Apple FRC.
- (void)setPendingFileProvider:(nullable id<SPFileFrameProvider>)provider;
/// Decode thread: consumes the +1 source frame unless returning Interrupted,
/// which leaves ownership with the caller.
- (sp::PushResult)submitSourceBuffer:(CVPixelBufferRef)buffer
                         context:(const sp::SPFrameGeneratorSubmitContext &)context;
#endif
- (instancetype)init NS_UNAVAILABLE;

/// Decode thread: quiesces the ring, invalidates in-flight work, and returns
/// originals at seek/rate/display/mode boundaries. Off also destroys the engine.
- (void)applyModeReset:(SPFrameInterpolationMode)mode;
/// Decode thread: breaks pairing without destroying the engine. Buffered
/// originals still drain in order, including at end of input.
- (void)breakPairChain;
/// Returns unqueued originals after a route change, in order, transferring +1
/// ownership to the handler. Reinject these before routing new source frames.
- (void)drainReturnedFramesWithHandler:(void (^)(CVPixelBufferRef buffer, int64_t ptsUs, int64_t generation))handler;
- (BOOL)hasReturnedFrames;
/// Discards invalidated returned frames at session end.
- (void)discardReturnedFrames;
/// Destroys engine sessions on the decode thread, or after it has been joined.
- (void)destroyEngine;
/// Idempotent shutdown after stop, before core destruction. Ends the emission
/// worker, observers, and event sources; the worker otherwise retains the module.
- (void)shutdown;
/// Counts originals still in the ring, returned mailbox, or emission worker.
/// End-of-content detection must include them before reporting completion.
- (size_t)pendingSourceFrameCount;
/// Coverage in [0,1], consumed by the presentation indicator.
- (double)coverageRatio;

@end

NS_ASSUME_NONNULL_END
