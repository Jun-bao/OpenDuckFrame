#import <Foundation/Foundation.h>
#import "SPFileFrameProvider.h"
#import "SPFileDistilEngine.h"
#import <dlfcn.h>
#include <cmath>
#include <algorithm>
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
    if(argc!=4)return 2;void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);if(!lib){fprintf(stderr,"dlopen %s\n",dlerror());return 2;}
    Class type=NSClassFromString(@"SPFileDistilEngine");if(!type)return 2;NSBundle *bundle=[NSBundle bundleWithPath:[NSString stringWithUTF8String:argv[2]]];
    id<SPFileFrameProvider> provider=(id)[(SPFileDistilEngine *)[type alloc] initWithResourceBundle:bundle];
    OSType format=strcmp(argv[3],"full")==0?kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    CVPixelBufferRef p=make(484,format,false),a=make(500,format,false),b=make(532,format,false);
    dispatch_semaphore_t ready=dispatch_semaphore_create(0);__block BOOL prepared=NO;__block NSString *reason=@"";
    [provider prepareWithSample:a completion:^(BOOL ok,NSString *r){prepared=ok;reason=r;dispatch_semaphore_signal(ready);}];
    BOOL preflight=dispatch_semaphore_wait(ready,dispatch_time(DISPATCH_TIME_NOW,90*NSEC_PER_SEC))==0 && prepared;
    if(!preflight){fprintf(stderr,"prepare: %s\n",reason.UTF8String);[provider invalidate];return 3;}
    dispatch_semaphore_t done=dispatch_semaphore_create(0);__block NSArray<SPOwnedPixelBuffer *> *out=nil;__block NSError *error=nil;__block double seconds=0;
    BOOL submitted=[provider submitPreceding:p previous:a current:b precedingPTSUs:958333 previousPTSUs:1000000 currentPTSUs:1041667 phases:@[@0.5] token:42 completion:^(uint64_t t,NSArray<SPOwnedPixelBuffer *> *r,double s,NSError *e){(void)t;out=r;error=e;seconds=s;dispatch_semaphore_signal(done);}];
    BOOL complete=submitted && dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,90*NSEC_PER_SEC))==0 && !error && out.count==1;
    double x=complete?center(out[0].buffer):-1;
    BOOL identity=complete && CVPixelBufferGetPixelFormatType(out[0].buffer)==format && CVPixelBufferGetWidth(out[0].buffer)==1280 && CVPixelBufferGetHeight(out[0].buffer)==720;
    for(CFStringRef key:{kCVImageBufferYCbCrMatrixKey,kCVImageBufferColorPrimariesKey,kCVImageBufferTransferFunctionKey}){
        CFTypeRef source=CVBufferCopyAttachment(a,key,NULL),target=complete?CVBufferCopyAttachment(out[0].buffer,key,NULL):NULL;
        identity &=source&&target&&CFEqual(source,target);if(source)CFRelease(source);if(target)CFRelease(target);
    }
    BOOL rejectsPhase=![provider submitPreceding:p previous:a current:b precedingPTSUs:1 previousPTSUs:2 currentPTSUs:3 phases:@[@0.25] token:2 completion:^(uint64_t t,NSArray *r,double s,NSError *e){(void)t;(void)r;(void)s;(void)e;}];
    BOOL rejectsBadPTS=![provider submitPreceding:p previous:a current:b precedingPTSUs:2 previousPTSUs:2 currentPTSUs:3 phases:@[@0.5] token:3 completion:^(uint64_t t,NSArray *r,double s,NSError *e){(void)t;(void)r;(void)s;(void)e;}];
    BOOL noTwoFrame=![provider submitPrevious:a current:b previousPTSUs:2 currentPTSUs:3 phases:@[@0.5] token:4 completion:^(uint64_t t,NSArray *r,double s,NSError *e){(void)t;(void)r;(void)s;(void)e;}];
    CVPixelBufferRef color=make(500,format,false);
    CVPixelBufferLockBaseAddress(color,0);auto y=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(color,0),uv=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(color,1);size_t sy=CVPixelBufferGetBytesPerRowOfPlane(color,0),su=CVPixelBufferGetBytesPerRowOfPlane(color,1);
    memset(y,120,sy*720);for(int row=0;row<360;row++)for(int col=0;col<1280;col+=2){uv[row*su+col]=85;uv[row*su+col+1]=200;}CVPixelBufferUnlockBaseAddress(color,0);
    dispatch_semaphore_t colorDone=dispatch_semaphore_create(0);__block NSArray<SPOwnedPixelBuffer *> *colorFrames=nil;__block NSError *colorError=nil;
    BOOL colorSubmitted=[provider submitPreceding:color previous:color current:color precedingPTSUs:2000000 previousPTSUs:2041667 currentPTSUs:2083334 phases:@[@0.5] token:5 completion:^(uint64_t t,NSArray<SPOwnedPixelBuffer *> *r,double s,NSError *e){(void)t;(void)s;colorFrames=r;colorError=e;dispatch_semaphore_signal(colorDone);}];
    BOOL colorDoneOK=colorSubmitted&&dispatch_semaphore_wait(colorDone,dispatch_time(DISPATCH_TIME_NOW,90*NSEC_PER_SEC))==0&&!colorError&&colorFrames.count==1;
    int yy=-1,cb=-1,cr=-1;if(colorDoneOK){CVPixelBufferRef outColor=colorFrames[0].buffer;CVPixelBufferLockBaseAddress(outColor,kCVPixelBufferLock_ReadOnly);yy=((uint8_t *)CVPixelBufferGetBaseAddressOfPlane(outColor,0))[360*CVPixelBufferGetBytesPerRowOfPlane(outColor,0)+640];auto u=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(outColor,1)+180*CVPixelBufferGetBytesPerRowOfPlane(outColor,1)+640;cb=u[0];cr=u[1];CVPixelBufferUnlockBaseAddress(outColor,kCVPixelBufferLock_ReadOnly);}CVPixelBufferRelease(color);
    BOOL colorOK=colorDoneOK && abs(yy-120)<=8 && abs(cb-85)<=8 && abs(cr-200)<=8;
    BOOL ok=preflight&&complete&&identity&&x>503&&x<529&&rejectsPhase&&rejectsBadPTS&&noTwoFrame&&colorOK;
    printf("{\"ok\":%s,\"range\":\"%s\",\"midpointCenter\":%.3f,\"seconds\":%.4f,\"constantColorYUV\":[%d,%d,%d],\"colorWithinTolerance\":%s,\"correctMetadata\":%s,\"rejectUnsupportedPhase\":%s,\"rejectInvalidPTS\":%s,\"rejectTwoFrame\":%s,\"scope\":\"actual Distil 720p model and 3 original synthetic inputs; not playback/GUI/quality guarantee\"}\n",ok?"true":"false",argv[3],x,seconds,yy,cb,cr,colorOK?"true":"false",identity?"true":"false",rejectsPhase?"true":"false",rejectsBadPTS?"true":"false",noTwoFrame?"true":"false");
    if(error)fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);[provider invalidate];
    id<SPFileFrameProvider> first=(id)[(SPFileDistilEngine *)[type alloc] initWithResourceBundle:bundle];
    id<SPFileFrameProvider> second=(id)[(SPFileDistilEngine *)[type alloc] initWithResourceBundle:bundle];
    dispatch_semaphore_t firstDone=dispatch_semaphore_create(0),secondDone=dispatch_semaphore_create(0);__block BOOL firstReady=YES,secondReady=YES;__block NSString *secondMessage=@"";
    [first prepareWithSample:a completion:^(BOOL r,NSString *message){(void)message;firstReady=r;dispatch_semaphore_signal(firstDone);}];
    [second prepareWithSample:a completion:^(BOOL r,NSString *message){secondReady=r;secondMessage=message;dispatch_semaphore_signal(secondDone);}];
    [first invalidate];
    BOOL canceled=dispatch_semaphore_wait(firstDone,dispatch_time(DISPATCH_TIME_NOW,90*NSEC_PER_SEC))==0 && !firstReady;
    BOOL bounded=dispatch_semaphore_wait(secondDone,dispatch_time(DISPATCH_TIME_NOW,90*NSEC_PER_SEC))==0 && !secondReady && [secondMessage containsString:@"正在处理"];
    printf("{\"ok\":%s,\"preflightSingleInflight\":%s,\"canceledPreflightRejected\":%s}\n",(canceled&&bounded)?"true":"false",bounded?"true":"false",canceled?"true":"false");
    ok &=canceled&&bounded;[second invalidate];CVPixelBufferRelease(p);CVPixelBufferRelease(a);CVPixelBufferRelease(b);return ok?0:4;
}}
