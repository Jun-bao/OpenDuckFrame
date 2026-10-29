#import "SPFileMetalFXScaler.h"
#import "SPFileColorTransfer.h"
#import <MetalFX/MetalFX.h>
#import <VideoToolbox/VideoToolbox.h>
#include <atomic>

static NSError *SPFileMetalFXError(NSInteger code,NSString *message){return [NSError errorWithDomain:@"Khua.FileMetalFX" code:code userInfo:@{NSLocalizedDescriptionKey:message}];}
@implementation SPFileMetalFXScaler {
    id<MTLDevice> _device; id<MTLCommandQueue> _commands; id<MTLFXSpatialScaler> _scaler;
    id<MTLTexture> _inputPrivate,_outputPrivate;
    CVMetalTextureCacheRef _cache; VTPixelTransferSessionRef _toRGB,_toNV12;
    dispatch_queue_t _queue;std::atomic<bool> _busy;int _inputWidth,_inputHeight,_outputWidth,_outputHeight;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device sourceWidth:(int)sourceWidth sourceHeight:(int)sourceHeight outputWidth:(int)outputWidth outputHeight:(int)outputHeight error:(NSError **)error {
    if(!(self=[super init]))return nil;_busy.store(false);
    if(!device||![MTLFXSpatialScalerDescriptor supportsDevice:device]||sourceWidth<2||sourceHeight<2||outputWidth<2||outputHeight<2||outputWidth>3840||outputHeight>2160||(sourceWidth&1)||(sourceHeight&1)||(outputWidth&1)||(outputHeight&1)){
        if(error)*error=SPFileMetalFXError(1,@"设备不支持 MetalFX 或文件输出尺寸无效。");return nil;
    }
    _device=device;_inputWidth=sourceWidth;_inputHeight=sourceHeight;_outputWidth=outputWidth;_outputHeight=outputHeight;
    _commands=[device newCommandQueue];_queue=dispatch_queue_create("app.khuaplayer.file-metalfx",DISPATCH_QUEUE_SERIAL);
    MTLFXSpatialScalerDescriptor *d=[MTLFXSpatialScalerDescriptor new];d.inputWidth=sourceWidth;d.inputHeight=sourceHeight;d.outputWidth=outputWidth;d.outputHeight=outputHeight;
    d.colorTextureFormat=MTLPixelFormatBGRA8Unorm;d.outputTextureFormat=MTLPixelFormatBGRA8Unorm;d.colorProcessingMode=MTLFXSpatialScalerColorProcessingModePerceptual;
    _scaler=[d newSpatialScalerWithDevice:device];
    if(!_scaler||!_commands||CVMetalTextureCacheCreate(kCFAllocatorDefault,NULL,device,NULL,&_cache)!=kCVReturnSuccess||VTPixelTransferSessionCreate(NULL,&_toRGB)!=noErr||VTPixelTransferSessionCreate(NULL,&_toNV12)!=noErr){if(error)*error=SPFileMetalFXError(2,@"MetalFX 文件缩放准备失败。");return nil;}
    MTLTextureDescriptor *inDesc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:sourceWidth height:sourceHeight mipmapped:NO];
    inDesc.storageMode=MTLStorageModePrivate;inDesc.usage=MTLTextureUsageShaderRead|_scaler.colorTextureUsage;
    MTLTextureDescriptor *outDesc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:outputWidth height:outputHeight mipmapped:NO];
    outDesc.storageMode=MTLStorageModePrivate;outDesc.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite|_scaler.outputTextureUsage;
    _inputPrivate=[device newTextureWithDescriptor:inDesc];_outputPrivate=[device newTextureWithDescriptor:outDesc];
    if(!_inputPrivate||!_outputPrivate){if(error)*error=SPFileMetalFXError(3,@"MetalFX 纹理分配失败。");return nil;}
    return self;
}
- (void)dealloc {if(_cache)CFRelease(_cache);if(_toRGB)CFRelease(_toRGB);if(_toNV12)CFRelease(_toNV12);}
- (int)outputWidth{return _outputWidth;}
- (int)outputHeight{return _outputHeight;}
- (BOOL)submit:(CVPixelBufferRef)source completion:(void (^)(CVPixelBufferRef,NSError *))completion{return [self submit:source ptsUs:INT64_MIN completion:completion];}
- (BOOL)submit:(CVPixelBufferRef)source ptsUs:(int64_t)ptsUs completion:(void (^)(CVPixelBufferRef,NSError *))completion {
    if(!source||!completion||_busy.exchange(true))return NO;
    CVPixelBufferRetain(source);dispatch_async(_queue,^{@autoreleasepool{
        CVPixelBufferRef rgb=NULL,scaled=NULL,result=NULL;CVMetalTextureRef inRef=NULL,outRef=NULL;NSError *failure=nil;
        OSType format=CVPixelBufferGetPixelFormatType(source);CGRect clean=CVImageBufferGetCleanRect(source);
        CFTypeRef matrix=CVBufferCopyAttachment(source,kCVImageBufferYCbCrMatrixKey,NULL),pri=CVBufferCopyAttachment(source,kCVImageBufferColorPrimariesKey,NULL),trc=CVBufferCopyAttachment(source,kCVImageBufferTransferFunctionKey,NULL);
        BOOL valid=ptsUs!=INT64_MIN && CVPixelBufferGetWidth(source)==(size_t)self->_inputWidth && CVPixelBufferGetHeight(source)==(size_t)self->_inputHeight && CGRectEqualToRect(clean,CGRectMake(0,0,self->_inputWidth,self->_inputHeight)) && (format==kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange||format==kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) && matrix&&pri&&trc&&((CFEqual(matrix,kCVImageBufferYCbCrMatrix_ITU_R_601_4)&&(CFEqual(pri,kCVImageBufferColorPrimaries_SMPTE_C)||CFEqual(pri,kCVImageBufferColorPrimaries_EBU_3213)))||(CFEqual(matrix,kCVImageBufferYCbCrMatrix_ITU_R_709_2)&&CFEqual(pri,kCVImageBufferColorPrimaries_ITU_R_709_2)))&&CFEqual(trc,kCVImageBufferTransferFunction_ITU_R_709_2);
        if(matrix)CFRelease(matrix);if(pri)CFRelease(pri);if(trc)CFRelease(trc);
        NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};
        if(!valid)failure=SPFileMetalFXError(4,@"MetalFX 文件缩放当前需要完整 SDR 8 位 NV12、支持的 601/709 色彩和有效时间戳。");
        if(!failure && (VTSessionSetProperty(self->_toRGB,kVTPixelTransferPropertyKey_DestinationColorPrimaries,kCVImageBufferColorPrimaries_ITU_R_709_2)!=noErr||VTSessionSetProperty(self->_toRGB,kVTPixelTransferPropertyKey_DestinationTransferFunction,kCVImageBufferTransferFunction_ITU_R_709_2)!=noErr||!SPConfigureFileColorTransfer(self->_toNV12,source,YES)))failure=SPFileMetalFXError(5,@"MetalFX 色彩转换准备失败。");
        if(!failure && (CVPixelBufferCreate(NULL,self->_inputWidth,self->_inputHeight,kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)attrs,&rgb)!=kCVReturnSuccess||CVPixelBufferCreate(NULL,self->_outputWidth,self->_outputHeight,kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)attrs,&scaled)!=kCVReturnSuccess||CVPixelBufferCreate(NULL,self->_outputWidth,self->_outputHeight,format,(__bridge CFDictionaryRef)attrs,&result)!=kCVReturnSuccess))failure=SPFileMetalFXError(6,@"MetalFX 画面分配失败。");
        if(!failure){CVBufferSetAttachment(rgb,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);CVBufferSetAttachment(rgb,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);CVBufferSetAttachment(scaled,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);CVBufferSetAttachment(scaled,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);CVBufferPropagateAttachments(source,result);CVBufferRemoveAttachment(result,kCVImageBufferCleanApertureKey);CVBufferRemoveAttachment(result,kCVImageBufferPreferredCleanApertureKey);CVBufferRemoveAttachment(result,kCVImageBufferDisplayDimensionsKey);
            if(VTPixelTransferSessionTransferImage(self->_toRGB,source,rgb)!=noErr)failure=SPFileMetalFXError(7,@"MetalFX 输入转换失败。");}
        if(!failure && (CVMetalTextureCacheCreateTextureFromImage(NULL,self->_cache,rgb,NULL,MTLPixelFormatBGRA8Unorm,self->_inputWidth,self->_inputHeight,0,&inRef)!=kCVReturnSuccess || CVMetalTextureCacheCreateTextureFromImage(NULL,self->_cache,scaled,NULL,MTLPixelFormatBGRA8Unorm,self->_outputWidth,self->_outputHeight,0,&outRef)!=kCVReturnSuccess || !inRef || !outRef))failure=SPFileMetalFXError(8,@"MetalFX 纹理创建失败。");
        if(!failure){id<MTLCommandBuffer> command=[self->_commands commandBuffer];id<MTLBlitCommandEncoder> copy=[command blitCommandEncoder];
            if(!command||!copy)failure=SPFileMetalFXError(9,@"MetalFX 指令创建失败。");
            else {[copy copyFromTexture:CVMetalTextureGetTexture(inRef) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(self->_inputWidth,self->_inputHeight,1) toTexture:self->_inputPrivate destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];[copy endEncoding];
                self->_scaler.colorTexture=self->_inputPrivate;self->_scaler.inputContentWidth=self->_inputWidth;self->_scaler.inputContentHeight=self->_inputHeight;self->_scaler.outputTexture=self->_outputPrivate;[self->_scaler encodeToCommandBuffer:command];
                id<MTLBlitCommandEncoder> copyOut=[command blitCommandEncoder];if(!copyOut)failure=SPFileMetalFXError(9,@"MetalFX 输出指令创建失败。");
                else {[copyOut copyFromTexture:self->_outputPrivate sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(self->_outputWidth,self->_outputHeight,1) toTexture:CVMetalTextureGetTexture(outRef) destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];[copyOut endEncoding];[command commit];[command waitUntilCompleted];if(command.status!=MTLCommandBufferStatusCompleted)failure=command.error?:SPFileMetalFXError(10,@"MetalFX GPU 处理失败。");}}
        }
        if(!failure && VTPixelTransferSessionTransferImage(self->_toNV12,scaled,result)!=noErr)failure=SPFileMetalFXError(11,@"MetalFX 输出转换失败。");
        if(inRef)CFRelease(inRef);if(outRef)CFRelease(outRef);if(rgb)CVPixelBufferRelease(rgb);if(scaled)CVPixelBufferRelease(scaled);CVPixelBufferRelease(source);self->_busy.store(false);
        if(failure&&result){CVPixelBufferRelease(result);result=NULL;}completion(result,failure);
    }});return YES;
}
@end
