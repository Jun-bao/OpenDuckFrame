#import "SPAirFusedPreprocessor.h"
#import <simd/simd.h>

static NSError *SPAirFusedError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"app.openduckframe.air-fused-preprocessor" code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation SPAirFusedPreprocessor {
    id<MTLCommandQueue> _queue;
    id<MTLComputePipelineState> _pipeline;
    CVMetalTextureCacheRef _textureCache;
    CVPixelBufferPoolRef _outputPool;
    int _sourceWidth, _sourceHeight, _outputWidth, _outputHeight;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
                        library:(id<MTLLibrary>)library
                    sourceWidth:(int)sourceWidth
                   sourceHeight:(int)sourceHeight
                    outputWidth:(int)outputWidth
                   outputHeight:(int)outputHeight
                          error:(NSError **)error {
    if (!(self = [super init])) return nil;
    if (sourceWidth < 2 || sourceHeight < 2 || outputWidth < 2 || outputHeight < 2 ||
        (sourceWidth & 1) || (sourceHeight & 1) || (outputWidth & 1) || (outputHeight & 1) ||
        library.device.registryID != device.registryID) {
        if (error) *error = SPAirFusedError(1, @"Invalid fused input dimensions or Metal device binding");
        return nil;
    }
    _sourceWidth = sourceWidth; _sourceHeight = sourceHeight;
    _outputWidth = outputWidth; _outputHeight = outputHeight;
    _queue = [device newCommandQueue];
    id<MTLFunction> function = [library newFunctionWithName:@"spAirNV12Lanczos"];
    NSError *pipelineError = nil;
    _pipeline = function ? [device newComputePipelineStateWithFunction:function error:&pipelineError] : nil;
    if (!_queue || !_pipeline) {
        if (error) *error = pipelineError ?: SPAirFusedError(2, @"Fused NV12 Lanczos kernel is unavailable");
        return nil;
    }
    CVReturn status = CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, device, NULL, &_textureCache);
    if (status != kCVReturnSuccess) {
        if (error) *error = SPAirFusedError(status, @"Cannot create fused input texture cache");
        return nil;
    }
    NSDictionary *pool = @{(__bridge NSString *)kCVPixelBufferPoolMinimumBufferCountKey: @2};
    NSDictionary *attributes = @{
        (__bridge NSString *)kCVPixelBufferWidthKey: @(outputWidth),
        (__bridge NSString *)kCVPixelBufferHeightKey: @(outputHeight),
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    status = CVPixelBufferPoolCreate(kCFAllocatorDefault, (__bridge CFDictionaryRef)pool,
                                    (__bridge CFDictionaryRef)attributes, &_outputPool);
    if (status != kCVReturnSuccess) {
        if (error) *error = SPAirFusedError(status, @"Cannot create fused BGRA output pool");
        return nil;
    }
    return self;
}

- (void)dealloc {
    if (_textureCache) CFRelease(_textureCache);
    if (_outputPool) CFRelease(_outputPool);
}

- (CVPixelBufferRef)processNV12Buffer:(CVPixelBufferRef)source error:(NSError **)error {
    if (CVPixelBufferGetPixelFormatType(source) != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        CVPixelBufferGetWidth(source) != (size_t)_sourceWidth ||
        CVPixelBufferGetHeight(source) != (size_t)_sourceHeight ||
        CVPixelBufferGetPlaneCount(source) != 2) {
        if (error) *error = SPAirFusedError(3, @"Fused input must match the prepared video-range NV12 dimensions");
        return NULL;
    }
    id matrix = CFBridgingRelease(CVBufferCopyAttachment(source, kCVImageBufferYCbCrMatrixKey, NULL));
    id primaries = CFBridgingRelease(CVBufferCopyAttachment(source, kCVImageBufferColorPrimariesKey, NULL));
    id transfer = CFBridgingRelease(CVBufferCopyAttachment(source, kCVImageBufferTransferFunctionKey, NULL));
    if (![matrix isEqual:(__bridge id)kCVImageBufferYCbCrMatrix_ITU_R_709_2] ||
        (primaries && ![primaries isEqual:(__bridge id)kCVImageBufferColorPrimaries_ITU_R_709_2]) ||
        (transfer && ![transfer isEqual:(__bridge id)kCVImageBufferTransferFunction_ITU_R_709_2])) {
        if (error) *error = SPAirFusedError(4, @"Fused input requires BT.709 SDR color attachments");
        return NULL;
    }

    // Offsets map a full-resolution luma index to normalized chroma texture
    // coordinates. The offline VT-reference fixtures use top-left centers for
    // untagged input. Tagged buffers use their declared sampling positions.
    vector_float2 chromaOffset = {1.0f, 1.0f};
    id chroma = CFBridgingRelease(CVBufferCopyAttachment(source, kCVImageBufferChromaLocationTopFieldKey, NULL));
    if (chroma) {
        if ([chroma isEqual:(__bridge id)kCVImageBufferChromaLocation_Left]) chromaOffset = (vector_float2){1.0f, 0.5f};
        else if ([chroma isEqual:(__bridge id)kCVImageBufferChromaLocation_Center]) chromaOffset = (vector_float2){0.5f, 0.5f};
        else if ([chroma isEqual:(__bridge id)kCVImageBufferChromaLocation_TopLeft]) chromaOffset = (vector_float2){1.0f, 1.0f};
        else if ([chroma isEqual:(__bridge id)kCVImageBufferChromaLocation_Top]) chromaOffset = (vector_float2){0.5f, 1.0f};
        else if ([chroma isEqual:(__bridge id)kCVImageBufferChromaLocation_BottomLeft]) chromaOffset = (vector_float2){1.0f, 0.0f};
        else if ([chroma isEqual:(__bridge id)kCVImageBufferChromaLocation_Bottom]) chromaOffset = (vector_float2){0.5f, 0.0f};
        else {
            if (error) *error = SPAirFusedError(5, @"Unsupported NV12 chroma siting in fused diagnostic");
            return NULL;
        }
    }
    id fields = CFBridgingRelease(CVBufferCopyAttachment(source, kCVImageBufferFieldCountKey, NULL));
    if (fields && [fields integerValue] != 1) {
        if (error) *error = SPAirFusedError(6, @"Fused diagnostic requires progressive NV12");
        return NULL;
    }

    CVPixelBufferRef output = NULL;
    NSDictionary *limit = @{(__bridge NSString *)kCVPixelBufferPoolAllocationThresholdKey: @4};
    CVReturn status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
        kCFAllocatorDefault, _outputPool, (__bridge CFDictionaryRef)limit, &output);
    if (status != kCVReturnSuccess) {
        if (error) *error = SPAirFusedError(status, @"Fused BGRA output pool is unavailable");
        return NULL;
    }
    CVMetalTextureRef yRef = NULL, uvRef = NULL, outputRef = NULL;
    NSDictionary *read = @{(__bridge NSString *)kCVMetalTextureUsage: @(MTLTextureUsageShaderRead)};
    NSDictionary *write = @{(__bridge NSString *)kCVMetalTextureUsage: @(MTLTextureUsageShaderWrite)};
    status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _textureCache, source,
        (__bridge CFDictionaryRef)read, MTLPixelFormatR8Unorm, _sourceWidth, _sourceHeight, 0, &yRef);
    if (status == kCVReturnSuccess) {
        status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _textureCache, source,
            (__bridge CFDictionaryRef)read, MTLPixelFormatRG8Unorm, _sourceWidth / 2, _sourceHeight / 2, 1, &uvRef);
    }
    if (status == kCVReturnSuccess) {
        status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _textureCache, output,
            (__bridge CFDictionaryRef)write, MTLPixelFormatBGRA8Unorm, _outputWidth, _outputHeight, 0, &outputRef);
    }
    if (status != kCVReturnSuccess || !yRef || !uvRef || !outputRef) {
        if (yRef) CFRelease(yRef);
        if (uvRef) CFRelease(uvRef);
        if (outputRef) CFRelease(outputRef);
        CVPixelBufferRelease(output);
        if (error) *error = SPAirFusedError(status, @"Cannot map fused NV12 and BGRA textures");
        return NULL;
    }
    id<MTLCommandBuffer> command = [_queue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
    if (encoder) {
        [encoder setComputePipelineState:_pipeline];
        [encoder setTexture:CVMetalTextureGetTexture(yRef) atIndex:0];
        [encoder setTexture:CVMetalTextureGetTexture(uvRef) atIndex:1];
        [encoder setTexture:CVMetalTextureGetTexture(outputRef) atIndex:2];
        [encoder setBytes:&chromaOffset length:sizeof(chromaOffset) atIndex:0];
        NSUInteger width = _pipeline.threadExecutionWidth;
        NSUInteger height = MIN((NSUInteger)4, MAX((NSUInteger)1, _pipeline.maxTotalThreadsPerThreadgroup / width));
        [encoder dispatchThreads:MTLSizeMake(_outputWidth, _outputHeight, 1)
          threadsPerThreadgroup:MTLSizeMake(width, height, 1)];
        [encoder endEncoding];
        [command commit];
        [command waitUntilCompleted];
    }
    CFRelease(yRef); CFRelease(uvRef); CFRelease(outputRef);
    if (!encoder || command.status != MTLCommandBufferStatusCompleted) {
        CVPixelBufferRelease(output);
        if (error) *error = command.error ?: SPAirFusedError(7, @"Fused NV12 Lanczos command failed");
        return NULL;
    }
    CVBufferPropagateAttachments(source, output);
    return output;
}
@end
