#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>

@interface NSObject (LiveOutputRepairContract)
+ (NSDictionary *)runOutputRepairContractWithBundle:(NSBundle *)bundle;
+ (NSDictionary *)runLowLatency120Smoke;
+ (NSDictionary *)runLowLatencyPrescaleSmoke;
+ (NSDictionary *)runLiveSwitchContract;
+ (NSDictionary *)runLiveQualityProbe;
+ (NSDictionary *)runNativeBridgeQualityProbeWithBundle:(NSBundle *)bundle;
+ (NSDictionary *)runStaticHoldContract;
+ (NSDictionary *)runSourceSizeLifecycleContract;
+ (NSDictionary *)runSourceClockSchedulingContract;
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        if ((argc != 3 && argc != 4) || !dlopen(argv[1], RTLD_NOW | RTLD_LOCAL)) { fprintf(stderr,"dlopen: %s\n",dlerror()); return 2; }
        Class type = NSClassFromString(@"SPLiveProcessor");
        NSBundle *bundle = [NSBundle bundleWithPath:[NSString stringWithUTF8String:argv[2]]];
        if (!type || !bundle) return 3;
        __block NSDictionary *result = nil;
        dispatch_semaphore_t done=dispatch_semaphore_create(0);
        BOOL low=argc==4 && strcmp(argv[3],"low120")==0, low2k=argc==4 && strcmp(argv[3],"low2k")==0, switching=argc==4 && strcmp(argv[3],"switch")==0, quality=argc==4 && strcmp(argv[3],"quality")==0, staticHold=argc==4 && strcmp(argv[3],"static")==0;
        BOOL nativeBridge=argc==4 && strcmp(argv[3],"native-bridge")==0;
        BOOL sourceLifecycle=argc==4 && strcmp(argv[3],"source-lifecycle")==0;
        BOOL sourceClock=argc==4 && strcmp(argv[3],"source-clock")==0;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{ result = sourceClock ? [type runSourceClockSchedulingContract] : (sourceLifecycle ? [type runSourceSizeLifecycleContract] : (nativeBridge ? [type runNativeBridgeQualityProbeWithBundle:bundle] : (low ? [type runLowLatency120Smoke] : (low2k ? [type runLowLatencyPrescaleSmoke] : (switching ? [type runLiveSwitchContract] : (quality ? [type runLiveQualityProbe] : (staticHold ? [type runStaticHoldContract] : [type runOutputRepairContractWithBundle:bundle]))))))); dispatch_semaphore_signal(done); });
        while (dispatch_semaphore_wait(done,DISPATCH_TIME_NOW) != 0) CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.02,false);
        NSData *json=[NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        fwrite(json.bytes,1,json.length,stdout); putchar('\n');
        return [result[@"ok"] boolValue] ? 0 : 1;
    }
}
