#import "SPArtCNNSR.h"
#import "SPFileLanczosScaler.h"
#import <CoreML/CoreML.h>
#import <Metal/Metal.h>
#import <VideoToolbox/VideoToolbox.h>
#include <algorithm>
#include <cmath>

static NSError *SPArtError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"app.openduckframe.artcnn" code:code
                          userInfo:@{NSLocalizedDescriptionKey:message}];
}

static NSURL *SPArtModelURL(NSBundle *bundle, int features) {
    NSString *name=[NSString stringWithFormat:@"ArtCNN_C4F%d",features];
    for (NSString *folder in @[@"",@"Models",@"Models/ArtCNN"]) {
        NSURL *url=[bundle URLForResource:name withExtension:@"mlmodelc" subdirectory:folder];
        if (url) return url;
    }
    return nil;
}

@implementation SPArtCNNSR {
    NSBundle *_resourceBundle;
    dispatch_queue_t _queue;
    MLModel *_model;
    MLMultiArray *_input;
    MLDictionaryFeatureProvider *_provider;
    SPFileLanczosScaler *_chromaScaler;
    VTPixelTransferSessionRef _transfer;
    int _width, _height, _features;
    BOOL _running, _inflight;
    uint64_t _epoch;
}

- (instancetype)init { return [self initWithResourceBundle:NSBundle.mainBundle]; }
- (instancetype)initWithResourceBundle:(NSBundle *)bundle {
    if (!(self=[super init])) return nil;
    _resourceBundle=bundle;
    _queue=dispatch_queue_create("app.openduckframe.artcnn",DISPATCH_QUEUE_SERIAL);
    return self;
}
+ (BOOL)isPackagedForThisSystem {
    return SPArtModelURL(NSBundle.mainBundle,16) && SPArtModelURL(NSBundle.mainBundle,32);
}
- (void)closeOnQueue {
    _model=nil; _input=nil; _provider=nil; _chromaScaler=nil;
    if (_transfer) { CFRelease(_transfer); _transfer=NULL; }
}
- (void)dealloc { if (_transfer) CFRelease(_transfer); }

- (BOOL)prepareWidth:(int)width height:(int)height features:(int)features error:(NSError **)error {
    if (width<2 || height<2 || width>1920 || height>1080 || (width&1) || (height&1) ||
        (features!=16 && features!=32)) {
        if (error) *error=SPArtError(1,@"ArtCNN requires even SDR input up to 1920x1080 (native 2x output).");
        return NO;
    }
    __block BOOL ok=NO;
    __block NSError *failure=nil;
    dispatch_sync(_queue,^{
        @synchronized(self) {
            if (self->_running || self->_inflight) { failure=SPArtError(2,@"The ArtCNN session is still active."); return; }
        }
        NSURL *url=SPArtModelURL(self->_resourceBundle,features);
        if (!url) { failure=SPArtError(3,@"The bundled ArtCNN model is missing."); return; }
        MLModelConfiguration *config=[MLModelConfiguration new];
        config.computeUnits=MLComputeUnitsAll;
        if (@available(macOS 14.4,*)) {
            MLOptimizationHints *hints=[MLOptimizationHints new];
            hints.reshapeFrequency=MLReshapeFrequencyHintInfrequent;
            config.optimizationHints=hints;
        }
        self->_model=[MLModel modelWithContentsOfURL:url configuration:config error:&failure];
        self->_input=[[MLMultiArray alloc] initWithShape:@[@1,@1,@(height),@(width)] dataType:MLMultiArrayDataTypeFloat16 error:&failure];
        MLFeatureValue *feature=self->_input ? [MLFeatureValue featureValueWithMultiArray:self->_input] : nil;
        if (!self->_model || !feature || ![self->_model.modelDescription.inputDescriptionsByName[@"input"] isAllowedValue:feature]) {
            if (!failure) failure=SPArtError(4,@"The input dimensions do not match the ArtCNN model.");
            [self closeOnQueue]; return;
        }
        self->_provider=[[MLDictionaryFeatureProvider alloc] initWithDictionary:@{@"input":feature} error:&failure];
        self->_chromaScaler=[[SPFileLanczosScaler alloc] initWithDevice:MTLCreateSystemDefaultDevice() width:width*2 height:height*2 error:&failure];
        if (!self->_provider || !self->_chromaScaler) { [self closeOnQueue]; return; }
        // Compile/specialize the actual shape before accepting source frames.
        [self->_input getMutableBytesWithHandler:^(void *bytes, NSInteger size, NSArray<NSNumber *> *strides) {
            (void)strides; memset(bytes,0,(size_t)size);
        }];
        id<MLFeatureProvider> warm=[self->_model predictionFromFeatures:self->_provider error:&failure];
        MLMultiArray *result=[warm featureValueForName:@"output"].multiArrayValue;
        if (!result || ![result.shape isEqual:@[@1,@1,@(height*2),@(width*2)]]) {
            if (!failure) failure=SPArtError(5,@"ArtCNN did not produce the expected native 2x frame.");
            [self closeOnQueue]; return;
        }
        [result getBytesWithHandler:^(const void *bytes, NSInteger size) {
            (void)size; volatile uint8_t value=((const uint8_t *)bytes)[0]; (void)value;
        }];
        self->_width=width; self->_height=height; self->_features=features;
        @synchronized(self) { self->_running=YES; ++self->_epoch; }
        NSLog(@"ArtCNN C4F%d ready: %dx%d -> %dx%d, original weights, CoreML all permitted devices",features,width,height,width*2,height*2);
        ok=YES;
    });
    if (!ok && error) *error=failure;
    return ok;
}

