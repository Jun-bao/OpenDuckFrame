#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import "SPFRCEngine.h"

NS_ASSUME_NONNULL_BEGIN

/// Experimental component only. The caller keeps its own bounded scheduling,
/// applies generation/config checks and does not use this as a synchronous scaler.
@interface SPAppleLowLatencySR : NSObject
+ (NSArray<NSNumber *> *)supportedFactorsForWidth:(int)width height:(int)height;
/// Called off the UI and live scheduling queues. A failed prepare leaves no session.
- (BOOL)prepareWidth:(int)width height:(int)height scale:(float)scale error:(NSError *_Nullable *_Nullable)error;
/// At most one job is in flight. The source is retained until the callback and
/// successful output transfers one owned reference to completion.
- (BOOL)submitSource:(CVPixelBufferRef)source pts:(CMTime)pts token:(uint64_t)token completion:(SPFRCEngineCompletion)completion;
/// Results arriving after invalidation are released and reported as stale.
- (void)invalidate;
@end

NS_ASSUME_NONNULL_END
