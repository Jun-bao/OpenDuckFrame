#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import "SPFrameBudgetGenerator.h"
#import "SPFileRifeEngine.h"
#import <dlfcn.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <mutex>
#include <thread>
#include <vector>

// A service-time control for comparison with the real RIFE provider. Copies
// are explicitly test outputs, never image-quality or RIFE performance evidence.
@interface TimedFileProvider : NSObject <SPFileFrameProvider>
@property double milliseconds;
@end
@implementation TimedFileProvider
- (void)prepareWithSample:(CVPixelBufferRef)sample completion:(void (^)(BOOL,NSString *))completion { completion(sample != NULL,@""); }
- (BOOL)submitPrevious:(CVPixelBufferRef)a current:(CVPixelBufferRef)b previousPTSUs:(int64_t)pa currentPTSUs:(int64_t)pb phases:(NSArray<NSNumber *> *)phases token:(uint64_t)token completion:(SPFRCPhasesCompletion)completion {
    (void)b; (void)pa; (void)pb; CVPixelBufferRetain(a);
    double sec=self.milliseconds/1000;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(sec*NSEC_PER_SEC)),dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSMutableArray *out=[NSMutableArray array];
        for (NSNumber *phase in phases) { (void)phase; [out addObject:[[SPOwnedPixelBuffer alloc] initRetainingBuffer:a]]; }
        CVPixelBufferRelease(a); completion(token,out,sec,nil);
    }); return YES;
}
- (void)invalidate {}
@end

@interface ObservedFileProvider : NSObject <SPFileFrameProvider>
@property(nonatomic,strong) id<SPFileFrameProvider> base;
@property(nonatomic,strong) NSLock *lock;
@property(nonatomic,strong) NSMutableArray<NSNumber *> *jobTimes;
@end
@implementation ObservedFileProvider
- (instancetype)init { if((self=[super init])){_lock=[NSLock new];_jobTimes=[NSMutableArray array];}return self; }
- (void)prepareWithSample:(CVPixelBufferRef)sample completion:(void (^)(BOOL,NSString *))completion { [self.base prepareWithSample:sample completion:completion]; }
- (BOOL)submitPrevious:(CVPixelBufferRef)a current:(CVPixelBufferRef)b previousPTSUs:(int64_t)pa currentPTSUs:(int64_t)pb phases:(NSArray<NSNumber *> *)phases token:(uint64_t)token completion:(SPFRCPhasesCompletion)completion {
    double start=CACurrentMediaTime();
    return [self.base submitPrevious:a current:b previousPTSUs:pa currentPTSUs:pb phases:phases token:token completion:^(uint64_t t,NSArray<SPOwnedPixelBuffer *> *out,double latency,NSError *error){
        [self.lock lock];[self.jobTimes addObject:@((CACurrentMediaTime()-start)*1000)];[self.lock unlock];
        completion(t,out,latency,error);
    }];
}
- (void)invalidate { [self.base invalidate]; }
@end

