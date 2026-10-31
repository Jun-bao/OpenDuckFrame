#import <Foundation/Foundation.h>
#import <dlfcn.h>
@interface NSObject (RifeSwitchContract)
@property (nonatomic) BOOL liveStreamEnabled;
- (NSDictionary *)streamDiagnostics;
@end
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3 || !dlopen(argv[1], RTLD_NOW | RTLD_LOCAL)) return 2;
        Class cls=NSClassFromString(@"SPRifeBridge"); if (!cls) return 3;
        id bridge=[[cls alloc] init]; [bridge setLiveStreamEnabled:NO];
        NSDictionary *d=[bridge streamDiagnostics]; BOOL expected=atoi(argv[2])!=0;
        BOOL ok=![d[@"requested"] boolValue] && [d[@"effective"] boolValue]==expected &&
            [d[@"enableSource"] isEqualToString:(expected?@"environment":@"disabled")];
        NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"ok":@(ok),@"diagnostics":d} options:0 error:nil];
        fwrite(json.bytes,1,json.length,stdout); putchar('\n'); return ok?0:1;
    }
}
