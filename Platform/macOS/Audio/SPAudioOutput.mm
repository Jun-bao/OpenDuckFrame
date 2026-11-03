#include "SPAudioOutput.h"
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>
#import <CoreAudio/CoreAudio.h>
#include <mach/mach_time.h>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <mutex>
#include <vector>
#include "SPRuntimeGates.hpp"
#include "SPTimeStretch.hpp"
#include "SPAudioPeak.hpp"
#include "SPAudioChannelMap.hpp"

static const int kSampleRate = 48000;

static const int kMaxChannels = sp::kSPAudioMaxChannels;
static const int kRingFrames = 24000;

static const int kHistFrames = 48000 * 3;
// Ramp gain changes over 20 ms. The zero-lookahead limiter attacks immediately
// and releases toward unity over at most 100 ms. A ceiling of 1 preserves the
// bit-exact unity bypass; this is sample-peak protection, not true-peak limiting.
static const int kGainRampFrames = kSampleRate * 20 / 1000;
static constexpr float kLimiterCeiling = 1.0f;
static constexpr float kLimiterReleaseStep = 1.0f / (kSampleRate * 0.100f);

typedef struct {

    float *buf;
    std::atomic<int64_t> readIdx;
    std::atomic<int64_t> writeIdx;
} SPSCRing;

@interface SPAudioOutput () {
    AudioUnit _unit;
    SPSCRing _ring;
    std::atomic<int64_t> _playedFrames;
    std::atomic<bool> _running;
    std::atomic<bool> _startRequested;
    std::atomic<bool> _desiredRunning;

    std::atomic<bool> _writeAbort;
    std::atomic<bool> _dead;
    std::atomic<int32_t> _epoch;

    std::atomic<int64_t> _discardUpTo;
    std::mutex _spaceMtx;
    std::condition_variable _spaceCv;

    std::mutex _publishMtx;
    double _rate;
    float *_rateScratch;
    float _resamplePos;
    SPTimeStretcher *_stretch;
    BOOL _stretchActive;

    float *_hist;
    int64_t _histTotal;
    struct SPRateSegment { int64_t outStart; int64_t inStart; double rate; };
    std::vector<SPRateSegment> _segments;

    std::atomic<bool> _switchPending;
    std::atomic<uint32_t> _switchSeq;
    std::atomic<uint32_t> _switchAppliedSeq;
    std::atomic<int64_t> _switchPlayedFrame;
    double _switchRate;
    std::atomic<int32_t> _lastRenderFrames;
    BOOL _regenerating;
    int32_t _lastSeenEpoch;
    std::atomic<bool> _ready;

    std::atomic<float> _targetGain;
    float _gainCurrent;
    float _gainTargetSnapshot;
    float _gainStep;
    int32_t _gainRampRemaining;
    float _limiterGain; // Stereo-linked to preserve the image.
    int32_t _dspEpoch;  // Reset the envelope across seek/reset boundaries.
    // Publish a generation before each real start so changes made while paused
    // begin from a fresh fade rather than stale render-thread state.
    std::atomic<uint32_t> _dspStartGeneration;
    uint32_t _dspStartSeen;

    std::atomic<uint32_t> _clkSeq;
    std::atomic<int64_t> _clkHostUs;
    std::atomic<int64_t> _clkFramesStart;
    std::atomic<int32_t> _clkFramesReal;
    std::atomic<int64_t> _clkReadIdx;

    std::atomic<int> _channels;
    std::mutex _layoutMtx;
    sp::AudioOutputLayout _negotiated;
    sp::AudioOutputLayout _applied;
    bool _negotiatedOnce;
    bool _appliedOnce;
    bool _layoutPending;
    AudioDeviceID _boundDevice;
    bool _listenerInstalled;
    AudioObjectPropertyListenerBlock _devListener;
    bool _mapInstalled;
    bool _unitBroken;

    int _writerCh;
}
@end

static inline int64_t spAudioHostUs(uint64_t ticks) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (int64_t)(ticks * tb.numer / tb.denom / 1000);
}

@implementation SPAudioOutput

- (instancetype)init {
    self = [super init];
    if (self) {
        _unit = NULL;
        _ring.readIdx.store(0);
        _ring.writeIdx.store(0);
        _playedFrames.store(0);
        _running.store(false);
        _startRequested.store(false);
        _writeAbort.store(false);
        _dead.store(false);
        _epoch.store(0);
        _discardUpTo.store(-1);
        _rate = 1.0;
        _resamplePos = 0;
        _lastSeenEpoch = 0;
        _ready.store(false);
        _targetGain.store(1.0f);
        _gainCurrent = 0.0f; // Fade in the first start as well.
        _gainTargetSnapshot = 1.0f;
        _gainStep = 1.0f / kGainRampFrames;
        _gainRampRemaining = kGainRampFrames;
        _limiterGain = 1.0f;
        _dspEpoch = 0;
        _dspStartGeneration.store(0);
        _dspStartSeen = 0;
        _clkSeq.store(0);
        _clkHostUs.store(0);
        _clkFramesStart.store(0);
        _clkFramesReal.store(0);
        _clkReadIdx.store(0);
        _ring.buf = (float *)calloc((size_t)kRingFrames * kMaxChannels, sizeof(float));
        _channels.store(2);
        _negotiatedOnce = false;
        _appliedOnce = false;
        _layoutPending = false;
        _boundDevice = kAudioObjectUnknown;
        _listenerInstalled = false;
        _devListener = nil;
        _mapInstalled = false;
        _unitBroken = false;
        _writerCh = 0;
        sp::initStereo(&_negotiated, 0);
        sp::initStereo(&_applied, 0);
    }
    return self;
}

- (void)dealloc {
    [self stop];
    [self removeDeviceListener];
    if (_unit) {
        AudioUnitUninitialize(_unit);
        AudioComponentInstanceDispose(_unit);
    }
    [self releaseSessionScratch];
    free(_ring.buf);
    _ring.buf = nullptr;
}