static CVPixelBufferRef frame(int width,int height,int index) {
    CVPixelBufferRef b=NULL;
    NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};
    if(CVPixelBufferCreate(NULL,width,height,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,(__bridge CFDictionaryRef)attrs,&b)!=kCVReturnSuccess)return NULL;
    CVBufferSetAttachment(b,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(b,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(b,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    CVPixelBufferLockBaseAddress(b,0);
    for(int p=0;p<2;p++)memset(CVPixelBufferGetBaseAddressOfPlane(b,p),p?128:40,CVPixelBufferGetBytesPerRowOfPlane(b,p)*CVPixelBufferGetHeightOfPlane(b,p));
    uint8_t *y=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(b,0);size_t stride=CVPixelBufferGetBytesPerRowOfPlane(b,0);
    int left=(index*5)%(width-80);
    for(int row=height/3;row<height*2/3;row++)for(int x=left;x<left+80;x++)y[row*stride+x]=((x+row)%16<8)?220:90;
    CVPixelBufferUnlockBaseAddress(b,0);return b;
}

struct Emitted { int64_t pts; double time,admitted; bool synthetic,generated; };
int main(int argc,const char **argv) { @autoreleasepool {
    if(argc!=5){fprintf(stderr,"usage: probe off|fake|rife WIDTH HEIGHT FRAMES (fake uses ODF_PROBE_JOB_MS; rife uses ODF_TEST_DEBUG_DYLIB/ODF_TEST_RESOURCE_APP)\n");return 2;}
    NSString *kind=[NSString stringWithUTF8String:argv[1]];
    int width=atoi(argv[2]),height=atoi(argv[3]),count=atoi(argv[4]);
    bool off=[kind isEqualToString:@"off"],real=[kind isEqualToString:@"rife"];
    if(width<100||height<100||count<24||(!off&&!real&&![kind isEqualToString:@"fake"]))return 2;
    id<SPFileFrameProvider> provider=nil;
    if(real){
        const char *dylib=getenv("ODF_TEST_DEBUG_DYLIB"),*app=getenv("ODF_TEST_RESOURCE_APP");
        if(!dylib||!app||!dlopen(dylib,RTLD_NOW|RTLD_LOCAL)){fprintf(stderr,"RIFE load failed: %s\n",dlerror());return 3;}
        Class cls=NSClassFromString(@"SPFileRifeEngine");
        provider=(id)[[cls alloc] initWithModelID:@"rife-v4.25" quality:@"fast" resourceBundle:[NSBundle bundleWithPath:[NSString stringWithUTF8String:app]]];
    }else if(!off){TimedFileProvider *p=[TimedFileProvider new];p.milliseconds=atof(getenv("ODF_PROBE_JOB_MS")?:"20");provider=p;}
    ObservedFileProvider *observed=nil;
    if(provider){observed=[ObservedFileProvider new];observed.base=provider;provider=observed;}
    CVPixelBufferRef sample=frame(width,height,0);if(!sample||(!off&&!provider))return 3;
    if(provider){
        dispatch_semaphore_t done=dispatch_semaphore_create(0);__block BOOL ready=NO;__block NSString *reason=@"";
        [provider prepareWithSample:sample completion:^(BOOL ok,NSString *message){ready=ok;reason=message;dispatch_semaphore_signal(done);}];
        if(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC))||!ready){fprintf(stderr,"prepare failed: %s\n",reason.UTF8String);return 3;}
    }
    CVPixelBufferRelease(sample);
    std::atomic<int64_t> generation{1};std::atomic<bool> seek{false},first{false},running{true},paused{false},active{false};
    std::atomic<int> mode{SPFrameInterpolationModeDoubleRate};std::atomic<uint64_t> epoch{1},late{0};std::atomic<double> hz{60},rate{1};
    sp::SPFrameGeneratorLiveState live;live.generation=&generation;live.seekPending=&seek;live.requestedMode=&mode;live.policyEpoch=&epoch;live.firstFramePending=&first;live.running=&running;live.paused=&paused;live.displayMaximumFPS=&hz;live.playbackRate=&rate;live.activeValue=&active;live.lateDrops=&late;
    std::mutex mutex;std::vector<Emitted> emitted;auto *lock=&mutex;auto *out=&emitted;
    const double start=CACurrentMediaTime(),playout=start+0.2;
    SPFrameGeneratorEnqueue enqueue=^sp::PushResult(CVPixelBufferRef b,int64_t pts,int64_t gen,BOOL synthetic,BOOL generated,CVPixelBufferRef original,int64_t originalPTS,uint64_t policy,uint64_t interrupt){
        (void)gen;(void)original;(void)originalPTS;(void)policy;(void)interrupt;
        const double admitted=CACurrentMediaTime();
        double wait=playout+double(pts)/1e6-CACurrentMediaTime();
        if(wait>0)std::this_thread::sleep_for(std::chrono::duration<double>(wait));
        {std::lock_guard<std::mutex> guard(*lock);out->push_back({pts,CACurrentMediaTime(),admitted,(bool)synthetic,(bool)generated});}
        CVPixelBufferRelease(b);return sp::PushResult::Pushed;
    };
    SPFrameBudgetGenerator *g=off?nil:[[SPFrameBudgetGenerator alloc] initWithDevice:MTLCreateSystemDefaultDevice() logId:880 liveState:live enqueue:enqueue status:^(NSString *s,BOOL on,int code){(void)s;(void)on;(void)code;} queueDepth:^size_t{return 4;}];
    if(g){sp::SPFrameGeneratorMediaInfo info;info.videoWidth=width;info.videoHeight=height;info.videoFps=24;info.frameIntervalUs=41667;[g resetForNewMediaWithInfo:info];[g setPendingFileProvider:provider];if(![g configureFileCadenceMode:2 numerator:0 denominator:1])return 4;[g applyModeReset:SPFrameInterpolationModeDoubleRate];}
    int submitted=0;
    for(int i=0;i<count;i++){@autoreleasepool{
        const int64_t pts=(1000000LL*i+12)/24;
        double wait=start+double(pts)/1e6-CACurrentMediaTime();if(wait>0)std::this_thread::sleep_for(std::chrono::duration<double>(wait));
        CVPixelBufferRef b=frame(width,height,i);if(!b)return 4;
        if(off){enqueue(b,pts,1,NO,NO,NULL,pts,1,0);submitted++;}
        else{sp::SPFrameGeneratorSubmitContext context;context.ptsUs=pts;context.generation=1;if([g submitSourceBuffer:b context:context]==sp::PushResult::Pushed)submitted++;else CVPixelBufferRelease(b);}
    }}
    if(g){[g breakPairChain];const double end=CACurrentMediaTime()+30;while([g pendingSourceFrameCount]>0&&CACurrentMediaTime()<end)std::this_thread::sleep_for(std::chrono::milliseconds(10));[g shutdown];}
    std::vector<Emitted> result;{std::lock_guard<std::mutex> guard(mutex);result=emitted;}
    int originals=0,generated=0,held=0;bool monotonic=true;double firstSource=0,lastSource=0,maxGap=0,last=0,maxLag=0;
    for(size_t i=0;i<result.size();i++){auto e=result[i];if(i&&e.pts<=result[i-1].pts)monotonic=false;generated+=e.generated;held+=e.synthetic&&!e.generated;if(!e.synthetic){originals++;if(!firstSource)firstSource=e.time;lastSource=e.time;if(last)maxGap=std::max(maxGap,e.time-last);last=e.time;maxLag=std::max(maxLag,e.time-(playout+double(e.pts)/1e6));}}
    double duration=result.size()>1?result.back().time-result.front().time:0;
    // Match the production FPS meter: held copies occupy enqueue slots, but
    // cannot count as additional presented pictures or mask a failed model.
    std::vector<Emitted> effective;
    for(auto e:result)if(!e.synthetic||e.generated)effective.push_back(e);
    double effectiveDuration=effective.size()>1?effective.back().time-effective.front().time:0;
    bool ok=submitted==count&&originals==count&&monotonic&&duration>0;
    NSArray<NSNumber *> *times=@[];
    if(observed){[observed.lock lock];times=[observed.jobTimes sortedArrayUsingSelector:@selector(compare:)];[observed.lock unlock];}
    double p50=times.count?times[(times.count-1)/2].doubleValue:0,p95=times.count?times[(times.count-1)*95/100].doubleValue:0;
    NSDictionary *record=@{@"ok":@(ok),@"provider":kind,@"profile":[NSString stringWithUTF8String:getenv("ODF_PERF_PROFILE")?:"off"],@"width":@(width),@"height":@(height),@"sourcePTS_FPS":@24,@"sourceFrames":@(originals),@"generated":@(generated),@"held":@(held),@"emittedFrames":@(result.size()),@"enqueueFPS":@(duration>0?(result.size()-1)/duration:0),@"effectiveFrames":@(effective.size()),@"emissionFPS":@(effectiveDuration>0?(effective.size()-1)/effectiveDuration:0),@"originalEmissionFPS":@(originals>1?(originals-1)/(lastSource-firstSource):0),@"providerJobs":@(times.count),@"providerJobMsP50":@(p50),@"providerJobMsP95":@(p95),@"maxOriginalGapMs":@(maxGap*1000),@"maxPlayoutLagMs":@(maxLag*1000),@"wallSeconds":@(CACurrentMediaTime()-start),@"scope":@"production file generator and real-time 24fps NV12 source; non-held enqueue rate, paced sink, 4-slot runway; no drawable/physical FPS, codec or audio acceptance"};
    std::vector<double> lags,early,tail;double firstAdmission=-1;
    for(auto e:result)if(!e.synthetic){
        if(firstAdmission<0)firstAdmission=(e.admitted-start)*1000;
        double lag=std::max(0.0,e.time-(playout+double(e.pts)/1e6))*1000;
        lags.push_back(lag);(lags.size()<=size_t(count/2)?early:tail).push_back(lag);
    }
    auto percentile=[](std::vector<double> values,int p){std::sort(values.begin(),values.end());return values.empty()?0:values[(values.size()-1)*p/100];};
    NSMutableDictionary *latencies=[record mutableCopy];
    latencies[@"firstSourceAdmissionMs"]=@(firstAdmission);
    latencies[@"playoutLagP50Ms"]=@(percentile(lags,50));latencies[@"playoutLagP95Ms"]=@(percentile(lags,95));
    latencies[@"firstHalfLagP95Ms"]=@(percentile(early,95));latencies[@"secondHalfLagP95Ms"]=@(percentile(tail,95));
    NSData *json=[NSJSONSerialization dataWithJSONObject:latencies options:NSJSONWritingSortedKeys error:nil];puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    return ok?0:1;
}}
