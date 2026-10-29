#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import "SPFRCEngine.h"

NS_ASSUME_NONNULL_BEGIN

/// ObjC face of the RIFE Metal adapter. The Swift class owns the interpolator.
/// Calls return immediately; inference runs on the adapter queue, not the live queue.
@interface SPRifeBridge : NSObject
- (instancetype)initWithResourceBundle:(NSBundle *)bundle;

- (BOOL)prepareModelID:(NSString *)modelID
               quality:(NSString *)quality
                 width:(int)width
                height:(int)height
                 error:(NSError *_Nullable *_Nullable)error;
- (BOOL)submitPrevious:(CVPixelBufferRef)previous
               current:(CVPixelBufferRef)current
             timesteps:(NSArray<NSNumber *> *)timesteps
                 token:(uint64_t)token
            completion:(SPFRCPhasesCompletion)completion;
- (void)invalidate;
+ (NSDictionary<NSString *, id> *)probe;

@end

NS_ASSUME_NONNULL_END