// Ownership handoff, not a concurrent trim: core callers hold the lifecycle
// lock, have joined the sole PCM writer, and have cancelled AudioUnit playback.
// The ring/clock/rate request authority and prewarmed unit deliberately survive.
- (void)releaseSessionScratch {
    // setup may briefly finish a previously accepted start after stop returns,
    // then immediately undo it on seeing desiredRunning=false. Its render path
    // never reads these writer-only buffers; do not assert that transient state.
    NSAssert(!_desiredRunning.load(), @"Session scratch requires a stop request");
    free(_rateScratch);
    _rateScratch = nullptr;
    free(_hist);
    _hist = nullptr;
    delete _stretch;
    _stretch = nullptr;
    _stretchActive = NO;
    _histTotal = 0;
    _resamplePos = 0;
    _regenerating = NO;
    _writerCh = 0;
    // reset on the next open owns epoch/segment invalidation; do not reset the
    // media clock or applied/requested rate here as a side effect of freeing.
}

static bool spPitchShiftResampler(void) {
    static const bool on = spAutomation() && getenv("SP_AUDIO_PITCHSHIFT") != nullptr;
    return on;
}

#pragma mark - Audio device discovery

static AudioDeviceID spDefaultOutputDevice(void) {
    AudioObjectPropertyAddress a = { kAudioHardwarePropertyDefaultOutputDevice,
                                     kAudioObjectPropertyScopeGlobal,
                                     kAudioObjectPropertyElementMain };
    AudioDeviceID dev = kAudioObjectUnknown;
    UInt32 sz = sizeof(dev);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &sz, &dev) != noErr) {
        return kAudioObjectUnknown;
    }
    return dev;
}

static UInt32 spDeviceOutputChannels(AudioDeviceID dev) {
    AudioObjectPropertyAddress a = { kAudioDevicePropertyStreamConfiguration,
                                     kAudioObjectPropertyScopeOutput,
                                     kAudioObjectPropertyElementMain };
    UInt32 sz = 0;
    if (AudioObjectGetPropertyDataSize(dev, &a, 0, NULL, &sz) != noErr || sz < sizeof(AudioBufferList)) return 0;
    std::vector<uint8_t> raw(sz);
    AudioBufferList *abl = (AudioBufferList *)raw.data();
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, abl) != noErr) return 0;
    UInt32 n = 0;
    for (UInt32 i = 0; i < abl->mNumberBuffers; i++) n += abl->mBuffers[i].mNumberChannels;
    return n;
}

static std::vector<uint32_t> spDeviceOutputLabels(AudioDeviceID dev, UInt32 channels) {
    std::vector<uint32_t> labels(channels, (uint32_t)kAudioChannelLabel_Unknown);
    AudioObjectPropertyAddress a = { kAudioDevicePropertyPreferredChannelLayout,
                                     kAudioObjectPropertyScopeOutput,
                                     kAudioObjectPropertyElementMain };
    UInt32 sz = 0;
    if (AudioObjectGetPropertyDataSize(dev, &a, 0, NULL, &sz) != noErr || sz < sizeof(AudioChannelLayout)) {
        return labels;
    }
    std::vector<uint8_t> raw(sz);
    AudioChannelLayout *acl = (AudioChannelLayout *)raw.data();
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, acl) != noErr) return labels;
    auto fromDescriptions = [&](const AudioChannelLayout *l) {
        UInt32 n = l->mNumberChannelDescriptions;
        if (n > channels) n = channels;
        for (UInt32 i = 0; i < n; i++) labels[i] = l->mChannelDescriptions[i].mChannelLabel;
    };
    if (acl->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions) {
        fromDescriptions(acl);
    } else if (acl->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelBitmap) {

        UInt32 idx = 0;
        for (UInt32 b = 0; b < 18 && idx < channels; b++) {
            if (acl->mChannelBitmap & (1u << b)) labels[idx++] = b + 1;
        }
    } else {
        AudioChannelLayoutTag tag = acl->mChannelLayoutTag;
        UInt32 esz = 0;
        if (AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForTag,
                                       sizeof(tag), &tag, &esz) == noErr && esz >= sizeof(AudioChannelLayout)) {
            std::vector<uint8_t> eraw(esz);
            AudioChannelLayout *el = (AudioChannelLayout *)eraw.data();
            if (AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForTag,
                                       sizeof(tag), &tag, &esz, el) == noErr) {
                fromDescriptions(el);
            }
        }
    }
    return labels;
}

static AudioDeviceID spFindOutputDeviceByName(const char *needle) {
    if (!needle || !*needle) return kAudioObjectUnknown;
    AudioObjectPropertyAddress a = { kAudioHardwarePropertyDevices,
                                     kAudioObjectPropertyScopeGlobal,
                                     kAudioObjectPropertyElementMain };
    UInt32 sz = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &sz) != noErr || !sz) {
        return kAudioObjectUnknown;
    }
    std::vector<AudioDeviceID> devs(sz / sizeof(AudioDeviceID));
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &sz, devs.data()) != noErr) {
        return kAudioObjectUnknown;
    }
    for (AudioDeviceID d : devs) {
        if (spDeviceOutputChannels(d) == 0) continue;
        for (AudioObjectPropertySelector sel : { (AudioObjectPropertySelector)kAudioObjectPropertyName,
                                                 (AudioObjectPropertySelector)kAudioDevicePropertyDeviceUID }) {
            AudioObjectPropertyAddress na = { sel, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
            CFStringRef str = NULL;
            UInt32 ssz = sizeof(str);
            if (AudioObjectGetPropertyData(d, &na, 0, NULL, &ssz, &str) != noErr || !str) continue;
            NSString *ns = CFBridgingRelease(str);
            if ([ns rangeOfString:[NSString stringWithUTF8String:needle]].location != NSNotFound) return d;
        }
    }
    return kAudioObjectUnknown;
}

#pragma mark - Setup

