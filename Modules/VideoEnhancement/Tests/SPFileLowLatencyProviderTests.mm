#import <Foundation/Foundation.h>
#import "SPFileFrameProvider.h"
#import <dlfcn.h>
#include <cmath>
#include <algorithm>
#include <unistd.h>
static CVPixelBufferRef make(int x, OSType format, bool bt601) {
    NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};CVPixelBufferRef b=NULL;
    if(CVPixelBufferCreate(NULL,1280,720,format,(__bridge CFDictionaryRef)attrs,&b)!=kCVReturnSuccess)return NULL;
    CVBufferSetAttachment(b,kCVImageBufferYCbCrMatrixKey,bt601?kCVImageBufferYCbCrMatrix_ITU_R_601_4:kCVImageBufferYCbCrMatrix_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(b,kCVImageBufferColorPrimariesKey,bt601?kCVImageBufferColorPrimaries_SMPTE_C:kCVImageBufferColorPrimaries_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(b,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    CVPixelBufferLockBaseAddress(b,0);uint8_t *y=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(b,0),*uv=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(b,1);size_t ys=CVPixelBufferGetBytesPerRowOfPlane(b,0),us=CVPixelBufferGetBytesPerRowOfPlane(b,1);
    memset(y,format==kCVPixelFormatType_420YpCbCr8BiPlanarFullRange?0:16,ys*720);memset(uv,128,us*360);
    for(int yy=320;yy<400;yy++)for(int xx=x-40;xx<x+40;xx++)y[yy*ys+xx]=(((xx-x)/6)^(yy/6))&1?220:60;
    CVPixelBufferUnlockBaseAddress(b,0);return b;
}
static double center(CVPixelBufferRef b) {
    CVPixelBufferLockBaseAddress(b,kCVPixelBufferLock_ReadOnly);const uint8_t *y=(const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(b,0);size_t stride=CVPixelBufferGetBytesPerRowOfPlane(b,0);double sum=0,weight=0;
    for(int row=300;row<420;row+=2)for(int x=350;x<700;x+=2){int value=std::max(0,int(y[row*stride+x])-30);sum+=x*value;weight+=value;}
    CVPixelBufferUnlockBaseAddress(b,kCVPixelBufferLock_ReadOnly);return weight?sum/weight:-1;
}
int main(int argc,const char **argv){@autoreleasepool{
    if(argc!=2)return 2;void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);if(!lib){fprintf(stderr,"dlopen %s\n",dlerror());return 2;}
    Class type=NSClassFromString(@"SPFileLowLatencyEngine");if(!type)return 2;BOOL ok=YES;
    for(bool bt601:{false}) for(OSType format:{kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,kCVPixelFormatType_420YpCbCr8BiPlanarFullRange}){
        id<SPFileFrameProvider> provider=[type new];CVPixelBufferRef a=make(500,format,bt601),b=make(532,format,bt601);dispatch_semaphore_t ready=dispatch_semaphore_create(0);__block BOOL prepared=NO;__block NSString *reason=@"";
        [provider prepareWithSample:a completion:^(BOOL p,NSString *r){prepared=p;reason=r;dispatch_semaphore_signal(ready);}];
        BOOL preflight=dispatch_semaphore_wait(ready,dispatch_time(DISPATCH_TIME_NOW,90*NSEC_PER_SEC))==0 && prepared;
        if(!preflight){fprintf(stderr,"preflight failed: %s\n",reason.UTF8String);[provider invalidate];CVPixelBufferRelease(a);CVPixelBufferRelease(b);return 3;}
        dispatch_semaphore_t done=dispatch_semaphore_create(0);__block NSArray<SPOwnedPixelBuffer *> *out=nil;__block NSError *error=nil;
        BOOL submitted=[provider submitPrevious:a current:b previousPTSUs:1000000 currentPTSUs:1041667 phases:@[@0.5] token:42 completion:^(uint64_t t,NSArray<SPOwnedPixelBuffer *> *r,double sec,NSError *e){(void)t;(void)sec;out=r;error=e;dispatch_semaphore_signal(done);}];
        BOOL doneOK=submitted && dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,90*NSEC_PER_SEC))==0 && !error && out.count==1;
        double x=doneOK?center(out[0].buffer):-1;
        BOOL identity=doneOK && CVPixelBufferGetPixelFormatType(out[0].buffer)==format && CVPixelBufferGetWidth(out[0].buffer)==1280 && CVPixelBufferGetHeight(out[0].buffer)==720;
        for(CFStringRef key:{kCVImageBufferYCbCrMatrixKey,kCVImageBufferColorPrimariesKey,kCVImageBufferTransferFunctionKey}){
            CFTypeRef src=CVBufferCopyAttachment(a,key,NULL),dst=doneOK?CVBufferCopyAttachment(out[0].buffer,key,NULL):NULL;
            identity &=src&&dst&&CFEqual(src,dst);if(src)CFRelease(src);if(dst)CFRelease(dst);
        }
        BOOL rejectsPhase=![provider submitPrevious:a current:b previousPTSUs:1 currentPTSUs:2 phases:@[@(1.0/3.0)] token:3 completion:^(uint64_t t,NSArray *r,double sec,NSError *e){(void)t;(void)r;(void)sec;(void)e;}];
        BOOL rejectsPTS=![provider submitPrevious:a current:b previousPTSUs:2 currentPTSUs:2 phases:@[@0.5] token:4 completion:^(uint64_t t,NSArray *r,double sec,NSError *e){(void)t;(void)r;(void)sec;(void)e;}];
        CVPixelBufferRef c=make(500,format,bt601);
        CVPixelBufferLockBaseAddress(c,0);
        size_t sy=CVPixelBufferGetBytesPerRowOfPlane(c,0),suv=CVPixelBufferGetBytesPerRowOfPlane(c,1);
        uint8_t *cy=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(c,0),*cuv=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(c,1);
        memset(cy,120,sy*720);for(int row=0;row<360;row++)for(int col=0;col<1280;col+=2){cuv[row*suv+col]=85;cuv[row*suv+col+1]=200;}
        CVPixelBufferUnlockBaseAddress(c,0);
        dispatch_semaphore_t colorDone=dispatch_semaphore_create(0);__block NSArray<SPOwnedPixelBuffer *> *colorOut=nil;__block NSError *colorError=nil;
        BOOL colorSubmitted=[provider submitPrevious:c current:c previousPTSUs:2000000 currentPTSUs:2041667 phases:@[@0.5] token:45 completion:^(uint64_t t,NSArray<SPOwnedPixelBuffer *> *r,double sec,NSError *e){(void)t;(void)sec;colorOut=r;colorError=e;dispatch_semaphore_signal(colorDone);}];
        BOOL colorComplete=colorSubmitted && dispatch_semaphore_wait(colorDone,dispatch_time(DISPATCH_TIME_NOW,90*NSEC_PER_SEC))==0 && !colorError && colorOut.count==1;
        int yv=-1,cb=-1,cr=-1;
        if(colorComplete){CVPixelBufferRef co=colorOut[0].buffer;CVPixelBufferLockBaseAddress(co,kCVPixelBufferLock_ReadOnly);yv=((uint8_t *)CVPixelBufferGetBaseAddressOfPlane(co,0))[360*CVPixelBufferGetBytesPerRowOfPlane(co,0)+640];auto uv=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(co,1)+180*CVPixelBufferGetBytesPerRowOfPlane(co,1)+640;cb=uv[0];cr=uv[1];CVPixelBufferUnlockBaseAddress(co,kCVPixelBufferLock_ReadOnly);}
        BOOL colorOK=colorComplete && abs(yv-120)<=8 && abs(cb-85)<=8 && abs(cr-200)<=8;
        CVPixelBufferRelease(c);
        BOOL pass=preflight&&identity&&fabs(x-516.0)<=10.0&&rejectsPhase&&rejectsPTS&&colorOK;ok &=pass;
        printf("{\"ok\":%s,\"range\":\"%s\",\"matrix\":\"%s\",\"midpointCenter\":%.3f,\"constantColorYUV\":[%d,%d,%d],\"colorWithinTolerance\":%s,\"realPTSUs\":[1000000,1041667],\"formatAndMetadata\":%s,\"rejectUnsupportedPhase\":%s,\"rejectInvalidPTS\":%s,\"scope\":\"real low-latency file provider synthetic pair; no playback or GUI\"}\n",pass?"true":"false",format==kCVPixelFormatType_420YpCbCr8BiPlanarFullRange?"full":"video",bt601?"601":"709",x,yv,cb,cr,colorOK?"true":"false",identity?"true":"false",rejectsPhase?"true":"false",rejectsPTS?"true":"false");
        __weak id weakProvider=provider;
        [provider invalidate];provider=nil;CVPixelBufferRelease(a);CVPixelBufferRelease(b);
        for(int wait=0;wait<200 && weakProvider;wait++)usleep(10000);
        BOOL released=weakProvider==nil;ok &=released;
        printf("{\"ok\":%s,\"completedProviderDeallocated\":%s}\n",released?"true":"false",released?"true":"false");
    }
    id<SPFileFrameProvider> unsupported=[type new];CVPixelBufferRef unsupportedFrame=make(500,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,true);
    dispatch_semaphore_t rejected=dispatch_semaphore_create(0);__block BOOL unsupportedReady=YES;
    [unsupported prepareWithSample:unsupportedFrame completion:^(BOOL ready,NSString *message){(void)message;unsupportedReady=ready;dispatch_semaphore_signal(rejected);}];
    BOOL rejected601=dispatch_semaphore_wait(rejected,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0 && !unsupportedReady;
    printf("{\"ok\":%s,\"reject601Video\":%s}\n",rejected601?"true":"false",rejected601?"true":"false");ok &=rejected601;
    [unsupported invalidate];CVPixelBufferRelease(unsupportedFrame);
    id<SPFileFrameProvider> canceled=[type new];__weak id weakCanceled=canceled;
    CVPixelBufferRef sample=make(500,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,false);
    dispatch_semaphore_t cancelDone=dispatch_semaphore_create(0);__block BOOL cancelReady=YES;
    [canceled prepareWithSample:sample completion:^(BOOL r,NSString *message){(void)message;cancelReady=r;dispatch_semaphore_signal(cancelDone);}];
    [canceled invalidate];canceled=nil;
    BOOL cancelFinished=dispatch_semaphore_wait(cancelDone,dispatch_time(DISPATCH_TIME_NOW,90*NSEC_PER_SEC))==0 && !cancelReady;
    CVPixelBufferRelease(sample);for(int wait=0;wait<200 && weakCanceled;wait++)usleep(10000);
    BOOL canceledReleased=cancelFinished && weakCanceled==nil;ok &=canceledReleased;
    printf("{\"ok\":%s,\"canceledPreflightDeallocated\":%s}\n",canceledReleased?"true":"false",canceledReleased?"true":"false");
    return ok?0:4;
}}
