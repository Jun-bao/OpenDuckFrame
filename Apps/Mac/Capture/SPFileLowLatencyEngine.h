#import <Foundation/Foundation.h>
#import "SPFileFrameProvider.h"

NS_ASSUME_NONNULL_BEGIN
/// File provider for Apple's one-midpoint temporal interpolator (8-bit SDR 709).
@interface SPFileLowLatencyEngine : NSObject <SPFileFrameProvider>
@end
NS_ASSUME_NONNULL_END