- (void)negotiateLayoutLocked {
    if (!_negotiatedOnce) {
#if SP_INTERNAL_BUILD && !SP_APP_STORE
        const char *devName = spAutomation() ? getenv("SP_AUDIO_DEVICE") : nullptr;
        if (devName) _boundDevice = spFindOutputDeviceByName(devName);
#endif
    }
    AudioDeviceID dev = _boundDevice != kAudioObjectUnknown ? _boundDevice : spDefaultOutputDevice();
    sp::AudioOutputLayout L;
    sp::initStereo(&L, 0);
    if (dev != kAudioObjectUnknown) {
        const UInt32 devCh = spDeviceOutputChannels(dev);
        const char *forced = nullptr;
#if SP_INTERNAL_BUILD && !SP_APP_STORE
        forced = spAutomation() ? getenv("SP_AUDIO_LAYOUT") : nullptr;
#endif
        if (forced) {
            sp::resolvePositionalLayout(forced, (int)devCh, &L);
        } else if (devCh >= 6) {
            std::vector<uint32_t> labels = spDeviceOutputLabels(dev, devCh);
            sp::resolveOutputLayout(labels.data(), (int)labels.size(), &L);
        } else {
            sp::initStereo(&L, (int)devCh);
        }
    }
    _negotiated = L;
    _negotiatedOnce = true;
    if (!_appliedOnce) {
        _channels.store(L.channels, std::memory_order_release);
        _layoutPending = false;
    } else {
        _layoutPending = (L != _applied) || _unitBroken;
    }
}

- (BOOL)configureUnitFormat:(const sp::AudioOutputLayout &)L {
    AudioStreamBasicDescription asbd = {};
    asbd.mSampleRate = kSampleRate;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    asbd.mChannelsPerFrame = (UInt32)L.channels;
    asbd.mBitsPerChannel = 32;
    asbd.mFramesPerPacket = 1;
    asbd.mBytesPerFrame = (UInt32)L.channels * sizeof(float);
    asbd.mBytesPerPacket = asbd.mBytesPerFrame;
    if (AudioUnitSetProperty(_unit, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input, 0, &asbd, sizeof(asbd)) != noErr) {
        return NO;
    }
    return [self installChannelMap:L];
}

- (BOOL)installChannelMap:(const sp::AudioOutputLayout &)L {
    if (L.deviceChannels <= 0) return YES;
    if (!L.useMap && !_mapInstalled) return YES;
    int n = L.deviceChannels < sp::kSPAudioMaxDeviceChannels ? L.deviceChannels
                                                              : sp::kSPAudioMaxDeviceChannels;
    std::vector<SInt32> map((size_t)n, -1);
    if (L.useMap) {
        for (int i = 0; i < n; i++) map[(size_t)i] = L.map[(size_t)i];
    } else {

        for (int i = 0; i < n && i < 2; i++) map[(size_t)i] = i;
    }
    OSStatus st = AudioUnitSetProperty(_unit, kAudioOutputUnitProperty_ChannelMap,
                                       kAudioUnitScope_Output, 0, map.data(),
                                       (UInt32)(map.size() * sizeof(SInt32)));
    if (st != noErr) {
        if (spDebug()) NSLog(@"[Audio] 声道映射表设置失败 %d（布局 %s，设备 %d 路）", (int)st, L.name(), L.deviceChannels);
        return !L.useMap;
    }
    _mapInstalled = true;
    return YES;
}

- (void)installDeviceListener {
    if (_listenerInstalled || _boundDevice != kAudioObjectUnknown) return;
    __weak SPAudioOutput *weakSelf = self;
    _devListener = ^(UInt32 n, const AudioObjectPropertyAddress *addrs) {
        (void)n; (void)addrs;
        [weakSelf handleDefaultDeviceChanged];
    };
    AudioObjectPropertyAddress a = { kAudioHardwarePropertyDefaultOutputDevice,
                                     kAudioObjectPropertyScopeGlobal,
                                     kAudioObjectPropertyElementMain };
    if (AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &a,
                                            dispatch_get_main_queue(), _devListener) == noErr) {
        _listenerInstalled = true;
    } else {
        _devListener = nil;
    }
}

- (void)removeDeviceListener {
    if (!_listenerInstalled) return;
    AudioObjectPropertyAddress a = { kAudioHardwarePropertyDefaultOutputDevice,
                                     kAudioObjectPropertyScopeGlobal,
                                     kAudioObjectPropertyElementMain };
    AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &a,
                                           dispatch_get_main_queue(), _devListener);
    _listenerInstalled = false;
    _devListener = nil;
}

- (void)handleDefaultDeviceChanged {
    bool pending = false, reapply = false;
    sp::AudioOutputLayout applied;
    {
        std::lock_guard<std::mutex> lk(_layoutMtx);
        [self negotiateLayoutLocked];
        pending = _layoutPending;
        reapply = !pending && _appliedOnce && _applied.useMap;
        applied = _applied;
    }
    if (spDebug()) {
        NSLog(@"[Audio] 默认输出设备变化：协商=%s（%d 路设备）%@", _negotiated.name(),
              _negotiated.deviceChannels, pending ? @"→ 待重配" : @"→ 布局不变");
    }
    if (pending) {
        void (^h)(void) = self.outputLayoutChangeHandler;
        if (h) h();
        else [self applyPendingOutputLayout];
    } else if (reapply && _ready.load() && _unit) {
        [self installChannelMap:applied];
    }
}

