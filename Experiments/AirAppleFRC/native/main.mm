#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>
#import <Metal/Metal.h>
#import <CommonCrypto/CommonDigest.h>
#import "SPFRCEngine.h"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <memory>
#include <stdexcept>
#include <string>
#include <time.h>
#include <vector>

static const uint32_t W=1814, H=1142;
static const uint64_t NS=1000000000ULL;
static const size_t MAX_JOBS=4000;
static NSMutableArray *setupEvents;

static uint64_t nowNs() { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static id jsonSafe(id value) {
    if (!value || value==NSNull.null) return NSNull.null;
    if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) return value;
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *out=[NSMutableArray array]; for(id v in value) [out addObject:jsonSafe(v)]; return out;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *out=[NSMutableDictionary dictionary];
        for(id key in value) out[[key description]]=jsonSafe(value[key]); return out;
    }
    return @{ @"type":NSStringFromClass([value class]), @"description":[value description] };
}

// Called only during setup by the fresh, observational engine copy.
extern "C" void ODFAppleFRCObserveSetup(NSDictionary *event) {
    [setupEvents addObject:jsonSafe(event)];
}

static NSString *fourCC(OSType value) {
    char text[5]={(char)(value>>24),(char)(value>>16),(char)(value>>8),(char)value,0};
    for(int i=0;i<4;i++) if(text[i]<32 || text[i]>126) text[i]='?';
    return [NSString stringWithUTF8String:text];
}
static NSDictionary *errorJSON(NSError *error) {
    return error ? @{ @"domain":error.domain,@"code":@(error.code),
                     @"description":error.localizedDescription ?: @"" } : @{};
}
static void fail(NSString *message) { throw std::runtime_error(message.UTF8String ?: "failure"); }
static void writeJSON(NSDictionary *value,NSString *path) {
    if ([NSFileManager.defaultManager fileExistsAtPath:path]) fail(@"existing result retained");
    NSError *error=nil;
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:&error];
    if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:&error]) fail(error.localizedDescription ?: @"JSON write failed");
}
static NSDictionary *capability() {
    const NSOperatingSystemVersion os=NSProcessInfo.processInfo.operatingSystemVersion;
    BOOL available=NO, supported=NO;
    if (@available(macOS 15.4,*)) { available=YES; supported=VTFrameRateConversionConfiguration.isSupported; }
    return @{ @"os":NSProcessInfo.processInfo.operatingSystemVersionString,
        @"osMajor":@(os.majorVersion),@"osMinor":@(os.minorVersion),@"osPatch":@(os.patchVersion),
        @"apiAvailable":@(available),@"isSupported":@(supported),
        @"configurationInitialized":@NO,@"sessionCreated":@NO,@"metalDeviceCreated":@NO,
        @"origin":@"Static OS/isSupported and declared source requirements only; not configuration/session validation",
        @"declaredSDKMaximum":@{ @"width":@8192,@"height":@4320 },
        @"proposedWidth":@(W),@"proposedHeight":@(H),
        @"productEngineInput":@"420v NV12 (this diagnostic); product converter does not accept BGRA",
        @"productVTInput":@"64RGBAHalf; actual dynamic supported formats/attributes require configuration creation",
        @"proposedQuality":@"Normal",@"proposedRevision":@1,@"usePrecomputedFlow":@NO };
}

