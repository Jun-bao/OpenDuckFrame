#import "SPFileLanczosScaler.h"
NS_ASSUME_NONNULL_BEGIN
@interface SPFileMetalFXScaler : SPFileLanczosScaler
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device sourceWidth:(int)sourceWidth sourceHeight:(int)sourceHeight outputWidth:(int)outputWidth outputHeight:(int)outputHeight error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
