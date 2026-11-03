#include "SPSubtitleRenderer.h"
#include "SPSubtitleCompositor.hpp"
#include "SPSubtitleSampleGate.hpp"
#include "SPSubtitleWatchdogGate.hpp"
#include <ass/ass.h>
#include <dlfcn.h>
#include <atomic>
#include <algorithm>
#include <cmath>
#include <mach/mach_time.h>
#include <os/lock.h>
#include <vector>

#import <Foundation/Foundation.h>

namespace {

constexpr size_t kMaxEventBytes = 10 * 1024;

constexpr size_t kMaxDrawingEventBytes = 512 * 1024;

static bool spLineHasDrawingTag(const char *bytes, size_t len) {
    if (!bytes || len < 3) return false;
    for (size_t i = 0; i + 2 < len; i++) {
        if (bytes[i] == '\\' && bytes[i + 1] == 'p' &&
            bytes[i + 2] >= '1' && bytes[i + 2] <= '9') {
            return true;
        }
    }
    return false;
}

constexpr int kMaxSimultaneousEvents = 200;

static double renderWatchdogMs() {
#if SP_APP_STORE
    return 1500.0;
#else
    static double v = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *env = getenv("SP_SUB_WATCHDOG_MS");
        v = env ? atof(env) : 1500.0;
        if (!std::isfinite(v) || v <= 0) v = 1500.0;
    });
    return v;
#endif
}

#define SPLOG(fmt, ...) NSLog(@"[c%u]" fmt, self->_spLogId, ##__VA_ARGS__)

#include "SPRuntimeGates.hpp"

constexpr double kMaxEstimatedRasterPx = 256.0 * 1000 * 1000;

static inline double subtitleElapsedMs(uint64_t start) {
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&timebase); });
    uint64_t elapsed = mach_absolute_time() - start;
    return (double)elapsed * (double)timebase.numer /
           (double)timebase.denom / 1000000.0;
}

struct AssApi {
    ASS_Library *(*library_init)(void);
    void (*library_done)(ASS_Library *);
    ASS_Renderer *(*renderer_init)(ASS_Library *);
    void (*renderer_done)(ASS_Renderer *);
    ASS_Track *(*new_track)(ASS_Library *);
    void (*free_track)(ASS_Track *);
    void (*process_codec_private)(ASS_Track *, char *, int);
    void (*process_chunk)(ASS_Track *, char *, int, long long, long long);
    void (*process_data)(ASS_Track *, char *, int);
    ASS_Image *(*render_frame)(ASS_Renderer *, ASS_Track *, long long, int *);
    void (*set_frame_size)(ASS_Renderer *, int, int);
    void (*set_storage_size)(ASS_Renderer *, int, int);
    void (*set_fonts)(ASS_Renderer *, const char *, const char *, int, const char *, int);
    void (*set_hinting)(ASS_Renderer *, ASS_Hinting);
    void (*set_margins)(ASS_Renderer *, int, int, int, int);
    void (*set_font_scale)(ASS_Renderer *, double);
    void (*set_cache_limits)(ASS_Renderer *, int, int);
    bool ok = false;
};

AssApi &assApi() {
    static AssApi api;
    static dispatch_once_t once;
    dispatch_once(&once, ^{

        NSBundle *owning = [NSBundle bundleForClass:SPSubtitleRenderer.class];
        NSString *fwDir = [owning isEqual:NSBundle.mainBundle]
            ? NSBundle.mainBundle.privateFrameworksPath
            : owning.bundleURL.URLByDeletingLastPathComponent.path;
        NSString *p = [fwDir stringByAppendingPathComponent:@"libass.9.dylib"];
        void *h = dlopen(p.fileSystemRepresentation, RTLD_LAZY);
#if !SP_APP_STORE
        if (!h) h = dlopen("libass.9.dylib", RTLD_LAZY);
#endif
        if (!h) {
            NSLog(@"[Subtitle] libass 加载失败，字幕功能不可用");
            return;
        }
#define SP_LOAD(name) api.name = (decltype(api.name))dlsym(h, "ass_" #name)
        SP_LOAD(library_init); SP_LOAD(library_done);
        SP_LOAD(renderer_init); SP_LOAD(renderer_done);
        SP_LOAD(new_track); SP_LOAD(free_track);
        SP_LOAD(process_codec_private); SP_LOAD(process_chunk); SP_LOAD(process_data);
        SP_LOAD(render_frame);
        SP_LOAD(set_frame_size); SP_LOAD(set_storage_size);
        SP_LOAD(set_fonts); SP_LOAD(set_hinting); SP_LOAD(set_margins);
        SP_LOAD(set_font_scale); SP_LOAD(set_cache_limits);
#undef SP_LOAD
        api.ok = api.library_init && api.library_done && api.renderer_init &&
                 api.renderer_done && api.new_track && api.free_track &&
                 api.process_codec_private && api.process_chunk && api.process_data &&
                 api.render_frame && api.set_frame_size && api.set_storage_size &&
                 api.set_fonts && api.set_hinting && api.set_margins &&
                 api.set_font_scale && api.set_cache_limits;
        if (!api.ok) NSLog(@"[Subtitle] libass 符号缺失，字幕功能不可用");
    });
    return api;
}
} // namespace

@interface SPSubtitleRenderer ()
- (void)handleRenderWatchdogTimer;
- (void)workerArmRenderWatchdogStarted:(uint64_t)renderStart
                                   gen:(uint64_t)gen;
@end

