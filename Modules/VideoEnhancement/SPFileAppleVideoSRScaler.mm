#import "SPFileAppleVideoSRScaler.h"
#import "SPFileColorTransfer.h"
#import "SPAppleVideoSR.h"
#import <VideoToolbox/VideoToolbox.h>
#import <cmath>
#include <atomic>

static NSError *SPFileVideoSRError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"OpenDuckFrame.FileAppleVideoSR" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}

@implementation SPFileAppleVideoSRScaler {
    SPAppleVideoSR *_engine;
    VTPixelTransferSessionRef _outputTransfer;
    CVPixelBufferPoolRef _videoRangePool, _fullRangePool;
    int _sourceWidth, _sourceHeight, _outputWidth, _outputHeight;
    std::atomic<bool> _busy;
}

- (instancetype)initWithSourceWidth:(int)sourceWidth sourceHeight:(int)sourceHeight outputWidth:(int)outputWidth outputHeight:(int)outputHeight error:(NSError **)error {
    if (!(self = [super init])) return nil;
    _busy.store(false);
    BOOL automatic = outputWidth == 0 && outputHeight == 0;
    NSSize input = automatic ? [SPAppleVideoSR automaticInputForWidth:sourceWidth height:sourceHeight] : NSMakeSize(sourceWidth, sourceHeight);
    if (automatic) {
        NSSize output = [SPAppleVideoSR automaticOutputForWidth:(int)input.width height:(int)input.height];
        outputWidth = (int)output.width; outputHeight = (int)output.height;
    }
    if (sourceWidth < 2 || sourceHeight < 2 || outputWidth < 2 || outputHeight < 2 || (outputWidth & 1) || (outputHeight & 1) ||
        outputWidth > 3840 || outputHeight > 2160) {
        if (error) *error = SPFileVideoSRError(1, @"文件超分需要有效的偶数输出尺寸，最高 3840×2160。"); return nil;
    }
    int inputWidth = (int)input.width, inputHeight = (int)input.height;
    if(inputWidth < 2 || inputHeight < 2 || outputWidth%inputWidth || outputHeight%inputHeight || outputWidth/inputWidth!=outputHeight/inputHeight || outputWidth/inputWidth<2) {
        if(error)*error=SPFileVideoSRError(2,@"Apple 视频超分需要设备支持的整数倍率和来源宽高比。");return nil;
    }
    int factor=outputWidth/inputWidth;
    _engine = [[SPAppleVideoSR alloc] init];
    _engine.allowsInputResize = inputWidth != sourceWidth || inputHeight != sourceHeight;
    if (![_engine prepareWidth:inputWidth height:inputHeight scale:factor error:error]) return nil;
    if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &_outputTransfer) != noErr || !_outputTransfer) {
        [_engine invalidate]; if (error) *error=SPFileVideoSRError(3,@"无法准备文件超分输出格式转换。 "); return nil;
    }
    _sourceWidth=sourceWidth; _sourceHeight=sourceHeight; _outputWidth=outputWidth; _outputHeight=outputHeight;
    return self;
}
- (void)dealloc { [_engine invalidate]; if (_outputTransfer) CFRelease(_outputTransfer); if (_videoRangePool) CFRelease(_videoRangePool); if (_fullRangePool) CFRelease(_fullRangePool); }
- (int)outputWidth { return _outputWidth; }
- (int)outputHeight { return _outputHeight; }
- (NSDictionary<NSString *,id> *)submissionDiagnostics { NSMutableDictionary *d=[_engine.submissionDiagnostics mutableCopy];d[@"temporal"]=@NO;d[@"mode"]=@"Random";return d; }
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
    CFTypeRef matrix=CVBufferCopyAttachment(source,kCVImageBufferYCbCrMatrixKey,NULL),primaries=CVBufferCopyAttachment(source,kCVImageBufferColorPrimariesKey,NULL),trc=CVBufferCopyAttachment(source,kCVImageBufferTransferFunctionKey,NULL);
    BOOL known=matrix&&primaries&&trc&&CFEqual(trc,kCVImageBufferTransferFunction_ITU_R_709_2)&&
        ((CFEqual(matrix,kCVImageBufferYCbCrMatrix_ITU_R_601_4)&&(CFEqual(primaries,kCVImageBufferColorPrimaries_SMPTE_C)||CFEqual(primaries,kCVImageBufferColorPrimaries_EBU_3213))) ||
         (CFEqual(matrix,kCVImageBufferYCbCrMatrix_ITU_R_709_2)&&CFEqual(primaries,kCVImageBufferColorPrimaries_ITU_R_709_2)));
    if(matrix)CFRelease(matrix);if(primaries)CFRelease(primaries);if(trc)CFRelease(trc);
    if (ptsUs==INT64_MIN || hdr || !known || CVPixelBufferGetWidth(source)!=(size_t)_sourceWidth || CVPixelBufferGetHeight(source)!=(size_t)_sourceHeight || !CGRectEqualToRect(clean,whole) ||
        (format!=kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange && format!=kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)) {
        completion(NULL,SPFileVideoSRError(4,@"文件 Apple 视频超分（逐帧实验）需要完整的 SDR 8 位 NV12、支持的 601/709 色彩和有效时间戳。")); return YES;
    }
    // Preserve the source range and colorimetry for VT output conversion.
    if (_busy.exchange(true)) return NO;
    if (!SPConfigureFileColorTransfer(_outputTransfer,source,YES)) {
        _busy.store(false); completion(NULL,SPFileVideoSRError(7,@"无法确定或设置文件的色彩矩阵。"));return YES;
    }
    CVPixelBufferRetain(source);
    BOOL submitted=[_engine submitRandomSource:source pts:CMTimeMake(ptsUs,1000000) token:0 completion:^(uint64_t token, CVPixelBufferRef output, double elapsed, NSError *failure) {
        (void)token; (void)elapsed;
        if (!output || failure) { if (output) CVPixelBufferRelease(output); CVPixelBufferRelease(source); self->_busy.store(false); completion(NULL,failure ?: SPFileVideoSRError(5,@"文件 Apple 视频超分（逐帧实验）失败。")); return; }
        CVPixelBufferPoolRef *pool=format==kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? &self->_fullRangePool : &self->_videoRangePool;
        if (!*pool) {
            NSDictionary *attrs=@{(id)kCVPixelBufferWidthKey:@(self->_outputWidth),(id)kCVPixelBufferHeightKey:@(self->_outputHeight),(id)kCVPixelBufferPixelFormatTypeKey:@(format),(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};
            CVPixelBufferPoolCreate(kCFAllocatorDefault,NULL,(__bridge CFDictionaryRef)attrs,pool);
        }
        NSDictionary *limit=@{(id)kCVPixelBufferPoolAllocationThresholdKey:@4};
        CVPixelBufferRef nv12=NULL;
        CVReturn create=*pool ? CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault,*pool,(__bridge CFDictionaryRef)limit,&nv12) : kCVReturnError;
        if (nv12) {
            CVBufferRemoveAllAttachments(nv12);
            // VT must see the target matrix and range before conversion.
            CVBufferPropagateAttachments(source,nv12);
            CVBufferRemoveAttachment(nv12,kCVImageBufferCleanApertureKey);
            CVBufferRemoveAttachment(nv12,kCVImageBufferPreferredCleanApertureKey);
            CVBufferRemoveAttachment(nv12,kCVImageBufferDisplayDimensionsKey);
        }
        OSStatus converted=(create==kCVReturnSuccess && nv12) ? VTPixelTransferSessionTransferImage(self->_outputTransfer,output,nv12) : -1;
        CVPixelBufferRelease(output);
        if (converted!=noErr) { if (nv12) CVPixelBufferRelease(nv12); CVPixelBufferRelease(source); self->_busy.store(false); completion(NULL,SPFileVideoSRError(6,@"文件 Apple 视频超分（逐帧实验）输出格式转换失败。")); return; }
        CVPixelBufferRelease(source); self->_busy.store(false); completion(nv12,nil);
    }];
    if (!submitted) { CVPixelBufferRelease(source); _busy.store(false); }
    return submitted;
}
@end