- (CVPixelBufferRef)adaptSource:(CVPixelBufferRef)source error:(NSError **)error CF_RETURNS_RETAINED {
    OSType format=CVPixelBufferGetPixelFormatType(source);
    if (format==kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format==kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        return CVPixelBufferRetain(source);
    if (format!=kCVPixelFormatType_32BGRA) { *error=SPArtError(6,@"ArtCNN supports SDR 8-bit NV12 or BGRA frames."); return NULL; }
    if (!_transfer && VTPixelTransferSessionCreate(kCFAllocatorDefault,&_transfer)!=noErr) {
        *error=SPArtError(7,@"Cannot prepare the ArtCNN input color conversion."); return NULL;
    }
    NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};
    CVPixelBufferRef nv12=NULL;
    CVPixelBufferCreate(NULL,_width,_height,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,(__bridge CFDictionaryRef)attrs,&nv12);
    CFTypeRef primaries=CVBufferCopyAttachment(source,kCVImageBufferColorPrimariesKey,NULL);
    CFTypeRef transfer=CVBufferCopyAttachment(source,kCVImageBufferTransferFunctionKey,NULL);
    BOOL configured=VTSessionSetProperty(_transfer,kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,kCVImageBufferYCbCrMatrix_ITU_R_709_2)==noErr &&
        VTSessionSetProperty(_transfer,kVTPixelTransferPropertyKey_DestinationColorPrimaries,primaries)==noErr &&
        VTSessionSetProperty(_transfer,kVTPixelTransferPropertyKey_DestinationTransferFunction,transfer)==noErr;
    if (primaries) CFRelease(primaries); if (transfer) CFRelease(transfer);
    if (!nv12 || !configured || VTPixelTransferSessionTransferImage(_transfer,source,nv12)!=noErr) {
        if (nv12) CVPixelBufferRelease(nv12);
        *error=SPArtError(8,@"ArtCNN input color conversion failed."); return NULL;
    }
    CVBufferPropagateAttachments(source,nv12);
    CVBufferSetAttachment(nv12,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    return nv12;
}

- (BOOL)processLuma:(CVPixelBufferRef)source output:(CVPixelBufferRef)output error:(NSError **)error {
    BOOL full=CVPixelBufferGetPixelFormatType(source)==kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    float offset=full?0.f:16.f, scale=full?255.f:219.f;
    if (CVPixelBufferLockBaseAddress(source,kCVPixelBufferLock_ReadOnly)!=kCVReturnSuccess) {
        *error=SPArtError(9,@"Cannot read the ArtCNN input frame."); return NO;
    }
    const uint8_t *luma=(const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(source,0);
    size_t pitch=CVPixelBufferGetBytesPerRowOfPlane(source,0);
    [_input getMutableBytesWithHandler:^(void *bytes, NSInteger size, NSArray<NSNumber *> *strides) {
        (void)size; __fp16 *tensor=(__fp16 *)bytes;
        size_t row=strides[2].unsignedLongLongValue, col=strides[3].unsignedLongLongValue;
        for (int y=0;y<self->_height;y++) for (int x=0;x<self->_width;x++)
            tensor[y*row+x*col]=(__fp16)std::clamp((luma[y*pitch+x]-offset)/scale,0.f,1.f);
    }];
    CVPixelBufferUnlockBaseAddress(source,kCVPixelBufferLock_ReadOnly);
    id<MLFeatureProvider> prediction=[_model predictionFromFeatures:_provider error:error];
    MLMultiArray *result=[prediction featureValueForName:@"output"].multiArrayValue;
    if (!result || ![result.shape isEqual:@[@1,@1,@(_height*2),@(_width*2)]] ||
        (result.dataType!=MLMultiArrayDataTypeFloat16 && result.dataType!=MLMultiArrayDataTypeFloat32)) {
        if (!*error) *error=SPArtError(10,@"ArtCNN returned an invalid output tensor."); return NO;
    }
    if (CVPixelBufferLockBaseAddress(output,0)!=kCVReturnSuccess) {
        *error=SPArtError(11,@"Cannot write the ArtCNN output frame."); return NO;
    }
    uint8_t *dest=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(output,0);
    size_t outPitch=CVPixelBufferGetBytesPerRowOfPlane(output,0);
    __block BOOL finite=YES;
    [result getBytesWithHandler:^(const void *bytes, NSInteger size) {
        (void)size; NSArray<NSNumber *> *strides=result.strides;
        size_t row=strides[2].unsignedLongLongValue, col=strides[3].unsignedLongLongValue;
        BOOL half=result.dataType==MLMultiArrayDataTypeFloat16;
        for (int y=0;y<self->_height*2;y++) for (int x=0;x<self->_width*2;x++) {
            size_t i=y*row+x*col;
            float v=half?(float)((const __fp16 *)bytes)[i]:((const float *)bytes)[i];
            if (!std::isfinite(v)) { finite=NO; v=0; }
            dest[y*outPitch+x]=(uint8_t)std::lround(std::clamp(v,0.f,1.f)*scale+offset);
        }
    }];
    CVPixelBufferUnlockBaseAddress(output,0);
    if (!finite) *error=SPArtError(12,@"ArtCNN produced non-finite pixels.");
    return finite;
}

- (BOOL)submitSource:(CVPixelBufferRef)source pts:(CMTime)pts token:(uint64_t)token completion:(SPFRCEngineCompletion)completion {
    if (!source || !completion || !CMTIME_IS_NUMERIC(pts)) return NO;
    __block uint64_t seen;
    @synchronized(self) {
        if (!_running || _inflight || CVPixelBufferGetWidth(source)!=(size_t)_width || CVPixelBufferGetHeight(source)!=(size_t)_height) return NO;
        _inflight=YES; seen=_epoch;
    }
    CVPixelBufferRetain(source);
    dispatch_async(_queue,^{
        CFAbsoluteTime start=CFAbsoluteTimeGetCurrent();
        void (^finish)(CVPixelBufferRef,NSError *)=^(CVPixelBufferRef result,NSError *failure) {
            BOOL stale;
            @synchronized(self) { stale=seen!=self->_epoch; self->_inflight=NO; }
            if (stale) {
                if (result) CVPixelBufferRelease(result);
                result=NULL; failure=SPArtError(13,@"The ArtCNN session has ended."); [self closeOnQueue];
            }
            CVPixelBufferRelease(source);
            completion(token,result,MAX(0,CFAbsoluteTimeGetCurrent()-start),failure);
        };
        BOOL stale; @synchronized(self) { stale=seen!=self->_epoch; }
        if (stale) { finish(NULL,nil); return; }
        CFTypeRef transfer=CVBufferCopyAttachment(source,kCVImageBufferTransferFunctionKey,NULL);
        BOOL hdr=transfer && (CFEqual(transfer,kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) || CFEqual(transfer,kCVImageBufferTransferFunction_ITU_R_2100_HLG));
        if (transfer) CFRelease(transfer);
        CGRect whole=CGRectMake(0,0,self->_width,self->_height);
        if (hdr || !CGRectEqualToRect(CVImageBufferGetCleanRect(source),whole)) {
            finish(NULL,SPArtError(14,@"ArtCNN requires a complete SDR frame without a clean-aperture crop.")); return;
        }
        NSError *failure=nil;
        CVPixelBufferRef adapted=[self adaptSource:source error:&failure];
        if (!adapted) { finish(NULL,failure); return; }
        BOOL accepted=[self->_chromaScaler submit:adapted ptsUs:CMTimeConvertScale(pts,1000000,kCMTimeRoundingMethod_Default).value completion:^(CVPixelBufferRef output,NSError *scaleError) {
            dispatch_async(self->_queue,^{
                NSError *local=scaleError;
                CVPixelBufferRef result=output;
                if (result && !local && ![self processLuma:adapted output:result error:&local]) {
                    CVPixelBufferRelease(result); result=NULL;
                }
                CVPixelBufferRelease(adapted);
                finish(result,local);
            });
        }];
        if (!accepted) { CVPixelBufferRelease(adapted); finish(NULL,SPArtError(15,@"ArtCNN chroma scaling is busy.")); }
    });
    return YES;
}
- (void)invalidate {
    BOOL active;
    @synchronized(self) { ++_epoch; _running=NO; active=_inflight; }
    if (!active) dispatch_async(_queue,^{ [self closeOnQueue]; });
}
@end
