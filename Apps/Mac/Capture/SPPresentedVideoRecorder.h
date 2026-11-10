#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

/// Owns a full rendered-frame copy across both asynchronous callbacks.
@interface SPPresentedRenderSnapshot : NSObject
/// Call for every drawable callback, including a zero presented time.
- (void)presentedAtTime:(CFTimeInterval)presentedTime;
/// Suppresses publication. GPU resources survive any subsequent cleanup commit.
- (void)cancelPublication;
@end

/// Single-use recorder for a separate, diagnostic quality window.
/// Preparation and encoding run on its worker queue. Completions run on main.
@interface SPPresentedVideoRecorder : NSObject
- (instancetype)initWithOutputURL:(NSURL *)outputURL width:(int)width height:(int)height;

/// Prepares the writer without accepting frames. Call after the formal test.
- (void)startWithCompletion:(void (^)(NSError *_Nullable error))completion;

/// Fused capture starts its fixed window at the first copied positive frame.
/// The one-shot start dictionary is delivered asynchronously on main. Its
/// windowStartMediaTime is actual presentation time, while anchorObservedHostTicks
/// records the later CPU callback observation. Arm before attaching the recorder.
- (BOOL)armRenderedWindowForDurationSeconds:(double)durationSeconds
                                  didStart:(void (^)(NSDictionary<NSString *, id> *start))didStart;

/// Call after preparation, immediately before attaching the presentation hook.
/// The Media-time window excludes late callbacks from the preceding test.
- (void)beginAtMediaTime:(CFTimeInterval)mediaTime
              hostTicks:(uint64_t)hostTicks
        durationSeconds:(double)durationSeconds;

/// Call only for counted, non-redraw positive-presented enhanced-view buffers.
/// This method retains the buffer and submits bounded work without GPU waits.
- (void)recordPresentedBuffer:(CVPixelBufferRef)buffer
                     frameID:(uint64_t)frameID
                         pts:(CMTime)pts
                   synthetic:(BOOL)synthetic
               presentedTime:(CFTimeInterval)presentedTime;

/// Fused diagnostic only, after the render encoder ends and before commit.
/// Requires a readable BGRA8 full-size texture and origin zero. Encodes a blit
/// into this command buffer and publishes only after GPU success plus positive
/// presentation. The ticket owns its private storage without retaining drawable.
/// Calls after the fixed Media window end are counted and suppressed before copy.
- (nullable SPPresentedRenderSnapshot *)encodeRenderCopyFromTexture:(id<MTLTexture>)texture
                                                      sourceOrigin:(MTLOrigin)sourceOrigin
                                                     commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                                                           frameID:(uint64_t)frameID
                                                               pts:(CMTime)pts
                                                         synthetic:(BOOL)synthetic
                                                             error:(NSError *_Nullable *_Nullable)error;

/// Detach the hook before calling. Finishes already accepted worker jobs,
/// writes a same-basename JSON sidecar, and returns the complete scalar ledger.
- (void)finishAtMediaTime:(CFTimeInterval)mediaTime
               hostTicks:(uint64_t)hostTicks
              completion:(void (^)(NSDictionary<NSString *, id> *report))completion;
@end

NS_ASSUME_NONNULL_END
