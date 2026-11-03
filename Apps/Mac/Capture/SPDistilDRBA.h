#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import "SPFRCEngine.h"
NS_ASSUME_NONNULL_BEGIN
/// Fixed 720p, X2 midpoint DistilDRBA model. Previous/current/next are three
/// original frames; the model runs asynchronously, with one job in flight.
@interface SPDistilDRBA : NSObject
+ (BOOL)isPackagedForThisSystem;
- (instancetype)initWithResourceBundle:(NSBundle *)bundle;
- (BOOL)prepareWidth:(int)width height:(int)height error:(NSError *_Nullable *_Nullable)error;
- (BOOL)submitPrevious:(CVPixelBufferRef)previous current:(CVPixelBufferRef)current next:(CVPixelBufferRef)next pts:(CMTime)pts token:(uint64_t)token completion:(SPFRCEngineCompletion)completion;
- (void)invalidate;
@end
NS_ASSUME_NONNULL_END