@implementation SPSubtitleRenderer {

    int _dbgShotLogs;
    std::atomic<int> _dbgTruncWarns;
    int _dbgChunkLogs;
    id<MTLDevice> _device;
    dispatch_queue_t _assQueue;

    ASS_Library *_lib;
    ASS_Renderer *_renderer;
    ASS_Track *_track;
    id<MTLTexture> _texture;

    std::vector<uint8_t> _canvas;
    int _lastW, _lastH;
    sp::SPSubtitleSampleGate _sampleGate;

    unsigned _largeDynamicStreak;
    double _renderCostEMAms;

    bool _scanCacheValid;
    long long _scanCacheFromMs, _scanCacheToMs;
    int _scanCacheOverlap;
    double _scanCachePx;
    double _fontScale;
    NSData *_codecPrivate;
    BOOL _overlapWarned;

    BOOL _externalTrackActive;

    os_unfair_lock _pubLock;
    id<MTLTexture> _pubTexture;
    CGPoint _pubOrigin;

    int64_t _pubSilentFromUs, _pubSilentToUs;
    uint64_t _pubSilentGen;
    CGPoint _mainOrigin;

    std::atomic<bool> _hasSubtitles;
    std::atomic<uint64_t> _gen;

    std::atomic<uint64_t> _poisonedGen;

    std::atomic<uint64_t> _loadReq;
    std::atomic<bool> _renderJobPending;
    std::atomic<int64_t> _desiredUs;
    std::atomic<int> _desiredW, _desiredH;
    std::atomic<bool> _forceSampleFlag;
    std::atomic<uint64_t> _renderStartTicks;
    std::atomic<uint64_t> _renderStartGen;

    dispatch_source_t _renderWatchdogTimer;
    os_unfair_lock _renderWatchdogLock;
    sp::SPSubtitleWatchdogGate _renderWatchdogGate;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device logId:(unsigned)logId {
    self = [super init];
    if (self) {
        _device = device;
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
        _spLogId = logId;

        _assQueue = dispatch_queue_create(
            [NSString stringWithFormat:@"dev.openduckframe.subtitle.c%u", logId].UTF8String,
            attr);
        _lib = NULL;
        _renderer = NULL;
        _track = NULL;
        _lastW = _lastH = 0;
        _sampleGate.reset();
        _largeDynamicStreak = 0;
        _renderCostEMAms = 0.0;
        _scanCacheValid = false;
        _codecPrivate = nil;
        _fontScale = 1.0;
        _overlapWarned = NO;
        _pubLock = OS_UNFAIR_LOCK_INIT;
        _pubTexture = nil;
        _pubOrigin = CGPointZero;
        _mainOrigin = CGPointZero;
        _pubSilentFromUs = _pubSilentToUs = 0;
        _pubSilentGen = 0;
        _hasSubtitles.store(false);
        _gen.store(0);
        _poisonedGen.store(sp::SPSubtitlePoisonState::kNone);
        _loadReq.store(0);
        _renderJobPending.store(false);
        _desiredUs.store(0);
        _desiredW.store(0);
        _desiredH.store(0);
        _forceSampleFlag.store(false);
        _renderStartTicks.store(0);
        _renderStartGen.store(0);
        _renderWatchdogLock = OS_UNFAIR_LOCK_INIT;
        _renderWatchdogTimer = nil;

    }
    return self;
}

static uint64_t subtitleWatchdogDelayNs(double delayMs) {

    constexpr double kMaxDelayMs = (double)INT64_MAX / 1000000.0;
    delayMs = std::clamp(delayMs, 0.001, kMaxDelayMs);
    return (uint64_t)(delayMs * 1000000.0);
}

- (void)workerArmRenderWatchdogStarted:(uint64_t)renderStart
                                   gen:(uint64_t)gen {
    const uint64_t delayNs = subtitleWatchdogDelayNs(renderWatchdogMs() * 1.25);
    os_unfair_lock_lock(&_renderWatchdogLock);
    if (!_renderWatchdogTimer) {
        _renderWatchdogTimer = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        if (_renderWatchdogTimer) {
            __weak SPSubtitleRenderer *weakSelf = self;
            dispatch_source_set_event_handler(_renderWatchdogTimer, ^{
                SPSubtitleRenderer *strongSelf = weakSelf;
                if (strongSelf) [strongSelf handleRenderWatchdogTimer];
            });
            dispatch_source_set_timer(_renderWatchdogTimer, DISPATCH_TIME_FOREVER,
                                      DISPATCH_TIME_FOREVER, 0);
            dispatch_activate(_renderWatchdogTimer);
        }
    }
    _renderWatchdogGate.arm(renderStart, gen);
    _renderStartGen.store(gen);
    _renderStartTicks.store(renderStart);
    if (_renderWatchdogTimer) {
        const uint64_t leewayNs = std::min<uint64_t>(delayNs / 20, 10 * NSEC_PER_MSEC);
        dispatch_source_set_timer(_renderWatchdogTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)delayNs),
                                  DISPATCH_TIME_FOREVER, leewayNs);
    }
    os_unfair_lock_unlock(&_renderWatchdogLock);
}

- (void)handleRenderWatchdogTimer {
    const double deadlineMs = renderWatchdogMs() * 1.25;
    sp::SPSubtitleWatchdogInspection inspection;
    BOOL claimed = NO;
    os_unfair_lock_lock(&_renderWatchdogLock);
    // A delivery from the previous arm may already be queued when the source is
    // moved to a newer render. Inspect the current start/deadline; an early stale
    // delivery merely re-arms the one source for the remaining current window.
    const uint64_t currentStart = _renderStartTicks.load();
    const double elapsedMs = currentStart ? subtitleElapsedMs(currentStart) : 0.0;
    inspection = _renderWatchdogGate.inspect(elapsedMs, deadlineMs);
    if (inspection.decision == sp::SPSubtitleWatchdogDecision::Wait) {
        const uint64_t delayNs = subtitleWatchdogDelayNs(inspection.waitMs);
        if (_renderWatchdogTimer) {
            const uint64_t leewayNs = std::min<uint64_t>(delayNs / 20, 10 * NSEC_PER_MSEC);
            dispatch_source_set_timer(_renderWatchdogTimer,
                                      dispatch_time(DISPATCH_TIME_NOW, (int64_t)delayNs),
                                      DISPATCH_TIME_FOREVER, leewayNs);
        }
    } else if (inspection.decision == sp::SPSubtitleWatchdogDecision::Fire &&
               _renderWatchdogGate.claim(inspection)) {
        // Claim closes this exact token before dropping the lock. A concurrent
        // completion/new arm can no longer turn this firing into a new-gen poison.
        _renderStartTicks.store(0);
        claimed = YES;
    }
    os_unfair_lock_unlock(&_renderWatchdogLock);
    if (claimed) {
        [self poisonForGen:inspection.generation reason:@"渲染任务超时未完成"];
    }
}