- (BOOL)setup {

    (void)spAudioHostUs(0);
    sp::AudioOutputLayout layout;
    {
        std::lock_guard<std::mutex> lk(_layoutMtx);
        if (!_negotiatedOnce) [self negotiateLayoutLocked];
        layout = _negotiated;
    }
    AudioComponentDescription desc = {
        .componentType = kAudioUnitType_Output,
        .componentSubType = _boundDevice != kAudioObjectUnknown ? kAudioUnitSubType_HALOutput
                                                                 : kAudioUnitSubType_DefaultOutput,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
    };
    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    if (!comp) return NO;
    if (AudioComponentInstanceNew(comp, &_unit) != noErr) { _unit = NULL; return NO; }

    auto fail = [self]() -> BOOL {
        AudioComponentInstanceDispose(self->_unit);
        self->_unit = NULL;
        return NO;
    };
    if (_boundDevice != kAudioObjectUnknown) {
        if (AudioUnitSetProperty(_unit, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &_boundDevice, sizeof(_boundDevice)) != noErr) {
            return fail();
        }
    }

    if (![self configureUnitFormat:layout]) {
        sp::initStereo(&layout, layout.deviceChannels);
        if (![self configureUnitFormat:layout]) return fail();
    }

    AURenderCallbackStruct cb = { renderCallback, (__bridge void *)self };

    if (AudioUnitSetProperty(_unit, kAudioUnitProperty_SetRenderCallback,
                             kAudioUnitScope_Global, 0, &cb, sizeof(cb)) != noErr) {
        return fail();
    }
    if (AudioUnitInitialize(_unit) != noErr) return fail();
    // Apply all user volume in the render callback and keep the HAL at unity.
    if (AudioUnitSetParameter(_unit, kHALOutputParam_Volume,
                              kAudioUnitScope_Global, 0, 1.0f, 0) != noErr) {
        AudioUnitUninitialize(_unit);
        return fail();
    }
    bool pendingAfterSetup = false;
    {
        std::lock_guard<std::mutex> lk(_layoutMtx);

        if (layout.channels != _channels.load(std::memory_order_acquire)) {
            [self resetInvalidateSettingChannels:layout.channels];
        }
        _applied = layout;
        _appliedOnce = true;

        [self negotiateLayoutLocked];
        pendingAfterSetup = _layoutPending;
    }
    if (spDebug()) {
        NSLog(@"[Audio] 输出布局：%s（%d 路 → 设备 %d 路%@）", layout.name(), layout.channels,
              layout.deviceChannels, _boundDevice != kAudioObjectUnknown ? @"，SP_AUDIO_DEVICE 绑定" : @"");
    }
    _ready.store(true);

    if (_startRequested.exchange(false)) {
        if (!_running.load()) {
            _dspStartGeneration.fetch_add(1, std::memory_order_release);
            if (AudioOutputUnitStart(_unit) == noErr) {
                _running.store(true);
            }
        }

        if (!_desiredRunning.load() && _running.load()) {
            AudioOutputUnitStop(_unit);
            _running.store(false);
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self installDeviceListener];
        if (pendingAfterSetup) [self handleDefaultDeviceChanged];
    });
    return YES;
}

#pragma mark - Output channel layout

- (uint64_t)outputChannelMask {
    std::lock_guard<std::mutex> lk(_layoutMtx);
    if (!_negotiatedOnce) [self negotiateLayoutLocked];

    return _appliedOnce ? _applied.mask : _negotiated.mask;
}

- (int)outputChannels {
    return _channels.load(std::memory_order_acquire);
}

- (BOOL)outputLayoutChangePending {
    std::lock_guard<std::mutex> lk(_layoutMtx);
    return _layoutPending;
}

- (NSString *)outputLayoutDescription {
    std::lock_guard<std::mutex> lk(_layoutMtx);
    const sp::AudioOutputLayout &L = _appliedOnce ? _applied : _negotiated;
    return [NSString stringWithFormat:@"%s/%d", L.name(), L.deviceChannels];
}

- (NSString *)outputLayoutName {
    std::lock_guard<std::mutex> lk(_layoutMtx);
    const sp::AudioOutputLayout &L = _appliedOnce ? _applied : _negotiated;
    return [NSString stringWithUTF8String:L.name()];
}

- (BOOL)applyPendingOutputLayout {
    sp::AudioOutputLayout L;
    {
        std::lock_guard<std::mutex> lk(_layoutMtx);
        if (!_layoutPending) return NO;
        L = _negotiated;
    }
    const bool haveUnit = _ready.load() && _unit;
    if (haveUnit) {

        AudioOutputUnitStop(_unit);
        _running.store(false);
        AudioUnitUninitialize(_unit);
        if (![self configureUnitFormat:L]) {
            sp::initStereo(&L, L.deviceChannels);
            (void)[self configureUnitFormat:L];
        }
        bool inited = AudioUnitInitialize(_unit) == noErr;
        if (!inited) {

            sp::initStereo(&L, L.deviceChannels);
            (void)[self configureUnitFormat:L];
            inited = AudioUnitInitialize(_unit) == noErr;
        }
        {
            std::lock_guard<std::mutex> lk(_layoutMtx);
            _unitBroken = !inited;
        }
        if (inited) {

            _dead.store(false);
        } else {
            NSLog(@"[Audio] 输出布局重配后 AudioUnitInitialize 失败，音频降级为静音（下次设备事件再试）");
            _dead.store(true);
        }
    }

    [self resetInvalidateSettingChannels:L.channels];
    {
        std::lock_guard<std::mutex> lk(_layoutMtx);
        _applied = L;
        _appliedOnce = true;
        _layoutPending = (L != _negotiated) || _unitBroken;
    }
    if (spDebug()) {
        NSLog(@"[Audio] 输出布局已重配：%s（%d 路 → 设备 %d 路）", L.name(), L.channels, L.deviceChannels);
    }
    if (haveUnit && !_dead.load() && _desiredRunning.load() && !_running.load()) {
        _dspStartGeneration.fetch_add(1, std::memory_order_release);
        if (AudioOutputUnitStart(_unit) == noErr) _running.store(true);
    }
    return YES;
}

#pragma mark - Real-time rendering

