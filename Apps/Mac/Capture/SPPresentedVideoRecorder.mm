#import "SPPresentedVideoRecorder.h"

#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach_time.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <vector>

NS_ASSUME_NONNULL_BEGIN

namespace {
constexpr size_t LedgerCapacity = 1024;
constexpr size_t PendingLimit = 4;
constexpr int PoolLimit = 8;
constexpr int RenderPoolLimit = 4;
constexpr int64_t RenderCallbackGraceNs = 250000000;

enum class FrameResult {
    pending, encoded, queueFull, invalidPTS, wrongSize, nonIncreasingTime,
    earlierError, writerBackpressure, poolUnavailable, transferFailed, appendFailed
};

struct FrameRecord {
    uint64_t sequence = 0, frameID = 0, callbackHostTicks = 0;
    uint64_t renderCopySequence = 0;
    size_t width = 0, height = 0;
    uint32_t pixelFormat = 0;
    int64_t errorCode = 0;
    CMTime sourcePTS = kCMTimeInvalid;
    double presentedTime = 0, callbackMs = 0, queueMs = 0, transferMs = 0, appendMs = 0;
    int64_t videoTimeNs = -1;
    bool synthetic = false;
    FrameResult result = FrameResult::pending;
};

enum class RenderResult { awaitingCallbacks, encodeFailed, published, notPresented, gpuFailed, cancelled, expired, abandoned };

struct RenderRecord {
    uint64_t sequence = 0, frameID = 0, encodedHostTicks = 0, gpuCallbackHostTicks = 0;
    uint64_t deviceRegistryID = 0;
    size_t textureWidth = 0, textureHeight = 0, originX = 0, originY = 0;
    uint64_t pixelFormat = 0;
    int64_t gpuStatus = 0, errorCode = 0;
    CMTime sourcePTS = kCMTimeInvalid;
    double encodeMs = 0, presentedTime = NAN;
    bool synthetic = false, gpuObserved = false;
    RenderResult result = RenderResult::awaitingCallbacks;
};

NSString *RenderResultName(RenderResult result) {
    switch (result) {
        case RenderResult::awaitingCallbacks: return @"awaiting-callbacks";
        case RenderResult::encodeFailed: return @"copy-encode-failed";
        case RenderResult::published: return @"submitted-to-recorder";
        case RenderResult::notPresented: return @"not-positive-presented";
        case RenderResult::gpuFailed: return @"copy-command-failed";
        case RenderResult::cancelled: return @"publication-cancelled";
        case RenderResult::expired: return @"callback-grace-expired";
        case RenderResult::abandoned: return @"callbacks-abandoned";
    }
}

NSString *ResultName(FrameResult result) {
    switch (result) {
        case FrameResult::pending: return @"pending";
        case FrameResult::encoded: return @"appended";
        case FrameResult::queueFull: return @"dropped-queue-full";
        case FrameResult::invalidPTS: return @"invalid-source-pts";
        case FrameResult::wrongSize: return @"wrong-buffer-size";
        case FrameResult::nonIncreasingTime: return @"non-increasing-presented-time";
        case FrameResult::earlierError: return @"earlier-writer-error";
        case FrameResult::writerBackpressure: return @"dropped-writer-backpressure";
        case FrameResult::poolUnavailable: return @"private-pool-unavailable";
        case FrameResult::transferFailed: return @"pixel-transfer-failed";
        case FrameResult::appendFailed: return @"append-failed";
    }
}

NSDictionary *Distribution(std::vector<double> values) {
    if (values.empty()) return @{ @"n": @0 };
    std::sort(values.begin(), values.end());
    auto percentile = [&](double fraction) {
        const double index = fraction * (values.size() - 1);
        const size_t lower = (size_t)std::floor(index), upper = (size_t)std::ceil(index);
        return values[lower] + (values[upper] - values[lower]) * (index - lower);
    };
    return @{ @"n": @(values.size()), @"min": @(values.front()), @"p50": @(percentile(.5)),
              @"p95": @(percentile(.95)), @"p99": @(percentile(.99)), @"max": @(values.back()) };
}
}

@interface SPPresentedVideoRecorder () {
    NSURL *_outputURL, *_sidecarURL;
    int _width, _height;
    dispatch_queue_t _queue;
    std::mutex _mutex;
    mach_timebase_info_data_t _timebase;
    BOOL _startRequested, _ready, _accepting, _begun, _finishRequested, _writerClosing;
    BOOL _renderCopyEnabled;
    BOOL _armed;
    void (^_windowDidStart)(NSDictionary<NSString *, id> *start);
    NSDictionary<NSString *, id> *_windowStart;
    uint64_t _armedHostTicks;
    double _armedMediaTime;
    uint64_t _beginHostTicks, _finishHostTicks, _finishWorkerTicks;
    double _beginMediaTime, _endMediaTime, _finishMediaTime, _requestedSeconds;
    double _prepareMs;
    size_t _recordCount, _pending, _maximumPending;
    uint64_t _ledgerOverflow, _outsideWindow, _invalidPresentedTime;
    std::array<FrameRecord, LedgerCapacity> _records;
    NSString *_firstFailure;
    AVAssetWriter *_writer;
    AVAssetWriterInput *_input;
    AVAssetWriterInputPixelBufferAdaptor *_adaptor;
    VTPixelTransferSessionRef _transfer;
    double _firstEncodedPresentedTime, _lastEncodedPresentedTime;
    uint64_t _appended;
    CVPixelBufferPoolRef _renderPool;
    CVMetalTextureCacheRef _renderTextureCache;
    id<MTLDevice> _renderDevice;
    dispatch_group_t _renderGroup;
    NSHashTable<SPPresentedRenderSnapshot *> *_renderTickets;
    std::array<RenderRecord, LedgerCapacity> _renderRecords;
    size_t _renderRecordCount, _renderOutstanding, _maximumRenderOutstanding;
    size_t _renderUnresolvedAtWriterClose;
    uint64_t _renderLedgerOverflow;
    uint64_t _renderCopiesSuppressedAfterWindow;
    double _firstSuppressedCopyMediaTime, _lastSuppressedCopyMediaTime;
}
- (void)recordBuffer:(CVPixelBufferRef)buffer frameID:(uint64_t)frameID pts:(CMTime)pts synthetic:(BOOL)synthetic
      presentedTime:(CFTimeInterval)presentedTime renderCopySequence:(uint64_t)renderCopySequence;
