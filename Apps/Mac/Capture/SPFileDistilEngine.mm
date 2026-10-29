#import "SPFileDistilEngine.h"
#import "SPDistilDRBA.h"
#import "SPFileColorTransfer.h"
#import <VideoToolbox/VideoToolbox.h>
#include <atomic>
#include <cmath>

static std::atomic<bool> SPFileDistilPreflightBusy{false};
static NSError *SPFileDistilError(NSInteger code,NSString *message){return [NSError errorWithDomain:@"Khua.FileDistil" code:code userInfo:@{NSLocalizedDescriptionKey:message}];}
static BOOL SPDistilFileCompatible(CVPixelBufferRef b, int width, int height, OSType format) {
    if (!b || CVPixelBufferGetWidth(b)!=(size_t)width || CVPixelBufferGetHeight(b)!=(size_t)height ||
        CVPixelBufferGetPixelFormatType(b)!=format ||
        (format!=kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange && format!=kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) ||
        !CGRectEqualToRect(CVImageBufferGetCleanRect(b),CGRectMake(0,0,width,height))) return NO;
    CFTypeRef matrix=CVBufferCopyAttachment(b,kCVImageBufferYCbCrMatrixKey,NULL);
    CFTypeRef primaries=CVBufferCopyAttachment(b,kCVImageBufferColorPrimariesKey,NULL);
    CFTypeRef transfer=CVBufferCopyAttachment(b,kCVImageBufferTransferFunctionKey,NULL);
    BOOL matrixOK=matrix && CFEqual(matrix,kCVImageBufferYCbCrMatrix_ITU_R_709_2);
    BOOL primariesOK=primaries && CFEqual(primaries,kCVImageBufferColorPrimaries_ITU_R_709_2);
    BOOL valid=matrixOK && primariesOK && transfer && CFEqual(transfer,kCVImageBufferTransferFunction_ITU_R_709_2);
    if(matrix)CFRelease(matrix); if(primaries)CFRelease(primaries); if(transfer)CFRelease(transfer);
    return valid;
}
static CVPixelBufferRef SPDistilFileTo709(VTPixelTransferSessionRef transfer, CVPixelBufferRef source, int width, int height) {
    if (!transfer || !source ||
        VTSessionSetProperty(transfer,kVTPixelTransferPropertyKey_DestinationColorPrimaries,kCVImageBufferColorPrimaries_ITU_R_709_2)!=noErr ||
        VTSessionSetProperty(transfer,kVTPixelTransferPropertyKey_DestinationTransferFunction,kCVImageBufferTransferFunction_ITU_R_709_2)!=noErr) return NULL;
    NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};
    CVPixelBufferRef rgb=NULL;
    if (CVPixelBufferCreate(NULL,width,height,kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)attrs,&rgb)!=kCVReturnSuccess) return NULL;
    CVBufferSetAttachment(rgb,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(rgb,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    if (VTPixelTransferSessionTransferImage(transfer,source,rgb)!=noErr) { CVPixelBufferRelease(rgb); return NULL; }
    CVBufferSetAttachment(rgb,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(rgb,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    CVBufferRemoveAttachment(rgb,kCVImageBufferYCbCrMatrixKey);
    return rgb;
}
static CVPixelBufferRef SPDistilFileConvert(VTPixelTransferSessionRef transfer, CVPixelBufferRef generated, CVPixelBufferRef original, int width, int height, OSType format) {
    if (!generated || CVPixelBufferGetWidth(generated)!=(size_t)width || CVPixelBufferGetHeight(generated)!=(size_t)height) return NULL;
    CVPixelBufferRef result=NULL;
    NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};
    if(CVPixelBufferCreate(NULL,width,height,format,(__bridge CFDictionaryRef)attrs,&result)!=kCVReturnSuccess) return NULL;
    CVBufferPropagateAttachments(original,result);
    if (!SPConfigureFileColorTransfer(transfer,original,YES) || VTPixelTransferSessionTransferImage(transfer,generated,result)!=noErr) {
        CVPixelBufferRelease(result); return NULL;
    }
    CVBufferPropagateAttachments(original,result);
    return result;
}
@implementation SPFileDistilEngine {
    dispatch_queue_t _queue; NSBundle *_bundle; SPDistilDRBA *_engine;
    VTPixelTransferSessionRef _toRGB, _toNV12;
    std::atomic<bool> _busy; uint64_t _epoch; OSType _format; BOOL _ready;
}
- (instancetype)init { return [self initWithResourceBundle:NSBundle.mainBundle]; }
- (instancetype)initWithResourceBundle:(NSBundle *)bundle {
    if(!(self=[super init]))return nil; _bundle=bundle; _busy.store(false);
    _queue=dispatch_queue_create("app.khuaplayer.file-distil",DISPATCH_QUEUE_SERIAL);return self;
}
- (void)dealloc {if(_toRGB)CFRelease(_toRGB);if(_toNV12)CFRelease(_toNV12);}
- (BOOL)requiresPrecedingSource{return YES;}
- (void)invalidate { @synchronized(self){_epoch++;_ready=NO;} dispatch_async(_queue,^{[self->_engine invalidate];self->_engine=nil;}); }
- (void)prepareWithSample:(CVPixelBufferRef)sample completion:(void (^)(BOOL,NSString *))completion {
    if(!sample||!completion){if(completion)completion(NO,@"文件视频帧尚未就绪。");return;}
    OSType format=CVPixelBufferGetPixelFormatType(sample);
    if(!SPDistilFileCompatible(sample,1280,720,format)){completion(NO,@"DistilDRBA 文件插帧需要 1280×720、SDR 8 位 NV12 和 BT.709 色彩。");return;}
    if(SPFileDistilPreflightBusy.exchange(true)){completion(NO,@"DistilDRBA 正在处理画面，请稍后重试。");return;}
    CVPixelBufferRetain(sample);uint64_t seen;@synchronized(self){seen=_epoch;}
    dispatch_async(_queue,^{
        NSError *error=nil;SPDistilDRBA *engine=[[SPDistilDRBA alloc] initWithResourceBundle:self->_bundle];
        if(![engine prepareWidth:1280 height:720 error:&error]){CVPixelBufferRelease(sample);SPFileDistilPreflightBusy.store(false);completion(NO,error.localizedDescription?:@"DistilDRBA 模型准备失败。");return;}
        if((!self->_toRGB && VTPixelTransferSessionCreate(NULL,&self->_toRGB)!=noErr) || (!self->_toNV12 && VTPixelTransferSessionCreate(NULL,&self->_toNV12)!=noErr)) {
            [engine invalidate];CVPixelBufferRelease(sample);SPFileDistilPreflightBusy.store(false);completion(NO,@"DistilDRBA 色彩转换准备失败。");return;
        }
        CVPixelBufferRef rgb=SPDistilFileTo709(self->_toRGB,sample,1280,720);
        if(!rgb){[engine invalidate];CVPixelBufferRelease(sample);SPFileDistilPreflightBusy.store(false);completion(NO,@"DistilDRBA 输入转换失败。");return;}
        BOOL accepted=[engine submitPrevious:rgb current:rgb next:rgb pts:CMTimeMake(1,60) token:0 completion:^(uint64_t token,CVPixelBufferRef out,double sec,NSError *failure){
            (void)token;(void)sec;dispatch_async(self->_queue,^{
                CVPixelBufferRef converted=(!failure && out)?SPDistilFileConvert(self->_toNV12,out,sample,1280,720,format):NULL;
                BOOL ready=converted && SPDistilFileCompatible(converted,1280,720,format);if(converted)CVPixelBufferRelease(converted);if(out)CVPixelBufferRelease(out);
                BOOL stale;@synchronized(self){stale=seen!=self->_epoch;if(ready&&!stale){self->_engine=engine;self->_format=format;self->_ready=YES;}}
                if(stale||!ready)[engine invalidate];CVPixelBufferRelease(sample);SPFileDistilPreflightBusy.store(false);
                completion(ready&&!stale,stale?@"准备已取消，原设置保持不变。":(failure.localizedDescription?:@"DistilDRBA 预检失败。"));
            });
        }];
        CVPixelBufferRelease(rgb);if(!accepted){[engine invalidate];CVPixelBufferRelease(sample);SPFileDistilPreflightBusy.store(false);completion(NO,@"DistilDRBA 预检无法提交。");}
    });
}
- (BOOL)submitPrevious:(CVPixelBufferRef)a current:(CVPixelBufferRef)b previousPTSUs:(int64_t)pa currentPTSUs:(int64_t)pb phases:(NSArray<NSNumber *> *)phases token:(uint64_t)token completion:(SPFRCPhasesCompletion)completion {
    (void)a;(void)b;(void)pa;(void)pb;(void)phases;(void)token;(void)completion;return NO;
}
- (BOOL)submitPreceding:(CVPixelBufferRef)p previous:(CVPixelBufferRef)a current:(CVPixelBufferRef)b precedingPTSUs:(int64_t)pp previousPTSUs:(int64_t)pa currentPTSUs:(int64_t)pb phases:(NSArray<NSNumber *> *)phases token:(uint64_t)token completion:(SPFRCPhasesCompletion)completion {
    if(!p||!a||!b||!completion||pp>=pa||pa>=pb||phases.count!=1||fabs(phases[0].doubleValue-0.5)>0.0001)return NO;
    uint64_t seen;OSType format;@synchronized(self){if(!_ready)return NO;seen=_epoch;format=_format;}
    if(!SPDistilFileCompatible(p,1280,720,format)||!SPDistilFileCompatible(a,1280,720,format)||!SPDistilFileCompatible(b,1280,720,format)||_busy.exchange(true))return NO;
    CVPixelBufferRetain(p);CVPixelBufferRetain(a);CVPixelBufferRetain(b);
    dispatch_async(_queue,^{
        BOOL stale;@synchronized(self){stale=seen!=self->_epoch||!self->_ready;}
        if(stale||!self->_engine){CVPixelBufferRelease(p);CVPixelBufferRelease(a);CVPixelBufferRelease(b);self->_busy.store(false);completion(token,nil,0,SPFileDistilError(1,@"DistilDRBA 结果属于旧会话。"));return;}
        CVPixelBufferRef x=SPDistilFileTo709(self->_toRGB,p,1280,720),y=SPDistilFileTo709(self->_toRGB,a,1280,720),z=SPDistilFileTo709(self->_toRGB,b,1280,720);
        if(!x||!y||!z){if(x)CVPixelBufferRelease(x);if(y)CVPixelBufferRelease(y);if(z)CVPixelBufferRelease(z);CVPixelBufferRelease(p);CVPixelBufferRelease(a);CVPixelBufferRelease(b);self->_busy.store(false);completion(token,nil,0,SPFileDistilError(2,@"DistilDRBA 输入转换失败。"));return;}
        CMTime midpoint=CMTimeMake(pa+(pb-pa)/2,1000000);
        BOOL accepted=[self->_engine submitPrevious:x current:y next:z pts:midpoint token:token completion:^(uint64_t returned,CVPixelBufferRef out,double sec,NSError *failure){
            dispatch_async(self->_queue,^{
                BOOL old;@synchronized(self){old=seen!=self->_epoch||!self->_ready;}
                CVPixelBufferRef nv=(!old && !failure && out)?SPDistilFileConvert(self->_toNV12,out,a,1280,720,format):NULL;
                if(out)CVPixelBufferRelease(out);NSError *resultError=failure;if(old)resultError=SPFileDistilError(1,@"DistilDRBA 结果属于旧会话。");else if(!resultError&&!nv)resultError=SPFileDistilError(3,@"DistilDRBA 输出转换失败。");
                NSArray *result=nv?@[[[SPOwnedPixelBuffer alloc] initWithBufferNoCopy:nv]]:nil;
                CVPixelBufferRelease(p);CVPixelBufferRelease(a);CVPixelBufferRelease(b);self->_busy.store(false);completion(returned,result,sec,resultError);
            });
        }];
        CVPixelBufferRelease(x);CVPixelBufferRelease(y);CVPixelBufferRelease(z);
        if(!accepted){CVPixelBufferRelease(p);CVPixelBufferRelease(a);CVPixelBufferRelease(b);self->_busy.store(false);completion(token,nil,0,SPFileDistilError(4,@"DistilDRBA 无法接收文件帧。"));}
    });return YES;
}
@end
