#import "SPAppleLowLatencySR.h"
#import "SPFileColorTransfer.h"
#import <VideoToolbox/VideoToolbox.h>
#import <VideoToolbox/VTFrameProcessor_LowLatencySuperResolutionScaler.h>
#import <cmath>

static NSError *SPSRError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"app.openduckframe.apple-low-sr" code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

static CVPixelBufferRef SPSRCreate(size_t width, size_t height, OSType format, NSDictionary *required) {
    NSDictionary *local = @{
        (id)kCVPixelBufferWidthKey: @(width), (id)kCVPixelBufferHeightKey: @(height),
        (id)kCVPixelBufferPixelFormatTypeKey: @(format), (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    CFDictionaryRef resolved = NULL;
    NSArray *list = required ? @[required, local] : @[local];
    if (CVPixelBufferCreateResolvedAttributesDictionary(kCFAllocatorDefault, (__bridge CFArrayRef)list, &resolved) != kCVReturnSuccess || !resolved) return NULL;
    CVPixelBufferRef result = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, resolved, &result);
    if (resolved) CFRelease(resolved);
    return status == kCVReturnSuccess ? result : NULL;
}

static OSType SPSRFormat(NSDictionary *attributes, NSArray<NSNumber *> *supported) {
    id declared = attributes[(id)kCVPixelBufferPixelFormatTypeKey];
    NSArray *formats = [declared isKindOfClass:NSNumber.class] ? @[declared] : ([declared isKindOfClass:NSArray.class] ? declared : supported);
    for (NSNumber *number in formats) {
        OSType value = (OSType)number.unsignedIntValue;
        if (value == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || value == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || value == kCVPixelFormatType_32BGRA) return value;
    }
    return 0;
}

static BOOL SPSRISSDR8(CVPixelBufferRef source) {
    OSType format = CVPixelBufferGetPixelFormatType(source);
    if (format != kCVPixelFormatType_32BGRA && format != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
        format != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) return NO;
    CFTypeRef transfer = CVBufferCopyAttachment(source, kCVImageBufferTransferFunctionKey, NULL);
    BOOL hdr = transfer && (CFEqual(transfer, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) ||
                            CFEqual(transfer, kCVImageBufferTransferFunction_ITU_R_2100_HLG));
    if (transfer) CFRelease(transfer);
    return !hdr;
}

static void SPSREndProcessor(id processor) {
    if (@available(macOS 15.4, *)) [(VTFrameProcessor *)processor endSession];
}

@implementation SPAppleLowLatencySR {
    dispatch_queue_t _queue;
    id _processor;
    NSDictionary *_sourceAttributes, *_destinationAttributes;
    VTPixelTransferSessionRef _transfer;
    OSType _sourceFormat, _destinationFormat;
    int _width, _height, _outWidth, _outHeight;
    uint64_t _epoch;
    BOOL _inflight;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _queue = dispatch_queue_create("app.openduckframe.apple-low-sr", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (void)dealloc { if (_transfer) CFRelease(_transfer); }

+ (BOOL)isSupported {
    if (@available(macOS 26.0, *)) return VTLowLatencySuperResolutionScalerConfiguration.isSupported;
    return NO;
}

+ (NSArray<NSNumber *> *)supportedFactorsForWidth:(int)width height:(int)height {
    if (width < 2 || height < 2) return @[];
    if (@available(macOS 26.0, *)) {
        if (!VTLowLatencySuperResolutionScalerConfiguration.isSupported) return @[];
        return [VTLowLatencySuperResolutionScalerConfiguration supportedScaleFactorsForFrameWidth:width frameHeight:height] ?: @[];
    }
    return @[];
}

+ (NSSize)inputSizeForWidth:(int)width height:(int)height preset:(int)preset {
    if (width < 4 || height < 4) return NSZeroSize;
    double ratio = 1.0;
    if (preset == 480 || preset == 720 || preset == 1080) {
        int maxWidth = preset == 480 ? 854 : (preset == 720 ? 1280 : 1920);
        ratio = MIN(1.0, MIN((double)maxWidth / width, (double)preset / height));
    }
    return NSMakeSize(MAX(4, ((int)(width * ratio)) & ~3), MAX(4, ((int)(height * ratio)) & ~3));
}

+ (NSSize)automaticOutputForWidth:(int)width height:(int)height {
    NSArray<NSNumber *> *factors = [[self supportedFactorsForWidth:width height:height]
        sortedArrayUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) { return [b compare:a]; }];
    for (NSNumber *number in factors) {
        double factor = number.doubleValue, w = width * factor, h = height * factor;
        int outW = (int)llround(w), outH = (int)llround(h);
        if (factor > 1 && fabs(w - outW) < 0.0001 && fabs(h - outH) < 0.0001 &&
            outW <= 3840 && outH <= 2160 && !(outW & 1) && !(outH & 1)) return NSMakeSize(outW, outH);
    }
    return NSZeroSize;
}

- (BOOL)prepareWidth:(int)width height:(int)height scale:(float)scale error:(NSError **)error {
    __block uint64_t prepareEpoch;
    @synchronized (self) {
        if (_processor || _inflight) { if (error) *error = SPSRError(1, @"超分会话仍在运行，请等待结束。 "); return NO; }
        prepareEpoch = _epoch;
    }
    if (!std::isfinite(scale) || scale <= 1.f || width < 2 || height < 2) {
        if (error) *error = SPSRError(2, @"来源尺寸或倍率无效。 "); return NO;
    }
    BOOL supported = NO;
    for (NSNumber *factor in [self.class supportedFactorsForWidth:width height:height]) {
        if (fabsf(factor.floatValue - scale) < 0.0001f) { supported = YES; break; }
    }
    double outWidth = width * (double)scale, outHeight = height * (double)scale;
    if (!supported || fabs(outWidth - round(outWidth)) > 0.0001 || fabs(outHeight - round(outHeight)) > 0.0001 ||
        outWidth > 3840 || outHeight > 2160) {
        if (error) *error = SPSRError(3, @"该来源尺寸不支持所选超分倍率，或输出超过当前预算。 "); return NO;
    }
    if (@available(macOS 26.0, *)) {
        if (@available(macOS 27.0, *)) {
            NSInteger maxDim = [VTLowLatencySuperResolutionScalerConfiguration maximumDimensionForSpatialScaleFactor:scale];
            NSInteger maxPixels = [VTLowLatencySuperResolutionScalerConfiguration maximumPixelCountForSpatialScaleFactor:scale];
            if (maxDim <= 0 || maxPixels <= 0 || width > maxDim || height > maxDim || (int64_t)width * height > maxPixels) {
                if (error) *error = SPSRError(4, @"所选尺寸超出这台 Mac 的低延迟超分限制。 "); return NO;
            }
        }
        VTLowLatencySuperResolutionScalerConfiguration *config = [[VTLowLatencySuperResolutionScalerConfiguration alloc]
            initWithFrameWidth:width frameHeight:height scaleFactor:scale];
        if (!config) { if (error) *error = SPSRError(5, @"无法创建低延迟超分配置。 "); return NO; }
        OSType sourceFormat = SPSRFormat(config.sourcePixelBufferAttributes, config.frameSupportedPixelFormats);
        OSType destFormat = SPSRFormat(config.destinationPixelBufferAttributes, config.frameSupportedPixelFormats);
        if (!sourceFormat || !destFormat) { if (error) *error = SPSRError(6, @"低延迟超分没有可用画面格式。 "); return NO; }
        VTFrameProcessor *processor = [[VTFrameProcessor alloc] init];
        NSError *local = nil;
        if (![processor startSessionWithConfiguration:config error:&local]) {
            if (error) *error = local ?: SPSRError(7, @"低延迟超分模型准备失败。 "); return NO;
        }
        @synchronized (self) {
            if (_processor || _inflight || _epoch != prepareEpoch) { SPSREndProcessor(processor); if (error) *error = SPSRError(1, @"超分会话状态已改变。 "); return NO; }
            _processor = processor;
            _sourceAttributes = [config.sourcePixelBufferAttributes copy];
            _destinationAttributes = [config.destinationPixelBufferAttributes copy];
            _sourceFormat = sourceFormat; _destinationFormat = destFormat;
            _width = width; _height = height; _outWidth = (int)round(outWidth); _outHeight = (int)round(outHeight);
            ++_epoch;
        }
        return YES;
    }
    if (error) *error = SPSRError(8, @"低延迟超分需要 macOS 26 或更高版本。 ");
    return NO;
}

- (BOOL)submitSource:(CVPixelBufferRef)source pts:(CMTime)pts token:(uint64_t)token completion:(SPFRCEngineCompletion)completion {
    if (!source || !completion || !CMTIME_IS_NUMERIC(pts) || !SPSRISSDR8(source)) return NO;
    __block id processor = nil;
    __block uint64_t seen = 0;
    @synchronized (self) {
        if (!_processor || _inflight || (!self.allowsInputResize &&
            (CVPixelBufferGetWidth(source) != (size_t)_width || CVPixelBufferGetHeight(source) != (size_t)_height))) return NO;
        _inflight = YES; processor = _processor; seen = _epoch;
    }
    CVPixelBufferRetain(source);
    dispatch_async(_queue, ^{
        CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
        void (^finish)(CVPixelBufferRef, NSError *) = ^(CVPixelBufferRef output, NSError *local) {
            BOOL stale;
            @synchronized (self) { stale = seen != self->_epoch; self->_inflight = NO; }
            if (stale && output) { CVPixelBufferRelease(output); output = NULL; }
            CVPixelBufferRelease(source);
            if (stale) { SPSREndProcessor(processor); local = SPSRError(9, @"超分结果属于已结束的会话。 "); }
            completion(token, output, MAX(0, CFAbsoluteTimeGetCurrent() - started), local);
        };
        BOOL invalidated;
        @synchronized (self) { invalidated = seen != self->_epoch; }
        if (invalidated) { finish(NULL, nil); return; }
        CVPixelBufferRef adapted = SPSRCreate(self->_width, self->_height, self->_sourceFormat, self->_sourceAttributes);
        if (!self->_transfer) VTPixelTransferSessionCreate(kCFAllocatorDefault, &self->_transfer);
        CFTypeRef sourceMatrix = CVBufferCopyAttachment(source, kCVImageBufferYCbCrMatrixKey, NULL);
        BOOL outputIsYUV = self->_sourceFormat != kCVPixelFormatType_32BGRA;
        BOOL configured = self->_transfer && SPConfigureFileColorTransfer(self->_transfer, source, outputIsYUV && sourceMatrix != NULL);
        if (sourceMatrix) CFRelease(sourceMatrix);
        if (!adapted || !configured || VTPixelTransferSessionTransferImage(self->_transfer, source, adapted) != noErr) {
            if (adapted) CVPixelBufferRelease(adapted);
            finish(NULL, SPSRError(10, @"低延迟超分输入格式转换失败。 ")); return;
        }
        CVBufferPropagateAttachments(source, adapted);
        if (self.allowsInputResize) {
            CVBufferRemoveAttachment(adapted, kCVImageBufferCleanApertureKey);
            CVBufferRemoveAttachment(adapted, kCVImageBufferPreferredCleanApertureKey);
            CVBufferRemoveAttachment(adapted, kCVImageBufferDisplayDimensionsKey);
        }
        CVPixelBufferRef output = SPSRCreate(self->_outWidth, self->_outHeight, self->_destinationFormat, self->_destinationAttributes);
        if (!output) { CVPixelBufferRelease(adapted); finish(NULL, SPSRError(11, @"无法分配超分输出缓冲。 ")); return; }
        CVBufferPropagateAttachments(source, output);
        if (@available(macOS 26.0, *)) {
            VTFrameProcessorFrame *inputFrame = [[VTFrameProcessorFrame alloc] initWithBuffer:adapted presentationTimeStamp:pts];
            VTFrameProcessorFrame *outputFrame = [[VTFrameProcessorFrame alloc] initWithBuffer:output presentationTimeStamp:pts];
            VTLowLatencySuperResolutionScalerParameters *parameters = inputFrame && outputFrame
                ? [[VTLowLatencySuperResolutionScalerParameters alloc] initWithSourceFrame:inputFrame destinationFrame:outputFrame] : nil;
            if (!parameters) { CVPixelBufferRelease(adapted); CVPixelBufferRelease(output); finish(NULL, SPSRError(12, @"超分参数创建失败。 ")); return; }
            [(VTFrameProcessor *)processor processWithParameters:parameters completionHandler:^(id<VTFrameProcessorParameters> result, NSError *local) {
                (void)result;
                dispatch_async(self->_queue, ^{
                    CVPixelBufferRelease(adapted);
                    if (local) { CVPixelBufferRelease(output); finish(NULL, local); }
                    else finish(output, nil);
                });
            }];
            return;
        }
        CVPixelBufferRelease(adapted); CVPixelBufferRelease(output); finish(NULL, SPSRError(8, @"低延迟超分需要 macOS 26。 "));
    });
    return YES;
}

- (void)invalidate {
    id retired = nil;
    BOOL active;
    @synchronized (self) { ++_epoch; retired = _processor; _processor = nil; active = _inflight; }
    if (retired && !active) dispatch_async(_queue, ^{ SPSREndProcessor(retired); });
    // An active job owns the retired processor and closes it after its callback.
}
@end