// Default ASS header for unstyled text subtitles (SRT, mov_text and WebVTT).
// Embedded and external ASS tracks retain their own styles. A 1280x720 script
// canvas with 55 pt text, a 3 pt outline and a 22 pt bottom margin keeps text
// near 7.6% of the picture height. Explicit PlayResX/Y prevents libass's
// 384x288 fallback from making the default text disproportionately large.
static const char *kAssHeader =
    "[Script Info]\nScriptType: v4.00+\nPlayResX: 1280\nPlayResY: 720\n\n"
    "[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n"
    "Style: Default,Arial,55,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,3,0,2,25,25,22,1\n\n"
    "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n";

#pragma mark - Subtitle worker

- (BOOL)workerEnsureAssReady {
    if (_renderer && _track) return YES;
    AssApi &A = assApi();
    if (!A.ok) return NO;
    _lib = A.library_init();
    if (!_lib) return NO;
    _renderer = A.renderer_init(_lib);
    if (!_renderer) { A.library_done(_lib); _lib = NULL; return NO; }
    _track = A.new_track(_lib);
    if (!_track) {
        A.renderer_done(_renderer); _renderer = NULL;
        A.library_done(_lib); _lib = NULL;
        return NO;
    }

    if (_codecPrivate.length) {
        A.process_codec_private(_track, (char *)_codecPrivate.bytes, (int)_codecPrivate.length);
    } else {
        A.process_codec_private(_track, (char *)kAssHeader, (int)strlen(kAssHeader));
    }

    A.set_frame_size(_renderer, _lastW > 0 ? _lastW : 1280, _lastH > 0 ? _lastH : 720);
    A.set_storage_size(_renderer, _lastW > 0 ? _lastW : 1280, _lastH > 0 ? _lastH : 720);
    A.set_fonts(_renderer, NULL, "Helvetica", ASS_FONTPROVIDER_CORETEXT, NULL, 1);
    A.set_hinting(_renderer, ASS_HINTING_LIGHT);
    A.set_margins(_renderer, 0, 0, 0, 0);
    A.set_font_scale(_renderer, _fontScale > 0 ? _fontScale : 1.0);

    A.set_cache_limits(_renderer, 2000, 32);
    return YES;
}

- (void)workerFreeAss {
    _texture = nil;
    std::vector<uint8_t>().swap(_canvas);
    _sampleGate.reset();

    if (!_track && !_renderer && !_lib) return;
    AssApi &A = assApi();
    if (_track) { A.free_track(_track); _track = NULL; }
    if (_renderer) { A.renderer_done(_renderer); _renderer = NULL; }
    if (_lib) { A.library_done(_lib); _lib = NULL; }
}

- (void)workerRebuildTrackWithDefaultHeader:(BOOL)useDefault {
    if (!_track) return;
    AssApi &A = assApi();
    A.free_track(_track);
    _track = A.new_track(_lib);
    if (!_track) return;
    if (!useDefault && _codecPrivate.length) {
        A.process_codec_private(_track, (char *)_codecPrivate.bytes, (int)_codecPrivate.length);
    } else {
        A.process_codec_private(_track, (char *)kAssHeader, (int)strlen(kAssHeader));
    }
}

- (void)poisonForGen:(uint64_t)gen reason:(NSString *)reason {
    if (_gen.load() != gen) return;
    if (_poisonedGen.exchange(gen) == gen) return;

    if (_gen.load() != gen) return;
    SPLOG(@"[Subtitle] %@（病态字幕内容），本轨字幕已停用", reason);
    os_unfair_lock_lock(&_pubLock);
    if (_gen.load() == gen) _pubTexture = nil;
    os_unfair_lock_unlock(&_pubLock);
    dispatch_async(_assQueue, ^{
        if (self->_gen.load() == gen && self->_poisonedGen.load() == gen) [self workerFreeAss];
    });
}

- (BOOL)isPoisonedNow { return _poisonedGen.load() == _gen.load(); }

- (void)completeRenderWindowStarted:(uint64_t)renderStart gen:(uint64_t)gen {
    os_unfair_lock_lock(&_renderWatchdogLock);
    if (_renderWatchdogGate.complete(renderStart)) {
        _renderStartTicks.store(0);
        if (_renderWatchdogTimer) {
            dispatch_source_set_timer(_renderWatchdogTimer, DISPATCH_TIME_FOREVER,
                                      DISPATCH_TIME_FOREVER, 0);
        }
    }
    os_unfair_lock_unlock(&_renderWatchdogLock);
    double totalMs = subtitleElapsedMs(renderStart);
    if (totalMs > renderWatchdogMs()) {
        [self poisonForGen:gen
                    reason:[NSString stringWithFormat:@"单次渲染耗时 %.0fms 超预算", totalMs]];
    }
}

- (void)publishTexture:(id<MTLTexture>)tex origin:(CGPoint)origin gen:(uint64_t)gen {
    BOOL published = NO;
    os_unfair_lock_lock(&_pubLock);
    if (_gen.load() == gen) {
        published = (_pubTexture != tex);
        _pubTexture = tex;
        _pubOrigin = origin;
    }
    os_unfair_lock_unlock(&_pubLock);

    if (published && _publishCallback) _publishCallback();
}

- (void)workerResetDynamicState {
    _sampleGate.invalidateTimeline();
    _largeDynamicStreak = 0;
    _renderCostEMAms = 0.0;
    _scanCacheValid = false;

    os_unfair_lock_lock(&_pubLock);
    _pubSilentFromUs = _pubSilentToUs = 0;
    os_unfair_lock_unlock(&_pubLock);
}

