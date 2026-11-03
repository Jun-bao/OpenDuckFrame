#import "SPFileLanczosScaler.h"

// File renderer adapter for the existing single-in-flight Apple SR engine.
@interface SPFileAppleSRScaler : SPFileLanczosScaler
- (nullable instancetype)initWithSourceWidth:(int)sourceWidth sourceHeight:(int)sourceHeight
                                outputWidth:(int)outputWidth outputHeight:(int)outputHeight
                                      error:(NSError **)error;
@end
