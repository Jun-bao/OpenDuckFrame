#import "SPDistilDRBA.h"
#import <CoreML/CoreML.h>
#import <VideoToolbox/VideoToolbox.h>
#include <cmath>
#include <initializer_list>

static NSError *SPDistilError(NSInteger code,NSString *message){return [NSError errorWithDomain:@"app.openduckframe.distildrba" code:code userInfo:@{NSLocalizedDescriptionKey:message}];}
static NSURL *SPDistilModelURL(NSBundle *bundle){
#if SP_DISTIL_PROBE
    NSString *path=NSProcessInfo.processInfo.environment[@"ODF_DISTIL_PROBE_MODEL"];
    if(path.length)return [NSURL fileURLWithPath:path];
#endif
    return [bundle URLForResource:@"DistilDRBA_720p" withExtension:@"mlmodelc"];
}
static MLMultiArray *SPDistilTensor(CVPixelBufferRef buffer,NSError **error){
    MLMultiArray *array=[[MLMultiArray alloc] initWithShape:@[@1,@3,@768,@1280] dataType:MLMultiArrayDataTypeFloat16 error:error];
    if(!array)return nil;
    _Float16 *values=(_Float16 *)array.dataPointer;size_t plane=(size_t)1280*768;
    if(CVPixelBufferLockBaseAddress(buffer,kCVPixelBufferLock_ReadOnly)!=kCVReturnSuccess){if(error)*error=SPDistilError(1,@"无法读取 DistilDRBA 输入。");return nil;}
    const uint8_t *base=(const uint8_t *)CVPixelBufferGetBaseAddress(buffer);size_t row=CVPixelBufferGetBytesPerRow(buffer);
    if(!base){CVPixelBufferUnlockBaseAddress(buffer,kCVPixelBufferLock_ReadOnly);if(error)*error=SPDistilError(1,@"无法读取 DistilDRBA 输入。");return nil;}
    for(int y=0;y<768;y++){const uint8_t *line=base+(size_t)MIN(y,719)*row;for(int x=0;x<1280;x++){
        const uint8_t *p=line+x*4;size_t i=(size_t)y*1280+x;values[i]=(_Float16)(p[0]/255.f);values[plane+i]=(_Float16)(p[1]/255.f);values[2*plane+i]=(_Float16)(p[2]/255.f);
    }}
    CVPixelBufferUnlockBaseAddress(buffer,kCVPixelBufferLock_ReadOnly);return array;
}
static CVPixelBufferRef SPDistilBuffer(MLMultiArray *array,CVPixelBufferRef source,NSError **error){
    NSArray<NSNumber *> *shape=array.shape,*strides=array.strides;
    if(shape.count!=4 || strides.count!=4 || shape[1].intValue!=3 || shape[2].intValue!=768 || shape[3].intValue!=1280 || (array.dataType!=MLMultiArrayDataTypeFloat16 && array.dataType!=MLMultiArrayDataTypeFloat32)){
        if(error)*error=SPDistilError(2,@"DistilDRBA 输出形状或格式不匹配。");return NULL;
    }
    NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};CVPixelBufferRef output=NULL;
    if(CVPixelBufferCreate(NULL,1280,720,kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)attrs,&output)!=kCVReturnSuccess||!output){if(error)*error=SPDistilError(3,@"无法分配 DistilDRBA 输出。");return NULL;}
    CVBufferPropagateAttachments(source,output);if(CVPixelBufferLockBaseAddress(output,0)!=kCVReturnSuccess){CVPixelBufferRelease(output);if(error)*error=SPDistilError(3,@"无法写入 DistilDRBA 输出。");return NULL;}
    uint8_t *dst=(uint8_t *)CVPixelBufferGetBaseAddress(output);size_t pitch=CVPixelBufferGetBytesPerRow(output);long cs=strides[1].longValue,ys=strides[2].longValue,xs=strides[3].longValue;
    const _Float16 *h=(const _Float16 *)array.dataPointer;const float *f=(const float *)array.dataPointer;
    for(int y=0;y<720;y++)for(int x=0;x<1280;x++){uint8_t *p=dst+(size_t)y*pitch+x*4;for(int c=0;c<3;c++){long i=c*cs+y*ys+x*xs;float value=array.dataType==MLMultiArrayDataTypeFloat16?(float)h[i]:f[i];if(!std::isfinite(value))value=0;value=std::fmax(0.f,std::fmin(1.f,value));p[c]=(uint8_t)lrintf(value*255.f);}p[3]=255;}
    CVPixelBufferUnlockBaseAddress(output,0);return output;
}
@implementation SPDistilDRBA {
    dispatch_queue_t _queue;MLModel *_model;NSBundle *_resourceBundle;VTPixelTransferSessionRef _transfer;uint64_t _epoch;BOOL _running,_inflight;
}
- (instancetype)init {return [self initWithResourceBundle:NSBundle.mainBundle];}
- (instancetype)initWithResourceBundle:(NSBundle *)bundle {if(!(self=[super init]))return nil;_resourceBundle=bundle;_queue=dispatch_queue_create("app.openduckframe.distildrba",DISPATCH_QUEUE_SERIAL);return self;}
- (void)dealloc {if(_transfer)CFRelease(_transfer);}
- (CVPixelBufferRef)copyBGRA:(CVPixelBufferRef)source {
    if(CVPixelBufferGetPixelFormatType(source)==kCVPixelFormatType_32BGRA)return CVPixelBufferRetain(source);
    NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};CVPixelBufferRef output=NULL;
    if(CVPixelBufferCreate(NULL,1280,720,kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)attrs,&output)!=kCVReturnSuccess)return NULL;
    if(!_transfer)VTPixelTransferSessionCreate(NULL,&_transfer);
    if(!_transfer||VTPixelTransferSessionTransferImage(_transfer,source,output)!=noErr){CVPixelBufferRelease(output);return NULL;}
    CVBufferPropagateAttachments(source,output);return output;
}
+ (BOOL)isPackagedForThisSystem {return SPDistilModelURL(NSBundle.mainBundle)!=nil;}
- (BOOL)prepareWidth:(int)width height:(int)height error:(NSError **)error {
    if(width!=1280||height!=720){if(error)*error=SPDistilError(4,@"当前 DistilDRBA 模型只支持 1280×720 输入和 X2 中点。");return NO;}
    NSURL *url=SPDistilModelURL(_resourceBundle);if(!url){if(error)*error=SPDistilError(5,@"此安装包缺少 DistilDRBA 模型。");return NO;}
    __block NSError *local=nil;__block BOOL ok=NO;dispatch_sync(_queue,^{
        @synchronized(self){if(self->_running||self->_inflight)return;}
        MLModelConfiguration *config=[[MLModelConfiguration alloc] init];
#if SP_DISTIL_PROBE
        config.computeUnits=MLComputeUnitsCPUOnly;
#else
        config.computeUnits=MLComputeUnitsAll;
#endif
        MLModel *model=[MLModel modelWithContentsOfURL:url configuration:config error:&local];if(!model)return;
        self->_model=model;@synchronized(self){self->_running=YES;self->_epoch++;}ok=YES;
    });if(!ok&&error)*error=local?:SPDistilError(6,@"DistilDRBA 模型准备失败。");return ok;
}
- (BOOL)submitPrevious:(CVPixelBufferRef)previous current:(CVPixelBufferRef)current next:(CVPixelBufferRef)next pts:(CMTime)pts token:(uint64_t)token completion:(SPFRCEngineCompletion)completion {
    if(!previous||!current||!next||!completion||!CMTIME_IS_NUMERIC(pts))return NO;
    for(CVPixelBufferRef b : {previous,current,next}){
        OSType format=CVPixelBufferGetPixelFormatType(b);
        if(CVPixelBufferGetWidth(b)!=1280||CVPixelBufferGetHeight(b)!=720||
           (format!=kCVPixelFormatType_32BGRA && format!=kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange && format!=kCVPixelFormatType_420YpCbCr8BiPlanarFullRange))return NO;
        CFTypeRef transfer=CVBufferCopyAttachment(b,kCVImageBufferTransferFunctionKey,NULL);
        BOOL hdr=transfer && (CFEqual(transfer,kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)||CFEqual(transfer,kCVImageBufferTransferFunction_ITU_R_2100_HLG));
        if(transfer)CFRelease(transfer);if(hdr)return NO;
    }
    __block uint64_t seen;@synchronized(self){if(!_running||_inflight||!_model)return NO;_inflight=YES;seen=_epoch;}
    CVPixelBufferRetain(previous);CVPixelBufferRetain(current);CVPixelBufferRetain(next);
    dispatch_async(_queue,^{@autoreleasepool{
        CFAbsoluteTime start=CFAbsoluteTimeGetCurrent();NSError *failure=nil;CVPixelBufferRef output=NULL;BOOL stale;@synchronized(self){stale=seen!=self->_epoch;}
        if(!stale){
            CVPixelBufferRef pa=[self copyBGRA:previous],pb=[self copyBGRA:current],pc=[self copyBGRA:next];
            if(!pa||!pb||!pc)failure=SPDistilError(9,@"DistilDRBA 输入格式转换失败。");
            MLMultiArray *a=failure?nil:SPDistilTensor(pa,&failure),*b=failure?nil:SPDistilTensor(pb,&failure),*c=failure?nil:SPDistilTensor(pc,&failure);
            if(a&&b&&c&&!failure){NSDictionary *values=@{@"previous":[MLFeatureValue featureValueWithMultiArray:a],@"current":[MLFeatureValue featureValueWithMultiArray:b],@"next":[MLFeatureValue featureValueWithMultiArray:c]};
                MLDictionaryFeatureProvider *features=[[MLDictionaryFeatureProvider alloc] initWithDictionary:values error:&failure];
                id<MLFeatureProvider> result=features?[self->_model predictionFromFeatures:features error:&failure]:nil;
                MLMultiArray *tensor=[result featureValueForName:@"var_1639"].multiArrayValue;
                if(tensor&&!failure)output=SPDistilBuffer(tensor,current,&failure);
                else if(!failure)failure=SPDistilError(7,@"DistilDRBA 未返回画面。");
            }
            if(pa)CVPixelBufferRelease(pa);if(pb)CVPixelBufferRelease(pb);if(pc)CVPixelBufferRelease(pc);
        }
        @synchronized(self){stale=seen!=self->_epoch;self->_inflight=NO;}
        if(stale){if(output)CVPixelBufferRelease(output);output=NULL;failure=SPDistilError(8,@"DistilDRBA 结果属于已结束的会话。");self->_model=nil;}
        CVPixelBufferRelease(previous);CVPixelBufferRelease(current);CVPixelBufferRelease(next);
        completion(token,output,MAX(0,CFAbsoluteTimeGetCurrent()-start),failure);
    }});return YES;
}
- (void)invalidate {BOOL active;@synchronized(self){_epoch++;_running=NO;active=_inflight;}if(!active)dispatch_async(_queue,^{self->_model=nil;});}
@end
