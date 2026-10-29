#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import "SPFRCEngine.h"

NS_ASSUME_NONNULL_BEGIN
/// VideoToolbox temporal super-resolution. One frame in flight, presentation
/// order only. The caller supplies discontinuity on a dropped source frame,
/// seek, cut or source/plan boundary; generated interpolation frames must not
/// be fed into this temporal history.
@interface SPAppleVideoSR : NSObject
+ (BOOL)isReadyForWidth:(int)width height:(int)height scale:(int)scale;
+ (NSArray<NSNumber *> *)readyScalesForWidth:(int)width height:(int)height;
- (BOOL)prepareWidth:(int)width height:(int)height scale:(int)scale error:(NSError *_Nullable *_Nullable)error;
- (BOOL)submitSource:(CVPixelBufferRef)source pts:(CMTime)pts discontinuity:(BOOL)discontinuity token:(uint64_t)token completion:(SPFRCEngineCompletion)completion;
/// Explicit independent-frame mode: always submits Random and retains no history.
- (BOOL)submitRandomSource:(CVPixelBufferRef)source pts:(CMTime)pts token:(uint64_t)token completion:(SPFRCEngineCompletion)completion;
@property (nonatomic, readonly, copy) NSDictionary<NSString *, id> *submissionDiagnostics;
- (void)invalidate;
@end
NS_ASSUME_NONNULL_END
