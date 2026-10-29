#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <Metal/Metal.h>
#import "SPFileMetalFXScaler.h"
#include <cmath>
static CVPixelBufferRef run(SPFileMetalFXScaler *scaler,CVPixelBufferRef input,int64_t pts,NSError **error){
    dispatch_semaphore_t done=dispatch_semaphore_create(0);__block CVPixelBufferRef result=NULL;__block NSError *failure=nil;
    BOOL accepted=[scaler submit:input ptsUs:pts completion:^(CVPixelBufferRef b,NSError *e){result=b;failure=e;dispatch_semaphore_signal(done);}];
    if(!accepted||dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC))!=0){if(error)*error=[NSError errorWithDomain:@"test" code:1 userInfo:nil];return NULL;}if(error)*error=failure;return result;
}
int main(int argc,const char **argv){@autoreleasepool{
    if(argc!=2)return 2;AVURLAsset *asset=[AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]] options:nil];AVAssetTrack *track=[[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];NSError *error=nil;AVAssetReader *reader=[[AVAssetReader alloc] initWithAsset:asset error:&error];
    AVAssetReaderTrackOutput *out=[[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES}];
    if(!track||!reader||![reader canAddOutput:out])return 2;[reader addOutput:out];if(![reader startReading])return 2;CMSampleBufferRef first=[out copyNextSampleBuffer];if(!first)return 2;CFRelease(first);CMSampleBufferRef sample=[out copyNextSampleBuffer];if(!sample)return 2;
    CVPixelBufferRef frame=CMSampleBufferGetImageBuffer(sample);int64_t pts=CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample),1000000,kCMTimeRoundingMethod_RoundHalfAwayFromZero).value;
    SPFileMetalFXScaler *scaler=[[SPFileMetalFXScaler alloc] initWithDevice:MTLCreateSystemDefaultDevice() sourceWidth:160 sourceHeight:96 outputWidth:320 outputHeight:192 error:&error];if(!scaler){fprintf(stderr,"prepare: %s\n",error.localizedDescription.UTF8String);return 3;}
    CVPixelBufferRef result=run(scaler,frame,pts,&error);BOOL valid=result&&!error&&CVPixelBufferGetWidth(result)==320&&CVPixelBufferGetHeight(result)==192&&CVPixelBufferGetPixelFormatType(result)==CVPixelBufferGetPixelFormatType(frame);BOOL meta=valid;
    for(CFStringRef key:{kCVImageBufferYCbCrMatrixKey,kCVImageBufferColorPrimariesKey,kCVImageBufferTransferFunctionKey}){CFTypeRef a=CVBufferCopyAttachment(frame,key,NULL),b=result?CVBufferCopyAttachment(result,key,NULL):NULL;meta &= a&&b&&CFEqual(a,b);if(a)CFRelease(a);if(b)CFRelease(b);}
    int min=255,max=0;if(result){CVPixelBufferLockBaseAddress(result,kCVPixelBufferLock_ReadOnly);const uint8_t *y=(const uint8_t*)CVPixelBufferGetBaseAddressOfPlane(result,0);size_t row=CVPixelBufferGetBytesPerRowOfPlane(result,0);for(int r=0;r<192;r+=8)for(int c=0;c<320;c+=8){int v=y[r*row+c];if(v<min)min=v;if(v>max)max=v;}CVPixelBufferUnlockBaseAddress(result,kCVPixelBufferLock_ReadOnly);CVPixelBufferRelease(result);}
    error=nil;CVPixelBufferRef invalid=run(scaler,frame,INT64_MIN,&error);BOOL invalidPTS=!invalid&&error;if(invalid)CVPixelBufferRelease(invalid);
    CFTypeRef matrix=CVBufferCopyAttachment(frame,kCVImageBufferYCbCrMatrixKey,NULL);CVBufferRemoveAttachment(frame,kCVImageBufferYCbCrMatrixKey);error=nil;invalid=run(scaler,frame,pts,&error);BOOL missingColor=!invalid&&error;if(invalid)CVPixelBufferRelease(invalid);if(matrix){CVBufferSetAttachment(frame,kCVImageBufferYCbCrMatrixKey,matrix,kCVAttachmentMode_ShouldPropagate);CFRelease(matrix);}
    BOOL colorOK=YES;int values[2][3]={{-1,-1,-1},{-1,-1,-1}};
    for(int full=0;full<2;full++){
        OSType f=full?kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
        NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};CVPixelBufferRef color=NULL;
        if(CVPixelBufferCreate(NULL,160,96,f,(__bridge CFDictionaryRef)attrs,&color)!=kCVReturnSuccess)return 5;
        CVBufferSetAttachment(color,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(color,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(color,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
        CVPixelBufferLockBaseAddress(color,0);auto cy=(uint8_t*)CVPixelBufferGetBaseAddressOfPlane(color,0),uv=(uint8_t*)CVPixelBufferGetBaseAddressOfPlane(color,1);size_t sy=CVPixelBufferGetBytesPerRowOfPlane(color,0),su=CVPixelBufferGetBytesPerRowOfPlane(color,1);memset(cy,120,sy*96);for(int r=0;r<48;r++)for(int c=0;c<160;c+=2){uv[r*su+c]=85;uv[r*su+c+1]=200;}CVPixelBufferUnlockBaseAddress(color,0);
        error=nil;CVPixelBufferRef scaled=run(scaler,color,1234567,&error);if(scaled){CVPixelBufferLockBaseAddress(scaled,kCVPixelBufferLock_ReadOnly);auto yy=(uint8_t*)CVPixelBufferGetBaseAddressOfPlane(scaled,0),u=(uint8_t*)CVPixelBufferGetBaseAddressOfPlane(scaled,1);values[full][0]=yy[96*CVPixelBufferGetBytesPerRowOfPlane(scaled,0)+160];u+=48*CVPixelBufferGetBytesPerRowOfPlane(scaled,1)+160;values[full][1]=u[0];values[full][2]=u[1];CVPixelBufferUnlockBaseAddress(scaled,kCVPixelBufferLock_ReadOnly);CVPixelBufferRelease(scaled);}CVPixelBufferRelease(color);
        colorOK &= !error && abs(values[full][0]-120)<=8 && abs(values[full][1]-85)<=8 && abs(values[full][2]-200)<=8;
    }
    printf("{\"ok\":%s,\"color709VideoYUV\":[%d,%d,%d],\"color709FullYUV\":[%d,%d,%d]}\n",colorOK?"true":"false",values[0][0],values[0][1],values[0][2],values[1][0],values[1][1],values[1][2]);
    NSError *sameError=nil;SPFileMetalFXScaler *same=[[SPFileMetalFXScaler alloc] initWithDevice:MTLCreateSystemDefaultDevice() sourceWidth:160 sourceHeight:96 outputWidth:160 outputHeight:96 error:&sameError];
    CVPixelBufferRef sameOut=same?run(same,frame,pts,&sameError):NULL;BOOL sameSize=sameOut&&!sameError&&CVPixelBufferGetWidth(sameOut)==160&&CVPixelBufferGetHeight(sameOut)==96;if(sameOut)CVPixelBufferRelease(sameOut);
    printf("{\"ok\":%s,\"sourceSizeMetalFX\":%s,\"error\":\"%s\"}\n",sameSize?"true":"false",sameSize?"true":"false",sameError.localizedDescription.UTF8String?:"");
    BOOL ok=sameSize&&colorOK&&valid&&meta&&max-min>20&&pts>0&&invalidPTS&&missingColor;printf("{\"ok\":%s,\"decodedPTSUs\":%lld,\"output\":\"320x192 NV12\",\"colorAttachments\":%s,\"nonflat\":%s,\"invalidPTSRejected\":%s,\"unknownColorRejected\":%s,\"scope\":\"real MetalFX decoded frame; no drawable/GUI/AV\"}\n",ok?"true":"false",(long long)pts,meta?"true":"false",max-min>20?"true":"false",invalidPTS?"true":"false",missingColor?"true":"false");CFRelease(sample);return ok?0:4;
}}
