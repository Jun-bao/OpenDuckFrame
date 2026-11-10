#pragma once

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>
#import <VideoToolbox/VideoToolbox.h>
#include "SPRateSchedule.hpp"
#include <array>
#include <memory>
#include <mach/mach_time.h>

static void SPForceSDRAttachments(CVPixelBufferRef buffer) {
    if (!buffer) return;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceITUR_709);
    if (space) {
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, space, kCVAttachmentMode_ShouldPropagate);
        CFRelease(space);
    }
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
    OSType format = CVPixelBufferGetPixelFormatType(buffer);
    if (format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                              kCVAttachmentMode_ShouldPropagate);
    }
    CVBufferRemoveAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey);
    CVBufferRemoveAttachment(buffer, kCVImageBufferContentLightLevelInfoKey);
    CVBufferRemoveAttachment(buffer, kCVImageBufferAmbientViewingEnvironmentKey);
}

static BOOL SPBufferIsHDR(CVPixelBufferRef buffer) {
    if (!buffer) return NO;
    OSType format = CVPixelBufferGetPixelFormatType(buffer);
    if (format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
        format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange ||
        format == kCVPixelFormatType_64RGBAHalf ||
        format == kCVPixelFormatType_ARGB2101010LEPacked) {
        return YES;
    }
    CFTypeRef transfer = CVBufferGetAttachment(buffer, kCVImageBufferTransferFunctionKey, NULL);
    if (transfer &&
        (CFEqual(transfer, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) ||
         CFEqual(transfer, kCVImageBufferTransferFunction_ITU_R_2100_HLG))) {
        return YES;
    }
    if (CVBufferGetAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey, NULL)) return YES;
    return NO;
}

static CVPixelBufferRef SPCreateBuffer(int width, int height, OSType format) {
    NSDictionary *attrs = @{
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    CVPixelBufferRef buffer = NULL;
    CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
                                          (__bridge CFDictionaryRef)attrs, &buffer);
    if (result != kCVReturnSuccess) return NULL;
    return buffer;
}

// Both callers use the original conversion/session parameters and attachments.
// A nonzero transfer bracket covers only the original VT API call.
static CVPixelBufferRef SPAirTransferWithSession(VTPixelTransferSessionRef session, CVPixelBufferRef source,
    OSType format, BOOL preserveSourceAttachments, int64_t &began, int64_t &ended, OSStatus &status) {
    began = ended = 0; status = noErr;
    if (!source || !session) { status = kCVReturnInvalidArgument; return NULL; }
    if (CVPixelBufferGetPixelFormatType(source) == format && !SPBufferIsHDR(source)) {
        CVPixelBufferRetain(source);
        return source;
    }
    int width = (int)CVPixelBufferGetWidth(source) & ~1;
    int height = (int)CVPixelBufferGetHeight(source) & ~1;
    if (width < 2 || height < 2) { status = kCVReturnInvalidSize; return NULL; }
    CVPixelBufferRef destination = SPCreateBuffer(width, height, format);
    if (!destination) { status = kCVReturnAllocationFailed; return NULL; }
    if (!preserveSourceAttachments) SPForceSDRAttachments(source);
    SPForceSDRAttachments(destination);
    began = (int64_t)mach_absolute_time();
    status = VTPixelTransferSessionTransferImage(session, source, destination);
    ended = (int64_t)mach_absolute_time();
    if (status != noErr) { CVPixelBufferRelease(destination); return NULL; }
    SPForceSDRAttachments(destination);
    return destination;
}

