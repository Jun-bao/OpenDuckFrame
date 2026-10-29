#import <AppKit/AppKit.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import "SPMetalRenderer.h"
#import "SPFileLanczosScaler.h"
#import "SPFileAppleSRScaler.h"
#import "SPFileAppleVideoSRScaler.h"
#include <atomic>
#include <unistd.h>

static std::atomic<int> gStarted{0}, gCompleted{0}, gAppleCompleted{0}, gVideoMask{0};
static std::atomic<int64_t> gObservedPTS{INT64_MIN};
static std::atomic<int> gSlowCalls{0};
static std::atomic<int64_t> gSlowLatestPTS{INT64_MIN};
static dispatch_semaphore_t gSlowStarted;
static void (^gFinishSlow)(void);
@interface TrackingLanczos : SPFileLanczosScaler @end
@implementation TrackingLanczos
- (BOOL)submit:(CVPixelBufferRef)source completion:(void (^)(CVPixelBufferRef, NSError *))completion {
    gStarted.fetch_add(1);
    return [super submit:source completion:^(CVPixelBufferRef result, NSError *error) {
        if (result && !error && CVPixelBufferGetWidth(result)==64 && CVPixelBufferGetHeight(result)==64) gCompleted.fetch_add(1);
        completion(result,error);
    }];
}
@end

@interface TrackingAppleSR : SPFileAppleSRScaler @end
@implementation TrackingAppleSR
- (BOOL)submit:(CVPixelBufferRef)source ptsUs:(int64_t)ptsUs completion:(void (^)(CVPixelBufferRef, NSError *))completion {
    gObservedPTS.store(ptsUs);
    return [super submit:source ptsUs:ptsUs completion:^(CVPixelBufferRef output, NSError *error) {
        if (output && !error && CVPixelBufferGetWidth(output)==1920 && CVPixelBufferGetHeight(output)==1080 && CVPixelBufferGetPixelFormatType(output)==kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) gAppleCompleted.fetch_add(1);
        completion(output,error);
    }];
}
@end

@interface TrackingVideoSR : SPFileAppleVideoSRScaler @end
@implementation TrackingVideoSR
- (BOOL)submit:(CVPixelBufferRef)source ptsUs:(int64_t)ptsUs completion:(void (^)(CVPixelBufferRef,NSError *))completion {
    return [super submit:source ptsUs:ptsUs completion:^(CVPixelBufferRef output,NSError *error){
        if(output&&!error){if(ptsUs==101001)gVideoMask.fetch_or(1);if(ptsUs==117667)gVideoMask.fetch_or(2);}
        completion(output,error);
    }];
}
@end

@interface SlowLanczos : SPFileLanczosScaler @end
@implementation SlowLanczos
- (BOOL)submit:(CVPixelBufferRef)source ptsUs:(int64_t)ptsUs completion:(void (^)(CVPixelBufferRef, NSError *))completion {
    gSlowLatestPTS.store(ptsUs); gSlowCalls.fetch_add(1);
    return [self submit:source completion:completion];
}
- (BOOL)submit:(CVPixelBufferRef)source completion:(void (^)(CVPixelBufferRef, NSError *))completion {
    CVPixelBufferRef retained=CVPixelBufferRetain(source);
    gFinishSlow = ^{ completion(retained,nil); };
    dispatch_semaphore_signal(gSlowStarted);
    return YES;
}
@end

