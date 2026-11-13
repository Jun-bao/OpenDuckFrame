#import <AppKit/AppKit.h>
#import <VideoToolbox/VideoToolbox.h>
#import <mach/mach_time.h>
#import <dlfcn.h>
#import "SPLowLatencyEngine.h"
#import "SPLiveProcessor.h"

static CVPixelBufferRef source(int width, int height, int offset) {
    CVPixelBufferRef buffer = NULL;
    CVPixelBufferCreate(NULL, width, height, kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},
                                    (id)kCVPixelBufferMetalCompatibilityKey:@YES}, &buffer);
    if (!buffer) return NULL;
    CVPixelBufferLockBaseAddress(buffer, 0);
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(buffer);
    size_t stride = CVPixelBufferGetBytesPerRow(buffer);
    for (int y=0; y<height; ++y) for (int x=0; x<width; ++x) {
        uint8_t *p=base+y*stride+x*4;
        uint8_t value=(x>width/3+offset && x<width/3+offset+100 && y>height/3 && y<height*2/3) ? 230 : 25;
        p[0]=p[1]=p[2]=value; p[3]=255;
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    return buffer;
}

static NSDictionary *runSize(int width, int height, NSInteger slots) {
    SPLowLatencyEngine *engine=[NSClassFromString(@"SPLowLatencyEngine") new];
    NSError *prepareError=nil;
    BOOL prepared=[engine prepareLiveWidth:width height:height frames:slots error:&prepareError];
    if (!prepared) return @{@"ok":@NO, @"error":prepareError.localizedDescription ?: @"prepare"};
    NSInteger maxDimension=1280, maxPixels=1280*720;
    if (@available(macOS 27.0, *)) {
        maxDimension=[VTLowLatencyFrameInterpolationConfiguration maximumDimensionForSpatialScaleFactor:1];
        maxPixels=[VTLowLatencyFrameInterpolationConfiguration maximumPixelCountForSpatialScaleFactor:1];
    }
    BOOL bounded=engine.width>0 && engine.height>0 && !(engine.width&1) && !(engine.height&1) &&
        (maxDimension<=0 || (engine.width<=maxDimension && engine.height<=maxDimension)) &&
        (maxPixels<=0 || (int64_t)engine.width*engine.height<=maxPixels);
    BOOL unchangedSmall=width!=1280 || height!=720 || (engine.width==width && engine.height==height);
    CVPixelBufferRef a=source(width,height,0), b=source(width,height,24);
    NSArray *phases=slots==2 ? @[@0.25,@0.5,@0.75] : @[@0.5];
    dispatch_semaphore_t done=dispatch_semaphore_create(0);
    __block NSArray<SPOwnedPixelBuffer *> *outputs=nil;
    __block NSError *runError=nil;
    __block BOOL tokenOK=NO;
    BOOL submitted=a && b && [engine submitPrevious:a current:b previousPTS:CMTimeMake(0,30) currentPTS:CMTimeMake(1,30)
        phases:phases token:41 completion:^(uint64_t token, NSArray<SPOwnedPixelBuffer *> *frames, double seconds, NSError *error) {
            tokenOK=token==41; outputs=frames; runError=error; dispatch_semaphore_signal(done);
        }];
    BOOL finished=submitted && dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_SEC))==0;
    BOOL geometry=finished && outputs.count==phases.count, color=geometry;
    for (SPOwnedPixelBuffer *output in outputs) {
        geometry=geometry && CVPixelBufferGetWidth(output.buffer)==width && CVPixelBufferGetHeight(output.buffer)==height;
        CFTypeRef primaries=CVBufferGetAttachment(output.buffer,kCVImageBufferColorPrimariesKey,NULL);
        color=color && primaries && CFEqual(primaries,kCVImageBufferColorPrimaries_ITU_R_709_2);
    }
    BOOL sourceIntact=a && b && CVPixelBufferGetWidth(a)==width && CVPixelBufferGetHeight(b)==height;
    if(a) CVPixelBufferRelease(a); if(b) CVPixelBufferRelease(b);
    NSDictionary *report=@{@"ok":@(prepared && bounded && unchangedSmall && submitted && finished && geometry && color && tokenOK && !runError && sourceIntact),
        @"input":@[@(width),@(height)], @"processing":@[@(engine.width),@(engine.height)],
        @"phases":phases, @"outputCount":@(outputs.count), @"sourceGeometryPreserved":@(sourceIntact),
        @"outputGeometryPreserved":@(geometry), @"bt709Preserved":@(color), @"bounded":@(bounded),
        @"error":runError.localizedDescription ?: @"", @"fallbackReason":engine.preparationFallbackReason};
    [engine invalidate]; return report;
}

