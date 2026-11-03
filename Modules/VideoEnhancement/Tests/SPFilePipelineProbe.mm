#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <AVFoundation/AVFoundation.h>
#import "SPFrameBudgetGenerator.h"
#import "SPFileCadence.hpp"
#import "SPFileLanczosScaler.h"
#import "SPFileMetalFXScaler.h"
#import "SPFileAppleVideoSRScaler.h"
#import "SPFileRifeEngine.h"
#import "SPFileDistilEngine.h"
#import <dlfcn.h>
#include <atomic>
#include <mutex>
#include <vector>
#include <unordered_map>
#include <thread>
#include <unistd.h>
static std::mutex providerPTSLock;
static std::unordered_map<CVPixelBufferRef,int64_t> providerPTS;
static std::atomic<int> providerPTSChecks{0}, providerPTSFailures{0}, precedingChecks{0}, precedingFailures{0};
struct Item { int64_t pts; bool synthetic; bool generated; CVPixelBufferRef buffer; CVPixelBufferRef original; int64_t originalPTS; };
@interface FakeFileProvider : NSObject <SPFileFrameProvider> @end
@implementation FakeFileProvider
- (void)prepareWithSample:(CVPixelBufferRef)sample completion:(void (^)(BOOL,NSString *))completion {(void)sample;completion(YES,@"");}
- (BOOL)submitPrevious:(CVPixelBufferRef)previous current:(CVPixelBufferRef)current previousPTSUs:(int64_t)previousPTSUs currentPTSUs:(int64_t)currentPTSUs phases:(NSArray<NSNumber *> *)phases token:(uint64_t)token completion:(SPFRCPhasesCompletion)completion {
    { std::lock_guard<std::mutex> guard(providerPTSLock);
      auto a=providerPTS.find(previous),b=providerPTS.find(current);
      if(a==providerPTS.end() || b==providerPTS.end() || a->second!=previousPTSUs || b->second!=currentPTSUs) providerPTSFailures.fetch_add(1);
      providerPTSChecks.fetch_add(1);
    }
    CVPixelBufferRetain(previous);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_MSEC),dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSMutableArray *out=[NSMutableArray array];for(NSNumber *phase in phases){(void)phase;[out addObject:[[SPOwnedPixelBuffer alloc] initRetainingBuffer:previous]];}
        CVPixelBufferRelease(previous);completion(token,out,0.020,nil);
    });return YES;
}
- (void)invalidate {}
@end
@interface ThreeSourceFakeProvider : FakeFileProvider @end
@implementation ThreeSourceFakeProvider
- (BOOL)requiresPrecedingSource{return YES;}
- (BOOL)submitPreceding:(CVPixelBufferRef)before previous:(CVPixelBufferRef)a current:(CVPixelBufferRef)b precedingPTSUs:(int64_t)p previousPTSUs:(int64_t)pa currentPTSUs:(int64_t)pb phases:(NSArray<NSNumber *> *)phases token:(uint64_t)token completion:(SPFRCPhasesCompletion)completion {
    {std::lock_guard<std::mutex> guard(providerPTSLock); auto prior=providerPTS.find(before);
     if(prior==providerPTS.end() || prior->second!=p || p>=pa || pa>=pb || llabs((pa-p)-(pb-pa))>2) precedingFailures.fetch_add(1);
     precedingChecks.fetch_add(1);}
    return [super submitPrevious:a current:b previousPTSUs:pa currentPTSUs:pb phases:phases token:token completion:completion];
}
@end
int main(int argc,const char **argv) { @autoreleasepool {
    int cadence=argc>1?atoi(argv[1]):3; if(cadence!=1&&cadence!=2&&cadence!=3&&cadence!=4&&cadence!=5&&cadence!=6&&cadence!=7&&cadence!=8)return 2;
    if (!SPFrameBudgetGenerator.isAvailable) { puts("{\"ok\":false,\"reason\":\"FRC unavailable\"}"); return 2; }
    std::atomic<int64_t> generation{1}; std::atomic<bool> seek{false},first{false},running{true},paused{false},active{false};
    std::atomic<int> mode{SPFrameInterpolationModeDoubleRate}; std::atomic<uint64_t> epoch{1},late{0}; std::atomic<double> hz{240},rate{1};
    sp::SPFrameGeneratorLiveState live; live.generation=&generation;live.seekPending=&seek;live.requestedMode=&mode;live.policyEpoch=&epoch;live.firstFramePending=&first;live.running=&running;live.paused=&paused;live.displayMaximumFPS=&hz;live.playbackRate=&rate;live.activeValue=&active;live.lateDrops=&late;
    const bool distilArg=argc>3 && strcmp(argv[3],"distil")==0;
    const bool probeVideoSR=getenv("ODF_PROBE_VIDEO_SR")!=nullptr;
    const int sourceWidth=distilArg?1280:(probeVideoSR?480:320),sourceHeight=distilArg?720:(probeVideoSR?270:192);
    const bool probeMetalFX=getenv("ODF_PROBE_METALFX")!=nullptr;
    const bool probeScale = getenv("ODF_PROBE_SCALE") != nullptr || probeMetalFX || probeVideoSR;
    const int scaleWidth=sourceWidth*(probeVideoSR?4:2),scaleHeight=sourceHeight*(probeVideoSR?4:2);
    NSError *scaleError=nil; SPFileLanczosScaler *scaler=probeVideoSR ? [[SPFileAppleVideoSRScaler alloc] initWithSourceWidth:sourceWidth sourceHeight:sourceHeight outputWidth:scaleWidth outputHeight:scaleHeight error:&scaleError] : (probeMetalFX ? [[SPFileMetalFXScaler alloc] initWithDevice:MTLCreateSystemDefaultDevice() sourceWidth:sourceWidth sourceHeight:sourceHeight outputWidth:scaleWidth outputHeight:scaleHeight error:&scaleError] : (probeScale ? [[SPFileLanczosScaler alloc] initWithDevice:MTLCreateSystemDefaultDevice() width:scaleWidth height:scaleHeight error:&scaleError] : nil));
    if (probeScale && !scaler) { fprintf(stderr,"scaler: %s\n",scaleError.localizedDescription.UTF8String); return 3; }
    std::atomic<int> scaleSuccess{0}, scaleFailures{0}; auto *scaledCount=&scaleSuccess; auto *scaleFailed=&scaleFailures;
    __block std::vector<Item> *items=new std::vector<Item>(); __block std::mutex *lock=new std::mutex();
    std::atomic<int> liveDepth{0}; std::atomic<int> *depth=&liveDepth; std::atomic<bool> *alive=&running; std::atomic<bool> go{false}; std::atomic<bool> *start=&go; std::atomic<bool> didInterrupt{false}; std::atomic<bool> *interruptFlag=&didInterrupt; bool forceInterrupt=cadence==8;
    std::thread consumer([&]{while(running.load()){if(liveDepth.load()>0)liveDepth.fetch_sub(1);usleep(3000);}});
    SPFrameBudgetGenerator *g=[[SPFrameBudgetGenerator alloc] initWithDevice:MTLCreateSystemDefaultDevice() logId:999 liveState:live
        enqueue:^sp::PushResult(CVPixelBufferRef buffer,int64_t pts,int64_t gen,BOOL synth,BOOL generated,CVPixelBufferRef original,int64_t originalPTS,uint64_t policy,uint64_t interrupt){
            (void)gen;(void)original;(void)originalPTS;(void)policy;(void)interrupt;
            if (scaler) {
                dispatch_semaphore_t done=dispatch_semaphore_create(0); __block BOOL valid=NO;
                OSType inputFormat=CVPixelBufferGetPixelFormatType(buffer);
                BOOL accepted=[scaler submit:buffer ptsUs:pts completion:^(CVPixelBufferRef output, NSError *failure) {
                    valid=output && !failure && CVPixelBufferGetWidth(output)==(size_t)scaleWidth && CVPixelBufferGetHeight(output)==(size_t)scaleHeight && CVPixelBufferGetPixelFormatType(output)==inputFormat;
                    if (output) CVPixelBufferRelease(output); dispatch_semaphore_signal(done);
                }];
                if (!accepted || dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))!=0 || !valid) scaleFailed->fetch_add(1);
                else scaledCount->fetch_add(1);
            }
            if(forceInterrupt && pts>=50050 && !interruptFlag->exchange(true))return sp::PushResult::Interrupted;while(!start->load() && alive->load())usleep(1000);while(depth->load()>=8 && alive->load())usleep(1000);if(!alive->load())return sp::PushResult::Interrupted;{std::lock_guard<std::mutex> l(*lock);items->push_back({pts,(bool)synth,(bool)generated,buffer,original,originalPTS});}depth->fetch_add(1);CVPixelBufferRelease(buffer);return sp::PushResult::Pushed;
        } status:^(NSString *s,BOOL on,int code){fprintf(stderr,"status code=%d active=%d text=%s\n",code,on,s.UTF8String?:"");} queueDepth:^size_t{return (size_t)depth->load();}];
    sp::SPFrameGeneratorMediaInfo info;info.videoWidth=sourceWidth;info.videoHeight=sourceHeight;info.videoFps=24;info.frameIntervalUs=41667;
    [g resetForNewMediaWithInfo:info]; BOOL threeProvider=argc>3 && strcmp(argv[3],"three")==0;
    BOOL fakeProvider=argc>3 && (strcmp(argv[3],"fake")==0 || threeProvider);
    BOOL realRife=argc>3 && strncmp(argv[3],"rife-v4.",8)==0;
    BOOL realLow=argc>3 && strcmp(argv[3],"apple-lowlatency")==0;
    BOOL realDistil=argc>3 && strcmp(argv[3],"distil")==0;
    if(fakeProvider)[g setPendingFileProvider:threeProvider ? [ThreeSourceFakeProvider new] : [FakeFileProvider new]];
    if(realRife || realLow || realDistil){
        const char *path=getenv("ODF_TEST_DEBUG_DYLIB"),*app=getenv("ODF_TEST_RESOURCE_APP");
        if(!path||!app||!dlopen(path,RTLD_NOW|RTLD_LOCAL)){fprintf(stderr,"debug dylib unavailable: %s\n",dlerror());return 3;}
        Class type=NSClassFromString(realLow?@"SPFileLowLatencyEngine":(realDistil?@"SPFileDistilEngine":@"SPFileRifeEngine"));NSBundle *bundle=[NSBundle bundleWithPath:[NSString stringWithUTF8String:app]];
        id<SPFileFrameProvider> real=realLow?(id)[type new]:(realDistil?(id)[(SPFileDistilEngine *)[type alloc] initWithResourceBundle:bundle]:(id)[[type alloc] initWithModelID:[NSString stringWithUTF8String:argv[3]] quality:@"fast" resourceBundle:bundle]);
        NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};CVPixelBufferRef sample=NULL;
        if(!real||CVPixelBufferCreate(NULL,sourceWidth,sourceHeight,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,(__bridge CFDictionaryRef)attrs,&sample)!=kCVReturnSuccess)return 3;
        CVBufferSetAttachment(sample,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(sample,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(sample,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
        dispatch_semaphore_t ready=dispatch_semaphore_create(0);__block BOOL prepared=NO;__block NSString *reason=@"";
        [real prepareWithSample:sample completion:^(BOOL ok,NSString *message){prepared=ok;reason=message;dispatch_semaphore_signal(ready);}];
        if(dispatch_semaphore_wait(ready,dispatch_time(DISPATCH_TIME_NOW,60*NSEC_PER_SEC))!=0||!prepared){fprintf(stderr,"provider prepare: %s\n",reason.UTF8String);CVPixelBufferRelease(sample);return 3;}
        CVPixelBufferRelease(sample);[g setPendingFileProvider:real];
    }
    if(![g configureFileCadenceMode:cadence==8?1:(cadence>=5?3:cadence) numerator:60000 denominator:1001])return 2;[g applyModeReset:SPFrameInterpolationModeDoubleRate];
    if(cadence==8){
        for(int i=0;i<4;i++){
            NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{}};CVPixelBufferRef b=NULL;
            if(CVPixelBufferCreate(NULL,320,192,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,(__bridge CFDictionaryRef)attrs,&b)!=kCVReturnSuccess)return 2;
            sp::SPFrameGeneratorSubmitContext c;c.ptsUs=(1000000LL*i+12)/24;c.generation=1;
            if([g submitSourceBuffer:b context:c]!=sp::PushResult::Pushed)CVPixelBufferRelease(b);
        }
        go.store(true);for(int i=0;i<100&&!didInterrupt.load();i++)usleep(10000);
        [g applyModeReset:SPFrameInterpolationModeOff];
        __block bool recovered=false;[g drainReturnedFramesWithHandler:^(CVPixelBufferRef frame,int64_t pts,int64_t gen){if(pts==41667&&gen==1)recovered=true;CVPixelBufferRelease(frame);}];
        bool hit=didInterrupt.load();running.store(false);consumer.join();[g shutdown];delete items;delete lock;
        bool ok=hit&&recovered;printf("{\"ok\":%s,\"interrupted\":%s,\"unscheduledSourceReinjected\":%s}\n",ok?"true":"false",hit?"true":"false",recovered?"true":"false");return ok?0:1;
    }
    if(cadence>=5){
        go.store(true);if(cadence==6)paused.store(true);
        NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{}}; CVPixelBufferRef b=NULL;
        if(CVPixelBufferCreate(NULL,320,192,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,(__bridge CFDictionaryRef)attrs,&b)!=kCVReturnSuccess)return 2;
        sp::SPFrameGeneratorSubmitContext c;c.ptsUs=1000000;c.generation=1;
        auto submitted=[g submitSourceBuffer:b context:c];if(submitted!=sp::PushResult::Pushed)CVPixelBufferRelease(b);
        usleep(120000);
        if(cadence==7)[g breakPairChain];
        if(cadence!=5)usleep(120000);
        [g applyModeReset:SPFrameInterpolationModeOff];
        __block int returned=0;[g drainReturnedFramesWithHandler:^(CVPixelBufferRef frame,int64_t pts,int64_t gen){if(pts==1000000&&gen==1)returned++;CVPixelBufferRelease(frame);}];
        size_t count;{std::lock_guard<std::mutex> l(*lock);count=items->size();}
        running.store(false);consumer.join();[g shutdown];delete items;delete lock;
        bool ok=submitted==sp::PushResult::Pushed&&(cadence==5?(returned==1&&count==0):(returned==0&&count==1));
        printf("{\"ok\":%s,\"mode\":%d,\"returned\":%d,\"emitted\":%zu,\"note\":\"synthetic lifecycle probe; no GUI\"}\n",ok?"true":"false",cadence,returned,count);return ok?0:1;
    }
    const int frameCount=realDistil?12:((realRife||realLow)?24:60);int submitted=0;
    std::vector<CVPixelBufferRef> sourceBuffers;std::vector<int64_t> sourcePTS;
    AVAssetReader *reader=nil; AVAssetReaderTrackOutput *videoOutput=nil;
    if (argc>2) {
        AVURLAsset *asset=[AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]] options:nil];
        AVAssetTrack *track=[[asset tracksWithMediaType:AVMediaTypeVideo] firstObject]; NSError *failure=nil;
        if (!track || !(reader=[[AVAssetReader alloc] initWithAsset:asset error:&failure])) return 3;
        videoOutput=[[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES}];
        if (![reader canAddOutput:videoOutput]) return 3; [reader addOutput:videoOutput]; if (![reader startReading]) return 3;
    }
    sp::SPRateRequest request;request.kind=cadence==1?sp::SPRateKind::FixedFPS:sp::SPRateKind::Multiplier;request.multiplier=cadence;request.fps=sp::spMake(60000,1001);
    sp::SPFileCadence expectedClock;expectedClock.reset(request,1);std::vector<sp::SPFileCadenceEvent> expected;
    for(int i=0;i<frameCount;i++){
        CVPixelBufferRef b=NULL; int64_t pts=(1000000LL*i+12)/24;
        if (videoOutput) {
            CMSampleBufferRef sample=[videoOutput copyNextSampleBuffer];
            if (!sample) { fprintf(stderr,"decoded source ended at %d\n",i); break; }
            CVImageBufferRef image=CMSampleBufferGetImageBuffer(sample); CMTime time=CMSampleBufferGetPresentationTimeStamp(sample);
            if (!image || !CMTIME_IS_NUMERIC(time) || CVPixelBufferGetWidth(image)!=(size_t)sourceWidth || CVPixelBufferGetHeight(image)!=(size_t)sourceHeight) { CFRelease(sample); return 3; }
            b=CVPixelBufferRetain(image); pts=CMTimeConvertScale(time,1000000,kCMTimeRoundingMethod_RoundHalfAwayFromZero).value; CFRelease(sample);
        } else {
            NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};
            if(CVPixelBufferCreate(NULL,320,192,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,(__bridge CFDictionaryRef)attrs,&b)!=kCVReturnSuccess)return 2;
            CVPixelBufferLockBaseAddress(b,0);for(int p=0;p<2;p++)memset(CVPixelBufferGetBaseAddressOfPlane(b,p),p?128:(40+i%100),CVPixelBufferGetBytesPerRowOfPlane(b,p)*CVPixelBufferGetHeightOfPlane(b,p));auto y=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(b,0); auto pitch=CVPixelBufferGetBytesPerRowOfPlane(b,0); int sx=20+(i*2)%200;
            for(int yy=35;yy<115;yy++)for(int xx=sx;xx<sx+50;xx++)y[yy*pitch+xx]=(uint8_t)(((xx+yy)%12<6)?220:90);
            CVPixelBufferUnlockBaseAddress(b,0);
        }
        sourceBuffers.push_back(CVPixelBufferRetain(b));sourcePTS.push_back(pts);
        { std::lock_guard<std::mutex> guard(providerPTSLock); providerPTS[b]=pts; }
        sp::SPFrameGeneratorSubmitContext c;c.ptsUs=pts;c.generation=1;
        auto planned=expectedClock.push(c.ptsUs,(uint64_t)i+1,1);for(const auto &e:planned.events)expected.push_back(e);
        auto result=[g submitSourceBuffer:b context:c];if(result==sp::PushResult::Pushed)submitted++;else CVPixelBufferRelease(b);
    }
    usleep(700000);go.store(true);[g breakPairChain];
    for(int i=0;i<((realRife||realLow||realDistil)?1200:100);i++){usleep(50000);if([g pendingSourceFrameCount]==0)break;}
    running.store(false);consumer.join();[g applyModeReset:SPFrameInterpolationModeOff];[g shutdown];
    std::vector<Item> result;{std::lock_guard<std::mutex> l(*lock);result=*items;}delete items;delete lock;
    bool monotonic=true;for(size_t i=1;i<result.size();i++)if(result[i].pts<=result[i-1].pts)monotonic=false;
    int generated=0,held=0;for(auto x:result){generated+=x.generated;held+=x.synthetic&&!x.generated;}
    bool complete=result.size()==expected.size(), ptsMatch=true, identity=true, baseline=true; size_t j=0; int sourceCount=0;
    for (const auto &item : result) {
        sourceCount += !item.synthetic;
        // Legacy X2 may omit late synthetic frames and rounds a half-microsecond down.
        // Extended cadence emits every planned slot, including explicit holds.
        while (j<expected.size() && expected[j].ptsUs < item.pts-(cadence==2?1:0)) ++j;
        if (j==expected.size() || llabs(item.pts-expected[j].ptsUs)>(cadence==2?1:0)) { ptsMatch=false; break; }
        identity = identity && (item.synthetic==(expected[j].action!=sp::SPScheduleAction::PresentSource));
        size_t index=(size_t)expected[j].frameA;
        baseline &= index>0 && index<=sourceBuffers.size() && (item.synthetic ? (item.original==sourceBuffers[index-1] && item.originalPTS==sourcePTS[index-1]) : (!item.original && item.buffer==sourceBuffers[index-1]));
        ++j;
    }
    bool providerPTSValid=!fakeProvider || (providerPTSChecks.load()>0 && providerPTSFailures.load()==0);
    bool precedingValid=!threeProvider || (precedingChecks.load()>0 && precedingFailures.load()==0 && held>=1);
    NSDictionary *diag=probeVideoSR ? ((SPFileAppleVideoSRScaler *)scaler).submissionDiagnostics : nil;
    bool randomOnly=!probeVideoSR || ([diag[@"random"] unsignedIntegerValue]==scaleSuccess.load() && [diag[@"sequential"] unsignedIntegerValue]==0 && [diag[@"history"] unsignedIntegerValue]==0 && ![diag[@"temporal"] boolValue] && ![diag[@"previous"] boolValue] && ![diag[@"previousOutput"] boolValue]);
    bool ok=randomOnly&&precedingValid&&providerPTSValid&&submitted==frameCount&&((cadence==2 && !fakeProvider && !realRife && !realLow && !realDistil) ? sourceCount==frameCount : complete)&&monotonic&&ptsMatch&&identity&&baseline&&generated>0 && (!probeScale || (scaleFailures.load()==0 && scaleSuccess.load()==(int)result.size()));
    printf("{\"ok\":%s,\"mode\":%d,\"provider\":\"%s\",\"submitted\":%d,\"outputs\":%zu,\"scheduled\":%zu,\"sourceOutputs\":%d,\"generated\":%d,\"held\":%d,\"scaled\":%d,\"scaleFailures\":%d,\"monotonic\":%s,\"ptsValid\":%s,\"planIdentity\":%s,\"sourceBaselineIdentity\":%s,\"providerPTSValid\":%s,\"precedingSourceValid\":%s,\"videoSRRandomOnly\":%s,\"note\":\"generator with controlled lookahead, optional decoded file; X2 can omit synthetic slots and rounds within 1us; not playback, audio sync, UI or performance\"}\n",ok?"true":"false",cadence,(realRife||realLow||realDistil)?argv[3]:(threeProvider?"three-copy":(fakeProvider?"fake-copy":"apple-frc")),submitted,result.size(),expected.size(),sourceCount,generated,held,scaleSuccess.load(),scaleFailures.load(),monotonic?"true":"false",ptsMatch?"true":"false",identity?"true":"false",baseline?"true":"false",fakeProvider?(providerPTSValid?"true":"false"):"null",threeProvider?(precedingValid?"true":"false"):"null",probeVideoSR?(randomOnly?"true":"false"):"null");for(auto buffer:sourceBuffers)CVPixelBufferRelease(buffer);return ok?0:1;
}}
