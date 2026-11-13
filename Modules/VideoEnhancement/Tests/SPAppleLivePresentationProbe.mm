#import <AppKit/AppKit.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach_time.h>
#import <dlfcn.h>
#import "SPLiveProcessor.h"

@interface SPLivePreviewView (PresentationProbe)
- (NSDictionary *)displaySlotDiagnostics;
@end

static CVPixelBufferRef image(int width,int height,int frame,bool timingPattern) {
    CVPixelBufferRef b=NULL;
    CVPixelBufferCreate(NULL,width,height,kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)@{
        (id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES},&b);
    if(!b)return NULL;
    CVPixelBufferLockBaseAddress(b,0);
    uint8_t *base=(uint8_t *)CVPixelBufferGetBaseAddress(b); size_t stride=CVPixelBufferGetBytesPerRow(b);
    for(int y=0;y<height;++y) {
        uint32_t *row=(uint32_t *)(base+y*stride);
        for(int x=0;x<width;++x) row[x]=timingPattern ? (0xff000000u | (uint32_t(32+(((x/32+y/32+frame)&1)*12))*0x010101)) : 0xff202020;
        int left=(frame*4)%(width-100);
        if(y>height/3 && y<height*2/3) for(int x=left;x<left+100;++x) row[x]=0xffdddddd;
    }
    CVPixelBufferUnlockBaseAddress(b,0);
    CVBufferSetAttachment(b,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(b,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(b,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    return b;
}

int main(int argc,char **argv) { @autoreleasepool {
    if(argc!=4 || !dlopen(argv[1],RTLD_NOW|RTLD_LOCAL)){fprintf(stderr,"dlopen: %s\n",dlerror());return 2;}
    NSString *dest=@(argv[2]);
    const int sourceW=2560, sourceH=1410;
    NSString *profile=@(argv[3]);
    const BOOL automatic=[profile hasPrefix:@"auto"];
    const int videoFPS=[profile isEqualToString:@"auto24"]?24:([profile isEqualToString:@"auto30"]?30:25);
    const BOOL videoFixture=automatic || [profile isEqualToString:@"source25"];
    const BOOL jitter=videoFixture || [profile isEqualToString:@"jitter"];
    const double warmup=videoFixture?6:3;
    [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    Class viewClass=NSClassFromString(@"SPLivePreviewView");
    SPLivePreviewView *view=[[viewClass alloc] initWithFrame:NSMakeRect(0,0,sourceW,sourceH)];
    NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,sourceW,sourceH)
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    window.title=@"OpenDuckFrame — timed presentation component test";
    window.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    window.contentView=view;window.level=NSFloatingWindowLevel; window.releasedWhenClosed=NO;
    [window orderFrontRegardless];
    const double requestedDisplayHz=MIN(60,window.screen.maximumFramesPerSecond);
    [view setGeneration:1];[view refreshVisibilitySnapshot];
    SPLiveProcessor *p=[NSClassFromString(@"SPLiveProcessor") new];
    p.outputPreview=view; [p installPresentationHooks]; [p adoptSourceGeneration:1];
    NSMutableArray *presentations=[NSMutableArray array];NSLock *recordLock=[NSLock new];
    void (^productionPresented)(NSDictionary *)=[view.presented copy];
    view.presented=^(NSDictionary *event) {
        if(productionPresented)productionPresented(event);
        if([event[@"presentedTime"] doubleValue]>0 && [event[@"counts"] boolValue]) {
            NSMutableDictionary *entry=[NSMutableDictionary dictionary];
            for(NSString *key in @[@"ptsNum",@"ptsDen",@"frameID",@"synthetic",@"presentedTime",@"logicalTargetHost",@"generation",@"configVersion",@"actualMinusLogicalTargetNs",@"presentRequestMethod"])if(event[key])entry[key]=event[key];
            [recordLock lock];[presentations addObject:entry];[recordLock unlock];
        }
    };
    SPLivePlanRequest *request=[NSClassFromString(@"SPLivePlanRequest") new];
    request.interpolationEnabled=YES;request.engineID=@"apple.lowlatency";request.modelID=@"vt.llfi.temporal.1";
    request.rateKind=SPLiveRateMultiplier;request.multiplier=2;request.captureSourceKind=SPLiveCaptureSourceKindWindow;
    request.automaticVideoCadence=automatic;
    request.displayRefreshHz=requestedDisplayHz>0?requestedDisplayHz:window.screen.maximumFramesPerSecond;request.scaleEnabled=NO;request.requestID=1;
    [p updateRequest:request];
    __block int frame=0,tick=0,lastVideo=-1;__block NSDictionary *baseline=nil; NSMutableArray *samples=[NSMutableArray array];
    NSTimeInterval began=CACurrentMediaTime();
    NSTimer *feed=[NSTimer timerWithTimeInterval:1.0/(jitter?60.0:30.0) repeats:YES block:^(NSTimer *t) {
        (void)t;
        int video=frame,pts=frame,den=30;
        if(jitter) {
            ++tick;video=tick*(videoFixture?videoFPS:24)/60;pts=tick;den=60;
            if(video==lastVideo && tick%12!=(videoFixture?1:0))return;
            lastVideo=video;
        }
        CVPixelBufferRef b=image(sourceW,sourceH,video,videoFixture);
        if(!b){fprintf(stderr,"pixel buffer allocation failed\n");exit(1);}
        if(jitter){CVPixelBufferLockBaseAddress(b,0);uint32_t *pixels=(uint32_t*)CVPixelBufferGetBaseAddress(b);for(int x=0;x<32;++x)pixels[x]=0xff000000 | (frame&1?0xffffff:0x888888);CVPixelBufferUnlockBaseAddress(b,0);}
        [p pushPixelBuffer:b ptsNum:pts ptsDen:den host:mach_absolute_time() generation:1];++frame;
        CVPixelBufferRelease(b);
    }];
    [[NSRunLoop mainRunLoop] addTimer:feed forMode:NSRunLoopCommonModes];
    NSTimer *sample=[NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *t) {
        [view refreshVisibilitySnapshot];
        if(requestedDisplayHz>0) {
            CAMetalDisplayLink *link=[view valueForKey:@"displayLink"];
            link.preferredFrameRateRange=CAFrameRateRangeMake(requestedDisplayHz,requestedDisplayHz,requestedDisplayHz);
        }
        NSDictionary *s=p.stats;
        NSMutableDictionary *v=[NSMutableDictionary dictionary];
        NSDictionary *display=[view displaySlotDiagnostics];
        v[@"actualSelectionLeadNs"]=@([view selectionGuardNs]);v[@"actualRuleB"]=display[@"ruleB"] ?: @{};
        for(NSString *k in @[@"overlayInputEstimateFPS",@"overlayPresentedFPS",@"estimatedRequestedFPS",@"syntheticOK",@"syntheticFail",@"presentedSource",@"presentedSynthetic",@"presentationFailuresEpoch",@"sourceGeneration",@"configVersion",@"frcEwmaMs",@"delayMs",@"captureToOutputReadyP95ms",@"renderDrops",@"nativeBudgetActive",@"snapshotStale",@"automaticVideoCadence",@"detectedVideoFPS",@"videoRetimedFrames",@"videoCoalescedInputs",@"videoPendingInput"])
            if(s[k])v[k]=s[k];
        v[@"elapsed"]=@(CACurrentMediaTime()-began);v[@"visible"]=@(view.windowVisibleSnapshot);
        v[@"drawableVisible"]=@(view.drawableVisibleSnapshot);v[@"exposed"]=@(view.exposedSnapshot);
        if(CACurrentMediaTime()-began>=warmup) {if(!baseline)baseline=v;[samples addObject:v];}
        if(CACurrentMediaTime()-began<warmup+20)return;
        [feed invalidate];[t invalidate];
        [recordLock lock];NSArray *recorded=[presentations copy];[recordLock unlock];
        NSArray *ordered=[recorded sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b) {
            return [a[@"presentedTime"] compare:b[@"presentedTime"]];
        }];
        NSUInteger reversals=0;NSDictionary *previous=nil;
        for(NSDictionary *event in ordered) {
            if([event[@"presentedTime"] doubleValue]<began+warmup)continue;
            if(previous && [event[@"generation"] isEqual:previous[@"generation"]] &&
                [event[@"configVersion"] isEqual:previous[@"configVersion"]] &&
                (long double)[event[@"ptsNum"] longLongValue]*[previous[@"ptsDen"] longLongValue] <
                (long double)[previous[@"ptsNum"] longLongValue]*[event[@"ptsDen"] longLongValue])++reversals;
            previous=event;
        }
        BOOL visible=samples.count>0;
        for(NSDictionary *v in samples)visible=visible && [v[@"drawableVisible"] boolValue];
        NSDictionary *last=samples.lastObject ?: @{};
        BOOL cadenceOK=!automatic || [last[@"detectedVideoFPS"] intValue]==videoFPS;
        BOOL ok=cadenceOK && p.resolvedPlan.committed && p.resolvedPlan.interpolationActive &&
            [last[@"syntheticOK"] unsignedLongLongValue]>0 && [last[@"syntheticFail"] intValue]==0 &&
            [last[@"presentedSynthetic"] unsignedLongLongValue]>0 && visible && reversals==0 &&
            [last[@"actualRuleB"][@"enabled"] boolValue] &&
            [last[@"actualRuleB"][@"decisionCountInContext"] unsignedLongLongValue]>0;
        NSDictionary *result=@{@"ok":@(ok),@"ptsReversals":@(reversals),@"allMeasuredDrawableVisible":@(visible),
            @"displayLinkRequestedHz":@(request.displayRefreshHz),@"physicalMaximumHz":@(window.screen.maximumFramesPerSecond),
            @"sourceSize":@[@(sourceW),@(sourceH)],@"sourceFPS":@(videoFixture?videoFPS:(jitter?24:30)),@"profile":profile,@"warmupSeconds":@(warmup),@"windowAnimationHz":@(jitter?5:0),
            @"sourceFrames":@(frame),@"baseline":baseline?:@{},@"samples":samples,@"presentations":recorded,
            @"scope":@"Production Apple low-latency processor and display-link presenter in an owned visible test window, 3-second warmup (6 for the 25 FPS fixture) then 20-second observation. Steady 30 FPS, or 24/25 FPS content plus 5 Hz window animation. The 25 FPS fixture adds a low-contrast moving texture in all six sampling regions. No ScreenCaptureKit, foreground-selection policy, audiovisual or subjective quality acceptance. Display-link callback request does not change physical screen refresh."};
        [p stop];
        NSDictionary *stopped=p.stats;
        const BOOL released=![stopped[@"videoPendingInput"] boolValue];
        NSMutableDictionary *final=[result mutableCopy];final[@"stopPendingInputReleased"]=@(released);
        final[@"ok"]=@(ok && released);
        NSData *json=[NSJSONSerialization dataWithJSONObject:final options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];
        BOOL written=[json writeToFile:dest atomically:YES];
        printf("Apple presentation probe: %s; report: %s\n",ok && released && written?"PASS":"FAIL",dest.UTF8String);
        [window orderOut:nil];[NSApp stop:nil];exit(ok && released && written?0:1);
    }];
    [[NSRunLoop mainRunLoop] addTimer:sample forMode:NSRunLoopCommonModes];
    [NSApp run];return 0;
}}
