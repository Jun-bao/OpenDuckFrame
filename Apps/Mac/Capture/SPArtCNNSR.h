#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import "SPFRCEngine.h"

NS_ASSUME_NONNULL_BEGIN
/// ArtCNN C4F16/C4F32: original MIT weights, SDR luma 2x; Lanczos chroma.
/// A single source frame may be in flight. Completion transfers a +1 NV12 frame.
@interface SPArtCNNSR : NSObject
+ (BOOL)isPackagedForThisSystem;
- (instancetype)initWithResourceBundle:(NSBundle *)bundle;
- (BOOL)prepareWidth:(int)width height:(int)height features:(int)features error:(NSError **)error;
- (BOOL)submitSource:(CVPixelBufferRef)source pts:(CMTime)pts token:(uint64_t)token completion:(SPFRCEngineCompletion)completion;
- (void)invalidate;
@end
NS_ASSUME_NONNULL_END