- (void)renderJobForGen:(uint64_t)gen {

    _renderJobPending.store(false);
    if (_gen.load() != gen || _poisonedGen.load() == gen) {

        const uint64_t cur = _gen.load();
        if (_hasSubtitles.load() && _poisonedGen.load() != cur &&
            !_renderJobPending.exchange(true)) {
            dispatch_async(_assQueue, ^{ [self renderJobForGen:cur]; });
        }
        return;
    }
    if (!_hasSubtitles.load()) return;
    if (![self workerEnsureAssReady]) return;

    int64_t us = _desiredUs.load();
    int vw = _desiredW.load(), vh = _desiredH.load();
    if (vw <= 0 || vh <= 0) return;
    AssApi &A = assApi();
    if (vw != _lastW || vh != _lastH) {
        _lastW = vw;
        _lastH = vh;
        A.set_frame_size(_renderer, vw, vh);
        A.set_storage_size(_renderer, vw, vh);
        _texture = nil;
        [self workerResetDynamicState];
    }
    if (_forceSampleFlag.exchange(false)) _sampleGate.forceNextSample();

    sp::SPSubtitleSampleDecision sampleDecision = _sampleGate.begin(us, _texture != nil);
    if (sampleDecision != sp::SPSubtitleSampleDecision::Sample) {
        return;
    }

    {
        long long ms = (long long)(us / 1000);
        int overlap = 0;
        double estimatedPx = 0;

        if (_scanCacheValid && ms >= _scanCacheFromMs && ms < _scanCacheToMs) {
            overlap = _scanCacheOverlap;
            estimatedPx = _scanCachePx;
        } else {
        double vScale = (double)vh / (_track->PlayResY > 0 ? (double)_track->PlayResY : 720.0);

        long long nextBoundaryMs = LLONG_MAX;
        bool scanBroke = false;
        for (int i = 0; i < _track->n_events; i++) {
            const ASS_Event &e = _track->events[i];
            const long long eEnd = e.Start + e.Duration;
            if (e.Start > ms) {
                if (e.Start < nextBoundaryMs) nextBoundaryMs = e.Start;
                continue;
            }
            if (eEnd <= ms) continue;
            if (eEnd < nextBoundaryMs) nextBoundaryMs = eEnd;
            if (++overlap > kMaxSimultaneousEvents) { scanBroke = true; break; }
            double fs = 55, scaleF = 1.0, pad = 3;
            if (e.Style >= 0 && e.Style < _track->n_styles) {
                const ASS_Style &st = _track->styles[e.Style];
                if (st.FontSize > 0) fs = st.FontSize;
                scaleF = std::max({st.ScaleX, st.ScaleY, 1.0});
                pad = st.Outline + st.Shadow + 3;
            }
            int glyphs = 0;
            int drawExp = 0;
            double drawMax = 0;
            if (e.Text) {
                bool inTag = false;
                for (const char *p = e.Text; *p; p++) {
                    if (*p == '{') {

                        if (p > e.Text && p[-1] == '\\' && !inTag) { glyphs++; continue; }
                        inTag = true;
                        continue;
                    }
                    if (*p == '}') {
                        if (p > e.Text && p[-1] == '\\' && !inTag) { glyphs++; continue; }
                        inTag = false;
                        continue;
                    }
                    if (!inTag) {
                        if (drawExp > 0) {

                            if ((*p >= '0' && *p <= '9') || *p == '-') {
                                char *end = NULL;
                                double v = strtod(p, &end);
                                double eff = fabs(v) / (double)(1 << (drawExp - 1));
                                drawMax = std::max(drawMax, eff);
                                if (end && end > p) p = end - 1;
                            }
                            continue;
                        }
                        glyphs++;
                        continue;
                    }

                    if (*p == '\\') {
                        double v = 0;
                        if (strncmp(p, "\\fscx", 5) == 0 || strncmp(p, "\\fscy", 5) == 0) {
                            v = strtod(p + 5, NULL);
                            if (v > 100) scaleF = std::max(scaleF, v / 100.0);
                        } else if (strncmp(p, "\\fs", 3) == 0 && p[3] >= '0' && p[3] <= '9') {
                            v = strtod(p + 3, NULL);
                            if (v > fs) fs = v;
                        } else if (strncmp(p, "\\bord", 5) == 0) {
                            v = strtod(p + 5, NULL);
                            if (v > 0) pad = std::max(pad, v);
                        } else if (strncmp(p, "\\blur", 5) == 0 || strncmp(p, "\\be", 3) == 0) {
                            v = strtod(p + (p[2] == 'l' ? 5 : 3), NULL);
                            if (v > 0) pad = std::max(pad, 3 * v);
                        } else if (*(p + 1) == 'p' && p[2] >= '0' && p[2] <= '9') {
                            drawExp = (int)strtod(p + 2, NULL);
                            if (drawExp > 30) drawExp = 30;
                        }
                    }
                }
            }

            double fscale = _fontScale > 0 ? _fontScale : 1.0;
            double dim = (fs * scaleF + 2 * pad) * fscale * vScale;
            estimatedPx += std::max(1, glyphs) * dim * dim;
            if (drawMax > 0) {

                double ddim = (drawMax * scaleF + 2 * pad) * fscale * vScale;
                estimatedPx += ddim * ddim;
            }
            if (estimatedPx > kMaxEstimatedRasterPx) { scanBroke = true; break; }
        }

        if (!scanBroke && nextBoundaryMs > ms) {
            _scanCacheValid = true;
            _scanCacheFromMs = ms;
            _scanCacheToMs = nextBoundaryMs;
            _scanCacheOverlap = overlap;
            _scanCachePx = estimatedPx;
        } else {
            _scanCacheValid = false;
        }
        }
        if (overlap > kMaxSimultaneousEvents || estimatedPx > kMaxEstimatedRasterPx) {
            if (!_overlapWarned) {
                _overlapWarned = YES;
                if (overlap > kMaxSimultaneousEvents) {
                    SPLOG(@"[Subtitle] 同刻重叠事件超限（>%d 条 @%.1fs），该时段字幕跳过（防内存失控）",
                          kMaxSimultaneousEvents, us / 1000000.0);
                } else {
                    SPLOG(@"[Subtitle] 光栅面积预估超限（~%.0fM 像素 @%.1fs），该时段字幕跳过（防内存失控）",
                          estimatedPx / 1e6, us / 1000000.0);
                }
            }
            _texture = nil;
            _sampleGate.markSampled(us);
            _sampleGate.markRendered(us);
            [self publishTexture:nil origin:CGPointZero gen:gen];
            return;
        }

        if (overlap == 0 && !_texture) {
            _sampleGate.markSampled(us);
            _sampleGate.markRendered(us);
            _sampleGate.setAdaptiveIntervalUs(0);
            if (_scanCacheValid && _scanCacheToMs > _scanCacheFromMs) {

                const int64_t toUs = _scanCacheToMs >= LLONG_MAX / 2000 ? INT64_MAX : _scanCacheToMs * 1000;
                os_unfair_lock_lock(&_pubLock);
                if (_gen.load() == gen && _pubTexture == nil) {
                    _pubSilentFromUs = _scanCacheFromMs * 1000;
                    _pubSilentToUs = toUs;
                    _pubSilentGen = gen;
                }
                os_unfair_lock_unlock(&_pubLock);
            }
            return;
        }
    }

    uint64_t renderStart = mach_absolute_time();
    int changed = 0;

    [self workerArmRenderWatchdogStarted:renderStart gen:gen];
    ASS_Image *img = A.render_frame(_renderer, _track, (long long)(us / 1000), &changed);
    _sampleGate.markSampled(us);
    if (_poisonedGen.load() == gen) {

        [self completeRenderWindowStarted:renderStart gen:gen];
        return;
    }
    if (!img) {
        [self completeRenderWindowStarted:renderStart gen:gen];
        _texture = nil;
        _sampleGate.markRendered(us);
        _sampleGate.setAdaptiveIntervalUs(0);
        _largeDynamicStreak = 0;
        _renderCostEMAms = 0.0;
        [self publishTexture:nil origin:CGPointZero gen:gen];
        return;
    }
    if (changed == 0 && _texture && _sampleGate.lastRenderedUs() >= 0) {
        [self completeRenderWindowStarted:renderStart gen:gen];
        _sampleGate.markRendered(us);

        _sampleGate.setAdaptiveIntervalUs(0);
        _largeDynamicStreak = 0;
        _renderCostEMAms *= 0.75;
        return;
    }

    int minX = INT_MAX, minY = INT_MAX, maxX = 0, maxY = 0;
    for (ASS_Image *i = img; i; i = i->next) {
        if (i->w <= 0 || i->h <= 0) continue;
        if (i->dst_x < minX) minX = i->dst_x;
        if (i->dst_y < minY) minY = i->dst_y;
        int x2 = i->dst_x + i->w;
        int y2 = i->dst_y + i->h;
        if (x2 > maxX) maxX = x2;
        if (y2 > maxY) maxY = y2;
    }
    if (minX < 0) minX = 0;
    if (minY < 0) minY = 0;
    if (maxX > vw) maxX = vw;
    if (maxY > vh) maxY = vh;
    int texW = maxX - minX, texH = maxY - minY;
    if (spDebug()) {
        if (_dbgShotLogs++ < 3) SPLOG(@"[Subtitle] 渲染 bbox=(%d,%d %dx%d) 视口=%dx%d",
                                  minX, minY, texW, texH, vw, vh);
    }
    if (texW <= 0 || texH <= 0) {
        [self completeRenderWindowStarted:renderStart gen:gen];
        _texture = nil;
        _sampleGate.markRendered(us);
        _sampleGate.setAdaptiveIntervalUs(0);
        _largeDynamicStreak = 0;
        _renderCostEMAms = 0.0;
        [self publishTexture:nil origin:CGPointZero gen:gen];
        return;
    }

    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                   width:texW height:texH mipmapped:NO];
    id<MTLTexture> nextTexture = [_device newTextureWithDescriptor:desc];
    if (!nextTexture) {

        [self completeRenderWindowStarted:renderStart gen:gen];
        _sampleGate.markRenderRetryRequired();
        return;
    }

    NSUInteger bytesPerRow = (NSUInteger)texW * 4;
    size_t canvasBytes = (size_t)bytesPerRow * (size_t)texH;
    _canvas.resize(canvasBytes);
    std::fill(_canvas.begin(), _canvas.end(), 0);
    for (ASS_Image *i = img; i; i = i->next) {
        const uint8_t *src = i->bitmap;

        int bx = i->dst_x - minX, by = i->dst_y - minY;
        int y0 = by < 0 ? -by : 0;
        int x0 = bx < 0 ? -bx : 0;
        int y1 = i->h, x1 = i->w;
        if (by + y1 > texH) y1 = texH - by;
        if (bx + x1 > texW) x1 = texW - bx;
        if (x0 >= x1 || y0 >= y1) continue;
        const uint8_t *clippedMask = src + (std::ptrdiff_t)y0 * i->stride + x0;
        uint8_t *clippedDestination =
            _canvas.data() + (size_t)(by + y0) * bytesPerRow + (size_t)(bx + x0) * 4;
        sp::compositeSubtitleBitmap(
            clippedDestination, (std::ptrdiff_t)bytesPerRow,
            clippedMask, (std::ptrdiff_t)i->stride,
            x1 - x0, y1 - y0, i->color);
    }
    [nextTexture replaceRegion:MTLRegionMake2D(0, 0, texW, texH)
                    mipmapLevel:0 withBytes:_canvas.data() bytesPerRow:bytesPerRow];
    [self completeRenderWindowStarted:renderStart gen:gen];
    if (_poisonedGen.load() == gen) return;
    _texture = nextTexture;
    _sampleGate.markRendered(us);
    [self publishTexture:nextTexture origin:CGPointMake(minX, minY) gen:gen];

    double renderCostMs = subtitleElapsedMs(renderStart);
    _renderCostEMAms = _renderCostEMAms > 0.0
        ? _renderCostEMAms * 0.75 + renderCostMs * 0.25 : renderCostMs;
    if (changed != 0) {
        _largeDynamicStreak = std::min(_largeDynamicStreak + 1, 1000u);
    } else {
        _largeDynamicStreak = 0;
    }
    int64_t oldInterval = _sampleGate.adaptiveIntervalUs();
    _sampleGate.setAdaptiveIntervalUs(
        (_largeDynamicStreak >= 2 && _renderCostEMAms > 6.0) ? 33333 : 0);
    if (spDebug() && oldInterval != _sampleGate.adaptiveIntervalUs()) {
        SPLOG(@"[Subtitle] 动态 ASS 背压 %@（EMA %.2fms, bbox %dx%d）",
              _sampleGate.adaptiveIntervalUs() ? @"30Hz" : @"关闭",
              _renderCostEMAms, texW, texH);
    }
}

