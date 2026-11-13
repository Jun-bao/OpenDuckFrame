#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "SPAppleLowLatencySR.h"
#import "SPFileAppleSRScaler.h"
#import "SPAppleVideoSR.h"
#import "SPFileAppleVideoSRScaler.h"

static CVPixelBufferRef fullHDFrame(void) {
    NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};
    CVPixelBufferRef buffer=NULL;
    if (CVPixelBufferCreate(NULL,1920,1080,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,(__bridge CFDictionaryRef)attrs,&buffer)!=kCVReturnSuccess) return NULL;
    CVBufferSetAttachment(buffer,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    CVPixelBufferLockBaseAddress(buffer,0);
    memset(CVPixelBufferGetBaseAddressOfPlane(buffer,0),100,CVPixelBufferGetBytesPerRowOfPlane(buffer,0)*1080);
    memset(CVPixelBufferGetBaseAddressOfPlane(buffer,1),128,CVPixelBufferGetBytesPerRowOfPlane(buffer,1)*540);
    CVPixelBufferUnlockBaseAddress(buffer,0);
    return buffer;
}

static BOOL runAutomatic(SPFileLanczosScaler *scaler, CVPixelBufferRef input, int width, int height) {
    if (!scaler || !input || scaler.outputWidth != width || scaler.outputHeight != height) return NO;
    dispatch_semaphore_t done=dispatch_semaphore_create(0); __block BOOL valid=NO;
    BOOL accepted=[scaler submit:input ptsUs:1000000 completion:^(CVPixelBufferRef output,NSError *error){
        valid=output && !error && CVPixelBufferGetWidth(output)==(size_t)width && CVPixelBufferGetHeight(output)==(size_t)height &&
          CVPixelBufferGetPixelFormatType(output)==CVPixelBufferGetPixelFormatType(input);
        if(output) CVPixelBufferRelease(output); dispatch_semaphore_signal(done);
    }];
    return accepted && dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,45*NSEC_PER_SEC))==0 && valid;
}

int main(int argc,const char **argv) { @autoreleasepool {
    if (argc!=2) return 2;
    AVURLAsset *asset=[AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]] options:nil];
    AVAssetTrack *track=[[asset tracksWithMediaType:AVMediaTypeVideo] firstObject]; NSError *error=nil;
    AVAssetReader *reader=track?[[AVAssetReader alloc] initWithAsset:asset error:&error]:nil;
    AVAssetReaderTrackOutput *out=track?[[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES}]:nil;
    if (!reader || !out || ![reader canAddOutput:out]) return 3;
    [reader addOutput:out]; if (![reader startReading]) return 3;
    CMSampleBufferRef sample=[out copyNextSampleBuffer]; if (!sample) return 3;
    CVPixelBufferRef source=CMSampleBufferGetImageBuffer(sample); CMTime pts=CMSampleBufferGetPresentationTimeStamp(sample);
    NSArray<NSNumber *> *factors=[SPAppleLowLatencySR supportedFactorsForWidth:1280 height:720];
    BOOL supported=NO; for (NSNumber *f in factors) if (fabs(f.doubleValue-1.5)<0.0001) supported=YES;
    if (!supported) { printf("{\"ok\":false,\"supported\":false,\"reason\":\"720p x1.5 not supported by this device\"}\n"); CFRelease(sample); return 4; }
    SPFileAppleSRScaler *scaler=[[SPFileAppleSRScaler alloc] initWithSourceWidth:1280 sourceHeight:720 outputWidth:1920 outputHeight:1080 error:&error];
    if (!scaler) { fprintf(stderr,"prepare: %s\n",error.localizedDescription.UTF8String); CFRelease(sample);return 5; }
    __block BOOL invalidRejected=NO; [scaler submit:source ptsUs:INT64_MIN completion:^(CVPixelBufferRef output,NSError *failure){invalidRejected=!output && failure!=nil;if(output) CVPixelBufferRelease(output);}];
    dispatch_semaphore_t done=dispatch_semaphore_create(0); __block BOOL valid=NO; __block NSString *reason=@"";
    OSType expected=CVPixelBufferGetPixelFormatType(source);
    BOOL accepted=[scaler submit:source ptsUs:CMTimeConvertScale(pts,1000000,kCMTimeRoundingMethod_RoundHalfAwayFromZero).value completion:^(CVPixelBufferRef result,NSError *failure){
        valid=result && !failure && CVPixelBufferGetWidth(result)==1920 && CVPixelBufferGetHeight(result)==1080 && CVPixelBufferGetPixelFormatType(result)==expected;
        reason=failure.localizedDescription ?: @""; if(result)CVPixelBufferRelease(result); dispatch_semaphore_signal(done);
    }];
    BOOL completed=accepted && dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC))==0;
    if(!completed||!valid) fprintf(stderr,"SR: %s\n",reason.UTF8String);
    CVPixelBufferRef fullHD=fullHDFrame();
    SPFileAppleSRScaler *autoLow=[[SPFileAppleSRScaler alloc] initWithSourceWidth:1920 sourceHeight:1080 outputWidth:0 outputHeight:0 error:&error];
    BOOL lowAuto=runAutomatic(autoLow,fullHD,1920,1080);
    NSSize videoInput=[SPAppleVideoSR automaticInputForWidth:1920 height:1080];
    NSSize videoOutput=[SPAppleVideoSR automaticOutputForWidth:(int)videoInput.width height:(int)videoInput.height];
    BOOL videoReady=videoInput.width>0 && videoOutput.width>0 && [SPAppleVideoSR isReadyForWidth:(int)videoInput.width height:(int)videoInput.height scale:(int)(videoOutput.width/videoInput.width)];
    SPFileAppleVideoSRScaler *autoVideo=videoReady ? [[SPFileAppleVideoSRScaler alloc] initWithSourceWidth:1920 sourceHeight:1080 outputWidth:0 outputHeight:0 error:&error] : nil;
    BOOL videoAuto=videoReady && runAutomatic(autoVideo,fullHD,(int)videoOutput.width,(int)videoOutput.height);
    if(fullHD) CVPixelBufferRelease(fullHD);
    CFRelease(sample); BOOL ok=completed&&valid&&invalidRejected&&lowAuto&&videoAuto;
    printf("{\"ok\":%s,\"supported\":%s,\"decodedNV12\":true,\"output\":\"1920x1080 NV12\",\"invalidPTSRejected\":%s,\"automaticLowFrom1080\":%s,\"automaticVideoFrom1080\":%s,\"videoModelReady\":%s,\"scope\":\"actual Apple SR frames and NV12 conversion; no UI, drawable, sustained playback or A/V sync\"}\n",ok?"true":"false",supported?"true":"false",invalidRejected?"true":"false",lowAuto?"true":"false",videoAuto?"true":"false",videoReady?"true":"false"); return ok?0:6;
} }
