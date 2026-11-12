#import "SPFileAnimationScaler.h"
#import "SPFileColorTransfer.h"
#import "SPAnime4K.h"
#import "SPArtCNNSR.h"
#import "SPRealCUGAN.h"
#import <VideoToolbox/VideoToolbox.h>
#include <atomic>

static NSError *SPFileAnimationError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"OpenDuckFrame.FileAnimation" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}

@implementation SPFileAnimationScaler {
    SPAnime4K *_anime;
    SPRealCUGAN *_cugan;
    SPArtCNNSR *_artCNN;
    VTPixelTransferSessionRef _toRGB, _toNV12;
    int _width, _height;
    std::atomic<bool> _busy;
}
- (instancetype)initWithSourceWidth:(int)width sourceHeight:(int)height engine:(NSString *)engine variant:(NSString *)variant resourceBundle:(NSBundle *)bundle error:(NSError **)error {
    if (!(self=[super init])) return nil;
    _busy.store(false);
    if (width<2 || height<2 || width>1920 || height>1080 || (width&1) || (height&1)) {
        if(error)*error=SPFileAnimationError(1,@"动画超分需要偶数输入尺寸，2× 输出最高 3840×2160。");return nil;
    }
    if ([engine isEqualToString:@"artcnn.c4f16"] || [engine isEqualToString:@"artcnn.c4f32"]) {
        _artCNN=[[SPArtCNNSR alloc] initWithResourceBundle:bundle];
        int features=[engine isEqualToString:@"artcnn.c4f32"]?32:16;
        if(![_artCNN prepareWidth:width height:height features:features error:error]) return nil;
    } else if ([engine isEqualToString:@"anime4k"]) {
        _anime=[[SPAnime4K alloc] initWithResourceBundle:bundle];
        if(![_anime prepareWidth:width height:height error:error]) return nil;
    } else if ([engine isEqualToString:@"realcugan"]) {
        _cugan=[[SPRealCUGAN alloc] initWithResourceBundle:bundle];
        if(![_cugan prepareWidth:width height:height variant:variant error:error]) return nil;
    } else { if(error)*error=SPFileAnimationError(2,@"这个动画超分引擎尚未接入。");return nil; }
    if(!_artCNN && (VTPixelTransferSessionCreate(kCFAllocatorDefault,&_toRGB)!=noErr || !_toRGB ||
       VTPixelTransferSessionCreate(kCFAllocatorDefault,&_toNV12)!=noErr || !_toNV12)) {
        if(error)*error=SPFileAnimationError(3,@"无法准备动画超分的画面格式转换。");return nil;
    }
    _width=width;_height=height;return self;
}
- (void)dealloc { [_anime invalidate];[_cugan invalidate];[_artCNN invalidate];if(_toRGB)CFRelease(_toRGB);if(_toNV12)CFRelease(_toNV12); }
- (int)outputWidth { return _width*2; }
- (int)outputHeight { return _height*2; }
- (BOOL)submit:(CVPixelBufferRef)source completion:(void (^)(CVPixelBufferRef, NSError *))completion {
    return [self submit:source ptsUs:INT64_MIN completion:completion];
}
- (BOOL)submit:(CVPixelBufferRef)source ptsUs:(int64_t)ptsUs completion:(void (^)(CVPixelBufferRef, NSError *))completion {
    if(!source||!completion)return NO;
    OSType format=CVPixelBufferGetPixelFormatType(source);
    CGRect whole=CGRectMake(0,0,CVPixelBufferGetWidth(source),CVPixelBufferGetHeight(source));
    CFTypeRef transfer=CVBufferCopyAttachment(source,kCVImageBufferTransferFunctionKey,NULL);
    BOOL hdr=transfer && (CFEqual(transfer,kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)||CFEqual(transfer,kCVImageBufferTransferFunction_ITU_R_2100_HLG));
    if(transfer)CFRelease(transfer);
    if(ptsUs==INT64_MIN||hdr||CVPixelBufferGetWidth(source)!=(size_t)_width||CVPixelBufferGetHeight(source)!=(size_t)_height||
       !CGRectEqualToRect(CVImageBufferGetCleanRect(source),whole)||
       (format!=kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange&&format!=kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)) {
        completion(NULL,SPFileAnimationError(4,@"动画超分需要完整的 SDR 8 位 NV12 帧和有效时间戳。"));return YES;
    }
    if(_busy.exchange(true))return NO;
    if(_artCNN) {
        // ArtCNN consumes the decoder's NV12 directly, retaining its original PTS
        // and color metadata; its completion transfers the native 2× NV12 +1.
        BOOL accepted=[_artCNN submitSource:source pts:CMTimeMake(ptsUs,1000000) token:0
            completion:^(uint64_t token,CVPixelBufferRef output,double elapsed,NSError *failure){
                (void)token;(void)elapsed;
                self->_busy.store(false);
                if(!output || failure) {
                    if(output)CVPixelBufferRelease(output);
                    completion(NULL,failure ?: SPFileAnimationError(7,@"ArtCNN 超分处理失败。"));
                } else completion(output,nil);
            }];
        if(!accepted)_busy.store(false);
        return accepted;
    }
    CFTypeRef sourcePrimaries=CVBufferCopyAttachment(source,kCVImageBufferColorPrimariesKey,NULL);
    CFTypeRef sourceTransfer=CVBufferCopyAttachment(source,kCVImageBufferTransferFunctionKey,NULL);
    BOOL knownColor=sourcePrimaries && sourceTransfer && CFGetTypeID(sourcePrimaries)==CFStringGetTypeID() && CFGetTypeID(sourceTransfer)==CFStringGetTypeID();
    if(sourcePrimaries)CFRelease(sourcePrimaries);if(sourceTransfer)CFRelease(sourceTransfer);
    // The official Anime4K path operates in BT.709 RGB. Convert to that
    // working space, then convert the result back to the source color space.
    BOOL configured=knownColor && SPConfigureFileColorTransfer(_toNV12,source,YES) &&
        VTSessionSetProperty(_toRGB,kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,NULL)==noErr &&
        VTSessionSetProperty(_toRGB,kVTPixelTransferPropertyKey_DestinationColorPrimaries,kCVImageBufferColorPrimaries_ITU_R_709_2)==noErr &&
        VTSessionSetProperty(_toRGB,kVTPixelTransferPropertyKey_DestinationTransferFunction,kCVImageBufferTransferFunction_ITU_R_709_2)==noErr;
    if(!configured) {
        _busy.store(false);completion(NULL,SPFileAnimationError(9,@"无法确定或设置文件的色彩信息。"));return YES;
    }
    NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};
    CVPixelBufferRef rgb=NULL;
    if(CVPixelBufferCreate(kCFAllocatorDefault,_width,_height,kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)attrs,&rgb)!=kCVReturnSuccess||!rgb) {
        _busy.store(false);completion(NULL,SPFileAnimationError(5,@"动画超分输入画面分配失败。"));return YES;
    }
    CVBufferPropagateAttachments(source,rgb);
    CVBufferSetAttachment(rgb,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(rgb,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    CVBufferRemoveAttachment(rgb,kCVImageBufferYCbCrMatrixKey);
    if(VTPixelTransferSessionTransferImage(_toRGB,source,rgb)!=noErr) {
        CVPixelBufferRelease(rgb);_busy.store(false);completion(NULL,SPFileAnimationError(6,@"动画超分输入格式转换失败。"));return YES;
    }
    CVBufferSetAttachment(rgb,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(rgb,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    CVBufferRemoveAttachment(rgb,kCVImageBufferYCbCrMatrixKey);
    CVPixelBufferRetain(source);
    SPFRCEngineCompletion finish=^(uint64_t token,CVPixelBufferRef output,double elapsed,NSError *failure){
        (void)token;(void)elapsed;
        if(!output||failure){if(output)CVPixelBufferRelease(output);CVPixelBufferRelease(source);self->_busy.store(false);completion(NULL,failure ?: SPFileAnimationError(7,@"动画超分处理失败。"));return;}
        CVPixelBufferRef nv12=NULL;
        CVReturn created=CVPixelBufferCreate(kCFAllocatorDefault,self->_width*2,self->_height*2,format,(__bridge CFDictionaryRef)attrs,&nv12);
        if(nv12){
            CVBufferPropagateAttachments(source,nv12);
            CVBufferRemoveAttachment(nv12,kCVImageBufferCleanApertureKey);
            CVBufferRemoveAttachment(nv12,kCVImageBufferPreferredCleanApertureKey);
            CVBufferRemoveAttachment(nv12,kCVImageBufferDisplayDimensionsKey);
        }
        OSStatus status=(created==kCVReturnSuccess&&nv12)?VTPixelTransferSessionTransferImage(self->_toNV12,output,nv12):-1;
        CVPixelBufferRelease(output);
        if(status!=noErr){if(nv12)CVPixelBufferRelease(nv12);CVPixelBufferRelease(source);self->_busy.store(false);completion(NULL,SPFileAnimationError(8,@"动画超分输出格式转换失败。"));return;}
        CVPixelBufferRelease(source);self->_busy.store(false);completion(nv12,nil);
    };
    BOOL accepted=_anime?[_anime submitSource:rgb pts:CMTimeMake(ptsUs,1000000) token:0 completion:finish]:[_cugan submitSource:rgb pts:CMTimeMake(ptsUs,1000000) token:0 completion:finish];
    CVPixelBufferRelease(rgb);
    if(!accepted){CVPixelBufferRelease(source);_busy.store(false);}
    return accepted;
}
@end
