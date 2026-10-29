#import "SPFileLanczosScaler.h"

// Adapts the resident, single-job animation engines to the file renderer.
@interface SPFileAnimationScaler : SPFileLanczosScaler
- (nullable instancetype)initWithSourceWidth:(int)width sourceHeight:(int)height
                                     engine:(NSString *)engine variant:(NSString *)variant
                             resourceBundle:(NSBundle *)bundle error:(NSError **)error;
@end