#pragma mark - Lifecycle

- (void)dealloc {

    if (_renderWatchdogTimer) {
        dispatch_source_cancel(_renderWatchdogTimer);
        _renderWatchdogTimer = nil;
    }
    [self workerFreeAss];
}

- (void)resetTrack {
    _gen.fetch_add(1);

    _poisonedGen.store(sp::SPSubtitlePoisonState::kNone);
    _hasSubtitles.store(false);
    os_unfair_lock_lock(&_pubLock);
    _pubTexture = nil;
    _pubOrigin = CGPointZero;
    _pubSilentFromUs = _pubSilentToUs = 0;
    os_unfair_lock_unlock(&_pubLock);
    dispatch_async(_assQueue, ^{
        self->_codecPrivate = nil;
        self->_externalTrackActive = NO;
        self->_overlapWarned = NO;
        self->_texture = nil;
        std::vector<uint8_t>().swap(self->_canvas);
        self->_sampleGate.reset();
        self->_largeDynamicStreak = 0;
        self->_renderCostEMAms = 0.0;
        self->_scanCacheValid = false;
        [self workerRebuildTrackWithDefaultHeader:YES];
    });
}

- (void)setCodecPrivate:(NSData *)priv {
    NSData *copied = priv.length ? [priv copy] : nil;
    dispatch_async(_assQueue, ^{
        self->_codecPrivate = copied;
        [self workerRebuildTrackWithDefaultHeader:NO];
    });
}