static OSStatus renderCallback(void *inRefCon,
                               AudioUnitRenderActionFlags *ioActionFlags,
                               const AudioTimeStamp *inTimeStamp,
                               UInt32 inBusNumber,
                               UInt32 inNumberFrames,
                               AudioBufferList *ioData) {
    SPAudioOutput *self = (__bridge SPAudioOutput *)inRefCon;
    UInt32 frames = inNumberFrames;

    const int ch = self->_channels.load(std::memory_order_relaxed);

    if (ioData->mNumberBuffers < 1 || !ioData->mBuffers[0].mData ||
        ioData->mBuffers[0].mDataByteSize < frames * (UInt32)ch * sizeof(float)) {
        for (UInt32 b = 0; b < ioData->mNumberBuffers; b++) {
            if (ioData->mBuffers[b].mData) memset(ioData->mBuffers[b].mData, 0, ioData->mBuffers[b].mDataByteSize);
        }
        return noErr;
    }
    float *out = (float *)ioData->mBuffers[0].mData;

    SPSCRing *ring = &self->_ring;
    self->_lastRenderFrames.store((int32_t)frames, std::memory_order_relaxed);
    int64_t readIdx = ring->readIdx.load(std::memory_order_acquire);
    int64_t writeIdx = ring->writeIdx.load(std::memory_order_acquire);

    int64_t disc = self->_discardUpTo.load(std::memory_order_acquire);
    if (disc > readIdx) {
        readIdx = disc > writeIdx ? writeIdx : disc;
        ring->readIdx.store(readIdx, std::memory_order_release);
    }
    int32_t available = (int32_t)(writeIdx - readIdx);
    int32_t n = (available > (int32_t)frames) ? (int32_t)frames : available;
    if (n < 0) n = 0;

    if (n > 0) {
        int32_t start = (int32_t)(readIdx % kRingFrames);
        int32_t first = (n < kRingFrames - start) ? n : (kRingFrames - start);
        memcpy(out, &ring->buf[(size_t)start * ch], (size_t)first * ch * sizeof(float));
        if (n > first) {
            memcpy(out + (size_t)first * ch, ring->buf, (size_t)(n - first) * ch * sizeof(float));
        }
    }
    if (n < (int32_t)frames) {
        memset(out + (size_t)n * ch, 0, (size_t)(frames - n) * ch * sizeof(float));
    }

    // Process every requested frame so limiter release advances through an
    // underrun, but advance the gain ramp only for actual media frames.
    int32_t dspEpoch = self->_epoch.load(std::memory_order_acquire);
    uint32_t dspStart = self->_dspStartGeneration.load(std::memory_order_acquire);
    float requestedGain = self->_targetGain.load(std::memory_order_relaxed);
    if (dspEpoch != self->_dspEpoch || dspStart != self->_dspStartSeen) {
        self->_dspEpoch = dspEpoch;
        self->_dspStartSeen = dspStart;
        self->_gainCurrent = 0.0f;
        self->_limiterGain = 1.0f;
        self->_gainTargetSnapshot = requestedGain;
        self->_gainRampRemaining = kGainRampFrames;
        self->_gainStep = requestedGain / kGainRampFrames;
    } else if (requestedGain != self->_gainTargetSnapshot) {
        self->_gainTargetSnapshot = requestedGain;
        self->_gainRampRemaining = kGainRampFrames;
        self->_gainStep = (requestedGain - self->_gainCurrent) / kGainRampFrames;
    }

    // Stable 100% playback is an exact bypass once the limiter returns to unity,
    // but only while nothing exceeds the ceiling: swresample's default downmix
    // (FLTP internal format => rematrix_maxval INT_MAX) is not normalised, so
    // 5.1/7.1 content can reach 2.4x full scale at 100% volume and the HAL
    // hard-clips it. Scan the block for peaks; content within the ceiling
    // stays bit-exact, anything above drops into the limiter for this block.
    bool unityBypass = self->_gainRampRemaining == 0 &&
                       self->_gainCurrent == 1.0f &&
                       self->_limiterGain == 1.0f;
    if (unityBypass) {
        const size_t total = (size_t)frames * ch;
        unityBypass = sp::audioBlockWithinCeiling(out, total, kLimiterCeiling);
    }
    if (!unityBypass) {
        // Stable mute remains a fast path without changing clock accounting.
        if (self->_gainRampRemaining == 0 && self->_gainCurrent == 0.0f &&
            self->_limiterGain == 1.0f) {
            memset(out, 0, (size_t)frames * ch * sizeof(float));
        } else {
            for (UInt32 i = 0; i < frames; i++) {
                if ((int32_t)i < n && self->_gainRampRemaining > 0) {
                    self->_gainCurrent += self->_gainStep;
                    if (--self->_gainRampRemaining == 0) {
                        // Remove accumulated error so unity reaches the exact bypass.
                        self->_gainCurrent = self->_gainTargetSnapshot;
                    }
                }

                float gain = self->_gainCurrent;
                float *fr = out + (size_t)i * ch;

                float peak = 0.0f;
                for (int c = 0; c < ch; c++) {
                    float v = fr[c] * gain;
                    if (!std::isfinite(v)) v = 0.0f;
                    fr[c] = v;
                    peak = std::fmax(peak, std::fabs(v));
                }
                // Peak check at every gain, not only above unity: content or
                // un-normalised downmixes can exceed 1.0 at 100% volume too.
                float required = 1.0f;
                if (peak > kLimiterCeiling) required = kLimiterCeiling / peak;
                if (required < self->_limiterGain) {
                    self->_limiterGain = required; // Zero-lookahead attack is immediate.
                } else if (self->_limiterGain < required) {
                    self->_limiterGain += kLimiterReleaseStep;
                    if (self->_limiterGain > required) self->_limiterGain = required;
                }
                const float lg = self->_limiterGain;
                for (int c = 0; c < ch; c++) fr[c] *= lg;
            }
        }
    }
    ring->readIdx.store(readIdx + n, std::memory_order_release);

    {
        uint64_t host = (inTimeStamp->mFlags & kAudioTimeStampHostTimeValid)
                            ? inTimeStamp->mHostTime : mach_absolute_time();
        int64_t pre = self->_playedFrames.load(std::memory_order_relaxed);
        uint32_t s = self->_clkSeq.load(std::memory_order_relaxed);

        self->_clkSeq.store(s + 1, std::memory_order_relaxed);
        std::atomic_thread_fence(std::memory_order_release);
        self->_clkHostUs.store(spAudioHostUs(host), std::memory_order_relaxed);
        self->_clkFramesStart.store(pre, std::memory_order_relaxed);
        self->_clkFramesReal.store(n, std::memory_order_relaxed);
        self->_clkReadIdx.store(readIdx + n, std::memory_order_relaxed);
        self->_clkSeq.store(s + 2, std::memory_order_release);
    }

    self->_playedFrames.fetch_add(n, std::memory_order_relaxed);
    return noErr;
}

#pragma mark - Controls

- (void)start {
    if (_dead.load()) return;
    _desiredRunning.store(true);
    _startRequested.store(true);
    if (!_ready.load()) return;
    if (_startRequested.exchange(false)) {
        if (_running.load()) return;
        // Publish before Start because the render callback may enter immediately.
        _dspStartGeneration.fetch_add(1, std::memory_order_release);
        if (AudioOutputUnitStart(_unit) == noErr) {
            _running.store(true);
        }
    }
}

