#import <Foundation/Foundation.h>
#import "SPFileFrameProvider.h"
NS_ASSUME_NONNULL_BEGIN
@interface SPFileDistilEngine : NSObject <SPFileFrameProvider>
- (instancetype)initWithResourceBundle:(NSBundle *)bundle;
@end
NS_ASSUME_NONNULL_END
