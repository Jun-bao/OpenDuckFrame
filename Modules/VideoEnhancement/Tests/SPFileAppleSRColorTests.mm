#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import "SPFileAppleSRScaler.h"
#include <cmath>

int main(){ @autoreleasepool {
    struct Case {const char *name; CFStringRef matrix,primaries; int y,u,v;};
    Case cases[]={{"601",kCVImageBufferYCbCrMatrix_ITU_R_601_4,kCVImageBufferColorPrimaries_SMPTE_C,81,90,240},
                  {"709",kCVImageBufferYCbCrMatrix_ITU_R_709_2,kCVImageBufferColorPrimaries_ITU_R_709_2,63,102,240},
                  {"2020",kCVImageBufferYCbCrMatrix_ITU_R_2020,kCVImageBufferColorPrimaries_ITU_R_2020,74,97,240}};
    NSError *error=nil;SPFileAppleSRScaler *scaler=[[SPFileAppleSRScaler alloc] initWithSourceWidth:1280 sourceHeight:720 outputWidth:1920 outputHeight:1080 error:&error];
    if(!scaler){fprintf(stderr,"prepare: %s\n",error.localizedDescription.UTF8String);return 2;}
    NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};bool all=true;
    for(auto c:cases){
        CVPixelBufferRef input=NULL;if(CVPixelBufferCreate(NULL,1280,720,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,(__bridge CFDictionaryRef)attrs,&input)!=kCVReturnSuccess)return 2;
        CVBufferSetAttachment(input,kCVImageBufferYCbCrMatrixKey,c.matrix,kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(input,kCVImageBufferColorPrimariesKey,c.primaries,kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(input,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
        CVPixelBufferLockBaseAddress(input,0);for(int plane=0;plane<2;plane++){uint8_t *p=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(input,plane);size_t stride=CVPixelBufferGetBytesPerRowOfPlane(input,plane),w=CVPixelBufferGetWidthOfPlane(input,plane),h=CVPixelBufferGetHeightOfPlane(input,plane);for(size_t y=0;y<h;y++)for(size_t x=0;x<w;x++){if(!plane)p[y*stride+x]=c.y;else {p[y*stride+2*x]=c.u;p[y*stride+2*x+1]=c.v;}}}CVPixelBufferUnlockBaseAddress(input,0);
        dispatch_semaphore_t done=dispatch_semaphore_create(0);__block int y=-1,u=-1,v=-1;__block BOOL metadata=NO;
        BOOL accepted=[scaler submit:input ptsUs:1234567 completion:^(CVPixelBufferRef output,NSError *failure){if(output&&!failure){CFTypeRef m=CVBufferCopyAttachment(output,kCVImageBufferYCbCrMatrixKey,NULL);metadata=m&&CFEqual(m,c.matrix);if(m)CFRelease(m);CVPixelBufferLockBaseAddress(output,kCVPixelBufferLock_ReadOnly);const uint8_t *yp=(const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(output,0),*uv=(const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(output,1);size_t ys=CVPixelBufferGetBytesPerRowOfPlane(output,0),us=CVPixelBufferGetBytesPerRowOfPlane(output,1);y=yp[540*ys+960];u=uv[270*us+960];v=uv[270*us+961];CVPixelBufferUnlockBaseAddress(output,kCVPixelBufferLock_ReadOnly);CVPixelBufferRelease(output);}dispatch_semaphore_signal(done);}];
        BOOL complete=accepted&&dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC))==0;
        bool ok=complete&&metadata&&abs(y-c.y)<=12&&abs(u-c.u)<=16&&abs(v-c.v)<=16;all &=ok;
        printf("{\"matrix\":\"%s\",\"inputYUV\":[%d,%d,%d],\"outputYUV\":[%d,%d,%d],\"metadata\":%s,\"ok\":%s,\"scope\":\"one constant-color actual Apple SR frame; not visual quality or playback\"}\n",c.name,c.y,c.u,c.v,y,u,v,metadata?"true":"false",ok?"true":"false");CVPixelBufferRelease(input);
    }return all?0:1;
} }
