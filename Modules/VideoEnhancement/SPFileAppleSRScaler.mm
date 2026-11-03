#import "SPFileAppleSRScaler.h"
#import "SPFileColorTransfer.h"
#import "SPAppleLowLatencySR.h"
#import <VideoToolbox/VideoToolbox.h>
#import <cmath>
#include <atomic>

static NSError *SPFileSRError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"OpenDuckFrame.FileAppleSR" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}

@implementation SPFileAppleSRScaler {
    SPAppleLowLatencySR *_engine;
    VTPixelTransferSessionRef _outputTransfer;
    int _sourceWidth, _sourceHeight, _outputWidth, _outputHeight;
    std::atomic<bool> _busy;
}

- (instancetype)initWithSourceWidth:(int)sourceWidth sourceHeight:(int)sourceHeight outputWidth:(int)outputWidth outputHeight:(int)outputHeight error:(NSError **)error {
    if (!(self = [super init])) return nil;
    _busy.store(false);
    if (sourceWidth < 2 || sourceHeight < 2 || outputWidth < 2 || outputHeight < 2 || (outputWidth & 1) || (outputHeight & 1) ||
        outputWidth > 3840 || outputHeight > 2160) {
        if (error) *error = SPFileSRError(1, @"文件超分需要有效的偶数输出尺寸，最高 3840×2160。"); return nil;
    }
    double x = (double)outputWidth/sourceWidth, y = (double)outputHeight/sourceHeight;
    if (std::fabs(x-y) > 0.0001) { if (error) *error=SPFileSRError(2,@"Apple 超分需要保持来源宽高比。 "); return nil; }
    _engine = [[SPAppleLowLatencySR alloc] init];
    if (![_engine prepareWidth:sourceWidth height:sourceHeight scale:(float)x error:error]) return nil;
    if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &_outputTransfer) != noErr || !_outputTransfer) {
        [_engine invalidate]; if (error) *error=SPFileSRError(3,@"无法准备文件超分输出格式转换。 "); return nil;
    }
    _sourceWidth=sourceWidth; _sourceHeight=sourceHeight; _outputWidth=outputWidth; _outputHeight=outputHeight;
    return self;
}
- (void)dealloc { [_engine invalidate]; if (_outputTransfer) CFRelease(_outputTransfer); }
- (int)outputWidth { return _outputWidth; }
- (int)outputHeight { return _outputHeight; }
- (BOOL)submit:(CVPixelBufferRef)source completion:(void (^)(CVPixelBufferRef, NSError *))completion {
    return [self submit:source ptsUs:INT64_MIN completion:completion];
}
- (BOOL)submit:(CVPixelBufferRef)source ptsUs:(int64_t)ptsUs completion:(void (^)(CVPixelBufferRef, NSError *))completion {
    if (!source || !completion) return NO;
    OSType format=CVPixelBufferGetPixelFormatType(source);
    CGRect clean=CVImageBufferGetCleanRect(source);
    CGRect whole=CGRectMake(0,0,CVPixelBufferGetWidth(source),CVPixelBufferGetHeight(source));
    CFTypeRef transfer=CVBufferCopyAttachment(source,kCVImageBufferTransferFunctionKey,NULL);
    BOOL hdr=transfer && (CFEqual(transfer,kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) || CFEqual(transfer,kCVImageBufferTransferFunction_ITU_R_2100_HLG));
    if (transfer) CFRelease(transfer);
    if (ptsUs==INT64_MIN || hdr || CVPixelBufferGetWidth(source)!=(size_t)_sourceWidth || CVPixelBufferGetHeight(source)!=(size_t)_sourceHeight || !CGRectEqualToRect(clean,whole) ||
        (format!=kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange && format!=kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)) {
        completion(NULL,SPFileSRError(4,@"文件 Apple 超分需要完整的 SDR 8 位 NV12 视频帧及有效时间戳。")); return YES;
    }
    // Preserve the source range and colorimetry for VT output conversion.
    if (_busy.exchange(true)) return NO;
    if (!SPConfigureFileColorTransfer(_outputTransfer,source,YES)) {
        _busy.store(false); completion(NULL,SPFileSRError(7,@"无法确定或设置文件的色彩矩阵。"));return YES;
    }
    CVPixelBufferRetain(source);
    BOOL submitted=[_engine submitSource:source pts:CMTimeMake(ptsUs,1000000) token:0 completion:^(uint64_t token, CVPixelBufferRef output, double elapsed, NSError *failure) {
        (void)token; (void)elapsed;
        if (!output || failure) { if (output) CVPixelBufferRelease(output); CVPixelBufferRelease(source); self->_busy.store(false); completion(NULL,failure ?: SPFileSRError(5,@"文件 Apple 超分失败。")); return; }
        NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};
        CVPixelBufferRef nv12=NULL;
        CVReturn create=CVPixelBufferCreate(kCFAllocatorDefault,self->_outputWidth,self->_outputHeight,format,(__bridge CFDictionaryRef)attrs,&nv12);
        if (nv12) {
            // VT must see the target matrix and range before conversion.
            CVBufferPropagateAttachments(source,nv12);
            CVBufferRemoveAttachment(nv12,kCVImageBufferCleanApertureKey);
            CVBufferRemoveAttachment(nv12,kCVImageBufferPreferredCleanApertureKey);
            CVBufferRemoveAttachment(nv12,kCVImageBufferDisplayDimensionsKey);
        }
        OSStatus converted=(create==kCVReturnSuccess && nv12) ? VTPixelTransferSessionTransferImage(self->_outputTransfer,output,nv12) : -1;
        CVPixelBufferRelease(output);
        if (converted!=noErr) { if (nv12) CVPixelBufferRelease(nv12); CVPixelBufferRelease(source); self->_busy.store(false); completion(NULL,SPFileSRError(6,@"文件 Apple 超分输出格式转换失败。")); return; }
        CVPixelBufferRelease(source); self->_busy.store(false); completion(nv12,nil);
    }];
    if (!submitted) { CVPixelBufferRelease(source); _busy.store(false); }
    return submitted;
}
@end
