#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import "SPFileLanczosScaler.h"
#import "SPFileMetalFXScaler.h"
#import "SPFileAppleSRScaler.h"
#import "SPFileAppleVideoSRScaler.h"
#import "SPFileAnimationScaler.h"
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <vector>

// Offline component measurement. No window, drawable, audio or displayed-FPS claim.
static double nowSeconds() {
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}
static NSString *formatName(OSType value) {
    if(value==kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)return @"NV12-video-range";
    if(value==kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)return @"NV12-full-range";
    char bytes[5]={(char)(value>>24),(char)(value>>16),(char)(value>>8),(char)value,0};
    return [NSString stringWithFormat:@"%s (0x%08x)",bytes,(unsigned)value];
}
static NSDictionary *colors(CVPixelBufferRef buffer) {
    NSMutableDictionary *result=[NSMutableDictionary dictionary];
    for(NSString *key in @[(id)kCVImageBufferYCbCrMatrixKey,(id)kCVImageBufferColorPrimariesKey,(id)kCVImageBufferTransferFunctionKey]) {
        CFTypeRef value=CVBufferCopyAttachment(buffer,(__bridge CFStringRef)key,NULL);
        result[key]=value?[(__bridge id)value description]:(id)NSNull.null;
        if(value)CFRelease(value);
    }
    result[@"range"]=CVPixelBufferGetPixelFormatType(buffer)==kCVPixelFormatType_420YpCbCr8BiPlanarFullRange?@"full":@"video";
    return result;
}
static NSDictionary *statistics(const std::vector<double> &samples) {
    if(samples.empty())return @{@"count":@0,@"mean":NSNull.null,@"p50":NSNull.null,@"p95":NSNull.null};
    std::vector<double> ordered=samples;std::sort(ordered.begin(),ordered.end());
    double total=0;for(double sample:samples)total+=sample;
    auto quantile=[&](double q){double index=q*(ordered.size()-1);size_t lo=(size_t)std::floor(index),hi=(size_t)std::ceil(index);return ordered[lo]+(ordered[hi]-ordered[lo])*(index-lo);};
    return @{@"count":@(samples.size()),@"mean":@(total/samples.size()),@"p50":@(quantile(.5)),@"p95":@(quantile(.95))};
}
static bool positiveInteger(const char *text,int &result) {
    char *end=NULL;errno=0;long value=strtol(text,&end,10);
    if(errno||!text[0]||!end||*end||value<1||value>INT_MAX)return false;
    result=(int)value;return true;
}
struct CompletionState {
    std::atomic<bool> done{false};
    CVPixelBufferRef output=NULL;
    NSError *__strong error=nil;
    double completedAt=0;
    ~CompletionState(){if(output)CVPixelBufferRelease(output);}
};
static bool writeNV12(FILE *file,CVPixelBufferRef buffer,uint64_t &written,NSString **reason) {
    OSType format=CVPixelBufferGetPixelFormatType(buffer);
    const size_t width=CVPixelBufferGetWidth(buffer),height=CVPixelBufferGetHeight(buffer);
    if((format!=kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange&&format!=kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)||
       (width&1)||(height&1)||CVPixelBufferGetPlaneCount(buffer)!=2) {
        if(reason)*reason=@"Raw export requires even-sized 8-bit NV12; P010 and other formats are not reinterpreted.";return false;
    }
    CVReturn locked=CVPixelBufferLockBaseAddress(buffer,kCVPixelBufferLock_ReadOnly);
    if(locked!=kCVReturnSuccess){if(reason)*reason=@"Cannot lock output pixel buffer.";return false;}
    bool ok=true;
    for(size_t plane=0;plane<2&&ok;plane++) {
        const uint8_t *base=(const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buffer,plane);
        size_t stride=CVPixelBufferGetBytesPerRowOfPlane(buffer,plane),rows=plane?height/2:height;
        if(!base||stride<width||CVPixelBufferGetHeightOfPlane(buffer,plane)!=rows){ok=false;break;}
        for(size_t row=0;row<rows;row++){size_t bytes=fwrite(base+row*stride,1,width,file);written+=bytes;if(bytes!=width){ok=false;break;}}
    }
    CVPixelBufferUnlockBaseAddress(buffer,kCVPixelBufferLock_ReadOnly);
    if(!ok&&reason)*reason=@"NV12 plane layout or raw output write failed.";
    return ok;
}
static int run(int argc,const char **argv) {
    if(argc!=10) {
        fprintf(stderr,"Usage: %s engine variant resource_app input output_raw result_json maxframes targetwidth targetheight\nEngines: lanczos, metalfx, apple-low, apple-video, anime4k, realcugan\n",argv[0]);return 2;
    }
    int limit=0,targetWidth=0,targetHeight=0;
    if(!positiveInteger(argv[7],limit)||!positiveInteger(argv[8],targetWidth)||!positiveInteger(argv[9],targetHeight)) {fprintf(stderr,"maxframes and target dimensions must be positive integers\n");return 2;}
    NSString *engine=[NSString stringWithUTF8String:argv[1]],*variant=[NSString stringWithUTF8String:argv[2]];
    NSString *resourcePath=[NSString stringWithUTF8String:argv[3]],*inputPath=[NSString stringWithUTF8String:argv[4]];
    NSString *rawPath=[NSString stringWithUTF8String:argv[5]],*jsonPath=[NSString stringWithUTF8String:argv[6]];
    NSMutableDictionary *report=[@{@"engine":engine,@"variant":variant,@"input":inputPath,@"resourceApp":resourcePath,@"outputRaw":rawPath,@"maxFrames":@(limit),@"targetWidth":@(targetWidth),@"targetHeight":@(targetHeight),@"scope":@"Offline production file-scaler adapters, real decoded source frames and PTS. Processing includes adapter color conversions; excludes decode and raw export. No drawable, real-time playback, audio or physical display-FPS acceptance.",@"timingUnits":@"milliseconds",@"firstError":NSNull.null} mutableCopy];
    auto fail=[&](NSString *stage,NSString *message,int64_t frame,NSError *error=nil) {
        if(report[@"firstError"]!=NSNull.null)return;
        NSMutableDictionary *entry=[@{@"stage":stage,@"message":message?:@"Unknown failure",@"frame":@(frame)} mutableCopy];
        if(error){entry[@"domain"]=error.domain;entry[@"code"]=@(error.code);}
        report[@"firstError"]=entry;
    };
    const double started=nowSeconds();double setupMs=0,decodeTotalMs=0,exportTotalMs=0;
    uint64_t rawBytes=0;int decoded=0,processed=0,exported=0;bool eof=false,allColor=true,allFormat=true,monotonic=true;
    int64_t previousPTS=INT64_MIN;NSMutableArray *frames=[NSMutableArray array];std::vector<double> times;
    FILE *raw=NULL;AVAssetReader *reader=nil;SPFileLanczosScaler *scaler=nil;
    do {
        if([inputPath.stringByStandardizingPath isEqualToString:rawPath.stringByStandardizingPath]||[inputPath.stringByStandardizingPath isEqualToString:jsonPath.stringByStandardizingPath]||[rawPath.stringByStandardizingPath isEqualToString:jsonPath.stringByStandardizingPath]){fail(@"arguments",@"Input, raw output and JSON paths must be distinct.",-1);break;}
        raw=fopen(rawPath.fileSystemRepresentation,"wb");if(!raw){fail(@"open-output",[NSString stringWithUTF8String:strerror(errno)],-1);break;}
        const double setupStarted=nowSeconds();NSError *error=nil;
        AVURLAsset *asset=[AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:inputPath] options:nil];
        AVAssetTrack *track=[[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
        reader=track?[[AVAssetReader alloc] initWithAsset:asset error:&error]:nil;
        AVAssetReaderTrackOutput *output=track?[[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES}]:nil;
        if(!reader||!output||![reader canAddOutput:output]){fail(@"prepare-decoder",error.localizedDescription?:@"No decodable video track.",-1,error);break;}
        [reader addOutput:output];if(![reader startReading]){fail(@"start-decoder",reader.error.localizedDescription,-1,reader.error);break;}
        report[@"nominalSourceFPS"]=@(track.nominalFrameRate);
        setupMs+=(nowSeconds()-setupStarted)*1000;
        for(int index=0;index<limit;index++) { @autoreleasepool {
            const double decodeStarted=nowSeconds();CMSampleBufferRef sample=[output copyNextSampleBuffer];
            double decodeMs=(nowSeconds()-decodeStarted)*1000;decodeTotalMs+=decodeMs;
            if(!sample){eof=reader.status==AVAssetReaderStatusCompleted;if(!eof)fail(@"decode",reader.error.localizedDescription?:@"Decoder returned no frame before completion.",index,reader.error);break;}
            decoded++;CVPixelBufferRef source=CMSampleBufferGetImageBuffer(sample);CMTime pts=CMSampleBufferGetPresentationTimeStamp(sample);
            if(!source||!CMTIME_IS_NUMERIC(pts)){fail(@"source-frame",@"Missing source pixel buffer or numeric PTS.",index);CFRelease(sample);break;}
            OSType sourceFormat=CVPixelBufferGetPixelFormatType(source);
            if(sourceFormat!=kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange&&sourceFormat!=kCVPixelFormatType_420YpCbCr8BiPlanarFullRange){fail(@"source-format",[NSString stringWithFormat:@"Expected SDR 8-bit NV12, got %@; P010 is not reinterpreted.",formatName(sourceFormat)],index);CFRelease(sample);break;}
            int64_t ptsUs=CMTimeConvertScale(pts,1000000,kCMTimeRoundingMethod_RoundHalfAwayFromZero).value;
            if(previousPTS!=INT64_MIN&&ptsUs<=previousPTS){monotonic=false;fail(@"source-pts",@"Source PTS is not strictly increasing.",index);CFRelease(sample);break;}
            previousPTS=ptsUs;
            if(!scaler) {
                const double preparedAt=nowSeconds();int w=(int)CVPixelBufferGetWidth(source),h=(int)CVPixelBufferGetHeight(source);
                report[@"sourceWidth"]=@(w);report[@"sourceHeight"]=@(h);report[@"sourcePixelFormat"]=formatName(sourceFormat);report[@"sourceColorAttachments"]=colors(source);
                id<MTLDevice> device=MTLCreateSystemDefaultDevice();report[@"metalDevice"]=device.name?:@"unavailable";
                if([engine isEqualToString:@"lanczos"])scaler=[[SPFileLanczosScaler alloc] initWithDevice:device width:targetWidth height:targetHeight error:&error];
                else if([engine isEqualToString:@"metalfx"]||[engine isEqualToString:@"metalfx.spatial"])scaler=[[SPFileMetalFXScaler alloc] initWithDevice:device sourceWidth:w sourceHeight:h outputWidth:targetWidth outputHeight:targetHeight error:&error];
                else if([engine isEqualToString:@"apple-low"]||[engine isEqualToString:@"apple.low-sr"])scaler=[[SPFileAppleSRScaler alloc] initWithSourceWidth:w sourceHeight:h outputWidth:targetWidth outputHeight:targetHeight error:&error];
                else if([engine isEqualToString:@"apple-video"]||[engine isEqualToString:@"apple.video-sr"])scaler=[[SPFileAppleVideoSRScaler alloc] initWithSourceWidth:w sourceHeight:h outputWidth:targetWidth outputHeight:targetHeight error:&error];
                else if([engine isEqualToString:@"anime4k"]||[engine isEqualToString:@"realcugan"]||[engine isEqualToString:@"cugan"]) {
                    if(targetWidth!=w*2||targetHeight!=h*2){fail(@"prepare-scaler",@"Anime4K and Real-CUGAN require their native 2x output.",index);CFRelease(sample);break;}
                    NSBundle *bundle=[NSBundle bundleWithPath:resourcePath];
                    if(!bundle){fail(@"resource-bundle",@"Cannot load resource app bundle.",index);CFRelease(sample);break;}
                    scaler=[[SPFileAnimationScaler alloc] initWithSourceWidth:w sourceHeight:h engine:[engine isEqualToString:@"cugan"]?@"realcugan":engine variant:variant resourceBundle:bundle error:&error];
                } else {fail(@"arguments",@"Unknown engine.",index);CFRelease(sample);break;}
                setupMs+=(nowSeconds()-preparedAt)*1000;
                if(!scaler){fail(@"prepare-scaler",error.localizedDescription?:@"Scaler initialization failed.",index,error);CFRelease(sample);break;}
            }
            auto state=std::make_shared<CompletionState>();const double submittedAt=nowSeconds();
            BOOL accepted=[scaler submit:source ptsUs:ptsUs completion:^(CVPixelBufferRef image,NSError *failure){state->output=image;state->error=failure;state->completedAt=nowSeconds();state->done.store(true,std::memory_order_release);}];
            if(!accepted){fail(@"submit",@"Scaler rejected frame; no fallback is substituted.",index);CFRelease(sample);break;}
            const double deadline=submittedAt+120;
            while(!state->done.load(std::memory_order_acquire)&&nowSeconds()<deadline)[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.002]];
            if(!state->done.load(std::memory_order_acquire)){fail(@"completion",@"Timed out waiting 120 seconds for scaler callback.",index);CFRelease(sample);break;}
            double processingMs=(state->completedAt-submittedAt)*1000;
            if(!state->output||state->error){fail(@"processing",state->error.localizedDescription?:@"Scaler completed without output.",index,state->error);CFRelease(sample);break;}
            CVPixelBufferRef result=state->output;OSType resultFormat=CVPixelBufferGetPixelFormatType(result);
            if(CVPixelBufferGetWidth(result)!=(size_t)targetWidth||CVPixelBufferGetHeight(result)!=(size_t)targetHeight){fail(@"output-dimensions",@"Scaler returned unexpected dimensions.",index);CFRelease(sample);break;}
            bool sameFormat=resultFormat==sourceFormat;allFormat=allFormat&&sameFormat;
            NSDictionary *inputColor=colors(source),*outputColor=colors(result);bool sameColor=[inputColor isEqualToDictionary:outputColor];allColor=allColor&&sameColor;
            if(!processed){report[@"outputPixelFormat"]=formatName(resultFormat);report[@"outputColorAttachments"]=outputColor;}
            processed++;times.push_back(processingMs);
            const double exportStarted=nowSeconds();NSString *writeReason=nil;bool saved=writeNV12(raw,result,rawBytes,&writeReason);double exportMs=(nowSeconds()-exportStarted)*1000;exportTotalMs+=exportMs;
            [frames addObject:@{@"index":@(index),@"ptsUs":@(ptsUs),@"decodeMs":@(decodeMs),@"processingMs":@(processingMs),@"exportMs":@(exportMs),@"samePixelFormat":@(sameFormat),@"colorAttachmentsPreserved":@(sameColor),@"exported":@(saved)}];
            CFRelease(sample);
            if(!saved){fail(@"export",writeReason,index);break;}
            exported++;
        }
            if(report[@"firstError"]!=NSNull.null||eof)break;
        }
    } while(false);
    if(raw&&fclose(raw)!=0)fail(@"close-output",[NSString stringWithUTF8String:strerror(errno)],processed);
    if([scaler isKindOfClass:SPFileAppleVideoSRScaler.class])report[@"submissionDiagnostics"]=[(SPFileAppleVideoSRScaler *)scaler submissionDiagnostics];
    report[@"readerStatus"]=@(reader.status);if(reader.status==AVAssetReaderStatusReading)[reader cancelReading];
    report[@"framesDecoded"]=@(decoded);report[@"framesProcessed"]=@(processed);report[@"framesExported"]=@(exported);report[@"requestedFramesSatisfied"]=@(exported==limit);report[@"endOfInput"]=@(eof);
    report[@"rawBytes"]=@(rawBytes);report[@"expectedRawBytes"]=@((uint64_t)targetWidth*targetHeight*3/2*exported);report[@"rawPixelLayout"]=@"NV12: tightly packed Y rows, then interleaved UV rows; row padding excluded";
    report[@"sourcePTSMonotonic"]=@(monotonic);report[@"allColorAttachmentsPreserved"]=@(allColor&&processed>0);report[@"allPixelFormatsPreserved"]=@(allFormat&&processed>0);
    report[@"setupMs"]=@(setupMs);report[@"decodeTotalMs"]=@(decodeTotalMs);report[@"exportTotalMs"]=@(exportTotalMs);report[@"processingMs"]=statistics(times);report[@"coldFirstFrameMs"]=times.empty()?(id)NSNull.null:@(times.front());
    size_t discarded=std::min((size_t)5,times.size());report[@"steadyStateExcludedFrames"]=@(discarded);report[@"steadyStateProcessingMs"]=statistics(std::vector<double>(times.begin()+discarded,times.end()));
    report[@"perFrame"]=frames;report[@"wallMs"]=@((nowSeconds()-started)*1000);
    BOOL ok=report[@"firstError"]==NSNull.null&&exported>0&&processed==exported;report[@"ok"]=@(ok);
    NSError *serializationError=nil;NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:&serializationError];
    if(!data||![data writeToFile:jsonPath options:NSDataWritingAtomic error:&serializationError]){fprintf(stderr,"result JSON: %s\n",serializationError.localizedDescription.UTF8String);return 3;}
    printf("%s: %d processed, %d exported; result=%s\n",ok?"ok":"failed",processed,exported,jsonPath.fileSystemRepresentation);
    return ok?0:1;
}
int main(int argc,const char **argv){@autoreleasepool{return run(argc,argv);}}