- (void)stop {
    _desiredRunning.store(false);
    _startRequested.store(false);

    if (_ready.load() && _unit) {
        AudioOutputUnitStop(_unit);
    }
    _running.store(false);

    _spaceCv.notify_all();
}

- (void)reset {
    [self resetInvalidateSettingChannels:0];
}

- (void)resetInvalidateSettingChannels:(int)channels {
    {

        std::lock_guard<std::mutex> lk(_publishMtx);
        _epoch.fetch_add(1);
        _writeAbort.store(false);
        _discardUpTo.store(_ring.writeIdx.load(std::memory_order_acquire),
                           std::memory_order_release);
        _segments.clear();
        _switchPending.store(false);
        _switchAppliedSeq.store(_switchSeq.load());
        _switchPlayedFrame.store(-1);
        if (channels > 0) _channels.store(channels, std::memory_order_release);
    }
    _spaceCv.notify_all();
}

- (void)requestRate:(double)rate {
    const double newRate = (rate > 0.05 && rate <= 5.0) ? rate : 1.0;
    {
        std::lock_guard<std::mutex> lk(_publishMtx);
        _switchRate = newRate;
        _switchSeq.fetch_add(1, std::memory_order_acq_rel);
        _switchPending.store(true, std::memory_order_release);
    }
    _spaceCv.notify_all();
}

- (BOOL)rateSwitchPending {
    return _switchAppliedSeq.load(std::memory_order_acquire) !=
           _switchSeq.load(std::memory_order_acquire);
}

- (int64_t)rateSwitchPlayedFrame {
    return _switchPlayedFrame.load(std::memory_order_acquire);
}

- (void)servicePendingRateSwitchWithEpoch:(int32_t)epoch {
    if (_dead.load() || !_switchPending.load(std::memory_order_acquire)) return;
    if (epoch != _epoch.load()) return;
    if (epoch != _lastSeenEpoch) {

        _lastSeenEpoch = epoch;
        _resamplePos = 0;
        if (_stretch) _stretch->reset();
        _stretchActive = NO;
        _histTotal = 0;
    }
    [self applyPendingRateSwitchWithEpoch:epoch];
}

- (void)abortWrites {
    _writeAbort.store(true);
    _spaceCv.notify_all();
}

- (void)markSetupFailed {
    _dead.store(true);
    _spaceCv.notify_all();
}

- (int64_t)clockFrames {
    for (int i = 0; i < 8; i++) {
        uint32_t s1 = _clkSeq.load(std::memory_order_acquire);
        if (s1 & 1) continue;
        int64_t hostUs = _clkHostUs.load(std::memory_order_relaxed);
        int64_t start = _clkFramesStart.load(std::memory_order_relaxed);
        int32_t real = _clkFramesReal.load(std::memory_order_relaxed);
        std::atomic_thread_fence(std::memory_order_acquire);
        if (_clkSeq.load(std::memory_order_relaxed) != s1) continue;
        if (hostUs <= 0) break;
        int64_t adv = (spAudioHostUs(mach_absolute_time()) - hostUs) * kSampleRate / 1000000;
        if (adv < 0) adv = 0;
        if (adv > real) adv = real;
        return start + adv;
    }
    return _playedFrames.load();
}

- (void)snapshotReadIdx:(int64_t *)readIdx playedFrames:(int64_t *)played {
    for (int i = 0; i < 8; i++) {
        uint32_t s1 = _clkSeq.load(std::memory_order_acquire);
        if (s1 & 1) continue;
        int64_t r = _clkReadIdx.load(std::memory_order_relaxed);
        int64_t p = _clkFramesStart.load(std::memory_order_relaxed) +
                    _clkFramesReal.load(std::memory_order_relaxed);
        std::atomic_thread_fence(std::memory_order_acquire);
        if (_clkSeq.load(std::memory_order_relaxed) != s1) continue;
        *readIdx = r;
        *played = p;
        return;
    }

    *readIdx = _ring.readIdx.load(std::memory_order_acquire);
    *played = _playedFrames.load(std::memory_order_relaxed);
}
- (int64_t)bufferedFrames {

    int64_t r = _ring.readIdx.load(std::memory_order_acquire);
    int64_t disc = _discardUpTo.load(std::memory_order_acquire);
    if (disc > r) r = disc;
    int64_t d = _ring.writeIdx.load(std::memory_order_acquire) - r;
    return d > 0 ? d : 0;
}
- (BOOL)isRunning { return _running.load(); }

- (void)setVolume:(float)volume {
    // Preserve the last valid value rather than publishing non-finite gain.
    if (!std::isfinite(volume)) return;
    if (volume < 0.0f) volume = 0.0f;
    if (volume > 5.0f) volume = 5.0f;
    _targetGain.store(volume, std::memory_order_release);
}

#pragma mark - Blocking decoder writes

- (int32_t)currentEpoch {
    return _epoch.load();
}

- (void)writePCM:(const float *)data frames:(int)count rate:(double)rate {
    [self writePCM:data frames:count channels:2 rate:rate expectedEpoch:_epoch.load()];
}

- (BOOL)writePCM:(const float *)data frames:(int)count rate:(double)rate expectedEpoch:(int32_t)expected {
    return [self writePCM:data frames:count channels:2 rate:rate expectedEpoch:expected];
}

- (int)adoptWriterChannels:(int)ch {
    if (_writerCh == ch) return ch;
    free(_hist);
    _hist = nullptr;
    free(_rateScratch);
    _rateScratch = nullptr;
    delete _stretch;
    _stretch = nullptr;
    _stretchActive = NO;
    _histTotal = 0;
    _resamplePos = 0;
    _writerCh = ch;
    return ch;
}

- (int)writerChannels {
    return _writerCh ? _writerCh : [self adoptWriterChannels:_channels.load(std::memory_order_acquire)];
}

