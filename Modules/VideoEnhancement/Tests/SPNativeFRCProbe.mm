#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>
#import <VideoToolbox/VTFrameProcessor.h>
#import <VideoToolbox/VTFrameProcessor_FrameRateConversion.h>
#include <cmath>
#include <chrono>

static CVReturn lastBufferStatus = kCVReturnSuccess;
static CVPixelBufferRef makeFrame(int shift, bool glyph) {
    const int w=2560,h=1440; CVPixelBufferRef p=nullptr;
    NSDictionary *attrs=getenv("ODF_PROBE_CPU_BUFFERS") ? @{} : @{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,w,h,kCVPixelFormatType_64RGBAHalf,(__bridge CFDictionaryRef)attrs,&p);
    lastBufferStatus = status;
    if (status!=kCVReturnSuccess) { fprintf(stderr,"CVPixelBufferCreate status=%d\n",status); return nullptr; }
    CVPixelBufferLockBaseAddress(p,0); auto *base=(uint8_t *)CVPixelBufferGetBaseAddress(p); size_t stride=CVPixelBufferGetBytesPerRow(p);
    for(int y=0;y<h;y++) { auto *row=(__fp16 *)(base+y*stride); for(int x=0;x<w;x++) {
        int xx=(x-shift+2560)%2560, gx=xx%24, gy=y%28;
        bool edge=glyph ? ((gx>=3&&gx<5&&gy>=3&&gy<23)||(gx>=16&&gx<18&&gy>=3&&gy<23)||(gy>=3&&gy<5&&gx>=3&&gx<18)||(gy>=12&&gy<14&&gx>=3&&gx<18)||(gy>=21&&gy<23&&gx>=3&&gx<18)) : ((xx/3+y/7)&1);
        __fp16 v=edge?0.82:0.16; row[x*4]=v;row[x*4+1]=v;row[x*4+2]=v;row[x*4+3]=1;
    }} CVPixelBufferUnlockBaseAddress(p,0); return p;
}
static NSDictionary *difference(CVPixelBufferRef a,CVPixelBufferRef b) {
    if(!a||!b||CVPixelBufferGetWidth(a)!=CVPixelBufferGetWidth(b)||CVPixelBufferGetHeight(a)!=CVPixelBufferGetHeight(b))return @{};
    CVPixelBufferLockBaseAddress(a,kCVPixelBufferLock_ReadOnly);CVPixelBufferLockBaseAddress(b,kCVPixelBufferLock_ReadOnly);
    auto *aa=(uint8_t *)CVPixelBufferGetBaseAddress(a),*bb=(uint8_t *)CVPixelBufferGetBaseAddress(b);
    size_t as=CVPixelBufferGetBytesPerRow(a),bs=CVPixelBufferGetBytesPerRow(b); double sum=0,ea=0,eb=0; uint64_t n=0;
    for(int y=0;y<1440;y+=4)for(int x=0;x<2559;x+=4){auto *ar=(__fp16 *)(aa+y*as),*br=(__fp16 *)(bb+y*bs);float av=ar[x*4],bv=br[x*4];sum+=fabs(av-bv);ea+=fabs((float)ar[(x+1)*4]-av);eb+=fabs((float)br[(x+1)*4]-bv);n++;}
    CVPixelBufferUnlockBaseAddress(b,kCVPixelBufferLock_ReadOnly);CVPixelBufferUnlockBaseAddress(a,kCVPixelBufferLock_ReadOnly);
    return @{ @"maeNormalized":@(sum/n), @"referenceEdge":@(ea/n), @"outputEdge":@(eb/n), @"sampledPixels":@(n), @"sampling":@"every fourth x and y; horizontal one-pixel edge" };
}
int main() { @autoreleasepool {
    NSMutableArray *cases=[NSMutableArray array]; BOOL allReady=YES;
    for (int glyph=0;glyph<2;glyph++) for (int moving=0;moving<2;moving++) {
        CVPixelBufferRef a=makeFrame(0,glyph),b=makeFrame(moving?8:0,glyph),gt=makeFrame(moving?4:0,glyph);
        if(!a||!b||!gt) {
            NSDictionary *result=@{@"scope":@"Direct VT SDK buffer test; no inference performed", @"bufferAllocation":getenv("ODF_PROBE_CPU_BUFFERS") ? @"CPU buffer" : @"IOSurface Metal compatible", @"failure":@"CVPixelBufferCreate failed", @"cvReturn":@(lastBufferStatus), @"cases":cases};
            NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];fwrite(json.bytes,1,json.length,stdout);putchar('\n');
            if(a)CVPixelBufferRelease(a); if(b)CVPixelBufferRelease(b); if(gt)CVPixelBufferRelease(gt); return 2;
        }
        [cases addObject:@{@"engine":@"no-interpolation",@"model":@"none",@"quality":@"none",@"inputSize":@[@2560,@1440],@"processingSize":@[@2560,@1440],@"outputSize":@[@2560,@1440],@"pixelFormat":@"64RGBAHalf",@"warmupCount":@0,@"timingScope":@"not timed",@"pattern":glyph?@"thin-glyph":@"3px-stripes",@"motion":moving?@"8px":@"static",@"phase":@0,@"samples":@1,@"difference":difference(a,a)}];
        for(int q=0;q<2;q++) {
            NSMutableDictionary *entry=[@{@"engine":@"apple.frc.sdk",@"model":q?@"vt.frc.quality":@"vt.frc.normal",@"quality":q?@"quality":@"normal",@"pattern":glyph?@"thin-glyph":@"3px-stripes",@"motion":moving?@"8px":@"static",@"phase":@0.5,@"inputSize":@[@2560,@1440],@"processingSize":@[@2560,@1440],@"outputSize":@[@2560,@1440],@"pixelFormat":@"64RGBAHalf",@"warmupCount":@1,@"requestedSamples":@1,@"samples":@0,@"timingScope":@"VT process submission through completion; excludes setup and pattern creation"} mutableCopy];
            NSError *error=nil; VTFrameProcessor *proc=[[VTFrameProcessor alloc] init];
            VTFrameRateConversionConfiguration *cfg=[[VTFrameRateConversionConfiguration alloc] initWithFrameWidth:2560 frameHeight:1440 usePrecomputedFlow:NO qualityPrioritization:q?VTFrameRateConversionConfigurationQualityPrioritizationQuality:VTFrameRateConversionConfigurationQualityPrioritizationNormal revision:VTFrameRateConversionConfigurationRevision1];
            BOOL ready=cfg && [proc startSessionWithConfiguration:cfg error:&error];
            entry[@"configurationCreated"] = @(cfg != nil);
            entry[@"sessionStarted"] = @(ready);
            if (!ready) { allReady=NO; entry[@"failure"]=error.localizedDescription ?: (cfg ? @"session rejected without NSError" : @"configuration initializer returned nil"); }
            for(int i=0;ready && i<2;i++) {
                CVPixelBufferRef out=makeFrame(0,glyph); VTFrameProcessorFrame *fa=[[VTFrameProcessorFrame alloc] initWithBuffer:a presentationTimeStamp:CMTimeMake(0,60)],*fb=[[VTFrameProcessorFrame alloc] initWithBuffer:b presentationTimeStamp:CMTimeMake(1,60)],*fo=[[VTFrameProcessorFrame alloc] initWithBuffer:out presentationTimeStamp:CMTimeMake(1,120)];
                VTFrameRateConversionParameters *params=[[VTFrameRateConversionParameters alloc] initWithSourceFrame:fa nextFrame:fb opticalFlow:nil interpolationPhase:@[@0.5] submissionMode:VTFrameRateConversionParametersSubmissionModeRandom destinationFrames:@[fo]];
                if(!params){allReady=NO;entry[@"failure"]=@"parameters rejected";CVPixelBufferRelease(out);break;}
                dispatch_semaphore_t done=dispatch_semaphore_create(0); __block NSError *failure=nil; auto start=std::chrono::steady_clock::now();
                [proc processWithParameters:params completionHandler:^(id<VTFrameProcessorParameters> p,NSError *e){(void)p;failure=e;dispatch_semaphore_signal(done);}];
                if(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,60*NSEC_PER_SEC))!=0){entry[@"failure"]=@"timeout"; [cases addObject:entry]; NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"cases":cases,@"timeout":@YES} options:NSJSONWritingPrettyPrinted error:nil];fwrite(json.bytes,1,json.length,stdout);return 3;}
                double ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
                if(failure){allReady=NO;entry[@"failure"]=failure.localizedDescription;CVPixelBufferRelease(out);break;}
                if(i==1){entry[@"samples"]=@1;entry[@"latencyMs"]=@(ms);entry[@"difference"]=difference(gt,out);entry[@"actualOutputSize"]=@[@(CVPixelBufferGetWidth(out)),@(CVPixelBufferGetHeight(out))];entry[@"actualPixelFormat"]=@(CVPixelBufferGetPixelFormatType(out));}
                CVPixelBufferRelease(out);
            }
            if(ready)[proc endSession];[cases addObject:entry];
        } CVPixelBufferRelease(a);CVPixelBufferRelease(b);CVPixelBufferRelease(gt);
    }
    NSDictionary *result=@{@"scope":@"Direct VT SDK buffer test; not OpenDuckFrame live bridge, file provider, physical display or subjective acceptance",@"bufferAllocation":getenv("ODF_PROBE_CPU_BUFFERS") ? @"CPU buffer (no IOSurface requested)" : @"IOSurface Metal compatible",@"frcSupported":@(VTFrameRateConversionConfiguration.isSupported),@"complete":@(allReady),@"cases":cases};
    NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];fwrite(json.bytes,1,json.length,stdout);putchar('\n');return allReady ? 0 : 1;
}}
