#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import "SPFRCEngine.h"
NS_ASSUME_NONNULL_BEGIN
/// Official Anime4K v4.0.1 Upscale CNN x2 S, optional runtime loaded lazily.
/// At most one frame runs; output transfers a +1 reference to completion.
@interface SPAnime4K : NSObject
+ (BOOL)isPackagedForThisSystem;
/// Defaults to the application bundle; alternate bundle enables isolated component tests.
- (instancetype)initWithResourceBundle:(NSBundle *)bundle;
- (BOOL)prepareWidth:(int)width height:(int)height error:(NSError *_Nullable *_Nullable)error;
- (BOOL)submitSource:(CVPixelBufferRef)source pts:(CMTime)pts token:(uint64_t)token completion:(SPFRCEngineCompletion)completion;
- (void)invalidate;
@end
NS_ASSUME_NONNULL_END
