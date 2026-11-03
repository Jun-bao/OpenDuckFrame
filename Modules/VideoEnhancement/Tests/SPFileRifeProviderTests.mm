#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "SPFileRifeEngine.h"
#import <dlfcn.h>
#include <cmath>
#include <algorithm>

static CVPixelBufferRef make(int center){
    NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};CVPixelBufferRef b=NULL;
    if(CVPixelBufferCreate(NULL,320,192,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,(__bridge CFDictionaryRef)attrs,&b)!=kCVReturnSuccess)return NULL;
    CVBufferSetAttachment(b,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(b,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(b,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    CVPixelBufferLockBaseAddress(b,0);uint8_t *y=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(b,0),*uv=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(b,1);size_t ys=CVPixelBufferGetBytesPerRowOfPlane(b,0),us=CVPixelBufferGetBytesPerRowOfPlane(b,1);
    memset(y,16,ys*192);memset(uv,128,us*96);
    for(int yy=72;yy<120;yy++)for(int xx=center-24;xx<center+24;xx++)y[yy*ys+xx]=(((xx-center)/4)^(yy/4))&1?235:40;
    CVPixelBufferUnlockBaseAddress(b,0);return b;
}
static double center(CVPixelBufferRef b){CVPixelBufferLockBaseAddress(b,kCVPixelBufferLock_ReadOnly);const uint8_t *y=(const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(b,0);size_t stride=CVPixelBufferGetBytesPerRowOfPlane(b,0);double sum=0,weight=0;for(int row=50;row<142;row+=2)for(int x=0;x<320;x+=2){int value=std::max(0,int(y[row*stride+x])-30);sum+=x*value;weight+=value;}CVPixelBufferUnlockBaseAddress(b,kCVPixelBufferLock_ReadOnly);return weight?sum/weight:-1;}
int main(int argc,const char **argv){@autoreleasepool{
    if(argc!=6 && argc!=7)return 2;BOOL expectReject=argc==7 && strcmp(argv[6],"reject")==0;void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);if(!lib){fprintf(stderr,"dlopen: %s\n",dlerror());return 3;}
    Class type=NSClassFromString(@"SPFileRifeEngine");NSBundle *bundle=[NSBundle bundleWithPath:[NSString stringWithUTF8String:argv[2]]];
    id<SPFileFrameProvider> provider=(id)[[type alloc] initWithModelID:[NSString stringWithUTF8String:argv[3]] quality:[NSString stringWithUTF8String:argv[5]] resourceBundle:bundle];if(!provider)return 3;
    AVURLAsset *asset=[AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[4]]] options:nil];AVAssetTrack *track=[[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];NSError *error=nil;
    AVAssetReader *reader=track?[[AVAssetReader alloc] initWithAsset:asset error:&error]:nil;AVAssetReaderTrackOutput *output=track?[[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES}]:nil;
    if(!reader||!output||![reader canAddOutput:output])return 4;[reader addOutput:output];if(![reader startReading])return 4;
    CMSampleBufferRef aSample=[output copyNextSampleBuffer],bSample=[output copyNextSampleBuffer];if(!aSample||!bSample)return 4;
    CVPixelBufferRef a=CMSampleBufferGetImageBuffer(aSample),b=CMSampleBufferGetImageBuffer(bSample);CMTime ta=CMSampleBufferGetPresentationTimeStamp(aSample),tb=CMSampleBufferGetPresentationTimeStamp(bSample);
    dispatch_semaphore_t ready=dispatch_semaphore_create(0);__block BOOL prepared=NO;__block NSString *reason=@"";
    [provider prepareWithSample:a completion:^(BOOL ok,NSString *message){prepared=ok;reason=message;dispatch_semaphore_signal(ready);}];
    BOOL prepareCompleted=dispatch_semaphore_wait(ready,dispatch_time(DISPATCH_TIME_NOW,60*NSEC_PER_SEC))==0;
    if(expectReject){BOOL ok=prepareCompleted&&!prepared&&reason.length>0;printf("{\"ok\":%s,\"model\":\"%s\",\"quality\":\"%s\",\"invalidSelectionRejected\":%s}\n",ok?"true":"false",argv[3],argv[5],ok?"true":"false");return ok?0:5;}
    if(!prepareCompleted||!prepared){fprintf(stderr,"prepare: %s\n",reason.UTF8String);return 5;}
    NSArray *phases=@[@0.25,@0.5,@0.75,@(1.0/3.0),@(2.0/3.0)];
    CVPixelBufferRef left=make(148),right=make(172);if(!left||!right)return 5;
    bool phaseOK=true;NSMutableArray *centers=[NSMutableArray array];
    for(NSNumber *phase in phases){
        dispatch_semaphore_t done=dispatch_semaphore_create(0);__block NSArray<SPOwnedPixelBuffer *> *frames=nil;__block NSError *failure=nil;
        BOOL submitted=[provider submitPrevious:left current:right previousPTSUs:0 currentPTSUs:41667 phases:@[phase] token:41 completion:^(uint64_t t,NSArray<SPOwnedPixelBuffer *> *r,double sec,NSError *e){(void)t;(void)sec;frames=r;failure=e;dispatch_semaphore_signal(done);}];
        BOOL complete=submitted&&dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,60*NSEC_PER_SEC))==0;
        double x=complete&&frames.count==1?center(frames[0].buffer):-1;[centers addObject:@(x)];double expected=148+24*phase.doubleValue;
        phaseOK &=complete&&!failure&&frames.count==1&&fabs(x-expected)<=16&&CVPixelBufferGetPixelFormatType(frames[0].buffer)==kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    }
    const int orderedIndices[]={0,3,1,4,2};bool phaseSeparation=centers.count==5;
    for(int i=1;i<5 && phaseSeparation;i++)phaseSeparation = [centers[orderedIndices[i]] doubleValue]-[centers[orderedIndices[i-1]] doubleValue]>=1.0;
    phaseOK &=phaseSeparation;
    dispatch_semaphore_t done=dispatch_semaphore_create(0);__block NSArray<SPOwnedPixelBuffer *> *decoded=nil;__block NSError *failure=nil;
    BOOL submitted=[provider submitPrevious:a current:b previousPTSUs:CMTimeConvertScale(ta,1000000,kCMTimeRoundingMethod_RoundHalfAwayFromZero).value currentPTSUs:CMTimeConvertScale(tb,1000000,kCMTimeRoundingMethod_RoundHalfAwayFromZero).value phases:@[@(1.0/3.0),@(2.0/3.0)] token:42 completion:^(uint64_t t,NSArray<SPOwnedPixelBuffer *> *r,double sec,NSError *e){(void)t;(void)sec;decoded=r;failure=e;dispatch_semaphore_signal(done);}];
    BOOL complete=submitted&&dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,60*NSEC_PER_SEC))==0;
    bool decodedOK=complete&&!failure&&decoded.count==2&&CMTIME_COMPARE_INLINE(tb,>,ta);
    for(SPOwnedPixelBuffer *frame in decoded){
        decodedOK &=CVPixelBufferGetWidth(frame.buffer)==320&&CVPixelBufferGetHeight(frame.buffer)==192&&CVPixelBufferGetPixelFormatType(frame.buffer)==CVPixelBufferGetPixelFormatType(a);
        CFStringRef keys[]={kCVImageBufferYCbCrMatrixKey,kCVImageBufferColorPrimariesKey,kCVImageBufferTransferFunctionKey};
        for(CFStringRef key:keys){CFTypeRef input=CVBufferCopyAttachment(a,key,NULL),outputValue=CVBufferCopyAttachment(frame.buffer,key,NULL);decodedOK &=input&&outputValue&&CFEqual(input,outputValue);if(input)CFRelease(input);if(outputValue)CFRelease(outputValue);}
    }
    NSData *json=[NSJSONSerialization dataWithJSONObject:centers options:0 error:nil];NSString *str=[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    bool ok=phaseOK&&decodedOK;printf("{\"ok\":%s,\"model\":\"%s\",\"quality\":\"%s\",\"phaseCenters\":%s,\"phaseOrderedAndSeparated\":%s,\"decodedPair\":%s,\"decodedPTSUs\":[%lld,%lld],\"scope\":\"real RIFE provider, synthetic position probe and one decoded pair; no GUI/drawable/audio\"}\n",ok?"true":"false",argv[3],argv[5],str.UTF8String,phaseSeparation?"true":"false",decodedOK?"true":"false",(long long)CMTimeConvertScale(ta,1000000,kCMTimeRoundingMethod_RoundHalfAwayFromZero).value,(long long)CMTimeConvertScale(tb,1000000,kCMTimeRoundingMethod_RoundHalfAwayFromZero).value);
    [provider invalidate];CVPixelBufferRelease(left);CVPixelBufferRelease(right);CFRelease(aSample);CFRelease(bSample);return ok?0:6;
}}