- (BOOL)writePCM:(const float *)data frames:(int)count channels:(int)channels
            rate:(double)rate expectedEpoch:(int32_t)expected {
    if (count <= 0 || _dead.load()) return NO;

    if (channels != _channels.load(std::memory_order_acquire)) return NO;
    int32_t epoch = _epoch.load();
    if (epoch != expected) return NO;
    const int ch = [self adoptWriterChannels:channels];
    if (epoch != _lastSeenEpoch) {
        _lastSeenEpoch = epoch;
        _resamplePos = 0;
        if (_stretch) _stretch->reset();
        _stretchActive = NO;
        _histTotal = 0;
    }

    if (_switchPending.load(std::memory_order_acquire)) {
        [self applyPendingRateSwitchWithEpoch:epoch];
        if (_epoch.load() != epoch) return NO;
    }
    const int64_t packetInStart = _histTotal;

    if (!_hist) {
        _hist = (float *)calloc((size_t)kHistFrames * ch, sizeof(float));
        if (!_hist) return NO;
    }
    {

        const float *src = data;
        int keep = count;
        if (keep > kHistFrames) {
            src += (size_t)(keep - kHistFrames) * ch;
            keep = kHistFrames;
        }
        int64_t pos = (_histTotal + (count - keep)) % kHistFrames;
        int first = (int)std::min<int64_t>(keep, kHistFrames - pos);
        memcpy(_hist + pos * ch, src, (size_t)first * ch * sizeof(float));
        if (keep > first) {
            memcpy(_hist, src + (size_t)first * ch,
                   (size_t)(keep - first) * ch * sizeof(float));
        }
        _histTotal += count;
    }

    {
        std::lock_guard<std::mutex> lk(_publishMtx);
        if (_switchSeq.load(std::memory_order_acquire) != 0) rate = _switchRate;
    }
    _rate = (rate > 0.05 && rate <= 5.0) ? rate : 1.0;
    [self noteSegmentForRateIfNeededAtInput:packetInStart];
    if (![self emitInput:data frames:count epoch:epoch]) {

        [self applyPendingRateSwitchWithEpoch:epoch];
    }
    return YES;
}

- (void)noteSegmentForRateIfNeededAtInput:(int64_t)packetInStart {
    std::lock_guard<std::mutex> lk(_publishMtx);
    if (!_segments.empty() && _segments.back().rate == _rate) return;
    int64_t pending = (_stretchActive && _stretch) ? _stretch->pendingInputFrames() : 0;
    _segments.push_back({_ring.writeIdx.load(std::memory_order_relaxed),
                         packetInStart - pending, _rate});

    while (_segments.size() > 64) _segments.erase(_segments.begin());
}

- (void)drainStretchAtEOFWithEpoch:(int32_t)epoch {
    if (_dead.load() || epoch != _epoch.load() || !_stretchActive || !_stretch) return;
    _stretch->finish([&](const float *out, int n) {
        return (bool)[self writeRaw:out frames:n epoch:epoch];
    });
    _stretchActive = NO;
}

- (void)applyPendingRateSwitchWithEpoch:(int32_t)epoch {
    while (_switchPending.exchange(false, std::memory_order_acq_rel)) {
        double newRate;
        uint32_t seq;
        int64_t inPos = -1, outPos = 0, r = 0;
        {
            std::lock_guard<std::mutex> lk(_publishMtx);

            if (_epoch.load() != epoch) {
                if (_switchAppliedSeq.load(std::memory_order_acquire) !=
                    _switchSeq.load(std::memory_order_acquire)) {
                    _switchPending.store(true, std::memory_order_release);
                }
                return;
            }
            newRate = _switchRate;
            seq = _switchSeq.load(std::memory_order_acquire);
            const int64_t w = _ring.writeIdx.load(std::memory_order_acquire);

            int64_t clkR = 0, clkPlayed = 0;
            [self snapshotReadIdx:&clkR playedFrames:&clkPlayed];
            const int64_t disc = _discardUpTo.load(std::memory_order_acquire);
            int64_t base = std::max(clkR, disc);
            if (base > w) base = w;

            r = std::max(_ring.readIdx.load(std::memory_order_acquire), base);
            if (r > w) r = w;
            int64_t margin = 0;
            if (_running.load(std::memory_order_acquire)) {
                int32_t blk = _lastRenderFrames.load(std::memory_order_relaxed);
                if (blk <= 0) blk = 1024;
                margin = 2 * (int64_t)blk + 256;
            }
            outPos = r + margin;
            if (outPos > w) outPos = w;

            if (outPos < w) _ring.writeIdx.store(outPos, std::memory_order_release);
            for (size_t i = _segments.size(); i > 0; i--) {
                const SPRateSegment &seg = _segments[i - 1];
                if (seg.outStart <= outPos) {
                    inPos = seg.inStart + (int64_t)llround((double)(outPos - seg.outStart) * seg.rate);
                    break;
                }
            }
            while (!_segments.empty() && _segments.back().outStart >= outPos && outPos < w) {
                _segments.pop_back();
            }

            _switchPlayedFrame.store(clkPlayed + (outPos - base), std::memory_order_release);
            _switchAppliedSeq.store(seq, std::memory_order_release);
        }
        _rate = newRate;
        _resamplePos = 0;
        if (_stretch) _stretch->reset();
        _stretchActive = NO;
        if (inPos < 0) {
            if (spDebug()) NSLog(@"[Audio] 倍速切换 %.2fx：无环内容可重生成", _rate);
            [self noteSegmentForRateIfNeededAtInput:_histTotal];
            continue;
        }
        const int64_t oldest = std::max<int64_t>(0, _histTotal - kHistFrames);
        if (inPos < oldest) inPos = oldest;
        if (inPos > _histTotal) inPos = _histTotal;

        const int ch = [self writerChannels];
        if (newRate != 1.0 && !spPitchShiftResampler()) {
            if (!_stretch) _stretch = new SPTimeStretcher(ch, kSampleRate);
            if (inPos > oldest && _hist) {
                const int ov = _stretch->overlapFrames();
                int64_t from = std::max<int64_t>(oldest, inPos - ov);
                int64_t n = inPos - from;
                int64_t pos = from % kHistFrames;
                int64_t first = std::min<int64_t>(n, kHistFrames - pos);
                _stretch->primeTail(_hist + pos * ch, (int)first);
                if (n > first) _stretch->primeTail(_hist, (int)(n - first));
            }
        }
        {
            std::lock_guard<std::mutex> lk(_publishMtx);

            if (_epoch.load() != epoch) return;
            _segments.push_back({outPos, inPos, _rate});
        }
        if (spDebug()) {
            NSLog(@"[Audio] 倍速切换 %.2fx：留白=%lld 重生成 %lld 输入帧（截断点 %lld 读头 %lld 写头 %lld 水位 %lld 已播 %lld running=%d 段=%zu）",
                  _rate, (long long)(outPos - r), (long long)(_histTotal - inPos), (long long)outPos,
                  (long long)_ring.readIdx.load(), (long long)_ring.writeIdx.load(),
                  (long long)_discardUpTo.load(), (long long)_playedFrames.load(),
                  (int)_running.load(), _segments.size());
        }
        _regenerating = YES;
        BOOL ok = _hist != nullptr;
        for (int64_t pos = inPos; pos < _histTotal && ok; ) {
            int64_t off = pos % kHistFrames;
            int n = (int)std::min<int64_t>({(int64_t)4096, _histTotal - pos, kHistFrames - off});
            ok = [self emitInput:_hist + off * ch frames:n epoch:epoch];
            pos += n;
            if (_switchPending.load(std::memory_order_acquire)) break;
        }
        _regenerating = NO;
    }
}