namespace spAirSourceConversion {

struct Context {
    uint64_t generation = 0, config = 0, measurement = 0, clock = 0, cancellation = 0;
};
enum class StaleReason { none, stopped, generation, config, measurement, clock, cancellation, mode };
inline StaleReason staleReason(Context captured, Context current, bool stopped) {
    if (stopped) return StaleReason::stopped;
    if (captured.generation != current.generation) return StaleReason::generation;
    if (captured.config != current.config) return StaleReason::config;
    if (captured.measurement != current.measurement) return StaleReason::measurement;
    if (captured.clock != current.clock) return StaleReason::clock;
    if (captured.cancellation != current.cancellation) return StaleReason::cancellation;
    return StaleReason::none;
}
struct Job {
    explicit Job(CVPixelBufferRef input) : source(input ? CVPixelBufferRetain(input) : NULL) {}
    ~Job() { if (source) CVPixelBufferRelease(source); if (output) CVPixelBufferRelease(output); }
    CVPixelBufferRef source = NULL, output = NULL;
    Context context{};
    sp::SPRational pts{}, anchorPTS{};
    uint64_t identity = 0, sourceID = 0, bytes = 0;
    int64_t captureHost = 0, geometryHost = 0, targetHost = 0, delayHost = 0, anchorHost = 0, sourceIntervalHost = 0;
    int64_t requestedHost = 0, workerBeginHost = 0, workerEndHost = 0, processorReturnHost = 0, transferBeginHost = 0, transferEndHost = 0;
    OSStatus status = noErr;
    bool held = false, basisKnown = false, traceEnabled = false, started = false;
    __strong void (^recordDimensions)(int width, int height) = nil;
};
using JobPtr = std::shared_ptr<Job>;

// Owned only by the native serial queue. Cancellation never clears the physical
// active job. Its actual completion is the only place that returns that slot.
struct State {
    JobPtr active;
    std::array<JobPtr, 2> waiting{};
    size_t waitingCount = 0;
    uint64_t cancellation = 0, nextIdentity = 0, ownedBytes = 0;
    uint64_t admitted = 0, completed = 0, canceledWaiting = 0, capacitySyncFallbacks = 0;
    bool admit(const JobPtr &job, uint64_t byteLimit) {
        if ((active && waitingCount == waiting.size()) || job->bytes > byteLimit || ownedBytes > byteLimit - job->bytes) {
            ++capacitySyncFallbacks;
            return false;
        }
        job->identity = ++nextIdentity; job->context.cancellation = cancellation;
        ownedBytes += job->bytes; ++admitted;
        if (active) waiting[waitingCount++] = job;
        else active = job;
        return true;
    }
    size_t cancel() {
        ++cancellation;
        const size_t count = waitingCount;
        for (size_t index = 0; index < waitingCount; ++index) {
            ownedBytes -= waiting[index]->bytes;
            waiting[index].reset();
        }
        waitingCount = 0; canceledWaiting += count;
        return count;
    }
    bool finish(const JobPtr &job) {
        if (active != job) return false;
        ownedBytes -= job->bytes; active.reset(); ++completed;
        if (waitingCount) {
            active = waiting[0];
            for (size_t index = 1; index < waitingCount; ++index) waiting[index - 1] = std::move(waiting[index]);
            waiting[--waitingCount].reset();
        }
        return true;
    }
    size_t outstanding() const { return (active ? 1 : 0) + waitingCount; }
};

} // namespace spAirSourceConversion

@interface SPAirSourceConversionWorker : NSObject
- (void)convert:(const spAirSourceConversion::JobPtr &)job completion:(dispatch_block_t)completion;
- (void)performConversion:(const spAirSourceConversion::JobPtr &)job;
@end
@implementation SPAirSourceConversionWorker {
    dispatch_queue_t _queue;
    VTPixelTransferSessionRef _session;
}
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _queue = dispatch_queue_create("app.openduckframe.air-source-conversion", dispatch_queue_attr_make_with_autorelease_frequency(
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0), DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM));
    return self;
}
- (void)dealloc {
    VTPixelTransferSessionRef session = _session;
    if (session) dispatch_async(_queue, ^{ CFRelease(session); });
}
- (void)performConversion:(const spAirSourceConversion::JobPtr &)job {
    if (!_session) job->status = VTPixelTransferSessionCreate(kCFAllocatorDefault, &_session);
    if (_session) job->output = SPAirTransferWithSession(_session, job->source, kCVPixelFormatType_32BGRA, YES,
        job->transferBeginHost, job->transferEndHost, job->status);
}
- (void)convert:(const spAirSourceConversion::JobPtr &)job completion:(dispatch_block_t)completion {
    auto retained = job;
    dispatch_async(_queue, ^{
        if (retained->traceEnabled) retained->workerBeginHost = (int64_t)mach_absolute_time();
        [self performConversion:retained];
        if (retained->output && retained->recordDimensions)
            retained->recordDimensions((int)CVPixelBufferGetWidth(retained->output), (int)CVPixelBufferGetHeight(retained->output));
        if (retained->traceEnabled) retained->workerEndHost = (int64_t)mach_absolute_time();
        if (retained->source) { CVPixelBufferRelease(retained->source); retained->source = NULL; }
        completion();
    });
}
@end
