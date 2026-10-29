#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import "SPPlayerCore.h"
#import "SPFileRifeEngine.h"
#import "SPFileDistilEngine.h"
#import <dlfcn.h>

@interface HeadlessFileProvider : NSObject <SPFileFrameProvider>
@property BOOL shouldFail;
@end
@implementation HeadlessFileProvider
- (void)prepareWithSample:(CVPixelBufferRef)sample completion:(void (^)(BOOL,NSString *))completion {(void)sample;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_MSEC),dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{completion(!self.shouldFail,self.shouldFail?@"test failure":@"");});}
- (BOOL)submitPrevious:(CVPixelBufferRef)previous current:(CVPixelBufferRef)current previousPTSUs:(int64_t)previousPTSUs currentPTSUs:(int64_t)currentPTSUs phases:(NSArray<NSNumber *> *)phases token:(uint64_t)token completion:(SPFRCPhasesCompletion)completion {
    (void)current;CVPixelBufferRetain(previous);dispatch_after(dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_MSEC),dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{NSMutableArray *outputs=[NSMutableArray array];for(NSNumber *phase in phases){(void)phase;[outputs addObject:[[SPOwnedPixelBuffer alloc] initRetainingBuffer:previous]];}CVPixelBufferRelease(previous);completion(token,outputs,0.020,nil);});return YES;
}
- (void)invalidate {}
@end

@interface SPPlayerCore (FileResourceTest)
- (void)prepareFileScalerWidth:(int)width height:(int)height engine:(NSString *)engine variant:(NSString *)variant resourceBundle:(NSBundle *)bundle completion:(void (^)(BOOL, NSString *))completion;
@end

static bool awaitCondition(BOOL (^condition)(void), NSTimeInterval seconds) {
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];
    while(!condition() && [end timeIntervalSinceNow]>0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
    return condition();
}