- (void)renderGPUCompletedSequence:(uint64_t)sequence status:(MTLCommandBufferStatus)status errorCode:(NSInteger)errorCode;
- (void)observePositiveRenderSequence:(uint64_t)sequence presentedTime:(CFTimeInterval)presentedTime;
- (void)resolveRenderSequence:(uint64_t)sequence result:(RenderResult)result buffer:(nullable CVPixelBufferRef)buffer
                     frameID:(uint64_t)frameID pts:(CMTime)pts synthetic:(BOOL)synthetic presentedTime:(CFTimeInterval)presentedTime;
@end

@interface SPPresentedRenderSnapshot () {
    SPPresentedVideoRecorder *_recorder;
    std::mutex _stateLock;
    CVPixelBufferRef _buffer;
    CVMetalTextureRef _texture;
    uint64_t _sequence, _frameID;
    CMTime _pts;
    BOOL _synthetic, _gpuDone, _gpuSucceeded, _presentationDone, _cancelled, _expired, _resolved;
    double _presentedTime;
}
- (instancetype)initWithRecorder:(SPPresentedVideoRecorder *)recorder buffer:(CVPixelBufferRef)buffer
                         texture:(nullable CVMetalTextureRef)texture sequence:(uint64_t)sequence frameID:(uint64_t)frameID
                             pts:(CMTime)pts synthetic:(BOOL)synthetic;
- (void)commandCompleted:(id<MTLCommandBuffer>)command;
- (void)expireCallbacks;
@end

@implementation SPPresentedRenderSnapshot
- (instancetype)initWithRecorder:(SPPresentedVideoRecorder *)recorder buffer:(CVPixelBufferRef)buffer
                         texture:(nullable CVMetalTextureRef)texture sequence:(uint64_t)sequence frameID:(uint64_t)frameID
                             pts:(CMTime)pts synthetic:(BOOL)synthetic {
    if ((self = [super init])) {
        // Consume the two Create-rule references from the render-copy encoder.
        _recorder = recorder; _buffer = buffer; _texture = texture;
        _sequence = sequence; _frameID = frameID; _pts = pts; _synthetic = synthetic;
        _presentedTime = NAN;
    }
    return self;
}
- (void)dealloc {
    if (!_resolved) [_recorder resolveRenderSequence:_sequence result:RenderResult::abandoned buffer:nullptr
        frameID:_frameID pts:_pts synthetic:_synthetic presentedTime:NAN];
    if (_texture) CFRelease(_texture);
    if (_buffer) CVPixelBufferRelease(_buffer);
}
- (void)resolveIfReady {
    CVPixelBufferRef buffer = nullptr;
    BOOL notify = NO;
    RenderResult result = RenderResult::awaitingCallbacks;
    double presentedTime;
    {
        std::lock_guard<std::mutex> lock(_stateLock);
        presentedTime = _presentedTime;
        if (!_resolved) {
            if (_cancelled) result = RenderResult::cancelled;
            else if (_expired) result = RenderResult::expired;
            else if (_gpuDone && !_gpuSucceeded) result = RenderResult::gpuFailed;
            else if (_gpuDone && _presentationDone)
                result = std::isfinite(presentedTime) && presentedTime > 0 ? RenderResult::published : RenderResult::notPresented;
            if (result != RenderResult::awaitingCallbacks) {
                _resolved = YES; notify = YES;
                if (result == RenderResult::published) buffer = CVPixelBufferRetain(_buffer);
            }
        }
        // A cancelled copy may still be submitted by the caller's cleanup path.
        // Its command retains this ticket, so keep GPU storage until completion.
        if (_resolved && _gpuDone) {
            if (_texture) { CFRelease(_texture); _texture = nullptr; }
            if (_buffer) { CVPixelBufferRelease(_buffer); _buffer = nullptr; }
        }
    }
    if (notify) [_recorder resolveRenderSequence:_sequence result:result buffer:buffer
        frameID:_frameID pts:_pts synthetic:_synthetic presentedTime:presentedTime];
    if (buffer) CVPixelBufferRelease(buffer);
}
- (void)commandCompleted:(id<MTLCommandBuffer>)command {
    const MTLCommandBufferStatus status = command.status;
    [_recorder renderGPUCompletedSequence:_sequence status:status errorCode:command.error.code];
    { std::lock_guard<std::mutex> lock(_stateLock); _gpuDone = YES; _gpuSucceeded = status == MTLCommandBufferStatusCompleted; }
    [self resolveIfReady];
}
- (void)presentedAtTime:(CFTimeInterval)presentedTime {
    {
        std::lock_guard<std::mutex> lock(_stateLock);
        // Publish the anchor before allowing the GPU callback to resolve this
        // frame, including when the two CPU callbacks arrive concurrently.
        if (!_resolved && !_cancelled && !_expired && std::isfinite(presentedTime) && presentedTime > 0)
            [_recorder observePositiveRenderSequence:_sequence presentedTime:presentedTime];
        _presentationDone = YES; _presentedTime = presentedTime;
    }
    [self resolveIfReady];
}
- (void)cancelPublication {
    { std::lock_guard<std::mutex> lock(_stateLock); _cancelled = YES; }
    [self resolveIfReady];
}
- (void)expireCallbacks {
    { std::lock_guard<std::mutex> lock(_stateLock); _expired = YES; }
    [self resolveIfReady];
}
@end

