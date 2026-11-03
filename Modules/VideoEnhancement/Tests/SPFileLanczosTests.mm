#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import "SPFileLanczosScaler.h"
#include <cmath>

int main() { @autoreleasepool {
    NSError *error = nil;
    SPFileLanczosScaler *scale = [[SPFileLanczosScaler alloc] initWithDevice:MTLCreateSystemDefaultDevice() width:32 height:32 error:&error];
    if (!scale) { fprintf(stderr,"prepare: %s\n",error.localizedDescription.UTF8String); return 1; }
    NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};
    CVPixelBufferRef source=NULL;
    if (CVPixelBufferCreate(NULL,16,16,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,(__bridge CFDictionaryRef)attrs,&source)!=kCVReturnSuccess) return 2;
    CVBufferSetAttachment(source,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(source,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    CVPixelBufferLockBaseAddress(source,0);
    uint8_t *y=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(source,0), *uv=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(source,1);
    size_t ys=CVPixelBufferGetBytesPerRowOfPlane(source,0), uvs=CVPixelBufferGetBytesPerRowOfPlane(source,1);
    for (int row=0;row<16;row++) for (int x=0;x<16;x++) y[row*ys+x]=(uint8_t)(32+x*10);
    for (int row=0;row<8;row++) for (int x=0;x<8;x++) { uv[row*uvs+2*x]=95; uv[row*uvs+2*x+1]=165; }
    CVPixelBufferUnlockBaseAddress(source,0);
    dispatch_semaphore_t done=dispatch_semaphore_create(0);
    __block CVPixelBufferRef result=NULL; __block NSError *failure=nil;
    if (![scale submit:source completion:^(CVPixelBufferRef out,NSError *e){result=out;failure=e;dispatch_semaphore_signal(done);}]) return 3;
    if (dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_SEC)) != 0) { fprintf(stderr,"GPU timeout\n"); return 4; }
    if (!result) { fprintf(stderr,"scale: %s\n",failure.localizedDescription.UTF8String); return 5; }
    bool size=CVPixelBufferGetWidth(result)==32 && CVPixelBufferGetHeight(result)==32;
    bool format=CVPixelBufferGetPixelFormatType(result)==kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    CFTypeRef primary=CVBufferCopyAttachment(result,kCVImageBufferColorPrimariesKey,NULL);
    bool color=primary && CFEqual(primary,kCVImageBufferColorPrimaries_ITU_R_709_2);
    if(primary)CFRelease(primary);
    bool clean=CGRectEqualToRect(CVImageBufferGetCleanRect(result),CGRectMake(0,0,32,32));
    CVPixelBufferLockBaseAddress(result,kCVPixelBufferLock_ReadOnly);
    uint8_t *outY=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(result,0), *outUV=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(result,1);
    size_t outYS=CVPixelBufferGetBytesPerRowOfPlane(result,0), outUVS=CVPixelBufferGetBytesPerRowOfPlane(result,1);
    int l=outY[16*outYS+4], r=outY[16*outYS+27], u=outUV[8*outUVS+8*2], v=outUV[8*outUVS+8*2+1];
    bool pixels=r>l+70 && abs(u-95)<5 && abs(v-165)<5;
    CVPixelBufferUnlockBaseAddress(result,kCVPixelBufferLock_ReadOnly);
    CVPixelBufferRelease(result);
    CVBufferSetAttachment(source,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_2100_HLG,kCVAttachmentMode_ShouldPropagate);
    __block BOOL rejected=NO; dispatch_semaphore_t hdrDone=dispatch_semaphore_create(0);
    [scale submit:source completion:^(CVPixelBufferRef out,NSError *e){rejected=(out==NULL && e!=nil);if(out)CVPixelBufferRelease(out);dispatch_semaphore_signal(hdrDone);}];
    dispatch_semaphore_wait(hdrDone,dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_SEC));
    CVBufferSetAttachment(source,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    NSDictionary *crop=@{(id)kCVImageBufferCleanApertureWidthKey:@8,(id)kCVImageBufferCleanApertureHeightKey:@8,
        (id)kCVImageBufferCleanApertureHorizontalOffsetKey:@0,(id)kCVImageBufferCleanApertureVerticalOffsetKey:@0};
    CVBufferSetAttachment(source,kCVImageBufferCleanApertureKey,(__bridge CFDictionaryRef)crop,kCVAttachmentMode_ShouldPropagate);
    __block BOOL cropRejected=NO;dispatch_semaphore_t cropDone=dispatch_semaphore_create(0);
    [scale submit:source completion:^(CVPixelBufferRef out,NSError *e){cropRejected=(out==NULL && e!=nil);if(out)CVPixelBufferRelease(out);dispatch_semaphore_signal(cropDone);}];
    dispatch_semaphore_wait(cropDone,dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_SEC));
    CVPixelBufferRelease(source);
    CVPixelBufferRef full=NULL;
    bool fullCreated=CVPixelBufferCreate(NULL,16,16,kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,(__bridge CFDictionaryRef)attrs,&full)==kCVReturnSuccess;
    __block BOOL fullRange=NO;dispatch_semaphore_t fullDone=dispatch_semaphore_create(0);
    if(fullCreated) {
        [scale submit:full completion:^(CVPixelBufferRef out,NSError *e){fullRange=out && !e && CVPixelBufferGetPixelFormatType(out)==kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;if(out)CVPixelBufferRelease(out);dispatch_semaphore_signal(fullDone);}];
        dispatch_semaphore_wait(fullDone,dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_SEC));
        CVPixelBufferRelease(full);
    }
    bool ok=size&&format&&color&&clean&&pixels&&rejected&&cropRejected&&fullRange;
    printf("{\"ok\":%s,\"size\":%s,\"nv12\":%s,\"fullRange\":%s,\"colorAttachments\":%s,\"cleanAperture\":%s,\"gradientAndChroma\":%s,\"hdrRejected\":%s,\"cropRejected\":%s,\"sample\":[%d,%d,%d,%d],\"scope\":\"synthetic GPU component; no file playback or GUI\"}\n",ok?"true":"false",size?"true":"false",format?"true":"false",fullRange?"true":"false",color?"true":"false",clean?"true":"false",pixels?"true":"false",rejected?"true":"false",cropRejected?"true":"false",l,r,u,v);
    return ok?0:6;
}}
