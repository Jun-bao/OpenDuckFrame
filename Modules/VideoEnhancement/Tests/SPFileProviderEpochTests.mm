#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import "SPFrameBudgetGenerator.h"
#include <atomic>
#include <mutex>
#include <vector>
#include <unistd.h>

static std::atomic<int> gInflight{0},gMaxInflight{0},gStarted{0},gThreeChecks{0},gThreeFailures{0};
@interface EpochProvider : NSObject <SPFileFrameProvider>
@property BOOL fail;
@property BOOL three;
@end
@implementation EpochProvider
- (void)prepareWithSample:(CVPixelBufferRef)sample completion:(void (^)(BOOL,NSString *))completion{(void)sample;completion(YES,@"");}
- (BOOL)submitPrevious:(CVPixelBufferRef)previous current:(CVPixelBufferRef)current previousPTSUs:(int64_t)previousPTSUs currentPTSUs:(int64_t)currentPTSUs phases:(NSArray<NSNumber *> *)phases token:(uint64_t)token completion:(SPFRCPhasesCompletion)completion{
    (void)current;int n=gInflight.fetch_add(1)+1;int old=gMaxInflight.load();while(n>old&&!gMaxInflight.compare_exchange_weak(old,n)){}gStarted.fetch_add(1);CVPixelBufferRetain(previous);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,300*NSEC_PER_MSEC),dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{NSMutableArray *out=[NSMutableArray array];if(!self.fail)for(NSNumber *phase in phases){(void)phase;[out addObject:[[SPOwnedPixelBuffer alloc] initRetainingBuffer:previous]];}CVPixelBufferRelease(previous);gInflight.fetch_sub(1);NSError *error=self.fail?[NSError errorWithDomain:@"epoch-test" code:7 userInfo:@{NSLocalizedDescriptionKey:@"provider deliberately failed"}]:nil;completion(token,self.fail?nil:out,0.3,error);});return YES;
}
- (BOOL)requiresPrecedingSource{return self.three;}
- (BOOL)submitPreceding:(CVPixelBufferRef)p previous:(CVPixelBufferRef)a current:(CVPixelBufferRef)b precedingPTSUs:(int64_t)pp previousPTSUs:(int64_t)pa currentPTSUs:(int64_t)pb phases:(NSArray<NSNumber *> *)phases token:(uint64_t)token completion:(SPFRCPhasesCompletion)completion{
    CFTypeRef x=CVBufferCopyAttachment(p,CFSTR("testGeneration"),NULL),y=CVBufferCopyAttachment(a,CFSTR("testGeneration"),NULL),z=CVBufferCopyAttachment(b,CFSTR("testGeneration"),NULL);
    bool good=x&&y&&z&&CFEqual(x,y)&&CFEqual(y,z)&&pp<pa&&pa<pb;if(x)CFRelease(x);if(y)CFRelease(y);if(z)CFRelease(z);
    gThreeChecks.fetch_add(1);if(!good)gThreeFailures.fetch_add(1);
    return [self submitPrevious:a current:b previousPTSUs:pa currentPTSUs:pb phases:phases token:token completion:completion];
}
- (void)invalidate {}
@end
static CVPixelBufferRef pixel(){NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};CVPixelBufferRef b=NULL;CVPixelBufferCreate(NULL,320,192,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,(__bridge CFDictionaryRef)attrs,&b);return b;}
int main(){@autoreleasepool{
    std::atomic<int64_t> generation{1};std::atomic<bool> seek{false},first{false},running{true},paused{false},active{false};std::atomic<int> mode{SPFrameInterpolationModeDoubleRate};std::atomic<uint64_t> policy{1},late{0};std::atomic<double> hz{240},rate{1};
    sp::SPFrameGeneratorLiveState live;live.generation=&generation;live.seekPending=&seek;live.requestedMode=&mode;live.policyEpoch=&policy;live.firstFramePending=&first;live.running=&running;live.paused=&paused;live.displayMaximumFPS=&hz;live.playbackRate=&rate;live.activeValue=&active;live.lateDrops=&late;
    std::mutex lock;std::mutex *mutex=&lock;std::vector<int64_t> gens;std::vector<int64_t> *emitted=&gens;std::atomic<int> generated{0};std::atomic<int> *generatedPtr=&generated;__block BOOL sawFailure=NO;
    SPFrameBudgetGenerator *g=[[SPFrameBudgetGenerator alloc] initWithDevice:MTLCreateSystemDefaultDevice() logId:9911 liveState:live enqueue:^sp::PushResult(CVPixelBufferRef b,int64_t pts,int64_t gen,BOOL synth,BOOL real,CVPixelBufferRef original,int64_t originalPTS,uint64_t e,uint64_t interrupt){(void)pts;(void)synth;(void)original;(void)originalPTS;(void)e;(void)interrupt;{std::lock_guard<std::mutex> l(*mutex);emitted->push_back(gen);}if(real)generatedPtr->fetch_add(1);CVPixelBufferRelease(b);return sp::PushResult::Pushed;} status:^(NSString *text,BOOL on,int code){(void)on;(void)code;if([text containsString:@"provider deliberately failed"])sawFailure=YES;} queueDepth:^size_t{return 0;}];
    sp::SPFrameGeneratorMediaInfo info;info.videoWidth=320;info.videoHeight=192;info.videoFps=24;info.frameIntervalUs=41667;[g resetForNewMediaWithInfo:info];BOOL three=getenv("KHUA_TEST_THREE_EPOCH")!=nullptr;EpochProvider *provider=[[EpochProvider alloc] init];provider.three=three;[g setPendingFileProvider:provider];[g configureFileCadenceMode:2 numerator:0 denominator:1];[g applyModeReset:SPFrameInterpolationModeDoubleRate];
    auto push=[&](int64_t pts,int64_t gen){CVPixelBufferRef b=pixel();CVBufferSetAttachment(b,CFSTR("testGeneration"),(__bridge CFNumberRef)@(gen),kCVAttachmentMode_ShouldPropagate);sp::SPFrameGeneratorSubmitContext c;c.ptsUs=pts;c.generation=gen;auto r=[g submitSourceBuffer:b context:c];if(r!=sp::PushResult::Pushed)CVPixelBufferRelease(b);return r==sp::PushResult::Pushed;};
    bool submitted=push(0,1)&&push(41667,1);if(three)submitted &=push(83334,1);for(int i=0;i<100&&gStarted.load()<1;i++)usleep(10000);bool oldStarted=gStarted.load()==1;
    generation.store(2);policy.store(2);[g applyModeReset:SPFrameInterpolationModeDoubleRate];{std::lock_guard<std::mutex> l(lock);gens.clear();}
    submitted &= push(1000000,2)&&push(1041667,2);if(three)submitted &=push(1083334,2);[g breakPairChain];for(int i=0;i<500&&[g pendingSourceFrameCount]>0;i++)usleep(10000);
    bool onlyNew=true;{std::lock_guard<std::mutex> l(lock);for(auto gen:gens)onlyNew &= gen==2;}
    bool activePair=generated.load()>0, bounded=gMaxInflight.load()==1;
    bool chainResetSafe=true;
    if(three) {
        int beforeBreak=gThreeChecks.load();
        submitted &=push(1500000,2)&&push(1541667,2);[g breakPairChain];
        for(int i=0;i<500&&[g pendingSourceFrameCount]>0;i++)usleep(10000);
        bool firstPairHeld=gThreeChecks.load()==beforeBreak;
        submitted &=push(1700000,2)&&push(1741667,2)&&push(1783334,2);[g breakPairChain];
        for(int i=0;i<500&&[g pendingSourceFrameCount]>0;i++)usleep(10000);
        chainResetSafe=firstPairHeld && gThreeChecks.load()==beforeBreak+1 && gThreeFailures.load()==0;
    }
    // Swap to a provider that explicitly fails; no Apple FRC substitution may be counted.
    EpochProvider *bad=[[EpochProvider alloc] init];bad.fail=YES;bad.three=three;[g setPendingFileProvider:bad];policy.store(3);[g applyModeReset:SPFrameInterpolationModeDoubleRate];int before=generated.load();
    submitted &=push(2000000,2)&&push(2041667,2);if(three)submitted &=push(2083334,2);[g breakPairChain];for(int i=0;i<500&&[g pendingSourceFrameCount]>0;i++)usleep(10000);bool explicitFailure=sawFailure&&generated.load()==before;
    running.store(false);[g applyModeReset:SPFrameInterpolationModeOff];[g shutdown];
    bool threeGood=!three || (gThreeChecks.load()>=4 && gThreeFailures.load()==0 && chainResetSafe);
    bool ok=threeGood&&submitted&&oldStarted&&onlyNew&&activePair&&bounded&&explicitFailure;
    printf("{\"ok\":%s,\"oldInFlight\":%s,\"newGenerationOnly\":%s,\"newGenerationGenerated\":%s,\"oneInFlightAcrossSwitch\":%s,\"failureNoFRCFallback\":%s,\"threeSourceGenerationSafe\":%s,\"threeSourceChecks\":%d,\"chainResetSafe\":%s,\"scope\":\"delayed fake provider lifecycle; no real inference, drawable, file UI or audio\"}\n",ok?"true":"false",oldStarted?"true":"false",onlyNew?"true":"false",activePair?"true":"false",bounded?"true":"false",explicitFailure?"true":"false",threeGood?"true":"false",gThreeChecks.load(),chainResetSafe?"true":"false");return ok?0:1;
}}