@implementation SPPresentedVideoRecorder
- (instancetype)initWithOutputURL:(NSURL *)outputURL width:(int)width height:(int)height {
    if ((self = [super init])) {
        _outputURL = [outputURL copy];
        _sidecarURL = [[outputURL URLByDeletingPathExtension] URLByAppendingPathExtension:@"json"];
        _width = width; _height = height;
        _queue = dispatch_queue_create("app.openduckframe.presented-video", DISPATCH_QUEUE_SERIAL_WITH_AUTORELEASE_POOL);
        mach_timebase_info(&_timebase);
        _firstEncodedPresentedTime = NAN;
        _lastEncodedPresentedTime = NAN;
        _firstSuppressedCopyMediaTime = NAN; _lastSuppressedCopyMediaTime = NAN;
        _renderGroup = dispatch_group_create();
        _renderTickets = [NSHashTable weakObjectsHashTable];
#if defined(ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC) && ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC == 1
        const char *fused = getenv("ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC");
        _renderCopyEnabled = fused && strcmp(fused, "1") == 0;
#endif
    }
    return self;
}

- (void)dealloc {
    if (_transfer) CFRelease(_transfer);
    if (_renderTextureCache) CFRelease(_renderTextureCache);
    if (_renderPool) CFRelease(_renderPool);
}

- (double)millisecondsSince:(uint64_t)start {
    return (double)(mach_absolute_time() - start) * _timebase.numer / _timebase.denom / 1e6;
}

- (void)fail:(NSString *)message {
    std::lock_guard<std::mutex> lock(_mutex);
    if (!_firstFailure) _firstFailure = [message copy];
}

- (void)startWithCompletion:(void (^)(NSError *_Nullable))completion {
    {
        std::lock_guard<std::mutex> lock(_mutex);
        if (_startRequested) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion([NSError errorWithDomain:@"SPPresentedVideoRecorder" code:1
                    userInfo:@{NSLocalizedDescriptionKey: @"Recorder preparation was already requested"}]);
            });
            return;
        }
        _startRequested = YES;
    }
    dispatch_async(_queue, ^{
        const uint64_t started = mach_absolute_time();
        NSError *error = nil;
        self->_writer = [[AVAssetWriter alloc] initWithURL:self->_outputURL fileType:AVFileTypeQuickTimeMovie error:&error];
        NSDictionary *settings = @{
            AVVideoCodecKey: AVVideoCodecTypeHEVC,
            AVVideoWidthKey: @(self->_width), AVVideoHeightKey: @(self->_height),
            AVVideoEncoderSpecificationKey: @{(__bridge NSString *)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: @YES},
            AVVideoColorPropertiesKey: @{ AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2 },
            AVVideoCompressionPropertiesKey: @{ AVVideoAverageBitRateKey: @((int64_t)self->_width * self->_height * 16),
                AVVideoExpectedSourceFrameRateKey: @48, AVVideoMaxKeyFrameIntervalKey: @48,
                AVVideoAllowFrameReorderingKey: @NO, AVVideoProfileLevelKey: (__bridge NSString *)kVTProfileLevel_HEVC_Main_AutoLevel }
        };
        if (!error && ![self->_writer canApplyOutputSettings:settings forMediaType:AVMediaTypeVideo])
            error = [NSError errorWithDomain:@"SPPresentedVideoRecorder" code:2
                userInfo:@{NSLocalizedDescriptionKey: @"Hardware HEVC writer rejected the video settings"}];
        if (!error) {
            self->_input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:settings];
            self->_input.expectsMediaDataInRealTime = YES;
            self->_input.mediaTimeScale = 1000000000;
            self->_adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:self->_input
                sourcePixelBufferAttributes:@{(__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                    (__bridge NSString *)kCVPixelBufferWidthKey: @(self->_width), (__bridge NSString *)kCVPixelBufferHeightKey: @(self->_height),
                    (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{} }];
            if ([self->_writer canAddInput:self->_input]) [self->_writer addInput:self->_input];
            else error = [NSError errorWithDomain:@"SPPresentedVideoRecorder" code:3
                userInfo:@{NSLocalizedDescriptionKey: @"Writer could not add the video input"}];
        }
        if (!error && ![self->_writer startWriting]) error = self->_writer.error;
        if (!error) {
            [self->_writer startSessionAtSourceTime:kCMTimeZero];
            const OSStatus status = VTPixelTransferSessionCreate(kCFAllocatorDefault, &self->_transfer);
            if (status != noErr) error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status
                userInfo:@{NSLocalizedDescriptionKey: @"Could not create the recorder's pixel transfer session"}];
        }
        self->_prepareMs = [self millisecondsSince:started];
        if (error) [self fail:error.localizedDescription];
        {
            std::lock_guard<std::mutex> lock(self->_mutex);
            self->_ready = error == nil;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    });
}

- (void)beginAtMediaTime:(CFTimeInterval)mediaTime hostTicks:(uint64_t)hostTicks durationSeconds:(double)durationSeconds {
    std::lock_guard<std::mutex> lock(_mutex);
    if (!_ready || _armed || _begun || _finishRequested || !std::isfinite(mediaTime) || mediaTime <= 0 ||
        !std::isfinite(durationSeconds) || durationSeconds <= 0 || durationSeconds > 10) {
        if (!_firstFailure) _firstFailure = @"Recorder begin did not meet the prepared, single-use, at-most-ten-second contract";
        return;
    }
    _begun = YES; _accepting = YES;
    _beginMediaTime = mediaTime; _endMediaTime = mediaTime + durationSeconds;
    _beginHostTicks = hostTicks; _requestedSeconds = durationSeconds;
}