struct Options {
    NSString *output=nil,*cancel=nil;
    bool capabilityOnly=false;
    static Options parse(int argc,char **argv) {
        Options result; NSMutableDictionary *values=[NSMutableDictionary dictionary];
        for(int i=1;i<argc;i++) {
            NSString *key=@(argv[i]);
            if ([key isEqualToString:@"--capability-only"]) { if(result.capabilityOnly)fail(@"duplicate capability flag");result.capabilityOnly=true;continue; }
            if (![@[@"--output",@"--seconds",@"--baseline-seconds",@"--cancel-file"] containsObject:key] || i+1>=argc || values[key]) fail(@"unknown/duplicate CLI option");
            values[key]=@(argv[++i]);
        }
        result.output=values[@"--output"];
        if(!result.output.isAbsolutePath || [NSFileManager.defaultManager fileExistsAtPath:result.output]) fail(@"absolute fresh --output required");
        if(result.capabilityOnly) { if(values.count!=1)fail(@"capability-only accepts --output only");return result; }
        result.cancel=values[@"--cancel-file"];
        if(values.count!=4 || ![values[@"--seconds"] isEqualToString:@"120"] ||
           ![values[@"--baseline-seconds"] isEqualToString:@"5"] || !result.cancel.isAbsolutePath) fail(@"fixed --seconds120 --baseline-seconds5 and absolute cancel-file required");
        return result;
    }
};

