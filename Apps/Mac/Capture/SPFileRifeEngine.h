#import <Foundation/Foundation.h>
#import "SPFileFrameProvider.h"

NS_ASSUME_NONNULL_BEGIN
@interface SPFileRifeEngine : NSObject <SPFileFrameProvider>
- (instancetype)initWithModelID:(NSString *)modelID quality:(NSString *)quality;
- (instancetype)initWithModelID:(NSString *)modelID quality:(NSString *)quality resourceBundle:(NSBundle *)bundle;
@end
NS_ASSUME_NONNULL_END