- (BOOL)armRenderedWindowForDurationSeconds:(double)durationSeconds
                                  didStart:(void (^)(NSDictionary<NSString *, id> *))didStart {
    std::lock_guard<std::mutex> lock(_mutex);
    if (!_ready || !_renderCopyEnabled || _armed || _begun || _finishRequested ||
        !std::isfinite(durationSeconds) || durationSeconds <= 0 || durationSeconds > 10) {
        if (!_firstFailure) _firstFailure = @"Rendered window could not be armed with the prepared single-use recorder";
        return NO;
    }
    _armed = YES; _accepting = YES; _requestedSeconds = durationSeconds;
    _windowDidStart = [didStart copy];
    _armedHostTicks = mach_absolute_time(); _armedMediaTime = CACurrentMediaTime();
    return YES;
}

- (void)observePositiveRenderSequence:(uint64_t)sequence presentedTime:(CFTimeInterval)presentedTime {
    void (^didStart)(NSDictionary<NSString *, id> *) = nil;
    NSDictionary<NSString *, id> *start;
    {
        std::lock_guard<std::mutex> lock(_mutex);
        if (!_armed || _begun || !_accepting || _finishRequested) return;
        const RenderRecord &record = _renderRecords[sequence - 1];
        _begun = YES; _beginMediaTime = presentedTime; _endMediaTime = presentedTime + _requestedSeconds;
        _beginHostTicks = mach_absolute_time();
        _windowStart = @{ @"windowStartMediaTime": @(_beginMediaTime), @"windowEndMediaTimeExclusive": @(_endMediaTime),
            @"requestedSeconds": @(_requestedSeconds), @"anchorObservedHostTicks": @(_beginHostTicks),
            @"anchorRenderCopySequence": @(sequence), @"anchorFrameID": @(record.frameID),
            @"anchorType": record.synthetic ? @"synthetic" : @"original", @"anchorPTSValue": @(record.sourcePTS.value),
            @"anchorPTSTimescale": @(record.sourcePTS.timescale),
            @"scope": @"First observed copied positive fixes the Media window once. Host ticks observe its CPU callback, not the physical presentation instant. GPU completion is still required for encoding." };
        start = _windowStart; didStart = _windowDidStart; _windowDidStart = nil;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ didStart(start); });
}

- (nullable SPPresentedRenderSnapshot *)encodeRenderCopyFromTexture:(id<MTLTexture>)texture sourceOrigin:(MTLOrigin)sourceOrigin
                                             commandBuffer:(id<MTLCommandBuffer>)commandBuffer frameID:(uint64_t)frameID
                                                       pts:(CMTime)pts synthetic:(BOOL)synthetic error:(NSError *_Nullable *_Nullable)error {
    const uint64_t started = mach_absolute_time();
    std::lock_guard<std::mutex> lock(_mutex);
    if (error) *error = nil;
    if (!_renderCopyEnabled || !_accepting) {
        if (error) *error = [NSError errorWithDomain:@"SPPresentedRenderCopy" code:20
            userInfo:@{NSLocalizedDescriptionKey: @"Rendered-frame recording is not active"}];
        return nil;
    }
    const CFTimeInterval currentMedia = CACurrentMediaTime();
    if (_begun && currentMedia >= _endMediaTime) {
        _renderCopiesSuppressedAfterWindow++;
        if (!std::isfinite(_firstSuppressedCopyMediaTime)) _firstSuppressedCopyMediaTime = currentMedia;
        _lastSuppressedCopyMediaTime = currentMedia;
        return nil;
    }
    if (_renderRecordCount == LedgerCapacity) {
        _renderLedgerOverflow++;
        if (!_firstFailure) _firstFailure = @"Rendered-copy ledger overflow";
        if (error) *error = [NSError errorWithDomain:@"SPPresentedRenderCopy" code:21
            userInfo:@{NSLocalizedDescriptionKey: _firstFailure}];
        return nil;
    }
    RenderRecord &record = _renderRecords[_renderRecordCount++];
    record.sequence = _renderRecordCount; record.frameID = frameID; record.sourcePTS = pts; record.synthetic = synthetic;
    record.textureWidth = texture.width; record.textureHeight = texture.height;
    record.originX = sourceOrigin.x; record.originY = sourceOrigin.y; record.pixelFormat = texture.pixelFormat;
    record.deviceRegistryID = texture.device.registryID;
    auto reject = [&](NSInteger code, NSString *message) -> SPPresentedRenderSnapshot *_Nullable {
        record.result = RenderResult::encodeFailed; record.errorCode = code; record.encodeMs = [self millisecondsSince:started];
        if (!_firstFailure) _firstFailure = [message copy];
        if (error) *error = [NSError errorWithDomain:@"SPPresentedRenderCopy" code:code
            userInfo:@{NSLocalizedDescriptionKey: message}];
        return nil;
    };
    if (sourceOrigin.x || sourceOrigin.y || sourceOrigin.z || texture.width != (size_t)_width || texture.height != (size_t)_height ||
        texture.textureType != MTLTextureType2D || texture.sampleCount != 1 || texture.pixelFormat != MTLPixelFormatBGRA8Unorm ||
        texture.framebufferOnly || commandBuffer.status >= MTLCommandBufferStatusCommitted ||
        texture.device.registryID != commandBuffer.commandQueue.device.registryID)
        return reject(22, @"Rendered copy requires a readable full-size BGRA8 drawable at origin zero, on the same uncommitted command buffer");
    if (!_renderPool) {
        NSDictionary *attributes = @{(__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (__bridge NSString *)kCVPixelBufferWidthKey: @(_width), (__bridge NSString *)kCVPixelBufferHeightKey: @(_height),
            (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES, (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}};
        const CVReturn created = CVPixelBufferPoolCreate(kCFAllocatorDefault, nullptr,
            (__bridge CFDictionaryRef)attributes, &_renderPool);
        if (created != kCVReturnSuccess) return reject(created, @"Could not create the full rendered-copy BGRA pool");
    }
    if (!_renderTextureCache) {
        _renderDevice = texture.device;
        const CVReturn created = CVMetalTextureCacheCreate(kCFAllocatorDefault, nullptr, _renderDevice, nullptr, &_renderTextureCache);
        if (created != kCVReturnSuccess) return reject(created, @"Could not create the rendered-copy Metal texture cache");
    }
    if (_renderDevice.registryID != texture.device.registryID) return reject(23, @"Rendered-copy Metal device changed");
    // CoreVideo requires periodic cache housekeeping. Live ticket references
    // keep their images in use while unused mappings can return to this pool.
    CVMetalTextureCacheFlush(_renderTextureCache, 0);
    CVPixelBufferRef buffer = nullptr;
    NSDictionary *threshold = @{(__bridge NSString *)kCVPixelBufferPoolAllocationThresholdKey: @(RenderPoolLimit)};
    const CVReturn allocated = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, _renderPool,
        (__bridge CFDictionaryRef)threshold, &buffer);
    if (allocated != kCVReturnSuccess) return reject(allocated, @"Full rendered-copy BGRA pool is unavailable");
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVMetalTextureRef image = nullptr;
    const CVReturn mapped = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _renderTextureCache, buffer, nullptr,
        MTLPixelFormatBGRA8Unorm, _width, _height, 0, &image);
    id<MTLTexture> destination = image ? CVMetalTextureGetTexture(image) : nil;
    if (mapped != kCVReturnSuccess || !destination) {
        if (image) CFRelease(image);
        CVPixelBufferRelease(buffer);
        return reject(mapped, @"Could not map the full rendered-copy BGRA texture");
    }
    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    if (!blit) {
        CFRelease(image); CVPixelBufferRelease(buffer);
        return reject(24, @"Could not create the rendered-copy blit encoder");
    }
    blit.label = @"quality-only-full-render-copy";
    [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:sourceOrigin sourceSize:MTLSizeMake(_width, _height, 1)
               toTexture:destination destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    record.encodedHostTicks = mach_absolute_time(); record.encodeMs = [self millisecondsSince:started];
    SPPresentedRenderSnapshot *ticket = [[SPPresentedRenderSnapshot alloc] initWithRecorder:self buffer:buffer texture:image
        sequence:record.sequence frameID:frameID pts:pts synthetic:synthetic];
    dispatch_group_enter(_renderGroup);
    _renderOutstanding++; _maximumRenderOutstanding = std::max(_maximumRenderOutstanding, _renderOutstanding);
    [_renderTickets addObject:ticket];
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) { [ticket commandCompleted:completed]; }];
    return ticket;
}

