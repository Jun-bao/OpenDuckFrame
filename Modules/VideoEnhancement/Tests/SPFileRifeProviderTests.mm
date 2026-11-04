#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "SPFileRifeEngine.h"
#import "SPRifeBridge.h"
#import <dlfcn.h>
#include <cmath>
#include <algorithm>
#include <atomic>
#include <memory>

static CVPixelBufferRef make(int center){
    NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};CVPixelBufferRef b=NULL;
    if(CVPixelBufferCreate(NULL,320,192,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,(__bridge CFDictionaryRef)attrs,&b)!=kCVReturnSuccess)return NULL;
    CVBufferSetAttachment(b,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(b,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(b,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    CVPixelBufferLockBaseAddress(b,0);uint8_t *y=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(b,0),*uv=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(b,1);size_t ys=CVPixelBufferGetBytesPerRowOfPlane(b,0),us=CVPixelBufferGetBytesPerRowOfPlane(b,1);
    memset(y,16,ys*192);memset(uv,128,us*96);
    for(int yy=72;yy<120;yy++)for(int xx=center-24;xx<center+24;xx++)y[yy*ys+xx]=(((xx-center)/4)^(yy/4))&1?235:40;
    CVPixelBufferUnlockBaseAddress(b,0);return b;
}
static double center(CVPixelBufferRef b){CVPixelBufferLockBaseAddress(b,kCVPixelBufferLock_ReadOnly);const uint8_t *y=(const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(b,0);size_t stride=CVPixelBufferGetBytesPerRowOfPlane(b,0);double sum=0,weight=0;for(int row=50;row<142;row+=2)for(int x=0;x<320;x+=2){int value=std::max(0,int(y[row*stride+x])-30);sum+=x*value;weight+=value;}CVPixelBufferUnlockBaseAddress(b,kCVPixelBufferLock_ReadOnly);return weight?sum/weight:-1;}
static NSArray<SPOwnedPixelBuffer *> *infer(id<SPFileFrameProvider> provider,CVPixelBufferRef a,CVPixelBufferRef b,int64_t pa,int64_t pb){
    dispatch_semaphore_t done=dispatch_semaphore_create(0);__block NSArray<SPOwnedPixelBuffer *> *frames=nil;
    BOOL accepted=[provider submitPrevious:a current:b previousPTSUs:pa currentPTSUs:pb phases:@[@0.5] token:90 completion:^(uint64_t t,NSArray<SPOwnedPixelBuffer *> *out,double sec,NSError *error){(void)t;(void)sec;frames=error?nil:out;dispatch_semaphore_signal(done);}];
    return accepted&&dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC))==0?frames:nil;
}
static double psnr(CVPixelBufferRef a,CVPixelBufferRef b){
    if(!a||!b||CVPixelBufferGetWidth(a)!=CVPixelBufferGetWidth(b)||CVPixelBufferGetHeight(a)!=CVPixelBufferGetHeight(b))return 0;
    CVPixelBufferLockBaseAddress(a,kCVPixelBufferLock_ReadOnly);CVPixelBufferLockBaseAddress(b,kCVPixelBufferLock_ReadOnly);
    double squared=0;size_t count=0;
    for(size_t plane=0;plane<2;plane++){
        const uint8_t *left=(const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(a,plane),*right=(const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(b,plane);
        size_t as=CVPixelBufferGetBytesPerRowOfPlane(a,plane),bs=CVPixelBufferGetBytesPerRowOfPlane(b,plane);
        for(size_t y=0;y<CVPixelBufferGetHeightOfPlane(a,plane);y++)for(size_t x=0;x<CVPixelBufferGetWidth(a);x++){int d=int(left[y*as+x])-int(right[y*bs+x]);squared+=d*d;count++;}
    }
    CVPixelBufferUnlockBaseAddress(b,kCVPixelBufferLock_ReadOnly);CVPixelBufferUnlockBaseAddress(a,kCVPixelBufferLock_ReadOnly);
    return squared>0?10*log10(255.0*255.0*count/squared):99;
}
static BOOL submitLive(SPRifeBridge *bridge,CVPixelBufferRef a,CVPixelBufferRef b,uint64_t token,SPFRCPhasesCompletion completion){
    return [bridge submitLivePrevious:a current:b previousID:1 currentID:2 previousPTS:CMTimeMake(0,1000000) currentPTS:CMTimeMake(41667,1000000) generation:1 clockEpoch:1 timesteps:@[@0.5] token:token completion:completion];
}
static bool callbackEpochContract(SPRifeBridge *bridge,CVPixelBufferRef a,CVPixelBufferRef b,NSString *model,NSString *quality){
    struct Counts {std::atomic<int> first{0},cancelled{0},rejected{0};std::atomic<bool> oldRejected{false},recovered{false};};
    auto counts=std::make_shared<Counts>();
    dispatch_semaphore_t entered=dispatch_semaphore_create(0),release=dispatch_semaphore_create(0),cancelled=dispatch_semaphore_create(0),barrier=dispatch_semaphore_create(0);
    // Hold the serial worker inside a completed job. The next accepted job
    // cannot start until after invalidate, so this race is deterministic.
    BOOL first=[bridge submitPrevious:a current:b timesteps:@[@0.5] token:800 completion:^(uint64_t t,NSArray<SPOwnedPixelBuffer *> *out,double sec,NSError *error){
        (void)t;(void)out;(void)sec;(void)error;counts->first++;dispatch_semaphore_signal(entered);dispatch_semaphore_wait(release,DISPATCH_TIME_FOREVER);
    }];
    if(!first||dispatch_semaphore_wait(entered,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC))){dispatch_semaphore_signal(release);return false;}
    BOOL accepted=submitLive(bridge,a,b,801,^(uint64_t t,NSArray<SPOwnedPixelBuffer *> *out,double sec,NSError *error){
        (void)sec;counts->cancelled++;counts->oldRejected=(t==801&&error!=nil&&out.count==0);dispatch_semaphore_signal(cancelled);
    });
    [bridge invalidate];
    BOOL rejected=submitLive(bridge,a,b,802,^(uint64_t t,NSArray<SPOwnedPixelBuffer *> *out,double sec,NSError *error){(void)t;(void)out;(void)sec;(void)error;counts->rejected++;});
    dispatch_semaphore_signal(release);
    if(!accepted||dispatch_semaphore_wait(cancelled,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC)))return false;
    NSError *error=nil;if(![bridge prepareModelID:model quality:quality width:320 height:192 error:&error])return false;
    BOOL submitted=submitLive(bridge,a,b,803,^(uint64_t t,NSArray<SPOwnedPixelBuffer *> *out,double sec,NSError *failure){
        (void)sec;counts->recovered=(t==803&&!failure&&out.count==1);dispatch_semaphore_signal(barrier);
    });
    BOOL completed=submitted&&dispatch_semaphore_wait(barrier,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC))==0;
    return completed&&!rejected&&counts->first==1&&counts->cancelled==1&&counts->rejected==0&&counts->oldRejected&&counts->recovered;
}
int main(int argc,const char **argv){@autoreleasepool{
    if(argc!=6 && argc!=7)return 2;BOOL expectReject=argc==7 && strcmp(argv[6],"reject")==0;void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);if(!lib){fprintf(stderr,"dlopen: %s\n",dlerror());return 3;}
    Class type=NSClassFromString(@"SPFileRifeEngine");NSBundle *bundle=[NSBundle bundleWithPath:[NSString stringWithUTF8String:argv[2]]];
    id<SPFileFrameProvider> provider=(id)[[type alloc] initWithModelID:[NSString stringWithUTF8String:argv[3]] quality:[NSString stringWithUTF8String:argv[5]] resourceBundle:bundle];if(!provider)return 3;
    AVURLAsset *asset=[AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[4]]] options:nil];AVAssetTrack *track=[[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];NSError *error=nil;
    AVAssetReader *reader=track?[[AVAssetReader alloc] initWithAsset:asset error:&error]:nil;AVAssetReaderTrackOutput *output=track?[[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES}]:nil;
    if(!reader||!output||![reader canAddOutput:output])return 4;[reader addOutput:output];if(![reader startReading])return 4;
    CMSampleBufferRef aSample=[output copyNextSampleBuffer],bSample=[output copyNextSampleBuffer];if(!aSample||!bSample)return 4;
    CVPixelBufferRef a=CMSampleBufferGetImageBuffer(aSample),b=CMSampleBufferGetImageBuffer(bSample);CMTime ta=CMSampleBufferGetPresentationTimeStamp(aSample),tb=CMSampleBufferGetPresentationTimeStamp(bSample);
    dispatch_semaphore_t ready=dispatch_semaphore_create(0);__block BOOL prepared=NO;__block NSString *reason=@"";
    [provider prepareWithSample:a completion:^(BOOL ok,NSString *message){prepared=ok;reason=message;dispatch_semaphore_signal(ready);}];
    BOOL prepareCompleted=dispatch_semaphore_wait(ready,dispatch_time(DISPATCH_TIME_NOW,60*NSEC_PER_SEC))==0;
    if(expectReject){BOOL ok=prepareCompleted&&!prepared&&reason.length>0;printf("{\"ok\":%s,\"model\":\"%s\",\"quality\":\"%s\",\"invalidSelectionRejected\":%s}\n",ok?"true":"false",argv[3],argv[5],ok?"true":"false");return ok?0:5;}
    if(!prepareCompleted||!prepared){fprintf(stderr,"prepare: %s\n",reason.UTF8String);return 5;}
    NSArray *phases=@[@0.25,@0.5,@0.75,@(1.0/3.0),@(2.0/3.0)];
    CVPixelBufferRef left=make(148),right=make(172);if(!left||!right)return 5;
    bool phaseOK=true;NSMutableArray *centers=[NSMutableArray array];
    for(NSNumber *phase in phases){
        dispatch_semaphore_t done=dispatch_semaphore_create(0);__block NSArray<SPOwnedPixelBuffer *> *frames=nil;__block NSError *failure=nil;
        BOOL submitted=[provider submitPrevious:left current:right previousPTSUs:0 currentPTSUs:41667 phases:@[phase] token:41 completion:^(uint64_t t,NSArray<SPOwnedPixelBuffer *> *r,double sec,NSError *e){(void)t;(void)sec;frames=r;failure=e;dispatch_semaphore_signal(done);}];
        BOOL complete=submitted&&dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,60*NSEC_PER_SEC))==0;
        double x=complete&&frames.count==1?center(frames[0].buffer):-1;[centers addObject:@(x)];double expected=148+24*phase.doubleValue;
        phaseOK &=complete&&!failure&&frames.count==1&&fabs(x-expected)<=16&&CVPixelBufferGetPixelFormatType(frames[0].buffer)==kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    }
    const int orderedIndices[]={0,3,1,4,2};bool phaseSeparation=centers.count==5;
    for(int i=1;i<5 && phaseSeparation;i++)phaseSeparation = [centers[orderedIndices[i]] doubleValue]-[centers[orderedIndices[i-1]] doubleValue]>=1.0;
    phaseOK &=phaseSeparation;
    // A/B -> B/C must actually hit the stream cache and preserve stateless
    // output quality. Reusing B at another PTS must reset that cache.
    SPRifeBridge *bridge=[(id)provider valueForKey:@"bridge"];
    uint64_t hitsBefore=[bridge.streamDiagnostics[@"hits"] unsignedLongLongValue];
    CVPixelBufferRef next=make(196);
    NSArray<SPOwnedPixelBuffer *> *cached=infer(provider,right,next,41667,83333);
    BOOL cacheHit=[bridge.streamDiagnostics[@"hits"] unsignedLongLongValue]>hitsBefore;
    bridge.liveStreamEnabled=NO;
    NSArray<SPOwnedPixelBuffer *> *reference=infer(provider,right,next,41667,83333);
    bridge.liveStreamEnabled=YES;
    double cachePSNR=cached.count==1&&reference.count==1?psnr(cached[0].buffer,reference[0].buffer):0;
    NSArray<SPOwnedPixelBuffer *> *jumped=infer(provider,left,right,0,41667);
    uint64_t missesBefore=[bridge.streamDiagnostics[@"misses"] unsignedLongLongValue];
    NSArray<SPOwnedPixelBuffer *> *retimed=infer(provider,right,next,0,41667);
    BOOL ptsReset=[bridge.streamDiagnostics[@"misses"] unsignedLongLongValue]>missesBefore;
    bool cacheOK=cacheHit&&cachePSNR>50&&jumped.count==1&&retimed.count==1&&ptsReset;
    // Force the common stream failure path, then require the following pair
    // to rebuild its features and match a stateless reference.
    BOOL seeded=infer(provider,left,right,0,41667).count==1;
    uint64_t fallbackBefore=[bridge.streamDiagnostics[@"fallbackSucceeded"] unsignedLongLongValue];
    [bridge injectStreamFailureForContract];
    NSArray<SPOwnedPixelBuffer *> *fallback=infer(provider,right,next,41667,83333);
    uint64_t missesAfterFallback=[bridge.streamDiagnostics[@"misses"] unsignedLongLongValue];
    CVPixelBufferRef last=make(220);
    NSArray<SPOwnedPixelBuffer *> *following=infer(provider,next,last,83333,125000);
    BOOL fallbackReset=[bridge.streamDiagnostics[@"misses"] unsignedLongLongValue]>missesAfterFallback;
    bridge.liveStreamEnabled=NO;
    NSArray<SPOwnedPixelBuffer *> *followingReference=infer(provider,next,last,83333,125000);
    bridge.liveStreamEnabled=YES;
    double fallbackPSNR=following.count==1&&followingReference.count==1?psnr(following[0].buffer,followingReference[0].buffer):0;
    bool fallbackOK=seeded&&fallback.count==1&&fallbackReset&&fallbackPSNR>50&&[bridge.streamDiagnostics[@"fallbackSucceeded"] unsignedLongLongValue]>fallbackBefore;
    CVPixelBufferRelease(last);
    CVPixelBufferRelease(next);
    dispatch_semaphore_t done=dispatch_semaphore_create(0);__block NSArray<SPOwnedPixelBuffer *> *decoded=nil;__block NSError *failure=nil;
    BOOL submitted=[provider submitPrevious:a current:b previousPTSUs:CMTimeConvertScale(ta,1000000,kCMTimeRoundingMethod_RoundHalfAwayFromZero).value currentPTSUs:CMTimeConvertScale(tb,1000000,kCMTimeRoundingMethod_RoundHalfAwayFromZero).value phases:@[@(1.0/3.0),@(2.0/3.0)] token:42 completion:^(uint64_t t,NSArray<SPOwnedPixelBuffer *> *r,double sec,NSError *e){(void)t;(void)sec;decoded=r;failure=e;dispatch_semaphore_signal(done);}];
    BOOL complete=submitted&&dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,60*NSEC_PER_SEC))==0;
    bool decodedOK=complete&&!failure&&decoded.count==2&&CMTIME_COMPARE_INLINE(tb,>,ta);
    for(SPOwnedPixelBuffer *frame in decoded){
        decodedOK &=CVPixelBufferGetWidth(frame.buffer)==320&&CVPixelBufferGetHeight(frame.buffer)==192&&CVPixelBufferGetPixelFormatType(frame.buffer)==CVPixelBufferGetPixelFormatType(a);
        CFStringRef keys[]={kCVImageBufferYCbCrMatrixKey,kCVImageBufferColorPrimariesKey,kCVImageBufferTransferFunctionKey};
        for(CFStringRef key:keys){CFTypeRef input=CVBufferCopyAttachment(a,key,NULL),outputValue=CVBufferCopyAttachment(frame.buffer,key,NULL);decodedOK &=input&&outputValue&&CFEqual(input,outputValue);if(input)CFRelease(input);if(outputValue)CFRelease(outputValue);}
    }
    bool callbackChecked=strcmp(argv[3],"rife-v4.25")==0&&strcmp(argv[5],"fast")==0;
    bool callbackOK=!callbackChecked||callbackEpochContract(bridge,left,right,[NSString stringWithUTF8String:argv[3]],[NSString stringWithUTF8String:argv[5]]);
    NSData *json=[NSJSONSerialization dataWithJSONObject:centers options:0 error:nil];NSString *str=[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    bool ok=phaseOK&&decodedOK&&cacheOK&&fallbackOK&&callbackOK;printf("{\"ok\":%s,\"model\":\"%s\",\"quality\":\"%s\",\"phaseCenters\":%s,\"phaseOrderedAndSeparated\":%s,\"decodedPair\":%s,\"cacheHitAndParity\":%s,\"cachePSNR\":%.3f,\"retimedSourceResetsCache\":%s,\"fallbackResetsAndMatches\":%s,\"fallbackPSNR\":%.3f,\"callbackEpochContract\":%s,\"decodedPTSUs\":[%lld,%lld],\"scope\":\"real RIFE provider, source continuity, failure recovery and stateless parity, synthetic position probe and one decoded pair; no GUI/drawable/audio\"}\n",ok?"true":"false",argv[3],argv[5],str.UTF8String,phaseSeparation?"true":"false",decodedOK?"true":"false",cacheOK?"true":"false",cachePSNR,ptsReset?"true":"false",fallbackOK?"true":"false",fallbackPSNR,callbackChecked?(callbackOK?"true":"false"):"null",(long long)CMTimeConvertScale(ta,1000000,kCMTimeRoundingMethod_RoundHalfAwayFromZero).value,(long long)CMTimeConvertScale(tb,1000000,kCMTimeRoundingMethod_RoundHalfAwayFromZero).value);
    [provider invalidate];CVPixelBufferRelease(left);CVPixelBufferRelease(right);CFRelease(aSample);CFRelease(bSample);return ok?0:6;
}}
