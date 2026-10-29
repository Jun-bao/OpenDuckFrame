#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import "SPFileMetalFXScaler.h"
#include <cmath>
#include <initializer_list>
int main(){@autoreleasepool{
 struct C {const char *name;CFStringRef matrix,primaries;} cases[]={{"601",kCVImageBufferYCbCrMatrix_ITU_R_601_4,kCVImageBufferColorPrimaries_SMPTE_C},{"601-ebu",kCVImageBufferYCbCrMatrix_ITU_R_601_4,kCVImageBufferColorPrimaries_EBU_3213},{"709",kCVImageBufferYCbCrMatrix_ITU_R_709_2,kCVImageBufferColorPrimaries_ITU_R_709_2},{"2020",kCVImageBufferYCbCrMatrix_ITU_R_2020,kCVImageBufferColorPrimaries_ITU_R_2020}};
 NSError *error=nil;SPFileMetalFXScaler *scaler=[[SPFileMetalFXScaler alloc] initWithDevice:MTLCreateSystemDefaultDevice() sourceWidth:160 sourceHeight:96 outputWidth:320 outputHeight:192 error:&error];if(!scaler){fprintf(stderr,"prepare: %s\n",error.localizedDescription.UTF8String);return 2;}BOOL all=YES;
 for(auto c:cases)for(int full=0;full<2;full++){
  OSType format=full?kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};CVPixelBufferRef src=NULL;
  if(CVPixelBufferCreate(NULL,160,96,format,(__bridge CFDictionaryRef)attrs,&src)!=kCVReturnSuccess)return 2;
  CVBufferSetAttachment(src,kCVImageBufferYCbCrMatrixKey,c.matrix,kCVAttachmentMode_ShouldPropagate);CVBufferSetAttachment(src,kCVImageBufferColorPrimariesKey,c.primaries,kCVAttachmentMode_ShouldPropagate);CVBufferSetAttachment(src,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
  CVPixelBufferLockBaseAddress(src,0);auto y=(uint8_t*)CVPixelBufferGetBaseAddressOfPlane(src,0),uv=(uint8_t*)CVPixelBufferGetBaseAddressOfPlane(src,1);size_t sy=CVPixelBufferGetBytesPerRowOfPlane(src,0),su=CVPixelBufferGetBytesPerRowOfPlane(src,1);memset(y,120,sy*96);for(int r=0;r<48;r++)for(int x=0;x<160;x+=2){uv[r*su+x]=85;uv[r*su+x+1]=200;}CVPixelBufferUnlockBaseAddress(src,0);
  dispatch_semaphore_t done=dispatch_semaphore_create(0);__block CVPixelBufferRef dst=NULL;__block NSError *failure=nil;BOOL accepted=[scaler submit:src ptsUs:1234567 completion:^(CVPixelBufferRef b,NSError *e){dst=b;failure=e;dispatch_semaphore_signal(done);}];BOOL finished=accepted&&dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC))==0&&!failure&&dst;int Y=-1,Cb=-1,Cr=-1;
  if(finished){CVPixelBufferLockBaseAddress(dst,kCVPixelBufferLock_ReadOnly);auto a=(uint8_t*)CVPixelBufferGetBaseAddressOfPlane(dst,0),b=(uint8_t*)CVPixelBufferGetBaseAddressOfPlane(dst,1);Y=a[96*CVPixelBufferGetBytesPerRowOfPlane(dst,0)+160];b+=48*CVPixelBufferGetBytesPerRowOfPlane(dst,1)+160;Cb=b[0];Cr=b[1];CVPixelBufferUnlockBaseAddress(dst,kCVPixelBufferLock_ReadOnly);}
  BOOL meta=finished;for(CFStringRef key:{kCVImageBufferYCbCrMatrixKey,kCVImageBufferColorPrimariesKey,kCVImageBufferTransferFunctionKey}){CFTypeRef a=CVBufferCopyAttachment(src,key,NULL),b=dst?CVBufferCopyAttachment(dst,key,NULL):NULL;meta &= a&&b&&CFEqual(a,b);if(a)CFRelease(a);if(b)CFRelease(b);}
  BOOL reject=strcmp(c.name,"2020")==0;BOOL ok=reject?(!dst&&failure!=nil):(finished&&meta&&abs(Y-120)<=8&&abs(Cb-85)<=8&&abs(Cr-200)<=8);all &=ok;printf("{\"ok\":%s,\"matrix\":\"%s\",\"range\":\"%s\",\"yuv\":[%d,%d,%d],\"expectedRejected\":%s,\"metadata\":%s,\"error\":\"%s\",\"scope\":\"actual MetalFX constant-color sample; no GUI or AV\"}\n",ok?"true":"false",c.name,full?"full":"video",Y,Cb,Cr,reject?"true":"false",meta?"true":"false",failure.localizedDescription.UTF8String?:"");if(dst)CVPixelBufferRelease(dst);CVPixelBufferRelease(src);
 }
 return all?0:1;
}}
