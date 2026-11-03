#import "SPFileLowLatencyEngine.h"
#import "SPLowLatencyEngine.h"
#import "SPFileColorTransfer.h"
#import <VideoToolbox/VideoToolbox.h>
#include <atomic>
#include <cmath>

static NSError *SPFileLLError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"OpenDuckFrame.FileLowLatency" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
static BOOL SPFileLLCompatible(CVPixelBufferRef b, int width, int height, OSType format) {
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
static CVPixelBufferRef SPFileLLTo709(VTPixelTransferSessionRef transfer, CVPixelBufferRef source, int width, int height) {
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
static CVPixelBufferRef SPFileLLConvert(VTPixelTransferSessionRef transfer, CVPixelBufferRef generated, CVPixelBufferRef original, int width, int height, OSType format) {
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
@implementation SPFileLowLatencyEngine {
    dispatch_queue_t _queue;
    SPLowLatencyEngine *_engine;
    VTPixelTransferSessionRef _toNV12, _toRGB;
    std::atomic<bool> _busy;
    uint64_t _epoch;
    int _width,_height;
    OSType _format;
    BOOL _ready;
}
- (instancetype)init {
    if (!(self=[super init])) return nil;
    _queue=dispatch_queue_create("app.openduckframe.file-lowlatency",DISPATCH_QUEUE_SERIAL);
    _busy.store(false); return self;
}
- (void)dealloc { if (_toNV12) CFRelease(_toNV12); if (_toRGB) CFRelease(_toRGB); }
- (void)invalidate {
    @synchronized(self) { _epoch++; _ready=NO; }
    dispatch_async(_queue, ^{ [self->_engine invalidate]; self->_engine=nil; });
}
- (void)prepareWithSample:(CVPixelBufferRef)sample completion:(void (^)(BOOL,NSString *))completion {
    if (!sample || !completion) { if(completion)completion(NO,@"文件视频帧尚未就绪。"); return; }
    int w=(int)CVPixelBufferGetWidth(sample),h=(int)CVPixelBufferGetHeight(sample);
    OSType format=CVPixelBufferGetPixelFormatType(sample);
    if (w<2 || h<2 || (w&1) || (h&1) || !SPFileLLCompatible(sample,w,h,format)) {
        CFTypeRef m=CVBufferCopyAttachment(sample,kCVImageBufferYCbCrMatrixKey,NULL);
        CFTypeRef p=CVBufferCopyAttachment(sample,kCVImageBufferColorPrimariesKey,NULL);
        CFTypeRef t=CVBufferCopyAttachment(sample,kCVImageBufferTransferFunctionKey,NULL);
        NSLog(@"[FileLowLatency] rejected %dx%d format=%u clean=%@ matrix=%@ primaries=%@ transfer=%@",w,h,(unsigned)format,NSStringFromRect(CVImageBufferGetCleanRect(sample)),(__bridge id)m,(__bridge id)p,(__bridge id)t);
        if(m)CFRelease(m);if(p)CFRelease(p);if(t)CFRelease(t);
        completion(NO,@"文件低延迟插帧当前需要完整的 SDR 8 位 NV12 和 BT.709 色彩。"); return;
    }
    CVPixelBufferRetain(sample); uint64_t seen; @synchronized(self) { seen=_epoch; }
    dispatch_async(_queue, ^{
        NSError *error=nil; SPLowLatencyEngine *probe=[SPLowLatencyEngine new];
        if (![probe prepareWidth:w height:h frames:1 error:&error]) {
            CVPixelBufferRelease(sample); completion(NO,error.localizedDescription?:@"低延迟模型准备失败。"); return;
        }
        if (!self->_toRGB && VTPixelTransferSessionCreate(NULL,&self->_toRGB)!=noErr) {
            [probe invalidate]; CVPixelBufferRelease(sample); completion(NO,@"低延迟色彩转换准备失败。"); return;
        }
        CVPixelBufferRef input=SPFileLLTo709(self->_toRGB,sample,w,h);
        if (!input) { [probe invalidate]; CVPixelBufferRelease(sample); completion(NO,@"低延迟预检输入转换失败。"); return; }
        BOOL accepted=[probe submitPrevious:input current:input previousPTS:CMTimeMake(0,1000000)
            currentPTS:CMTimeMake(33333,1000000) phases:@[@0.5] token:0 completion:^(uint64_t token,NSArray<SPOwnedPixelBuffer *> *outputs,double seconds,NSError *failure){
            (void)token;(void)seconds; dispatch_async(self->_queue, ^{
                BOOL valid=!failure && outputs.count==1 && CVPixelBufferGetWidth(outputs[0].buffer)==(size_t)w && CVPixelBufferGetHeight(outputs[0].buffer)==(size_t)h;
                if (valid && !self->_toNV12) valid=VTPixelTransferSessionCreate(NULL,&self->_toNV12)==noErr;
                CVPixelBufferRef checked=valid ? SPFileLLConvert(self->_toNV12,outputs[0].buffer,sample,w,h,format) : NULL;
                valid=valid && checked && SPFileLLCompatible(checked,w,h,format);
                if(checked)CVPixelBufferRelease(checked);
                [probe invalidate]; NSError *nextError=nil; SPLowLatencyEngine *next=nil;
                BOOL stale; @synchronized(self) { stale=seen!=self->_epoch; }
                if (valid && !stale) { next=[SPLowLatencyEngine new]; valid=[next prepareWidth:w height:h frames:1 error:&nextError]; }
                @synchronized(self) {
                    stale=seen!=self->_epoch;
                    if(valid && !stale) { self->_engine=next; self->_width=w; self->_height=h; self->_format=format; self->_ready=YES; }
                }
                if (stale || !valid) [next invalidate];
                CVPixelBufferRelease(sample);
                completion(valid&&!stale, stale?@"准备已取消，原设置保持不变。":(failure.localizedDescription?:nextError.localizedDescription?:@"低延迟预检失败。"));
            });
        }];
        CVPixelBufferRelease(input);
        if (!accepted) { [probe invalidate]; CVPixelBufferRelease(sample); completion(NO,@"低延迟预检无法提交。"); }
    });
}
- (BOOL)submitPrevious:(CVPixelBufferRef)previous current:(CVPixelBufferRef)current
        previousPTSUs:(int64_t)previousPTSUs currentPTSUs:(int64_t)currentPTSUs
               phases:(NSArray<NSNumber *> *)phases token:(uint64_t)token completion:(SPFRCPhasesCompletion)completion {
    if (!previous || !current || !completion || currentPTSUs<=previousPTSUs || phases.count!=1 || fabs(phases[0].doubleValue-0.5)>0.0001) return NO;
    uint64_t seen; int w,h; OSType format;
    @synchronized(self) { if(!_ready)return NO; seen=_epoch; w=_width;h=_height;format=_format; }
    if (!SPFileLLCompatible(previous,w,h,format) || !SPFileLLCompatible(current,w,h,format) || _busy.exchange(true)) return NO;
    CVPixelBufferRetain(previous); CVPixelBufferRetain(current);
    dispatch_async(_queue, ^{
        BOOL stale; @synchronized(self) { stale=seen!=self->_epoch || !self->_ready; }
        if (stale || !self->_engine) {
            CVPixelBufferRelease(previous); CVPixelBufferRelease(current); self->_busy.store(false);
            completion(token,nil,0,SPFileLLError(1,@"低延迟结果属于旧会话。")); return;
        }
        CVPixelBufferRef a=SPFileLLTo709(self->_toRGB,previous,w,h),b=SPFileLLTo709(self->_toRGB,current,w,h);
        if (!a || !b) { if(a)CVPixelBufferRelease(a); if(b)CVPixelBufferRelease(b); CVPixelBufferRelease(previous); CVPixelBufferRelease(current); self->_busy.store(false); completion(token,nil,0,SPFileLLError(4,@"低延迟输入色彩转换失败。")); return; }
        BOOL accepted=[self->_engine submitPrevious:a current:b previousPTS:CMTimeMake(previousPTSUs,1000000)
            currentPTS:CMTimeMake(currentPTSUs,1000000) phases:phases token:token completion:^(uint64_t returned,NSArray<SPOwnedPixelBuffer *> *outputs,double seconds,NSError *error){
            dispatch_async(self->_queue, ^{
                BOOL stale; @synchronized(self) { stale=seen!=self->_epoch || !self->_ready; }
                NSError *failure=error; CVPixelBufferRef result=NULL;
                if (!stale && !failure && outputs.count==1)
                    result=SPFileLLConvert(self->_toNV12,outputs[0].buffer,previous,w,h,format);
                if (stale) failure=SPFileLLError(1,@"低延迟结果属于旧会话。");
                else if (!failure && !result) failure=SPFileLLError(2,@"低延迟输出格式转换失败。");
                NSArray *boxes=result ? @[[[SPOwnedPixelBuffer alloc] initWithBufferNoCopy:result]] : nil;
                CVPixelBufferRelease(previous); CVPixelBufferRelease(current); self->_busy.store(false);
                completion(returned,boxes,seconds,failure);
            });
        }];
        CVPixelBufferRelease(a); CVPixelBufferRelease(b);
        if (!accepted) { CVPixelBufferRelease(previous); CVPixelBufferRelease(current); self->_busy.store(false); completion(token,nil,0,SPFileLLError(3,@"低延迟引擎无法接收文件帧。")); }
    }); return YES;
}
@end