static CVPixelBufferRef makeBuffer(OSType format) {
    CVPixelBufferRef output=nullptr;
    NSDictionary *attrs=@{(__bridge NSString*)kCVPixelBufferMetalCompatibilityKey:@YES,
                          (__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey:@{}};
    CVReturn code=CVPixelBufferCreate(nullptr,W,H,format,(__bridge CFDictionaryRef)attrs,&output);
    if(code!=kCVReturnSuccess || !output || !CVPixelBufferGetIOSurface(output)) fail(@"IOSurface pixel buffer allocation");
    return output;
}
static CVPixelBufferRef image(int shift) {
    CVPixelBufferRef output=makeBuffer(kCVPixelFormatType_32BGRA);
    CVPixelBufferLockBaseAddress(output,0);
    auto *base=(uint8_t*)CVPixelBufferGetBaseAddress(output);size_t stride=CVPixelBufferGetBytesPerRow(output);
    for(uint32_t y=0;y<H;y++)for(uint32_t x=0;x<W;x++) {
        auto *p=base+y*stride+4*x;
        p[0]=((x+shift)^y)&255;p[1]=(3*x+y+shift)&255;p[2]=(x+2*y+shift)&255;p[3]=255;
    }
    CVPixelBufferUnlockBaseAddress(output,0);return output;
}
static uint8_t quantize(double value,int low,int high) { return (uint8_t)std::max(low,std::min(high,(int)std::lround(value))); }
static CVPixelBufferRef toNV12(CVPixelBufferRef input) {
    CVPixelBufferRef output=makeBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    CVPixelBufferLockBaseAddress(input,kCVPixelBufferLock_ReadOnly);CVPixelBufferLockBaseAddress(output,0);
    auto *rgb=(const uint8_t*)CVPixelBufferGetBaseAddress(input);size_t rs=CVPixelBufferGetBytesPerRow(input);
    auto *luma=(uint8_t*)CVPixelBufferGetBaseAddressOfPlane(output,0),*uv=(uint8_t*)CVPixelBufferGetBaseAddressOfPlane(output,1);
    size_t ys=CVPixelBufferGetBytesPerRowOfPlane(output,0),us=CVPixelBufferGetBytesPerRowOfPlane(output,1);
    for(uint32_t y=0;y<H;y+=2)for(uint32_t x=0;x<W;x+=2) {
        double cb=0,cr=0;
        for(unsigned dy=0;dy<2;dy++)for(unsigned dx=0;dx<2;dx++) {
            const uint8_t *p=rgb+(y+dy)*rs+4*(x+dx);
            const double blue=p[0],green=p[1],red=p[2],yy=.2126*red+.7152*green+.0722*blue;
            luma[(y+dy)*ys+x+dx]=quantize(16+219*yy/255,16,235);
            cb+=(blue-yy)/(2*(1-.0722));cr+=(red-yy)/(2*(1-.2126));
        }
        uv[(y/2)*us+x]=quantize(128+224*(cb/4)/255,16,240);
        uv[(y/2)*us+x+1]=quantize(128+224*(cr/4)/255,16,240);
    }
    CVPixelBufferUnlockBaseAddress(output,0);CVPixelBufferUnlockBaseAddress(input,kCVPixelBufferLock_ReadOnly);
    CVBufferSetAttachment(output,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(output,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(output,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(output,kCVImageBufferChromaLocationTopFieldKey,kCVImageBufferChromaLocation_Center,kCVAttachmentMode_ShouldPropagate);
    return output;
}
static NSString *pixelHash(CVPixelBufferRef buffer) {
    CVPixelBufferLockBaseAddress(buffer,kCVPixelBufferLock_ReadOnly);CC_SHA256_CTX context;CC_SHA256_Init(&context);
    size_t planes=CVPixelBufferGetPlaneCount(buffer);
    if(!planes) {
        auto *base=(const uint8_t*)CVPixelBufferGetBaseAddress(buffer);size_t stride=CVPixelBufferGetBytesPerRow(buffer);
        for(uint32_t y=0;y<H;y++)CC_SHA256_Update(&context,base+y*stride,W*4);
    } else for(size_t plane=0;plane<planes;plane++) {
        auto *base=(const uint8_t*)CVPixelBufferGetBaseAddressOfPlane(buffer,plane);
        size_t stride=CVPixelBufferGetBytesPerRowOfPlane(buffer,plane),height=CVPixelBufferGetHeightOfPlane(buffer,plane);
        for(size_t y=0;y<height;y++)CC_SHA256_Update(&context,base+y*stride,W);
    }
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256_Final(digest,&context);
    CVPixelBufferUnlockBaseAddress(buffer,kCVPixelBufferLock_ReadOnly);
    NSMutableString *out=[NSMutableString stringWithCapacity:64];for(auto byte:digest)[out appendFormat:@"%02x",byte];return out;
}

struct Result {
    std::atomic<bool> done{false};
    dispatch_semaphore_t signal=dispatch_semaphore_create(0);
    uint64_t readyNs=0,token=0;double engineLatencySec=0;
    NSError *error=nil;CVPixelBufferRef output=nullptr;
    ~Result(){if(output)CVPixelBufferRelease(output);}
};
struct Job {
    uint64_t jobID=0,sourceTick=0,targetNs=0,submitNs=0,submitReturnNs=0,readyNs=0,completionToken=0;
    int sequence=0,tick=-1,missedSlotsBefore=0,aShift=0,bShift=0;
    bool accepted=false,callbackSeen=false,outputIOSurface=false;
    uint32_t outputFormat=0,outputWidth=0,outputHeight=0;
    double engineLatencySec=0;
    NSString *phase=nil,*status=@"missing_ready",*errorDomain=@"",*errorDescription=@"";NSInteger errorCode=0;
    NSDictionary *json()const {
        return @{ @"jobID":@(jobID),@"phase":phase,@"sequence":@(sequence),@"tick":@(tick),@"sourceTick":@(sourceTick),
            @"targetNs":@(targetNs),@"submitNs":@(submitNs),@"submitReturnNs":@(submitReturnNs),@"readyNs":@(readyNs),
            @"submitToReadyNs":@(readyNs>=submitNs && readyNs ? readyNs-submitNs:0),@"completionToken":@(completionToken),
            @"launchLagNs":@(targetNs && submitNs>=targetNs ? submitNs-targetNs:0),@"missedSlotsBefore":@(missedSlotsBefore),
            @"frameAShift":@(aShift),@"frameBShift":@(bShift),@"ptsAValue":@(sourceTick-1),@"ptsBValue":@(sourceTick),@"ptsTimescale":@24,
            @"accepted":@(accepted),@"callbackSeen":@(callbackSeen),@"status":status,
            @"errorDomain":errorDomain,@"errorCode":@(errorCode),@"errorDescription":errorDescription,
            @"actualOutputFormat":@(outputFormat),@"actualOutputFourCC":fourCC(outputFormat),
            @"outputWidth":@(outputWidth),@"outputHeight":@(outputHeight),@"outputIOSurface":@(outputIOSurface),
            @"engineLatencySec":@(engineLatencySec),@"submissionMode":@"Random (canonical submitPair path)" };
    }
};
struct Phase {
    uint64_t start=0,end=0,requestedEnd=0;int seconds=0,planned=0,submitted=0,completeCount=0,errors=0,missing=0,rejected=0,skipped=0,unissued=0;
    bool complete=false;
    NSDictionary *json()const {
        int unfinished=errors+missing+rejected+unissued;
        return @{ @"startNs":@(start),@"requestedEndNs":@(requestedEnd),@"endNs":@(end),@"requestedSeconds":@(seconds),
            @"plannedSlots":@(planned),@"submittedCount":@(submitted),@"completeCount":@(completeCount),
            @"terminalErrorCount":@(errors),@"missingReadyCount":@(missing),@"rejectedCount":@(rejected),
            @"skippedSlots":@(skipped),@"unissuedRemainingSlots":@(unissued),@"unfinishedCount":@(unfinished),
            @"actualHz":@(end>start ? completeCount/(double(end-start)/NS):0),@"complete":@(complete) };
    }
};
struct Cancelled{};
static bool cancelled(NSString *file) { return file && [NSFileManager.defaultManager fileExistsAtPath:file]; }

int main(int argc,char **argv) { @autoreleasepool {
    if(argc==2 && (!strcmp(argv[1],"--help") || !strcmp(argv[1],"-h"))) {
        puts("air-apple-frc --output ABS-new.json --seconds 120 --baseline-seconds 5 --cancel-file ABS\nCPU only: --output ABS-new.json --capability-only\nNo session/configuration/Metal device is created by capability-only.");return 0;
    }
    Options options;
    try { options=Options::parse(argc,argv); }
    catch(const std::exception &e){fprintf(stderr,"air-apple-frc CLI: %s\n",e.what());return 2;}
    NSMutableDictionary *report=[@{ @"format":@"odf-air-apple-frc-native-v1",@"status":@"failed",@"formalStarted":@NO,
        @"setupSucceeded":@NO,@"failurePhase":@"setup",@"capability":capability(),
        @"configuration":@{ @"engine":@"apple.frc",@"width":@(W),@"height":@(H),@"mode":@"paced24",@"targetHz":@24,
            @"seconds":@120,@"baselineSeconds":@5,@"warmup":@20,@"sessionsRequested":@2,@"outputCapacity":@8,
            @"quality":@"Normal",@"revision":@1,@"usePrecomputedFlow":@NO,@"submissionMode":@"Random",
            @"scope":@"B submit to final NV12 engine completion; includes both NV12-to-Half conversions, VT and Half-to-NV12; no capture/presenter/GPU-execution claim",
            @"clock":@"CLOCK_UPTIME_RAW nanoseconds; all submit/ready/phase/tick times use this domain",
            @"callbackTimeoutSeconds":@10,@"maximumJobs":@(MAX_JOBS),@"singleRequestInFlight":@YES,
            @"inputPTS":@"24Hz source ticks; alternating shift0/7; adjacent source frames unless explicit missed tick",
            @"warmupCadence":@"20 back-to-back complete pairs; prefix and formal use absolute24Hz ticks" } } mutableCopy];
    if(options.capabilityOnly) {
        report[@"status"]=@"capability_only";report[@"origin"]=@"CPU metadata/isSupported only; no config/session/device/buffer";
        try{writeJSON(report,options.output);return 0;}catch(const std::exception&e){fprintf(stderr,"%s\n",e.what());return 2;}
    }
    setupEvents=[NSMutableArray array];report[@"actualSetupEvents"]=setupEvents;
    std::vector<Job> jobs;jobs.reserve(3100);NSMutableDictionary *phases=[NSMutableDictionary dictionary];NSMutableArray *thermal=[NSMutableArray array];
    CVPixelBufferRef originals[2]={nullptr,nullptr},inputs[2]={nullptr,nullptr},lastOutput=nullptr;
    SPFRCEngine *engine=nil;
    NSString *failurePhase=@"setup";
    uint64_t nextID=1;
    bool cancellationObservedInJob=false;
    std::shared_ptr<Result> stoppedRequest;
    auto runJob=[&](NSString *phase,int sequence,int tick,uint64_t sourceTick,uint64_t target,int skippedBefore)->Job {
        if(cancelled(options.cancel))throw Cancelled{};
        if(jobs.size()>=MAX_JOBS)fail(@"bounded job storage exhausted");
        Job job;job.jobID=nextID++;job.phase=phase;job.sequence=sequence;job.tick=tick;job.sourceTick=sourceTick;
        job.targetNs=target;job.missedSlotsBefore=skippedBefore;job.aShift=((sourceTick-1)%2)?7:0;job.bShift=(sourceTick%2)?7:0;
        auto state=std::make_shared<Result>();
        SPFRCEngineCompletion completion=^(uint64_t token,CVPixelBufferRef midpoint,double latency,NSError *error) {
            const uint64_t ready=nowNs();
            state->readyNs=ready;state->token=token;state->engineLatencySec=latency;state->error=error;
            state->output=midpoint; // Canonical completion transfers +1, released by Result.
            state->done.store(true,std::memory_order_release);dispatch_semaphore_signal(state->signal);
        };
        job.submitNs=nowNs();
        job.accepted=[engine submitPairWithFrameA:inputs[(sourceTick-1)%2] frameB:inputs[sourceTick%2]
            ptsA:CMTimeMake(sourceTick-1,24) ptsB:CMTimeMake(sourceTick,24) token:job.jobID completion:completion];
        job.submitReturnNs=nowNs();
        bool sawCancellation=false;
        if(job.accepted)while(!state->done.load(std::memory_order_acquire)) {
            dispatch_semaphore_wait(state->signal,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_MSEC));
            if(cancelled(options.cancel))sawCancellation=true;
            if(nowNs()-job.submitNs>=10*NS)break;
        }
        job.callbackSeen=state->done.load(std::memory_order_acquire);
        if(!job.accepted)job.status=@"rejected";
        else if(!job.callbackSeen) {job.status=@"missing_ready";job.errorDescription=@"callback deadline10s; no ready fabricated";stoppedRequest=state;}
        else {
            job.readyNs=state->readyNs;job.completionToken=state->token;job.engineLatencySec=state->engineLatencySec;
            if(state->error){job.status=@"callback_error";job.errorDomain=state->error.domain;job.errorCode=state->error.code;job.errorDescription=state->error.localizedDescription ?: @"";}
            else if(state->output && state->token==job.jobID) {
                job.outputFormat=CVPixelBufferGetPixelFormatType(state->output);job.outputWidth=(uint32_t)CVPixelBufferGetWidth(state->output);job.outputHeight=(uint32_t)CVPixelBufferGetHeight(state->output);
                job.outputIOSurface=CVPixelBufferGetIOSurface(state->output)!=nullptr;
                if(job.outputFormat==kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange && job.outputWidth==W && job.outputHeight==H && job.outputIOSurface) {
                    job.status=@"ready";if(lastOutput)CVPixelBufferRelease(lastOutput);lastOutput=CVPixelBufferRetain(state->output);
                } else job.status=@"invalid_output";
            } else job.status=@"invalid_output";
        }
        jobs.push_back(job);
        if(sawCancellation)cancellationObservedInJob=true;
        return job;
    };
    auto phase=[&](NSString *name,int seconds,uint64_t start,uint64_t ptsOffset) {
        Phase state;state.start=start;state.seconds=seconds;state.planned=seconds*24;state.requestedEnd=start+seconds*NS;
        int tick=0,missedBefore=0,nextThermal=0;
        try {
            while(tick<state.planned) {
                if(cancelled(options.cancel))throw Cancelled{};
                uint64_t target=start+uint64_t(tick)*NS/24;
                if(state.submitted>0 || nowNs()>=start+NS/24) {
                    const uint64_t ready=nowNs();
                    while(tick<state.planned && target<=ready) {tick++;state.skipped++;missedBefore++;target=start+uint64_t(tick)*NS/24;}
                }
                if(tick>=state.planned)break;
                uint64_t stamp=nowNs();if(stamp<target)[NSThread sleepForTimeInterval:double(target-stamp)/NS];
                stamp=nowNs();
                if(stamp>=state.requestedEnd)continue;
                if(stamp<target)continue;
                if(stamp-target>=NS/24)continue;
                Job job;
                @autoreleasepool {job=runJob(name,state.submitted,tick,ptsOffset+tick+1,target,missedBefore);}
                state.submitted++;tick++;missedBefore=0;
                if([job.status isEqualToString:@"ready"])state.completeCount++;
                else {
                    if(!job.accepted)state.rejected++;else if(!job.callbackSeen)state.missing++;else state.errors++;
                    fail([NSString stringWithFormat:@"job%llu %@ %@",job.jobID,job.status,job.errorDescription]);
                }
                if(cancellationObservedInJob)throw Cancelled{};
                int elapsed=(int)((nowNs()-start)/NS);
                if(elapsed>=nextThermal) {
                    [thermal addObject:@{@"phase":name,@"sampleNs":@(nowNs()),@"elapsedSeconds":@(elapsed),@"thermalState":@(NSProcessInfo.processInfo.thermalState)}];
                    printf("phase=%s seconds=%d complete=%d\n",name.UTF8String,elapsed,state.completeCount);fflush(stdout);nextThermal=elapsed+1;
                }
            }
            state.complete=true;
        } catch(...) {
            state.end=nowNs();state.unissued=state.planned-tick;phases[name]=state.json();throw;
        }
        state.end=nowNs();state.unissued=state.planned-tick;phases[name]=state.json();
    };
    try {
        NSDictionary *env=NSProcessInfo.processInfo.environment;
        if(env[@"CHUANFLOW_FRC_CONTINUOUS"] || env[@"CHUANFLOW_THROUGHPUT_TRACE"] || env[@"SP_DEBUG"] || env[@"SP_AUTOMATION"])fail(@"inherited continuity/trace/debug/automation variables are not allowed");
        if(![report[@"capability"][@"isSupported"] boolValue])fail(@"Apple FRC unsupported; configuration/session not attempted");
        if(cancelled(options.cancel))throw Cancelled{};
        NSMutableArray *fixtures=[NSMutableArray array];
        for(int i=0;i<2;i++) {
            originals[i]=image(i?7:0);const uint64_t start=nowNs();inputs[i]=toNV12(originals[i]);const uint64_t end=nowNs();
            [fixtures addObject:@{@"shift":@(i?7:0),@"bgraSHA256":pixelHash(originals[i]),@"nv12SHA256":pixelHash(inputs[i]),@"cpuConversionNs":@(end-start)}];
        }
        report[@"fixtureSetup"]=@{@"frames":fixtures,@"conversion":@"CPU BT.709 video-range; Y round/clamp16..235; CbCr2x2 box average round/clamp16..240; Center chroma; no GPU",
            @"matrix":@"Kr0.2126,Kb0.0722",@"sourceFourCC":@"BGRA",@"engineInputFourCC":@"420v",@"excludedFromSubmitReady":@YES};
        id<MTLDevice> device=MTLCreateSystemDefaultDevice();if(!device)fail(@"Metal device unavailable");
        report[@"device"]=@{@"name":device.name,@"registryID":@(device.registryID)};
        NSString *binary=[NSProcessInfo.processInfo.arguments.firstObject stringByStandardizingPath];
        NSString *libraryPath=[[binary stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"FrameBudget.metallib"];
        NSError *error=nil;id<MTLLibrary> library=[device newLibraryWithURL:[NSURL fileURLWithPath:libraryPath] error:&error];
        if(!library){report[@"setupError"]=errorJSON(error);fail(@"FrameBudget metallib load failed");}
        SPFrameBudgetMetal *metal=[[SPFrameBudgetMetal alloc] initWithDevice:device library:library width:W height:H pixelFormat:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange error:&error];
        if(!metal){report[@"setupError"]=errorJSON(error);fail(@"canonical frame converter creation failed");}
        engine=[[SPFRCEngine alloc] initWithMetal:metal sessions:2 outputCapacity:8 quality:SPFRCQualityNormal error:&error];
        if(!engine){report[@"setupError"]=errorJSON(error);fail(@"canonical Apple session creation failed");}
        report[@"actualSessionCount"]=@(engine.sessionCount);if(engine.sessionCount!=2)fail(@"actual session count mismatch");
        report[@"setupSucceeded"]=@YES;
        failurePhase=@"warmup";
        for(int i=0;i<20;i++) { @autoreleasepool {
            Job job=runJob(@"warmup",i,-1,i+1,0,0);
            if(cancellationObservedInJob)throw Cancelled{};
            if(![job.status isEqualToString:@"ready"])fail([NSString stringWithFormat:@"warmup %@",job.status]);
        }}
        failurePhase=@"baseline";const uint64_t start=nowNs();phase(@"baseline",5,start,20);
        if(cancelled(options.cancel))throw Cancelled{};
        failurePhase=@"measurement";report[@"formalStarted"]=@YES;phase(@"measurement",120,start+5*NS,140);
        if(cancelled(options.cancel))throw Cancelled{};
        report[@"status"]=@"complete";report[@"failurePhase"]=NSNull.null;
    } catch(const Cancelled&) {report[@"status"]=@"cancelled";report[@"failurePhase"]=failurePhase;report[@"firstFailure"]=@"cancellation marker";}
      catch(const std::exception &e) {report[@"status"]=[report[@"setupSucceeded"] boolValue]?@"failed":@"setup_failed";report[@"failurePhase"]=failurePhase;report[@"firstFailure"]=@(e.what());}
    if(engine)[engine invalidate];
    if(stoppedRequest) {
        const bool seen=stoppedRequest->done.load(std::memory_order_acquire);
        report[@"stoppedRequestAfterInvalidation"]=@{@"callbackSeen":@(seen),@"readyNs":@(seen?stoppedRequest->readyNs:0),
            @"token":@(seen?stoppedRequest->token:0),@"error":seen?errorJSON(stoppedRequest->error):@{},
            @"scope":@"Late observation only; original missing-ready job is retained without reclassification"};
    }
    report[@"phases"]=phases;report[@"thermalSamples"]=thermal;
    NSMutableArray *rows=[NSMutableArray arrayWithCapacity:jobs.size()];for(const auto &job:jobs)[rows addObject:job.json()];report[@"jobs"]=rows;
    if(lastOutput){report[@"lastOutputSHA256"]=pixelHash(lastOutput);CVPixelBufferRelease(lastOutput);}
    for(auto buffer:inputs)if(buffer)CVPixelBufferRelease(buffer);for(auto buffer:originals)if(buffer)CVPixelBufferRelease(buffer);
    report[@"functionalComplete"]=@([report[@"status"] isEqualToString:@"complete"]);
    try{writeJSON(report,options.output);}catch(const std::exception&e){fprintf(stderr,"%s\n",e.what());return 2;}
    printf("status=%s output=%s\n",[report[@"status"] UTF8String],options.output.UTF8String);
    return [report[@"status"] isEqualToString:@"complete"]?0:([report[@"status"] isEqualToString:@"cancelled"]?4:1);
}}
