#import "SPFileLanczosScaler.h"
NS_ASSUME_NONNULL_BEGIN
/// Independent-frame Random mode; deliberately keeps no temporal history.
@interface SPFileAppleVideoSRScaler : SPFileLanczosScaler
- (nullable instancetype)initWithSourceWidth:(int)sourceWidth sourceHeight:(int)sourceHeight outputWidth:(int)outputWidth outputHeight:(int)outputHeight error:(NSError **)error;
@property (nonatomic,readonly,copy) NSDictionary<NSString *,id> *submissionDiagnostics;
@end
NS_ASSUME_NONNULL_END
