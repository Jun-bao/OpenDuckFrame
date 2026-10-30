// Headless bridge probe. A standalone Release target links the same bridge
// sources; a Debug-dylib runner is available for development diagnostics.
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <Metal/Metal.h>
#import <CommonCrypto/CommonDigest.h>
#import <dlfcn.h>
#import "SPFRCEngine.h"
#import "SPRifeBridge.h"
#include <chrono>
#include <algorithm>
#include <thread>
#include <vector>
#include <deque>
#include <mutex>
#include <cmath>

using Clock = std::chrono::steady_clock;
static double ms(Clock::time_point a, Clock::time_point b) { return std::chrono::duration<double, std::milli>(b-a).count(); }
struct ProbeSample {
    Clock::time_point begin{}, callback{}, waiter{};
    double bridgeSec = 0;
    uint64_t completionOrder = 0;
    NSArray<SPOwnedPixelBuffer *> *__strong outputs = nil;
    NSError *__strong error = nil;
    BOOL accepted = NO;
};
struct ProbeState {
    std::mutex mutex;
    std::deque<int> ready;
    std::vector<ProbeSample> samples;
    dispatch_semaphore_t readySignal = dispatch_semaphore_create(0);
    uint64_t completionOrder = 0;
    Clock::time_point origin = Clock::now();
    ProbeState() : samples(35) {}
};
static CVPixelBufferRef frame(int shiftPixels, NSString *pattern, OSType format) {
    const int w=2560,h=1440;
    NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};
    CVPixelBufferRef p=nullptr;
    if (CVPixelBufferCreate(kCFAllocatorDefault,w,h,format,(__bridge CFDictionaryRef)attrs,&p)!=kCVReturnSuccess) return nullptr;
    if (CVPixelBufferLockBaseAddress(p,0)!=kCVReturnSuccess) { CVPixelBufferRelease(p); return nullptr; }
    bool planar=CVPixelBufferIsPlanar(p); auto *base=(uint8_t *)(planar?CVPixelBufferGetBaseAddressOfPlane(p,0):CVPixelBufferGetBaseAddress(p));
    size_t stride=planar?CVPixelBufferGetBytesPerRowOfPlane(p,0):CVPixelBufferGetBytesPerRow(p);
    int shift=[pattern isEqualToString:@"static"]?0:shiftPixels;
    for(int y=0;y<h;y++) for(int x=0;x<w;x++) {
        int xx=(x-shift+w)%w; uint8_t v;
        if ([pattern isEqualToString:@"lines"]) {
            int gx=xx%48,gy=y%40; bool edge=(gx==3||gx==4||gx==28||gy==4||gy==20||gy==35) && gx<32 && gy<36;
            v=edge?230:36;
        } else {
            v=(uint8_t)(35+(x*80/w)+(y*35/h));
            if(xx>680&&xx<1180&&y>350&&y<880) v=(uint8_t)(180+(xx%50));
            if(x>930&&x<1120&&y>520&&y<980) v=70; // fixed occluder
        }
        if(planar) base[y*stride+x]=v;
        else { uint8_t *q=base+y*stride+x*4; q[0]=v;q[1]=v;q[2]=v;q[3]=255; }
    }
    if(planar) {
        auto *uv=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(p,1); size_t us=CVPixelBufferGetBytesPerRowOfPlane(p,1);
        for(int y=0;y<h/2;y++) memset(uv+y*us,128,w);
    }
    CVPixelBufferUnlockBaseAddress(p,0); return p;
}
static NSString *digest(CVPixelBufferRef p) {
    if (!p || CVPixelBufferLockBaseAddress(p,kCVPixelBufferLock_ReadOnly)!=kCVReturnSuccess) return @"";
    CC_SHA256_CTX ctx; CC_SHA256_Init(&ctx); bool planar=CVPixelBufferIsPlanar(p);
    for(size_t i=0;i<(planar?CVPixelBufferGetPlaneCount(p):1);i++) {
        size_t h=planar?CVPixelBufferGetHeightOfPlane(p,i):CVPixelBufferGetHeight(p);
        size_t stride=planar?CVPixelBufferGetBytesPerRowOfPlane(p,i):CVPixelBufferGetBytesPerRow(p);
        size_t row=planar?CVPixelBufferGetWidth(p):CVPixelBufferGetWidth(p)*4;
        auto *base=(uint8_t *)(planar?CVPixelBufferGetBaseAddressOfPlane(p,i):CVPixelBufferGetBaseAddress(p));
        for(size_t y=0;y<h;y++) CC_SHA256_Update(&ctx,base+y*stride,(CC_LONG)row);
    }
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(bytes,&ctx);
    CVPixelBufferUnlockBaseAddress(p,kCVPixelBufferLock_ReadOnly);
    NSMutableString *result=[NSMutableString stringWithCapacity:64]; for(auto b:bytes) [result appendFormat:@"%02x",b]; return result;
}
static BOOL dump(CVPixelBufferRef p, NSString *path) {
    if (!p || !path.length || CVPixelBufferLockBaseAddress(p,kCVPixelBufferLock_ReadOnly)!=kCVReturnSuccess) return NO;
    NSMutableData *data=[NSMutableData data]; bool planar=CVPixelBufferIsPlanar(p);
    size_t planes=planar?CVPixelBufferGetPlaneCount(p):1;
    for(size_t i=0;i<planes;i++) {
        size_t h=planar?CVPixelBufferGetHeightOfPlane(p,i):CVPixelBufferGetHeight(p);
        size_t stride=planar?CVPixelBufferGetBytesPerRowOfPlane(p,i):CVPixelBufferGetBytesPerRow(p);
        size_t row=planar?CVPixelBufferGetWidth(p):CVPixelBufferGetWidth(p)*4;
        auto *base=(uint8_t *)(planar?CVPixelBufferGetBaseAddressOfPlane(p,i):CVPixelBufferGetBaseAddress(p));
        for(size_t y=0;y<h;y++) [data appendBytes:base+y*stride length:row];
    }
    CVPixelBufferUnlockBaseAddress(p,kCVPixelBufferLock_ReadOnly);
    return [data writeToFile:path atomically:YES];
}
static NSDictionary *pixelDifference(CVPixelBufferRef a, CVPixelBufferRef b) {
    if(!a || !b || CVPixelBufferGetWidth(a)!=CVPixelBufferGetWidth(b) || CVPixelBufferGetHeight(a)!=CVPixelBufferGetHeight(b) ||
       CVPixelBufferGetPixelFormatType(a)!=kCVPixelFormatType_32BGRA || CVPixelBufferGetPixelFormatType(b)!=kCVPixelFormatType_32BGRA) return @{};
    if(CVPixelBufferLockBaseAddress(a,kCVPixelBufferLock_ReadOnly)!=kCVReturnSuccess) return @{};
    if(CVPixelBufferLockBaseAddress(b,kCVPixelBufferLock_ReadOnly)!=kCVReturnSuccess) { CVPixelBufferUnlockBaseAddress(a,kCVPixelBufferLock_ReadOnly); return @{}; }
    size_t w=CVPixelBufferGetWidth(a),h=CVPixelBufferGetHeight(a),as=CVPixelBufferGetBytesPerRow(a),bs=CVPixelBufferGetBytesPerRow(b);
    auto *ap=(uint8_t *)CVPixelBufferGetBaseAddress(a),*bp=(uint8_t *)CVPixelBufferGetBaseAddress(b);
    double sum=0,sq=0,maxd=0; uint64_t count=0;
    for(size_t y=0;y<h;y+=2) for(size_t x=0;x<w;x+=2) for(int c=0;c<3;c++) { double d=std::abs(int(ap[y*as+4*x+c])-int(bp[y*bs+4*x+c])); sum+=d; sq+=d*d; maxd=std::max(maxd,d); count++; }
    CVPixelBufferUnlockBaseAddress(b,kCVPixelBufferLock_ReadOnly); CVPixelBufferUnlockBaseAddress(a,kCVPixelBufferLock_ReadOnly);
    return @{ @"sampledRGBValues":@(count), @"mae8bit":@(sum/count), @"max8bit":@(maxd), @"psnrDb":@(sq?10*log10(255.0*255.0*count/sq):999) };
}
static int fail(NSString *stage, NSString *message, int code) {
    NSDictionary *result=@{ @"complete":@NO, @"failureStage":stage, @"error":message ?: @"unknown", @"gpuTime":@"unknown" };
    NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
    fwrite(json.bytes,1,json.length,stdout); putchar('\n'); return code;
}
int main(int argc,const char **argv) { @autoreleasepool {
    if(argc!=8) { fprintf(stderr,"usage: probe DYLIB APP rife|frc fast|balanced|normal lines|natural|static unpaced|paced OUTPUT_PREFIX\n"); return 2; }
    if(strcmp(argv[1],"-")!=0 && !dlopen(argv[1],RTLD_NOW|RTLD_LOCAL)) { const char *error=dlerror(); return fail(@"dlopen",error?@(error):@"unknown",2); }
    NSBundle *bundle=[NSBundle bundleWithPath:@(argv[2])]; NSString *engine=@(argv[3]),*quality=@(argv[4]),*pattern=@(argv[5]),*pace=@(argv[6]),*prefix=@(argv[7]);
    BOOL rife=[engine isEqualToString:@"rife"], frc=[engine isEqualToString:@"frc"];
    if(!bundle || (!rife&&!frc) || ![@[@"lines",@"natural",@"static"] containsObject:pattern] || ![@[@"unpaced",@"paced"] containsObject:pace] || (rife && ![@[@"fast",@"balanced"] containsObject:quality]) || (frc && ![quality isEqualToString:@"normal"])) return 2;
    NSString *phaseOption=[NSProcessInfo processInfo].environment[@"CHUANFLOW_PROBE_MULTIPLIER"] ?: @"2";
    NSArray<NSNumber *> *phases = [phaseOption isEqualToString:@"2"] ? @[@0.5] : ([phaseOption isEqualToString:@"3"] ? @[@(1.0/3.0),@(2.0/3.0)] : ([phaseOption isEqualToString:@"4"] ? @[@0.25,@0.5,@0.75] : nil));
    if(!phases) { fprintf(stderr,"invalid CHUANFLOW_PROBE_MULTIPLIER\n"); return 2; }
    NSUInteger selectedPhase=phases.count==3?1:0;
    NSDictionary *environment=[NSProcessInfo processInfo].environment;
    NSString *frcMode=environment[@"CHUANFLOW_FRC_MODE"] ?: @"random1";
    BOOL frcContinuous=[environment[@"CHUANFLOW_FRC_CONTINUOUS"] isEqualToString:@"1"];
    if(frc && (![@[@"random1",@"random2",@"sequential1"] containsObject:frcMode] ||
               frcContinuous != [frcMode isEqualToString:@"sequential1"]))
        return fail(@"mode", @"Set CHUANFLOW_FRC_MODE=random1/random2 with CHUANFLOW_FRC_CONTINUOUS=0, or sequential1 with =1", 2);
    unsigned concurrency=frc && [frcMode isEqualToString:@"random2"] ? 2 : 1;
    OSType format=rife?kCVPixelFormatType_32BGRA:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    std::vector<CVPixelBufferRef> inputs; for(int i=0;i<36;i++) { auto p=frame(i*2,pattern,format); if(!p) return fail(@"input_allocation",[NSString stringWithFormat:@"CVPixelBufferCreate or lock failed at %d",i],3); inputs.push_back(p); }
    NSMutableArray<NSString *> *beforeHashes=[NSMutableArray array];
    for(auto input:inputs) [beforeHashes addObject:digest(input)];
    auto setupStart=Clock::now(); NSError *setupError=nil; SPRifeBridge *rifeBridge=nil; SPFRCEngine *frcEngine=nil;
    if(rife) {
        rifeBridge=[[NSClassFromString(@"SPRifeBridge") alloc] initWithResourceBundle:bundle];
        if(![rifeBridge prepareModelID:@"rife-v4.25" quality:quality width:2560 height:1440 error:&setupError]) rifeBridge=nil;
    } else {
        id<MTLDevice> device=MTLCreateSystemDefaultDevice(); NSString *metalPath=[NSProcessInfo processInfo].environment[@"CHUANFLOW_FRAMEBUDGET_METALLIB"];
        id<MTLLibrary> library=metalPath.length?[device newLibraryWithURL:[NSURL fileURLWithPath:metalPath] error:&setupError]:nil;
        if(metalPath.length && !library) return fail(@"framebudget_library",setupError.localizedDescription,4);
        SPFrameBudgetMetal *metal=[[NSClassFromString(@"SPFrameBudgetMetal") alloc] initWithDevice:device library:library width:2560 height:1440 pixelFormat:format error:&setupError];
        if(metal) frcEngine=[[NSClassFromString(@"SPFRCEngine") alloc] initWithMetal:metal sessions:concurrency outputCapacity:8 quality:SPFRCQualityNormal error:&setupError];
    }
    double setupMs=ms(setupStart,Clock::now());
    if(!rifeBridge&&!frcEngine) return fail(@"setup",setupError.localizedDescription,4);
    if(frc && [environment[@"CHUANFLOW_PROBE_FRC_LEGACY_CASES"] isEqualToString:@"1"]) {
        if(concurrency!=1) return fail(@"legacy_contract_mode",@"legacy contract requires one session",2);
        NSMutableArray *cases=[NSMutableArray array]; BOOL all=YES;
        for(int i=0;i<2;i++) {
            dispatch_semaphore_t done=dispatch_semaphore_create(0); __block NSError *failure=nil; __block NSUInteger count=0;
            BOOL accepted=[frcEngine submitPhasesWithFrameA:inputs[i] frameB:inputs[i+1] ptsA:CMTimeMake(i,60) ptsB:CMTimeMake(i+1,60) phases:@[@0.5] sequential:i==1 token:i+1
                completion:^(uint64_t token,NSArray<SPOwnedPixelBuffer *> *out,double elapsed,NSError *e){(void)token;(void)elapsed;failure=e;count=out.count;dispatch_semaphore_signal(done);}];
            if(accepted && dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,120*NSEC_PER_SEC))!=0) exit(fail(@"legacy_contract_timeout",@"callback timed out",5));
            BOOL ok=accepted && !failure && count==1; all=all && ok;
            [cases addObject:@{ @"sequentialArgument":@(i==1),@"ok":@(ok),@"error":failure.localizedDescription ?: @"" }];
        }
        NSDictionary *diag=[frcEngine continuityDiagnostics];
        BOOL modes=[diag[@"random"] unsignedLongLongValue]==1 && [diag[@"sequential"] unsignedLongLongValue]==1;
        all=all && modes;
        NSDictionary *result=@{ @"scope":@"legacy FRC API behavior under current environment; one session",@"ok":@(all),@"cases":cases,@"diagnostics":diag };
        [frcEngine invalidate]; for(auto p:inputs) CVPixelBufferRelease(p);
        NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil]; fwrite(json.bytes,1,json.length,stdout); putchar('\n'); return all?0:1;
    }
    if(rife && [environment[@"CHUANFLOW_PROBE_CASES"] isEqualToString:@"1"]) {
        if(![environment[@"CHUANFLOW_RIFE_STREAM"] isEqualToString:@"1"]) return fail(@"contract_mode",@"CHUANFLOW_RIFE_STREAM=1 is required",2);
        SPRifeBridge *reference=[[NSClassFromString(@"SPRifeBridge") alloc] initWithResourceBundle:bundle]; NSError *referenceError=nil;
        if(![reference prepareModelID:@"rife-v4.25" quality:quality width:2560 height:1440 error:&referenceError]) return fail(@"reference_prepare",referenceError.localizedDescription,4);
        NSMutableArray *cases=[NSMutableArray array]; __block BOOL all=YES;
        auto infer = ^NSArray<SPOwnedPixelBuffer *> *(SPRifeBridge *bridge, BOOL stream, CVPixelBufferRef a, CVPixelBufferRef b, int ia, int ib, uint64_t generation, uint64_t clock, NSArray<NSNumber *> *steps, NSError **outError) {
            dispatch_semaphore_t done=dispatch_semaphore_create(0); __block NSArray<SPOwnedPixelBuffer *> *outputs=nil; __block NSError *error=nil;
            SPFRCPhasesCompletion cb=^(uint64_t token, NSArray<SPOwnedPixelBuffer *> *out, double elapsed, NSError *e) { (void)token; (void)elapsed; outputs=out; error=e; dispatch_semaphore_signal(done); };
            BOOL accepted=stream ? [bridge submitLivePrevious:a current:b previousID:ia+1 currentID:ib+1 previousPTS:CMTimeMake(ia,60) currentPTS:CMTimeMake(ib,60) generation:generation clockEpoch:clock timesteps:steps token:100+cases.count completion:cb] :
                [bridge submitPrevious:a current:b timesteps:steps token:100+cases.count completion:cb];
            if(!accepted) { if(outError) *outError=[NSError errorWithDomain:@"SPProbe" code:1 userInfo:@{NSLocalizedDescriptionKey:@"submission rejected"}]; return nil; }
            if(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,120*NSEC_PER_SEC))!=0) exit(fail(@"contract_timeout",@"accepted request timed out",5));
            if(outError) *outError=error; return outputs;
        };
        auto run = ^(NSString *name, int ia, int ib, uint64_t gen, uint64_t clock, NSArray<NSNumber *> *steps, NSString *expected) {
            @autoreleasepool {
                NSDictionary *before=[rifeBridge streamDiagnostics]; NSError *e=nil,*refError=nil;
                NSArray<SPOwnedPixelBuffer *> *ref=infer(reference,NO,inputs[ia],inputs[ib],ia,ib,gen,clock,steps,&refError);
                NSArray<SPOwnedPixelBuffer *> *actual=infer(rifeBridge,YES,inputs[ia],inputs[ib],ia,ib,gen,clock,steps,&e);
                NSDictionary *after=[rifeBridge streamDiagnostics];
                NSInteger hits=[after[@"hits"] integerValue]-[before[@"hits"] integerValue];
                NSInteger resets=[after[@"resets"] integerValue]-[before[@"resets"] integerValue];
                BOOL continuity=[expected isEqualToString:@"hit"] ? hits==1 && resets==0 : resets>=1 && hits==0;
                BOOL pass=!e && !refError && actual.count==steps.count && ref.count==steps.count && continuity;
                NSMutableArray *diffs=[NSMutableArray array];
                for(NSUInteger i=0;i<MIN(actual.count,ref.count);i++) { NSDictionary *d=pixelDifference(ref[i].buffer,actual[i].buffer); [diffs addObject:d]; pass=pass && d.count>0; }
                all=all && pass; [cases addObject:@{ @"case":name,@"ok":@(pass),@"phases":steps,@"outputCount":@(actual.count),@"expected":expected,@"hitDelta":@(hits),@"resetDelta":@(resets),@"sampledDifferences":diffs,@"error":e.localizedDescription ?: refError.localizedDescription ?: @"" }];
            }
        };
        run(@"A/B X2",0,1,1,1,@[@0.5],@"reset");
        run(@"B/C X3",1,2,1,1,@[@(1.0/3),@(2.0/3)],@"hit");
        run(@"A/D gap X4",0,3,1,1,@[@0.25,@0.5,@0.75],@"reset");
        run(@"repeat A/D",0,3,1,1,@[@0.5],@"reset");
        run(@"clock change D/E",3,4,1,2,@[@0.5],@"reset");
        run(@"generation change E/F",4,5,2,2,@[@0.5],@"reset");
        run(@"F/G",5,6,2,2,@[@0.5],@"hit");
        BOOL repeatAccepted=[rifeBridge submitLivePrevious:inputs[0] current:inputs[0] previousID:1 currentID:1 previousPTS:CMTimeMake(0,60) currentPTS:CMTimeMake(1,60) generation:1 clockEpoch:1 timesteps:@[@0.5] token:999 completion:^(uint64_t t,NSArray<SPOwnedPixelBuffer *> *o,double d,NSError *e){(void)t;(void)o;(void)d;(void)e;}];
        all=all && !repeatAccepted; [cases addObject:@{ @"case":@"same frame identity rejected",@"ok":@(!repeatAccepted) }];
        CVPixelBufferRef small=nullptr; NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};
        CVPixelBufferCreate(kCFAllocatorDefault,16,16,kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)attrs,&small);
        NSError *dimensionError=nil;
        if(small) { (void)infer(rifeBridge,YES,inputs[0],small,0,4,2,2,@[@0.5],&dimensionError); CVPixelBufferRelease(small); }
        BOOL dimensionFailed=dimensionError!=nil; all=all && dimensionFailed;
        [cases addObject:@{ @"case":@"bad dimensions",@"ok":@(dimensionFailed),@"error":dimensionError.localizedDescription ?: @"allocation failed" }];
        run(@"error recovery B/C",1,2,2,2,@[@0.5],@"reset");
        NSMutableArray<SPOwnedPixelBuffer *> *held=[NSMutableArray array]; NSMutableArray<NSString *> *heldHashes=[NSMutableArray array]; NSError *poolError=nil;
        for(int i=0;i<12;i++) { @autoreleasepool {
            NSError *e=nil; NSArray<SPOwnedPixelBuffer *> *outputs=infer(rifeBridge,YES,inputs[0],inputs[1],0,1,3,3,@[@0.5],&e);
            if(e || outputs.count!=1) { poolError=e; break; }
            [held addObject:outputs[0]]; [heldHashes addObject:digest(outputs[0].buffer)];
        }}
        BOOL exhausted=[poolError.domain isEqualToString:@"app.khuaplayer.rife"] && poolError.code==SPRifeBridgeErrorOutputPoolExhausted;
        BOOL stable=held.count>0; for(NSUInteger i=0;i<held.count;i++) stable=stable && heldHashes[i].length>0 && [heldHashes[i] isEqualToString:digest(held[i].buffer)];
        NSUInteger heldCount=held.count; [held removeAllObjects];
        NSError *recoveryError=nil; NSArray *recovered=infer(rifeBridge,YES,inputs[1],inputs[2],1,2,3,3,@[@0.5],&recoveryError);
        BOOL poolRecovered=!recoveryError && recovered.count==1; recovered=nil;
        all=all && exhausted && stable && poolRecovered;
        [cases addObject:@{ @"case":@"held output pool exhaustion and release",@"ok":@(exhausted&&stable&&poolRecovered),@"heldCount":@(heldCount),@"poolErrorCode":@(poolError.code),@"poolErrorDomain":poolError.domain ?: @"",@"stable":@(stable),@"recovered":@(poolRecovered) }];
        [rifeBridge invalidate]; NSError *prepareError=nil;
        BOOL prepared=[rifeBridge prepareModelID:@"rife-v4.25" quality:quality width:2560 height:1440 error:&prepareError];
        all=all && prepared; [cases addObject:@{ @"case":@"invalidate and reprepare",@"ok":@(prepared),@"error":prepareError.localizedDescription ?: @"" }];
        if(prepared) run(@"post reprepare A/B",0,1,4,4,@[@0.5],@"reset");
        NSError *qualityError=nil,*referenceQualityError=nil; NSString *otherQuality=[quality isEqualToString:@"fast"]?@"balanced":@"fast";
        BOOL qualityChanged=[rifeBridge prepareModelID:@"rife-v4.25" quality:otherQuality width:2560 height:1440 error:&qualityError];
        BOOL referenceQualityChanged=[reference prepareModelID:@"rife-v4.25" quality:otherQuality width:2560 height:1440 error:&referenceQualityError];
        all=all && qualityChanged && referenceQualityChanged;
        [cases addObject:@{ @"case":@"quality switch",@"ok":@(qualityChanged&&referenceQualityChanged),@"error":qualityError.localizedDescription ?: referenceQualityError.localizedDescription ?: @"" }];
        if(qualityChanged&&referenceQualityChanged) run(@"post quality switch A/B",0,1,4,4,@[@0.5],@"reset");
        if([environment[@"CHUANFLOW_PROBE_MODEL_SWITCH"] isEqualToString:@"1"]) {
            NSError *e=nil,*re=nil; BOOL changed=[rifeBridge prepareModelID:@"rife-v4.26" quality:quality width:2560 height:1440 error:&e];
            BOOL referenceChanged=[reference prepareModelID:@"rife-v4.26" quality:quality width:2560 height:1440 error:&re];
            all=all && changed && referenceChanged; [cases addObject:@{ @"case":@"model 4.25 to 4.26",@"ok":@(changed&&referenceChanged),@"error":e.localizedDescription ?: re.localizedDescription ?: @"" }];
            if(changed&&referenceChanged) run(@"post model switch A/B",0,1,5,5,@[@0.5],@"reset");
        }
        BOOL sourceUnchanged=YES; for(NSUInteger i=0;i<inputs.size();i++) sourceUnchanged=sourceUnchanged && beforeHashes[i].length>0 && [beforeHashes[i] isEqualToString:digest(inputs[i])];
        all=all && sourceUnchanged;
        NSDictionary *result=@{ @"scope":@"actual RIFE bridge cache and ownership contract; sampled parity is not subjective quality",@"ok":@(all),@"inputUnchanged":@(sourceUnchanged),@"cases":cases,@"diagnostics":[rifeBridge streamDiagnostics] };
        [reference invalidate]; [rifeBridge invalidate]; for(auto p:inputs) CVPixelBufferRelease(p);
        NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil]; fwrite(json.bytes,1,json.length,stdout); putchar('\n'); return all?0:1;
    }
    NSMutableArray *samples=[NSMutableArray arrayWithCapacity:35];
    for(int i=0;i<35;i++) [samples addObject:[NSNull null]];
    ProbeState state; ProbeState *shared=&state;
    NSUInteger completed=0,failed=0,rejected=0,measuredSuccess=0,maxInflight=0;
    __strong SPOwnedPixelBuffer *selected=nil, *heldOutput=nil;
    NSString *heldBefore=@"";
    double measuredWall=0; Clock::time_point lastCallback{}, lastSubmit{}; BOOL haveLastSubmit=NO;
    auto runBatch = [&](int first, int limit) {
        int next=first, inFlight=0;
        auto batchStart=Clock::now();
        while(next<limit || inFlight>0) {
            while(next<limit && inFlight<(int)concurrency) {
                int i=next++;
                if(i>first && [pace isEqualToString:@"paced"]) std::this_thread::sleep_until(batchStart+std::chrono::microseconds((long long)(i-first)*16667));
                ProbeSample &sample=state.samples[i]; sample.begin=Clock::now();
                double arrival=haveLastSubmit?ms(lastSubmit,sample.begin):0; lastSubmit=sample.begin; haveLastSubmit=YES;
                SPFRCPhasesCompletion cb=^(uint64_t token, NSArray<SPOwnedPixelBuffer *> *outputs, double elapsed, NSError *error) {
                    (void)token;
                    const auto callbackTime=Clock::now();
                    {
                        std::lock_guard<std::mutex> lock(shared->mutex);
                        ProbeSample &entry=shared->samples[i];
                        entry.callback=callbackTime; entry.outputs=outputs; entry.error=error;
                        entry.bridgeSec=elapsed; entry.completionOrder=++shared->completionOrder;
                        shared->ready.push_back(i);
                    }
                    dispatch_semaphore_signal(shared->readySignal);
                };
                BOOL accepted=rife ? [rifeBridge submitLivePrevious:inputs[i] current:inputs[i+1] previousID:i+1 currentID:i+2 previousPTS:CMTimeMake(i,60) currentPTS:CMTimeMake(i+1,60) generation:1 clockEpoch:1 timesteps:phases token:i+1 completion:cb] :
                  [frcEngine submitLivePhasesWithFrameA:inputs[i] frameB:inputs[i+1] ptsA:CMTimeMake(i,60) ptsB:CMTimeMake(i+1,60) frameIDA:i+1 frameIDB:i+2 generation:1 clockEpoch:1 phases:phases token:i+1 completion:cb];
                sample.accepted=accepted;
                if(accepted) { inFlight++; maxInflight=MAX(maxInflight,(NSUInteger)inFlight); }
                else {
                    rejected++;
                    samples[i]=@{ @"index":@(i),@"warmup":@(i<5),@"accepted":@NO,@"valid":@NO,@"submitTimestampMs":@(ms(state.origin,sample.begin)),
                        @"arrivalIntervalMs":@(arrival),@"submitToCallbackMs":[NSNull null],@"submitToWaiterMs":[NSNull null],@"completionOrder":[NSNull null],@"error":@"submission rejected" };
                }
                // Store arrival independently until the callback is drained.
                if(accepted) samples[i]=@{ @"arrivalIntervalMs":@(arrival) };
            }
            if(inFlight==0) continue;
            if(dispatch_semaphore_wait(state.readySignal,dispatch_time(DISPATCH_TIME_NOW,120*NSEC_PER_SEC))!=0)
                exit(fail(@"callback_timeout",@"An accepted request did not complete within 120 seconds",5));
            const auto woke=Clock::now(); int i;
            {
                std::lock_guard<std::mutex> lock(state.mutex);
                i=state.ready.front(); state.ready.pop_front(); state.samples[i].waiter=woke;
            }
            inFlight--;
            ProbeSample &sample=state.samples[i];
            BOOL valid=sample.accepted && !sample.error && sample.outputs.count==phases.count;
            NSMutableArray *outputInfo=[NSMutableArray array]; NSUInteger outputIndex=0;
            for(SPOwnedPixelBuffer *box in sample.outputs) {
                size_t w=CVPixelBufferGetWidth(box.buffer),h=CVPixelBufferGetHeight(box.buffer); valid=valid && w==2560 && h==1440;
                [outputInfo addObject:@{ @"phase":outputIndex<phases.count?phases[outputIndex]:@0, @"size":@[@(w),@(h)], @"format":@(CVPixelBufferGetPixelFormatType(box.buffer)) }]; outputIndex++;
            }
            if(valid) {
                completed++; if(i>=5) measuredSuccess++;
                if(i==4) heldOutput=sample.outputs[selectedPhase];
                if(i==10) selected=sample.outputs[selectedPhase];
            } else failed++;
            const double arrival=[samples[i][@"arrivalIntervalMs"] doubleValue];
            samples[i]=@{ @"index":@(i),@"warmup":@(i<5),@"accepted":@YES,@"valid":@(valid),@"arrivalIntervalMs":@(arrival),
                @"submitTimestampMs":@(ms(state.origin,sample.begin)),@"callbackTimestampMs":@(ms(state.origin,sample.callback)),@"waiterTimestampMs":@(ms(state.origin,sample.waiter)),
                @"submitToCallbackMs":@(ms(sample.begin,sample.callback)),@"submitToWaiterMs":@(ms(sample.begin,sample.waiter)),
                @"bridgeMs":@(sample.bridgeSec*1000),@"callbackRecordOrder":@(sample.completionOrder),@"outputs":outputInfo,@"error":sample.error.localizedDescription ?: @"" };
            if(i>=5 && sample.callback>lastCallback) lastCallback=sample.callback;
            sample.outputs=nil; sample.error=nil;
        }
        return batchStart;
    };
    runBatch(0,5);
    heldBefore=digest(heldOutput.buffer);
    auto measuredStart=runBatch(5,35); auto measuredEnd=Clock::now(); measuredWall=ms(measuredStart,measuredEnd);
    NSString *raw=[prefix stringByAppendingString:@".raw"]; BOOL saved=dump(selected.buffer,raw);
    CVPixelBufferRef gt=frame(21,pattern,format); NSString *gtPath=[prefix stringByAppendingString:@".gt.raw"];
    BOOL gtSaved=phases[selectedPhase].doubleValue==0.5 && dump(gt,gtPath); if(gt) CVPixelBufferRelease(gt);
    NSMutableArray<NSString *> *afterHashes=[NSMutableArray array]; BOOL sourceUnchanged=YES;
    for(NSUInteger i=0;i<inputs.size();i++) { NSString *h=digest(inputs[i]); [afterHashes addObject:h]; sourceUnchanged=sourceUnchanged && h.length>0 && [h isEqualToString:beforeHashes[i]]; }
    NSString *heldAfter=digest(heldOutput.buffer);
    BOOL heldUnchanged=heldBefore.length>0 && [heldBefore isEqualToString:heldAfter];
    NSDictionary *diag=rife?[rifeBridge streamDiagnostics]:[frcEngine continuityDiagnostics];
    if(rife)[rifeBridge invalidate]; else [frcEngine invalidate];
    for(auto p:inputs) CVPixelBufferRelease(p);
    BOOL validRun=measuredSuccess==30 && completed==35 && failed==0 && rejected==0 && saved && sourceUnchanged && heldUnchanged;
    NSMutableArray *completionSequence=[NSMutableArray array];
    std::vector<int> order; for(int i=0;i<35;i++) if(state.samples[i].accepted) order.push_back(i);
    std::sort(order.begin(),order.end(),[&](int a,int b){return state.samples[a].callback<state.samples[b].callback;});
    for(int i:order) [completionSequence addObject:@(i)];
    NSDictionary *result=@{ @"scope":@"headless app bridge; no display or subjective acceptance", @"engine":engine,@"quality":quality,@"pattern":pattern,@"pace":pace,
        @"frcMode":frc?frcMode:@"not-applicable",@"sessions":@(frc?concurrency:0),@"maxInflight":@(maxInflight),
        @"inputSize":@[@2560,@1440],@"inputFormat":@(format),@"phases":phases,@"selectedPhase":phases[selectedPhase],@"setupMs":@(setupMs),
        @"warmup":@5,@"requestedMeasured":@30,@"completedAll":@(completed),@"failedAll":@(failed),@"rejectedAll":@(rejected),
        @"measuredCompleted":@(measuredSuccess),@"measuredWallMs":@(measuredWall),@"measuredCallbackWallMs":@(lastCallback.time_since_epoch().count()?ms(measuredStart,lastCallback):0),
        @"measuredPairsPerSecond":@(measuredWall>0?measuredSuccess*1000.0/measuredWall:0),@"gpuTime":@"unknown",@"diagnostics":diag ?: @{},
        @"selectedPairIndex":@10,@"selectedRaw":saved?raw:@"",@"syntheticGT":gtSaved?gtPath:@"",@"inputSHA256Before":beforeHashes,@"inputSHA256After":afterHashes,
        @"inputUnchanged":@(sourceUnchanged),@"heldOutputSHA256Before":heldBefore,@"heldOutputSHA256After":heldAfter,@"heldOutputUnchanged":@(heldUnchanged),@"validRun":@(validRun),@"completionSequenceByCallbackTime":completionSequence,@"samples":samples };
    NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil]; fwrite(json.bytes,1,json.length,stdout); putchar('\n');
    return validRun ? 0 : 1;
}}
