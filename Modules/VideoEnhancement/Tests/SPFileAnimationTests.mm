#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "SPFileAnimationScaler.h"

int main(int argc,const char **argv) { @autoreleasepool {
    if(argc!=5)return 2;
    NSString *engine=[NSString stringWithUTF8String:argv[1]], *variant=[NSString stringWithUTF8String:argv[2]];
    NSBundle *bundle=[NSBundle bundleWithPath:[NSString stringWithUTF8String:argv[3]]];
    AVURLAsset *asset=[AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[4]]] options:nil];
    AVAssetTrack *track=[[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];NSError *error=nil;
    AVAssetReader *reader=track?[[AVAssetReader alloc] initWithAsset:asset error:&error]:nil;
    AVAssetReaderTrackOutput *out=track?[[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES}]:nil;
    if(!bundle||!reader||!out||![reader canAddOutput:out])return 3;[reader addOutput:out];if(![reader startReading])return 3;
    CMSampleBufferRef first=[out copyNextSampleBuffer];if(!first)return 3;CFRelease(first);
    CMSampleBufferRef sample=[out copyNextSampleBuffer];if(!sample)return 3;
    CVPixelBufferRef source=CMSampleBufferGetImageBuffer(sample);CMTime pts=CMSampleBufferGetPresentationTimeStamp(sample);
    CFTypeRef matrix=CVBufferCopyAttachment(source,kCVImageBufferYCbCrMatrixKey,NULL);
    CFTypeRef primaries=CVBufferCopyAttachment(source,kCVImageBufferColorPrimariesKey,NULL);
    CFTypeRef transfer=CVBufferCopyAttachment(source,kCVImageBufferTransferFunctionKey,NULL);
    if(!matrix||!primaries||!transfer){fprintf(stderr,"decoded frame missing color information\n");return 4;}
    SPFileAnimationScaler *scaler=[[SPFileAnimationScaler alloc] initWithSourceWidth:160 sourceHeight:96 engine:engine variant:variant resourceBundle:bundle error:&error];
    if(!scaler){fprintf(stderr,"prepare: %s\n",error.localizedDescription.UTF8String);return 5;}
    __block BOOL invalidRejected=NO;[scaler submit:source ptsUs:INT64_MIN completion:^(CVPixelBufferRef output,NSError *failure){invalidRejected=!output&&failure!=nil;if(output)CVPixelBufferRelease(output);}];
    CVBufferRemoveAttachment(source,kCVImageBufferYCbCrMatrixKey);
    __block BOOL unknownColorRejected=NO;[scaler submit:source ptsUs:1234567 completion:^(CVPixelBufferRef output,NSError *failure){unknownColorRejected=!output&&failure!=nil;if(output)CVPixelBufferRelease(output);}];
    CVBufferSetAttachment(source,kCVImageBufferYCbCrMatrixKey,matrix,kCVAttachmentMode_ShouldPropagate);
    dispatch_semaphore_t done=dispatch_semaphore_create(0);__block BOOL valid=NO, metadata=NO, nonflat=NO;__block NSString *reason=@"";
    OSType format=CVPixelBufferGetPixelFormatType(source);int64_t ptsUs=CMTimeConvertScale(pts,1000000,kCMTimeRoundingMethod_RoundHalfAwayFromZero).value;
    BOOL accepted=[scaler submit:source ptsUs:ptsUs completion:^(CVPixelBufferRef output,NSError *failure){
        valid=output&&!failure&&CVPixelBufferGetWidth(output)==320&&CVPixelBufferGetHeight(output)==192&&CVPixelBufferGetPixelFormatType(output)==format;
        if(output){
            CFTypeRef m=CVBufferCopyAttachment(output,kCVImageBufferYCbCrMatrixKey,NULL),p=CVBufferCopyAttachment(output,kCVImageBufferColorPrimariesKey,NULL),t=CVBufferCopyAttachment(output,kCVImageBufferTransferFunctionKey,NULL);
            metadata=m&&p&&t&&CFEqual(m,matrix)&&CFEqual(p,primaries)&&CFEqual(t,transfer);if(m)CFRelease(m);if(p)CFRelease(p);if(t)CFRelease(t);
            CVPixelBufferLockBaseAddress(output,kCVPixelBufferLock_ReadOnly);const uint8_t *y=(const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(output,0);size_t pitch=CVPixelBufferGetBytesPerRowOfPlane(output,0);int lo=255,hi=0;
            for(int row=0;row<192;row+=8)for(int col=0;col<320;col+=8){int v=y[row*pitch+col];if(v<lo)lo=v;if(v>hi)hi=v;}nonflat=hi-lo>20;CVPixelBufferUnlockBaseAddress(output,kCVPixelBufferLock_ReadOnly);
            CVPixelBufferRelease(output);
        }
        reason=failure.localizedDescription ?: @"";dispatch_semaphore_signal(done);
    }];
    BOOL completed=accepted&&dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,60*NSEC_PER_SEC))==0;
    if(!completed||!valid)fprintf(stderr,"processing: %s\n",reason.UTF8String);
    BOOL ok=completed&&valid&&metadata&&nonflat&&invalidRejected&&unknownColorRejected&&ptsUs>0;
    printf("{\"ok\":%s,\"engine\":\"%s\",\"variant\":\"%s\",\"actualDecodedPTSUs\":%lld,\"output\":\"320x192 NV12\",\"colorAttachments\":%s,\"nonflat\":%s,\"invalidPTSRejected\":%s,\"unknownColorRejected\":%s,\"scope\":\"one decoded frame and actual bundled backend; no app, window, drawable, GUI, sustained playback or A/V sync\"}\n",ok?"true":"false",argv[1],argv[2],(long long)ptsUs,metadata?"true":"false",nonflat?"true":"false",invalidRejected?"true":"false",unknownColorRejected?"true":"false");
    CFRelease(matrix);CFRelease(primaries);CFRelease(transfer);CFRelease(sample);return ok?0:6;
} }
