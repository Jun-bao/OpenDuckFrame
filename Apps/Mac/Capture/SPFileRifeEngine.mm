#import "SPFileRifeEngine.h"
#import "SPRifeBridge.h"
#import "SPFileColorTransfer.h"
#import <VideoToolbox/VideoToolbox.h>
#include <atomic>
#include <initializer_list>

static NSError *SPFileRifeError(NSInteger code,NSString *message){return [NSError errorWithDomain:@"OpenDuckFrame.FileRife" code:code userInfo:@{NSLocalizedDescriptionKey:message}];}
static CVPixelBufferRef SPFileRifeCreate(int w,int h,OSType format){
    NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};
    CVPixelBufferRef result=NULL;return CVPixelBufferCreate(NULL,w,h,format,(__bridge CFDictionaryRef)attrs,&result)==kCVReturnSuccess?result:NULL;
}
@implementation SPFileRifeEngine {
    NSString *_modelID,*_quality;
    NSBundle *_resourceBundle;
    SPRifeBridge *_bridge;
    VTPixelTransferSessionRef _toRGB,_toNV12;
    dispatch_queue_t _queue;
    std::atomic<bool> _busy;
    uint64_t _epoch;
    BOOL _ready;
    int _width,_height;
}
- (instancetype)initWithModelID:(NSString *)modelID quality:(NSString *)quality {return [self initWithModelID:modelID quality:quality resourceBundle:NSBundle.mainBundle];}
- (instancetype)initWithModelID:(NSString *)modelID quality:(NSString *)quality resourceBundle:(NSBundle *)bundle {
    if(!(self=[super init]))return nil;_resourceBundle=bundle;_modelID=[modelID copy];_quality=[quality copy];_queue=dispatch_queue_create("app.openduckframe.file-rife",DISPATCH_QUEUE_SERIAL);_busy.store(false);return self;
}
- (void)dealloc {[_bridge invalidate];if(_toRGB)CFRelease(_toRGB);if(_toNV12)CFRelease(_toNV12);}
- (void)invalidate {@synchronized(self){_epoch++;_ready=NO;}[_bridge invalidate];}
- (void)prepareWithSample:(CVPixelBufferRef)sample completion:(void (^)(BOOL, NSString *))completion {
    if(!sample||!completion){if(completion)completion(NO,@"文件视频帧尚未就绪。");return;}
    CVPixelBufferRetain(sample);uint64_t seen;@synchronized(self){seen=_epoch;}
    dispatch_async(_queue,^{
        int w=(int)CVPixelBufferGetWidth(sample),h=(int)CVPixelBufferGetHeight(sample);OSType f=CVPixelBufferGetPixelFormatType(sample);
        CFTypeRef matrix=CVBufferCopyAttachment(sample,kCVImageBufferYCbCrMatrixKey,NULL);
        CFTypeRef pri=CVBufferCopyAttachment(sample,kCVImageBufferColorPrimariesKey,NULL),trc=CVBufferCopyAttachment(sample,kCVImageBufferTransferFunctionKey,NULL);
        BOOL hdr=trc&&(CFEqual(trc,kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)||CFEqual(trc,kCVImageBufferTransferFunction_ITU_R_2100_HLG));
        BOOL valid=matrix&&pri&&trc&&!hdr&&w>=2&&h>=2&&w<=1920&&h<=1080&&!(w&1)&&!(h&1)&&
            (f==kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange||f==kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)&&
            CGRectEqualToRect(CVImageBufferGetCleanRect(sample),CGRectMake(0,0,w,h));
        if(matrix)CFRelease(matrix);if(pri)CFRelease(pri);if(trc)CFRelease(trc);
        if(!valid){CVPixelBufferRelease(sample);completion(NO,@"文件 RIFE 需要完整 SDR 8 位 NV12 帧、已知色彩信息和最高 1920×1080 的偶数尺寸。");return;}
        if(![@[@"fast",@"balanced",@"hq"] containsObject:self->_quality]){CVPixelBufferRelease(sample);completion(NO,@"所选 RIFE 质量档位不可用。");return;}
        NSError *error=nil;SPRifeBridge *bridge=[[SPRifeBridge alloc] initWithResourceBundle:self->_resourceBundle];
        BOOL prepared=[bridge prepareModelID:self->_modelID quality:self->_quality width:w height:h error:&error];
        if(!prepared){CVPixelBufferRelease(sample);completion(NO,error.localizedDescription?:@"RIFE 模型准备失败。");return;}
        if(VTPixelTransferSessionCreate(NULL,&self->_toRGB)!=noErr||VTPixelTransferSessionCreate(NULL,&self->_toNV12)!=noErr){[bridge invalidate];CVPixelBufferRelease(sample);completion(NO,@"RIFE 色彩转换准备失败。");return;}
        @synchronized(self){if(seen!=self->_epoch){[bridge invalidate];CVPixelBufferRelease(sample);completion(NO,@"准备已取消，原设置保持不变。");return;}self->_bridge=bridge;self->_width=w;self->_height=h;self->_ready=YES;}
        BOOL submitted=[self submitPrevious:sample current:sample previousPTSUs:0 currentPTSUs:33333 phases:@[@0.5] token:1 completion:^(uint64_t token,NSArray<SPOwnedPixelBuffer *> *out,double latency,NSError *failure){
            (void)token;(void)latency;BOOL ready=!failure&&out.count==1&&CVPixelBufferGetWidth(out.firstObject.buffer)==(size_t)w&&CVPixelBufferGetHeight(out.firstObject.buffer)==(size_t)h&&CVPixelBufferGetPixelFormatType(out.firstObject.buffer)==f;
            CVPixelBufferRelease(sample);if(!ready)[self invalidate];completion(ready,failure.localizedDescription?:@"");
        }];
        if(!submitted){CVPixelBufferRelease(sample);[self invalidate];completion(NO,@"RIFE 预检任务繁忙。");}
    });
}
- (BOOL)submitPrevious:(CVPixelBufferRef)previous current:(CVPixelBufferRef)current previousPTSUs:(int64_t)previousPTSUs currentPTSUs:(int64_t)currentPTSUs phases:(NSArray<NSNumber *> *)phases token:(uint64_t)token completion:(SPFRCPhasesCompletion)completion {
    if(!previous||!current||!completion||currentPTSUs<=previousPTSUs||phases.count<1||phases.count>3)return NO;
    uint64_t seen;SPRifeBridge *bridge;@synchronized(self){if(!_ready)return NO;seen=_epoch;bridge=_bridge;}
    if(_busy.exchange(true))return NO;
    CVPixelBufferRetain(previous);CVPixelBufferRetain(current);
    dispatch_async(_queue,^{
        void (^fail)(NSError *)=^(NSError *error){CVPixelBufferRelease(previous);CVPixelBufferRelease(current);self->_busy.store(false);completion(token,nil,0,error);};
        OSType format=CVPixelBufferGetPixelFormatType(previous);
        CFTypeRef m1=CVBufferCopyAttachment(previous,kCVImageBufferYCbCrMatrixKey,NULL),m2=CVBufferCopyAttachment(current,kCVImageBufferYCbCrMatrixKey,NULL);
        CFTypeRef p1=CVBufferCopyAttachment(previous,kCVImageBufferColorPrimariesKey,NULL),p2=CVBufferCopyAttachment(current,kCVImageBufferColorPrimariesKey,NULL);
        CFTypeRef t1=CVBufferCopyAttachment(previous,kCVImageBufferTransferFunctionKey,NULL),t2=CVBufferCopyAttachment(current,kCVImageBufferTransferFunctionKey,NULL);
        BOOL compatible=m1&&m2&&p1&&p2&&t1&&t2&&CFEqual(m1,m2)&&CFEqual(p1,p2)&&CFEqual(t1,t2)&&
           CVPixelBufferGetWidth(previous)==(size_t)self->_width&&CVPixelBufferGetHeight(previous)==(size_t)self->_height&&
           CVPixelBufferGetWidth(current)==(size_t)self->_width&&CVPixelBufferGetHeight(current)==(size_t)self->_height&&CVPixelBufferGetPixelFormatType(current)==format&&
           CGRectEqualToRect(CVImageBufferGetCleanRect(previous),CGRectMake(0,0,self->_width,self->_height))&&
           CGRectEqualToRect(CVImageBufferGetCleanRect(current),CGRectMake(0,0,self->_width,self->_height))&&
           (format==kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange||format==kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)&&
           !CFEqual(t1,kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)&&!CFEqual(t1,kCVImageBufferTransferFunction_ITU_R_2100_HLG);
        if(m1)CFRelease(m1);if(m2)CFRelease(m2);if(p1)CFRelease(p1);if(p2)CFRelease(p2);if(t1)CFRelease(t1);if(t2)CFRelease(t2);
        if(!compatible||!SPConfigureFileColorTransfer(self->_toNV12,previous,YES)||
           VTSessionSetProperty(self->_toRGB,kVTPixelTransferPropertyKey_DestinationColorPrimaries,kCVImageBufferColorPrimaries_ITU_R_709_2)!=noErr||
           VTSessionSetProperty(self->_toRGB,kVTPixelTransferPropertyKey_DestinationTransferFunction,kCVImageBufferTransferFunction_ITU_R_709_2)!=noErr){fail(SPFileRifeError(1,@"RIFE 帧对的格式或色彩信息不兼容。"));return;}
        CVPixelBufferRef a=SPFileRifeCreate(self->_width,self->_height,kCVPixelFormatType_32BGRA),b=SPFileRifeCreate(self->_width,self->_height,kCVPixelFormatType_32BGRA);
        if(!a||!b){if(a)CVPixelBufferRelease(a);if(b)CVPixelBufferRelease(b);fail(SPFileRifeError(2,@"RIFE 输入画面分配失败。"));return;}
        for(CVPixelBufferRef rgb:{a,b}){CVBufferSetAttachment(rgb,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);CVBufferSetAttachment(rgb,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);}
        if(VTPixelTransferSessionTransferImage(self->_toRGB,previous,a)!=noErr||VTPixelTransferSessionTransferImage(self->_toRGB,current,b)!=noErr){CVPixelBufferRelease(a);CVPixelBufferRelease(b);fail(SPFileRifeError(3,@"RIFE 输入格式转换失败。"));return;}
        for(CVPixelBufferRef rgb:{a,b}){CVBufferSetAttachment(rgb,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);CVBufferSetAttachment(rgb,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);CVBufferRemoveAttachment(rgb,kCVImageBufferYCbCrMatrixKey);}
        BOOL accepted=[bridge submitPrevious:a current:b timesteps:phases token:token completion:^(uint64_t callbackToken,NSArray<SPOwnedPixelBuffer *> *outputs,double latency,NSError *error){
            (void)callbackToken;dispatch_async(self->_queue,^{
                NSMutableArray<SPOwnedPixelBuffer *> *converted=[NSMutableArray array];
                NSError *failure=error;
                BOOL stale;@synchronized(self){stale=seen!=self->_epoch;}
                if(!stale&&!failure&&outputs.count==phases.count){
                    for(SPOwnedPixelBuffer *box in outputs){
                        if(CVPixelBufferGetWidth(box.buffer)!=(size_t)self->_width || CVPixelBufferGetHeight(box.buffer)!=(size_t)self->_height){failure=SPFileRifeError(8,@"RIFE 输出尺寸不正确。 ");break;}
                        CVPixelBufferRef nv=SPFileRifeCreate(self->_width,self->_height,format);if(!nv){failure=SPFileRifeError(4,@"RIFE 输出画面分配失败。");break;}
                        CVBufferPropagateAttachments(previous,nv);CVBufferRemoveAttachment(nv,kCVImageBufferCleanApertureKey);CVBufferRemoveAttachment(nv,kCVImageBufferPreferredCleanApertureKey);CVBufferRemoveAttachment(nv,kCVImageBufferDisplayDimensionsKey);
                        OSStatus result=VTPixelTransferSessionTransferImage(self->_toNV12,box.buffer,nv);
                        if(result!=noErr){CVPixelBufferRelease(nv);failure=SPFileRifeError(5,@"RIFE 输出格式转换失败。");break;}
                        [converted addObject:[[SPOwnedPixelBuffer alloc] initWithBufferNoCopy:nv]];
                    }
                }
                CVPixelBufferRelease(a);CVPixelBufferRelease(b);CVPixelBufferRelease(previous);CVPixelBufferRelease(current);self->_busy.store(false);
                if(stale)failure=SPFileRifeError(6,@"RIFE 结果属于旧会话。");
                completion(token,failure?nil:converted,latency,failure);
            });
        }];
        if(!accepted){CVPixelBufferRelease(a);CVPixelBufferRelease(b);fail(SPFileRifeError(7,@"RIFE 暂时无法接收任务。"));}
    });return YES;
}
@end