- (BOOL)emitInput:(const float *)data frames:(int)count epoch:(int32_t)epoch {
    const int ch = [self writerChannels];
    if (_rate == 1.0) {
        if (_stretchActive) {

            BOOL ok = YES;
            _stretch->flushRaw([&](const float *out, int n) {
                ok = ok && [self writeRaw:out frames:n epoch:epoch];
                return ok;
            });
            _stretchActive = NO;
            if (!ok) return NO;
        }
        BOOL ok = [self writeRaw:data frames:count epoch:epoch];

        if (_stretch) _stretch->primeTail(data, count);
        return ok;
    }
    if (!spPitchShiftResampler()) {
        if (!_stretch) _stretch = new SPTimeStretcher(ch, kSampleRate);
        _stretch->setRate(_rate);
        _stretchActive = YES;
        BOOL ok = YES;
        _stretch->process(data, count, [&](const float *out, int n) {
            ok = [self writeRaw:out frames:n epoch:epoch];
            return ok;
        });
        return ok;
    }

    int outCount = (int)ceilf((count - _resamplePos) / _rate);
    if (outCount <= 0) {
        _resamplePos -= count;
        return YES;
    }

    const int chunk = 4096;
    if (!_rateScratch) {
        _rateScratch = (float *)malloc((size_t)chunk * ch * sizeof(float));
        if (!_rateScratch) return NO;
    }
    float *tmp = _rateScratch;
    int produced = 0;
    while (produced < outCount) {
        int n = (outCount - produced > chunk) ? chunk : outCount - produced;
        float *out = tmp;
        for (int i = 0; i < n; i++) {
            float pos = _resamplePos + (produced + i) * _rate;
            int p0 = (int)pos;
            int p1 = p0 + 1;
            float frac = pos - p0;
            if (p1 >= count) p1 = count - 1;
            if (p1 < 0) p1 = 0;
            if (p0 < 0) p0 = 0;
            if (p0 >= count) p0 = count - 1;
            for (int c = 0; c < ch; c++) {
                float v0 = data[(size_t)p0 * ch + c];
                float v1 = data[(size_t)p1 * ch + c];
                out[(size_t)i * ch + c] = v0 + (v1 - v0) * frac;
            }
        }
        if (![self writeRaw:tmp frames:n epoch:epoch]) return NO;
        produced += n;
    }

    _resamplePos = _resamplePos + outCount * _rate - count;
    return YES;
}

- (BOOL)writeRaw:(const float *)data frames:(int)count epoch:(int32_t)epoch {
    int written = 0;

    const int ch = [self writerChannels];
    if (ch != _channels.load(std::memory_order_acquire)) return NO;
    while (written < count) {
        if (_dead.load() || _writeAbort.load() || _epoch.load() != epoch) return NO;
        if (_switchPending.load(std::memory_order_acquire)) return NO;
        int64_t w = _ring.writeIdx.load(std::memory_order_relaxed);
        int64_t r = _ring.readIdx.load(std::memory_order_acquire);

        int64_t disc = _discardUpTo.load(std::memory_order_acquire);
        if (disc > r && !_running.load(std::memory_order_acquire)) r = disc;
        int64_t occ = w - r;
        if (occ < 0) occ = 0;
        if (occ > kRingFrames) occ = kRingFrames;
        int32_t space = kRingFrames - 1 - (int32_t)occ;
        if (space <= 0) {

            int32_t need = count - written;
            if (need > kRingFrames / 2) need = kRingFrames / 2;
            int64_t waitMs = need / 48 + 1;
            if (waitMs < 10) waitMs = 10;
            if (waitMs > 250) waitMs = 250;
            std::unique_lock<std::mutex> lock(_spaceMtx);
            _spaceCv.wait_for(lock, std::chrono::milliseconds(waitMs));
            continue;
        }
        int32_t n = count - written;
        if (n > space) n = space;

        int32_t start = (int32_t)(w % kRingFrames);
        int32_t first = (n < kRingFrames - start) ? n : (kRingFrames - start);
        memcpy(&_ring.buf[(size_t)start * ch], data + (size_t)written * ch, (size_t)first * ch * sizeof(float));
        if (n > first) {
            memcpy(_ring.buf, data + (size_t)(written + first) * ch, (size_t)(n - first) * ch * sizeof(float));
        }

        {
            std::lock_guard<std::mutex> lk(_publishMtx);
            if (_epoch.load() != epoch) return NO;

            if (ch != _channels.load(std::memory_order_relaxed)) return NO;

            if (_switchPending.load(std::memory_order_acquire)) return NO;
            _ring.writeIdx.store(w + n, std::memory_order_release);
        }
        written += n;
    }
    return YES;
}

@end
