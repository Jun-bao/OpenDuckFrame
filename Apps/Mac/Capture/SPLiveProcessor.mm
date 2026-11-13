#import "SPLiveProcessor.h"

#import "SPFRCEngine.h"
#import "SPFrameBudgetMetal.h"
#import "SPLowLatencyEngine.h"
#import "SPAppleLowLatencySR.h"
#import "SPAppleVideoSR.h"
#import "SPAnime4K.h"
#import "SPArtCNNSR.h"
#import "SPRealCUGAN.h"
#import "SPDistilDRBA.h"
#import "SPRifeBridge.h"
#include "SPAirRobustSourceLead.hpp"
#include "SPAirWindowOptimization.hpp"
#include "SPAirMeasurementTrace.hpp"
#include "SPAirSourceConversion.hpp"
#include "SPAirDisplayPolicyB.hpp"
#import "SPRateSchedule.hpp"
#import "SPLiveDisplayQueue.h"
#import "SPRifePairAffineClock.hpp"
#import "SPFPSMeter.hpp"
#import "SPPresentationBudget.hpp"
#import "SPRateBudget.hpp"
#import "SPFRCBudgetPolicy.hpp"
#import "SPLiveHeldPolicy.hpp"
#import "SPPresentationOrder.hpp"
#import "SPPresentationGeometry.hpp"
#import "SPOutputGeometry.hpp"
#import "SPSharedGeometry.hpp"
#import "SPSRResizePolicy.hpp"
#import "SPLivePixelProbeCV.h"
#if ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC
#include "SPAirFusedPresentation.hpp"
#endif
#if ODF_AIR_BETA_DIAGNOSTIC || ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
#include "SPAirBetaSizing.hpp"
#endif
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
#import "SPPresentedVideoRecorder.h"
#endif

#import <CoreMedia/CoreMedia.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <VideoToolbox/VideoToolbox.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach_time.h>
#import <sys/qos.h>
#import <sys/sysctl.h>

#include <cstring>
#include <cfloat>
#include <atomic>
#include <array>
#include <algorithm>
#include <pthread.h>
#include <cmath>
#include <deque>
#include <mutex>
#include <memory>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include <type_traits>

static BOOL SPLiveIsArtCNNScaleEngine(SPLiveScaleEngine engine) {
    return engine == SPLiveScaleArtCNN16 || engine == SPLiveScaleArtCNN32;
}

static BOOL SPLiveIsNative2xScaleEngine(SPLiveScaleEngine engine) {
    return engine == SPLiveScaleAnime4K || engine == SPLiveScaleRealCUGAN || SPLiveIsArtCNNScaleEngine(engine);
}

// Private live-budget bridge entry point; the public adapter API is unchanged.
@interface SPRifeBridge (SPRateBudgetProbe)
- (void)resetLiveCacheForRateBudgetProbe;
- (NSDictionary *)airBetaMeasurementReadiness;
@end

extern "C" int spRunRateScheduleTests(void);

static const void *SPLiveQueueKey = &SPLiveQueueKey;

static int64_t SPHostNow(void) { return (int64_t)mach_absolute_time(); }

static bool SPAirCadenceCausalTraceRequested() {
#if defined(ODF_AIR_PRESENTATION_GUARD_DIAGNOSTIC) && ODF_AIR_PRESENTATION_GUARD_DIAGNOSTIC == 1
    const char *value = getenv("ODF_AIR_CADENCE_CAUSAL_TRACE");
    return value && strcmp(value, "1") == 0;
#else
    return false;
#endif
}

static bool SPAirBetaSessionRecorderRequested() {
#if ODF_AIR_BETA_DIAGNOSTIC
    const char *value = getenv("ODF_AIR_BETA_SESSION_RECORDER");
    return value && strcmp(value, "1") == 0;
#else
    return false;
#endif
}

static bool SPAirRobustSourceLeadRequested() {
#if ODF_AIR_BETA_DIAGNOSTIC
    const char *value = getenv("ODF_AIR_ROBUST_SOURCE_LEAD_DIAGNOSTIC");
    return value && strcmp(value, "1") == 0;
#else
    return false;
#endif
}

static bool SPAirFullMeasurementTraceRequested() {
#if ODF_AIR_BETA_DIAGNOSTIC && ODF_AIR_PRESENTATION_GUARD_DIAGNOSTIC
    return SPAirCadenceCausalTraceRequested() &&
        strcmp(getenv("ODF_AIR_BETA_CAPTURE_DIAGNOSTIC") ?: "", "1") == 0;
#else
    return false;
#endif
}

struct SPAirPresentedObservationScope {
    std::atomic<uint64_t> *pending;
    explicit SPAirPresentedObservationScope(std::atomic<uint64_t> *counter) : pending(counter) {
        if (pending) pending->fetch_add(1, std::memory_order_acq_rel);
    }
    ~SPAirPresentedObservationScope() {
        if (pending) pending->fetch_sub(1, std::memory_order_release);
    }
};

// Preallocated POD only. Writers use existing mutex/serial-queue ownership, or
// the explicitly checked main-run-loop-only callback contract below. This
// container adds no synchronization or hot-path IO.
template<class T, size_t Capacity> struct SPAirCausalRing {
    static constexpr size_t capacity = Capacity;
    std::array<T, Capacity> records{};
    uint64_t total = 0, postSealAttempts = 0;
    bool sealed = false;
    void append(T event) {
        if (sealed) { ++postSealAttempts; return; }
        event.sequence = ++total; records[(total - 1) % Capacity] = event;
    }
    void copy(std::vector<T> &out) const {
        const uint64_t count = std::min(total, (uint64_t)Capacity);
        for (uint64_t i = total - count; i < total; ++i) out.push_back(records[i % Capacity]);
    }
};
struct SPAirCurrentStatsEvent {
    uint64_t sequence, beginHostTicks, endHostTicks, threadID;
};
using SPAirCurrentStatsRing = SPAirCausalRing<SPAirCurrentStatsEvent, 16384>;

enum class SPAirFrameKind : uint8_t { admitted, selected, discarded, rejected, slotExpired, positivePresented, zeroPresented, failureNotification, configurationMarker };
enum class SPAirFrameReason : uint8_t { none, superseded, configuration, stalePTS, expired, generation, epoch, clock, invisible, deadline, texture, pipeline, command, gpu, notPresented, queueFull, invalidPTS, duplicatePTS, other };
enum class SPAirFrameStage : uint8_t { admission, selection, cleanup, finalCheck, visibilityCleanup, callback };
struct SPAirFrameEvent {
    uint64_t sequence, frameID, generation, config, epoch, clock, slotToken, replacementFrameID;
    int64_t hostTicks, captureHostTicks, enqueueHostTicks, requestStartHostTicks, logicalTargetHostTicks;
    int64_t slotDisplayTimeMediaNs, presentedTimeMediaNs, callbackHostTicks;
    SPAirFrameKind kind; SPAirFrameReason reason; SPAirFrameStage stage;
    bool synthetic, typeKnown, counts, countsKnown, callbackCountsKnown, redraw, hasSlot, hasReplacement, replacementSynthetic, replacementCounts, output;
    uint64_t previousConfig, previousEpoch;
    char reasonText[72];
};
struct SPAirBudgetEvent {
    uint64_t sequence, generation, configBefore, configAfter, epochBefore, epochAfter;
    uint64_t freshSamples, planned, dropped, probeToken;
    int64_t hostTicks;
    double policyMediaTimeSeconds, contentFPS, medianTaskMs, phaseCostBeforeMs, phaseCostAfterMs, refreshHz;
    int inflight, requested, appliedBefore, appliedAfter, budgetBefore, budgetAfter, displayCap;
    uint32_t gateMask; // 1 disabled,2 engine,4 session,8 stopped,16 inflight,32 probe,64 fresh<8,128 unchanged/persistence
    sp::RateBudgetLimit limit;
    bool suspend, inputAvailable, policyCalled, nativeSuspended;
};
static_assert(std::is_pod<SPAirFrameEvent>::value && std::is_pod<SPAirBudgetEvent>::value, "causal trace records must remain POD");
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
using SPAirFrameRing = SPAirCausalRing<SPAirFrameEvent, 262144>;
using SPAirBudgetRing = SPAirCausalRing<SPAirBudgetEvent, 65536>;
#else
using SPAirFrameRing = SPAirCausalRing<SPAirFrameEvent, 16384>;
using SPAirBudgetRing = SPAirCausalRing<SPAirBudgetEvent, 8192>;
#endif

enum class SPAirSlotCallbackOutcome : uint8_t { createdToken, busy, entryRejected };
enum class SPAirSlotEntryReject : uint8_t { none, wrongLink, invisible, noGeneration, invalidDeadline, invalidDisplayTime, displayNotAfterDeadline, deadlineReached };
enum class SPAirSlotOrigin : uint8_t { timerAttempt, callbackReplaced, callbackContextRetired, visibilityRetired, contextCleanupRetired };
struct SPAirSlotCallbackEvent {
    uint64_t sequence, generation, config, epoch, clock, createdToken, observedToken;
    int64_t entryHostTicks, outcomeHostTicks, entryMediaNs;
    double targetTimestampMediaSeconds, targetPresentationTimestampMediaSeconds;
    SPAirSlotCallbackOutcome outcome;
    SPAirSlotEntryReject reject;
    bool contextUnderPresentationMutex;
};
struct SPAirSlotConsumeEvent {
    uint64_t sequence, token, observedToken, frameID, generation, config, epoch, clock;
    uint64_t currentGeneration, currentConfig, currentEpoch, currentClock;
    int64_t entryHostTicks, recordHostTicks, handlerEntryMediaNs, lockAcquiredMediaNs, plannedSelectionMediaNs, deadlineMediaNs, displayTimeMediaNs;
    uint8_t outcome;
    SPAirSlotOrigin origin;
    bool terminal;
    uint32_t prematureWakeCount;
    bool prematureWakeCountSaturated;
};
struct SPAirSlotSnapshot {
    int64_t sampleHostTicks, deadlineMediaNs, displayTimeMediaNs;
    uint64_t token, generation, config, epoch, clock;
    bool hasPending;
};
static_assert(std::is_pod<SPAirSlotCallbackEvent>::value && std::is_pod<SPAirSlotConsumeEvent>::value, "slot trace records must remain POD");

// One immutable terminal row per token. Repeated early wakes update only the
// token's bounded observation count under the existing presentation mutex.
template<size_t Capacity> struct SPAirTokenConsumeRing {
    static constexpr size_t capacity = Capacity;
    std::array<SPAirSlotConsumeEvent, Capacity> records{};
    uint64_t total = 0, observations = 0, overwrittenTokens = 0;
    uint64_t invalidTokens = 0, repeatedAfterTerminal = 0, postSealAttempts = 0;
    bool sealed = false;
    void append(SPAirSlotConsumeEvent event) {
        if (sealed) { ++postSealAttempts; return; }
        ++observations;
        if (!event.token) { ++invalidTokens; return; }
        auto &record = records[(event.token - 1) % Capacity];
        if (record.token == event.token) {
            if (record.terminal) { ++repeatedAfterTerminal; return; }
            event.sequence = record.sequence;
            event.prematureWakeCount = record.prematureWakeCount;
            event.prematureWakeCountSaturated = record.prematureWakeCountSaturated;
        } else {
            if (record.token) ++overwrittenTokens;
            event.sequence = ++total;
        }
        if (event.outcome == (uint8_t)2) {
            if (event.prematureWakeCount == UINT32_MAX) event.prematureWakeCountSaturated = true;
            else ++event.prematureWakeCount;
        }
        record = event;
    }
    void copy(std::vector<SPAirSlotConsumeEvent> &out) const {
        for (const auto &record : records) if (record.token) out.push_back(record);
        std::sort(out.begin(), out.end(), [](const auto &a, const auto &b) { return a.sequence < b.sequence; });
    }
};

#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
using SPAirSlotCallbackRing = SPAirCausalRing<SPAirSlotCallbackEvent, 131072>;
using SPAirSlotConsumeRing = SPAirTokenConsumeRing<131072>;
#else
using SPAirSlotCallbackRing = SPAirCausalRing<SPAirSlotCallbackEvent, 16384>;
using SPAirSlotConsumeRing = SPAirCausalRing<SPAirSlotConsumeEvent, 16384>;
#endif

static SPAirFrameReason SPAirReason(NSString *value) {
    if ([value isEqualToString:@"display-slot-superseded"]) return SPAirFrameReason::superseded;
    if ([value isEqualToString:@"configuration"]) return SPAirFrameReason::configuration;
    if ([value isEqualToString:@"display-stale-pts"]) return SPAirFrameReason::stalePTS;
    if ([value isEqualToString:@"generation"]) return SPAirFrameReason::generation;
    if ([value isEqualToString:@"epoch"]) return SPAirFrameReason::epoch;
    if ([value isEqualToString:@"clock-retired"]) return SPAirFrameReason::clock;
    if ([value isEqualToString:@"display-invisible"]) return SPAirFrameReason::invisible;
    if ([value isEqualToString:@"display-submit-deadline"]) return SPAirFrameReason::deadline;
    if ([value isEqualToString:@"texture"]) return SPAirFrameReason::texture;
    if ([value isEqualToString:@"pipeline"]) return SPAirFrameReason::pipeline;
    if ([value isEqualToString:@"command"]) return SPAirFrameReason::command;
    if ([value isEqualToString:@"gpu"]) return SPAirFrameReason::gpu;
    if ([value isEqualToString:@"display-not-presented"]) return SPAirFrameReason::notPresented;
    return SPAirFrameReason::other;
}

static int64_t SPHostToNs(int64_t host) {
    static mach_timebase_info_data_t info;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&info); });
    return host * (int64_t)info.numer / (int64_t)info.denom;
}

static const uint64_t SPQueueByteBudget = 160ull << 20;
static std::atomic<uint64_t> SPR8NextJobID{1};
static BOOL SPR8Enabled(void) {
    NSArray<NSString *> *a = NSProcessInfo.processInfo.arguments;
    NSUInteger p = [a indexOfObject:@"--odf-isolated-profile"], l = [a indexOfObject:@"--odf-live-log"];
    return [a containsObject:@"--odf-r8-quality-diagnostics"] && [a containsObject:@"--odf-pixel-diagnostics"] &&
        p != NSNotFound && p + 1 < a.count && [a[p + 1] hasPrefix:@"/"] &&
        l != NSNotFound && l + 1 < a.count && [a[l + 1] hasPrefix:@"/"];
}
static BOOL SPR8FixtureEnabled(void) {
    return SPR8Enabled() && [NSProcessInfo.processInfo.arguments containsObject:@"--odf-r8-fixture-diagnostics"];
}
static BOOL SPRifePairAffineClockEnabled(void) {
    return SPR8Enabled() && [NSProcessInfo.processInfo.arguments containsObject:@"--odf-rife-pair-affine-clock"];
}
static int SPR8DecodeFixture(CVPixelBufferRef buffer) {
    if (!buffer) return -1;
    OSType format = CVPixelBufferGetPixelFormatType(buffer);
    bool planar = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    if (!planar && format != kCVPixelFormatType_32BGRA) return -1;
    if (CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return -1;
    size_t width=CVPixelBufferGetWidth(buffer), height=CVPixelBufferGetHeight(buffer);
    auto *base=(uint8_t *)(planar ? CVPixelBufferGetBaseAddressOfPlane(buffer,0) : CVPixelBufferGetBaseAddress(buffer));
    size_t stride=planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer,0) : CVPixelBufferGetBytesPerRow(buffer);
    int result=-1; const bool marker[8]={true,true,false,true,false,false,true,true};
    if (base && width>=128 && height>=80) for (int row=0; row<=70 && result<0; ++row) {
        size_t y=std::min(height-1,(size_t)(height*(0.02+row*0.004))); bool bits[64]={}; bool valid=true;
        for (int c=0;c<64;++c) {
            size_t x=std::min(width-1,(size_t)(width*(0.08+0.84*(c+0.5)/64)));
            auto *p=base+y*stride+x*(planar?1:4);
            int level=planar?p[0]:(p[0]+p[1]+p[2])/3;
            if (level>175) bits[c]=true; else if (level<80) bits[c]=false; else { valid=false; break; }
        }
        if (!valid) continue;
        for (int i=0;i<8;++i) if (bits[i]!=marker[i] || bits[56+i]!=marker[7-i]) { valid=false; break; }
        uint32_t frame=0;
        if (valid) for (int i=0;i<24;++i) {
            if (bits[8+i]==bits[32+i]) { valid=false; break; }
            frame=(frame<<1)|(bits[8+i]?1:0);
        }
        if (valid) result=(int)frame;
    }
    CVPixelBufferUnlockBaseAddress(buffer,kCVPixelBufferLock_ReadOnly);
    return result;
}

// Full-buffer coordinates, only used for the explicitly selected fixture.
// Two of three orange-chroma votes are required at each sampled x.
static NSDictionary *SPR8FixtureMotion(CVPixelBufferRef buffer) {
    uint64_t started=clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    size_t width=buffer ? CVPixelBufferGetWidth(buffer) : 0, height=buffer ? CVPixelBufferGetHeight(buffer) : 0;
    auto make = ^NSDictionary *(BOOL valid, double centroid, int first, int last, int active, NSString *reason) {
        return @{ @"valid": @(valid), @"centroidX": @(centroid), @"centroidNorm": @(valid ? centroid/(double)width : -1),
            @"firstX": @(first), @"lastX": @(last), @"activeColumns": @(active), @"bufferWidth": @(width),
            @"sampleDurationNs": @(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)-started), @"reason": reason,
            @"rows": @[@0.41,@0.43,@0.45], @"coordinateSpace": @"full_pixel_buffer", @"metric": @"orange_chroma_weighted_centroid" };
    };
    if (!buffer) return make(NO,-1,-1,-1,0,@"unsupported");
    OSType format=CVPixelBufferGetPixelFormatType(buffer);
    bool planar=format==kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format==kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    if ((!planar && format!=kCVPixelFormatType_32BGRA) || width<128 || height<80) return make(NO,-1,-1,-1,0,@"unsupported");
    if (CVPixelBufferLockBaseAddress(buffer,kCVPixelBufferLock_ReadOnly)!=kCVReturnSuccess) return make(NO,-1,-1,-1,0,@"lock_failed");
    auto *base=(uint8_t *)(planar ? CVPixelBufferGetBaseAddressOfPlane(buffer,0) : CVPixelBufferGetBaseAddress(buffer));
    auto *uv=(uint8_t *)(planar ? CVPixelBufferGetBaseAddressOfPlane(buffer,1) : nullptr);
    size_t stride=planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer,0) : CVPixelBufferGetBytesPerRow(buffer);
    size_t uvStride=planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer,1) : 0;
    if (!base || (planar && !uv)) {
        CVPixelBufferUnlockBaseAddress(buffer,kCVPixelBufferLock_ReadOnly);
        return make(NO,-1,-1,-1,0,base ? @"missing_chroma" : @"missing_base");
    }
    size_t ys[3]={(size_t)(height*0.41),(size_t)(height*0.43),(size_t)(height*0.45)};
    double sum=0, weighted=0; int first=(int)width,last=-1,active=0;
    for (size_t x=0;x<width;++x) {
        int votes=0,strength=0;
        for (size_t y : ys) {
            int score=0;
            if (planar) {
                size_t offset=(y/2)*uvStride+(x/2)*2;
                if (base[y*stride+x]>35) score=std::max(0,std::min((int)uv[offset+1]-128,128-(int)uv[offset]));
            } else {
                auto *p=base+y*stride+x*4; int b=p[0],g=p[1],r=p[2];
                if (r>50) score=std::max(0,std::min(r-g,g-b));
            }
            if (score>=8) { ++votes; strength+=score; }
        }
        if (votes>=2) { first=std::min(first,(int)x);last=(int)x;++active;sum+=strength;weighted+=(double)strength*x; }
    }
    CVPixelBufferUnlockBaseAddress(buffer,kCVPixelBufferLock_ReadOnly);
    int span=last>=first ? last-first+1 : 0;
    bool valid=span>=std::max(8,(int)(width/100)) && span<=(int)(width/4) && active*100>=span*65 && sum>0;
    return make(valid,valid?weighted/sum:-1,valid?first:-1,valid?last:-1,active,valid?@"ok":@"no_coherent_orange_stripe");
}

static int SPR8Option(NSString *flag, int fallback, NSArray<NSNumber *> *allowed) {
    if (!SPR8Enabled()) return fallback;
    NSArray<NSString *> *a = NSProcessInfo.processInfo.arguments;
    NSUInteger i = [a indexOfObject:flag];
    if (i == NSNotFound || i + 1 >= a.count) return fallback;
    NSString *value = a[i + 1];
    for (NSNumber *n in allowed) if ([value isEqualToString:n.stringValue]) return n.intValue;
    return fallback;
}
static const double SPInteractiveCapSec = 0.090;
static const double SPQualityCapSec = 0.250;

static void SPPushSample(std::vector<int64_t> &samples, int64_t value) {
    samples.push_back(value);
    if (samples.size() > 40000) samples.erase(samples.begin(), samples.begin() + 8000);
}

static double SPPercentileMs(std::vector<int64_t> samples) {
    if (samples.empty()) return -1;
    std::sort(samples.begin(), samples.end());
    size_t index = (samples.size() - 1) * 95 / 100;
    return (double)samples[index] / 1e6;
}

// Statistics use a fixed recent window. Control-policy percentiles retain
// their existing full-history helper and sample storage.
static double SPStatsPercentileMs(const std::vector<int64_t> &samples) {
    if (samples.empty()) return -1;
    const size_t count = std::min(samples.size(), size_t{1024});
    std::vector<int64_t> recent(samples.end() - count, samples.end());
    const size_t index = (recent.size() - 1) * 95 / 100;
    std::nth_element(recent.begin(), recent.begin() + index, recent.end());
    return (double)recent[index] / 1e6;
}

// R7 diagnostics are enabled only with both isolated profile and log paths.
static BOOL SPR7Passthrough(void) {
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    NSUInteger p = [args indexOfObject:@"--odf-isolated-profile"];
    NSUInteger l = [args indexOfObject:@"--odf-live-log"];
    return [args containsObject:@"--odf-r7-passthrough"] && [args containsObject:@"--odf-pixel-diagnostics"] &&
        p != NSNotFound && p + 1 < args.count && [args[p + 1] hasPrefix:@"/"] &&
        l != NSNotFound && l + 1 < args.count && [args[l + 1] hasPrefix:@"/"];
}

static void SPWaitUntilHost(int64_t deadline) {
    for (;;) {
        int64_t now = SPHostNow();
        if (now >= deadline) return;
        int64_t ns = SPHostToNs(deadline - now);
        if (ns > 2500000) usleep((useconds_t)((ns - 1200000) / 1000));
        else {
            while (SPHostNow() < deadline) {}
            return;
        }
    }
}

// Used only by short, explicitly timed headless probes. This avoids sleep
// coalescing; the probes still record actual delivery timestamps and fail on
// missed pacing rather than treating this request as proof of a frame rate.
static void SPProbeSpinUntilHost(int64_t deadline) {
    while (SPHostNow() < deadline) {}
}

static NSError *SPLiveError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"app.openduckframe.live" code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @""}];
}

BOOL SPAirBetaEnabled(void) {
#if ODF_AIR_BETA_DIAGNOSTIC
    static const BOOL enabled = [NSBundle.mainBundle.infoDictionary[@"ODFAirBeta"] boolValue] &&
        strcmp(getenv("ODF_AIR_BETA_DIAGNOSTIC") ?: "", "1") == 0;
    return enabled;
#else
    return NO;
#endif
}

NSSize SPAirBetaProcessingSize(int width, int height) {
#if ODF_AIR_BETA_DIAGNOSTIC || ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
    const auto choice = sp::airBetaSize(width, height);
    if (choice.valid) return NSMakeSize(choice.processingWidth, choice.processingHeight);
#endif
    return NSZeroSize;
}

NSString *SPAirBetaSizingReason(int width, int height) {
#if ODF_AIR_BETA_DIAGNOSTIC || ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
    switch (sp::airBetaSize(width, height).failure) {
        case sp::AirBetaSizeFailure::none: return nil;
        case sp::AirBetaSizeFailure::invalidCapture: return @"采集宽高须为至少2像素的偶数，现以原帧播放";
        case sp::AirBetaSizeFailure::outsideEnvelope: return @"窗口超过2648×1668像素的验证范围，现以原帧播放";
        case sp::AirBetaSizeFailure::invalidProcessing: return @"处理尺寸未能满足面积与偶数约束，现以原帧播放";
        case sp::AirBetaSizeFailure::paddingExceeded: return @"模型补齐尺寸超过2048×1280，现以原帧播放";
    }
#endif
    return @"Air实验档未启用";
}

static NSString *SPAirHardwareModel() {
    static NSString *model;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        char value[128] = {}; size_t length = sizeof(value);
        model = sysctlbyname("hw.model", value, &length, nullptr, 0) == 0 ?
            [NSString stringWithUTF8String:value] : @"";
    });
    return model;
}





#if ODF_AIR_BETA_DIAGNOSTIC || ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
static NSString *SPAirBetaFourCC(OSType format) {
    const char bytes[] = {(char)(format >> 24), (char)(format >> 16), (char)(format >> 8), (char)format};
    return [[NSString alloc] initWithBytes:bytes length:4 encoding:NSASCIIStringEncoding] ?: @"未知";
}
static NSString *SPAirBetaFormatReason(CVPixelBufferRef buffer) {
    if (SPBufferIsHDR(buffer)) return @"当前为HDR或10位采集，现以原帧播放";
    CFTypeRef primaries = CVBufferGetAttachment(buffer, kCVImageBufferColorPrimariesKey, NULL);
    CFTypeRef space = CVBufferGetAttachment(buffer, kCVImageBufferCGColorSpaceKey, NULL);
    if ((primaries && (CFEqual(primaries, kCVImageBufferColorPrimaries_P3_D65) || CFEqual(primaries, kCVImageBufferColorPrimaries_DCI_P3))) ||
        (space && CFGetTypeID(space) == CGColorSpaceGetTypeID() && CGColorSpaceIsWideGamutRGB((CGColorSpaceRef)space)))
        return @"当前为P3或宽色域采集，现以原帧播放";
    const OSType format = CVPixelBufferGetPixelFormatType(buffer);
    if (format != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        return [NSString stringWithFormat:@"采集格式为%@，窗口优化只支持420v BT.709 SDR，现以原帧播放", SPAirBetaFourCC(format)];
    CFTypeRef matrix = CVBufferGetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, NULL);
    CFTypeRef transfer = CVBufferGetAttachment(buffer, kCVImageBufferTransferFunctionKey, NULL);
    if (!matrix || !primaries || !transfer || !CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2) ||
        !CFEqual(primaries, kCVImageBufferColorPrimaries_ITU_R_709_2) || !CFEqual(transfer, kCVImageBufferTransferFunction_ITU_R_709_2))
        return @"采集未提供完整BT.709 SDR标记，现以原帧播放";
    return nil;
}
#endif



static void SPSampleLuma(CVPixelBufferRef buffer, uint8_t *out, int count) {
    memset(out, 0, (size_t)count);
    if (!buffer || count <= 0) return;
    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    OSType format = CVPixelBufferGetPixelFormatType(buffer);
    size_t width = CVPixelBufferGetWidth(buffer);
    size_t height = CVPixelBufferGetHeight(buffer);
    int cols = 8, rows = count / 8;
    if (rows < 1) rows = 1;
    if (format == kCVPixelFormatType_32BGRA) {
        uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(buffer);
        size_t stride = CVPixelBufferGetBytesPerRow(buffer);
        int index = 0;
        for (int y = 0; y < rows && index < count; ++y) {
            size_t py = (size_t)((y + 0.5) * height / rows);
            if (py >= height) py = height - 1;
            uint8_t *row = base + py * stride;
            for (int x = 0; x < cols && index < count; ++x) {
                size_t px = (size_t)((x + 0.5) * width / cols);
                if (px >= width) px = width - 1;
                uint8_t *p = row + px * 4;
                out[index++] = (uint8_t)((54 * p[2] + 183 * p[1] + 19 * p[0]) >> 8);
            }
        }
    } else if (CVPixelBufferIsPlanar(buffer) && CVPixelBufferGetPlaneCount(buffer) >= 1) {
        uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buffer, 0);
        size_t stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0);
        size_t pw = CVPixelBufferGetWidthOfPlane(buffer, 0);
        size_t ph = CVPixelBufferGetHeightOfPlane(buffer, 0);
        int index = 0;
        for (int y = 0; y < rows && index < count; ++y) {
            size_t py = (size_t)((y + 0.5) * ph / rows);
            if (py >= ph) py = ph - 1;
            for (int x = 0; x < cols && index < count; ++x) {
                size_t px = (size_t)((x + 0.5) * pw / cols);
                if (px >= pw) px = pw - 1;
                out[index++] = base[py * stride + px];
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
}

static double SPWhiteCenterX(CVPixelBufferRef buffer) {
    if (!buffer || CVPixelBufferGetPixelFormatType(buffer) != kCVPixelFormatType_32BGRA) return -1;
    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(buffer);
    size_t stride = CVPixelBufferGetBytesPerRow(buffer);
    size_t width = CVPixelBufferGetWidth(buffer);
    size_t height = CVPixelBufferGetHeight(buffer);
    double sum = 0, weight = 0;
    size_t y0 = height * 28 / 100;
    size_t y1 = height * 46 / 100;
    if (y1 > height) y1 = height;
    for (size_t y = y0; y < y1; y += 2) {
        uint8_t *row = base + y * stride;
        for (size_t x = 0; x < width; x += 4) {
            uint8_t green = row[x * 4 + 1];
            if (green > 180) {
                sum += (double)x * green;
                weight += green;
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    return weight > 0 ? sum / weight : -1;
}

static int SPTestBGRAFirstByte(CVPixelBufferRef buffer) {
    if (!buffer) return -1;
    OSType format=CVPixelBufferGetPixelFormatType(buffer);
    if (format!=kCVPixelFormatType_32BGRA && format!=kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange && format!=kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) return -1;
    CVPixelBufferLockBaseAddress(buffer,kCVPixelBufferLock_ReadOnly);
    const uint8_t *base=(const uint8_t *)(format==kCVPixelFormatType_32BGRA ? CVPixelBufferGetBaseAddress(buffer) : CVPixelBufferGetBaseAddressOfPlane(buffer,0));
    int value=base ? base[0] : -1;
    if (value>=0 && format==kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) value=(int)llround((value-16)*255.0/219.0);
    CVPixelBufferUnlockBaseAddress(buffer,kCVPixelBufferLock_ReadOnly); return value;
}

// Only bit-identical input is safe to hold; sampling would miss small motion.
static BOOL SPIdenticalSourcePixels(CVPixelBufferRef a, CVPixelBufferRef b) {
    if (!a || !b || CVPixelBufferGetPixelFormatType(a)!=CVPixelBufferGetPixelFormatType(b) ||
        CVPixelBufferGetWidth(a)!=CVPixelBufferGetWidth(b) || CVPixelBufferGetHeight(a)!=CVPixelBufferGetHeight(b)) return NO;
    OSType format=CVPixelBufferGetPixelFormatType(a);
    if (format!=kCVPixelFormatType_32BGRA && format!=kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange && format!=kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) return NO;
    for (CFStringRef key : {kCVImageBufferColorPrimariesKey,kCVImageBufferTransferFunctionKey,kCVImageBufferYCbCrMatrixKey}) {
        CFTypeRef x=CVBufferGetAttachment(a,key,NULL), y=CVBufferGetAttachment(b,key,NULL);
        if ((x==NULL)!=(y==NULL) || (x&&y&&!CFEqual(x,y))) return NO;
    }
    if (CVPixelBufferLockBaseAddress(a,kCVPixelBufferLock_ReadOnly)!=kCVReturnSuccess) return NO;
    if (CVPixelBufferLockBaseAddress(b,kCVPixelBufferLock_ReadOnly)!=kCVReturnSuccess) { CVPixelBufferUnlockBaseAddress(a,kCVPixelBufferLock_ReadOnly); return NO; }
    BOOL equal=YES; size_t planes=CVPixelBufferIsPlanar(a)?CVPixelBufferGetPlaneCount(a):1;
    if (planes!=(CVPixelBufferIsPlanar(b)?CVPixelBufferGetPlaneCount(b):1)) equal=NO;
    for(size_t p=0;equal && p<planes;p++) {
        BOOL planar=CVPixelBufferIsPlanar(a);
        const uint8_t *x=(const uint8_t *)(planar?CVPixelBufferGetBaseAddressOfPlane(a,p):CVPixelBufferGetBaseAddress(a));
        const uint8_t *y=(const uint8_t *)(planar?CVPixelBufferGetBaseAddressOfPlane(b,p):CVPixelBufferGetBaseAddress(b));
        size_t sx=planar?CVPixelBufferGetBytesPerRowOfPlane(a,p):CVPixelBufferGetBytesPerRow(a), sy=planar?CVPixelBufferGetBytesPerRowOfPlane(b,p):CVPixelBufferGetBytesPerRow(b);
        size_t h=planar?CVPixelBufferGetHeightOfPlane(a,p):CVPixelBufferGetHeight(a);
        size_t bytes=planar?CVPixelBufferGetWidthOfPlane(a,p)*(p==1?2:1):CVPixelBufferGetWidth(a)*4;
        if(!x||!y||sx<bytes||sy<bytes) { equal=NO; break; }
        for(size_t row=0;row<h;row++) if(memcmp(x+row*sx,y+row*sy,bytes)!=0){equal=NO;break;}
    }
    CVPixelBufferUnlockBaseAddress(b,kCVPixelBufferLock_ReadOnly);CVPixelBufferUnlockBaseAddress(a,kCVPixelBufferLock_ReadOnly);return equal;
}

static NSDictionary *SPQualityDiff(CVPixelBufferRef lhs, CVPixelBufferRef rhs) {
    if (!lhs || !rhs || CVPixelBufferGetWidth(lhs)!=CVPixelBufferGetWidth(rhs) || CVPixelBufferGetHeight(lhs)!=CVPixelBufferGetHeight(rhs)) return @{};
    CVPixelBufferLockBaseAddress(lhs,kCVPixelBufferLock_ReadOnly); CVPixelBufferLockBaseAddress(rhs,kCVPixelBufferLock_ReadOnly);
    const uint8_t *a=(const uint8_t *)CVPixelBufferGetBaseAddress(lhs), *b=(const uint8_t *)CVPixelBufferGetBaseAddress(rhs);
    size_t sa=CVPixelBufferGetBytesPerRow(lhs), sb=CVPixelBufferGetBytesPerRow(rhs), w=CVPixelBufferGetWidth(lhs), h=CVPixelBufferGetHeight(lhs);
    uint64_t hist[256]={}, n=0; double sum=0, meanA=0,meanB=0,edgeA=0,edgeB=0, channelsA[3]={},channelsB[3]={}; uint64_t edges=0;
    for(size_t y=0;y<h;y+=4) for(size_t x=0;x<w;x+=4) {
        for(size_t c=0;c<3;c++) { int av=a[y*sa+x*4+c], bv=b[y*sb+x*4+c], diff=abs(av-bv); hist[diff]++;sum+=diff;meanA+=av;meanB+=bv;channelsA[c]+=av;channelsB[c]+=bv;n++; }
        if(x+1<w) { edgeA+=abs((int)a[y*sa+x*4+1]-(int)a[y*sa+(x+1)*4+1]); edgeB+=abs((int)b[y*sb+x*4+1]-(int)b[y*sb+(x+1)*4+1]);edges++; }
    }
    uint64_t seen=0;int p95=0;for(;p95<255;p95++){seen+=hist[p95];if(seen*100>=n*95)break;}
    CVPixelBufferUnlockBaseAddress(rhs,kCVPixelBufferLock_ReadOnly);CVPixelBufferUnlockBaseAddress(lhs,kCVPixelBufferLock_ReadOnly);
    return @{ @"mae":@(n?sum/n:0), @"p95Abs":@(p95), @"meanA":@(n?meanA/n:0), @"meanB":@(n?meanB/n:0),
        @"meanBGRAReference":@[@(n?channelsA[0]*3/n:0),@(n?channelsA[1]*3/n:0),@(n?channelsA[2]*3/n:0)],
        @"meanBGRAPhase":@[@(n?channelsB[0]*3/n:0),@(n?channelsB[1]*3/n:0),@(n?channelsB[2]*3/n:0)],
        @"edgeA":@(edges?edgeA/edges:0), @"edgeB":@(edges?edgeB/edges:0), @"samples":@(n) };
}

static CVPixelBufferRef SPQualityNV12(BOOL full,int shift,BOOL glyph=NO) {
    const int w=2560,h=1440; OSType f=full?kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    CVPixelBufferRef p=SPCreateBuffer(w,h,f);if(!p)return NULL;SPForceSDRAttachments(p);
    CVPixelBufferLockBaseAddress(p,0);uint8_t *y=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(p,0),*uv=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(p,1);
    size_t ys=CVPixelBufferGetBytesPerRowOfPlane(p,0),us=CVPixelBufferGetBytesPerRowOfPlane(p,1);
    for(int row=0;row<h;row++)for(int col=0;col<w;col++) { int x=col-shift+24; BOOL bars;
        if(glyph) { int gx=x%24,gy=row%28; bars=(gx>=3&&gx<5&&gy>=3&&gy<23)||(gx>=16&&gx<18&&gy>=3&&gy<23)||(gy>=3&&gy<5&&gx>=3&&gx<18)||(gy>=12&&gy<14&&gx>=3&&gx<18)||(gy>=21&&gy<23&&gx>=3&&gx<18); }
        else bars=((x/3+row/7)&1)!=0;
        y[row*ys+col]=full?(bars?225:30):(bars?209:42); }
    for(int row=0;row<h/2;row++)for(int col=0;col<w;col+=2) { BOOL colored=col>1200&&col<1700&&row>200&&row<500;uv[row*us+col]=colored?100:128;uv[row*us+col+1]=colored?165:128; }
    CVPixelBufferUnlockBaseAddress(p,0);return p;
}

NSSize SPLiveSRInputSize(int width, int height, int preset) {
    if (width < 2 || height < 2 || (preset != 480 && preset != 720 && preset != 1080)) return NSMakeSize(width, height);
    int maxWidth = preset == 480 ? 854 : (preset == 720 ? 1280 : 1920);
    double factor = MIN(1.0, MIN((double)maxWidth / width, (double)preset / height));
    return NSMakeSize(MAX(2, ((int)(width * factor)) & ~1), MAX(2, ((int)(height * factor)) & ~1));
}

static NSSize SPLiveSRInputSizeForRequest(int width, int height, SPLivePlanRequest *request) {
    int preset = request.scaleEnabled ? request.srInputPreset : 0;
    if (request.scaleEnabled && request.scaleEngine == SPLiveScaleAppleLowLatencySR)
        return [SPAppleLowLatencySR inputSizeForWidth:width height:height preset:preset];
    NSSize input = SPLiveSRInputSize(width, height, preset);
    if (request.scaleEnabled && request.scaleEngine == SPLiveScaleAppleVideoSR && request.outputWidth == 0 && request.outputHeight == 0) {
        NSSize effective = [SPAppleVideoSR automaticInputForWidth:(int)input.width height:(int)input.height];
        NSSize output = [SPAppleVideoSR automaticOutputForWidth:(int)effective.width height:(int)effective.height];
        // Leave room for the source, compare frame, and temporal output buffers
        // within the live queue's 160 MiB budget.
        if (output.width > 3200 || output.height > 1800) {
            double ratio = MIN(3200.0 / output.width, 1800.0 / output.height);
            effective = [SPAppleVideoSR automaticInputForWidth:MAX(4, ((int)(effective.width * ratio)) & ~3)
                                                         height:MAX(4, ((int)(effective.height * ratio)) & ~3)];
        }
        return effective;
    }
    return input;
}

@implementation SPLivePlanRequest
- (id)copyWithZone:(NSZone *)zone {
    (void)zone;
    SPLivePlanRequest *copy = [[SPLivePlanRequest alloc] init];
    copy.requestID = self.requestID;
    copy.interpolationEnabled = self.interpolationEnabled;
    copy.quality = self.quality;
    copy.rateKind = self.rateKind;
    copy.fpsNumerator = self.fpsNumerator;
    copy.fpsDenominator = self.fpsDenominator;
    copy.multiplier = self.multiplier;
    copy.scaleEnabled = self.scaleEnabled;
    copy.scaleEngine = self.scaleEngine;
    copy.scaleQualityID = self.scaleQualityID ?: @"none";
    copy.srInputPreset = self.srInputPreset;
    copy.requiredSourceWidth = self.requiredSourceWidth; copy.requiredSourceHeight = self.requiredSourceHeight;
    copy.requiredSourceWindowID = self.requiredSourceWindowID; copy.requiredSourcePID = self.requiredSourcePID;
    copy.requiredSourceAfterHost = self.requiredSourceAfterHost;
    copy.outputWidth = self.outputWidth;
    copy.outputHeight = self.outputHeight;
    copy.viewMode = self.viewMode;
    copy.displayRefreshHz = self.displayRefreshHz;
    copy.captureCapFPS = self.captureCapFPS;
    copy.engineID = self.engineID ?: @"apple.frc";
    copy.modelID = self.modelID ?: @"";
    copy.qualityID = self.qualityID ?: @"";
    copy.rifeStreamEnabled = self.rifeStreamEnabled;
    copy.captureSourceKind = self.captureSourceKind;
    return copy;
}
@end

@implementation SPLiveResolvedPlan
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _engineID = @"apple.frc";
    _modelID = @"vt.frc.normal";
    _scaleEngineID = @"";
    _unavailableReason = @"";
    _colorPath = @"sdr.bt709.8bit";
    return self;
}
@end

@implementation SPSpatialScaler {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLComputePipelineState> _horizontal;
    id<MTLComputePipelineState> _vertical;
    id<MTLFXSpatialScaler> _metalFX;
    CVMetalTextureCacheRef _cache;
    int _inputW, _inputH, _outputW, _outputH;
    SPLiveScaleEngine _engine;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
                        inputW:(int)inputW
                        inputH:(int)inputH
                       outputW:(int)outputW
                       outputH:(int)outputH
                        engine:(SPLiveScaleEngine)engine
                         error:(NSError **)error {
    if (!(self = [super init])) return nil;
    _device = device;
    _inputW = inputW;
    _inputH = inputH;
    _outputW = outputW;
    _outputH = outputH;
    _engine = engine;
    _queue = [device newCommandQueue];
    if (CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, device, NULL, &_cache) != kCVReturnSuccess) {
        if (error) *error = SPLiveError(20, @"纹理缓存创建失败");
        return nil;
    }
    if (engine == SPLiveScaleMetalFX) {
        if (![MTLFXSpatialScalerDescriptor supportsDevice:device]) {
            if (error) *error = SPLiveError(21, @"这台 Mac 不支持 MetalFX 空间缩放");
            return nil;
        }
        MTLFXSpatialScalerDescriptor *descriptor = [[MTLFXSpatialScalerDescriptor alloc] init];
        descriptor.inputWidth = (NSUInteger)inputW;
        descriptor.inputHeight = (NSUInteger)inputH;
        descriptor.outputWidth = (NSUInteger)outputW;
        descriptor.outputHeight = (NSUInteger)outputH;
        descriptor.colorTextureFormat = MTLPixelFormatBGRA8Unorm;
        descriptor.outputTextureFormat = MTLPixelFormatBGRA8Unorm;
        descriptor.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
        _metalFX = [descriptor newSpatialScalerWithDevice:device];
        if (!_metalFX) {
            if (error) *error = SPLiveError(22, @"MetalFX 空间缩放器创建失败");
            return nil;
        }
        return self;
    }
    id<MTLLibrary> library = [device newDefaultLibrary];
    NSError *functionError = nil;
    id<MTLFunction> horizontal = [library newFunctionWithName:@"spLanczosHorizontal"];
    id<MTLFunction> vertical = [library newFunctionWithName:@"spLanczosVertical"];
    _horizontal = horizontal ? [device newComputePipelineStateWithFunction:horizontal error:&functionError] : nil;
    _vertical = vertical && !functionError ? [device newComputePipelineStateWithFunction:vertical error:&functionError] : nil;
    if (!_horizontal || !_vertical) {
        if (error) *error = functionError ?: SPLiveError(23, @"Lanczos 着色器不可用");
        return nil;
    }
    return self;
}

- (void)dealloc {
    if (_cache) CFRelease(_cache);
}

- (SPLiveScaleEngine)engine { return _engine; }

- (CVMetalTextureRef)createTextureForBuffer:(CVPixelBufferRef)buffer {
    CVMetalTextureRef ref = NULL;
    size_t width = CVPixelBufferGetWidth(buffer);
    size_t height = CVPixelBufferGetHeight(buffer);
    CVReturn result = CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, _cache, buffer, NULL, MTLPixelFormatBGRA8Unorm, width, height, 0, &ref);
    if (result != kCVReturnSuccess || !ref) return NULL;
    return ref;
}

- (nullable CVPixelBufferRef)scaleBuffer:(CVPixelBufferRef)source error:(NSError **)error {
    if (!source) return NULL;
    if (_inputW == _outputW && _inputH == _outputH) {
        CVPixelBufferRetain(source);
        return source;
    }
    CVPixelBufferRef destination = SPCreateBuffer(_outputW, _outputH, kCVPixelFormatType_32BGRA);
    if (!destination) {
        if (error) *error = SPLiveError(24, @"缩放输出缓冲失败");
        return NULL;
    }
    CVMetalTextureRef inputRef = [self createTextureForBuffer:source];
    CVMetalTextureRef outputRef = [self createTextureForBuffer:destination];
    id<MTLTexture> input = inputRef ? CVMetalTextureGetTexture(inputRef) : nil;
    id<MTLTexture> output = outputRef ? CVMetalTextureGetTexture(outputRef) : nil;
    if (!input || !output) {
        if (inputRef) CFRelease(inputRef);
        if (outputRef) CFRelease(outputRef);
        CVPixelBufferRelease(destination);
        if (error) *error = SPLiveError(25, @"缩放纹理失败");
        return NULL;
    }
    id<MTLCommandBuffer> command = [_queue commandBuffer];
    if (_engine == SPLiveScaleMetalFX) {
        MTLTextureDescriptor *inDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                           width:(NSUInteger)_inputW
                                                                                          height:(NSUInteger)_inputH
                                                                                       mipmapped:NO];
        inDesc.storageMode = MTLStorageModePrivate;
        inDesc.usage = MTLTextureUsageShaderRead | _metalFX.colorTextureUsage;
        MTLTextureDescriptor *outDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                            width:(NSUInteger)_outputW
                                                                                           height:(NSUInteger)_outputH
                                                                                        mipmapped:NO];
        outDesc.storageMode = MTLStorageModePrivate;
        outDesc.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead | _metalFX.outputTextureUsage;
        id<MTLTexture> inPrivate = [_device newTextureWithDescriptor:inDesc];
        id<MTLTexture> outPrivate = [_device newTextureWithDescriptor:outDesc];
        id<MTLBlitCommandEncoder> blitIn = [command blitCommandEncoder];
        [blitIn copyFromTexture:input sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                     sourceSize:MTLSizeMake((NSUInteger)_inputW, (NSUInteger)_inputH, 1)
                      toTexture:inPrivate destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blitIn endEncoding];
        _metalFX.colorTexture = inPrivate;
        _metalFX.inputContentWidth = (NSUInteger)_inputW;
        _metalFX.inputContentHeight = (NSUInteger)_inputH;
        _metalFX.outputTexture = outPrivate;
        [_metalFX encodeToCommandBuffer:command];
        id<MTLBlitCommandEncoder> blitOut = [command blitCommandEncoder];
        [blitOut copyFromTexture:outPrivate sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake((NSUInteger)_outputW, (NSUInteger)_outputH, 1)
                       toTexture:output destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blitOut endEncoding];
    } else {
        MTLTextureDescriptor *midDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                                            width:(NSUInteger)_outputW
                                                                                           height:(NSUInteger)_inputH
                                                                                        mipmapped:NO];
        midDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        midDesc.storageMode = MTLStorageModePrivate;
        id<MTLTexture> mid = [_device newTextureWithDescriptor:midDesc];
        id<MTLComputeCommandEncoder> horizontal = [command computeCommandEncoder];
        [horizontal setComputePipelineState:_horizontal];
        [horizontal setTexture:input atIndex:0];
        [horizontal setTexture:mid atIndex:1];
        NSUInteger tw = _horizontal.threadExecutionWidth;
        NSUInteger th = MAX((NSUInteger)1, _horizontal.maxTotalThreadsPerThreadgroup / tw);
        [horizontal dispatchThreads:MTLSizeMake((NSUInteger)_outputW, (NSUInteger)_inputH, 1)
              threadsPerThreadgroup:MTLSizeMake(tw, th, 1)];
        [horizontal endEncoding];
        id<MTLComputeCommandEncoder> vertical = [command computeCommandEncoder];
        [vertical setComputePipelineState:_vertical];
        [vertical setTexture:mid atIndex:0];
        [vertical setTexture:output atIndex:1];
        [vertical dispatchThreads:MTLSizeMake((NSUInteger)_outputW, (NSUInteger)_outputH, 1)
            threadsPerThreadgroup:MTLSizeMake(tw, th, 1)];
        [vertical endEncoding];
        (void)mid;
    }
    [command commit];
    [command waitUntilCompleted];
    CFRelease(inputRef); CFRelease(outputRef);
    if (command.status != MTLCommandBufferStatusCompleted) {
        CVPixelBufferRelease(destination);
        if (error) *error = SPLiveError(26, @"缩放 GPU 失败");
        return NULL;
    }
    SPForceSDRAttachments(destination);
    CVMetalTextureCacheFlush(_cache, 0);
    return destination;
}

@end

BOOL SPLiveCanPrepareMetalFX(int width, int height) {
    if (width < 2 || height < 2 || width*2 > 3840 || height*2 > 2160) return NO;
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    if (!device) return NO;
    NSError *error=nil;
    SPSpatialScaler *scaler=[[SPSpatialScaler alloc] initWithDevice:device inputW:width inputH:height outputW:width*2 outputH:height*2 engine:SPLiveScaleMetalFX error:&error];
    return scaler != nil;
}


@interface SPProbeDrawable : NSObject
@property(nonatomic,strong) id<MTLTexture> texture;
@end
@implementation SPProbeDrawable
@end

static BOOL SPGeometryRectValue(id value, sp::GeometryRect &out) {
    if (![value isKindOfClass:NSArray.class] || [value count] != 4) return NO;
    NSArray *a = value;
    for (id x in a) if (![x isKindOfClass:NSNumber.class]) return NO;
    out = {[a[0] doubleValue], [a[1] doubleValue], [a[2] doubleValue], [a[3] doubleValue]};
    return std::isfinite(out.x) && std::isfinite(out.y) && std::isfinite(out.width) && std::isfinite(out.height);
}
static BOOL SPSourceGeometryValue(NSDictionary *d, sp::GeometrySource &s) {
    if (![d isKindOfClass:NSDictionary.class] ||
        !SPGeometryRectValue(d[@"screenRect"], s.screenRect) || !SPGeometryRectValue(d[@"contentRect"], s.contentRect)) return NO;
    for (NSString *key in @[@"generation",@"windowID",@"pid",@"bufferWidth",@"bufferHeight",@"scaleFactor",@"contentScale"])
        if (![d[key] isKindOfClass:NSNumber.class]) return NO;
    s.generation=[d[@"generation"] unsignedLongLongValue]; s.windowID=[d[@"windowID"] unsignedLongLongValue];
    s.pid=[d[@"pid"] unsignedLongLongValue]; s.bufferWidth=[d[@"bufferWidth"] intValue]; s.bufferHeight=[d[@"bufferHeight"] intValue];
    s.scaleFactor=[d[@"scaleFactor"] doubleValue]; s.contentScale=[d[@"contentScale"] doubleValue];
    return YES;
}
static BOOL SPTargetGeometryValue(NSDictionary *d, sp::GeometryTarget &t) {
    if (![d isKindOfClass:NSDictionary.class] || !SPGeometryRectValue(d[@"screenRect"], t.screenRect) ||
        !SPGeometryRectValue(d[@"windowBounds"], t.windowBounds) || !SPGeometryRectValue(d[@"panelFrame"], t.panelFrame) || !SPGeometryRectValue(d[@"displayFrame"], t.displayFrame) ||
        !SPGeometryRectValue(d[@"displayBoundsQuartz"], t.displayBoundsQuartz)) return NO;
    for (NSString *key in @[@"generation",@"windowID",@"pid",@"config",@"epoch",@"displayID",@"backingScale",@"verified"])
        if (![d[key] isKindOfClass:NSNumber.class]) return NO;
    t.generation=[d[@"generation"] unsignedLongLongValue]; t.windowID=[d[@"windowID"] unsignedLongLongValue];
    t.pid=[d[@"pid"] unsignedLongLongValue]; t.config=[d[@"config"] unsignedLongLongValue];
    t.epoch=[d[@"epoch"] unsignedLongLongValue]; t.displayID=[d[@"displayID"] unsignedLongLongValue];
    t.backingScale=[d[@"backingScale"] doubleValue]; t.verified=[d[@"verified"] boolValue];
    return YES;
}

// Own pixel buffers from admission until rejection or GPU completion. Pending
// requests never reserve drawable/GPU tickets and remain strictly bounded.
@class SPPreparedTextureLease, SPPreparedTextureMapper;
@interface SPDisplayFrameRequest : NSObject {
@public
    spAirMeasurement::TracePtr _measurementTrace;
    uint64_t _measurementLeaseID;
}
@property(nonatomic, assign) CVPixelBufferRef enhanced;
@property(nonatomic, assign) CVPixelBufferRef original;
@property(nonatomic) SPLiveViewMode mode;
@property(nonatomic) int64_t captureHost;
@property(nonatomic) uint64_t generation;
@property(nonatomic) uint64_t config;
@property(nonatomic) uint64_t epoch;
@property(nonatomic) uint64_t clockEpoch;
@property(nonatomic) uint64_t surfaceToken;
@property(nonatomic) int64_t ptsNum;
@property(nonatomic) int64_t ptsDen;
@property(nonatomic) BOOL synthetic;
@property(nonatomic) uint64_t frameID;
@property(nonatomic) BOOL counts;
@property(nonatomic) BOOL redraw;
@property(nonatomic) BOOL airPerformanceEnabled;
#if ODF_AIR_BETA_DIAGNOSTIC
@property(nonatomic) int betaCaptureWidth;
@property(nonatomic) int betaCaptureHeight;
#endif
@property(nonatomic) int64_t logicalTargetHost;
@property(nonatomic) int64_t enqueueHost;
@property(nonatomic) int64_t causalEnqueueHostTicks;
@property(nonatomic, copy) NSDictionary *captureGeometry;
@property(nonatomic, strong) SPPreparedTextureLease *preparedTextureLease;
@property(nonatomic) int preparedTextureAdmissionReason;
@end
static spAirMeasurement::Event SPAirMeasurementFrame(SPDisplayFrameRequest *frame, spAirMeasurement::Kind kind) {
    spAirMeasurement::Event event;
    event.kind = kind; event.frameID = frame.frameID; event.generation = frame.generation;
    event.config = frame.config; event.epoch = frame.epoch; event.clock = frame.clockEpoch;
    event.ptsNum = frame.ptsNum; event.ptsDen = frame.ptsDen; event.targetHostTicks = frame.logicalTargetHost;
    event.flags = (frame.synthetic ? 1u : 0u) | (frame.counts ? 2u : 0u) | (frame.redraw ? 4u : 0u) | 8u;
    event.groupID = frame->_measurementLeaseID;
    return event;
}

enum SPPreparedTextureReason { SPPreparedNone, SPPreparedCapacity, SPPreparedNotReady, SPPreparedMapFailed, SPPreparedMismatch, SPPreparedMissing, SPPreparedCancelled };
static NSString *SPPreparedTextureReasonName(int reason) {
    switch (reason) {
        case SPPreparedNone: return @"none";
        case SPPreparedCapacity: return @"capacity";
        case SPPreparedNotReady: return @"not-ready";
        case SPPreparedMapFailed: return @"map-failed";
        case SPPreparedMismatch: return @"identity-or-context-mismatch";
        case SPPreparedCancelled: return @"cancelled";
        default: return @"missing";
    }
}
enum SPPreparedTexturePhase { SPPreparedQueued, SPPreparedMapping, SPPreparedReady, SPPreparedInflight, SPPreparedRetired, SPPreparedFailed, SPPreparedAbandoned };

@interface SPPreparedTextureLease : NSObject {
@public
    SPPreparedTextureMapper *_owner;
    spAirMeasurement::TracePtr _measurementTrace;
    spAirMeasurement::Event _measurementIdentity;
    std::atomic<int> _phase;
    std::atomic<int64_t> _mapStartedHostTicks, _mapEndedHostTicks;
    CVPixelBufferRef _primary, _secondary;
    CVPixelBufferRef _enhancedIdentity, _originalIdentity;
    CVMetalTextureRef _primaryRef, _secondaryRef;
    uint64_t _generation, _config, _epoch, _clockEpoch, _frameID;
    SPLiveViewMode _mode;
    BOOL _recycled; // mapper queue only
}
- (instancetype)initWithOwner:(SPPreparedTextureMapper *)owner frame:(SPDisplayFrameRequest *)frame;
- (BOOL)claimForFrame:(SPDisplayFrameRequest *)frame reason:(int *)reason;
- (void)cancel;
- (void)complete;
- (id<MTLTexture>)primaryTexture;
- (id<MTLTexture>)secondaryTexture;
@end

// Diagnostic-only, fixed-capacity owner. Cache Create/Flush and every owned CF
// release run on this queue; no view/frame is retained by the owner.
@interface SPPreparedTextureMapper : NSObject {
@public
    dispatch_queue_t _queue;
    id<MTLDevice> _device;
    CVMetalTextureCacheRef _cache;
    std::atomic<uint64_t> _outstanding, _peak, _admitted, _capacityRejected;
    std::atomic<uint64_t> _maps, _mapFailures, _textureFailures, _cacheFailures, _mapFlushes, _recycleFlushes, _idleFlushes, _recycled, _cancelled;
    std::atomic<uint64_t> _selected, _hits;
    std::array<std::atomic<uint64_t>, 7> _fallbacks;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device;
- (SPPreparedTextureLease *)prepareFrame:(SPDisplayFrameRequest *)frame;
- (SPPreparedTextureLease *)claimFrame:(SPDisplayFrameRequest *)frame recordSelection:(BOOL)record reason:(int *)reason;
- (void)mapLease:(SPPreparedTextureLease *)lease;
- (void)recycleLease:(SPPreparedTextureLease *)lease;
- (NSDictionary *)snapshot;
- (void)fenceForProbe;
@end

@implementation SPDisplayFrameRequest
- (void)dealloc {
    [_preparedTextureLease cancel];
    if (_enhanced) CVPixelBufferRelease(_enhanced);
    if (_original) CVPixelBufferRelease(_original);
}
@end

@implementation SPPreparedTextureLease
- (instancetype)initWithOwner:(SPPreparedTextureMapper *)owner frame:(SPDisplayFrameRequest *)frame {
    if (!(self = [super init])) return nil;
    _owner = owner; _phase.store(SPPreparedQueued); _mapStartedHostTicks.store(0); _mapEndedHostTicks.store(0);
    _generation = frame.generation; _config = frame.config; _epoch = frame.epoch; _clockEpoch = frame.clockEpoch; _frameID = frame.frameID; _mode = frame.mode;
    if (frame->_measurementTrace) {
        _measurementTrace = frame->_measurementTrace;
        _measurementIdentity = SPAirMeasurementFrame(frame, spAirMeasurement::Kind::leaseRequest);
    }
    _enhancedIdentity = frame.enhanced; _originalIdentity = frame.original;
    CVPixelBufferRef primary = frame.mode == SPLiveViewOriginal ? (frame.original ?: frame.enhanced) : frame.enhanced;
    CVPixelBufferRef secondary = frame.original ?: frame.enhanced;
    _primary = primary ? CVPixelBufferRetain(primary) : NULL;
    _secondary = frame.mode == SPLiveViewCompare && secondary ? CVPixelBufferRetain(secondary) : NULL;
    return self;
}
- (BOOL)claimForFrame:(SPDisplayFrameRequest *)frame reason:(int *)reason {
    if (_generation != frame.generation || _config != frame.config || _epoch != frame.epoch || _clockEpoch != frame.clockEpoch ||
        _frameID != frame.frameID || _mode != frame.mode || _enhancedIdentity != frame.enhanced || _originalIdentity != frame.original) {
        *reason = SPPreparedMismatch; return NO;
    }
    int expected = SPPreparedReady;
    if (_phase.compare_exchange_strong(expected, SPPreparedInflight, std::memory_order_acq_rel)) { *reason = SPPreparedNone; return YES; }
    *reason = expected == SPPreparedFailed ? SPPreparedMapFailed :
        (expected == SPPreparedAbandoned || expected == SPPreparedRetired ? SPPreparedCancelled : SPPreparedNotReady);
    return NO;
}
- (void)cancel {
    int phase = _phase.load();
    while (phase == SPPreparedQueued || phase == SPPreparedMapping || phase == SPPreparedReady) {
        if (_phase.compare_exchange_weak(phase, SPPreparedAbandoned)) {
            _owner->_cancelled.fetch_add(1);
            if (_measurementTrace) {
                auto event = _measurementIdentity;
                event.kind = spAirMeasurement::Kind::leaseCancel;
                event.beginHostTicks = event.endHostTicks = SPHostNow();
                event.values[0] = phase;
                _measurementTrace->append(event);
            }
            SPPreparedTextureMapper *owner = _owner;
            dispatch_async(owner->_queue, ^{ [owner recycleLease:self]; });
            return;
        }
    }
}
- (void)complete {
    int expected = SPPreparedInflight;
    if (!_phase.compare_exchange_strong(expected, SPPreparedRetired)) return;
    if (_measurementTrace) {
        auto event = _measurementIdentity;
        event.kind = spAirMeasurement::Kind::leaseCompleteRequest;
        event.beginHostTicks = event.endHostTicks = SPHostNow();
        _measurementTrace->append(event);
    }
    SPPreparedTextureMapper *owner = _owner;
    dispatch_async(owner->_queue, ^{ [owner recycleLease:self]; });
}
- (id<MTLTexture>)primaryTexture { return _primaryRef ? CVMetalTextureGetTexture(_primaryRef) : nil; }
- (id<MTLTexture>)secondaryTexture { return _secondaryRef ? CVMetalTextureGetTexture(_secondaryRef) : nil; }
@end

@implementation SPPreparedTextureMapper
- (instancetype)initWithDevice:(id<MTLDevice>)device {
    if (!(self = [super init])) return nil;
    _device = device;
    _queue = dispatch_queue_create("app.openduckframe.air-prepared-texture-map", dispatch_queue_attr_make_with_autorelease_frequency(
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0), DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM));
    _outstanding.store(0); _peak.store(0); _admitted.store(0); _capacityRejected.store(0);
    _maps.store(0); _mapFailures.store(0); _textureFailures.store(0); _cacheFailures.store(0); _mapFlushes.store(0); _recycleFlushes.store(0);
    _idleFlushes.store(0); _recycled.store(0); _cancelled.store(0); _selected.store(0); _hits.store(0);
    for (auto &value : _fallbacks) value.store(0);
    return self;
}
- (void)dealloc {
    CVMetalTextureCacheRef cache = _cache;
    if (cache) dispatch_async(_queue, ^{ CVMetalTextureCacheFlush(cache, 0); CFRelease(cache); });
}
- (SPPreparedTextureLease *)prepareFrame:(SPDisplayFrameRequest *)frame {
    spAirMeasurement::Event measurement;
    if (frame->_measurementTrace) {
        frame->_measurementLeaseID = frame->_measurementTrace->identity();
        measurement = SPAirMeasurementFrame(frame, spAirMeasurement::Kind::leaseRequest);
        measurement.beginHostTicks = SPHostNow();
    }
    uint64_t count = _outstanding.load();
    do { if (count >= 4) { _capacityRejected.fetch_add(1); frame.preparedTextureAdmissionReason = SPPreparedCapacity;
        if (frame->_measurementTrace) {
            measurement.endHostTicks = SPHostNow();
            measurement.values[0] = 0;
            measurement.values[1] = count;
            frame->_measurementTrace->append(measurement);
        }
        return nil; } }
    while (!_outstanding.compare_exchange_weak(count, count + 1));
    uint64_t peak = _peak.load(); while (peak < count + 1 && !_peak.compare_exchange_weak(peak, count + 1)) {}
    _admitted.fetch_add(1);
    if (frame->_measurementTrace) {
        measurement.endHostTicks = SPHostNow();
        measurement.values[0] = 1;
        measurement.values[1] = count + 1;
        frame->_measurementTrace->append(measurement);
    }
    SPPreparedTextureLease *lease = [[SPPreparedTextureLease alloc] initWithOwner:self frame:frame];
    frame.preparedTextureLease = lease;
    dispatch_async(_queue, ^{ [self mapLease:lease]; });
    return lease;
}
- (void)mapLease:(SPPreparedTextureLease *)lease {
    int expected = SPPreparedQueued;
    if (!lease->_phase.compare_exchange_strong(expected, SPPreparedMapping)) { [self recycleLease:lease]; return; }
    _maps.fetch_add(1); lease->_mapStartedHostTicks.store(SPHostNow());
    if (!_cache && CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, _device, NULL, &_cache) != kCVReturnSuccess) _cacheFailures.fetch_add(1);
    BOOL valid = _cache && lease->_primary;
    if (valid) {
        CVReturn result = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _cache, lease->_primary, NULL,
            MTLPixelFormatBGRA8Unorm, CVPixelBufferGetWidth(lease->_primary), CVPixelBufferGetHeight(lease->_primary), 0, &lease->_primaryRef);
        valid = result == kCVReturnSuccess && lease->_primaryRef && CVMetalTextureGetTexture(lease->_primaryRef);
        if (!valid) _textureFailures.fetch_add(1);
    }
    if (valid && lease->_secondary) {
        CVReturn result = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _cache, lease->_secondary, NULL,
            MTLPixelFormatBGRA8Unorm, CVPixelBufferGetWidth(lease->_secondary), CVPixelBufferGetHeight(lease->_secondary), 0, &lease->_secondaryRef);
        valid = result == kCVReturnSuccess && lease->_secondaryRef && CVMetalTextureGetTexture(lease->_secondaryRef);
        if (!valid) _textureFailures.fetch_add(1);
    }
    if (_cache) { CVMetalTextureCacheFlush(_cache, 0); _mapFlushes.fetch_add(1); }
    lease->_mapEndedHostTicks.store(SPHostNow());
    if (lease->_measurementTrace) {
        auto event = lease->_measurementIdentity; event.kind = spAirMeasurement::Kind::leaseMap;
        event.beginHostTicks = lease->_mapStartedHostTicks.load(); event.endHostTicks = lease->_mapEndedHostTicks.load();
        event.values[0] = valid; lease->_measurementTrace->append(event);
    }
    if (!valid) { _mapFailures.fetch_add(1); lease->_phase.store(SPPreparedFailed); [self recycleLease:lease]; return; }
    expected = SPPreparedMapping;
    const bool measurementReadyPublished = lease->_phase.compare_exchange_strong(expected, SPPreparedReady, std::memory_order_release);
    if (!measurementReadyPublished) [self recycleLease:lease];
    if (lease->_measurementTrace) {
        auto event = lease->_measurementIdentity; event.kind = spAirMeasurement::Kind::leaseReady;
        event.beginHostTicks = event.endHostTicks = SPHostNow(); event.values[0] = measurementReadyPublished; event.values[1] = lease->_phase.load();
        lease->_measurementTrace->append(event);
    }
}
- (void)recycleLease:(SPPreparedTextureLease *)lease {
    if (lease->_recycled) return; lease->_recycled = YES;
    const uint64_t measurementReleaseBegin = lease->_measurementTrace ? SPHostNow() : 0;
    if (lease->_primaryRef) { CFRelease(lease->_primaryRef); lease->_primaryRef = NULL; }
    if (lease->_secondaryRef) { CFRelease(lease->_secondaryRef); lease->_secondaryRef = NULL; }
    if (lease->_primary) { CVPixelBufferRelease(lease->_primary); lease->_primary = NULL; }
    if (lease->_secondary) { CVPixelBufferRelease(lease->_secondary); lease->_secondary = NULL; }
    if (_cache) { CVMetalTextureCacheFlush(_cache, 0); _recycleFlushes.fetch_add(1); }
    _recycled.fetch_add(1);
    const uint64_t previousOutstanding = _outstanding.fetch_sub(1);
    if (previousOutstanding == 1 && _cache) _idleFlushes.fetch_add(1);
    if (lease->_measurementTrace) {
        auto event = lease->_measurementIdentity; event.kind = spAirMeasurement::Kind::leaseRelease;
        event.beginHostTicks = measurementReleaseBegin; event.endHostTicks = SPHostNow();
        event.values[0] = previousOutstanding; event.values[1] = previousOutstanding - 1;
        event.values[2] = lease->_phase.load(); lease->_measurementTrace->append(event);
    }
}
- (SPPreparedTextureLease *)claimFrame:(SPDisplayFrameRequest *)frame recordSelection:(BOOL)record reason:(int *)reason {
    if (record) _selected.fetch_add(1);
    SPPreparedTextureLease *lease = frame.preparedTextureLease;
    int failure = lease ? SPPreparedNone : (frame.preparedTextureAdmissionReason ?: SPPreparedMissing);
    if (lease && [lease claimForFrame:frame reason:&failure]) { if (record) _hits.fetch_add(1); *reason = SPPreparedNone;
        if (frame->_measurementTrace) {
            auto event = SPAirMeasurementFrame(frame, spAirMeasurement::Kind::leaseClaim);
            event.beginHostTicks = event.endHostTicks = SPHostNow();
            event.values[0] = SPPreparedNone;
            event.values[1] = 1;
            frame->_measurementTrace->append(event);
        }
        return lease; }
    if (frame->_measurementTrace) {
        auto event = SPAirMeasurementFrame(frame, spAirMeasurement::Kind::leaseClaim);
        event.beginHostTicks = event.endHostTicks = SPHostNow();
        event.values[0] = failure;
        event.values[1] = 0;
        frame->_measurementTrace->append(event);
    }
    if (record) _fallbacks[(size_t)failure].fetch_add(1);
    *reason = failure; [lease cancel]; return nil;
}
- (NSDictionary *)snapshot {
    NSMutableDictionary *reasons = [NSMutableDictionary dictionary]; uint64_t fallback = 0;
    for (int reason = 1; reason < 7; ++reason) { const uint64_t count = _fallbacks[(size_t)reason].load(); reasons[SPPreparedTextureReasonName(reason)] = @(count); fallback += count; }
    return @{ @"enabled": @YES, @"capacity": @4, @"outstanding": @(_outstanding.load()), @"peakOutstanding": @(_peak.load()),
        @"admitted": @(_admitted.load()), @"admissionCapacityRejected": @(_capacityRejected.load()), @"maps": @(_maps.load()),
        @"selectedRenderRequests": @(_selected.load()), @"hits": @(_hits.load()), @"fallbacks": @(fallback), @"fallbackReasons": reasons,
        @"mapFailures": @(_mapFailures.load()), @"textureFailures": @(_textureFailures.load()), @"cacheCreateFailures": @(_cacheFailures.load()),
        @"mapFlushes": @(_mapFlushes.load()), @"recycleFlushes": @(_recycleFlushes.load()), @"lastIdleFlushes": @(_idleFlushes.load()),
        @"recycled": @(_recycled.load()), @"cancelled": @(_cancelled.load()),
        @"scope": @"Diagnostic independent serial cache; outstanding includes queued, ready, GPU-inflight and queued cleanup, bounded at four. Hit/fallback denominator is selected render requests only. Cache Create/Flush and lease CF release occur only on mapper queue; no drawable is acquired here." };
}
- (void)fenceForProbe { dispatch_sync(_queue, ^{}); }
@end

static sp::DisplayQueueFrame SPDisplayFrameTiming(SPDisplayFrameRequest *frame) {
    return {{frame.ptsNum, frame.ptsDen}, frame.logicalTargetHost > 0 ? SPHostToNs(frame.logicalTargetHost) : 0,
            frame.frameID, (bool)frame.counts, (bool)frame.redraw};
}

// Only the current prospective slot owns a drawable. Deferred timer blocks
// retain a weak view and token, never the update or an obsolete drawable.
@interface SPProspectiveDisplaySlot : NSObject {
@public
    sp::DisplaySlotWindow timing;
    spAirDisplayPolicyB::RefreshHistory ruleBHistory;
    bool ruleBEnabled;
    int64_t selectionScanEndedHostTicks;
    int64_t discardReportsStartedHostTicks, discardReportsEndedHostTicks;
    uint64_t staleDiscardReportCount, supersededDiscardReportCount;
    qos_class_t timerHandlerRequestedQoSClass;
    bool timerHandlerQoSRecorded;
}
@property(nonatomic, strong) id<CAMetalDrawable> drawable;
@property(nonatomic) double deadline;
@property(nonatomic) double displayTime;
@property(nonatomic) int64_t callbackHost;
@end
@implementation SPProspectiveDisplaySlot
@end

static SPAirFrameEvent SPAirFrameRecord(SPDisplayFrameRequest *frame, SPAirFrameKind kind, SPAirFrameReason reason,
                                       SPAirFrameStage stage, SPProspectiveDisplaySlot *slot = nil, SPDisplayFrameRequest *replacement = nil) {
    SPAirFrameEvent event{}; event.hostTicks = SPHostNow(); event.kind = kind; event.reason = reason; event.stage = stage;
    if (frame) {
        event.countsKnown = event.typeKnown = true;
        event.frameID = frame.frameID; event.generation = frame.generation; event.config = frame.config; event.epoch = frame.epoch; event.clock = frame.clockEpoch;
        event.captureHostTicks = frame.captureHost; event.enqueueHostTicks = frame.causalEnqueueHostTicks; event.requestStartHostTicks = frame.enqueueHost;
        event.logicalTargetHostTicks = frame.logicalTargetHost; event.synthetic = frame.synthetic; event.counts = frame.counts; event.redraw = frame.redraw;
    } else event.countsKnown = false;
    if (slot) {
        event.hasSlot = true; event.slotToken = slot->timing.token; event.slotDisplayTimeMediaNs = (int64_t)(slot.displayTime * 1e9);
        if (!frame) { event.generation = slot->timing.context.generation; event.config = slot->timing.context.config; event.epoch = slot->timing.context.measurementEpoch; event.clock = slot->timing.context.clockEpoch; }
    }
    if (replacement) { event.hasReplacement = true; event.replacementFrameID = replacement.frameID; event.replacementSynthetic = replacement.synthetic; event.replacementCounts = replacement.counts; }
    return event;
}

static SPAirFrameEvent SPAirCallbackRecord(NSDictionary *info, NSString *endpoint) {
    SPAirFrameEvent event{}; event.hostTicks = SPHostNow(); event.stage = SPAirFrameStage::callback;
    event.frameID = [info[@"frameID"] unsignedLongLongValue]; event.generation = [info[@"generation"] unsignedLongLongValue];
    event.config = [info[@"configVersion"] unsignedLongLongValue]; event.epoch = [info[@"measurementEpoch"] unsignedLongLongValue]; event.clock = [info[@"clockEpoch"] unsignedLongLongValue];
    event.captureHostTicks = [info[@"captureHost"] longLongValue]; event.requestStartHostTicks = [info[@"presentationEnqueueHost"] longLongValue];
    event.logicalTargetHostTicks = [info[@"logicalTargetHost"] longLongValue]; event.slotToken = [info[@"displaySlotToken"] unsignedLongLongValue];
    event.hasSlot = event.slotToken != 0; event.slotDisplayTimeMediaNs = (int64_t)([info[@"displayLinkTargetPresentationTimestamp"] doubleValue] * 1e9);
    event.synthetic = [info[@"synthetic"] boolValue]; event.typeKnown = info[@"synthetic"] != nil;
    event.counts = [info[@"counts"] boolValue]; event.callbackCountsKnown = info[@"counts"] != nil; event.countsKnown = false;
    event.output = [endpoint isEqualToString:@"output"]; event.callbackHostTicks = [info[@"presentedHost"] longLongValue];
    const double presented = [info[@"presentedTime"] doubleValue];
    event.presentedTimeMediaNs = std::isfinite(presented) && presented > 0 && presented < (double)INT64_MAX / 1e9 ? (int64_t)(presented * 1e9) : 0;
    event.countsKnown = event.presentedTimeMediaNs > 0 && event.callbackCountsKnown;
    return event;
}

static NSString *SPAirFrameKindName(SPAirFrameKind kind) {
    switch (kind) {
        case SPAirFrameKind::admitted: return @"admitted"; case SPAirFrameKind::selected: return @"selected";
        case SPAirFrameKind::discarded: return @"discarded"; case SPAirFrameKind::rejected: return @"rejected-before-admission";
        case SPAirFrameKind::slotExpired: return @"slot-expired-no-request-retired";
        case SPAirFrameKind::positivePresented: return @"positive-presented-callback"; case SPAirFrameKind::zeroPresented: return @"zero-presented-callback";
        case SPAirFrameKind::failureNotification: return @"failure-notification"; case SPAirFrameKind::configurationMarker: return @"configuration-marker";
    }
    return @"unknown";
}
static NSString *SPAirFrameReasonName(SPAirFrameReason reason) {
    switch (reason) {
        case SPAirFrameReason::none: return @"none"; case SPAirFrameReason::superseded: return @"display-slot-superseded";
        case SPAirFrameReason::configuration: return @"configuration"; case SPAirFrameReason::stalePTS: return @"stale-pts";
        case SPAirFrameReason::expired: return @"expired-slot"; case SPAirFrameReason::generation: return @"generation";
        case SPAirFrameReason::epoch: return @"epoch"; case SPAirFrameReason::clock: return @"clock-retired";
        case SPAirFrameReason::invisible: return @"invisible"; case SPAirFrameReason::deadline: return @"display-submit-deadline";
        case SPAirFrameReason::texture: return @"texture"; case SPAirFrameReason::pipeline: return @"pipeline";
        case SPAirFrameReason::command: return @"command"; case SPAirFrameReason::gpu: return @"gpu";
        case SPAirFrameReason::notPresented: return @"display-not-presented"; case SPAirFrameReason::queueFull: return @"queue-full";
        case SPAirFrameReason::invalidPTS: return @"invalid-pts"; case SPAirFrameReason::duplicatePTS: return @"duplicate-pts";
        case SPAirFrameReason::other: return @"other-see-original-reason";
    }
    return @"unknown";
}
static NSString *SPAirFrameStageName(SPAirFrameStage stage) {
    switch (stage) {
        case SPAirFrameStage::admission: return @"admission"; case SPAirFrameStage::selection: return @"selection";
        case SPAirFrameStage::cleanup: return @"configuration-or-context-cleanup"; case SPAirFrameStage::finalCheck: return @"final-check-before-commit";
        case SPAirFrameStage::visibilityCleanup: return @"visibility-cleanup"; case SPAirFrameStage::callback: return @"processor-callback-before-filtering";
    }
    return @"unknown";
}
static NSDictionary *SPAirRingMetadata(uint64_t total, NSUInteger capacity, NSArray *events) {
    return @{ @"capacity": @(capacity), @"total": @(total), @"dropped": @(total > capacity ? total - capacity : 0),
        @"firstseq": events.count ? events.firstObject[@"sequence"] : (id)NSNull.null,
        @"lastseq": events.count ? events.lastObject[@"sequence"] : (id)NSNull.null, @"exportedCount": @(events.count), @"events": events };
}
static NSDictionary *SPAirFrameExport(const std::vector<SPAirFrameEvent> &values, uint64_t total, NSString *endpoint, int64_t cutoff) {
    NSMutableArray *events = [NSMutableArray arrayWithCapacity:values.size()];
    for (const auto &e : values) {
        if (e.hostTicks > cutoff) continue;
        NSString *owner = endpoint ?: (e.output ? @"output" : @"preview");
        [events addObject:@{ @"sequence": @(e.sequence), @"kind": SPAirFrameKindName(e.kind), @"reason": SPAirFrameReasonName(e.reason),
            @"originalReason": e.reasonText[0] ? [NSString stringWithUTF8String:e.reasonText] : (id)NSNull.null,
            @"stage": SPAirFrameStageName(e.stage), @"endpoint": owner, @"hostTicks": @(e.hostTicks),
            @"frameID": e.kind == SPAirFrameKind::slotExpired || e.kind == SPAirFrameKind::configurationMarker ? (id)NSNull.null : @(e.frameID), @"generation": @(e.generation), @"configVersion": @(e.config), @"measurementEpoch": @(e.epoch), @"clockEpoch": @(e.clock),
            @"type": e.typeKnown ? (e.synthetic ? @"synthetic" : @"original") : (id)NSNull.null, @"counts": e.countsKnown ? @(e.counts) : (id)NSNull.null, @"callbackCounts": e.callbackCountsKnown ? @(e.counts) : (id)NSNull.null, @"redraw": @(e.redraw),
            @"captureHostTicks": e.captureHostTicks ? @(e.captureHostTicks) : (id)NSNull.null,
            @"enqueueHostTicks": e.enqueueHostTicks ? @(e.enqueueHostTicks) : (id)NSNull.null,
            @"requestStartHostTicks": e.requestStartHostTicks ? @(e.requestStartHostTicks) : (id)NSNull.null,
            @"logicalTargetHostTicks": e.logicalTargetHostTicks ? @(e.logicalTargetHostTicks) : (id)NSNull.null,
            @"slotToken": e.hasSlot ? @(e.slotToken) : (id)NSNull.null, @"slotDisplayTimeMediaNs": e.hasSlot ? @(e.slotDisplayTimeMediaNs) : (id)NSNull.null,
            @"replacementFrameID": e.hasReplacement ? @(e.replacementFrameID) : (id)NSNull.null,
            @"replacementType": e.hasReplacement ? (e.replacementSynthetic ? @"synthetic" : @"original") : (id)NSNull.null,
            @"replacementCounts": e.hasReplacement ? @(e.replacementCounts) : (id)NSNull.null,
            @"presentedTimeMediaNs": e.presentedTimeMediaNs ? @(e.presentedTimeMediaNs) : (id)NSNull.null,
            @"callbackHostTicks": e.callbackHostTicks ? @(e.callbackHostTicks) : (id)NSNull.null,
            @"previousConfigVersion": e.kind == SPAirFrameKind::configurationMarker ? @(e.previousConfig) : (id)NSNull.null,
            @"previousMeasurementEpoch": e.kind == SPAirFrameKind::configurationMarker ? @(e.previousEpoch) : (id)NSNull.null }];
    }
    return SPAirRingMetadata(total, SPAirFrameRing::capacity, events);
}
static NSDictionary *SPAirBudgetExport(const std::vector<SPAirBudgetEvent> &values, uint64_t total, int64_t cutoff) {
    NSMutableArray *events = [NSMutableArray arrayWithCapacity:values.size()];
    for (const auto &e : values) {
        if (e.hostTicks > cutoff) continue;
        NSMutableArray *gates = [NSMutableArray array];
        NSArray *names = @[@"rate-budget-disabled", @"engine-unavailable", @"session-not-ready", @"stopped", @"application-blocked-inflight", @"application-blocked-probe-inflight", @"fresh-samples-below-eight", @"policy-unchanged-persistence-or-other-inputs"];
        for (NSUInteger bit = 0; bit < names.count; ++bit) if (e.gateMask & (1u << bit)) [gates addObject:names[bit]];
        if (e.suspend && e.policyCalled) [gates addObject:@"explicit-suspension-zero-content-fps"];
        [events addObject:@{ @"sequence": @(e.sequence), @"hostTicks": @(e.hostTicks), @"source": e.suspend ? @"suspendRateBudgetOnQueue" : @"updateRateBudgetOnQueue",
            @"generation": @(e.generation), @"configBefore": @(e.configBefore), @"configAfter": @(e.configAfter), @"epochBefore": @(e.epochBefore), @"epochAfter": @(e.epochAfter),
            @"freshSamples": @(e.freshSamples), @"freshSamplesAtLeastEight": @(e.freshSamples >= 8), @"inflight": @(e.inflight), @"probeInFlight": @(e.probeToken != 0), @"probeInFlightToken": @(e.probeToken),
            @"policyUpdateCalled": @(e.policyCalled), @"policyInputAvailable": @(e.inputAvailable), @"policyMediaTimeSeconds": e.policyCalled ? @(e.policyMediaTimeSeconds) : (id)NSNull.null,
            @"gateMask": @(e.gateMask), @"evaluationEntryBlocked": @((e.gateMask & 15) != 0), @"applicationGateBlocked": @((e.gateMask & 48) != 0), @"noDecisionReasons": gates, @"nativeEvidenceSuspended": @(e.nativeSuspended),
            @"requestedMultiplier": @(e.requested), @"appliedMultiplierBefore": @(e.appliedBefore), @"appliedMultiplierAfter": @(e.appliedAfter),
            @"budgetMultiplierBefore": @(e.budgetBefore), @"budgetMultiplierAfter": @(e.budgetAfter),
            @"decision": e.budgetBefore != e.budgetAfter ? @"policy-target-changed" : (e.appliedBefore != e.appliedAfter ? @"pending-target-applied" : @"unchanged"),
            @"contentFPS": @(e.contentFPS), @"medianTaskMs": @(e.medianTaskMs), @"plannedPhases": @(e.planned), @"droppedPhases": @(e.dropped),
            @"phaseCostBeforeMs": @(e.phaseCostBeforeMs), @"phaseCostAfterMs": @(e.phaseCostAfterMs), @"refreshHz": @(e.refreshHz), @"displayCap": @(e.displayCap),
            @"limit": [NSString stringWithUTF8String:sp::rateBudgetLimitName(e.limit)] }];
    }
    return SPAirRingMetadata(total, SPAirBudgetRing::capacity, events);
}
enum class SPDisplayTimerOutcome : uint8_t { selected, noFrame, waiting, staleToken, noCurrentSlot, retired, gpuBusy, expiredConsume, expiredReplaced };
static_assert((uint8_t)SPDisplayTimerOutcome::waiting == 2, "token logger waiting outcome binding");
struct SPDisplayTimerTrace {
    sp::DisplaySlotWindow armed{};
    uint64_t observedToken = 0, frameID = 0;
    int64_t handlerEntryNs = 0, lockAcquiredNs = 0;
    SPDisplayTimerOutcome outcome = SPDisplayTimerOutcome::noCurrentSlot;
    int64_t handlerEntryHostTicks = 0; // opt-in metadata; existing mach entry sample
};
static NSString *SPDisplayTimerOutcomeName(SPDisplayTimerOutcome outcome) {
    switch (outcome) {
        case SPDisplayTimerOutcome::selected: return @"selected";
        case SPDisplayTimerOutcome::noFrame: return @"no-frame";
        case SPDisplayTimerOutcome::waiting: return @"premature-wake-rearmed";
        case SPDisplayTimerOutcome::staleToken: return @"stale-token";
        case SPDisplayTimerOutcome::noCurrentSlot: return @"no-current-slot";
        case SPDisplayTimerOutcome::retired: return @"retired-context";
        case SPDisplayTimerOutcome::gpuBusy: return @"gpu-busy";
        case SPDisplayTimerOutcome::expiredConsume: return @"expired-consume";
        case SPDisplayTimerOutcome::expiredReplaced: return @"expired-callback-replaced";
    }
}

static NSDictionary *SPAirSlotCallbackExport(const std::vector<SPAirSlotCallbackEvent> &values, uint64_t total, int64_t cutoff) {
    NSMutableArray *events = [NSMutableArray arrayWithCapacity:values.size()];
    NSArray *reasons = @[@"none", @"wrong-link", @"drawable-invisible", @"zero-generation", @"nonfinite-target-timestamp", @"nonfinite-target-presentation-timestamp", @"display-not-after-deadline", @"deadline-already-reached"];
    for (const auto &e : values) {
        if (e.outcomeHostTicks > cutoff) continue;
        [events addObject:@{ @"sequence": @(e.sequence), @"entryHostTicks": @(e.entryHostTicks), @"outcomeHostTicks": @(e.outcomeHostTicks), @"entryMediaNs": @(e.entryMediaNs),
            @"targetTimestampMediaSeconds": std::isfinite(e.targetTimestampMediaSeconds) ? @(e.targetTimestampMediaSeconds) : (id)NSNull.null,
            @"targetPresentationTimestampMediaSeconds": std::isfinite(e.targetPresentationTimestampMediaSeconds) ? @(e.targetPresentationTimestampMediaSeconds) : (id)NSNull.null,
            @"outcome": e.outcome == SPAirSlotCallbackOutcome::createdToken ? @"created-token" : (e.outcome == SPAirSlotCallbackOutcome::busy ? @"busy" : @"entry-rejected"),
            @"entryRejectReason": reasons[(NSUInteger)e.reject], @"createdToken": e.createdToken ? @(e.createdToken) : (id)NSNull.null,
            @"observedToken": e.contextUnderPresentationMutex ? @(e.observedToken) : (id)NSNull.null,
            @"generation": @(e.generation), @"configVersion": @(e.config), @"measurementEpoch": @(e.epoch), @"clockEpoch": @(e.clock),
            @"contextUnderPresentationMutex": @(e.contextUnderPresentationMutex) }];
    }
    return SPAirRingMetadata(total, SPAirSlotCallbackRing::capacity, events);
}
static NSDictionary *SPAirSlotConsumeExport(const std::vector<SPAirSlotConsumeEvent> &values, uint64_t total, int64_t cutoff) {
    NSMutableArray *events = [NSMutableArray arrayWithCapacity:values.size()];
    for (const auto &e : values) {
        if (e.recordHostTicks > cutoff) continue;
        NSArray *origins = @[@"timer-attempt", @"callback-replaced-expired-slot", @"callback-retired-context", @"visibility-retired-slot", @"context-cleanup-retired-slot"];
        [events addObject:@{ @"sequence": @(e.sequence), @"token": @(e.token), @"observedToken": @(e.observedToken), @"frameID": e.frameID ? @(e.frameID) : (id)NSNull.null,
            @"origin": origins[(NSUInteger)e.origin], @"terminalDisposition": @(e.terminal),
            @"prematureWakeCount": @(e.prematureWakeCount), @"prematureWakeCountSaturated": @(e.prematureWakeCountSaturated),
            @"entryHostTicks": e.entryHostTicks ? @(e.entryHostTicks) : (id)NSNull.null, @"recordHostTicks": @(e.recordHostTicks),
            @"handlerEntryMediaNs": e.origin == SPAirSlotOrigin::timerAttempt ? @(e.handlerEntryMediaNs) : (id)NSNull.null,
            @"lockAcquiredMediaNs": e.origin == SPAirSlotOrigin::timerAttempt ? @(e.lockAcquiredMediaNs) : (id)NSNull.null,
            @"plannedSelectionMediaNs": @(e.plannedSelectionMediaNs), @"deadlineMediaNs": @(e.deadlineMediaNs), @"displayTimeMediaNs": @(e.displayTimeMediaNs),
            @"outcome": SPDisplayTimerOutcomeName((SPDisplayTimerOutcome)e.outcome), @"generation": @(e.generation), @"configVersion": @(e.config), @"measurementEpoch": @(e.epoch), @"clockEpoch": @(e.clock),
            @"currentGeneration": @(e.currentGeneration), @"currentConfigVersion": @(e.currentConfig), @"currentMeasurementEpoch": @(e.currentEpoch), @"currentClockEpoch": @(e.currentClock) }];
    }
    return SPAirRingMetadata(total, SPAirSlotConsumeRing::capacity, events);
}
static NSDictionary *SPAirSlotSnapshotExport(SPAirSlotSnapshot snapshot) {
    return @{ @"sampleHostTicks": snapshot.sampleHostTicks ? @(snapshot.sampleHostTicks) : (id)NSNull.null,
        @"pendingToken": snapshot.hasPending ? @(snapshot.token) : (id)NSNull.null,
        @"generation": snapshot.hasPending ? @(snapshot.generation) : (id)NSNull.null, @"configVersion": snapshot.hasPending ? @(snapshot.config) : (id)NSNull.null,
        @"measurementEpoch": snapshot.hasPending ? @(snapshot.epoch) : (id)NSNull.null, @"clockEpoch": snapshot.hasPending ? @(snapshot.clock) : (id)NSNull.null,
        @"deadlineMediaNs": snapshot.hasPending ? @(snapshot.deadlineMediaNs) : (id)NSNull.null, @"displayTimeMediaNs": snapshot.hasPending ? @(snapshot.displayTimeMediaNs) : (id)NSNull.null };
}

#if ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC
struct SPAirFusedRenderRecord {
    uint64_t sequence = 0, frameID = 0, generation = 0, config = 0, epoch = 0, clock = 0, slotToken = 0;
    int64_t selectionHostTicks = 0, requestStartHostTicks = 0, enqueueHostTicks = 0;
    int bufferWidth = 0, bufferHeight = 0, drawableWidth = 0, drawableHeight = 0;
    int referenceWidth = 2648, referenceHeight = 1668;
    std::array<double, 4> imageRect{};
    bool synthetic = false, counts = false, redraw = false, lanczosFragment = false;
    std::atomic<bool> gpuObserved{false}, presentedObserved{false}, publicationCancelled{false};
    std::atomic<uint32_t> gpuStatus{0};
    std::atomic<int64_t> completedHostTicks{0};
    std::atomic<double> gpuStartSeconds{0}, gpuEndSeconds{0}, completedMediaTime{0}, presentedTime{0};
    double displayTargetMediaTime = 0;
};
using SPAirFusedRenderPtr = std::shared_ptr<SPAirFusedRenderRecord>;
static constexpr size_t SPAirFusedRenderCapacity = 131072;
using SPAirFusedRenderNotes = std::array<SPAirFusedRenderPtr, SPAirFusedRenderCapacity>;

static NSArray *SPAirFusedRect(const SPAirFusedRenderPtr &record) {
    return record ? @[@(record->imageRect[0]), @(record->imageRect[1]), @(record->imageRect[2]), @(record->imageRect[3])] : nil;
}
static NSDictionary *SPAirFusedRenderExport(const SPAirFusedRenderPtr &record) {
    const bool gpu = record->gpuObserved.load(std::memory_order_acquire);
    const bool presented = record->presentedObserved.load(std::memory_order_acquire);
    const double start = record->gpuStartSeconds.load(), end = record->gpuEndSeconds.load();
    const bool validGPU = gpu && std::isfinite(start) && start > 0 && std::isfinite(end) && end >= start;
    return @{ @"sequence": @(record->sequence), @"frameID": @(record->frameID),
        @"generation": @(record->generation), @"configVersion": @(record->config),
        @"measurementEpoch": @(record->epoch), @"clockEpoch": @(record->clock),
        @"selectionHostTicks": @(record->selectionHostTicks), @"slotToken": @(record->slotToken),
        @"requestStartHostTicks": @(record->requestStartHostTicks), @"enqueueHostTicks": @(record->enqueueHostTicks),
        @"synthetic": @(record->synthetic),
        @"counts": @(record->counts), @"redraw": @(record->redraw),
        @"bufferPixels": @[@(record->bufferWidth), @(record->bufferHeight)],
        @"drawablePixels": @[@(record->drawableWidth), @(record->drawableHeight)],
        @"sourceReferencePixels": @[@(record->referenceWidth), @(record->referenceHeight)], @"outputRectPixels": SPAirFusedRect(record),
        @"fragment": record->lanczosFragment ? @"spAirPresentLanczos" : @"spPresentFragment",
        @"gpuObserved": @(gpu), @"gpuStatus": gpu ? @(record->gpuStatus.load()) : (id)NSNull.null,
        @"gpuStartSeconds": validGPU ? @(start) : (id)NSNull.null,
        @"gpuEndSeconds": validGPU ? @(end) : (id)NSNull.null,
        @"completedHostTicks": gpu ? @(record->completedHostTicks.load()) : (id)NSNull.null,
        @"completedMediaTime": gpu ? @(record->completedMediaTime.load()) : (id)NSNull.null,
        @"displayTargetMediaTime": @(record->displayTargetMediaTime),
        @"presentedObserved": @(presented),
        @"presentedTime": presented ? @(record->presentedTime.load()) : (id)NSNull.null,
        @"publicationCancelled": @(record->publicationCancelled.load()) };
}
#endif

@interface SPLivePreviewView () <CAMetalDisplayLinkDelegate>
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
@property (atomic, strong, nullable) SPPresentedVideoRecorder *presentedVideoRecorder;
#endif
- (void)setPresentedVideoReadbackEnabled:(BOOL)enabled;
- (void)setAirBetaCaptureWidth:(int)width height:(int)height;
- (NSDictionary *)fusedRifePresentationSnapshotIncludeRecords:(BOOL)includeRecords cutoffHostTicks:(int64_t)cutoff;
- (void)updateDisplayLinkConfiguration;
- (void)setPresentationClockEpoch:(uint64_t)clockEpoch;
- (void)prepareWarmSurface:(SPDisplayFrameRequest *)frame targetSize:(CGSize)size;
- (sp::DisplaySlotContext)displaySlotContext;
- (void)armDisplaySlotLocked:(uint64_t)token;
- (void)parkDisplaySlotTimerLocked;
- (void)resetAirDisplayPolicyLocked;
- (void)recordDisplayTimerTraceLocked:(SPDisplayTimerTrace)trace;
- (void)recordAirSlotTraceLocked:(SPDisplayTimerTrace)trace origin:(SPAirSlotOrigin)origin;
- (void)consumeDisplaySlot:(sp::DisplaySlotWindow)armedSlot;
- (int64_t)presentationPreparationLeadNs;
- (NSDictionary *)displaySlotDiagnostics;
- (NSDictionary *)preparedTextureCountersSnapshot;
- (void)discardOutdatedPresentations;
- (void)reportPendingPresentation:(SPDisplayFrameRequest *)frame reason:(NSString *)reason;
- (void)renderPendingPresentation:(SPDisplayFrameRequest *)frame slot:(SPProspectiveDisplaySlot *)slot selectionHost:(int64_t)selectionHost;
- (void)observeSourceGeometry:(NSDictionary *)value generation:(uint64_t)generation;
- (CVMetalTextureRef)createTexture:(CVPixelBufferRef)buffer apiStartedHostTicks:(int64_t *)started apiEndedHostTicks:(int64_t *)ended;
- (NSDictionary *)runPreparedTextureLifetimeProbe;
- (void)copyAirCadenceEvents:(std::vector<SPAirFrameEvent> *)events total:(uint64_t *)total;
- (void)copyAirCadenceEvents:(std::vector<SPAirFrameEvent> *)events total:(uint64_t *)total
    consumes:(std::vector<SPAirSlotConsumeEvent> *)consumes consumeTotal:(uint64_t *)consumeTotal snapshot:(SPAirSlotSnapshot *)snapshot;
- (BOOL)copyAirSlotCallbacks:(std::vector<SPAirSlotCallbackEvent> *)events total:(uint64_t *)total
    mainCallerSynchronouslyOnProcessorQueue:(BOOL)safe unsupported:(uint64_t *)unsupported;
@end

@implementation SPLivePreviewView {
    CAMetalLayer *_metalLayer;
    CALayer *_sourceCover;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;
    CAMetalDisplayLink *_displayLink;
    dispatch_queue_t _renderQueue;
    dispatch_source_t _displaySlotTimer;
    std::array<SPDisplayTimerTrace, 64> _displayTimerTrace;
    uint64_t _displayTimerTraceCount;
    std::atomic<uint64_t> _displaySlotExpiredInConsume, _displaySlotExpiredByCallback;
    SPProspectiveDisplaySlot *_prospectiveSlot;
    uint64_t _nextDisplaySlotToken;
    std::atomic<int64_t> _displayPreparationLeadNs;
    spAirDisplayPolicyB::RefreshHistory _airDisplayRefreshHistory;
    spAirDisplayPolicyB::Decision _airRuleBLastDecision;
    uint64_t _airRuleBDecisionCount;
    std::size_t _airRuleBLastHistoryCount;
    std::atomic<uint64_t> _displaySlotExpired, _displaySlotRetired, _displaySlotBusy, _displaySlotNoFrame;
    std::mutex _presentationMutex;
    NSMutableArray<SPDisplayFrameRequest *> *_pendingPresentations;
    sp::SPRational _lastSubmittedPresentationPTS;
    bool _haveSubmittedPresentationPTS;
    id<MTLRenderPipelineState> _pipeline;
#if ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC
    BOOL _airFusedRifePresentDiagnostic;
    id<MTLRenderPipelineState> _airFusedPresentPipeline;
    std::mutex _airFusedNotesMutex;
    std::unique_ptr<SPAirFusedRenderNotes> _airFusedRenderNotes;
    uint64_t _airFusedRenderTotal;
    BOOL _airFusedTraceSealed;
    uint64_t _airFusedPostSealAttempts;
    SPAirFusedRenderPtr _airFusedLastPositiveOriginal, _airFusedLastPositiveSynthetic;
#endif
    CVMetalTextureCacheRef _cache;
    std::atomic<uint64_t> _generation;
    std::mutex _generationMutex;
    uint64_t _highestGeneration;
    uint64_t _revealedGeneration;
    std::atomic<bool> _windowVisible;
    std::atomic<bool> _drawableVisible;
    std::atomic<bool> _exposed;
    std::atomic<bool> _followTargetContent;
    std::atomic<uint32_t> _diagnosticDisplayID;
    std::atomic<uint64_t> _diagnosticConfig;
    std::atomic<uint64_t> _diagnosticEpoch;
    std::atomic<uint64_t> _presentationClockEpoch;
    std::atomic<bool> _warmSurfacePending;
    std::atomic<uint64_t> _surfaceToken;
    std::atomic<int> _inflightDraws;
    BOOL _airSessionObservationEnabled;
    std::atomic<uint64_t> _airPresentedCallbacksPending;
    std::atomic<uint64_t> _airCapacityViewSealedHostTicks;
    BOOL _airPresentationTimingDiagnostic;
    SPPreparedTextureMapper *_preparedTextures;
    BOOL _airPreparedTextureDiagnostic;
    spAirMeasurement::TracePtr _measurementTrace;
    std::atomic<bool> _airPerformanceEnabled;
    std::atomic<int64_t> _selectionGuardNs;
    int64_t _diagnosticSelectionGuardNs;
    std::unique_ptr<SPAirFrameRing> _airCadenceFrames;
    std::unique_ptr<SPAirSlotCallbackRing> _airSlotCallbacks; // main-thread writer only
    std::unique_ptr<SPAirSlotConsumeRing> _airSlotConsumes; // existing presentationMutex only
    std::atomic<uint64_t> _airSlotCallbackUnsupported;
#if ODF_AIR_BETA_DIAGNOSTIC
    std::atomic<int> _airBetaCaptureWidth, _airBetaCaptureHeight;
#endif
    std::mutex _geometryMutex;
    sp::SharedGeometryAuthority _sharedGeometry;
    int64_t _geometryVerifiedHost;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
#if ODF_AIR_BETA_DIAGNOSTIC
    _airBetaCaptureWidth.store(0); _airBetaCaptureHeight.store(0);
#endif
    const char *airTiming = getenv("ODF_AIR_PRESENTATION_TIMING_DIAGNOSTIC");
    _airPresentationTimingDiagnostic = airTiming && strcmp(airTiming, "1") == 0;
    if (SPAirCadenceCausalTraceRequested()) {
        _airCadenceFrames = std::make_unique<SPAirFrameRing>();
        _airSlotCallbacks = std::make_unique<SPAirSlotCallbackRing>(); _airSlotConsumes = std::make_unique<SPAirSlotConsumeRing>();
    }
    _airSlotCallbackUnsupported.store(0);
    if (SPAirFullMeasurementTraceRequested())
        _measurementTrace = std::make_shared<spAirMeasurement::Trace>(spAirMeasurement::viewCapacity);
    _airPerformanceEnabled.store(false);
    const BOOL legacyAirRecipe = SPAirBetaEnabled() ||
        (strcmp(getenv("ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC") ?: "", "1") == 0 &&
         strcmp(getenv("ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC") ?: "", "1") == 0 &&
         strcmp(getenv("ODF_AIR_RESIDENT_KEEPALIVE_DIAGNOSTIC") ?: "", "1") == 0);
    _diagnosticSelectionGuardNs = legacyAirRecipe ? 2000000 : 1000000;
    _selectionGuardNs.store(_diagnosticSelectionGuardNs);
    _generation.store(0);
    _highestGeneration = 0;
    _revealedGeneration = 0;
    _windowVisible.store(false);
    _drawableVisible.store(false);
    _exposed.store(false);
    _followTargetContent.store(false);
    _diagnosticDisplayID.store(0);
    _diagnosticConfig.store(0);
    _diagnosticEpoch.store(0);
    _presentationClockEpoch.store(0);
    _warmSurfacePending.store(false);
    _surfaceToken.store(0);
    _inflightDraws.store(0);
    _airSessionObservationEnabled = SPAirBetaSessionRecorderRequested();
    _airPresentedCallbacksPending.store(0);
    _airCapacityViewSealedHostTicks.store(0);
    _geometryVerifiedHost = 0;
    _nextDisplaySlotToken = 0;
    _displayPreparationLeadNs.store(16000000);
    _displaySlotExpired.store(0); _displaySlotRetired.store(0); _displaySlotBusy.store(0); _displaySlotNoFrame.store(0);
    _renderQueue = dispatch_queue_create("app.openduckframe.display-slot-render",
        dispatch_queue_attr_make_with_autorelease_frequency(
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0),
            DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM));
    _displayTimerTraceCount = 0;
    _displaySlotExpiredInConsume.store(0); _displaySlotExpiredByCallback.store(0);
    _displaySlotTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT, _renderQueue);
    if (_displaySlotTimer) {
        dispatch_source_set_timer(_displaySlotTimer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 50000);
        dispatch_resume(_displaySlotTimer); // activated once; later arms/parks never suspend it
    }
    _pendingPresentations = [NSMutableArray array];
    _haveSubmittedPresentationPTS = false;
    self.wantsLayer = YES;
    _device = MTLCreateSystemDefaultDevice();
#if defined(ODF_AIR_PRESENTATION_GUARD_DIAGNOSTIC) && ODF_AIR_PRESENTATION_GUARD_DIAGNOSTIC == 1
    const char *preparedTextures = getenv("ODF_AIR_PREPARED_TEXTURE_DIAGNOSTIC");
    _airPreparedTextureDiagnostic = preparedTextures && strcmp(preparedTextures, "1") == 0;
    if (_airPreparedTextureDiagnostic) _preparedTextures = [[SPPreparedTextureMapper alloc] initWithDevice:_device];
#endif
    _metalLayer = [CAMetalLayer layer];
    _metalLayer.device = _device;
    _metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    _metalLayer.framebufferOnly = YES;
    _metalLayer.contentsScale = 2;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceITUR_709);
    _metalLayer.colorspace = space;
    CGColorSpaceRelease(space);
    self.layer = _metalLayer;
    _sourceCover = [CALayer layer];
    _sourceCover.backgroundColor = NSColor.blackColor.CGColor;
    _sourceCover.hidden = YES;
    [_metalLayer addSublayer:_sourceCover];
    _commandQueue = [_device newCommandQueue];
    if (_device) CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, _device, NULL, &_cache);
    id<MTLLibrary> library = [_device newDefaultLibrary];
    id<MTLFunction> vertex = [library newFunctionWithName:@"spPresentVertex"];
    id<MTLFunction> fragment = [library newFunctionWithName:@"spPresentFragment"];
    if (vertex && fragment) {
        MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
        desc.vertexFunction = vertex;
        desc.fragmentFunction = fragment;
        desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        _pipeline = [_device newRenderPipelineStateWithDescriptor:desc error:NULL];
    }
#if ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC
    _airFusedRifePresentDiagnostic = strcmp(getenv("ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC") ?: "", "1") == 0 &&
        strcmp(getenv("ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC") ?: "", "1") == 0 &&
        strcmp(getenv("ODF_AIR_RESIDENT_KEEPALIVE_DIAGNOSTIC") ?: "", "1") == 0;
    if (SPAirCadenceCausalTraceRequested()) _airFusedRenderNotes = std::make_unique<SPAirFusedRenderNotes>();
    if (_airFusedRifePresentDiagnostic && vertex) {
        id<MTLFunction> fusedFragment = [library newFunctionWithName:@"spAirPresentLanczos"];
        if (fusedFragment) {
            MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
            desc.vertexFunction = vertex; desc.fragmentFunction = fusedFragment;
            desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
            _airFusedPresentPipeline = [_device newRenderPipelineStateWithDescriptor:desc error:NULL];
        }
    }
#endif
    if (_pipeline && _displaySlotTimer) {
        _displayLink = [[CAMetalDisplayLink alloc] initWithMetalLayer:_metalLayer];
        _displayLink.delegate = self;
        _displayLink.preferredFrameLatency = 1;
        _displayLink.paused = YES;
        [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    return self;
}

- (void)dealloc {
    [_displayLink invalidate];
    if (_displaySlotTimer) dispatch_source_cancel(_displaySlotTimer);
    if (_cache) CFRelease(_cache);
}

- (BOOL)setAirPerformanceEnabled:(BOOL)enabled captureWidth:(int)width captureHeight:(int)height {
#if ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC && ODF_AIR_BETA_DIAGNOSTIC
    if (enabled && !_airFusedPresentPipeline) {
        id<MTLLibrary> library = [_device newDefaultLibrary];
        id<MTLFunction> vertex = [library newFunctionWithName:@"spPresentVertex"];
        id<MTLFunction> fragment = [library newFunctionWithName:@"spAirPresentLanczos"];
        if (vertex && fragment) {
            MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
            descriptor.vertexFunction = vertex; descriptor.fragmentFunction = fragment;
            descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
            _airFusedPresentPipeline = [_device newRenderPipelineStateWithDescriptor:descriptor error:NULL];
        }
    }
    if (enabled && (!_airFusedPresentPipeline || !_pipeline)) return NO;
    if (enabled && !_preparedTextures) _preparedTextures = [[SPPreparedTextureMapper alloc] initWithDevice:_device];
    [self setAirBetaCaptureWidth:width height:height];
    _selectionGuardNs.store(enabled ? 2000000 : _diagnosticSelectionGuardNs);
    {
        std::lock_guard<std::mutex> lock(_presentationMutex);
        if (_airPerformanceEnabled.exchange(enabled, std::memory_order_acq_rel) != enabled)
            [self resetAirDisplayPolicyLocked];
    }
    return YES;
#else
    _airPerformanceEnabled.store(false);
    _selectionGuardNs.store(_diagnosticSelectionGuardNs);
    return !enabled;
#endif
}

- (BOOL)airPerformanceEnabled { return _airPerformanceEnabled.load(std::memory_order_acquire); }
- (int64_t)selectionGuardNs { return _selectionGuardNs.load(); }

- (void)setPresentedVideoReadbackEnabled:(BOOL)enabled {
#if ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC
    if (_airFusedRifePresentDiagnostic) _metalLayer.framebufferOnly = !enabled;
#endif
}

- (void)setAirBetaCaptureWidth:(int)width height:(int)height {
#if ODF_AIR_BETA_DIAGNOSTIC
    _airBetaCaptureWidth.store(width); _airBetaCaptureHeight.store(height);
#endif
}

- (NSDictionary *)fusedRifePresentationSnapshotIncludeRecords:(BOOL)includeRecords cutoffHostTicks:(int64_t)cutoff {
#if ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC
    if (!_airFusedRifePresentDiagnostic && ![self airPerformanceEnabled])
        return @{ @"compiled": @YES, @"enabled": @NO, @"lanczosPipelineReady": @(_airFusedPresentPipeline != nil) };
    const int64_t sampled = SPHostNow();
    uint64_t total = 0;
    SPAirFusedRenderPtr original, synthetic;
    std::vector<SPAirFusedRenderPtr> records;
    if (includeRecords) records.reserve(SPAirFusedRenderCapacity);
    {
        std::lock_guard<std::mutex> lock(_airFusedNotesMutex);
        total = _airFusedRenderTotal;
        original = _airFusedLastPositiveOriginal; synthetic = _airFusedLastPositiveSynthetic;
        if (includeRecords && _airFusedRenderNotes) {
            const uint64_t count = std::min(total, (uint64_t)SPAirFusedRenderCapacity);
            for (uint64_t index = total - count; index < total; index++)
                records.push_back((*_airFusedRenderNotes)[index % SPAirFusedRenderCapacity]);
        }
    }
    SPAirFusedRenderPtr latest = original;
    if (synthetic && (!latest || synthetic->sequence > latest->sequence)) latest = synthetic;
    NSMutableDictionary *result = [@{ @"schema": @"odf-air-fused-rife-presenter-v1", @"compiled": @YES, @"enabled": @YES,
        @"sampleHostTicks": @(sampled), @"exportCutoffHostTicks": @(cutoff), @"includeRecords": @(includeRecords),
        @"capacity": @(SPAirFusedRenderCapacity), @"total": @(total),
        @"dropped": @(total > SPAirFusedRenderCapacity ? total - SPAirFusedRenderCapacity : 0),
        @"sourceReferencePixels": latest ? @[@(latest->referenceWidth), @(latest->referenceHeight)] : (id)NSNull.null,
        @"lanczosPipelineReady": @(_airFusedPresentPipeline != nil),
        @"actualDrawablePixels": latest ? @[@(latest->drawableWidth), @(latest->drawableHeight)] : (id)NSNull.null,
        @"actualOriginalBufferPixels": original ? @[@(original->bufferWidth), @(original->bufferHeight)] : (id)NSNull.null,
        @"actualSyntheticBufferPixels": synthetic ? @[@(synthetic->bufferWidth), @(synthetic->bufferHeight)] : (id)NSNull.null,
        @"originalPresentedRect": SPAirFusedRect(original) ?: (id)NSNull.null,
        @"syntheticPresentedRect": SPAirFusedRect(synthetic) ?: (id)NSNull.null,
        @"originalFragment": original ? (original->lanczosFragment ? @"spAirPresentLanczos" : @"spPresentFragment") : (id)NSNull.null,
        @"syntheticFragment": synthetic ? (synthetic->lanczosFragment ? @"spAirPresentLanczos" : @"spPresentFragment") : (id)NSNull.null,
        @"rectsExactlyEqual": original && synthetic ? @(original->imageRect == synthetic->imageRect) : (id)NSNull.null,
        @"geometryFunction": (SPAirBetaEnabled() || [self airPerformanceEnabled]) ? @"sp::airBetaPresentationGeometry" : @"sp::airFusedPresentationGeometry",
        @"scope": @"Latest counted non-redraw positive drawable callbacks supply actual summary rectangles and dimensions. Full records retain actual encoded pipeline, buffer shape, drawable shape and rectangle with the request context. No physical screen pixel claim.",
        @"gpuTimingScope": @"Metal GPU start/end seconds are raw command-buffer residency times. completedHostTicks and completedMediaTime are CPU completion-handler observations, after actual GPU completion. No absolute GPU-to-Media or GPU-to-mach subtraction is assumed. Their CPU callback margin can provide a conservative lower bound under the existing same-context clock bounds.",
        @"cutoffScope": @"Record inclusion uses selectionHostTicks<=exportCutoffHostTicks. Atomic GPU/presented terminal observations are sampled at export and can be later than that cutoff. They cannot replenish frozen admission or positive-presentation numerators. Unobserved GPU or presentation state is null." } mutableCopy];
    if (includeRecords) {
        NSMutableArray *rows = [NSMutableArray arrayWithCapacity:records.size()];
        for (const auto &record : records) if (record && record->selectionHostTicks <= cutoff) [rows addObject:SPAirFusedRenderExport(record)];
        result[@"records"] = rows; result[@"exportedCount"] = @(rows.count);
    }
    return result;
#else
    return @{ @"compiled": @NO, @"enabled": @NO };
#endif
}

- (void)layout {
    [super layout];
    CGSize oldSize = _metalLayer.drawableSize;
    _metalLayer.contentsScale = self.window.backingScaleFactor ?: NSScreen.mainScreen.backingScaleFactor ?: 2;
    _metalLayer.frame = self.bounds;
    _sourceCover.frame = self.bounds;
    _metalLayer.drawableSize = CGSizeMake(MAX(1, self.bounds.size.width * _metalLayer.contentsScale),
                                          MAX(1, self.bounds.size.height * _metalLayer.contentsScale));
    if (!CGSizeEqualToSize(oldSize, _metalLayer.drawableSize)) {
        std::lock_guard<std::mutex> lock(_geometryMutex); _sharedGeometry.observeTarget({}, false);
    }
    [self refreshVisibilitySnapshot];
}

- (void)refreshVisibilitySnapshot {
    NSAssert(NSThread.isMainThread, @"AppKit visibility must be read on the main thread");
    NSWindow *window = self.window;
    BOOL visible = window != nil && window.isVisible && !self.isHiddenOrHasHiddenAncestor;
    BOOL drawable = visible && (window.occlusionState & NSWindowOcclusionStateVisible) != 0;
    _windowVisible.store(visible);
    _drawableVisible.store(drawable);
    _exposed.store(visible && window.alphaValue >= 0.99);
    _diagnosticDisplayID.store([window.screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue]);
    [self updateDisplayLinkConfiguration];
    if (!drawable || window.alphaValue < 0.99) {
        std::lock_guard<std::mutex> lock(_geometryMutex);
        _sharedGeometry.observeTarget({}, false);
    }
}

- (BOOL)windowVisibleSnapshot { return _windowVisible.load(); }
- (BOOL)drawableVisibleSnapshot { return _drawableVisible.load(); }
- (BOOL)exposedSnapshot { return _exposed.load(); }

- (void)setGeneration:(uint64_t)generation {
    uint64_t old;
    {
        std::lock_guard<std::mutex> lock(_generationMutex);
        // Zero closes presentation on stop but does not erase the source
        // high-water mark. Resume may re-open the same generation; an older
        // queued adoption can never roll the view back after a newer source.
        if (generation && generation < _highestGeneration) return;
        if (generation > _highestGeneration) _highestGeneration = generation;
        std::lock_guard<std::mutex> pendingLock(_presentationMutex);
        old = _generation.exchange(generation);
        if (generation != old) { _haveSubmittedPresentationPTS = false; [self resetAirDisplayPolicyLocked]; }
    }
    if (generation != old) {
        { std::lock_guard<std::mutex> lock(_geometryMutex); _sharedGeometry.invalidate(); }
        [self discardOutdatedPresentations];
        if (NSThread.isMainThread) [self updateDisplayLinkConfiguration];
        else dispatch_async(dispatch_get_main_queue(), ^{ [self updateDisplayLinkConfiguration]; });
    }
    if (!generation || generation == old) return;
    void (^cover)(void) = ^{ [self applySourceCoverForGeneration:generation]; };
    if (NSThread.isMainThread) cover(); else dispatch_async(dispatch_get_main_queue(), cover);
}

- (void)applySourceCoverForGeneration:(uint64_t)generation {
    NSAssert(NSThread.isMainThread, @"preview cover must be updated on the main thread");
    std::lock_guard<std::mutex> lock(_generationMutex);
    // A presented callback for this generation can run before the cover
    // dispatched by its adoption; a late cover must not obscure that frame.
    if (_generation.load() != generation || _revealedGeneration == generation) return;
    [CATransaction begin]; [CATransaction setDisableActions:YES]; _sourceCover.hidden = NO; [CATransaction commit];
}

- (void)revealSourceGeneration:(uint64_t)generation {
    NSAssert(NSThread.isMainThread, @"preview cover must be updated on the main thread");
    std::lock_guard<std::mutex> lock(_generationMutex);
    if (_generation.load() != generation) return;
    _revealedGeneration = generation;
    [CATransaction begin]; [CATransaction setDisableActions:YES]; _sourceCover.hidden = YES; [CATransaction commit];
}

- (BOOL)sourceCoverVisibleForTesting { return !_sourceCover.hidden; }

- (void)setDiagnosticsConfig:(uint64_t)config epoch:(uint64_t)epoch {
    uint64_t oldConfig, oldEpoch;
    {
        std::lock_guard<std::mutex> generationLock(_generationMutex);
        std::lock_guard<std::mutex> pendingLock(_presentationMutex);
        oldConfig = _diagnosticConfig.exchange(config); oldEpoch = _diagnosticEpoch.exchange(epoch);
        if (_airCadenceFrames && (oldConfig != config || oldEpoch != epoch)) {
            SPAirFrameEvent event = SPAirFrameRecord(nil, SPAirFrameKind::configurationMarker, SPAirFrameReason::configuration, SPAirFrameStage::cleanup);
            event.generation = _generation.load(); event.config = config; event.epoch = epoch; event.clock = _presentationClockEpoch.load();
            event.previousConfig = oldConfig; event.previousEpoch = oldEpoch; _airCadenceFrames->append(event);
        }
        if (oldConfig != config || oldEpoch != epoch) { _haveSubmittedPresentationPTS = false; [self resetAirDisplayPolicyLocked]; }
    }
    if (oldConfig != config || oldEpoch != epoch) {
        { std::lock_guard<std::mutex> lock(_geometryMutex); _sharedGeometry.invalidate(); }
        [self discardOutdatedPresentations];
    }
}

- (void)setPresentationClockEpoch:(uint64_t)clockEpoch {
    bool changed;
    {
        std::lock_guard<std::mutex> generationLock(_generationMutex);
        std::lock_guard<std::mutex> pendingLock(_presentationMutex);
        changed = _presentationClockEpoch.exchange(clockEpoch) != clockEpoch;
        if (changed) { _haveSubmittedPresentationPTS = false; [self resetAirDisplayPolicyLocked]; }
    }
    if (changed) { [self invalidateSharedGeometry]; [self discardOutdatedPresentations]; }
}

- (void)observeSourceGeometry:(NSDictionary *)value generation:(uint64_t)generation {
    sp::GeometrySource source{};
    BOOL valid=SPSourceGeometryValue(value, source) && source.generation==generation;
    std::lock_guard<std::mutex> lock(_geometryMutex);
    if (_generation.load()!=generation || !generation) return;
    _sharedGeometry.observeSource(source, valid);
}

- (void)observeVerifiedWindowGeometry:(NSDictionary *)value {
    NSAssert(NSThread.isMainThread, @"target verification must use the main thread");
    sp::GeometryTarget target{};
    BOOL valid=SPTargetGeometryValue(value, target) && target.verified && target.generation==_generation.load() &&
        target.config==_diagnosticConfig.load() && target.epoch==_diagnosticEpoch.load();
    std::lock_guard<std::mutex> lock(_geometryMutex);
    valid = valid && target.generation==_generation.load() && target.config==_diagnosticConfig.load() && target.epoch==_diagnosticEpoch.load();
    if (_geometryVerifiedHost > 0 && SPHostToNs(SPHostNow()-_geometryVerifiedHost)>350000000LL)
        _sharedGeometry.observeTarget({}, false); // expiry cannot resurrect an old presented ticket
    _sharedGeometry.observeTarget(target, valid);
    _geometryVerifiedHost = valid ? SPHostNow() : 0;
}

- (void)invalidateSharedGeometry {
    std::lock_guard<std::mutex> lock(_geometryMutex);
    _sharedGeometry.invalidate(); _geometryVerifiedHost=0;
}

- (NSDictionary *)sharedGeometrySnapshot {
    std::lock_guard<std::mutex> lock(_geometryMutex);
    auto g = _sharedGeometry.active();
    if (!g.valid || g.generation!=_generation.load() || g.config!=_diagnosticConfig.load() || g.epoch!=_diagnosticEpoch.load() ||
        g.displayID!=_diagnosticDisplayID.load() || _geometryVerifiedHost<=0 || SPHostToNs(SPHostNow()-_geometryVerifiedHost)>350000000LL)
        return @{ @"valid": @NO, @"version": [NSNull null], @"routingPermitted": @NO };
    auto rect=[](sp::GeometryRect r) -> NSArray * { return @[@(r.x),@(r.y),@(r.width),@(r.height)]; };
    return @{ @"valid": @YES, @"version": @(g.version), @"generation": @(g.generation), @"config": @(g.config),
        @"routingPermitted": @NO, @"scope": @"verified metadata and presented geometry; real input compatibility not established",
        @"measurementEpoch": @(g.epoch), @"windowID": @(g.windowID), @"pid": @(g.pid), @"displayID": @(g.displayID),
        @"presentedFrameID": @(g.frameID), @"captureHost": @(g.captureHost), @"verifiedHost": @(_geometryVerifiedHost),
        @"screenRectQuartz": rect(g.sourceScreenRect), @"contentRectSurfacePoints": rect(g.sourceContentRect),
        @"windowBoundsQuartz": rect(g.sourceWindowBounds),
        @"sourceBufferPixels": @[@(g.sourceBufferWidth),@(g.sourceBufferHeight)], @"scaleFactor": @(g.scaleFactor),
        @"contentScale": @(g.contentScale), @"panelFrameAppKitPoints": rect(g.panelFrame), @"displayFrameAppKitPoints": rect(g.displayFrame),
        @"displayBoundsQuartz": rect(g.displayBoundsQuartz),
        @"drawablePixels": @[@(g.drawableWidth),@(g.drawableHeight)], @"outputImageRectPixels": rect(g.render.image),
        @"sourceCropQuartz": rect(g.input.sourceCrop) };
}

- (NSDictionary<NSString *, NSNumber *> *)mapOutputPixel:(NSPoint)point geometryVersion:(uint64_t)version {
    std::lock_guard<std::mutex> lock(_geometryMutex);
    auto g = _sharedGeometry.active(); sp::GeometryPoint result{};
    if (!g.valid || g.generation!=_generation.load() || g.config!=_diagnosticConfig.load() || g.epoch!=_diagnosticEpoch.load() ||
        g.displayID!=_diagnosticDisplayID.load() || _geometryVerifiedHost<=0 || SPHostToNs(SPHostNow()-_geometryVerifiedHost)>350000000LL ||
        !sp::outputToSource(g.input,version,{point.x,point.y},result)) return nil;
    return @{ @"x": @(result.x), @"y": @(result.y), @"version": @(version) };
}

- (NSDictionary<NSString *, NSNumber *> *)mapQuartzOutputPoint:(CGPoint)point geometryVersion:(uint64_t)version clamp:(BOOL)clamp {
    std::lock_guard<std::mutex> lock(_geometryMutex);
    auto g = _sharedGeometry.active(); sp::GeometryPoint result{};
    if (!g.valid || g.generation!=_generation.load() || g.config!=_diagnosticConfig.load() || g.epoch!=_diagnosticEpoch.load() ||
        g.displayID!=_diagnosticDisplayID.load() || _geometryVerifiedHost<=0 || SPHostToNs(SPHostNow()-_geometryVerifiedHost)>350000000LL ||
        !sp::mapQuartzOutputToSource(g,version,{point.x,point.y},clamp,result)) return nil;
    return @{ @"x": @(result.x), @"y": @(result.y), @"version": @(version) };
}

+ (NSDictionary<NSString *, id> *)runSharedGeometryBridgeContract {
    __block SPLivePreviewView *view=nil;
    void (^makeView)(void) = ^{ view=[[SPLivePreviewView alloc] initWithFrame:NSMakeRect(0,0,640,480)]; };
    if (NSThread.isMainThread) makeView(); else dispatch_sync(dispatch_get_main_queue(), makeView);
    [view setGeneration:3]; [view setDiagnosticsConfig:4 epoch:5]; view->_diagnosticDisplayID.store(8);
    NSDictionary *source=@{ @"generation":@3, @"windowID":@101, @"pid":@77, @"bufferWidth":@1280, @"bufferHeight":@960,
        @"screenRect":@[@100,@200,@640,@480], @"contentRect":@[@0,@0,@640,@480], @"scaleFactor":@2, @"contentScale":@1 };
    NSDictionary *target=@{ @"generation":@3, @"windowID":@101, @"pid":@77, @"config":@4, @"epoch":@5, @"displayID":@8,
        @"screenRect":@[@100,@200,@640,@480], @"windowBounds":@[@100,@168,@640,@512],
        @"panelFrame":@[@(-640),@0,@640,@480], @"displayFrame":@[@(-1920),@0,@1920,@1080],
        @"displayBoundsQuartz":@[@(-1920),@0,@1920,@1080], @"backingScale":@2, @"verified":@YES };
    [view observeSourceGeometry:source generation:3];
    void (^verify)(void) = ^{ [view observeVerifiedWindowGeometry:target]; };
    if (NSThread.isMainThread) verify(); else dispatch_sync(dispatch_get_main_queue(), verify);
    sp::GeometrySource frame{}; BOOL parsed=SPSourceGeometryValue(source,frame);
    sp::SharedGeometry pending{};
    { std::lock_guard<std::mutex> lock(view->_geometryMutex);
      pending=view->_sharedGeometry.candidate(frame,3,4,5,8,1280,960,1280,960,false); }
    BOOL pendingInvisible=![[view sharedGeometrySnapshot][@"valid"] boolValue];
    { std::lock_guard<std::mutex> lock(view->_geometryMutex); (void)view->_sharedGeometry.activate(pending.version,25,100); }
    NSDictionary *first=[view sharedGeometrySnapshot]; NSDictionary *mapped=[view mapOutputPixel:NSMakePoint(640,480) geometryVersion:pending.version];
    BOOL valid=parsed && pending.valid && [first[@"valid"] boolValue] && [first[@"presentedFrameID"] unsignedLongLongValue]==25 &&
        fabs([mapped[@"x"] doubleValue]-420)<.001 && fabs([mapped[@"y"] doubleValue]-440)<.001;
    [view observeSourceGeometry:nil generation:2];
    BOOL staleIgnored=[[view sharedGeometrySnapshot][@"valid"] boolValue];
    { std::lock_guard<std::mutex> lock(view->_geometryMutex); view->_geometryVerifiedHost=1; }
    BOOL expired=![[view sharedGeometrySnapshot][@"valid"] boolValue];
    if (NSThread.isMainThread) verify(); else dispatch_sync(dispatch_get_main_queue(), verify);
    expired=expired && ![[view sharedGeometrySnapshot][@"valid"] boolValue] && ![view mapOutputPixel:NSMakePoint(640,480) geometryVersion:pending.version];
    { std::lock_guard<std::mutex> lock(view->_geometryMutex);
      pending=view->_sharedGeometry.candidate(frame,3,4,5,8,1280,960,1280,960,false);
      expired=expired && pending.valid && view->_sharedGeometry.activate(pending.version,26,101); }
    NSMutableDictionary *moved=[source mutableCopy]; moved[@"screenRect"]=@[@110,@200,@640,@480];
    [view observeSourceGeometry:moved generation:3];
    BOOL invalidated=![[view sharedGeometrySnapshot][@"valid"] boolValue] && ![view mapOutputPixel:NSMakePoint(640,480) geometryVersion:pending.version];
    BOOL ok=valid && pendingInvisible && staleIgnored && expired && invalidated;
    return @{ @"ok":@(ok), @"candidateNotActiveBeforePresentation":@(pendingInvisible), @"matchingMap":@(valid),
        @"staleGenerationIgnored":@(staleIgnored), @"expiredCannotResurrect":@(expired), @"moveRevokesVersion":@(invalidated),
        @"scope":@"actual view metadata/authority bridge and inverse transform; no real window, SCK, drawable or GUI input" };
}

- (void)setSurfaceToken:(uint64_t)token { _surfaceToken.store(token); }
- (void)setFollowTargetContent:(BOOL)follow {
    if (_followTargetContent.exchange(follow) != follow) [self invalidateSharedGeometry];
}

- (CVMetalTextureRef)createTexture:(CVPixelBufferRef)buffer {
    return [self createTexture:buffer apiStartedHostTicks:nullptr apiEndedHostTicks:nullptr];
}

- (CVMetalTextureRef)createTexture:(CVPixelBufferRef)buffer apiStartedHostTicks:(int64_t *)started apiEndedHostTicks:(int64_t *)ended {
    if (!buffer || !_cache) return NULL;
    CVMetalTextureRef ref = NULL;
    const size_t width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer);
    if (started) *started = SPHostNow();
    CVReturn result = CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, _cache, buffer, NULL, MTLPixelFormatBGRA8Unorm,
        width, height, 0, &ref);
    if (ended) *ended = SPHostNow();
    if (result != kCVReturnSuccess || !ref) return NULL;
    return ref;
}

- (void)writeQuad:(float *)v viewportWidth:(float)pw height:(float)ph frameWidth:(float)fw frameHeight:(float)fh fill:(BOOL)fill
        geometry:(const sp::OutputGeometry *)shared {
    const auto geometry = shared && shared->valid ? *shared : sp::outputGeometry({0,0,pw,ph},{0,0,fw,fh},fill,1);
    const auto fallback = sp::outputQuad(pw, ph, fw, fh, fill);
    float hw = geometry.valid ? (float)(geometry.image.width / pw) : fallback.halfWidth;
    float hh = geometry.valid ? (float)(geometry.image.height / ph) : fallback.halfHeight;
    float xyuv[16] = {
        -hw, -hh, 0, 1,
         hw, -hh, 1, 1,
        -hw,  hh, 0, 0,
         hw,  hh, 1, 0,
    };
    memcpy(v, xyuv, sizeof(xyuv));
}

- (void)drawTexture:(id<MTLTexture>)texture
         frameWidth:(float)fw
        frameHeight:(float)fh
           viewport:(MTLViewport)viewport
             buffer:(id<MTLCommandBuffer>)command
           drawable:(id<CAMetalDrawable>)drawable
               fill:(BOOL)fill {
    [self drawTexture:texture frameWidth:fw frameHeight:fh viewport:viewport buffer:command drawable:drawable fill:fill geometry:nullptr];
}

- (void)drawTexture:(id<MTLTexture>)texture
         frameWidth:(float)fw frameHeight:(float)fh viewport:(MTLViewport)viewport
             buffer:(id<MTLCommandBuffer>)command drawable:(id<CAMetalDrawable>)drawable
               fill:(BOOL)fill geometry:(const sp::OutputGeometry *)geometry {
    [self drawTexture:texture frameWidth:fw frameHeight:fh viewport:viewport buffer:command
        drawable:drawable fill:fill geometry:geometry pipeline:_pipeline];
}

- (void)drawTexture:(id<MTLTexture>)texture
         frameWidth:(float)fw frameHeight:(float)fh viewport:(MTLViewport)viewport
             buffer:(id<MTLCommandBuffer>)command drawable:(id<CAMetalDrawable>)drawable
               fill:(BOOL)fill geometry:(const sp::OutputGeometry *)geometry
           pipeline:(id<MTLRenderPipelineState>)pipeline {
    float quad[16];
    [self writeQuad:quad viewportWidth:(float)viewport.width height:(float)viewport.height frameWidth:fw frameHeight:fh fill:fill geometry:geometry];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> enc = [command renderCommandEncoderWithDescriptor:pass];
    [enc setViewport:viewport];
    [enc setRenderPipelineState:pipeline];
    [enc setVertexBytes:quad length:sizeof(quad) atIndex:0];
    [enc setFragmentTexture:texture atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [enc endEncoding];
}

+ (NSDictionary *)runPreparedTextureLifetimeProbe {
    __block SPLivePreviewView *view = nil;
    void (^makeView)(void) = ^{ view = [[SPLivePreviewView alloc] initWithFrame:NSMakeRect(0, 0, 64, 64)]; };
    if (NSThread.isMainThread) makeView(); else dispatch_sync(dispatch_get_main_queue(), makeView);
    return [view runPreparedTextureLifetimeProbe];
}

- (NSDictionary *)runPreparedTextureLifetimeProbe {
    if (!_preparedTextures) return @{ @"ok": @NO, @"enabled": @NO, @"reason": @"requires diagnostic guard build and ODF_AIR_PREPARED_TEXTURE_DIAGNOSTIC=1" };
    NSDictionary *attrs = @{ (id)kCVPixelBufferWidthKey:@64, (id)kCVPixelBufferHeightKey:@64,
        (id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA), (id)kCVPixelBufferIOSurfacePropertiesKey:@{}, (id)kCVPixelBufferMetalCompatibilityKey:@YES };
    NSDictionary *limit = @{ (id)kCVPixelBufferPoolAllocationThresholdKey:@1 };
    CVPixelBufferPoolRef pool = NULL; CVPixelBufferRef first = NULL, candidate = NULL;
    CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)attrs, &pool);
    CVReturn created = pool ? CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, (__bridge CFDictionaryRef)limit, &first) : kCVReturnError;
    if (created != kCVReturnSuccess || !first || !_pipeline) { if (first) CVPixelBufferRelease(first); if (pool) CFRelease(pool); return @{ @"ok":@NO, @"reason":@"prepared probe pixel pool/pipeline setup" }; }
    CVPixelBufferLockBaseAddress(first, 0);
    for (size_t y = 0; y < 64; ++y) {
        uint8_t *row = (uint8_t *)CVPixelBufferGetBaseAddress(first) + y * CVPixelBufferGetBytesPerRow(first);
        for (size_t x = 0; x < 64; ++x) { row[x*4] = 0; row[x*4+1] = 0; row[x*4+2] = 255; row[x*4+3] = 255; }
    }
    CVPixelBufferUnlockBaseAddress(first, 0);
    NSMutableArray<SPDisplayFrameRequest *> *frames = [NSMutableArray array]; BOOL capacityBounded = YES;
    for (uint64_t i = 0; i < 5; ++i) {
        SPDisplayFrameRequest *frame = [SPDisplayFrameRequest new]; frame.enhanced = CVPixelBufferRetain(first);
        frame.generation = 1; frame.config = 1; frame.epoch = 1; frame.clockEpoch = 1; frame.frameID = 9000 + i; frame.mode = SPLiveViewEnhanced;
        SPPreparedTextureLease *lease = [_preparedTextures prepareFrame:frame];
        if (i < 4) { capacityBounded = capacityBounded && lease != nil; [frames addObject:frame]; }
        else capacityBounded = capacityBounded && lease == nil && frame.preparedTextureAdmissionReason == SPPreparedCapacity;
    }
    CVPixelBufferRelease(first); first = NULL;
    [_preparedTextures fenceForProbe];
    SPDisplayFrameRequest *frame = frames.firstObject;
    int claimReason = SPPreparedNone;
    SPPreparedTextureLease *lease = [_preparedTextures claimFrame:frame recordSelection:NO reason:&claimReason];
    id<MTLTexture> mapped = [lease primaryTexture];
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:64 mipmapped:NO];
    desc.usage = MTLTextureUsageRenderTarget; desc.storageMode = MTLStorageModeShared;
    id<MTLTexture> output = [_device newTextureWithDescriptor:desc];
    id<MTLSharedEvent> event = [_device newSharedEvent]; id<MTLCommandBuffer> command = [_commandQueue commandBuffer];
    BOOL blocked = NO, reusable = NO, gpuCompleted = NO, sampledRed = NO;
    const BOOL setup = lease && mapped && output && event && command;
    if (setup) {
        [command encodeWaitForEvent:event value:1];
        SPProbeDrawable *surface = [SPProbeDrawable new]; surface.texture = output;
        MTLRenderPassDescriptor *clear = [MTLRenderPassDescriptor renderPassDescriptor];
        clear.colorAttachments[0].texture = output; clear.colorAttachments[0].loadAction = MTLLoadActionClear;
        clear.colorAttachments[0].storeAction = MTLStoreActionStore; [[command renderCommandEncoderWithDescriptor:clear] endEncoding];
        MTLViewport full = {0,0,64,64,0,1};
        [self drawTexture:mapped frameWidth:64 frameHeight:64 viewport:full buffer:command drawable:(id<CAMetalDrawable>)surface fill:YES];
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [command addCompletedHandler:^(id<MTLCommandBuffer> completed) { (void)completed; [lease complete]; dispatch_semaphore_signal(done); }];
        [command commit];
        // Drop every request and its original pixel-buffer retain. Only the
        // inflight lease/texture ownership protects the source until completion.
        frame = nil; [frames removeAllObjects]; [_preparedTextures fenceForProbe];
        CVReturn busy = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, (__bridge CFDictionaryRef)limit, &candidate);
        blocked = busy == kCVReturnWouldExceedAllocationThreshold && event.signaledValue == 0;
        if (candidate) { CVPixelBufferRelease(candidate); candidate = NULL; }
        event.signaledValue = 1;
        const BOOL completedInTime = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0;
        gpuCompleted = completedInTime && command.status == MTLCommandBufferStatusCompleted;
        if (gpuCompleted) {
            uint8_t pixels[64*64*4] = {};
            [output getBytes:pixels bytesPerRow:64*4 fromRegion:MTLRegionMake2D(0,0,64,64) mipmapLevel:0];
            const size_t center = (32*64+32)*4; sampledRed = pixels[center+2] > 240 && pixels[center+1] < 10 && pixels[center] < 10;
        }
        mapped = nil; command = nil;
        if (completedInTime) {
            [_preparedTextures fenceForProbe];
            CVReturn available = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, (__bridge CFDictionaryRef)limit, &candidate);
            reusable = available == kCVReturnSuccess && candidate != NULL;
            if (candidate) { CVPixelBufferRelease(candidate); candidate = NULL; }
        }
    } else { [lease complete]; frame = nil; [frames removeAllObjects]; [_preparedTextures fenceForProbe]; }
    if (pool) CFRelease(pool);
    NSDictionary *stats = [_preparedTextures snapshot];
    const BOOL clean = [stats[@"outstanding"] unsignedLongLongValue] == 0 && [stats[@"peakOutstanding"] unsignedLongLongValue] == 4 &&
        [stats[@"mapFailures"] unsignedLongLongValue] == 0 && [stats[@"textureFailures"] unsignedLongLongValue] == 0 && [stats[@"recycled"] unsignedLongLongValue] == 4;
    return @{ @"ok": @(capacityBounded && setup && blocked && gpuCompleted && sampledRed && reusable && clean), @"enabled": @YES,
        @"capacityBoundedAtFourAdmissions": @(capacityBounded), @"claimReason": SPPreparedTextureReasonName(claimReason),
        @"poolBlockedBeforeGPUCompletion": @(blocked), @"gpuCompleted": @(gpuCompleted), @"mappedTextureReadbackRed": @(sampledRed),
        @"poolReusableAfterGPUCompletionAndMapperFlush": @(reusable), @"preparedTexture": stats,
        @"scope": @"Bounded independent-cache offscreen GPU read/draw probe with one-buffer pool threshold, four prepared leases and fifth admission rejection. Requests are released before GPU wait is signalled; release/Flush are fenced on mapper queue. No drawable, SCK, model or physical display." };
}

- (NSDictionary *)runOffscreenDrawAndLifetimeProbe {
    if (_preparedTextures) return [self runPreparedTextureLifetimeProbe];
    MTLTextureDescriptor *outDesc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:32 mipmapped:NO];
    outDesc.usage=MTLTextureUsageRenderTarget; outDesc.storageMode=MTLStorageModeShared;
    id<MTLTexture> out=[_device newTextureWithDescriptor:outDesc];
    MTLTextureDescriptor *redDesc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:16 height:9 mipmapped:NO];
    redDesc.usage=MTLTextureUsageShaderRead; redDesc.storageMode=MTLStorageModeShared;
    MTLTextureDescriptor *greenDesc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:16 height:16 mipmapped:NO];
    greenDesc.usage=MTLTextureUsageShaderRead; greenDesc.storageMode=MTLStorageModeShared;
    id<MTLTexture> red=[_device newTextureWithDescriptor:redDesc], green=[_device newTextureWithDescriptor:greenDesc];
    if (!out||!red||!green||!_pipeline) return @{ @"ok":@NO, @"reason":@"metal setup" };
    uint8_t r[16*9*4],g[16*16*4];for(int i=0;i<16*9;i++){r[4*i]=0;r[4*i+1]=0;r[4*i+2]=255;r[4*i+3]=255;}
    for(int i=0;i<16*16;i++){g[4*i]=0;g[4*i+1]=255;g[4*i+2]=0;g[4*i+3]=255;}
    [red replaceRegion:MTLRegionMake2D(0,0,16,9) mipmapLevel:0 withBytes:r bytesPerRow:16*4];
    [green replaceRegion:MTLRegionMake2D(0,0,16,16) mipmapLevel:0 withBytes:g bytesPerRow:16*4];
    SPProbeDrawable *surface=[SPProbeDrawable new];surface.texture=out; id<MTLCommandBuffer> cmd=[_commandQueue commandBuffer];
    MTLRenderPassDescriptor *clear=[MTLRenderPassDescriptor renderPassDescriptor];clear.colorAttachments[0].texture=out;
    clear.colorAttachments[0].loadAction=MTLLoadActionClear;clear.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,1);clear.colorAttachments[0].storeAction=MTLStoreActionStore;
    [[cmd renderCommandEncoderWithDescriptor:clear] endEncoding];
    MTLViewport left={0,0,32,32,0,1},right={32,0,32,32,0,1};
    [self drawTexture:red frameWidth:16 frameHeight:9 viewport:left buffer:cmd drawable:(id<CAMetalDrawable>)surface fill:NO];
    [self drawTexture:green frameWidth:16 frameHeight:16 viewport:right buffer:cmd drawable:(id<CAMetalDrawable>)surface fill:NO];
    [cmd commit];[cmd waitUntilCompleted];uint8_t pixels[64*32*4];
    [out getBytes:pixels bytesPerRow:64*4 fromRegion:MTLRegionMake2D(0,0,64,32) mipmapLevel:0];
    auto px=[&](int x,int y,int c){return pixels[(y*64+x)*4+c];};
    BOOL independent=cmd.status==MTLCommandBufferStatusCompleted && px(16,1,2)<10 && px(16,16,2)>240 && px(48,1,1)>240;
    NSDictionary *attrs=@{(id)kCVPixelBufferWidthKey:@64,(id)kCVPixelBufferHeightKey:@64,(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA),(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};
    CVPixelBufferPoolRef pool=NULL; CVPixelBufferPoolCreate(kCFAllocatorDefault,NULL,(__bridge CFDictionaryRef)attrs,&pool);
    NSDictionary *limit=@{(id)kCVPixelBufferPoolAllocationThresholdKey:@1}; CVPixelBufferRef first=NULL, second=NULL;
    CVReturn created=pool?CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault,pool,(__bridge CFDictionaryRef)limit,&first):kCVReturnError;
    CVMetalTextureRef ref=first?[self createTexture:first]:NULL; id<MTLTexture> mapped=ref?CVMetalTextureGetTexture(ref):nil;
    id<MTLSharedEvent> event=[_device newSharedEvent]; id<MTLCommandBuffer> pending=[_commandQueue commandBuffer];
    BOOL guarded=NO,released=NO;
    if(created==kCVReturnSuccess && first && ref && mapped && event && pending) {
        [pending encodeWaitForEvent:event value:1]; CVPixelBufferRetain(first);
        [pending addCompletedHandler:^(id<MTLCommandBuffer> finished){ (void)finished; CFRelease(ref); CVPixelBufferRelease(first); }];
        [pending commit];CVPixelBufferRelease(first);first=NULL;
        CVReturn busy=CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault,pool,(__bridge CFDictionaryRef)limit,&second);
        guarded=busy==kCVReturnWouldExceedAllocationThreshold; if(second){CVPixelBufferRelease(second);second=NULL;}
        event.signaledValue=1;[pending waitUntilCompleted];CVMetalTextureCacheFlush(_cache,0);
        CVReturn available=CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault,pool,(__bridge CFDictionaryRef)limit,&second);
        released=available==kCVReturnSuccess && second!=NULL; if(second)CVPixelBufferRelease(second);
    } else { if(ref)CFRelease(ref);if(first)CVPixelBufferRelease(first); }
    if(pool)CFRelease(pool);
    return @{ @"ok":@(independent&&guarded&&released), @"compareQuadsIndependent":@(independent), @"poolBlockedBeforeGPUCompletion":@(guarded),
        @"poolReusableAfterGPUCompletion":@(released), @"scope":@"actual offscreen preview draw and GPU buffer lifetime; no drawable window or physical display" };
}

- (BOOL)presentEnhanced:(CVPixelBufferRef)enhanced
               original:(CVPixelBufferRef)original
                   mode:(SPLiveViewMode)mode
            captureHost:(int64_t)captureHost
             generation:(uint64_t)generation
                 ptsNum:(int64_t)ptsNum
                 ptsDen:(int64_t)ptsDen
              synthetic:(BOOL)synthetic
                frameID:(uint64_t)frameID
                 counts:(BOOL)counts
         captureGeometry:(NSDictionary *)captureGeometry
                 reason:(NSString **)reason {
    return [self presentEnhanced:enhanced original:original mode:mode captureHost:captureHost
                     generation:generation ptsNum:ptsNum ptsDen:ptsDen synthetic:synthetic
                        frameID:frameID counts:counts captureGeometry:captureGeometry
               presentationHost:0 reason:reason];
}

- (BOOL)presentEnhanced:(CVPixelBufferRef)enhanced
               original:(CVPixelBufferRef)original
                   mode:(SPLiveViewMode)mode
            captureHost:(int64_t)captureHost
             generation:(uint64_t)generation
                 ptsNum:(int64_t)ptsNum
                 ptsDen:(int64_t)ptsDen
              synthetic:(BOOL)synthetic
                frameID:(uint64_t)frameID
                 counts:(BOOL)counts
         captureGeometry:(NSDictionary *)captureGeometry
       presentationHost:(int64_t)presentationHost
                 reason:(NSString **)reason {
    return [self presentEnhanced:enhanced original:original mode:mode captureHost:captureHost generation:generation
                          ptsNum:ptsNum ptsDen:ptsDen synthetic:synthetic frameID:frameID counts:counts
                 captureGeometry:captureGeometry presentationHost:presentationHost redraw:NO reason:reason];
}

- (BOOL)presentEnhanced:(CVPixelBufferRef)enhanced
               original:(CVPixelBufferRef)original
                   mode:(SPLiveViewMode)mode
            captureHost:(int64_t)captureHost
             generation:(uint64_t)generation
                 ptsNum:(int64_t)ptsNum
                 ptsDen:(int64_t)ptsDen
              synthetic:(BOOL)synthetic
                frameID:(uint64_t)frameID
                 counts:(BOOL)counts
         captureGeometry:(NSDictionary *)captureGeometry
       presentationHost:(int64_t)presentationHost
                 redraw:(BOOL)redraw
                 reason:(NSString **)reason {
    if (generation != _generation.load()) { if (reason) *reason = @"generation"; return NO; }
    if (!_pipeline || !_displayLink) { if (reason) *reason = @"pipeline"; return NO; }
    CVPixelBufferRef primary = mode == SPLiveViewOriginal ? (original ?: enhanced) : enhanced;
    if (!primary) { if (reason) *reason = @"input"; return NO; }
    BOOL warmSurface = _surfaceToken.load() != 0 && _windowVisible.load() && !_exposed.load();
    if (!warmSurface && (!_windowVisible.load() || !_drawableVisible.load())) { if (reason) *reason = @"display-invisible"; return NO; }
    SPDisplayFrameRequest *frame = [SPDisplayFrameRequest new];
    frame.enhanced = enhanced ? CVPixelBufferRetain(enhanced) : NULL;
    frame.original = original ? CVPixelBufferRetain(original) : NULL;
    frame.mode = mode; frame.captureHost = captureHost; frame.generation = generation;
    frame.config = _diagnosticConfig.load(); frame.epoch = _diagnosticEpoch.load(); frame.clockEpoch = _presentationClockEpoch.load();
    frame.surfaceToken = _surfaceToken.load(); frame.ptsNum = ptsNum; frame.ptsDen = ptsDen;
    frame.airPerformanceEnabled = [self airPerformanceEnabled];
    if (_measurementTrace) frame->_measurementTrace = _measurementTrace;
#if ODF_AIR_BETA_DIAGNOSTIC
    if (SPAirBetaEnabled() || frame.airPerformanceEnabled) {
        frame.betaCaptureWidth = _airBetaCaptureWidth.load();
        frame.betaCaptureHeight = _airBetaCaptureHeight.load();
    }
#endif
    frame.synthetic = synthetic; frame.frameID = frameID; frame.counts = counts; frame.redraw = redraw;
    frame.logicalTargetHost = presentationHost; frame.enqueueHost = SPHostNow();
    frame.captureGeometry = captureGeometry;
    if (warmSurface) {
        if (_warmSurfacePending.exchange(true)) { if (reason) *reason = @"display-warm-inflight"; return NO; }
        dispatch_async(dispatch_get_main_queue(), ^{
            CGSize size = self->_metalLayer.drawableSize;
            dispatch_async(self->_renderQueue, ^{ [self prepareWarmSurface:frame targetSize:size]; });
        });
        return YES; // GPU surface preparation only; never a physical presentation success
    }
    std::lock_guard<std::mutex> lock(_presentationMutex);
    if (generation != _generation.load() || frame.config != _diagnosticConfig.load() || frame.epoch != _diagnosticEpoch.load() || frame.clockEpoch != _presentationClockEpoch.load()) {
        if (_airCadenceFrames) _airCadenceFrames->append(SPAirFrameRecord(frame, SPAirFrameKind::rejected,
            frame.config != _diagnosticConfig.load() ? SPAirFrameReason::configuration : SPAirFrameReason::other, SPAirFrameStage::admission));
        if (reason) *reason = @"display-context-changed"; return NO;
    }
    std::vector<sp::DisplayQueueFrame> timings;
    for (SPDisplayFrameRequest *pending in _pendingPresentations) timings.push_back(SPDisplayFrameTiming(pending));
    auto decision = sp::admitDisplayFrame(timings, SPDisplayFrameTiming(frame), _haveSubmittedPresentationPTS, _lastSubmittedPresentationPTS);
    if (decision != sp::DisplayAdmission::accepted) {
        if (_airCadenceFrames) _airCadenceFrames->append(SPAirFrameRecord(frame, SPAirFrameKind::rejected,
            decision == sp::DisplayAdmission::full ? SPAirFrameReason::queueFull : (decision == sp::DisplayAdmission::duplicatePTS ? SPAirFrameReason::duplicatePTS :
                (decision == sp::DisplayAdmission::invalidPTS ? SPAirFrameReason::invalidPTS : SPAirFrameReason::stalePTS)), SPAirFrameStage::admission));
        if (reason) *reason = decision == sp::DisplayAdmission::full ? @"display-queue-full" :
            (decision == sp::DisplayAdmission::duplicatePTS ? @"display-duplicate-pts" :
             (decision == sp::DisplayAdmission::invalidPTS ? @"display-invalid-pts" :
              (decision == sp::DisplayAdmission::redrawNotCurrent ? @"display-redraw-not-current" : @"display-stale-pts")));
        return NO;
    }
    [_pendingPresentations insertObject:frame atIndex:sp::displayFrameInsertionIndex(timings, SPDisplayFrameTiming(frame))];
    if (_airCadenceFrames) {
        SPAirFrameEvent event = SPAirFrameRecord(frame, SPAirFrameKind::admitted, SPAirFrameReason::none, SPAirFrameStage::admission);
        frame.causalEnqueueHostTicks = event.hostTicks; event.enqueueHostTicks = event.hostTicks; _airCadenceFrames->append(event);
    }
    if ((frame.airPerformanceEnabled || _airPreparedTextureDiagnostic) && _preparedTextures) [_preparedTextures prepareFrame:frame];
    return YES; // admitted only; success is still counted exclusively by addPresentedHandler
}

- (void)updateDisplayLinkConfiguration {
    NSAssert(NSThread.isMainThread, @"display-link configuration belongs to its main run loop");
    double maximum = self.window.screen.maximumFramesPerSecond ?: NSScreen.mainScreen.maximumFramesPerSecond;
    if (maximum <= 0) maximum = 60;
    float preferred = (float)MAX(1, maximum);
    _displayLink.preferredFrameRateRange = CAFrameRateRangeMake(preferred, preferred, preferred);
    _displayLink.paused = !_drawableVisible.load() || _generation.load() == 0;
    if (!_drawableVisible.load()) {
        NSArray<SPDisplayFrameRequest *> *discarded;
        { std::lock_guard<std::mutex> lock(_presentationMutex);
          if (_airCadenceFrames) for (SPDisplayFrameRequest *frame in _pendingPresentations)
              _airCadenceFrames->append(SPAirFrameRecord(frame, SPAirFrameKind::discarded, SPAirFrameReason::invisible, SPAirFrameStage::visibilityCleanup));
          discarded = [_pendingPresentations copy]; [_pendingPresentations removeAllObjects];
          if (_prospectiveSlot) {
              if (_airSlotConsumes) [self recordAirSlotTraceLocked:{_prospectiveSlot->timing, _prospectiveSlot->timing.token, 0, 0, 0, SPDisplayTimerOutcome::retired} origin:SPAirSlotOrigin::visibilityRetired];
              _displaySlotRetired.fetch_add(1); _prospectiveSlot = nil;
          }
          [self parkDisplaySlotTimerLocked]; }
        for (SPDisplayFrameRequest *frame in discarded) [self reportPendingPresentation:frame reason:@"display-invisible"];
    }
}

- (void)reportPendingPresentation:(SPDisplayFrameRequest *)frame reason:(NSString *)reason {
    [self reportPendingPresentation:frame reason:reason details:nil];
}

- (void)reportPendingPresentation:(SPDisplayFrameRequest *)frame reason:(NSString *)reason details:(NSDictionary *)details {
    [frame.preparedTextureLease cancel];
    if (!frame.counts || !self.presentationFailure) return;
    NSMutableDictionary *info = [@{
        @"reason": reason, @"generation": @(frame.generation), @"configVersion": @(frame.config),
        @"measurementEpoch": @(frame.epoch), @"clockEpoch": @(frame.clockEpoch), @"frameID": @(frame.frameID),
        @"ptsNum": @(frame.ptsNum), @"ptsDen": @(frame.ptsDen), @"synthetic": @(frame.synthetic),
        @"logicalTargetHost": @(frame.logicalTargetHost), @"presentationEnqueueHost": @(frame.enqueueHost) } mutableCopy];
    if (details) [info addEntriesFromDictionary:details];
    self.presentationFailure(info);
}

- (void)discardOutdatedPresentations {
    NSMutableArray<SPDisplayFrameRequest *> *discarded = [NSMutableArray array];
    {
        std::lock_guard<std::mutex> lock(_presentationMutex);
        if (_prospectiveSlot && !sp::sameDisplaySlotContext(_prospectiveSlot->timing.context, [self displaySlotContext])) {
            if (_airSlotConsumes) [self recordAirSlotTraceLocked:{_prospectiveSlot->timing, _prospectiveSlot->timing.token, 0, 0, 0, SPDisplayTimerOutcome::retired} origin:SPAirSlotOrigin::contextCleanupRetired];
            _displaySlotRetired.fetch_add(1); _prospectiveSlot = nil;
            [self parkDisplaySlotTimerLocked];
        }
        for (NSInteger i = (NSInteger)_pendingPresentations.count - 1; i >= 0; --i) {
            SPDisplayFrameRequest *frame = _pendingPresentations[(NSUInteger)i];
            if (frame.generation != _generation.load() || frame.config != _diagnosticConfig.load() || frame.epoch != _diagnosticEpoch.load() || frame.clockEpoch != _presentationClockEpoch.load()) {
                if (_airCadenceFrames) {
                    const auto reason = frame.generation != _generation.load() ? SPAirFrameReason::generation :
                        (frame.config != _diagnosticConfig.load() ? SPAirFrameReason::configuration : (frame.epoch != _diagnosticEpoch.load() ? SPAirFrameReason::epoch : SPAirFrameReason::clock));
                    _airCadenceFrames->append(SPAirFrameRecord(frame, SPAirFrameKind::discarded, reason, SPAirFrameStage::cleanup));
                }
                [discarded addObject:frame]; [_pendingPresentations removeObjectAtIndex:(NSUInteger)i];
            }
        }
    }
    for (SPDisplayFrameRequest *frame in discarded) [self reportPendingPresentation:frame reason:
        frame.generation != _generation.load() ? @"generation" : (frame.config != _diagnosticConfig.load() ? @"configuration" :
            (frame.epoch != _diagnosticEpoch.load() ? @"epoch" : @"clock-retired"))];
}

// A transparent output may receive no display-link updates. Prepare one
// bounded offscreen surface for its existing token handshake; never present it.
- (void)prepareWarmSurface:(SPDisplayFrameRequest *)frame targetSize:(CGSize)size {
    @autoreleasepool {
        if (frame.generation != _generation.load() || frame.config != _diagnosticConfig.load() ||
            frame.epoch != _diagnosticEpoch.load() || frame.clockEpoch != _presentationClockEpoch.load() ||
            frame.surfaceToken != _surfaceToken.load()) {
            _warmSurfacePending.store(false); [self reportPendingPresentation:frame reason:@"display-warm-context-changed"]; return;
        }
        CVPixelBufferRef primary = frame.mode == SPLiveViewOriginal ? (frame.original ?: frame.enhanced) : frame.enhanced;
        CVPixelBufferRef secondary = frame.original ?: frame.enhanced;
        CVMetalTextureRef aRef = [self createTexture:primary];
        CVMetalTextureRef bRef = frame.mode == SPLiveViewCompare ? [self createTexture:secondary] : NULL;
        id<MTLTexture> a = aRef ? CVMetalTextureGetTexture(aRef) : nil, b = bRef ? CVMetalTextureGetTexture(bRef) : nil;
        MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
            width:MAX((NSUInteger)1,(NSUInteger)size.width) height:MAX((NSUInteger)1,(NSUInteger)size.height) mipmapped:NO];
        desc.usage = MTLTextureUsageRenderTarget;
        SPProbeDrawable *surface = [SPProbeDrawable new]; surface.texture = [_device newTextureWithDescriptor:desc];
        id<MTLCommandBuffer> command = [_commandQueue commandBuffer];
        if (!a || !surface.texture || !command) {
            if (aRef) CFRelease(aRef); if (bRef) CFRelease(bRef);
            _warmSurfacePending.store(false); [self reportPendingPresentation:frame reason:@"display-warm-surface"]; return;
        }
        MTLRenderPassDescriptor *clear = [MTLRenderPassDescriptor renderPassDescriptor];
        clear.colorAttachments[0].texture = surface.texture; clear.colorAttachments[0].loadAction = MTLLoadActionClear;
        clear.colorAttachments[0].storeAction = MTLStoreActionStore;
        [[command renderCommandEncoderWithDescriptor:clear] endEncoding];
        MTLViewport full = {0,0,(double)surface.texture.width,(double)surface.texture.height,0,1};
        if (frame.mode == SPLiveViewCompare && b) {
            MTLViewport left = full, right = full; left.width *= .5; right.width *= .5; right.originX = left.width;
            [self drawTexture:a frameWidth:CVPixelBufferGetWidth(primary) frameHeight:CVPixelBufferGetHeight(primary)
                viewport:left buffer:command drawable:(id<CAMetalDrawable>)surface fill:NO];
            [self drawTexture:b frameWidth:CVPixelBufferGetWidth(secondary) frameHeight:CVPixelBufferGetHeight(secondary)
                viewport:right buffer:command drawable:(id<CAMetalDrawable>)surface fill:NO];
        } else [self drawTexture:a frameWidth:CVPixelBufferGetWidth(primary) frameHeight:CVPixelBufferGetHeight(primary)
            viewport:full buffer:command drawable:(id<CAMetalDrawable>)surface fill:_followTargetContent.load()];
        _inflightDraws.fetch_add(1);
        [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            if (aRef) CFRelease(aRef); if (bRef) CFRelease(bRef);
            self->_inflightDraws.fetch_sub(1); self->_warmSurfacePending.store(false);
            if (frame.clockEpoch != self->_presentationClockEpoch.load()) return;
            if (completed.status != MTLCommandBufferStatusCompleted) [self reportPendingPresentation:frame reason:@"display-warm-gpu"];
            if (self.surfaceReady) self.surfaceReady(@{
                @"generation": @(frame.generation), @"configVersion": @(frame.config), @"measurementEpoch": @(frame.epoch),
                @"clockEpoch": @(frame.clockEpoch), @"surfaceToken": @(frame.surfaceToken), @"captureHost": @(frame.captureHost),
                @"frameID": @(frame.frameID), @"counts": @(frame.counts), @"windowVisible": @(self->_windowVisible.load()),
                @"gpuCompleted": @(completed.status == MTLCommandBufferStatusCompleted), @"surfacePreparationOnly": @YES,
                @"viewMode": @(frame.mode), @"enhancedWidth": @(frame.enhanced ? CVPixelBufferGetWidth(frame.enhanced) : 0),
                @"enhancedHeight": @(frame.enhanced ? CVPixelBufferGetHeight(frame.enhanced) : 0),
                @"originalWidth": @(frame.original ? CVPixelBufferGetWidth(frame.original) : 0),
                @"originalHeight": @(frame.original ? CVPixelBufferGetHeight(frame.original) : 0) });
        }];
        [command commit];
    }
}

- (sp::DisplaySlotContext)displaySlotContext {
    return {_generation.load(), _diagnosticConfig.load(), _diagnosticEpoch.load(), _presentationClockEpoch.load()};
}

- (void)resetAirDisplayPolicyLocked {
    _airDisplayRefreshHistory.reset();
    _airRuleBLastDecision = {};
    _airRuleBDecisionCount = 0; _airRuleBLastHistoryCount = 0;
    if (_prospectiveSlot) _prospectiveSlot->ruleBEnabled = false;
}

- (void)copyAirCadenceEvents:(std::vector<SPAirFrameEvent> *)events total:(uint64_t *)total {
    [self copyAirCadenceEvents:events total:total consumes:nullptr consumeTotal:nullptr snapshot:nullptr];
}

- (void)copyAirCadenceEvents:(std::vector<SPAirFrameEvent> *)events total:(uint64_t *)total
    consumes:(std::vector<SPAirSlotConsumeEvent> *)consumes consumeTotal:(uint64_t *)consumeTotal snapshot:(SPAirSlotSnapshot *)snapshot {
    if (!_airCadenceFrames) { *total = 0; return; }
    events->reserve(SPAirFrameRing::capacity); // controlled export only; allocation precedes existing mutex
    if (consumes) consumes->reserve(SPAirSlotConsumeRing::capacity);
    std::lock_guard<std::mutex> lock(_presentationMutex);
    if (snapshot) {
        snapshot->sampleHostTicks = SPHostNow(); snapshot->hasPending = _prospectiveSlot != nil;
        if (_prospectiveSlot) {
            const auto pending = _prospectiveSlot->timing; snapshot->token = pending.token; snapshot->generation = pending.context.generation; snapshot->config = pending.context.config;
            snapshot->epoch = pending.context.measurementEpoch; snapshot->clock = pending.context.clockEpoch; snapshot->deadlineMediaNs = pending.deadlineNs; snapshot->displayTimeMediaNs = pending.displayNs;
        }
    }
    _airCadenceFrames->copy(*events); *total = _airCadenceFrames->total;
    if (consumes && consumeTotal) { _airSlotConsumes->copy(*consumes); *consumeTotal = _airSlotConsumes->total; }
}

- (BOOL)copyAirSlotCallbacks:(std::vector<SPAirSlotCallbackEvent> *)events total:(uint64_t *)total
    mainCallerSynchronouslyOnProcessorQueue:(BOOL)safe unsupported:(uint64_t *)unsupported {
    *unsupported = _airSlotCallbackUnsupported.load();
    *total = 0;
    // The controlled main caller is synchronously inside/blocked by its _q
    // export, so no main-run-loop delegate can write while this copy executes.
    if (!safe || !dispatch_get_specific(SPLiveQueueKey) || !_airSlotCallbacks) return NO;
    events->reserve(SPAirSlotCallbackRing::capacity); _airSlotCallbacks->copy(*events); *total = _airSlotCallbacks->total;
    return YES;
}

- (int64_t)presentationPreparationLeadNs { return _displayPreparationLeadNs.load(); }

- (void)recordDisplayTimerTraceLocked:(SPDisplayTimerTrace)trace {
    _displayTimerTrace[_displayTimerTraceCount % _displayTimerTrace.size()] = trace;
    ++_displayTimerTraceCount;
    if (_airSlotConsumes && (trace.handlerEntryHostTicks || trace.outcome == SPDisplayTimerOutcome::expiredReplaced))
        [self recordAirSlotTraceLocked:trace origin:trace.handlerEntryHostTicks ? SPAirSlotOrigin::timerAttempt : SPAirSlotOrigin::callbackReplaced];
}

- (void)recordAirSlotTraceLocked:(SPDisplayTimerTrace)trace origin:(SPAirSlotOrigin)origin {
    if (_airSlotConsumes) {
        SPAirSlotConsumeEvent event{}; event.token = trace.armed.token; event.observedToken = trace.observedToken; event.frameID = trace.frameID;
        event.generation = trace.armed.context.generation; event.config = trace.armed.context.config; event.epoch = trace.armed.context.measurementEpoch; event.clock = trace.armed.context.clockEpoch;
        const auto current = [self displaySlotContext]; event.currentGeneration = current.generation; event.currentConfig = current.config; event.currentEpoch = current.measurementEpoch; event.currentClock = current.clockEpoch;
        event.entryHostTicks = trace.handlerEntryHostTicks; event.recordHostTicks = SPHostNow(); event.handlerEntryMediaNs = trace.handlerEntryNs; event.lockAcquiredMediaNs = trace.lockAcquiredNs;
        event.plannedSelectionMediaNs = trace.armed.deadlineNs - sp::displaySlotSelectionGuardNs(trace.armed); event.deadlineMediaNs = trace.armed.deadlineNs; event.displayTimeMediaNs = trace.armed.displayNs;
        event.outcome = (uint8_t)trace.outcome; event.origin = origin;
        event.terminal = trace.outcome == SPDisplayTimerOutcome::selected || trace.outcome == SPDisplayTimerOutcome::noFrame ||
            trace.outcome == SPDisplayTimerOutcome::expiredConsume || trace.outcome == SPDisplayTimerOutcome::expiredReplaced ||
            trace.outcome == SPDisplayTimerOutcome::retired || trace.outcome == SPDisplayTimerOutcome::gpuBusy;
        _airSlotConsumes->append(event);
    }
}

- (NSDictionary *)preparedTextureCountersSnapshot {
    return ([self airPerformanceEnabled] || _airPreparedTextureDiagnostic) && _preparedTextures ? [_preparedTextures snapshot] : @{ @"enabled": @NO, @"capacity": @4 };
}

- (NSDictionary *)displaySlotDiagnostics {
    std::array<SPDisplayTimerTrace, 64> history;
    uint64_t total; NSUInteger pendingFrames; bool pendingSlot;
    bool ruleBEnabled;
    spAirDisplayPolicyB::Decision ruleBDecision;
    uint64_t ruleBDecisionCount; std::size_t ruleBHistoryCount;
    {
        std::lock_guard<std::mutex> lock(_presentationMutex);
        history = _displayTimerTrace; total = _displayTimerTraceCount;
        pendingFrames = _pendingPresentations.count; pendingSlot = _prospectiveSlot != nil;
        ruleBEnabled = _airPerformanceEnabled.load(); ruleBDecision = _airRuleBLastDecision;
        ruleBDecisionCount = _airRuleBDecisionCount; ruleBHistoryCount = _airRuleBLastHistoryCount;
    }
    // Build diagnostic objects outside the deadline-sensitive publication lock.
    NSUInteger count = (NSUInteger)MIN(total, (uint64_t)history.size());
    NSMutableArray *events = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; ++i) {
        const auto &trace = history[(total - count + i) % history.size()];
        NSString *expiredOrigin = trace.outcome == SPDisplayTimerOutcome::expiredConsume ? @"consume" :
            (trace.outcome == SPDisplayTimerOutcome::expiredReplaced ? @"callback-replaced" : nil);
        [events addObject:@{ @"handlerToken": @(trace.armed.token), @"observedToken": @(trace.observedToken),
            @"generation": @(trace.armed.context.generation), @"configVersion": @(trace.armed.context.config),
            @"measurementEpoch": @(trace.armed.context.measurementEpoch), @"clockEpoch": @(trace.armed.context.clockEpoch),
            @"plannedSelectionNs": @(trace.armed.deadlineNs - sp::displaySlotSelectionGuardNs(trace.armed)),
            @"deadlineNs": @(trace.armed.deadlineNs), @"scheduledDisplayNs": @(trace.armed.displayNs),
            @"handlerEntryNs": trace.handlerEntryNs ? @(trace.handlerEntryNs) : (id)[NSNull null],
            @"lockAcquiredNs": trace.lockAcquiredNs ? @(trace.lockAcquiredNs) : (id)[NSNull null],
            @"frameID": trace.frameID ? @(trace.frameID) : (id)[NSNull null],
            @"outcome": SPDisplayTimerOutcomeName(trace.outcome), @"expiredOrigin": expiredOrigin ?: (id)[NSNull null] }];
    }
    NSDictionary *result = @{ @"pendingSlots": @(pendingSlot), @"slotCapacity": @1,
        @"pendingFrames": @(pendingFrames), @"frameCapacity": @(sp::displayQueueCapacity),
        @"expiredSlotsLifetime": @(_displaySlotExpired.load()),
        @"expiredInConsumeLifetime": @(_displaySlotExpiredInConsume.load()),
        @"expiredByCallbackLifetime": @(_displaySlotExpiredByCallback.load()),
        @"retiredSlotsLifetime": @(_displaySlotRetired.load()), @"busySlotsLifetime": @(_displaySlotBusy.load()),
        @"noFrameSlotsLifetime": @(_displaySlotNoFrame.load()), @"preparationLeadNs": @(_displayPreparationLeadNs.load()),
        @"selectionGuardNs": @([self selectionGuardNs]), @"timerLeewayNs": @50000, @"timerStrict": @YES,
        @"ruleB": @{ @"enabled": @(ruleBEnabled), @"historyCapacity": @8, @"decisionCountInContext": @(ruleBDecisionCount),
            @"lastDecisionBranch": ruleBDecisionCount ? @((int)ruleBDecision.branch) : (id)NSNull.null,
            @"lastDecisionRefreshPeriodNs": ruleBDecision.refreshPeriodNs > 0 ? @(ruleBDecision.refreshPeriodNs) : (id)NSNull.null,
            @"lastDecisionHistoryCount": @(ruleBHistoryCount) },
        @"timerTraceCapacity": @(history.size()), @"timerTraceTotal": @(total), @"timerTrace": events,
        @"timerTraceNote": @"bounded slot observations; handler entry includes OS wake and render-queue scheduling, lock acquisition separately includes mutex wait" };
#if defined(ODF_AIR_PRESENTATION_GUARD_DIAGNOSTIC) && ODF_AIR_PRESENTATION_GUARD_DIAGNOSTIC == 1
    NSMutableDictionary *diagnostic = [result mutableCopy];
    diagnostic[@"preparedTexture"] = ([self airPerformanceEnabled] || _airPreparedTextureDiagnostic) && _preparedTextures ? [_preparedTextures snapshot] : @{ @"enabled": @NO, @"capacity": @4 };
    result = diagnostic;
#endif
    return result;
}

// All arm/park calls own presentationMutex. Publication and arming are one
// transaction; an old callback cannot rearm after a newer ticket was published.
- (void)parkDisplaySlotTimerLocked {
    if (_displaySlotTimer) dispatch_source_set_timer(_displaySlotTimer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 50000);
}

- (void)armDisplaySlotLocked:(uint64_t)token {
    if (!_prospectiveSlot || !sp::canArmDisplaySlot(_prospectiveSlot->timing, token, [self displaySlotContext])) return;
    const sp::DisplaySlotWindow armedSlot = _prospectiveSlot->timing;
    int64_t delayNs = MAX((int64_t)0, armedSlot.deadlineNs - sp::displaySlotSelectionGuardNs(armedSlot) - (int64_t)(CACurrentMediaTime() * 1e9));
    __weak SPLivePreviewView *weakSelf = self;
    dispatch_source_set_event_handler(_displaySlotTimer, ^{ [weakSelf consumeDisplaySlot:armedSlot]; });
    dispatch_source_set_timer(_displaySlotTimer, dispatch_time(DISPATCH_TIME_NOW, delayNs), DISPATCH_TIME_FOREVER, 50000);
}

- (void)metalDisplayLink:(CAMetalDisplayLink *)link needsUpdate:(CAMetalDisplayLinkUpdate *)update {
    @autoreleasepool {
        int64_t callbackHost = SPHostNow();
        double deadline = update.targetTimestamp, displayTime = update.targetPresentationTimestamp;
        int64_t nowNs = (int64_t)(CACurrentMediaTime() * 1e9);
        const BOOL slotTrace = _airSlotCallbacks && NSThread.isMainThread;
        if (_airSlotCallbacks && !slotTrace) _airSlotCallbackUnsupported.fetch_add(1, std::memory_order_relaxed);
        SPAirSlotCallbackEvent slotEvent{};
        if (slotTrace) {
            slotEvent.entryHostTicks = callbackHost; slotEvent.entryMediaNs = nowNs;
            slotEvent.targetTimestampMediaSeconds = deadline; slotEvent.targetPresentationTimestampMediaSeconds = displayTime;
            const auto context = [self displaySlotContext]; slotEvent.generation = context.generation; slotEvent.config = context.config; slotEvent.epoch = context.measurementEpoch; slotEvent.clock = context.clockEpoch;
        }
        auto rejected = [&](bool value, SPAirSlotEntryReject reason) { if (value && slotTrace) slotEvent.reject = reason; return value; };
        auto recordCallback = [&](SPAirSlotCallbackOutcome outcome) {
            if (slotTrace) { slotEvent.outcome = outcome; slotEvent.outcomeHostTicks = SPHostNow(); _airSlotCallbacks->append(slotEvent); }
        };
        // Same short-circuit predicates, evaluation order and return as before;
        // record only the predicate which actually rejects this callback.
        if (rejected(link != _displayLink, SPAirSlotEntryReject::wrongLink) || rejected(!_drawableVisible.load(), SPAirSlotEntryReject::invisible) || rejected(!_generation.load(), SPAirSlotEntryReject::noGeneration) ||
            rejected(!std::isfinite(deadline), SPAirSlotEntryReject::invalidDeadline) || rejected(!std::isfinite(displayTime), SPAirSlotEntryReject::invalidDisplayTime) || rejected(displayTime <= deadline, SPAirSlotEntryReject::displayNotAfterDeadline) ||
            rejected(deadline * 1e9 <= nowNs, SPAirSlotEntryReject::deadlineReached)) { recordCallback(SPAirSlotCallbackOutcome::entryRejected); return; }
        SPProspectiveDisplaySlot *slot = [SPProspectiveDisplaySlot new];
        slot.drawable = update.drawable; slot.deadline = deadline; slot.displayTime = displayTime; slot.callbackHost = callbackHost;
        {
            std::lock_guard<std::mutex> lock(_presentationMutex);
            auto context = [self displaySlotContext];
            if (slotTrace) {
                slotEvent.generation = context.generation; slotEvent.config = context.config; slotEvent.epoch = context.measurementEpoch; slotEvent.clock = context.clockEpoch;
                slotEvent.contextUnderPresentationMutex = true; slotEvent.observedToken = _prospectiveSlot ? _prospectiveSlot->timing.token : 0;
            }
            if (_prospectiveSlot && !sp::canReplaceDisplaySlot(_prospectiveSlot->timing, context, nowNs)) {
                _displaySlotBusy.fetch_add(1); recordCallback(SPAirSlotCallbackOutcome::busy); return; // preserve an older slot that is still usable
            }
            if (_prospectiveSlot) {
                if (sp::sameDisplaySlotContext(_prospectiveSlot->timing.context, context)) {
                    _displaySlotExpired.fetch_add(1); _displaySlotExpiredByCallback.fetch_add(1);
                    [self recordDisplayTimerTraceLocked:{_prospectiveSlot->timing, _prospectiveSlot->timing.token, 0, 0,
                        (int64_t)(CACurrentMediaTime() * 1e9), SPDisplayTimerOutcome::expiredReplaced}];
                } else {
                    if (_airSlotConsumes) [self recordAirSlotTraceLocked:{_prospectiveSlot->timing, _prospectiveSlot->timing.token, 0, 0, 0, SPDisplayTimerOutcome::retired} origin:SPAirSlotOrigin::callbackContextRetired];
                    _displaySlotRetired.fetch_add(1);
                }
            }
            slot->timing = {++_nextDisplaySlotToken, context, (int64_t)(deadline * 1e9), (int64_t)(displayTime * 1e9), [self selectionGuardNs]};
            slot->ruleBEnabled = [self airPerformanceEnabled];
            if (slot->ruleBEnabled) {
                _airDisplayRefreshHistory.observe(slot->timing.displayNs);
                slot->ruleBHistory = _airDisplayRefreshHistory;
            }
            _prospectiveSlot = slot;
            _displayPreparationLeadNs.store(sp::displayPreparationLeadNs(slot->timing));
            [self armDisplaySlotLocked:slot->timing.token];
            if (slotTrace) slotEvent.createdToken = slot->timing.token;
            recordCallback(SPAirSlotCallbackOutcome::createdToken);
        }
    }
}

- (void)consumeDisplaySlot:(sp::DisplaySlotWindow)armedSlot {
    @autoreleasepool {
        int64_t handlerEntryNs = (int64_t)(CACurrentMediaTime() * 1e9);
        int64_t selectionHost = SPHostNow();
        const BOOL timingDiagnostic = _airPresentationTimingDiagnostic;
        const qos_class_t handlerQoS = timingDiagnostic ? qos_class_self() : QOS_CLASS_UNSPECIFIED;
        const uint64_t token = armedSlot.token;
        SPProspectiveDisplaySlot *slot;
        SPDisplayFrameRequest *frame = nil;
        NSMutableArray<SPDisplayFrameRequest *> *stale = [NSMutableArray array];
        NSMutableArray<SPDisplayFrameRequest *> *superseded = [NSMutableArray array];
        {
            std::lock_guard<std::mutex> lock(_presentationMutex);
            int64_t lockAcquiredNs = (int64_t)(CACurrentMediaTime() * 1e9);
            slot = _prospectiveSlot;
            SPDisplayTimerTrace trace{armedSlot, slot ? slot->timing.token : 0, 0, handlerEntryNs, lockAcquiredNs, SPDisplayTimerOutcome::noCurrentSlot};
            if (_airSlotConsumes) trace.handlerEntryHostTicks = selectionHost;
            if (!slot) { [self recordDisplayTimerTraceLocked:trace]; return; }
            auto decision = sp::displaySlotDecision(slot->timing, token, [self displaySlotContext], lockAcquiredNs);
            if (decision == sp::DisplaySlotDecision::staleToken) {
                trace.outcome = SPDisplayTimerOutcome::staleToken; [self recordDisplayTimerTraceLocked:trace]; return;
            }
            if (decision == sp::DisplaySlotDecision::waiting) {
                trace.outcome = SPDisplayTimerOutcome::waiting; [self recordDisplayTimerTraceLocked:trace];
                [self armDisplaySlotLocked:token]; return; // helper does not acquire this mutex again
            }
            _prospectiveSlot = nil; // local ownership lasts only through this selection/render work item
            [self parkDisplaySlotTimerLocked];
            if (decision == sp::DisplaySlotDecision::expired) {
                if (_airCadenceFrames) _airCadenceFrames->append(SPAirFrameRecord(nil, SPAirFrameKind::slotExpired, SPAirFrameReason::expired, SPAirFrameStage::selection, slot));
                _displaySlotExpired.fetch_add(1); _displaySlotExpiredInConsume.fetch_add(1);
                trace.outcome = SPDisplayTimerOutcome::expiredConsume; [self recordDisplayTimerTraceLocked:trace]; return;
            }
            if (decision == sp::DisplaySlotDecision::retired || !_drawableVisible.load()) {
                _displaySlotRetired.fetch_add(1); trace.outcome = SPDisplayTimerOutcome::retired; [self recordDisplayTimerTraceLocked:trace]; return;
            }
            if (_inflightDraws.load() >= 2) {
                _displaySlotBusy.fetch_add(1); trace.outcome = SPDisplayTimerOutcome::gpuBusy; [self recordDisplayTimerTraceLocked:trace]; return;
            }
            for (NSInteger i = (NSInteger)_pendingPresentations.count - 1; i >= 0; --i) {
                SPDisplayFrameRequest *pending = _pendingPresentations[(NSUInteger)i];
                if (pending.generation != slot->timing.context.generation || pending.config != slot->timing.context.config ||
                    pending.epoch != slot->timing.context.measurementEpoch || pending.clockEpoch != slot->timing.context.clockEpoch) {
                    if (_airCadenceFrames) {
                        const auto reason = pending.generation != slot->timing.context.generation ? SPAirFrameReason::generation :
                            (pending.config != slot->timing.context.config ? SPAirFrameReason::configuration : (pending.epoch != slot->timing.context.measurementEpoch ? SPAirFrameReason::epoch : SPAirFrameReason::clock));
                        _airCadenceFrames->append(SPAirFrameRecord(pending, SPAirFrameKind::discarded, reason, SPAirFrameStage::selection, slot));
                    }
                    [stale addObject:pending]; [_pendingPresentations removeObjectAtIndex:(NSUInteger)i];
                }
            }
            for (NSInteger i = (NSInteger)_pendingPresentations.count - 1; i >= 0; --i) {
                SPDisplayFrameRequest *pending = _pendingPresentations[(NSUInteger)i];
                int comparison = _haveSubmittedPresentationPTS ? sp::spCmp({pending.ptsNum,pending.ptsDen}, _lastSubmittedPresentationPTS) : 1;
                if (_haveSubmittedPresentationPTS && (comparison < 0 || (comparison == 0 && !pending.redraw))) {
                    if (_airCadenceFrames) _airCadenceFrames->append(SPAirFrameRecord(pending, SPAirFrameKind::discarded, SPAirFrameReason::stalePTS, SPAirFrameStage::selection, slot));
                    [stale addObject:pending]; [_pendingPresentations removeObjectAtIndex:(NSUInteger)i];
                }
            }
            std::vector<sp::DisplayQueueFrame> timings;
            for (SPDisplayFrameRequest *pending in _pendingPresentations) timings.push_back(SPDisplayFrameTiming(pending));
            const uint64_t measurementChoiceBegin = _measurementTrace ? SPHostNow() : 0;
            const bool ruleBEnabled = slot->ruleBEnabled && [self airPerformanceEnabled];
            const auto ruleB = spAirDisplayPolicyB::decide(timings, slot->timing.displayNs,
                slot->ruleBHistory.intervals, slot->ruleBHistory.count, ruleBEnabled);
            const auto selected = ruleB.selected;
            if (ruleBEnabled) {
                _airRuleBLastDecision = ruleB; _airRuleBLastHistoryCount = slot->ruleBHistory.count;
                ++_airRuleBDecisionCount;
            }
            if (_measurementTrace) {
                const uint64_t ended = SPHostNow(), group = _measurementTrace->identity();
                spAirMeasurement::Event event; event.kind = spAirMeasurement::Kind::choiceBegin;
                event.groupID = group; event.relatedID = slot->timing.token;
                event.generation = slot->timing.context.generation; event.config = slot->timing.context.config;
                event.epoch = slot->timing.context.measurementEpoch; event.clock = slot->timing.context.clockEpoch;
                event.beginHostTicks = measurementChoiceBegin; event.endHostTicks = ended;
                event.sampleHostTicks = selectionHost; event.values[0] = timings.size();
                event.values[1] = slot->timing.displayNs; event.values[2] = slot->timing.deadlineNs;
                _measurementTrace->append(event);
                for (NSUInteger index = 0; index < _pendingPresentations.count; ++index) {
                    auto candidate = SPAirMeasurementFrame(_pendingPresentations[index], spAirMeasurement::Kind::choiceCandidate);
                    candidate.groupID = group; candidate.relatedID = slot->timing.token;
                    candidate.beginHostTicks = measurementChoiceBegin; candidate.endHostTicks = ended;
                    candidate.values[0] = index; candidate.values[1] = index == selected ? 1 : (index < selected && selected < timings.size() ? 2 : 0);
                    _measurementTrace->append(candidate);
                }
                event.kind = spAirMeasurement::Kind::choiceEnd; event.values[3] = selected;
                event.frameID = selected < timings.size() ? timings[selected].frameID : 0;
                event.flags = 512u | (ruleBEnabled ? 1024u : 0u) | ((uint32_t)ruleB.branch << 16);
                event.clockLifeID = ruleB.refreshPeriodNs; event.armID = slot->ruleBHistory.count;
                if (selected < timings.size()) {
                    event.ptsNum = timings[selected].pts.num; event.ptsDen = timings[selected].pts.den;
                    event.targetHostTicks = _pendingPresentations[selected].logicalTargetHost;
                }
                _measurementTrace->append(event);
            }
            if (selected < timings.size()) {
                frame = _pendingPresentations[selected];
                for (NSUInteger index = 0; index < selected; ++index) {
                    if (_airCadenceFrames) _airCadenceFrames->append(SPAirFrameRecord(_pendingPresentations[index], SPAirFrameKind::discarded, SPAirFrameReason::superseded, SPAirFrameStage::selection, slot, frame));
                    [superseded addObject:_pendingPresentations[index]];
                }
                [_pendingPresentations removeObjectsInRange:NSMakeRange(0, selected + 1)];
                if (_airCadenceFrames) _airCadenceFrames->append(SPAirFrameRecord(frame, SPAirFrameKind::selected, SPAirFrameReason::none, SPAirFrameStage::selection, slot));
            }
            if (timingDiagnostic) {
                slot->selectionScanEndedHostTicks = SPHostNow();
                slot->timerHandlerRequestedQoSClass = handlerQoS;
                slot->timerHandlerQoSRecorded = true;
            }
            trace.frameID = frame ? frame.frameID : 0;
            trace.outcome = frame ? SPDisplayTimerOutcome::selected : SPDisplayTimerOutcome::noFrame;
            [self recordDisplayTimerTraceLocked:trace];
        }
        int64_t callbackHost = slot.callbackHost;
        if (timingDiagnostic) {
            slot->staleDiscardReportCount = stale.count;
            slot->supersededDiscardReportCount = superseded.count;
            slot->discardReportsStartedHostTicks = SPHostNow();
        }
        for (SPDisplayFrameRequest *discarded in stale) [self reportPendingPresentation:discarded reason:@"display-stale-pts"];
        for (SPDisplayFrameRequest *discarded in superseded) [self reportPendingPresentation:discarded reason:@"display-slot-superseded"
            details:@{ @"displayLinkCallbackHost": @(callbackHost), @"displayLinkTargetTimestamp": @(slot.deadline),
                @"displayLinkTargetPresentationTimestamp": @(slot.displayTime),
                @"scheduledMinusLogicalTargetNs": discarded.logicalTargetHost > 0 ? @((int64_t)(slot.displayTime * 1e9) - SPHostToNs(discarded.logicalTargetHost)) : (id)[NSNull null] }];
        if (timingDiagnostic) slot->discardReportsEndedHostTicks = SPHostNow();
        if (frame) [self renderPendingPresentation:frame slot:slot selectionHost:selectionHost];
        else _displaySlotNoFrame.fetch_add(1);
    }
}

- (void)renderPendingPresentation:(SPDisplayFrameRequest *)frame slot:(SPProspectiveDisplaySlot *)slot selectionHost:(int64_t)selectionHost {
    const int64_t renderEntryHostTicks = _airPresentationTimingDiagnostic ? SPHostNow() : 0;
    const double presentDeadline = slot.deadline, scheduledDisplayTime = slot.displayTime;
    const int64_t callbackHost = slot.callbackHost;
    const uint64_t slotToken = slot->timing.token;
    uint64_t seen = frame.generation, seenConfig = frame.config, seenEpoch = frame.epoch, seenClock = frame.clockEpoch;
    uint64_t seenSurfaceToken = frame.surfaceToken, frameID = frame.frameID;
    int64_t captureHost = frame.captureHost, ptsNum = frame.ptsNum, ptsDen = frame.ptsDen;
    int64_t presentationHost = frame.logicalTargetHost;
    BOOL synthetic = frame.synthetic, counts = frame.counts;
    SPLiveViewMode mode = frame.mode;
    NSDictionary *captureGeometry = frame.captureGeometry;
    CVPixelBufferRef enhanced = frame.enhanced, original = frame.original;
    CVPixelBufferRef primary = mode == SPLiveViewOriginal ? (original ?: enhanced) : enhanced;
    CVPixelBufferRef secondary = original ?: enhanced;
    BOOL windowVisible = _windowVisible.load(), occluded = windowVisible && !_drawableVisible.load(), exposed = _exposed.load();
    BOOL fillTarget = _followTargetContent.load() && mode != SPLiveViewCompare;
    uint32_t diagnosticDisplayID = _diagnosticDisplayID.load();
    int width = (int)CVPixelBufferGetWidth(primary), height = (int)CVPixelBufferGetHeight(primary);
    int enhancedWidth = enhanced ? (int)CVPixelBufferGetWidth(enhanced) : 0, enhancedHeight = enhanced ? (int)CVPixelBufferGetHeight(enhanced) : 0;
    int originalWidth = original ? (int)CVPixelBufferGetWidth(original) : 0, originalHeight = original ? (int)CVPixelBufferGetHeight(original) : 0;
    int64_t drawableWaitNs = 0;
    id<CAMetalDrawable> drawable = slot.drawable;
    struct SPDrawNote {
        std::atomic<long long> gpuHost{0};
        std::atomic<long long> commitHost{0};
        std::atomic<long long> scheduledHost{0};
        std::atomic<double> scheduledMedia{0};
        std::atomic<double> presentRequestMedia{0};
        std::atomic<long long> texturePreparationEndedHostTicks{0};
        std::atomic<long long> encodingEndedHostTicks{0};
        std::atomic<long long> generationLockRequestedHostTicks{0};
        std::atomic<long long> generationLockAcquiredHostTicks{0};
        std::atomic<long long> presentationLockRequestedHostTicks{0};
        std::atomic<long long> presentationLockAcquiredHostTicks{0};
        std::atomic<long long> deadlineCheckHostTicks{0};
        std::atomic<double> deadlineCheckMediaTimeSeconds{0};
        std::atomic<double> deadlineSlackSeconds{0};
        std::atomic<long long> selectionScanEndedHostTicks{0};
        std::atomic<long long> discardReportsStartedHostTicks{0}, discardReportsEndedHostTicks{0};
        std::atomic<uint64_t> staleDiscardReportCount{0}, supersededDiscardReportCount{0};
        std::atomic<long long> renderEntryHostTicks{0};
        std::atomic<long long> primaryCVTextureAPIStartedHostTicks{0}, primaryCVTextureAPIEndedHostTicks{0};
        std::atomic<long long> secondaryCVTextureAPIStartedHostTicks{0}, secondaryCVTextureAPIEndedHostTicks{0};
        std::atomic<unsigned int> timerHandlerRequestedQoSClass{0};
        std::atomic<bool> timerHandlerQoSRecorded{false};
        std::atomic<bool> preparedTextureEnabled{false}, preparedTextureHit{false};
        std::atomic<int> preparedTextureFallbackReason{SPPreparedNone};
        std::atomic<int64_t> preparedMapStartedHostTicks{0}, preparedMapEndedHostTicks{0};
        std::atomic<uint64_t> preparedMapFrameID{0};
        NSDictionary *timingMetadata(int64_t selectionHost, double deadline, uint64_t slotToken) const {
            const auto checkHost = deadlineCheckHostTicks.load();
            const bool qosRecorded = timerHandlerQoSRecorded.load();
            NSString *qosName = @"not-recorded";
            if (qosRecorded) switch (timerHandlerRequestedQoSClass.load()) {
                case QOS_CLASS_USER_INTERACTIVE: qosName = @"user-interactive"; break;
                case QOS_CLASS_USER_INITIATED: qosName = @"user-initiated"; break;
                case QOS_CLASS_DEFAULT: qosName = @"default"; break;
                case QOS_CLASS_UTILITY: qosName = @"utility"; break;
                case QOS_CLASS_BACKGROUND: qosName = @"background"; break;
                case QOS_CLASS_UNSPECIFIED: qosName = @"unspecified"; break;
                default: qosName = @"unknown"; break;
            }
            return @{ @"displaySlotToken": @(slotToken), @"selectionHostTicks": @(selectionHost),
                @"selectionScanEndedHostTicks": @(selectionScanEndedHostTicks.load()),
                @"discardReportsStartedHostTicks": @(discardReportsStartedHostTicks.load()),
                @"discardReportsEndedHostTicks": @(discardReportsEndedHostTicks.load()),
                @"staleDiscardReportCount": @(staleDiscardReportCount.load()),
                @"supersededDiscardReportCount": @(supersededDiscardReportCount.load()),
                @"discardReportCount": @(staleDiscardReportCount.load() + supersededDiscardReportCount.load()),
                @"renderEntryHostTicks": @(renderEntryHostTicks.load()),
                @"primaryCVTextureAPIStartedHostTicks": @(primaryCVTextureAPIStartedHostTicks.load()),
                @"primaryCVTextureAPIEndedHostTicks": @(primaryCVTextureAPIEndedHostTicks.load()),
                @"secondaryCVTextureAPIStartedHostTicks": @(secondaryCVTextureAPIStartedHostTicks.load()),
                @"secondaryCVTextureAPIEndedHostTicks": @(secondaryCVTextureAPIEndedHostTicks.load()),
                @"timerHandlerQoSRecorded": @(qosRecorded),
                @"timerHandlerRequestedQoSClass": @(timerHandlerRequestedQoSClass.load()),
                @"timerHandlerRequestedQoSName": qosName,
                @"preparedTextureEnabled": @(preparedTextureEnabled.load()), @"preparedTextureHit": @(preparedTextureHit.load()),
                @"preparedTextureFallbackReason": SPPreparedTextureReasonName(preparedTextureFallbackReason.load()),
                @"preparedMapStartedHostTicks": @(preparedMapStartedHostTicks.load()), @"preparedMapEndedHostTicks": @(preparedMapEndedHostTicks.load()),
                @"preparedMapFrameID": @(preparedMapFrameID.load()),
                @"texturePreparationEndedHostTicks": @(texturePreparationEndedHostTicks.load()),
                @"encodingEndedHostTicks": @(encodingEndedHostTicks.load()),
                @"generationLockRequestedHostTicks": @(generationLockRequestedHostTicks.load()),
                @"generationLockAcquiredHostTicks": @(generationLockAcquiredHostTicks.load()),
                @"presentationLockRequestedHostTicks": @(presentationLockRequestedHostTicks.load()),
                @"presentationLockAcquiredHostTicks": @(presentationLockAcquiredHostTicks.load()),
                @"deadlineCheckHostTicks": @(checkHost),
                @"deadlineCheckMediaTimeSeconds": checkHost ? @(deadlineCheckMediaTimeSeconds.load()) : (id)NSNull.null,
                @"presentDeadlineMediaTimeSeconds": @(deadline),
                @"deadlineSlackSeconds": checkHost ? @(deadlineSlackSeconds.load()) : (id)NSNull.null,
                @"scope": @"Opt-in CPU stages only; HostTicks are mach_absolute_time. Zero means stage not reached, including secondary CV API outside Compare and deadline-path CV API on a preparedTextureHit; zero is not a measured CV duration. Prepared map timestamps belong to the independent mapper job for preparedMapFrameID. CV API stamps bracket only CVMetalTextureCacheCreateTextureFromImage after width/height lookup. Discard counts are calls to the existing reporting helper, whose forwarding guard is unchanged. QoS is qos_class_self's reported requested class, not priority overrides. Deadline CA media time is the actual comparison sample; its HostTicks were sampled immediately before it. Null means comparison not performed. No submission/presentation/GPU success is inferred." };
        }
    };
    auto note = std::make_shared<SPDrawNote>();
    const BOOL timingDiagnostic = _airPresentationTimingDiagnostic;
    int preparedReason = SPPreparedNone;
    const BOOL preparedTextureEnabled = frame.airPerformanceEnabled || _airPreparedTextureDiagnostic;
    SPPreparedTextureLease *preparedLease = preparedTextureEnabled && _preparedTextures ? [_preparedTextures claimFrame:frame recordSelection:YES reason:&preparedReason] : nil;
    if (timingDiagnostic) {
        note->preparedTextureEnabled.store(preparedTextureEnabled && _preparedTextures != nil); note->preparedTextureHit.store(preparedLease != nil);
        note->preparedTextureFallbackReason.store(preparedReason);
        if (preparedLease) {
            note->preparedMapStartedHostTicks.store(preparedLease->_mapStartedHostTicks.load());
            note->preparedMapEndedHostTicks.store(preparedLease->_mapEndedHostTicks.load()); note->preparedMapFrameID.store(preparedLease->_frameID);
        }
    }
    if (timingDiagnostic) {
        note->selectionScanEndedHostTicks.store(slot->selectionScanEndedHostTicks);
        note->discardReportsStartedHostTicks.store(slot->discardReportsStartedHostTicks);
        note->discardReportsEndedHostTicks.store(slot->discardReportsEndedHostTicks);
        note->staleDiscardReportCount.store(slot->staleDiscardReportCount);
        note->supersededDiscardReportCount.store(slot->supersededDiscardReportCount);
        note->timerHandlerRequestedQoSClass.store((unsigned int)slot->timerHandlerRequestedQoSClass);
        note->timerHandlerQoSRecorded.store(slot->timerHandlerQoSRecorded);
        note->renderEntryHostTicks.store(renderEntryHostTicks);
    }
    void (^reportFailure)(NSString *) = ^(NSString *why) {
        if (counts && self.presentationFailure) {
            NSDictionary *info = @{
            @"reason": why, @"generation": @(seen), @"configVersion": @(seenConfig), @"measurementEpoch": @(seenEpoch),
            @"frameID": @(frameID), @"ptsNum": @(ptsNum), @"ptsDen": @(ptsDen), @"synthetic": @(synthetic), @"clockEpoch": @(seenClock),
            @"logicalTargetHost": @(presentationHost), @"presentationEnqueueHost": @(frame.enqueueHost),
            @"presentationQueueStartHost": @(callbackHost), @"displayLinkCallbackHost": @(callbackHost),
            @"displaySelectionHost": @(selectionHost), @"displaySlotToken": @(slotToken),
            @"displayLinkTargetTimestamp": @(presentDeadline), @"displayLinkTargetPresentationTimestamp": @(scheduledDisplayTime),
            @"metalCommitHost": @(note->commitHost.load()), @"metalScheduledHost": @(note->scheduledHost.load()),
            @"metalScheduledMediaTime": @(note->scheduledMedia.load()),
            @"presentRequestMethod": @"command-buffer-ordinary", @"presentRequestMediaTime": @(note->presentRequestMedia.load()) };
            if (timingDiagnostic) {
                NSMutableDictionary *diagnosticInfo = [info mutableCopy];
                diagnosticInfo[@"airPresentationTiming"] = note->timingMetadata(selectionHost, presentDeadline, slotToken);
                info = diagnosticInfo;
            }
            self.presentationFailure(info);
        }
    };
    void (^releaseTicket)(void) = ^{ self->_inflightDraws.fetch_sub(1); };
#if ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC
    const BOOL fusedPresentation = _airFusedRifePresentDiagnostic || frame.airPerformanceEnabled;
    const BOOL fusedSynthetic = fusedPresentation && synthetic && mode == SPLiveViewEnhanced;
    id<MTLRenderPipelineState> renderPipeline = fusedSynthetic ? _airFusedPresentPipeline : _pipeline;
    int expectedWidth = synthetic ? 1814 : 2648, expectedHeight = synthetic ? 1142 : 1668;
#if ODF_AIR_BETA_DIAGNOSTIC
    if (SPAirBetaEnabled() || frame.airPerformanceEnabled) {
        const auto choice = sp::airBetaSize(frame.betaCaptureWidth, frame.betaCaptureHeight);
        expectedWidth = synthetic ? choice.processingWidth : frame.betaCaptureWidth;
        expectedHeight = synthetic ? choice.processingHeight : frame.betaCaptureHeight;
    }
#endif
    if (fusedPresentation && counts && mode == SPLiveViewEnhanced &&
        (width != expectedWidth || height != expectedHeight)) {
        reportFailure(@"fused-present-buffer-shape"); [preparedLease complete]; return;
    }
    if (fusedSynthetic && !renderPipeline) { reportFailure(@"fused-present-pipeline"); [preparedLease complete]; return; }
#endif
    int64_t primaryAPIStarted = 0, primaryAPIEnded = 0, secondaryAPIStarted = 0, secondaryAPIEnded = 0;
    const uint64_t measurementInlineBegin = frame->_measurementTrace && !preparedLease ? SPHostNow() : 0;
    CVMetalTextureRef aRef = preparedLease ? NULL : (timingDiagnostic ? [self createTexture:primary apiStartedHostTicks:&primaryAPIStarted apiEndedHostTicks:&primaryAPIEnded] : [self createTexture:primary]);
    CVMetalTextureRef bRef = !preparedLease && mode == SPLiveViewCompare ? (timingDiagnostic ? [self createTexture:secondary apiStartedHostTicks:&secondaryAPIStarted apiEndedHostTicks:&secondaryAPIEnded] : [self createTexture:secondary]) : NULL;
    if (frame->_measurementTrace && !preparedLease) {
        auto event = SPAirMeasurementFrame(frame, spAirMeasurement::Kind::inlineMap);
        event.beginHostTicks = primaryAPIStarted > 0 ? primaryAPIStarted : measurementInlineBegin;
        event.endHostTicks = secondaryAPIEnded > 0 ? secondaryAPIEnded : (primaryAPIEnded > 0 ? primaryAPIEnded : SPHostNow());
        event.values[0] = preparedReason; event.values[1] = aRef != nullptr; event.values[2] = mode == SPLiveViewCompare;
        event.values[3] = primaryAPIStarted > 0 && primaryAPIEnded > 0;
        frame->_measurementTrace->append(event);
    }
    if (timingDiagnostic) {
        note->primaryCVTextureAPIStartedHostTicks.store(primaryAPIStarted); note->primaryCVTextureAPIEndedHostTicks.store(primaryAPIEnded);
        note->secondaryCVTextureAPIStartedHostTicks.store(secondaryAPIStarted); note->secondaryCVTextureAPIEndedHostTicks.store(secondaryAPIEnded);
    }
    id<MTLTexture> a = preparedLease ? [preparedLease primaryTexture] : (aRef ? CVMetalTextureGetTexture(aRef) : nil);
    id<MTLTexture> b = preparedLease ? [preparedLease secondaryTexture] : (bRef ? CVMetalTextureGetTexture(bRef) : nil);
    if (timingDiagnostic) note->texturePreparationEndedHostTicks.store(SPHostNow());
    if (!drawable || !a || !self->_pipeline) {
        reportFailure(!drawable ? @"drawable" : (!a ? @"texture" : @"pipeline"));
        if (aRef) CFRelease(aRef);
        if (bRef) CFRelease(bRef);
        [preparedLease complete];
        return;
    }
    id<MTLCommandBuffer> command = [self->_commandQueue commandBuffer];
    if (!command) {
        reportFailure(@"command");
        if (aRef) CFRelease(aRef);
        if (bRef) CFRelease(bRef);
        [preparedLease complete];
        return;
    }
    MTLRenderPassDescriptor *clear = [MTLRenderPassDescriptor renderPassDescriptor];
    clear.colorAttachments[0].texture = drawable.texture;
    clear.colorAttachments[0].loadAction = MTLLoadActionClear;
    clear.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    clear.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> enc = [command renderCommandEncoderWithDescriptor:clear];
    [enc endEncoding];
    CGSize size = CGSizeMake(drawable.texture.width, drawable.texture.height);
    float fw = (float)CVPixelBufferGetWidth(primary);
    float fh = (float)CVPixelBufferGetHeight(primary);
#if ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC
    auto fusedGeometry = sp::airFusedPresentationGeometry({0,0,size.width,size.height}, width, height,
        fillTarget, fusedPresentation);
#if ODF_AIR_BETA_DIAGNOSTIC
    if (SPAirBetaEnabled() || frame.airPerformanceEnabled) fusedGeometry = sp::airBetaPresentationGeometry({0,0,size.width,size.height},
        frame.betaCaptureWidth, frame.betaCaptureHeight, fillTarget);
#endif
    if (fusedPresentation) {
        fw = (float)fusedGeometry.sourceCrop.width;
        fh = (float)fusedGeometry.sourceCrop.height;
    }
#endif
    sp::GeometrySource diagnosticGeometry{};
    sp::SurfaceCropState cropState{};
    BOOL diagnosticSource = SPSourceGeometryValue(captureGeometry, diagnosticGeometry);
    sp::visualOutputGeometry(diagnosticSource ? &diagnosticGeometry : nullptr, seen, (int)fw, (int)fh, size.width, size.height, fillTarget, cropState);
    NSString *cropStatus = cropState == sp::SurfaceCropState::validated ? @"metadata-valid-unapplied" : (cropState == sp::SurfaceCropState::targetAspectMismatch ? @"target-aspect-mismatch-unapplied" : @"metadata-unavailable-unapplied");
    sp::SharedGeometry geometryCandidate{};
    sp::GeometrySource sourceGeometry{};
    if (counts && mode != SPLiveViewCompare && SPSourceGeometryValue(captureGeometry, sourceGeometry)) {
        std::lock_guard<std::mutex> lock(self->_geometryMutex);
        geometryCandidate=self->_sharedGeometry.candidate(sourceGeometry, seen, seenConfig, seenEpoch, diagnosticDisplayID,
            (int)size.width, (int)size.height, (int)fw, (int)fh, fillTarget);
    }
    // If this drawable cannot be tied to the current verified geometry,
    // no earlier mapping may remain active while it is being presented.
    if (counts && !geometryCandidate.valid) [self invalidateSharedGeometry];
    id imageRectPixels = [NSNull null];
    if (mode != SPLiveViewCompare) {
        auto geometry = sp::outputGeometry({0,0,size.width,size.height},{0,0,fw,fh},fillTarget,1);
#if ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC
        if (fusedPresentation) geometry = geometryCandidate.valid ? geometryCandidate.render : fusedGeometry;
#endif
        if (geometry.valid) imageRectPixels = @[@(geometry.image.x), @(geometry.image.y), @(geometry.image.width), @(geometry.image.height)];
    }
    if (mode == SPLiveViewCompare && b) {
        MTLViewport left = {0, 0, size.width * 0.5, size.height, 0, 1};
        MTLViewport right = {size.width * 0.5, 0, size.width * 0.5, size.height, 0, 1};
        [self drawTexture:a frameWidth:fw frameHeight:fh viewport:left buffer:command drawable:drawable fill:NO];
        [self drawTexture:b frameWidth:(float)CVPixelBufferGetWidth(secondary)
              frameHeight:(float)CVPixelBufferGetHeight(secondary)
                 viewport:right buffer:command drawable:drawable fill:NO];
    } else {
        MTLViewport full = {0, 0, size.width, size.height, 0, 1};
#if ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC
        [self drawTexture:a frameWidth:fw frameHeight:fh viewport:full buffer:command drawable:drawable fill:fillTarget
                  geometry:geometryCandidate.valid ? &geometryCandidate.render : (fusedPresentation ? &fusedGeometry : nullptr)
                  pipeline:renderPipeline];
#else
        [self drawTexture:a frameWidth:fw frameHeight:fh viewport:full buffer:command drawable:drawable fill:fillTarget
                  geometry:geometryCandidate.valid ? &geometryCandidate.render : nullptr];
#endif
    }
#if ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC
    SPAirFusedRenderPtr fusedRecord;
    if (_airFusedRenderNotes && fusedPresentation && mode != SPLiveViewCompare) {
        fusedRecord = std::make_shared<SPAirFusedRenderRecord>();
        fusedRecord->frameID = frameID; fusedRecord->generation = seen; fusedRecord->config = seenConfig;
        fusedRecord->epoch = seenEpoch; fusedRecord->clock = seenClock; fusedRecord->slotToken = slotToken;
        fusedRecord->selectionHostTicks = selectionHost; fusedRecord->requestStartHostTicks = frame.enqueueHost;
        fusedRecord->enqueueHostTicks = frame.causalEnqueueHostTicks;
        fusedRecord->bufferWidth = width; fusedRecord->bufferHeight = height;
        fusedRecord->referenceWidth = (int)fw; fusedRecord->referenceHeight = (int)fh;
        fusedRecord->drawableWidth = (int)size.width; fusedRecord->drawableHeight = (int)size.height;
        if ([imageRectPixels isKindOfClass:NSArray.class]) {
            NSArray *rectangle = imageRectPixels;
            for (int index = 0; index < 4; index++) fusedRecord->imageRect[index] = [rectangle[index] doubleValue];
        }
        fusedRecord->synthetic = synthetic; fusedRecord->counts = counts; fusedRecord->redraw = frame.redraw;
        fusedRecord->lanczosFragment = renderPipeline == _airFusedPresentPipeline;
        fusedRecord->displayTargetMediaTime = scheduledDisplayTime;
        std::lock_guard<std::mutex> lock(_airFusedNotesMutex);
        if (_airFusedTraceSealed) ++_airFusedPostSealAttempts;
        else {
            fusedRecord->sequence = ++_airFusedRenderTotal;
            (*_airFusedRenderNotes)[(fusedRecord->sequence - 1) % SPAirFusedRenderCapacity] = fusedRecord;
        }
    }
    SPPresentedRenderSnapshot *qualitySnapshot = nil;
    if (fusedPresentation && counts && !frame.redraw && mode == SPLiveViewEnhanced) {
        SPPresentedVideoRecorder *recorder = self.presentedVideoRecorder;
        if (recorder && ptsDen > 0 && ptsDen <= INT32_MAX) {
            qualitySnapshot = [recorder encodeRenderCopyFromTexture:drawable.texture sourceOrigin:MTLOriginMake(0,0,0)
                commandBuffer:command frameID:frameID pts:CMTimeMake(ptsNum,(int32_t)ptsDen)
                synthetic:synthetic error:NULL];
        }
    }
#endif
    if (timingDiagnostic) note->encodingEndedHostTicks.store(SPHostNow());
    self->_inflightDraws.fetch_add(1);
    [command addCompletedHandler:^(id<MTLCommandBuffer> done) {
        if (frame->_measurementTrace) {
            auto event = SPAirMeasurementFrame(frame, spAirMeasurement::Kind::gpuCallback);
            event.beginHostTicks = event.endHostTicks = SPHostNow(); event.values[0] = done.status;
            event.gpuStartSeconds = done.GPUStartTime; event.gpuEndSeconds = done.GPUEndTime;
            frame->_measurementTrace->append(event);
        }
        if (done.status != MTLCommandBufferStatusCompleted) reportFailure(@"gpu");
        note->gpuHost.store((long long)SPHostNow());
#if ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC
        if (fusedRecord) {
            fusedRecord->completedHostTicks.store(SPHostNow());
            fusedRecord->completedMediaTime.store(CACurrentMediaTime());
            fusedRecord->gpuStatus.store((uint32_t)done.status);
            fusedRecord->gpuStartSeconds.store(done.GPUStartTime); fusedRecord->gpuEndSeconds.store(done.GPUEndTime);
            fusedRecord->gpuObserved.store(true, std::memory_order_release);
        }
#endif
        if (aRef) CFRelease(aRef);
        if (bRef) CFRelease(bRef);
        [preparedLease complete];
        uint64_t completedFrameID = frame.frameID; // retains the admitted buffers through GPU completion
        if (seenSurfaceToken && self.surfaceReady && seenClock == self->_presentationClockEpoch.load()) {
            self.surfaceReady(@{ @"generation": @(seen), @"configVersion": @(seenConfig), @"captureHost": @(captureHost),
                @"measurementEpoch": @(seenEpoch), @"clockEpoch": @(seenClock), @"surfaceToken": @(seenSurfaceToken), @"frameID": @(completedFrameID),
                @"counts": @(counts), @"windowVisible": @(windowVisible),
                @"gpuCompleted": @(done.status == MTLCommandBufferStatusCompleted), @"viewMode": @(mode),
                @"enhancedWidth": @(enhancedWidth), @"enhancedHeight": @(enhancedHeight),
                @"originalWidth": @(originalWidth), @"originalHeight": @(originalHeight) });
        }
        releaseTicket();
    }];
    [drawable addPresentedHandler:^(id<MTLDrawable> presentedDrawable) {
        SPAirPresentedObservationScope callbackObservation(self->_airSessionObservationEnabled ? &self->_airPresentedCallbacksPending : nullptr);
        long long gpuHost = note->gpuHost.load();
        BOOL physicallyPresented = std::isfinite(presentedDrawable.presentedTime) && presentedDrawable.presentedTime > 0;
#if ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC
        [qualitySnapshot presentedAtTime:presentedDrawable.presentedTime];
        if (fusedRecord) {
            fusedRecord->presentedTime.store(presentedDrawable.presentedTime);
            fusedRecord->presentedObserved.store(true, std::memory_order_release);
            if (physicallyPresented && counts && !frame.redraw && mode == SPLiveViewEnhanced) {
                std::lock_guard<std::mutex> lock(self->_airFusedNotesMutex);
                (synthetic ? self->_airFusedLastPositiveSynthetic : self->_airFusedLastPositiveOriginal) = fusedRecord;
            }
        }
#endif
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
        if (physicallyPresented && counts && !frame.redraw && mode == SPLiveViewEnhanced
#if ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC
            && !fusedPresentation
#endif
        ) {
            SPPresentedVideoRecorder *recorder = self.presentedVideoRecorder;
            // Capturing frame in this handler retains the exact admitted primary
            // buffer even when its command-buffer completion has already fired.
            CVPixelBufferRef recordedBuffer = frame.enhanced;
            if (recorder && recordedBuffer && ptsDen > 0 && ptsDen <= INT32_MAX) {
                [recorder recordPresentedBuffer:recordedBuffer frameID:frameID
                    pts:CMTimeMake(ptsNum, (int32_t)ptsDen) synthetic:synthetic
                    presentedTime:presentedDrawable.presentedTime];
            }
        }
#endif
        if (!physicallyPresented) reportFailure(@"display-not-presented");
        BOOL geometryActivated = NO;
        if (geometryCandidate.valid && counts && windowVisible && exposed && !occluded && presentedDrawable.presentedTime > 0 &&
            seen==self->_generation.load() && seenConfig==self->_diagnosticConfig.load() && seenEpoch==self->_diagnosticEpoch.load() && seenClock==self->_presentationClockEpoch.load()) {
            std::lock_guard<std::mutex> lock(self->_geometryMutex);
            if (seen==self->_generation.load() && seenConfig==self->_diagnosticConfig.load() && seenEpoch==self->_diagnosticEpoch.load() && seenClock==self->_presentationClockEpoch.load() &&
                self->_geometryVerifiedHost>0 && SPHostToNs(SPHostNow()-self->_geometryVerifiedHost)<=350000000LL)
                geometryActivated=self->_sharedGeometry.activate(geometryCandidate.version,frameID,captureHost);
        }
        if (physicallyPresented) dispatch_async(dispatch_get_main_queue(), ^{
            [self revealSourceGeneration:seen];
        });
        if (!self.presented) return;
        NSDictionary *info = @{
            @"captureHost": @(captureHost),
            @"presentedHost": @(SPHostNow()),
            @"presentedTime": @(presentedDrawable.presentedTime),
            @"handlerMediaTime": @(CACurrentMediaTime()),
            @"drawableWaitNs": @(drawableWaitNs),
            @"presentationEnqueueHost": @(frame.enqueueHost),
            @"presentationQueueStartHost": @(callbackHost),
            @"displaySelectionHost": @(selectionHost), @"displaySlotToken": @(slotToken),
            @"metalCommitHost": @(note->commitHost.load()),
            @"metalScheduledHost": @(note->scheduledHost.load()),
            @"metalScheduledMediaTime": @(note->scheduledMedia.load()),
            @"presentRequestMethod": @"command-buffer-ordinary",
            @"displayLinkCallbackHost": @(callbackHost),
            @"displayLinkTargetTimestamp": @(presentDeadline),
            @"displayLinkTargetPresentationTimestamp": @(scheduledDisplayTime),
            @"logicalTargetHost": @(presentationHost),
            @"scheduledMinusLogicalTargetNs": presentationHost > 0 ? @((int64_t)(scheduledDisplayTime * 1e9) - SPHostToNs(presentationHost)) : (id)[NSNull null],
            @"actualMinusScheduledDisplayNs": physicallyPresented ? @((int64_t)((presentedDrawable.presentedTime - scheduledDisplayTime) * 1e9)) : (id)[NSNull null],
            @"actualMinusLogicalTargetNs": physicallyPresented && presentationHost > 0 ? @((int64_t)(presentedDrawable.presentedTime * 1e9) - SPHostToNs(presentationHost)) : (id)[NSNull null],
            @"presentRequestMediaTime": @(note->presentRequestMedia.load()),
            @"gpuHost": @(gpuHost),
            @"occluded": @(occluded),
            @"windowVisible": @(windowVisible),
            @"exposed": @(exposed),
            @"generation": @(seen),
            @"configVersion": @(seenConfig),
            @"measurementEpoch": @(seenEpoch), @"clockEpoch": @(seenClock),
            @"ptsNum": @(ptsNum),
            @"ptsDen": @(ptsDen),
            @"synthetic": @(synthetic),
            @"viewMode": @(mode),
            @"frameID": @(frameID),
            @"counts": @(counts && physicallyPresented),
            @"width": @(width),
            @"height": @(height),
            @"drawableWidth": @((int)size.width),
            @"drawableHeight": @((int)size.height),
            @"outputImageRectPixels": imageRectPixels,
            @"surfaceGeometryAssessment": cropStatus,
            @"outputDisplayID": diagnosticDisplayID ? @(diagnosticDisplayID) : (id)[NSNull null],
            @"geometryVersion": geometryActivated ? @(geometryCandidate.version) : (id)[NSNull null],
            @"enhancedCenter": @(-1),
            @"originalCenter": @(-1),
        };
        if (timingDiagnostic) {
            NSMutableDictionary *diagnosticInfo = [info mutableCopy];
            diagnosticInfo[@"airPresentationTiming"] = note->timingMetadata(selectionHost, presentDeadline, slotToken);
            info = diagnosticInfo;
        }
        self.presented(info);
    }];
    // The update's present deadline differs from its future display target.
    // Ordinary command-buffer presentation waits for GPU scheduling before
    // invoking drawable.present(). Timed presents assert for these drawables.
    {
        if (timingDiagnostic) note->generationLockRequestedHostTicks.store(SPHostNow());
        std::lock_guard<std::mutex> generationLock(_generationMutex);
        if (timingDiagnostic) note->generationLockAcquiredHostTicks.store(SPHostNow());
        if (timingDiagnostic) note->presentationLockRequestedHostTicks.store(SPHostNow());
        std::lock_guard<std::mutex> pendingLock(_presentationMutex);
        if (timingDiagnostic) note->presentationLockAcquiredHostTicks.store(SPHostNow());
        NSString *invalid = seen != _generation.load() ? @"generation" :
            (seenConfig != _diagnosticConfig.load() ? @"configuration" : (seenEpoch != _diagnosticEpoch.load() ? @"epoch" :
                (seenClock != _presentationClockEpoch.load() ? @"clock-retired" : nil)));
        if (!invalid) {
            const int64_t checkHost = timingDiagnostic ? SPHostNow() : 0;
            // This single existing CA clock sample remains the decision input.
            const double checkMediaTime = CACurrentMediaTime();
            if (timingDiagnostic) {
                note->deadlineCheckHostTicks.store(checkHost);
                note->deadlineCheckMediaTimeSeconds.store(checkMediaTime);
                note->deadlineSlackSeconds.store(presentDeadline - checkMediaTime);
            }
            if (checkMediaTime >= presentDeadline) invalid = @"display-submit-deadline";
        }
        if (invalid) {
#if ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC
            if (fusedRecord) fusedRecord->publicationCancelled.store(true);
            [qualitySnapshot cancelPublication];
#endif
            if (_airCadenceFrames) _airCadenceFrames->append(SPAirFrameRecord(frame, SPAirFrameKind::discarded, SPAirReason(invalid), SPAirFrameStage::finalCheck, slot));
            [command commit]; reportFailure(invalid); return;
        }
        [command addScheduledHandler:^(id<MTLCommandBuffer> scheduled) {
            (void)scheduled;
            note->scheduledHost.store(SPHostNow());
            note->scheduledMedia.store(CACurrentMediaTime());
        }];
        // This records wrapper registration, not the private present call.
        note->presentRequestMedia.store(CACurrentMediaTime());
        [command presentDrawable:drawable];
        note->commitHost.store(SPHostNow());
        [command commit];
        _lastSubmittedPresentationPTS = {ptsNum,ptsDen}; _haveSubmittedPresentationPTS = true;
    }
    if (_cache) CVMetalTextureCacheFlush(_cache, 0);
}

@end

struct SPLiveHeld {
    CVPixelBufferRef source = nullptr;
    CVPixelBufferRef yuv = nullptr;
    CVPixelBufferRef lowPrescaled = nullptr;
    uint64_t lowPrescaledConfig = 0;
    int64_t host = 0;
    sp::SPRational pts{};
    int pins = 0;
    uint64_t previousIdentity = 0;
    sp::RifeSourceClockTarget pairClockSource{};
};

struct SPLiveInbound {
    CVPixelBufferRef buffer = nullptr;
    int64_t ptsNum = 0;
    int64_t ptsDen = 1;
    int64_t host = 0;
    int64_t readyHost = 0;
    uint64_t generation = 0;
};

struct SPLiveJob {
    uint64_t diagnosticID = 0;
    uint64_t measurementEpoch = 0;
    int64_t callbackHost = 0;
    uint64_t configVersion = 0;
    uint64_t generation = 0;
    int64_t captureHost = 0;
    sp::SPRational pts[3]{};
    sp::SPRational phase[3]{};
    int64_t targetHost[3]{};
    sp::RifePairClockTarget pairClock[3]{};
    uint64_t clockEpoch = 0;
    int count = 0;
    uint64_t frameA = 0;
    uint64_t frameB = 0;
    uint64_t inflightEpoch = 0;
    uint64_t probeRound = 0;
    int probeIndex = -1;
    CVPixelBufferRef probeSourceA = nullptr, probeSourceB = nullptr;
    CMTime probePreviousPTS = kCMTimeInvalid, probeCurrentPTS = kCMTimeInvalid;
};

struct SPSRJob {
    CVPixelBufferRef input = nullptr;
    CVPixelBufferRef original = nullptr;
    sp::SPRational pts{};
    int64_t captureHost = 0;
    int64_t targetHost = 0;
    int64_t geometryHost = 0;
    uint64_t clockEpoch = 0;
    uint64_t sourceGeneration = 0;
    uint64_t configVersion = 0;
    uint64_t sequence = 0;
    uint64_t bytes = 0;
    BOOL synthetic = NO;
    BOOL held = NO;
    BOOL discontinuity = NO;
};

static void SPReleaseSRJob(SPSRJob *job) {
    if (!job) return;
    if (job->input) CVPixelBufferRelease(job->input);
    if (job->original) CVPixelBufferRelease(job->original);
    delete job;
}

struct SPPlaySlot {
    sp::SPRational pts{};
    uint64_t jobID = 0, clockEpoch = 0, measurementEpoch = 0;
    int64_t targetHost = 0;
    int64_t readyHost = 0;
    BOOL synthetic = NO;
    BOOL fixedFallback = NO;
    CVPixelBufferRef enhanced = nullptr;
    CVPixelBufferRef original = nullptr;
    uint64_t frameID = 0;
    uint64_t sourceGeneration = 0;
    uint64_t configVersion = 0;
    int64_t captureHost = 0;
    int64_t geometryHost = 0;
    BOOL hasCenter = NO;
    double enhancedCenter = -1;
    double originalCenter = -1;
};

struct SPPendingPhase {
    sp::SPRational pts{};
    uint64_t jobID = 0, configVersion = 0, clockEpoch = 0, measurementEpoch = 0;
    int64_t targetHost = 0;
    uint64_t generation = 0;
};

struct SPRateBudgetWindowSample {
    int64_t host = 0;
    uint64_t planned = 0, dropped = 0;
};

struct SPFrameMark {
    uint64_t jobID = 0, clockEpoch = 0;
    int64_t readyHost = 0;
    int64_t targetHost = 0;
    BOOL hasCenter = NO;
    double enhancedCenter = -1;
    double originalCenter = -1;
    BOOL held = NO;
    uint64_t fpsEpoch = 0;
};

static int64_t SPRationalToHost(sp::SPRational seconds) {
    mach_timebase_info_data_t info;
    mach_timebase_info(&info);
    if (seconds.den == 0 || info.numer == 0) return 0;
    __int128 ns = (__int128)seconds.num * 1000000000 / seconds.den;
    __int128 host = ns * info.denom / info.numer;
    if (host > INT64_MAX) return INT64_MAX;
    if (host < INT64_MIN) return INT64_MIN;
    return (int64_t)host;
}

static void SPReleaseSlot(SPPlaySlot &slot) {
    if (slot.enhanced) CVPixelBufferRelease(slot.enhanced);
    if (slot.original) CVPixelBufferRelease(slot.original);
    slot.enhanced = nullptr;
    slot.original = nullptr;
}

static NSDictionary *SPRifeSourceClockValue(const sp::RifeSourceClockTarget &target) {
    return @{ @"frozen":@(target.frozen), @"targetHost":@(target.targetHost), @"frozenDelayHost":@(target.delayHost),
        @"ptsNum":@(target.pts.num), @"ptsDen":@(target.pts.den), @"generation":@(target.context.generation),
        @"configVersion":@(target.context.config), @"measurementEpoch":@(target.context.measurement), @"clockEpoch":@(target.context.clock) };
}
static NSDictionary *SPRifePairClockValue(const sp::RifePairClockTarget &target, uint64_t frameA, uint64_t frameB) {
    NSString *binding=@"unbound-missing-endpoint";
    switch(target.binding) {
        case sp::RifePairClockBinding::bound: binding=@"bound"; break;
        case sp::RifePairClockBinding::contextMismatch: binding=@"unbound-context"; break;
        case sp::RifePairClockBinding::unorderedEndpoints: binding=@"unbound-endpoint-order"; break;
        case sp::RifePairClockBinding::invalidPhase: binding=@"unbound-phase"; break;
        case sp::RifePairClockBinding::overflow: binding=@"unbound-overflow"; break;
        case sp::RifePairClockBinding::frozenOnly: binding=@"unbound-external-frozen-deadline"; break;
        case sp::RifePairClockBinding::missingEndpoint: break;
    }
    return @{ @"frameA":@(frameA), @"frameB":@(frameB), @"ptsNum":@(target.pts.num), @"ptsDen":@(target.pts.den),
        @"generation":@(target.context.generation), @"configVersion":@(target.context.config),
        @"measurementEpoch":@(target.context.measurement), @"clockEpoch":@(target.context.clock),
        @"binding":binding, @"alphaTimeNum":target.alphaTimeValid ? @(target.alphaTime.num) : (id)NSNull.null,
        @"alphaTimeDen":target.alphaTimeValid ? @(target.alphaTime.den) : (id)NSNull.null,
        @"legacyCandidateTargetHost":target.legacyTargetHost>0 ? @(target.legacyTargetHost) : (id)NSNull.null,
        @"legacyFrozenDelayHost":target.legacyTargetHost>0 ? @(target.legacyDelayHost) : (id)NSNull.null,
        @"endpointA":SPRifeSourceClockValue(target.endpointA), @"endpointB":SPRifeSourceClockValue(target.endpointB),
        @"selectedTargetHost":@(target.selectedTargetHost), @"frozenDeadlineOverride":@(target.deadlineOverride),
        @"selectedMinusLegacyHost":target.legacyTargetHost>0 ? @(target.selectedTargetHost-target.legacyTargetHost) : (id)NSNull.null,
        @"metricScope":@"opt-in target remapping; legacy candidate and selected target must be evaluated separately" };
}
static NSArray *SPRifeJobPairClockValues(const SPLiveJob *job) {
    NSMutableArray *values=[NSMutableArray array];
    for(int i=0;i<job->count;++i) if(job->pairClock[i].recorded)
        [values addObject:SPRifePairClockValue(job->pairClock[i],job->frameA,job->frameB)];
    return values;
}

@interface SPLiveProcessor (SPRifePairClockPrivate)
- (void)airDetachSessionServiceTrace:(nullable SPRifeBridge *)bridge reason:(NSString *)reason;
- (void)submitEventGroup:(const std::vector<sp::SPScheduleOutput> &)events generation:(uint64_t)generation
    frozenDeadline:(int64_t)frozenDeadline frozenPairClock:(const sp::RifePairClockTarget *)frozenPairClock;
- (BOOL)deferRifeEvent:(const sp::SPScheduleOutput &)event generation:(uint64_t)generation
    deadline:(int64_t)deadline retryHost:(int64_t)retryHost frozenPairClock:(const sp::RifePairClockTarget *)frozenPairClock;
@end

struct SPAirDelayAlignmentEvent {
    uint64_t sequence, generation, config, epochBefore, epochAfter;
    int64_t hostTicks, intervalNs, modelNs, processNs, presentationLeadNs, renderMarginNs;
    int64_t wantedNs, capNs, queueLimitNs, roundedNs, finalNs;
    int64_t oldSourceLeadNs, actualSourceLeadNs, positiveIntervalP95Ns;
    uint64_t positiveIntervalHistoryCount, positiveIntervalObservedCount;
    int requestedMultiplier, effectiveMultiplier;
    bool calculated, activeX2, sourceOnly, timeClamped, byteClamped;
    bool robustSourceLeadRequested, robustSourceLeadApplied;
};
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
using SPAirDelayAlignmentRing = SPAirCausalRing<SPAirDelayAlignmentEvent, 131072>;
#else
using SPAirDelayAlignmentRing = SPAirCausalRing<SPAirDelayAlignmentEvent, 16384>;
#endif
static NSDictionary *SPAirDelayAlignmentExport(const std::vector<SPAirDelayAlignmentEvent> &values, uint64_t total, int64_t cutoff) {
    NSMutableArray *events = [NSMutableArray arrayWithCapacity:values.size()];
    for (const auto &e : values) {
        if (e.hostTicks > cutoff) continue;
        [events addObject:@{ @"sequence": @(e.sequence), @"hostTicks": @(e.hostTicks), @"generation": @(e.generation),
            @"configVersion": @(e.config), @"epochBefore": @(e.epochBefore), @"epochAfter": @(e.epochAfter),
            @"calculated": @(e.calculated), @"activeX2": @(e.activeX2), @"sourceOnly": @(e.sourceOnly),
            @"requestedMultiplier": @(e.requestedMultiplier), @"effectiveMultiplier": @(e.effectiveMultiplier),
            @"intervalNs": e.calculated ? @(e.intervalNs) : (id)NSNull.null,
            @"robustSourceLeadRequested": @(e.robustSourceLeadRequested), @"robustSourceLeadApplied": @(e.robustSourceLeadApplied),
            @"robustSourceLeadBootstrap": @(e.robustSourceLeadApplied && e.positiveIntervalHistoryCount == 0),
            @"oldSourceLeadNs": e.calculated ? @(e.oldSourceLeadNs) : (id)NSNull.null,
            @"actualSourceLeadNs": e.calculated ? @(e.actualSourceLeadNs) : (id)NSNull.null,
            @"positiveIntervalP95Ns": e.robustSourceLeadApplied && e.positiveIntervalHistoryCount ? @(e.positiveIntervalP95Ns) : (id)NSNull.null,
            @"positiveIntervalHistoryCount": @(e.positiveIntervalHistoryCount), @"positiveIntervalObservedCount": @(e.positiveIntervalObservedCount),
            @"modelNs": e.calculated ? @(e.modelNs) : (id)NSNull.null,
            @"processNs": e.calculated ? @(e.processNs) : (id)NSNull.null,
            @"presentationLeadNs": e.activeX2 ? @(e.presentationLeadNs) : (id)NSNull.null,
            @"renderMarginNs": e.calculated ? @(e.renderMarginNs) : (id)NSNull.null,
            @"wantedNs": e.calculated ? @(e.wantedNs) : (id)NSNull.null,
            @"capNs": @(e.capNs), @"queueLimitNs": e.calculated ? @(e.queueLimitNs) : (id)NSNull.null,
            @"roundedNs": e.calculated ? @(e.roundedNs) : (id)NSNull.null,
            @"finalNs": @(e.finalNs), @"timeClamped": @(e.timeClamped), @"byteClamped": @(e.byteClamped) }];
    }
    return SPAirRingMetadata(total, SPAirDelayAlignmentRing::capacity, events);
}

@implementation SPLiveProcessor {
    dispatch_queue_t _q;
    spAirMeasurement::TracePtr _measurementTrace;
    uint64_t _measurementClockLife, _measurementArm, _measurementFire;
    std::unique_ptr<SPAirFrameRing> _airCadenceCallbacks;
    std::unique_ptr<SPAirBudgetRing> _airCadenceBudget;
    std::unique_ptr<SPAirCurrentStatsRing> _airCurrentStatsCalls;
    NSString *_airTraceSessionID;
    NSObject *_airTraceKeeperJournal;
    SPAirRetainedPayloadBudget *_airTracePayloadBudget;
    void (^_airTraceRetiredServiceHandler)(NSObject *, NSDictionary *);
    dispatch_queue_t _airTraceReplyQueue;
    NSHashTable<SPRifeBridge *> *_airTraceDetachedBridges;
    uint64_t _airTraceDetachPending, _airTraceDetachDropped, _airTraceServiceOrdinal, _airTraceUntrackedJobsAtBegin, _airTraceSessionBeginHostTicks;
    BOOL _airTraceSessionActive, _airTraceRecordingSaturated;
    std::atomic<uint64_t> _airOutputSubmitDeadlineFailures;
    BOOL _airDelayAlignmentRequested, _airDelayAlignmentActiveX2;
    BOOL _airDelayAlignmentDiagnosticRequested, _airTrueSourceIntervalDiagnosticRequested, _airRobustSourceLeadDiagnosticRequested;
    SPLivePlanRequest *_airPerformanceRecipe;
    BOOL _airPerformanceCandidate, _airPerformanceRequested, _airPerformanceEnabled, _airPerformanceFormatKnown, _airPerformanceEligibilityKnown;
    SPLiveCaptureSourceKind _airActualSourceKind;
    NSString *_airPerformanceReason, *_airPerformanceFormatReason, *_airPerformanceEligibilityReason;
    NSDictionary *_airPerformanceSelection;
    BOOL _airTrueSourceIntervalRequested, _airInteractiveCap125msRequested;
    int64_t _airDelayAlignmentLeadNs, _airDelayAlignmentMarginNs;
    std::unique_ptr<SPAirDelayAlignmentRing> _airDelayAlignmentEvents;
    SPLivePlanRequest *_request;
#if ODF_AIR_BETA_DIAGNOSTIC
    SPLivePlanRequest *_airBetaRecipe;
    NSString *_airBetaFormatReason, *_airBetaFormatDescription, *_airBetaFallbackReason, *_airBetaOriginalFailure;
    NSString *_airBetaEligibilityReason;
    BOOL _airBetaFormatKnown, _airBetaEligibilityKnown;
    double _airBetaObservedRefreshHz;
#endif
    SPLiveResolvedPlan *_resolved;
    SPFRCEngine *_engine;
    SPLowLatencyEngine *_lowLatency;
    SPRifeBridge *_rife;
#if ODF_AIR_RESIDENT_KEEPALIVE_DIAGNOSTIC
    SPRifeBridge *_airResidentRetiredBridge;
    uint64_t _airCapacitySealedHostTicks;
    uint64_t _airResidentPlanToken;
    NSString *_airResidentInstallFailure;
#endif
    SPDistilDRBA *_distil;
    SPAppleLowLatencySR *_appleSR;
    SPAppleVideoSR *_videoSR;
    SPAnime4K *_animeSR;
    SPRealCUGAN *_cuganSR;
    SPArtCNNSR *_artCNNSR;
    std::deque<SPSRJob *> _srPending;
    uint64_t _srSequence;
    uint64_t _srPendingBytes;
    BOOL _srBusy, _srFailed;
    sp::SPRational _srActivePTS;
    BOOL _videoSRDiscontinuity;
    dispatch_queue_t _prepareQ;
    uint64_t _prepareToken;
    uint64_t _ackRequestID;
    NSString *_ackEngineID, *_ackModelID;
    NSDictionary *_statsSnapshot;
    std::mutex _statsMx;
    SPFrameBudgetMetal *_metal;
    SPSpatialScaler *_scaler;
    SPSpatialScaler *_baselineScaler;
    SPSpatialScaler *_srInputScaler;
    BOOL _testRecordSRInput;
    int _testSRInputWidth, _testSRInputHeight;
    CVPixelBufferRef _testSRExpectedBaseline, _testSRExpectedSource;
    int64_t _testSRExpectedHost;
    BOOL _testSRSourceSlot, _testSRSyntheticSlot, _testSRNewGenerationSlot;
    BOOL _testSRBaselineMatches, _testSRIdentityMatches;
    NSString *_testSRError;
    VTPixelTransferSessionRef _transfer;
    SPAirSourceConversionWorker *_sourceConverter;
    spAirSourceConversion::State _sourceConversions;
    std::array<uint64_t, 8> _sourceConversionInvalidated;
    uint64_t _sourceConversionDelivered, _sourceConversionFrames, _sourceConversionFailures;
    std::vector<SPPlaySlot> _slots;
    std::vector<SPPendingPhase> _pending;
    std::vector<sp::SPScheduleOutput> _rifePending;
    uint64_t _rifePendingGeneration;
    BOOL _haveRifeDeferred;
    sp::SPScheduleOutput _rifeDeferredEvent;
    int64_t _rifeDeferredDeadline;
    sp::RifePairClockTarget _rifeDeferredPairClock;
    int64_t _rifeDeferredRetryHost;
    uint64_t _rifeDeferredGeneration, _rifeDeferredClockEpoch;
    uint64_t _rifeDeferredAccepted, _rifeDeferredExpired, _rifeDeferredStale, _rifeDeferredCapacityDrops;
    uint64_t _rifePoolPressureEvents, _rifePoolRetryAdmissions, _rifePoolUnexpiredDrops;
    BOOL _rifeSlowMode;
    BOOL _lowPrescaleSlowMode;
    BOOL _testCapturePlayout;
    BOOL _testExactFixedSchedule;
    BOOL _testKeepLowRealtime;
    std::vector<std::pair<sp::SPRational, bool>> _testPlayout;
    std::vector<sp::SPRational> _testHoldPlayout;
    NSMutableArray *_testPendingTrace;
    NSMutableArray *_testTimingTrace;
    std::unordered_map<uint64_t, SPFrameMark> _marks;
    // Bounded diagnostic metadata only; jobs retain their existing owners.
    std::unordered_map<uint64_t, std::pair<int64_t, uint64_t>> _r7JobHosts;
    uint64_t _r7JobCompleted, _r7JobUntracked;
    NSDictionary *_r7LastJobSubmitted, *_r7LastJobCompleted;
    NSMutableArray<NSDictionary *> *_r7JobTimeline;
    NSMutableArray<NSDictionary *> *_r8OutputTimeline;
    dispatch_source_t _clock;
    BOOL _haveAnchor;
    sp::SPRational _anchorPts;
    int64_t _anchorHost;
    uint64_t _clockEpoch, _clockRetiredJobs, _clockRetiredModelOutputs, _clockRetiredPhaseDrops;
    int64_t _delayHost;
    int64_t _intervalHost;
    BOOL _haveInterval;
    BOOL _airRobustSourceLeadRequested;
    sp::AirRobustSourceLead _airRobustSourceLeadHistory;
    sp::AirSourceLeadEvaluation _airSourceLeadEvaluation;
    BOOL _airRobustSourceLeadApplied;
    double _frcEwmaSec;
    double _scaleEwmaSec;
    BOOL _delayClamped;
    BOOL _delayTimeClamped, _delayByteClamped;
    NSUInteger _peakSlots;
    uint64_t _r8ReportedSlotBytesPeak, _r8SlotReferencePeak, _r8BudgetEvictions;
    BOOL _haveLastPts;
    sp::SPRational _lastPresentedPts;
    CVPixelBufferRef _lastEnhanced;
    CVPixelBufferRef _lastOriginal;
    BOOL _lastSynthetic;
    sp::SPRational _lastRedrawPts;
    int64_t _lastRedrawGeometryHost;
    int64_t _lastRedrawTargetHost;
    uint64_t _nextFrameID;
    uint64_t _outputSurfaceToken;
    int64_t _outputSurfaceMinimumCaptureHost;
    uint64_t _lowPrescaleInputs, _lowSyntheticNoRescale, _testBaselineMatches, _testBaselineMismatches;
    uint64_t _outputWarmGPUCompleted, _outputWarmGPUFailed, _outputWarmRejected;
    uint64_t _outputPresentedZeroTime, _outputPresentedValidTime;
    BOOL _pixelDiagnosticsEnabled;
    int64_t _pixelLastInputAttemptHost;
    NSMutableDictionary<NSNumber *, NSDictionary *> *_pixelInputSamples;
    NSMutableArray<NSNumber *> *_pixelInputOrder;
    NSDictionary *_pixelLastInput, *_pixelLastOutputSubmitted, *_pixelPendingOutput, *_pixelLastOutputCallback, *_pixelLastOutputPresented;
    uint64_t _pixelInputAttempts, _pixelInputExpired, _pixelOutputMatched, _pixelOutputUnmatchedCallback, _pixelOutputPresentedCount;
    uint64_t _epochPhysicalSource, _epochPhysicalSynthetic;
    BOOL _physicalHavePts;
    sp::SPRational _physicalLastPts;
    NSInteger _outputWarmMode;
    int _outputWarmEnhancedWidth, _outputWarmEnhancedHeight, _outputWarmOriginalWidth, _outputWarmOriginalHeight;
    uint64_t _inflightEpoch;
    sp::SPRational _previousSourcePts;
    sp::FPSMeter _fpsMeter;
    sp::FPSMeter _pumpedCaptureMeter;
    uint64_t _fpsObservationEpoch;
    uint64_t _previousSourceIdentity;
    BOOL _havePreviousSourcePts;
    sp::SPRateScheduler _scheduler;
    std::mutex _inMx;
    std::deque<SPLiveInbound> _inbound;
    sp::FPSMeter _copiedMeter; // protected by _inMx, before inbound eviction
    uint64_t _copiedGeneration, _copiedFrames;
    BOOL _pumpQueued;
    std::unordered_map<uint64_t, SPLiveHeld> _held;
    uint64_t _nextIdentity;
    uint64_t _sourceGeneration;
    uint64_t _configVersion;
    BOOL _stopped;
    BOOL _building;
    BOOL _preparing;
    BOOL _asyncPrepareFailed;
    BOOL _sourceSizeConstraintFailed;
    BOOL _sessionReady;
    BOOL _scoreOutput;
    int _inflight;
    int _width;
    int _height;
    int _sourceWidth, _sourceHeight;
    sp::PresentationGeometry _presentationGeometry;
    NSString *_surfaceGeometryAssessment;
    NSString *_surfaceCropEndpoint;
    uint64_t _lastPairB;
    BOOL _havePair;
    uint64_t _captured, _idle, _completeFrames, _interrupted;
    uint64_t _processedSequence;
    std::mutex _capturePressureMutex;
    bool _capturePressureQueued;
    uint64_t _capturePressureGeneration;
    uint64_t _capturePressureEvents;
    int64_t _lastProcessedHost, _lastDrawablePresentedHost;
    int64_t _r7ContentChangedHost;
    uint64_t _r7ContentChangedGeneration, _r7ContentChangedConfig, _r7ContentChangedEpoch;
    uint64_t _r7LumaGeneration, _r7LumaConfig, _r7LumaEpoch;
    uint64_t _syntheticOK, _syntheticFail, _presentedSource, _presentedSynthetic;
    uint64_t _scheduledSynthetic, _submitted;
    sp::FRCBudgetGate _r9FRCBudgetGate;
    double _r9RequiredBudgetMs, _r9AllowedBudgetMs;
    uint64_t _r9BudgetRejectedPhases, _r9BackendFullPhases, _r9BudgetProbeJobs;
    uint64_t _r9OnTimeSynthetic, _r9LatePhysicalSynthetic, _r9TimingUnknownSynthetic;
    uint64_t _r9RateSyntheticBaseline, _r9RateOnTimeBaseline;
    int64_t _r9RateHost;
    double _r9GeneratedFPS, _r9OnTimeSyntheticFPS;
    sp::RateBudget _rateBudget;
    sp::FixedRateBudget _fixedRateBudget;
    int _fixedMaxBatchCount;
    int _effectiveMultiplier;
    BOOL _rateBudgetPassthrough;
    int64_t _rifeBusySinceHost;
    uint64_t _rifeBudgetRejectedPhases, _rateBudgetSkippedPhases;
    uint64_t _fixedSourceReused, _fixedFallbackPresented, _fixedFallbackReplaced;
    std::deque<SPRateBudgetWindowSample> _rateBudgetWindow;
    std::vector<sp::SPRational> _rateBudgetDropPTS;
    std::deque<int64_t> _rateBudgetCompletedHosts;
    NSDictionary *_rateBudgetLastDecision;
    BOOL _rateBudgetProbeActive;
    uint64_t _rateBudgetProbeRound, _rateBudgetProbeJobs, _rateBudgetProbeLastFrameB;
    uint64_t _rateBudgetProbeInFlightToken, _rateBudgetProbeInFlightEpoch;
    int _rateBudgetProbeCollected;
    int64_t _rateBudgetProbeNextHost;
    double _rateBudgetProbeMedianMs;
    std::deque<SPLiveJob *> _rateBudgetProbePending;
    std::vector<double> _rateBudgetProbeTaskCosts, _rateBudgetProbePhaseCosts;
    uint64_t _nativeBudgetSkippedPhases;
    BOOL _nativeBudgetActive;
    BOOL _nativeBGRADirectActive;
    uint64_t _nativeBGRADirectFrames;
    std::mutex _rawCadenceMutex;
    sp::NativeCadenceGate _nativeCadence;
    uint64_t _sourceMissingDrops, _sourceConversionDrops, _sourcePolicyDrops;
    uint64_t _sourceStaleDrops, _sourceDueMergeDrops, _sourceSlotEvictionDrops;
    uint64_t _deadlineDrops, _sceneSkips, _queueDrops, _presentedCallbacks, _renderDrops;
    uint64_t _engineUnavailableDrops, _inflightLimitDrops, _engineSubmissionRejectedDrops, _rifePoolPressureDrops;
    NSMutableDictionary *_presentationFailuresLifetime, *_presentationFailuresEpoch;
    NSMutableDictionary<NSNumber *, NSDictionary *> *_geometryInputs;
    NSMutableArray<NSNumber *> *_geometryInputOrder;
    NSMutableDictionary *_firstPresentationFailureLifetime, *_firstPresentationFailureEpoch, *_ignoredPresentedCallbacks;
    uint64_t _staticHoldPhases, _epochStaticHoldPhases;
    uint64_t _lateReadyDrops, _staleReadyDrops, _dueMergeDrops, _pendingExpiredDrops, _slotEvictionDrops;
    std::vector<int64_t> _captureToModelReadyNs;
    std::vector<int64_t> _captureToOutputReadyNs;
    uint64_t _stoppedDrops, _generationDrops;
    uint64_t _measurementEpoch;
    uint64_t _epochSamples;
    uint64_t _epochDuplicates;
    uint64_t _epochSizeChanges;
    uint64_t _epochScheduled;
    uint64_t _epochPresentedSynthetic;
    uint64_t _epochPresentedSource;
    uint64_t _epochDeadline;
    uint64_t _epochQueueDrops;
    uint64_t _phaseBatchSplits;
    uint32_t _epochHist[201];
    sp::PresentationOrder _presentationOrder;
    BOOL _epochMonotonic;
    BOOL _epochHavePts;
    sp::SPRational _epochLastPts;
    int _epochWidth;
    int _epochHeight;
    BOOL _delayClampNoted;
    std::vector<int64_t> _copyEntryNs;
    std::vector<sp::SPRational> _claimedDrops;
    std::mutex _latencyMx;
    std::vector<int64_t> _latencyNs;
    std::vector<int64_t> _frcNs;
    std::vector<int64_t> _scaleNs;
    std::vector<int64_t> _transferNs;
    std::vector<int64_t> _queueNs;
    std::vector<int64_t> _playheadNs;
    std::vector<int64_t> _drawableWaitNs;
    std::vector<int64_t> _presentationAdmissionToCallbackNs;
    std::vector<int64_t> _metalCommitToDisplayNs;
    std::vector<int64_t> _displayScheduledTargetOffsetNs;
    std::vector<int64_t> _presentGapNs;
    std::vector<int64_t> _presentMediaLagNs;
    std::vector<int64_t> _gpuToDisplayNs;
    std::vector<int64_t> _captureToDisplayNs;
    OSType _sourcePixelFormat;
    BOOL _holdFailureStatus;
    uint64_t _occludedPresents;
    BOOL _phaseRejectNoted;
    uint64_t _measuredScheduled;
    uint64_t _centerSampleNs;
    int _centerSamples;
    BOOL _probeWindowOpen;
    BOOL _probeAggregateOnly;
    BOOL _probeMonotonic;
    BOOL _probeSizeOK;
    BOOL _probeHaveLast;
    sp::SPRational _probeMinPts;
    sp::SPRational _probeLastPts;
    int64_t _windowStart;
    int _windowCallbacks, _windowChanged;
    uint8_t _previousLuma[64];
    BOOL _haveLuma;
    int64_t _lastStatsHost;
    NSMutableArray<NSDictionary *> *_probeOutputs;
    dispatch_semaphore_t _probeGate;
    int _probeSyntheticGoal;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _airOutputSubmitDeadlineFailures.store(0, std::memory_order_relaxed);
    if (SPAirFullMeasurementTraceRequested())
        _measurementTrace = std::make_shared<spAirMeasurement::Trace>(spAirMeasurement::processorCapacity);
    _airRobustSourceLeadRequested = SPAirRobustSourceLeadRequested();
    if (SPAirCadenceCausalTraceRequested()) {
        _airCadenceCallbacks = std::make_unique<SPAirFrameRing>();
        _airCadenceBudget = std::make_unique<SPAirBudgetRing>();
#if defined(ODF_AIR_BETA_DIAGNOSTIC) && ODF_AIR_BETA_DIAGNOSTIC == 1
        const char *statsDiagnostic = getenv("ODF_AIR_BETA_CAPTURE_DIAGNOSTIC");
        if (statsDiagnostic && strcmp(statsDiagnostic, "1") == 0)
            _airCurrentStatsCalls = std::make_unique<SPAirCurrentStatsRing>();
#else
        _airCurrentStatsCalls = std::make_unique<SPAirCurrentStatsRing>();
#endif
    }
#if defined(ODF_AIR_PRESENTATION_GUARD_DIAGNOSTIC) && ODF_AIR_PRESENTATION_GUARD_DIAGNOSTIC == 1
    const char *alignDelay = getenv("ODF_AIR_DELAY_ALIGNMENT_DIAGNOSTIC");
    _airDelayAlignmentRequested = alignDelay && strcmp(alignDelay, "1") == 0;
    const char *trueInterval = getenv("ODF_AIR_TRUE_SOURCE_INTERVAL_DIAGNOSTIC");
    _airTrueSourceIntervalRequested = trueInterval && strcmp(trueInterval, "1") == 0;
    const char *cap125ms = getenv("ODF_AIR_INTERACTIVE_CAP_125MS_DIAGNOSTIC");
    _airInteractiveCap125msRequested = cap125ms && strcmp(cap125ms, "1") == 0;
#endif
    _airDelayAlignmentDiagnosticRequested = _airDelayAlignmentRequested;
    _airTrueSourceIntervalDiagnosticRequested = _airTrueSourceIntervalRequested;
    _airRobustSourceLeadDiagnosticRequested = _airRobustSourceLeadRequested;
    if (_airDelayAlignmentRequested && _airCadenceCallbacks) _airDelayAlignmentEvents = std::make_unique<SPAirDelayAlignmentRing>();
    _capturePressureQueued = false;
    _capturePressureGeneration = 0;
    _q = dispatch_queue_create("app.openduckframe.live",
                               dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    _request = [[SPLivePlanRequest alloc] init];
    _request.rateKind = SPLiveRateMultiplier;
    _request.multiplier = 2;
    _request.fpsNumerator = 60;
    _request.fpsDenominator = 1;
    _request.quality = SPFRCQualityNormal;
    _request.engineID = @"apple.frc";
    _request.modelID = @"vt.frc.normal";
    _request.qualityID = @"normal";
    _request.scaleEngine = SPLiveScaleLanczos;
    _request.outputWidth = 1920;
    _request.outputHeight = 1080;
    _presentationFailuresLifetime = [NSMutableDictionary dictionary];
    _presentationFailuresEpoch = [NSMutableDictionary dictionary];
    _firstPresentationFailureLifetime = [NSMutableDictionary dictionary];
    _firstPresentationFailureEpoch = [NSMutableDictionary dictionary];
    _ignoredPresentedCallbacks = [NSMutableDictionary dictionary];
    _geometryInputs = [NSMutableDictionary dictionary];
    _geometryInputOrder = [NSMutableArray array];
    _resolved = [[SPLiveResolvedPlan alloc] init];
    _sourceGeneration = 1;
    _configVersion = 1;
    _nextIdentity = 1;
    _windowStart = SPHostNow();
    _frcEwmaSec = 0.030;
    _scaleEwmaSec = 0.004;
    _probeMonotonic = YES;
    _probeSizeOK = YES;
    _prepareQ = dispatch_queue_create("app.openduckframe.live-prepare",
                                     dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    dispatch_queue_set_specific(_q, SPLiveQueueKey, (__bridge void *)self, NULL);
    _epochMonotonic = YES;
    [self resetRateBudgetOnQueue];
    [self beginMeasurementEpoch];
    VTPixelTransferSessionCreate(kCFAllocatorDefault, &_transfer);
    return self;
}

- (void)dealloc {
    [self stop];
    if (_transfer) CFRelease(_transfer);
}

- (SPLiveResolvedPlan *)resolvedPlan { return _resolved; }

- (NSDictionary *)rememberStats:(NSDictionary *)stats {
    std::lock_guard<std::mutex> lock(_statsMx);
    _statsSnapshot = stats;
    return stats;
}

- (NSDictionary<NSString *, id> *)stats {
    if (dispatch_get_specific(SPLiveQueueKey) == (__bridge void *)self) return [self rememberStats:[self currentStats]];
    __block NSDictionary *value = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(_q, ^{
        value = [self rememberStats:[self currentStats]];
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_MSEC)) != 0) {
        std::lock_guard<std::mutex> lock(_statsMx);
        NSMutableDictionary *stale = [(_statsSnapshot ?: @{}) mutableCopy];
        stale[@"snapshotStale"] = @YES;
        return stale;
    }
    return value ?: @{};
}

- (void)requestStatsSnapshotOnQueue:(dispatch_queue_t)replyQueue completion:(void (^)(NSDictionary<NSString *, id> *))completion {
    dispatch_async(_q, ^{
        NSDictionary *value = [self rememberStats:[self currentStats]];
        dispatch_async(replyQueue, ^{ completion(value); });
    });
}

- (NSDictionary<NSString *, id> *)cachedStatsSnapshot {
    NSDictionary *value;
    {
        std::lock_guard<std::mutex> lock(_statsMx);
        value = _statsSnapshot;
    }
    const uint64_t readHost = SPHostNow();
    NSDictionary *sampling = value[@"statsSampling"];
    const uint64_t end = [sampling[@"endHostTicks"] unsignedLongLongValue];
    const int64_t age = end && readHost >= end ? SPHostToNs(readHost - end) : -1;
    return @{ @"available": @(value != nil), @"stats": value ?: @{},
        @"sampleBeginHostTicks": sampling[@"beginHostTicks"] ?: (id)NSNull.null,
        @"sampleEndHostTicks": sampling[@"endHostTicks"] ?: (id)NSNull.null,
        @"threadID": sampling[@"threadID"] ?: (id)NSNull.null,
        @"readHostTicks": @(readHost), @"ageNs": age >= 0 ? @(age) : (id)NSNull.null,
        @"snapshotStale": @(age < 0 || age > 1500000000LL) };
}

- (NSDictionary<NSString *, id> *)statsBoundaryCountersSnapshot {
    const uint64_t begin = SPHostNow();
    uint64_t threadID = 0;
    pthread_threadid_np(nullptr, &threadID);
    NSDictionary *prepared = [self.outputPreview preparedTextureCountersSnapshot] ?: @{};
    const uint64_t deadline = _airOutputSubmitDeadlineFailures.load(std::memory_order_relaxed);
    const uint64_t end = SPHostNow();
    return @{ @"enabled": @(_airCurrentStatsCalls != nullptr),
        @"sampleBeginHostTicks": @(begin), @"sampleEndHostTicks": @(end), @"threadID": @(threadID),
        @"presentationSlots": @{ @"output": @{ @"preparedTexture": prepared } },
        @"presentationFailuresLifetime": @{ @"output.display-submit-deadline": @(deadline) } };
}

- (int)inboundCount {
    std::lock_guard<std::mutex> lock(_inMx);
    return (int)_inbound.size();
}

- (NSDictionary *)copiedCadenceStats {
    std::lock_guard<std::mutex> lock(_inMx);
    double rate = _copiedGeneration == _sourceGeneration ?
        _copiedMeter.inputArrivalRate((int64_t)(CACurrentMediaTime()*1e9)) : -1;
    return @{ @"copyAcceptedCount": @(_copiedFrames), @"copyAcceptedHostRate": @(rate) };
}

// The capture callback only touches the gate under this mutex. Configuration
// is read on the processing queue, never from the callback thread.
- (sp::NativeCadenceSnapshot)nativeCadenceSnapshot {
    std::lock_guard<std::mutex> lock(_rawCadenceMutex);
    return _nativeCadence.query(SPHostToNs(SPHostNow()));
}

- (BOOL)nativeBudgetForSnapshot:(const sp::NativeCadenceSnapshot &)snapshot {
    return !_stopped && _request.interpolationEnabled && _request.rateKind == SPLiveRateMultiplier &&
        snapshot.active && snapshot.generation == _sourceGeneration &&
        snapshot.width == _sourceWidth && snapshot.height == _sourceHeight &&
        snapshot.captureLimit == _request.captureCapFPS && snapshot.refreshHz == _request.displayRefreshHz;
}

- (BOOL)rateBudgetEnabled {
    return !SPR7Passthrough() && _request.interpolationEnabled &&
        [_request.engineID isEqualToString:@"rife.metal"] &&
        _request.rateKind == SPLiveRateMultiplier && _request.multiplier >= 2 && _request.multiplier <= 4;
}

- (BOOL)usesFixedSourceReuse {
    return !_testExactFixedSchedule && _request.interpolationEnabled && _request.rateKind == SPLiveRateFixedFPS &&
        [_request.engineID isEqualToString:@"rife.metal"];
}

- (void)clearRateBudgetWindow {
    _rateBudgetWindow.clear();
    _rateBudgetDropPTS.clear();
}

- (void)resetRateBudgetOnQueue {
    [self cancelRateBudgetProbe];
    int requested = _request.rateKind == SPLiveRateMultiplier ? (int)_request.multiplier : 1;
    _rateBudget.reset(requested);
    _fixedRateBudget.reset();
    _fixedMaxBatchCount = 0;
    _effectiveMultiplier = _rateBudget.snapshot().effectiveMultiplier;
    _rateBudgetPassthrough = NO;
    _rifeBudgetRejectedPhases = 0;
    _rateBudgetSkippedPhases = 0;
    _fixedSourceReused = _fixedFallbackPresented = _fixedFallbackReplaced = 0;
    _rifeBusySinceHost = 0;
    _rateBudgetCompletedHosts.clear();
    _rateBudgetLastDecision = @{};
    _rateBudgetProbeJobs = 0;
    _rateBudgetProbeMedianMs = -1;
    [self clearRateBudgetWindow];
}

- (void)noteRateBudgetPlanned:(size_t)count {
    if (![self rateBudgetEnabled] || _rateBudgetPassthrough || _nativeBudgetActive || count == 0) return;
    _rateBudgetWindow.push_back({SPHostNow(), (uint64_t)count, 0});
}

- (void)noteRateBudgetDrop:(sp::SPRational)pts {
    if (![self rateBudgetEnabled] || _rateBudgetPassthrough || _nativeBudgetActive) return;
    for (const auto &seen : _rateBudgetDropPTS) if (sp::spCmp(seen, pts) == 0) return;
    _rateBudgetDropPTS.push_back(pts);
    if (_rateBudgetDropPTS.size() > 8192)
        _rateBudgetDropPTS.erase(_rateBudgetDropPTS.begin(), _rateBudgetDropPTS.begin() + 2048);
    _rateBudgetWindow.push_back({SPHostNow(), 0, 1});
}

- (double)rateBudgetMedianTaskMs {
    if (_frcNs.empty()) return 0;
    size_t count = MIN((size_t)16, _frcNs.size());
    std::vector<int64_t> recent(_frcNs.end() - count, _frcNs.end());
    std::sort(recent.begin(), recent.end());
    return (recent[(count - 1) / 2] / 2.0 + recent[count / 2] / 2.0) / 1e6;
}

- (uint64_t)rateBudgetFreshSampleCount {
    int64_t now = SPHostNow();
    while (!_rateBudgetCompletedHosts.empty() &&
           SPHostToNs(now - _rateBudgetCompletedHosts.front()) > 2000000000LL)
        _rateBudgetCompletedHosts.pop_front();
    return (uint64_t)_rateBudgetCompletedHosts.size();
}

- (void)releaseRateBudgetProbeJob:(SPLiveJob *)job {
    // A retained buffer and generation identify the original lease even if
    // a request reset has replaced the current held-frame map.
    if (job->generation == _sourceGeneration) {
        for (int side = 0; side < 2; ++side) {
            uint64_t identity = side == 0 ? job->frameA : job->frameB;
            CVPixelBufferRef source = side == 0 ? job->probeSourceA : job->probeSourceB;
            auto found = _held.find(identity);
            if (found != _held.end() && found->second.source == source && found->second.pins > 0)
                found->second.pins -= 1;
        }
    }
    if (job->probeSourceA) CVPixelBufferRelease(job->probeSourceA);
    if (job->probeSourceB) CVPixelBufferRelease(job->probeSourceB);
    delete job;
}

- (void)cancelRateBudgetProbe {
    ++_rateBudgetProbeRound;
    _rateBudgetProbeActive = NO;
    _rateBudgetProbeCollected = 0;
    _rateBudgetProbeLastFrameB = 0;
    _rateBudgetProbeNextHost = 0;
    _rateBudgetProbeTaskCosts.clear();
    _rateBudgetProbePhaseCosts.clear();
    while (!_rateBudgetProbePending.empty()) {
        SPLiveJob *job = _rateBudgetProbePending.front();
        _rateBudgetProbePending.pop_front();
        [self releaseRateBudgetProbeJob:job];
    }
    // The submitted job owns its slot and leases until its own callback.
    // Do not clear _rateBudgetProbeInFlightToken here.
}

- (BOOL)rateBudgetProbeEligible {
    double fps = _fpsMeter.inputRate((int64_t)(CACurrentMediaTime() * 1e9));
    return [self rateBudgetEnabled] && _rateBudgetPassthrough && _effectiveMultiplier == 1 &&
        _rateBudget.snapshot().effectiveMultiplier == 1 &&
        _rateBudget.snapshot().limit == sp::RateBudgetLimit::Compute && _rife && _sessionReady && !_stopped &&
        !_nativeBudgetActive && ![self nativeBudgetForSnapshot:[self nativeCadenceSnapshot]] &&
        std::isfinite(fps) && fps > 0;
}

- (void)finishRateBudgetProbe:(SPLiveJob *)job outputs:(NSArray<SPOwnedPixelBuffer *> *)outputs
                     latency:(double)latency error:(NSError *)error {
    BOOL ownsSlot = job->diagnosticID == _rateBudgetProbeInFlightToken;
    if (ownsSlot) {
        _rateBudgetProbeInFlightToken = 0;
        if (job->inflightEpoch == _inflightEpoch && _inflight > 0) {
            --_inflight;
            _rifeBusySinceHost = _inflight > 0 ? SPHostNow() : 0;
        }
    }
    BOOL current = ownsSlot && _rateBudgetProbeActive && job->probeRound == _rateBudgetProbeRound &&
        job->generation == _sourceGeneration && job->configVersion == _configVersion &&
        job->clockEpoch == _clockEpoch && job->measurementEpoch == _measurementEpoch &&
        [self rateBudgetProbeEligible];
    if (current) {
        if (error || outputs.count != (NSUInteger)job->count || !std::isfinite(latency) || latency <= 0) {
            [self cancelRateBudgetProbe];
        } else {
            if (job->probeIndex > 0) {
                _rateBudgetProbeTaskCosts.push_back(latency * 1000.0);
                _rateBudgetProbePhaseCosts.push_back(latency * 1000.0 / job->count);
            }
            if (job->probeIndex == 3) {
                if (_rateBudgetProbeTaskCosts.size() == 3 && _rateBudgetProbePhaseCosts.size() == 3) {
                    auto tasks = _rateBudgetProbeTaskCosts, phases = _rateBudgetProbePhaseCosts;
                    std::sort(tasks.begin(), tasks.end());
                    std::sort(phases.begin(), phases.end());
                    if (_rateBudget.recordProbePhaseCost(phases[1]))
                        _rateBudgetProbeMedianMs = tasks[1];
                }
                _rateBudgetProbeActive = NO;
            }
        }
    } else if (_rateBudgetProbeActive && job->probeRound == _rateBudgetProbeRound) {
        [self cancelRateBudgetProbe];
    }
    [self releaseRateBudgetProbeJob:job];
    // Output owners leave this callback without entering playback, drop
    // accounting, or ordinary submission/synthetic counters.
    [self submitNextRateBudgetProbe];
    [self trimHeld];
}

- (void)submitNextRateBudgetProbe {
    if (!_rateBudgetProbeActive || _rateBudgetProbeInFlightToken || _inflight > 0 ||
        _rateBudgetProbePending.empty()) return;
    if (![self rateBudgetProbeEligible]) { [self cancelRateBudgetProbe]; return; }
    SPLiveJob *job = _rateBudgetProbePending.front();
    _rateBudgetProbePending.pop_front();
    if (job->probeRound != _rateBudgetProbeRound || job->generation != _sourceGeneration ||
        job->configVersion != _configVersion || job->clockEpoch != _clockEpoch ||
        job->measurementEpoch != _measurementEpoch) {
        [self releaseRateBudgetProbeJob:job]; [self cancelRateBudgetProbe]; return;
    }
    NSMutableArray<NSNumber *> *phases = [NSMutableArray array];
    for (int i = 0; i < job->count; ++i) {
        float value = 0;
        if (!sp::spPhaseFitsFloat(job->phase[i], value)) {
            [self releaseRateBudgetProbeJob:job]; [self cancelRateBudgetProbe]; return;
        }
        [phases addObject:@(value)];
    }
    job->inflightEpoch = _inflightEpoch;
    _rateBudgetProbeInFlightEpoch = _inflightEpoch;
    _rateBudgetProbeInFlightToken = job->diagnosticID;
    ++_inflight;
    _rifeBusySinceHost = SPHostNow();
    SPLiveProcessor *selfRef = self;
#if ODF_AIR_PRESENTATION_GUARD_DIAGNOSTIC
    if (_rife.serviceTraceEnabled) [_rife setServiceTraceToken:job->diagnosticID configVersion:job->configVersion
        measurementEpoch:job->measurementEpoch probe:YES probeIndex:job->probeIndex probeRound:job->probeRound];
#endif
    BOOL submitted = [_rife submitLivePrevious:job->probeSourceA current:job->probeSourceB
        previousID:job->frameA currentID:job->frameB
        previousPTS:job->probePreviousPTS currentPTS:job->probeCurrentPTS
        generation:job->generation clockEpoch:job->clockEpoch timesteps:phases token:job->diagnosticID
        completion:^(uint64_t token, NSArray<SPOwnedPixelBuffer *> *outputs, double latency, NSError *error) {
            NSArray<SPOwnedPixelBuffer *> *kept = [outputs copy] ?: @[];
            dispatch_async(selfRef->_q, ^{
                @autoreleasepool { [selfRef finishRateBudgetProbe:job outputs:kept latency:latency error:error]; }
            });
        }];
    if (submitted) {
        ++_rateBudgetProbeJobs;
    } else {
        _rateBudgetProbeInFlightToken = 0;
        --_inflight;
        _rifeBusySinceHost = 0;
        [self releaseRateBudgetProbeJob:job];
        [self cancelRateBudgetProbe];
    }
}

- (BOOL)collectRateBudgetProbeGroup:(const std::vector<sp::SPScheduleOutput> &)group
                         generation:(uint64_t)generation {
    if (![self rateBudgetProbeEligible] || generation != _sourceGeneration || group.empty() || group.size() > 3)
        return NO;
    int64_t now = SPHostNow();
    if (!_rateBudgetProbeNextHost)
        _rateBudgetProbeNextHost = now + SPRationalToHost(sp::spMake(10, 1));
    if (!_rateBudgetProbeActive) {
        if (now < _rateBudgetProbeNextHost || _rateBudgetProbeInFlightToken || _inflight > 0) return NO;
        ++_rateBudgetProbeRound;
        _rateBudgetProbeActive = YES;
        _rateBudgetProbeCollected = 0;
        _rateBudgetProbeLastFrameB = 0;
        _rateBudgetProbeTaskCosts.clear();
        _rateBudgetProbePhaseCosts.clear();
        _rateBudgetProbeNextHost = now + SPRationalToHost(sp::spMake(10, 1));
        [_rife resetLiveCacheForRateBudgetProbe];
    }
    if (_rateBudgetProbeCollected >= 4) return NO;
    auto a = _held.find(group.front().frameA), b = _held.find(group.front().frameB);
    if (a == _held.end() || b == _held.end() || !a->second.source || !b->second.source ||
        a->second.pts.den <= 0 || a->second.pts.den > INT32_MAX ||
        b->second.pts.den <= 0 || b->second.pts.den > INT32_MAX ||
        (_rateBudgetProbeCollected > 0 && group.front().frameA != _rateBudgetProbeLastFrameB)) {
        [self cancelRateBudgetProbe];
        return NO;
    }
    SPLiveJob *job = new SPLiveJob();
    job->diagnosticID = SPR8NextJobID.fetch_add(1);
    job->generation = generation; job->configVersion = _configVersion;
    job->clockEpoch = _clockEpoch; job->measurementEpoch = _measurementEpoch;
    job->probeRound = _rateBudgetProbeRound; job->probeIndex = _rateBudgetProbeCollected++;
    job->frameA = group.front().frameA; job->frameB = group.front().frameB;
    job->count = (int)group.size();
    for (int i = 0; i < job->count; ++i) job->phase[i] = group[(size_t)i].phase;
    job->probeSourceA = CVPixelBufferRetain(a->second.source);
    job->probeSourceB = CVPixelBufferRetain(b->second.source);
    job->probePreviousPTS = CMTimeMake(a->second.pts.num, (int32_t)a->second.pts.den);
    job->probeCurrentPTS = CMTimeMake(b->second.pts.num, (int32_t)b->second.pts.den);
    ++a->second.pins; ++b->second.pins;
    _rateBudgetProbeLastFrameB = job->frameB;
    _rateBudgetProbePending.push_back(job);
    [self submitNextRateBudgetProbe];
    return YES;
}

- (void)suspendRateBudgetOnQueue {
    SPAirBudgetEvent trace{};
    if (_airCadenceBudget) {
        trace.hostTicks = SPHostNow(); trace.suspend = true; trace.generation = _sourceGeneration; trace.configBefore = _configVersion; trace.epochBefore = _measurementEpoch;
        trace.appliedBefore = _effectiveMultiplier; trace.budgetBefore = _rateBudget.snapshot().effectiveMultiplier;
        trace.phaseCostBeforeMs = _rateBudget.snapshot().phaseCostMs; trace.inflight = _inflight; trace.probeToken = _rateBudgetProbeInFlightToken;
        trace.requested = (int)_request.multiplier;
    }
    [self cancelRateBudgetProbe];
    _rateBudgetCompletedHosts.clear();
    if (![self rateBudgetEnabled]) {
        if (_airCadenceBudget) { trace.gateMask = 1; trace.appliedAfter = _effectiveMultiplier; const auto after = _rateBudget.snapshot(); trace.budgetAfter = after.effectiveMultiplier; trace.phaseCostAfterMs = after.phaseCostMs; trace.displayCap = after.displayCap; trace.limit = after.limit; trace.configAfter = _configVersion; trace.epochAfter = _measurementEpoch; _airCadenceBudget->append(trace); }
        return;
    }
    const double policyNow = CACurrentMediaTime();
    (void)_rateBudget.update({policyNow, 0, (int)_request.multiplier, 0, 0, 0});
    [self clearRateBudgetWindow];
    if (_airCadenceBudget) {
        trace.policyCalled = trace.inputAvailable = true; trace.policyMediaTimeSeconds = policyNow; trace.requested = (int)_request.multiplier;
        trace.appliedAfter = _effectiveMultiplier; const auto after = _rateBudget.snapshot(); trace.budgetAfter = after.effectiveMultiplier; trace.phaseCostAfterMs = after.phaseCostMs; trace.displayCap = after.displayCap; trace.limit = after.limit;
        trace.configAfter = _configVersion; trace.epochAfter = _measurementEpoch; _airCadenceBudget->append(trace);
    }
}

- (void)updateRateBudgetOnQueue {
    SPAirBudgetEvent trace{};
    if (_airCadenceBudget) {
        trace.hostTicks = SPHostNow(); trace.generation = _sourceGeneration; trace.configBefore = _configVersion; trace.epochBefore = _measurementEpoch;
        trace.appliedBefore = _effectiveMultiplier; trace.budgetBefore = _rateBudget.snapshot().effectiveMultiplier; trace.phaseCostBeforeMs = _rateBudget.snapshot().phaseCostMs;
        trace.inflight = _inflight; trace.probeToken = _rateBudgetProbeInFlightToken; trace.requested = (int)_request.multiplier;
        for (int64_t completed : _rateBudgetCompletedHosts) if (SPHostToNs(trace.hostTicks - completed) <= 2000000000LL) ++trace.freshSamples;
    }
    auto finishTrace = [&](uint32_t gates) {
        if (!_airCadenceBudget) return;
        trace.gateMask |= gates; trace.appliedAfter = _effectiveMultiplier; trace.configAfter = _configVersion; trace.epochAfter = _measurementEpoch;
        const auto after = _rateBudget.snapshot(); trace.budgetAfter = after.effectiveMultiplier; trace.phaseCostAfterMs = after.phaseCostMs; trace.displayCap = after.displayCap; trace.limit = after.limit;
        _airCadenceBudget->append(trace);
    };
    const BOOL budgetEnabled = [self rateBudgetEnabled];
    if (!budgetEnabled || !_rife || !_sessionReady || _stopped) {
        [self cancelRateBudgetProbe];
        finishTrace((!budgetEnabled ? 1 : 0) | (!_rife ? 2 : 0) | (!_sessionReady ? 4 : 0) | (_stopped ? 8 : 0));
        return;
    }
    if ([self nativeBudgetForSnapshot:[self nativeCadenceSnapshot]]) {
        if (_airCadenceBudget) trace.nativeSuspended = true;
        // Native bypass still suspends compute evidence, but the display cap
        // must observe continuous content cadence across native-gate changes.
        [self cancelRateBudgetProbe];
        _rateBudgetCompletedHosts.clear();
        [self clearRateBudgetWindow];
    }
    int64_t now = SPHostNow();
    // A one-second rolling phase window feeds the independent 2/3-second
    // persistence rules. Retried phases are counted only once by their PTS.
    while (!_rateBudgetWindow.empty() && SPHostToNs(now - _rateBudgetWindow.front().host) > 1000000000LL)
        _rateBudgetWindow.pop_front();
    uint64_t planned = 0, dropped = 0;
    for (const auto &sample : _rateBudgetWindow) { planned += sample.planned; dropped += sample.dropped; }
    double median = [self rateBudgetMedianTaskMs];
    double fps = _fpsMeter.inputRate((int64_t)(CACurrentMediaTime() * 1e9));
    uint64_t fresh = [self rateBudgetFreshSampleCount];
    if (_airCadenceBudget) { trace.inputAvailable = true; trace.contentFPS = fps; trace.medianTaskMs = median; trace.planned = planned; trace.dropped = dropped; trace.freshSamples = fresh; trace.refreshHz = _request.displayRefreshHz; }
    if (!std::isfinite(fps) || fps <= 0) [self cancelRateBudgetProbe];
    auto budget = _rateBudget.snapshot();
    if (budget.effectiveMultiplier == _effectiveMultiplier) {
        const double policyNow = CACurrentMediaTime();
        budget = _rateBudget.update({policyNow, fps, (int)_request.multiplier,
                                    median, planned, dropped, fresh, _request.displayRefreshHz});
        if (_airCadenceBudget) { trace.policyCalled = true; trace.policyMediaTimeSeconds = policyNow; }
        if (budget.effectiveMultiplier != _effectiveMultiplier) {
            _rateBudgetLastDecision = @{ @"host": @(now), @"from": @(_effectiveMultiplier),
                @"to": @(budget.effectiveMultiplier), @"medianMs": @(median),
                @"planned": @(planned), @"dropped": @(dropped), @"freshSamples": @(fresh),
                @"contentFPS": @(fps), @"phaseCostMs": @(budget.phaseCostMs),
                @"refreshHz": @(_request.displayRefreshHz), @"displayCap": @(budget.displayCap),
                @"limit": [NSString stringWithUTF8String:sp::rateBudgetLimitName(budget.limit)] };
        }
    }
    if (budget.limit != sp::RateBudgetLimit::Compute && _rateBudgetProbeActive)
        [self cancelRateBudgetProbe];
    if (budget.effectiveMultiplier == _effectiveMultiplier) { finishTrace((fresh < 8 ? 64 : 0) | 128); return; }
    // Reuse the loaded engine. Let its bounded serial queue drain before
    // changing ownership epochs; admission rejects new jobs during this gap.
    if (_inflight > 0 || _rateBudgetProbeInFlightToken) { finishTrace((_inflight > 0 ? 16 : 0) | (_rateBudgetProbeInFlightToken ? 32 : 0)); return; }
    int previous = _effectiveMultiplier;
    _effectiveMultiplier = budget.effectiveMultiplier;
    _rateBudgetPassthrough = _effectiveMultiplier == 1;
    [self.outputPreview invalidateSharedGeometry];
    _configVersion += 1;
    _inflightEpoch = _configVersion;
    _rifeBusySinceHost = 0;
    [self clearPendingRife];
    [self clearPlaySlots];
    _pending.clear();
    _marks.clear();
    _havePair = NO;
    [self clearRateBudgetWindow];
    [self resetSchedulerOnQueue];
    [self refreshResolvedOnQueue];
    // Clears service samples so X3 task costs cannot be interpreted as X2.
    // Keep the budget's remembered phase cost, counters, and retry cooldown.
    [self beginMeasurementEpoch];
    _rateBudget.markRateApplied(CACurrentMediaTime());
    if (_rateBudgetPassthrough && budget.limit == sp::RateBudgetLimit::Compute)
        _rateBudgetProbeNextHost = SPHostNow() + SPRationalToHost(sp::spMake(10, 1));
    [self recordR7JobEvent:@"rateBudgetChanged" detail:@{
        @"requested": @(_request.multiplier), @"previous": @(previous), @"effective": @(_effectiveMultiplier),
        @"config": @(_configVersion), @"medianTaskMs": @(median),
        @"plannedPhases": @(planned), @"droppedPhases": @(dropped) }];
    finishTrace(0);
}

- (void)applyObservedCaptureEnvironment {
    auto snapshot=[self nativeCadenceSnapshot];
    if (snapshot.configured) {
        _request.captureCapFPS=snapshot.captureLimit;
        _request.displayRefreshHz=snapshot.refreshHz;
    }
}

- (void)recordR7JobEvent:(NSString *)kind detail:(NSDictionary *)detail {
    if (!_pixelDiagnosticsEnabled) return;
    if (!_r7JobTimeline) _r7JobTimeline = [NSMutableArray array];
    NSMutableDictionary *event = [detail mutableCopy];
    event[@"kind"] = kind;
    event[@"host"] = @(SPHostNow());
    [_r7JobTimeline addObject:event];
    NSUInteger limit = SPR8Enabled() ? 256 : 64;
    if (_r7JobTimeline.count > limit) [_r7JobTimeline removeObjectAtIndex:0];
}

- (double)r7OldestJobAgeMs {
    int64_t oldest = 0;
    for (const auto &entry : _r7JobHosts) {
        if (entry.second.second == _configVersion && (!oldest || entry.second.first < oldest)) oldest = entry.second.first;
    }
    return oldest ? (double)SPHostToNs(SPHostNow() - oldest) / 1e6 : -1;
}

- (NSDictionary *)pixelDiagnosticsSnapshot {
    if (!_pixelDiagnosticsEnabled) return @{ @"enabled": @NO };
    return @{ @"enabled": @YES, @"intervalMs": @1000,
        @"scope": @"sampled owned input and pre-draw output buffers matched by source-frame geometryHost, then output present callback and visibility snapshot at submission; no screen pixels; equal hashes do not prove identical frames",
        @"inputAttempts": @(_pixelInputAttempts), @"inputExpired": @(_pixelInputExpired),
        @"outputMatched": @(_pixelOutputMatched), @"outputUnmatchedCallback": @(_pixelOutputUnmatchedCallback),
        @"outputPresentedCount": @(_pixelOutputPresentedCount),
        @"lastInput": _pixelLastInput ?: @{}, @"lastOutputSubmitted": _pixelLastOutputSubmitted ?: @{},
        @"pendingOutput": _pixelPendingOutput ?: @{}, @"lastOutputCallback": _pixelLastOutputCallback ?: @{},
        @"lastOutputPresented": _pixelLastOutputPresented ?: @{} };
}

- (NSDictionary *)currentStats {
    uint64_t statsBegin = 0, statsThread = 0;
    if (_airCurrentStatsCalls) {
        statsBegin = SPHostNow();
        pthread_threadid_np(nullptr, &statsThread);
    }
    NSDictionary *windowOptimization = [self airWindowOptimizationSnapshot];
#if ODF_AIR_BETA_DIAGNOSTIC
    NSDictionary *airBeta = SPAirBetaEnabled() ? [self airBetaSnapshot] : @{};
    NSDictionary *measurementReadiness = [self airBetaMeasurementReadiness];
#endif
    const double p95 = SPStatsPercentileMs(_latencyNs);
    NSMutableArray *epochHistogram = [NSMutableArray arrayWithCapacity:201];
    for (int i = 0; i < 201; ++i) [epochHistogram addObject:@(_epochHist[i])];
    double seconds = (double)SPHostToNs(SPHostNow() - _windowStart) / 1e9;
    if (seconds < 0.25) seconds = 0.25;
    double inputFPS = _fpsMeter.inputRate((int64_t)(CACurrentMediaTime() * 1e9));
    auto raw = [self nativeCadenceSnapshot];
    _nativeBudgetActive = [self nativeBudgetForSnapshot:raw];
    if (!_nativeBudgetActive) _nativeBGRADirectActive = NO;
    NSDictionary *copiedCadence = [self copiedCadenceStats];
    NSDictionary *rifeDiagnostics = _rife ? [_rife streamDiagnostics] : @{};
    int processingWidth = _resolved.interpolationActive ? (_lowLatency ? _lowLatency.width : _width) : 0;
    int processingHeight = _resolved.interpolationActive ? (_lowLatency ? _lowLatency.height : _height) : 0;
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
    if (_resolved.interpolationActive && _rife.rifePrescaleEnabled) {
        processingWidth = _rife.processingWidth; processingHeight = _rife.processingHeight;
    }
#endif
    double requestedFPS = -1;
    if (_resolved.committed && _resolved.interpolationActive && _request.interpolationEnabled && _request.rateKind == SPLiveRateFixedFPS && _request.fpsDenominator > 0)
        requestedFPS = (double)_request.fpsNumerator / (double)_request.fpsDenominator;
    else if (_resolved.committed && _resolved.interpolationActive && _request.interpolationEnabled && _request.rateKind == SPLiveRateMultiplier && inputFPS > 0)
        requestedFPS = inputFPS * _request.multiplier;
    NSDictionary *result = @{
        @"airWindowOptimization": windowOptimization,
        @"pumpedInputSequence": @(_processedSequence),
        @"capturePressureEvents": @(_capturePressureEvents),
        @"lastProcessedHost": @(_lastProcessedHost),
        @"lastDrawablePresentedHost": @(_lastDrawablePresentedHost),
        @"freshnessNote": @"Host ticks; presentation is a drawable callback, not proof of changing content or delivered input.",
        @"pixelDiagnostics": [self pixelDiagnosticsSnapshot],
        @"captured": @(_captured),
        @"idle": @(_idle),
        @"complete": @(_completeFrames),
        @"interrupted": @(_interrupted),
        @"syntheticOK": @(_syntheticOK),
        @"syntheticFail": @(_syntheticFail),
        @"scheduledSynthetic": @(_scheduledSynthetic),
        @"rateRequestedMultiplier": @(_request.rateKind == SPLiveRateMultiplier ? _request.multiplier : 0),
        @"rateEffectiveMultiplier": @(_request.rateKind == SPLiveRateMultiplier ? ([self rateBudgetEnabled] ? _effectiveMultiplier : _request.multiplier) : 0),
        @"rateBudgetPassthrough": @(_rateBudgetPassthrough),
        @"fixedSourceReuse": @([self usesFixedSourceReuse]),
        @"fixedSourceReused": @(_fixedSourceReused),
        @"fixedFallbackPresented": @(_fixedFallbackPresented),
        @"fixedFallbackReplaced": @(_fixedFallbackReplaced),
        @"rateBudgetLimit": [NSString stringWithUTF8String:sp::rateBudgetLimitName(_rateBudget.snapshot().limit)],
        @"rateBudgetDisplayCap": @(_rateBudget.snapshot().displayCap),
        @"rateBudgetDisplayCapChanges": @(_rateBudget.snapshot().displayCapChanges),
        @"rateBudgetRejectedPhases": @(_rifeBudgetRejectedPhases),
        @"rifeBudgetRejectedPhases": @(_rifeBudgetRejectedPhases),
        @"rateBudgetSkippedPhases": @(_rateBudgetSkippedPhases),
        @"rateBudgetDowngrades": @(_rateBudget.snapshot().downgrades),
        @"rateBudgetUpgrades": @(_rateBudget.snapshot().upgrades),
        @"rateBudgetPhaseCostMs": @(_rateBudget.snapshot().phaseCostMs),
        @"rateBudgetLastDecision": _rateBudgetLastDecision ?: @{},
        @"rateBudgetFreshSamples": @([self rateBudgetFreshSampleCount]),
        @"rateBudgetProbeJobs": @(_rateBudgetProbeJobs),
        @"rateBudgetProbeMedianMs": @(_rateBudgetProbeMedianMs),
        @"rifeRecentJobs": rifeDiagnostics[@"rifeRecentJobs"] ?: @[],
#if ODF_AIR_BETA_DIAGNOSTIC
        @"airBeta": airBeta,
        @"airBetaMeasurementReadiness": measurementReadiness,
        @"airWindowOptimizationReadiness": measurementReadiness,
#endif
#if ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC
        @"airFusedRifePresenter": [self.outputPreview fusedRifePresentationSnapshotIncludeRecords:NO cutoffHostTicks:SPHostNow()] ?: @{},
#endif
        @"processThermalState": @([NSProcessInfo processInfo].thermalState),
        @"processLowPowerMode": @([NSProcessInfo processInfo].lowPowerModeEnabled),
        @"nativeBudgetSkippedPhases": @(_nativeBudgetSkippedPhases),
        @"nativeBudgetActive": @(_nativeBudgetActive),
        @"nativeBGRADirectActive": @(_nativeBGRADirectActive), @"nativeBGRADirectFrames": @(_nativeBGRADirectFrames),
        @"nativeCadenceReason": [NSString stringWithUTF8String:raw.reason],
        @"nativeCadenceAgeMs": @(raw.ageNs < 0 ? -1 : (double)raw.ageNs / 1e6),
        @"nativeCadenceSamples": @(raw.samples), @"nativeCadenceEntries": @(raw.entries), @"nativeCadenceExits": @(raw.exits),
        @"nativeCadenceDisplayID": @(raw.displayID), @"nativeCadenceCaptureLimit": @(raw.captureLimit),
        @"rawCallbackCount": @(raw.callbacks), @"rawCallbackPTSRate": @(raw.ptsFPS), @"rawCallbackHostRate": @(raw.hostFPS),
        @"copyAcceptedCount": copiedCadence[@"copyAcceptedCount"], @"copyAcceptedHostRate": copiedCadence[@"copyAcceptedHostRate"],
        @"pumpedCaptureHostRate": @(_pumpedCaptureMeter.inputArrivalRate((int64_t)(CACurrentMediaTime()*1e9))),
        @"pumpArrivalRate": @(_fpsMeter.inputArrivalRate((int64_t)(CACurrentMediaTime()*1e9))),
        @"staticHoldPhases": @(_staticHoldPhases), @"epochStaticHoldPhases": @(_epochStaticHoldPhases),
        @"submitted": @(_submitted),
        @"r9BudgetLimited": @(_r9FRCBudgetGate.limited()),
        @"r9RequiredBudgetMs": @(_r9RequiredBudgetMs), @"r9AllowedBudgetMs": @(_r9AllowedBudgetMs),
        @"r9BudgetRejectedPhases": @(_r9BudgetRejectedPhases), @"r9BudgetProbeJobs": @(_r9BudgetProbeJobs),
        @"r9BackendFullPhases": @(_r9BackendFullPhases),
        @"r9BackendBusy": @(_engine ? _engine.busyCount : 0), @"r9BackendSessions": @(_engine ? _engine.sessionCount : 0),
        @"r9GeneratedFPS": @(_r9GeneratedFPS), @"r9OnTimeSyntheticFPS": @(_r9OnTimeSyntheticFPS),
        @"r9OnTimePhysicalSynthetic": @(_r9OnTimeSynthetic), @"r9LatePhysicalSynthetic": @(_r9LatePhysicalSynthetic),
        @"r9TimingUnknownSynthetic": @(_r9TimingUnknownSynthetic),
        @"r9OnTimeDefinition": @"visible, scored non-held synthetic drawable, presentedTime no later than frozen target plus 2ms; callback-order estimate, not subjective visual proof",
        @"r7JobsTracked": @(_r7JobHosts.size()),
        @"r7JobsUntracked": @(_r7JobUntracked),
        @"r7JobsCompleted": @(_r7JobCompleted),
        @"r7OldestJobAgeMs": @([self r7OldestJobAgeMs]),
        @"r7LastJobSubmitted": _r7LastJobSubmitted ?: @{},
        @"r7LastJobCompleted": _r7LastJobCompleted ?: @{},
        @"r7JobTimeline": [_r7JobTimeline copy] ?: @[],
        @"r8OutputTimeline": [_r8OutputTimeline copy] ?: @[],
        @"presentedSource": @(_presentedSource),
        @"presentedSynthetic": @(_presentedSynthetic),
        @"presented": @(_presentedSource + _presentedSynthetic),
        @"presentationEndpoint": _scoreOutput ? @"output" : @"preview",
        @"rateKind": _request.rateKind == SPLiveRateMultiplier ? @"multiplier" : @"fixedFPS",
        @"rateMultiplier": @(_request.multiplier),
        @"fixedFPSNumerator": @(_request.fpsNumerator),
        @"fixedFPSDenominator": @(_request.fpsDenominator),
        @"estimatedRequestedFPS": @(requestedFPS),
        @"requestedFPSIsEstimated": @(_request.rateKind == SPLiveRateMultiplier),
        @"captureCapFPS": @(_request.captureCapFPS),
        @"displayRefreshHz": @(_request.displayRefreshHz),
        @"presentationPolicy": [self requestUsesLatestPresentation:_request] ? @"latest-bounded" : @"deadline",
        @"viewMode": _request.viewMode == SPLiveViewOriginal ? @"original" : (_request.viewMode == SPLiveViewCompare ? @"compare" : @"enhanced"),
        @"outputWarmMode": @(_outputWarmMode),
        @"outputWarmEnhancedSize": @[@(_outputWarmEnhancedWidth), @(_outputWarmEnhancedHeight)],
        @"outputWarmOriginalSize": @[@(_outputWarmOriginalWidth), @(_outputWarmOriginalHeight)],
        @"rifePendingPairs": @(_rifePending.empty() ? 0 : 1),
        @"rifeDeferredPairs": @(_haveRifeDeferred ? 1 : 0), @"rifeDeferredAccepted": @(_rifeDeferredAccepted),
        @"rifeDeferredExpired": @(_rifeDeferredExpired), @"rifeDeferredStale": @(_rifeDeferredStale), @"rifeDeferredCapacityDrops": @(_rifeDeferredCapacityDrops),
        @"rifePoolPressureEvents": @(_rifePoolPressureEvents), @"rifePoolRetryAdmissions": @(_rifePoolRetryAdmissions),
        @"rifePoolUnexpiredDrops": @(_rifePoolUnexpiredDrops),
        @"rifeSlowMode": @(_rifeSlowMode),
        @"lowPrescaleSlowMode": @(_lowPrescaleSlowMode),
        @"outputWarmToken": @(_outputSurfaceToken),
        @"outputWarmGPUCompleted": @(_outputWarmGPUCompleted),
        @"outputWarmGPUFailed": @(_outputWarmGPUFailed),
        @"outputWarmRejected": @(_outputWarmRejected),
        @"outputPresentedZeroTime": @(_outputPresentedZeroTime),
        @"outputPresentedValidTime": @(_outputPresentedValidTime),
        @"epochPhysicalSource": @(_epochPhysicalSource),
        @"epochPhysicalSynthetic": @(_epochPhysicalSynthetic),
        @"deadlineDrops": @(_deadlineDrops),
        @"lateReadyDrops": @(_lateReadyDrops), @"staleReadyDrops": @(_staleReadyDrops),
        @"dueMergeDrops": @(_dueMergeDrops), @"pendingExpiredDrops": @(_pendingExpiredDrops),
        @"slotEvictionDrops": @(_slotEvictionDrops), @"captureToModelReadyP95ms": @(SPStatsPercentileMs(_captureToModelReadyNs)),
        @"captureToOutputReadyP95ms": @(SPStatsPercentileMs(_captureToOutputReadyNs)),
        @"sceneSkips": @(_sceneSkips),
        @"queueDrops": @(_queueDrops),
        @"sourceMissingDrops": @(_sourceMissingDrops), @"sourceConversionDrops": @(_sourceConversionDrops),
        @"sourcePolicyDrops": @(_sourcePolicyDrops), @"sourceStaleDrops": @(_sourceStaleDrops),
        @"sourceDueMergeDrops": @(_sourceDueMergeDrops), @"sourceSlotEvictionDrops": @(_sourceSlotEvictionDrops),
        @"engineUnavailableDropsLifetime": @(_engineUnavailableDrops), @"inflightLimitDropsLifetime": @(_inflightLimitDrops),
        @"rifePoolPressureDropsLifetime": @(_rifePoolPressureDrops),
        @"engineSubmissionRejectedDropsLifetime": @(_engineSubmissionRejectedDrops),
        @"stoppedDrops": @(_stoppedDrops),
        @"generationDrops": @(_generationDrops),
        @"clockRetiredJobsLifetime": @(_clockRetiredJobs), @"clockRetiredModelOutputsLifetime": @(_clockRetiredModelOutputs),
        @"clockRetiredPhaseDropsLifetime": @(_clockRetiredPhaseDrops),
        @"renderDrops": @(_renderDrops),
        @"renderDropsScope": @"synchronous scored rejections since last probe reset",
        @"presentationFailuresLifetime": [_presentationFailuresLifetime copy],
        @"presentationFailuresEpoch": [_presentationFailuresEpoch copy],
        @"firstPresentationFailureLifetime": [_firstPresentationFailureLifetime copy],
        @"firstPresentationFailureEpoch": [_firstPresentationFailureEpoch copy],
        @"epochPhysicalCountsMethod": @"callback-order filtered estimate; see presentationOrder for presented-time order",
        @"stopped": @(_stopped),
        @"sourceGeneration": @(_sourceGeneration),
        @"measurementEpoch": @(_measurementEpoch),
        @"clockEpoch": @(_clockEpoch),
        @"epochSamples": @(_epochSamples),
        @"epochP95ms": @(p95),
        @"epochMonotonic": @(_epochMonotonic),
        @"epochCallbackMonotonic": @(_epochMonotonic),
        @"ignoredPresentedCallbacksLifetime": [_ignoredPresentedCallbacks copy],
        @"presentationOrder": [self presentationOrderSummary],
        @"sizeChain": [self sizeChainSnapshot],
        @"surfaceGeometryAssessment": _surfaceGeometryAssessment ?: @"uncalibrated-no-presentation",
        @"surfaceCropEndpoint": _surfaceCropEndpoint ?: @"none",
        @"epochDuplicates": @(_epochDuplicates),
        @"presentedWidth": @(_epochWidth),
        @"presentedHeight": @(_epochHeight),
        @"presentedSizeChanges": @(_epochSizeChanges),
        @"epochScheduled": @(_epochScheduled),
        @"epochPresentedSynthetic": @(_epochPresentedSynthetic),
        @"epochPresentedSource": @(_epochPresentedSource),
        @"epochDeadline": @(_epochDeadline),
        @"epochQueueDrops": @(_epochQueueDrops),
        @"phaseBatchSplits": @(_phaseBatchSplits),
        @"copyEntryP95ms": @(SPStatsPercentileMs(_copyEntryNs)),
        @"latencyHistogramMs": epochHistogram,
        @"presentedCallbacks": @(_presentedCallbacks),
        @"inflight": @(_inflight),
        @"playoutSlots": @((int)_slots.size()),
        @"peakSlots": @(_peakSlots),
        @"slotCap": @([self slotCap]),
        @"heldFrames": @((int)_held.size()),
        @"queued": @([self inboundCount]),
        @"p95ms": @(p95),
        @"delayMs": @((double)SPHostToNs(_delayHost) / 1e6),
        @"delayAlignmentRequested": @(_airDelayAlignmentRequested),
        @"delayAlignmentActiveX2": @(_airDelayAlignmentActiveX2),
        @"delayAlignmentPresentationLeadNs": @(_airDelayAlignmentLeadNs),
        @"delayAlignmentRenderMarginNs": @(_airDelayAlignmentMarginNs),
        @"airRobustSourceLead": @{ @"schema": @"odf-air-source-lead-max-p95-v1", @"policy": @"max-old-lead-type7-p95-half", @"quantileType": @7,
            @"requested": @(_airRobustSourceLeadRequested),
            @"applied": @(_airRobustSourceLeadApplied), @"maximumHistoryCount": @32,
            @"bootstrap": @(_airRobustSourceLeadApplied && _airSourceLeadEvaluation.historyCount == 0),
            @"historyCount": @(_airSourceLeadEvaluation.historyCount), @"observedIntervals": @(_airSourceLeadEvaluation.observedIntervals),
            @"oldLeadNs": @((int64_t)llround(_airSourceLeadEvaluation.oldLeadSeconds * 1e9)),
            @"actualLeadNs": @((int64_t)llround(_airSourceLeadEvaluation.leadSeconds * 1e9)),
            @"positiveIntervalP95Ns": _airRobustSourceLeadApplied && _airSourceLeadEvaluation.historyCount
                ? @((int64_t)llround(_airSourceLeadEvaluation.p95IntervalSeconds * 1e9)) : (id)NSNull.null },
        @"delayClamped": @(_delayClamped),
        @"delayTimeClamped": @(_delayTimeClamped), @"delayByteClamped": @(_delayByteClamped),
        @"interactiveCapMs": @(_request.quality == SPFRCQualityHigh ? SPQualityCapSec * 1000.0 : SPInteractiveCapSec * 1000.0),
        @"interactiveTier": _request.quality == SPFRCQualityHigh ? @"quality" : @"normal",
        @"frcP95ms": @(SPStatsPercentileMs(_frcNs)),
        @"scaleP95ms": @(SPStatsPercentileMs(_scaleNs)),
        @"airSourceConversion": [self airSourceConversionSnapshot],
        @"transferP95ms": @(SPStatsPercentileMs(_transferNs)),
        @"queueP95ms": @(SPStatsPercentileMs(_queueNs)),
        @"playheadP95ms": @(SPStatsPercentileMs(_playheadNs)),
        @"drawableWaitP95ms": @(SPStatsPercentileMs(_drawableWaitNs)),
        @"presentationDriver": @"CAMetalDisplayLink",
        @"presentationSlots": @{ @"preview": [self.preview displaySlotDiagnostics] ?: @{}, @"output": [self.outputPreview displaySlotDiagnostics] ?: @{} },
        @"presentationAdmissionToCallbackP95ms": @(SPStatsPercentileMs(_presentationAdmissionToCallbackNs)),
        @"metalCommitToDisplayP95ms": @(SPStatsPercentileMs(_metalCommitToDisplayNs)),
        @"displayScheduledTargetOffsetP95ms": @(SPStatsPercentileMs(_displayScheduledTargetOffsetNs)),
        @"notifyGapP95ms": @(SPStatsPercentileMs(_presentGapNs)),
        @"presentGapP95ms": @(SPStatsPercentileMs(_presentGapNs)),
        @"presentMediaLagP95ms": @(SPStatsPercentileMs(_presentMediaLagNs)),
        @"gpuToDisplayP95ms": @(SPStatsPercentileMs(_gpuToDisplayNs)),
        @"captureToDisplayP95ms": @(SPStatsPercentileMs(_captureToDisplayNs)),
        @"displayTimingNote": @"CAMetalDrawable.presentedTime and CACurrentMediaTime share media time; subtract callback delivery lag from mach host intervals. Existing capture-to-callback metric is unchanged.",
        @"occludedPresents": @(_occludedPresents),
        @"engineID": _resolved.engineID ?: @"",
        @"modelID": _resolved.modelID ?: @"",
        @"qualityID": _request.qualityID ?: @"",
        @"rifeStreamEnabled": @(_request.rifeStreamEnabled),
        @"rifeStreamDiagnostics": rifeDiagnostics,
        @"scaleEngineID": _resolved.scaleEngineID ?: @"",
        @"scaleQualityID": _resolved.scaleQualityID ?: @"",
        @"sourcePixelFormat": @(_sourcePixelFormat),
        @"frcEwmaMs": @(_frcEwmaSec * 1000.0),
        @"scaleEwmaMs": @(_scaleEwmaSec * 1000.0),
        @"measuredScheduled": @(_measuredScheduled),
        @"centerSampleMs": @((double)_centerSampleNs / 1e6),
        @"centerSamples": @(_centerSamples),
        @"queueByteBudget": @([self r8QueueByteBudget]),
        @"r8QualityDiagnostic": @(SPR8Enabled()),
        @"rifePairAffineClock": @([self usesRifePairAffineClock]),
        @"r8ExperimentActive": @([self r8CanExperiment]),
        @"r8AdmissionLimit": @([self r8AdmissionLimit]),
        @"r8SessionsRequested": @(SPR8Option(@"--odf-r8-sessions", 2, @[@1,@2,@3,@4])),
        @"r8SessionsActual": @(_engine ? _engine.sessionCount : 0),
        @"r8QueueBudgetScope": @"playout slot nominal bytes only; excludes capture pool, VT/Metal surfaces and model allocations",
        @"r8SlotCapByBytes": @([self slotCapByBytes]),
        @"r8PeakSlots": @(_peakSlots),
        @"r8TransientReserveFrames": @([self r8CanExperiment] ? 1 : 0),
        @"r8SlotReferencesCurrent": @(_slots.size() * 2),
        @"r8SlotReferencesPeak": @(_r8SlotReferencePeak),
        @"r8BudgetEvictions": @(_r8BudgetEvictions),
        @"r8ReportedSlotBytesCurrent": @([self r8ReportedSlotBytes]),
        @"r8ReportedSlotBytesPeak": @(_r8ReportedSlotBytesPeak),
        @"r8ReportedSlotBytesScope": @"deduplicated CVPixelBufferGetDataSize for queued slot buffers, not resident or total GPU/VT process memory",
        @"sourceWidth": @(_width),
        @"sourceHeight": @(_height),
        @"srInputWidth": @((int)SPLiveSRInputSizeForRequest(_width, _height, _request).width),
        @"srInputHeight": @((int)SPLiveSRInputSizeForRequest(_width, _height, _request).height),
        @"lowLatencyPreScale": @([self requestUsesLowPrescale:_request width:_width height:_height]),
        @"lowLatencyPrescaledInputs": @(_lowPrescaleInputs), @"lowLatencySyntheticNoRescale": @(_lowSyntheticNoRescale),
        @"processingWidth": @(processingWidth),
        @"processingHeight": @(processingHeight),
        @"lowLatencyProcessingWidth": @(_lowLatency ? _lowLatency.width : 0),
        @"lowLatencyProcessingHeight": @(_lowLatency ? _lowLatency.height : 0),
        @"lowLatencyPreparationFallbackReason": _lowLatency.preparationFallbackReason ?: @"",
        @"lowLatencyProcessingOrder": [self requestUsesLowPrescale:_request width:_width height:_height] ? @"lanczos-before-low-latency" : @"interpolation-before-scale",
        @"estimatedContentFPS": @((double)_windowChanged / seconds),
        @"r7ContentChange": @{ @"host": @(_r7ContentChangedHost),
            @"generation": @(_r7ContentChangedGeneration), @"configVersion": @(_r7ContentChangedConfig),
            @"measurementEpoch": @(_r7ContentChangedEpoch),
            @"note": @"sampled luma change; capture mach host, not proof of full-frame identity" },
        @"callbackFPS": @((double)_windowCallbacks / seconds),
        @"overlayInputEstimateFPS": @(_fpsMeter.inputRate((int64_t)(CACurrentMediaTime() * 1e9))),
        @"overlayPresentedFPS": @(_fpsMeter.outputRate((int64_t)(CACurrentMediaTime() * 1e9))),
        @"interpolationActive": @(_resolved.interpolationActive),
        @"scaleActive": @(_resolved.scaleActive),
        @"configVersion": @(_configVersion),
    };
    if (!_airCurrentStatsCalls) return result;
    NSMutableDictionary *measured = [result mutableCopy];
    NSMutableDictionary *sampling = [@{ @"beginHostTicks": @(statsBegin), @"threadID": @(statsThread),
        @"scope": @"currentStats through snapshot construction; end tagging and trace append follow the bracket" } mutableCopy];
    measured[@"statsSampling"] = sampling;
    const uint64_t statsEnd = SPHostNow();
    sampling[@"endHostTicks"] = @(statsEnd);
    _airCurrentStatsCalls->append({0, statsBegin, statsEnd, statsThread});
    return measured;
}

- (void)publishStats {
    int64_t now = SPHostNow();
    if (SPHostToNs(now - _lastStatsHost) < 200000000LL) return;
    _lastStatsHost = now;
    int64_t elapsedNs = _r9RateHost > 0 ? SPHostToNs(now - _r9RateHost) : 0;
    if (elapsedNs >= 1000000000LL) {
        if (elapsedNs <= 3000000000LL && _syntheticOK >= _r9RateSyntheticBaseline && _r9OnTimeSynthetic >= _r9RateOnTimeBaseline) {
            double seconds = (double)elapsedNs / 1e9;
            _r9GeneratedFPS = (_syntheticOK - _r9RateSyntheticBaseline) / seconds;
            _r9OnTimeSyntheticFPS = (_r9OnTimeSynthetic - _r9RateOnTimeBaseline) / seconds;
        } else { _r9GeneratedFPS = -1; _r9OnTimeSyntheticFPS = -1; }
        _r9RateHost = now; _r9RateSyntheticBaseline = _syntheticOK; _r9RateOnTimeBaseline = _r9OnTimeSynthetic;
    }
    void (^handler)(NSDictionary *) = self.statsHandler;
    if (!handler) return;
    NSDictionary *stats = [self currentStats];
    dispatch_async(dispatch_get_main_queue(), ^{ handler(stats); });
}

- (void)publishStatus:(NSString *)status failed:(BOOL)failed {
    void (^handler)(NSString *, BOOL, uint64_t) = self.statusHandler;
    if (!handler) return;
    uint64_t requestID = _ackRequestID;
    dispatch_async(dispatch_get_main_queue(), ^{ handler(status, failed, requestID); });
}

- (BOOL)validateRequest:(SPLivePlanRequest *)request reason:(NSString **)reason {
    BOOL sourceGuard = request.requiredSourceWidth || request.requiredSourceHeight || request.requiredSourceWindowID || request.requiredSourcePID || request.requiredSourceAfterHost;
    BOOL appleLowSR = request.scaleEngine == SPLiveScaleAppleLowLatencySR || request.scaleEngine == SPLiveScaleAppleVideoSR;
    if (sourceGuard && (request.requiredSourceWidth < 2 || request.requiredSourceHeight < 2 || !request.requiredSourceWindowID || request.requiredSourcePID <= 0 || !request.requiredSourceAfterHost || (!appleLowSR && request.srInputPreset != 0) || !request.scaleEnabled ||
        (!appleLowSR && request.scaleEngine != SPLiveScaleMetalFX && !SPLiveIsNative2xScaleEngine(request.scaleEngine)))) {
        if (reason) *reason = @"来源窗口尺寸计划无效或缺少已确认的窗口身份。";
        return NO;
    }
    if (sourceGuard && !appleLowSR) {
        BOOL nativeOutput = request.outputWidth == request.requiredSourceWidth*2 && request.outputHeight == request.requiredSourceHeight*2;
        BOOL autoAnimation = SPLiveIsNative2xScaleEngine(request.scaleEngine) && request.outputWidth == 0 && request.outputHeight == 0;
        if (!nativeOutput && !autoAnimation) { if (reason) *reason = @"来源窗口模式需要匹配的 2× 输出尺寸。"; return NO; }
    }
    if (request.scaleEnabled && request.scaleEngine == SPLiveScaleAppleVideoSR && request.interpolationEnabled) {
        if (reason) *reason = @"Apple 视频超分暂不支持同时插帧，请先关闭帧生成。";
        return NO;
    }
    if (request.scaleEnabled && request.scaleEngine == SPLiveScaleAppleVideoSR &&
        (int64_t)request.outputWidth * request.outputHeight > 3200LL * 1800) {
        if (reason) *reason = @"苹果视频超分的实时输出尺寸过大，请选择自动输出或更小尺寸。";
        return NO;
    }
    if (request.interpolationEnabled && request.rateKind == SPLiveRateMultiplier &&
        request.multiplier != 2 && request.multiplier != 3 && request.multiplier != 4) {
        if (reason) *reason = @"倍率只接受 X2、X3、X4";
        return NO;
    }
    if (request.interpolationEnabled && request.rateKind == SPLiveRateFixedFPS &&
        (request.fpsNumerator <= 0 || request.fpsDenominator <= 0)) {
        if (reason) *reason = @"自定义帧率的分子和分母都要大于 0";
        return NO;
    }
    if (request.outputWidth > 3840 || request.outputHeight > 2160) {
        if (reason) *reason = @"输出尺寸超过本轮 3840×2160 预算";
        return NO;
    }
    NSString *engine = request.engineID.length ? request.engineID : @"apple.frc";
    if (request.interpolationEnabled && [engine isEqualToString:@"distildrba.coreml"] &&
        (request.rateKind != SPLiveRateMultiplier || request.multiplier != 2)) {
        if (reason) *reason = @"DistilDRBA 当前支持 720p 来源和 X2。";
        return NO;
    }
    if (request.interpolationEnabled && [engine isEqualToString:@"apple.lowlatency"]) {
        if (![SPLowLatencyEngine isSupported]) {
            if (reason) *reason = @"这台系统没有 Apple 低延迟插帧";
            return NO;
        }
        if (request.rateKind == SPLiveRateMultiplier && request.multiplier == 3) {
            if (reason) *reason = @"低延迟只提供 1/2，或 1/4、1/2、3/4。X3 的 1/3 和 2/3 不会被改写，可改用 Apple 帧率转换。";
            return NO;
        }
        if (request.rateKind == SPLiveRateFixedFPS) {
            if (reason) *reason = @"低延迟不能表达固定帧率里的任意相位。请改用 Apple 帧率转换，或改成 X2 / X4。";
            return NO;
        }
    }
    if (request.interpolationEnabled && [engine isEqualToString:@"rife.metal"]) {
        NSString *model = request.modelID.length ? request.modelID : @"rife-v4.25";
        if (![model isEqualToString:@"rife-v4.25"] && ![model isEqualToString:@"rife-v4.26"]) {
            if (reason) *reason = @"RIFE 只有 4.25 和单独的 4.26 权重";
            return NO;
        }
    }
    return YES;
}

- (void)publishPlanState:(NSInteger)state reason:(NSString *)reason {
    if (state == 0) _holdFailureStatus = YES;
    if (state == 2) _holdFailureStatus = NO;
    void (^handler)(NSInteger, NSString *, NSString *, NSString *, uint64_t) = self.planHandler;
    if (!handler) return;
    NSString *engine = _ackEngineID ?: @"";
    NSString *model = _ackModelID ?: @"";
    NSString *text = reason ?: @"";
    uint64_t requestID = _ackRequestID;
    dispatch_async(dispatch_get_main_queue(), ^{ handler(state, engine, model, text, requestID); });
}

- (void)retireEngines {
    [_engine invalidate];
    _engine = nil;
    [_lowLatency invalidate];
    _lowLatency = nil;
    [self airRetireResidentKeeperForBridge:_rife reason:@"engines_retired"];
    [_rife invalidate];
    _rife = nil;
    [_distil invalidate];
    _distil = nil;
    _metal = nil;
}

- (void)airRetireResidentKeeperForBridge:(SPRifeBridge *)bridge reason:(NSString *)reason {
    if (_airTraceSessionActive && bridge) {
        [bridge recordKeeperRetirementForDiagnostics:reason];
        [self airDetachSessionServiceTrace:bridge reason:reason];
    }
#if ODF_AIR_RESIDENT_KEEPALIVE_DIAGNOSTIC
    if (!bridge.residentKeepAliveEnabled) return;
    [bridge requestStopKeeperForPlanToken:0 reason:reason];
    _airResidentRetiredBridge = bridge;
#endif
}

- (void)airStartInstalledResidentKeeper {
#if ODF_AIR_RESIDENT_KEEPALIVE_DIAGNOSTIC
    if (!_rife.residentKeepAliveEnabled || !_sessionReady || !_resolved.committed ||
        !_request.interpolationEnabled || !_request.rifeStreamEnabled ||
        _request.rateKind != SPLiveRateMultiplier || _request.multiplier != 2) return;
    _airResidentPlanToken = _prepareToken;
    if (![_rife startKeeperForPlanToken:_airResidentPlanToken generation:_sourceGeneration configVersion:_configVersion] &&
        !_airResidentInstallFailure) _airResidentInstallFailure = @"Installed keeper start was rejected";
#endif
}

- (void)markResidentKeepAlivePhase:(NSString *)phase {
#if ODF_AIR_RESIDENT_KEEPALIVE_DIAGNOSTIC
    NSString *name = [phase copy];
    dispatch_async(_q, ^{ [self->_rife markKeeperPhase:name forPlanToken:self->_airResidentPlanToken]; });
#endif
}

- (void)requestStopResidentKeepAliveForDiagnostics:(NSString *)reason {
#if ODF_AIR_RESIDENT_KEEPALIVE_DIAGNOSTIC
    NSString *text = [reason copy];
    dispatch_async(_q, ^{
        if (self->_airTraceSessionActive) {
            // A keeper-only request does not retire the RIFE producer. Its
            // service trace is detached at the existing actual bridge stop.
            [self->_rife recordKeeperRetirementForDiagnostics:text];
            if (self->_rife.residentKeepAliveEnabled) {
                [self->_rife requestStopKeeperForPlanToken:0 reason:text];
                self->_airResidentRetiredBridge = self->_rife;
            }
        } else [self airRetireResidentKeeperForBridge:self->_rife reason:text];
    });
#endif
}

- (NSDictionary *)residentKeepAliveSnapshotAtCutoffHostTicks:(uint64_t)cutoff includeRecords:(BOOL)includeRecords {
#if ODF_AIR_RESIDENT_KEEPALIVE_DIAGNOSTIC
    __block NSDictionary *result;
    void (^capture)(void) = ^{
        NSDictionary *active = [self->_rife snapshotKeeperAtCutoffHostTicks:cutoff includeRecords:includeRecords];
        NSDictionary *retired = self->_airResidentRetiredBridge != self->_rife
            ? [self->_airResidentRetiredBridge snapshotKeeperAtCutoffHostTicks:cutoff includeRecords:includeRecords] : nil;
        result = @{ @"schema": @"odf-app-resident-keepalive-processor-v1", @"compiled": @YES,
            @"enabled": @(self->_rife.residentKeepAliveEnabled || self->_airResidentRetiredBridge.residentKeepAliveEnabled),
            @"installedPlanToken": @(self->_airResidentPlanToken), @"sourceGenerationAtSnapshot": @(self->_sourceGeneration),
            @"configVersionAtSnapshot": @(self->_configVersion), @"stopped": @(self->_stopped),
            @"firstFailure": self->_airResidentInstallFailure ?: (id)NSNull.null,
            @"active": active ?: @{}, @"retired": retired ?: @{},
            @"exportCutoffHostTicks": @(cutoff), @"scope": @"CPU metadata/export only; no GPU wait. Retired bridge stays readable after processor stop." };
    };
    if (dispatch_get_specific(SPLiveQueueKey) == (__bridge void *)self) capture(); else dispatch_sync(_q, capture);
    return result;
#else
    return @{ @"compiled": @NO, @"enabled": @NO };
#endif
}

- (BOOL)requestUsesAsyncEngine:(SPLivePlanRequest *)request {
    if (!request.interpolationEnabled) return NO;
    NSString *engine = request.engineID.length ? request.engineID : @"apple.frc";
    return [engine isEqualToString:@"apple.lowlatency"] || [engine isEqualToString:@"rife.metal"] || [engine isEqualToString:@"distildrba.coreml"];
}

- (BOOL)requestUsesAsyncScale:(SPLivePlanRequest *)request {
    return request.scaleEnabled && (request.scaleEngine == SPLiveScaleAppleLowLatencySR || request.scaleEngine == SPLiveScaleAppleVideoSR || SPLiveIsNative2xScaleEngine(request.scaleEngine));
}

- (BOOL)requestUsesLatestScale:(SPLivePlanRequest *)request {
    return request.scaleEnabled && SPLiveIsNative2xScaleEngine(request.scaleEngine);
}

- (BOOL)requestUsesLowPrescale:(SPLivePlanRequest *)request width:(int)width height:(int)height {
    int w=request.outputWidth, h=request.outputHeight;
    return request.srInputPreset == 0 && request.interpolationEnabled && [request.engineID isEqualToString:@"apple.lowlatency"] &&
        request.scaleEnabled && request.scaleEngine==SPLiveScaleLanczos && w>0 && h>0 &&
        !(w&1) && !(h&1) && width>0 && height>0 && w<width && h<height &&
        (int64_t)w*height==(int64_t)h*width;
}

- (BOOL)requestUsesLatestPresentation:(SPLivePlanRequest *)request {
    return SPR7Passthrough() || !request.interpolationEnabled || [self requestUsesLatestScale:request] || (request.interpolationEnabled &&
        ([request.engineID isEqualToString:@"distildrba.coreml"] ||
         ([request.engineID isEqualToString:@"apple.lowlatency"] && _lowPrescaleSlowMode)));
}

- (void)clearPendingRife {
    if (!_rifePending.empty()) {
        for (uint64_t identity : {_rifePending.front().frameA, _rifePending.front().frameB}) {
            auto found = _held.find(identity);
            if (found != _held.end() && found->second.pins > 0) found->second.pins -= 1;
        }
        _rifePending.clear();
    }
    _rifePendingGeneration = 0;
    [self clearDeferredRife];
}

- (void)clearDeferredRife {
    if (!_haveRifeDeferred) return;
    for (uint64_t identity : {_rifeDeferredEvent.frameA, _rifeDeferredEvent.frameB}) {
        auto found = _held.find(identity);
        if (found != _held.end() && found->second.pins > 0) found->second.pins -= 1;
    }
    [self erasePending:_rifeDeferredEvent.pts];
    _haveRifeDeferred = NO;
    _rifeDeferredRetryHost = 0;
    _rifeDeferredPairClock = {};
}

- (BOOL)deferRifeEvent:(const sp::SPScheduleOutput &)event generation:(uint64_t)generation
               deadline:(int64_t)deadline retryHost:(int64_t)retryHost {
    return [self deferRifeEvent:event generation:generation deadline:deadline retryHost:retryHost frozenPairClock:nullptr];
}

- (BOOL)deferRifeEvent:(const sp::SPScheduleOutput &)event generation:(uint64_t)generation
    deadline:(int64_t)deadline retryHost:(int64_t)retryHost frozenPairClock:(const sp::RifePairClockTarget *)frozenPairClock {
    auto a=_held.find(event.frameA), b=_held.find(event.frameB);
    if (_haveRifeDeferred || a==_held.end() || b==_held.end() || deadline<=SPHostNow() ||
        (_haveLastPts && sp::spCmp(event.pts,_lastPresentedPts)<=0)) return NO;
    _haveRifeDeferred=YES; _rifeDeferredEvent=event; _rifeDeferredDeadline=deadline;
    _rifeDeferredPairClock = frozenPairClock ? *frozenPairClock : sp::RifePairClockTarget{};
    _rifeDeferredGeneration=generation; _rifeDeferredClockEpoch=_clockEpoch; _rifeDeferredRetryHost=retryHost; _rifeDeferredAccepted++;
    a->second.pins++; b->second.pins++;
    SPPendingPhase phase; phase.pts=event.pts; phase.targetHost=deadline; phase.generation=generation;
    _pending.push_back(phase);
    return YES;
}

- (void)expireDeferredRifeAt:(int64_t)now {
    if (!_haveRifeDeferred) return;
    if (_rifeDeferredGeneration != _sourceGeneration || _rifeDeferredClockEpoch != _clockEpoch ||
        (_rifeDeferredPairClock.recorded && !sp::sameRifePairClockContext(_rifeDeferredPairClock.context,[self rifePairClockContext]))) {
        [self clearDeferredRife]; return;
    }
    BOOL stale = _haveLastPts && sp::spCmp(_rifeDeferredEvent.pts, _lastPresentedPts) <= 0;
    if (_rifeDeferredDeadline <= now || stale) {
        if ([self noteUniqueSyntheticDrop:_rifeDeferredEvent.pts]) {
            if (stale && _rifeDeferredDeadline > now) { _rifeDeferredStale++; _staleReadyDrops++; }
            else { _rifeDeferredExpired++; _pendingExpiredDrops++; }
        }
        [self clearDeferredRife];
    }
}

- (void)resumeDeferredRife {
    int64_t now=SPHostNow();
    [self expireDeferredRifeAt:now];
    if (!_haveRifeDeferred || _inflight >= 2 || !_rife || _stopped) return;
    if (_rifeDeferredRetryHost > now) {
        int64_t next=_slots.empty()?_rifeDeferredRetryHost:MIN(_rifeDeferredRetryHost,_slots.front().targetHost);
        [self armClockAt:next]; return;
    }
    auto event = _rifeDeferredEvent;
    int64_t deadline = _rifeDeferredDeadline;
    uint64_t generation = _rifeDeferredGeneration;
    const auto frozenPairClock = _rifeDeferredPairClock;
    [self clearDeferredRife];
    [self submitEventGroup:{event} generation:generation frozenDeadline:deadline
        frozenPairClock:frozenPairClock.recorded ? &frozenPairClock : nullptr];
}

- (void)resetAsyncScaleOnQueue {
    ++_srSequence;
    while (!_srPending.empty()) { SPReleaseSRJob(_srPending.front()); _srPending.pop_front(); }
    _srPendingBytes = 0;
    _srBusy = NO;
    _srFailed = NO;
    _videoSRDiscontinuity = YES;
}

- (void)installRequest:(SPLivePlanRequest *)request lowLatency:(SPLowLatencyEngine *)lowLatency rife:(SPRifeBridge *)rife distil:(SPDistilDRBA *)distil appleSR:(SPAppleLowLatencySR *)appleSR videoSR:(SPAppleVideoSR *)videoSR animeSR:(SPAnime4K *)animeSR cuganSR:(SPRealCUGAN *)cuganSR artCNNSR:(SPArtCNNSR *)artCNNSR {
    SPFRCEngine *oldEngine = _engine;
    SPLowLatencyEngine *oldLow = _lowLatency;
    SPRifeBridge *oldRife = _rife;
    SPDistilDRBA *oldDistil = _distil;
    SPAppleLowLatencySR *oldSR = _appleSR;
    SPAppleVideoSR *oldVideoSR = _videoSR;
    SPAnime4K *oldAnimeSR = _animeSR;
    SPRealCUGAN *oldCuganSR = _cuganSR;
    SPArtCNNSR *oldArtCNNSR = _artCNNSR;
    SPFrameBudgetMetal *oldMetal = _metal;
    SPSpatialScaler *oldScaler = _scaler;
    SPSpatialScaler *oldBaseline = _baselineScaler;
    SPSpatialScaler *oldInput = _srInputScaler;
    SPLivePlanRequest *oldRequest = _request;
    BOOL oldReady = _sessionReady;
    BOOL oldInterpolationActive = _resolved.interpolationActive;
    BOOL oldScaleActive = _resolved.scaleActive;
    BOOL oldCommitted = _resolved.committed;
    _engine = nil;
    _metal = nil;
    _scaler = nil;
    _baselineScaler = nil;
    _srInputScaler = nil;
    _lowLatency = lowLatency;
    _rife = rife;
    _distil = distil;
    _appleSR = appleSR;
    _videoSR = videoSR;
    _animeSR = animeSR;
    _cuganSR = cuganSR;
    _artCNNSR = artCNNSR;
    _request = request;
    _sessionReady = NO;
    NSError *error = nil;
    BOOL ok = [self buildOnQueue:&error];
    if (!ok) {
        [lowLatency invalidate];
        [self airDetachSessionServiceTrace:rife reason:@"failed-installation"];
        [rife invalidate];
        [distil invalidate];
        [appleSR invalidate];
        [videoSR invalidate];
        [animeSR invalidate];
        [cuganSR invalidate];
        [artCNNSR invalidate];
        _engine = oldEngine;
        _lowLatency = oldLow;
        _rife = oldRife;
        _distil = oldDistil;
        _appleSR = oldSR;
        _videoSR = oldVideoSR;
        _animeSR = oldAnimeSR;
        _cuganSR = oldCuganSR;
        _artCNNSR = oldArtCNNSR;
        _metal = oldMetal;
        _scaler = oldScaler;
        _baselineScaler = oldBaseline;
        _srInputScaler = oldInput;
        _request = oldRequest;
        _sessionReady = oldReady;
        NSString *reason = error.localizedDescription ?: @"准备失败，仍使用上一份可用计划";
        [self refreshResolvedOnQueue];
        _resolved.interpolationActive = oldInterpolationActive;
        _resolved.scaleActive = oldScaleActive;
        _resolved.committed = oldCommitted;
        _resolved.unavailableReason = reason;
#if ODF_AIR_BETA_DIAGNOSTIC
        if (SPAirBetaEnabled() && request.interpolationEnabled) { [self airBetaUsePassthrough:reason]; return; }
#endif
        if (_airPerformanceEnabled && request.interpolationEnabled) { [self airPerformanceUsePassthrough:reason]; return; }
        [self publishStatus:reason failed:YES];
        [self publishPlanState:0 reason:reason];
        return;
    }
    _sourceSizeConstraintFailed = NO;
    [oldEngine invalidate];
    [oldLow invalidate];
    [self airRetireResidentKeeperForBridge:oldRife reason:@"plan_replaced"];
    [oldRife invalidate];
    [oldDistil invalidate];
    [oldSR invalidate];
    [oldVideoSR invalidate];
    [oldAnimeSR invalidate];
    [oldCuganSR invalidate];
    [oldArtCNNSR invalidate];
    [self applyObservedCaptureEnvironment];
    [self resetRateBudgetOnQueue];
    [self clearPendingRife];
    _rifeSlowMode = NO;
    _lowPrescaleSlowMode = NO;
    [self resetAsyncScaleOnQueue];
    [self.outputPreview invalidateSharedGeometry];
    _configVersion += 1;
    _inflightEpoch = _configVersion;
    _inflight = 0;
    _havePair = NO;
    [self clearPlaySlots];
    if (distil || rife) {
        if (_lastEnhanced) { CVPixelBufferRelease(_lastEnhanced); _lastEnhanced = nullptr; }
        if (_lastOriginal) { CVPixelBufferRelease(_lastOriginal); _lastOriginal = nullptr; }
        _haveLastPts = NO;
    }
    [self resetSchedulerOnQueue];
    [self recomputeInteractiveDelay];
    [self refreshResolvedOnQueue];
    _resolved.committed = YES;
    _resolved.configVersion = _configVersion;
    [self beginMeasurementEpoch];
    [self airStartInstalledResidentKeeper];
#if ODF_AIR_BETA_DIAGNOSTIC
    if (SPAirBetaEnabled() && rife && _airResidentInstallFailure) {
        [self airBetaUsePassthrough:[NSString stringWithFormat:@"Air保活启动失败，现以原帧播放：%@", _airResidentInstallFailure]];
        return;
    }
#endif
#if ODF_AIR_RESIDENT_KEEPALIVE_DIAGNOSTIC
    if (_airPerformanceEnabled && rife && _airResidentInstallFailure) {
        [self airPerformanceUsePassthrough:[NSString stringWithFormat:@"窗口优化保活启动失败，现以原帧播放：%@", _airResidentInstallFailure]];
        return;
    }
#endif
    [self publishPlanState:2 reason:_resolved.activeSummary ?: @"增强运行"];
}

#if ODF_AIR_BETA_DIAGNOSTIC
- (NSString *)airBetaEnvironmentReason {
    if (!_airBetaFormatKnown) return @"等待实际采集格式，当前以原帧播放";
    NSString *sizeReason = SPAirBetaSizingReason(_sourceWidth, _sourceHeight);
    if (sizeReason) return sizeReason;
    if (_airBetaFormatReason) return _airBetaFormatReason;
    const auto raw = [self nativeCadenceSnapshot];
    const double refresh = _airBetaObservedRefreshHz > 1 ? _airBetaObservedRefreshHz : (raw.configured ? raw.refreshHz : _request.displayRefreshHz);
    if (!std::isfinite(refresh) || refresh != 60.0)
        return [NSString stringWithFormat:@"当前显示器为%.2fHz，Air实验档只支持60Hz，现以原帧播放", refresh];
    for (const char *key : {"ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC", "ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC", "ODF_AIR_RESIDENT_KEEPALIVE_DIAGNOSTIC"}) {
        if (strcmp(getenv(key) ?: "", "1") != 0) return @"Air融合处理或保活配方未启用，现以原帧播放";
    }
    NSDictionary *presenter = [self.outputPreview fusedRifePresentationSnapshotIncludeRecords:NO cutoffHostTicks:SPHostNow()];
    if (![presenter[@"lanczosPipelineReady"] boolValue]) return @"Air呈现器尚未就绪，现以原帧播放";
    return nil;
}

- (void)airBetaUsePassthrough:(NSString *)reason {
    _prepareToken += 1; _preparing = NO; _asyncPrepareFailed = YES;
    [self retireEngines];
    if (_lastEnhanced) { CVPixelBufferRelease(_lastEnhanced); _lastEnhanced = NULL; }
    if (_lastOriginal) { CVPixelBufferRelease(_lastOriginal); _lastOriginal = NULL; }
    _haveLastPts = NO;
    SPLivePlanRequest *original = [(_airBetaRecipe ?: _request) copy];
    original.interpolationEnabled = NO; original.scaleEnabled = NO;
    _airBetaFallbackReason = [reason copy];
    if (_width < 2 || _height < 2) {
        _request = original; _sessionReady = YES;
        _resolved.committed = YES; _resolved.interpolationActive = NO; _resolved.scaleActive = NO;
    } else {
        [self installRequest:original lowLatency:nil rife:nil distil:nil appleSR:nil videoSR:nil animeSR:nil cuganSR:nil artCNNSR:nil];
    }
    _resolved.interpolationActive = NO;
    _resolved.unavailableReason = reason;
    [self publishStatus:reason failed:NO];
    [self publishPlanState:2 reason:reason];
}

- (NSDictionary *)airBetaSnapshot {
    NSDictionary *runtime = _rife ? [_rife airBetaRuntimeState] : @{};
    if ([runtime[@"keeper"] isEqual:@"failed"] && _request.interpolationEnabled) {
        [self airBetaUsePassthrough:[NSString stringWithFormat:@"Air保活失败，现以原帧播放：%@", runtime[@"reason"] ?: @"未知错误"]];
        runtime = @{};
    }
    NSString *keeper = runtime[@"keeper"] ?: (_preparing ? @"preparing" : @"inactive");
    const BOOL active = _resolved.interpolationActive && _rife && [keeper isEqual:@"active"];
    const NSInteger factor = active && !_nativeBudgetActive && !_rateBudgetPassthrough
        ? ([self rateBudgetEnabled] ? _effectiveMultiplier : _request.multiplier) : 1;
    NSString *reason = _airBetaOriginalFailure ?: _airBetaFallbackReason;
    if (!reason.length) reason = _preparing ? @"正在准备Air实验档，当前显示原帧" :
        (active ? (factor > 1 ? @"Air实验档已生效" : @"当前按1×播放，保活保持运行") : @"等待保活启动，当前显示原帧");
    return @{ @"enabled": @YES, @"capturePixels": @[@(_sourceWidth), @(_sourceHeight)],
        @"processingPixels": _rife ? @[@(_rife.processingWidth), @(_rife.processingHeight)] : @[@0, @0],
        @"format": _airBetaFormatDescription ?: @"待采集", @"keeper": keeper,
        @"effectiveFactor": @(MAX(1, factor)), @"fps": @(_fpsMeter.outputRate((int64_t)(CACurrentMediaTime() * 1e9))),
        @"reason": reason, @"sourceGeneration": @(_sourceGeneration), @"configVersion": @(_configVersion) };
}

- (NSDictionary *)airBetaMeasurementReadiness {
    NSDictionary *runtime = _rife ? [_rife airBetaMeasurementReadiness] : @{};
    NSDictionary *keeper = runtime[@"keeper"] ?: @{};
    const BOOL finalPlan = (SPAirBetaEnabled() || _airPerformanceEnabled) && _sessionReady && _resolved.committed && _resolved.interpolationActive &&
        !_preparing && _rife && _airResidentPlanToken != 0 && _airResidentPlanToken == _prepareToken &&
        _request.interpolationEnabled && !_request.scaleEnabled && [_request.engineID isEqual:@"rife.metal"] &&
        [_request.modelID isEqual:@"rife-v4.25"] && [_request.qualityID isEqual:@"fast"] &&
        _request.rifeStreamEnabled && _request.rateKind == SPLiveRateMultiplier && _request.multiplier == 2;
    id failure = runtime[@"firstFailure"];
    const BOOL noRuntimeFailure = failure == NSNull.null || ([failure isKindOfClass:NSString.class] && [failure length] == 0);
    const BOOL actual = finalPlan && [runtime[@"compiled"] boolValue] && [runtime[@"hasInterpolator"] boolValue] &&
        [runtime[@"loadedModelID"] isEqual:@"rife-v4.25"] && [runtime[@"loadedQuality"] isEqual:@"fast"] &&
        [runtime[@"preparedGPUInputOutput"] boolValue] && [runtime[@"liveStreamEnabled"] boolValue] && noRuntimeFailure;
    const BOOL keeperMatches = [keeper[@"available"] boolValue] &&
        [keeper[@"planToken"] unsignedLongLongValue] == _airResidentPlanToken &&
        [keeper[@"generation"] unsignedLongLongValue] == _sourceGeneration &&
        [keeper[@"configVersion"] unsignedLongLongValue] == _configVersion;
    const BOOL operational = [keeper[@"operational"] boolValue];
    NSString *reason = !finalPlan ? @"current final X2 plan is not installed" :
        (!actual ? @"prepared runtime identity or GPU-IO/stream state is not ready" :
        (!keeperMatches ? @"keeper plan context does not match" : (!operational ? @"keeper first operational command is not observed" : @"ready")));
    return @{ @"schema": @"odf-air-beta-measurement-readiness-v1", @"enabled": @(SPAirBetaEnabled() || _airPerformanceEnabled),
        @"productionOptimizationEnabled": @(_airPerformanceEnabled),
        @"sourceGeneration": @(_sourceGeneration), @"configVersion": @(_configVersion),
        @"measurementEpoch": @(_measurementEpoch), @"clockEpoch": @(_clockEpoch),
        @"planToken": @(_airResidentPlanToken), @"prepareToken": @(_prepareToken),
        @"sessionReady": @(_sessionReady), @"committed": @(_resolved.committed), @"interpolationActive": @(_resolved.interpolationActive),
        @"preparing": @(_preparing), @"hasRifeBridge": @(_rife != nil), @"nativeActualFinalX2": @(actual),
        @"keeperPlanMatchesContext": @(keeperMatches), @"keeperOperational": @(operational),
        @"ready": @(actual && keeperMatches && operational), @"reason": reason, @"runtime": runtime,
        @"observedHostTicks": @(SPHostNow()) };
}
#endif

- (void)airSetPerformanceMode:(BOOL)enabled {
    _airPerformanceEnabled = enabled;
    _airDelayAlignmentRequested = _airDelayAlignmentDiagnosticRequested || enabled;
    _airTrueSourceIntervalRequested = _airTrueSourceIntervalDiagnosticRequested || enabled;
    _airRobustSourceLeadRequested = _airRobustSourceLeadDiagnosticRequested || enabled;
    if (_airDelayAlignmentRequested && _airCadenceCallbacks && !_airDelayAlignmentEvents)
        _airDelayAlignmentEvents = std::make_unique<SPAirDelayAlignmentRing>();
    [self.outputPreview setAirPerformanceEnabled:enabled captureWidth:_sourceWidth captureHeight:_sourceHeight];
    [self.preview setAirPerformanceEnabled:enabled captureWidth:_sourceWidth captureHeight:_sourceHeight];
}

- (void)airConfigurePerformanceRequest:(SPLivePlanRequest *)request {
    const BOOL wasCandidate = _airPerformanceCandidate;
    _airPerformanceSelection = [SPRifeBridge airPerformanceSelectionStatus];
    sp::AirWindowOptimizationInput input;
    input.hardware = SPAirHardwareModel().UTF8String;
    input.sourceKind = request.captureSourceKind;
    input.interpolation = request.interpolationEnabled;
    input.rife425 = [request.engineID isEqual:@"rife.metal"] && [request.modelID isEqual:@"rife-v4.25"];
    input.fast = [request.qualityID isEqual:@"fast"];
    input.multiplierRate = request.rateKind == SPLiveRateMultiplier;
    input.multiplier = request.multiplier;
    input.stream = request.rifeStreamEnabled;
    input.scale = request.scaleEnabled;
    input.original = [_airPerformanceSelection[@"originalEF29"] boolValue];
    input.productionFourStage = [_airPerformanceSelection[@"productionFourStage"] boolValue] &&
        [_airPerformanceSelection[@"expectedGraphID"] isEqual:@"odf-ifnet425-fourstage-acc-v1"] &&
        [_airPerformanceSelection[@"expectedWeightsSHA256"] isEqual:@"729ea555016da98e207bc4570e0be81dddbbd37302f7330c89696da798fba22d"];
    input.gpuIO = [_airPerformanceSelection[@"gpuIO"] boolValue];
    input.accumulate = [_airPerformanceSelection[@"accumulate"] boolValue];
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC && ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC && ODF_AIR_RESIDENT_KEEPALIVE_DIAGNOSTIC && ODF_AIR_PRESENTATION_GUARD_DIAGNOSTIC && ODF_AIR_BETA_DIAGNOSTIC
    input.compiled = true;
#endif
    const char *reason = sp::airWindowOptimizationReason(input);
    _airPerformanceCandidate = !SPAirBetaEnabled() && !reason;
    if (_airPerformanceCandidate && !wasCandidate) _airPerformanceFormatKnown = NO;
    _airPerformanceRecipe = _airPerformanceCandidate ? [request copy] : nil;
    _airPerformanceRequested = _airPerformanceCandidate && _airActualSourceKind == SPLiveCaptureSourceKindWindow;
    _airPerformanceReason = reason ? [NSString stringWithUTF8String:reason] : @"等待实际窗口采集";
    _airPerformanceEligibilityKnown = NO;
    if (!_airPerformanceCandidate) [self airSetPerformanceMode:NO];
}

- (NSString *)airPerformanceEnvironmentReason {
#if ODF_AIR_BETA_DIAGNOSTIC || ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
    if (!_airPerformanceFormatKnown) return @"等待实际窗口采集";
    if (_airActualSourceKind != SPLiveCaptureSourceKindWindow) return @"actual-source-is-not-window";
    if (_airPerformanceFormatReason) return _airPerformanceFormatReason;
    NSString *sizeReason = SPAirBetaSizingReason(_sourceWidth, _sourceHeight);
    if (sizeReason) return sizeReason;
    const auto raw = [self nativeCadenceSnapshot];
    const double refresh = raw.configured ? raw.refreshHz : (_airPerformanceRecipe ?: _request).displayRefreshHz;
    if (!std::isfinite(refresh) || refresh != 60.0) return @"窗口优化需要60Hz显示，现以原帧播放";
    if (!self.outputPreview) return @"等待窗口呈现器，当前以原帧播放";
    return nil;
#else
    return @"feature-not-compiled";
#endif
}

- (void)airPerformanceUsePassthrough:(NSString *)reason {
    _prepareToken += 1; _preparing = NO; _asyncPrepareFailed = YES;
    [self retireEngines];
    [self airSetPerformanceMode:NO];
    if (_lastEnhanced) { CVPixelBufferRelease(_lastEnhanced); _lastEnhanced = NULL; }
    if (_lastOriginal) { CVPixelBufferRelease(_lastOriginal); _lastOriginal = NULL; }
    _haveLastPts = NO;
    SPLivePlanRequest *original = [(_airPerformanceRecipe ?: _request) copy];
    original.interpolationEnabled = NO; original.scaleEnabled = NO;
    _airPerformanceReason = [reason copy];
    if (_width < 2 || _height < 2) {
        _request = original; _sessionReady = YES;
        _resolved.committed = YES; _resolved.interpolationActive = NO; _resolved.scaleActive = NO;
    } else {
        [self installRequest:original lowLatency:nil rife:nil distil:nil appleSR:nil videoSR:nil animeSR:nil cuganSR:nil artCNNSR:nil];
    }
    _resolved.interpolationActive = NO; _resolved.unavailableReason = reason;
    [self publishStatus:reason failed:NO];
    [self publishPlanState:2 reason:reason];
}

- (NSDictionary *)airWindowOptimizationSnapshot {
    NSDictionary *runtime = _rife ? [_rife airBetaRuntimeState] : @{};
    if (_airPerformanceEnabled && [runtime[@"keeper"] isEqual:@"failed"]) {
        [self airPerformanceUsePassthrough:[NSString stringWithFormat:@"窗口优化保活失败，现以原帧播放：%@", runtime[@"reason"] ?: @"未知错误"]];
        runtime = @{};
    }
    const BOOL bridgeEnabled = _rife && _rife.airPerformanceEnabled;
    const BOOL active = _airPerformanceEnabled && bridgeEnabled && _resolved.interpolationActive &&
        [runtime[@"keeper"] isEqual:@"active"];
    NSString *reason = _airPerformanceReason ?: @"configuration-not-eligible";
    if (_airPerformanceEnabled) reason = active ? @"窗口优化已生效" : (_preparing ? @"正在准备窗口优化" : @"等待保活启动");
    NSDictionary *prepared = [self.outputPreview preparedTextureCountersSnapshot] ?: @{};
    uint64_t planToken = 0;
    NSDictionary *retired = @{};
#if ODF_AIR_RESIDENT_KEEPALIVE_DIAGNOSTIC
    planToken = _airResidentPlanToken;
    if (_airResidentRetiredBridge) retired = [_airResidentRetiredBridge airBetaMeasurementReadiness] ?: @{};
#endif
    return @{ @"schema": @"odf-air-window-optimization-v1", @"hardware": SPAirHardwareModel(),
        @"hardwareSupported": @(sp::airWindowHardwareSupported(SPAirHardwareModel().UTF8String)),
        @"requestEligible": @(_airPerformanceCandidate), @"candidate": @(_airPerformanceRequested),
        @"enabled": @(_airPerformanceEnabled), @"active": @(active), @"reason": reason,
        @"requestedSourceKind": @((_airPerformanceRecipe ?: _request).captureSourceKind), @"actualSourceKind": @(_airActualSourceKind),
        @"selection": _airPerformanceSelection ?: @{}, @"selectionGuardNs": @([self.outputPreview selectionGuardNs]),
        @"sourceGeneration": @(_sourceGeneration), @"configVersion": @(_configVersion),
        @"measurementEpoch": @(_measurementEpoch), @"clockEpoch": @(_clockEpoch), @"planToken": @(planToken),
        @"capturePixels": @[@(_sourceWidth), @(_sourceHeight)],
        @"processingPixels": _rife ? @[@(_rife.processingWidth), @(_rife.processingHeight)] : @[@0,@0],
        @"applied": @{ @"prescale": @(bridgeEnabled && _rife.rifePrescaleEnabled),
            @"fusedPreprocessAndPresent": @(bridgeEnabled && _rife.fusedRifePresentEnabled),
            @"presenter": @([self.outputPreview airPerformanceEnabled]),
            @"keeper": @(bridgeEnabled && _rife.residentKeepAliveEnabled),
            @"preparedTexture": prepared,
            @"delayAlignmentRequested": @(_airDelayAlignmentRequested), @"delayAlignmentActiveX2": @(_airDelayAlignmentActiveX2),
            @"trueSourceIntervalRequested": @(_airTrueSourceIntervalRequested),
            @"robustSourceLeadRequested": @(_airRobustSourceLeadRequested), @"robustSourceLeadApplied": @(_airRobustSourceLeadApplied),
            @"interactiveCapNs": @((int64_t)llround((_request.quality == SPFRCQualityHigh ? SPQualityCapSec : SPInteractiveCapSec) * 1e9)) },
        @"runtime": runtime, @"retiredRuntime": retired,
        @"traceAllocated": @{ @"callbacks": @(_airCadenceCallbacks != nullptr), @"budget": @(_airCadenceBudget != nullptr),
            @"delay": @(_airDelayAlignmentEvents != nullptr), @"stats": @(_airCurrentStatsCalls != nullptr) } };
}

- (void)startAsyncEngine:(SPLivePlanRequest *)request {
#if ODF_AIR_BETA_DIAGNOSTIC
    if (SPAirBetaEnabled()) {
        if (![request.engineID isEqual:@"rife.metal"] || ![request.modelID isEqual:@"rife-v4.25"] ||
            ![request.qualityID isEqual:@"fast"] || !request.rifeStreamEnabled || request.rateKind != SPLiveRateMultiplier ||
            request.multiplier != 2 || request.scaleEnabled) {
            [self airBetaUsePassthrough:@"Air实验档配方不符，现以原帧播放"]; return;
        }
        NSString *reason = [self airBetaEnvironmentReason];
        if (reason) { [self airBetaUsePassthrough:reason]; return; }
        _airBetaFallbackReason = nil; _airBetaOriginalFailure = nil;
        _airResidentInstallFailure = nil;
    }
#endif
    if (_airPerformanceCandidate) {
        if (!_airPerformanceFormatKnown) {
            _request = request; _sessionReady = NO; _resolved.committed = NO;
            _airPerformanceReason = @"等待实际窗口采集";
            return;
        }
        if (_airPerformanceRequested) {
            NSString *reason = [self airPerformanceEnvironmentReason];
            if (reason) { [self airPerformanceUsePassthrough:reason]; return; }
            if (![self.outputPreview setAirPerformanceEnabled:YES captureWidth:_sourceWidth captureHeight:_sourceHeight]) {
                [self airPerformanceUsePassthrough:@"窗口呈现器未就绪，现以原帧播放"]; return;
            }
            [self airSetPerformanceMode:YES];
            _airPerformanceReason = @"正在准备窗口优化";
#if ODF_AIR_RESIDENT_KEEPALIVE_DIAGNOSTIC
            _airResidentInstallFailure = nil;
#endif
        } else {
            [self airSetPerformanceMode:NO];
            _airPerformanceReason = @"actual-source-is-not-window";
        }
    }
    _asyncPrepareFailed = NO;
    if (_width < 2 || _height < 2) {
        _request = request;
        [self resetRateBudgetOnQueue];
        [self applyObservedCaptureEnvironment];
        _sessionReady = NO;
        _resolved.committed = NO;
        [self refreshResolvedOnQueue];
        [self publishStatus:@"计划已记下，等到来源画面后准备引擎" failed:NO];
        [self publishPlanState:1 reason:@"计划已记下，等到来源画面后准备引擎"];
        return;
    }
    _preparing = YES;
    _prepareToken += 1;
    uint64_t token = _prepareToken;
    int width = _width;
    int height = _height;
    SPLivePlanRequest *copy = [request copy];
    NSString *engine = copy.engineID.length ? copy.engineID : @"apple.frc";
    NSObject *sessionJournal = _airTraceSessionActive ? _airTraceKeeperJournal : nil;
    const BOOL sessionRecordingSealed = _airTraceRecordingSaturated;
    const BOOL performanceEnabled = _airPerformanceEnabled;
    [self publishStatus:@"正在准备引擎" failed:NO];
    [self publishPlanState:1 reason:@"正在准备引擎，当前画面仍用上一份已生效的计划"];
    dispatch_async(_prepareQ, ^{
        if (copy.scaleEnabled && copy.scaleEngine == SPLiveScaleAppleVideoSR) {
            NSSize input = SPLiveSRInputSizeForRequest(width, height, copy);
            BOOL automatic = copy.outputWidth == 0 && copy.outputHeight == 0;
            NSSize output = automatic ? [SPAppleVideoSR automaticOutputForWidth:(int)input.width height:(int)input.height] : NSMakeSize(copy.outputWidth, copy.outputHeight);
            int factor = input.width > 0 ? (int)llround(output.width / input.width) : 0;
            if (factor >= 2 && ![SPAppleVideoSR isReadyForWidth:(int)input.width height:(int)input.height scale:factor]) {
                dispatch_async(self->_q, ^{ if (token == self->_prepareToken) [self publishStatus:@"正在准备苹果视频超分模型，可能需要下载" failed:NO]; });
                [SPAppleVideoSR ensureModelForWidth:(int)input.width height:(int)input.height scale:factor completion:^(NSError *modelError) {
                    dispatch_async(self->_q, ^{
                        if (token != self->_prepareToken) return;
                        self->_preparing = NO;
                        if (modelError) {
                            self->_asyncPrepareFailed = YES;
                            self->_resolved.unavailableReason = modelError.localizedDescription;
                            [self publishStatus:modelError.localizedDescription failed:YES];
                            [self publishPlanState:0 reason:modelError.localizedDescription];
                        } else [self updateRequest:copy];
                    });
                }];
                return;
            }
        }
        NSError *error = nil;
        BOOL sessionPreparationTraceLost = NO;
        SPLowLatencyEngine *lowLatency = nil;
        SPRifeBridge *rife = nil;
        SPDistilDRBA *distil = nil;
        SPAppleLowLatencySR *appleSR = nil;
        SPAppleVideoSR *videoSR = nil;
        SPAnime4K *animeSR = nil;
        SPRealCUGAN *cuganSR = nil;
        SPArtCNNSR *artCNNSR = nil;
        if (copy.interpolationEnabled && [engine isEqualToString:@"apple.lowlatency"]) {
            NSInteger frames = (copy.rateKind == SPLiveRateFixedFPS || copy.multiplier >= 4) ? 2 : 1;
            lowLatency = [[SPLowLatencyEngine alloc] init];
            BOOL pre=[self requestUsesLowPrescale:copy width:width height:height];
            if (![lowLatency prepareLiveWidth:pre ? copy.outputWidth : width height:pre ? copy.outputHeight : height frames:frames error:&error]) lowLatency = nil;
            else copy.modelID = lowLatency.modelID;
        } else if (copy.interpolationEnabled && [engine isEqualToString:@"rife.metal"]) {
            if (!copy.modelID.length) copy.modelID = @"rife-v4.25";
            if (!copy.qualityID.length) copy.qualityID = @"balanced";
            rife = [[SPRifeBridge alloc] init];
            rife.airPerformanceEnabled = performanceEnabled;
            if (sessionJournal) [rife setKeeperSessionJournal:sessionJournal];
            if (sessionRecordingSealed) [rife sealServiceTraceForDiagnostics];
            rife.liveStreamEnabled = copy.rifeStreamEnabled;
            if (![rife prepareModelID:copy.modelID quality:copy.qualityID width:width height:height error:&error]) {
                if (sessionJournal) sessionPreparationTraceLost = YES;
                rife = nil;
            }
        } else if (copy.interpolationEnabled && [engine isEqualToString:@"distildrba.coreml"]) {
            copy.modelID = @"distildrba.v1.720p";
            distil = [[SPDistilDRBA alloc] init];
            if (![distil prepareWidth:width height:height error:&error]) distil = nil;
        }
        BOOL needsAsyncInterpolation = [self requestUsesAsyncEngine:copy];
        if (!error && [self requestUsesAsyncScale:copy]) {
            NSSize effective = SPLiveSRInputSizeForRequest(width, height, copy);
            int width = (int)effective.width, height = (int)effective.height;
            BOOL automatic = copy.outputWidth == 0 && copy.outputHeight == 0;
            BOOL autoAnime = SPLiveIsNative2xScaleEngine(copy.scaleEngine) && automatic;
            BOOL autoApple = automatic && (copy.scaleEngine == SPLiveScaleAppleLowLatencySR || copy.scaleEngine == SPLiveScaleAppleVideoSR);
            NSSize appleOutput = !autoApple ? NSZeroSize : (copy.scaleEngine == SPLiveScaleAppleVideoSR ?
                [SPAppleVideoSR automaticOutputForWidth:width height:height] : [SPAppleLowLatencySR automaticOutputForWidth:width height:height]);
            int targetWidth = autoAnime ? width * 2 : (autoApple ? (int)appleOutput.width : copy.outputWidth);
            int targetHeight = autoAnime ? height * 2 : (autoApple ? (int)appleOutput.height : copy.outputHeight);
            float scale = width > 0 ? (float)targetWidth / (float)width : 0;
            float scaleH = height > 0 ? (float)targetHeight / (float)height : 0;
            if (targetWidth < 2 || targetHeight < 2 || fabsf(scale - scaleH) > 0.0001f) {
                error = SPLiveError(37, @"苹果超分不支持当前输入尺寸或输出倍率，请缩小超分输入尺寸并选择自动输出。 ");
            } else {
                if (SPLiveIsNative2xScaleEngine(copy.scaleEngine)) {
                    if (fabsf(scale - 2.0f) > 0.0001f) error = SPLiveError(39, @"该动画超分当前使用 2× 来源尺寸。");
                    else if (copy.scaleEngine == SPLiveScaleAnime4K) { animeSR = [[SPAnime4K alloc] init]; if (![animeSR prepareWidth:width height:height error:&error]) animeSR = nil; }
                    else if (SPLiveIsArtCNNScaleEngine(copy.scaleEngine)) {
                        artCNNSR = [[SPArtCNNSR alloc] initWithResourceBundle:NSBundle.mainBundle];
                        int features = copy.scaleEngine == SPLiveScaleArtCNN32 ? 32 : 16;
                        if (![artCNNSR prepareWidth:width height:height features:features error:&error]) artCNNSR = nil;
                    } else { cuganSR = [[SPRealCUGAN alloc] init]; if (![cuganSR prepareWidth:width height:height variant:copy.scaleQualityID ?: @"none" error:&error]) cuganSR = nil; }
                } else if (copy.scaleEngine == SPLiveScaleAppleVideoSR) {
                    int integerScale = (int)roundf(scale);
                    if (fabsf(scale-integerScale) > 0.0001f) error = SPLiveError(38, @"视频超分需要支持的整数倍率。");
                    else { videoSR = [[SPAppleVideoSR alloc] init]; if (![videoSR prepareWidth:width height:height scale:integerScale error:&error]) videoSR = nil; }
                } else {
                    appleSR = [[SPAppleLowLatencySR alloc] init];
                    if (![appleSR prepareWidth:width height:height scale:scale error:&error]) appleSR = nil;
                }
            }
        }
        dispatch_async(self->_q, ^{
            if (sessionPreparationTraceLost && self->_airTraceSessionActive) ++self->_airTraceDetachDropped;
            if (token != self->_prepareToken) {
                [lowLatency invalidate];
                [self airDetachSessionServiceTrace:rife reason:@"stale-preparation"];
                [rife invalidate];
                [distil invalidate];
                [appleSR invalidate];
                [videoSR invalidate];
                [animeSR invalidate];
                [cuganSR invalidate];
                [artCNNSR invalidate];
                return;
            }
            self->_preparing = NO;
            if (error || (needsAsyncInterpolation && !lowLatency && !rife && !distil) || ([self requestUsesAsyncScale:copy] && !appleSR && !videoSR && !animeSR && !cuganSR && !artCNNSR)) {
                [self airDetachSessionServiceTrace:rife reason:@"failed-preparation"];
                [lowLatency invalidate]; [rife invalidate]; [distil invalidate]; [appleSR invalidate]; [videoSR invalidate]; [animeSR invalidate]; [cuganSR invalidate]; [artCNNSR invalidate];
#if ODF_AIR_BETA_DIAGNOSTIC
                if (SPAirBetaEnabled()) {
                    [self airBetaUsePassthrough:[NSString stringWithFormat:@"Air初始化失败，现以原帧播放：%@", error.localizedDescription ?: @"融合处理器或保活未准备成功"]];
                    return;
                }
#endif
                if (performanceEnabled) {
                    [self airPerformanceUsePassthrough:[NSString stringWithFormat:@"窗口优化初始化失败，现以原帧播放：%@", error.localizedDescription ?: @"处理器未准备成功"]];
                    return;
                }
                self->_asyncPrepareFailed = YES;
                NSString *reason = error.localizedDescription ?: @"准备失败，仍使用上一份可用计划";
                self->_resolved.unavailableReason = reason;
                [self publishStatus:reason failed:YES];
                [self publishPlanState:0 reason:reason];
                return;
            }
            [self installRequest:copy lowLatency:lowLatency rife:rife distil:distil appleSR:appleSR videoSR:videoSR animeSR:animeSR cuganSR:cuganSR artCNNSR:artCNNSR];
        });
    });
}

- (void)updateRequest:(SPLivePlanRequest *)request {
    SPLivePlanRequest *copy = [request copy];
    if (copy.scaleEngine == SPLiveScaleLanczos) copy.srInputPreset = 0;
    dispatch_async(_q, ^{
        self->_ackRequestID = copy.requestID;
        self->_ackEngineID = copy.engineID ?: @"";
        self->_ackModelID = copy.modelID ?: @"";
        // Every new request supersedes any preparation already in flight,
        // including when the new request is synchronous or is rejected.
        self->_prepareToken += 1;
        self->_preparing = NO;
        NSString *reason = nil;
        if (![self validateRequest:copy reason:&reason]) {
            self->_resolved.unavailableReason = reason;
            self->_resolved.requestedSummary = reason;
            [self publishStatus:reason failed:YES];
            [self publishPlanState:0 reason:reason];
            return;
        }
#if ODF_AIR_BETA_DIAGNOSTIC
        if (SPAirBetaEnabled()) {
            self->_airBetaRecipe = copy.interpolationEnabled ? [copy copy] : nil;
            self->_airBetaEligibilityKnown = NO;
            self->_airBetaOriginalFailure = nil;
            if (copy.interpolationEnabled) { [self startAsyncEngine:copy]; return; }
            self->_airBetaFallbackReason = @"Air实验档已关闭，当前显示原帧";
        }
#endif
        const BOOL wasPerformanceEnabled = self->_airPerformanceEnabled;
        [self airConfigurePerformanceRequest:copy];
        if (wasPerformanceEnabled) {
            [self retireEngines];
            [self airSetPerformanceMode:NO];
            self->_sessionReady = NO; self->_resolved.interpolationActive = NO;
            [self clearPendingRife]; [self clearPlaySlots];
            [self.outputPreview invalidateSharedGeometry];
            ++self->_configVersion; self->_inflightEpoch = self->_configVersion; self->_inflight = 0;
            [self beginMeasurementEpoch];
        }
        if (SPR7Passthrough()) {
            self->_request = copy;
            [self resetRateBudgetOnQueue];
            [self.outputPreview invalidateSharedGeometry];
            self->_configVersion += 1;
            self->_inflightEpoch = self->_configVersion;
            [self clearPendingRife];
            [self clearPlaySlots];
            [self resetSchedulerOnQueue];
            [self refreshResolvedOnQueue];
            self->_resolved.committed = YES;
            self->_resolved.interpolationActive = NO;
            self->_resolved.scaleActive = NO;
            self->_resolved.configVersion = self->_configVersion;
            self->_sessionReady = YES;
            [self beginMeasurementEpoch];
            [self publishStatus:@"诊断直通：增强计算已旁路" failed:NO];
            [self publishPlanState:2 reason:@"诊断直通：增强计算已旁路"];
            return;
        }
        BOOL needsEngine = copy.interpolationEnabled || copy.scaleEnabled;
        if ([self requestUsesAsyncEngine:copy] || [self requestUsesAsyncScale:copy]) {
            [self startAsyncEngine:copy];
            return;
        }
        if (self->_width < 2) {
            self->_request = copy;
            [self resetRateBudgetOnQueue];
            [self applyObservedCaptureEnvironment];
            self->_resolved.committed = !needsEngine;
            self->_sessionReady = !needsEngine;
            if (!needsEngine) {
                [self.outputPreview invalidateSharedGeometry];
                self->_configVersion += 1; self->_inflightEpoch = self->_configVersion;
                [self clearPendingRife]; [self clearPlaySlots]; [self resetSchedulerOnQueue];
            }
            [self recomputeInteractiveDelay];
            [self refreshResolvedOnQueue];
            if (!needsEngine) {
                self->_resolved.committed = YES; self->_resolved.configVersion = self->_configVersion;
                [self beginMeasurementEpoch];
                [self publishPlanState:2 reason:@"预览原画面"];
            }
            [self publishStatus:needsEngine ? @"计划已记下，等到来源画面后准备引擎" : @"预览原画面" failed:NO];
            return;
        }
        SPFRCEngine *oldEngine = self->_engine;
        SPLowLatencyEngine *oldLow = self->_lowLatency;
        SPRifeBridge *oldRife = self->_rife;
        SPDistilDRBA *oldDistil = self->_distil;
        SPAppleLowLatencySR *oldSR = self->_appleSR;
        SPAppleVideoSR *oldVideoSR = self->_videoSR;
        SPAnime4K *oldAnimeSR = self->_animeSR;
        SPRealCUGAN *oldCuganSR = self->_cuganSR;
        SPArtCNNSR *oldArtCNNSR = self->_artCNNSR;
        SPFrameBudgetMetal *oldMetal = self->_metal;
        SPSpatialScaler *oldScaler = self->_scaler;
        SPSpatialScaler *oldBaseline = self->_baselineScaler;
        SPSpatialScaler *oldInput = self->_srInputScaler;
        SPLivePlanRequest *oldRequest = self->_request;
        BOOL oldReady = self->_sessionReady;
        self->_engine = nil;
        self->_metal = nil;
        self->_scaler = nil;
        self->_baselineScaler = nil;
        self->_srInputScaler = nil;
        self->_request = copy;
        self->_sessionReady = NO;
        NSError *error = nil;
        BOOL ok = [self buildOnQueue:&error];
        if (!ok) {
            [self->_engine invalidate];
            self->_engine = oldEngine;
            self->_metal = oldMetal;
            self->_scaler = oldScaler;
            self->_baselineScaler = oldBaseline;
            self->_srInputScaler = oldInput;
            self->_request = oldRequest;
            self->_sessionReady = oldReady;
            self->_resolved.committed = oldReady;
            self->_resolved.unavailableReason = error.localizedDescription ?: @"准备失败，仍使用上一份可用计划";
            [self publishStatus:self->_resolved.unavailableReason failed:YES];
            [self publishPlanState:0 reason:self->_resolved.unavailableReason];
            return;
        }
        self->_sourceSizeConstraintFailed = NO;
        [oldEngine invalidate];
        [oldLow invalidate];
        [self airRetireResidentKeeperForBridge:oldRife reason:@"plan_replaced"];
        [oldRife invalidate];
        [oldDistil invalidate];
        [oldSR invalidate];
        [oldVideoSR invalidate];
        [oldAnimeSR invalidate];
        [oldCuganSR invalidate];
        [oldArtCNNSR invalidate];
        [self applyObservedCaptureEnvironment];
        [self resetRateBudgetOnQueue];
        // Pending pairs pin source buffers and belong to the old plan.
        // Cancel only after a successful replacement so rollback keeps them.
        [self clearPendingRife];
        [self trimHeld];
        self->_lowLatency = nil;
        self->_rife = nil;
        self->_distil = nil;
        self->_appleSR = nil;
        self->_videoSR = nil;
        self->_animeSR = nil;
        self->_cuganSR = nil;
        self->_artCNNSR = nil;
        [self resetAsyncScaleOnQueue];
        [self.outputPreview invalidateSharedGeometry];
        self->_configVersion += 1;
        self->_inflightEpoch = self->_configVersion;
        self->_inflight = 0;
        self->_havePair = NO;
        [self clearPlaySlots];
        [self resetSchedulerOnQueue];
        [self recomputeInteractiveDelay];
        [self refreshResolvedOnQueue];
        self->_resolved.committed = YES;
        self->_resolved.configVersion = self->_configVersion;
        [self beginMeasurementEpoch];
        if (self->_width < 2 && needsEngine) {
            [self publishStatus:@"计划已接受，等到来源画面后准备引擎" failed:NO];
            [self publishPlanState:1 reason:@"计划已接受，等到来源画面后准备引擎"];
        } else {
            [self publishPlanState:2 reason:self->_resolved.activeSummary ?: @"已生效"];
        }
    });
}

- (void)setViewMode:(SPLiveViewMode)mode {
    dispatch_async(_q, ^{
        if (self->_request.viewMode != mode) { self->_fpsMeter.resetOutput(); self->_fpsObservationEpoch += 1; [self.outputPreview invalidateSharedGeometry]; }
        self->_request.viewMode = mode;
        if (!self->_lastEnhanced && !self->_lastOriginal) return;
        [self showPair:self->_lastEnhanced original:self->_lastOriginal pts:self->_lastRedrawPts
             synthetic:self->_lastSynthetic captureHost:0 geometryHost:self->_lastRedrawGeometryHost frameID:0 presentationHost:self->_lastRedrawTargetHost redraw:YES];
    });
}

- (void)resetFPSObservations {
    dispatch_async(_q, ^{ self->_fpsMeter.reset(); self->_fpsObservationEpoch += 1; [self suspendRateBudgetOnQueue]; });
}

- (void)discardQueuedStateOnQueue {
    [self resetRateBudgetOnQueue];
    _fpsMeter.reset();
    _pumpedCaptureMeter.reset();
    _fpsObservationEpoch += 1;
    [self clearPendingRife];
    _rifeSlowMode = NO;
    _lowPrescaleSlowMode = NO;
    [self resetAsyncScaleOnQueue];
    [self clearPlaySlots];
    self->_pending.clear();
    self->_marks.clear();
    [self->_geometryInputs removeAllObjects];
    [self->_geometryInputOrder removeAllObjects];
    self->_haveAnchor = NO;
    self->_haveLastPts = NO;
    self->_havePreviousSourcePts = NO;
    self->_airRobustSourceLeadHistory.reset();
    self->_previousSourceIdentity = 0;
    self->_processedSequence = 0;
    self->_lastProcessedHost = 0;
    self->_lastDrawablePresentedHost = 0;
    self->_havePair = NO;
    self->_haveLuma = NO;
    self->_lastPairB = 0;
    if (self->_clock) {
        if (self->_measurementTrace) {
            auto event = [self airMeasurementEvent:spAirMeasurement::Kind::timerCancel];
            event.beginHostTicks = event.endHostTicks = SPHostNow();
            self->_measurementTrace->append(event);
        }
        dispatch_source_cancel(self->_clock);
        self->_clock = nil;
    }
    {
        std::lock_guard<std::mutex> lock(self->_inMx);
        while (!self->_inbound.empty()) {
            CVPixelBufferRelease(self->_inbound.front().buffer);
            self->_inbound.pop_front();
        }
        self->_copiedMeter.reset(); self->_copiedGeneration = 0;
    }
    for (auto &entry : self->_held) {
        if (entry.second.source) CVPixelBufferRelease(entry.second.source);
        if (entry.second.yuv) CVPixelBufferRelease(entry.second.yuv);
        if (entry.second.lowPrescaled) CVPixelBufferRelease(entry.second.lowPrescaled);
    }
    self->_held.clear();
    self->_inflightEpoch += 1;
    self->_inflight = 0;
    [self resetSchedulerOnQueue];
}

- (void)adoptSourceGeneration:(uint64_t)generation {
    dispatch_async(_q, ^{
        if (generation < self->_sourceGeneration) return;
        BOOL same = generation == self->_sourceGeneration;
        if (same && !self->_stopped) {
            [self->_preview setGeneration:generation];
            [self->_outputPreview setGeneration:generation];
            return;
        }
        [self airRetireResidentKeeperForBridge:self->_rife reason:@"source_generation_changed"];
#if ODF_AIR_BETA_DIAGNOSTIC
        if (SPAirBetaEnabled()) {
            [self->_rife invalidate]; self->_rife = nil;
            self->_sessionReady = NO; self->_resolved.interpolationActive = NO;
            self->_sourceWidth = 0; self->_sourceHeight = 0;
            self->_airBetaFormatKnown = NO; self->_airBetaEligibilityKnown = NO;
            self->_airBetaFormatDescription = nil;
            self->_airBetaFallbackReason = @"等待新来源的实际采集格式，当前显示原帧";
        }
#endif
        if (self->_airPerformanceCandidate || self->_airPerformanceEnabled) {
            [self->_rife invalidate]; self->_rife = nil;
            [self airSetPerformanceMode:NO];
            self->_sessionReady = NO; self->_resolved.interpolationActive = NO;
            self->_sourceWidth = 0; self->_sourceHeight = 0;
            self->_airPerformanceFormatKnown = NO; self->_airPerformanceEligibilityKnown = NO;
            self->_airActualSourceKind = SPLiveCaptureSourceKindUnknown;
            self->_airPerformanceRequested = NO;
            if (self->_airPerformanceRecipe) self->_request = [self->_airPerformanceRecipe copy];
        }
        self->_prepareToken += 1;
        self->_preparing = NO;
        self->_asyncPrepareFailed = NO;
        if ([self requestUsesAsyncScale:self->_request] && (self->_appleSR || self->_videoSR || self->_animeSR || self->_cuganSR || self->_artCNNSR)) {
            [self->_appleSR invalidate];
            [self->_videoSR invalidate];
            [self->_animeSR invalidate];
            [self->_cuganSR invalidate];
            [self->_artCNNSR invalidate];
            self->_appleSR = nil;
            self->_videoSR = nil;
            self->_animeSR = nil;
            self->_cuganSR = nil;
            self->_artCNNSR = nil;
            self->_sessionReady = NO;
        }
        self->_sourceGeneration = generation;
        self->_processedSequence = 0;
        self->_lastProcessedHost = 0;
        self->_lastDrawablePresentedHost = 0;
        if (self->_lastEnhanced) { CVPixelBufferRelease(self->_lastEnhanced); self->_lastEnhanced = nullptr; }
        if (self->_lastOriginal) { CVPixelBufferRelease(self->_lastOriginal); self->_lastOriginal = nullptr; }
        self->_stopped = NO;
        self->_stoppedDrops = 0;
        self->_generationDrops = 0;
        [self discardQueuedStateOnQueue];
        [self beginMeasurementEpoch];
        [self->_preview setGeneration:generation];
        [self->_outputPreview setGeneration:generation];
        if (!self->_sessionReady) [self publishStatus:@"来源已接入" failed:NO];
    });
}

- (void)resetSchedulerOnQueue {
    sp::SPRateRequest rate;
    BOOL valid = YES;
    if (!_request.interpolationEnabled) {
        _resolved.interpolationActive = NO;
        return;
    }
    if (_request.rateKind == SPLiveRateMultiplier) {
        rate.kind = sp::SPRateKind::Multiplier;
        if ([self rateBudgetEnabled] && _rateBudget.snapshot().requestedMultiplier != _request.multiplier)
            [self resetRateBudgetOnQueue];
        // X1 uses the existing phase-skip path; never send an invalid X1
        // request to the scheduler.
        rate.multiplier = [self rateBudgetEnabled] && _effectiveMultiplier >= 2
            ? _effectiveMultiplier : (int)_request.multiplier;
        _resolved.targetNumerator = _request.multiplier;
        _resolved.targetDenominator = 1;
    } else {
        rate.kind = sp::SPRateKind::FixedFPS;
        rate.fps = sp::spMake(_request.fpsNumerator, _request.fpsDenominator);
        rate.reuseSources = [self usesFixedSourceReuse];
        _resolved.targetNumerator = _request.fpsNumerator;
        _resolved.targetDenominator = _request.fpsDenominator;
        if (_request.fpsNumerator <= 0 || _request.fpsDenominator <= 0) valid = NO;
    }
    if (!valid || !_scheduler.reset(rate, _configVersion, sp::spMake(1, 2))) {
        _resolved.unavailableReason = @"帧率请求无效";
        _resolved.interpolationActive = NO;
        [self publishStatus:@"帧率请求无效" failed:YES];
    }
}

- (void)refreshResolvedOnQueue {
    _resolved.configVersion = _configVersion;
    _resolved.colorPath = @"sdr.bt709.8bit";
    NSString *engine = _request.engineID.length ? _request.engineID : @"apple.frc";
    _resolved.engineID = engine;
    if (_request.modelID.length) _resolved.modelID = _request.modelID;
    else if ([engine isEqualToString:@"apple.frc"]) _resolved.modelID = _request.quality == SPFRCQualityHigh ? @"vt.frc.quality" : @"vt.frc.normal";
    switch (_request.scaleEngine) {
        case SPLiveScaleArtCNN16: _resolved.scaleEngineID = @"artcnn.c4f16"; break;
        case SPLiveScaleArtCNN32: _resolved.scaleEngineID = @"artcnn.c4f32"; break;
        case SPLiveScaleRealCUGAN: _resolved.scaleEngineID = @"realcugan"; break;
        case SPLiveScaleAnime4K: _resolved.scaleEngineID = @"anime4k"; break;
        case SPLiveScaleAppleVideoSR: _resolved.scaleEngineID = @"apple.video-sr"; break;
        case SPLiveScaleAppleLowLatencySR: _resolved.scaleEngineID = @"apple.low-sr"; break;
        case SPLiveScaleMetalFX: _resolved.scaleEngineID = @"metalfx.spatial"; break;
        default: _resolved.scaleEngineID = @"lanczos"; break;
    }
    _resolved.scaleQualityID = _request.scaleEngine == SPLiveScaleRealCUGAN ? (_request.scaleQualityID ?: @"none") : @"";
    BOOL automatic = _request.scaleEnabled && _request.outputWidth == 0 && _request.outputHeight == 0;
    BOOL autoAnime = automatic && SPLiveIsNative2xScaleEngine(_request.scaleEngine);
    NSSize effective = SPLiveSRInputSizeForRequest(_width, _height, _request);
    BOOL autoApple = automatic && (_request.scaleEngine == SPLiveScaleAppleLowLatencySR || _request.scaleEngine == SPLiveScaleAppleVideoSR);
    NSSize appleOutput = !autoApple ? NSZeroSize : (_request.scaleEngine == SPLiveScaleAppleVideoSR ?
        [SPAppleVideoSR automaticOutputForWidth:(int)effective.width height:(int)effective.height] : [SPAppleLowLatencySR automaticOutputForWidth:(int)effective.width height:(int)effective.height]);
    _resolved.outputWidth = autoAnime ? (int)effective.width * 2 : (autoApple ? (int)appleOutput.width : (_request.scaleEnabled ? _request.outputWidth : _width));
    _resolved.outputHeight = autoAnime ? (int)effective.height * 2 : (autoApple ? (int)appleOutput.height : (_request.scaleEnabled ? _request.outputHeight : _height));
    double target = 0;
    if (_request.interpolationEnabled && _request.rateKind == SPLiveRateFixedFPS && _request.fpsDenominator > 0) {
        target = (double)_request.fpsNumerator / (double)_request.fpsDenominator;
    } else if (_request.interpolationEnabled && _request.multiplier > 1) {
        double source = _fpsMeter.inputRate((int64_t)(CACurrentMediaTime() * 1e9));
        if (source <= 0 && _haveInterval && _intervalHost > 0) {
            double seconds = (double)SPHostToNs(_intervalHost) / 1e9;
            if (seconds > 0.001) source = 1.0 / seconds;
        }
        if (source > 0) target = source * (double)_request.multiplier;
    }
    _resolved.presentationLimited = target > 1 && _request.displayRefreshHz > 1 && target > _request.displayRefreshHz + 1.0;
    if (!_request.interpolationEnabled && !_request.scaleEnabled) {
        _resolved.interpolationActive = NO;
        _resolved.scaleActive = NO;
        _resolved.unavailableReason = @"";
        _sessionReady = YES;
        [self publishStatus:@"预览原画面" failed:NO];
    }
    NSString *requestedRate = _request.rateKind == SPLiveRateMultiplier
        ? [NSString stringWithFormat:@"X%ld", (long)_request.multiplier]
        : [NSString stringWithFormat:@"%lld/%lld", _request.fpsNumerator, _request.fpsDenominator];
    _resolved.requestedSummary = [NSString stringWithFormat:@"请求 %@ %@", requestedRate,
                                  _request.interpolationEnabled ? @"插帧" : @"不插帧"];
    _resolved.activeSummary = _resolved.committed
        ? [NSString stringWithFormat:@"生效 v%llu %@", (unsigned long long)_configVersion, requestedRate]
        : @"尚未生效";
}

- (uint64_t)resumeSource {
    __block uint64_t value = 1;
    dispatch_sync(_q, ^{ value = self->_sourceGeneration; });
    [self adoptSourceGeneration:value];
    dispatch_sync(_q, ^{});
    return value;
}

- (void)stop {
    void (^stopOnQueue)(void) = ^{
        [self airRetireResidentKeeperForBridge:self->_rife reason:@"plan_stopped"];
        self->_stopped = YES;
        self->_r9FRCBudgetGate.reset();
        self->_r9RequiredBudgetMs = 0; self->_r9AllowedBudgetMs = 0;
        self->_r9GeneratedFPS = -1; self->_r9OnTimeSyntheticFPS = -1; self->_r9RateHost = 0;
        [self.outputPreview invalidateSharedGeometry];
        self->_configVersion += 1;
        self->_inflightEpoch = self->_configVersion;
        self->_sessionReady = NO;
        self->_prepareToken += 1;
        self->_preparing = NO;
        self->_request.interpolationEnabled = NO;
        self->_request.scaleEnabled = NO;
        [self->_preview setGeneration:0];
        [self->_outputPreview setGeneration:0];
        [self->_engine invalidate];
        self->_engine = nil;
        [self->_lowLatency invalidate];
        self->_lowLatency = nil;
        [self->_rife invalidate];
        self->_rife = nil;
        [self->_distil invalidate];
        self->_distil = nil;
        [self->_appleSR invalidate];
        [self->_videoSR invalidate];
        [self->_animeSR invalidate];
        [self->_cuganSR invalidate];
        [self->_artCNNSR invalidate];
        self->_appleSR = nil;
        self->_videoSR = nil;
        self->_animeSR = nil;
        self->_cuganSR = nil;
        self->_artCNNSR = nil;
        self->_scaler = nil;
        self->_baselineScaler = nil;
        self->_srInputScaler = nil;
        self->_metal = nil;
        [self discardQueuedStateOnQueue];
        { std::lock_guard<std::mutex> lock(self->_rawCadenceMutex); self->_nativeCadence.reset("stopped"); }
        if (self->_lastEnhanced) { CVPixelBufferRelease(self->_lastEnhanced); self->_lastEnhanced = nullptr; }
        if (self->_lastOriginal) { CVPixelBufferRelease(self->_lastOriginal); self->_lastOriginal = nullptr; }
    };
    if (dispatch_get_specific(SPLiveQueueKey) == (__bridge void *)self) stopOnQueue();
    else dispatch_sync(_q, stopOnQueue);
    [self publishStatus:@"已停止" failed:NO];
}

// Test-only entry points for the production copier/processor ownership contract.
// They use the same serial queue and finishJob reclamation as real completions.
- (NSDictionary *)ownedContractSnapshotOnQueue {
        size_t source=0, synthetic=0;
        for (const auto &item : _testPlayout) { if (item.second) synthetic++; else source++; }
        return @{ @"processed": @(_processedSequence), @"held": @(_held.size()), @"slots": @(_slots.size()),
            @"playoutSource": @(source), @"playoutSynthetic": @(synthetic), @"redrawHeld": @(_lastEnhanced != nullptr),
            @"nativeBudgetActive": @([self nativeBudgetForSnapshot:[self nativeCadenceSnapshot]]), @"delayMs": @((double)SPHostToNs(_delayHost)/1e6),
            @"peakSlots": @(_peakSlots), @"slotCap": @([self slotCap]), @"sampleHost": @(SPHostNow()) };
}

// Deterministic cancellation evidence, using the same serial queue, real
// finish/cancel/release functions and CVPixelBuffer leases as live probes.
// This hook is called only by the isolated contract executable.
- (NSDictionary<NSString *, id> *)ownedContractRateBudgetProbeCancellation:(NSString *)scenario {
    if (![@[@"current", @"config", @"generation", @"clock", @"stopped", @"queued"] containsObject:scenario])
        return @{ @"setup": @NO, @"error": @"unknown probe contract scenario" };
    __block NSDictionary *result;
    dispatch_sync(_q, ^{
        // Each test owns a fresh processor. Refuse to disturb a live session.
        if (!self->_held.empty() || self->_inflight || self->_rateBudgetProbeInFlightToken ||
            !self->_rateBudgetProbePending.empty()) {
            result = @{ @"setup": @NO, @"error": @"probe contract requires an idle fresh processor" };
            return;
        }
        self->_request.interpolationEnabled = YES;
        self->_request.engineID = @"rife.metal";
        self->_request.rateKind = SPLiveRateMultiplier;
        self->_request.multiplier = 2;
        self->_request.displayRefreshHz = 120;
        self->_sourceGeneration = 21;
        self->_configVersion = 31;
        self->_clockEpoch = 41;
        self->_measurementEpoch = 51;
        self->_inflightEpoch = 61;
        self->_rife = [[SPRifeBridge alloc] init]; // Unprepared: no model or GPU work.
        self->_sessionReady = YES;
        self->_stopped = NO;
        self->_nativeBudgetActive = NO;
        self->_rateBudget.reset(2);
        for (int tick = 0; tick <= 51; ++tick)
            self->_rateBudget.update({tick / 10.0, 60, 2, 40, 100, 100, 16});
        self->_effectiveMultiplier = self->_rateBudget.snapshot().effectiveMultiplier;
        self->_rateBudgetPassthrough = self->_effectiveMultiplier == 1;
        self->_rateBudgetProbeMedianMs = 40;
        self->_fpsMeter.reset();
        int64_t nowNs = (int64_t)(CACurrentMediaTime() * 1e9);
        self->_fpsMeter.input(0, nowNs - 17000000);
        self->_fpsMeter.input(16666667, nowNs - 1);

        // The release callback is a lifetime observation, not a retain-count
        // guess. A shared counter remains valid even in an intentionally broken
        // mutation run where a retained source outlives the test hook.
        auto releases = std::make_shared<std::atomic<int>>(0);
        int buffersCreated = 0;
        auto buffer = [&]() -> CVPixelBufferRef {
            void *bytes = calloc(1, 64);
            if (!bytes) return nullptr;
            auto counter = new std::shared_ptr<std::atomic<int>>(releases);
            CVPixelBufferRef value = nullptr;
            CVReturn status = CVPixelBufferCreateWithBytes(kCFAllocatorDefault, 4, 4,
                kCVPixelFormatType_32BGRA, bytes, 16,
                [](void *context, const void *address) {
                    auto counter = static_cast<std::shared_ptr<std::atomic<int>> *>(context);
                    (*counter)->fetch_add(1);
                    delete counter;
                    free(const_cast<void *>(address));
                }, counter, nullptr, &value);
            if (status != kCVReturnSuccess) { delete counter; free(bytes); return nullptr; }
            ++buffersCreated;
            return value;
        };
        for (uint64_t identity : {uint64_t(101), uint64_t(102)}) {
            SPLiveHeld held;
            held.source = buffer();
            held.pins = 1;
            self->_held.emplace(identity, held);
        }
        if (!self->_held[101].source || !self->_held[102].source) {
            for (auto &entry : self->_held) if (entry.second.source) CVPixelBufferRelease(entry.second.source);
            self->_held.clear();
            result = @{ @"setup": @NO, @"error": @"source buffer allocation" };
            return;
        }
        self->_rateBudgetProbeRound = 71;
        self->_rateBudgetProbeActive = YES;
        self->_rateBudgetProbeCollected = 4;
        // Make this the last measured group. Without the invalidation guard,
        // its 6 ms result changes the median from 40 to 5 ms and fails the test.
        self->_rateBudgetProbeTaskCosts = {4, 5};
        self->_rateBudgetProbePhaseCosts = {4, 5};
        SPLiveJob *job = new SPLiveJob();
        job->diagnosticID = 81;
        job->generation = self->_sourceGeneration;
        job->configVersion = self->_configVersion;
        job->clockEpoch = self->_clockEpoch;
        job->measurementEpoch = self->_measurementEpoch;
        job->inflightEpoch = self->_inflightEpoch;
        job->probeRound = self->_rateBudgetProbeRound;
        job->probeIndex = 3;
        job->count = 1;
        job->frameA = 101;
        job->frameB = 102;
        job->probeSourceA = CVPixelBufferRetain(self->_held[101].source);
        job->probeSourceB = CVPixelBufferRetain(self->_held[102].source);
        const int inflightBaseline = self->_inflight;
        const double phaseCostBefore = self->_rateBudget.snapshot().phaseCostMs;
        const double probeMedianBefore = self->_rateBudgetProbeMedianMs;
        BOOL setup = [self rateBudgetProbeEligible] && phaseCostBefore == 40;
        int pinsBefore = 0;
        for (const auto &entry : self->_held) pinsBefore += entry.second.pins;
        BOOL oldHeldRemoved = NO;

        if ([scenario isEqualToString:@"queued"]) {
            self->_rateBudgetProbePending.push_back(job);
            [self cancelRateBudgetProbe];
        } else {
            self->_rateBudgetProbeInFlightToken = job->diagnosticID;
            self->_rateBudgetProbeInFlightEpoch = self->_inflightEpoch;
            ++self->_inflight;
            if ([scenario isEqualToString:@"config"]) ++self->_configVersion;
            if ([scenario isEqualToString:@"clock"]) ++self->_clockEpoch;
            if ([scenario isEqualToString:@"stopped"]) self->_stopped = YES;
            if ([scenario isEqualToString:@"generation"]) {
                ++self->_sourceGeneration;
                // A real source replacement destroys the old held map. The
                // submitted job alone now retains its old-generation sources.
                // Reuse the identities with new buffers to test isolation.
                for (auto &entry : self->_held) CVPixelBufferRelease(entry.second.source);
                self->_held.clear();
                oldHeldRemoved = YES;
                for (uint64_t identity : {uint64_t(101), uint64_t(102)}) {
                    SPLiveHeld held;
                    held.source = buffer();
                    held.pins = 1;
                    self->_held.emplace(identity, held);
                }
                setup = setup && self->_held[101].source && self->_held[102].source;
            }
            // Only count/latency metadata matters here; no output is sampled or
            // presented. Source ownership above is backed by real pixel buffers.
            NSArray<SPOwnedPixelBuffer *> *outputs = (id)@[[NSObject new]];
            [self finishRateBudgetProbe:job outputs:outputs latency:0.006 error:nil];
        }
        int pinsAfter = 0;
        for (const auto &entry : self->_held) pinsAfter += entry.second.pins;
        int releasedAfterCallback = releases->load();
        int inflightAfter = self->_inflight;
        uint64_t tokenAfter = self->_rateBudgetProbeInFlightToken;
        BOOL activeAfter = self->_rateBudgetProbeActive;
        size_t pendingAfter = self->_rateBudgetProbePending.size();
        double phaseCostAfter = self->_rateBudget.snapshot().phaseCostMs;
        double probeMedianAfter = self->_rateBudgetProbeMedianMs;
        for (auto &entry : self->_held) if (entry.second.source) CVPixelBufferRelease(entry.second.source);
        self->_held.clear();
        result = @{ @"setup": @(setup), @"scenario": scenario,
            @"inflightBaseline": @(inflightBaseline), @"inflightAfter": @(inflightAfter),
            @"tokenAfter": @(tokenAfter), @"activeAfter": @(activeAfter), @"pendingAfter": @(pendingAfter),
            @"pinsBefore": @(pinsBefore), @"pinsAfter": @(pinsAfter), @"oldHeldRemoved": @(oldHeldRemoved),
            @"phaseCostBefore": @(phaseCostBefore), @"phaseCostAfter": @(phaseCostAfter),
            @"probeMedianBefore": @(probeMedianBefore), @"probeMedianAfter": @(probeMedianAfter),
            @"releasedAfterCallback": @(releasedAfterCallback), @"releasedAfterCleanup": @(releases->load()),
            @"buffersCreated": @(buffersCreated) };
        self->_rife = nil;
        self->_sessionReady = NO;
        self->_request.interpolationEnabled = NO;
    });
    return result;
}

- (NSDictionary *)ownedContractFence {
    __block NSDictionary *value;
    dispatch_sync(_q, ^{ value=[self ownedContractSnapshotOnQueue]; });
    return value;
}

- (void)ownedContractAsyncFence:(void (^)(NSDictionary *))completion {
    dispatch_async(_q, ^{ completion([self ownedContractSnapshotOnQueue]); });
}

- (void)ownedContractConfigureNativeWidth:(int)width height:(int)height {
    dispatch_sync(_q, ^{
        self->_request.interpolationEnabled=YES; self->_request.engineID=@"rife.metal";
        self->_request.rateKind=SPLiveRateMultiplier; self->_request.multiplier=2; self->_request.displayRefreshHz=120;
        self->_request.captureCapFPS=0; self->_request.scaleEnabled=NO;
        self->_width=width; self->_height=height; self->_resolved.outputWidth=width; self->_resolved.outputHeight=height;
        self->_rife=[[SPRifeBridge alloc] init]; self->_sessionReady=YES; self->_resolved.committed=YES; self->_resolved.interpolationActive=YES;
        self->_testCapturePlayout=YES;
        [self setRawCadenceRefreshHz:120 captureLimit:0 displayID:1];
        [self resetSchedulerOnQueue];
    });
}
- (uint64_t)ownedContractPinOldest {
    __block uint64_t identity = 0;
    dispatch_sync(_q, ^{
        for (const auto &entry : self->_held) if (!identity || entry.first < identity) identity = entry.first;
        auto found = self->_held.find(identity); if (found != self->_held.end()) found->second.pins++;
    });
    return identity;
}
- (int)ownedContractByteForIdentity:(uint64_t)identity {
    __block int value = -1;
    dispatch_sync(_q, ^{
        auto found = self->_held.find(identity);
        if (found == self->_held.end() || !found->second.source) return;
        CVPixelBufferRef b = found->second.source;
        CVPixelBufferLockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
        auto p = CVPixelBufferIsPlanar(b) ? CVPixelBufferGetBaseAddressOfPlane(b, 0) : CVPixelBufferGetBaseAddress(b);
        if (p) value = *(const unsigned char *)p;
        CVPixelBufferUnlockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    });
    return value;
}
- (BOOL)ownedContractInstallRedrawForIdentity:(uint64_t)identity {
    __block BOOL installed = NO;
    dispatch_sync(_q, ^{
        auto found = self->_held.find(identity);
        if (found == self->_held.end() || !found->second.source) return;
        if (self->_lastEnhanced) CVPixelBufferRelease(self->_lastEnhanced);
        self->_lastEnhanced = CVPixelBufferRetain(found->second.source);
        installed = YES;
    });
    return installed;
}
- (void)ownedContractStabilizePlayout {
    dispatch_sync(_q, ^{
        [self clearPlaySlots];
        if (self->_clock) {
            if (self->_measurementTrace) {
                auto event = [self airMeasurementEvent:spAirMeasurement::Kind::timerCancel];
                event.beginHostTicks = event.endHostTicks = SPHostNow();
                self->_measurementTrace->append(event);
            }
            dispatch_source_cancel(self->_clock); self->_clock = nil;
        }
        if (self->_lastEnhanced) { CVPixelBufferRelease(self->_lastEnhanced); self->_lastEnhanced = nullptr; }
        if (self->_lastOriginal) { CVPixelBufferRelease(self->_lastOriginal); self->_lastOriginal = nullptr; }
    });
}
- (uint64_t)ownedContractRedrawIdentity {
    __block uint64_t value;
    dispatch_sync(_q, ^{ value = (uint64_t)(uintptr_t)self->_lastEnhanced; });
    return value;
}
- (void)ownedContractInstallRedrawBuffer:(CVPixelBufferRef)buffer {
    dispatch_sync(_q, ^{
        if (self->_lastEnhanced) CVPixelBufferRelease(self->_lastEnhanced);
        self->_lastEnhanced = buffer ? CVPixelBufferRetain(buffer) : nullptr;
    });
}
- (void)ownedContractCompleteIdentity:(uint64_t)identity stale:(BOOL)stale {
    dispatch_sync(_q, ^{
        SPLiveJob *job = new SPLiveJob();
        job->frameA = identity; job->frameB = 0; job->generation = self->_sourceGeneration;
        job->configVersion = stale ? self->_configVersion + 1 : self->_configVersion;
        job->clockEpoch = self->_clockEpoch; job->inflightEpoch = self->_inflightEpoch;
        job->count = 1;
        [self finishJob:job token:0 outputs:@[] latency:0 error:stale ? nil : SPLiveError(99, @"contract error")];
    });
}

- (void)ownedContractQueueCurrentThenStalePressure {
    dispatch_sync(_q, ^{
        [self noteCapturePoolPressureForGeneration:self->_sourceGeneration];
        [self noteCapturePoolPressureForGeneration:self->_sourceGeneration - 1];
    });
}

- (void)noteCapturePoolPressureForGeneration:(uint64_t)generation {
    {
        std::lock_guard<std::mutex> lock(_capturePressureMutex);
        // Generations are monotonic; a delayed old callback cannot overwrite a
        // pending current-source notification while the serial queue is busy.
        _capturePressureGeneration = std::max(_capturePressureGeneration, generation);
        if (_capturePressureQueued) return;
        _capturePressureQueued = true;
    }
    dispatch_async(_q, ^{
        uint64_t requested;
        {
            std::lock_guard<std::mutex> lock(self->_capturePressureMutex);
            requested = self->_capturePressureGeneration;
            self->_capturePressureGeneration = 0;
            self->_capturePressureQueued = false;
        }
        if (self->_stopped || requested != self->_sourceGeneration) return;
        self->_capturePressureEvents++;
        [self trimHeld];
        [self->_rife relieveCapturePressure];
        // Redraw copies may alias an owned capture buffer (not SCK's borrowed
        // buffer). The current drawable remains visible; freeing these idle
        // redraw references leaves capture headroom. Active GPU jobs retain
        // their own references and are never forcibly released here.
        CFStringRef ticket = CFSTR("app.openduckframe.capture.poolTicket");
        if (self->_lastEnhanced && CVBufferGetAttachment(self->_lastEnhanced, ticket, NULL)) {
            CVPixelBufferRelease(self->_lastEnhanced); self->_lastEnhanced = nullptr;
        }
        if (self->_lastOriginal && CVBufferGetAttachment(self->_lastOriginal, ticket, NULL)) {
            CVPixelBufferRelease(self->_lastOriginal); self->_lastOriginal = nullptr;
        }
    });
}

- (void)noteCaptureStatus:(NSInteger)statusCode {
    dispatch_async(_q, ^{
        self->_captured += 1;
        self->_windowCallbacks += 1;
        if (statusCode == 1) self->_idle += 1;
        else if (statusCode == 2) {
            self->_interrupted += 1;
            [self publishStatus:@"来源中断" failed:YES];
        } else self->_completeFrames += 1;
        int64_t elapsed = SPHostToNs(SPHostNow() - self->_windowStart);
        if (elapsed > 1000000000LL) {
            self->_windowStart = SPHostNow();
            self->_windowCallbacks = 0;
            self->_windowChanged = 0;
        }
        [self publishStats];
    });
}

- (void)observeCaptureGeometry:(NSDictionary *)geometry generation:(uint64_t)generation {
    [self.outputPreview observeSourceGeometry:geometry generation:generation];
}

- (NSDictionary *)inputGeometrySnapshot { return [self.outputPreview sharedGeometrySnapshot] ?: @{ @"valid": @NO }; }
- (NSDictionary<NSString *, NSNumber *> *)mapQuartzOutputPoint:(CGPoint)point geometryVersion:(uint64_t)version clamp:(BOOL)clamp {
    return [self.outputPreview mapQuartzOutputPoint:point geometryVersion:version clamp:clamp];
}

- (void)noteRawCapturePTSNum:(int64_t)ptsNum ptsDen:(int64_t)ptsDen host:(int64_t)host
                       width:(int)width height:(int)height generation:(uint64_t)generation {
    __int128 ptsNs = ptsDen > 0 ? (__int128)ptsNum * 1000000000 / ptsDen : 0;
    bool valid = ptsDen > 0 && ptsNs >= INT64_MIN && ptsNs <= INT64_MAX;
    std::lock_guard<std::mutex> lock(_rawCadenceMutex);
    _nativeCadence.observe(valid ? (int64_t)ptsNs : 0, SPHostToNs(host), generation, width, height, valid);
}

- (void)setRawCadenceRefreshHz:(double)refreshHz captureLimit:(int)captureLimit displayID:(uint64_t)displayID {
    std::lock_guard<std::mutex> lock(_rawCadenceMutex);
    _nativeCadence.configure(refreshHz, captureLimit, displayID);
}

- (void)updateDisplayRefreshHz:(double)refreshHz {
    dispatch_async(_q, ^{
#if ODF_AIR_BETA_DIAGNOSTIC
        if (SPAirBetaEnabled()) self->_airBetaObservedRefreshHz = refreshHz;
#endif
        if (refreshHz <= 1 || self->_request.displayRefreshHz == refreshHz) return;
        self->_request.displayRefreshHz = refreshHz;
        if (self->_airPerformanceRecipe && !self->_stopped) {
            self->_airPerformanceRecipe.displayRefreshHz = refreshHz;
            self->_airPerformanceEligibilityKnown = NO;
            [self startAsyncEngine:self->_airPerformanceRecipe];
        }
#if ODF_AIR_BETA_DIAGNOSTIC
        if (SPAirBetaEnabled() && self->_airBetaRecipe && !self->_stopped) [self startAsyncEngine:self->_airBetaRecipe];
#endif
        [self refreshResolvedOnQueue];
        [self publishStats];
    });
}

- (void)updateCaptureLimitFPS:(int)captureLimit {
    dispatch_async(_q, ^{
        self->_request.captureCapFPS = captureLimit;
        [self publishStats];
    });
}

- (void)pushPixelBuffer:(CVPixelBufferRef)buffer
                 ptsNum:(int64_t)ptsNum
                 ptsDen:(int64_t)ptsDen
                   host:(int64_t)host
             generation:(uint64_t)generation {
    [self pushPixelBuffer:buffer ptsNum:ptsNum ptsDen:ptsDen host:host readyHost:host generation:generation];
}

- (void)pushPixelBuffer:(CVPixelBufferRef)buffer
                 ptsNum:(int64_t)ptsNum
                 ptsDen:(int64_t)ptsDen
                   host:(int64_t)host
              readyHost:(int64_t)readyHost
             generation:(uint64_t)generation {
    if (!buffer || ptsDen == 0) return;
    CVPixelBufferRetain(buffer);
    std::lock_guard<std::mutex> lock(_inMx);
    if (generation >= _copiedGeneration) {
        if (generation != _copiedGeneration) { _copiedMeter.reset(); _copiedGeneration = generation; }
        __int128 ptsNs = (__int128)ptsNum * 1000000000 / ptsDen;
        if (ptsDen > 0 && ptsNs >= INT64_MIN && ptsNs <= INT64_MAX)
            _copiedMeter.input((int64_t)ptsNs, SPHostToNs(host));
        ++_copiedFrames;
    }
    const NSUInteger cap = [self inboundCap];
    if (_inbound.size() >= cap) {
        CVPixelBufferRelease(_inbound.front().buffer);
        _inbound.pop_front();
        _queueDrops += 1;
        _epochQueueDrops += 1;
    }
    SPLiveInbound item;
    item.buffer = buffer;
    item.ptsNum = ptsNum;
    item.ptsDen = ptsDen;
    item.host = host;
    item.readyHost = readyHost > 0 ? readyHost : host;
    item.generation = generation;
    _inbound.push_back(item);
    if (!_pumpQueued) {
        _pumpQueued = YES;
        dispatch_async(_q, ^{ [self pump]; });
    }
}

- (CVPixelBufferRef)transfer:(CVPixelBufferRef)source format:(OSType)format {
    int64_t began = 0, ended = 0;
    OSStatus status = noErr;
    CVPixelBufferRef result = SPAirTransferWithSession(_transfer, source, format,
        SPAirBetaEnabled() || _airPerformanceRequested, began, ended, status);
    if (began) SPPushSample(_transferNs, SPHostToNs(ended - began));
#if ODF_AIR_BETA_DIAGNOSTIC
    if (!result && began && SPAirBetaEnabled()) {
        _airBetaOriginalFailure = [NSString stringWithFormat:@"%@；原帧转换失败（%d），来源窗口继续播放", _airBetaFallbackReason ?: @"Air实验档已旁路", (int)status];
    }
#endif
    return result;
}

- (CVPixelBufferRef)yuvForIdentity:(uint64_t)identity {
    auto found = _held.find(identity);
    if (found == _held.end()) return NULL;
    if (!found->second.yuv) {
        found->second.yuv = [self transfer:found->second.source format:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange];
    }
    return found->second.yuv;
}

- (CVPixelBufferRef)lowPrescaledForIdentity:(uint64_t)identity {
    auto found=_held.find(identity);
    if (found==_held.end() || !_scaler) return NULL;
    if (found->second.lowPrescaled && found->second.lowPrescaledConfig!=_configVersion) {
        CVPixelBufferRelease(found->second.lowPrescaled); found->second.lowPrescaled=nullptr;
    }
    if (!found->second.lowPrescaled) {
        CVPixelBufferRef bgra=[self transfer:found->second.source format:kCVPixelFormatType_32BGRA];
        if (!bgra) return NULL;
        found->second.lowPrescaled=[self scaleBuffer:bgra with:_scaler];
        if (found->second.lowPrescaled) _lowPrescaleInputs++;
        CVPixelBufferRelease(bgra);
        found->second.lowPrescaledConfig=_configVersion;
    }
    return found->second.lowPrescaled;
}

- (CVPixelBufferRef)displayBufferForSource:(CVPixelBufferRef)source {
    if (!source) return NULL;
    CVPixelBufferRef bgra = [self transfer:source format:kCVPixelFormatType_32BGRA];
    if (!bgra) return NULL;
    if (!_request.scaleEnabled) return bgra;
    int outW = _request.outputWidth > 0 ? _request.outputWidth : (int)CVPixelBufferGetWidth(bgra);
    int outH = _request.outputHeight > 0 ? _request.outputHeight : (int)CVPixelBufferGetHeight(bgra);
    outW &= ~1;
    outH &= ~1;
    if (!_scaler) {
        return bgra;
    }
    NSError *error = nil;
    CVPixelBufferRef scaled = [_scaler scaleBuffer:bgra error:&error];
    CVPixelBufferRelease(bgra);
    return scaled;
}

- (void)recordPresentationFailure:(NSString *)reason endpoint:(NSString *)endpoint generation:(uint64_t)generation config:(uint64_t)config epoch:(uint64_t)epoch frame:(uint64_t)frame {
    [self recordPresentationFailure:reason endpoint:endpoint generation:generation config:config epoch:epoch frame:frame details:nil];
}

- (void)recordPresentationFailure:(NSString *)reason endpoint:(NSString *)endpoint generation:(uint64_t)generation config:(uint64_t)config epoch:(uint64_t)epoch frame:(uint64_t)frame details:(NSDictionary *)details {
    if (_airCadenceCallbacks) {
        SPAirFrameEvent event = SPAirCallbackRecord(details, endpoint); event.kind = SPAirFrameKind::failureNotification; event.reason = SPAirReason(reason);
        event.frameID = frame; event.generation = generation; event.config = config; event.epoch = epoch;
        [reason getCString:event.reasonText maxLength:sizeof(event.reasonText) encoding:NSUTF8StringEncoding]; event.reasonText[sizeof(event.reasonText)-1] = 0; _airCadenceCallbacks->append(event);
    }
    NSString *key = [NSString stringWithFormat:@"%@.%@", endpoint, reason ?: @"unknown"];
    NSMutableDictionary *sample = [@{ @"reason": reason ?: @"unknown", @"endpoint": endpoint, @"frameID": @(frame),
        @"generation": @(generation), @"configVersion": @(config), @"measurementEpoch": @(epoch), @"observedHost": @(SPHostNow()) } mutableCopy];
    auto mark = _marks.find(frame);
    if (mark != _marks.end()) {
        sample[@"logicalTargetHost"] = @(mark->second.targetHost);
    }
    if (details) [sample addEntriesFromDictionary:details];
    if (SPR8FixtureEnabled() && [endpoint isEqualToString:@"output"]) {
        if (!_r8OutputTimeline) _r8OutputTimeline = [NSMutableArray array];
        sample[@"kind"] = @"presentationFailure";
        [_r8OutputTimeline addObject:[sample copy]];
        if (_r8OutputTimeline.count > 512) [_r8OutputTimeline removeObjectAtIndex:0];
    }
    if (mark != _marks.end() && mark->second.jobID) [self recordR7JobEvent:@"presentationFailure" detail:@{
        @"id": @(mark->second.jobID), @"frameID": @(frame), @"reason": reason ?: @"unknown",
        @"endpoint": endpoint ?: @"unknown", @"generation": @(generation), @"config": @(config),
        @"clockEpoch": @(mark->second.clockEpoch), @"measurementEpoch": @(epoch) }];
    _presentationFailuresLifetime[key] = @([_presentationFailuresLifetime[key] unsignedLongLongValue] + 1);
    if (_airCurrentStatsCalls && [key isEqualToString:@"output.display-submit-deadline"])
        _airOutputSubmitDeadlineFailures.fetch_add(1, std::memory_order_relaxed);
    if (!_firstPresentationFailureLifetime[endpoint]) _firstPresentationFailureLifetime[endpoint] = sample;
    if (generation == _sourceGeneration && config == _configVersion && epoch == _measurementEpoch) {
        _presentationFailuresEpoch[key] = @([_presentationFailuresEpoch[key] unsignedLongLongValue] + 1);
        if (!_firstPresentationFailureEpoch[endpoint]) _firstPresentationFailureEpoch[endpoint] = sample;
    }
}

- (void)setPresentedVideoRecorder:(SPPresentedVideoRecorder *)recorder {
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
    self.outputPreview.presentedVideoRecorder = recorder;
#endif
}

- (void)setPresentedVideoReadbackEnabled:(BOOL)enabled {
    [self.outputPreview setPresentedVideoReadbackEnabled:enabled];
}

- (void)installPresentationHooks {
    SPLiveProcessor *strong = self;
    void (^block)(NSDictionary *) = ^(NSDictionary *info) {
        dispatch_async(strong->_q, ^{ [strong notePresented:info]; });
    };
    void (^failure)(NSString *, NSDictionary *) = ^(NSString *endpoint, NSDictionary *info) {
        dispatch_async(strong->_q, ^{ [strong recordPresentationFailure:info[@"reason"] endpoint:endpoint
            generation:[info[@"generation"] unsignedLongLongValue] config:[info[@"configVersion"] unsignedLongLongValue]
            epoch:[info[@"measurementEpoch"] unsignedLongLongValue] frame:[info[@"frameID"] unsignedLongLongValue] details:info]; });
    };
    self.preview.presentationFailure = ^(NSDictionary *info) { failure(@"preview", info); };
    self.outputPreview.presentationFailure = ^(NSDictionary *info) { failure(@"output", info); };
    self.preview.presented = ^(NSDictionary *info) {
        NSMutableDictionary *tagged = [info mutableCopy]; tagged[@"endpoint"] = @"preview"; block(tagged);
    };
    self.outputPreview.presented = ^(NSDictionary *info) {
        dispatch_async(strong->_q, ^{
            if ([info[@"presentedTime"] doubleValue] > 0) strong->_outputPresentedValidTime++;
            else strong->_outputPresentedZeroTime++;
            NSMutableDictionary *tagged = [info mutableCopy]; tagged[@"endpoint"] = @"output";
            [strong notePresented:tagged];
        });
    };
    self.outputPreview.surfaceReady = ^(NSDictionary *info) {
        dispatch_async(strong->_q, ^{
            uint64_t generation = [info[@"generation"] unsignedLongLongValue];
            uint64_t config = [info[@"configVersion"] unsignedLongLongValue];
            if ([info[@"gpuCompleted"] boolValue]) strong->_outputWarmGPUCompleted++;
            else strong->_outputWarmGPUFailed++;
            strong->_outputWarmMode=[info[@"viewMode"] integerValue];
            strong->_outputWarmEnhancedWidth=[info[@"enhancedWidth"] intValue];
            strong->_outputWarmEnhancedHeight=[info[@"enhancedHeight"] intValue];
            strong->_outputWarmOriginalWidth=[info[@"originalWidth"] intValue];
            strong->_outputWarmOriginalHeight=[info[@"originalHeight"] intValue];
            if (!strong->_stopped && strong->_outputSurfaceToken && [info[@"counts"] boolValue] &&
                [info[@"gpuCompleted"] boolValue] && [info[@"windowVisible"] boolValue] &&
                [info[@"captureHost"] longLongValue] >= strong->_outputSurfaceMinimumCaptureHost &&
                [info[@"surfaceToken"] unsignedLongLongValue] == strong->_outputSurfaceToken &&
                [info[@"measurementEpoch"] unsignedLongLongValue] == strong->_measurementEpoch &&
                generation == strong->_sourceGeneration && config == strong->_configVersion &&
                strong->_resolved.committed) {
                uint64_t token = strong->_outputSurfaceToken;
                strong->_outputSurfaceToken = 0;
                [strong.outputPreview setSurfaceToken:0];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (strong.outputSurfaceHandler) strong.outputSurfaceHandler(generation, config, token);
                });
            } else strong->_outputWarmRejected++;
        });
    };
}

- (void)awaitOutputSurfaceWithToken:(uint64_t)token {
    [self awaitOutputSurfaceWithToken:token minimumCaptureHost:0];
}

- (void)awaitOutputSurfaceWithToken:(uint64_t)token minimumCaptureHost:(int64_t)captureHost {
    dispatch_async(_q, ^{ self->_outputSurfaceToken = token; self->_outputSurfaceMinimumCaptureHost = captureHost;
        [self.outputPreview setSurfaceToken:token]; });
}

- (void)enablePixelDiagnostics {
    dispatch_async(_q, ^{
        self->_pixelDiagnosticsEnabled = YES;
        if (!self->_pixelInputSamples) self->_pixelInputSamples = [NSMutableDictionary dictionary];
        if (!self->_pixelInputOrder) self->_pixelInputOrder = [NSMutableArray array];
    });
}

- (void)sampleDiagnosticInput:(CVPixelBufferRef)buffer host:(int64_t)host identity:(uint64_t)identity
                       ptsNum:(int64_t)ptsNum ptsDen:(int64_t)ptsDen {
    if (!_pixelDiagnosticsEnabled) return;
    int64_t now = SPHostNow();
    if (_pixelLastInputAttemptHost > 0 && SPHostToNs(now - _pixelLastInputAttemptHost) < 1000000000LL) return;
    _pixelLastInputAttemptHost = now;
    _pixelInputAttempts++;
    NSMutableDictionary *sample = [SPPixelFingerprintBuffer(buffer) mutableCopy];
    sample[@"sourceGeneration"] = @(_sourceGeneration); sample[@"configVersion"] = @(_configVersion);
    sample[@"sourceIdentity"] = @(identity); sample[@"captureHost"] = @(host);
    sample[@"ptsNum"] = @(ptsNum); sample[@"ptsDen"] = @(ptsDen);
    sample[@"captureGeometrySameFrame"] = _geometryInputs[@(host)] ?: @{};
    sample[@"measurementEpoch"] = @(_measurementEpoch);
    sample[@"activePlan"] = @{ @"scaleEnabled": @(_request.scaleEnabled), @"scaleEngine": @(_request.scaleEngine),
        @"srInputPreset": @(_request.srInputPreset), @"interpolationEnabled": @(_request.interpolationEnabled),
        @"outputWidth": @(_request.outputWidth), @"outputHeight": @(_request.outputHeight) };
    _pixelLastInput = [sample copy];
    if (host <= 0 || ![sample[@"status"] isEqual:@"ok"]) return;
    NSNumber *key = @(host);
    _pixelInputSamples[key] = _pixelLastInput;
    [_pixelInputOrder addObject:key];
    while (_pixelInputOrder.count > 6) {
        NSNumber *oldest = _pixelInputOrder.firstObject;
        if (_pixelInputSamples[oldest]) { [_pixelInputSamples removeObjectForKey:oldest]; _pixelInputExpired++; }
        [_pixelInputOrder removeObjectAtIndex:0];
    }
}

- (NSDictionary *)sizeChainSnapshot {
    const auto sample = _presentationGeometry.get(_scoreOutput);
    if (!sample.valid || !_resolved.committed || _resolved.configVersion != _configVersion) return @{};
    return @{ @"endpoint": _scoreOutput ? @"output" : @"preview", @"sourceWidth": @(sample.sourceWidth), @"sourceHeight": @(sample.sourceHeight),
        @"processingWidth": @(sample.processingWidth), @"processingHeight": @(sample.processingHeight),
        @"srInputWidth": @((int)SPLiveSRInputSizeForRequest(_width, _height, _request).width), @"srInputHeight": @((int)SPLiveSRInputSizeForRequest(_width, _height, _request).height),
        @"bufferWidth": @(sample.bufferWidth), @"bufferHeight": @(sample.bufferHeight), @"drawableWidth": @(sample.drawableWidth), @"drawableHeight": @(sample.drawableHeight),
        @"presentedTimeNs": @(sample.presentedTimeNs), @"sourceGeneration": @(_sourceGeneration), @"configVersion": @(_configVersion), @"measurementEpoch": @(_measurementEpoch),
        @"engineID": _resolved.engineID ?: @"", @"modelID": _resolved.modelID ?: @"", @"downsampled": @([self requestUsesLowPrescale:_request width:_width height:_height]) };
}

- (NSDictionary *)presentationOrderSummary {
    auto convert = [](sp::PresentationSummary s) -> NSDictionary * {
        return @{ @"backwards": @(s.backwards), @"duplicates": @(s.duplicates), @"ambiguousTimes": @(s.ambiguousTimes),
                  @"invalidTimes": @(s.invalidTimes), @"invisible": @(s.invisible), @"excluded": @(s.excluded) };
    };
    return @{ @"preview": convert(_presentationOrder.summary(false)), @"output": convert(_presentationOrder.summary(true)),
              @"windowSize": @(_presentationOrder.events().size()), @"windowCapacity": @(sp::PresentationOrder::capacity),
              @"evictedSinceEpochStart": @(_presentationOrder.evicted()), @"coversWholeEpoch": @(_presentationOrder.evicted() == 0),
              @"scope": @"bounded callback window ordered by presentedTime; ambiguous ties excluded" };
}

- (NSDictionary *)presentationOrderDiagnostics {
    const BOOL callerWasMain = NSThread.isMainThread;
    const BOOL callerWasProcessorQueue = dispatch_get_specific(SPLiveQueueKey) == (__bridge void *)self;
    __block NSDictionary *result;
    void (^capture)(void) = ^{
        const int64_t causalCutoff = self->_airCadenceCallbacks ? SPHostNow() : 0;
        NSMutableArray *events = [NSMutableArray arrayWithCapacity:self->_presentationOrder.events().size()];
        for (const auto &e : self->_presentationOrder.events()) {
            [events addObject:@{ @"ptsNs": @(e.pts), @"presentedTimeNs": @(e.presented), @"frameID": @(e.frame),
                @"endpoint": e.output ? @"output" : @"preview", @"visible": @(e.visible), @"held": @(e.held), @"originalSynthetic": @(e.originalSynthetic) }];
        }
        result = @{ @"summary": [self presentationOrderSummary], @"sourceGeneration": @(self->_sourceGeneration),
                    @"configVersion": @(self->_configVersion), @"measurementEpoch": @(self->_measurementEpoch), @"eventsInCallbackOrder": events };
        if (self->_airCadenceCallbacks) {
            std::vector<SPAirFrameEvent> preview, output, callbacks; std::vector<SPAirBudgetEvent> budgets;
            std::vector<SPAirSlotCallbackEvent> previewSlotCallbacks, outputSlotCallbacks;
            std::vector<SPAirSlotConsumeEvent> previewSlotConsumes, outputSlotConsumes;
            SPAirSlotSnapshot previewSlotSnapshot{}, outputSlotSnapshot{};
            uint64_t previewTotal = 0, outputTotal = 0;
            uint64_t previewCallbackTotal = 0, outputCallbackTotal = 0, previewConsumeTotal = 0, outputConsumeTotal = 0, previewUnsupported = 0, outputUnsupported = 0;
            [self.preview copyAirCadenceEvents:&preview total:&previewTotal consumes:&previewSlotConsumes consumeTotal:&previewConsumeTotal snapshot:&previewSlotSnapshot];
            [self.outputPreview copyAirCadenceEvents:&output total:&outputTotal consumes:&outputSlotConsumes consumeTotal:&outputConsumeTotal snapshot:&outputSlotSnapshot];
            const BOOL captureWasProcessorQueue = dispatch_get_specific(SPLiveQueueKey) == (__bridge void *)self;
            const BOOL mainCallerSyncExport = callerWasMain && !callerWasProcessorQueue && captureWasProcessorQueue;
            const BOOL previewCallbackSafe = [self.preview copyAirSlotCallbacks:&previewSlotCallbacks total:&previewCallbackTotal mainCallerSynchronouslyOnProcessorQueue:mainCallerSyncExport unsupported:&previewUnsupported];
            const BOOL outputCallbackSafe = [self.outputPreview copyAirSlotCallbacks:&outputSlotCallbacks total:&outputCallbackTotal mainCallerSynchronouslyOnProcessorQueue:mainCallerSyncExport unsupported:&outputUnsupported];
            const BOOL callbackExportSafe = mainCallerSyncExport && previewCallbackSafe && outputCallbackSafe;
            callbacks.reserve(16384); self->_airCadenceCallbacks->copy(callbacks);
            budgets.reserve(8192); self->_airCadenceBudget->copy(budgets);
            NSDictionary *previewExport = SPAirFrameExport(preview, previewTotal, @"preview", causalCutoff);
            NSDictionary *outputExport = SPAirFrameExport(output, outputTotal, @"output", causalCutoff);
            NSDictionary *callbackExport = SPAirFrameExport(callbacks, self->_airCadenceCallbacks->total, nil, causalCutoff);
            NSDictionary *budgetExport = SPAirBudgetExport(budgets, self->_airCadenceBudget->total, causalCutoff);
            NSDictionary *unavailableCallbacks = @{ @"capacity": @16384, @"total": NSNull.null, @"dropped": NSNull.null,
                @"firstseq": NSNull.null, @"lastseq": NSNull.null, @"exportedCount": @0, @"events": @[], @"unsupported": @YES };
            NSDictionary *previewCallbackExport = previewCallbackSafe ? SPAirSlotCallbackExport(previewSlotCallbacks, previewCallbackTotal, causalCutoff) : unavailableCallbacks;
            NSDictionary *outputCallbackExport = outputCallbackSafe ? SPAirSlotCallbackExport(outputSlotCallbacks, outputCallbackTotal, causalCutoff) : unavailableCallbacks;
            NSDictionary *previewConsumeExport = SPAirSlotConsumeExport(previewSlotConsumes, previewConsumeTotal, causalCutoff);
            NSDictionary *outputConsumeExport = SPAirSlotConsumeExport(outputSlotConsumes, outputConsumeTotal, causalCutoff);
            NSDictionary *delayExport = nil;
            uint64_t delayOverflow = 0;
            if (self->_airDelayAlignmentEvents) {
                std::vector<SPAirDelayAlignmentEvent> delayEvents; delayEvents.reserve(16384);
                self->_airDelayAlignmentEvents->copy(delayEvents);
                delayExport = SPAirDelayAlignmentExport(delayEvents, self->_airDelayAlignmentEvents->total, causalCutoff);
                delayOverflow = [delayExport[@"dropped"] unsignedLongLongValue];
            }
            const uint64_t slotOverflow = [previewConsumeExport[@"dropped"] unsignedLongLongValue] + [outputConsumeExport[@"dropped"] unsignedLongLongValue] +
                (previewCallbackSafe ? [previewCallbackExport[@"dropped"] unsignedLongLongValue] : 0) + (outputCallbackSafe ? [outputCallbackExport[@"dropped"] unsignedLongLongValue] : 0);
            const uint64_t overflow = [previewExport[@"dropped"] unsignedLongLongValue] + [outputExport[@"dropped"] unsignedLongLongValue] +
                [callbackExport[@"dropped"] unsignedLongLongValue] + [budgetExport[@"dropped"] unsignedLongLongValue] + slotOverflow + delayOverflow;
            NSMutableDictionary *extended = [result mutableCopy];
            extended[@"airCadenceCausalTrace"] = @{ @"enabled": @YES, @"exportCutoffHostTicks": @(causalCutoff),
                @"overflowCount": @(overflow), @"overflowCountKnown": @(callbackExportSafe), @"ringsComplete": @(overflow == 0 && callbackExportSafe && previewUnsupported == 0 && outputUnsupported == 0), @"preview": previewExport, @"output": outputExport,
                @"callbacks": callbackExport, @"rateBudget": budgetExport,
                @"delayAlignment": @{ @"enabled": @(self->_airDelayAlignmentEvents != nullptr),
                    @"trueSourceIntervalRequested": @(self->_airTrueSourceIntervalRequested),
                    @"interactiveCap125msRequested": @(self->_airInteractiveCap125msRequested),
                    @"recomputes": delayExport ?: @{},
                    @"scope": @"POD per-recompute inputs and result; nanoseconds except HostTicks. Source-only early return has calculated=false and uncomputed fields null. capNs is the actual logical cap: normal interactive 90ms, explicit guard-build diagnostic 125ms; quality cap is unchanged. True-source-interval diagnostic only removes the 1/30 upper clamp; initial fallback and source-estimate validity rule are unchanged. Capture-to-positive-presented latency is measured separately, not bounded by finalNs." },
                @"slots": @{ @"callbackExportSafe": @(callbackExportSafe), @"valid": @(callbackExportSafe && previewUnsupported == 0 && outputUnsupported == 0 && slotOverflow == 0),
                    @"overflowCount": @(slotOverflow), @"overflowCountKnown": @(callbackExportSafe),
                    @"callerWasMain": @(callerWasMain), @"callerWasProcessorQueue": @(callerWasProcessorQueue), @"captureWasProcessorQueue": @(captureWasProcessorQueue),
                    @"unsupported": @(previewUnsupported + outputUnsupported),
                    @"preview": @{ @"callbackExportSafe": @(previewCallbackSafe), @"unsupported": @(previewUnsupported), @"callbacks": previewCallbackExport, @"consumes": previewConsumeExport, @"pendingSlotSnapshot": SPAirSlotSnapshotExport(previewSlotSnapshot) },
                    @"output": @{ @"callbackExportSafe": @(outputCallbackSafe), @"unsupported": @(outputUnsupported), @"callbacks": outputCallbackExport, @"consumes": outputConsumeExport, @"pendingSlotSnapshot": SPAirSlotSnapshotExport(outputSlotSnapshot) },
                    @"scope": @"Separate preallocated rings: display-link callback is main-thread-only; unexpected off-main callbacks increment only an atomic unsupported counter and invalidate coverage. Callback copy requires an originating main caller synchronously exporting on its processor queue, so the main run loop cannot deliver another callback (including inline dispatch_sync execution). Otherwise its ring is not read and total/dropped remain unknown. Consume attempts and proactive token dispositions write/copy only under existing presentationMutex; consume, frame and pending-slot snapshot copies share one lock region. origin distinguishes timer attempts, callback replacement and visibility/context cleanup. terminalDisposition is true only when the old state clears/replaces that token; stale/no-current/waiting attempts are nonterminal. pendingSlotSnapshot has its own sampleHostTicks after global cutoff, not an atomic state at exportCutoffHostTicks; filtered post-cutoff dispositions leave an unknown tail for offline accounting. Early-reject context is an entry atomic snapshot, while created/busy context is read under presentationMutex. Guard reasons are the first true original short-circuit predicate. HostTicks and CA MediaNs/MediaSeconds are separate clocks. Overflow invalidates completeness." },
                @"sourceStoppedScope": @"Controlled caller contract: SelfProbe exports after SCK stop completion and before processor.stop. This method does not verify capture state, wait for GPU, flush, or stop any queue. Records are filtered by record host <= exportCutoffHostTicks; GPU/callback tail remains unknown.",
                @"scope": @"Trace-only diagnostic library. Preallocated POD rings never reset with configuration/measurement epochs. View writes use existing presentationMutex regions; processor writes use existing serial queue. No trace arrays are exported in periodic stats. Capacity overflow makes evidence incomplete. enqueueHostTicks is actual bounded-queue admission, requestStartHostTicks preserves the prior request timestamp. Unassigned cleanup slot/replacement are null. Callback metadata may lack original counts/capture/admission time; join to its admission using endpoint/generation/config/epoch/clock/frameID/requestStartHostTicks. endingInflight is unresolved at cutoff, not confirmed hardware work. Raw positive presented callbacks are recorded before score/context filtering; this is not physical/human acceptance. Budget caller gates are exact; fresh<8 is input evidence, internal persistence/cooldown reasons are not introspected." };
            result = extended;
        }
#if ODF_AIR_PRESENTATION_GUARD_DIAGNOSTIC
        if (self->_airDelayAlignmentRequested && [self->_request.engineID isEqualToString:@"apple.frc"]) {
            NSMutableDictionary *extended = [result mutableCopy];
            extended[@"appleFRCIdentity"] = @{ @"requestedEngineID": self->_request.engineID ?: @"",
                @"resolvedEngineID": self->_resolved.engineID ?: @"", @"resolvedModelID": self->_resolved.modelID ?: @"",
                @"qualityID": self->_request.qualityID ?: @"", @"quality": @(self->_request.quality),
                @"OSVersion": NSProcessInfo.processInfo.operatingSystemVersionString,
                @"isSupportedIfResolved": @([SPFRCEngine availabilityIfResolved]),
                @"engineInstanceCreated": @(self->_engine != nil), @"actualEngineClass": self->_engine ? NSStringFromClass(self->_engine.class) : (id)NSNull.null,
                @"sessionsActual": @(self->_engine ? self->_engine.sessionCount : 0), @"width": @(self->_width), @"height": @(self->_height),
                @"sourcePixelFormat": @(self->_sourcePixelFormat), @"rifeStreamEnabled": @(self->_request.rifeStreamEnabled),
                @"captureToOutputReadyOrigin": @"B source captureHost; includes B-side capture/copy/queue, input/VT/output conversions and delivery; excludes the A-to-B source interval. No extra I subtraction.",
                @"scope": @"Guard-build explicit delay-alignment diagnostic snapshot of the actual configured processor instance; capability alone is not session or performance acceptance." };
            result = extended;
        }
        if (self->_rife.serviceTraceEnabled) {
            NSMutableDictionary *extended = [result mutableCopy];
            const uint64_t serviceCutoff = causalCutoff > 0 ? (uint64_t)causalCutoff : (uint64_t)SPHostNow();
            extended[@"airServiceTrace"] = [self->_rife serviceTraceSnapshotAtCutoffHostTicks:serviceCutoff];
            result = extended;
        }
#if ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC
        if (self->_outputPreview) {
            NSMutableDictionary *extended = [result mutableCopy];
            extended[@"airFusedRifePresenter"] = [self->_outputPreview fusedRifePresentationSnapshotIncludeRecords:YES cutoffHostTicks:SPHostNow()];
            result = extended;
        }
#endif
#endif
    };
    if (dispatch_get_specific(SPLiveQueueKey) == (__bridge void *)self) capture(); else dispatch_sync(_q, capture);
    return result;
}

- (void)notePresented:(NSDictionary *)info {
    if (_airCadenceCallbacks) {
        SPAirFrameEvent event = SPAirCallbackRecord(info, info[@"endpoint"]);
        event.kind = event.presentedTimeMediaNs > 0 ? SPAirFrameKind::positivePresented : SPAirFrameKind::zeroPresented;
        event.reason = event.presentedTimeMediaNs > 0 ? SPAirFrameReason::none : SPAirFrameReason::notPresented;
        _airCadenceCallbacks->append(event);
    }
    if (SPR8FixtureEnabled() && [info[@"endpoint"] isEqual:@"output"]) {
        if (!_r8OutputTimeline) _r8OutputTimeline = [NSMutableArray array];
        [_r8OutputTimeline addObject:@{ @"kind": @"presented", @"frameID": info[@"frameID"] ?: @0,
            @"generation": info[@"generation"] ?: @0, @"configVersion": info[@"configVersion"] ?: @0,
            @"measurementEpoch": info[@"measurementEpoch"] ?: @0, @"clockEpoch": info[@"clockEpoch"] ?: @0,
            @"presentedTime": info[@"presentedTime"] ?: @0, @"counts": info[@"counts"] ?: @NO,
            @"windowVisible": info[@"windowVisible"] ?: @NO, @"exposed": info[@"exposed"] ?: @NO,
            @"occluded": info[@"occluded"] ?: @NO, @"synthetic": info[@"synthetic"] ?: @NO,
            @"callbackHost": info[@"presentedHost"] ?: @0, @"handlerMediaTime": info[@"handlerMediaTime"] ?: @0,
            @"presentationEnqueueHost": info[@"presentationEnqueueHost"] ?: @0,
            @"presentationQueueStartHost": info[@"presentationQueueStartHost"] ?: @0,
            @"metalCommitHost": info[@"metalCommitHost"] ?: @0,
            @"metalScheduledHost": info[@"metalScheduledHost"] ?: @0,
            @"metalScheduledMediaTime": info[@"metalScheduledMediaTime"] ?: @0,
            @"presentRequestMethod": info[@"presentRequestMethod"] ?: @"drawable-immediate",
            @"gpuHost": info[@"gpuHost"] ?: @0,
            @"displayLinkCallbackHost": info[@"displayLinkCallbackHost"] ?: @0,
            @"displaySelectionHost": info[@"displaySelectionHost"] ?: @0,
            @"displaySlotToken": info[@"displaySlotToken"] ?: @0,
            @"displayLinkTargetTimestamp": info[@"displayLinkTargetTimestamp"] ?: @0,
            @"displayLinkTargetPresentationTimestamp": info[@"displayLinkTargetPresentationTimestamp"] ?: @0,
            @"logicalTargetHost": info[@"logicalTargetHost"] ?: @0,
            @"scheduledMinusLogicalTargetNs": info[@"scheduledMinusLogicalTargetNs"] ?: [NSNull null],
            @"actualMinusScheduledDisplayNs": info[@"actualMinusScheduledDisplayNs"] ?: [NSNull null],
            @"actualMinusLogicalTargetNs": info[@"actualMinusLogicalTargetNs"] ?: [NSNull null],
            @"presentRequestMediaTime": info[@"presentRequestMediaTime"] ?: @0,
            @"drawablePixels": @[info[@"drawableWidth"] ?: @0, info[@"drawableHeight"] ?: @0],
            @"outputImageRectPixels": info[@"outputImageRectPixels"] ?: [NSNull null],
            @"outputDisplayID": info[@"outputDisplayID"] ?: [NSNull null], @"geometryVersion": info[@"geometryVersion"] ?: [NSNull null] }];
        if (_r8OutputTimeline.count > 512) [_r8OutputTimeline removeObjectAtIndex:0];
    }
    uint64_t configVersion = [info[@"configVersion"] unsignedLongLongValue];
    uint64_t epoch = [info[@"measurementEpoch"] unsignedLongLongValue];
    NSString *ignored = ![info[@"counts"] boolValue] ? @"redrawOrUnscored" :
        ([info[@"generation"] unsignedLongLongValue] != _sourceGeneration ? @"generation" :
         (configVersion != 0 && configVersion != _configVersion ? @"configuration" :
          (epoch != 0 && epoch != _measurementEpoch ? @"epoch" :
           (info[@"clockEpoch"] && [info[@"clockEpoch"] unsignedLongLongValue] != _clockEpoch ? @"clock" : nil))));
    if (ignored) {
        if ([info[@"endpoint"] isEqual:@"output"] && _pixelPendingOutput &&
            [info[@"frameID"] unsignedLongLongValue] == [_pixelPendingOutput[@"frameID"] unsignedLongLongValue]) {
            NSMutableDictionary *event = [_pixelPendingOutput mutableCopy];
            event[@"callbackState"] = ignored;
            _pixelLastOutputCallback = [event copy]; _pixelPendingOutput = nil; _pixelOutputUnmatchedCallback++;
        }
        NSString *key = [NSString stringWithFormat:@"%@.%@", info[@"endpoint"] ?: @"unknown", ignored];
        _ignoredPresentedCallbacks[key] = @([_ignoredPresentedCallbacks[key] unsignedLongLongValue] + 1);
        return;
    }
    _surfaceGeometryAssessment = [info[@"surfaceGeometryAssessment"] isKindOfClass:NSString.class] ? info[@"surfaceGeometryAssessment"] : @"uncalibrated-no-metadata";
    _surfaceCropEndpoint = info[@"endpoint"] ?: @"unknown";
    sp::SPRational pts = sp::spMake([info[@"ptsNum"] longLongValue], [info[@"ptsDen"] longLongValue]);
    if (_probeWindowOpen && sp::spCmp(pts, _probeMinPts) < 0) return;
    const uint64_t meterFrameID = [info[@"frameID"] unsignedLongLongValue];
    auto meterMark = _marks.find(meterFrameID);
    const bool held = meterMark == _marks.end() || meterMark->second.held || meterMark->second.fpsEpoch != _fpsObservationEpoch;
    const double presentTime = [info[@"presentedTime"] doubleValue];
    __int128 ptsNs = pts.den > 0 ? (__int128)pts.num * 1000000000 / pts.den : INT64_MIN;
    const bool physicalVisible = [info[@"windowVisible"] boolValue] && ![info[@"occluded"] boolValue] && [info[@"exposed"] boolValue];
    if ([info[@"endpoint"] isEqual:@"output"] && _pixelPendingOutput &&
        [info[@"frameID"] unsignedLongLongValue] == [_pixelPendingOutput[@"frameID"] unsignedLongLongValue] &&
        [info[@"generation"] unsignedLongLongValue] == [_pixelPendingOutput[@"sourceGeneration"] unsignedLongLongValue] &&
        configVersion == [_pixelPendingOutput[@"configVersion"] unsignedLongLongValue]) {
        NSMutableDictionary *event = [_pixelPendingOutput mutableCopy];
        event[@"callbackHost"] = info[@"presentedHost"] ?: @0;
        event[@"presentedTime"] = @(presentTime);
        event[@"snapshotVisibleAtSubmission"] = @(physicalVisible);
        event[@"surfaceGeometryAssessment"] = info[@"surfaceGeometryAssessment"] ?: @"uncalibrated-no-metadata";
        event[@"outputImageRectPixels"] = info[@"outputImageRectPixels"] ?: [NSNull null];
        if (physicalVisible && presentTime > 0) {
            event[@"callbackState"] = @"visible_present_callback";
            _pixelLastOutputPresented = [event copy]; _pixelOutputPresentedCount++;
        } else {
            event[@"callbackState"] = @"not_visible_or_missing_presented_time";
            _pixelOutputUnmatchedCallback++;
        }
        _pixelLastOutputCallback = [event copy]; _pixelPendingOutput = nil;
    }
    if (ptsNs >= INT64_MIN && ptsNs <= INT64_MAX) {
        int64_t timeNs = presentTime > 0 && presentTime < (double)INT64_MAX / 1e9 ? (int64_t)(presentTime * 1e9) : 0;
        _presentationOrder.add({(int64_t)ptsNs, timeNs, meterFrameID, [info[@"endpoint"] isEqualToString:@"output"], physicalVisible,
                                held, [info[@"viewMode"] integerValue] == SPLiveViewOriginal && [info[@"synthetic"] boolValue]}, _sourceGeneration, configVersion ?: _configVersion, epoch ?: _measurementEpoch);
    }
    if (physicalVisible && !held && _resolved.committed && _resolved.configVersion == _configVersion &&
        presentTime > 0 && presentTime < (double)INT64_MAX / 1e9) {
        const bool output = [info[@"endpoint"] isEqualToString:@"output"];
        if (output == (bool)_scoreOutput) {
            sp::PresentationGeometrySample sample;
            sample.sourceWidth = _sourceWidth; sample.sourceHeight = _sourceHeight;
            sample.processingWidth = _lowLatency ? _lowLatency.width : _width;
            sample.processingHeight = _lowLatency ? _lowLatency.height : _height;
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
            if (_rife.rifePrescaleEnabled) { sample.processingWidth = _rife.processingWidth; sample.processingHeight = _rife.processingHeight; }
#endif
            sample.bufferWidth = [info[@"width"] intValue]; sample.bufferHeight = [info[@"height"] intValue];
            sample.drawableWidth = [info[@"drawableWidth"] intValue]; sample.drawableHeight = [info[@"drawableHeight"] intValue];
            sample.presentedTimeNs = (int64_t)(presentTime * 1e9);
            _presentationGeometry.record(output, sample);
        }
    }
    if (ptsNs >= INT64_MIN && ptsNs <= INT64_MAX && presentTime > 0 && presentTime < (double)INT64_MAX / 1e9) {
        const bool originalSynthetic = [info[@"viewMode"] integerValue] == SPLiveViewOriginal && [info[@"synthetic"] boolValue];
        const bool visible = [info[@"windowVisible"] boolValue] && ![info[@"occluded"] boolValue] && [info[@"exposed"] boolValue];
        _fpsMeter.presented((int64_t)ptsNs, (int64_t)(presentTime * 1e9), meterFrameID, held, originalSynthetic,
                            visible);
        if (visible && !held && !originalSynthetic && (!_physicalHavePts || sp::spCmp(pts, _physicalLastPts) > 0)) {
            if ([info[@"synthetic"] boolValue]) {
                _epochPhysicalSynthetic++;
                if (meterMark == _marks.end() || meterMark->second.targetHost <= 0) _r9TimingUnknownSynthetic++;
                else {
                    int64_t actualNs = (int64_t)(presentTime * 1e9);
                    int64_t targetNs = SPHostToNs(meterMark->second.targetHost);
                    bool onTime = actualNs <= targetNs + 2000000LL;
                    if (onTime) _r9OnTimeSynthetic++;
                    else _r9LatePhysicalSynthetic++;
                    if (meterMark->second.jobID) [self recordR7JobEvent:@"physicalSynthetic" detail:@{
                        @"id": @(meterMark->second.jobID), @"frameID": @(meterFrameID),
                        @"generation": @(_sourceGeneration), @"config": @(_configVersion),
                        @"clockEpoch": @(meterMark->second.clockEpoch), @"measurementEpoch": @(_measurementEpoch),
                        @"targetHost": @(meterMark->second.targetHost), @"presentedTime": @(presentTime),
                        @"onTimePlus2ms": @(onTime) }];
                }
            } else _epochPhysicalSource++;
            _physicalLastPts=pts; _physicalHavePts=YES;
        }
    }
    if (physicalVisible && presentTime > 0 && [info[@"endpoint"] isEqualToString:(_scoreOutput ? @"output" : @"preview")])
        _lastDrawablePresentedHost = [info[@"presentedHost"] longLongValue];
    _presentedCallbacks += 1;
    if ([info[@"synthetic"] boolValue]) {
        _presentedSynthetic += 1;
        _epochPresentedSynthetic += 1;
    } else {
        _presentedSource += 1;
        _epochPresentedSource += 1;
    }
    int width = [info[@"width"] intValue];
    int height = [info[@"height"] intValue];
    if (_epochWidth == 0) {
        _epochWidth = width;
        _epochHeight = height;
    } else if (width != _epochWidth || height != _epochHeight) {
        _epochSizeChanges += 1;
        _epochWidth = width;
        _epochHeight = height;
    }
    if (_epochHavePts && sp::spCmp(pts, _epochLastPts) <= 0) {
        if (sp::spCmp(pts, _epochLastPts) == 0) _epochDuplicates += 1;
        else _epochMonotonic = NO;
    }
    _epochLastPts = pts;
    _epochHavePts = YES;
    int64_t captureHost = [info[@"captureHost"] longLongValue];
    int64_t presentedHost = [info[@"presentedHost"] longLongValue];
    int64_t latencyNs = (captureHost > 0 && presentedHost > captureHost) ? SPHostToNs(presentedHost - captureHost) : -1;
    if ([info[@"occluded"] boolValue]) _occludedPresents += 1;
    int64_t admissionHost = [info[@"presentationEnqueueHost"] longLongValue];
    int64_t queueStartHost = [info[@"presentationQueueStartHost"] longLongValue];
    if (admissionHost > 0 && queueStartHost >= admissionHost)
        SPPushSample(_presentationAdmissionToCallbackNs, SPHostToNs(queueStartHost - admissionHost));
    int64_t commitHost = [info[@"metalCommitHost"] longLongValue];
    double scheduledDisplay = [info[@"displayLinkTargetPresentationTimestamp"] doubleValue];
    if (presentTime > 0 && commitHost > 0 && presentTime * 1e9 >= SPHostToNs(commitHost))
        SPPushSample(_metalCommitToDisplayNs, (int64_t)(presentTime * 1e9) - SPHostToNs(commitHost));
    id scheduleOffset = info[@"scheduledMinusLogicalTargetNs"];
    if (scheduledDisplay > 0 && [scheduleOffset isKindOfClass:NSNumber.class])
        SPPushSample(_displayScheduledTargetOffsetNs, [scheduleOffset longLongValue]);
    int64_t drawableWait = [info[@"drawableWaitNs"] longLongValue];
    if (drawableWait > 0) SPPushSample(_drawableWaitNs, drawableWait);
    int64_t gpuHost = [info[@"gpuHost"] longLongValue];
    if (presentedHost > 0 && gpuHost > 0 && presentedHost >= gpuHost) {
        SPPushSample(_presentGapNs, SPHostToNs(presentedHost - gpuHost));
    }
    double presentedTime = [info[@"presentedTime"] doubleValue];
    double handlerMedia = [info[@"handlerMediaTime"] doubleValue];
    if (presentedTime > 0 && handlerMedia > presentedTime) {
        int64_t deliveryNs = (int64_t)((handlerMedia - presentedTime) * 1e9);
        SPPushSample(_presentMediaLagNs, deliveryNs);
        if (latencyNs >= deliveryNs) SPPushSample(_captureToDisplayNs, latencyNs - deliveryNs);
        if (presentedHost > 0 && gpuHost > 0 && presentedHost >= gpuHost) {
            int64_t gpuToCallbackNs = SPHostToNs(presentedHost - gpuHost);
            if (gpuToCallbackNs >= deliveryNs) SPPushSample(_gpuToDisplayNs, gpuToCallbackNs - deliveryNs);
        }
    }
    if (latencyNs >= 0) {
        std::lock_guard<std::mutex> lock(_latencyMx);
        SPPushSample(_latencyNs, latencyNs);
        int bucket = (int)(latencyNs / 1000000LL);
        if (bucket < 0) bucket = 0;
        if (bucket > 200) bucket = 200;
        _epochHist[bucket] += 1;
        _epochSamples += 1;
    }
    uint64_t frameID = [info[@"frameID"] unsignedLongLongValue];
    double enhancedCenter = [info[@"enhancedCenter"] doubleValue];
    double originalCenter = [info[@"originalCenter"] doubleValue];
    auto mark = _marks.find(frameID);
    if (mark != _marks.end()) {
        if (presentedHost > 0 && mark->second.readyHost > 0) {
            SPPushSample(_queueNs, SPHostToNs(presentedHost - mark->second.readyHost));
        }
        if (presentedHost > 0 && mark->second.targetHost > 0) {
            SPPushSample(_playheadNs, SPHostToNs(presentedHost - mark->second.targetHost));
        }
        if (mark->second.hasCenter) {
            enhancedCenter = mark->second.enhancedCenter;
            originalCenter = mark->second.originalCenter;
        }
        _marks.erase(mark);
    }
    if (_probeAggregateOnly) {
        if (_probeHaveLast && sp::spCmp(_probeLastPts, pts) >= 0) _probeMonotonic = NO;
        _probeLastPts = pts;
        _probeHaveLast = YES;
        if ([info[@"width"] intValue] != _resolved.outputWidth || [info[@"height"] intValue] != _resolved.outputHeight) {
            _probeSizeOK = NO;
        }
    } else if (_probeOutputs) {
        NSMutableDictionary *row = [info mutableCopy];
        row[@"enhancedCenter"] = @(enhancedCenter);
        row[@"originalCenter"] = @(originalCenter);
        row[@"centerX"] = @(enhancedCenter);
        row[@"latencyMs"] = @(latencyNs >= 0 ? (double)latencyNs / 1e6 : -1);
        [_probeOutputs addObject:row];
    }
    [self publishStats];
}

- (void)recordR9SlotDrop:(const SPPlaySlot &)slot reason:(NSString *)reason {
    if (!slot.synthetic || !slot.jobID) return;
    [self recordR7JobEvent:reason detail:@{ @"id": @(slot.jobID), @"frameID": @(slot.frameID),
        @"ptsNum": @(slot.pts.num), @"ptsDen": @(slot.pts.den), @"generation": @(slot.sourceGeneration),
        @"config": @(slot.configVersion), @"clockEpoch": @(slot.clockEpoch),
        @"measurementEpoch": @(slot.measurementEpoch), @"targetHost": @(slot.targetHost) }];
}

- (void)clearPlaySlots {
    [self cancelSourceConversions];
    for (auto &slot : _slots) SPReleaseSlot(slot);
    _slots.clear();
}

- (void)rememberPair:(CVPixelBufferRef)enhanced original:(CVPixelBufferRef)original pts:(sp::SPRational)pts synthetic:(BOOL)synthetic geometryHost:(int64_t)geometryHost targetHost:(int64_t)targetHost {
    if (_lastEnhanced) CVPixelBufferRelease(_lastEnhanced);
    if (_lastOriginal) CVPixelBufferRelease(_lastOriginal);
    _lastEnhanced = enhanced ? CVPixelBufferRetain(enhanced) : nullptr;
    _lastOriginal = original ? CVPixelBufferRetain(original) : nullptr;
    _lastRedrawPts = pts;
    _lastRedrawGeometryHost = geometryHost;
    _lastRedrawTargetHost = targetHost;
    _lastSynthetic = synthetic;
}

- (void)airMeasurementTarget:(sp::SPRational)pts target:(int64_t)target frame:(uint64_t)frameID
    job:(uint64_t)jobID phase:(uint64_t)phase synthetic:(BOOL)synthetic computed:(BOOL)computed {
    spAirMeasurement::Event event; event.kind = spAirMeasurement::Kind::targetCreated;
    event.beginHostTicks = event.endHostTicks = SPHostNow(); event.frameID = frameID;
    event.relatedID = jobID; event.groupID = phase; event.ptsNum = pts.num; event.ptsDen = pts.den;
    event.targetHostTicks = target; event.generation = _sourceGeneration; event.config = _configVersion;
    event.epoch = _measurementEpoch; event.clock = _clockEpoch; event.flags = (synthetic ? 1u : 0u) | 8u;
    sp::SPRational delta{};
    if (computed && _haveAnchor && sp::spSub(pts, _anchorPts, delta)) {
        event.flags |= 16u; event.values[0] = _delayHost; event.values[1] = _anchorHost;
        event.values[2] = _anchorPts.num; event.values[3] = _anchorPts.den;
    }
    if (_haveInterval && _intervalHost > 0) { event.flags |= 64u; event.sampleHostTicks = _intervalHost; }
    if (_airTrueSourceIntervalRequested) event.flags |= 128u;
    _measurementTrace->append(event);
}

- (spAirMeasurement::Event)airMeasurementEvent:(spAirMeasurement::Kind)kind {
    spAirMeasurement::Event event; event.kind = kind;
    event.generation = _sourceGeneration; event.config = _configVersion;
    event.epoch = _measurementEpoch; event.clock = _clockEpoch;
    event.clockLifeID = _measurementClockLife; event.armID = _measurementArm;
    if (!_slots.empty()) { const auto &slot = _slots.front(); event.frameID = slot.frameID;
        event.ptsNum = slot.pts.num; event.ptsDen = slot.pts.den; event.targetHostTicks = slot.targetHost;
        event.flags = (slot.synthetic ? 1u : 0u) | 8u; }
    return event;
}

- (void)ensureClock {
    if (_clock) return;
    _clock = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT, _q);
    SPLiveProcessor *strong = self;
    const uint64_t measurementClockLife = _measurementTrace ? _measurementTrace->identity() : 0;
    if (_measurementTrace) {
        _measurementClockLife = measurementClockLife; _measurementArm = 0;
        auto event = [self airMeasurementEvent:spAirMeasurement::Kind::timerCreate];
        event.beginHostTicks = event.endHostTicks = SPHostNow(); _measurementTrace->append(event);
    }
    dispatch_source_set_event_handler(_clock, ^{
        if (strong->_measurementTrace) {
            auto event = [strong airMeasurementEvent:spAirMeasurement::Kind::timerFire];
            event.beginHostTicks = event.endHostTicks = SPHostNow(); event.clockLifeID = measurementClockLife;
            event.groupID = strong->_measurementTrace->identity(); event.values[0] = strong->_measurementClockLife;
            if (measurementClockLife == strong->_measurementClockLife && strong->_clock) {
                event.flags |= 16u; event.values[1] = dispatch_source_get_data(strong->_clock);
            }
            strong->_measurementFire = event.groupID; strong->_measurementTrace->append(event);
        }
        if (strong->_testCapturePlayout && strong->_testTimingTrace.count < 80) {
            if (!strong->_testTimingTrace) strong->_testTimingTrace=[NSMutableArray array];
            int64_t fired=SPHostNow();
            int64_t target=strong->_slots.empty()?0:strong->_slots.front().targetHost;
            [strong->_testTimingTrace addObject:@{ @"kind":@"timer", @"host":@(fired), @"targetHost":@(target), @"slots":@(strong->_slots.size()),
                @"lateMs":@(target ? (double)SPHostToNs(fired-target)/1e6 : 0) }];
        }
        [strong drainDue]; [strong publishStats];
        if (strong->_measurementTrace) strong->_measurementFire = 0;
    });
    dispatch_resume(_clock);
    dispatch_source_set_timer(_clock, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
    if (_measurementTrace) {
        auto event = [self airMeasurementEvent:spAirMeasurement::Kind::timerPark];
        event.beginHostTicks = event.endHostTicks = SPHostNow();
        _measurementTrace->append(event);
    }
}

- (void)armClockAt:(int64_t)targetHost {
    [self ensureClock];
    const int64_t measurementRequestedDue = _measurementTrace ? targetHost : 0;
    int64_t now = SPHostNow();
    if (_haveRifeDeferred && _rifeDeferredRetryHost > now && _inflight < 2 && _rifeDeferredRetryHost < targetHost)
        targetHost = _rifeDeferredRetryHost;
    int64_t delta = targetHost > now ? targetHost - now : 0;
    int64_t ns = SPHostToNs(delta);
    if (ns < 0) ns = 0;
    spAirMeasurement::Event measurement;
    if (_measurementTrace) {
        measurement = [self airMeasurementEvent:spAirMeasurement::Kind::timerArm];
        measurement.relatedID = _measurementArm; _measurementArm = _measurementTrace->identity(); measurement.armID = _measurementArm;
        measurement.sampleHostTicks = now; measurement.values[0] = measurementRequestedDue;
        measurement.values[1] = targetHost; measurement.values[2] = ns; measurement.beginHostTicks = SPHostNow();
    }
    const dispatch_time_t measurementDeadline = dispatch_time(DISPATCH_TIME_NOW, ns);
    dispatch_source_set_timer(_clock, measurementDeadline, DISPATCH_TIME_FOREVER, 400 * NSEC_PER_USEC);
    if (_measurementTrace) { measurement.endHostTicks = SPHostNow(); measurement.values[3] = measurementDeadline; _measurementTrace->append(measurement); }
}

- (double)outputFramesPerSecond {
    if (_request.rateKind == SPLiveRateFixedFPS && _request.fpsDenominator > 0) {
        return (double)_request.fpsNumerator / (double)_request.fpsDenominator;
    }
    double source = 30.0;
    if (_haveInterval && _intervalHost > 0) {
        double seconds = (double)SPHostToNs(_intervalHost) / 1e9;
        if (seconds > 0.001) source = 1.0 / seconds;
    }
    if (!_request.interpolationEnabled) return source;
    int multiplier = [self rateBudgetEnabled] ? _effectiveMultiplier : (_request.multiplier > 0 ? (int)_request.multiplier : 1);
    return source * multiplier;
}

- (uint64_t)r8ReportedSlotBytes {
    if (!SPR8Enabled()) return 0;
    std::unordered_set<CVPixelBufferRef> unique;
    uint64_t bytes=0;
    for (const auto &slot : _slots) for (CVPixelBufferRef buffer : {slot.enhanced, slot.original}) {
        if (buffer && unique.insert(buffer).second) bytes += CVPixelBufferGetDataSize(buffer);
    }
    return bytes;
}
- (BOOL)r8CanExperiment {
    return SPR8Enabled() && _request.interpolationEnabled && _request.quality == SPFRCQualityHigh && !_request.scaleEnabled &&
        [_request.engineID isEqualToString:@"apple.frc"] && _width > 0 && _height > 0 &&
        _width <= 3840 && _height <= 2160;
}
- (uint64_t)r8QueueByteBudget {
    return [self r8CanExperiment] ? ((uint64_t)SPR8Option(@"--odf-r8-budget-mib", 160, @[@160,@320,@480]) << 20) : SPQueueByteBudget;
}
- (int)r8AdmissionLimit {
    return [self r8CanExperiment] ? SPR8Option(@"--odf-r8-inflight", 2, @[@1,@2,@3,@4]) : 2;
}
- (NSUInteger)slotCapByBytes {
    int w = _resolved.outputWidth > 0 ? _resolved.outputWidth : (_width > 0 ? _width : 1920);
    int h = _resolved.outputHeight > 0 ? _resolved.outputHeight : (_height > 0 ? _height : 1080);
    uint64_t planes = _request.viewMode == SPLiveViewCompare ? 2ull : 1ull;
    uint64_t bytes = (uint64_t)w * (uint64_t)h * 4ull * planes;
    if (bytes < 1) bytes = 1;
    NSUInteger cap = (NSUInteger)([self r8QueueByteBudget] / bytes);
    // The existing insert-then-evict path transiently has one extra slot.
    // Diagnostic budgets reserve it while preserving the regular path.
    if ([self r8CanExperiment] && cap > 3) cap -= 1;
    if (cap < 3) cap = 3;
    if (cap > 32) cap = 32;
    return cap;
}

- (NSUInteger)slotCap {
    NSUInteger byBytes = [self slotCapByBytes];
    double fps = [self outputFramesPerSecond];
    if (fps < 1) fps = 1;
    double delaySec = (double)SPHostToNs(_delayHost) / 1e9;
    NSUInteger byTime = (NSUInteger)(fps * delaySec + 0.999) + 2;
    if (byTime < 3) byTime = 3;
    return MIN(byBytes, byTime);
}

- (NSUInteger)inboundCap {
    double delaySec = (double)SPHostToNs(_delayHost) / 1e9;
    double sourceFps = 30.0;
    if (_haveInterval && _intervalHost > 0) {
        double seconds = (double)SPHostToNs(_intervalHost) / 1e9;
        if (seconds > 0.001) sourceFps = 1.0 / seconds;
    }
    NSUInteger cap = (NSUInteger)(sourceFps * delaySec + 0.999) + 2;
    if (cap < 4) cap = 4;
    if (cap > 12) cap = 12;
    return cap;
}

- (void)beginMeasurementEpoch {
    [self cancelSourceConversions];
    _r9FRCBudgetGate.reset();
    _r9RequiredBudgetMs = 0; _r9AllowedBudgetMs = 0;
    _r9OnTimeSynthetic = 0; _r9LatePhysicalSynthetic = 0; _r9TimingUnknownSynthetic = 0;
    _r9GeneratedFPS = -1; _r9OnTimeSyntheticFPS = -1; _r9RateHost = SPHostNow();
    _r9RateSyntheticBaseline = _syntheticOK; _r9RateOnTimeBaseline = 0;
    _processedSequence = 0;
    _lastProcessedHost = 0;
    _lastDrawablePresentedHost = 0;
    _nativeBudgetActive = NO;
    (void)[self nativeCadenceSnapshot];
    _nativeBudgetSkippedPhases = 0;
    _fpsMeter.resetOutput();
    _fpsObservationEpoch += 1;
    _latencyNs.clear();
    _frcNs.clear();
    _rateBudgetCompletedHosts.clear();
    [self cancelRateBudgetProbe];
    [self clearRateBudgetWindow];
    _scaleNs.clear();
    _transferNs.clear();
    _queueNs.clear();
    _playheadNs.clear();
    _drawableWaitNs.clear();
    _presentationAdmissionToCallbackNs.clear();
    _metalCommitToDisplayNs.clear();
    _displayScheduledTargetOffsetNs.clear();
    _presentGapNs.clear();
    _presentMediaLagNs.clear();
    _gpuToDisplayNs.clear();
    _captureToDisplayNs.clear();
    _captureToModelReadyNs.clear();
    _captureToOutputReadyNs.clear();
    _copyEntryNs.clear();
    _phaseRejectNoted = NO;
    memset(_epochHist, 0, sizeof(_epochHist));
    _epochSamples = 0;
    _epochDuplicates = 0;
    _epochSizeChanges = 0;
    _epochScheduled = 0;
    _epochStaticHoldPhases = 0;
    _epochPresentedSynthetic = 0;
    _epochPresentedSource = 0;
    _epochPhysicalSource = 0; _epochPhysicalSynthetic = 0; _physicalHavePts = NO;
    _epochDeadline = 0;
    _epochQueueDrops = 0;
    [_presentationFailuresEpoch removeAllObjects];
    [_firstPresentationFailureEpoch removeAllObjects];
    _epochMonotonic = YES;
    _epochHavePts = NO;
    _epochWidth = 0;
    _epochHeight = 0;
    _claimedDrops.clear();
    _frcEwmaSec = 0.025;
    _scaleEwmaSec = 0.004;
    _measurementEpoch += 1;
    [self.outputPreview setDiagnosticsConfig:_configVersion epoch:_measurementEpoch];
    _presentationOrder.reset(_sourceGeneration, _configVersion, _measurementEpoch);
    _presentationGeometry.reset();
    [self recomputeInteractiveDelay];
}

- (double)informationLeadSeconds:(double)interval {
    if (!_request.interpolationEnabled || _rateBudgetPassthrough || interval <= 0) return 0;
    if (_request.rateKind == SPLiveRateFixedFPS) return interval;
    int multiplier = [self rateBudgetEnabled] ? _effectiveMultiplier : (int)_request.multiplier;
    if (multiplier < 2) multiplier = 2;
    return interval * (double)(multiplier - 1) / (double)multiplier;
}

- (BOOL)noteUniqueSyntheticDrop:(sp::SPRational)pts {
    for (const auto &item : _claimedDrops) {
        if (sp::spCmp(item, pts) == 0) return NO;
    }
    _claimedDrops.push_back(pts);
    if (_claimedDrops.size() > 8192) _claimedDrops.erase(_claimedDrops.begin(), _claimedDrops.begin() + 2048);
    _deadlineDrops += 1;
    _epochDeadline += 1;
    [self noteRateBudgetDrop:pts];
    return YES;
}

- (BOOL)noteClockRetiredSyntheticDrop:(sp::SPRational)pts {
    for (const auto &item : _claimedDrops) if (sp::spCmp(item, pts) == 0) return NO;
    _claimedDrops.push_back(pts);
    if (_claimedDrops.size() > 8192) _claimedDrops.erase(_claimedDrops.begin(), _claimedDrops.begin()+2048);
    _clockRetiredPhaseDrops += 1;
    return YES;
}

// Retire only work tied to the previous PTS-to-host mapping. In-flight
// model/SR work remains bounded and its callback is rejected by clockEpoch.
- (void)retireClockTimeline {
    ++_clockEpoch;
    [self.preview setPresentationClockEpoch:_clockEpoch];
    [self.outputPreview setPresentationClockEpoch:_clockEpoch];
    _fpsMeter.resetOutput();
    _fpsObservationEpoch += 1;
    for (const auto &pending : _pending) {
        if ([self noteClockRetiredSyntheticDrop:pending.pts] && pending.jobID)
            [self recordR7JobEvent:@"clockRetiredDrop" detail:@{ @"id": @(pending.jobID), @"ptsNum": @(pending.pts.num), @"ptsDen": @(pending.pts.den), @"generation": @(pending.generation), @"config": @(pending.configVersion), @"clockEpoch": @(pending.clockEpoch), @"measurementEpoch": @(pending.measurementEpoch) }];
    }
    for (const auto &pending : _rifePending) [self noteClockRetiredSyntheticDrop:pending.pts];
    [self clearPendingRife];
    while (!_srPending.empty()) {
        SPSRJob *pending = _srPending.front(); _srPending.pop_front();
        _srPendingBytes = _srPendingBytes >= pending->bytes ? _srPendingBytes-pending->bytes : 0;
        if (pending->synthetic) [self noteClockRetiredSyntheticDrop:pending->pts];
        SPReleaseSRJob(pending);
    }
    for (const auto &slot : _slots) if (slot.synthetic && [self noteClockRetiredSyntheticDrop:slot.pts]) [self recordR9SlotDrop:slot reason:@"clockRetiredDrop"];
    _videoSRDiscontinuity = YES;
    _pending.clear();
    [self clearPlaySlots];
}

- (void)recomputeInteractiveDelay {
    double cap = _request.quality == SPFRCQualityHigh ? SPQualityCapSec : SPInteractiveCapSec;
#if defined(ODF_AIR_PRESENTATION_GUARD_DIAGNOSTIC) && ODF_AIR_PRESENTATION_GUARD_DIAGNOSTIC == 1
    if (_airInteractiveCap125msRequested && _request.quality != SPFRCQualityHigh) cap = 0.125;
#endif
    SPAirDelayAlignmentEvent alignmentEvent{};
    if (_airDelayAlignmentEvents) {
        alignmentEvent.hostTicks = SPHostNow(); alignmentEvent.generation = _sourceGeneration;
        alignmentEvent.config = _configVersion; alignmentEvent.epochBefore = _measurementEpoch;
        alignmentEvent.requestedMultiplier = (int)_request.multiplier; alignmentEvent.effectiveMultiplier = _effectiveMultiplier;
        alignmentEvent.capNs = (int64_t)llround(cap * 1e9);
        alignmentEvent.robustSourceLeadRequested = _airRobustSourceLeadRequested;
        alignmentEvent.positiveIntervalHistoryCount = _airRobustSourceLeadHistory.historyCount();
        alignmentEvent.positiveIntervalObservedCount = _airRobustSourceLeadHistory.observedIntervals();
    }
    _airRobustSourceLeadApplied = NO;
    _airSourceLeadEvaluation = _airRobustSourceLeadHistory.evaluate(0, false);
    _airDelayAlignmentActiveX2 = NO;
    _airDelayAlignmentLeadNs = 0;
    _airDelayAlignmentMarginNs = 0;
    // There is no future temporal phase to wait for in source-only output.
    // Scaling finishes before enqueue; its actual cost is not an extra queue
    // delay. In-flight work remains owned by its original epoch.
    if (SPR7Passthrough() || !_request.interpolationEnabled || _rateBudgetPassthrough) {
        _delayHost = 0;
        _r9RequiredBudgetMs = 0;
        _r9AllowedBudgetMs = 0;
        _delayClamped = NO;
        _delayTimeClamped = NO;
        _delayByteClamped = NO;
        _delayClampNoted = NO;
        if (_airDelayAlignmentEvents) {
            alignmentEvent.sourceOnly = true; alignmentEvent.epochAfter = _measurementEpoch;
            alignmentEvent.finalNs = SPHostToNs(_delayHost); _airDelayAlignmentEvents->append(alignmentEvent);
        }
        return;
    }
    double interval = 1.0 / 30.0;
    if (_haveInterval && _intervalHost > 0) {
        double seconds = (double)SPHostToNs(_intervalHost) / 1e9;
        if (seconds > 0.001) interval = seconds;
    }
#if defined(ODF_AIR_PRESENTATION_GUARD_DIAGNOSTIC) && ODF_AIR_PRESENTATION_GUARD_DIAGNOSTIC == 1
    if (!_airTrueSourceIntervalRequested && interval > 1.0 / 30.0) interval = 1.0 / 30.0;
#else
    if (interval > 1.0 / 30.0) interval = 1.0 / 30.0;
#endif
    double lead = [self informationLeadSeconds:interval];
    _airRobustSourceLeadApplied = _airRobustSourceLeadRequested && (SPAirBetaEnabled() || _airPerformanceEnabled) &&
        [_request.engineID isEqualToString:@"rife.metal"] && _request.rateKind == SPLiveRateMultiplier && _request.multiplier == 2;
    _airSourceLeadEvaluation = _airRobustSourceLeadHistory.evaluate(lead, _airRobustSourceLeadApplied);
    lead = _airSourceLeadEvaluation.leadSeconds;
    double frc = _frcEwmaSec;
    if (_frcNs.size() >= 8) {
        std::vector<int64_t> recent = _frcNs;
        if (recent.size() > 32) recent.erase(recent.begin(), recent.end() - 32);
        std::sort(recent.begin(), recent.end());
        size_t index = (recent.size() - 1) * 80 / 100;
        frc = MAX(frc, (double)recent[index] / 1e9);
    }
    double process = frc + (_request.scaleEnabled ? _scaleEwmaSec : 0);
    if ([self usesFixedSourceReuse] && _fixedMaxBatchCount > 0)
        process = MAX(process, _fixedRateBudget.taskMs(_fixedMaxBatchCount) / 1000.0 + (_request.scaleEnabled ? _scaleEwmaSec : 0));
    if ([_request.engineID isEqualToString:@"apple.frc"] && _captureToOutputReadyNs.size() >= 8) {
        // This includes input wait, model, output conversion and scaling up to
        // enqueue-ready; callback-only model latency is not output readiness.
        std::vector<int64_t> recent = _captureToOutputReadyNs;
        if (recent.size() > 32) recent.erase(recent.begin(), recent.end() - 32);
        std::sort(recent.begin(), recent.end());
        process = MAX(process, (double)recent[(recent.size() - 1) * 80 / 100] / 1e9);
    }
    if (process < 0.008) process = 0.008;
    double renderMargin = 0.016;
    if (_airDelayAlignmentRequested && _request.rateKind == SPLiveRateMultiplier && _request.multiplier == 2 &&
        _effectiveMultiplier == 2 && ([_request.engineID isEqualToString:@"rife.metal"]
#if defined(ODF_AIR_PRESENTATION_GUARD_DIAGNOSTIC) && ODF_AIR_PRESENTATION_GUARD_DIAGNOSTIC == 1
        || [_request.engineID isEqualToString:@"apple.frc"]
#endif
        )) {
        SPLivePreviewView *timedView = self.outputPreview.windowVisibleSnapshot ? self.outputPreview : self.preview;
        _airDelayAlignmentLeadNs = MAX((int64_t)16000000, [timedView presentationPreparationLeadNs]);
        _airDelayAlignmentMarginNs = _airDelayAlignmentLeadNs + 3000000;
        _airDelayAlignmentActiveX2 = YES;
        renderMargin = (double)_airDelayAlignmentMarginNs / 1e9;
    }
    double wanted = lead + process + renderMargin;
    if (_lowLatency && [self requestUsesLowPrescale:_request width:_width height:_height] && _captureToOutputReadyNs.size() >= 8) {
        // Include actual capture-to-ready time, which also covers pre-scaling,
        // conversion, asynchronous delivery and comparison baseline work.
        double observed = SPPercentileMs(_captureToOutputReadyNs) / 1000.0;
        if (observed > 0) wanted = MAX(wanted, lead + observed + 0.008);
    }
    if (wanted < lead + 0.012) wanted = lead + 0.012;
    BOOL timeClamped = wanted > cap;
    BOOL byteClamped = NO;
    BOOL clamped = timeClamped;
    double delay = clamped ? cap : wanted;
    double fps = [self outputFramesPerSecond];
    if (fps < 1) fps = 1;
    NSUInteger byBytes = [self slotCapByBytes];
    double queueLimit = (double)(byBytes > 2 ? byBytes - 2 : 1) / fps;
    _r9RequiredBudgetMs = wanted * 1000.0;
    _r9AllowedBudgetMs = MIN(cap, queueLimit) * 1000.0;
    if (delay > queueLimit) {
        delay = queueLimit;
        clamped = YES;
        byteClamped = YES;
    }
    if (delay > cap) {
        delay = cap;
        clamped = YES;
    }
    int64_t next = SPRationalToHost(sp::spMake((int64_t)llround(delay * 1000.0), 1000));
    const int64_t roundedDelayHost = next;
    if (_delayHost > next) {
        double current = (double)SPHostToNs(_delayHost) / 1e9;
        if (current > cap + 0.001) {
            [self retireClockTimeline];
            _haveAnchor = NO;
            _haveLastPts = NO;
        } else {
            // RIFE source and midpoint deadlines share the same timeline.
            // Shrinking by half a source interval can collapse the next
            // midpoint onto the previous source deadline during 60→120.
            const BOOL rifeTimeline = _request.interpolationEnabled && [_request.engineID isEqualToString:@"rife.metal"];
            int64_t maxDrop = (_haveInterval && _intervalHost > 0) ? _intervalHost / (rifeTimeline ? 8 : 2) : SPRationalToHost(sp::spMake(rifeTimeline ? 2 : 8, 1000));
            if (_delayHost - next > maxDrop) next = _delayHost - maxDrop;
        }
    }
    BOOL nativePassthrough = [self nativeBudgetForSnapshot:[self nativeCadenceSnapshot]];
    if (clamped && !nativePassthrough && !_delayClampNoted && !_rife && ![self requestUsesLatestPresentation:_request]) {
        _delayClampNoted = YES;
        [self publishStatus:@"互动预算已用尽，赶不上的帧会计入覆盖率" failed:YES];
    } else if (nativePassthrough && _delayClampNoted) {
        // UI clears only this particular old warning after a fresh matching
        // statistics snapshot. Do not overwrite unrelated failure statuses.
        _delayClampNoted = NO;
    } else if (!clamped && _delayClampNoted) {
        _delayClampNoted = NO;
        if (!_holdFailureStatus) {
            NSString *status = _resolved.interpolationActive ? @"增强运行" : (_resolved.scaleActive ? @"缩放运行" : @"预览原画面");
            [self publishStatus:status failed:NO];
        }
    } else if (!clamped) {
        _delayClampNoted = NO;
    }
    _delayClamped = clamped;
    _delayTimeClamped = timeClamped;
    _delayByteClamped = byteClamped;
    _delayHost = next;
    if (_airDelayAlignmentEvents) {
        alignmentEvent.calculated = true; alignmentEvent.activeX2 = _airDelayAlignmentActiveX2;
        alignmentEvent.epochAfter = _measurementEpoch;
        alignmentEvent.intervalNs = (int64_t)llround(interval * 1e9); alignmentEvent.modelNs = (int64_t)llround(frc * 1e9);
        alignmentEvent.processNs = (int64_t)llround(process * 1e9); alignmentEvent.presentationLeadNs = _airDelayAlignmentLeadNs;
        alignmentEvent.robustSourceLeadApplied = _airRobustSourceLeadApplied;
        alignmentEvent.oldSourceLeadNs = (int64_t)llround(_airSourceLeadEvaluation.oldLeadSeconds * 1e9);
        alignmentEvent.actualSourceLeadNs = (int64_t)llround(_airSourceLeadEvaluation.leadSeconds * 1e9);
        alignmentEvent.positiveIntervalP95Ns = (int64_t)llround(_airSourceLeadEvaluation.p95IntervalSeconds * 1e9);
        alignmentEvent.renderMarginNs = (int64_t)llround(renderMargin * 1e9); alignmentEvent.wantedNs = (int64_t)llround(wanted * 1e9);
        alignmentEvent.queueLimitNs = (int64_t)llround(queueLimit * 1e9); alignmentEvent.roundedNs = SPHostToNs(roundedDelayHost);
        alignmentEvent.finalNs = SPHostToNs(_delayHost); alignmentEvent.timeClamped = timeClamped; alignmentEvent.byteClamped = byteClamped;
        _airDelayAlignmentEvents->append(alignmentEvent);
    }
}

- (int64_t)targetHostForPTS:(sp::SPRational)pts {
    if (!_haveAnchor) return SPHostNow() + _delayHost;
    sp::SPRational delta{};
    if (!sp::spSub(pts, _anchorPts, delta)) return SPHostNow() + _delayHost;
    return _anchorHost + SPRationalToHost(delta) + _delayHost;
}

- (BOOL)usesRifePairAffineClock {
    return SPRifePairAffineClockEnabled() && _request.interpolationEnabled &&
        [_request.engineID isEqualToString:@"rife.metal"] && _request.rateKind == SPLiveRateMultiplier;
}

- (sp::RifePairClockContext)rifePairClockContext {
    return {_sourceGeneration, _configVersion, _measurementEpoch, _clockEpoch};
}

// The caller has observed this accepted real source before entering here. The
// endpoint is immutable; B remains the same endpoint when it becomes the next A.
- (void)freezeRifeSourceClockIdentity:(uint64_t)identity generation:(uint64_t)generation {
    auto found=_held.find(identity);
    if(generation!=_sourceGeneration || found==_held.end() || found->second.pairClockSource.frozen) return;
    int64_t delay=_delayHost, candidate=[self targetHostForPTS:found->second.pts];
    if(!sp::freezeRifeSourceClockTarget(found->second.pairClockSource,[self rifePairClockContext],found->second.pts,candidate,delay)) return;
    NSDictionary *value=@{ @"sourceIdentity":@(identity), @"source":SPRifeSourceClockValue(found->second.pairClockSource) };
    [self recordR7JobEvent:@"pairAffineSourceFrozen" detail:value];
    if(_testCapturePlayout) {
        if(!_testTimingTrace) _testTimingTrace=[NSMutableArray array];
        if(_testTimingTrace.count<80) { NSMutableDictionary *trace=[value mutableCopy]; trace[@"kind"]=@"pairAffineSourceFrozen"; [_testTimingTrace addObject:trace]; }
    }
}

- (sp::RifePairClockTarget)rifePairClockTargetForEvent:(const sp::SPScheduleOutput &)event {
    int64_t delay=_delayHost, candidate=[self targetHostForPTS:event.pts];
    auto a=_held.find(event.frameA), b=_held.find(event.frameB);
    return sp::rifePairClockTarget([self rifePairClockContext],event.pts,candidate,delay,
        a==_held.end() ? nullptr : &a->second.pairClockSource,
        b==_held.end() ? nullptr : &b->second.pairClockSource);
}

- (void)recordRifePairClockPlan:(NSArray *)targets {
    NSDictionary *value=@{ @"targets":targets, @"rifePairAffineClock":@YES };
    [self recordR7JobEvent:@"pairAffinePlan" detail:value];
    if(!_r8OutputTimeline) _r8OutputTimeline=[NSMutableArray array];
    NSMutableDictionary *event=[value mutableCopy]; event[@"kind"]=@"pairAffinePlan"; event[@"host"]=@(SPHostNow());
    [_r8OutputTimeline addObject:event];
    if(_r8OutputTimeline.count>512) [_r8OutputTimeline removeObjectAtIndex:0];
}

- (void)recordRifeSourceEnqueueClock:(uint64_t)identity pts:(sp::SPRational)pts selected:(int64_t)selected stage:(NSString *)stage {
    auto source=_held.find(identity);
    if(source==_held.end()) return;
    const int64_t delay=_delayHost, legacy=[self targetHostForPTS:pts];
    NSDictionary *value=@{ @"sourceIdentity":@(identity),@"ptsNum":@(pts.num),@"ptsDen":@(pts.den),
        @"generation":@(_sourceGeneration),@"configVersion":@(_configVersion),@"measurementEpoch":@(_measurementEpoch),@"clockEpoch":@(_clockEpoch),
        @"captureHost":@(source->second.host),@"candidateStage":stage,
        @"legacyCandidateTargetHost":@(legacy),@"legacyCandidateDelayHost":@(delay),
        @"canonicalSource":SPRifeSourceClockValue(source->second.pairClockSource),
        @"selectedTargetHost":@(selected>0 ? selected : legacy),
        @"selectedMinusLegacyHost":@((selected>0 ? selected : legacy)-legacy) };
    [self recordR7JobEvent:@"pairAffineSourceEnqueue" detail:value];
    if(!_r8OutputTimeline) _r8OutputTimeline=[NSMutableArray array];
    NSMutableDictionary *event=[value mutableCopy]; event[@"kind"]=@"pairAffineSourceEnqueue"; event[@"host"]=@(SPHostNow());
    [_r8OutputTimeline addObject:event];
    if(_r8OutputTimeline.count>512) [_r8OutputTimeline removeObjectAtIndex:0];
}

- (void)noteSourceClock:(sp::SPRational)pts host:(int64_t)host {
    if (host <= 0) host = SPHostNow();
    BOOL traceHadAnchor = _haveAnchor;
    BOOL traceErrorValid = _haveAnchor;
    BOOL traceReanchored = NO;
    int64_t traceError = 0;
    sp::SPRational traceOldAnchor = _anchorPts;
    if (_haveAnchor) {
        int64_t expected = [self targetHostForPTS:pts] - _delayHost;
        int64_t error = host - expected;
        traceError = error;
        if (error < 0) error = -error;
        if (SPHostToNs(error) > 150000000LL) {
            traceReanchored = YES;
            [self retireClockTimeline];
            _anchorPts = pts;
            _anchorHost = host;
            _haveLastPts = NO;
        }
    } else if (!_haveAnchor) {
        _anchorPts = pts;
        _anchorHost = host;
        _haveAnchor = YES;
    }
    if (_havePreviousSourcePts) {
        sp::SPRational delta{};
        if (sp::spSub(pts, _previousSourcePts, delta) && sp::spCmp(delta, sp::spMake(0, 1)) > 0) {
            if (_airRobustSourceLeadRequested || _airPerformanceRequested)
                _airRobustSourceLeadHistory.observePositiveInterval((double)delta.num / (double)delta.den);
            int64_t interval = SPRationalToHost(delta);
            if (interval > 0) {
                _intervalHost = _haveInterval ? (_intervalHost * 3 + interval) / 4 : interval;
                _haveInterval = YES;
                [self recomputeInteractiveDelay];
                [self refreshResolvedOnQueue];
            }
        }
    }
    _previousSourcePts = pts;
    _havePreviousSourcePts = YES;
    if (_testCapturePlayout && _testTimingTrace.count < 80) {
        if (!_testTimingTrace) _testTimingTrace=[NSMutableArray array];
        [_testTimingTrace addObject:@{ @"kind":@"sourceClock", @"ptsNum":@(pts.num), @"ptsDen":@(pts.den),
            @"hadAnchor":@(traceHadAnchor), @"oldAnchorPtsNum":@(traceOldAnchor.num), @"oldAnchorPtsDen":@(traceOldAnchor.den),
            @"reanchored":@(traceReanchored), @"clockErrorValid":@(traceErrorValid), @"clockErrorMs":@((double)SPHostToNs(traceError)/1e6),
            @"anchorPtsNum":@(_anchorPts.num), @"anchorPtsDen":@(_anchorPts.den),
            @"anchorHostFromSourceMs":@((double)SPHostToNs(_anchorHost-host)/1e6), @"delayMs":@((double)SPHostToNs(_delayHost)/1e6) }];
    }
}

// Observe only actual source identity/PTS, not synthetic or hold output PTS.
// Scheduler output can mention an older source after the current input, so
// ignore duplicate and backwards observations rather than updating EWMA twice.
- (void)observeSourceIdentity:(uint64_t)identity {
    auto found = _held.find(identity);
    if (found == _held.end()) return;
    const auto pts = found->second.pts;
    if (_havePreviousSourcePts && sp::spCmp(pts, _previousSourcePts) <= 0) return;
    [self noteSourceClock:pts host:found->second.host];
}

- (void)erasePending:(sp::SPRational)pts {
    _pending.erase(std::remove_if(_pending.begin(), _pending.end(), [&](const SPPendingPhase &item) {
        return sp::spCmp(item.pts, pts) == 0;
    }), _pending.end());
}

- (BOOL)waitForPendingBefore:(sp::SPRational)pts now:(int64_t)now earliest:(int64_t *)earliest {
    BOOL wait = NO;
    for (auto it = _pending.begin(); it != _pending.end();) {
        if (it->generation != _sourceGeneration || sp::spCmp(it->pts, pts) >= 0) {
            ++it;
            continue;
        }
        if ([self requestUsesLatestPresentation:_request]) {
            [self noteUniqueSyntheticDrop:it->pts];
            it = _pending.erase(it);
            continue;
        }
        if (it->targetHost > now) {
            if (!wait || it->targetHost < *earliest) *earliest = it->targetHost;
            wait = YES;
            ++it;
            continue;
        }
        if (_testCapturePlayout && _testPendingTrace.count < 24) {
            if (!_testPendingTrace) _testPendingTrace=[NSMutableArray array];
            [_testPendingTrace addObject:@{ @"kind":@"expired", @"ptsNum":@(it->pts.num), @"ptsDen":@(it->pts.den),
                @"lateMs":@((double)SPHostToNs(now-it->targetHost)/1e6), @"delayMs":@((double)SPHostToNs(_delayHost)/1e6) }];
        }
        if ([self noteUniqueSyntheticDrop:it->pts]) {
            _pendingExpiredDrops++;
            if (it->jobID) [self recordR7JobEvent:@"pendingExpiredDrop" detail:@{ @"id": @(it->jobID), @"ptsNum": @(it->pts.num), @"ptsDen": @(it->pts.den), @"generation": @(it->generation), @"config": @(it->configVersion), @"clockEpoch": @(it->clockEpoch), @"measurementEpoch": @(it->measurementEpoch), @"targetHost": @(it->targetHost) }];
        }
        it = _pending.erase(it);
    }
    return wait;
}

- (CVPixelBufferRef)scaleBuffer:(CVPixelBufferRef)bgra with:(SPSpatialScaler *)scaler {
    if (!bgra) return NULL;
    if (!scaler) {
        CVPixelBufferRetain(bgra);
        return bgra;
    }
    int64_t started = SPHostNow();
    CVPixelBufferRef scaled = [scaler scaleBuffer:bgra error:NULL];
    int64_t ns = SPHostToNs(SPHostNow() - started);
    SPPushSample(_scaleNs, ns);
    double seconds = (double)ns / 1e9;
    _scaleEwmaSec = _scaleEwmaSec <= 0 ? seconds : (0.8 * _scaleEwmaSec + 0.2 * seconds);
    return scaled;
}

- (void)prepareDiagnosticOutput:(CVPixelBufferRef)enhanced original:(CVPixelBufferRef)original
                    captureHost:(int64_t)captureHost frameID:(uint64_t)frameID
                             pts:(sp::SPRational)pts synthetic:(BOOL)synthetic {
    if (!_pixelDiagnosticsEnabled || captureHost <= 0) return;
    NSNumber *key = @(captureHost);
    NSDictionary *input = _pixelInputSamples[key];
    if (!input) return;
    [_pixelInputSamples removeObjectForKey:key];
    [_pixelInputOrder removeObject:key];
    if ([input[@"sourceGeneration"] unsignedLongLongValue] != _sourceGeneration ||
        [input[@"configVersion"] unsignedLongLongValue] != _configVersion) { _pixelInputExpired++; return; }
    if (_pixelPendingOutput) _pixelOutputUnmatchedCallback++;
    CVPixelBufferRef primary = _request.viewMode == SPLiveViewOriginal ? (original ?: enhanced) : enhanced;
    NSDictionary *output = SPPixelFingerprintBuffer(primary);
    _pixelOutputMatched++;
    _pixelPendingOutput = @{ @"sourceGeneration": @(_sourceGeneration), @"configVersion": @(_configVersion),
        @"measurementEpoch": @(_measurementEpoch), @"captureHost": @(captureHost), @"frameID": @(frameID),
        @"ptsNum": @(pts.num), @"ptsDen": @(pts.den), @"synthetic": @(synthetic), @"viewMode": @(_request.viewMode),
        @"input": input, @"outputBuffer": output, @"submissionState": @"pending" };
    _pixelLastOutputSubmitted = _pixelPendingOutput;
}

- (void)showPair:(CVPixelBufferRef)enhanced
        original:(CVPixelBufferRef)original
             pts:(sp::SPRational)pts
       synthetic:(BOOL)synthetic
     captureHost:(int64_t)captureHost
    geometryHost:(int64_t)geometryHost
         frameID:(uint64_t)frameID
presentationHost:(int64_t)presentationHost
          redraw:(BOOL)redraw {
    [self.preview setDiagnosticsConfig:_configVersion epoch:_measurementEpoch];
    [self.outputPreview setDiagnosticsConfig:_configVersion epoch:_measurementEpoch];
    [self.preview setPresentationClockEpoch:_clockEpoch];
    [self.outputPreview setPresentationClockEpoch:_clockEpoch];
    BOOL outputVisible = self.outputPreview.windowVisibleSnapshot;
    if (_scoreOutput != outputVisible) { _fpsMeter.resetOutput(); _fpsObservationEpoch += 1; _presentationGeometry.reset(); }
    _scoreOutput = outputVisible;
    uint64_t generation = _sourceGeneration;
    BOOL previewCounts = redraw ? NO : !outputVisible;
    BOOL outputCounts = redraw ? NO : outputVisible;
    if (self.preview) {
        NSString *reason = nil;
        BOOL accepted = [self.preview presentEnhanced:enhanced original:original mode:_request.viewMode
                                          captureHost:captureHost generation:generation
                                               ptsNum:pts.num ptsDen:pts.den synthetic:synthetic
                                              frameID:frameID counts:previewCounts captureGeometry:nil presentationHost:presentationHost redraw:redraw reason:&reason];
        if (!accepted && previewCounts) { _renderDrops += 1; [self recordPresentationFailure:reason endpoint:@"preview" generation:generation config:_configVersion epoch:_measurementEpoch frame:frameID
            details:@{ @"ptsNum": @(pts.num), @"ptsDen": @(pts.den), @"logicalTargetHost": @(presentationHost), @"synthetic": @(synthetic) }]; }
    }
    if (self.outputPreview) {
        if (SPR8FixtureEnabled() && outputCounts) {
            if (!_r8OutputTimeline) _r8OutputTimeline = [NSMutableArray array];
            CVPixelBufferRef primary = _request.viewMode == SPLiveViewOriginal ? (original ?: enhanced) : enhanced;
            int code = SPR8DecodeFixture(primary);
            NSDictionary *motion = SPR8FixtureMotion(primary);
            [_r8OutputTimeline addObject:@{ @"kind": @"submitted", @"frameID": @(frameID),
                @"generation": @(generation), @"configVersion": @(_configVersion), @"measurementEpoch": @(_measurementEpoch),
                @"captureHost": @(captureHost), @"submitHost": @(SPHostNow()), @"clockEpoch": @(_clockEpoch),
                @"logicalTargetHost": @(presentationHost),
                @"geometryVersion": [NSNull null], @"ptsNum": @(pts.num), @"ptsDen": @(pts.den),
                @"synthetic": @(synthetic), @"decoded": @(code >= 0), @"frameNumber": @(code), @"motion": motion }];
            if (_r8OutputTimeline.count > 512) [_r8OutputTimeline removeObjectAtIndex:0];
        }
        if (_pixelDiagnosticsEnabled && !redraw && outputVisible && self.outputPreview.drawableVisibleSnapshot && self.outputPreview.exposedSnapshot)
            [self prepareDiagnosticOutput:enhanced original:original captureHost:geometryHost frameID:frameID pts:pts synthetic:synthetic];
        NSString *reason = nil;
        BOOL accepted = [self.outputPreview presentEnhanced:enhanced original:original mode:_request.viewMode
                                                captureHost:captureHost generation:generation
                                                     ptsNum:pts.num ptsDen:pts.den synthetic:synthetic
                                                    frameID:frameID counts:outputCounts captureGeometry:_geometryInputs[@(captureHost)] presentationHost:presentationHost redraw:redraw reason:&reason];
        if (_pixelPendingOutput && [_pixelPendingOutput[@"frameID"] unsignedLongLongValue] == frameID) {
            NSMutableDictionary *submitted = [_pixelPendingOutput mutableCopy];
            submitted[@"submissionState"] = accepted ? @"accepted" : @"rejected";
            if (!accepted) submitted[@"submissionFailure"] = reason ?: @"unknown";
            _pixelLastOutputSubmitted = [submitted copy];
            _pixelPendingOutput = accepted ? _pixelLastOutputSubmitted : nil;
        }
        if (!accepted && outputCounts) { _renderDrops += 1; [self recordPresentationFailure:reason endpoint:@"output" generation:generation config:_configVersion epoch:_measurementEpoch frame:frameID
            details:@{ @"ptsNum": @(pts.num), @"ptsDen": @(pts.den), @"logicalTargetHost": @(presentationHost), @"synthetic": @(synthetic) }]; }
    }
}

- (void)drainDue {
    int64_t now = SPHostNow();
    uint64_t measurementDrainID = 0;
    if (_measurementTrace) { auto event = [self airMeasurementEvent:spAirMeasurement::Kind::drainEntry];
        event.beginHostTicks = event.endHostTicks = event.sampleHostTicks = now;
        event.groupID = _measurementTrace->identity(); measurementDrainID = event.groupID; event.relatedID = _measurementFire;
        event.values[0] = _slots.size(); event.values[1] = _pending.size(); _measurementTrace->append(event); }
    [self expireDeferredRifeAt:now];
    if (_haveRifeDeferred && _rifeDeferredRetryHost > 0 && _rifeDeferredRetryHost <= now) [self resumeDeferredRife];
    int64_t slop = SPRationalToHost(sp::spMake(1, 1000));
    // Hand ready buffers to the bounded display-link queue ahead of time.
    // This lead does not change logical targets or due-merge eligibility.
    SPLivePreviewView *timedView = self.outputPreview.windowVisibleSnapshot ? self.outputPreview : self.preview;
    int64_t observedLeadNs = MAX((int64_t)16000000, [timedView presentationPreparationLeadNs]);
    int64_t prepareLead = [self requestUsesLatestPresentation:_request] ? 0 :
        SPRationalToHost(sp::spMake(observedLeadNs + (_airPerformanceEnabled ? 3000000 : 0), 1000000000));
    while (!_slots.empty()) {
        int64_t earliest = 0;
        if ([self waitForPendingBefore:_slots.front().pts now:now earliest:&earliest]) {
            [self armClockAt:earliest];
            return;
        }
        if (_slots.front().targetHost > now + slop + prepareLead) {
            [self armClockAt:_slots.front().targetHost - prepareLead];
            return;
        }
        while (_slots.size() > 1 && _slots[1].targetHost <= now + slop) {
            if (_slots.front().synthetic && [self noteUniqueSyntheticDrop:_slots.front().pts]) {
                _dueMergeDrops++; [self recordR9SlotDrop:_slots.front() reason:@"dueMergeDrop"];
            }
            if (!_slots.front().synthetic) _sourceDueMergeDrops++;
            [self erasePending:_slots.front().pts];
            _marks.erase(_slots.front().frameID);
            SPReleaseSlot(_slots.front());
            _slots.erase(_slots.begin());
        }
        if (_slots.empty()) break;
        if (_slots.front().targetHost > now + slop + prepareLead) {
            [self armClockAt:_slots.front().targetHost - prepareLead];
            return;
        }
        SPPlaySlot slot = _slots.front();
        _slots.erase(_slots.begin());
        if (slot.sourceGeneration != _sourceGeneration || slot.configVersion != _configVersion) {
            _marks.erase(slot.frameID);
            SPReleaseSlot(slot);
            continue;
        }
        if (_haveLastPts && sp::spCmp(slot.pts, _lastPresentedPts) <= 0) {
            if (slot.synthetic) {
                if ([self noteUniqueSyntheticDrop:slot.pts]) [self recordR9SlotDrop:slot reason:@"stalePlayoutDrop"];
            } else _sourceStaleDrops++;
            _marks.erase(slot.frameID);
            SPReleaseSlot(slot);
            continue;
        }
        if (_measurementTrace) {
            auto event = [self airMeasurementEvent:spAirMeasurement::Kind::drainEntry];
            event.beginHostTicks = event.endHostTicks = SPHostNow(); event.relatedID = measurementDrainID;
            event.frameID = slot.frameID; event.generation = slot.sourceGeneration; event.config = slot.configVersion;
            event.epoch = slot.measurementEpoch; event.clock = slot.clockEpoch; event.ptsNum = slot.pts.num;
            event.ptsDen = slot.pts.den; event.targetHostTicks = slot.targetHost; event.sampleHostTicks = slot.readyHost;
            event.flags = (slot.synthetic ? 1u : 0u) | 8u | 256u;
            event.values[0] = observedLeadNs; event.values[1] = prepareLead; event.values[2] = _measurementFire;
            _measurementTrace->append(event);
        }
        [self showPair:slot.enhanced original:slot.original pts:slot.pts synthetic:slot.synthetic
           captureHost:slot.captureHost geometryHost:slot.geometryHost frameID:slot.frameID
       presentationHost:slot.targetHost redraw:NO];
        if (slot.fixedFallback) {
            _fixedFallbackPresented++;
            for (const auto &pending : _pending) if (sp::spCmp(pending.pts, slot.pts) == 0) {
                if ([self noteUniqueSyntheticDrop:slot.pts]) _pendingExpiredDrops++;
                break;
            }
            [self erasePending:slot.pts];
        }
        if (_testCapturePlayout) {
            _testPlayout.emplace_back(slot.pts, slot.synthetic);
            auto mark = _marks.find(slot.frameID);
            if (mark != _marks.end() && mark->second.held) _testHoldPlayout.push_back(slot.pts);
        }
        [self rememberPair:slot.enhanced original:slot.original pts:slot.pts synthetic:slot.synthetic geometryHost:slot.geometryHost targetHost:slot.targetHost];
        _lastPresentedPts = slot.pts;
        _haveLastPts = YES;
        SPReleaseSlot(slot);
        if (_slots.empty()) {
            [self armClockAt:now + SPRationalToHost(sp::spMake(1, 10))];
            return;
        }
        [self armClockAt:_slots.front().targetHost - prepareLead];
        return;
    }
    [self armClockAt:now + SPRationalToHost(sp::spMake(1, 10))];
}

- (void)enqueueReadyEnhanced:(CVPixelBufferRef)enhanced
                    original:(CVPixelBufferRef)original
                         pts:(sp::SPRational)pts
                   synthetic:(BOOL)synthetic
                         held:(BOOL)held
                 captureHost:(int64_t)captureHost
                  generation:(uint64_t)generation
                deadlineHost:(int64_t)deadlineHost {
    [self enqueueReadyEnhanced:enhanced original:original pts:pts synthetic:synthetic held:held
                  captureHost:captureHost generation:generation deadlineHost:deadlineHost jobID:0];
}

- (void)enqueueReadyEnhanced:(CVPixelBufferRef)enhanced
                    original:(CVPixelBufferRef)original
                         pts:(sp::SPRational)pts
                   synthetic:(BOOL)synthetic
                         held:(BOOL)held
                 captureHost:(int64_t)captureHost
                  generation:(uint64_t)generation
                deadlineHost:(int64_t)deadlineHost
                       jobID:(uint64_t)jobID {
    [self enqueueReadyEnhanced:enhanced original:original pts:pts synthetic:synthetic held:held captureHost:captureHost generation:generation deadlineHost:deadlineHost jobID:jobID geometryHost:captureHost];
}

- (void)enqueueReadyEnhanced:(CVPixelBufferRef)enhanced original:(CVPixelBufferRef)original pts:(sp::SPRational)pts synthetic:(BOOL)synthetic held:(BOOL)held captureHost:(int64_t)captureHost generation:(uint64_t)generation deadlineHost:(int64_t)deadlineHost jobID:(uint64_t)jobID geometryHost:(int64_t)geometryHost {
    [self enqueueReadyEnhanced:enhanced original:original pts:pts synthetic:synthetic held:held captureHost:captureHost generation:generation deadlineHost:deadlineHost jobID:jobID geometryHost:geometryHost fixedFallback:NO];
}

- (void)enqueueReadyEnhanced:(CVPixelBufferRef)enhanced original:(CVPixelBufferRef)original pts:(sp::SPRational)pts synthetic:(BOOL)synthetic held:(BOOL)held captureHost:(int64_t)captureHost generation:(uint64_t)generation deadlineHost:(int64_t)deadlineHost jobID:(uint64_t)jobID geometryHost:(int64_t)geometryHost fixedFallback:(BOOL)fixedFallback {
    if (!enhanced || generation != _sourceGeneration) {
        if (enhanced) CVPixelBufferRelease(enhanced);
        if (original) CVPixelBufferRelease(original);
        return;
    }
    if (synthetic && captureHost > 0 && SPHostNow() > captureHost)
        SPPushSample(_captureToOutputReadyNs, SPHostToNs(SPHostNow() - captureHost));
    if (synthetic && _lowLatency && [self requestUsesLowPrescale:_request width:_width height:_height]) {
        [self recomputeInteractiveDelay];
        if (!_testKeepLowRealtime && _delayClamped) _lowPrescaleSlowMode = YES;
    }
    if (_haveLastPts && sp::spCmp(pts, _lastPresentedPts) <= 0) {
        if (synthetic && [self noteUniqueSyntheticDrop:pts]) {
            _staleReadyDrops++;
            if (jobID) [self recordR7JobEvent:@"staleReadyDrop" detail:@{ @"id": @(jobID), @"ptsNum": @(pts.num), @"ptsDen": @(pts.den), @"generation": @(generation), @"config": @(_configVersion), @"clockEpoch": @(_clockEpoch), @"measurementEpoch": @(_measurementEpoch) }];
        }
        if (!synthetic) _sourceStaleDrops++;
        [self erasePending:pts];
        CVPixelBufferRelease(enhanced);
        if (original) CVPixelBufferRelease(original);
        return;
    }
    SPPlaySlot slot;
    slot.pts = pts;
    slot.jobID = jobID;
    slot.clockEpoch = _clockEpoch;
    slot.measurementEpoch = _measurementEpoch;
    slot.targetHost = [self requestUsesLatestPresentation:_request] ? SPHostNow() : (deadlineHost > 0 ? deadlineHost : [self targetHostForPTS:pts]);
    slot.synthetic = synthetic;
    slot.fixedFallback = fixedFallback;
    slot.enhanced = enhanced;
    slot.original = original ?: CVPixelBufferRetain(enhanced);
    slot.frameID = ++_nextFrameID;
    slot.readyHost = SPHostNow();
    if (_measurementTrace && !synthetic) [self airMeasurementTarget:pts target:slot.targetHost frame:slot.frameID
        job:jobID phase:0 synthetic:NO computed:![self requestUsesLatestPresentation:_request] && deadlineHost <= 0];
    slot.sourceGeneration = generation;
    slot.configVersion = _configVersion;
    slot.captureHost = captureHost;
    slot.geometryHost = geometryHost;
    if (synthetic && !slot.jobID) for (const auto &pending : _pending) {
        if (pending.generation == generation && sp::spCmp(pending.pts, pts) == 0) { slot.jobID = pending.jobID; break; }
    }
    if (!fixedFallback) [self erasePending:pts];
    if (synthetic && ![self requestUsesLatestPresentation:_request] && slot.targetHost + SPRationalToHost(sp::spMake(2, 1000)) < slot.readyHost) {
        if ([self noteUniqueSyntheticDrop:pts]) {
            _lateReadyDrops++;
            if (slot.jobID) [self recordR7JobEvent:@"lateReadyDrop" detail:@{ @"id": @(slot.jobID), @"ptsNum": @(pts.num), @"ptsDen": @(pts.den), @"generation": @(generation), @"config": @(_configVersion), @"clockEpoch": @(_clockEpoch), @"measurementEpoch": @(_measurementEpoch), @"targetHost": @(slot.targetHost), @"readyHost": @(slot.readyHost) }];
        }
        SPReleaseSlot(slot);
        return;
    }
    if (_probeWindowOpen && _centerSamples < 8 && enhanced && original) {
        int64_t sampleStart = SPHostNow();
        slot.enhancedCenter = SPWhiteCenterX(enhanced);
        slot.originalCenter = SPWhiteCenterX(original);
        slot.hasCenter = slot.enhancedCenter >= 0 || slot.originalCenter >= 0;
        _centerSampleNs += (uint64_t)SPHostToNs(SPHostNow() - sampleStart);
        _centerSamples += 1;
    }
    auto at = std::lower_bound(_slots.begin(), _slots.end(), slot, [](const SPPlaySlot &a, const SPPlaySlot &b) {
        return sp::spCmp(a.pts, b.pts) < 0;
    });
    if (at != _slots.end() && sp::spCmp(at->pts, pts) == 0 && [self usesFixedSourceReuse]) {
        if (synthetic && at->fixedFallback) {
            _marks.erase(at->frameID);
            SPReleaseSlot(*at);
            at = _slots.erase(at);
            _fixedFallbackReplaced++;
        } else {
            // A standby image must never replace an already-ready model frame.
            SPReleaseSlot(slot);
            return;
        }
    }
    const uint64_t measurementInsertBegin = _measurementTrace ? SPHostNow() : 0;
    _slots.insert(at, slot);
    if (_measurementTrace) {
        spAirMeasurement::Event event; event.kind = spAirMeasurement::Kind::slotInsert;
        event.beginHostTicks = measurementInsertBegin; event.endHostTicks = SPHostNow();
        event.frameID = slot.frameID; event.relatedID = slot.jobID; event.generation = slot.sourceGeneration;
        event.config = slot.configVersion; event.epoch = slot.measurementEpoch; event.clock = slot.clockEpoch;
        event.ptsNum = slot.pts.num; event.ptsDen = slot.pts.den; event.targetHostTicks = slot.targetHost;
        event.flags = (slot.synthetic ? 1u : 0u) | 8u; event.sampleHostTicks = slot.readyHost;
        event.values[0] = _slots.size() - 1; event.values[1] = _slots.size(); _measurementTrace->append(event);
    }
    if (_testRecordSRInput) {
        BOOL shape = CVPixelBufferGetWidth(slot.enhanced) == 1920 && CVPixelBufferGetHeight(slot.enhanced) == 1080 && CVPixelBufferGetPixelFormatType(slot.enhanced) == kCVPixelFormatType_32BGRA;
        if (slot.sourceGeneration == 1 && !slot.synthetic && sp::spCmp(slot.pts, sp::spMake(10,1)) == 0 && shape) {
            _testSRSourceSlot = YES;
            _testSRBaselineMatches = _testSRExpectedBaseline && slot.original && SPIdenticalSourcePixels(_testSRExpectedBaseline, slot.original);
            auto found = _held.find(11);
            _testSRIdentityMatches = slot.captureHost == _testSRExpectedHost && found != _held.end() && found->second.source == _testSRExpectedSource;
        }
        if (slot.sourceGeneration == 1 && slot.synthetic && sp::spCmp(slot.pts, sp::spMake(601,60)) == 0 && shape) _testSRSyntheticSlot = YES;
        if (slot.sourceGeneration == 2 && !slot.synthetic && sp::spCmp(slot.pts, sp::spMake(21,1)) == 0 && shape) _testSRNewGenerationSlot = YES;
    }
    SPFrameMark mark;
    mark.jobID = slot.jobID;
    mark.clockEpoch = slot.clockEpoch;
    mark.readyHost = slot.readyHost;
    mark.targetHost = slot.targetHost;
    mark.hasCenter = slot.hasCenter;
    mark.enhancedCenter = slot.enhancedCenter;
    mark.originalCenter = slot.originalCenter;
    mark.held = held;
    mark.fpsEpoch = _fpsObservationEpoch;
    _marks[slot.frameID] = mark;
    if (SPR8FixtureEnabled()) {
        if (!_r8OutputTimeline) _r8OutputTimeline = [NSMutableArray array];
        [_r8OutputTimeline addObject:@{ @"kind": @"enqueued", @"frameID": @(slot.frameID), @"jobID": @(slot.jobID),
            @"generation": @(generation), @"configVersion": @(_configVersion), @"measurementEpoch": @(_measurementEpoch),
            @"clockEpoch": @(_clockEpoch), @"geometryVersion": [NSNull null], @"captureHost": @(captureHost),
            @"readyHost": @(slot.readyHost), @"targetHost": @(slot.targetHost), @"ptsNum": @(pts.num), @"ptsDen": @(pts.den), @"synthetic": @(synthetic) }];
        if (_r8OutputTimeline.count > 512) [_r8OutputTimeline removeObjectAtIndex:0];
    }
    if (_slots.size() > _peakSlots) _peakSlots = _slots.size();
    if (SPR8Enabled()) {
        _r8SlotReferencePeak = MAX(_r8SlotReferencePeak, (uint64_t)_slots.size() * 2);
        _r8ReportedSlotBytesPeak = MAX(_r8ReportedSlotBytesPeak, [self r8ReportedSlotBytes]);
    }
    NSUInteger cap = [self slotCap];
    while (_slots.size() > cap || ([self r8CanExperiment] && [self r8ReportedSlotBytes] > [self r8QueueByteBudget])) {
        if ([self r8CanExperiment] && [self r8ReportedSlotBytes] > [self r8QueueByteBudget]) _r8BudgetEvictions++;
        auto victim = std::find_if(_slots.begin(), _slots.end(), [](const SPPlaySlot &item) { return item.fixedFallback; });
        if (victim == _slots.end()) victim = std::find_if(_slots.begin(), _slots.end(), [](const SPPlaySlot &item) { return item.synthetic; });
        if (victim == _slots.end()) victim = _slots.begin();
        if (victim->synthetic && [self noteUniqueSyntheticDrop:victim->pts]) {
            _slotEvictionDrops++; [self recordR9SlotDrop:*victim reason:@"slotEvictionDrop"];
        }
        if (!victim->synthetic) _sourceSlotEvictionDrops++;
        _marks.erase(victim->frameID);
        SPReleaseSlot(*victim);
        _slots.erase(victim);
    }
    [self ensureClock];
    [self drainDue];
}

- (CVPixelBufferRef)bgraFromSource:(CVPixelBufferRef)source {
    return [self transfer:source format:kCVPixelFormatType_32BGRA];
}

// Owns both buffers on entry. One active request plus at most two waiting
// requests share a conservative byte budget; no wait occurs on the live queue.
- (void)enqueueAsyncScale:(CVPixelBufferRef)input original:(CVPixelBufferRef)original
                     pts:(sp::SPRational)pts synthetic:(BOOL)synthetic held:(BOOL)held
             captureHost:(int64_t)captureHost generation:(uint64_t)generation deadlineHost:(int64_t)deadlineHost {
    [self enqueueAsyncScale:input original:original pts:pts synthetic:synthetic held:held captureHost:captureHost generation:generation deadlineHost:deadlineHost geometryHost:captureHost];
}

- (void)enqueueAsyncScale:(CVPixelBufferRef)input original:(CVPixelBufferRef)original pts:(sp::SPRational)pts synthetic:(BOOL)synthetic held:(BOOL)held captureHost:(int64_t)captureHost generation:(uint64_t)generation deadlineHost:(int64_t)deadlineHost geometryHost:(int64_t)geometryHost {
    if (!input || (!_appleSR && !_videoSR && !_animeSR && !_cuganSR && !_artCNNSR) || _srFailed) {
        if (input) CVPixelBufferRelease(input); if (original) CVPixelBufferRelease(original);
        if (synthetic) { [self erasePending:pts]; [self noteUniqueSyntheticDrop:pts]; }
        return;
    }
    if (_srInputScaler) {
        CVPixelBufferRef reduced = [self scaleBuffer:input with:_srInputScaler];
        CVPixelBufferRelease(input); input = reduced;
        if (!input) { [self publishStatus:@"超分输入缩放失败" failed:YES]; if (original) CVPixelBufferRelease(original); if (synthetic) { [self erasePending:pts]; [self noteUniqueSyntheticDrop:pts]; } return; }
    }
    if (_testRecordSRInput) { _testSRInputWidth = (int)CVPixelBufferGetWidth(input); _testSRInputHeight = (int)CVPixelBufferGetHeight(input); }
    uint64_t inputBytes = (uint64_t)CVPixelBufferGetBytesPerRow(input) * CVPixelBufferGetHeight(input);
    uint64_t originalBytes = original ? (uint64_t)CVPixelBufferGetBytesPerRow(original) * CVPixelBufferGetHeight(original) : 0;
    // Temporal video SR retains the previous RGBA-half output, plus the new
    // RGBA-half output and converted BGRA. Include all three in the budget.
    uint64_t outputBudget = (uint64_t)MAX(_resolved.outputWidth, 1) * (uint64_t)MAX(_resolved.outputHeight, 1) * (_videoSR ? 20 : (_cuganSR ? 16 : 8));
    uint64_t cost = inputBytes + originalBytes + outputBudget;
    BOOL latestScale = !_request.interpolationEnabled || [self requestUsesLatestScale:_request];
    if (latestScale && ((_srBusy && sp::spCmp(pts,_srActivePTS)<=0) ||
        (!_srPending.empty() && sp::spCmp(pts,_srPending.front()->pts)<=0))) {
        CVPixelBufferRelease(input);if(original)CVPixelBufferRelease(original);
        if(synthetic){[self erasePending:pts];[self noteUniqueSyntheticDrop:pts];}
        _queueDrops+=1;_epochQueueDrops+=1;return;
    }
    if (latestScale && !_srPending.empty()) {
        SPSRJob *replaced = _srPending.front(); _srPending.pop_front();
        _srPendingBytes = _srPendingBytes >= replaced->bytes ? _srPendingBytes - replaced->bytes : 0;
        if (replaced->synthetic) { [self erasePending:replaced->pts]; [self noteUniqueSyntheticDrop:replaced->pts]; }
        if (_videoSR) _videoSRDiscontinuity = YES;
        SPReleaseSRJob(replaced);
        _queueDrops += 1; _epochQueueDrops += 1;
    }
    if (_srPending.size() >= 2 || cost > SPQueueByteBudget || _srPendingBytes > SPQueueByteBudget - cost) {
        CVPixelBufferRelease(input); if (original) CVPixelBufferRelease(original);
        if (synthetic) { [self erasePending:pts]; [self noteUniqueSyntheticDrop:pts]; }
        if (_videoSR) _videoSRDiscontinuity = YES;
        _queueDrops += 1; _epochQueueDrops += 1;
        return;
    }
    SPSRJob *job = new SPSRJob();
    job->input = input; job->original = original; job->pts = pts; job->synthetic = synthetic;
    job->held = held;
    job->captureHost = captureHost; job->geometryHost = geometryHost; job->targetHost = deadlineHost; job->clockEpoch = _clockEpoch;
    job->sourceGeneration = generation; job->configVersion = _configVersion;
    job->sequence = _srSequence; job->bytes = cost;
    job->discontinuity = _videoSR && _videoSRDiscontinuity;
    if (_videoSR) _videoSRDiscontinuity = NO;
    _srPendingBytes += cost;
    _srPending.push_back(job);
    [self drainAsyncScaleOnQueue];
}

- (void)drainAsyncScaleOnQueue {
    if (_srBusy || _srFailed || _srPending.empty() || (!_appleSR && !_videoSR && !_animeSR && !_cuganSR && !_artCNNSR)) return;
    SPSRJob *job = _srPending.front();
    _srPending.pop_front();
    _srBusy = YES;
    _srActivePTS = job->pts;
    CMTime pts = job->pts.den > 0 && job->pts.den <= INT32_MAX
        ? CMTimeMake(job->pts.num, (int32_t)job->pts.den) : kCMTimeInvalid;
    SPLiveProcessor *strong = self;
    SPFRCEngineCompletion completion = ^(uint64_t token, CVPixelBufferRef output, double latency, NSError *error) {
            (void)token;
            dispatch_async(strong->_q, ^{
                if (job->sequence != strong->_srSequence || job->sourceGeneration != strong->_sourceGeneration ||
                    job->configVersion != strong->_configVersion || strong->_stopped) {
                    if (output) CVPixelBufferRelease(output);
                    SPReleaseSRJob(job);
                    return;
                }
                strong->_srBusy = NO;
                strong->_srPendingBytes = strong->_srPendingBytes >= job->bytes ? strong->_srPendingBytes - job->bytes : 0;
                if (job->clockEpoch != strong->_clockEpoch) {
                    if (job->synthetic) [strong noteClockRetiredSyntheticDrop:job->pts];
                    if (output) CVPixelBufferRelease(output);
                    SPReleaseSRJob(job); [strong drainAsyncScaleOnQueue]; return;
                }
                if (latency > 0) {
                    SPPushSample(strong->_scaleNs, (int64_t)(latency * 1e9));
                    strong->_scaleEwmaSec = strong->_scaleEwmaSec <= 0 ? latency : (0.8 * strong->_scaleEwmaSec + 0.2 * latency);
                    [strong recomputeInteractiveDelay];
                }
                if (job->clockEpoch != strong->_clockEpoch) {
                    if (job->synthetic) [strong noteClockRetiredSyntheticDrop:job->pts];
                    if (output) CVPixelBufferRelease(output);
                    SPReleaseSRJob(job); [strong drainAsyncScaleOnQueue]; return;
                }
                CVPixelBufferRef bgra = output ? [strong transfer:output format:kCVPixelFormatType_32BGRA] : NULL;
                if (output) CVPixelBufferRelease(output);
                if (error || !bgra) {
                    if (strong->_testRecordSRInput) strong->_testSRError = error.localizedDescription ?: @"SR output conversion failed";
                    if (bgra) CVPixelBufferRelease(bgra);
                    if (job->synthetic) { [strong erasePending:job->pts]; [strong noteUniqueSyntheticDrop:job->pts]; }
                    [strong failAsyncScaleOnQueue:error.localizedDescription ?: @"超分处理失败。"];
                } else {
                    CVPixelBufferRef original = job->original;
                    job->original = nullptr;
                    [strong enqueueReadyEnhanced:bgra original:original pts:job->pts synthetic:job->synthetic held:job->held
                                      captureHost:job->captureHost generation:job->sourceGeneration deadlineHost:job->targetHost jobID:0 geometryHost:job->geometryHost];
                }
                SPReleaseSRJob(job);
                [strong drainAsyncScaleOnQueue];
            });
        };
    BOOL accepted = _artCNNSR
        ? [_artCNNSR submitSource:job->input pts:pts token:job->sequence completion:completion]
        : _cuganSR
        ? [_cuganSR submitSource:job->input pts:pts token:job->sequence completion:completion]
        : _animeSR
        ? [_animeSR submitSource:job->input pts:pts token:job->sequence completion:completion]
        : _videoSR
        ? [_videoSR submitSource:job->input pts:pts discontinuity:job->discontinuity token:job->sequence completion:completion]
        : [_appleSR submitSource:job->input pts:pts token:job->sequence completion:completion];
    if (!accepted) {
        if (_testRecordSRInput) _testSRError = @"SR submission rejected";
        _srBusy = NO;
        _srPendingBytes = _srPendingBytes >= job->bytes ? _srPendingBytes - job->bytes : 0;
        if (job->synthetic) { [self erasePending:job->pts]; [self noteUniqueSyntheticDrop:job->pts]; }
        [self failAsyncScaleOnQueue:@"超分不能处理当前来源格式或时间戳。"];
        SPReleaseSRJob(job);
    }
}

- (void)failAsyncScaleOnQueue:(NSString *)reason {
    _srFailed = YES;
    [_artCNNSR invalidate];
    _artCNNSR = nil;
    _holdFailureStatus = YES;
    _resolved.scaleActive = NO;
    _resolved.unavailableReason = reason;
    while (!_srPending.empty()) {
        SPSRJob *pending = _srPending.front(); _srPending.pop_front();
        if (pending->synthetic) { [self erasePending:pending->pts]; [self noteUniqueSyntheticDrop:pending->pts]; }
        SPReleaseSRJob(pending);
    }
    _srPendingBytes = 0;
    [self publishStatus:reason failed:YES];
}

- (spAirSourceConversion::Context)airSourceConversionContext {
    return {_sourceGeneration, _configVersion, _measurementEpoch, _clockEpoch, _sourceConversions.cancellation};
}

- (NSDictionary *)airSourceConversionSnapshot {
    NSMutableDictionary *invalidated = [NSMutableDictionary dictionary];
    const char *names[] = {"none", "stopped", "generation", "config", "measurement", "clock", "cancellation", "mode"};
    for (size_t index = 1; index < _sourceConversionInvalidated.size(); ++index)
        invalidated[@(names[index])] = @(_sourceConversionInvalidated[index]);
    return @{ @"enabled": @(_airPerformanceEnabled && _airPerformanceRequested && !_request.scaleEnabled &&
            _airActualSourceKind == SPLiveCaptureSourceKindWindow && ![self requestUsesLatestPresentation:_request] && _sourcePixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        @"workerCreated": @(_sourceConverter != nil), @"sourcePixelFormat": @(_sourcePixelFormat),
        @"active": @(_sourceConversions.active != nullptr), @"waiting": @(_sourceConversions.waitingCount),
        @"outstanding": @(_sourceConversions.outstanding()), @"waitingCapacity": @2,
        @"reservedBytes": @(_sourceConversions.ownedBytes), @"byteLimit": @(SPQueueByteBudget),
        @"admitted": @(_sourceConversions.admitted), @"completed": @(_sourceConversions.completed),
        @"enqueueAttempts": @(_sourceConversionDelivered), @"createdFrames": @(_sourceConversionFrames), @"failures": @(_sourceConversionFailures),
        @"canceledWaiting": @(_sourceConversions.canceledWaiting), @"invalidated": invalidated,
        @"capacitySyncFallbacks": @(_sourceConversions.capacitySyncFallbacks),
        @"cancellation": @(_sourceConversions.cancellation),
        @"scope": @"One active plus two waiting. Byte reservations conservatively include input plus eight bytes per output pixel. Full capacity restores the old synchronous source path without merging or dropping a source." };
}

- (void)airRecordSourceConversion:(const spAirSourceConversion::JobPtr &)job kind:(spAirMeasurement::Kind)kind
    frame:(uint64_t)frameID reason:(spAirSourceConversion::StaleReason)reason {
    if (!_measurementTrace || !job->traceEnabled) return;
    auto event = [self airMeasurementEvent:kind];
    event.frameID = frameID; event.generation = job->context.generation; event.config = job->context.config;
    event.epoch = job->context.measurement; event.clock = job->context.clock; event.groupID = job->identity;
    event.relatedID = job->sourceID; event.ptsNum = job->pts.num; event.ptsDen = job->pts.den;
    event.targetHostTicks = job->targetHost; event.flags = 8u;
    if (kind == spAirMeasurement::Kind::sourceConvertRequested) {
        event.beginHostTicks = event.endHostTicks = job->requestedHost;
        if (job->basisKnown) event.flags |= 16u;
        event.values[0] = job->delayHost; event.values[1] = job->anchorHost;
        event.values[2] = job->anchorPTS.num; event.values[3] = job->anchorPTS.den;
        event.sampleHostTicks = job->sourceIntervalHost;
        if (!job->identity) event.flags |= 256u;
    } else if (kind == spAirMeasurement::Kind::sourceConvertFinished) {
        event.beginHostTicks = job->workerBeginHost; event.endHostTicks = job->workerEndHost;
        event.sampleHostTicks = job->processorReturnHost;
        event.values[0] = (uint64_t)(int64_t)job->status; event.values[1] = job->transferBeginHost;
        event.values[2] = job->transferEndHost; event.values[3] = job->context.cancellation;
        if (job->output) event.flags |= 16u;
    } else {
        event.endHostTicks = SPHostNow();
        event.beginHostTicks = job->processorReturnHost ?: event.endHostTicks;
        event.sampleHostTicks = job->processorReturnHost;
        event.values[0] = (uint64_t)reason; event.values[1] = _sourceConversions.outstanding();
        event.values[2] = _sourceConversions.ownedBytes; event.values[3] = job->context.cancellation;
        if (frameID) event.flags |= 16u;
    }
    _measurementTrace->append(event);
}

- (void)cancelSourceConversions {
    using R = spAirSourceConversion::StaleReason;
    for (size_t index = 0; index < _sourceConversions.waitingCount; ++index) {
        const auto &job = _sourceConversions.waiting[index];
        auto reason = spAirSourceConversion::staleReason(job->context, [self airSourceConversionContext], _stopped);
        if (reason == R::none) reason = R::cancellation;
        ++_sourceConversionInvalidated[(size_t)reason];
        if (reason == R::stopped) ++_stoppedDrops;
        else if (reason == R::generation) ++_generationDrops;
        else ++_sourceStaleDrops;
        [self airRecordSourceConversion:job kind:spAirMeasurement::Kind::sourceConvertDelivered frame:0 reason:reason];
    }
    _sourceConversions.cancel();
}

- (void)drainSourceConversions {
    auto job = _sourceConversions.active;
    if (!job || job->started) return;
    job->started = true;
    if (!_sourceConverter) _sourceConverter = [SPAirSourceConversionWorker new];
    [_sourceConverter convert:job completion:^{
        dispatch_async(self->_q, ^{
            if (job->traceEnabled) job->processorReturnHost = SPHostNow();
            using R = spAirSourceConversion::StaleReason;
            [self airRecordSourceConversion:job kind:spAirMeasurement::Kind::sourceConvertFinished frame:0 reason:R::none];
            auto reason = spAirSourceConversion::staleReason(job->context, [self airSourceConversionContext], self->_stopped);
            if (reason == R::none && (!self->_airPerformanceEnabled || self->_request.scaleEnabled ||
                self->_airActualSourceKind != SPLiveCaptureSourceKindWindow)) reason = R::mode;
            uint64_t frameID = 0;
            if (reason != R::none) {
                ++self->_sourceConversionInvalidated[(size_t)reason];
                if (reason == R::stopped) ++self->_stoppedDrops;
                else if (reason == R::generation) ++self->_generationDrops;
                else ++self->_sourceStaleDrops;
            } else if (!job->output) {
                ++self->_sourceConversionFailures; ++self->_sourceConversionDrops;
            } else {
                if (job->transferBeginHost) SPPushSample(self->_transferNs, SPHostToNs(job->transferEndHost - job->transferBeginHost));
                CVPixelBufferRef converted = job->output; job->output = NULL;
                const uint64_t previousFrameID = self->_nextFrameID;
                [self enqueueReadyEnhanced:converted original:CVPixelBufferRetain(converted) pts:job->pts synthetic:NO held:job->held
                    captureHost:job->captureHost generation:job->context.generation deadlineHost:job->targetHost jobID:0 geometryHost:job->geometryHost];
                if (self->_nextFrameID != previousFrameID) { frameID = self->_nextFrameID; ++self->_sourceConversionFrames; }
                ++self->_sourceConversionDelivered;
            }
            [self airRecordSourceConversion:job kind:spAirMeasurement::Kind::sourceConvertDelivered frame:frameID reason:reason];
            if (job->output) { CVPixelBufferRelease(job->output); job->output = NULL; }
            self->_sourceConversions.finish(job);
            [self drainSourceConversions];
        });
    }];
}

- (BOOL)enqueueSourceConversion:(CVPixelBufferRef)source identity:(uint64_t)identity pts:(sp::SPRational)pts
    held:(BOOL)held host:(int64_t)host generation:(uint64_t)generation deadline:(int64_t)deadline {
    if (!_airPerformanceEnabled || !_airPerformanceRequested || _airActualSourceKind != SPLiveCaptureSourceKindWindow ||
        _request.scaleEnabled || generation != _sourceGeneration || [self requestUsesLatestPresentation:_request] ||
        CVPixelBufferGetPixelFormatType(source) != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) return NO;
    auto job = std::make_shared<spAirSourceConversion::Job>(source);
    job->context = [self airSourceConversionContext]; job->sourceID = identity; job->pts = pts;
    job->held = held; job->captureHost = host; job->geometryHost = host;
    job->targetHost = deadline > 0 ? deadline : [self targetHostForPTS:pts];
    job->delayHost = _delayHost; job->anchorHost = _anchorHost; job->anchorPTS = _anchorPts;
    sp::SPRational anchorDelta{};
    job->basisKnown = deadline <= 0 && _haveAnchor && sp::spSub(pts, _anchorPts, anchorDelta);
    job->sourceIntervalHost = _haveInterval ? _intervalHost : 0;
    job->bytes = CVPixelBufferGetDataSize(source) + (uint64_t)CVPixelBufferGetWidth(source) * CVPixelBufferGetHeight(source) * 8;
    job->traceEnabled = _measurementTrace != nullptr;
    job->requestedHost = job->traceEnabled ? SPHostNow() : 0;
    const BOOL accepted = _sourceConversions.admit(job, SPQueueByteBudget);
    [self airRecordSourceConversion:job kind:spAirMeasurement::Kind::sourceConvertRequested frame:0 reason:spAirSourceConversion::StaleReason::none];
    if (!accepted) return NO;
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
    SPRifeBridge *bridge = _rife;
    if (bridge.rifePrescaleEnabled) job->recordDimensions = ^(int width, int height) { [bridge recordPrescaleOriginalWidth:width height:height]; };
#endif
    [self drainSourceConversions];
    return YES;
}

- (void)enqueueSourceIdentity:(uint64_t)identity
                          pts:(sp::SPRational)pts
                         host:(int64_t)host
                   generation:(uint64_t)generation
                        force:(BOOL)force {
    [self enqueueSourceIdentity:identity pts:pts host:host generation:generation force:force retimed:NO];
}

- (void)enqueueSourceIdentity:(uint64_t)identity pts:(sp::SPRational)pts host:(int64_t)host generation:(uint64_t)generation force:(BOOL)force retimed:(BOOL)retimed {
    auto found = _held.find(identity);
    if (found == _held.end()) { _sourceMissingDrops++; return; }
    BOOL held = !retimed && sp::spCmp(pts, found->second.pts) != 0;
    // Unscaled BGRA aliases a capture-owned buffer. Once fresh native cadence
    // is confirmed, a RIFE midpoint is not needed and the normal interpolation
    // lead can otherwise occupy this small capture pool.
    BOOL nativeDirect = _nativeBudgetActive && !held && found->second.source && !_request.scaleEnabled &&
        [_request.engineID isEqualToString:@"rife.metal"] &&
        CVPixelBufferGetPixelFormatType(found->second.source)==kCVPixelFormatType_32BGRA;
    if (nativeDirect && !_nativeBGRADirectActive) {
        // Retire old deadlines and pending phases; already running jobs retain
        // their owners but their retired clock results cannot be presented.
        [self retireClockTimeline];
        _nativeBGRADirectActive=YES;
    } else if (!nativeDirect) {
        _nativeBGRADirectActive=NO;
    }
    if (_videoSR && _havePreviousSourcePts) {
        sp::SPRational delta{};
        if (!sp::spSub(pts, _previousSourcePts, delta) || sp::spCmp(delta, sp::spMake(0,1)) <= 0 ||
            (_haveInterval && SPRationalToHost(delta) > MAX(_intervalHost * 3, SPRationalToHost(sp::spMake(1,10))))) {
            _videoSRDiscontinuity = YES;
        }
    }
    if (!held) [self observeSourceIdentity:identity];
    int64_t pairClockDeadline=0;
    if([self usesRifePairAffineClock] && !held && !retimed &&
        found->second.pairClockSource.frozen && sp::spCmp(pts,found->second.pairClockSource.pts)==0 &&
        sp::sameRifePairClockContext(found->second.pairClockSource.context,[self rifePairClockContext]))
        pairClockDeadline=found->second.pairClockSource.targetHost;
    // Distil and low-prescale retain their existing independent policy. RIFE
    // sources always share the deadline queue with its synthetic phases.
    if (!force && (_distil || (_lowLatency && _lowPrescaleSlowMode)) && _resolved.interpolationActive && _sessionReady && _lastEnhanced && _request.viewMode != SPLiveViewOriginal) { _sourcePolicyDrops++; return; }
    if (_sessionReady && _lowLatency && [self requestUsesLowPrescale:_request width:_width height:_height]) {
        CVPixelBufferRef cached=[self lowPrescaledForIdentity:identity];
        if (!cached) { [self publishStatus:@"低延迟前置缩放失败" failed:YES]; return; }
        CVPixelBufferRef enhanced=CVPixelBufferRetain(cached);
        CVPixelBufferRef original=_request.viewMode==SPLiveViewCompare ? CVPixelBufferRetain(cached) : NULL;
        [self enqueueReadyEnhanced:enhanced original:original pts:pts synthetic:NO held:held captureHost:host generation:generation deadlineHost:0];
        return;
    }
    if ([self enqueueSourceConversion:found->second.source identity:identity pts:pts held:held
        host:host generation:generation deadline:pairClockDeadline]) return;
    CVPixelBufferRef bgra = [self bgraFromSource:found->second.source];
    if (!bgra) { _sourceConversionDrops++; return; }
    if (_srFailed && SPLiveIsArtCNNScaleEngine(_request.scaleEngine)) {
        // Keep failed ArtCNN sessions on source frames. This is baseline display,
        // not recovered enhancement; retain the error and exclude it from SR timing.
        CVPixelBufferRef fallback = _baselineScaler ? [_baselineScaler scaleBuffer:bgra error:NULL] : NULL;
        if (!fallback) fallback = CVPixelBufferRetain(bgra);
        CVPixelBufferRelease(bgra);
        [self enqueueReadyEnhanced:fallback original:CVPixelBufferRetain(fallback) pts:pts synthetic:NO held:held
                       captureHost:host generation:generation deadlineHost:pairClockDeadline];
        return;
    }
    if ([self requestUsesAsyncScale:_request] && _sessionReady && (_appleSR || _videoSR || _animeSR || _cuganSR || _artCNNSR)) {
        CVPixelBufferRef original = _request.viewMode != SPLiveViewEnhanced ? [self scaleBuffer:bgra with:_baselineScaler] : NULL;
        if([self usesRifePairAffineClock] && !held && !retimed)
            [self recordRifeSourceEnqueueClock:identity pts:pts selected:pairClockDeadline stage:@"source-enqueue-before-async-scale"];
        [self enqueueAsyncScale:bgra original:original pts:pts synthetic:NO held:held captureHost:host generation:generation deadlineHost:pairClockDeadline];
        return;
    }
    CVPixelBufferRef scaleInput = [self scaleBuffer:bgra with:_request.scaleEnabled ? _srInputScaler : nil];
    if (!scaleInput && _srInputScaler) { CVPixelBufferRelease(bgra); [self publishStatus:@"超分输入缩放失败" failed:YES]; return; }
    CVPixelBufferRef enhanced = [self scaleBuffer:scaleInput with:_request.scaleEnabled ? _scaler : nil];
    if (scaleInput) CVPixelBufferRelease(scaleInput);
    CVPixelBufferRef original = nil;
    if (_request.viewMode != SPLiveViewEnhanced) {
        original = [self scaleBuffer:bgra with:_request.scaleEnabled ? _baselineScaler : nil];
    }
    CVPixelBufferRelease(bgra);
    if (!enhanced) enhanced = original ? CVPixelBufferRetain(original) : NULL;
    if (!original && enhanced) original = CVPixelBufferRetain(enhanced);
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
    if (enhanced && _rife.rifePrescaleEnabled) {
        [_rife recordPrescaleOriginalWidth:(int)CVPixelBufferGetWidth(enhanced)
                                   height:(int)CVPixelBufferGetHeight(enhanced)];
    }
#endif
    if (nativeDirect) _nativeBGRADirectFrames++;
    if([self usesRifePairAffineClock] && !held && !retimed) {
        int64_t sourceDeadline=nativeDirect ? SPHostNow() : pairClockDeadline;
        [self recordRifeSourceEnqueueClock:identity pts:pts selected:sourceDeadline stage:@"source-enqueue-ready"];
        [self enqueueReadyEnhanced:enhanced original:original pts:pts synthetic:NO held:held captureHost:host generation:generation deadlineHost:sourceDeadline];
    } else {
        [self enqueueReadyEnhanced:enhanced original:original pts:pts synthetic:NO held:held captureHost:host generation:generation deadlineHost:nativeDirect ? SPHostNow() : 0];
    }
}

// Reserve a cheap, owned source image at each model deadline. On-time model
// output replaces this slot; an overloaded/failed job leaves it for playout.
// Standby images count as holds, never as additional motion frames.
- (void)enqueueFixedFallbacks:(const std::vector<sp::SPScheduleOutput> &)events generation:(uint64_t)generation {
    uint64_t cachedID = 0;
    CVPixelBufferRef cached = nil;
    for (const auto &event : events) {
        const uint64_t identity = sp::spCmp(event.phase, sp::spMake(1, 2)) < 0 ? event.frameA : event.frameB;
        auto found = _held.find(identity);
        if (found == _held.end() || !found->second.source) continue;
        if (identity != cachedID) {
            if (cached) CVPixelBufferRelease(cached);
            cached = [self bgraFromSource:found->second.source];
            cachedID = identity;
        }
        if (!cached) continue;
        [self enqueueReadyEnhanced:CVPixelBufferRetain(cached) original:nil pts:event.pts synthetic:NO held:YES
                       captureHost:found->second.host generation:generation deadlineHost:[self targetHostForPTS:event.pts]
                             jobID:0 geometryHost:found->second.host fixedFallback:YES];
    }
    if (cached) CVPixelBufferRelease(cached);
}

// Shared by live FRC admission and its deterministic production-queue contract.
- (BOOL)r9AdmitFRCPhases:(NSUInteger)count backendAvailable:(BOOL)available nowNs:(int64_t)nowNs {
    bool measured = _frcNs.size() >= 8 || _captureToOutputReadyNs.size() >= 8;
    auto decision = _r9FRCBudgetGate.decide(_r9RequiredBudgetMs, _r9AllowedBudgetMs, measured, available, nowNs);
    if (decision == sp::FRCBudgetGate::Decision::backendBusy) {
        _queueDrops += count; _epochQueueDrops += count; _r9BackendFullPhases += count; return NO;
    }
    if (decision == sp::FRCBudgetGate::Decision::budgetLimited) {
        _queueDrops += count; _epochQueueDrops += count; _r9BudgetRejectedPhases += count; return NO;
    }
    if (decision == sp::FRCBudgetGate::Decision::probe) _r9BudgetProbeJobs++;
    return YES;
}

- (void)r9RecordUsableLatency:(double)latency {
    SPPushSample(_frcNs, (int64_t)(latency * 1e9));
    _frcEwmaSec = _frcEwmaSec <= 0 ? latency : (0.5 * _frcEwmaSec + 0.5 * latency);
    [self recomputeInteractiveDelay];
}

- (void)submitEventGroup:(const std::vector<sp::SPScheduleOutput> &)events generation:(uint64_t)generation {
    [self submitEventGroup:events generation:generation frozenDeadline:0];
}

- (void)submitEventGroup:(const std::vector<sp::SPScheduleOutput> &)events generation:(uint64_t)generation frozenDeadline:(int64_t)frozenDeadline {
    [self submitEventGroup:events generation:generation frozenDeadline:frozenDeadline frozenPairClock:nullptr];
}

- (void)submitEventGroup:(const std::vector<sp::SPScheduleOutput> &)events generation:(uint64_t)generation
    frozenDeadline:(int64_t)frozenDeadline frozenPairClock:(const sp::RifePairClockTarget *)frozenPairClock {
    // A phase depends on frame B; observe its real source clock before its
    // deadline is calculated, including callers which submit a pair directly.
    if (!events.empty() && generation == _sourceGeneration) [self observeSourceIdentity:events.front().frameB];
    if (_testCapturePlayout && !events.empty() && _testTimingTrace.count < 80) {
        auto b = _held.find(events.front().frameB);
        if (b != _held.end()) {
            if (!_testTimingTrace) _testTimingTrace=[NSMutableArray array];
            [_testTimingTrace addObject:@{ @"kind":@"phasePlan", @"ptsNum":@(events.front().pts.num), @"ptsDen":@(events.front().pts.den),
                @"sourcePtsNum":@(b->second.pts.num), @"sourcePtsDen":@(b->second.pts.den),
                @"anchorPtsNum":@(_anchorPts.num), @"anchorPtsDen":@(_anchorPts.den), @"anchorValid":@(_haveAnchor),
                @"deadlineFromSourceMs":@((double)SPHostToNs([self targetHostForPTS:events.front().pts]-b->second.host)/1e6),
                @"delayMs":@((double)SPHostToNs(_delayHost)/1e6) }];
        }
    }
    BOOL wantLow = [_request.engineID isEqualToString:@"apple.lowlatency"];
    BOOL wantRife = [_request.engineID isEqualToString:@"rife.metal"];
    BOOL wantDistil = [_request.engineID isEqualToString:@"distildrba.coreml"];
    sp::RifePairClockTarget pairClock[3]{};
    const BOOL pairAffine=[self usesRifePairAffineClock];
    if(pairAffine) {
        NSMutableArray *targets=[NSMutableArray array];
        for(size_t i=0;i<MIN((size_t)3,events.size());++i) {
            pairClock[i]=frozenDeadline>0 && i==0
                ? sp::reuseRifePairClockTarget(frozenPairClock,[self rifePairClockContext],events[i].pts,frozenDeadline)
                : [self rifePairClockTargetForEvent:events[i]];
            [targets addObject:SPRifePairClockValue(pairClock[i],events[i].frameA,events[i].frameB)];
        }
        [self recordRifePairClockPlan:targets];
    }
    BOOL haveEngine = wantLow ? (_lowLatency != nil) : (wantRife ? (_rife != nil) : (wantDistil ? (_distil != nil) : (_engine != nil)));
    BOOL slowPair=wantLow && _lowPrescaleSlowMode;
    if (wantRife && haveEngine && !events.empty()) {
        int64_t now = SPHostNow();
        int64_t deadline = frozenDeadline > 0 ? frozenDeadline : (pairAffine ? pairClock[0].selectedTargetHost : [self targetHostForPTS:events.front().pts]);
        BOOL changingRate = [self rateBudgetEnabled] &&
            (_rateBudgetPassthrough || _rateBudget.snapshot().effectiveMultiplier != _effectiveMultiplier);
        size_t count = MIN((size_t)32, _frcNs.size());
        double serviceMs = 0;
        if (count > 0) {
            std::vector<int64_t> recent(_frcNs.end() - count, _frcNs.end());
            std::sort(recent.begin(), recent.end());
            serviceMs = recent[(count - 1) * 80 / 100] / 1e6;
        }
        double elapsedMs = _rifeBusySinceHost > 0 ? MAX(0.0, SPHostToNs(now - _rifeBusySinceHost) / 1e6) : 0;
        double remainingMs = SPHostToNs(deadline - now) / 1e6;
        int rifeInflight = _inflight + ((_rateBudgetProbeInFlightToken &&
            _rateBudgetProbeInFlightEpoch != _inflightEpoch) ? 1 : 0);
        BOOL admitted = [self usesFixedSourceReuse]
            ? _fixedRateBudget.admit((int)events.size(), SPHostToNs(now) / 1e6, SPHostToNs(deadline) / 1e6)
            : sp::shouldAdmitRife(rifeInflight, count, serviceMs, elapsedMs, remainingMs);
        BOOL missesBudget = !admitted && rifeInflight < 2;
        if (changingRate || !admitted) {
            _queueDrops += events.size(); _epochQueueDrops += events.size();
            if (missesBudget) _rifeBudgetRejectedPhases += events.size();
            else if (rifeInflight >= 2) { _inflightLimitDrops += events.size(); _rifeDeferredCapacityDrops += events.size(); }
            for (const auto &event : events) [self noteRateBudgetDrop:event.pts];
            return;
        }
    }
    if (!events.empty() && slowPair && _inflight >= 1 && haveEngine) {
        auto a = _held.find(events.front().frameA), b = _held.find(events.front().frameB);
        if (a != _held.end() && b != _held.end()) {
            if (!_rifePending.empty()) { _queueDrops += _rifePending.size(); _epochQueueDrops += _rifePending.size(); }
            [self clearPendingRife];
            _rifePending = events;
            _rifePendingGeneration = generation;
            a->second.pins += 1; b->second.pins += 1;
            return;
        }
    }
    int admission = (!wantLow && !wantRife && !wantDistil) ? [self r8AdmissionLimit] : ((wantDistil || slowPair) ? 1 : 2);
    BOOL appleFRC = !wantLow && !wantRife && !wantDistil && _engine != nil;
    if (!events.empty() && appleFRC && _engine.busyCount >= _engine.sessionCount) {
        (void)[self r9AdmitFRCPhases:events.size() backendAvailable:NO nowNs:SPHostToNs(SPHostNow())];
        return;
    }
    if (events.empty() || _inflight >= admission || !haveEngine) {
        if (!events.empty()) {
            _queueDrops += events.size();
            _epochQueueDrops += events.size();
            if (!haveEngine) _engineUnavailableDrops += events.size();
            else _inflightLimitDrops += events.size();
        }
        return;
    }
    if (appleFRC && ![self r9AdmitFRCPhases:events.size()
                        backendAvailable:(_engine.busyCount < _engine.sessionCount) nowNs:SPHostToNs(SPHostNow())]) return;
    NSMutableArray<NSNumber *> *phases = [NSMutableArray array];
    for (const auto &event : events) {
        float value = 0;
        if (wantLow) {
            if (![SPLowLatencyEngine supportsPhaseNumerator:event.phase.num denominator:event.phase.den frames:_lowLatency.frames outFloat:&value]) {
                if (!_phaseRejectNoted) {
                    _phaseRejectNoted = YES;
                    NSString *text = [NSString stringWithFormat:@"相位 %lld/%lld 不在低延迟支持的 1/2 或 1/4、1/2、3/4 里，请求没有被改写。可改用 Apple 帧率转换。",
                                      event.phase.num, event.phase.den];
                    _resolved.unavailableReason = text;
                    _holdFailureStatus = YES;
                    [self publishStatus:text failed:YES];
                }
                _queueDrops += events.size();
                _epochQueueDrops += events.size();
                return;
            }
        } else if (!sp::spPhaseFitsFloat(event.phase, value)) {
            _syntheticFail += 1;
            _resolved.unavailableReason = @"相位无法精确提交";
            [self publishStatus:wantRife ? @"该相位无法交给 RIFE" : @"该相位无法交给 Apple 帧率转换" failed:YES];
            return;
        }
        [phases addObject:@(value)];
    }
    CVPixelBufferRef a = NULL;
    CVPixelBufferRef b = NULL;
    if (wantLow || wantRife || wantDistil) {
        auto heldA = _held.find(events.front().frameA);
        auto heldB = _held.find(events.front().frameB);
        a = heldA == _held.end() ? NULL : heldA->second.source;
        b = heldB == _held.end() ? NULL : heldB->second.source;
    } else {
        a = [self yuvForIdentity:events.front().frameA];
        b = [self yuvForIdentity:events.front().frameB];
    }
    if (!a || !b) {
        _syntheticFail += 1;
        return;
    }
    if (wantLow && SPIdenticalSourcePixels(a,b)) {
        CVPixelBufferRef image=NULL;
        if ([self requestUsesLowPrescale:_request width:_width height:_height]) {
            CVPixelBufferRef cached=[self lowPrescaledForIdentity:events.front().frameA];
            if(cached) image=CVPixelBufferRetain(cached);
        } else {
            CVPixelBufferRef source=[self bgraFromSource:a];
            image=source ? [self scaleBuffer:source with:_request.scaleEnabled ? _scaler : nil] : NULL;
            if(source)CVPixelBufferRelease(source);
        }
        if (!image) { _syntheticFail += events.size(); [self publishStatus:@"静止帧处理失败" failed:YES]; return; }
        auto heldB=_held.find(events.front().frameB); int64_t host=heldB==_held.end()?0:heldB->second.host;
        for(const auto &event:events) {
            _staticHoldPhases++; _epochStaticHoldPhases++;
            [self enqueueReadyEnhanced:CVPixelBufferRetain(image) original:CVPixelBufferRetain(image) pts:event.pts synthetic:NO held:YES captureHost:host generation:generation deadlineHost:0];
        }
        CVPixelBufferRelease(image); return;
    }
    if (wantLow && [self requestUsesLowPrescale:_request width:_width height:_height]) {
        a=[self lowPrescaledForIdentity:events.front().frameA];
        b=[self lowPrescaledForIdentity:events.front().frameB];
        if (!a || !b) { _syntheticFail += 1; [self publishStatus:@"低延迟前置缩放失败" failed:YES]; return; }
    }
    SPLiveJob *job = new SPLiveJob();
    job->diagnosticID = SPR8NextJobID.fetch_add(1);
    job->measurementEpoch = _measurementEpoch;
    job->configVersion = _configVersion;
    job->generation = generation;
    job->clockEpoch = _clockEpoch;
    auto hostB = _held.find(events.front().frameB);
    job->captureHost = hostB == _held.end() ? 0 : hostB->second.host;
    job->count = (int)MIN((size_t)3, events.size());
    for (int i = 0; i < job->count; ++i) {
        job->pts[i] = events[(size_t)i].pts;
        job->phase[i] = events[(size_t)i].phase;
        job->pairClock[i] = pairClock[i];
        job->targetHost[i] = frozenDeadline > 0 && i == 0 ? frozenDeadline : (pairAffine ? pairClock[i].selectedTargetHost : [self targetHostForPTS:job->pts[i]]);
        if (_measurementTrace) [self airMeasurementTarget:job->pts[i] target:job->targetHost[i] frame:0
            job:job->diagnosticID phase:i synthetic:YES computed:!(frozenDeadline > 0 && i == 0) && !pairAffine];
    }
    job->frameA = events.front().frameA;
    job->frameB = events.front().frameB;
    job->inflightEpoch = _inflightEpoch;
    if (auto aHeld = _held.find(job->frameA); aHeld != _held.end()) aHeld->second.pins += 1;
    if (auto bHeld = _held.find(job->frameB); bHeld != _held.end()) bHeld->second.pins += 1;
    uint64_t token = job->diagnosticID;
    if (wantRife && _inflight == 0) _rifeBusySinceHost = SPHostNow();
    _inflight += 1;
    _havePair = YES;
    _lastPairB = events.front().frameB;
    SPLiveProcessor *selfRef = self;
    SPFRCPhasesCompletion finish = ^(uint64_t doneToken, NSArray<SPOwnedPixelBuffer *> *outputs, double latency, NSError *error) {
        // Each box already owns its buffer. Copy the array for the queue
        // handoff instead of adding a second owner for every output.
        NSArray<SPOwnedPixelBuffer *> *kept = [outputs copy] ?: @[];
        const int64_t callbackHost = SPHostNow();
        dispatch_async(selfRef->_q, ^{
            job->callbackHost = callbackHost;
            @autoreleasepool { [selfRef finishJob:job token:doneToken outputs:kept latency:latency error:error]; }
        });
    };
    BOOL submitted = NO;
    if (wantLow) {
        auto heldA = _held.find(job->frameA), heldB = _held.find(job->frameB);
        if (heldA != _held.end() && heldB != _held.end()) {
            const auto pa = heldA->second.pts, pb = heldB->second.pts;
            if (pa.den > 0 && pa.den <= INT32_MAX && pb.den > 0 && pb.den <= INT32_MAX) {
                submitted = [_lowLatency submitPrevious:a current:b
                    previousPTS:CMTimeMake(pa.num, (int32_t)pa.den) currentPTS:CMTimeMake(pb.num, (int32_t)pb.den)
                    phases:phases token:token completion:finish];
            }
        }
    }
    else if (wantRife) {
        auto heldA = _held.find(job->frameA), heldB = _held.find(job->frameB);
        if (heldA != _held.end() && heldB != _held.end()) {
            const auto pa = heldA->second.pts, pb = heldB->second.pts;
            if (pa.den > 0 && pa.den <= INT32_MAX && pb.den > 0 && pb.den <= INT32_MAX) {
#if ODF_AIR_PRESENTATION_GUARD_DIAGNOSTIC
                if (_rife.serviceTraceEnabled) [_rife setServiceTraceToken:job->diagnosticID configVersion:job->configVersion
                    measurementEpoch:job->measurementEpoch probe:NO probeIndex:-1 probeRound:0];
#endif
                submitted = [_rife submitLivePrevious:a current:b previousID:job->frameA currentID:job->frameB
                    previousPTS:CMTimeMake(pa.num, (int32_t)pa.den) currentPTS:CMTimeMake(pb.num, (int32_t)pb.den)
                    generation:generation clockEpoch:_clockEpoch timesteps:phases token:token completion:finish];
            }
        }
    }
    else if (wantDistil) {
        auto heldA = _held.find(job->frameA);
        auto previous = heldA == _held.end() ? _held.end() : _held.find(heldA->second.previousIdentity);
        const auto midpoint = job->pts[0];
        if (previous != _held.end() && job->count == 1 && midpoint.den > 0 && midpoint.den <= INT32_MAX) {
            submitted = [_distil submitPrevious:previous->second.source current:a next:b
                pts:CMTimeMake(midpoint.num, (int32_t)midpoint.den) token:token
                completion:^(uint64_t doneToken, CVPixelBufferRef output, double latency, NSError *error) {
                    NSArray *boxes = output ? @[[[SPOwnedPixelBuffer alloc] initWithBufferNoCopy:output]] : @[];
                    finish(doneToken, boxes, latency, error);
                }];
        }
    }
    else {
        auto heldA = _held.find(job->frameA), heldB = _held.find(job->frameB);
        if (heldA != _held.end() && heldB != _held.end()) {
            const auto pa = heldA->second.pts, pb = heldB->second.pts;
            if (pa.den > 0 && pa.den <= INT32_MAX && pb.den > 0 && pb.den <= INT32_MAX) {
                submitted = [_engine submitLivePhasesWithFrameA:a frameB:b
                    ptsA:CMTimeMake(pa.num, (int32_t)pa.den) ptsB:CMTimeMake(pb.num, (int32_t)pb.den)
                    frameIDA:job->frameA frameIDB:job->frameB generation:generation clockEpoch:_clockEpoch
                    phases:phases token:token completion:finish];
            }
        }
    }
    if (!submitted) {
        if (job->inflightEpoch == _inflightEpoch) {
            _inflight = MAX(0, _inflight - 1);
            if (wantRife && _inflight == 0) _rifeBusySinceHost = 0;
        }
        if (wantRife) for (int i = 0; i < job->count; ++i) [self noteRateBudgetDrop:job->pts[i]];
        [self unpinJob:job];
        _queueDrops += (uint64_t)MAX(1, job->count);
        _epochQueueDrops += (uint64_t)MAX(1, job->count);
        _engineSubmissionRejectedDrops += (uint64_t)MAX(1, job->count);
        [self recordR7JobEvent:@"rejected" detail:@{ @"id": @(token), @"frameA": @(job->frameA), @"frameB": @(job->frameB), @"generation": @(generation), @"config": @(_configVersion) }];
        delete job;
    } else {
        _submitted += 1;
        int64_t submittedHost = SPHostNow();
        if (wantRife && [self usesFixedSourceReuse])
            _fixedRateBudget.submitted(token, job->count, SPHostToNs(submittedHost) / 1e6);
        if (_r7JobHosts.size() < 32) _r7JobHosts[token] = {submittedHost, _configVersion};
        else _r7JobUntracked++;
        _r7LastJobSubmitted = @{ @"id": @(token), @"host": @(submittedHost),
            @"frameA": @(job->frameA), @"frameB": @(job->frameB),
            @"captureHost": @(job->captureHost), @"generation": @(generation), @"config": @(_configVersion),
            @"clockEpoch": @(job->clockEpoch), @"measurementEpoch": @(job->measurementEpoch), @"deadlineHost": @(job->targetHost[0]),
            @"deadlineSlackMs": @(job->targetHost[0] ? (double)SPHostToNs(job->targetHost[0] - submittedHost) / 1e6 : 0) };
        if(job->pairClock[0].recorded) {
            NSMutableDictionary *detail=[_r7LastJobSubmitted mutableCopy];
            detail[@"pairAffineTargets"]=SPRifeJobPairClockValues(job); _r7LastJobSubmitted=detail;
        }
        [self recordR7JobEvent:@"submitted" detail:_r7LastJobSubmitted];
        for (int phaseIndex = 0; phaseIndex < job->count; ++phaseIndex) {
            const auto &event = events[(size_t)phaseIndex];
            SPPendingPhase phase;
            phase.pts = event.pts;
            phase.jobID = job->diagnosticID;
            phase.configVersion = job->configVersion;
            phase.clockEpoch = job->clockEpoch;
            phase.measurementEpoch = job->measurementEpoch;
            phase.targetHost = job->targetHost[phaseIndex];
            phase.generation = generation;
            if (_testCapturePlayout && _testPendingTrace.count < 24) {
                if (!_testPendingTrace) _testPendingTrace=[NSMutableArray array];
                [_testPendingTrace addObject:@{ @"kind":@"submitted", @"ptsNum":@(event.pts.num), @"ptsDen":@(event.pts.den),
                    @"deadlineFromSourceMs":@((double)SPHostToNs(phase.targetHost-job->captureHost)/1e6),
                    @"enqueueFromSourceMs":@((double)SPHostToNs(SPHostNow()-job->captureHost)/1e6),
                    @"anchorValid":@(_haveAnchor), @"anchorPtsNum":@(_anchorPts.num), @"anchorPtsDen":@(_anchorPts.den),
                    @"anchorHostFromSourceMs":@((double)SPHostToNs(_anchorHost-job->captureHost)/1e6),
                    @"frameBptsNum":@(hostB == _held.end() ? 0 : hostB->second.pts.num),
                    @"frameBptsDen":@(hostB == _held.end() ? 0 : hostB->second.pts.den),
                    @"delayMs":@((double)SPHostToNs(_delayHost)/1e6) }];
            }
            _pending.push_back(phase);
        }
    }
}

- (void)unpinJob:(SPLiveJob *)job {
    for (uint64_t identity : {job->frameA, job->frameB}) {
        auto found = _held.find(identity);
        if (found != _held.end() && found->second.pins > 0) found->second.pins -= 1;
    }
}

- (void)finishJob:(SPLiveJob *)job
            token:(uint64_t)token
          outputs:(NSArray<SPOwnedPixelBuffer *> *)outputs
          latency:(double)latency
            error:(NSError *)error {
    int64_t completedHost = SPHostNow();
    _r7JobHosts.erase(job->diagnosticID);
    _r7JobCompleted++;
    _r7LastJobCompleted = @{ @"id": @(job->diagnosticID), @"host": @(completedHost),
        @"frameA": @(job->frameA), @"frameB": @(job->frameB), @"captureHost": @(job->captureHost),
        @"generation": @(job->generation), @"config": @(job->configVersion), @"outputs": @(outputs.count),
        @"error": @(error != nil), @"deadlineHost": @(job->targetHost[0]),
        @"deadlineSlackMs": @(job->targetHost[0] ? (double)SPHostToNs(job->targetHost[0] - completedHost) / 1e6 : 0),
        @"clockEpoch": @(job->clockEpoch), @"measurementEpoch": @(job->measurementEpoch),
        @"callbackHost": @(job->callbackHost),
        @"callbackDeliveryMs": @(job->callbackHost ? (double)SPHostToNs(completedHost - job->callbackHost) / 1e6 : -1),
        @"captureToReadyMs": @(job->captureHost ? (double)SPHostToNs(completedHost - job->captureHost) / 1e6 : -1) };
    if(job->pairClock[0].recorded) {
        NSMutableDictionary *detail=[_r7LastJobCompleted mutableCopy];
        detail[@"pairAffineTargets"]=SPRifeJobPairClockValues(job); _r7LastJobCompleted=detail;
    }
    [self recordR7JobEvent:@"completed" detail:_r7LastJobCompleted];
    (void)token;
    BOOL releasedCapacity = job->inflightEpoch == _inflightEpoch && _inflight > 0;
    if (releasedCapacity) {
        _inflight -= 1;
        if (_rife) _rifeBusySinceHost = _inflight > 0 ? completedHost : 0;
    }
    if ([self usesFixedSourceReuse]) {
        const bool usable = job->configVersion == _configVersion && job->generation == _sourceGeneration &&
            job->clockEpoch == _clockEpoch && !error && outputs.count > 0;
        _fixedRateBudget.completed(job->diagnosticID, SPHostToNs(completedHost) / 1e6, usable ? latency * 1000 : 0);
    }
    [self unpinJob:job];
    if (job->configVersion != _configVersion || job->generation != _sourceGeneration || _stopped) {
        if (releasedCapacity) [self resumeDeferredRife];
        [self trimHeld]; delete job;
        return;
    }
    if (job->clockEpoch != _clockEpoch) {
        _clockRetiredJobs += 1; _clockRetiredModelOutputs += outputs.count;
        if (releasedCapacity) [self resumeDeferredRife];
        [self trimHeld]; delete job;
        return;
    }
#if ODF_AIR_BETA_DIAGNOSTIC
    if (SPAirBetaEnabled() && error && _rife &&
        !([error.domain isEqual:@"app.openduckframe.rife"] && error.code == SPRifeBridgeErrorOutputPoolExhausted)) {
        [self airBetaUsePassthrough:[NSString stringWithFormat:@"Air融合处理失败，现以原帧播放：%@", error.localizedDescription]];
        [self trimHeld]; delete job; return;
    }
#endif
    if (_airPerformanceEnabled && error && _rife &&
        !([error.domain isEqual:@"app.openduckframe.rife"] && error.code == SPRifeBridgeErrorOutputPoolExhausted)) {
        [self airPerformanceUsePassthrough:[NSString stringWithFormat:@"窗口优化处理失败，现以原帧播放：%@", error.localizedDescription]];
        [self trimHeld]; delete job; return;
    }
    // FRC/RIFE failures can finish before inference (for example pool pressure).
    // They are not samples of the cost of producing a usable output.
    BOOL validTimingSample = (!_engine && !_rife) || (!error && outputs.count > 0);
    if (validTimingSample && job->captureHost > 0 && SPHostNow() > job->captureHost)
        SPPushSample(_captureToModelReadyNs, SPHostToNs(SPHostNow() - job->captureHost));
    if (validTimingSample && latency > 0) {
        if (_rife) _rateBudgetCompletedHosts.push_back(job->callbackHost > 0 ? job->callbackHost : completedHost);
        [self r9RecordUsableLatency:latency];
        if (!_testKeepLowRealtime && _lowLatency && _delayClamped && [self requestUsesLowPrescale:_request width:_width height:_height]) _lowPrescaleSlowMode = YES;
    }
    // Delay recomputation can itself retire the clock mapping.
    if (job->clockEpoch != _clockEpoch) {
        _clockRetiredJobs += 1; _clockRetiredModelOutputs += outputs.count;
        if (releasedCapacity) [self resumeDeferredRife];
        [self trimHeld]; delete job; return;
    }
    if(job->pairClock[0].recorded && !sp::sameRifePairClockContext(job->pairClock[0].context,[self rifePairClockContext])) {
        [self recordR7JobEvent:@"pairAffineContextRetired" detail:@{ @"id":@(job->diagnosticID), @"targets":SPRifeJobPairClockValues(job) }];
        _pending.erase(std::remove_if(_pending.begin(),_pending.end(),[&](const SPPendingPhase &phase) {
            return phase.jobID==job->diagnosticID && phase.clockEpoch==job->clockEpoch && phase.measurementEpoch==job->measurementEpoch;
        }),_pending.end());
        if(releasedCapacity) [self resumeDeferredRife];
        [self trimHeld]; delete job; return;
    }
    if (_probeWindowOpen && job->count > 0) {
        BOOL measured = NO;
        for (int i = 0; i < job->count; ++i) {
            if (sp::spCmp(job->pts[i], _probeMinPts) >= 0) measured = YES;
        }
        if (!measured) {
            for (int i = 0; i < job->count; ++i) [self erasePending:job->pts[i]];
            if (releasedCapacity) [self resumeDeferredRife];
            [self trimHeld]; delete job;
            return;
        }
    }
    if (error || outputs.count == 0) {
        if (_rife && [error.domain isEqualToString:@"app.openduckframe.rife"] && error.code == SPRifeBridgeErrorOutputPoolExhausted) {
            _rifePoolPressureEvents++;
            for (int i = 0; i < job->count; ++i) [self erasePending:job->pts[i]];
            int64_t now=SPHostNow(), retry=now+SPRationalToHost(sp::spMake(5,1000));
            sp::SPScheduleOutput event; event.action=sp::SPScheduleAction::Interpolate;
            event.frameA=job->frameA; event.frameB=job->frameB; event.pts=job->pts[0]; event.phase=job->phase[0];
            BOOL deferred=job->count==1 && retry<job->targetHost[0] &&
                [self deferRifeEvent:event generation:job->generation deadline:job->targetHost[0] retryHost:retry
                    frozenPairClock:job->pairClock[0].recorded ? &job->pairClock[0] : nullptr];
            if (deferred) {
                _rifePoolRetryAdmissions++;
                int64_t next=_slots.empty()?retry:MIN(retry,_slots.front().targetHost);
                [self armClockAt:next];
            } else {
                uint64_t dropped=(uint64_t)MAX(1,job->count);
                _rifePoolPressureDrops+=dropped; _queueDrops+=dropped; _epochQueueDrops+=dropped;
                for (int i=0;i<job->count;i++) [self noteRateBudgetDrop:job->pts[i]];
                for (int i=0;i<job->count;i++) {
                    if (job->targetHost[i] > now) _rifePoolUnexpiredDrops++;
                    else if ([self noteUniqueSyntheticDrop:job->pts[i]]) _pendingExpiredDrops++;
                }
            }
            [self resumeDeferredRife]; [self trimHeld]; delete job; return;
        }
        [self clearPendingRife];
        for (int i = 0; i < job->count; ++i) [self erasePending:job->pts[i]];
        _syntheticFail += (uint64_t)MAX((NSUInteger)1, outputs.count);
        if (_rife) for (int i = 0; i < job->count; ++i) [self noteRateBudgetDrop:job->pts[i]];
        _resolved.interpolationActive = NO;
        _resolved.unavailableReason = error.localizedDescription ?: @"插帧失败";
        [self publishStatus:_resolved.unavailableReason failed:YES];
        [self trimHeld]; delete job;
        return;
    }
    BOOL recovered = _resolved.unavailableReason.length > 0;
    _resolved.interpolationActive = YES;
    if (!_srFailed) _resolved.unavailableReason = @"";
    if (recovered && !_holdFailureStatus && !_srFailed) [self publishStatus:@"增强运行" failed:NO];
    _syntheticOK += outputs.count;
    NSUInteger index = 0;
    for (SPOwnedPixelBuffer *box in outputs) {
        const NSUInteger phaseIndex = MIN(index, (NSUInteger)2);
        sp::SPRational pts = job->pts[phaseIndex];
        int64_t phaseDeadline = job->targetHost[phaseIndex];
        index += 1;
        CVPixelBufferRef bgra = [self transfer:box.buffer format:kCVPixelFormatType_32BGRA];
        if ([self requestUsesAsyncScale:_request]) {
            CVPixelBufferRef original = nil;
            auto sourceA = _held.find(job->frameA);
            if (_request.viewMode != SPLiveViewEnhanced && sourceA != _held.end()) {
                CVPixelBufferRef base = [self bgraFromSource:sourceA->second.source];
                original = [self scaleBuffer:base with:_baselineScaler];
                if (base) CVPixelBufferRelease(base);
            }
            int64_t geometryHost = sourceA != _held.end() ? sourceA->second.host : 0;
            [self enqueueAsyncScale:bgra original:original pts:pts synthetic:YES held:NO
                        captureHost:job->captureHost generation:job->generation deadlineHost:phaseDeadline geometryHost:geometryHost];
            continue;
        }
        CVPixelBufferRef scaled = bgra;
        if (bgra && _scaler && [_request.engineID isEqualToString:@"apple.lowlatency"] && [self requestUsesLowPrescale:_request width:_width height:_height]) _lowSyntheticNoRescale++;
        if (bgra && _scaler && !([_request.engineID isEqualToString:@"apple.lowlatency"] && [self requestUsesLowPrescale:_request width:_width height:_height])) {
            CVPixelBufferRef scaleInput = [self scaleBuffer:bgra with:_srInputScaler];
            scaled = scaleInput ? [_scaler scaleBuffer:scaleInput error:NULL] : NULL;
            if (scaleInput) CVPixelBufferRelease(scaleInput);
            CVPixelBufferRelease(bgra);
        }
        if (!scaled) {
            _syntheticFail += 1;
            if (_rife) [self noteRateBudgetDrop:pts];
            [self erasePending:pts];
            continue;
        }
        CVPixelBufferRef original = nil;
        auto sourceA = _held.find(job->frameA);
        if (_request.viewMode != SPLiveViewEnhanced && sourceA != _held.end()) {
            if (_lowLatency && [self requestUsesLowPrescale:_request width:_width height:_height]) {
                CVPixelBufferRef cached=[self lowPrescaledForIdentity:job->frameA];
                if (cached) original=CVPixelBufferRetain(cached);
            } else {
                CVPixelBufferRef base = [self bgraFromSource:sourceA->second.source];
                original = [self scaleBuffer:base with:_request.scaleEnabled ? _baselineScaler : nil];
                if (base) CVPixelBufferRelease(base);
            }
        }
        if (_testCapturePlayout && original && sourceA != _held.end()) {
            int a=SPTestBGRAFirstByte(sourceA->second.source), b=SPTestBGRAFirstByte(original);
            if (a>=0 && b>=0) { if (abs(a-b)<=2) _testBaselineMatches++; else _testBaselineMismatches++; }
        }
        int64_t geometryHost = sourceA != _held.end() ? sourceA->second.host : 0;
        [self enqueueReadyEnhanced:scaled original:original pts:pts synthetic:YES held:NO
                      captureHost:job->captureHost generation:job->generation deadlineHost:phaseDeadline jobID:job->diagnosticID geometryHost:geometryHost];
    }
    if (!_rifePending.empty() && _rifePendingGeneration == _sourceGeneration && (_rife || _lowLatency) && !_stopped) {
        auto pending = _rifePending;
        uint64_t pendingGeneration = _rifePendingGeneration;
        [self clearPendingRife];
        [self submitEventGroup:pending generation:pendingGeneration];
    }
    [self resumeDeferredRife];
    [self trimHeld];
    delete job;
}

- (void)trimHeld {
    // The scheduler needs the newest two sources for the next pair (and, at
    // submission time, the previous source of A for three-frame engines).
    // Jobs and pending pairs pin every older source they still use. Keep the
    // newest two regardless of pinning, release every other unpinned entry.
    // Unlike a fixed high-water mark this leaves room even in a four-buffer
    // capture pool. In-flight owners are never reclaimed early.
    std::vector<sp::HeldLease> leases;
    leases.reserve(_held.size());
    for (const auto &entry : _held) leases.push_back({entry.first, entry.second.pins});
    for (uint64_t key : sp::reclaimableHeld(std::move(leases))) {
        auto found = _held.find(key);
        if (found == _held.end()) continue;
        if (found->second.source) CVPixelBufferRelease(found->second.source);
        if (found->second.yuv) CVPixelBufferRelease(found->second.yuv);
        if (found->second.lowPrescaled) CVPixelBufferRelease(found->second.lowPrescaled);
        _held.erase(found);
    }
}

// The accepted input clock and its generated events must be processed as one
// ordered operation. Shared with the deterministic production-path contract.
- (void)handleAcceptedInput:(uint64_t)identity events:(const std::vector<sp::SPScheduleOutput> &)events generation:(uint64_t)generation {
    [self observeSourceIdentity:identity];
    if([self usesRifePairAffineClock]) [self freezeRifeSourceClockIdentity:identity generation:generation];
    [self handleEvents:events generation:generation];
}

- (void)handleEvents:(const std::vector<sp::SPScheduleOutput> &)events generation:(uint64_t)generation {
    auto raw = [self nativeCadenceSnapshot];
    _nativeBudgetActive = [self nativeBudgetForSnapshot:raw];
    if (!_nativeBudgetActive) _nativeBGRADirectActive=NO;
    if (_nativeBudgetActive && _rateBudgetProbeActive) [self cancelRateBudgetProbe];
    size_t index = 0;
    while (index < events.size()) {
        const sp::SPScheduleOutput &event = events[index];
        if (event.skipReason == sp::SPScheduleSkipReason::SceneCut ||
            event.skipReason == sp::SPScheduleSkipReason::Gap ||
            event.skipReason == sp::SPScheduleSkipReason::Boundary) {
            _sceneSkips += 1;
            _havePair = NO;
            [self clearPendingRife];
        }
        if (event.action != sp::SPScheduleAction::Interpolate) {
            auto found = _held.find(event.sourceIdentity);
            int64_t host = found == _held.end() ? 0 : found->second.host;
            const BOOL retimed = [self usesFixedSourceReuse] && event.action == sp::SPScheduleAction::PresentSource;
            if (retimed && found != _held.end() && sp::spCmp(event.pts, found->second.pts) != 0) _fixedSourceReused++;
            [self enqueueSourceIdentity:event.sourceIdentity pts:event.pts host:host generation:generation
                                   force:_nativeBudgetActive || _rateBudgetPassthrough || event.skipReason != sp::SPScheduleSkipReason::None retimed:retimed];
            index += 1;
            continue;
        }
        std::vector<sp::SPScheduleOutput> group;
        while (index < events.size() && events[index].action == sp::SPScheduleAction::Interpolate &&
               events[index].frameA == event.frameA && events[index].frameB == event.frameB) {
            group.push_back(events[index]);
            index += 1;
        }
        if (_rateBudgetPassthrough && !_nativeBudgetActive &&
            [self collectRateBudgetProbeGroup:group generation:generation]) continue;
        _scheduledSynthetic += group.size();
        _epochScheduled += group.size();
        if (_probeWindowOpen) {
            for (const auto &item : group) {
                if (sp::spCmp(item.pts, _probeMinPts) >= 0) _measuredScheduled += 1;
            }
        }
        // Raw callback cadence is independent of copy admission, scheduler,
        // inference and the measurement epoch. Match it to this source/size.
        if (_nativeBudgetActive) {
            _nativeBudgetSkippedPhases += group.size();
            continue;
        }
        if (_rateBudgetPassthrough) {
            _rateBudgetSkippedPhases += group.size();
            continue;
        }
        [self noteRateBudgetPlanned:group.size()];
        if ([self usesFixedSourceReuse]) {
            const int batchCount = (int)MIN((size_t)3, group.size());
            if (batchCount > _fixedMaxBatchCount) {
                _fixedMaxBatchCount = batchCount;
                [self recomputeInteractiveDelay];
            }
            [self enqueueFixedFallbacks:group generation:generation];
        }
        if (group.size() > 3) _phaseBatchSplits += 1;
        for (size_t batch = 0; batch < group.size(); batch += 3) {
            size_t count = MIN((size_t)3, group.size() - batch);
            std::vector<sp::SPScheduleOutput> slice(group.begin() + (long)batch, group.begin() + (long)(batch + count));
            [self submitEventGroup:slice generation:generation];
        }
    }
}

- (BOOL)buildOnQueue:(NSError **)error {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        if (error) *error = SPLiveError(30, @"没有 Metal 设备");
        return NO;
    }
    if (_request.interpolationEnabled && ![self requestUsesAsyncEngine:_request]) {
        if (![SPFRCEngine isAvailable]) {
            if (error) *error = SPLiveError(31, @"这台 Mac 不支持 Apple 帧率转换");
            _resolved.interpolationActive = NO;
            _resolved.unavailableReason = @"Apple 帧率转换不可用";
            return NO;
        }
        NSError *local = nil;
        _metal = [[SPFrameBudgetMetal alloc] initWithDevice:device library:nil width:(uint32_t)_width
                                                     height:(uint32_t)_height
                                                pixelFormat:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                                                      error:&local];
        SPFRCQuality quality = _request.quality == SPFRCQualityHigh ? SPFRCQualityHigh : SPFRCQualityNormal;
        const BOOL continuousFRC = [[[NSProcessInfo processInfo] environment][@"CHUANFLOW_FRC_CONTINUOUS"] isEqualToString:@"1"];
        int sessions = [self r8CanExperiment] ? SPR8Option(@"--odf-r8-sessions", continuousFRC ? 1 : 2, @[@1,@2,@3,@4]) : (continuousFRC ? 1 : 2);
        _engine = _metal ? [[SPFRCEngine alloc] initWithMetal:_metal sessions:sessions outputCapacity:8 quality:quality error:&local] : nil;
        if (!_engine) {
            if (error) *error = local ?: SPLiveError(32, @"插帧会话创建失败");
            _resolved.interpolationActive = NO;
            _resolved.unavailableReason = local.localizedDescription ?: @"插帧会话创建失败";
            return NO;
        }
        if (SPR8Enabled()) {
            __weak SPLiveProcessor *weakProcessor = self;
            _engine.diagnosticHandler = ^(NSDictionary<NSString *, id> *event) {
                SPLiveProcessor *processor = weakProcessor;
                if (!processor) return;
                dispatch_async(processor->_q, ^{ [processor recordR7JobEvent:@"frcStages" detail:event]; });
            };
        }
        _resolved.interpolationActive = YES;
        _resolved.unavailableReason = @"";
    } else if (_request.interpolationEnabled) {
        if (!_lowLatency && !_rife && !_distil) {
            if (error) *error = SPLiveError(35, @"引擎还没有准备好");
            _resolved.interpolationActive = NO;
            return NO;
        }
        _resolved.interpolationActive = YES;
        _resolved.engineID = _request.engineID ?: @"";
        _resolved.modelID = _request.modelID ?: @"";
        _resolved.unavailableReason = @"";
    }
    if (_request.scaleEnabled) {
        BOOL automatic = _request.outputWidth == 0 && _request.outputHeight == 0;
        BOOL autoAnime = SPLiveIsNative2xScaleEngine(_request.scaleEngine) && automatic;
        NSSize effective = SPLiveSRInputSizeForRequest(_width, _height, _request);
        int inputW = (int)effective.width, inputH = (int)effective.height;
        BOOL autoApple = automatic && (_request.scaleEngine == SPLiveScaleAppleLowLatencySR || _request.scaleEngine == SPLiveScaleAppleVideoSR);
        NSSize appleOutput = !autoApple ? NSZeroSize : (_request.scaleEngine == SPLiveScaleAppleVideoSR ?
            [SPAppleVideoSR automaticOutputForWidth:inputW height:inputH] : [SPAppleLowLatencySR automaticOutputForWidth:inputW height:inputH]);
        int outW = autoAnime ? inputW * 2 : (autoApple ? (int)appleOutput.width : (_request.outputWidth > 0 ? (_request.outputWidth & ~1) : _width));
        int outH = autoAnime ? inputH * 2 : (autoApple ? (int)appleOutput.height : (_request.outputHeight > 0 ? (_request.outputHeight & ~1) : _height));
        if (outW < 2 || outH < 2) {
            if (error) *error = SPLiveError(33, @"输出尺寸无效");
            return NO;
        }
        NSError *local = nil;
        if (inputW != _width || inputH != _height) {
            _srInputScaler = [[SPSpatialScaler alloc] initWithDevice:device inputW:_width inputH:_height outputW:inputW outputH:inputH engine:SPLiveScaleLanczos error:&local];
            if (!_srInputScaler) { if (error) *error = local ?: SPLiveError(34, @"超分输入缩放创建失败"); return NO; }
        }
        if (![self requestUsesAsyncScale:_request]) {
            _scaler = [[SPSpatialScaler alloc] initWithDevice:device inputW:inputW inputH:inputH outputW:outW outputH:outH
                                                       engine:_request.scaleEngine error:&local];
        }
        if (_request.scaleEngine == SPLiveScaleLanczos && !_srInputScaler) _baselineScaler = _scaler;
        else _baselineScaler = [[SPSpatialScaler alloc] initWithDevice:device inputW:_width inputH:_height outputW:outW outputH:outH
                                                                engine:SPLiveScaleLanczos error:&local];
        BOOL scaleEngineReady = SPLiveIsArtCNNScaleEngine(_request.scaleEngine) ? _artCNNSR != nil :
            (_request.scaleEngine == SPLiveScaleAppleLowLatencySR ? _appleSR != nil : (_request.scaleEngine == SPLiveScaleAppleVideoSR ? _videoSR != nil : (_request.scaleEngine == SPLiveScaleAnime4K ? _animeSR != nil : (_request.scaleEngine == SPLiveScaleRealCUGAN ? _cuganSR != nil : _scaler != nil))));
        if (!scaleEngineReady || !_baselineScaler) {
            _resolved.scaleActive = NO;
            _resolved.unavailableReason = local.localizedDescription ?: @"缩放创建失败";
            if (error) *error = local ?: SPLiveError(34, _resolved.unavailableReason);
            [self publishStatus:_resolved.unavailableReason failed:YES];
            return ([self requestUsesAsyncScale:_request] || [self requestUsesLowPrescale:_request width:_width height:_height]) ? NO : (!_request.interpolationEnabled ? NO : YES);
        }
        if ([self requestUsesLowPrescale:_request width:_width height:_height]) {
            CVPixelBufferRef sample=NULL;
            for (const auto &entry : _held) if (entry.second.source) { sample=entry.second.source; break; }
            if (sample) {
                CVPixelBufferRef bgra=[self transfer:sample format:kCVPixelFormatType_32BGRA];
                CVPixelBufferRef scaled=bgra ? [self scaleBuffer:bgra with:_scaler] : NULL;
                if (bgra) CVPixelBufferRelease(bgra);
                BOOL valid=scaled && CVPixelBufferGetWidth(scaled)==outW && CVPixelBufferGetHeight(scaled)==outH;
                if (scaled) CVPixelBufferRelease(scaled);
                if (!valid) { if (error) *error=SPLiveError(39,@"低延迟前置缩放准备失败"); return NO; }
            }
        }
        _resolved.scaleActive = YES;
        _resolved.outputWidth = outW;
        _resolved.outputHeight = outH;
    } else {
        _resolved.scaleActive = NO;
        _resolved.outputWidth = _width;
        _resolved.outputHeight = _height;
    }
    if (!_request.interpolationEnabled) _resolved.interpolationActive = NO;
    _resolved.unavailableReason = @"";
    _sessionReady = YES;
    _resolved.committed = YES;
    NSString *status = _stopped ? @"已停止" : (_resolved.interpolationActive ? @"增强运行" : (_resolved.scaleActive ? @"缩放运行" : @"预览原画面"));
    if (!_stopped && _resolved.presentationLimited) status = [status stringByAppendingString:@" · 显示器刷新率低于目标帧率"];
    [self publishStatus:status failed:NO];
    return YES;
}

- (void)beginBuildOnQueue {
    if (_sessionReady || _width < 2) return;
    if ([self requestUsesAsyncEngine:_request] || [self requestUsesAsyncScale:_request]) {
        if (_preparing || _asyncPrepareFailed) return;
        [self startAsyncEngine:_request];
        return;
    }
    if (_building) return;
    _building = YES;
    [self publishStatus:@"准备引擎" failed:NO];
    NSError *error = nil;
    int64_t traceBuildStart = _testCapturePlayout ? SPHostNow() : 0;
    BOOL ok = [self buildOnQueue:&error];
    if (_testCapturePlayout && _testTimingTrace.count < 80) {
        if (!_testTimingTrace) _testTimingTrace=[NSMutableArray array];
        [_testTimingTrace addObject:@{ @"kind":@"rebuild", @"durationMs":@((double)SPHostToNs(SPHostNow()-traceBuildStart)/1e6),
            @"success":@(ok), @"error":error.localizedDescription ?: @"", @"configVersion":@(_configVersion) }];
    }
    _building = NO;
    if (!ok) [self publishStatus:error.localizedDescription ?: @"准备失败" failed:YES];
}

- (void)pump {
    std::deque<SPLiveInbound> batch;
    {
        std::lock_guard<std::mutex> lock(_inMx);
        batch.swap(_inbound);
        _pumpQueued = NO;
    }
    if (SPR7Passthrough() || !_request.interpolationEnabled) {
        // Coalesce only already-buffered frames of the current source. Pick
        // the greatest valid PTS rather than blindly trusting callback order.
        size_t newest = batch.size();
        for (size_t i=0; i<batch.size(); ++i) {
            if (batch[i].generation != _sourceGeneration || batch[i].ptsDen <= 0) continue;
            if (newest == batch.size() || sp::spCmp(sp::spMake(batch[i].ptsNum,batch[i].ptsDen),
                                                     sp::spMake(batch[newest].ptsNum,batch[newest].ptsDen)) > 0) newest = i;
        }
        if (newest != batch.size()) {
            std::deque<SPLiveInbound> kept;
            for (size_t i=0; i<batch.size(); ++i) {
                if (i != newest && batch[i].generation == _sourceGeneration) {
                    CVPixelBufferRelease(batch[i].buffer); _queueDrops++; _epochQueueDrops++;
                    if (_videoSR) _videoSRDiscontinuity = YES;
                } else kept.push_back(batch[i]);
            }
            batch.swap(kept);
        }
    }
    for (auto &item : batch) {
        if (item.readyHost > item.host) SPPushSample(_copyEntryNs, SPHostToNs(item.readyHost - item.host));
        if (_stopped) {
            _stoppedDrops += 1;
            CVPixelBufferRelease(item.buffer);
            if (_stoppedDrops == 1 || _stoppedDrops % 60 == 0) {
                [self publishStatus:@"已停止，新帧已丢弃" failed:YES];
            }
            continue;
        }
        if (item.generation != _sourceGeneration) {
            _generationDrops += 1;
            CVPixelBufferRelease(item.buffer);
            continue;
        }
        if (item.ptsDen > 0) {
            __int128 inputPTS = (__int128)item.ptsNum * 1000000000 / item.ptsDen;
            if (inputPTS >= INT64_MIN && inputPTS <= INT64_MAX) {
                _fpsMeter.input((int64_t)inputPTS, (int64_t)(CACurrentMediaTime() * 1e9));
                _pumpedCaptureMeter.input((int64_t)inputPTS, SPHostToNs(item.host));
            }
        }
        const SPLiveCaptureSourceKind previousActualKind = _airActualSourceKind;
        CFTypeRef sourceKind = CVBufferGetAttachment(item.buffer, CFSTR("app.openduckframe.capture.sourceKind"), nullptr);
        _airActualSourceKind = SPLiveCaptureSourceKindUnknown;
        if (sourceKind && CFGetTypeID(sourceKind) == CFNumberGetTypeID()) {
            const NSInteger kind = [(__bridge NSNumber *)sourceKind integerValue];
            if (kind >= SPLiveCaptureSourceKindWindow && kind <= SPLiveCaptureSourceKindFile)
                _airActualSourceKind = (SPLiveCaptureSourceKind)kind;
        }
        _airPerformanceFormatKnown = YES;
        _airPerformanceRequested = _airPerformanceCandidate && _airActualSourceKind == SPLiveCaptureSourceKindWindow;
#if ODF_AIR_BETA_DIAGNOSTIC || ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
        _airPerformanceFormatReason = _airPerformanceRequested ? SPAirBetaFormatReason(item.buffer) : nil;
#endif
        if (_airPerformanceCandidate && previousActualKind != _airActualSourceKind) {
            ++_prepareToken; _preparing = NO; _asyncPrepareFailed = NO;
            [self retireEngines]; [self airSetPerformanceMode:NO];
            _sessionReady = NO; _resolved.interpolationActive = NO;
            _request = [_airPerformanceRecipe copy];
            [self clearPendingRife]; [self clearPlaySlots];
            [self.outputPreview invalidateSharedGeometry];
            ++_configVersion; _inflightEpoch = _configVersion; _inflight = 0;
            _airPerformanceEligibilityKnown = NO;
            [self beginMeasurementEpoch];
        }
#if ODF_AIR_BETA_DIAGNOSTIC
        if (SPAirBetaEnabled()) {
            _airBetaFormatKnown = YES;
            _airBetaFormatReason = SPAirBetaFormatReason(item.buffer);
            _airBetaFormatDescription = _airBetaFormatReason ? SPAirBetaFourCC(CVPixelBufferGetPixelFormatType(item.buffer)) : @"420v · BT.709 · SDR";
        }
#endif
        if (SPBufferIsHDR(item.buffer) && !SPAirBetaEnabled() && !_airPerformanceRequested) {
            CVPixelBufferRelease(item.buffer);
            _resolved.interpolationActive = NO;
            _resolved.scaleActive = NO;
            BOOL rife = [_request.engineID isEqualToString:@"rife.metal"];
            NSString *reason = rife ? @"RIFE 只处理 8 位 SDR，HDR 已停用" : @"HDR 捕获未增强";
            _resolved.unavailableReason = reason;
            [self publishStatus:reason failed:YES];
            continue;
        }
        _sourcePixelFormat = CVPixelBufferGetPixelFormatType(item.buffer);
        int previousSourceWidth = _sourceWidth, previousSourceHeight = _sourceHeight;
        _sourceWidth = (int)CVPixelBufferGetWidth(item.buffer);
        _sourceHeight = (int)CVPixelBufferGetHeight(item.buffer);
#if ODF_AIR_BETA_DIAGNOSTIC
        if (SPAirBetaEnabled() || _airPerformanceRequested) {
            [self.outputPreview setAirBetaCaptureWidth:_sourceWidth height:_sourceHeight];
            [self.preview setAirBetaCaptureWidth:_sourceWidth height:_sourceHeight];
        }
#endif
        if (_request.requiredSourceWidth > 0 && _request.requiredSourceHeight > 0) {
            if (_request.requiredSourceAfterHost && item.host <= (int64_t)_request.requiredSourceAfterHost) {
                CVPixelBufferRelease(item.buffer); continue;
            }
            NSDictionary *frameGeometry = CFBridgingRelease(CVBufferCopyAttachment(item.buffer, CFSTR("app.openduckframe.capture.geometry"), NULL));
            sp::GeometrySource geometry{};
            bool valid = SPSourceGeometryValue(frameGeometry, geometry) && geometry.generation == item.generation &&
                geometry.windowID == _request.requiredSourceWindowID && geometry.pid == (uint64_t)_request.requiredSourcePID &&
                _sourceWidth == _request.requiredSourceWidth && _sourceHeight == _request.requiredSourceHeight &&
                geometry.bufferWidth == _sourceWidth && geometry.bufferHeight == _sourceHeight &&
                std::isfinite(geometry.scaleFactor) && std::isfinite(geometry.contentScale) && fabs(geometry.contentScale-1.0) <= 0.002 &&
                fabs(geometry.screenRect.width*geometry.scaleFactor-_sourceWidth) <= 1 && fabs(geometry.screenRect.height*geometry.scaleFactor-_sourceHeight) <= 1 &&
                fabs(geometry.contentRect.x) <= .01 && fabs(geometry.contentRect.y) <= .01 &&
                fabs(geometry.contentRect.width*geometry.scaleFactor-_sourceWidth) <= 1 && fabs(geometry.contentRect.height*geometry.scaleFactor-_sourceHeight) <= 1;
            if (_sourceSizeConstraintFailed || !valid) {
                _width = _sourceWidth & ~1; _height = _sourceHeight & ~1;
                if (!_sourceSizeConstraintFailed) {
                    _sourceSizeConstraintFailed = YES; ++_configVersion; _resolved.configVersion = _configVersion;
                    ++_prepareToken; _preparing = NO; _sessionReady = NO; [self retireEngines];
                    [_appleSR invalidate]; [_videoSR invalidate]; [_animeSR invalidate]; [_cuganSR invalidate]; [_artCNNSR invalidate];
                    _appleSR=nil; _videoSR=nil; _animeSR=nil; _cuganSR=nil; _artCNNSR=nil;
                    _scaler=nil; _baselineScaler=nil; _srInputScaler=nil;
                    [self discardQueuedStateOnQueue]; [self.outputPreview invalidateSharedGeometry];
                    if (_lastEnhanced) { CVPixelBufferRelease(_lastEnhanced); _lastEnhanced=nullptr; }
                    if (_lastOriginal) { CVPixelBufferRelease(_lastOriginal); _lastOriginal=nullptr; }
                    _resolved.committed=NO; _resolved.scaleActive=NO; _resolved.interpolationActive=NO;
                    _resolved.unavailableReason=@"来源窗口采集尺寸或几何已改变，请重新应用。";
                    [self publishStatus:_resolved.unavailableReason failed:YES];
                    [self publishPlanState:0 reason:_resolved.unavailableReason];
                }
                CVPixelBufferRelease(item.buffer); [self publishStats]; continue;
            }
        }
        int width = _sourceWidth & ~1;
        int height = _sourceHeight & ~1;
        // A prepared processing size can precede the first observed raw size.
        // First observation confirms it; only a change between known raw sizes
        // invalidates an otherwise identical even-sized processing pipeline.
        BOOL hadRawSize = previousSourceWidth > 0 && previousSourceHeight > 0;
        BOOL rawSizeChanged = hadRawSize && (_sourceWidth != previousSourceWidth || _sourceHeight != previousSourceHeight);
        if (_testCapturePlayout && _testTimingTrace.count < 80) {
            if (!_testTimingTrace) _testTimingTrace=[NSMutableArray array];
            [_testTimingTrace addObject:@{ @"kind":@"pumpInput", @"ptsNum":@(item.ptsNum), @"ptsDen":@(item.ptsDen),
                @"sourceSize":@[@(_sourceWidth),@(_sourceHeight)], @"knownRawBefore":@(hadRawSize),
                @"sizeInvalidates":@(width!=_width || height!=_height || rawSizeChanged), @"sessionReady":@(_sessionReady),
                @"captureToPumpMs":@((double)SPHostToNs(SPHostNow()-item.host)/1e6),
                @"configVersion":@(_configVersion), @"measurementEpoch":@(_measurementEpoch) }];
        }
        if (width != _width || height != _height || rawSizeChanged) {
            if (_sessionReady && _resolved.scaleActive && _request.scaleEnabled && (_request.scaleEngine == SPLiveScaleAppleLowLatencySR || _request.scaleEngine == SPLiveScaleAppleVideoSR)) {
                NSSize previous = SPLiveSRInputSizeForRequest(_width, _height, _request);
                NSSize next = SPLiveSRInputSizeForRequest(width, height, _request);
                int outW=0, outH=0;
                if (sp::resizedNativeSROutput((int)previous.width, (int)previous.height, _request.outputWidth, _request.outputHeight,
                                               (int)next.width, (int)next.height, outW, outH)) {
                    _request = [_request copy]; _request.outputWidth = outW; _request.outputHeight = outH;
                }
            }
            _resolved.committed = NO; _resolved.scaleActive = NO; _resolved.interpolationActive = NO;
            _width = width;
            _height = height;
            [self.outputPreview invalidateSharedGeometry];
            _configVersion += 1;
            _inflightEpoch = _configVersion;
            _inflight = 0;
            _sessionReady = NO;
            [self resetRateBudgetOnQueue];
            _prepareToken += 1;
            _preparing = NO;
            _asyncPrepareFailed = NO;
            [_engine invalidate];
            _engine = nil;
            [_lowLatency invalidate];
            _lowLatency = nil;
#if ODF_AIR_BETA_DIAGNOSTIC
            if (SPAirBetaEnabled() || _airPerformanceEnabled) [self airRetireResidentKeeperForBridge:_rife reason:@"capture-size-changed"];
#endif
            [_rife invalidate];
            _rife = nil;
            [_distil invalidate];
            _distil = nil;
            _previousSourceIdentity = 0;
            [self clearPendingRife];
            [self trimHeld];
            [_appleSR invalidate];
            [_videoSR invalidate];
            [_animeSR invalidate];
            [_cuganSR invalidate];
            [_artCNNSR invalidate];
            _appleSR = nil;
            _videoSR = nil;
            _animeSR = nil;
            _cuganSR = nil;
            _artCNNSR = nil;
            [self resetAsyncScaleOnQueue];
            _scaler = nil;
            _baselineScaler = nil;
            _srInputScaler = nil;
            _havePair = NO;
            [self clearPlaySlots];
            _pending.clear();
            _marks.clear();
            _haveLastPts = NO;
            _haveAnchor = NO;
            [self resetSchedulerOnQueue];
            [self beginMeasurementEpoch];
        }
#if ODF_AIR_BETA_DIAGNOSTIC
        if (SPAirBetaEnabled() && _airBetaRecipe) {
            NSString *eligibility = [self airBetaEnvironmentReason];
            BOOL changedEligibility = !_airBetaEligibilityKnown || !(_airBetaEligibilityReason == eligibility || [_airBetaEligibilityReason isEqual:eligibility]);
            if (changedEligibility || rawSizeChanged || !hadRawSize) {
                _airBetaEligibilityKnown = YES; _airBetaEligibilityReason = [eligibility copy];
                [self startAsyncEngine:_airBetaRecipe];
            }
        }
#endif
        if (_airPerformanceRecipe) {
            NSString *eligibility = [self airPerformanceEnvironmentReason];
            BOOL changedEligibility = !_airPerformanceEligibilityKnown ||
                !(_airPerformanceEligibilityReason == eligibility || [_airPerformanceEligibilityReason isEqual:eligibility]);
            if (changedEligibility || rawSizeChanged || !hadRawSize) {
                _airPerformanceEligibilityKnown = YES; _airPerformanceEligibilityReason = [eligibility copy];
                [self startAsyncEngine:_airPerformanceRecipe];
            }
        }
        uint8_t luma[64];
        SPSampleLuma(item.buffer, luma, 64);
        BOOL cut = NO;
        BOOL changed = YES;
        BOOL comparableLuma = _haveLuma && _r7LumaGeneration == _sourceGeneration &&
            _r7LumaConfig == _configVersion && _r7LumaEpoch == _measurementEpoch;
        if (_haveLuma) {
            cut = sp::spDetectSceneCut(_previousLuma, luma, 64);
            int64_t mad = 0;
            for (int i = 0; i < 64; ++i) {
                int delta = (int)luma[i] - (int)_previousLuma[i];
                if (delta < 0) delta = -delta;
                mad += delta;
            }
            changed = mad / 64 > 3;
        }
        memcpy(_previousLuma, luma, 64);
        _haveLuma = YES;
        if (cut && _videoSR) _videoSRDiscontinuity = YES;
        if (changed) _windowChanged += 1;
        // Recovery evidence requires two comparable samples in this exact
        // source/configuration/measurement epoch. Never count the first sample.
        if (comparableLuma && changed && item.host > 0) {
            _r7ContentChangedHost = item.host;
            _r7ContentChangedGeneration = _sourceGeneration;
            _r7ContentChangedConfig = _configVersion;
            _r7ContentChangedEpoch = _measurementEpoch;
        }
        _r7LumaGeneration = _sourceGeneration;
        _r7LumaConfig = _configVersion;
        _r7LumaEpoch = _measurementEpoch;
        _processedSequence += 1;
        _lastProcessedHost = SPHostNow();
        uint64_t identity = _nextIdentity++;
        _held[identity].source = item.buffer;
        _held[identity].host = item.host;
        _held[identity].pts = sp::spMake(item.ptsNum, item.ptsDen);
        NSDictionary *geometry = CFBridgingRelease(CVBufferCopyAttachment(item.buffer, CFSTR("app.openduckframe.capture.geometry"), NULL));
        if ([geometry isKindOfClass:NSDictionary.class] && item.host > 0) {
            NSNumber *key = @(item.host); _geometryInputs[key] = [geometry copy]; [_geometryInputOrder addObject:key];
            while (_geometryInputOrder.count > 128) { NSNumber *old = _geometryInputOrder.firstObject; [_geometryInputOrder removeObjectAtIndex:0]; [_geometryInputs removeObjectForKey:old]; }
        }
        if (_pixelDiagnosticsEnabled)
            [self sampleDiagnosticInput:item.buffer host:item.host identity:identity ptsNum:item.ptsNum ptsDen:item.ptsDen];
        auto previous = _held.find(_previousSourceIdentity);
        if (!cut && previous != _held.end()) {
            sp::SPRational delta{};
            if (sp::spSub(_held[identity].pts, previous->second.pts, delta) &&
                sp::spCmp(delta, sp::spMake(0, 1)) > 0 && sp::spCmp(delta, sp::spMake(1, 2)) <= 0)
                _held[identity].previousIdentity = _previousSourceIdentity;
        }
        // Explicit isolated diagnostic: use the production presenter and source
        // timing, but never construct or submit enhancement jobs.
        if (SPR7Passthrough()) {
            _resolved.committed = YES;
            _resolved.interpolationActive = NO;
            _resolved.scaleActive = NO;
            _resolved.configVersion = _configVersion;
            _sessionReady = YES;
            _previousSourceIdentity = identity;
            [self observeSourceIdentity:identity];
            CVPixelBufferRef original = [self bgraFromSource:item.buffer];
            if (original) {
                [self enqueueReadyEnhanced:original original:CVPixelBufferRetain(original)
                                      pts:sp::spMake(item.ptsNum, item.ptsDen) synthetic:NO held:NO
                              captureHost:item.host generation:item.generation deadlineHost:0];
            } else { _sourceConversionDrops++; }
            [self trimHeld];
            continue;
        }
        if ((_request.interpolationEnabled || _request.scaleEnabled) && !_sessionReady) {
            [self beginBuildOnQueue];
        }
        [self updateRateBudgetOnQueue];
        BOOL engineReady = _engine != nil || _lowLatency != nil || _rife != nil || _distil != nil;
        if (_request.interpolationEnabled && _sessionReady && engineReady) {
            sp::SPScheduleInput input;
            input.pts = sp::spMake(item.ptsNum, item.ptsDen);
            input.identity = identity;
            input.generation = _configVersion;
            input.sceneCutBefore = cut;
            sp::SPSchedulePushResult result = _scheduler.push(input);
            if (result.reject == sp::SPScheduleReject::None) {
                _previousSourceIdentity = identity;
                [self handleAcceptedInput:identity events:result.events generation:item.generation];
            } else {
                // A rejected PTS does not advance the scheduler. Do not let
                // rejected pump identities evict its last accepted source.
                auto rejected = _held.find(identity);
                if (rejected != _held.end()) {
                    if (rejected->second.source) CVPixelBufferRelease(rejected->second.source);
                    _held.erase(rejected);
                }
            }
        } else {
            _previousSourceIdentity = identity;
            sp::SPRational pts = sp::spMake(item.ptsNum, item.ptsDen);
            [self observeSourceIdentity:identity];
            [self enqueueSourceIdentity:identity pts:pts host:item.host generation:item.generation force:NO];
        }
        [self trimHeld];
    }
    [self publishStats];
}

- (BOOL)installSynchronouslyWidth:(int)width height:(int)height error:(NSError **)error {
    __block BOOL ok = NO;
    __block NSError *local = nil;
    dispatch_sync(_q, ^{
        self->_stopped = NO;
        self->_width = width & ~1;
        self->_height = height & ~1;
        [self resetSchedulerOnQueue];
        [self refreshResolvedOnQueue];
        ok = [self buildOnQueue:&local];
    });
    if (!ok && error) *error = local;
    return ok;
}

+ (CVPixelBufferRef)syntheticFrame:(int)index {
    CVPixelBufferRef buffer = SPCreateBuffer(1280, 720, kCVPixelFormatType_32BGRA);
    if (!buffer) return NULL;
    CVPixelBufferLockBaseAddress(buffer, 0);
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(buffer);
    size_t stride = CVPixelBufferGetBytesPerRow(buffer);
    for (int y = 0; y < 720; ++y) {
        uint8_t *row = base + (size_t)y * stride;
        for (int x = 0; x < 1280; ++x) {
            row[x * 4 + 0] = 18;
            row[x * 4 + 1] = 18;
            row[x * 4 + 2] = 18;
            row[x * 4 + 3] = 255;
        }
    }
    int origin = 48 + (index % 20) * 36;
    for (int y = 220; y < 292; ++y) {
        uint8_t *row = base + (size_t)y * stride;
        for (int x = origin; x < origin + 72 && x < 1280; ++x) {
            row[x * 4 + 0] = 240;
            row[x * 4 + 1] = 240;
            row[x * 4 + 2] = 240;
            row[x * 4 + 3] = 255;
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    SPForceSDRAttachments(buffer);
    return buffer;
}

+ (NSDictionary<NSString *, id> *)runFRCPTSProbe {
    SPLiveProcessor *processor = [[SPLiveProcessor alloc] init];
    processor->_request.interpolationEnabled = YES;
    NSError *error = nil;
    if (![processor installSynchronouslyWidth:1280 height:720 error:&error])
        return @{@"processed": @NO, @"error": error.localizedDescription ?: @"prepare"};
    CVPixelBufferRef a = [self syntheticFrame:0], b = [self syntheticFrame:1];
    __block CVPixelBufferRef ya = NULL, yb = NULL;
    dispatch_sync(processor->_q, ^{
        ya = [processor transfer:a format:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange];
        yb = [processor transfer:b format:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange];
    });
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSUInteger count = 0;
    __block NSString *failure = @"";
    CMTime ptsA = CMTimeMake(3000000, 30000), ptsB = CMTimeMake(3001001, 30000);
    BOOL submitted = ya && yb && [processor->_engine submitPhasesWithFrameA:ya frameB:yb ptsA:ptsA ptsB:ptsB
        phases:@[@0.25f, @0.5f, @0.75f] sequential:NO token:1
        completion:^(uint64_t token, NSArray<SPOwnedPixelBuffer *> *outputs, double latency, NSError *runError) {
            (void)token; (void)latency; count = outputs.count; failure = runError.localizedDescription ?: @"";
            dispatch_semaphore_signal(done);
        }];
    if (submitted) dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    BOOL sameRejected = ya && yb && ![processor->_engine submitPhasesWithFrameA:ya frameB:yb ptsA:ptsA ptsB:ptsA
        phases:@[@0.5f] sequential:NO token:2 completion:^(uint64_t t, NSArray<SPOwnedPixelBuffer *> *o, double l, NSError *e) {
            (void)t; (void)o; (void)l; (void)e;
        }];
    __block BOOL midpointOK = NO;
    dispatch_semaphore_t midpointDone = dispatch_semaphore_create(0);
    BOOL midpointSubmitted = ya && yb && [processor->_engine submitPairWithFrameA:ya frameB:yb ptsA:ptsA ptsB:ptsB token:3
        completion:^(uint64_t token, CVPixelBufferRef output, double latency, NSError *runError) {
            (void)token; (void)latency; midpointOK = output != NULL && runError == nil;
            if (output) CVPixelBufferRelease(output);
            dispatch_semaphore_signal(midpointDone);
        }];
    if (midpointSubmitted) dispatch_semaphore_wait(midpointDone, DISPATCH_TIME_FOREVER);
    if (a) CVPixelBufferRelease(a); if (b) CVPixelBufferRelease(b);
    if (ya) CVPixelBufferRelease(ya); if (yb) CVPixelBufferRelease(yb);
    [processor stop];
    return @{@"processed": @(submitted && count == 3 && failure.length == 0), @"outputCount": @(count),
             @"duplicatePTSRejected": @(sameRejected), @"ptsA": @"3000000/30000", @"ptsB": @"3001001/30000",
             @"fileMidpointProcessed": @(midpointSubmitted && midpointOK),
             @"phases": @[@0.25f, @0.5f, @0.75f], @"error": failure};
}

+ (NSDictionary<NSString *, id> *)runAppleLowSRProbe {
    NSArray<NSNumber *> *factors = [SPAppleLowLatencySR supportedFactorsForWidth:1280 height:720];
    BOOL supportsCandidate = NO;
    for (NSNumber *factor in factors) if (fabsf(factor.floatValue - 1.5f) < 0.0001f) supportsCandidate = YES;
    if (!supportsCandidate) return @{@"supportedFactors": factors, @"candidateSupported": @NO, @"processed": @NO};
    SPAppleLowLatencySR *scaler = [[SPAppleLowLatencySR alloc] init];
    NSError *error = nil;
    if (![scaler prepareWidth:1280 height:720 scale:1.5f error:&error]) {
        return @{@"supportedFactors": factors, @"candidateSupported": @YES, @"processed": @NO,
                 @"error": error.localizedDescription ?: @"prepare"};
    }
    CVPixelBufferRef source = [self syntheticFrame:0];
    if (!source) { [scaler invalidate]; return @{@"candidateSupported": @YES, @"processed": @NO, @"error": @"source allocation"}; }
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    __block CVPixelBufferRef output = NULL;
    __block NSError *resultError = nil;
    __block double latency = 0;
    BOOL submitted = [scaler submitSource:source pts:CMTimeMake(1001, 30000) token:1
        completion:^(uint64_t token, CVPixelBufferRef result, double seconds, NSError *error) {
            (void)token; output = result; resultError = error; latency = seconds; dispatch_semaphore_signal(gate);
        }];
    if (submitted) dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER);
    int width = output ? (int)CVPixelBufferGetWidth(output) : 0;
    int height = output ? (int)CVPixelBufferGetHeight(output) : 0;
    OSType format = output ? CVPixelBufferGetPixelFormatType(output) : 0;
    double sourceCenter = SPWhiteCenterX(source);
    __block CVPixelBufferRef rgb = NULL;
    if (output) {
        SPLiveProcessor *converter = [[SPLiveProcessor alloc] init];
        dispatch_sync(converter->_q, ^{ rgb = [converter transfer:output format:kCVPixelFormatType_32BGRA]; });
    }
    double outputCenter = SPWhiteCenterX(rgb);
    BOOL contentOK = sourceCenter >= 0 && outputCenter >= 0 && fabs(outputCenter - sourceCenter * 1.5) <= 8;
    BOOL separateSurface = output && CVPixelBufferGetIOSurface(source) != CVPixelBufferGetIOSurface(output);
    BOOL processed = submitted && !resultError && width == 1920 && height == 1080 && contentOK && separateSurface;
    if (rgb) CVPixelBufferRelease(rgb);
    if (output) CVPixelBufferRelease(output);
    CVPixelBufferRelease(source);
    int continuousOK = 0, continuousFailed = 0;
    for (int i = 0; i < 300; ++i) {
        CVPixelBufferRef next = [self syntheticFrame:i];
        if (!next) { continuousFailed++; continue; }
        dispatch_semaphore_t nextGate = dispatch_semaphore_create(0);
        __block BOOL oneOK = NO;
        BOOL accepted = [scaler submitSource:next pts:CMTimeMake(i, 30) token:(uint64_t)i + 10
            completion:^(uint64_t callbackToken, CVPixelBufferRef result, double seconds, NSError *local) {
                (void)seconds;
                oneOK = callbackToken == (uint64_t)i + 10 && !local && result &&
                    CVPixelBufferGetWidth(result) == 1920 && CVPixelBufferGetHeight(result) == 1080;
                if (result) CVPixelBufferRelease(result);
                dispatch_semaphore_signal(nextGate);
            }];
        if (accepted) dispatch_semaphore_wait(nextGate, DISPATCH_TIME_FOREVER);
        if (accepted && oneOK) continuousOK++; else continuousFailed++;
        CVPixelBufferRelease(next);
    }
    [scaler invalidate];
    return @{@"supportedFactors": factors, @"candidateSupported": @YES, @"processed": @(processed),
             @"width": @(width), @"height": @(height), @"pixelFormat": @(format), @"pts": @"1001/30000",
             @"sourceCenter": @(sourceCenter), @"outputCenter": @(outputCenter), @"contentPositionOK": @(contentOK),
             @"separateSurface": @(separateSurface), @"continuousFrames": @300,
             @"continuousProcessed": @(continuousOK), @"continuousFailed": @(continuousFailed),
             @"continuousNote": @"Synthetic component test concurrent with other activity; not a realtime performance measurement.",
             @"elapsedSec": @(latency), @"error": resultError.localizedDescription ?: @""};
}

+ (NSDictionary<NSString *, id> *)runStaticHoldContract {
    CVPixelBufferRef a=SPQualityNV12(NO,0), b=SPQualityNV12(NO,0);
    if(!a||!b){if(a)CVPixelBufferRelease(a);if(b)CVPixelBufferRelease(b);return @{ @"ok":@NO, @"error":@"allocation" };}
    int64_t started=SPHostNow(); BOOL identical=SPIdenticalSourcePixels(a,b); double compareMs=(double)SPHostToNs(SPHostNow()-started)/1e6;
    CVPixelBufferLockBaseAddress(b,0);uint8_t *uv=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(b,1);size_t stride=CVPixelBufferGetBytesPerRowOfPlane(b,1), rows=CVPixelBufferGetHeightOfPlane(b,1), cols=CVPixelBufferGetWidthOfPlane(b,1)*2;
    uv[(rows-1)*stride+cols-1]^=1;CVPixelBufferUnlockBaseAddress(b,0);
    BOOL chromaDifference=!SPIdenticalSourcePixels(a,b);
    CVPixelBufferLockBaseAddress(b,0);uv=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(b,1);uv[(rows-1)*stride+cols-1]^=1;CVPixelBufferUnlockBaseAddress(b,0);
    CVPixelBufferLockBaseAddress(b,0);uint8_t *y=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(b,0);size_t ys=CVPixelBufferGetBytesPerRowOfPlane(b,0);y[1439*ys+2559]^=1;CVPixelBufferUnlockBaseAddress(b,0);
    BOOL lumaDifference=!SPIdenticalSourcePixels(a,b);
    CVPixelBufferLockBaseAddress(b,0);y=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(b,0);y[1439*ys+2559]^=1;CVPixelBufferUnlockBaseAddress(b,0);
    NSError *error=nil;SPLowLatencyEngine *engine=[[SPLowLatencyEngine alloc] init];BOOL prepared=[engine prepareWidth:1920 height:1080 frames:1 error:&error];
    SPLiveProcessor *p=[[SPLiveProcessor alloc] init];[p adoptSourceGeneration:1];
    SPLivePlanRequest *request=[[SPLivePlanRequest alloc] init];request.interpolationEnabled=YES;request.engineID=@"apple.lowlatency";request.rateKind=SPLiveRateMultiplier;request.multiplier=2;
    request.scaleEnabled=YES;request.scaleEngine=SPLiveScaleLanczos;request.outputWidth=1920;request.outputHeight=1080;
    dispatch_sync(p->_q, ^{ p->_width=2560;p->_height=1440;p->_held[11].source=CVPixelBufferRetain(a);p->_held[11].pts=sp::spMake(0,1);p->_held[11].host=SPHostNow();
        p->_held[12].source=CVPixelBufferRetain(b);p->_held[12].pts=sp::spMake(1,60);p->_held[12].host=SPHostNow();
        if(prepared)[p installRequest:request lowLatency:engine rife:nil distil:nil appleSR:nil videoSR:nil animeSR:nil cuganSR:nil artCNNSR:nil];
        sp::SPScheduleOutput event;event.action=sp::SPScheduleAction::Interpolate;event.frameA=11;event.frameB=12;event.pts=sp::spMake(1,120);event.phase=sp::spMake(1,2);
        if(p->_sessionReady)[p submitEventGroup:{event} generation:1]; });
    __block BOOL held=NO;
    for(int i=0;i<200&&!held;i++){usleep(10000);dispatch_sync(p->_q,^{ held=p->_lastEnhanced && !p->_lastSynthetic && sp::spCmp(p->_lastRedrawPts,sp::spMake(1,120))==0 && p->_staticHoldPhases==1 && p->_submitted==0 && p->_syntheticOK==0; });}
    [p stop];CVPixelBufferRelease(a);CVPixelBufferRelease(b);
    return @{ @"ok":@(identical&&chromaDifference&&lumaDifference&&prepared&&held), @"identicalFullFrame":@(identical), @"singleChromaChangeRejected":@(chromaDifference),
        @"singleLumaChangeRejected":@(lumaDifference), @"actualProcessorHeldWithoutModel":@(held), @"comparisonMs":@(compareMs),
        @"scope":@"2K NV12 exact identity and headless production held phase; no visual or physical FPS acceptance" };
}

// Controlled synthetic component comparison. No capture, window, physical
// presentation or file provider is involved. Each result is from its named bridge.
+ (NSDictionary<NSString *, id> *)runNativeBridgeQualityProbeWithBundle:(NSBundle *)bundle {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return @{ @"ok": @NO, @"error": @"no Metal device", @"cases": @[] };
    SPLiveProcessor *converter = [[SPLiveProcessor alloc] init];
    NSMutableArray *cases = [NSMutableArray array];
    NSString *selection = NSProcessInfo.processInfo.environment[@"ODF_NATIVE_BRIDGE_ENGINE"] ?: @"all";
    NSArray<NSString *> *choices = @[@"all", @"frc-normal", @"frc-quality", @"rife", @"llfi"];
    if (![choices containsObject:selection]) return @{ @"ok":@NO, @"error":@"invalid ODF_NATIVE_BRIDGE_ENGINE", @"cases":@[] };
    BOOL allOK = YES, timedOut = NO;
    for (int style=0; style<2; ++style) for (int moving=0; moving<2; ++moving) {
        CVPixelBufferRef input=SPQualityNV12(NO,moving?8:0,style);
        CVPixelBufferRef rgba=input?[converter transfer:input format:kCVPixelFormatType_32BGRA]:NULL;
        NSDictionary *diff=rgba?SPQualityDiff(rgba,rgba):@{};
        BOOL ok=diff.count>0; allOK=allOK && ok;
        [cases addObject:@{ @"engine":@"generator-identity", @"model":@"none", @"quality":@"none", @"pattern":style?@"thin-glyph":@"3px-stripes", @"motion":moving?@"8px":@"static",
            @"inputSize":@[@2560,@1440], @"processingSize":@[@2560,@1440], @"actualOutputSize":rgba?@[@(CVPixelBufferGetWidth(rgba)),@(CVPixelBufferGetHeight(rgba))]:@[],
            @"inputPixelFormat":@"NV12 video range", @"actualOutputPixelFormat":@(rgba?CVPixelBufferGetPixelFormatType(rgba):0), @"phase":@0,
            @"requestedWarmups":@0, @"warmupsCompleted":@0, @"requestedSamples":@1, @"samples":@(ok?1:0), @"timingScope":@"not timed",
            @"processed":@(ok), @"difference":diff, @"role":@"generator identity only; not app capture/color/display baseline" }];
        if(rgba)CVPixelBufferRelease(rgba); if(input)CVPixelBufferRelease(input);
    }
    for (int kind=0; kind<4 && !timedOut; ++kind) {
        NSString *selectionKey = @[@"frc-normal", @"frc-quality", @"rife", @"llfi"][kind];
        if (![selection isEqualToString:@"all"] && ![selection isEqualToString:selectionKey]) continue;
        NSString *engineName = kind < 2 ? @"apple.frc.bridge" : (kind == 2 ? @"rife.metal.bridge" : @"apple.lowlatency.bridge");
        NSString *quality = kind == 1 ? @"quality" : (kind == 2 ? @"fast" : @"normal");
        NSString *model = kind == 0 ? @"vt.frc.normal" : (kind == 1 ? @"vt.frc.quality" : (kind == 2 ? @"rife-v4.25" : @"vt.llfi.temporal.1"));
        NSError *setupError = nil;
        SPFrameBudgetMetal *metal = nil; SPFRCEngine *frc = nil; SPRifeBridge *rife = nil; SPLowLatencyEngine *low = nil; SPSpatialScaler *down = nil;
        if (kind < 2) {
            metal = [[SPFrameBudgetMetal alloc] initWithDevice:device library:nil width:2560 height:1440 pixelFormat:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange error:&setupError];
            if (metal) frc = [[SPFRCEngine alloc] initWithMetal:metal sessions:1 outputCapacity:4 quality:kind == 1 ? SPFRCQualityHigh : SPFRCQualityNormal error:&setupError];
        } else if (kind == 2) {
            rife = [[SPRifeBridge alloc] initWithResourceBundle:bundle];
            if (![rife prepareModelID:model quality:quality width:2560 height:1440 error:&setupError]) rife = nil;
        } else {
            low = [[SPLowLatencyEngine alloc] init];
            if (![low prepareWidth:1920 height:1080 frames:1 error:&setupError]) low = nil;
            if (low) down = [[SPSpatialScaler alloc] initWithDevice:device inputW:2560 inputH:1440 outputW:1920 outputH:1080 engine:SPLiveScaleLanczos error:&setupError];
        }
        BOOL ready = kind < 2 ? frc != nil : (kind == 2 ? rife != nil : low != nil && down != nil);
        for (int style=0; style<2 && !timedOut; ++style) for (int moving=0; moving<2 && !timedOut; ++moving) {
            NSMutableDictionary *item = [@{ @"engine":engineName, @"model":model, @"quality":quality,
                @"pattern":style?@"thin-glyph":@"3px-stripes", @"motion":moving?@"8px":@"static", @"phase":@0.5,
                @"inputSize":@[@2560,@1440], @"processingSize":kind==3?@[@1920,@1080]:@[@2560,@1440],
                @"inputPixelFormat":kind==3?@"BGRA8 after Lanczos 1440-to-1080":@"NV12 video range",
                @"requestedWarmups":@1, @"requestedSamples":@3, @"warmupsCompleted":@0, @"samples":@0,
                @"timingScope":@"bridge submit through completion and waiter wake-up; includes bridge conversions, excludes setup and comparison",
                @"role":kind==3?@"1080p performance reference; not native 1440p":@"native-size bridge comparison" } mutableCopy];
            if (!ready) { item[@"failure"] = setupError.localizedDescription ?: @"bridge setup failed"; allOK=NO; [cases addObject:item]; continue; }
            CVPixelBufferRef a=SPQualityNV12(NO,0,style), b=SPQualityNV12(NO,moving?8:0,style), gt=SPQualityNV12(NO,moving?4:0,style);
            CVPixelBufferRef inputA=a, inputB=b;
            CVPixelBufferRef ref=[converter transfer:gt format:kCVPixelFormatType_32BGRA];
            CVPixelBufferRef downA=NULL, downB=NULL, downGT=NULL;
            if (kind==3 && a && b && ref) {
                CVPixelBufferRef rgbaA=[converter transfer:a format:kCVPixelFormatType_32BGRA], rgbaB=[converter transfer:b format:kCVPixelFormatType_32BGRA];
                downA=rgbaA?[down scaleBuffer:rgbaA error:&setupError]:NULL; downB=rgbaB?[down scaleBuffer:rgbaB error:&setupError]:NULL;
                downGT=[down scaleBuffer:ref error:&setupError];
                if(rgbaA)CVPixelBufferRelease(rgbaA); if(rgbaB)CVPixelBufferRelease(rgbaB);
                CVPixelBufferRelease(ref); ref=downGT?CVPixelBufferRetain(downGT):NULL; inputA=downA; inputB=downB;
            }
            if (a) { item[@"actualSourceSize"]=@[@(CVPixelBufferGetWidth(a)), @(CVPixelBufferGetHeight(a))]; item[@"actualSourcePixelFormat"]=@(CVPixelBufferGetPixelFormatType(a)); }
            if (inputA) { item[@"actualBridgeInputSize"]=@[@(CVPixelBufferGetWidth(inputA)), @(CVPixelBufferGetHeight(inputA))]; item[@"actualBridgeInputPixelFormat"]=@(CVPixelBufferGetPixelFormatType(inputA)); }
            NSMutableArray *latencies=[NSMutableArray array], *differences=[NSMutableArray array]; NSDictionary *diff=nil; int warm=0; NSString *failure=@"";
            if (!inputA || !inputB || !ref) failure=setupError.localizedDescription ?: @"input allocation or conversion failed";
            for (int n=0; n<4 && !failure.length; ++n) {
                dispatch_semaphore_t done=dispatch_semaphore_create(0);
                __block NSArray<SPOwnedPixelBuffer *> *outputs=nil; __block NSError *runError=nil;
                CVPixelBufferRetain(inputA); CVPixelBufferRetain(inputB);
                SPFRCPhasesCompletion complete = ^(uint64_t token, NSArray<SPOwnedPixelBuffer *> *frames, double elapsed, NSError *error) {
                    (void)token; (void)elapsed; outputs=frames; runError=error; CVPixelBufferRelease(inputA); CVPixelBufferRelease(inputB); dispatch_semaphore_signal(done);
                };
                int64_t started=SPHostNow();
                BOOL submitted = kind<2 ? [frc submitPhasesWithFrameA:inputA frameB:inputB ptsA:CMTimeMake(0,60) ptsB:CMTimeMake(1,60) phases:@[@0.5] sequential:NO token:n+1 completion:complete] :
                    (kind==2 ? [rife submitPrevious:inputA current:inputB timesteps:@[@0.5] token:n+1 completion:complete] :
                     [low submitPrevious:inputA current:inputB previousPTS:CMTimeMake(0,60) currentPTS:CMTimeMake(1,60) phases:@[@0.5] token:n+1 completion:complete]);
                if (!submitted) { CVPixelBufferRelease(inputA); CVPixelBufferRelease(inputB); failure=@"bridge rejected submission"; break; }
                if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30*NSEC_PER_SEC)) != 0) { failure=@"bridge completion timeout (30s); remaining cases skipped"; timedOut=YES; break; }
                double ms=(double)SPHostToNs(SPHostNow()-started)/1e6;
                CVPixelBufferRef raw=outputs.count ? outputs[0].buffer : NULL;
                if (runError || !raw) { failure=runError.localizedDescription ?: @"no output"; break; }
                item[@"actualOutputSize"]=@[@(CVPixelBufferGetWidth(raw)),@(CVPixelBufferGetHeight(raw))];
                item[@"actualOutputPixelFormat"]=@(CVPixelBufferGetPixelFormatType(raw));
                int expectedW=kind==3?1920:2560, expectedH=kind==3?1080:1440;
                if (CVPixelBufferGetWidth(raw)!=expectedW || CVPixelBufferGetHeight(raw)!=expectedH) { failure=@"output dimensions differ from requested processing size"; break; }
                if(n==0) { warm++; continue; }
                CVPixelBufferRef output=[converter transfer:raw format:kCVPixelFormatType_32BGRA];
                if (!output) { failure=@"output BGRA comparison conversion failed"; break; }
                diff=SPQualityDiff(ref,output); CVPixelBufferRelease(output);
                if (!diff.count) { failure=@"comparison failed"; break; }
                [latencies addObject:@(ms)]; [differences addObject:diff];
            }
            item[@"warmupsCompleted"]=@(warm); item[@"samples"]=@(latencies.count); item[@"latencyMs"]=latencies;
            if(diff) item[@"phaseVsSyntheticMidpointSamples"]=differences;
            if(failure.length) item[@"failure"]=failure;
            item[@"processed"]=@(warm==1 && latencies.count==3 && !failure.length);
            if(![item[@"processed"] boolValue]) allOK=NO;
            [cases addObject:item];
            for(CVPixelBufferRef f : {a,b,gt,ref,downA,downB,downGT}) if(f)CVPixelBufferRelease(f);
        }
        [frc invalidate]; [rife invalidate]; [low invalidate];
    }
    [converter stop];
    return @{ @"ok":@(allOK && !timedOut), @"cases":cases, @"timedOut":@(timedOut), @"selection":selection,
        @"scope":@"synthetic 2560x1440 NV12 patterns through application FRC/RIFE bridges and downscaled 1080p LLFI reference; no capture, file provider, drawable, physical playback, subjective acceptance, or sustained FPS" };
}

+ (NSDictionary<NSString *, id> *)runLiveQualityProbe {
    id<MTLDevice> device=MTLCreateSystemDefaultDevice(); NSError *error=nil;
    SPSpatialScaler *down=[[SPSpatialScaler alloc] initWithDevice:device inputW:2560 inputH:1440 outputW:1920 outputH:1080 engine:SPLiveScaleLanczos error:&error];
    SPSpatialScaler *up=[[SPSpatialScaler alloc] initWithDevice:device inputW:1920 inputH:1080 outputW:2560 outputH:1440 engine:SPLiveScaleLanczos error:&error];
    if(!down||!up)return @{ @"ok":@NO, @"error":error.localizedDescription ?: @"scaler" };
    SPLiveProcessor *p=[[SPLiveProcessor alloc] init]; NSMutableArray *cases=[NSMutableArray array]; BOOL ok=YES;
    for(int style=0;style<2;style++) for(int full=0;full<2;full++) for(int moving=0;moving<2;moving++) {
        if(style && full) continue;
        CVPixelBufferRef inputA=SPQualityNV12(full,0,style), inputB=SPQualityNV12(full,moving?8:0,style), inputGT=SPQualityNV12(full,moving?4:0,style);
        CVPixelBufferRef largeA=[p transfer:inputA format:kCVPixelFormatType_32BGRA], largeB=[p transfer:inputB format:kCVPixelFormatType_32BGRA], largeGT=[p transfer:inputGT format:kCVPixelFormatType_32BGRA];
        CVPixelBufferRef smallA=[down scaleBuffer:largeA error:&error], smallB=[down scaleBuffer:largeB error:&error], smallGT=[down scaleBuffer:largeGT error:&error];
        CVPixelBufferRef roundtrip=[up scaleBuffer:smallA error:&error];
        SPLowLatencyEngine *engine=[[SPLowLatencyEngine alloc] init]; BOOL ready=[engine prepareWidth:1920 height:1080 frames:1 error:&error];
        dispatch_semaphore_t done=dispatch_semaphore_create(0); __block CVPixelBufferRef raw=NULL; __block NSString *failure=@"";
        BOOL submitted=ready && smallA && smallB && [engine submitPrevious:smallA current:smallB previousPTS:CMTimeMake(0,60) currentPTS:CMTimeMake(1,60) phases:@[@0.5f] token:1 completion:^(uint64_t token, NSArray<SPOwnedPixelBuffer *> *outputs, double latency, NSError *err) {
            (void)token;(void)latency; if(outputs.count)raw=CVPixelBufferRetain(outputs[0].buffer);failure=err.localizedDescription ?: @"";dispatch_semaphore_signal(done);
        }];
        if(submitted)dispatch_semaphore_wait(done,DISPATCH_TIME_FOREVER);
        CVPixelBufferRef output=[p transfer:raw format:kCVPixelFormatType_32BGRA];
        NSDictionary *spatial=SPQualityDiff(largeA,roundtrip), *motion=SPQualityDiff(smallGT,output);
        BOOL valid=output && spatial.count>0 && motion.count>0 && failure.length==0;
        ok=ok&&valid;
        [cases addObject:@{ @"range":full?@"full":@"video", @"pattern":style?@"thin-glyph-like":@"3px-stripes", @"motion":moving?@"8px":@"static", @"processed":@(valid),
            @"sourceFormat":full?@"NV12-full":@"NV12-video", @"sourceTo1080To2k":spatial, @"phaseOutputVs1080Midpoint":motion,
            @"llOutputFormat":@(raw?CVPixelBufferGetPixelFormatType(raw):0), @"error":failure }];
        [engine invalidate];
        for(CVPixelBufferRef f : {inputA,inputB,inputGT,largeA,largeB,largeGT,smallA,smallB,smallGT,roundtrip,raw,output}) if(f)CVPixelBufferRelease(f);
    }
    __block SPLivePreviewView *preview=nil;
    dispatch_sync(dispatch_get_main_queue(), ^{ preview=[[SPLivePreviewView alloc] initWithFrame:NSMakeRect(0,0,64,32)]; });
    NSDictionary *resources=[preview runOffscreenDrawAndLifetimeProbe];
    NSError *frcError=nil;
    SPFrameBudgetMetal *metal=[[SPFrameBudgetMetal alloc] initWithDevice:device library:nil width:2560 height:1440 pixelFormat:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange error:&frcError];
    SPFRCEngine *frc=metal?[[SPFRCEngine alloc] initWithMetal:metal sessions:1 outputCapacity:4 quality:SPFRCQualityNormal error:&frcError]:nil;
    NSMutableArray *nativeFRC=[NSMutableArray array];
    if(frc) for(int moving=0;moving<2;moving++) {
        CVPixelBufferRef a=SPQualityNV12(NO,0,YES), b=SPQualityNV12(NO,moving?8:0,YES), gt=SPQualityNV12(NO,moving?4:0,YES);
        dispatch_semaphore_t done=dispatch_semaphore_create(0); __block CVPixelBufferRef raw=NULL; __block NSString *failure=@"";
        BOOL submitted=[frc submitPhasesWithFrameA:a frameB:b ptsA:CMTimeMake(0,60) ptsB:CMTimeMake(1,60) phases:@[@0.5f] sequential:NO token:1 completion:^(uint64_t token, NSArray<SPOwnedPixelBuffer *> *outputs, double latency, NSError *err) {
            (void)token;(void)latency;if(outputs.count)raw=CVPixelBufferRetain(outputs[0].buffer);failure=err.localizedDescription ?: @"";dispatch_semaphore_signal(done);
        }];
        if(submitted)dispatch_semaphore_wait(done,DISPATCH_TIME_FOREVER);
        CVPixelBufferRef ref=[p transfer:gt format:kCVPixelFormatType_32BGRA], output=[p transfer:raw format:kCVPixelFormatType_32BGRA];
        [nativeFRC addObject:@{ @"motion":moving?@"8px":@"static", @"processed":@(output!=NULL), @"sourceSize":@[@2560,@1440],
            @"phaseOutputVsNativeMidpoint":SPQualityDiff(ref,output), @"error":failure }];
        for(CVPixelBufferRef f : {a,b,gt,raw,ref,output})if(f)CVPixelBufferRelease(f);
    }
    [frc invalidate];
    [p stop]; return @{ @"ok":@(ok && [resources[@"ok"] boolValue]), @"cases":cases, @"renderResources":resources,
        @"nativeFRC":nativeFRC, @"nativeFRCPrepareError":frcError.localizedDescription ?: @"",
        @"scope":@"synthetic 709 NV12 source, actual 2K→1080 Lanczos→VT low latency; sampled pixels and fixed synthetic midpoint, no real content or visible playback" };
}

+ (NSDictionary<NSString *, id> *)runLiveSwitchContract {
    SPLiveProcessor *p=[[SPLiveProcessor alloc] init]; [p adoptSourceGeneration:1];
    __block NSMutableArray *events=[NSMutableArray array];
    p.planHandler=^(NSInteger state, NSString *engine, NSString *model, NSString *reason, uint64_t requestID) {
        [events addObject:@{ @"state":@(state), @"engine":engine, @"model":model, @"reason":reason, @"id":@(requestID) }];
    };
    dispatch_sync(p->_q, ^{ p->_width=640; p->_height=360; });
    SPLivePlanRequest *rife=[[SPLivePlanRequest alloc] init]; rife.requestID=100; rife.interpolationEnabled=YES;
    rife.engineID=@"rife.metal"; rife.modelID=@"rife-v4.26"; rife.qualityID=@"fast"; rife.rateKind=SPLiveRateMultiplier; rife.multiplier=2;
    rife.rifeStreamEnabled=YES;
    [p updateRequest:rife]; __block BOOL initial=NO, requestApplied=NO;
    for(int i=0;i<400&&!initial;i++) { usleep(10000); dispatch_sync(p->_q, ^{ initial=p->_resolved.committed && p->_rife!=nil && [p->_resolved.engineID isEqualToString:@"rife.metal"]; }); }
    dispatch_sync(p->_q, ^{
        NSDictionary *diag=[p->_rife streamDiagnostics];
        requestApplied=p->_request.rifeStreamEnabled && [diag[@"requested"] boolValue] && [diag[@"effective"] boolValue] && [diag[@"enableSource"] isEqualToString:@"request"];
    });
    SPLivePlanRequest *ll=[[SPLivePlanRequest alloc] init]; ll.requestID=102; ll.interpolationEnabled=YES;
    ll.engineID=@"apple.lowlatency"; ll.modelID=@"vt.llfi.temporal.1"; ll.rateKind=SPLiveRateMultiplier; ll.multiplier=2;
    SPLivePlanRequest *bad=[ll copy]; bad.requestID=101; bad.multiplier=3; [p updateRequest:bad];
    dispatch_sync(p->_q,^{}); __block BOOL rejectedRetains=NO;
    dispatch_sync(p->_q, ^{ rejectedRetains=p->_rife!=nil && p->_resolved.committed && [p->_resolved.engineID isEqualToString:@"rife.metal"] && p->_resolved.unavailableReason.length>0; });
    [p updateRequest:ll]; __block BOOL actualLL=NO;
    for(int i=0;i<400&&!actualLL;i++) { usleep(10000); dispatch_sync(p->_q, ^{ actualLL=p->_resolved.committed && p->_lowLatency!=nil && [p->_resolved.engineID isEqualToString:@"apple.lowlatency"]; }); }
    SPLivePlanRequest *old=[ll copy]; old.requestID=103; SPLivePlanRequest *newer=[ll copy]; newer.requestID=104;
    newer.engineID=@"apple.frc"; newer.modelID=@"vt.frc.normal";
    [p updateRequest:old]; [p updateRequest:newer];
    __block BOOL latestFRC=NO;
    for(int i=0;i<400&&!latestFRC;i++) { usleep(10000); dispatch_sync(p->_q, ^{ latestFRC=p->_resolved.committed && p->_engine!=nil && [p->_resolved.engineID isEqualToString:@"apple.frc"]; }); }
    usleep(100000); __block NSArray *captured;
    dispatch_sync(dispatch_get_main_queue(), ^{ captured=[events copy]; });
    BOOL llAck=NO, rejectAck=NO, latestAck=NO, lateOldCommit=NO;
    for(NSDictionary *item in captured) { uint64_t id=[item[@"id"] unsignedLongLongValue]; NSInteger state=[item[@"state"] integerValue];
        if(id==102 && state==2 && [item[@"engine"] isEqual:@"apple.lowlatency"]) llAck=YES;
        if(id==101 && state==0 && [item[@"engine"] isEqual:@"apple.lowlatency"] && [item[@"reason"] length]>0) rejectAck=YES;
        if(id==104 && state==2 && [item[@"engine"] isEqual:@"apple.frc"]) latestAck=YES;
        if(id==103 && state==2) lateOldCommit=YES;
    }
    [p stop]; BOOL ok=initial && requestApplied && actualLL && rejectedRetains && latestFRC && llAck && rejectAck && latestAck && !lateOldCommit;
    return @{ @"ok":@(ok), @"initialRIFE426":@(initial), @"rifeRequestApplied":@(requestApplied), @"realLLActivated":@(actualLL), @"failureRetainedRIFE":@(rejectedRetains),
        @"newerFRCActive":@(latestFRC), @"correctLLAck":@(llAck), @"correctRejectedAck":@(rejectAck),
        @"correctNewerAck":@(latestAck), @"oldPrepareCommitted":@(lateOldCommit), @"events":captured ?: @[],
        @"scope":@"real processor update/prepare/commit and rejection; no picker, native UI or physical presentation" };
}

+ (NSDictionary<NSString *, id> *)runLowLatencyPrescaleSmoke {
    const int width=2560,height=1440,count=90;
    CVPixelBufferRef frames[4]={};
    for(int i=0;i<4;i++) {
        frames[i]=SPCreateBuffer(width,height,kCVPixelFormatType_32BGRA);
        if(!frames[i]) { for(auto f:frames)if(f)CVPixelBufferRelease(f); return @{ @"ok":@NO, @"error":@"source allocation" }; }
        CVPixelBufferLockBaseAddress(frames[i],0); uint8_t *base=(uint8_t *)CVPixelBufferGetBaseAddress(frames[i]); size_t stride=CVPixelBufferGetBytesPerRow(frames[i]);
        for(int y=0;y<height;y++) for(int x=0;x<width;x++) { uint8_t *px=base+y*stride+x*4; BOOL mark=x>=800+i*4&&x<1040+i*4&&y>=480&&y<720; px[0]=px[1]=px[2]=mark?200:40+i*10;px[3]=255; }
        CVPixelBufferUnlockBaseAddress(frames[i],0); SPForceSDRAttachments(frames[i]);
    }
    VTPixelTransferSessionRef inputTransfer=NULL; VTPixelTransferSessionCreate(kCFAllocatorDefault,&inputTransfer);
    for(int i=0;i<4;i++) {
        CVPixelBufferRef nv=SPCreateBuffer(width,height,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
        if(!nv || !inputTransfer || VTPixelTransferSessionTransferImage(inputTransfer,frames[i],nv)!=noErr) {
            if(nv)CVPixelBufferRelease(nv); if(inputTransfer)CFRelease(inputTransfer);
            for(auto f:frames)if(f)CVPixelBufferRelease(f); return @{ @"ok":@NO, @"error":@"NV12 conversion" };
        }
        SPForceSDRAttachments(nv); CVPixelBufferRelease(frames[i]); frames[i]=nv;
    }
    if(inputTransfer)CFRelease(inputTransfer);
    SPLiveProcessor *p=[[SPLiveProcessor alloc] init]; [p adoptSourceGeneration:1];
    CVPixelBufferRef sampleFrame=frames[0];
    BOOL forceRealtime=getenv("ODF_TEST_KEEP_LOW_REALTIME")!=NULL;
    dispatch_sync(p->_q, ^{ p->_width=width; p->_height=height; p->_testCapturePlayout=YES; p->_testKeepLowRealtime=forceRealtime;
        p->_held[999].source=CVPixelBufferRetain(sampleFrame); p->_held[999].pts=sp::spMake(0,1); });
    SPLivePlanRequest *request=[[SPLivePlanRequest alloc] init]; request.requestID=501; request.interpolationEnabled=YES;
    request.engineID=@"apple.lowlatency"; request.modelID=@"vt.llfi.temporal.1"; request.rateKind=SPLiveRateMultiplier;
    request.multiplier=2; request.scaleEnabled=YES; request.scaleEngine=SPLiveScaleLanczos;
    request.outputWidth=1920; request.outputHeight=1080; request.viewMode=SPLiveViewCompare;
    request.captureCapFPS=60; request.displayRefreshHz=120; [p updateRequest:request];
    __block BOOL prepared=NO;
    for(int i=0;i<600&&!prepared;i++) { usleep(10000); dispatch_sync(p->_q, ^{ prepared=p->_sessionReady && p->_lowLatency.width==1920 && p->_lowLatency.height==1080 && p->_resolved.committed; }); }
    if(!prepared) { NSString *reason=p.resolvedPlan.unavailableReason ?: @"prepare timeout"; [p stop]; for(auto f:frames)CVPixelBufferRelease(f); return @{ @"ok":@NO, @"prepared":@NO, @"error":reason }; }
    int64_t start=SPHostNow(),last=start;
    for(int i=0;i<count;i++) { SPWaitUntilHost(start+SPRationalToHost(sp::spMake(i,60))); last=SPHostNow(); [p pushPixelBuffer:frames[i%4] ptsNum:i ptsDen:60 host:last generation:1]; }
    double sourceHz=(count-1)*1e9/(double)SPHostToNs(last-start);
    usleep(700000); __block BOOL sizeOK=NO,ordered=YES,grid=YES,baseline=NO; __block int src=0,syn=0,stableSrc=0,stableSyn=0;
    __block NSDictionary *stats; __block NSArray *pendingTrace; __block NSArray *missingTicks;
    dispatch_sync(p->_q, ^{ const auto &v=p->_testPlayout; for(size_t i=0;i<v.size();i++) { if(v[i].second)syn++;else src++; if(i&&sp::spCmp(v[i-1].first,v[i].first)>=0)ordered=NO;
        __int128 ticks=(__int128)v[i].first.num*120; int64_t den=v[i].first.den; if(den<=0 || ticks%den!=0 || ((ticks/den)&1)!=(v[i].second?1:0))grid=NO; }
        bool present[120]={};
        for(const auto &item:v) { __int128 ticks=(__int128)item.first.num*120; if(item.first.den<=0 || ticks%item.first.den) continue;
            int tick=(int)(ticks/item.first.den); if(tick>=36&&tick<156) { present[tick-36]=true; if(item.second)stableSyn++;else stableSrc++; } }
        NSMutableArray *missing=[NSMutableArray array]; for(int j=0;j<120;j++) if(!present[j]) [missing addObject:@(j+36)]; missingTicks=[missing copy];
        sizeOK=p->_lastEnhanced && CVPixelBufferGetWidth(p->_lastEnhanced)==1920 && CVPixelBufferGetHeight(p->_lastEnhanced)==1080;
        baseline=p->_lastOriginal && CVPixelBufferGetWidth(p->_lastOriginal)==1920 && CVPixelBufferGetHeight(p->_lastOriginal)==1080;
        stats=[p currentStats]; pendingTrace=[p->_testPendingTrace copy] ?: @[]; });
    SPLivePlanRequest *bad=[request copy]; bad.requestID=502; bad.outputWidth=1918; [p updateRequest:bad];
    __block BOOL rejectedRetained=NO;
    for(int i=0;i<600&&!rejectedRetained;i++) { usleep(10000); dispatch_sync(p->_q, ^{ rejectedRetained=p->_resolved.unavailableReason.length>0 && p->_resolved.committed && p->_lowLatency.width==1920; }); }
    __block uint64_t baselineMatches=0, baselineMismatches=0, prescaledInputs=0, noRescale=0;
    dispatch_sync(p->_q, ^{ baselineMatches=p->_testBaselineMatches; baselineMismatches=p->_testBaselineMismatches;
        prescaledInputs=p->_lowPrescaleInputs; noRescale=p->_lowSyntheticNoRescale; });
    [p adoptSourceGeneration:2]; __block BOOL generationClear=NO, staleRejected=NO;
    dispatch_sync(p->_q, ^{ generationClear=p->_sourceGeneration==2 && !p->_lastEnhanced && p->_held.empty();
        SPLiveJob *stale=new SPLiveJob(); stale->generation=1; stale->configVersion=p->_configVersion; stale->count=1; stale->pts[0]=sp::spMake(1,120);
        SPOwnedPixelBuffer *box=[[SPOwnedPixelBuffer alloc] initWithBufferNoCopy:CVPixelBufferRetain(sampleFrame)];
        [p finishJob:stale token:0 outputs:@[box] latency:0 error:nil]; staleRejected=!p->_lastEnhanced && p->_held.empty(); });
    [p stop]; __block BOOL stoppedClean=NO; dispatch_sync(p->_q, ^{ stoppedClean=p->_stopped && !p->_lowLatency && p->_held.empty(); });
    for(auto f:frames)CVPixelBufferRelease(f);
    BOOL ok=prepared && sizeOK && baseline && ordered && grid && src>0 && syn>0 && rejectedRetained && generationClear && staleRejected && stoppedClean && baselineMatches>0 && baselineMismatches==0 && prescaledInputs>0 && noRescale>0;
    return @{ @"ok":@(ok), @"prepared":@(prepared), @"sourceSize":@[@2560,@1440], @"sourceFormat":@"NV12 video-range", @"processingSize":@[@1920,@1080],
        @"outputSizeCorrect":@(sizeOK), @"baselineSizeCorrect":@(baseline), @"playoutSources":@(src), @"playoutSynthetic":@(syn),
        @"ptsOrdered":@(ordered), @"ptsOn120Grid":@(grid), @"inputCount":@(count), @"invalidAspectRetainsPlan":@(rejectedRetained), @"sourceGenerationClears":@(generationClear), @"oldGenerationRejected":@(staleRejected), @"stopReleasesEngineAndFrames":@(stoppedClean),
        @"sourceABaselineMatches":@(baselineMatches), @"sourceABaselineMismatches":@(baselineMismatches), @"prescaledInputs":@(prescaledInputs), @"syntheticNoRescale":@(noRescale),
        @"stableIntervalPTS":@"[0.3,1.3)", @"stableSource":@(stableSrc), @"stableSynthetic":@(stableSyn), @"stableExpectedEach":@60, @"stableMissing120Ticks":missingTicks ?: @[],
        @"inputHzObserved":@(sourceHz), @"forcedOriginalRealtimePolicy":@(forceRealtime), @"pendingTrace":pendingTrace,
        @"submitted":stats[@"submitted"] ?: @0, @"modelOutputs":stats[@"syntheticOK"] ?: @0,
        @"queueDrops":stats[@"queueDrops"] ?: @0, @"deadlineDrops":stats[@"deadlineDrops"] ?: @0,
        @"slowMode":stats[@"lowPrescaleSlowMode"] ?: @NO, @"delayClamped":stats[@"delayClamped"] ?: @NO,
        @"frcP95ms":stats[@"frcP95ms"] ?: @0, @"scaleP95ms":stats[@"scaleP95ms"] ?: @0,
        @"transferP95ms":stats[@"transferP95ms"] ?: @0, @"modelReadyP95ms":stats[@"captureToModelReadyP95ms"] ?: @0,
        @"readyP95ms":stats[@"captureToOutputReadyP95ms"] ?: @0,
        @"pendingExpired":stats[@"pendingExpiredDrops"] ?: @0, @"lateReady":stats[@"lateReadyDrops"] ?: @0,
        @"processingOrder":stats[@"lowLatencyProcessingOrder"] ?: @"", @"scope":@"real 2560x1440 controlled source, Lanczos to 1920x1080 then VT low latency; no window or physical FPS" };
}

+ (NSDictionary<NSString *, id> *)runLowLatency120Smoke {
    NSError *error=nil;
    SPLowLatencyEngine *engine=[[SPLowLatencyEngine alloc] init];
    BOOL prepared=[engine prepareWidth:640 height:360 frames:1 error:&error];
    if (!prepared) return @{ @"ok":@NO, @"prepared":@NO, @"error":error.localizedDescription ?: @"low latency unavailable" };
    SPLiveProcessor *p=[[SPLiveProcessor alloc] init]; [p adoptSourceGeneration:1];
    SPLivePlanRequest *request=[[SPLivePlanRequest alloc] init];
    request.interpolationEnabled=YES; request.engineID=@"apple.lowlatency"; request.rateKind=SPLiveRateMultiplier;
    request.multiplier=2; request.captureCapFPS=60; request.displayRefreshHz=120;
    dispatch_sync(p->_q, ^{ p->_width=640; p->_height=360; p->_testCapturePlayout=YES;
        [p installRequest:request lowLatency:engine rife:nil distil:nil appleSR:nil videoSR:nil animeSR:nil cuganSR:nil artCNNSR:nil]; });
    __block BOOL installed=NO; dispatch_sync(p->_q, ^{ installed=p->_sessionReady && p->_resolved.interpolationActive; });
    if (!installed) { [p stop]; return @{ @"ok":@NO, @"prepared":@YES, @"installed":@NO, @"error":p.resolvedPlan.unavailableReason ?: @"install" }; }
    CVPixelBufferRef frames[4]={};
    for (int i=0;i<4;i++) {
        frames[i]=SPCreateBuffer(640,360,kCVPixelFormatType_32BGRA);
        if (!frames[i]) { for (auto f:frames) if(f)CVPixelBufferRelease(f); [p stop]; return @{ @"ok":@NO, @"error":@"frame allocation" }; }
        CVPixelBufferLockBaseAddress(frames[i],0);
        uint8_t *base=(uint8_t *)CVPixelBufferGetBaseAddress(frames[i]); size_t stride=CVPixelBufferGetBytesPerRow(frames[i]);
        for(int y=0;y<360;y++) for(int x=0;x<640;x++) { uint8_t *px=base+y*stride+x*4; BOOL mark=x>=200+i*2&&x<260+i*2&&y>=120&&y<180; px[0]=px[1]=px[2]=mark?200:40;px[3]=255; }
        CVPixelBufferUnlockBaseAddress(frames[i],0); SPForceSDRAttachments(frames[i]);
    }
    const int count=90; int64_t start=SPHostNow();
    for(int i=0;i<count;i++) {
        SPWaitUntilHost(start+SPRationalToHost(sp::spMake(i,60)));
        [p pushPixelBuffer:frames[i%4] ptsNum:i ptsDen:60 host:SPHostNow() generation:1];
    }
    int64_t end=SPHostNow(); usleep(400000);
    __block NSMutableDictionary *report=[NSMutableDictionary dictionary];
    dispatch_sync(p->_q, ^{
        const auto &v=p->_testPlayout; int source=0,synth=0; BOOL valid=YES,ordered=YES;
        for(size_t i=0;i<v.size();i++) { __int128 ticks=(__int128)v[i].first.num*120; int64_t den=v[i].first.den;
            if(den<=0 || ticks%den!=0 || ((ticks/den)&1)!=(v[i].second?1:0)) valid=NO;
            if(i && sp::spCmp(v[i-1].first,v[i].first)>=0)ordered=NO;
            if(v[i].second)synth++; else source++; }
        NSDictionary *stats=[p currentStats];
        [report addEntriesFromDictionary:@{ @"ok":@(p->_submitted>0 && p->_syntheticOK>0 && synth>0 && valid && ordered),
            @"prepared":@YES, @"installed":@YES, @"inputCount":@(count), @"inputHzObserved":@((count-1)*1e9/(double)SPHostToNs(end-start)),
            @"scheduledPhases":@(p->_scheduledSynthetic), @"submittedPairs":@(p->_submitted), @"actualModelOutputs":@(p->_syntheticOK),
            @"modelFailures":@(p->_syntheticFail), @"deadlineDrops":@(p->_deadlineDrops), @"queueDrops":@(p->_queueDrops),
            @"playoutSources":@(source), @"playoutSynthetic":@(synth), @"ptsOn120Grid":@(valid), @"ptsOrdered":@(ordered),
            @"frcP95ms":stats[@"frcP95ms"], @"frcEwmaMs":stats[@"frcEwmaMs"], @"delayMs":stats[@"delayMs"],
            @"delayClamped":stats[@"delayClamped"], @"peakSlots":stats[@"peakSlots"], @"slotCap":stats[@"slotCap"],
            @"scope":@"real low-latency VT engine and live production queue, controlled 640x360 60fps input; no window, drawable or physical FPS" }];
    });
    for(auto f:frames) CVPixelBufferRelease(f); [p stop]; return report;
}

// Deterministic clock inputs, real scheduler and production event handlers;
// no model is submitted here. The existing output-repair smoke remains real.
+ (NSDictionary<NSString *, id> *)runFixedRateContract {
    SPLiveProcessor *p=[[SPLiveProcessor alloc] init];
    CVPixelBufferRef buffer=SPCreateBuffer(32,32,kCVPixelFormatType_32BGRA);
    __block BOOL originalClock=NO, originalCounted=NO, standby=NO, lateKeepsStandby=NO,
        replaces=NO, overloadFallback=NO, lateCannotReturn=NO, sourceContinues=NO;
    if (buffer) dispatch_sync(p->_q, ^{
        p->_request.interpolationEnabled=YES;p->_request.engineID=@"rife.metal";
        p->_request.rateKind=SPLiveRateFixedFPS;p->_request.fpsNumerator=60;p->_request.fpsDenominator=1;
        p->_testCapturePlayout=YES;
        const int64_t base=SPHostNow()+SPRationalToHost(sp::spMake(2,1));
        p->_held[11].source=CVPixelBufferRetain(buffer);p->_held[11].pts=sp::spMake(0,1);p->_held[11].host=base;
        p->_held[12].source=CVPixelBufferRetain(buffer);p->_held[12].pts=sp::spMake(103,3000);
        p->_held[12].host=base+SPRationalToHost(p->_held[12].pts);
        [p observeSourceIdentity:11];[p observeSourceIdentity:12];
        [p enqueueSourceIdentity:12 pts:sp::spMake(1,30) host:p->_held[12].host generation:p->_sourceGeneration force:NO retimed:YES];
        originalClock=sp::spCmp(p->_previousSourcePts,p->_held[12].pts)==0;
        originalCounted=p->_slots.size()==1 && !p->_marks[p->_slots[0].frameID].held;
        [p clearPlaySlots];p->_marks.clear();
        sp::SPScheduleOutput event;event.action=sp::SPScheduleAction::Interpolate;
        event.frameA=11;event.frameB=12;event.pts=sp::spMake(1,60);event.phase=sp::spMake(50,103);
        [p enqueueFixedFallbacks:{event} generation:p->_sourceGeneration];
        standby=p->_slots.size()==1 && p->_slots[0].fixedFallback && p->_marks[p->_slots[0].frameID].held;
        [p enqueueReadyEnhanced:CVPixelBufferRetain(buffer) original:nil pts:event.pts synthetic:YES held:NO captureHost:base
                    generation:p->_sourceGeneration deadlineHost:SPHostNow()-SPRationalToHost(sp::spMake(1,100))];
        lateKeepsStandby=p->_lateReadyDrops==1 && p->_slots.size()==1 && p->_slots[0].fixedFallback;
        [p enqueueReadyEnhanced:CVPixelBufferRetain(buffer) original:nil pts:event.pts synthetic:YES held:NO captureHost:base
                    generation:p->_sourceGeneration deadlineHost:base+SPRationalToHost(sp::spMake(1,10))];
        replaces=p->_slots.size()==1 && p->_slots[0].synthetic && !p->_slots[0].fixedFallback && p->_fixedFallbackReplaced==1 && p->_marks.size()==1;
        [p clearPlaySlots];p->_marks.clear();p->_claimedDrops.clear();
        [p enqueueFixedFallbacks:{event} generation:p->_sourceGeneration];
        SPPendingPhase pending;pending.pts=event.pts;pending.generation=p->_sourceGeneration;
        pending.targetHost=SPHostNow()-SPRationalToHost(sp::spMake(1,1000));p->_pending.push_back(pending);
        p->_slots[0].targetHost=pending.targetHost;
        [p drainDue];
        overloadFallback=p->_testPlayout.size()==1 && !p->_testPlayout[0].second &&
            p->_fixedFallbackPresented==1 && p->_pending.empty() && p->_pendingExpiredDrops==1;
        [p enqueueReadyEnhanced:CVPixelBufferRetain(buffer) original:nil pts:event.pts synthetic:YES held:NO captureHost:base
                    generation:p->_sourceGeneration deadlineHost:base];
        lateCannotReturn=p->_slots.empty() && p->_testPlayout.size()==1;
        [p enqueueSourceIdentity:12 pts:sp::spMake(1,30) host:p->_held[12].host generation:p->_sourceGeneration force:NO retimed:YES];
        if (!p->_slots.empty()) { p->_slots[0].targetHost=SPHostNow();[p drainDue]; }
        sourceContinues=p->_testPlayout.size()==2 && !p->_testPlayout.back().second &&
            sp::spCmp(p->_testPlayout.back().first,sp::spMake(1,30))==0;
    });
    [p stop];if(buffer)CVPixelBufferRelease(buffer);
    const BOOL ok=originalClock&&originalCounted&&standby&&lateKeepsStandby&&replaces&&overloadFallback&&lateCannotReturn&&sourceContinues;
    return @{ @"ok":@(ok), @"retimedSourceKeepsCaptureClock":@(originalClock), @"retimedOriginalCountsAsSource":@(originalCounted),
        @"standbyCountsAsHold":@(standby), @"lateModelKeepsStandby":@(lateKeepsStandby), @"onTimeModelReplacesStandby":@(replaces),
        @"overloadShowsOriginal":@(overloadFallback), @"lateModelCannotResurrect":@(lateCannotReturn), @"nextSourceContinues":@(sourceContinues) };
}

+ (NSDictionary<NSString *, id> *)runSourceClockSchedulingContract {
    NSMutableArray *rates=[NSMutableArray array]; BOOL allRates=YES;
    for (int multiplier=2; multiplier<=4; ++multiplier) {
        SPLiveProcessor *p=[[SPLiveProcessor alloc] init];
        __block BOOL ordered=NO, phasePTS=NO, updateOnce=NO, beforeWasLate=NO, afterUsesB=NO, duplicateIgnored=NO;
        __block double oldFromB=0, newFromB=0, delayMs=0; __block int phaseCount=0, sourceClockCount=0;
        dispatch_sync(p->_q, ^{
            p->_request.interpolationEnabled=YES; p->_request.engineID=@"apple.frc";
            p->_request.rateKind=SPLiveRateMultiplier; p->_request.multiplier=multiplier;
            p->_testCapturePlayout=YES; [p resetSchedulerOnQueue];
            int64_t aHost=SPHostNow()+SPRationalToHost(sp::spMake(2,1));
            int64_t bHost=aHost+SPRationalToHost(sp::spMake(300,1000));
            p->_held[11].pts=sp::spMake(0,1); p->_held[11].host=aHost;
            p->_held[12].pts=sp::spMake(1,30); p->_held[12].host=bHost;
            sp::SPScheduleInput a; a.identity=11; a.pts=p->_held[11].pts; a.generation=p->_configVersion;
            auto ar=p->_scheduler.push(a); if(ar.reject==sp::SPScheduleReject::None){[p handleAcceptedInput:11 events:ar.events generation:p->_sourceGeneration];}
            sp::SPScheduleInput b; b.identity=12; b.pts=p->_held[12].pts; b.generation=p->_configVersion;
            auto br=p->_scheduler.push(b);
            if(br.reject==sp::SPScheduleReject::None){[p handleAcceptedInput:12 events:br.events generation:p->_sourceGeneration];}
            ordered=ar.reject==sp::SPScheduleReject::None && br.reject==sp::SPScheduleReject::None;
            phasePTS=YES;
            for(const auto &e:br.events) if(e.action==sp::SPScheduleAction::Interpolate) {
                ++phaseCount; sp::SPRational expected=sp::spMake(phaseCount,30*multiplier);
                if(sp::spCmp(e.pts,expected)!=0 || sp::spCmp(e.phase,sp::spMake(phaseCount,multiplier))!=0)phasePTS=NO;
            }
            phasePTS=phasePTS && phaseCount==multiplier-1;
            NSArray *trace=p->_testTimingTrace ?: @[]; NSUInteger traceCount=trace.count; NSDictionary *plan=nil;
            for(NSDictionary *entry in trace){if([entry[@"kind"] isEqual:@"sourceClock"])sourceClockCount++; if([entry[@"kind"] isEqual:@"phasePlan"])plan=entry;}
            double stepMs=1000.0/(30.0*multiplier); delayMs=[plan[@"delayMs"] doubleValue];
            oldFromB=(double)SPHostToNs(aHost+SPRationalToHost(sp::spMake(1,30*multiplier))+p->_delayHost-bHost)/1e6;
            newFromB=[plan[@"deadlineFromSourceMs"] doubleValue];
            beforeWasLate=oldFromB<0; afterUsesB=plan && [plan[@"anchorPtsNum"] longLongValue]==1 && [plan[@"anchorPtsDen"] longLongValue]==30 &&
                fabs(newFromB-(delayMs-(1000.0/30.0-stepMs)))<0.1;
            updateOnce=sourceClockCount==2 && p->_havePreviousSourcePts && sp::spCmp(p->_previousSourcePts,sp::spMake(1,30))==0 &&
                llabs(SPHostToNs(p->_intervalHost)-33333333LL)<1000;
            auto duplicate=p->_scheduler.push(b); [p observeSourceIdentity:12];
            duplicateIgnored=duplicate.reject==sp::SPScheduleReject::DuplicatePTS && p->_testTimingTrace.count==traceCount;
        });
        BOOL ok=ordered&&phasePTS&&updateOnce&&beforeWasLate&&afterUsesB&&duplicateIgnored;
        allRates=allRates&&ok;
        [rates addObject:@{ @"multiplier":@(multiplier), @"ok":@(ok), @"phases":@(phaseCount), @"clockUpdates":@(sourceClockCount),
            @"oldAnchorDeadlineFromBMs":@(oldFromB), @"updatedDeadlineFromBMs":@(newFromB), @"delayMs":@(delayMs),
            @"sourceClockUpdatedOnce":@(updateOnce), @"originalPhasePTS":@(phasePTS), @"duplicateIgnored":@(duplicateIgnored) }];
        [p stop];
    }
    SPLiveProcessor *fixed=[[SPLiveProcessor alloc] init]; __block BOOL holdOK=NO;
    dispatch_sync(fixed->_q, ^{
        fixed->_request.interpolationEnabled=YES; fixed->_request.engineID=@"apple.frc"; fixed->_request.rateKind=SPLiveRateFixedFPS;
        fixed->_request.fpsNumerator=60; fixed->_request.fpsDenominator=1; fixed->_testCapturePlayout=YES; [fixed resetSchedulerOnQueue];
        int64_t base=SPHostNow()+SPRationalToHost(sp::spMake(2,1));
        fixed->_held[21].pts=sp::spMake(0,1); fixed->_held[21].host=base;
        fixed->_held[22].pts=sp::spMake(1,30); fixed->_held[22].host=base+SPRationalToHost(sp::spMake(1,30));
        sp::SPScheduleInput a; a.identity=21; a.pts=sp::spMake(0,1); a.generation=fixed->_configVersion;
        auto ar=fixed->_scheduler.push(a); if(ar.reject==sp::SPScheduleReject::None){[fixed handleAcceptedInput:21 events:ar.events generation:fixed->_sourceGeneration];}
        sp::SPScheduleInput b; b.identity=22; b.pts=sp::spMake(1,30); b.generation=fixed->_configVersion; b.sceneCutBefore=true;
        auto br=fixed->_scheduler.push(b); if(br.reject==sp::SPScheduleReject::None){[fixed handleAcceptedInput:22 events:br.events generation:fixed->_sourceGeneration];}
        int holds=0, clocks=0; for(auto e:br.events) if(e.action==sp::SPScheduleAction::Hold && sp::spCmp(e.pts,sp::spMake(1,60))==0)holds++;
        for(NSDictionary *entry in fixed->_testTimingTrace)if([entry[@"kind"] isEqual:@"sourceClock"])clocks++;
        holdOK=holds==1 && clocks==2 && sp::spCmp(fixed->_previousSourcePts,sp::spMake(1,30))==0 && llabs(SPHostToNs(fixed->_intervalHost)-33333333LL)<1000;
    });
    [fixed stop];
    SPLiveProcessor *stale=[[SPLiveProcessor alloc] init]; __block BOOL retired=NO, lateRejected=NO, recomputedWouldBeFuture=NO, fpsReset=NO, sourceReset=NO;
    CVPixelBufferRef buffer=SPCreateBuffer(32,32,kCVPixelFormatType_32BGRA);
    dispatch_sync(stale->_q, ^{
        stale->_request.interpolationEnabled=YES; stale->_request.engineID=@"apple.frc";
        int64_t base=SPHostNow()+SPRationalToHost(sp::spMake(2,1));
        [stale noteSourceClock:sp::spMake(0,1) host:base];
        int64_t media=(int64_t)(CACurrentMediaTime()*1e9);
        stale->_fpsMeter.presented(0,media-10000000,1,false,false,true);
        stale->_fpsMeter.presented(1,media,2,false,false,true);
        BOOL hadFPS=stale->_fpsMeter.outputRate(media)>0; uint64_t fpsEpoch=stale->_fpsObservationEpoch;
        SPLiveJob *job=new SPLiveJob(); job->configVersion=stale->_configVersion; job->generation=stale->_sourceGeneration;
        job->inflightEpoch=stale->_inflightEpoch; job->clockEpoch=stale->_clockEpoch; job->count=1; job->pts[0]=sp::spMake(1,60);
        [stale noteSourceClock:sp::spMake(1,30) host:base+SPRationalToHost(sp::spMake(300,1000))];
        fpsReset=hadFPS && stale->_fpsMeter.outputRate(media)<0 && stale->_fpsObservationEpoch==fpsEpoch+1;
        SPPendingPhase pending; pending.pts=sp::spMake(1,60); pending.generation=stale->_sourceGeneration; stale->_pending.push_back(pending);
        [stale finishJob:job token:0 outputs:@[] latency:0 error:nil];
        retired=stale->_clockRetiredJobs==1 && stale->_syntheticFail==0 && stale->_pending.size()==1;
        stale->_pending.clear();
        recomputedWouldBeFuture=[stale targetHostForPTS:sp::spMake(1,10)] > SPHostNow();
        if(buffer) [stale enqueueReadyEnhanced:CVPixelBufferRetain(buffer) original:NULL pts:sp::spMake(1,10) synthetic:YES held:NO captureHost:0 generation:stale->_sourceGeneration deadlineHost:SPHostNow()-SPRationalToHost(sp::spMake(50,1000))];
        lateRejected=buffer && recomputedWouldBeFuture && stale->_lateReadyDrops==1 && stale->_slots.empty();
    });
    [stale adoptSourceGeneration:2];
    dispatch_sync(stale->_q, ^{ sourceReset=stale->_sourceGeneration==2 && !stale->_havePreviousSourcePts && !stale->_haveAnchor; });
    [stale stop]; if(buffer)CVPixelBufferRelease(buffer);
    // This uses actual accepted-source/event handling and actual completion to
    // enqueue. No RIFE object/model is created; inference outputs are simulated.
    SPLiveProcessor *rifeClock=[[SPLiveProcessor alloc] init];
    __block NSDictionary *rifeResult=nil; __block BOOL rifeOK=NO;
    CVPixelBufferRef rifeBuffer=SPCreateBuffer(32,32,kCVPixelFormatType_32BGRA);
    dispatch_sync(rifeClock->_q, ^{
        auto p=rifeClock;
        p->_request.interpolationEnabled=YES; p->_request.engineID=@"rife.metal";
        p->_request.rateKind=SPLiveRateMultiplier; p->_request.multiplier=2;
        p->_testCapturePlayout=YES; p->_width=32; p->_height=32; [p resetSchedulerOnQueue];
        p->_delayHost=SPRationalToHost(sp::spMake(40,1000));
        int64_t base=SPHostNow()+SPRationalToHost(sp::spMake(2,1));
        for(uint64_t identity=41;identity<=43;++identity) {
            p->_held[identity].pts=sp::spMake((int64_t)identity-41,60);
            p->_held[identity].host=base+SPRationalToHost(p->_held[identity].pts);
        }
        if(rifeBuffer) p->_held[42].source=CVPixelBufferRetain(rifeBuffer);
        auto accept=[&](uint64_t identity) {
            sp::SPScheduleInput input; input.identity=identity; input.pts=p->_held[identity].pts; input.generation=p->_configVersion;
            auto result=p->_scheduler.push(input);
            if(result.reject==sp::SPScheduleReject::None) [p handleAcceptedInput:identity events:result.events generation:p->_sourceGeneration];
            return result;
        };
        auto first=accept(41), second=accept(42);
        BOOL enabled=[p usesRifePairAffineClock];
        if(!enabled) {
            rifeOK=!p->_held[41].pairClockSource.frozen && !p->_held[42].pairClockSource.frozen;
            rifeResult=@{ @"ok":@(rifeOK),@"enabled":@NO,@"defaultPathLeavesEndpointsUnfrozen":@(rifeOK) }; return;
        }
        sp::SPScheduleOutput midpoint;
        for(auto event:second.events) if(event.action==sp::SPScheduleAction::Interpolate) midpoint=event;
        auto frozen=[p rifePairClockTargetForEvent:midpoint];
        const auto b=p->_held[42].pairClockSource;
        BOOL sourceBUsesCanonical=NO;
        for(const auto &slot:p->_slots) if(!slot.synthetic && sp::spCmp(slot.pts,p->_held[42].pts)==0)
            sourceBUsesCanonical=slot.targetHost==b.targetHost;
        BOOL sourceOrder=first.reject==sp::SPScheduleReject::None && second.reject==sp::SPScheduleReject::None &&
            p->_held[41].pairClockSource.frozen && b.frozen && frozen.binding==sp::RifePairClockBinding::bound;
        BOOL frozenBeforePlan=NO; NSUInteger freezeIndex=NSNotFound,planIndex=NSNotFound;
        for(NSUInteger i=0;i<p->_testTimingTrace.count;++i) {
            NSDictionary *trace=p->_testTimingTrace[i];
            if([trace[@"kind"] isEqual:@"pairAffineSourceFrozen"] && [trace[@"sourceIdentity"] unsignedLongLongValue]==42) freezeIndex=i;
            if([trace[@"kind"] isEqual:@"phasePlan"]) planIndex=i;
        }
        frozenBeforePlan=freezeIndex!=NSNotFound && planIndex!=NSNotFound && freezeIndex<planIndex;
        accept(43);
        BOOL reusedA=p->_held[42].pairClockSource.targetHost==b.targetHost && p->_held[42].pairClockSource.delayHost==b.delayHost;
        ++p->_measurementEpoch;
        auto stale=[p rifePairClockTargetForEvent:midpoint];
        BOOL staleFallback=stale.binding==sp::RifePairClockBinding::contextMismatch && stale.selectedTargetHost==stale.legacyTargetHost;
        --p->_measurementEpoch;
        BOOL deferred=[p deferRifeEvent:midpoint generation:p->_sourceGeneration deadline:frozen.selectedTargetHost
            retryHost:SPHostNow()+SPRationalToHost(sp::spMake(5,1000)) frozenPairClock:&frozen];
        p->_delayHost=SPRationalToHost(sp::spMake(84,1000));
        const auto retry=p->_rifeDeferredPairClock;
        [p clearDeferredRife];
        [p submitEventGroup:{midpoint} generation:p->_sourceGeneration frozenDeadline:frozen.selectedTargetHost frozenPairClock:&retry];
        NSDictionary *retried=[p->_r8OutputTimeline.lastObject[@"targets"] firstObject];
        BOOL retryStable=deferred && [retried[@"selectedTargetHost"] longLongValue]==frozen.selectedTargetHost &&
            [retried[@"legacyFrozenDelayHost"] longLongValue]==frozen.legacyDelayHost &&
            [retried[@"legacyCandidateTargetHost"] longLongValue]==frozen.legacyTargetHost;
        SPLiveJob *job=new SPLiveJob(); job->count=1; job->frameA=41; job->frameB=42;
        job->generation=p->_sourceGeneration; job->configVersion=p->_configVersion;
        job->clockEpoch=p->_clockEpoch; job->measurementEpoch=p->_measurementEpoch; job->inflightEpoch=p->_inflightEpoch;
        job->pts[0]=midpoint.pts; job->phase[0]=midpoint.phase; job->targetHost[0]=frozen.selectedTargetHost; job->pairClock[0]=frozen;
        SPOwnedPixelBuffer *box=rifeBuffer ? [[SPOwnedPixelBuffer alloc] initWithBufferNoCopy:CVPixelBufferRetain(rifeBuffer)] : nil;
        [p finishJob:job token:0 outputs:box ? @[box] : @[] latency:0 error:nil];
        BOOL completionFrozen=NO;
        for(const auto &slot:p->_slots) if(slot.synthetic && sp::spCmp(slot.pts,midpoint.pts)==0)
            completionFrozen=slot.targetHost==frozen.selectedTargetHost;
        rifeOK=sourceOrder && frozenBeforePlan && sourceBUsesCanonical && reusedA && staleFallback && retryStable && completionFrozen;
        rifeResult=@{ @"ok":@(rifeOK),@"enabled":@YES,@"acceptedSourcesFrozenBeforePhases":@(sourceOrder&&frozenBeforePlan),
            @"previousBReusedAsA":@(reusedA),@"staleContextFallsBack":@(staleFallback),@"deferredWholeSnapshotReused":@(retryStable),
            @"sourceBUsesSameCanonicalTarget":@(sourceBUsesCanonical),
            @"completionPreservesSelectedTarget":@(completionFrozen),@"target":SPRifePairClockValue(frozen,41,42) };
    });
    [rifeClock stop]; if(rifeBuffer)CVPixelBufferRelease(rifeBuffer);
    BOOL ok=allRates && holdOK && retired && lateRejected && fpsReset && sourceReset && rifeOK;
    return @{ @"ok":@(ok), @"multipliers":rates, @"fixedFPSHoldUsesRealSourceClock":@(holdOK),
        @"oldClockJobRetiredWithoutTouchingNewPending":@(retired), @"lateFrozenDeadlineRejected":@(lateRejected),
        @"recomputedDeadlineWouldBeFuture":@(recomputedWouldBeFuture), @"fpsWindowResetOnReanchor":@(fpsReset), @"sourceGenerationReset":@(sourceReset),
        @"rifePairAffineClock":rifeResult ?: @{},
        @"scope":@"deterministic source clock and actual scheduler/event handler with simulated completion and synthetic buffer; no real inference, capture, window or physical FPS" };
}

// Exercises actual source-only pump/playout without constructing a model or
// window. Physical timing and the asynchronous GPU path require native tests.
+ (NSDictionary<NSString *, id> *)runP1SourceOnlyAckContract {
    SPLiveProcessor *p=[[SPLiveProcessor alloc] init];
    auto ack=std::make_shared<std::atomic<int>>(0);
    p.planHandler=^(NSInteger state, NSString *engine, NSString *model, NSString *reason, uint64_t requestID) {
        (void)engine; (void)model; (void)reason;
        if (state==2 && requestID==701) ack->fetch_add(1);
    };
    SPLivePlanRequest *request=[[SPLivePlanRequest alloc] init]; request.requestID=701;
    request.interpolationEnabled=NO; request.scaleEnabled=NO; request.engineID=@"apple.frc";
    [p updateRequest:request];
    for (int i=0;i<100 && ack->load()==0;++i) usleep(10000);
    __block BOOL committed=NO, zeroDelay=NO; __block uint64_t config=0;
    dispatch_sync(p->_q, ^{ committed=p->_resolved.committed && p->_resolved.configVersion==p->_configVersion;
        zeroDelay=p->_delayHost==0; config=p->_configVersion; });
    BOOL ok=ack->load()==1 && committed && zeroDelay && config>1;
    [p stop];
    return @{ @"ok":@(ok), @"ackExactlyOnce":@(ack->load()==1), @"committed":@(committed), @"zeroTemporalDelay":@(zeroDelay),
        @"config":@(config), @"scope":@"source-only request before first source frame; no GUI, capture or event tap" };
}

+ (NSDictionary<NSString *, id> *)runP0PassthroughContract {
    SPLiveProcessor *p = [[SPLiveProcessor alloc] init];
    CVPixelBufferRef frame = SPCreateBuffer(320,192,kCVPixelFormatType_32BGRA);
    if (!frame) return @{ @"ok": @NO, @"error": @"frame allocation" };
    __block BOOL zero=NO, newest=NO, staleSource=NO, orderedInterpolation=NO, disabledScaleIgnored=NO;
    dispatch_sync(p->_q, ^{
        p->_stopped=NO; p->_request.interpolationEnabled=NO; p->_request.scaleEnabled=NO;
        p->_width=320; p->_height=192; p->_sourceWidth=320; p->_sourceHeight=192;
        p->_sessionReady=YES; p->_testCapturePlayout=YES; p->_frcEwmaSec=0.9; p->_scaleEwmaSec=0.8;
        for (int i=0; i<10; ++i) { SPPushSample(p->_frcNs,900000000); SPPushSample(p->_captureToOutputReadyNs,900000000); }
        p->_delayHost=SPRationalToHost(sp::spMake(1,2)); [p recomputeInteractiveDelay];
        zero=p->_delayHost==0 && [p requestUsesLatestPresentation:p->_request];
        for (int n : {3,1,2}) {
            SPLiveInbound item; item.buffer=CVPixelBufferRetain(frame); item.ptsNum=n; item.ptsDen=60;
            item.host=SPHostNow(); item.readyHost=item.host; item.generation=p->_sourceGeneration;
            p->_inbound.push_back(item);
        }
        SPLiveInbound old; old.buffer=CVPixelBufferRetain(frame); old.ptsNum=9; old.ptsDen=60;
        old.host=SPHostNow(); old.readyHost=old.host; old.generation=p->_sourceGeneration-1; p->_inbound.push_back(old);
        [p pump];
        newest=p->_testPlayout.size()==1 && sp::spCmp(p->_testPlayout.back().first,sp::spMake(3,60))==0 && p->_processedSequence==1;
        staleSource=p->_generationDrops==1;
        p->_request.interpolationEnabled=YES; p->_request.engineID=@"apple.frc";
        p->_frcNs.clear(); p->_captureToOutputReadyNs.clear(); p->_frcEwmaSec=0.020;
        p->_scaleEwmaSec=0.8; [p recomputeInteractiveDelay]; double noScale=p->_r9RequiredBudgetMs;
        p->_scaleEwmaSec=0.001; [p recomputeInteractiveDelay];
        disabledScaleIgnored=fabs(noScale-p->_r9RequiredBudgetMs)<0.001;
        orderedInterpolation=![p requestUsesLatestPresentation:p->_request] && p->_r9RequiredBudgetMs>0;
    });
    [p stop]; CVPixelBufferRelease(frame);
    BOOL ok=zero && newest && staleSource && orderedInterpolation && disabledScaleIgnored;
    return @{ @"ok":@(ok), @"zeroTemporalWait":@(zero), @"newestBufferedSource":@(newest),
        @"oldGenerationDropped":@(staleSource), @"interpolationRetainsDeadlines":@(orderedInterpolation),
        @"disabledScaleExcluded":@(disabledScaleIgnored),
        @"scope":@"actual CPU processor queue, no GUI or physical presentation; async scale and old callback isolation require separate regression" };
}

// Exercises production processor queue methods with CPU-owned synthetic
// buffers and controlled timestamps; it does not instantiate a VT/GPU model.
+ (NSDictionary<NSString *, id> *)runR9FRCBudgetContract {
    SPLiveProcessor *p = [[SPLiveProcessor alloc] init];
    CVPixelBufferRef frame = SPCreateBuffer(320,192,kCVPixelFormatType_32BGRA);
    if (!frame) return @{ @"ok": @NO, @"error": @"frame allocation" };
    __block BOOL limited=NO, sourceContinues=NO, backendSeparate=NO, recovered=NO, staleIgnored=NO, terminalExclusive=NO, reset=NO, sourceReset=NO, stopReset=NO;
    __block uint64_t rejected=0, probes=0, sourceCount=0;
    dispatch_sync(p->_q, ^{
        p->_stopped=NO; p->_request.interpolationEnabled=YES; p->_request.engineID=@"apple.frc";
        p->_request.quality=SPFRCQualityHigh; p->_request.rateKind=SPLiveRateMultiplier; p->_request.multiplier=2;
        p->_request.scaleEnabled=NO; p->_width=2560; p->_height=1410;
        p->_resolved.outputWidth=2560; p->_resolved.outputHeight=1410;
        p->_haveInterval=YES; p->_intervalHost=SPRationalToHost(sp::spMake(1,60)); p->_testCapturePlayout=YES;
        [p beginMeasurementEpoch];
        for (int i=0;i<32;i++) { SPPushSample(p->_captureToOutputReadyNs,100000000); [p r9RecordUsableLatency:0.100]; }
        limited=p->_r9RequiredBudgetMs > p->_r9AllowedBudgetMs;
        int64_t base=SPHostToNs(SPHostNow());
        uint64_t oldBackend=p->_r9BackendFullPhases, oldReject=p->_r9BudgetRejectedPhases;
        BOOL deniedBusy=![p r9AdmitFRCPhases:1 backendAvailable:NO nowNs:base];
        backendSeparate=deniedBusy && p->_r9BackendFullPhases==oldBackend+1 && p->_r9BudgetRejectedPhases==oldReject;
        for (int i=0;i<120;i++) {
            (void)[p r9AdmitFRCPhases:1 backendAvailable:YES nowNs:base+(int64_t)i*1000000000LL/60];
            uint64_t id=(uint64_t)(1000+i); auto pts=sp::spMake(i+1,60);
            p->_held[id].source=CVPixelBufferRetain(frame); p->_held[id].pts=pts;
            p->_held[id].host=SPHostNow()-SPRationalToHost(sp::spMake(1,2));
            p->_haveAnchor=YES; p->_anchorPts=pts; p->_anchorHost=p->_held[id].host;
            p->_delayHost=0; p->_havePreviousSourcePts=NO;
            [p enqueueSourceIdentity:id pts:pts host:p->_held[id].host generation:p->_sourceGeneration force:YES];
            [p trimHeld];
        }
        rejected=p->_r9BudgetRejectedPhases; probes=p->_r9BudgetProbeJobs; sourceCount=p->_testPlayout.size();
        limited=limited && p->_r9FRCBudgetGate.limited() && rejected>100 && probes>=1 && probes<=2;
        sourceContinues=sourceCount==120;
        for (const auto &output:p->_testPlayout) if (output.second) sourceContinues=NO;
        // Fast feedback only arrives on accepted re-probes, exercising the real
        // sample window and recomputation rather than assigning a desired result.
        for (int i=0;i<40 && p->_r9FRCBudgetGate.limited();i++) {
            int64_t when=base+3000000000LL+(int64_t)i*2100000000LL;
            if ([p r9AdmitFRCPhases:1 backendAvailable:YES nowNs:when]) {
                SPPushSample(p->_captureToOutputReadyNs,15000000);
                [p r9RecordUsableLatency:0.015];
            }
        }
        (void)[p r9AdmitFRCPhases:1 backendAvailable:YES nowNs:base+100000000000LL];
        recovered=!p->_r9FRCBudgetGate.limited() && p->_r9RequiredBudgetMs<=p->_r9AllowedBudgetMs;
        size_t before=p->_frcNs.size(), beforeReady=p->_captureToOutputReadyNs.size();
        uint64_t beforeSynth=p->_syntheticOK, beforeOnTime=p->_r9OnTimeSynthetic;
        p->_r9GeneratedFPS=12.5; p->_r9OnTimeSyntheticFPS=3.5;
        double requiredBefore=p->_r9RequiredBudgetMs, allowedBefore=p->_r9AllowedBudgetMs;
        BOOL gateBefore=p->_r9FRCBudgetGate.limited();
        for (int reason=0;reason<3;reason++) {
            SPLiveJob *job=new SPLiveJob(); job->generation=p->_sourceGeneration; job->configVersion=p->_configVersion;
            job->clockEpoch=p->_clockEpoch; job->inflightEpoch=p->_inflightEpoch; job->count=1;
            if(reason==0) job->generation++;
            if(reason==1) job->configVersion++;
            if(reason==2) job->clockEpoch++;
            SPOwnedPixelBuffer *box=[[SPOwnedPixelBuffer alloc] initWithBufferNoCopy:CVPixelBufferRetain(frame)];
            [p finishJob:job token:0 outputs:@[box] latency:9.0 error:nil];
        }
        staleIgnored=p->_frcNs.size()==before && p->_captureToOutputReadyNs.size()==beforeReady &&
            p->_syntheticOK==beforeSynth && p->_r9OnTimeSynthetic==beforeOnTime && p->_r9FRCBudgetGate.limited()==gateBefore &&
            p->_r9GeneratedFPS==12.5 && p->_r9OnTimeSyntheticFPS==3.5 && p->_r9RequiredBudgetMs==requiredBefore && p->_r9AllowedBudgetMs==allowedBefore;
        [p clearPlaySlots]; p->_haveLastPts=NO; p->_pending.clear(); p->_claimedDrops.clear(); p->_pixelDiagnosticsEnabled=YES;
        uint64_t beforeExpired=p->_pendingExpiredDrops, beforeLate=p->_lateReadyDrops;
        int64_t now=SPHostNow(); SPPendingPhase pending; pending.pts=sp::spMake(7000,120); pending.jobID=42;
        pending.generation=p->_sourceGeneration; pending.configVersion=p->_configVersion; pending.clockEpoch=p->_clockEpoch;
        pending.measurementEpoch=p->_measurementEpoch; pending.targetHost=now-SPRationalToHost(sp::spMake(5,100));
        p->_pending.push_back(pending); int64_t earliest=0;
        (void)[p waitForPendingBefore:sp::spMake(7001,120) now:now earliest:&earliest];
        [p enqueueReadyEnhanced:CVPixelBufferRetain(frame) original:NULL pts:pending.pts synthetic:YES held:NO
                   captureHost:0 generation:p->_sourceGeneration deadlineHost:pending.targetHost jobID:42];
        [p enqueueReadyEnhanced:CVPixelBufferRetain(frame) original:NULL pts:sp::spMake(7002,120) synthetic:YES held:NO
                   captureHost:0 generation:p->_sourceGeneration deadlineHost:pending.targetHost jobID:43];
        int expiredEvents=0, duplicateLate=0, otherLate=0;
        for (NSDictionary *event in p->_r7JobTimeline) {
            if ([event[@"id"] unsignedLongLongValue]==42 && [event[@"kind"] isEqual:@"pendingExpiredDrop"]) expiredEvents++;
            if ([event[@"id"] unsignedLongLongValue]==42 && [event[@"kind"] isEqual:@"lateReadyDrop"]) duplicateLate++;
            if ([event[@"id"] unsignedLongLongValue]==43 && [event[@"kind"] isEqual:@"lateReadyDrop"]) otherLate++;
        }
        terminalExclusive=p->_pendingExpiredDrops==beforeExpired+1 && p->_lateReadyDrops==beforeLate+1 && expiredEvents==1 && duplicateLate==0 && otherLate==1;
        [p beginMeasurementEpoch]; reset=!p->_r9FRCBudgetGate.limited() && p->_r9GeneratedFPS<0 && p->_r9OnTimeSyntheticFPS<0;
    });
    [p adoptSourceGeneration:2];
    dispatch_sync(p->_q, ^{ sourceReset=p->_sourceGeneration==2 && !p->_r9FRCBudgetGate.limited() && p->_r9GeneratedFPS<0; });
    [p stop];
    dispatch_sync(p->_q, ^{ stopReset=p->_stopped && !p->_r9FRCBudgetGate.limited() && p->_r9GeneratedFPS<0 && p->_r9OnTimeSyntheticFPS<0; });
    CVPixelBufferRelease(frame);
    BOOL ok=limited && sourceContinues && backendSeparate && recovered && staleIgnored && terminalExclusive && reset && sourceReset && stopReset;
    return @{ @"ok": @(ok), @"budgetLimited": @(limited), @"sourceContinues": @(sourceContinues),
        @"backendFullSeparate": @(backendSeparate), @"recoveredFromFeedback": @(recovered),
        @"oldCallbacksIgnored": @(staleIgnored), @"phaseTerminalsExclusive": @(terminalExclusive),
        @"epochReset": @(reset), @"sourceReset": @(sourceReset), @"stopReset": @(stopReset), @"rejectedPhases": @(rejected), @"probeJobs": @(probes), @"sourceFrames": @(sourceCount),
        @"scope": @"production queue and policy with controlled CPU buffer/timing; no FRC inference, SCK, drawable or GUI" };
}

 + (NSDictionary<NSString *, id> *)runPresentationBudgetContract {
    SPLiveProcessor *p = [[SPLiveProcessor alloc] init];
    CVPixelBufferRef frame = SPCreateBuffer(320,192,kCVPixelFormatType_32BGRA);
    if (!frame) { [p stop]; return @{ @"ok":@NO, @"error":@"frame allocation" }; }
    __block BOOL preEnable=NO, epochPreserves=NO, nativeCross=NO, pressureSource=NO, pressureRecovery=NO, bounded=NO, timelyOrder=NO, lateRejected=NO, sameContext=NO;
    __block BOOL deferredAdmission=NO, deferredCapacity=NO, deferredExpiry=NO, deferredClockReset=NO, deferredGenerationReset=NO, deferredSubmitFailure=NO, poolRetry=NO, deferredStale=NO;
    __block BOOL independentNativeSources=YES, captureLimitTransition=NO, unconfiguredRequestPreserved=NO, sourceChangeClears=NO, previewGenerationGuard=NO, coverOrderGuard=NO, stopResumeGuard=NO, deferredRetiredWake=NO, nativeBGRARecovery=NO, steppedPlayout=NO;
    dispatch_sync(p->_q, ^{
        p->_request.interpolationEnabled=NO; p->_request.engineID=@"rife.metal";
        p->_request.rateKind=SPLiveRateMultiplier; p->_request.multiplier=2; p->_request.displayRefreshHz=120;
        p->_sourceWidth=320; p->_sourceHeight=192; p->_width=320; p->_height=192;
        [p setRawCadenceRefreshHz:120 captureLimit:0 displayID:1];
        int64_t now=SPHostToNs(SPHostNow());
        {
            std::lock_guard<std::mutex> lock(p->_rawCadenceMutex);
            for(int i=0;i<110;i++) p->_nativeCadence.observe((int64_t)i*1000000000/120,now-910000000LL+(int64_t)i*1000000000/120,1,320,192);
            preEnable=p->_nativeCadence.query(now).active;
        }
        [p beginMeasurementEpoch];
        auto preserved=[p nativeCadenceSnapshot]; epochPreserves=preserved.active && preserved.callbacks>=110;
        p->_request.interpolationEnabled=YES; p->_sessionReady=YES; p->_resolved.interpolationActive=YES;
        p->_rife=[[SPRifeBridge alloc] init]; p->_rifeSlowMode=YES; p->_testCapturePlayout=YES;
        p->_lastEnhanced=CVPixelBufferRetain(frame); p->_lastOriginal=CVPixelBufferRetain(frame);
        int64_t past=SPHostNow()-SPRationalToHost(sp::spMake(1,10));
        p->_haveAnchor=YES; p->_anchorPts=sp::spMake(10,1); p->_anchorHost=past;
        p->_delayHost=SPRationalToHost(sp::spMake(1,1000));
        for(int i=0;i<3;i++) { p->_held[11+i].source=CVPixelBufferRetain(frame); p->_held[11+i].pts=sp::spMake(1200+i,120); p->_held[11+i].host=past+SPRationalToHost(sp::spMake(i,120)); }
        [p enqueueSourceIdentity:11 pts:p->_held[11].pts host:past generation:1 force:NO];
        sp::SPScheduleOutput mid; mid.action=sp::SPScheduleAction::Interpolate; mid.frameA=11; mid.frameB=12; mid.pts=sp::spMake(2401,240); mid.phase=sp::spMake(1,2);
        sp::SPScheduleOutput source; source.action=sp::SPScheduleAction::PresentSource; source.sourceIdentity=12; source.pts=p->_held[12].pts;
        [p handleEvents:{mid,source} generation:1];
        nativeCross=p->_nativeBudgetActive && p->_nativeBudgetSkippedPhases==1 && p->_testPlayout.size()>=2 &&
            !p->_testPlayout.back().second && sp::spCmp(p->_testPlayout.back().first,source.pts)==0 && ![p requestUsesLatestPresentation:p->_request];
        p->_sourceWidth=321; sameContext=![p nativeBudgetForSnapshot:[p nativeCadenceSnapshot]]; p->_sourceWidth=320;
        p->_rifeSlowMode=NO;
        pressureSource=YES; bounded=YES;
        for (int i=0;i<6;i++) {
            SPLiveJob *job=new SPLiveJob(); job->generation=1; job->configVersion=p->_configVersion; job->clockEpoch=p->_clockEpoch; job->inflightEpoch=p->_inflightEpoch;
            job->count=1; job->pts[0]=sp::spMake(2403+i*2,240); p->_frcEwmaSec=0.08;
            SPPendingPhase pending; pending.pts=job->pts[0]; pending.generation=1; pending.targetHost=SPHostNow(); p->_pending.push_back(pending);
            NSError *pool=[NSError errorWithDomain:@"app.openduckframe.rife" code:SPRifeBridgeErrorOutputPoolExhausted userInfo:nil];
            [p finishJob:job token:0 outputs:@[] latency:0.5 error:pool];
            uint64_t id=30+i; p->_held[id].source=CVPixelBufferRetain(frame); p->_held[id].pts=sp::spMake(1203+i,120);
            p->_held[id].host=SPHostNow()-SPRationalToHost(sp::spMake(1,2));
            p->_haveAnchor=YES; p->_anchorPts=p->_held[id].pts; p->_anchorHost=p->_held[id].host; p->_havePreviousSourcePts=NO;
            [p enqueueSourceIdentity:id pts:p->_held[id].pts host:p->_held[id].host generation:1 force:NO];
            pressureSource=pressureSource && p->_delayClamped && !p->_rifeSlowMode && !p->_testPlayout.back().second &&
                sp::spCmp(p->_testPlayout.back().first,p->_held[id].pts)==0;
            bounded=bounded && p->_slots.size()<=[p slotCap] && p->_pending.empty();
        }
        int64_t future=SPHostNow()+SPRationalToHost(sp::spMake(4,100));
        [p enqueueReadyEnhanced:CVPixelBufferRetain(frame) original:NULL pts:sp::spMake(2417,240) synthetic:YES held:NO captureHost:SPHostNow() generation:1 deadlineHost:future];
    });
    for (int mode=0;mode<2;mode++) {
        SPLiveProcessor *independent=[[SPLiveProcessor alloc] init];
        dispatch_sync(independent->_q, ^{
            independent->_request.interpolationEnabled=YES; independent->_request.rateKind=SPLiveRateMultiplier;
            independent->_request.multiplier=2; independent->_request.displayRefreshHz=120;
            independent->_request.engineID=mode==0 ? @"distildrba.coreml" : @"apple.lowlatency";
            independent->_sourceWidth=320; independent->_sourceHeight=192; independent->_width=320; independent->_height=192;
            independent->_sessionReady=YES; independent->_resolved.interpolationActive=YES; independent->_testCapturePlayout=YES;
            if (mode==0) independent->_distil=[[SPDistilDRBA alloc] init];
            else { independent->_lowLatency=[[SPLowLatencyEngine alloc] init]; independent->_lowPrescaleSlowMode=YES; }
            independent->_lastEnhanced=CVPixelBufferRetain(frame); independent->_lastOriginal=CVPixelBufferRetain(frame);
            [independent setRawCadenceRefreshHz:120 captureLimit:0 displayID:1];
            int64_t now=SPHostToNs(SPHostNow());
            { std::lock_guard<std::mutex> lock(independent->_rawCadenceMutex);
              for(int i=0;i<100;i++) independent->_nativeCadence.observe((int64_t)i*1000000000/120,now-830000000LL+(int64_t)i*1000000000/120,1,320,192); }
            int64_t past=SPHostNow()-SPRationalToHost(sp::spMake(1,10));
            independent->_held[2].source=CVPixelBufferRetain(frame); independent->_held[2].pts=sp::spMake(1201,120); independent->_held[2].host=past;
            sp::SPScheduleOutput mid; mid.action=sp::SPScheduleAction::Interpolate; mid.frameA=1; mid.frameB=2; mid.pts=sp::spMake(2401,240); mid.phase=sp::spMake(1,2);
            sp::SPScheduleOutput source; source.action=sp::SPScheduleAction::PresentSource; source.sourceIdentity=2; source.pts=independent->_held[2].pts;
            [independent handleEvents:{mid,source} generation:1];
            independentNativeSources=independentNativeSources && independent->_nativeBudgetActive && independent->_nativeBudgetSkippedPhases==1 &&
                !independent->_testPlayout.empty() && !independent->_testPlayout.back().second && sp::spCmp(independent->_testPlayout.back().first,source.pts)==0;
        });
        [independent stop];
    }
    SPLiveProcessor *capCheck=[[SPLiveProcessor alloc] init];
    dispatch_sync(capCheck->_q, ^{ capCheck->_width=320; capCheck->_height=192; capCheck->_sourceWidth=320; capCheck->_sourceHeight=192; });
    SPLivePlanRequest *staleRequest=[[SPLivePlanRequest alloc] init]; staleRequest.interpolationEnabled=NO; staleRequest.scaleEnabled=NO;
    staleRequest.rateKind=SPLiveRateMultiplier; staleRequest.multiplier=2; staleRequest.captureCapFPS=60; staleRequest.displayRefreshHz=60;
    [capCheck setRawCadenceRefreshHz:60 captureLimit:60 displayID:1]; [capCheck updateCaptureLimitFPS:60];
    dispatch_sync(capCheck->_q, ^{});
    [capCheck setRawCadenceRefreshHz:120 captureLimit:0 displayID:1]; [capCheck updateCaptureLimitFPS:0];
    dispatch_sync(capCheck->_q, ^{
        [capCheck installRequest:staleRequest lowLatency:nil rife:nil distil:nil appleSR:nil videoSR:nil animeSR:nil cuganSR:nil artCNNSR:nil];
        capCheck->_request.interpolationEnabled=YES;
        int64_t now=SPHostToNs(SPHostNow());
        { std::lock_guard<std::mutex> lock(capCheck->_rawCadenceMutex);
          for(int i=0;i<100;i++) capCheck->_nativeCadence.observe((int64_t)i*1000000000/120,now-830000000LL+(int64_t)i*1000000000/120,1,320,192); }
        captureLimitTransition=capCheck->_request.captureCapFPS==0 && capCheck->_request.displayRefreshHz==120 &&
            [capCheck nativeBudgetForSnapshot:[capCheck nativeCadenceSnapshot]];
    });
    [capCheck stop];
    SPLiveProcessor *unconfigured=[[SPLiveProcessor alloc] init];
    dispatch_sync(unconfigured->_q, ^{
        unconfigured->_request.captureCapFPS=60; unconfigured->_request.displayRefreshHz=120;
        [unconfigured applyObservedCaptureEnvironment];
        unconfiguredRequestPreserved=unconfigured->_request.captureCapFPS==60 && unconfigured->_request.displayRefreshHz==120;
    });
    [unconfigured stop];
    SPLiveProcessor *sourceChange=[[SPLiveProcessor alloc] init];
    dispatch_sync(sourceChange->_q, ^{ sourceChange->_lastEnhanced=CVPixelBufferRetain(frame); sourceChange->_lastOriginal=CVPixelBufferRetain(frame); });
    [sourceChange adoptSourceGeneration:2];
    dispatch_sync(sourceChange->_q, ^{ sourceChangeClears=sourceChange->_sourceGeneration==2 && !sourceChange->_lastEnhanced && !sourceChange->_lastOriginal; });
    [sourceChange stop];
    dispatch_sync(dispatch_get_main_queue(), ^{
        SPLivePreviewView *view=[[SPLivePreviewView alloc] initWithFrame:NSMakeRect(0,0,64,32)];
        [view setGeneration:1]; [view revealSourceGeneration:1];
        BOOL first=![view sourceCoverVisibleForTesting];
        [view setGeneration:2]; BOOL covered=[view sourceCoverVisibleForTesting];
        [view setGeneration:1]; [view revealSourceGeneration:1]; BOOL oldCannotReveal=[view sourceCoverVisibleForTesting];
        [view setGeneration:2]; BOOL sameKeepsCover=[view sourceCoverVisibleForTesting];
        [view revealSourceGeneration:2]; previewGenerationGuard=first && covered && oldCannotReveal && sameKeepsCover && ![view sourceCoverVisibleForTesting];
        // The production dispatched cover runs after a presented callback.
        [view applySourceCoverForGeneration:2]; coverOrderGuard=![view sourceCoverVisibleForTesting];
        [view setGeneration:0]; [view setGeneration:2];
        BOOL sameSourceResumed=![view sourceCoverVisibleForTesting];
        [view setGeneration:3]; [view setGeneration:2]; [view revealSourceGeneration:2];
        BOOL olderRemainsCovered=[view sourceCoverVisibleForTesting];
        [view setGeneration:0]; [view revealSourceGeneration:3];
        BOOL stoppedCannotReveal=[view sourceCoverVisibleForTesting];
        [view setGeneration:3];
        [view revealSourceGeneration:3];
        stopResumeGuard=sameSourceResumed && olderRemainsCovered && stoppedCannotReveal && ![view sourceCoverVisibleForTesting];
    });
    SPLiveProcessor *d = [[SPLiveProcessor alloc] init];
    dispatch_sync(d->_q, ^{
        d->_request.interpolationEnabled=YES; d->_request.engineID=@"rife.metal"; d->_request.rateKind=SPLiveRateMultiplier; d->_request.multiplier=2;
        d->_rife=[[SPRifeBridge alloc] init]; d->_sourceWidth=320; d->_sourceHeight=192; d->_width=320; d->_height=192;
        d->_haveAnchor=YES; d->_anchorPts=sp::spMake(10,1); d->_anchorHost=SPHostNow(); d->_delayHost=SPRationalToHost(sp::spMake(9,100));
        for(int i=0;i<2;i++) { d->_held[51+i].source=CVPixelBufferRetain(frame); d->_held[51+i].pts=sp::spMake(600+i,60); d->_held[51+i].host=d->_anchorHost+SPRationalToHost(sp::spMake(i,60)); }
        sp::SPScheduleOutput mid; mid.action=sp::SPScheduleAction::Interpolate; mid.frameA=51; mid.frameB=52; mid.pts=sp::spMake(1201,120); mid.phase=sp::spMake(1,2);
        d->_inflight=2; [d submitEventGroup:{mid} generation:1];
        deferredAdmission=d->_haveRifeDeferred && d->_rifeDeferredAccepted==1 && d->_pending.size()==1 && d->_held[51].pins==1 && d->_held[52].pins==1;
        [d submitEventGroup:{mid} generation:1]; deferredCapacity=d->_rifeDeferredCapacityDrops==1 && d->_pending.size()==1;
        int64_t deadline=d->_rifeDeferredDeadline; [d expireDeferredRifeAt:deadline+1];
        deferredExpiry=!d->_haveRifeDeferred && d->_pending.empty() && d->_rifeDeferredExpired==1 && d->_held[51].pins==0 && d->_held[52].pins==0;
        [d submitEventGroup:{mid} generation:1]; d->_clockEpoch++; [d expireDeferredRifeAt:SPHostNow()];
        deferredClockReset=!d->_haveRifeDeferred && d->_pending.empty() && d->_held[51].pins==0 && d->_held[52].pins==0;
        [d submitEventGroup:{mid} generation:1]; d->_sourceGeneration=2; [d expireDeferredRifeAt:SPHostNow()];
        deferredGenerationReset=!d->_haveRifeDeferred && d->_pending.empty() && d->_held[51].pins==0 && d->_held[52].pins==0;
        d->_sourceGeneration=1; [d submitEventGroup:{mid} generation:1]; d->_inflight=1;
        uint64_t rejected=d->_engineSubmissionRejectedDrops; [d resumeDeferredRife];
        deferredSubmitFailure=!d->_haveRifeDeferred && d->_pending.empty() && d->_held[51].pins==0 && d->_held[52].pins==0 && d->_engineSubmissionRejectedDrops==rejected+1;
        d->_inflight=0;
        SPLiveJob *poolJob=new SPLiveJob(); poolJob->generation=1; poolJob->configVersion=d->_configVersion; poolJob->clockEpoch=d->_clockEpoch; poolJob->inflightEpoch=d->_inflightEpoch;
        poolJob->count=1; poolJob->frameA=51; poolJob->frameB=52; poolJob->pts[0]=sp::spMake(2401,240); poolJob->phase[0]=sp::spMake(1,4);
        poolJob->targetHost[0]=SPHostNow()+SPRationalToHost(sp::spMake(5,100));
        int64_t deadline2=poolJob->targetHost[0]; NSError *pool=[NSError errorWithDomain:@"app.openduckframe.rife" code:SPRifeBridgeErrorOutputPoolExhausted userInfo:nil];
        [d finishJob:poolJob token:0 outputs:@[] latency:0 error:pool];
        poolRetry=d->_haveRifeDeferred && d->_rifePoolRetryAdmissions==1 && d->_rifeDeferredDeadline==deadline2 && d->_held[51].pins==1 && d->_held[52].pins==1;
        d->_haveLastPts=YES; d->_lastPresentedPts=sp::spMake(2401,240); uint64_t oldExpired=d->_rifeDeferredExpired;
        [d expireDeferredRifeAt:SPHostNow()];
        deferredStale=!d->_haveRifeDeferred && d->_rifeDeferredStale==1 && d->_rifeDeferredExpired==oldExpired && d->_held[51].pins==0 && d->_held[52].pins==0;
    });
    SPLiveProcessor *wake = [[SPLiveProcessor alloc] init];
    dispatch_sync(wake->_q, ^{
        wake->_request.interpolationEnabled=YES; wake->_request.engineID=@"rife.metal";
        wake->_request.rateKind=SPLiveRateMultiplier; wake->_request.multiplier=2;
        wake->_rife=[[SPRifeBridge alloc] init]; wake->_width=320; wake->_height=192;
        wake->_inflight=2; uint64_t retiredClock=wake->_clockEpoch;
        [wake retireClockTimeline];
        wake->_haveAnchor=YES; wake->_anchorPts=sp::spMake(20,1); wake->_anchorHost=SPHostNow();
        wake->_delayHost=SPRationalToHost(sp::spMake(1,1));
        for(int i=0;i<2;i++) { wake->_held[71+i].source=CVPixelBufferRetain(frame); wake->_held[71+i].pts=sp::spMake(1200+i,60); wake->_held[71+i].host=wake->_anchorHost+SPRationalToHost(sp::spMake(i,60)); }
        sp::SPScheduleOutput mid; mid.action=sp::SPScheduleAction::Interpolate; mid.frameA=71; mid.frameB=72; mid.pts=sp::spMake(2401,120); mid.phase=sp::spMake(1,2);
        [wake submitEventGroup:{mid} generation:1];
        BOOL queued=wake->_haveRifeDeferred && wake->_pending.size()==1;
        uint64_t rejected=wake->_engineSubmissionRejectedDrops, oldOutputs=wake->_syntheticOK;
        SPLiveJob *old=new SPLiveJob(); old->generation=1; old->configVersion=wake->_configVersion; old->clockEpoch=retiredClock; old->inflightEpoch=wake->_inflightEpoch;
        SPOwnedPixelBuffer *oldOutput=[[SPOwnedPixelBuffer alloc] initWithBufferNoCopy:CVPixelBufferRetain(frame)];
        [wake finishJob:old token:0 outputs:@[oldOutput] latency:0 error:nil];
        deferredRetiredWake=queued && !wake->_haveRifeDeferred && wake->_engineSubmissionRejectedDrops==rejected+1 &&
            wake->_syntheticOK==oldOutputs && wake->_clockRetiredModelOutputs==1 && wake->_pending.empty() &&
            wake->_held[71].pins==0 && wake->_held[72].pins==0;
    });
    [wake stop];
    SPLiveProcessor *nativeExit = [[SPLiveProcessor alloc] init];
    dispatch_sync(nativeExit->_q, ^{
        nativeExit->_request.interpolationEnabled=YES; nativeExit->_request.engineID=@"rife.metal"; nativeExit->_request.rateKind=SPLiveRateMultiplier;
        nativeExit->_request.multiplier=2; nativeExit->_request.displayRefreshHz=120; nativeExit->_sourceWidth=320; nativeExit->_sourceHeight=192;
        nativeExit->_width=320; nativeExit->_height=192; nativeExit->_rife=[[SPRifeBridge alloc] init]; nativeExit->_testCapturePlayout=YES;
        [nativeExit setRawCadenceRefreshHz:120 captureLimit:0 displayID:1];
        int64_t nowNs=SPHostToNs(SPHostNow());
        { std::lock_guard<std::mutex> lock(nativeExit->_rawCadenceMutex);
          for(int i=0;i<110;i++) nativeExit->_nativeCadence.observe((int64_t)i*1000000000/120,nowNs-910000000LL+(int64_t)i*1000000000/120,1,320,192); }
        int64_t now=SPHostNow();
        for(int i=0;i<2;i++) { nativeExit->_held[90+i].source=CVPixelBufferRetain(frame); nativeExit->_held[90+i].pts=sp::spMake(1200+i,120); nativeExit->_held[90+i].host=now+SPRationalToHost(sp::spMake(i,120)); }
        sp::SPScheduleOutput first; first.action=sp::SPScheduleAction::PresentSource; first.sourceIdentity=90; first.pts=sp::spMake(10,1);
        uint64_t priorClock=nativeExit->_clockEpoch;
        [nativeExit handleEvents:{first} generation:1];
        BOOL entered=nativeExit->_nativeBGRADirectActive && nativeExit->_nativeBGRADirectFrames==1 && nativeExit->_clockEpoch==priorClock+1 && !nativeExit->_testPlayout.empty();
        [nativeExit setRawCadenceRefreshHz:120 captureLimit:60 displayID:1]; nativeExit->_request.captureCapFPS=60;
        sp::SPScheduleOutput mid; mid.action=sp::SPScheduleAction::Interpolate; mid.frameA=90; mid.frameB=91; mid.pts=sp::spMake(2401,240); mid.phase=sp::spMake(1,2);
        uint64_t rejected=nativeExit->_engineSubmissionRejectedDrops;
        [nativeExit handleEvents:{mid} generation:1];
        nativeBGRARecovery=entered && !nativeExit->_nativeBGRADirectActive && !nativeExit->_nativeBudgetActive && nativeExit->_engineSubmissionRejectedDrops==rejected+1;
    });
    [nativeExit stop];
    SPLiveProcessor *stepped = [[SPLiveProcessor alloc] init];
    dispatch_sync(stepped->_q, ^{
        stepped->_request.interpolationEnabled=YES; stepped->_request.engineID=@"rife.metal"; stepped->_testCapturePlayout=YES;
        for (int i=0;i<3;i++) {
            sp::SPRational pts=i==0?sp::spMake(600,60):(i==1?sp::spMake(1201,120):sp::spMake(601,60));
            [stepped enqueueReadyEnhanced:CVPixelBufferRetain(frame) original:NULL pts:pts synthetic:i==1 held:NO captureHost:0 generation:1 deadlineHost:SPHostNow()];
            [stepped drainDue];
        }
        auto &v=stepped->_testPlayout;
        steppedPlayout=v.size()==3 && !v[0].second && v[1].second && !v[2].second && sp::spCmp(v[0].first,v[1].first)<0 && sp::spCmp(v[1].first,v[2].first)<0;
    });
    [stepped stop];
    SPLiveProcessor *t = [[SPLiveProcessor alloc] init];
    __block int64_t timelyStart=0, timelySecond=0, timelyDispatchStart=0, timelyDeadline=0, timelyReady=0;
    __block int64_t firstEnqueueStart=0, firstEnqueueEnd=0;
    __block NSMutableArray *timelyTrace=[NSMutableArray array];
    __block NSArray *timelyTimers=@[];
    __block uint64_t timelySourceMerge=0, timelySyntheticMerge=0;
    dispatch_sync(t->_q, ^{
        t->_request.interpolationEnabled=YES; t->_request.engineID=@"rife.metal"; t->_request.rateKind=SPLiveRateMultiplier; t->_request.multiplier=2;
        t->_testCapturePlayout=YES; t->_sourceWidth=320; t->_sourceHeight=192; t->_width=320; t->_height=192;
        int64_t warm=SPHostNow()-SPRationalToHost(sp::spMake(1,1));
        t->_held[20].source=CVPixelBufferRetain(frame); t->_held[20].pts=sp::spMake(9,1); t->_held[20].host=warm;
        [t enqueueSourceIdentity:20 pts:t->_held[20].pts host:warm generation:1 force:NO];
        [t clearPlaySlots]; t->_testPlayout.clear(); t->_haveLastPts=NO; t->_havePreviousSourcePts=NO;
        t->_haveAnchor=NO;
        t->_delayHost=SPRationalToHost(sp::spMake(9,100));
        for(int i=0;i<2;i++) { t->_held[21+i].source=CVPixelBufferRetain(frame); t->_held[21+i].pts=sp::spMake(600+i,60); }
    });
    timelyStart=SPHostNow();
    dispatch_async(t->_q, ^{
        firstEnqueueStart=SPHostNow();
        t->_held[21].host=timelyStart; t->_haveAnchor=YES; t->_anchorPts=sp::spMake(10,1); t->_anchorHost=timelyStart;
        [t enqueueSourceIdentity:21 pts:t->_held[21].pts host:timelyStart generation:1 force:NO];
        firstEnqueueEnd=SPHostNow();
    });
    int64_t waitEntry=SPHostNow();
    SPProbeSpinUntilHost(timelyStart+SPRationalToHost(sp::spMake(1,60)));
    timelySecond=SPHostNow();
    dispatch_sync(t->_q, ^{
        timelyDispatchStart=SPHostNow(); t->_held[22].host=timelySecond;
        [t observeSourceIdentity:22];
        SPPendingPhase phase; phase.pts=sp::spMake(1201,120); phase.targetHost=[t targetHostForPTS:phase.pts]; timelyDeadline=phase.targetHost; phase.generation=1; t->_pending.push_back(phase);
        [t enqueueSourceIdentity:22 pts:t->_held[22].pts host:t->_held[22].host generation:1 force:NO];
        timelyReady=SPHostNow();
        [t enqueueReadyEnhanced:CVPixelBufferRetain(frame) original:NULL pts:phase.pts synthetic:YES held:NO captureHost:timelySecond generation:1 deadlineHost:phase.targetHost];
    });
    usleep(220000);
    dispatch_sync(p->_q, ^{ pressureRecovery=!p->_testPlayout.empty() && p->_testPlayout.back().second && sp::spCmp(p->_testPlayout.back().first,sp::spMake(2417,240))==0; });
    dispatch_sync(t->_q, ^{
        auto &v=t->_testPlayout;
        for (const auto &item:v) [timelyTrace addObject:@{ @"ptsNum":@(item.first.num), @"ptsDen":@(item.first.den), @"synthetic":@(item.second) }];
        timelyTimers=[t->_testTimingTrace copy] ?: @[];
        timelySourceMerge=t->_sourceDueMergeDrops; timelySyntheticMerge=t->_dueMergeDrops;
        double sourceIntervalMs=(double)SPHostToNs(timelySecond-timelyStart)/1e6;
        timelyOrder=sourceIntervalMs>=15 && sourceIntervalMs<=22 && timelyReady<timelyDeadline && v.size()>=3 && !v[0].second && v[1].second && !v[2].second &&
            sp::spCmp(v[0].first,v[1].first)<0 && sp::spCmp(v[1].first,v[2].first)<0;
        bounded=bounded && t->_peakSlots<=[t slotCap]+1 && t->_slots.size()<=[t slotCap];
    });
    SPLiveProcessor *late = [[SPLiveProcessor alloc] init];
    dispatch_sync(late->_q, ^{
        late->_request.interpolationEnabled=YES; late->_request.engineID=@"rife.metal"; late->_testCapturePlayout=YES;
        int64_t past=SPHostNow()-SPRationalToHost(sp::spMake(1,1));
        late->_haveAnchor=YES; late->_anchorPts=sp::spMake(601,60); late->_anchorHost=past; late->_delayHost=0;
        late->_held[80].source=CVPixelBufferRetain(frame); late->_held[80].pts=sp::spMake(601,60); late->_held[80].host=past;
        [late enqueueSourceIdentity:80 pts:late->_held[80].pts host:past generation:1 force:NO];
        BOOL sourcePresented=!late->_testPlayout.empty() && !late->_testPlayout.back().second;
        uint64_t before=late->_staleReadyDrops;
        [late enqueueReadyEnhanced:CVPixelBufferRetain(frame) original:NULL pts:sp::spMake(1201,120) synthetic:YES held:NO captureHost:0 generation:1 deadlineHost:SPHostNow()];
        lateRejected=sourcePresented && late->_staleReadyDrops==before+1 && !late->_testPlayout.back().second;
    });
    [late stop];
    [t stop]; [d stop]; [p stop]; CVPixelBufferRelease(frame);
    BOOL ok=preEnable && epochPreserves && nativeCross && pressureSource && pressureRecovery && bounded && timelyOrder && lateRejected && sameContext && deferredAdmission && deferredCapacity && deferredExpiry && deferredClockReset && deferredGenerationReset && deferredSubmitFailure && poolRetry && deferredStale && independentNativeSources && captureLimitTransition && unconfiguredRequestPreserved && sourceChangeClears && previewGenerationGuard && coverOrderGuard && stopResumeGuard && deferredRetiredWake && nativeBGRARecovery && steppedPlayout;
    return @{ @"ok":@(ok), @"rawBeforeEnhancement":@(preEnable), @"measurementEpochPreservesRaw":@(epochPreserves),
        @"oldSlowAndNativeStillPresentSources":@(nativeCross), @"sixPoolPressureEventsStillPresentSources":@(pressureSource), @"syntheticResumesAfterPressure":@(pressureRecovery),
        @"queueBounded":@(bounded), @"timely60to120SourceMidpointSource":@(timelyOrder), @"lateMidpointRejected":@(lateRejected),
        @"deferredAdmittedAndPinned":@(deferredAdmission), @"deferredFullCapacityAccounted":@(deferredCapacity), @"deferredExpiryUnpins":@(deferredExpiry),
        @"deferredClockChangeUnpins":@(deferredClockReset), @"deferredGenerationChangeUnpins":@(deferredGenerationReset), @"deferredSubmissionFailureUnpins":@(deferredSubmitFailure),
        @"poolBusyUnexpiredRetryPreservesDeadline":@(poolRetry), @"deferredStaleCountedSeparately":@(deferredStale),
        @"distilAndLowNativeStillPresentSource":@(independentNativeSources), @"stalePlanRetainsCurrentCapAndRefresh":@(captureLimitTransition),
        @"unconfiguredEnvironmentPreservesRequest":@(unconfiguredRequestPreserved),
        @"sourceChangeReleasesOldBuffers":@(sourceChangeClears), @"oldGenerationCannotRevealCover":@(previewGenerationGuard),
        @"lateSameGenerationCoverCannotHidePresented":@(coverOrderGuard), @"stopResumeGenerationSafe":@(stopResumeGuard), @"retiredCompletionWakesCurrentDeferred":@(deferredRetiredWake),
        @"nativeBGRADirectExitAttemptsInterpolation":@(nativeBGRARecovery), @"steppedDrainSourceMidpointSource":@(steppedPlayout), @"steppedDrainScope":@"logic simulation with manually due production queue, not a real timer result",
        @"sourceDeliveryIntervalMs":@((double)SPHostToNs(timelySecond-timelyStart)/1e6),
        @"firstEnqueueDispatchWaitMs":@((double)SPHostToNs(firstEnqueueStart-timelyStart)/1e6),
        @"firstEnqueueDurationMs":@((double)SPHostToNs(firstEnqueueEnd-firstEnqueueStart)/1e6),
        @"waitEntryFromFirstMs":@((double)SPHostToNs(waitEntry-timelyStart)/1e6), @"waitDurationMs":@((double)SPHostToNs(timelySecond-waitEntry)/1e6),
        @"sourceDispatchWaitMs":@((double)SPHostToNs(timelyDispatchStart-timelySecond)/1e6),
        @"injectedReadyBeforeDeadlineMs":@((double)SPHostToNs(timelyDeadline-timelyReady)/1e6),
        @"playoutSequence":timelyTrace, @"timerTrace":timelyTimers, @"sourceDueMergeDrops":@(timelySourceMerge), @"syntheticDueMergeDrops":@(timelySyntheticMerge),
        @"rawSizeMismatchRejected":@(sameContext), @"scope":@"production processor and raw gate with synthetic buffers and simulated metadata; no actual capture, drawable or physical FPS" };
}

+ (NSDictionary<NSString *, id> *)runRejectedPTSContract {
    SPLiveProcessor *p = [[SPLiveProcessor alloc] init];
    dispatch_sync(p->_q, ^{
        p->_request.interpolationEnabled = YES; p->_request.engineID = @"apple.frc";
        p->_request.rateKind = SPLiveRateMultiplier; p->_request.multiplier = 2;
        p->_request.scaleEnabled = NO;
    });
    NSError *error = nil; BOOL prepared = [p installSynchronouslyWidth:320 height:192 error:&error];
    CVPixelBufferRef frame = SPCreateBuffer(320,192,kCVPixelFormatType_32BGRA);
    if (!prepared || !frame) { if(frame) CVPixelBufferRelease(frame); [p stop]; return @{ @"ok":@NO, @"error":error.localizedDescription ?: @"frame unavailable" }; }
    CVPixelBufferLockBaseAddress(frame,0); memset(CVPixelBufferGetBaseAddress(frame),64,CVPixelBufferGetBytesPerRow(frame)*192); CVPixelBufferUnlockBaseAddress(frame,0);
    [p pushPixelBuffer:frame ptsNum:1 ptsDen:60 host:SPHostNow() generation:1];
    __block uint64_t accepted = 0; dispatch_sync(p->_q, ^{ accepted=p->_previousSourceIdentity; });
    [p pushPixelBuffer:frame ptsNum:1 ptsDen:60 host:SPHostNow() generation:1];
    dispatch_sync(p->_q, ^{});
    [p pushPixelBuffer:frame ptsNum:0 ptsDen:60 host:SPHostNow() generation:1];
    __block BOOL retained = NO, pair = NO;
    dispatch_sync(p->_q, ^{ retained=accepted && p->_previousSourceIdentity==accepted && p->_held.find(accepted)!=p->_held.end() && p->_held.size()==1; });
    [p pushPixelBuffer:frame ptsNum:2 ptsDen:60 host:SPHostNow() generation:1];
    dispatch_sync(p->_q, ^{ pair=p->_previousSourceIdentity!=accepted && p->_submitted>0 && p->_syntheticFail==0; });
    [p stop]; CVPixelBufferRelease(frame);
    return @{ @"ok":@(retained && pair), @"acceptedSourceRetained":@(retained), @"nextLegalPairSubmitted":@(pair),
              @"scope":@"production pump and scheduler with duplicate/backwards PTS and real FRC submission; no drawable" };
}

+ (NSDictionary<NSString *, id> *)runPendingReplacementContract {
    SPLiveProcessor *p = [[SPLiveProcessor alloc] init];
    __block SPLiveJob *oldJob = nullptr;
    __block BOOL setup = NO, pendingCleared = NO, staleCleared = NO;
    dispatch_sync(p->_q, ^{
        p->_width = 64; p->_height = 64;
        for (uint64_t i = 1; i <= 4; ++i) {
            CVPixelBufferRef frame = SPCreateBuffer(64, 64, kCVPixelFormatType_32BGRA);
            if (!frame) return;
            p->_held[i].source = frame;
        }
        p->_nextIdentity = 5;
        p->_held[1].pins++; p->_held[2].pins++;
        oldJob = new SPLiveJob(); oldJob->frameA = 1; oldJob->frameB = 2;
        oldJob->configVersion = p->_configVersion; oldJob->generation = p->_sourceGeneration;
        oldJob->clockEpoch = p->_clockEpoch; oldJob->inflightEpoch = p->_inflightEpoch;
        oldJob->count = 1; p->_inflight = 1;
        sp::SPScheduleOutput pending; pending.frameA = 3; pending.frameB = 4;
        p->_rifePending.push_back(pending); p->_rifePendingGeneration = p->_sourceGeneration;
        p->_held[3].pins++; p->_held[4].pins++;
        setup = YES;
    });
    SPLivePlanRequest *request = [[SPLivePlanRequest alloc] init];
    request.engineID = @"apple.frc"; request.interpolationEnabled = NO;
    request.scaleEnabled = NO; request.rateKind = SPLiveRateMultiplier; request.multiplier = 2;
    [p updateRequest:request];
    dispatch_sync(p->_q, ^{
        pendingCleared = p->_rifePending.empty() && p->_configVersion != oldJob->configVersion;
        auto three = p->_held.find(3), four = p->_held.find(4);
        pendingCleared = pendingCleared && (three == p->_held.end() || three->second.pins == 0) &&
            (four == p->_held.end() || four->second.pins == 0);
        [p finishJob:oldJob token:0 outputs:@[] latency:0 error:nil];
        staleCleared = p->_held.find(1) == p->_held.end() && p->_held.find(2) == p->_held.end() && !p->_lastEnhanced;
    });
    [p stop];
    return @{ @"ok": @(setup && pendingCleared && staleCleared), @"setup": @(setup),
              @"pendingPinsReleased": @(pendingCleared), @"oldJobReleasedWithoutOutput": @(staleCleared),
              @"scope": @"production synchronous plan replacement and stale completion with simulated in-flight jobs; no real GPU consumer" };
}

// Exercises the real synchronous FRC setup and the production pump. The
// presentation callbacks below are injected metadata, not physical display.
+ (NSDictionary<NSString *, id> *)runSourceSizeLifecycleContract {
    SPLiveProcessor *p=[[SPLiveProcessor alloc] init];
    dispatch_sync(p->_q, ^{
        p->_request.interpolationEnabled=YES; p->_request.engineID=@"apple.frc";
        p->_request.rateKind=SPLiveRateMultiplier; p->_request.multiplier=2;
        p->_request.scaleEnabled=NO; p->_request.viewMode=SPLiveViewEnhanced;
    });
    NSError *error=nil; BOOL prepared=[p installSynchronouslyWidth:320 height:192 error:&error];
    CVPixelBufferRef first=SPCreateBuffer(320,192,kCVPixelFormatType_32BGRA);
    CVPixelBufferRef odd=SPCreateBuffer(321,192,kCVPixelFormatType_32BGRA);
    CVPixelBufferRef changed=SPCreateBuffer(322,192,kCVPixelFormatType_32BGRA);
    if (!prepared || !first || !odd || !changed) {
        if(first)CVPixelBufferRelease(first); if(odd)CVPixelBufferRelease(odd); if(changed)CVPixelBufferRelease(changed);
        [p stop]; return @{ @"ok":@NO, @"prepared":@(prepared), @"error":error.localizedDescription ?: @"synthetic buffer allocation failed" };
    }
    for (CVPixelBufferRef frame : {first,odd,changed}) {
        CVPixelBufferLockBaseAddress(frame,0);
        memset(CVPixelBufferGetBaseAddress(frame),64,CVPixelBufferGetBytesPerRow(frame)*CVPixelBufferGetHeight(frame));
        CVPixelBufferUnlockBaseAddress(frame,0);
    }
    __block SPFRCEngine *initialEngine=nil; __block uint64_t oldConfig=0,oldEpoch=0;
    __block BOOL initialRawUnknown=NO, firstKept=NO, firstGeometry=NO, oddChanged=NO, oddRebuilt=NO;
    __block BOOL staleRejected=NO, freshGeometry=NO, processedSizeChanged=NO;
    __block uint64_t oddConfig=0,oddEpoch=0, finalConfig=0,finalEpoch=0;
    dispatch_sync(p->_q, ^{ initialEngine=p->_engine; oldConfig=p->_configVersion; oldEpoch=p->_measurementEpoch;
        initialRawUnknown=p->_sourceWidth==0 && p->_sourceHeight==0 && initialEngine!=nil && p->_sessionReady; });
    [p pushPixelBuffer:first ptsNum:0 ptsDen:60 host:SPHostNow() generation:1];
    dispatch_sync(p->_q, ^{
        firstKept=p->_sourceWidth==320 && p->_sourceHeight==192 && p->_engine==initialEngine && p->_sessionReady &&
            p->_configVersion==oldConfig && p->_measurementEpoch==oldEpoch;
        p->_marks[9001].fpsEpoch=p->_fpsObservationEpoch;
        [p notePresented:@{ @"counts":@YES, @"generation":@1, @"configVersion":@(oldConfig), @"measurementEpoch":@(oldEpoch),
            @"endpoint":@"preview", @"windowVisible":@YES, @"occluded":@NO, @"exposed":@YES,
            @"presentedTime":@1.0, @"ptsNum":@0, @"ptsDen":@60, @"frameID":@9001, @"synthetic":@NO,
            @"width":@320, @"height":@192, @"drawableWidth":@640, @"drawableHeight":@384 }];
        NSDictionary *chain=[p sizeChainSnapshot];
        firstGeometry=[chain[@"sourceWidth"] intValue]==320 && [chain[@"drawableWidth"] intValue]==640;
    });
    [p pushPixelBuffer:odd ptsNum:1 ptsDen:60 host:SPHostNow() generation:1];
    dispatch_sync(p->_q, ^{
        oddConfig=p->_configVersion; oddEpoch=p->_measurementEpoch;
        oddChanged=p->_sourceWidth==321 && p->_sourceHeight==192 && p->_width==320 && p->_height==192 &&
            oddConfig==oldConfig+1 && oddEpoch==oldEpoch+1;
        oddRebuilt=p->_sessionReady && p->_engine && p->_engine!=initialEngine;
        NSDictionary *before=[p sizeChainSnapshot];
        [p notePresented:@{ @"counts":@YES, @"generation":@1, @"configVersion":@(oldConfig), @"measurementEpoch":@(oldEpoch),
            @"endpoint":@"preview", @"windowVisible":@YES, @"occluded":@NO, @"exposed":@YES,
            @"presentedTime":@2.0, @"ptsNum":@1, @"ptsDen":@60, @"frameID":@9002, @"synthetic":@NO,
            @"width":@320, @"height":@192, @"drawableWidth":@640, @"drawableHeight":@384 }];
        [p notePresented:@{ @"counts":@YES, @"generation":@1, @"configVersion":@(oddConfig), @"measurementEpoch":@(oldEpoch), @"endpoint":@"preview" }];
        [p notePresented:@{ @"counts":@YES, @"generation":@0, @"configVersion":@(oddConfig), @"measurementEpoch":@(oddEpoch), @"endpoint":@"preview" }];
        staleRejected=before.count==0 && [p sizeChainSnapshot].count==0 &&
            [p->_ignoredPresentedCallbacks[@"preview.configuration"] unsignedLongLongValue]>0 &&
            [p->_ignoredPresentedCallbacks[@"preview.epoch"] unsignedLongLongValue]>0 &&
            [p->_ignoredPresentedCallbacks[@"preview.generation"] unsignedLongLongValue]>0;
    });
    // A second genuine buffer gives the new scheduler its normal source pair.
    [p pushPixelBuffer:odd ptsNum:2 ptsDen:60 host:SPHostNow() generation:1];
    dispatch_sync(p->_q, ^{
        p->_marks[9003].fpsEpoch=p->_fpsObservationEpoch;
        [p notePresented:@{ @"counts":@YES, @"generation":@1, @"configVersion":@(oddConfig), @"measurementEpoch":@(oddEpoch),
            @"endpoint":@"preview", @"windowVisible":@YES, @"occluded":@NO, @"exposed":@YES,
            @"presentedTime":@3.0, @"ptsNum":@2, @"ptsDen":@60, @"frameID":@9003, @"synthetic":@NO,
            @"width":@320, @"height":@192, @"drawableWidth":@640, @"drawableHeight":@384 }];
        NSDictionary *chain=[p sizeChainSnapshot];
        freshGeometry=[chain[@"sourceWidth"] intValue]==321 && [chain[@"processingWidth"] intValue]==320 &&
            [chain[@"drawableWidth"] intValue]==640 && [chain[@"configVersion"] unsignedLongLongValue]==oddConfig;
        [p notePresented:@{ @"counts":@YES, @"generation":@1, @"configVersion":@(oldConfig), @"measurementEpoch":@(oldEpoch),
            @"endpoint":@"preview", @"windowVisible":@YES, @"occluded":@NO, @"exposed":@YES,
            @"presentedTime":@4.0, @"ptsNum":@3, @"ptsDen":@60, @"frameID":@9004, @"synthetic":@NO,
            @"width":@320, @"height":@192, @"drawableWidth":@800, @"drawableHeight":@600 }];
        NSDictionary *afterStale=[p sizeChainSnapshot];
        staleRejected=staleRejected && [afterStale[@"sourceWidth"] intValue]==321 && [afterStale[@"drawableWidth"] intValue]==640;
    });
    [p pushPixelBuffer:changed ptsNum:3 ptsDen:60 host:SPHostNow() generation:1];
    dispatch_sync(p->_q, ^{ finalConfig=p->_configVersion; finalEpoch=p->_measurementEpoch;
        processedSizeChanged=p->_sourceWidth==322 && p->_width==322 && finalConfig==oddConfig+1 && finalEpoch==oddEpoch+1 && p->_sessionReady && p->_engine!=nil; });
    [p stop]; CVPixelBufferRelease(first); CVPixelBufferRelease(odd); CVPixelBufferRelease(changed);
    BOOL ok=initialRawUnknown && firstKept && firstGeometry && oddChanged && oddRebuilt && staleRejected && freshGeometry && processedSizeChanged;
    return @{ @"ok":@(ok), @"prepared":@(prepared), @"initialRawUnknown":@(initialRawUnknown), @"firstMatchingInputKeptEngineAndEpoch":@(firstKept),
        @"initialGeometryCallbackAccepted":@(firstGeometry), @"oddRawChangeSameProcessingSizeIsolated":@(oddChanged), @"oddChangeRebuiltEngine":@(oddRebuilt),
        @"staleCallbackDidNotPolluteSizeChain":@(staleRejected), @"freshCallbackUsesNewRawSize":@(freshGeometry), @"processedSizeChangeIsolated":@(processedSizeChanged),
        @"initialConfig":@(oldConfig), @"initialEpoch":@(oldEpoch), @"oddConfig":@(oddConfig), @"oddEpoch":@(oddEpoch), @"finalConfig":@(finalConfig), @"finalEpoch":@(finalEpoch),
        @"scope":@"real FRC engine setup and production pump with 320x192, 321x192 and 322x192 synthetic BGRA buffers; injected presentation metadata, no window or physical display" };
}

+ (NSDictionary<NSString *, id> *)runOutputRepairContractWithBundle:(NSBundle *)bundle {
    // A real GPU command and a real RIFE inference, but no drawable/window.
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> queue = [device newCommandQueue];
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:8 height:8 mipmapped:NO];
    desc.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> texture = [device newTextureWithDescriptor:desc];
    id<MTLCommandBuffer> cmd = [queue commandBuffer];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    [[cmd renderCommandEncoderWithDescriptor:pass] endEncoding];
    [cmd commit]; [cmd waitUntilCompleted];
    BOOL gpuOK = cmd.status == MTLCommandBufferStatusCompleted;
    SPLiveProcessor *p = [[SPLiveProcessor alloc] init];
    __block SPLivePreviewView *output = nil;
    auto reveals = std::make_shared<std::atomic<int>>(0);
    dispatch_sync(dispatch_get_main_queue(), ^{
        output = [[SPLivePreviewView alloc] initWithFrame:NSMakeRect(0,0,320,192)];
        p.outputPreview = output;
        p.outputSurfaceHandler = ^(uint64_t generation, uint64_t config, uint64_t token) {
            if (generation == 1 && config == 7 && (token == 42 || token == 43)) reveals->fetch_add(1);
        };
        [p installPresentationHooks];
    });
    dispatch_sync(p->_q, ^{ p->_sourceGeneration=1; p->_configVersion=7; p->_measurementEpoch=9;
        p->_resolved.committed=YES; p->_resolved.scaleActive=YES; });
    [p awaitOutputSurfaceWithToken:42];
    dispatch_sync(p->_q, ^{});
    NSDictionary *(^readyInfo)(uint64_t,uint64_t,uint64_t,uint64_t,BOOL,BOOL) = ^NSDictionary *(uint64_t generation,uint64_t config,uint64_t epoch,uint64_t token,BOOL ok,BOOL visible) {
        return @{ @"generation":@(generation), @"configVersion":@(config), @"measurementEpoch":@(epoch),
            @"surfaceToken":@(token), @"counts":@YES, @"windowVisible":@(visible), @"gpuCompleted":@(ok) };
    };
    output.surfaceReady(readyInfo(0,7,9,42,YES,YES));
    output.surfaceReady(readyInfo(1,6,9,42,YES,YES));
    output.surfaceReady(readyInfo(1,7,8,42,YES,YES));
    output.surfaceReady(readyInfo(1,7,9,41,YES,YES));
    output.surfaceReady(readyInfo(1,7,9,42,NO,YES));
    output.surfaceReady(readyInfo(1,7,9,42,YES,NO));
    dispatch_sync(p->_q, ^{});
    BOOL rejectsStale = reveals->load()==0;
    output.surfaceReady(readyInfo(1,7,9,42,gpuOK,YES));
    for (int i=0;i<100 && reveals->load()==0;i++) usleep(10000);
    BOOL readyOnce = reveals->load()==1;
    output.surfaceReady(readyInfo(1,7,9,42,gpuOK,YES));
    dispatch_sync(p->_q, ^{});
    usleep(20000);
    readyOnce = readyOnce && reveals->load()==1;
    [p awaitOutputSurfaceWithToken:43 minimumCaptureHost:100];
    dispatch_sync(p->_q, ^{});
    NSMutableDictionary *oldCapture=[readyInfo(1,7,9,43,gpuOK,YES) mutableCopy]; oldCapture[@"captureHost"]=@99;
    output.surfaceReady(oldCapture);
    dispatch_sync(p->_q, ^{});
    usleep(20000);
    BOOL resumeFreshCapture=reveals->load()==1;
    NSMutableDictionary *newCapture=[readyInfo(1,7,9,43,gpuOK,YES) mutableCopy]; newCapture[@"captureHost"]=@100;
    output.surfaceReady(newCapture);
    for (int i=0;i<100 && reveals->load()==1;i++) usleep(10000);
    resumeFreshCapture = resumeFreshCapture && reveals->load()==2;
    dispatch_sync(p->_q, ^{ for (uint64_t id : {91ull,92ull,93ull}) p->_marks[id].fpsEpoch=p->_fpsObservationEpoch; });
    NSDictionary *(^presentInfo)(uint64_t,BOOL) = ^NSDictionary *(uint64_t id,BOOL exposed) {
        return @{ @"generation":@1, @"configVersion":@7, @"measurementEpoch":@9,
            @"counts":@YES, @"windowVisible":@YES, @"occluded":@NO, @"exposed":@(exposed),
            @"presentedTime":@1.0, @"ptsNum":@10, @"ptsDen":@1, @"frameID":@(id), @"synthetic":@YES };
    };
    output.presented(presentInfo(91,NO));
    dispatch_sync(p->_q, ^{});
    __block BOOL physicalGate=NO;
    dispatch_sync(p->_q, ^{ physicalGate=p->_epochPhysicalSynthetic==0; });
    output.presented(presentInfo(92,YES)); output.presented(presentInfo(93,YES));
    dispatch_sync(p->_q, ^{ physicalGate=physicalGate && p->_epochPhysicalSynthetic==1; });

    NSError *error=nil;
    SPRifeBridge *rife = [[SPRifeBridge alloc] initWithResourceBundle:bundle];
    int64_t rifePrepareStart=SPHostNow();
    BOOL prepared = [rife prepareModelID:@"rife-v4.26" quality:@"fast" width:320 height:192 error:&error];
    double rifePrepareMs=(double)SPHostToNs(SPHostNow()-rifePrepareStart)/1e6;
    SPSpatialScaler *scaler = [[SPSpatialScaler alloc] initWithDevice:device inputW:320 inputH:192 outputW:640 outputH:384 engine:SPLiveScaleLanczos error:&error];
    CVPixelBufferRef frame = SPCreateBuffer(320,192,kCVPixelFormatType_32BGRA);
    if (!prepared || !scaler || !frame) { [p stop]; if(frame) CVPixelBufferRelease(frame); return @{ @"ok":@NO, @"reason":error.localizedDescription ?: @"prepare" }; }
    CVPixelBufferLockBaseAddress(frame,0);
    memset(CVPixelBufferGetBaseAddress(frame), 64, CVPixelBufferGetBytesPerRow(frame)*192);
    CVPixelBufferUnlockBaseAddress(frame,0);
    __block BOOL sourceProgress=NO, bounded=NO, noPendingPair=NO;
    int64_t past=SPHostNow()-SPRationalToHost(sp::spMake(1,1));
    dispatch_sync(p->_q, ^{
        p->_rife=rife; p->_scaler=scaler; p->_request.interpolationEnabled=YES;
        p->_request.engineID=@"rife.metal"; p->_request.scaleEnabled=YES;
        p->_rifeSlowMode=YES;
        p->_sessionReady=YES; p->_resolved.interpolationActive=YES; p->_resolved.scaleActive=YES;
        for (int i=0;i<4;i++) { p->_held[11+i].source=CVPixelBufferRetain(frame); p->_held[11+i].pts=sp::spMake(300+i,30); p->_held[11+i].host=past; }
        [p enqueueSourceIdentity:11 pts:sp::spMake(10,1) host:past generation:1 force:NO];
        sp::SPScheduleOutput a; a.action=sp::SPScheduleAction::Interpolate; a.frameA=11; a.frameB=12; a.pts=sp::spMake(601,60); a.phase=sp::spMake(1,2);
        [p submitEventGroup:{a} generation:1];
        [p enqueueSourceIdentity:12 pts:sp::spMake(301,30) host:past generation:1 force:NO];
        sourceProgress=p->_lastEnhanced && sp::spCmp(p->_lastRedrawPts,sp::spMake(301,30))==0;
        auto b=a; b.frameA=12; b.frameB=13; b.pts=sp::spMake(603,60); [p submitEventGroup:{b} generation:1];
        auto c=a; c.frameA=13; c.frameB=14; c.pts=sp::spMake(605,60); [p submitEventGroup:{c} generation:1];
        bounded=p->_inflight<=2;
        noPendingPair=p->_rifePending.empty();
    });
    __block BOOL actualOutput=NO, correctSize=NO;
    for(int i=0;i<500 && !actualOutput;i++) { usleep(10000); dispatch_sync(p->_q, ^{
        actualOutput=p->_syntheticOK>=1;
        correctSize=p->_lastEnhanced && CVPixelBufferGetWidth(p->_lastEnhanced)==640 && CVPixelBufferGetHeight(p->_lastEnhanced)==384;
    }); }
    // Fast-mode scheduling must retain source, midpoint and next source in
    // their actual PTS order; no drawable or physical-FPS claim is made here.
    SPLiveProcessor *fast=[[SPLiveProcessor alloc] init];
    __block int64_t fastSourceStart=0; NSMutableArray *fastInputTrace=[NSMutableArray array];
    dispatch_sync(fast->_q, ^{
        fast->_sourceGeneration=1; fast->_configVersion=1; fast->_request.interpolationEnabled=YES;
        fast->_request.engineID=@"rife.metal"; fast->_request.rateKind=SPLiveRateMultiplier; fast->_request.multiplier=2;
        fast->_rifeSlowMode=NO; fast->_testCapturePlayout=YES;
        fast->_rife=rife; fast->_sessionReady=YES; fast->_resolved.interpolationActive=YES;
        int64_t now=SPHostNow(); fastSourceStart=now;
        fast->_held[31].source=CVPixelBufferRetain(frame); fast->_held[31].pts=sp::spMake(10,1); fast->_held[31].host=now;
        fast->_held[32].source=CVPixelBufferRetain(frame); fast->_held[32].pts=sp::spMake(301,30); fast->_held[32].host=now+SPRationalToHost(sp::spMake(1,30));
        fast->_haveAnchor=YES; fast->_anchorPts=sp::spMake(10,1);
        fast->_anchorHost=now;
        fast->_haveInterval=YES; fast->_intervalHost=SPRationalToHost(sp::spMake(1,30));
        fast->_frcEwmaSec=0.001; fast->_scaleEwmaSec=0.001; fast->_delayHost=SPRationalToHost(sp::spMake(9,100));
        [fast enqueueSourceIdentity:31 pts:sp::spMake(10,1) host:now generation:1 force:NO];
    });
    // The second source arrives at the actual 30 fps interval; a future
    // captured frame must not be delivered to the processor early.
    usleep(33333);
    int64_t fastBHost=SPHostNow();
    dispatch_sync(fast->_q, ^{
        fast->_held[32].host=fastBHost;
        [fastInputTrace addObject:@{ @"frame":@1, @"actualFromStartMs":@((double)SPHostToNs(fastBHost-fastSourceStart)/1e6),
            @"plannedFromStartMs":@(1000.0/30.0), @"dispatchWaitMs":@((double)SPHostToNs(SPHostNow()-fastBHost)/1e6) }];
        sp::SPScheduleOutput midpoint; midpoint.action=sp::SPScheduleAction::Interpolate; midpoint.frameA=31; midpoint.frameB=32;
        midpoint.pts=sp::spMake(601,60); midpoint.phase=sp::spMake(1,2);
        [fast submitEventGroup:{midpoint} generation:1];
        [fast enqueueSourceIdentity:32 pts:sp::spMake(301,30) host:fast->_held[32].host generation:1 force:NO];
    });
    for (int step=1;step<=4;step++) {
        usleep(33333);
        int64_t inputHost=SPHostNow();
        dispatch_sync(fast->_q, ^{
            uint64_t a=31+step, b=32+step;
            int64_t now=inputHost;
            [fastInputTrace addObject:@{ @"frame":@(step+1), @"actualFromStartMs":@((double)SPHostToNs(now-fastSourceStart)/1e6),
                @"plannedFromStartMs":@((step+1)*1000.0/30.0), @"dispatchWaitMs":@((double)SPHostToNs(SPHostNow()-inputHost)/1e6) }];
            fast->_held[b].source=CVPixelBufferRetain(frame);
            fast->_held[b].pts=sp::spMake(301+step,30); fast->_held[b].host=now;
            sp::SPScheduleOutput midpoint; midpoint.action=sp::SPScheduleAction::Interpolate; midpoint.frameA=a; midpoint.frameB=b;
            midpoint.pts=sp::spMake(601+step*2,60); midpoint.phase=sp::spMake(1,2);
            [fast submitEventGroup:{midpoint} generation:1];
            [fast enqueueSourceIdentity:b pts:sp::spMake(301+step,30) host:now generation:1 force:NO];
        });
    }
    usleep(300000);
    __block BOOL fastOrder=NO;
    __block NSMutableArray *fastTrace=[NSMutableArray array];
    __block double fastModelEwma=0; __block BOOL fastClamped=NO, fastSlowMode=NO;
    __block NSArray *fastTimingTrace=@[], *fastPendingTrace=@[];
    for(int i=0;i<100 && !fastOrder;i++) { usleep(10000); dispatch_sync(fast->_q, ^{
        const auto &v=fast->_testPlayout;
        fastModelEwma=fast->_frcEwmaSec; fastClamped=fast->_delayClamped; fastSlowMode=fast->_rifeSlowMode;
        fastTimingTrace=[fast->_testTimingTrace copy] ?: @[]; fastPendingTrace=[fast->_testPendingTrace copy] ?: @[];
        [fastTrace removeAllObjects];
        for (const auto &item : v) [fastTrace addObject:@{ @"num":@(item.first.num), @"den":@(item.first.den), @"synthetic":@(item.second) }];
        int sources=0, synthetic=0; bool ordered=true;
        for(size_t j=0;j<v.size();j++) { if(v[j].second) synthetic++; else sources++;
            if(j && sp::spCmp(v[j-1].first,v[j].first)>=0) ordered=false; }
        fastOrder=ordered && sources>=2 && synthetic>=2 && !fast->_rifeSlowMode && fast->_syntheticOK>=2;
    }); }
    __block BOOL clampedSourceContinues=NO;
    __block NSDictionary *clampDiagnostics=@{};
    dispatch_sync(fast->_q, ^{
        SPLiveJob *late=new SPLiveJob(); late->generation=1; late->configVersion=1; late->inflightEpoch=0;
        late->count=1; late->pts[0]=sp::spMake(700,60); late->clockEpoch=fast->_clockEpoch; fast->_frcEwmaSec=0.08;
        SPOwnedPixelBuffer *box=[[SPOwnedPixelBuffer alloc] initWithBufferNoCopy:CVPixelBufferRetain(frame)];
        [fast finishJob:late token:0 outputs:@[box] latency:0.5 error:nil];
        // This fixture jumps the anchor far into the past. Retire the old
        // timeline first, as the production re-anchor path does, so a newer
        // source cannot acquire an earlier deadline behind an old slot.
        [fast retireClockTimeline];
        fast->_haveAnchor=YES; fast->_anchorPts=sp::spMake(12,1);
        fast->_anchorHost=SPHostNow()-SPRationalToHost(sp::spMake(1,1));
        fast->_held[100].source=CVPixelBufferRetain(frame); fast->_held[100].pts=sp::spMake(12,1); fast->_held[100].host=fast->_anchorHost;
        BOOL beforeClamp=fast->_delayClamped, beforeSlow=fast->_rifeSlowMode;
        uint64_t beforeStale=fast->_sourceStaleDrops, beforePolicy=fast->_sourcePolicyDrops, beforeMissing=fast->_sourceMissingDrops, beforeConversion=fast->_sourceConversionDrops;
        size_t beforeSlots=fast->_slots.size(), beforePending=fast->_pending.size();
        [fast enqueueSourceIdentity:100 pts:fast->_held[100].pts host:fast->_held[100].host generation:1 force:NO];
        clampedSourceContinues=fast->_delayClamped && !fast->_rifeSlowMode && fast->_haveLastPts && sp::spCmp(fast->_lastPresentedPts,sp::spMake(12,1))==0;
        clampDiagnostics=@{ @"delayClampedBeforeSource":@(beforeClamp), @"delayClampedAfterSource":@(fast->_delayClamped),
            @"timeClamped":@(fast->_delayTimeClamped), @"byteClamped":@(fast->_delayByteClamped), @"slowBeforeSource":@(beforeSlow), @"slowAfterSource":@(fast->_rifeSlowMode),
            @"haveLastPTS":@(fast->_haveLastPts), @"lastPTSNum":@(fast->_lastPresentedPts.num), @"lastPTSDen":@(fast->_lastPresentedPts.den),
            @"slotsBefore":@(beforeSlots), @"slotsAfter":@(fast->_slots.size()), @"pendingBefore":@(beforePending), @"pendingAfter":@(fast->_pending.size()),
            @"sourceStaleDelta":@(fast->_sourceStaleDrops-beforeStale), @"sourcePolicyDelta":@(fast->_sourcePolicyDrops-beforePolicy),
            @"sourceMissingDelta":@(fast->_sourceMissingDrops-beforeMissing), @"sourceConversionDelta":@(fast->_sourceConversionDrops-beforeConversion),
            @"targetMinusNowMs":@((double)SPHostToNs([fast targetHostForPTS:sp::spMake(12,1)]-SPHostNow())/1e6) };
    });
    [fast stop];
    [p adoptSourceGeneration:2];
    __block BOOL staleJobRejected=NO;
    dispatch_sync(p->_q, ^{
        SPLiveJob *stale=new SPLiveJob(); stale->generation=1; stale->configVersion=7; stale->inflightEpoch=0;
        stale->count=1; stale->pts[0]=sp::spMake(607,60);
        p->_rifeSlowMode=NO; p->_frcEwmaSec=0.01;
        size_t previousSamples=p->_frcNs.size();
        SPPendingPhase current; current.pts=stale->pts[0]; current.generation=2; p->_pending.push_back(current);
        SPOwnedPixelBuffer *box=[[SPOwnedPixelBuffer alloc] initWithBufferNoCopy:CVPixelBufferRetain(frame)];
        [p finishJob:stale token:0 outputs:@[box] latency:0.7 error:nil];
        staleJobRejected=p->_sourceGeneration==2 && !p->_lastEnhanced && p->_rifePending.empty() &&
            !p->_rifeSlowMode && p->_frcEwmaSec==0.01 && p->_frcNs.size()==previousSamples && p->_pending.size()==1;
    });
    SPLiveProcessor *frc=[[SPLiveProcessor alloc] init];
    dispatch_sync(frc->_q, ^{ frc->_request.interpolationEnabled=YES; frc->_request.engineID=@"apple.frc";
        frc->_request.rateKind=SPLiveRateMultiplier; frc->_request.multiplier=2; frc->_request.fpsNumerator=60; frc->_request.fpsDenominator=1;
        frc->_request.captureCapFPS=60; frc->_request.displayRefreshHz=120; frc->_sourceGeneration=1; frc->_testCapturePlayout=YES; });
    NSError *frcError=nil;
    int64_t frcPrepareStart=SPHostNow();
    BOOL frcPrepared=[frc installSynchronouslyWidth:320 height:192 error:&frcError];
    double frcPrepareMs=(double)SPHostToNs(SPHostNow()-frcPrepareStart)/1e6;
    int64_t frcStart=SPHostNow(), frcLast=frcStart;
    NSMutableArray *frcInputTrace=[NSMutableArray array];
    const double frcPeriodMs=1000.0/60.0, frcMaxLatenessMs=frcPeriodMs/2.0;
    double frcMaxObservedLatenessMs=0, frcMinIntervalMs=DBL_MAX, frcMaxIntervalMs=0;
    int frcPacingViolations=0;
    if (frcPrepared) for(int i=0;i<30;i++) {
        int64_t planned=frcStart+SPRationalToHost(sp::spMake(i,60));
        SPProbeSpinUntilHost(planned);
        int64_t previous=frcLast; frcLast=SPHostNow();
        double lateMs=(double)SPHostToNs(frcLast-planned)/1e6;
        frcMaxObservedLatenessMs=std::max(frcMaxObservedLatenessMs,lateMs);
        if (lateMs > frcMaxLatenessMs) frcPacingViolations++;
        if (i>0) {
            double intervalMs=(double)SPHostToNs(frcLast-previous)/1e6;
            frcMinIntervalMs=std::min(frcMinIntervalMs,intervalMs);
            frcMaxIntervalMs=std::max(frcMaxIntervalMs,intervalMs);
            if (intervalMs < frcPeriodMs/2.0 || intervalMs > frcPeriodMs*1.5) frcPacingViolations++;
        }
        [frc pushPixelBuffer:frame ptsNum:i ptsDen:60 host:frcLast generation:1];
        int64_t pushed=SPHostNow();
        [frcInputTrace addObject:@{ @"frame":@(i), @"plannedFromStartMs":@((double)SPHostToNs(planned-frcStart)/1e6),
            @"actualFromStartMs":@((double)SPHostToNs(frcLast-frcStart)/1e6), @"pushDurationMs":@((double)SPHostToNs(pushed-frcLast)/1e6) }];
    }
    BOOL frcInputPacingValid=frcPrepared && frcInputTrace.count==30 && frcPacingViolations==0;
    usleep(300000);
    __block int frcSources=0,frcSynthetic=0; __block BOOL frcOrdered=YES, frcRateIdentity=NO, frcMidpoints=YES;
    __block NSDictionary *frcDiagnostics=@{};
    dispatch_sync(frc->_q, ^{
        const auto &v=frc->_testPlayout;
        for(size_t i=0;i<v.size();i++) { if(v[i].second) {
                frcSynthetic++; __int128 ticks=(__int128)v[i].first.num*120;
                if(v[i].first.den<=0 || ticks%v[i].first.den!=0 || ((ticks/v[i].first.den)&1)==0) frcMidpoints=NO;
            } else frcSources++;
            if(i && sp::spCmp(v[i-1].first,v[i].first)>=0) frcOrdered=NO; }
        NSDictionary *stats=[frc currentStats];
        frcRateIdentity=[stats[@"rateKind"] isEqual:@"multiplier"] && [stats[@"rateMultiplier"] intValue]==2 &&
            [stats[@"captureCapFPS"] intValue]==60 && [stats[@"displayRefreshHz"] intValue]==120;
        frcDiagnostics=@{ @"inputHzObserved":@(frcPrepared && frcLast>frcStart ? (29)*1e9/(double)SPHostToNs(frcLast-frcStart) : 0),
            @"inputPacingValid":@(frcInputPacingValid), @"inputPacingViolations":@(frcPacingViolations),
            @"inputPacingMaxLatenessMs":@(frcMaxLatenessMs), @"inputPacingMaxObservedLatenessMs":@(frcMaxObservedLatenessMs),
            @"inputPacingMinIntervalMs":@(frcMinIntervalMs==DBL_MAX ? 0 : frcMinIntervalMs), @"inputPacingMaxIntervalMs":@(frcMaxIntervalMs),
            @"inputPacingAllowedIntervalMs":@[ @(frcPeriodMs/2.0), @(frcPeriodMs*1.5) ],
            @"scheduled":stats[@"scheduledSynthetic"], @"submitted":stats[@"submitted"],
            @"modelOutputs":stats[@"syntheticOK"], @"modelFailures":stats[@"syntheticFail"],
            @"engineUnavailableDropsLifetime":stats[@"engineUnavailableDropsLifetime"], @"inflightLimitDropsLifetime":stats[@"inflightLimitDropsLifetime"],
            @"engineSubmissionRejectedDropsLifetime":stats[@"engineSubmissionRejectedDropsLifetime"],
            @"clockRetiredJobsLifetime":stats[@"clockRetiredJobsLifetime"], @"clockRetiredModelOutputsLifetime":stats[@"clockRetiredModelOutputsLifetime"],
            @"clockRetiredPhaseDropsLifetime":stats[@"clockRetiredPhaseDropsLifetime"],
            @"deadlineDrops":stats[@"deadlineDrops"], @"queueDrops":stats[@"queueDrops"],
            @"delayClamped":stats[@"delayClamped"], @"frcP95ms":stats[@"frcP95ms"],
            @"frcEwmaMs":stats[@"frcEwmaMs"], @"delayMs":stats[@"delayMs"],
            @"lateReadyDrops":stats[@"lateReadyDrops"], @"staleReadyDrops":stats[@"staleReadyDrops"],
            @"dueMergeDrops":stats[@"dueMergeDrops"], @"pendingExpiredDrops":stats[@"pendingExpiredDrops"],
            @"slotEvictionDrops":stats[@"slotEvictionDrops"], @"captureToModelReadyP95ms":stats[@"captureToModelReadyP95ms"],
            @"captureToOutputReadyP95ms":stats[@"captureToOutputReadyP95ms"], @"transferP95ms":stats[@"transferP95ms"],
            @"pendingTrace":frc->_testPendingTrace ?: @[], @"timingTrace":frc->_testTimingTrace ?: @[],
            @"initialPrepareMs":@(frcPrepareMs), @"inputTrace":frcInputTrace, @"scope":@"FRC 320x192 real buffers, setup and monotonic host clock instrumentation; not physical display",
            @"peakSlots":stats[@"peakSlots"], @"slotCap":stats[@"slotCap"] };
    });
    [frc stop]; CVPixelBufferRelease(frame); [p stop];
    BOOL frcSmoke=frcPrepared && frcInputPacingValid && frcSources>0 && frcSynthetic>0 && frcOrdered && frcRateIdentity && frcMidpoints;
    SPLiveProcessor *rateCheck=[[SPLiveProcessor alloc] init]; __block BOOL activeTarget=NO;
    dispatch_sync(rateCheck->_q, ^{
        auto *q=rateCheck; int64_t now=(int64_t)(CACurrentMediaTime()*1e9);
        q->_request.interpolationEnabled=YES; q->_request.rateKind=SPLiveRateMultiplier; q->_request.multiplier=2;
        q->_request.captureCapFPS=30; q->_request.displayRefreshHz=60;
        q->_fpsMeter.input(0,now-17000000); q->_fpsMeter.input(16666667,now-1);
        q->_resolved.committed=NO; q->_resolved.interpolationActive=YES;
        BOOL pendingHidden=[[q currentStats][@"estimatedRequestedFPS"] doubleValue] < 0;
        q->_resolved.committed=YES;
        double x2=[[q currentStats][@"estimatedRequestedFPS"] doubleValue];
        q->_request.rateKind=SPLiveRateFixedFPS; q->_request.fpsNumerator=60; q->_request.fpsDenominator=1;
        double fixed=[[q currentStats][@"estimatedRequestedFPS"] doubleValue];
        activeTarget=pendingHidden && x2>119 && x2<121 && fixed==60;
    });
    [rateCheck stop];
    BOOL ok=gpuOK && rejectsStale && readyOnce && resumeFreshCapture && physicalGate && prepared && sourceProgress && bounded && noPendingPair && actualOutput && correctSize && fastOrder && staleJobRejected && clampedSourceContinues && frcSmoke && activeTarget;
    return @{ @"ok":@(ok), @"gpuCommandCompleted":@(gpuOK), @"warmupStaleFailedHiddenRejected":@(rejectsStale),
        @"warmupAcceptedOnce":@(readyOnce), @"warmupRejectsPreResumeCapture":@(resumeFreshCapture), @"physicalFPSExcludesWarmAndDuplicates":@(physicalGate), @"realRifePrepared":@(prepared), @"sourceContinuesDespiteOldSlow":@(sourceProgress),
        @"atMostTwoInflight":@(bounded), @"noSlowPendingPair":@(noPendingPair), @"actualRifeCompleted":@(actualOutput),
        @"lanczosOutputSize":@(correctSize), @"fast30to60OrderedSourceAndSynthetic":@(fastOrder), @"fastPlayout":fastTrace,
        @"fastModelEwmaMs":@(fastModelEwma*1000), @"fastDelayClamped":@(fastClamped), @"fastSlowMode":@(fastSlowMode),
        @"fastDiagnostics":@{ @"rifePrepareMs":@(rifePrepareMs), @"input":@"same synthetic 320x192 BGRA frame; manually submitted source and midpoint events at 30 fps", @"manualAnchor":@YES,
            @"pendingTrace":fastPendingTrace, @"timingTrace":fastTimingTrace, @"inputTrace":fastInputTrace, @"scope":@"test-only instrumentation; RIFE inference and scheduling, no physical display" },
        @"budgetClampSourceContinues":@(clampedSourceContinues), @"budgetClampDiagnostics":clampDiagnostics, @"staleGenerationJobRejected":@(staleJobRejected),
        @"frc60to120ProductionSmoke":@(frcSmoke), @"frcInputPacingValid":@(frcInputPacingValid), @"frcSourceOutputs":@(frcSources), @"frcSyntheticOutputs":@(frcSynthetic), @"frcMidpointsOn120Grid":@(frcMidpoints), @"frcDiagnostics":frcDiagnostics, @"frcError":frcError.localizedDescription ?: @"", @"activeTargetExcludesPendingAndCap":@(activeTarget),
        @"scope":@"offscreen GPU command, simulated warmup callback metadata, fast production queue and real slow RIFE/Lanczos scheduling; no window, drawable, physical presentation or GUI" };
}

+ (NSDictionary<NSString *, id> *)runFixedRateModelProbeWithBundle:(NSBundle *)bundle {
    NSDictionary<NSString *, NSString *> *environment=NSProcessInfo.processInfo.environment;
    if ([environment[@"ODF_AIR_CADENCE_DIAGNOSTIC"] isEqualToString:@"1"]) {
        auto option=[&](NSString *key, int fallback, int minimum, int maximum) {
            NSString *text=environment[key]; long long value=0;
            NSScanner *scanner=text ? [NSScanner scannerWithString:text] : nil;
            if (!scanner || ![scanner scanLongLong:&value] || !scanner.isAtEnd) return fallback;
            return (int)MAX((long long)minimum,MIN((long long)maximum,value));
        };
        const int width=option(@"ODF_AIR_CADENCE_WIDTH",2648,128,4096)&~1;
        const int height=option(@"ODF_AIR_CADENCE_HEIGHT",1668,128,4096)&~1;
        const int seconds=option(@"ODF_AIR_CADENCE_SECONDS",24,5,60);
        const int warmup=MIN(seconds-1,option(@"ODF_AIR_CADENCE_WARMUP_SECONDS",3,1,5));
        const int refresh=option(@"ODF_AIR_CADENCE_DISPLAY_HZ",60,30,240);
        const int inputRate=30,count=inputRate*seconds;
        NSString *scope=@"logical offscreen playout; no SCK, drawable, physical display, or quality acceptance";
        NSMutableArray<SPOwnedPixelBuffer *> *inputs=[NSMutableArray array];
        const uint8_t levels[]={48,64,80,96,80,64};
        for (int i=0;i<6;i++) {
            CVPixelBufferRef frame=SPCreateBuffer(width,height,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
            if (!frame) return @{ @"ok":@NO,@"executionOK":@NO,@"error":@"input allocation",@"scope":scope };
            CVPixelBufferLockBaseAddress(frame,0);
            for (size_t plane=0;plane<CVPixelBufferGetPlaneCount(frame);plane++)
                memset(CVPixelBufferGetBaseAddressOfPlane(frame,plane),plane?128:levels[i],
                    CVPixelBufferGetBytesPerRowOfPlane(frame,plane)*CVPixelBufferGetHeightOfPlane(frame,plane));
            CVPixelBufferUnlockBaseAddress(frame,0);
            [inputs addObject:[[SPOwnedPixelBuffer alloc] initWithBufferNoCopy:frame]];
        }
        SPRifeBridge *rife=[[SPRifeBridge alloc] initWithResourceBundle:bundle]; rife.liveStreamEnabled=YES;
        NSError *error=nil;
        if (![rife prepareModelID:@"rife-v4.25" quality:@"fast" width:width height:height error:&error])
            return @{ @"ok":@NO,@"executionOK":@NO,@"error":error.localizedDescription?:@"RIFE setup",@"scope":scope };
        NSDictionary *prepared=[rife streamDiagnostics];
        NSString *experiment=prepared[@"experimentModel"];
        if ((experiment && ![experiment isEqualToString:@"original"]) ||
            [prepared[@"experimentIO"] boolValue] || [prepared[@"experimentReplaceMask"] boolValue]) {
            [rife invalidate];
            return @{ @"ok":@NO,@"executionOK":@NO,@"error":@"Use an original-model resource bundle without active experiment overrides; preferences were not changed.",
                @"preparedStreamDiagnostics":prepared,@"scope":scope };
        }
        SPLiveProcessor *p=[[SPLiveProcessor alloc] init];
        dispatch_sync(p->_q, ^{
            p->_request.interpolationEnabled=YES; p->_request.engineID=@"rife.metal"; p->_request.modelID=@"rife-v4.25"; p->_request.qualityID=@"fast";
            p->_request.quality=SPFRCQualityNormal; p->_request.scaleEnabled=NO;
            p->_request.rifeStreamEnabled=YES; p->_request.rateKind=SPLiveRateMultiplier;
            p->_request.multiplier=2; p->_request.captureCapFPS=0; p->_request.displayRefreshHz=refresh;
            p->_width=width; p->_height=height; p->_resolved.outputWidth=width; p->_resolved.outputHeight=height;
            p->_resolved.committed=YES; p->_resolved.interpolationActive=YES; p->_sessionReady=YES; p->_rife=rife; p->_testCapturePlayout=YES;
            [p resetSchedulerOnQueue]; [p refreshResolvedOnQueue];
        });
        const int64_t start=SPHostNow(); int64_t first=0,last=0;
        NSMutableArray<NSDictionary *> *timeline=[NSMutableArray array];
        __block int64_t previousHost=start;
        __block uint64_t previousSource=0,previousSynthetic=0,previousHolds=0,previousEpoch=0,previousConfig=0;
        __block BOOL haveSnapshot=NO;
        // These test vectors are lifetime logical counts, independent of the
        // production measurement epochs. Production stats remain raw snapshots.
        void (^sample)(NSString *)=^(NSString *kind) {
            const int64_t host=SPHostNow();
            uint64_t source=0,synthetic=0,holds=p->_testHoldPlayout.size();
            for (const auto &entry:p->_testPlayout) { if (entry.second) synthetic++; else source++; }
            const double elapsed=(double)SPHostToNs(host-start)/1e9;
            const double previousElapsed=(double)SPHostToNs(previousHost-start)/1e9;
            const double interval=(double)SPHostToNs(host-previousHost)/1e9;
            const BOOL reset=source<previousSource || synthetic<previousSynthetic || holds<previousHolds || holds>source;
            const BOOL valid=haveSnapshot && !reset && interval>0;
            const uint64_t sourceDelta=reset?0:source-previousSource,syntheticDelta=reset?0:synthetic-previousSynthetic,holdDelta=reset?0:holds-previousHolds;
            const BOOL validUnique=valid && sourceDelta>=holdDelta;
            const BOOL completeSecond=[kind isEqualToString:@"second"] && interval>=0.9 && interval<=1.1;
            NSDictionary *stats=[p currentStats];
            [timeline addObject:@{ @"kind":kind,@"host":@(host),@"hostElapsedSeconds":@(elapsed),@"intervalStartSeconds":@(previousElapsed),@"intervalSeconds":@(interval),
                @"completeHostSecond":@(completeSecond),@"measurementWindow":@(completeSecond && previousElapsed>=warmup && elapsed<=seconds),
                @"logicalSourceSlotsTotal":@(source),@"logicalSyntheticTotal":@(synthetic),@"logicalHoldTotal":@(holds),@"logicalSlotTotal":@(source+synthetic),
                @"logicalCounterReset":@(reset),@"sourceSlotDelta":valid?@(sourceDelta):(id)NSNull.null,
                @"syntheticDelta":valid?@(syntheticDelta):(id)NSNull.null,@"holdDelta":valid?@(holdDelta):(id)NSNull.null,
                @"logicalUniqueFPS":validUnique?@((sourceDelta-holdDelta+syntheticDelta)/interval):(id)NSNull.null,
                @"logicalSlotFPS":valid?@((sourceDelta+syntheticDelta)/interval):(id)NSNull.null,
                @"configVersion":@(p->_configVersion),@"measurementEpoch":@(p->_measurementEpoch),
                @"epochChanged":@(haveSnapshot && previousEpoch!=p->_measurementEpoch),@"configChanged":@(haveSnapshot && previousConfig!=p->_configVersion),
                @"stats":stats }];
            previousHost=host; previousSource=source; previousSynthetic=synthetic; previousHolds=holds;
            previousEpoch=p->_measurementEpoch; previousConfig=p->_configVersion; haveSnapshot=YES;
        };
        dispatch_sync(p->_q, ^{ sample(@"initial"); });
        dispatch_source_t sampler=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,p->_q);
        dispatch_source_set_timer(sampler,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),NSEC_PER_SEC,NSEC_PER_MSEC);
        dispatch_source_set_event_handler(sampler, ^{ sample(@"second"); });
        dispatch_resume(sampler);
        for (int i=0;i<count;i++) {
            const int64_t ptsNs=(int64_t)i*1000000000/inputRate+(i?llround(1800000*sin(i*1.731)):0);
            SPProbeSpinUntilHost(start+SPRationalToHost(sp::spMake(ptsNs,1000000000)));
            const int64_t host=SPHostNow(); if (!i) first=host; last=host;
            [p pushPixelBuffer:inputs[i%6].buffer ptsNum:ptsNs ptsDen:1000000000 host:host generation:1];
        }
        SPProbeSpinUntilHost(start+SPRationalToHost(sp::spMake(seconds,1)));
        dispatch_sync(p->_q, ^{ dispatch_source_cancel(sampler); sample(@"input-end"); });
        __block BOOL drained=NO;
        const int64_t drainDeadline=SPHostNow()+SPRationalToHost(sp::spMake(2,1));
        do {
            dispatch_sync(p->_q, ^{ drained=p->_inflight==0 && p->_rateBudgetProbeInFlightToken==0 && [p inboundCount]==0; });
            if (!drained) usleep(10000);
        } while (!drained && SPHostNow()<drainDeadline);
        __block NSDictionary *result=nil;
        dispatch_sync(p->_q, ^{
            sample(@"final");
            BOOL ordered=YES;
            for (size_t i=1;i<p->_testPlayout.size();i++)
                if (sp::spCmp(p->_testPlayout[i-1].first,p->_testPlayout[i].first)>=0) ordered=NO;
            double inputFPS=(count-1)*1e9/(double)SPHostToNs(last-first);
            BOOL executed=drained && ordered && inputFPS>inputRate-1 && inputFPS<inputRate+1 && p->_syntheticFail==0 && p->_testPlayout.size()>p->_testHoldPlayout.size();
            NSUInteger observed=0,atLeast29=0,atLeast58=0; double measuredSeconds=0;
            for (NSDictionary *row in timeline) if ([row[@"measurementWindow"] boolValue] && [row[@"logicalUniqueFPS"] isKindOfClass:NSNumber.class]) {
                observed++; measuredSeconds+=[row[@"intervalSeconds"] doubleValue];
                if ([row[@"logicalUniqueFPS"] doubleValue]>=29) atLeast29++;
                if ([row[@"logicalUniqueFPS"] doubleValue]>=58) atLeast58++;
            }
            result=@{ @"ok":@(executed),@"executionOK":@(executed),@"scope":scope,
                @"configuration":@{ @"inputSize":@[@(width),@(height)],@"inputRate":@(inputRate),@"displayRefreshHz":@(refresh),@"durationSeconds":@(seconds),@"warmupSeconds":@(warmup),@"requestedMultiplier":@2,
                    @"model":@"rife-v4.25",@"quality":@"fast",@"inputFormat":@"NV12 video-range",@"inputContent":@"six immutable uniform luma levels with neutral chroma",@"timestampJitterMs":@1.8 },
                @"inputFPS":@(inputFPS),@"inputFramesSubmitted":@(count),@"monotonicPTS":@(ordered),@"drained":@(drained),@"drainLimitSeconds":@2,
                @"preparedStreamDiagnostics":prepared,@"timeline":[timeline copy],@"finalStats":[p currentStats],
                @"logicalGoalObservations":@{ @"hostSecondWindows":@(observed),@"observedHostSeconds":@(measuredSeconds),@"nominalMeasurementSeconds":@(seconds-warmup),@"windowsAtLeast29":@(atLeast29),@"windowsAtLeast58":@(atLeast58),
                    @"fractionAtLeast29":observed?@((double)atLeast29/observed):(id)NSNull.null,@"fractionAtLeast58":observed?@((double)atLeast58/observed):(id)NSNull.null },
                @"resultNote":@"ok/executionOK describe execution only; logical goal observations exclude warmup and incomplete host windows and do not certify display FPS or user-visible quality. Raw production stats may reset at the recorded epoch/config changes; no deltas are inferred from those stats." };
        });
        [p stop];
        return result;
    }
    const int requestedInput=[NSProcessInfo.processInfo.environment[@"ODF_FIXED_RATE_PROBE_INPUT_FPS"] intValue];
    const int inputRate=requestedInput==28?28:30;
    const int width=2560,height=1410,count=inputRate*5;
    NSMutableArray<SPOwnedPixelBuffer *> *inputs=[NSMutableArray array];
    const uint8_t levels[]={48,64,80,96,80,64};
    for(int i=0;i<6;i++) {
        CVPixelBufferRef frame=SPCreateBuffer(width,height,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
        if(!frame)return @{ @"ok":@NO,@"error":@"input allocation" };
        CVPixelBufferLockBaseAddress(frame,0);
        for(size_t plane=0;plane<CVPixelBufferGetPlaneCount(frame);plane++)
            memset(CVPixelBufferGetBaseAddressOfPlane(frame,plane),plane?128:levels[i],
                CVPixelBufferGetBytesPerRowOfPlane(frame,plane)*CVPixelBufferGetHeightOfPlane(frame,plane));
        CVPixelBufferUnlockBaseAddress(frame,0);
        [inputs addObject:[[SPOwnedPixelBuffer alloc] initWithBufferNoCopy:frame]];
    }
    NSMutableArray *cases=[NSMutableArray array];__block BOOL allOK=YES;
    for(int mode=0;mode<3;mode++) {
        SPRifeBridge *rife=[[SPRifeBridge alloc] initWithResourceBundle:bundle];rife.liveStreamEnabled=YES;
        NSError *error=nil;
        if(![rife prepareModelID:@"rife-v4.25" quality:@"fast" width:width height:height error:&error])
            return @{ @"ok":@NO,@"error":error.localizedDescription?:@"RIFE setup" };
        SPLiveProcessor *p=[[SPLiveProcessor alloc] init];
        dispatch_sync(p->_q, ^{
            p->_request.interpolationEnabled=YES;p->_request.engineID=@"rife.metal";p->_request.modelID=@"rife-v4.25";p->_request.qualityID=@"fast";
            p->_request.rifeStreamEnabled=YES;p->_request.rateKind=mode==0?SPLiveRateMultiplier:SPLiveRateFixedFPS;
            p->_request.multiplier=2;p->_request.fpsNumerator=60;p->_request.fpsDenominator=1;p->_request.displayRefreshHz=120;
            p->_testExactFixedSchedule=mode==1;
            p->_width=width;p->_height=height;p->_resolved.outputWidth=width;p->_resolved.outputHeight=height;
            p->_resolved.committed=YES;p->_resolved.interpolationActive=YES;p->_sessionReady=YES;p->_rife=rife;p->_testCapturePlayout=YES;
            [p resetSchedulerOnQueue];
        });
        const int64_t start=SPHostNow();int64_t first=0,last=0;
        for(int i=0;i<count;i++) {
            // Identical jittered capture clock and immutable pixel sequence for all three modes.
            const int64_t ptsNs=(int64_t)i*1000000000/inputRate+(i?llround(1800000*sin(i*1.731)):0);
            SPProbeSpinUntilHost(start+SPRationalToHost(sp::spMake(ptsNs,1000000000)));
            const int64_t host=SPHostNow();if(!i)first=host;last=host;
            [p pushPixelBuffer:inputs[i%6].buffer ptsNum:ptsNs ptsDen:1000000000 host:host generation:1];
        }
        usleep(300000);
        dispatch_sync(p->_q, ^{
            int source=0,synthetic=0,holds=0;BOOL ordered=YES;
            auto inWindow=[](sp::SPRational pts){ return sp::spCmp(pts,sp::spMake(1,1))>=0 && sp::spCmp(pts,sp::spMake(4,1))<0; };
            for(size_t i=0;i<p->_testPlayout.size();i++) {
                const auto &entry=p->_testPlayout[i];
                if(i&&sp::spCmp(p->_testPlayout[i-1].first,entry.first)>=0)ordered=NO;
                if(inWindow(entry.first)){if(entry.second)synthetic++;else source++;}
            }
            for(auto pts:p->_testHoldPlayout)if(inWindow(pts))holds++;
            NSDictionary *stats=[p currentStats],*diag=[rife streamDiagnostics];
            double inputFPS=(count-1)*1e9/(double)SPHostToNs(last-first);
            BOOL ok=ordered&&inputFPS>inputRate-1&&inputFPS<inputRate+1&&p->_syntheticFail==0&&source+synthetic>holds;
            allOK=allOK&&ok;
            [cases addObject:@{ @"mode":mode==0?@"x2":(mode==1?@"strict-fixed60":@"reuse-fixed60"),@"ok":@(ok),
                @"inputFPS":@(inputFPS),@"sampleSeconds":@3,@"sourceFrames":@(source-holds),@"syntheticFrames":@(synthetic),@"holdFrames":@(holds),
                @"uniquePlayoutFPS":@((source-holds+synthetic)/3.0),@"slotPlayoutFPS":@((source+synthetic)/3.0),
                @"monotonicPTS":@(ordered),@"modelFailures":@(p->_syntheticFail),@"queueDrops":@(p->_queueDrops),@"deadlineDrops":@(p->_deadlineDrops),
                @"fixedFallbackPresented":@(p->_fixedFallbackPresented),@"fixedFallbackReplaced":@(p->_fixedFallbackReplaced),
                @"frcP95ms":stats[@"frcP95ms"]?:@0,@"delayMs":stats[@"delayMs"]?:@0,
                @"cacheHits":diag[@"hits"]?:@0,@"cacheMisses":diag[@"misses"]?:@0 }];
        });
        [p stop];
    }
    return @{ @"ok":@(allOK),@"cases":cases,@"model":@"rife-v4.25",@"quality":@"fast",@"inputSize":@[@(width),@(height)],
        @"inputRate":@(inputRate),@"scope":@"real RIFE and production processor playout, identical paced immutable NV12 input with +/-1.8 ms timestamp jitter; 1s warmup, 3s measurement; no ScreenCaptureKit, drawable or physical display" };
}

+ (NSDictionary<NSString *, id> *)runRifePacedWithBundle:(NSBundle *)bundle fullSize:(BOOL)fullSize {
    const int width=fullSize?2560:320, height=fullSize?1410:192, count=fullSize?300:90;
    const int segmentCount=fullSize?5:3, segmentSize=count/segmentCount;
    const int inputCount=fullSize?6:count+5;
    NSMutableArray<SPOwnedPixelBuffer *> *inputs=[NSMutableArray arrayWithCapacity:inputCount];
    uint64_t inputBytes=0;
    for (int i=0;i<inputCount;i++) {
        CVPixelBufferRef frame=SPCreateBuffer(width,height,fullSize?kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:kCVPixelFormatType_32BGRA);
        if (!frame) return @{ @"ok":@NO, @"error":@"input allocation" };
        CVPixelBufferLockBaseAddress(frame,0);
        if (fullSize) {
            for (size_t plane=0;plane<CVPixelBufferGetPlaneCount(frame);plane++) {
                size_t bytes=CVPixelBufferGetBytesPerRowOfPlane(frame,plane)*CVPixelBufferGetHeightOfPlane(frame,plane);
                memset(CVPixelBufferGetBaseAddressOfPlane(frame,plane),plane ? 128 : 64+i%5,bytes); inputBytes+=bytes;
            }
        } else {
            size_t bytes=CVPixelBufferGetBytesPerRow(frame)*height;
            memset(CVPixelBufferGetBaseAddress(frame),64+i%5,bytes); inputBytes+=bytes;
        }
        CVPixelBufferUnlockBaseAddress(frame,0);
        [inputs addObject:[[SPOwnedPixelBuffer alloc] initWithBufferNoCopy:frame]];
    }
    SPRifeBridge *rife=[[SPRifeBridge alloc] initWithResourceBundle:bundle]; rife.liveStreamEnabled=YES;
    NSError *error=nil; int64_t prepareStart=SPHostNow();
    BOOL prepared=[rife prepareModelID:@"rife-v4.25" quality:@"fast" width:width height:height error:&error];
    double prepareMs=(double)SPHostToNs(SPHostNow()-prepareStart)/1e6;
    if (!prepared) return @{ @"ok":@NO, @"error":error.localizedDescription ?: @"RIFE prepare", @"prepareMs":@(prepareMs) };
    NSMutableArray<SPOwnedPixelBuffer *> *poolHeld=[NSMutableArray array];
    for (int i=0;i<(fullSize?0:4);i++) {
        dispatch_semaphore_t done=dispatch_semaphore_create(0); __block NSString *failure=@"";
        BOOL accepted=[rife submitLivePrevious:inputs[i].buffer current:inputs[i+1].buffer previousID:100+i currentID:101+i
            previousPTS:CMTimeMake(i,60) currentPTS:CMTimeMake(i+1,60) generation:1 clockEpoch:0 timesteps:@[@0.5f] token:i
            completion:^(uint64_t token, NSArray<SPOwnedPixelBuffer *> *outputs, double latency, NSError *err) {
                (void)token; (void)latency; if(outputs.count) [poolHeld addObject:outputs[0]]; failure=err.localizedDescription ?: @""; dispatch_semaphore_signal(done);
            }];
        if (!accepted || dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC)) != 0 || failure.length) {
            [rife invalidate]; return @{ @"ok":@NO, @"error":failure.length ? failure : @"preload failed or timed out", @"preloaded":@(poolHeld.count) };
        }
    }
    SPLiveProcessor *p=[[SPLiveProcessor alloc] init];
    dispatch_sync(p->_q, ^{
        p->_request.interpolationEnabled=YES; p->_request.engineID=@"rife.metal"; p->_request.modelID=@"rife-v4.25"; p->_request.qualityID=@"fast";
        p->_request.rifeStreamEnabled=YES; p->_request.rateKind=SPLiveRateMultiplier; p->_request.multiplier=2; p->_request.displayRefreshHz=120;
        p->_request.scaleEnabled=NO; p->_width=width; p->_height=height; p->_resolved.outputWidth=width; p->_resolved.outputHeight=height;
        p->_resolved.committed=YES; p->_resolved.interpolationActive=YES; p->_sessionReady=YES; p->_rife=rife; p->_testCapturePlayout=YES;
        [p resetSchedulerOnQueue];
    });
    int64_t start=SPHostNow(), first=0, last=0; NSMutableArray *inputIntervals=[NSMutableArray array]; NSMutableArray *segments=[NSMutableArray array];
    void (^captureSegment)(int, BOOL) = ^(int delivered, BOOL releasePool) {
        int64_t requested=SPHostNow();
        dispatch_async(p->_q, ^{
            int64_t sampled=SPHostNow();
            int source=0, synthetic=0;
            for(const auto &item:p->_testPlayout) { if(item.second) synthetic++; else source++; }
            NSDictionary *diag=[rife streamDiagnostics];
            [segments addObject:@{ @"delivered":@(delivered), @"requestHost":@(requested), @"sampleHost":@(sampled),
                @"fenceWaitMs":@((double)SPHostToNs(sampled-requested)/1e6), @"releasedHeldPool":@(releasePool), @"heldBeforeRelease":@(poolHeld.count),
                @"source":@(source), @"synthetic":@(synthetic),
                @"modelOutputs":@(p->_syntheticOK), @"cacheHits":diag[@"hits"] ?: @0,
                @"poolFailures":diag[@"poolFailures"] ?: @0, @"slots":@(p->_slots.size()), @"slotCap":@([p slotCap]) }];
            if (releasePool) [poolHeld removeAllObjects];
        });
    };
    for (int i=0;i<count;i++) {
        SPProbeSpinUntilHost(start+SPRationalToHost(sp::spMake(i,60)));
        int64_t host=SPHostNow(); if(i==0)first=host; else [inputIntervals addObject:@((double)SPHostToNs(host-last)/1e6)]; last=host;
        [p pushPixelBuffer:inputs[fullSize ? i%inputCount : i+5].buffer ptsNum:i ptsDen:60 host:host generation:1];
        if ((i+1)%segmentSize==0) captureSegment(i+1,!fullSize && i+1==segmentSize);
    }
    usleep(500000);
    __block NSDictionary *report;
    dispatch_sync(p->_q, ^{
        int source=0, synthetic=0; bool ordered=true;
        for(size_t i=0;i<p->_testPlayout.size();i++) {
            if(p->_testPlayout[i].second) synthetic++; else source++;
            if(i && sp::spCmp(p->_testPlayout[i-1].first,p->_testPlayout[i].first)>=0) ordered=false;
        }
        NSDictionary *stats=[p currentStats], *diag=[rife streamDiagnostics];
        double fps=(double)(count-1)*1e9/(double)SPHostToNs(last-first);
        NSArray *sorted=[inputIntervals sortedArrayUsingSelector:@selector(compare:)];
        double intervalP95=[sorted[(sorted.count-1)*95/100] doubleValue];
        BOOL pacing=fps>=55 && fps<=65 && intervalP95<=25;
        NSMutableArray *segmentDeltas=[NSMutableArray arrayWithCapacity:segments.count];
        BOOL progressive=segments.count==(NSUInteger)segmentCount;
        NSDictionary *previous=nil; int64_t previousHost=start;
        for (NSDictionary *segment in segments) {
            int64_t sampled=[segment[@"sampleHost"] longLongValue];
            double seconds=(double)SPHostToNs(sampled-previousHost)/1e9;
            int sourceDelta=[segment[@"source"] intValue]-[previous[@"source"] intValue];
            int syntheticDelta=[segment[@"synthetic"] intValue]-[previous[@"synthetic"] intValue];
            int modelDelta=[segment[@"modelOutputs"] intValue]-[previous[@"modelOutputs"] intValue];
            int cacheDelta=[segment[@"cacheHits"] intValue]-[previous[@"cacheHits"] intValue];
            int poolDelta=[segment[@"poolFailures"] intValue]-[previous[@"poolFailures"] intValue];
            [segmentDeltas addObject:@{ @"delivered":segment[@"delivered"], @"elapsedFromStartSec":@((double)SPHostToNs(sampled-start)/1e9),
                @"durationSec":@(seconds), @"source":@(sourceDelta), @"synthetic":@(syntheticDelta), @"modelOutputs":@(modelDelta),
                @"cacheHits":@(cacheDelta), @"poolFailures":@(poolDelta),
                @"sourcePerSec":@(seconds>0?sourceDelta/seconds:0), @"syntheticPerSec":@(seconds>0?syntheticDelta/seconds:0) }];
            if (!previous) progressive=progressive && sourceDelta>0;
            else progressive=progressive && sourceDelta>0 && syntheticDelta>0 && modelDelta>0 && cacheDelta>0;
            previous=segment; previousHost=sampled;
        }
        BOOL pressureSatisfied=fullSize || (p->_rifePoolPressureEvents>0 && [diag[@"poolFailures"] intValue]>0);
        BOOL ok=pacing && progressive && source>0 && synthetic>0 && p->_syntheticOK>0 && ordered && pressureSatisfied && p->_slots.size()<=[p slotCap];
        report=@{ @"ok":@(ok), @"model":@"rife-v4.25", @"quality":@"fast", @"streamCache":@YES,
            @"inputSize":@[@(width),@(height)], @"sourceFrames":@(count), @"inputHz":@(fps), @"inputIntervalP95ms":@(intervalP95), @"inputPacingValid":@(pacing), @"inputIntervalsMs":inputIntervals,
            @"inputFormat":fullSize?@"420v":@"BGRA", @"immutableInputBuffers":@(inputCount), @"immutableInputBytes":@(inputBytes),
            @"poolHeldBeforeRun":@(fullSize?0:4), @"segments":segments, @"segmentDeltas":segmentDeltas, @"continuousProgressAcrossSegments":@(progressive), @"sourcePlayout":@(source), @"syntheticPlayout":@(synthetic),
            @"monotonicPTS":@(ordered), @"modelOutputs":@(p->_syntheticOK), @"modelFailures":@(p->_syntheticFail),
            @"poolPressureEvents":@(p->_rifePoolPressureEvents), @"poolRetryAdmissions":@(p->_rifePoolRetryAdmissions), @"poolUnexpiredDrops":@(p->_rifePoolUnexpiredDrops),
            @"queueDrops":@(p->_queueDrops), @"deadlineDrops":@(p->_deadlineDrops), @"peakSlots":@(p->_peakSlots), @"slotCap":@([p slotCap]),
            @"delayMs":stats[@"delayMs"], @"frcP95ms":stats[@"frcP95ms"], @"captureToModelReadyP95ms":stats[@"captureToModelReadyP95ms"],
            @"streamDiagnostics":diag, @"prepareMs":@(prepareMs),
            @"scope":fullSize ? @"real RIFE 4.25 Fast streaming model and production queue, 2560x1410 immutable NV12 synthetic paced 60 Hz input, no artificial pool retention; no SCK, drawable or physical display" : @"real RIFE 4.25 Fast streaming model and production queue, 320x192 synthetic paced 60 Hz input, four output buffers deliberately retained then released; no SCK, drawable or physical display" };
    });
    [p stop]; return report;
}

+ (NSDictionary<NSString *, id> *)runRife60to120WithBundle:(NSBundle *)bundle { return [self runRifePacedWithBundle:bundle fullSize:NO]; }
+ (NSDictionary<NSString *, id> *)runRifeFullSizeWithBundle:(NSBundle *)bundle { return [self runRifePacedWithBundle:bundle fullSize:YES]; }

+ (NSDictionary<NSString *, id> *)runEngineProbe {
    @autoreleasepool {
        NSDictionary *low = [SPLowLatencyEngine probePhases];
        NSDictionary *rife = [SPRifeBridge probe];
        NSDictionary *frcPTS = [self runFRCPTSProbe];
        NSDictionary *appleLowSR = [self runAppleLowSRProbe];
        BOOL lowOK = [low[@"ok"] boolValue];
        BOOL rifeOK = [rife[@"ok"] boolValue];
        BOOL frcOK = [frcPTS[@"processed"] boolValue] && [frcPTS[@"duplicatePTSRejected"] boolValue] && [frcPTS[@"fileMidpointProcessed"] boolValue];
        NSMutableDictionary *report = [@{
            @"ok": @(lowOK && rifeOK && frcOK),
            @"lowLatency": low ?: @{},
            @"rife": rife ?: @{},
            @"frcPTS": frcPTS ?: @{},
        } mutableCopy];
        BOOL srOK = ![appleLowSR[@"candidateSupported"] boolValue] || [appleLowSR[@"processed"] boolValue];
        report[@"ok"] = @(lowOK && rifeOK && frcOK && srOK);
        report[@"appleLowSR"] = appleLowSR ?: @{};
        return report;
    }
}

+ (NSDictionary<NSString *, id> *)runAnimationPipelineContract:(SPLiveScaleEngine)engine variant:(NSString *)variant preset:(int)preset {
    SPLiveProcessor *p=[[SPLiveProcessor alloc] init];
    int width=preset ? 960 : (engine==SPLiveScaleRealCUGAN?240:160), height=preset ? 540 : (engine==SPLiveScaleRealCUGAN?128:96);
    NSSize effective=SPLiveSRInputSize(width,height,preset);
    int outputW=(int)effective.width*2, outputH=(int)effective.height*2;
    CVPixelBufferRef input=SPCreateBuffer(width,height,kCVPixelFormatType_32BGRA);
    if(!input)return @{ @"ok":@NO, @"reason":@"source allocation" };
    CVPixelBufferLockBaseAddress(input,0);
    uint8_t *base=(uint8_t *)CVPixelBufferGetBaseAddress(input);size_t pitch=CVPixelBufferGetBytesPerRow(input);
    for(int y=0;y<height;y++)for(int x=0;x<width;x++){uint8_t *pixel=base+y*pitch+x*4;uint8_t v=((x/9+y/9)%2)?220:30;pixel[0]=pixel[1]=pixel[2]=v;pixel[3]=255;}
    CVPixelBufferUnlockBaseAddress(input,0);
    [p adoptSourceGeneration:1];dispatch_sync(p->_q,^{p->_width=width;p->_height=height;});
    SPLivePlanRequest *request=[[SPLivePlanRequest alloc] init];request.scaleEnabled=YES;request.scaleEngine=engine;request.scaleQualityID=variant;request.srInputPreset=preset;request.outputWidth=0;request.outputHeight=0;request.viewMode=SPLiveViewCompare;
    [p updateRequest:request];__block BOOL ready=NO;
    for(int i=0;i<400&&!ready;i++){usleep(50000);dispatch_sync(p->_q,^{ready=p->_sessionReady&&(engine==SPLiveScaleAnime4K ? p->_animeSR!=nil : p->_cuganSR!=nil)&&p->_resolved.scaleActive&&p->_resolved.outputWidth==outputW&&p->_resolved.outputHeight==outputH;});}
    if(!ready){CVPixelBufferRelease(input);NSDictionary *stats=[p stats];[p stop];return @{ @"ok":@NO,@"reason":@"animation scale prepare",@"stats":stats };}
    // The source and a simulated interpolated frame both take the real shader
    // path. Its target is deliberately in the past: slow-mode output must
    // still be presented rather than discarded by the interactive deadline.
    int64_t past=SPHostNow()-SPRationalToHost(sp::spMake(1,1));
    dispatch_sync(p->_q,^{
        p->_held[11].source=CVPixelBufferRetain(input);p->_held[11].host=past;p->_held[11].pts=sp::spMake(10,1);
        [p enqueueSourceIdentity:11 pts:sp::spMake(10,1) host:past generation:1 force:NO];
    });
    __block BOOL sourceOutput=NO,compare=NO,content=NO;
    for(int i=0;i<400&&!sourceOutput;i++){usleep(50000);dispatch_sync(p->_q,^{sourceOutput=p->_lastEnhanced&&CVPixelBufferGetWidth(p->_lastEnhanced)==outputW&&CVPixelBufferGetHeight(p->_lastEnhanced)==outputH&&sp::spCmp(p->_lastRedrawPts,sp::spMake(10,1))==0;compare=p->_lastOriginal&&CVPixelBufferGetWidth(p->_lastOriginal)==outputW;if(sourceOutput)content=SPWhiteCenterX(p->_lastEnhanced)>=0;});}
    dispatch_sync(p->_q,^{
        SPLiveJob *job=new SPLiveJob();job->configVersion=p->_configVersion;job->generation=1;job->inflightEpoch=p->_inflightEpoch;job->clockEpoch=p->_clockEpoch;job->captureHost=past;job->frameA=11;job->count=1;job->pts[0]=sp::spMake(601,60);
        SPOwnedPixelBuffer *box=[[SPOwnedPixelBuffer alloc] initWithBufferNoCopy:CVPixelBufferRetain(input)];[p finishJob:job token:1 outputs:@[box] latency:0 error:nil];
    });
    __block BOOL syntheticOutput=NO;
    for(int i=0;i<400&&!syntheticOutput;i++){usleep(50000);dispatch_sync(p->_q,^{syntheticOutput=p->_lastSynthetic&&p->_lastEnhanced&&sp::spCmp(p->_lastRedrawPts,sp::spMake(601,60))==0;});}
    __block BOOL bounded=YES,latest=YES,replacementCounted=YES;
    if(engine==SPLiveScaleAnime4K || [variant isEqualToString:@"none"]) {
        __block uint64_t before=0;
        dispatch_sync(p->_q,^{
            before=p->_queueDrops;
            for(int i=0;i<6;i++){
                CVPixelBufferRef baseline=[p scaleBuffer:input with:p->_baselineScaler];
                [p enqueueAsyncScale:CVPixelBufferRetain(input) original:baseline pts:sp::spMake(330+i,30) synthetic:NO held:NO captureHost:past generation:1 deadlineHost:0];
            }
            // An older interpolation completion must not replace a newer
            // queued source just because it arrived later on the queue.
            CVPixelBufferRef olderBaseline=[p scaleBuffer:input with:p->_baselineScaler];
            [p enqueueAsyncScale:CVPixelBufferRetain(input) original:olderBaseline pts:sp::spMake(331,30) synthetic:YES held:NO captureHost:past generation:1 deadlineHost:0];
            bounded=p->_srPending.size()<=1 && !p->_srPending.empty() && sp::spCmp(p->_srPending.front()->pts,sp::spMake(335,30))==0;
            replacementCounted=p->_queueDrops>=before+5;
        });
        latest=NO;
        for(int i=0;i<400&&!latest;i++){usleep(50000);dispatch_sync(p->_q,^{latest=p->_lastEnhanced&&sp::spCmp(p->_lastRedrawPts,sp::spMake(335,30))==0;});}
    }
    CVPixelBufferRelease(input);[p stop];
    return @{ @"ok":@(ready&&sourceOutput&&syntheticOutput&&bounded&&compare&&content&&latest&&replacementCounted),@"prepared":@(ready),@"sourceOutput":@(sourceOutput),@"nonblankContent":@(content),@"syntheticOutputAfterDeadline":@(syntheticOutput),@"pendingAtMostOne":@(bounded),@"newestPresented":@(latest),@"replacementsCounted":@(replacementCounted),@"compareBaseline":@(compare),@"srInput":@[@((int)effective.width),@((int)effective.height)],@"output":@[@(outputW),@(outputH)],@"note":@"Synthetic source and simulated interpolation only; real capture, actual model combination, saved UI config, color and performance unverified." };
}



+ (NSDictionary<NSString *, id> *)runAnime4KPipelineContract { return [self runAnimationPipelineContract:SPLiveScaleAnime4K variant:@"none" preset:0]; }
+ (NSDictionary<NSString *, id> *)runRealCUGANPipelineContract {
    NSMutableDictionary *variants=[NSMutableDictionary dictionary];BOOL ok=YES;
    for(NSString *name in @[@"none",@"light",@"medium",@"strong"]) {
        NSDictionary *result=[self runAnimationPipelineContract:SPLiveScaleRealCUGAN variant:name preset:0];variants[name]=result;ok=ok&&[result[@"ok"] boolValue];
    }
    return @{ @"ok":@(ok),@"variants":variants,@"note":@"All four models were called on a synthetic 240×128 source, including tiled processing; real sources, quality and UI persistence remain unverified." };
}

+ (NSDictionary<NSString *, id> *)runVideoSRPipelineContract {
    SPLiveProcessor *p = [[SPLiveProcessor alloc] init];
    CVPixelBufferRef input = SPCreateBuffer(1920, 1080, kCVPixelFormatType_32BGRA);
    if (!input) return @{ @"ok": @NO, @"reason": @"source allocation" };
    CVPixelBufferLockBaseAddress(input, 0);
    memset(CVPixelBufferGetBaseAddress(input), 80, CVPixelBufferGetBytesPerRow(input) * CVPixelBufferGetHeight(input));
    CVPixelBufferUnlockBaseAddress(input, 0);
    [p adoptSourceGeneration:1];
    dispatch_sync(p->_q, ^{ p->_width=1920; p->_height=1080; p->_testRecordSRInput=YES; });
    SPLivePlanRequest *request=[[SPLivePlanRequest alloc] init];
    request.scaleEnabled=YES; request.scaleEngine=SPLiveScaleAppleVideoSR;
    request.outputWidth=0; request.outputHeight=0; request.viewMode=SPLiveViewCompare;
    NSSize effective=SPLiveSRInputSizeForRequest(1920,1080,request);
    NSSize expected=[SPAppleVideoSR automaticOutputForWidth:(int)effective.width height:(int)effective.height];
    [p updateRequest:request];
    __block BOOL ready=NO;
    for (int i=0;i<400&&!ready;i++) { usleep(50000); dispatch_sync(p->_q, ^{ready=p->_sessionReady && p->_videoSR && p->_resolved.scaleActive;}); }
    if (!ready) { CVPixelBufferRelease(input); [p stop]; return @{ @"ok":@NO, @"reason":@"video SR prepare", @"stats":[p stats] }; }
    __block uint64_t config=0; dispatch_sync(p->_q, ^{config=p->_configVersion;});
    SPLivePlanRequest *large=[request copy]; large.outputWidth=3840; large.outputHeight=2160;
    __block BOOL oversizedRejected=NO;
    dispatch_sync(p->_q, ^{oversizedRejected=![p validateRequest:large reason:nil];});
    SPLivePlanRequest *bad=[request copy]; bad.interpolationEnabled=YES; bad.engineID=@"apple.frc"; bad.multiplier=2;
    [p updateRequest:bad];
    __block BOOL rejectedWithoutReplacing=NO;
    dispatch_sync(p->_q, ^{rejectedWithoutReplacing=p->_configVersion==config && p->_videoSR && p->_sessionReady && !p->_request.interpolationEnabled;});
    int64_t future=SPHostNow()+SPRationalToHost(sp::spMake(120,1));
    __block int observed=0; __block BOOL sizes=YES, comparison=YES, failed=NO;
    for (int frame=0;frame<3;frame++) {
        dispatch_sync(p->_q, ^{
            int i=frame;
            uint64_t id=11+i;
            p->_held[id].source=CVPixelBufferRetain(input);p->_held[id].host=future+SPRationalToHost(sp::spMake(i,30));p->_held[id].pts=sp::spMake(i,30);
            [p enqueueSourceIdentity:id pts:sp::spMake(i,30) host:p->_held[id].host generation:1 force:NO];
        });
        for (int i=0;i<400&&observed<frame+1&&!failed;i++) {usleep(50000);dispatch_sync(p->_q, ^{
            failed=p->_srFailed;
            if (p->_lastEnhanced && sp::spCmp(p->_lastRedrawPts,sp::spMake(frame,30))==0) {
                observed=frame+1;
                sizes=sizes && CVPixelBufferGetWidth(p->_lastEnhanced)==(size_t)expected.width && CVPixelBufferGetHeight(p->_lastEnhanced)==(size_t)expected.height && CVPixelBufferGetPixelFormatType(p->_lastEnhanced)==kCVPixelFormatType_32BGRA;
                comparison=comparison && p->_lastOriginal && CVPixelBufferGetWidth(p->_lastOriginal)==(size_t)expected.width;
            }
        });}
        if (failed || observed<frame+1) break;
    }
    __block NSString *firstError=nil; dispatch_sync(p->_q, ^{firstError=p->_testSRError;});
    [p adoptSourceGeneration:2];dispatch_sync(p->_q,^{});
    [p pushPixelBuffer:input ptsNum:1 ptsDen:1 host:future generation:2];
    __block BOOL secondReady=NO;
    for(int i=0;i<400&&!secondReady;i++){usleep(50000);dispatch_sync(p->_q,^{secondReady=p->_sourceGeneration==2 && p->_sessionReady && p->_videoSR && p->_resolved.scaleActive;});}
    [p pushPixelBuffer:input ptsNum:31 ptsDen:30 host:future+SPRationalToHost(sp::spMake(1,30)) generation:2];
    __block BOOL newOutput=NO,oldOutput=NO;
    for(int i=0;i<400&&!newOutput;i++){usleep(50000);dispatch_sync(p->_q,^{
        newOutput=p->_sourceGeneration==2 && p->_lastEnhanced && sp::spCmp(p->_lastRedrawPts,sp::spMake(31,30))==0 && CVPixelBufferGetWidth(p->_lastEnhanced)==(size_t)expected.width;
        for(const SPPlaySlot &slot:p->_slots) if(slot.sourceGeneration!=2) oldOutput=YES;
    });}
    __block NSString *lastError=nil; dispatch_sync(p->_q, ^{lastError=p->_testSRError;});
    CVPixelBufferRelease(input);[p stop];
    BOOL ok=ready&&rejectedWithoutReplacing&&oversizedRejected&&observed==3&&sizes&&comparison&&secondReady&&newOutput&&!oldOutput;
    return @{ @"ok":@(ok), @"prepared":@(ready), @"outputFramesWithOriginalPTS":@(observed), @"outputBGRAAndSize":@(sizes), @"compareBaseline":@(comparison), @"unverifiedCombinationRejectedAndOldPlanKept":@(rejectedWithoutReplacing), @"oversizedLiveOutputRejected":@(oversizedRejected), @"newGenerationSession":@(secondReady), @"newGenerationOutput":@(newOutput), @"oldGenerationOutput":@(oldOutput), @"firstError":firstError ?: @"", @"lastError":lastError ?: @"", @"automaticOutput":@[@((int)expected.width),@((int)expected.height)], @"note":@"Synthetic sources only; real capture, visual quality, UI persistence and performance remain unverified." };
}

+ (NSDictionary<NSString *, id> *)runSRPipelineContractWithPreset:(int)preset {
    SPLiveProcessor *p = [[SPLiveProcessor alloc] init];
    int width = preset ? 2560 : 1280, height = preset ? 1440 : 720;
    CVPixelBufferRef source = preset ? SPCreateBuffer(width, height, kCVPixelFormatType_32BGRA) : [self syntheticFrame:0];
    if (source && preset) {
        CVPixelBufferLockBaseAddress(source, 0);
        uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(source); size_t stride = CVPixelBufferGetBytesPerRow(source);
        for (int y=0; y<height; ++y) for (int x=0; x<width; ++x) {
            uint8_t *pixel=base + y*stride + x*4; uint8_t v=((x/7+y/9)&1) ? 225 : 25;
            pixel[0]=pixel[1]=pixel[2]=v; pixel[3]=255;
        }
        CVPixelBufferUnlockBaseAddress(source, 0);
    }
    if (!source) return @{ @"ok": @NO, @"reason": @"source allocation" };
    [p adoptSourceGeneration:1];
    dispatch_sync(p->_q, ^{ p->_width = width; p->_height = height; p->_testRecordSRInput = YES; });
    SPLivePlanRequest *request = [[SPLivePlanRequest alloc] init];
    request.scaleEnabled = YES; request.scaleEngine = SPLiveScaleAppleLowLatencySR; request.srInputPreset = preset;
    request.outputWidth = preset ? 0 : 1920; request.outputHeight = preset ? 0 : 1080; request.viewMode = SPLiveViewCompare;
    [p updateRequest:request];
    __block BOOL ready = NO;
    for (int i = 0; i < 400 && !ready; ++i) {
        usleep(50000);
        dispatch_sync(p->_q, ^{ ready = p->_sessionReady && p->_resolved.scaleActive && p->_appleSR != nil; });
    }
    if (!ready) { CVPixelBufferRelease(source); [p stop]; return @{ @"ok": @NO, @"reason": @"SR prepare", @"stats": [p stats] }; }
    __block uint64_t originalConfig = 0;
    __block BOOL preScalerReady = NO; __block CVPixelBufferRef baselineReference = NULL;
    dispatch_sync(p->_q, ^{
        originalConfig = p->_configVersion;
        preScalerReady = preset ? p->_srInputScaler != nil : p->_srInputScaler == nil;
        baselineReference = [p scaleBuffer:source with:p->_baselineScaler];
    });
    SPLivePlanRequest *bad = [request copy]; bad.outputWidth = 1600; bad.outputHeight = 900;
    [p updateRequest:bad];
    __block BOOL prepareFinished = NO, preserved = NO;
    for (int i = 0; i < 400 && !prepareFinished; ++i) {
        usleep(50000);
        dispatch_sync(p->_q, ^{ prepareFinished = !p->_preparing; preserved = p->_sessionReady && p->_resolved.scaleActive && p->_configVersion == originalConfig && p->_appleSR != nil; });
    }
    int64_t future = SPHostNow() + SPRationalToHost(sp::spMake(20, 1));
    dispatch_sync(p->_q, ^{
        p->_testSRExpectedBaseline = baselineReference; p->_testSRExpectedSource = source; p->_testSRExpectedHost = future;
        p->_held[11].source = CVPixelBufferRetain(source);
        p->_held[11].host = future;
        p->_held[11].pts = sp::spMake(10, 1);
        [p enqueueSourceIdentity:11 pts:sp::spMake(10, 1) host:future generation:1 force:NO];
        SPLiveJob *job = new SPLiveJob();
        job->configVersion = p->_configVersion; job->generation = 1; job->inflightEpoch = p->_inflightEpoch; job->clockEpoch = p->_clockEpoch;
        job->captureHost = future; job->frameA = 11; job->count = 1; job->pts[0] = sp::spMake(601, 60);
        SPOwnedPixelBuffer *output = [[SPOwnedPixelBuffer alloc] initWithBufferNoCopy:CVPixelBufferRetain(source)];
        [p finishJob:job token:1 outputs:@[output] latency:0 error:nil];
    });
    __block BOOL sourceOK = NO, syntheticOK = NO, baselinePixelsOK = NO, identityOK = NO, inputSizeOK = NO;
    for (int i = 0; i < 400 && !(sourceOK && syntheticOK); ++i) {
        usleep(50000);
        dispatch_sync(p->_q, ^{
            sourceOK = p->_testSRSourceSlot; syntheticOK = p->_testSRSyntheticSlot;
            baselinePixelsOK = p->_testSRBaselineMatches; identityOK = p->_testSRIdentityMatches;
            inputSizeOK = p->_testSRInputWidth == 1280 && p->_testSRInputHeight == 720;
        });
    }
    // Replace the source after work was queued. The next frame must rebuild a
    // fresh SR session rather than submitting into the invalidated one.
    [p adoptSourceGeneration:2];
    dispatch_sync(p->_q, ^{});
    [p pushPixelBuffer:source ptsNum:20 ptsDen:1 host:future generation:2];
    __block BOOL secondReady = NO;
    for (int i = 0; i < 400 && !secondReady; ++i) {
        usleep(50000);
        dispatch_sync(p->_q, ^{ secondReady = p->_sourceGeneration == 2 && p->_sessionReady && p->_appleSR && p->_resolved.scaleActive; });
    }
    [p pushPixelBuffer:source ptsNum:21 ptsDen:1 host:future generation:2];
    __block BOOL newGenerationOutput = NO, oldGenerationOutput = NO;
    for (int i = 0; i < 400 && !newGenerationOutput; ++i) {
        usleep(50000);
        dispatch_sync(p->_q, ^{
            newGenerationOutput = p->_testSRNewGenerationSlot;
            for (const SPPlaySlot &slot : p->_slots) if (slot.sourceGeneration != 2) oldGenerationOutput = YES;
        });
    }
    __block NSString *testSRError = nil;
    dispatch_sync(p->_q, ^{ testSRError = p->_testSRError; p->_testRecordSRInput = NO; p->_testSRExpectedBaseline = NULL; p->_testSRExpectedSource = NULL; });
    if (baselineReference) CVPixelBufferRelease(baselineReference);
    CVPixelBufferRelease(source);
    [p stop];
    return @{ @"ok": @(ready && prepareFinished && preserved && sourceOK && syntheticOK && baselinePixelsOK && identityOK && inputSizeOK && preScalerReady && secondReady && newGenerationOutput && !oldGenerationOutput),
              @"ready": @(ready), @"failedPreparePreservesPlan": @(prepareFinished && preserved),
              @"sourcePTSAndBGRA": @(sourceOK), @"syntheticPTSAndBGRA": @(syntheticOK),
              @"newGenerationReady": @(secondReady), @"newGenerationOutput": @(newGenerationOutput), @"oldGenerationOutput": @(oldGenerationOutput),
              @"engineCallbackError": testSRError ?: @"", @"compareBaseline": @(baselinePixelsOK), @"baselineMatchesRaw": @(baselinePixelsOK), @"sourceIdentityAndHost": @(identityOK), @"actualSRInput1280x720": @(inputSizeOK), @"preScalerExpectedState": @(preScalerReady), @"captureSize": @[@(width), @(height)], @"note": @"No GUI: synthetic input and simulated interpolation output; real capture and actual interpolation remain independently unverified." };
}

+ (NSDictionary<NSString *, id> *)runAppleSRResizeContract {
    SPLiveProcessor *p=[[SPLiveProcessor alloc] init]; [p adoptSourceGeneration:1];
    dispatch_sync(p->_q, ^{ p->_width=2560; p->_height=1410; p->_sourceWidth=2560; p->_sourceHeight=1410; });
    SPLivePlanRequest *request=[[SPLivePlanRequest alloc] init]; request.scaleEnabled=YES; request.scaleEngine=SPLiveScaleAppleLowLatencySR; request.srInputPreset=720; request.outputWidth=1920; request.outputHeight=1056;
    [p updateRequest:request]; __block BOOL initial=NO;
    for(int i=0;i<400&&!initial;i++){usleep(50000);dispatch_sync(p->_q, ^{ initial=p->_sessionReady && p->_resolved.scaleActive && p->_appleSR; });}
    CVPixelBufferRef full=SPCreateBuffer(2560,1440,kCVPixelFormatType_32BGRA), normal=SPCreateBuffer(2560,1410,kCVPixelFormatType_32BGRA);
    if(!initial || !full || !normal) { if(full)CVPixelBufferRelease(full);if(normal)CVPixelBufferRelease(normal);NSDictionary *stats=[p stats];[p stop];return @{ @"ok":@NO,@"reason":@"initial prepare or buffers",@"stats":stats }; }
    for(CVPixelBufferRef b : {full,normal}) { CVPixelBufferLockBaseAddress(b,0); memset(CVPixelBufferGetBaseAddress(b),90,CVPixelBufferGetBytesPerRow(b)*CVPixelBufferGetHeight(b)); CVPixelBufferUnlockBaseAddress(b,0); }
    int64_t host=SPHostNow(); [p pushPixelBuffer:full ptsNum:1 ptsDen:1 host:host generation:1];
    __block BOOL fullReady=NO;
    for(int i=0;i<400&&!fullReady;i++){usleep(50000);dispatch_sync(p->_q, ^{ fullReady=p->_sessionReady && p->_resolved.scaleActive && p->_resolved.committed && p->_request.outputWidth==1920 && p->_request.outputHeight==1080; });}
    [p pushPixelBuffer:full ptsNum:2 ptsDen:1 host:SPHostNow() generation:1]; __block BOOL fullOutput=NO;
    for(int i=0;i<400&&!fullOutput;i++){usleep(50000);dispatch_sync(p->_q, ^{ fullOutput=p->_lastEnhanced && CVPixelBufferGetWidth(p->_lastEnhanced)==1920 && CVPixelBufferGetHeight(p->_lastEnhanced)==1080 && sp::spCmp(p->_lastRedrawPts,sp::spMake(2,1))==0; });}
    [p pushPixelBuffer:normal ptsNum:3 ptsDen:1 host:SPHostNow() generation:1]; __block BOOL normalReady=NO;
    for(int i=0;i<400&&!normalReady;i++){usleep(50000);dispatch_sync(p->_q, ^{ normalReady=p->_sessionReady && p->_resolved.scaleActive && p->_resolved.committed && p->_request.outputWidth==1920 && p->_request.outputHeight==1056; });}
    [p pushPixelBuffer:normal ptsNum:4 ptsDen:1 host:SPHostNow() generation:1]; __block BOOL normalOutput=NO;
    for(int i=0;i<400&&!normalOutput;i++){usleep(50000);dispatch_sync(p->_q, ^{ normalOutput=p->_lastEnhanced && CVPixelBufferGetWidth(p->_lastEnhanced)==1920 && CVPixelBufferGetHeight(p->_lastEnhanced)==1056 && sp::spCmp(p->_lastRedrawPts,sp::spMake(4,1))==0; });}
    NSDictionary *stats=[p stats]; CVPixelBufferRelease(full); CVPixelBufferRelease(normal); [p stop];
    return @{ @"ok":@(initial&&fullReady&&fullOutput&&normalReady&&normalOutput), @"initialNativeReady":@(initial), @"fullNativeReady":@(fullReady), @"fullActualOutput":@(fullOutput), @"normalNativeReady":@(normalReady), @"normalActualOutput":@(normalOutput), @"stats":stats, @"scope":@"synthetic same-generation input and real Apple SR processing, no ScreenCaptureKit or screen presentation" };
}

+ (NSDictionary<NSString *, id> *)runMetalFXSourceWindowContract {
    SPLiveProcessor *p=[[SPLiveProcessor alloc] init]; [p adoptSourceGeneration:1];
    dispatch_sync(p->_q, ^{ p->_width=1280; p->_height=720; p->_sourceWidth=1280; p->_sourceHeight=720; });
    SPLivePlanRequest *request=[[SPLivePlanRequest alloc] init]; request.scaleEnabled=YES; request.scaleEngine=SPLiveScaleMetalFX;
    request.srInputPreset=0; request.outputWidth=2560; request.outputHeight=1440; request.viewMode=SPLiveViewCompare;
    request.requiredSourceWidth=1280; request.requiredSourceHeight=720; request.requiredSourceWindowID=11; request.requiredSourcePID=22; request.requiredSourceAfterHost=SPHostNow();
    [p updateRequest:request]; __block BOOL ready=NO;
    for(int i=0;i<200&&!ready;i++){usleep(10000);dispatch_sync(p->_q, ^{ ready=p->_sessionReady && p->_resolved.scaleActive && p->_scaler && !p->_srInputScaler && p->_request.srInputPreset==0; });}
    CVPixelBufferRef frame=SPCreateBuffer(1280,720,kCVPixelFormatType_32BGRA);
    if (!ready || !frame) { if(frame) CVPixelBufferRelease(frame); NSDictionary *stats=[p stats]; [p stop]; return @{ @"ok":@NO,@"reason":@"MetalFX prepare or input allocation",@"stats":stats }; }
    CVPixelBufferLockBaseAddress(frame,0); uint8_t *base=(uint8_t *)CVPixelBufferGetBaseAddress(frame); size_t stride=CVPixelBufferGetBytesPerRow(frame);
    for(int y=0;y<720;y++)for(int x=0;x<1280;x++){uint8_t *px=base+y*stride+x*4;uint8_t value=((x/16+y/16)&1)?220:30;px[0]=px[1]=px[2]=value;px[3]=255;}
    CVPixelBufferUnlockBaseAddress(frame,0);
    NSDictionary *geometry=@{ @"generation":@1,@"windowID":@11,@"pid":@22,@"bufferWidth":@1280,@"bufferHeight":@720,
        @"screenRect":@[@0,@0,@1280,@720],@"contentRect":@[@0,@0,@1280,@720],@"scaleFactor":@1,@"contentScale":@1 };
    CVBufferSetAttachment(frame, CFSTR("app.openduckframe.capture.geometry"), (__bridge CFDictionaryRef)geometry, kCVAttachmentMode_ShouldNotPropagate);
    int64_t host=SPHostNow(); [p pushPixelBuffer:frame ptsNum:1 ptsDen:1 host:host generation:1];
    __block BOOL output=NO, baseline=NO;
    for(int i=0;i<400&&!output;i++){usleep(10000);dispatch_sync(p->_q, ^{ output=p->_lastEnhanced && CVPixelBufferGetWidth(p->_lastEnhanced)==2560 && CVPixelBufferGetHeight(p->_lastEnhanced)==1440 && sp::spCmp(p->_lastRedrawPts,sp::spMake(1,1))==0; baseline=p->_lastOriginal && CVPixelBufferGetWidth(p->_lastOriginal)==2560 && CVPixelBufferGetWidth(frame)==1280; });}
    CVPixelBufferRef changed=SPCreateBuffer(1280,720,kCVPixelFormatType_32BGRA); __block BOOL constraintStopped=NO;
    if (changed) {
        NSMutableDictionary *bad=[geometry mutableCopy]; bad[@"contentScale"]=@0.5;
        CVBufferSetAttachment(changed, CFSTR("app.openduckframe.capture.geometry"), (__bridge CFDictionaryRef)bad, kCVAttachmentMode_ShouldNotPropagate);
        [p pushPixelBuffer:changed ptsNum:2 ptsDen:1 host:SPHostNow() generation:1];
        for(int i=0;i<200&&!constraintStopped;i++){usleep(10000);dispatch_sync(p->_q, ^{ constraintStopped=p->_sourceSizeConstraintFailed && !p->_resolved.committed && !p->_resolved.scaleActive && p->_resolved.unavailableReason.length>0; });}
        CVPixelBufferRelease(changed);
    }
    NSDictionary *stats=[p stats];CVPixelBufferRelease(frame);[p stop];
    return @{ @"ok":@(ready&&output&&baseline&&constraintStopped), @"sourcePixels":@[@1280,@720], @"srInputPixels":@[@1280,@720], @"outputPixels":@[@2560,@1440], @"noPrescale":@(ready), @"actualGPUOutput":@(output), @"rawBaseline":@(baseline), @"changedGeometryStopped":@(constraintStopped), @"stats":stats, @"scope":@"synthetic same-frame metadata and production MetalFX queue; no AX, SCK, visible window or subjective quality" };
}

+ (NSDictionary<NSString *, id> *)runSRInputPipelineContract {
    NSMutableDictionary *result=[[self runSRPipelineContractWithPreset:720] mutableCopy];
    SPLiveProcessor *p=[[SPLiveProcessor alloc] init]; [p adoptSourceGeneration:1];
    dispatch_sync(p->_q, ^{ p->_width=2560; p->_height=1440; });
    SPLivePlanRequest *request=[[SPLivePlanRequest alloc] init]; request.scaleEnabled=YES; request.scaleEngine=SPLiveScaleLanczos; request.srInputPreset=720; request.outputWidth=1920; request.outputHeight=1080;
    [p updateRequest:request]; __block BOOL lanczos=NO, lowPrescale=NO;
    for(int i=0;i<100 && !lanczos;i++){usleep(10000);dispatch_sync(p->_q, ^{ lanczos=p->_sessionReady && p->_resolved.scaleActive && p->_request.srInputPreset==0 && !p->_srInputScaler && request.srInputPreset==720; });}
    SPLivePlanRequest *low=[request copy]; low.srInputPreset=0; low.interpolationEnabled=YES; low.engineID=@"apple.lowlatency";
    dispatch_sync(p->_q, ^{ lowPrescale=[p requestUsesLowPrescale:low width:2560 height:1440]; });
    [p stop]; result[@"lanczosKeepsSourceAndSavedChoice"] = @(lanczos); result[@"defaultLowPrescaleGate"] = @(lowPrescale);
    NSDictionary *resize=[self runAppleSRResizeContract]; result[@"appleSRResize"] = resize;
    NSDictionary *metal=[self runMetalFXSourceWindowContract]; result[@"metalFXSourceWindow"] = metal;
    result[@"ok"] = @([result[@"ok"] boolValue] && lanczos && lowPrescale && [resize[@"ok"] boolValue] && [metal[@"ok"] boolValue]); return result;
}
+ (NSDictionary<NSString *, id> *)runSRPipelineContract { return [self runSRPipelineContractWithPreset:0]; }

+ (NSDictionary<NSString *, id> *)runSessionContract {
    int schedule = spRunRateScheduleTests();
    SPLiveProcessor *processor = [[SPLiveProcessor alloc] init];
    CVPixelBufferRef frame = SPCreateBuffer(32, 32, kCVPixelFormatType_32BGRA);
    if (!frame) return @{@"ok": @NO, @"reason": @"buffer", @"scheduleFailures": @(schedule)};
    CVPixelBufferLockBaseAddress(frame, 0);
    memset(CVPixelBufferGetBaseAddress(frame), 40, CVPixelBufferGetBytesPerRow(frame) * 32);
    CVPixelBufferUnlockBaseAddress(frame, 0);
    const int64_t pts = 336876423129125LL;
    const int64_t den = 1000000000LL;
    [processor adoptSourceGeneration:1];
    dispatch_sync(processor->_q, ^{});
    [processor pushPixelBuffer:frame ptsNum:pts ptsDen:den host:SPHostNow() generation:1];
    dispatch_sync(processor->_q, ^{});
    NSDictionary *running = [processor stats];
    [processor stop];
    NSDictionary *stopped = [processor stats];
    [processor pushPixelBuffer:frame ptsNum:pts + 33333333 ptsDen:den host:SPHostNow() generation:1];
    dispatch_sync(processor->_q, ^{});
    NSDictionary *whileStopped = [processor stats];
    [processor adoptSourceGeneration:1];
    dispatch_sync(processor->_q, ^{});
    [processor pushPixelBuffer:frame ptsNum:pts + 66666666 ptsDen:den host:SPHostNow() generation:1];
    dispatch_sync(processor->_q, ^{});
    NSDictionary *rebound = [processor stats];
    [processor adoptSourceGeneration:2];
    dispatch_sync(processor->_q, ^{});
    [processor pushPixelBuffer:frame ptsNum:pts + 100000000 ptsDen:den host:SPHostNow() generation:1];
    dispatch_sync(processor->_q, ^{});
    NSDictionary *oldGeneration = [processor stats];
    [processor pushPixelBuffer:frame ptsNum:pts + 133333333 ptsDen:den host:SPHostNow() generation:2];
    dispatch_sync(processor->_q, ^{});
    NSDictionary *newGeneration = [processor stats];
    CVPixelBufferRelease(frame);
    BOOL firstAccepted = [running[@"stoppedDrops"] unsignedLongLongValue] == 0 &&
        [running[@"generationDrops"] unsignedLongLongValue] == 0;
    BOOL generationHeld = [stopped[@"sourceGeneration"] unsignedLongLongValue] == 1 && [stopped[@"stopped"] boolValue];
    BOOL droppedWhileStopped = [whileStopped[@"stoppedDrops"] unsignedLongLongValue] >= 1;
    BOOL resumed = [rebound[@"stopped"] boolValue] == NO &&
        [rebound[@"stoppedDrops"] unsignedLongLongValue] == 0 &&
        [rebound[@"sourceGeneration"] unsignedLongLongValue] == 1;
    BOOL oldRejected = [oldGeneration[@"generationDrops"] unsignedLongLongValue] >= 1 &&
        [oldGeneration[@"sourceGeneration"] unsignedLongLongValue] == 2;
    BOOL acceptedNew = [newGeneration[@"generationDrops"] unsignedLongLongValue] == [oldGeneration[@"generationDrops"] unsignedLongLongValue] &&
        [newGeneration[@"stopped"] boolValue] == NO;
    SPLiveProcessor *startOrder = [[SPLiveProcessor alloc] init];
    [startOrder adoptSourceGeneration:1];
    __block BOOL sourceOnlyPreview = NO;
    dispatch_sync(startOrder->_q, ^{ sourceOnlyPreview = !startOrder->_request.interpolationEnabled && !startOrder->_request.scaleEnabled; });
    [startOrder stop];
    SPLivePlanRequest *explicitStart = [[SPLivePlanRequest alloc] init];
    explicitStart.interpolationEnabled = YES;
    explicitStart.scaleEnabled = YES;
    explicitStart.engineID = @"rife.metal";
    explicitStart.modelID = @"rife-v4.25";
    explicitStart.rateKind = SPLiveRateMultiplier;
    explicitStart.multiplier = 2;
    // The UI queues generation before Start; the following queued callback
    // deliberately arrives late with the same generation, then an older one.
    [startOrder adoptSourceGeneration:2];
    [startOrder updateRequest:explicitStart];
    __block uint64_t pendingToken = 0;
    dispatch_sync(startOrder->_q, ^{ startOrder->_preparing = YES; pendingToken = startOrder->_prepareToken; });
    [startOrder adoptSourceGeneration:2];
    [startOrder adoptSourceGeneration:1];
    __block BOOL explicitIntentKept = NO, lateSameKept = NO, olderIgnored = NO;
    dispatch_sync(startOrder->_q, ^{
        explicitIntentKept = startOrder->_request.interpolationEnabled && startOrder->_request.scaleEnabled &&
            [startOrder->_request.engineID isEqualToString:@"rife.metal"] && !startOrder->_stopped;
        lateSameKept = startOrder->_preparing && startOrder->_prepareToken == pendingToken;
        olderIgnored = startOrder->_sourceGeneration == 2;
    });
    [startOrder stop];
    BOOL ok = schedule == 0 && firstAccepted && generationHeld && droppedWhileStopped && resumed && oldRejected && acceptedNew &&
        sourceOnlyPreview && explicitIntentKept && lateSameKept && olderIgnored;
    return @{
        @"ok": @(ok),
        @"scheduleFailures": @(schedule),
        @"firstAccepted": @(firstAccepted),
        @"generationHeldAcrossStop": @(generationHeld),
        @"droppedWhileStopped": @(droppedWhileStopped),
        @"sameGenerationRestart": @(resumed),
        @"oldGenerationRejected": @(oldRejected),
        @"newGenerationAccepted": @(acceptedNew),
        @"sourceOnlyPreview": @(sourceOnlyPreview),
        @"explicitStartIntentKept": @(explicitIntentKept),
        @"lateSameGenerationKeepsPendingPrepare": @(lateSameKept),
        @"olderGenerationNotificationIgnored": @(olderIgnored),
        @"startOrderTestNote": @"Simulated pending-prepare state; real engine restart still needs window capture verification.",
        @"stoppedGeneration": stopped[@"sourceGeneration"] ?: @0,
        @"reboundGeneration": rebound[@"sourceGeneration"] ?: @0,
    };
}

- (void)openProbeWindowMinNum:(int64_t)num den:(int64_t)den aggregate:(BOOL)aggregate {
    dispatch_sync(_q, ^{
        self->_probeWindowOpen = YES;
        self->_probeMinPts = sp::spMake(num, den);
        self->_probeAggregateOnly = aggregate;
        self->_probeMonotonic = YES;
        self->_probeSizeOK = YES;
        self->_probeHaveLast = NO;
        self->_measuredScheduled = 0;
        self->_presentedSource = 0;
        self->_presentedSynthetic = 0;
        self->_presentedCallbacks = 0;
        self->_scheduledSynthetic = 0;
        self->_deadlineDrops = 0;
        self->_queueDrops = 0;
        self->_renderDrops = 0;
        self->_syntheticOK = 0;
        self->_syntheticFail = 0;
        self->_submitted = 0;
        self->_peakSlots = 0;
        self->_centerSamples = 0;
        self->_centerSampleNs = 0;
        self->_latencyNs.clear();
        self->_frcNs.clear();
        self->_scaleNs.clear();
        self->_transferNs.clear();
        self->_queueNs.clear();
        self->_playheadNs.clear();
        [self->_probeOutputs removeAllObjects];
        self->_windowStart = SPHostNow();
    });
}

+ (NSDictionary<NSString *, id> *)runProbe {
    NSMutableDictionary *report = [NSMutableDictionary dictionary];
    int schedule = spRunRateScheduleTests();
    report[@"scheduleFailures"] = @(schedule);
    report[@"frcAvailable"] = @([SPFRCEngine isAvailable]);
    NSMutableDictionary *capability = [NSMutableDictionary dictionary];
    if (@available(macOS 26.0, *)) {
        capability[@"lowLatencySupported"] = @(VTLowLatencyFrameInterpolationConfiguration.isSupported);
        id temporal1 = [[VTLowLatencyFrameInterpolationConfiguration alloc] initWithFrameWidth:1280 frameHeight:720 numberOfInterpolatedFrames:1];
        id temporal2 = [[VTLowLatencyFrameInterpolationConfiguration alloc] initWithFrameWidth:1280 frameHeight:720 numberOfInterpolatedFrames:2];
        id spatial = [[VTLowLatencyFrameInterpolationConfiguration alloc] initWithFrameWidth:1280 frameHeight:720 spatialScaleFactor:2];
        capability[@"lowLatencyTemporal1"] = @(temporal1 != nil);
        capability[@"lowLatencyTemporal2"] = @(temporal2 != nil);
        capability[@"lowLatencySpatial2x"] = @(spatial != nil);
        capability[@"lowLatencyNote"] = @"低延迟接口未接入实时路径。X3 的 1/3、2/3 不在它的等距相位集合里。";
        if (@available(macOS 27.0, *)) {
            capability[@"lowLatencyMaxDimensionScale1"] = @([VTLowLatencyFrameInterpolationConfiguration maximumDimensionForSpatialScaleFactor:1]);
        }
        capability[@"superResolutionScaleFactors"] = VTSuperResolutionScalerConfiguration.supportedScaleFactors ?: @[];
        VTSuperResolutionScalerConfiguration *superConfig = [[VTSuperResolutionScalerConfiguration alloc]
            initWithFrameWidth:1280 frameHeight:720 scaleFactor:2
            inputType:VTSuperResolutionScalerConfigurationInputTypeVideo usePrecomputedFlow:NO
            qualityPrioritization:VTSuperResolutionScalerConfigurationQualityPrioritizationNormal
            revision:VTSuperResolutionScalerConfigurationRevision1];
        capability[@"superResolutionConfig"] = @(superConfig != nil);
        if (superConfig) capability[@"superResolutionModelStatus"] = @(superConfig.configurationModelStatus);
        capability[@"superResolutionNote"] = @"Apple 视频超分未接入本轮。";
    }
    capability[@"metalFXDevice"] = @([MTLFXSpatialScalerDescriptor supportsDevice:MTLCreateSystemDefaultDevice()]);
    report[@"capability"] = capability;
    if (![SPFRCEngine isAvailable]) {
        report[@"combination"] = @{@"ok": @NO, @"reason": @"FRC unavailable"};
        return report;
    }
    SPLiveProcessor *processor = [[SPLiveProcessor alloc] init];
    processor->_probeOutputs = [NSMutableArray array];
    processor->_probeGate = dispatch_semaphore_create(0);
    processor->_probeSyntheticGoal = 20;
    SPLivePlanRequest *request = [[SPLivePlanRequest alloc] init];
    request.interpolationEnabled = YES;
    request.quality = SPFRCQualityNormal;
    request.rateKind = SPLiveRateMultiplier;
    request.multiplier = 2;
    request.scaleEnabled = YES;
    request.scaleEngine = SPLiveScaleLanczos;
    request.outputWidth = 1920;
    request.outputHeight = 1080;
    request.viewMode = SPLiveViewCompare;
    request.displayRefreshHz = 60;
    processor->_request = request;
    NSError *error = nil;
    BOOL ready = [processor installSynchronouslyWidth:1280 height:720 error:&error];
    report[@"sessionReady"] = @(ready);
    if (!ready) {
        report[@"combination"] = @{@"ok": @NO, @"reason": error.localizedDescription ?: @"session"};
        return report;
    }
    __block SPLivePreviewView *probeView = nil;
    __block NSWindow *probeWindow = nil;
    void (^makeWindow)(void) = ^{
        probeView = [[SPLivePreviewView alloc] initWithFrame:NSMakeRect(0, 0, 640, 360)];
        probeWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(120, 120, 640, 360)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                     backing:NSBackingStoreBuffered defer:NO];
        probeWindow.title = @"OpenDuckFrame presentation probe";
        probeWindow.contentView = probeView;
        [probeWindow orderFrontRegardless];
        [probeView refreshVisibilitySnapshot];
        processor.preview = probeView;
        [processor installPresentationHooks];
    };
    if ([NSThread isMainThread]) makeWindow();
    else dispatch_sync(dispatch_get_main_queue(), makeWindow);
    [probeView setGeneration:processor->_sourceGeneration];
    uint64_t probeGeneration = processor->_sourceGeneration;
    const int warmup = 30;
    const int measured = 300;
    const int total = warmup + measured;
    CVPixelBufferRef ring[20];
    for (int i = 0; i < 20; ++i) ring[i] = [self syntheticFrame:i];
    int64_t interval = SPRationalToHost(sp::spMake(1, 30));
    int64_t t0 = SPHostNow() + interval;
    NSMutableArray<NSNumber *> *jitter = [NSMutableArray array];
    int64_t firstHost = 0, lastHost = 0;
    for (int i = 0; i < total; ++i) {
        if (i == warmup) [processor openProbeWindowMinNum:warmup den:30 aggregate:NO];
        int64_t deadline = t0 + (int64_t)i * interval;
        SPWaitUntilHost(deadline);
        int64_t host = SPHostNow();
        if (i >= warmup) {
            [jitter addObject:@(SPHostToNs(host - deadline))];
            if (i == warmup) firstHost = host;
            lastHost = host;
        }
        [processor pushPixelBuffer:ring[i % 20] ptsNum:i ptsDen:30 host:host generation:probeGeneration];
    }
    for (int wait = 0; wait < 150; ++wait) {
        __block int inflight = 1;
        __block int slots = 1;
        dispatch_sync(processor->_q, ^{
            inflight = processor->_inflight;
            slots = (int)processor->_slots.size() + (int)processor->_pending.size();
        });
        if (inflight == 0 && slots == 0) break;
        usleep(20000);
    }
    usleep(150000);
    NSArray *outputs = [processor->_probeOutputs copy];
    NSDictionary *liveStats = [processor stats];
    BOOL monotonic = YES;
    int syntheticCount = 0;
    BOOL compareDiffers = NO;
    NSDictionary *mid = nil;
    long long previousNum = 0, previousDen = 1;
    BOOL havePrevious = NO;
    std::vector<double> latencies;
    for (NSDictionary *item in outputs) {
        long long num = [item[@"ptsNum"] longLongValue];
        long long den = [item[@"ptsDen"] longLongValue];
        if (havePrevious) {
            __int128 leftPts = (__int128)previousNum * den;
            __int128 rightPts = (__int128)num * previousDen;
            if (leftPts >= rightPts) monotonic = NO;
        }
        previousNum = num;
        previousDen = den;
        havePrevious = YES;
        double latencyMs = [item[@"latencyMs"] doubleValue];
        if (latencyMs >= 0) latencies.push_back(latencyMs);
        if ([item[@"synthetic"] boolValue]) {
            syntheticCount += 1;
            if (!mid) mid = item;
            double enhancedCenter = [item[@"enhancedCenter"] doubleValue];
            double originalCenter = [item[@"originalCenter"] doubleValue];
            if (enhancedCenter >= 0 && originalCenter >= 0 && fabs(enhancedCenter - originalCenter) > 2.0) compareDiffers = YES;
        }
    }
    std::sort(latencies.begin(), latencies.end());
    double p95 = latencies.empty() ? -1 : latencies[(latencies.size() - 1) * 95 / 100];
    BOOL sizeOK = outputs.count > 0;
    for (NSDictionary *item in outputs) {
        if ([item[@"width"] intValue] != 1920 || [item[@"height"] intValue] != 1080) sizeOK = NO;
    }
    double mediaSec = (double)(measured - 1) / 30.0;
    double spanSec = firstHost > 0 && lastHost > firstHost ? (double)SPHostToNs(lastHost - firstHost) / 1e9 : 0;
    double inputFps = spanSec > 0 ? (double)(measured - 1) / spanSec : 0;
    double driftMs = (spanSec - mediaSec) * 1000.0;
    std::vector<int64_t> jitterAbs;
    for (NSNumber *value in jitter) {
        int64_t sample = value.longLongValue;
        jitterAbs.push_back(sample < 0 ? -sample : sample);
    }
    BOOL clockOK = inputFps >= 29.5 && inputFps <= 30.5 && fabs(driftMs) < 80.0;
    uint64_t scheduled = [liveStats[@"measuredScheduled"] unsignedLongLongValue];
    double coverage = scheduled > 0 ? (double)syntheticCount / (double)scheduled : 0;
    BOOL performanceOK = clockOK && scheduled > 0 && coverage >= 0.95 && p95 >= 0 && p95 <= 100.0;
    BOOL functionalOK = ready && sizeOK && monotonic && compareDiffers && syntheticCount > 0;
    NSString *bottleneck = @"none";
    if (!performanceOK) {
        double frcP95 = [liveStats[@"frcP95ms"] doubleValue];
        double scaleP95 = [liveStats[@"scaleP95ms"] doubleValue];
        double transferP95 = [liveStats[@"transferP95ms"] doubleValue];
        double queueP95 = [liveStats[@"queueP95ms"] doubleValue];
        double playheadP95 = [liveStats[@"playheadP95ms"] doubleValue];
        if (!clockOK) bottleneck = @"probe-clock";
        else if (frcP95 >= scaleP95 && frcP95 >= transferP95 && frcP95 >= 25.0) bottleneck = @"frc";
        else if (scaleP95 + transferP95 >= 20.0) bottleneck = @"scale-or-transfer";
        else if ([liveStats[@"queueDrops"] unsignedLongLongValue] > 0 || queueP95 > 40.0) bottleneck = @"queue";
        else if (playheadP95 > 20.0) bottleneck = @"playhead";
        else if (p95 > 100.0) bottleneck = @"capture-to-present";
        else bottleneck = @"coverage";
    }
    NSMutableArray *sample = [NSMutableArray array];
    for (NSDictionary *item in outputs) {
        if ([item[@"enhancedCenter"] doubleValue] >= 0 || sample.count < 4) [sample addObject:item];
        if (sample.count >= 16) break;
    }
    NSDictionary *clock = @{
        @"warmupFrames": @(warmup),
        @"measuredFrames": @(measured),
        @"inputFps": @(inputFps),
        @"hostSpanSec": @(spanSec),
        @"mediaSpanSec": @(mediaSec),
        @"driftMs": @(driftMs),
        @"jitterP95ms": @(SPPercentileMs(jitterAbs)),
        @"absoluteGrid": @YES,
        @"clockOK": @(clockOK),
    };
    report[@"clock"] = clock;
    report[@"liveStats"] = liveStats;
    report[@"outputSample"] = sample;
    report[@"stages"] = @{
        @"frcP95ms": liveStats[@"frcP95ms"] ?: @(-1),
        @"scaleP95ms": liveStats[@"scaleP95ms"] ?: @(-1),
        @"transferP95ms": liveStats[@"transferP95ms"] ?: @(-1),
        @"queueP95ms": liveStats[@"queueP95ms"] ?: @(-1),
        @"playheadP95ms": liveStats[@"playheadP95ms"] ?: @(-1),
        @"presentP95ms": @(p95),
        @"delayMs": liveStats[@"delayMs"] ?: @(-1),
        @"delayClamped": liveStats[@"delayClamped"] ?: @NO,
        @"slotCap": liveStats[@"slotCap"] ?: @0,
        @"peakSlots": liveStats[@"peakSlots"] ?: @0,
        @"centerSampleMs": liveStats[@"centerSampleMs"] ?: @0,
        @"centerSamples": liveStats[@"centerSamples"] ?: @0,
        @"bottleneck": bottleneck,
    };
    BOOL fiveMinuteOK = YES;
    if (performanceOK) {
        const int longFrames = 30 * 60 * 5;
        int64_t longT0 = SPHostNow() + interval;
        int64_t longFirst = 0, longLast = 0;
        NSMutableArray<NSNumber *> *longJitter = [NSMutableArray array];
        [processor openProbeWindowMinNum:total den:30 aggregate:YES];
        for (int i = 0; i < longFrames; ++i) {
            int64_t deadline = longT0 + (int64_t)i * interval;
            SPWaitUntilHost(deadline);
            int64_t host = SPHostNow();
            if (i == 0) longFirst = host;
            longLast = host;
            [longJitter addObject:@(SPHostToNs(host - deadline))];
            int frameIndex = total + i;
            [processor pushPixelBuffer:ring[frameIndex % 20] ptsNum:frameIndex ptsDen:30 host:host generation:probeGeneration];
        }
        for (int wait = 0; wait < 150; ++wait) {
            __block int inflight = 1;
            __block int slots = 1;
            dispatch_sync(processor->_q, ^{
                inflight = processor->_inflight;
                slots = (int)processor->_slots.size() + (int)processor->_pending.size();
            });
            if (inflight == 0 && slots == 0) break;
            usleep(20000);
        }
        usleep(150000);
        NSDictionary *longStats = [processor stats];
        double longMedia = (double)(longFrames - 1) / 30.0;
        double longSpan = longLast > longFirst ? (double)SPHostToNs(longLast - longFirst) / 1e9 : 0;
        double longFps = longSpan > 0 ? (double)(longFrames - 1) / longSpan : 0;
        double longDrift = (longSpan - longMedia) * 1000.0;
        std::vector<int64_t> longAbs;
        for (NSNumber *value in longJitter) {
            int64_t sampleValue = value.longLongValue;
            longAbs.push_back(sampleValue < 0 ? -sampleValue : sampleValue);
        }
        BOOL longClockOK = longFps >= 29.5 && longFps <= 30.5 && fabs(longDrift) < 250.0;
        uint64_t longScheduled = [longStats[@"measuredScheduled"] unsignedLongLongValue];
        uint64_t longPresented = [longStats[@"presentedSynthetic"] unsignedLongLongValue];
        double longCoverage = longScheduled > 0 ? (double)longPresented / (double)longScheduled : 0;
        double longP95 = [longStats[@"p95ms"] doubleValue];
        __block BOOL longMonotonic = NO;
        __block BOOL longSize = NO;
        dispatch_sync(processor->_q, ^{
            longMonotonic = processor->_probeMonotonic;
            longSize = processor->_probeSizeOK && processor->_presentedCallbacks > 0;
        });
        fiveMinuteOK = longClockOK && longMonotonic && longSize && longScheduled > 0 && longCoverage >= 0.95 && longP95 >= 0 && longP95 <= 100.0;
        report[@"fiveMinute"] = @{
            @"ran": @YES,
            @"frames": @(longFrames),
            @"inputFps": @(longFps),
            @"hostSpanSec": @(longSpan),
            @"mediaSpanSec": @(longMedia),
            @"driftMs": @(longDrift),
            @"jitterP95ms": @(SPPercentileMs(longAbs)),
            @"coverage": @(longCoverage),
            @"scheduledSynthetic": @(longScheduled),
            @"presentedSynthetic": @(longPresented),
            @"p95ms": @(longP95),
            @"monotonic": @(longMonotonic),
            @"size": @(longSize),
            @"ok": @(fiveMinuteOK),
            @"liveStats": longStats,
        };
    } else {
        fiveMinuteOK = NO;
        report[@"fiveMinute"] = @{@"ran": @NO, @"reason": @"300-frame performance not met"};
    }
    for (int i = 0; i < 20; ++i) CVPixelBufferRelease(ring[i]);
    BOOL staleIgnored = YES;
    report[@"combination"] = @{
        @"functionalOK": @(functionalOK),
        @"performanceOK": @(performanceOK),
        @"fiveMinuteOK": @(fiveMinuteOK),
        @"ok": @(functionalOK && performanceOK && fiveMinuteOK),
        @"coverage": @(coverage),
        @"scheduledSynthetic": @(scheduled),
        @"outputCount": @(outputs.count),
        @"syntheticPresented": @(syntheticCount),
        @"p95ms": @(p95),
        @"monotonic": @(monotonic),
        @"compareDiffers": @(compareDiffers),
        @"staleIgnored": @(staleIgnored),
        @"mid": mid ?: @{},
        @"midpointBetween": @(compareDiffers),
        @"size": @(sizeOK),
        @"clockOK": @(clockOK),
        @"bottleneck": bottleneck,
        @"colorPath": @"sdr.bt709.8bit",
        @"presentationEndpoint": @"preview",
        @"realWindowCapture": @NO,
        @"note": @"可见预览窗口上的合成运动呈现。不是系统选窗验收。迟到帧仍留在覆盖率分母里。",
    };

    for (int wait = 0; wait < 40 && processor->_inflight > 0; ++wait) usleep(25000);
    CVPixelBufferRef a = [self syntheticFrame:0];
    CVPixelBufferRef b = [self syntheticFrame:1];
    __block CVPixelBufferRef yuvA = NULL;
    __block CVPixelBufferRef yuvB = NULL;
    dispatch_sync(processor->_q, ^{
        yuvA = [processor transfer:a format:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange];
        yuvB = [processor transfer:b format:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange];
    });
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    __block NSUInteger x3Count = 0, x4Count = 0;
    __block BOOL x3Distinct = NO, x4Distinct = NO;
    __block double x3a = -1, x3b = -1, x4a = -1, x4b = -1;
    [processor->_engine submitPhasesWithFrameA:yuvA frameB:yuvB phases:@[@(1.f / 3.f), @(2.f / 3.f)] sequential:NO token:3
                                     completion:^(uint64_t token, NSArray<SPOwnedPixelBuffer *> *outputs3, double latency, NSError *phaseError) {
        (void)token; (void)latency;
        dispatch_async(processor->_q, ^{
            x3Count = phaseError ? 0 : outputs3.count;
            if (outputs3.count == 2) {
                CVPixelBufferRef d0 = [processor transfer:outputs3[0].buffer format:kCVPixelFormatType_32BGRA];
                CVPixelBufferRef d1 = [processor transfer:outputs3[1].buffer format:kCVPixelFormatType_32BGRA];
                x3a = SPWhiteCenterX(d0);
                x3b = SPWhiteCenterX(d1);
                x3Distinct = fabs(x3a - x3b) > 1.0;
                if (d0) CVPixelBufferRelease(d0);
                if (d1) CVPixelBufferRelease(d1);
            }
            [processor->_engine submitPhasesWithFrameA:yuvA frameB:yuvB phases:@[@0.25f, @0.5f, @0.75f] sequential:NO token:4
                                             completion:^(uint64_t token4, NSArray<SPOwnedPixelBuffer *> *outputs4, double latency4, NSError *error4) {
                (void)token4; (void)latency4;
                dispatch_async(processor->_q, ^{
                    x4Count = error4 ? 0 : outputs4.count;
                    if (outputs4.count == 3) {
                        CVPixelBufferRef d0 = [processor transfer:outputs4[0].buffer format:kCVPixelFormatType_32BGRA];
                        CVPixelBufferRef d2 = [processor transfer:outputs4[2].buffer format:kCVPixelFormatType_32BGRA];
                        x4a = SPWhiteCenterX(d0);
                        x4b = SPWhiteCenterX(d2);
                        x4Distinct = fabs(x4a - x4b) > 1.0;
                        if (d0) CVPixelBufferRelease(d0);
                        if (d2) CVPixelBufferRelease(d2);
                    }
                    dispatch_semaphore_signal(gate);
                });
            }];
        });
    }];
    dispatch_semaphore_wait(gate, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC));
    report[@"phases"] = @{
        @"x3Count": @(x3Count), @"x3Distinct": @(x3Distinct), @"x3Centers": @[@(x3a), @(x3b)],
        @"x4Count": @(x4Count), @"x4Distinct": @(x4Distinct), @"x4Centers": @[@(x4a), @(x4b)],
    };
    CVPixelBufferRelease(a);
    CVPixelBufferRelease(b);
    if (yuvA) CVPixelBufferRelease(yuvA);
    if (yuvB) CVPixelBufferRelease(yuvB);

    CVPixelBufferRef dot = SPCreateBuffer(1280, 720, kCVPixelFormatType_32BGRA);
    CVPixelBufferLockBaseAddress(dot, 0);
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(dot);
    size_t stride = CVPixelBufferGetBytesPerRow(dot);
    memset(base, 0, stride * 720);
    uint8_t *pixel = base + 100 * stride + 100 * 4;
    pixel[0] = pixel[1] = pixel[2] = 255;
    pixel[3] = 255;
    CVPixelBufferUnlockBaseAddress(dot, 0);
    __block CVPixelBufferRef halo = NULL;
    dispatch_sync(processor->_q, ^{
        halo = [processor->_scaler scaleBuffer:dot error:NULL];
    });
    int nonzero = 0;
    if (halo) {
        CVPixelBufferLockBaseAddress(halo, kCVPixelBufferLock_ReadOnly);
        uint8_t *out = (uint8_t *)CVPixelBufferGetBaseAddress(halo);
        size_t outStride = CVPixelBufferGetBytesPerRow(halo);
        for (int y = 140; y < 170; ++y) {
            uint8_t *row = out + y * outStride;
            for (int x = 140; x < 170; ++x) if (row[x * 4] > 8) nonzero += 1;
        }
        CVPixelBufferUnlockBaseAddress(halo, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferRelease(halo);
    }
    report[@"lanczos"] = @{@"nonzeroNeighborhood": @(nonzero), @"spread": @(nonzero >= 4)};
    CVPixelBufferRelease(dot);

    NSError *fxError = nil;
    SPSpatialScaler *fx = [[SPSpatialScaler alloc] initWithDevice:MTLCreateSystemDefaultDevice() inputW:1280 inputH:720
                                                         outputW:1920 outputH:1080 engine:SPLiveScaleMetalFX error:&fxError];
    CVPixelBufferRef fxFrame = [self syntheticFrame:2];
    CVPixelBufferRef fxOut = [fx scaleBuffer:fxFrame error:&fxError];
    report[@"metalFX"] = @{
        @"created": @(fx != nil),
        @"outputWidth": @(fxOut ? (int)CVPixelBufferGetWidth(fxOut) : 0),
        @"outputHeight": @(fxOut ? (int)CVPixelBufferGetHeight(fxOut) : 0),
        @"error": fxError.localizedDescription ?: @"",
    };
    if (fxOut) CVPixelBufferRelease(fxOut);
    CVPixelBufferRelease(fxFrame);
    dispatch_sync(processor->_q, ^{
        processor->_probeAggregateOnly = NO;
        processor->_probeWindowOpen = NO;
        [processor->_probeOutputs removeAllObjects];
    });
    NSUInteger beforeStop = processor->_probeOutputs.count;
    [processor stop];
    CVPixelBufferRef stale = [self syntheticFrame:3];
    [processor pushPixelBuffer:stale ptsNum:0 ptsDen:30 host:SPHostNow() generation:probeGeneration];
    CVPixelBufferRelease(stale);
    usleep(200000);
    BOOL staleOK = processor->_probeOutputs.count == beforeStop;
    report[@"staleIgnored"] = @(staleOK);
    NSMutableDictionary *combination = [report[@"combination"] mutableCopy];
    combination[@"staleIgnored"] = @(staleOK);
    combination[@"ok"] = @([combination[@"ok"] boolValue] && staleOK);
    report[@"combination"] = combination;
    if (probeWindow) {
        dispatch_async(dispatch_get_main_queue(), ^{ [probeWindow orderOut:nil]; });
    }
    return report;
}

@end

#if ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC
#include "SPAirCapacityExport.inc"
#endif
