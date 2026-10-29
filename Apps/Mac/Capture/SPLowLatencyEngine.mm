#import "SPLowLatencyEngine.h"

#import <VideoToolbox/VideoToolbox.h>
#import <VideoToolbox/VTFrameProcessor.h>
#import <VideoToolbox/VTFrameProcessor_LowLatencyFrameInterpolation.h>
#import <CoreMedia/CoreMedia.h>
#import <ImageIO/ImageIO.h>
#import <atomic>

static NSError *SPLLError(NSInteger code, NSString *text) {
    return [NSError errorWithDomain:@"app.khuaplayer.lowlatency" code:code userInfo:@{NSLocalizedDescriptionKey: text}];
}

static BOOL SPLLSame(int64_t n, int64_t d, int64_t tn, int64_t td) {
    if (n <= 0 || d <= 0 || tn <= 0 || td <= 0) return NO;
    return (__int128)n * td == (__int128)d * tn;
}

static void SPLLAttach709(CVPixelBufferRef buffer) {
    if (!buffer) return;
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
}

static CVPixelBufferRef SPLLCreateWithAttributes(size_t width, size_t height, OSType format, NSDictionary *required);

static CVPixelBufferRef SPLLCreate(size_t width, size_t height, OSType format) {
    return SPLLCreateWithAttributes(width, height, format, nil);
}

// The optional probe accepts fixture paths from its caller; no developer path
// is part of the application. Decode all three images to the same RGB space.
static CVPixelBufferRef SPLLReadFixture(NSString *path) {
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!source) return NULL;
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (!image) return NULL;
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    CVPixelBufferRef buffer = SPLLCreate(width, height, kCVPixelFormatType_32BGRA);
    if (!buffer) { CGImageRelease(image); return NULL; }
    CVPixelBufferLockBaseAddress(buffer, 0);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceITUR_709);
    CGContextRef context = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(buffer), width, height, 8,
        CVPixelBufferGetBytesPerRow(buffer), space, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    if (space) CGColorSpaceRelease(space);
    if (context) { CGContextDrawImage(context, CGRectMake(0, 0, width, height), image); CGContextRelease(context); }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    CGImageRelease(image);
    if (!context) { CVPixelBufferRelease(buffer); return NULL; }
    return buffer;
}

