#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import "SPFRCEngine.h"

NS_ASSUME_NONNULL_BEGIN

/// The caller owns bounded scheduling and generation/config checks.
@interface SPAppleLowLatencySR : NSObject
+ (BOOL)isSupported;
+ (NSArray<NSNumber *> *)supportedFactorsForWidth:(int)width height:(int)height;
/// An optional maximum input box, aligned for supported fractional factors.
+ (NSSize)inputSizeForWidth:(int)width height:(int)height preset:(int)preset;
/// Largest supported factor with an even output, or NSZeroSize when unavailable.
+ (NSSize)automaticOutputForWidth:(int)width height:(int)height;
/// File playback can reduce a decoded frame during the existing pixel transfer.
@property (nonatomic) BOOL allowsInputResize;
/// Called off the UI and live scheduling queues. A failed prepare leaves no session.
- (BOOL)prepareWidth:(int)width height:(int)height scale:(float)scale error:(NSError *_Nullable *_Nullable)error;
/// At most one job is in flight. The source is retained until the callback and
/// successful output transfers one owned reference to completion.
- (BOOL)submitSource:(CVPixelBufferRef)source pts:(CMTime)pts token:(uint64_t)token completion:(SPFRCEngineCompletion)completion;
/// Results arriving after invalidation are released and reported as stale.
- (void)invalidate;
@end

NS_ASSUME_NONNULL_END