- (void)renderGPUCompletedSequence:(uint64_t)sequence status:(MTLCommandBufferStatus)status errorCode:(NSInteger)errorCode {
    std::lock_guard<std::mutex> lock(_mutex);
    RenderRecord &record = _renderRecords[sequence - 1];
    record.gpuObserved = true; record.gpuStatus = status; record.gpuCallbackHostTicks = mach_absolute_time();
    if (errorCode) record.errorCode = errorCode;
}

- (void)resolveRenderSequence:(uint64_t)sequence result:(RenderResult)result buffer:(nullable CVPixelBufferRef)buffer
                     frameID:(uint64_t)frameID pts:(CMTime)pts synthetic:(BOOL)synthetic presentedTime:(CFTimeInterval)presentedTime {
    // Submit before leaving the group so writer finalization stays behind it.
    if (result == RenderResult::published)
        [self recordBuffer:buffer frameID:frameID pts:pts synthetic:synthetic presentedTime:presentedTime renderCopySequence:sequence];
    {
        std::lock_guard<std::mutex> lock(_mutex);
        RenderRecord &record = _renderRecords[sequence - 1];
        record.result = result; record.presentedTime = presentedTime;
        if ((result == RenderResult::gpuFailed || result == RenderResult::expired || result == RenderResult::abandoned) && !_firstFailure)
            _firstFailure = RenderResultName(result);
        _renderOutstanding--;
    }
    dispatch_group_leave(_renderGroup);
}

- (void)recordPresentedBuffer:(CVPixelBufferRef)buffer frameID:(uint64_t)frameID pts:(CMTime)pts
                   synthetic:(BOOL)synthetic presentedTime:(CFTimeInterval)presentedTime {
    if (_renderCopyEnabled) {
        [self fail:@"Fused diagnostic recording requires the full rendered-copy ticket"]; return;
    }
    [self recordBuffer:buffer frameID:frameID pts:pts synthetic:synthetic presentedTime:presentedTime renderCopySequence:0];
}

- (void)recordBuffer:(CVPixelBufferRef)buffer frameID:(uint64_t)frameID pts:(CMTime)pts synthetic:(BOOL)synthetic
      presentedTime:(CFTimeInterval)presentedTime renderCopySequence:(uint64_t)renderCopySequence {
    const uint64_t callbackStart = mach_absolute_time();
    std::lock_guard<std::mutex> lock(_mutex);
    if (_writerClosing || (!_accepting && !(renderCopySequence && _finishRequested))) return;
    if (!std::isfinite(presentedTime) || presentedTime <= 0) { _invalidPresentedTime++; return; }
    if (presentedTime < _beginMediaTime || presentedTime >= _endMediaTime) { _outsideWindow++; return; }
    if (_recordCount == LedgerCapacity) {
        _ledgerOverflow++;
        if (!_firstFailure) _firstFailure = @"Presented-video ledger overflow";
        return;
    }
    const size_t index = _recordCount++;
    FrameRecord &record = _records[index];
    record.sequence = index + 1; record.frameID = frameID; record.sourcePTS = pts;
    record.renderCopySequence = renderCopySequence;
    record.synthetic = synthetic; record.presentedTime = presentedTime; record.callbackHostTicks = callbackStart;
    if (buffer) {
        record.width = CVPixelBufferGetWidth(buffer); record.height = CVPixelBufferGetHeight(buffer);
        record.pixelFormat = CVPixelBufferGetPixelFormatType(buffer);
    }
    if (!CMTIME_IS_NUMERIC(pts)) record.result = FrameResult::invalidPTS;
    else if (!buffer || record.width != (size_t)_width || record.height != (size_t)_height)
        record.result = FrameResult::wrongSize;
    else if (_pending == PendingLimit) record.result = FrameResult::queueFull;
    if (record.result != FrameResult::pending) {
        if (!_firstFailure) _firstFailure = ResultName(record.result);
        record.callbackMs = [self millisecondsSince:callbackStart];
        return;
    }
    CVPixelBufferRetain(buffer);
    _pending++; _maximumPending = std::max(_maximumPending, _pending);
    dispatch_async(_queue, ^{
        [self appendBuffer:buffer recordIndex:index];
        CVPixelBufferRelease(buffer);
        std::lock_guard<std::mutex> workerLock(self->_mutex);
        self->_pending--;
    });
    record.callbackMs = [self millisecondsSince:callbackStart];
}