- (void)setFontScale:(double)scale {
    dispatch_async(_assQueue, ^{
        self->_fontScale = scale;
        if (self->_renderer) {
            assApi().set_font_scale(self->_renderer, scale);
            [self workerResetDynamicState];
        }
    });
}

- (BOOL)hasSubtitles { return _hasSubtitles.load(); }
- (CGPoint)textureOrigin { return _mainOrigin; }

- (void)forceNextSample {
    _forceSampleFlag.store(true);
}

#pragma mark - Subtitle data

- (void)processChunk:(const uint8_t *)data length:(size_t)len ptsUs:(int64_t)ptsUs durationUs:(int64_t)durationUs {
    if (len == 0) return;
    if ([self isPoisonedNow]) return;

    size_t maxBytes = spLineHasDrawingTag((const char *)data, len)
                          ? kMaxDrawingEventBytes : kMaxEventBytes;
    if (len > maxBytes) {
        if (_dbgTruncWarns.fetch_add(1) < 3) {
            SPLOG(@"[Subtitle] 单条字幕事件 %zuKB 超上限，截断至 %zuKB", len / 1024, maxBytes / 1024);
        }
        len = maxBytes;
    }

    long long start = (long long)(ptsUs / 1000);
    long long dur = (long long)(durationUs / 1000);
    if (dur <= 0) dur = 100;

    _hasSubtitles.store(true);
    NSData *copied = [NSData dataWithBytes:data length:len];
    uint64_t gen = _gen.load();
    dispatch_async(_assQueue, ^{
        if (self->_gen.load() != gen || self->_poisonedGen.load() == gen) return;
        if (self->_externalTrackActive) return;
        if (![self workerEnsureAssReady]) return;
        assApi().process_chunk(self->_track, (char *)copied.bytes, (int)copied.length, start, dur);

        [self workerResetDynamicState];
        if (spDebug()) {
            if (++self->_dbgChunkLogs <= 3) {
                SPLOG(@"[Subtitle] 事件#%d @%.1fs 时长%.1fs 事件总数=%d",
                      self->_dbgChunkLogs, start / 1000.0, dur / 1000.0, self->_track->n_events);
            }
        }
    });
}

static BOOL spLineRangeHasDrawingTag(NSString *text, NSRange line) {
    NSRange search = line;
    while (search.length >= 3) {
        NSRange r = [text rangeOfString:@"\\p" options:NSLiteralSearch range:search];
        if (r.location == NSNotFound) return NO;
        NSUInteger next = r.location + 2;
        if (next < NSMaxRange(line)) {
            unichar c = [text characterAtIndex:next];
            if (c >= '1' && c <= '9') return YES;
        }
        NSUInteger newStart = r.location + 1;
        if (newStart >= NSMaxRange(line)) return NO;
        search = NSMakeRange(newStart, NSMaxRange(line) - newStart);
    }
    return NO;
}