int main() { @autoreleasepool {
    CAMetalLayer *layer=[CAMetalLayer layer]; layer.drawableSize=CGSizeMake(64,64);
    SPMetalRenderer *renderer=[[SPMetalRenderer alloc] initWithLayer:layer logId:991];
    if (!renderer) { fprintf(stderr,"renderer init failed\n"); return 1; }
    NSError *error=nil;
    TrackingLanczos *scaler=[[TrackingLanczos alloc] initWithDevice:renderer.device width:64 height:64 error:&error];
    if (!scaler) { fprintf(stderr,"scaler init failed: %s\n",error.localizedDescription.UTF8String); return 2; }
    NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};
    CVPixelBufferRef source=NULL;
    if (CVPixelBufferCreate(NULL,32,32,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,(__bridge CFDictionaryRef)attrs,&source)!=kCVReturnSuccess) return 3;
    CVBufferSetAttachment(source,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    [renderer setFileLanczosScaler:scaler];
    BOOL accepted=[renderer renderPixelBuffer:source];
    for(int i=0;i<100 && gCompleted.load()==0;i++)usleep(20000);
    const int started=gStarted.load(), completed=gCompleted.load();
    [renderer setFileLanczosScaler:nil]; [renderer discardPendingSubmits];
    // Replace a still-running scale request: the replacement may not start
    // another GPU job until the old request completes, and old completion may
    // not publish into the new renderer epoch.
    CAMetalLayer *otherLayer=[CAMetalLayer layer]; otherLayer.drawableSize=CGSizeMake(64,64);
    SPMetalRenderer *other=[[SPMetalRenderer alloc] initWithLayer:otherLayer logId:992];
    SlowLanczos *slow=[[SlowLanczos alloc] initWithDevice:other.device width:64 height:64 error:&error];
    TrackingLanczos *replacement=[[TrackingLanczos alloc] initWithDevice:other.device width:64 height:64 error:&error];
    gStarted.store(0);gCompleted.store(0);gSlowStarted=dispatch_semaphore_create(0);
    [other setFileLanczosScaler:slow];BOOL oldAccepted=[other renderPixelBuffer:source];
    bool slowStarted=dispatch_semaphore_wait(gSlowStarted,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0;
    [other setFileLanczosScaler:replacement];BOOL newAccepted=[other renderPixelBuffer:source];
    usleep(200000);bool bounded=gStarted.load()==0;
    if(gFinishSlow) { gFinishSlow();gFinishSlow=nil; }
    for(int i=0;i<150 && gCompleted.load()==0;i++)usleep(20000);
    bool replacementCompleted=gCompleted.load()>0;
    [other setFileLanczosScaler:nil];[other discardPendingSubmits];
    // Invalidate an in-flight job as a seek, then as a same-engine replan.
    // Both retain one in-flight task and accept only a latest pending request.
    bool epochsOK=true;
    for(int kind=0;kind<2;kind++) {
        CAMetalLayer *epochLayer=[CAMetalLayer layer];epochLayer.drawableSize=CGSizeMake(64,64);
        SPMetalRenderer *epochRenderer=[[SPMetalRenderer alloc] initWithLayer:epochLayer logId:994+kind];
        SlowLanczos *same=[[SlowLanczos alloc] initWithDevice:epochRenderer.device width:64 height:64 error:&error];
        gSlowCalls.store(0);gSlowLatestPTS.store(INT64_MIN);gSlowStarted=dispatch_semaphore_create(0);gFinishSlow=nil;
        [epochRenderer setFileLanczosScaler:same];BOOL first=[epochRenderer renderPixelBuffer:source ptsUs:101 presented:nil];
        bool firstStarted=dispatch_semaphore_wait(gSlowStarted,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0;
        if(kind==0)[epochRenderer discardPendingSubmits]; else [epochRenderer setFileLanczosScaler:same];
        BOOL next=[epochRenderer renderPixelBuffer:source ptsUs:202 presented:nil];usleep(100000);
        bool onlyOne=gSlowCalls.load()==1;
        void (^oldFinish)(void)=gFinishSlow;gFinishSlow=nil;if(oldFinish)oldFinish();
        bool secondStarted=dispatch_semaphore_wait(gSlowStarted,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0;
        bool newPTS=gSlowCalls.load()==2&&gSlowLatestPTS.load()==202;
        void (^newFinish)(void)=gFinishSlow;gFinishSlow=nil;if(newFinish)newFinish();
        [epochRenderer setFileLanczosScaler:nil];[epochRenderer discardPendingSubmits];
        epochsOK &= first&&firstStarted&&next&&onlyOne&&secondStarted&&newPTS;
    }
    // Original mode must never submit the enhanced/synthetic buffer to the scaler;
    // compare mode must still scale the right-hand result. No window/drawable is created.
    CAMetalLayer *viewLayer=[CAMetalLayer layer]; viewLayer.drawableSize=CGSizeMake(64,64);
    SPMetalRenderer *viewRenderer=[[SPMetalRenderer alloc] initWithLayer:viewLayer logId:996];
    TrackingLanczos *viewScaler=[[TrackingLanczos alloc] initWithDevice:viewRenderer.device width:64 height:64 error:&error];
    CVPixelBufferRef baseline=NULL;
    BOOL baselineCreated=CVPixelBufferCreate(NULL,16,16,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,(__bridge CFDictionaryRef)attrs,&baseline)==kCVReturnSuccess;
    gStarted.store(0); gCompleted.store(0);
    [viewRenderer setFileLanczosScaler:viewScaler]; [viewRenderer setFileViewMode:1];
    BOOL originalAccepted=baselineCreated && [viewRenderer renderPixelBuffer:source original:baseline ptsUs:303 presented:nil];
    usleep(300000); bool originalBypassesScaler=gStarted.load()==0;
    [viewRenderer setFileViewMode:2];
    BOOL compareAccepted=baselineCreated && [viewRenderer renderPixelBuffer:source original:baseline ptsUs:404 presented:nil];
    for(int i=0;i<100 && gCompleted.load()==0;i++)usleep(20000);
    bool compareScalesEnhanced=gStarted.load()>0 && gCompleted.load()>0;
    [viewRenderer setFileLanczosScaler:nil]; [viewRenderer discardPendingSubmits];
    if(baseline)CVPixelBufferRelease(baseline);
    CVPixelBufferRelease(source);
    TrackingAppleSR *apple=[[TrackingAppleSR alloc] initWithSourceWidth:1280 sourceHeight:720 outputWidth:1920 outputHeight:1080 error:&error];
    CVPixelBufferRef srSource=NULL;
    BOOL created=CVPixelBufferCreate(NULL,1280,720,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,(__bridge CFDictionaryRef)attrs,&srSource)==kCVReturnSuccess;
    if(srSource) {
        CVBufferSetAttachment(srSource,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(srSource,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(srSource,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    }
    CAMetalLayer *srLayer=[CAMetalLayer layer]; srLayer.drawableSize=CGSizeMake(64,64);
    SPMetalRenderer *srRenderer=[[SPMetalRenderer alloc] initWithLayer:srLayer logId:993];
    BOOL srAccepted=NO;
    if (apple && created && srRenderer) {
        [srRenderer setFileLanczosScaler:apple]; srAccepted=[srRenderer renderPixelBuffer:srSource ptsUs:1234567 presented:nil];
        for(int i=0;i<500 && gAppleCompleted.load()==0;i++)usleep(20000);
        [srRenderer setFileLanczosScaler:nil]; [srRenderer discardPendingSubmits];
    }
    if(srSource)CVPixelBufferRelease(srSource);
    bool srOK=srAccepted && gAppleCompleted.load()>0 && gObservedPTS.load()==1234567;
    CAMetalLayer *videoLayer=[CAMetalLayer layer];videoLayer.drawableSize=CGSizeMake(64,64);
    SPMetalRenderer *videoRenderer=[[SPMetalRenderer alloc] initWithLayer:videoLayer logId:997];
    TrackingVideoSR *video=[[TrackingVideoSR alloc] initWithSourceWidth:480 sourceHeight:270 outputWidth:1920 outputHeight:1080 error:&error];
    CVPixelBufferRef videoInput=NULL;BOOL madeVideo=CVPixelBufferCreate(NULL,480,270,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,(__bridge CFDictionaryRef)attrs,&videoInput)==kCVReturnSuccess;
    if(videoInput){CVBufferSetAttachment(videoInput,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);CVBufferSetAttachment(videoInput,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);CVBufferSetAttachment(videoInput,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);}
    BOOL videoFirst=NO,videoSecond=NO;gVideoMask.store(0);
    if(video && madeVideo && videoRenderer){[videoRenderer setFileLanczosScaler:video];videoFirst=[videoRenderer renderPixelBuffer:videoInput original:NULL ptsUs:101001 presented:nil];
        for(int i=0;i<500 && !(gVideoMask.load()&1);i++)usleep(10000);[videoRenderer discardPendingSubmits];
        videoSecond=[videoRenderer renderPixelBuffer:videoInput original:videoInput ptsUs:117667 presented:nil];
        for(int i=0;i<500 && !(gVideoMask.load()&2);i++)usleep(10000);[videoRenderer discardPendingSubmits];}
    NSDictionary *videoDiag=videoRenderer.fileScalerDiagnostics;
    bool videoRandomOK=videoFirst&&videoSecond&&gVideoMask.load()==3&&[videoDiag[@"random"] unsignedIntegerValue]>=2&&[videoDiag[@"sequential"] unsignedIntegerValue]==0&&[videoDiag[@"history"] unsignedIntegerValue]==0&&![videoDiag[@"temporal"] boolValue]&&![videoDiag[@"previous"] boolValue]&&![videoDiag[@"previousOutput"] boolValue];
    [videoRenderer setFileLanczosScaler:nil];if(videoInput)CVPixelBufferRelease(videoInput);
    const bool ok=accepted && started>0 && completed>0 && oldAccepted && newAccepted && slowStarted && bounded && replacementCompleted && srOK && epochsOK && originalAccepted && originalBypassesScaler && compareAccepted && compareScalesEnhanced && videoRandomOK;
    printf("{\"ok\":%s,\"rendererAccepted\":%s,\"scaleStarted\":%d,\"scaledOutput64\":%d,\"singleInflightAcrossReplacement\":%s,\"replacementCompleted\":%s,\"appleSRAndPTS\":%s,\"seekAndSameEngineEpochs\":%s,\"originalBypassesScaler\":%s,\"compareScalesEnhanced\":%s,\"videoRandomSourceAndPairedInput\":%s,\"disabledAndDiscarded\":true,\"scope\":\"headless renderer queue and actual GPU scaler; no drawable presentation, file, audio, window or GUI\"}\n",ok?"true":"false",accepted?"true":"false",started,completed,bounded?"true":"false",replacementCompleted?"true":"false",srOK?"true":"false",epochsOK?"true":"false",originalBypassesScaler?"true":"false",compareScalesEnhanced?"true":"false",videoRandomOK?"true":"false");
    return ok?0:4;
}}
