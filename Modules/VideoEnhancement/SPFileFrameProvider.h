#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import "SPFRCEngine.h"

NS_ASSUME_NONNULL_BEGIN
/// A preflighted, single-in-flight provider. Frames are original file sources;
/// generated outputs must be owned NV12 and phases refer to the original pair.
@protocol SPFileFrameProvider <NSObject>
- (void)prepareWithSample:(CVPixelBufferRef)sample completion:(void (^)(BOOL ready, NSString *message))completion;
- (BOOL)submitPrevious:(CVPixelBufferRef)previous current:(CVPixelBufferRef)current
        previousPTSUs:(int64_t)previousPTSUs currentPTSUs:(int64_t)currentPTSUs
               phases:(NSArray<NSNumber *> *)phases token:(uint64_t)token completion:(SPFRCPhasesCompletion)completion;
- (void)invalidate;
@optional
/// A temporal model may require the genuine original immediately before A.
- (BOOL)requiresPrecedingSource;
- (BOOL)submitPreceding:(CVPixelBufferRef)preceding previous:(CVPixelBufferRef)previous current:(CVPixelBufferRef)current
       precedingPTSUs:(int64_t)precedingPTSUs previousPTSUs:(int64_t)previousPTSUs currentPTSUs:(int64_t)currentPTSUs
               phases:(NSArray<NSNumber *> *)phases token:(uint64_t)token completion:(SPFRCPhasesCompletion)completion;
@end
NS_ASSUME_NONNULL_END