static NSDictionary *runLivePlan(void) {
    SPLiveProcessor *processor=[NSClassFromString(@"SPLiveProcessor") new];
    [processor adoptSourceGeneration:7];
    SPLivePlanRequest *request=[NSClassFromString(@"SPLivePlanRequest") new];
    request.interpolationEnabled=YES; request.engineID=@"apple.lowlatency"; request.modelID=@"vt.llfi.temporal.1";
    request.rateKind=SPLiveRateMultiplier; request.multiplier=2; request.displayRefreshHz=60;
    request.captureSourceKind=SPLiveCaptureSourceKindWindow;
    [processor updateRequest:request];
    CVPixelBufferRef first=source(2560,1410,0);
    [processor pushPixelBuffer:first ptsNum:0 ptsDen:30 host:mach_absolute_time() generation:7];
    CVPixelBufferRelease(first);
    for(int i=0;i<1000 && !processor.resolvedPlan.committed && !processor.resolvedPlan.unavailableReason.length;++i) usleep(10000);
    for(int frame=1;frame<5;++frame) {
        CVPixelBufferRef buffer=source(2560,1410,frame*6);
        [processor pushPixelBuffer:buffer ptsNum:frame ptsDen:30 host:mach_absolute_time() generation:7];
        CVPixelBufferRelease(buffer); usleep(33333);
    }
    NSDictionary *stats=processor.stats;
    for(int i=0;i<100 && [stats[@"syntheticOK"] intValue]==0;++i) { usleep(10000); stats=processor.stats; }
    BOOL ok=processor.resolvedPlan.committed && processor.resolvedPlan.interpolationActive &&
        [stats[@"syntheticOK"] intValue]>0 && [stats[@"syntheticFail"] intValue]==0 &&
        fabs([stats[@"estimatedRequestedFPS"] doubleValue]-60)<0.1 &&
        [stats[@"sourceWidth"] intValue]==2560 && [stats[@"sourceHeight"] intValue]==1410 &&
        processor.resolvedPlan.outputWidth==2560 && processor.resolvedPlan.outputHeight==1410;
    NSDictionary *result=@{@"ok":@(ok), @"targetFPS":stats[@"estimatedRequestedFPS"] ?: @(-1),
        @"generated":stats[@"syntheticOK"] ?: @0, @"error":processor.resolvedPlan.unavailableReason ?: @""};
    [processor stop]; return result;
}

int main(int argc,const char **argv) { @autoreleasepool {
    if(argc!=2 || !dlopen(argv[1],RTLD_NOW|RTLD_LOCAL)) { fprintf(stderr,"dlopen: %s\n",dlerror()); return 2; }
    if(![NSClassFromString(@"SPLowLatencyEngine") isSupported]) { puts("SKIP: Apple low latency is unavailable on this Mac"); return 0; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{ @autoreleasepool {
        NSMutableArray *cases=[NSMutableArray array];
        for(NSArray *size in @[@[@1280,@720,@1],@[@2560,@1410,@1],@[@5120,@2820,@2],@[@1410,@2560,@1]])
            [cases addObject:runSize([size[0] intValue],[size[1] intValue],[size[2] integerValue])];
        SPLowLatencyEngine *invalid=[NSClassFromString(@"SPLowLatencyEngine") new];
        NSError *error=nil;
        BOOL oddRejected=![invalid prepareLiveWidth:1279 height:720 frames:1 error:&error] && error!=nil;
        NSDictionary *live=runLivePlan();
        BOOL ok=oddRejected && [live[@"ok"] boolValue];
        for(NSDictionary *item in cases) ok=ok && [item[@"ok"] boolValue];
        NSDictionary *result=@{@"ok":@(ok), @"cases":cases, @"oddRejected":@(oddRejected), @"livePlan":live,
            @"scope":@"Real Apple inference and live plan; synthetic inputs. No capture permission, window, drawable or physical FPS measurement."};
        NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil];
        fwrite(json.bytes,1,json.length,stdout); putchar('\n'); exit(ok?0:1);
    }}); dispatch_main();
}}