static double SPLLFixtureMAE(CVPixelBufferRef lhs, CVPixelBufferRef rhs) {
    if (!lhs || !rhs || CVPixelBufferGetPixelFormatType(lhs) != kCVPixelFormatType_32BGRA ||
        CVPixelBufferGetPixelFormatType(rhs) != kCVPixelFormatType_32BGRA ||
        CVPixelBufferGetWidth(lhs) != CVPixelBufferGetWidth(rhs) || CVPixelBufferGetHeight(lhs) != CVPixelBufferGetHeight(rhs)) return -1;
    CVPixelBufferLockBaseAddress(lhs, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(rhs, kCVPixelBufferLock_ReadOnly);
    const uint8_t *a = (const uint8_t *)CVPixelBufferGetBaseAddress(lhs);
    const uint8_t *b = (const uint8_t *)CVPixelBufferGetBaseAddress(rhs);
    size_t sa = CVPixelBufferGetBytesPerRow(lhs), sb = CVPixelBufferGetBytesPerRow(rhs);
    size_t width = CVPixelBufferGetWidth(lhs), height = CVPixelBufferGetHeight(lhs);
    double sum = 0; uint64_t count = 0;
    for (size_t y = 0; y < height; y += 2) for (size_t x = 0; x < width; x += 2) {
        for (size_t c = 0; c < 3; ++c) { sum += abs((int)a[y * sa + x * 4 + c] - (int)b[y * sb + x * 4 + c]); ++count; }
    }
    CVPixelBufferUnlockBaseAddress(rhs, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(lhs, kCVPixelBufferLock_ReadOnly);
    return count ? sum / count : -1;
}

static CVPixelBufferRef SPLLCreateWithAttributes(size_t width, size_t height, OSType format, NSDictionary *required) {
    NSMutableDictionary *ours = [@{
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
        (id)kCVPixelBufferPixelFormatTypeKey: @(format),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    } mutableCopy];
    CFDictionaryRef resolved = NULL;
    NSArray *sources = required ? @[required, ours] : @[ours];
    CVPixelBufferCreateResolvedAttributesDictionary(kCFAllocatorDefault, (__bridge CFArrayRef)sources, &resolved);
    CVPixelBufferRef buffer = NULL;
    CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, resolved ?: (__bridge CFDictionaryRef)ours, &buffer);
    if (resolved) CFRelease(resolved);
    if (result != kCVReturnSuccess) return NULL;
    SPLLAttach709(buffer);
    return buffer;
}

static OSType SPLLFormat(NSDictionary *attrs, NSArray<NSNumber *> *supported) {
    id value = attrs[(id)kCVPixelBufferPixelFormatTypeKey];
    if ([value isKindOfClass:[NSNumber class]]) return (OSType)[value unsignedIntValue];
    NSArray *listed = [value isKindOfClass:[NSArray class]] ? value : supported;
    for (NSNumber *item in listed) {
        if (item.unsignedIntValue == kCVPixelFormatType_32BGRA) return kCVPixelFormatType_32BGRA;
    }
    if (listed.count > 0) return (OSType)[listed[0] unsignedIntValue];
    return kCVPixelFormatType_32BGRA;
}

static int SPLLMaxLuma(CVPixelBufferRef buffer) {
    if (!buffer || CVPixelBufferGetPixelFormatType(buffer) != kCVPixelFormatType_32BGRA) return -1;
    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(buffer);
    int width = (int)CVPixelBufferGetWidth(buffer);
    int height = (int)CVPixelBufferGetHeight(buffer);
    size_t stride = CVPixelBufferGetBytesPerRow(buffer);
    int maxLuma = 0;
    for (int y = 0; y < height; y += 2) {
        uint8_t *row = base + (size_t)y * stride;
        for (int x = 0; x < width; x += 2) maxLuma = MAX(maxLuma, row[x * 4 + 1]);
    }
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    return maxLuma;
}

static void SPLLPaintChecker(CVPixelBufferRef buffer, int centerX) {
    CVPixelBufferLockBaseAddress(buffer, 0);
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(buffer);
    int width = (int)CVPixelBufferGetWidth(buffer);
    int height = (int)CVPixelBufferGetHeight(buffer);
    size_t stride = CVPixelBufferGetBytesPerRow(buffer);
    if (base) {
        for (int y = 0; y < height; ++y) memset(base + (size_t)y * stride, 0, stride);
        int size = 72;
        int x0 = centerX - size / 2;
        int y0 = height / 2 - size / 2;
        for (int y = 0; y < size; ++y) {
            int py = y0 + y;
            if (py < 0 || py >= height) continue;
            uint8_t *row = base + (size_t)py * stride;
            for (int x = 0; x < size; ++x) {
                int px = x0 + x;
                if (px < 0 || px >= width) continue;
                BOOL on = ((x / 6) ^ (y / 6)) & 1;
                uint8_t value = on ? 255 : 20;
                row[px * 4 + 0] = value;
                row[px * 4 + 1] = value;
                row[px * 4 + 2] = value;
                row[px * 4 + 3] = 255;
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
}

static void SPLLPaintBar(CVPixelBufferRef buffer, int x0, int x1) {
    CVPixelBufferLockBaseAddress(buffer, 0);
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(buffer);
    int width = (int)CVPixelBufferGetWidth(buffer);
    int height = (int)CVPixelBufferGetHeight(buffer);
    size_t stride = CVPixelBufferGetBytesPerRow(buffer);
    if (base && x1 > x0) {
        for (int y = 0; y < height; ++y) memset(base + (size_t)y * stride, 0, stride);
        int y0 = height * 30 / 100;
        int y1 = height * 70 / 100;
        for (int y = y0; y < y1; ++y) {
            uint8_t *row = base + (size_t)y * stride;
            for (int x = MAX(0, x0); x < MIN(width, x1); ++x) {
                row[x * 4 + 0] = 255;
                row[x * 4 + 1] = 255;
                row[x * 4 + 2] = 255;
                row[x * 4 + 3] = 255;
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
}

static double SPLLCenter(CVPixelBufferRef buffer) {
    if (CVPixelBufferGetPixelFormatType(buffer) != kCVPixelFormatType_32BGRA) return -1;
    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(buffer);
    int width = (int)CVPixelBufferGetWidth(buffer);
    int height = (int)CVPixelBufferGetHeight(buffer);
    size_t stride = CVPixelBufferGetBytesPerRow(buffer);
    double sum = 0;
    double weight = 0;
    int y0 = height * 30 / 100;
    int y1 = height * 70 / 100;
    for (int y = y0; y < y1; y += 2) {
        uint8_t *row = base + (size_t)y * stride;
        for (int x = 0; x < width; x += 2) {
            int luma = row[x * 4 + 1];
            if (luma > 12) {
                sum += (double)x * luma;
                weight += luma;
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    return weight > 0 ? sum / weight : -1;
}

@interface SPLowLatencyEngine ()
- (BOOL)submitUncheckedPrevious:(CVPixelBufferRef)previous
                        current:(CVPixelBufferRef)current
                    previousPTS:(CMTime)previousPTS
                     currentPTS:(CMTime)currentPTS
                         phases:(NSArray<NSNumber *> *)phases
                          token:(uint64_t)token
                     completion:(SPFRCPhasesCompletion)completion;
@end

@implementation SPLowLatencyEngine {
    VTFrameProcessor *_processor;
    VTLowLatencyFrameInterpolationConfiguration *_config;
    VTPixelTransferSessionRef _transfer;
    dispatch_queue_t _queue;
    NSDictionary *_sourceAttributes;
    NSDictionary *_destinationAttributes;
    OSType _sourceFormat;
    OSType _destFormat;
    NSInteger _frames;
    int _width;
    int _height;
    NSString *_modelID;
    std::atomic<uint64_t> _epoch;
}

+ (BOOL)isSupported {
    if (@available(macOS 26.0, *)) return VTLowLatencyFrameInterpolationConfiguration.isSupported;
    return NO;
}

+ (BOOL)supportsPhaseNumerator:(int64_t)numerator
                   denominator:(int64_t)denominator
                        frames:(NSInteger)frames
                      outFloat:(float *)outFloat {
    if (SPLLSame(numerator, denominator, 1, 2)) {
        if (outFloat) *outFloat = 0.5f;
        return YES;
    }
    if (frames < 2) return NO;
    if (SPLLSame(numerator, denominator, 1, 4)) {
        if (outFloat) *outFloat = 0.25f;
        return YES;
    }
    if (SPLLSame(numerator, denominator, 3, 4)) {
        if (outFloat) *outFloat = 0.75f;
        return YES;
    }
    return NO;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _epoch.store(0);
    _queue = dispatch_queue_create("app.khuaplayer.lowlatency",
                                   dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    dispatch_queue_set_specific(_queue, (__bridge const void *)self, (__bridge void *)self, NULL);
    _modelID = @"vt.llfi.temporal.1";
    return self;
}

- (void)dealloc {
    if (_transfer) CFRelease(_transfer);
}

- (NSInteger)frames { return _frames; }
- (int)width { return _width; }
- (int)height { return _height; }
- (NSString *)modelID { return _modelID; }

- (BOOL)prepareWidth:(int)width height:(int)height frames:(NSInteger)frames error:(NSError **)error {
    if (width < 2 || height < 2 || (width & 1) || (height & 1)) {
        if (error) *error = SPLLError(2, @"低延迟插帧要求偶数宽高");
        return NO;
    }
    if (frames != 1 && frames != 2) {
        if (error) *error = SPLLError(3, @"低延迟插帧只准备 1 个或 2 个插值点");
        return NO;
    }
    if (@available(macOS 26.0, *)) {
        if (!VTLowLatencyFrameInterpolationConfiguration.isSupported) {
            if (error) *error = SPLLError(1, @"这台 Mac 不支持 Apple 低延迟插帧");
            return NO;
        }
        if (@available(macOS 27.0, *)) {
            NSInteger maxDim = [VTLowLatencyFrameInterpolationConfiguration maximumDimensionForSpatialScaleFactor:1];
            NSInteger maxCount = [VTLowLatencyFrameInterpolationConfiguration maximumPixelCountForSpatialScaleFactor:1];
            if (maxDim > 0 && (width > maxDim || height > maxDim)) {
                if (error) *error = SPLLError(4, [NSString stringWithFormat:@"画面边长超过低延迟上限 %ld", (long)maxDim]);
                return NO;
            }
            if (maxCount > 0 && (NSInteger)width * (NSInteger)height > maxCount) {
                if (error) *error = SPLLError(5, @"画面像素数超过低延迟上限");
                return NO;
            }
        }
        VTLowLatencyFrameInterpolationConfiguration *config =
            [[VTLowLatencyFrameInterpolationConfiguration alloc] initWithFrameWidth:width
                                                                        frameHeight:height
                                                         numberOfInterpolatedFrames:frames];
        if (!config) {
            if (error) *error = SPLLError(6, @"低延迟配置创建失败");
            return NO;
        }
        __block VTFrameProcessor *processor = nil;
        __block NSError *local = nil;
        __block BOOL started = NO;
        void (^start)(void) = ^{
            processor = [[VTFrameProcessor alloc] init];
            started = [processor startSessionWithConfiguration:config error:&local];
        };
        if (dispatch_get_specific((__bridge const void *)self) == (__bridge void *)self) start();
        else dispatch_sync(_queue, start);
        if (!started) {
            if (error) *error = local ?: SPLLError(7, @"低延迟模型准备失败");
            return NO;
        }
        if (_processor) {
            VTFrameProcessor *previous = _processor;
            dispatch_async(_queue, ^{ [previous endSession]; });
        }
        _processor = processor;
        _config = config;
        _frames = frames;
        _width = width;
        _height = height;
        _modelID = frames >= 2 ? @"vt.llfi.temporal.2" : @"vt.llfi.temporal.1";
        _sourceAttributes = config.sourcePixelBufferAttributes;
        _destinationAttributes = config.destinationPixelBufferAttributes;
        _sourceFormat = SPLLFormat(_sourceAttributes, config.frameSupportedPixelFormats);
        _destFormat = SPLLFormat(_destinationAttributes, config.frameSupportedPixelFormats);
        return YES;
    }
    if (error) *error = SPLLError(8, @"Apple 低延迟插帧需要 macOS 26");
    return NO;
}

- (CVPixelBufferRef)adapt:(CVPixelBufferRef)source format:(OSType)format {
    if (!source) return NULL;
    if (CVPixelBufferGetPixelFormatType(source) == format &&
        (int)CVPixelBufferGetWidth(source) == _width &&
        (int)CVPixelBufferGetHeight(source) == _height &&
        CVPixelBufferGetIOSurface(source) != NULL) {
        CVPixelBufferRetain(source);
        return source;
    }
    CVPixelBufferRef destination = SPLLCreateWithAttributes((size_t)_width, (size_t)_height, format, _sourceAttributes);
    if (!destination) return NULL;
    if (!_transfer && VTPixelTransferSessionCreate(kCFAllocatorDefault, &_transfer) != noErr) {
        CVPixelBufferRelease(destination);
        return NULL;
    }
    if (VTPixelTransferSessionTransferImage(_transfer, source, destination) != noErr) {
        CVPixelBufferRelease(destination);
        return NULL;
    }
    SPLLAttach709(destination);
    return destination;
}

- (BOOL)submitPrevious:(CVPixelBufferRef)previous
               current:(CVPixelBufferRef)current
                phases:(NSArray<NSNumber *> *)phases
                 token:(uint64_t)token
            completion:(SPFRCPhasesCompletion)completion {
    return [self submitPrevious:previous current:current previousPTS:CMTimeMake(0, 30)
                     currentPTS:CMTimeMake(1, 30) phases:phases token:token completion:completion];
}

- (BOOL)submitPrevious:(CVPixelBufferRef)previous
               current:(CVPixelBufferRef)current
           previousPTS:(CMTime)previousPTS
            currentPTS:(CMTime)currentPTS
                phases:(NSArray<NSNumber *> *)phases
                 token:(uint64_t)token
            completion:(SPFRCPhasesCompletion)completion {
    if (!CMTIME_IS_NUMERIC(previousPTS) || !CMTIME_IS_NUMERIC(currentPTS) || CMTimeCompare(previousPTS, currentPTS) >= 0) return NO;
    for (NSNumber *phase in phases) {
        float value = phase.floatValue;
        BOOL known = fabsf(value - 0.5f) < 0.0001f || (_frames >= 2 && (fabsf(value - 0.25f) < 0.0001f || fabsf(value - 0.75f) < 0.0001f));
        if (!known) return NO;
    }
    return [self submitUncheckedPrevious:previous current:current previousPTS:previousPTS currentPTS:currentPTS phases:phases token:token completion:completion];
}

- (BOOL)submitUncheckedPrevious:(CVPixelBufferRef)previous
                        current:(CVPixelBufferRef)current
                    previousPTS:(CMTime)previousPTS
                     currentPTS:(CMTime)currentPTS
                         phases:(NSArray<NSNumber *> *)phases
                          token:(uint64_t)token
                     completion:(SPFRCPhasesCompletion)completion {
    if (!completion || !_processor || phases.count == 0 || phases.count > 3) return NO;
    CVPixelBufferRef adaptedA = [self adapt:previous format:_sourceFormat];
    CVPixelBufferRef adaptedB = [self adapt:current format:_sourceFormat];
    if (!adaptedA || !adaptedB) {
        if (adaptedA) CVPixelBufferRelease(adaptedA);
        if (adaptedB) CVPixelBufferRelease(adaptedB);
        return NO;
    }
    uint64_t seen = _epoch;
    VTFrameProcessor *processor = _processor;
    OSType destFormat = _destFormat;
    int width = _width;
    int height = _height;
    NSArray<NSNumber *> *phaseCopy = [phases copy];
    dispatch_async(_queue, ^{
        if (seen != self->_epoch || !processor) {
            CVPixelBufferRelease(adaptedA);
            CVPixelBufferRelease(adaptedB);
            completion(token, nil, 0, SPLLError(9, @"低延迟会话已结束"));
            return;
        }
        if (@available(macOS 26.0, *)) {
            VTFrameProcessorFrame *frameA = [[VTFrameProcessorFrame alloc] initWithBuffer:adaptedA presentationTimeStamp:previousPTS];
            VTFrameProcessorFrame *frameB = [[VTFrameProcessorFrame alloc] initWithBuffer:adaptedB presentationTimeStamp:currentPTS];
            NSMutableArray<VTFrameProcessorFrame *> *destinations = [NSMutableArray array];
            NSMutableArray<SPOwnedPixelBuffer *> *owned = [NSMutableArray array];
            BOOL built = frameA && frameB;
            for (NSUInteger i = 0; built && i < phaseCopy.count; ++i) {
                CVPixelBufferRef dst = SPLLCreateWithAttributes((size_t)width, (size_t)height, destFormat, self->_destinationAttributes);
                float phase = phaseCopy[i].floatValue;
                CMTime delta = CMTimeConvertScale(CMTimeSubtract(currentPTS, previousPTS), 1000000000,
                                                   kCMTimeRoundingMethod_RoundHalfAwayFromZero);
                CMTime destinationPTS = CMTimeAdd(previousPTS, CMTimeMultiplyByFloat64(delta, phase));
                VTFrameProcessorFrame *frame = dst ? [[VTFrameProcessorFrame alloc] initWithBuffer:dst presentationTimeStamp:destinationPTS] : nil;
                if (!frame) {
                    if (dst) CVPixelBufferRelease(dst);
                    built = NO;
                    break;
                }
                [destinations addObject:frame];
                [owned addObject:[[SPOwnedPixelBuffer alloc] initWithBufferNoCopy:dst]];
            }
            VTLowLatencyFrameInterpolationParameters *params = built
                ? [[VTLowLatencyFrameInterpolationParameters alloc] initWithSourceFrame:frameB
                                                                           previousFrame:frameA
                                                                      interpolationPhase:phaseCopy
                                                                       destinationFrames:destinations]
                : nil;
            if (!params) {
                CVPixelBufferRelease(adaptedA);
                CVPixelBufferRelease(adaptedB);
                completion(token, nil, 0, SPLLError(10, @"低延迟参数创建失败"));
                return;
            }
            auto *once = new std::atomic<int>(0);
            CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
            [processor processWithParameters:params completionHandler:^(id<VTFrameProcessorParameters> done, NSError *error) {
                (void)done;
                if (once->exchange(1) != 0) return;
                delete once;
                CVPixelBufferRelease(adaptedA);
                CVPixelBufferRelease(adaptedB);
                double seconds = MAX(0, CFAbsoluteTimeGetCurrent() - started);
                if (seen != self->_epoch) {
                    completion(token, nil, seconds, SPLLError(11, @"低延迟结果属于旧会话"));
                    return;
                }
                if (error) {
                    completion(token, nil, seconds, error);
                    return;
                }
                if (owned.count != phaseCopy.count) {
                    completion(token, nil, seconds, SPLLError(12, @"低延迟输出数量和相位不一致"));
                    return;
                }
                completion(token, owned, seconds, nil);
            }];
            return;
        }
        CVPixelBufferRelease(adaptedA);
        CVPixelBufferRelease(adaptedB);
        completion(token, nil, 0, SPLLError(8, @"Apple 低延迟插帧需要 macOS 26"));
    });
    return YES;
}

- (void)invalidate {
    _epoch += 1;
    VTFrameProcessor *processor = _processor;
    _processor = nil;
    _config = nil;
    if (!processor) return;
    dispatch_async(_queue, ^{ [processor endSession]; });
}

+ (NSDictionary<NSString *, id> *)measureEngine:(SPLowLatencyEngine *)engine
                                         phases:(NSArray<NSNumber *> *)phases
                                       expected:(NSArray<NSNumber *> *)expected
                                          width:(int)width
                                           barA:(int)centerA
                                           barB:(int)centerB
                                      unchecked:(BOOL)unchecked {
    CVPixelBufferRef a = SPLLCreate((size_t)width, (size_t)engine.height, kCVPixelFormatType_32BGRA);
    CVPixelBufferRef b = SPLLCreate((size_t)width, (size_t)engine.height, kCVPixelFormatType_32BGRA);
    if (!a || !b) {
        if (a) CVPixelBufferRelease(a);
        if (b) CVPixelBufferRelease(b);
        return @{@"ok": @NO, @"reason": @"buffer"};
    }
    SPLLPaintChecker(a, centerA);
    SPLLPaintChecker(b, centerB);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSArray<SPOwnedPixelBuffer *> *outputs = nil;
    __block NSError *error = nil;
    __block double latency = 0;
    BOOL submitted = unchecked
        ? [engine submitUncheckedPrevious:a current:b previousPTS:CMTimeMake(0, 30) currentPTS:CMTimeMake(1, 30) phases:phases token:1 completion:^(uint64_t token, NSArray<SPOwnedPixelBuffer *> *frames, double seconds, NSError *callError) {
        (void)token;
        outputs = frames;
        error = callError;
        latency = seconds;
        dispatch_semaphore_signal(done);
    }]
        : [engine submitPrevious:a current:b phases:phases token:1 completion:^(uint64_t token, NSArray<SPOwnedPixelBuffer *> *frames, double seconds, NSError *callError) {
        (void)token;
        outputs = frames;
        error = callError;
        latency = seconds;
        dispatch_semaphore_signal(done);
    }];
    if (!submitted) {
        CVPixelBufferRelease(a);
        CVPixelBufferRelease(b);
        return @{@"ok": @NO, @"reason": @"submit"};
    }
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    CVPixelBufferRelease(a);
    CVPixelBufferRelease(b);
    NSMutableArray *centers = [NSMutableArray array];
    NSMutableArray *maxLumas = [NSMutableArray array];
    BOOL positions = outputs.count == expected.count && error == nil;
    for (NSUInteger i = 0; i < outputs.count; ++i) {
        CVPixelBufferRef raw = outputs[i].buffer;
        CVPixelBufferRef bgra = raw;
        BOOL releaseCopy = NO;
        if (CVPixelBufferGetPixelFormatType(raw) != kCVPixelFormatType_32BGRA) {
            bgra = SPLLCreate(CVPixelBufferGetWidth(raw), CVPixelBufferGetHeight(raw), kCVPixelFormatType_32BGRA);
            VTPixelTransferSessionRef transfer = NULL;
            if (bgra && VTPixelTransferSessionCreate(kCFAllocatorDefault, &transfer) == noErr) {
                VTPixelTransferSessionTransferImage(transfer, raw, bgra);
            }
            if (transfer) CFRelease(transfer);
            releaseCopy = YES;
        }
        double center = bgra ? SPLLCenter(bgra) : -1;
        [maxLumas addObject:@(bgra ? SPLLMaxLuma(bgra) : -1)];
        if (releaseCopy && bgra) CVPixelBufferRelease(bgra);
        [centers addObject:@(center)];
        double want = expected[i].doubleValue;
        int outW = (int)CVPixelBufferGetWidth(raw);
        int outH = (int)CVPixelBufferGetHeight(raw);
        double tolerance = abs(centerB - centerA) <= 32 ? 4.0 : 12.0;
        if (outW != width || outH != engine.height || fabs(center - want) > tolerance) positions = NO;
    }
    return @{
        @"ok": @(positions),
        @"error": error.localizedDescription ?: @"",
        @"errorCode": @(error.code),
        @"errorInfo": error.userInfo.description ?: @"",
        @"latencySec": @(latency),
        @"centers": centers,
        @"expected": expected,
        @"outputCount": @(outputs.count),
        @"maxLuma": maxLumas,
        @"sourceFormat": @(engine->_sourceFormat),
        @"destinationFormat": @(engine->_destFormat),
    };
}

+ (NSDictionary<NSString *, id> *)measureFixture {
    NSDictionary *env = NSProcessInfo.processInfo.environment;
    NSString *pathA = env[@"KHUA_PHASE_FIXTURE_A"];
    NSString *pathB = env[@"KHUA_PHASE_FIXTURE_B"];
    NSString *pathMid = env[@"KHUA_PHASE_FIXTURE_MID"];
    if (!pathA.length || !pathB.length || !pathMid.length) return @{@"provided": @NO};
    CVPixelBufferRef a = SPLLReadFixture(pathA), b = SPLLReadFixture(pathB), gt = SPLLReadFixture(pathMid);
    if (!a || !b || !gt || CVPixelBufferGetWidth(a) != CVPixelBufferGetWidth(b) ||
        CVPixelBufferGetHeight(a) != CVPixelBufferGetHeight(b) || CVPixelBufferGetWidth(a) != CVPixelBufferGetWidth(gt) ||
        CVPixelBufferGetHeight(a) != CVPixelBufferGetHeight(gt)) {
        if (a) CVPixelBufferRelease(a); if (b) CVPixelBufferRelease(b); if (gt) CVPixelBufferRelease(gt);
        return @{@"provided": @YES, @"processed": @NO, @"error": @"fixture decode or dimensions"};
    }
    int width = (int)CVPixelBufferGetWidth(a), height = (int)CVPixelBufferGetHeight(a);
    SPLowLatencyEngine *engine = [[SPLowLatencyEngine alloc] init];
    NSError *prepareError = nil;
    if (![engine prepareWidth:width height:height frames:1 error:&prepareError]) {
        CVPixelBufferRelease(a); CVPixelBufferRelease(b); CVPixelBufferRelease(gt);
        return @{@"provided": @YES, @"processed": @NO, @"error": prepareError.localizedDescription ?: @"prepare"};
    }
    __block NSArray<SPOwnedPixelBuffer *> *outputs = nil;
    __block NSError *runError = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    BOOL submitted = [engine submitPrevious:a current:b previousPTS:CMTimeMake(0, 60) currentPTS:CMTimeMake(2, 60) phases:@[@0.5f] token:1
        completion:^(uint64_t token, NSArray<SPOwnedPixelBuffer *> *frames, double seconds, NSError *error) {
            (void)token; (void)seconds; outputs = frames; runError = error; dispatch_semaphore_signal(done);
        }];
    if (submitted) dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    CVPixelBufferRef raw = outputs.firstObject.buffer;
    CVPixelBufferRef rgb = NULL;
    if (raw) {
        rgb = SPLLCreate(CVPixelBufferGetWidth(raw), CVPixelBufferGetHeight(raw), kCVPixelFormatType_32BGRA);
        VTPixelTransferSessionRef transfer = NULL;
        if (!rgb || VTPixelTransferSessionCreate(kCFAllocatorDefault, &transfer) != noErr ||
            VTPixelTransferSessionTransferImage(transfer, raw, rgb) != noErr) {
            if (rgb) CVPixelBufferRelease(rgb); rgb = NULL;
        }
        if (transfer) CFRelease(transfer);
    }
    double modelMAE = SPLLFixtureMAE(rgb, gt), sourceMAE = SPLLFixtureMAE(a, gt);
    if (rgb) CVPixelBufferRelease(rgb);
    CVPixelBufferRelease(a); CVPixelBufferRelease(b); CVPixelBufferRelease(gt);
    [engine invalidate];
    return @{@"provided": @YES, @"processed": @(submitted && runError == nil && modelMAE >= 0),
             @"width": @(width), @"height": @(height), @"phase": @0.5,
             @"inputIntervalSeconds": @(2.0 / 60.0), @"outputCount": @(outputs.count), @"modelMAE": @(modelMAE), @"sourceMAE": @(sourceMAE),
             @"colorSpace": @"ITU-R BT.709, RGB components; every second pixel",
             @"error": runError.localizedDescription ?: @""};
}

+ (NSDictionary<NSString *, id> *)probePhases {
    BOOL half = [self supportsPhaseNumerator:1 denominator:2 frames:1 outFloat:NULL];
    BOOL quarter = [self supportsPhaseNumerator:1 denominator:4 frames:2 outFloat:NULL];
    BOOL threeQuarter = [self supportsPhaseNumerator:3 denominator:4 frames:2 outFloat:NULL];
    BOOL thirdRejected = ![self supportsPhaseNumerator:1 denominator:3 frames:2 outFloat:NULL];
    BOOL onePointRejectsQuarter = ![self supportsPhaseNumerator:1 denominator:4 frames:1 outFloat:NULL];
    if (![self isSupported]) {
        return @{
            @"ok": @NO,
            @"supported": @NO,
            @"reason": @"Apple 低延迟插帧在这台系统上不可用",
            @"thirdRejected": @(thirdRejected),
            @"onePointRejectsQuarter": @(onePointRejectsQuarter),
        };
    }
    SPLowLatencyEngine *engine = [[SPLowLatencyEngine alloc] init];
    NSError *error = nil;
    if (![engine prepareWidth:640 height:360 frames:2 error:&error]) {
        return @{@"ok": @NO, @"supported": @YES, @"reason": error.localizedDescription ?: @"prepare", @"thirdRejected": @(thirdRejected)};
    }
    // Keep the large-motion checker below as a stress sample, and measure a
    // separate 24 px displacement on a fresh processor for comparison.
    SPLowLatencyEngine *smallEngine = [[SPLowLatencyEngine alloc] init];
    NSError *smallError = nil;
    NSDictionary *smallMotion = @{@"ok": @NO};
    if ([smallEngine prepareWidth:640 height:360 frames:2 error:&smallError]) {
        smallMotion = [self measureEngine:smallEngine phases:@[@0.25f, @0.5f, @0.75f]
                                 expected:@[@314, @320, @326] width:640 barA:308 barB:332 unchecked:NO];
        [smallEngine invalidate];
    } else {
        smallMotion = @{@"ok": @NO, @"error": smallError.localizedDescription ?: @"prepare"};
    }
    const int centerA = 240;
    const int centerB = 400;
    auto expect = ^(float phase) {
        return @((double)centerA * (1.0 - phase) + (double)centerB * phase);
    };
    SPLowLatencyEngine *one = [[SPLowLatencyEngine alloc] init];
    NSError *oneError = nil;
    NSDictionary *frames1 = @{@"ok": @NO};
    if ([one prepareWidth:640 height:360 frames:1 error:&oneError]) {
        frames1 = [self measureEngine:one phases:@[@0.5f] expected:@[expect(0.5f)] width:640 barA:centerA barB:centerB unchecked:NO];
        [one invalidate];
    } else {
        frames1 = @{@"ok": @NO, @"error": oneError.localizedDescription ?: @"prepare"};
    }
    NSDictionary *dyadic = [self measureEngine:engine
                                        phases:@[@0.25f, @0.5f, @0.75f]
                                      expected:@[expect(0.25f), expect(0.5f), expect(0.75f)]
                                         width:640
                                          barA:centerA
                                          barB:centerB
                                     unchecked:NO];
    NSDictionary *onlyHalf = [self measureEngine:engine
                                         phases:@[@0.5f]
                                       expected:@[expect(0.5f)]
                                          width:640
                                           barA:centerA
                                           barB:centerB
                                      unchecked:NO];
    NSDictionary *third = [self measureEngine:engine
                                              phases:@[@(1.0f / 3.0f), @(2.0f / 3.0f)]
                                            expected:@[expect(1.0f / 3.0f), expect(2.0f / 3.0f)]
                                               width:640
                                                barA:centerA
                                                barB:centerB
                                           unchecked:YES];
    CVPixelBufferRef junkA = SPLLCreate(640, 360, kCVPixelFormatType_32BGRA);
    CVPixelBufferRef junkB = SPLLCreate(640, 360, kCVPixelFormatType_32BGRA);
    BOOL thirdSubmitted = [engine submitPrevious:junkA
                                        current:junkB
                                         phases:@[@(1.0f / 3.0f)]
                                          token:9
                                     completion:^(uint64_t token, NSArray<SPOwnedPixelBuffer *> *outputs, double latency, NSError *callError) {
        (void)token; (void)outputs; (void)latency; (void)callError;
    }];
    BOOL samePTSSubmitted = [engine submitPrevious:junkA current:junkB
        previousPTS:CMTimeMake(1, 30) currentPTS:CMTimeMake(1, 30) phases:@[@0.5f] token:10
        completion:^(uint64_t token, NSArray<SPOwnedPixelBuffer *> *outputs, double latency, NSError *callError) {
            (void)token; (void)outputs; (void)latency; (void)callError;
        }];
    CVPixelBufferRelease(junkA);
    CVPixelBufferRelease(junkB);
    [engine invalidate];
    BOOL ok = half && quarter && threeQuarter && thirdRejected && onePointRejectsQuarter && [dyadic[@"ok"] boolValue] && !thirdSubmitted && !samePTSSubmitted;
    return @{
        @"ok": @(ok),
        @"supported": @YES,
        @"modelID": engine.modelID ?: @"",
        @"frames": @(engine.frames),
        @"thirdRejectedByContract": @(thirdRejected),
        @"onePointRejectsQuarter": @(onePointRejectsQuarter),
        @"productRejectedThirdSubmit": @(!thirdSubmitted),
        @"duplicatePTSRejected": @(!samePTSSubmitted),
        @"frames1": frames1,
        @"smallMotion24px": smallMotion,
        @"realFixture": [self measureFixture],
        @"dyadic": dyadic,
        @"onlyHalf": onlyHalf,
        @"experimentalThird": third,
        @"thirdDeclaredSupported": @NO,
    };
}

@end
