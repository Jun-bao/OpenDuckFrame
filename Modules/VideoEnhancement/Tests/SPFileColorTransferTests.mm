#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#import "SPFileColorTransfer.h"
#include <cmath>
#include <initializer_list>

int main() { @autoreleasepool {
    NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};
    struct Case {const char *name; CFStringRef matrix; CFStringRef primaries; double kr;};
    Case cases[]={{"601",kCVImageBufferYCbCrMatrix_ITU_R_601_4,kCVImageBufferColorPrimaries_SMPTE_C,0.299},
                  {"709",kCVImageBufferYCbCrMatrix_ITU_R_709_2,kCVImageBufferColorPrimaries_ITU_R_709_2,0.2126},
                  {"2020",kCVImageBufferYCbCrMatrix_ITU_R_2020,kCVImageBufferColorPrimaries_ITU_R_2020,0.2627}};
    VTPixelTransferSessionRef session=NULL;if(VTPixelTransferSessionCreate(NULL,&session)!=noErr)return 2;
    bool all=true;
    for(auto c:cases) for(int full=0;full<2;full++) {
        OSType fmt=full?kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
        CVPixelBufferRef rgb=NULL,yuv=NULL,back=NULL;
        if(CVPixelBufferCreate(NULL,32,32,kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)attrs,&rgb)!=kCVReturnSuccess||
           CVPixelBufferCreate(NULL,32,32,fmt,(__bridge CFDictionaryRef)attrs,&yuv)!=kCVReturnSuccess||
           CVPixelBufferCreate(NULL,32,32,kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)attrs,&back)!=kCVReturnSuccess)return 2;
        for(CVPixelBufferRef b:{rgb,yuv,back}) {
            CVBufferSetAttachment(b,kCVImageBufferColorPrimariesKey,c.primaries,kCVAttachmentMode_ShouldPropagate);
            CVBufferSetAttachment(b,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
        }
        CVBufferSetAttachment(yuv,kCVImageBufferYCbCrMatrixKey,c.matrix,kCVAttachmentMode_ShouldPropagate);
        CVPixelBufferLockBaseAddress(rgb,0);uint8_t *p=(uint8_t *)CVPixelBufferGetBaseAddress(rgb);size_t stride=CVPixelBufferGetBytesPerRow(rgb);
        for(int y=0;y<32;y++)for(int x=0;x<32;x++){uint8_t *q=p+y*stride+x*4;q[0]=0;q[1]=0;q[2]=255;q[3]=255;}
        CVPixelBufferUnlockBaseAddress(rgb,0);
        BOOL configured=SPConfigureFileColorTransfer(session,yuv,YES);
        OSStatus a=configured?VTPixelTransferSessionTransferImage(session,rgb,yuv):-1;
        BOOL reverseConfigured=SPConfigureFileColorTransfer(session,yuv,NO);
        OSStatus b=reverseConfigured?VTPixelTransferSessionTransferImage(session,yuv,back):-1;
        CVPixelBufferLockBaseAddress(yuv,kCVPixelBufferLock_ReadOnly);int actual=*((uint8_t *)CVPixelBufferGetBaseAddressOfPlane(yuv,0));CVPixelBufferUnlockBaseAddress(yuv,kCVPixelBufferLock_ReadOnly);
        CVPixelBufferLockBaseAddress(back,kCVPixelBufferLock_ReadOnly);const uint8_t *q=(const uint8_t *)CVPixelBufferGetBaseAddress(back);int blue=q[0],green=q[1],red=q[2];CVPixelBufferUnlockBaseAddress(back,kCVPixelBufferLock_ReadOnly);
        int expected=(int)lround((full?255.0:219.0)*c.kr+(full?0.0:16.0));
        bool ok=configured&&reverseConfigured&&a==noErr&&b==noErr&&abs(actual-expected)<=5&&red>=235&&green<=16&&blue<=16;all &=ok;
        printf("{\"matrix\":\"%s\",\"range\":\"%s\",\"y\":%d,\"expectedY\":%d,\"roundtripRGB\":[%d,%d,%d],\"ok\":%s}\n",c.name,full?"full":"video",actual,expected,red,green,blue,ok?"true":"false");
        CVPixelBufferRelease(rgb);CVPixelBufferRelease(yuv);CVPixelBufferRelease(back);
    }
    CFRelease(session);return all?0:1;
} }
