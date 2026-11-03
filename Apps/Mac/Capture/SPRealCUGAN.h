#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import "SPFRCEngine.h"
NS_ASSUME_NONNULL_BEGIN
/// Real-CUGAN x2, resident ncnn/Vulkan adapter. One job in flight.
@interface SPRealCUGAN : NSObject
+ (BOOL)isPackagedForThisSystem;
/// Defaults to the application bundle; alternate bundle enables isolated component tests.
- (instancetype)initWithResourceBundle:(NSBundle *)bundle;
- (BOOL)prepareWidth:(int)width height:(int)height variant:(NSString *)variant error:(NSError *_Nullable *_Nullable)error;
- (BOOL)submitSource:(CVPixelBufferRef)source pts:(CMTime)pts token:(uint64_t)token completion:(SPFRCEngineCompletion)completion;
- (void)invalidate;
@end
NS_ASSUME_NONNULL_END