- (void)appendBuffer:(CVPixelBufferRef)source recordIndex:(size_t)index {
    FrameRecord record;
    {
        std::lock_guard<std::mutex> lock(_mutex);
        record = _records[index];
    }
    record.queueMs = [self millisecondsSince:record.callbackHostTicks];
    CVPixelBufferRef destination = nullptr;
    NSError *writerError = _writer.error;
    if (_writer.status != AVAssetWriterStatusWriting || writerError) record.result = FrameResult::earlierError;
    else if (std::isfinite(_lastEncodedPresentedTime) && record.presentedTime <= _lastEncodedPresentedTime)
        record.result = FrameResult::nonIncreasingTime;
    else if (!_input.readyForMoreMediaData) record.result = FrameResult::writerBackpressure;
    else {
        NSDictionary *aux = @{(__bridge NSString *)kCVPixelBufferPoolAllocationThresholdKey: @(PoolLimit)};
        CVPixelBufferPoolRef pool = _adaptor.pixelBufferPool;
        const CVReturn allocated = pool ? CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
            (__bridge CFDictionaryRef)aux, &destination) : kCVReturnInvalidPoolAttributes;
        if (allocated != kCVReturnSuccess) { record.result = FrameResult::poolUnavailable; record.errorCode = allocated; }
        else {
            CVBufferPropagateAttachments(source, destination);
            CVBufferSetAttachment(destination, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
            CVBufferSetAttachment(destination, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
            CVBufferSetAttachment(destination, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
            const uint64_t transferStart = mach_absolute_time();
            const OSStatus transferred = VTPixelTransferSessionTransferImage(_transfer, source, destination);
            record.transferMs = [self millisecondsSince:transferStart];
            if (transferred != noErr) { record.result = FrameResult::transferFailed; record.errorCode = transferred; }
            else {
                const double firstTime = std::isfinite(_firstEncodedPresentedTime) ? _firstEncodedPresentedTime : record.presentedTime;
                record.videoTimeNs = (int64_t)llround((record.presentedTime - firstTime) * 1e9);
                const uint64_t appendStart = mach_absolute_time();
                const BOOL appended = [_adaptor appendPixelBuffer:destination withPresentationTime:CMTimeMake(record.videoTimeNs, 1000000000)];
                record.appendMs = [self millisecondsSince:appendStart];
                record.result = appended ? FrameResult::encoded : FrameResult::appendFailed;
                if (!appended) record.errorCode = _writer.error.code;
                if (appended) {
                    if (!std::isfinite(_firstEncodedPresentedTime)) _firstEncodedPresentedTime = record.presentedTime;
                    _lastEncodedPresentedTime = record.presentedTime;
                    _appended++;
                }
            }
        }
    }
    if (destination) CVPixelBufferRelease(destination);
    {
        std::lock_guard<std::mutex> lock(_mutex);
        // callbackMs is finalized by the caller after it enqueues this job.
        record.callbackMs = _records[index].callbackMs;
        _records[index] = record;
        if (record.result != FrameResult::encoded && !_firstFailure) {
            _firstFailure = writerError.localizedDescription ?: _writer.error.localizedDescription ?:
                [NSString stringWithFormat:@"%@ (code %lld)", ResultName(record.result), (long long)record.errorCode];
        }
    }
}

- (void)finishAtMediaTime:(CFTimeInterval)mediaTime hostTicks:(uint64_t)hostTicks
              completion:(void (^)(NSDictionary<NSString *, id> *))completion {
    {
        std::lock_guard<std::mutex> lock(_mutex);
        _accepting = NO; _finishRequested = YES;
        _windowDidStart = nil;
        if (_armed && !_begun && !_firstFailure) _firstFailure = @"Armed recording stopped before its first copied positive frame";
        _finishMediaTime = mediaTime; _finishHostTicks = hostTicks;
        if (std::isfinite(mediaTime)) {
            if (_begun && mediaTime < _beginMediaTime + _requestedSeconds && !_firstFailure)
                _firstFailure = @"Quality window ended before its requested duration";
            _endMediaTime = std::min(_endMediaTime, mediaTime);
        }
        else if (!_firstFailure) _firstFailure = @"Recorder finish Media time was not finite";
        // A ticket may see its positive callback before its completed callback.
        // Its enqueue precedes group_leave, keeping writer close behind all data.
        dispatch_group_notify(_renderGroup, _queue, ^{ [self closeWriterWithCompletion:completion]; });
        if (_renderCopyEnabled) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, RenderCallbackGraceNs), _queue, ^{
            NSArray<SPPresentedRenderSnapshot *> *tickets;
            {
                std::lock_guard<std::mutex> callbackLock(self->_mutex);
                if (self->_writerClosing) return;
                tickets = self->_renderTickets.allObjects;
            }
            for (SPPresentedRenderSnapshot *ticket in tickets) [ticket expireCallbacks];
            [self closeWriterWithCompletion:completion];
        });
    }
}