static NSString *sanitizeSubtitleLines(NSString *text, unsigned logId) {
    const NSUInteger kMaxLineChars = kMaxEventBytes;
    const NSUInteger kMaxDrawingLineChars = kMaxDrawingEventBytes;

    NSUInteger (^lineLimit)(NSRange) = ^NSUInteger(NSRange lineRange) {
        return spLineRangeHasDrawingTag(text, lineRange) ? kMaxDrawingLineChars
                                                         : kMaxLineChars;
    };
    BOOL needsRewrite = NO;
    NSUInteger pos = 0, total = text.length;
    while (pos < total) {
        NSRange nl = [text rangeOfString:@"\n" options:0 range:NSMakeRange(pos, total - pos)];
        NSUInteger lineEnd = (nl.location == NSNotFound) ? total : nl.location;
        NSUInteger lineLen = lineEnd - pos;
        if (lineLen > kMaxLineChars && lineLen > lineLimit(NSMakeRange(pos, lineLen))) {
            needsRewrite = YES;
            break;
        }
        pos = (nl.location == NSNotFound) ? total : nl.location + 1;
    }
    if (!needsRewrite) return text;
    NSMutableString *out = [NSMutableString stringWithCapacity:MIN(total, kMaxLineChars * 64)];
    NSUInteger truncated = 0;
    pos = 0;
    while (pos < total) {
        NSRange nl = [text rangeOfString:@"\n" options:0 range:NSMakeRange(pos, total - pos)];
        NSUInteger lineEnd = (nl.location == NSNotFound) ? total : nl.location;
        NSUInteger lineLen = lineEnd - pos;
        NSUInteger limit = (lineLen > kMaxLineChars)
                               ? lineLimit(NSMakeRange(pos, lineLen)) : kMaxLineChars;
        if (lineLen > limit) {

            NSRange safe = [text rangeOfComposedCharacterSequenceAtIndex:pos + limit];
            [out appendString:[text substringWithRange:NSMakeRange(pos, safe.location - pos)]];
            truncated++;
        } else {
            [out appendString:[text substringWithRange:NSMakeRange(pos, lineLen)]];
        }
        [out appendString:@"\n"];
        pos = (nl.location == NSNotFound) ? total : nl.location + 1;
    }
    NSLog(@"[c%u][Subtitle] 外挂字幕含 %lu 条超长行（>%luKB），已截断", logId,
          (unsigned long)truncated, (unsigned long)(kMaxLineChars / 1024));
    return out;
}

- (void)invalidatePendingLoads { _loadReq.fetch_add(1); }

