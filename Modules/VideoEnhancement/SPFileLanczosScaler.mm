#import "SPFileLanczosScaler.h"
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#include <atomic>

static NSError *SPFileScaleError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"Khua.FileLanczos" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}

@implementation SPFileLanczosScaler {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    MPSImageLanczosScale *_luma;
    MPSImageLanczosScale *_chroma;
    CVMetalTextureCacheRef _cache;
    int _width, _height;
    std::atomic<bool> _busy;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device width:(int)width height:(int)height error:(NSError **)error {
    if (!(self = [super init])) return nil;
    _busy.store(false);
    if (!device || !MPSSupportsMTLDevice(device) || width < 2 || height < 2 || width > 3840 || height > 2160 || (width & 1) || (height & 1)) {
        if (error) *error = SPFileScaleError(1, @"设备不支持或输出尺寸无效（须为偶数，最高 3840×2160）。");
        return nil;
    }
    _device = device; _width = width; _height = height;
    _queue = [device newCommandQueue];
    _luma = [[MPSImageLanczosScale alloc] initWithDevice:device];
    _chroma = [[MPSImageLanczosScale alloc] initWithDevice:device];
    if (!_queue || !_luma || !_chroma || CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, device, NULL, &_cache) != kCVReturnSuccess) {
        if (error) *error = SPFileScaleError(2, @"Lanczos 图像处理器准备失败。");
        return nil;
    }
    return self;
}

- (void)dealloc { if (_cache) CFRelease(_cache); }
- (int)outputWidth { return _width; }
- (int)outputHeight { return _height; }

- (BOOL)submit:(CVPixelBufferRef)source ptsUs:(int64_t)ptsUs completion:(void (^)(CVPixelBufferRef, NSError *))completion {
    (void)ptsUs;
    return [self submit:source completion:completion];
}

- (BOOL)submit:(CVPixelBufferRef)source completion:(void (^)(CVPixelBufferRef, NSError *))completion {
    if (!source || !completion || _busy.exchange(true)) return NO;
    const OSType format = CVPixelBufferGetPixelFormatType(source);
    CFTypeRef transfer = CVBufferCopyAttachment(source, kCVImageBufferTransferFunctionKey, NULL);
    BOOL hdr = transfer && (CFEqual(transfer, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) ||
                            CFEqual(transfer, kCVImageBufferTransferFunction_ITU_R_2100_HLG));
    if (transfer) CFRelease(transfer);
    if ((format != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange && format != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) || hdr) {
        _busy.store(false);
        completion(NULL, SPFileScaleError(3, @"文件 Lanczos 目前仅支持 SDR 的 8 位 NV12 视频。"));
        return YES;
    }
    CGRect clean = CVImageBufferGetCleanRect(source);
    CGRect whole = CGRectMake(0, 0, CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source));
    if (!CGRectEqualToRect(clean, whole)) {
        _busy.store(false);
        completion(NULL, SPFileScaleError(7, @"文件 Lanczos 暂不支持带裁切区域的视频。"));
        return YES;
    }
    NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey:@{}, (id)kCVPixelBufferMetalCompatibilityKey:@YES};
    CVPixelBufferRef output = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, _width, _height, format, (__bridge CFDictionaryRef)attrs, &output) != kCVReturnSuccess || !output) {
        _busy.store(false); completion(NULL, SPFileScaleError(4, @"无法分配缩放输出。")); return YES;
    }
    CVBufferPropagateAttachments(source, output);
    CVBufferRemoveAttachment(output, kCVImageBufferCleanApertureKey);
    CVBufferRemoveAttachment(output, kCVImageBufferPreferredCleanApertureKey);
    CVBufferRemoveAttachment(output, kCVImageBufferDisplayDimensionsKey);
    CVMetalTextureRef refs[4] = { NULL, NULL, NULL, NULL };
    const MTLPixelFormat pixelFormats[2] = { MTLPixelFormatR8Unorm, MTLPixelFormatRG8Unorm };
    BOOL valid = YES;
    for (size_t i=0; i<2; ++i) {
        CVReturn a = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _cache, source, NULL, pixelFormats[i], CVPixelBufferGetWidthOfPlane(source,i), CVPixelBufferGetHeightOfPlane(source,i), i, &refs[i]);
        CVReturn b = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _cache, output, NULL, pixelFormats[i], CVPixelBufferGetWidthOfPlane(output,i), CVPixelBufferGetHeightOfPlane(output,i), i, &refs[i+2]);
        if (a != kCVReturnSuccess || b != kCVReturnSuccess || !refs[i] || !refs[i+2]) valid = NO;
    }
    id<MTLCommandBuffer> command = valid ? [_queue commandBuffer] : nil;
    if (!command) {
        for (auto ref : refs) if (ref) CFRelease(ref);
        CVPixelBufferRelease(output); _busy.store(false);
        completion(NULL, SPFileScaleError(5, @"无法创建缩放纹理或 GPU 命令。")); return YES;
    }
    CVPixelBufferRetain(source);
    [_luma encodeToCommandBuffer:command sourceTexture:CVMetalTextureGetTexture(refs[0]) destinationTexture:CVMetalTextureGetTexture(refs[2])];
    [_chroma encodeToCommandBuffer:command sourceTexture:CVMetalTextureGetTexture(refs[1]) destinationTexture:CVMetalTextureGetTexture(refs[3])];
    CVMetalTextureRef r0=refs[0],r1=refs[1],r2=refs[2],r3=refs[3];
    [command addCompletedHandler:^(id<MTLCommandBuffer> done) {
        CFRelease(r0); CFRelease(r1); CFRelease(r2); CFRelease(r3);
        CVPixelBufferRelease(source);
        self->_busy.store(false);
        if (done.status == MTLCommandBufferStatusCompleted) completion(output, nil);
        else { CVPixelBufferRelease(output); completion(NULL, SPFileScaleError(6, @"Lanczos GPU 处理失败。")); }
    }];
    [command commit];
    return YES;
}
@end