- (void)closeWriterWithCompletion:(void (^)(NSDictionary<NSString *, id> *))completion {
    {
        std::lock_guard<std::mutex> lock(_mutex);
        if (_writerClosing) return;
        _writerClosing = YES;
        _renderUnresolvedAtWriterClose = _renderOutstanding;
        if (_renderOutstanding && !_firstFailure) _firstFailure = @"Rendered-copy callbacks unresolved at writer close";
    }
    _finishWorkerTicks = mach_absolute_time();
    if (_writer.status == AVAssetWriterStatusWriting && _appended > 0) {
        const double end = _endMediaTime - _firstEncodedPresentedTime;
        if (end > _lastEncodedPresentedTime - _firstEncodedPresentedTime)
            [_writer endSessionAtSourceTime:CMTimeMake((int64_t)llround(end * 1e9), 1000000000)];
        [_input markAsFinished];
        [_writer finishWritingWithCompletionHandler:^{
            dispatch_async(self->_queue, ^{ [self finishReportWithCompletion:completion]; });
        }];
    } else {
        if (_appended == 0) [self fail:@"Recorder had no appended positive-presented frames"];
        [_writer cancelWriting];
        [self finishReportWithCompletion:completion];
    }
}

- (void)finishReportWithCompletion:(void (^)(NSDictionary<NSString *, id> *))completion {
    if (_writer.status != AVAssetWriterStatusCompleted) [self fail:_writer.error.localizedDescription ?: @"Video writer did not complete"];
    NSMutableArray *ledger = [NSMutableArray arrayWithCapacity:_recordCount];
    NSMutableDictionary *counts = [NSMutableDictionary dictionary];
    std::vector<double> callback, queue, transfer, append;
    for (size_t index = 0; index < _recordCount; index++) {
        const FrameRecord &record = _records[index];
        NSString *name = ResultName(record.result);
        counts[name] = @([counts[name] unsignedLongLongValue] + 1);
        callback.push_back(record.callbackMs);
        if (record.result != FrameResult::queueFull && record.result != FrameResult::invalidPTS && record.result != FrameResult::wrongSize) queue.push_back(record.queueMs);
        if (record.transferMs > 0) transfer.push_back(record.transferMs);
        if (record.appendMs > 0) append.push_back(record.appendMs);
        [ledger addObject:@{ @"sequence": @(record.sequence), @"frameID": @(record.frameID),
            @"renderCopySequence": record.renderCopySequence ? @(record.renderCopySequence) : (id)NSNull.null,
            @"ptsValue": @(record.sourcePTS.value), @"ptsTimescale": @(record.sourcePTS.timescale),
            @"ptsFlags": @(record.sourcePTS.flags), @"ptsEpoch": @(record.sourcePTS.epoch),
            @"type": record.synthetic ? @"synthetic" : @"original", @"actualPresentedTime": @(record.presentedTime),
            @"sourceWidth": @(record.width), @"sourceHeight": @(record.height), @"sourceFourCC": @(record.pixelFormat),
            @"callbackHostTicks": @(record.callbackHostTicks), @"videoPresentationTimeNs": record.videoTimeNs >= 0 ? @(record.videoTimeNs) : (id)NSNull.null,
            @"result": name, @"errorCode": @(record.errorCode), @"callbackSubmitMs": @(record.callbackMs), @"queueMs": @(record.queueMs),
            @"transferMs": @(record.transferMs), @"appendMs": @(record.appendMs) }];
    }
    NSDictionary *file = [[NSFileManager defaultManager] attributesOfItemAtPath:_outputURL.path error:nil];
    NSString *failure;
    std::vector<RenderRecord> renderRecords;
    size_t outstandingAtReport;
    {
        std::lock_guard<std::mutex> lock(_mutex);
        failure = _firstFailure; outstandingAtReport = _renderOutstanding;
        renderRecords.assign(_renderRecords.begin(), _renderRecords.begin() + _renderRecordCount);
    }
    NSMutableArray *renderLedger = [NSMutableArray arrayWithCapacity:renderRecords.size()];
    NSMutableDictionary *renderCounts = [NSMutableDictionary dictionary];
    std::vector<double> copyEncodeMs;
    for (const RenderRecord &record : renderRecords) {
        NSString *name = RenderResultName(record.result);
        renderCounts[name] = @([renderCounts[name] unsignedLongLongValue] + 1);
        copyEncodeMs.push_back(record.encodeMs);
        [renderLedger addObject:@{ @"sequence": @(record.sequence), @"frameID": @(record.frameID),
            @"type": record.synthetic ? @"synthetic" : @"original", @"ptsValue": @(record.sourcePTS.value),
            @"ptsTimescale": @(record.sourcePTS.timescale), @"ptsEpoch": @(record.sourcePTS.epoch),
            @"renderTextureWidth": @(record.textureWidth), @"renderTextureHeight": @(record.textureHeight),
            @"copyOriginX": @(record.originX), @"copyOriginY": @(record.originY), @"copyWidth": @(_width), @"copyHeight": @(_height),
            @"metalPixelFormat": @(record.pixelFormat), @"deviceRegistryID": @(record.deviceRegistryID),
            @"copyEncodedHostTicks": @(record.encodedHostTicks), @"copyEncodeMs": @(record.encodeMs),
            @"gpuCallbackHostTicks": record.gpuObserved ? @(record.gpuCallbackHostTicks) : (id)NSNull.null,
            @"gpuCommandBufferStatus": record.gpuObserved ? @(record.gpuStatus) : (id)NSNull.null,
            @"actualPresentedTime": std::isfinite(record.presentedTime) ? @(record.presentedTime) : (id)NSNull.null,
            @"result": name, @"errorCode": @(record.errorCode) }];
    }
    NSDictionary *renderCopies = @{ @"schema": @"odf-full-render-copy-v1", @"enabled": @(_renderCopyEnabled),
        @"poolAllocationLimit": @(RenderPoolLimit), @"records": renderLedger, @"resultCounts": renderCounts,
        @"maximumUnresolvedAssociations": @(_maximumRenderOutstanding), @"unresolvedAtWriterClose": @(_renderUnresolvedAtWriterClose),
        @"unresolvedAtReport": @(outstandingAtReport), @"ledgerOverflow": @(_renderLedgerOverflow),
        @"callbackGraceNs": @(RenderCallbackGraceNs), @"copyEncodeCPUms": Distribution(copyEncodeMs),
        @"textureCacheHousekeeping": @"Flush before each bounded allocation; live ticket texture references retain in-use images",
        @"suppressedAfterWindowEnd": @(_renderCopiesSuppressedAfterWindow),
        @"firstSuppressedCopyMediaTime": std::isfinite(_firstSuppressedCopyMediaTime) ? @(_firstSuppressedCopyMediaTime) : (id)NSNull.null,
        @"lastSuppressedCopyMediaTime": std::isfinite(_lastSuppressedCopyMediaTime) ? @(_lastSuppressedCopyMediaTime) : (id)NSNull.null,
        @"source": @"Full BGRA8 render target, unscaled same-command-buffer texture blit into a private IOSurface buffer",
        @"ownership": @"Ticket retains private buffer and mapped texture through GPU completion and presentation resolution; encoder retains only the private buffer. No drawable retained for encoding. Cancelled cleanup submissions retain GPU storage until completion.",
        @"graceScope": @"Asynchronous quality export bound only. Missing callbacks become incomplete material; in-flight GPU storage is retained until completion. No synchronous GPU wait." };
    NSMutableDictionary *report = [@{
        @"schema": @"odf-positive-presented-video-v1", @"status": failure ? @"incomplete" : @"completed",
        @"firstFailure": failure ?: (id)NSNull.null, @"outputPath": _outputURL.path, @"sidecarPath": _sidecarURL.path,
        @"width": @(_width), @"height": @(_height), @"codec": @"HEVC Main", @"container": @"QuickTime Movie",
        @"hardwareRequired": @YES, @"hardwareVerification": @"Required through AVVideoEncoderSpecificationKey; no independent encoder telemetry",
        @"averageBitRateRequested": @((int64_t)_width * _height * 16), @"encodedPixelFormat": @"420v",
        @"captureSource": _renderCopyEnabled ? @"full-render-target-copy" : @"presented-source-buffer",
        @"method": _renderCopyEnabled ? @"Quality-only full render-target BGRA blit, GPU-success plus positive-presented join, private NV12 transfer, then real-time HEVC; no overlays" : @"Counted enhanced-view positive-presented source buffers copied to a private NV12 pool with VTPixelTransfer, then real-time AVAssetWriter HEVC; no overlays",
        @"timestampRule": @"Actual presentedTime minus first appended actual presentedTime, rounded to nanoseconds; no fixed-frame-rate resampling",
        @"windowArmed": @(_armed), @"windowStarted": @(_begun), @"windowStart": _windowStart ?: (id)NSNull.null,
        @"windowStartRule": _armed ? @"First observed copied positive, fixed once" : @"Caller-provided Media time",
        @"armedHostTicks": _armed ? @(_armedHostTicks) : (id)NSNull.null,
        @"armedMediaTime": _armed ? @(_armedMediaTime) : (id)NSNull.null,
        @"beginHostTicks": @(_beginHostTicks), @"finishHostTicks": @(_finishHostTicks), @"finishWorkerHostTicks": @(_finishWorkerTicks),
        @"windowStartMediaTime": @(_beginMediaTime), @"windowEndMediaTimeExclusive": @(_endMediaTime),
        @"windowSeconds": @(std::max(0.0, _endMediaTime - _beginMediaTime)),
        @"finishMediaTime": std::isfinite(_finishMediaTime) ? @(_finishMediaTime) : (id)NSNull.null,
        @"requestedSeconds": @(_requestedSeconds),
        @"firstAppendedPresentedTime": std::isfinite(_firstEncodedPresentedTime) ? @(_firstEncodedPresentedTime) : (id)NSNull.null,
        @"lastAppendedPresentedTime": std::isfinite(_lastEncodedPresentedTime) ? @(_lastEncodedPresentedTime) : (id)NSNull.null,
        @"observedFrames": @(_recordCount), @"appendedFrames": @(_appended), @"frameResultCounts": counts,
        @"pendingLimit": @(PendingLimit), @"maximumPending": @(_maximumPending), @"pendingAtFinish": @(_pending),
        @"privatePoolAllocationLimit": @(PoolLimit), @"ledgerCapacity": @(LedgerCapacity), @"ledgerOverflow": @(_ledgerOverflow),
        @"outsideMediaWindowExcluded": @(_outsideWindow), @"invalidPresentedTimeExcluded": @(_invalidPresentedTime),
        @"prepareMs": @(_prepareMs), @"finishRequestToReportMs": [NSNumber numberWithDouble:_finishHostTicks ? [self millisecondsSince:_finishHostTicks] : 0],
        @"callbackSubmitMs": Distribution(callback), @"workerQueueMs": Distribution(queue),
        @"pixelTransferWallMs": Distribution(transfer), @"appendCallWallMs": Distribution(append),
        @"writerStatus": @(_writer.status), @"fileBytes": file[NSFileSize] ?: @0,
        @"scope": @"Separate quality-only window. Positive-presented buffer association is not physical-screen or human acceptance. Compression and recorder overhead remain part of this material; its cadence is analyzed separately from the formal performance window.",
        @"frames": ledger
    } mutableCopy];
    report[@"renderCopies"] = renderCopies;
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
    if (!json || ![json writeToURL:_sidecarURL options:NSDataWritingWithoutOverwriting error:&error]) {
        report[@"status"] = @"incomplete";
        report[@"sidecarError"] = error.localizedDescription ?: @"Could not write recorder sidecar";
        if (!failure) report[@"firstFailure"] = report[@"sidecarError"];
    }
    NSDictionary *finished = [report copy];
    dispatch_async(dispatch_get_main_queue(), ^{ completion(finished); });
}
@end

NS_ASSUME_NONNULL_END