int main(int argc,const char **argv) { @autoreleasepool {
    if(argc!=2 && argc!=3 && argc!=4)return 2;
    BOOL apple=argc==3 && strcmp(argv[2],"apple")==0;
    BOOL metalfx=argc==3 && strcmp(argv[2],"metalfx")==0;
    BOOL videoSR=argc==3 && strcmp(argv[2],"videosr")==0;
    NSString *engine=argc==4?[NSString stringWithUTF8String:argv[2]]:(apple?@"apple.low-sr":(metalfx?@"metalfx.spatial":(videoSR?@"apple.video-sr":@"lanczos")));
    NSBundle *resources=argc==4?[NSBundle bundleWithPath:[NSString stringWithUTF8String:argv[3]]]:NSBundle.mainBundle;
    int outputWidth=argc==4?320:((apple||metalfx||videoSR)?1920:640), outputHeight=argc==4?192:((apple||metalfx||videoSR)?1080:384);
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    NSView *view=[[NSView alloc] initWithFrame:NSMakeRect(0,0,320,192)];
    view.wantsLayer=YES;view.layer=[CAMetalLayer layer];
    SPPlayerCore *core=[[SPPlayerCore alloc] initWithView:view];
    if(!core)return 3;
    [core setMuted:YES];[core setTimelinePreviewSuspended:YES];[core setWindowVisibleForRendering:YES];
    NSError *error=nil;BOOL accepted=[core openFileAtPath:[NSString stringWithUTF8String:argv[1]] error:&error];
    bool ready=accepted && awaitCondition(^BOOL { return core.hasEverPresentedThisSession || core.state==SPPlayerStateFailed; },10);
    if(!ready || core.state==SPPlayerStateFailed) {
        fprintf(stderr,"headless media did not reach a renderer admission; state=%ld error=%s\n",(long)core.state,error.localizedDescription.UTF8String?:"");
        [core stop];return 4;
    }
    __block BOOL prepared=NO,finished=NO;__block NSString *reason=@"";
    [core prepareFileScalerWidth:outputWidth height:outputHeight engine:engine variant:@"none" resourceBundle:resources completion:^(BOOL ok,NSString *message){prepared=ok;reason=message;finished=YES;}];
    if(!awaitCondition(^BOOL{return finished;},15) || !prepared) { fprintf(stderr,"prepare: %s\n",reason.UTF8String);[core stop];return 5; }
    bool committed=[core activatePreparedFileLanczos] && core.fileLanczosActive && core.fileLanczosWidth==outputWidth && core.fileLanczosHeight==outputHeight;
    __block BOOL invalidFinished=NO,invalidAccepted=YES;
    [core prepareFileLanczosWidth:9998 height:384 completion:^(BOOL ok,NSString *message){(void)message;invalidAccepted=ok;invalidFinished=YES;}];
    bool invalidCompleted=awaitCondition(^BOOL{return invalidFinished;},10);
    bool kept=invalidCompleted && !invalidAccepted && core.fileLanczosActive && core.fileLanczosWidth==outputWidth && core.fileLanczosHeight==outputHeight;
    __block BOOL cancelFinished=NO,cancelAccepted=YES;
    [core prepareFileScalerWidth:outputWidth height:outputHeight engine:engine variant:@"none" resourceBundle:resources completion:^(BOOL ok,NSString *message){(void)message;cancelAccepted=ok;cancelFinished=YES;}];
    [core cancelPreparedFileLanczos];
    bool cancelDone=awaitCondition(^BOOL{return cancelFinished;},15);
    bool cancelKept=cancelDone && !cancelAccepted && core.fileLanczosActive && core.fileLanczosWidth==outputWidth;
    bool fakeRequested=getenv("KHUA_TEST_FAKE_FILE_PROVIDER")!=nullptr, realRequested=getenv("KHUA_TEST_REAL_FILE_RIFE")!=nullptr, lowRequested=getenv("KHUA_TEST_REAL_FILE_LOW_LATENCY")!=nullptr, distilRequested=getenv("KHUA_TEST_REAL_FILE_DISTIL")!=nullptr;
    bool providerRequested=fakeRequested||realRequested||lowRequested||distilRequested;
    id<SPFileFrameProvider> provider=nil;
    if(fakeRequested) provider=[[HeadlessFileProvider alloc] init];
    if(realRequested){
        const char *path=getenv("KHUA_TEST_DEBUG_DYLIB"),*app=getenv("KHUA_TEST_RESOURCE_APP"),*model=getenv("KHUA_TEST_REAL_FILE_RIFE");
        if(!path||!app||!dlopen(path,RTLD_NOW|RTLD_LOCAL)){fprintf(stderr,"debug dylib: %s\n",dlerror());return 7;}
        Class type=NSClassFromString(@"SPFileRifeEngine");provider=(id)[[type alloc] initWithModelID:[NSString stringWithUTF8String:model] quality:@"fast" resourceBundle:[NSBundle bundleWithPath:[NSString stringWithUTF8String:app]]];
        if(!provider)return 7;
    }
    if(lowRequested) {
        const char *path=getenv("KHUA_TEST_DEBUG_DYLIB");
        if(!path||!dlopen(path,RTLD_NOW|RTLD_LOCAL)){fprintf(stderr,"debug dylib: %s\n",dlerror());return 7;}
        provider=(id)[NSClassFromString(@"SPFileLowLatencyEngine") new]; if(!provider)return 7;
    }
    if(distilRequested) {
        const char *path=getenv("KHUA_TEST_DEBUG_DYLIB"),*app=getenv("KHUA_TEST_RESOURCE_APP");
        if(!path||!app||!dlopen(path,RTLD_NOW|RTLD_LOCAL)){fprintf(stderr,"debug dylib: %s\n",dlerror());return 7;}
        provider=(id)[(SPFileDistilEngine *)[NSClassFromString(@"SPFileDistilEngine") alloc] initWithResourceBundle:[NSBundle bundleWithPath:[NSString stringWithUTF8String:app]]];if(!provider)return 7;
    }
    __block BOOL providerDone=NO,providerReady=NO;
    if(providerRequested) [core prepareFileFrameProvider:provider completion:^(BOOL ready,NSString *message){if(!ready)fprintf(stderr,"provider: %s\n",message.UTF8String);providerReady=ready;providerDone=YES;}];
    bool providerPrepared=!providerRequested || (awaitCondition(^BOOL{return providerDone;},30)&&providerReady);
    __block BOOL scaleDone=NO,scaleReady=NO;
    if(providerRequested) [core prepareFileScalerWidth:outputWidth height:outputHeight engine:engine variant:@"none" resourceBundle:resources completion:^(BOOL ready,NSString *message){(void)message;scaleReady=ready;scaleDone=YES;}];
    bool scalePrepared=!providerRequested || (awaitCondition(^BOOL{return scaleDone;},10)&&scaleReady);
    bool transaction=!providerRequested || (providerPrepared && scalePrepared && [core commitFilePlanWithInterpolation:YES usePreparedProvider:YES cadence:((lowRequested||distilRequested)?2:3) numerator:0 denominator:1 usePreparedScaler:YES] && core.fileLanczosActive);
    NSDictionary *videoDiagnostics=core.fileScalerDiagnostics;
    bool videoRandomOK=!videoSR || ([videoDiagnostics[@"random"] unsignedIntegerValue]>=1 && [videoDiagnostics[@"sequential"] unsignedIntegerValue]==0 && [videoDiagnostics[@"history"] unsignedIntegerValue]==0 && ![videoDiagnostics[@"temporal"] boolValue] && [videoDiagnostics[@"mode"] isEqualToString:@"Random"]);
    bool rejectedAndKept=!providerRequested || (![core commitFilePlanWithInterpolation:YES usePreparedProvider:YES cadence:((lowRequested||distilRequested)?2:3) numerator:0 denominator:1 usePreparedScaler:NO] && core.fileLanczosActive);
    // Keep unknown scan fail-closed; test same-file recovery by seeking to its initial keyframe.
    bool scanTest=getenv("KHUA_TEST_SCAN_WAIT")!=nullptr;
    bool sawScanWait=!scanTest || (providerRequested && awaitCondition(^BOOL{return core.frameInterpolationAwaitingScan;},5));
    if(providerRequested)[core seekTo:scanTest?0.0:0.5];
    bool providerActive=!providerRequested || awaitCondition(^BOOL{return core.frameInterpolationActive;},8);
    if(providerRequested&&!providerActive)fprintf(stderr,"provider did not become active: %s\n",core.frameInterpolationStatus.UTF8String);
    __block BOOL providerCancelDone=NO,providerCancelReady=YES;
    if(providerRequested){
        HeadlessFileProvider *late=[[HeadlessFileProvider alloc] init];
        [core prepareFileFrameProvider:late completion:^(BOOL ready,NSString *message){(void)message;providerCancelReady=ready;providerCancelDone=YES;}];
        [core cancelPreparedFileFrameProvider];
    }
    bool canceledProviderKept=!providerRequested || (awaitCondition(^BOOL{return providerCancelDone;},10)&&!providerCancelReady&&core.fileLanczosActive&&core.frameInterpolationMode==SPFrameInterpolationModeDoubleRate);
    __block BOOL failedDone=NO,failedReady=YES;HeadlessFileProvider *failed=[[HeadlessFileProvider alloc] init];failed.shouldFail=YES;
    if(providerRequested)[core prepareFileFrameProvider:failed completion:^(BOOL ready,NSString *message){(void)message;failedReady=ready;failedDone=YES;}];
    bool failedKept=!providerRequested || (awaitCondition(^BOOL{return failedDone;},10)&&!failedReady&&core.fileLanczosActive&&core.frameInterpolationMode==SPFrameInterpolationModeDoubleRate);
    BOOL cadence=[core configureFileInterpolationMode:((lowRequested||distilRequested)?2:3) numerator:0 denominator:1];
    core.frameInterpolationMode=SPFrameInterpolationModeDoubleRate;
    [core seekTo:1.2];
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    bool seekRetained=cadence && core.fileLanczosActive && core.fileLanczosWidth==outputWidth && core.state!=SPPlayerStateFailed;
    bool compatTier=getenv("SP_TIER") && strcmp(getenv("SP_TIER"),"compat")==0;
    bool returnedFRC=true;
    if(providerRequested){
        BOOL fallback=[core commitFilePlanWithInterpolation:YES usePreparedProvider:NO cadence:2 numerator:0 denominator:1 usePreparedScaler:NO];
        returnedFRC=compatTier ? (!fallback && core.frameInterpolationMode==SPFrameInterpolationModeDoubleRate && core.fileLanczosActive) : (fallback && core.frameInterpolationMode==SPFrameInterpolationModeDoubleRate && !core.fileLanczosActive);
    }
    [core disableFileLanczos];bool disabled=!core.fileLanczosActive;[core stop];
    bool ok=videoRandomOK && committed && kept && cancelKept && providerPrepared && scalePrepared && transaction && rejectedAndKept && providerActive && sawScanWait && canceledProviderKept && failedKept && seekRetained && returnedFRC && disabled;
    printf("{\"ok\":%s,\"fileOpenedAndFrameAdmitted\":%s,\"preparedCurrentDecodedFrame\":%s,\"committedRequestedSize\":%s,\"invalidKeptOldPlan\":%s,\"cancelKeptOldPlan\":%s,\"seekAndCadenceRetainedPlan\":%s,\"providerRequested\":%s,\"providerTransaction\":%s,\"providerBecameActive\":%s,\"scanWaitObserved\":%s,\"missingProviderKeptPlan\":%s,\"failedPrepareKeptPlan\":%s,\"canceledProviderKeptPlan\":%s,\"frcSelectionBehaviorCorrect\":%s,\"compatibilityTierSimulated\":%s,\"disabled\":%s,\"videoRandomNoHistory\":%s,\"scope\":\"headless real-file player core and GPU preflight; no window, actual drawable, UI or A/V sync\"}\n",ok?"true":"false",ready?"true":"false",prepared?"true":"false",committed?"true":"false",kept?"true":"false",cancelKept?"true":"false",seekRetained?"true":"false",providerRequested?"true":"false",transaction?"true":"false",providerActive?"true":"false",sawScanWait?"true":"false",rejectedAndKept?"true":"false",failedKept?"true":"false",canceledProviderKept?"true":"false",returnedFRC?"true":"false",compatTier?"true":"false",disabled?"true":"false",videoRandomOK?"true":"false");
    return ok?0:6;
}}
