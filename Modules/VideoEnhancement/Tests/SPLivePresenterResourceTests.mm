// Directly exercise the existing renderer/resource probe without the model matrix.
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>

@interface NSObject (SPLivePresenterResourceProbe)
- (instancetype)initWithFrame:(NSRect)frame;
- (NSDictionary *)runOffscreenDrawAndLifetimeProbe;
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 2 || !dlopen(argv[1], RTLD_NOW | RTLD_LOCAL)) {
            fprintf(stderr, "dlopen: %s\n", dlerror()); return 2;
        }
        Class type = NSClassFromString(@"SPLivePreviewView");
        id view = [[type alloc] initWithFrame:NSMakeRect(0, 0, 64, 32)];
        SEL legacy = NSSelectorFromString(@"presentEnhanced:original:mode:captureHost:generation:ptsNum:ptsDen:synthetic:frameID:counts:captureGeometry:reason:");
        if (!view || ![view respondsToSelector:legacy]) return 3;
        NSMutableDictionary *result = [[view runOffscreenDrawAndLifetimeProbe] mutableCopy];
        result[@"legacyPublicSelectorPresent"] = @YES;
        NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil];
        fwrite(data.bytes, 1, data.length, stdout); putchar('\n');
        return [result[@"ok"] boolValue] ? 0 : 1;
    }
}
