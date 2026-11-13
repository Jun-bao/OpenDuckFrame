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
+ (BOOL)isSupported;
+ (NSSize)automaticInputForWidth:(int)width height:(int)height NS_SWIFT_NAME(automaticInput(width:height:));
+ (NSSize)automaticOutputForWidth:(int)width height:(int)height NS_SWIFT_NAME(automaticOutput(width:height:));
+ (void)ensureModelForWidth:(int)width height:(int)height scale:(int)scale completion:(void (^)(NSError *_Nullable))completion NS_SWIFT_NAME(ensureModel(width:height:scale:completion:));
+ (BOOL)isReadyForWidth:(int)width height:(int)height scale:(int)scale;
+ (NSArray<NSNumber *> *)readyScalesForWidth:(int)width height:(int)height;
@property (nonatomic) BOOL allowsInputResize;
- (BOOL)prepareWidth:(int)width height:(int)height scale:(int)scale error:(NSError *_Nullable *_Nullable)error;
- (BOOL)submitSource:(CVPixelBufferRef)source pts:(CMTime)pts discontinuity:(BOOL)discontinuity token:(uint64_t)token completion:(SPFRCEngineCompletion)completion;
/// Explicit independent-frame mode: always submits Random and retains no history.
- (BOOL)submitRandomSource:(CVPixelBufferRef)source pts:(CMTime)pts token:(uint64_t)token completion:(SPFRCEngineCompletion)completion;
@property (nonatomic, readonly, copy) NSDictionary<NSString *, id> *submissionDiagnostics;
- (void)invalidate;
@end
NS_ASSUME_NONNULL_END