- (void)loadSubtitleText:(NSString *)text completion:(void (^)(BOOL))completion {
    uint64_t gen = _gen.load();
    const uint64_t req = _loadReq.fetch_add(1) + 1;
    void (^finish)(BOOL) = ^(BOOL ok) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(ok); });
    };
    dispatch_async(_assQueue, ^{
        if (self->_gen.load() != gen || self->_poisonedGen.load() == gen) { finish(NO); return; }
        if (self->_loadReq.load() != req) { finish(NO); return; }
        if (![self workerEnsureAssReady]) { finish(NO); return; }

        NSString *body = text;
        if ([body rangeOfString:@"\r"].location != NSNotFound) {
            body = [body stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
            body = [body stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
        }

        NSString *head = body.length > 4096 ? [body substringToIndex:4096] : body;
        BOOL isASS = [head containsString:@"[Script Info]"] || [head containsString:@"[V4+ Styles]"];
        NSString *script = isASS ? sanitizeSubtitleLines(body, self->_spLogId) : [self assFromSrtText:body];
        AssApi &A = assApi();
        ASS_Track *tmp = A.new_track(self->_lib);
        if (!tmp) { finish(NO); return; }
        // Feed the default header first so converted SRT content inherits the
        // 1280x720 PlayRes instead of libass's 384x288 fallback. External ASS
        // content can override PlayRes when its script is processed next.
        A.process_codec_private(tmp, (char *)kAssHeader, (int)strlen(kAssHeader));
        const char *utf8 = script.UTF8String;
        A.process_data(tmp, (char *)utf8, (int)strlen(utf8));
        enum { kMaxLoadedEvents = 200000 };
        if (tmp->n_events <= 0 || tmp->n_events > kMaxLoadedEvents) {
            if (tmp->n_events > kMaxLoadedEvents) {
                SPLOG(@"[Subtitle] 外挂字幕事件数 %d 超上限（疑似炸弹），拒绝加载", tmp->n_events);
            } else {
                SPLOG(@"[Subtitle] 外挂字幕解析出 0 条事件，拒绝加载（保留当前字幕）");
            }
            A.free_track(tmp);
            finish(NO);
            return;
        }

        if (self->_loadReq.load() != req || self->_gen.load() != gen) {
            A.free_track(tmp);
            finish(NO);
            return;
        }

        ASS_Track *old = self->_track;
        self->_track = tmp;
        self->_externalTrackActive = YES;
        self->_hasSubtitles.store(true);
        A.free_track(old);
        [self workerResetDynamicState];
        if (spDebug()) {
            SPLOG(@"[Subtitle] 外挂字幕已提交：%d 条事件 PlayRes=%dx%d",
                  self->_track->n_events, self->_track->PlayResX, self->_track->PlayResY);
        }
        finish(YES);
    });
}

- (NSString *)assFromSrtText:(NSString *)text {
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    NSMutableString *ass = [NSMutableString string];
    [ass appendString:@"[Script Info]\nScriptType: v4.00+\n\n"];
    [ass appendString:@"[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n"];
    [ass appendString:@"Style: Default,Helvetica,48,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,0,2,40,40,40,1\n\n"];
    [ass appendString:@"[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"];
    NSUInteger idx = 0;
    NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
    NSCharacterSet *wsNL = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    while (idx < lines.count) {
        while (idx < lines.count && [lines[idx] stringByTrimmingCharactersInSet:ws].length == 0) { idx++; }
        if (idx >= lines.count) break;

        NSString *timeline;
        if ([lines[idx] containsString:@"-->"]) {
            timeline = lines[idx];
            idx++;
        } else {
            idx++;
            if (idx >= lines.count) break;
            timeline = lines[idx];
            idx++;

            if (![timeline containsString:@"-->"]) continue;
        }
        NSArray *parts = [timeline componentsSeparatedByString:@"-->"];
        if (parts.count < 2) continue;
        NSString *startS = [parts[0] stringByTrimmingCharactersInSet:wsNL];
        NSString *endS = [parts[1] stringByTrimmingCharactersInSet:wsNL];

        NSRange sp = [endS rangeOfCharacterFromSet:ws];
        if (sp.location != NSNotFound) endS = [endS substringToIndex:sp.location];
        double t0 = srtTimeToSeconds(startS);
        double t1 = srtTimeToSeconds(endS);

        NSMutableString *textLines = [NSMutableString string];
        while (idx < lines.count && [lines[idx] stringByTrimmingCharactersInSet:ws].length > 0) {
            if (textLines.length < kMaxEventBytes) {
                NSString *raw = lines[idx];
                if (raw.length > kMaxEventBytes) {
                    NSRange safe = [raw rangeOfComposedCharacterSequenceAtIndex:kMaxEventBytes];
                    raw = [raw substringToIndex:safe.location];
                }
                if (textLines.length > 0) [textLines appendString:@"\\N"];
                [textLines appendString:SPSubtitleInlineTagsToASS(raw)];
            }
            idx++;
        }
        if (textLines.length == 0) continue;
        if (textLines.length > kMaxEventBytes) {
            NSRange safe = [textLines rangeOfComposedCharacterSequenceAtIndex:kMaxEventBytes];
            [textLines deleteCharactersInRange:NSMakeRange(safe.location, textLines.length - safe.location)];
        }

        [ass appendFormat:@"Dialogue: 0,%@,%@,Default,,0,0,0,,%@\n",
            [self assTimeFromSeconds:t0], [self assTimeFromSeconds:t1], textLines];
    }
    return ass;
}

static double srtTimeToSeconds(NSString *s) {
    NSArray *parts = [s componentsSeparatedByString:@":"];
    double h = 0, m = 0, sec = 0;
    if (parts.count == 3) {
        h = [parts[0] doubleValue];
        m = [parts[1] doubleValue];
        sec = [[parts[2] stringByReplacingOccurrencesOfString:@"," withString:@"."] doubleValue];
    } else if (parts.count == 2) {
        m = [parts[0] doubleValue];
        sec = [[parts[1] stringByReplacingOccurrencesOfString:@"," withString:@"."] doubleValue];
    } else {
        return 0;
    }
    return h * 3600 + m * 60 + sec;
}

- (NSString *)assTimeFromSeconds:(double)sec {
    int cs = (int)llround(sec * 100);
    int h = cs / 360000;
    int m = (cs / 6000) % 60;
    int s = (cs / 100) % 60;
    int c = cs % 100;
    return [NSString stringWithFormat:@"%d:%02d:%02d.%02d", h, m, s, c];
}

NSString *SPSubtitleInlineTagsToASS(NSString *s) {
    NSString *r = s;

    if ([r rangeOfString:@"{"].location != NSNotFound ||
        [r rangeOfString:@"}"].location != NSNotFound) {
        r = [r stringByReplacingOccurrencesOfString:@"{" withString:@"\\{"];
        r = [r stringByReplacingOccurrencesOfString:@"}" withString:@"\\}"];
    }

    if ([r rangeOfString:@"<"].location != NSNotFound) {
        NSRange all = NSMakeRange(0, r.length);
        r = [r stringByReplacingOccurrencesOfString:@"<i>" withString:@"{\\i1}"
                                            options:NSCaseInsensitiveSearch range:all];
        all = NSMakeRange(0, r.length);
        r = [r stringByReplacingOccurrencesOfString:@"</i>" withString:@"{\\i0}"
                                            options:NSCaseInsensitiveSearch range:all];
        all = NSMakeRange(0, r.length);
        r = [r stringByReplacingOccurrencesOfString:@"<b>" withString:@"{\\b1}"
                                            options:NSCaseInsensitiveSearch range:all];
        all = NSMakeRange(0, r.length);
        r = [r stringByReplacingOccurrencesOfString:@"</b>" withString:@"{\\b0}"
                                            options:NSCaseInsensitiveSearch range:all];
        all = NSMakeRange(0, r.length);
        r = [r stringByReplacingOccurrencesOfString:@"<u>" withString:@"{\\u1}"
                                            options:NSCaseInsensitiveSearch range:all];
        all = NSMakeRange(0, r.length);
        r = [r stringByReplacingOccurrencesOfString:@"</u>" withString:@"{\\u0}"
                                            options:NSCaseInsensitiveSearch range:all];
        all = NSMakeRange(0, r.length);
        r = [r stringByReplacingOccurrencesOfString:@"<[^<>]{1,64}>" withString:@""
                                            options:NSRegularExpressionSearch range:all];
    }
    return r;
}

#pragma mark - Nonblocking subtitle presentation

- (id<MTLTexture>)textureForTime:(int64_t)us viewportWidth:(int)vw viewportHeight:(int)vh {
    if (!_hasSubtitles.load()) return nil;
    if ([self isPoisonedNow]) return nil;

    const uint64_t inflightPeek = _renderStartTicks.load();
    if (inflightPeek != 0 &&
        subtitleElapsedMs(inflightPeek) > renderWatchdogMs()) {
        sp::SPSubtitleWatchdogInspection inspection;
        BOOL timedOut = NO;
        os_unfair_lock_lock(&_renderWatchdogLock);
        const uint64_t currentStart = _renderStartTicks.load();
        const double elapsedMs =
            currentStart ? subtitleElapsedMs(currentStart) : 0.0;
        inspection = _renderWatchdogGate.inspect(elapsedMs, renderWatchdogMs());
        if (inspection.decision == sp::SPSubtitleWatchdogDecision::Fire &&
            _renderWatchdogGate.claim(inspection)) {
            _renderStartTicks.store(0);
            timedOut = YES;
        }
        os_unfair_lock_unlock(&_renderWatchdogLock);
        if (timedOut) {
            [self poisonForGen:inspection.generation
                        reason:@"渲染超预算（tick 轮询检出）"];
            return nil;
        }
    }
    {

        os_unfair_lock_lock(&_pubLock);
        const bool silent = _pubTexture == nil && _pubSilentGen == _gen.load() &&
                            us >= _pubSilentFromUs && us < _pubSilentToUs;
        os_unfair_lock_unlock(&_pubLock);
        if (silent && !_forceSampleFlag.load()) return nil;
    }
    _desiredUs.store(us);
    _desiredW.store(vw);
    _desiredH.store(vh);
    if (!_renderJobPending.exchange(true)) {
        uint64_t gen = _gen.load();
        dispatch_async(_assQueue, ^{ [self renderJobForGen:gen]; });
    }
    id<MTLTexture> tex;
    os_unfair_lock_lock(&_pubLock);
    tex = _pubTexture;
    _mainOrigin = _pubOrigin;
    os_unfair_lock_unlock(&_pubLock);
    return tex;
}

@end
