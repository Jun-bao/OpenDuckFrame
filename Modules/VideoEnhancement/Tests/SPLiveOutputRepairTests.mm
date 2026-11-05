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
+ (NSDictionary *)runFixedRateContract;
+ (NSDictionary *)runFixedRateModelProbeWithBundle:(NSBundle *)bundle;
+ (NSDictionary *)runPendingReplacementContract;
+ (NSDictionary *)runRejectedPTSContract;
+ (NSDictionary *)runPresentationBudgetContract;
+ (NSDictionary *)runR9FRCBudgetContract;
+ (NSDictionary *)runP0PassthroughContract;
+ (NSDictionary *)runSharedGeometryBridgeContract;
+ (NSDictionary *)runP1SourceOnlyAckContract;
+ (NSDictionary *)runRife60to120WithBundle:(NSBundle *)bundle;
+ (NSDictionary *)runRifeFullSizeWithBundle:(NSBundle *)bundle;
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        if ((argc != 3 && argc != 4) || !dlopen(argv[1], RTLD_NOW | RTLD_LOCAL)) { fprintf(stderr,"dlopen: %s\n",dlerror()); return 2; }
        id activity = [[NSProcessInfo processInfo] beginActivityWithOptions:(NSActivityLatencyCritical | NSActivityUserInitiated)
                                                                      reason:@"Bounded headless cadence contract"];
        Class type = NSClassFromString(@"SPLiveProcessor");
        if (argc == 4 && (strcmp(argv[3], "owned-capture") == 0 || strcmp(argv[3], "owned-native120") == 0 || strcmp(argv[3], "owned-native120-bgra") == 0)) {
            Class contract = NSClassFromString(@"SPOwnedCaptureContract");
            SEL selector=strcmp(argv[3],"owned-native120")==0 ? NSSelectorFromString(@"runNative120") : (strcmp(argv[3],"owned-native120-bgra")==0 ? NSSelectorFromString(@"runNative120BGRA") : @selector(run));
            if (!contract || ![contract respondsToSelector:selector]) { [[NSProcessInfo processInfo] endActivity:activity]; return 4; }
            NSDictionary *value = [contract performSelector:selector];
            NSData *json = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
            fwrite(json.bytes, 1, json.length, stdout); putchar('\n');
            [[NSProcessInfo processInfo] endActivity:activity];
            return [value[@"ok"] boolValue] ? 0 : 1;
        }
        NSBundle *bundle = [NSBundle bundleWithPath:[NSString stringWithUTF8String:argv[2]]];
        if (!type || !bundle) { [[NSProcessInfo processInfo] endActivity:activity]; return 3; }
        if (argc == 4 && strcmp(argv[3], "p0-passthrough") == 0) {
            NSDictionary *value = [type runP0PassthroughContract];
            NSData *json = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
            fwrite(json.bytes, 1, json.length, stdout); putchar('\n');
            [[NSProcessInfo processInfo] endActivity:activity];
            return [value[@"ok"] boolValue] ? 0 : 1;
        }
        __block NSDictionary *result = nil;
        dispatch_semaphore_t done=dispatch_semaphore_create(0);
        if (argc == 4 && (strcmp(argv[3], "fixed-rate") == 0 || strcmp(argv[3], "fixed-model") == 0)) {
            const BOOL model=strcmp(argv[3],"fixed-model")==0;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{ result=model?[type runFixedRateModelProbeWithBundle:bundle]:[type runFixedRateContract]; dispatch_semaphore_signal(done); });
            while (dispatch_semaphore_wait(done,DISPATCH_TIME_NOW) != 0) CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.02,false);
            NSData *json=[NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
            fwrite(json.bytes,1,json.length,stdout); putchar('\n');
            [[NSProcessInfo processInfo] endActivity:activity]; return [result[@"ok"] boolValue] ? 0 : 1;
        }
        if (argc == 4 && strcmp(argv[3], "p1-source-ack") == 0) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{ result=[type runP1SourceOnlyAckContract]; dispatch_semaphore_signal(done); });
            while (dispatch_semaphore_wait(done,DISPATCH_TIME_NOW) != 0) CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.02,false);
            NSData *json=[NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
            fwrite(json.bytes,1,json.length,stdout); putchar('\n');
            [[NSProcessInfo processInfo] endActivity:activity]; return [result[@"ok"] boolValue] ? 0 : 1;
        }
        if (argc == 4 && strcmp(argv[3], "p0-geometry-bridge") == 0) {
            Class view=NSClassFromString(@"SPLivePreviewView");
            if (!view) { [[NSProcessInfo processInfo] endActivity:activity]; return 4; }
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{ result=[view runSharedGeometryBridgeContract]; dispatch_semaphore_signal(done); });
            while (dispatch_semaphore_wait(done,DISPATCH_TIME_NOW) != 0) CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.02,false);
            NSData *json=[NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
            fwrite(json.bytes,1,json.length,stdout); putchar('\n');
            [[NSProcessInfo processInfo] endActivity:activity]; return [result[@"ok"] boolValue] ? 0 : 1;
        }
        BOOL low=argc==4 && strcmp(argv[3],"low120")==0, low2k=argc==4 && strcmp(argv[3],"low2k")==0, switching=argc==4 && strcmp(argv[3],"switch")==0, quality=argc==4 && strcmp(argv[3],"quality")==0, staticHold=argc==4 && strcmp(argv[3],"static")==0;
        BOOL nativeBridge=argc==4 && strcmp(argv[3],"native-bridge")==0;
        BOOL sourceLifecycle=argc==4 && strcmp(argv[3],"source-lifecycle")==0;
        BOOL sourceClock=argc==4 && strcmp(argv[3],"source-clock")==0;
        BOOL pendingReplacement=argc==4 && strcmp(argv[3],"pending-replacement")==0;
        BOOL rejectedPTS=argc==4 && strcmp(argv[3],"rejected-pts")==0;
        BOOL budget=argc==4 && strcmp(argv[3],"budget")==0;
        BOOL r9Budget=argc==4 && strcmp(argv[3],"r9-budget")==0;
        BOOL rife60=argc==4 && strcmp(argv[3],"rife60")==0;
        BOOL rifeFull=argc==4 && strcmp(argv[3],"rife-fullsize")==0;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{ result = r9Budget ? [type runR9FRCBudgetContract] : (rifeFull ? [type runRifeFullSizeWithBundle:bundle] : (rife60 ? [type runRife60to120WithBundle:bundle] : (budget ? [type runPresentationBudgetContract] : (rejectedPTS ? [type runRejectedPTSContract] : (pendingReplacement ? [type runPendingReplacementContract] : (sourceClock ? [type runSourceClockSchedulingContract] : (sourceLifecycle ? [type runSourceSizeLifecycleContract] : (nativeBridge ? [type runNativeBridgeQualityProbeWithBundle:bundle] : (low ? [type runLowLatency120Smoke] : (low2k ? [type runLowLatencyPrescaleSmoke] : (switching ? [type runLiveSwitchContract] : (quality ? [type runLiveQualityProbe] : (staticHold ? [type runStaticHoldContract] : [type runOutputRepairContractWithBundle:bundle]))))))))))))); dispatch_semaphore_signal(done); });
        while (dispatch_semaphore_wait(done,DISPATCH_TIME_NOW) != 0) CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.02,false);
        NSData *json=[NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        fwrite(json.bytes,1,json.length,stdout); putchar('\n');
        [[NSProcessInfo processInfo] endActivity:activity];
        return [result[@"ok"] boolValue] ? 0 : 1;
    }
}
