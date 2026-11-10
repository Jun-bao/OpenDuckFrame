#if ODF_AIR_BETA_DIAGNOSTIC
// Derived from the frozen04 controller, SHA256 b5874dffe69a71ee0f2b0762741726590763b983ea81da958c45bd3096b1586b.
// Scene and capture POD retain that source. The embedded diagnostic ports the05
// asynchronous snapshot scheduler. Ordinary Beta UI does not create this driver.
#import "SPPresentedVideoRecorder.h"
#import "SPAirDiagnosticStream.hpp"
// Same-binary Beta fixture. The production Swift capture source owns SCK.
#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import "SPAirBetaSizing.hpp"
#import <objc/message.h>
#import <CoreFoundation/CoreFoundation.h>
#import <mach/mach_time.h>
#import <unistd.h>
#import <pthread.h>
#import <CommonCrypto/CommonDigest.h>
#include <atomic>
#include <cmath>
#include <memory>
#include <array>
#include <algorithm>
#include <vector>
#include <type_traits>
#import "SPLiveProcessor.h"
#import "SPFRCEngine.h"

@interface NSObject (SPAirBetaWindowCaptureFacadeAPI)
- (instancetype)initWithProcessor:(SPLiveProcessor *)processor;
@property (nonatomic, copy) void (^sampleHandler)(CMSampleBufferRef, uint64_t, uint64_t, uint64_t);
@property (nonatomic, copy) void (^gateHandler)(CMSampleBufferRef, uint64_t, uint64_t, uint64_t);
@property (nonatomic, copy) void (^constructionHandler)(uint64_t, uint64_t, uint64_t);
@property (nonatomic, copy) void (^statusHandler)(NSString *, BOOL);
@property (nonatomic, copy) void (^resizeEventHandler)(NSDictionary *);
@property (nonatomic, readonly) dispatch_queue_t observationQueue;
- (void)startOwnWindow:(uint32_t)windowID excludedWindowIDs:(NSArray<NSNumber *> *)outputIDs;
- (void)stopCaptureWithCompletion:(void (^)(NSString *))completion;
- (NSDictionary *)ownedCopyErrorCounters;
- (NSDictionary *)captureDiagnostics;
- (NSDictionary *)normalCaptureReport;
- (NSDictionary *)normalCaptureReportForSnapshot:(NSDictionary *)snapshot;
- (NSDictionary *)snapshotAtHostNs:(int64_t)host generation:(uint64_t)generation;
- (NSObject *)makeSessionRecorderWithPreview:(SPLivePreviewView *)preview directory:(NSString *)directory;
- (void)configureDiagnosticOutputPath:(NSString *)path;
- (void)armWithWindowID:(uint32_t)windowID ownerPID:(int32_t)ownerPID generation:(uint64_t)generation;
- (void)captureEntryFenceAtCutoffHostTicks:(uint64_t)cutoff handler:(void (^)(NSDictionary *))handler;
+ (NSDictionary *)evaluateReadiness:(NSDictionary *)readiness positive:(NSDictionary *)positive;
- (NSDictionary *)diagnosticCallbackRange;
- (void)adoptDiagnosticFormalCheckpoint:(NSDictionary *)checkpoint;
- (void)setDiagnosticOptionsProvider:(void (^)(NSDictionary *, void (^)(NSDictionary *)))provider;
- (void)finishForReason:(NSString *)reason completion:(void (^)(NSDictionary *))completion;
- (void)recordFinalLiveLogReceipt:(NSDictionary *)receipt completion:(void (^)(void))completion;
@end

static NSDictionary *SPBetaExpectedPixels(int width, int height) {
    const auto size = sp::airBetaSize(width, height);
    return @{ @"capture":@[@(width), @(height)],
        @"rifeProcess":@[@(size.processingWidth), @(size.processingHeight)],
        @"syntheticBuffer":@[@(size.processingWidth), @(size.processingHeight)],
        @"presenterOutput":@[@2200, @1600], @"originalOutput":@[@(width), @(height)],
        @"padded":@[@(size.paddedWidth), @(size.paddedHeight)], @"valid":@(size.valid) };
}

static int64_t SPProbeNs(uint64_t host) {
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&timebase); });
    return (int64_t)(((__uint128_t)host * timebase.numer) / timebase.denom);
}
static double SPProbeNow(void) { return (double)SPProbeNs(mach_absolute_time()) / 1e9; }
static BOOL SPProbeInterpolates(NSString *arm) { return [arm isEqual:@"rife"] || [arm isEqual:@"apple"]; }
static NSDictionary *SPProbeExecutableIdentity(void) {
    NSString *path = NSBundle.mainBundle.executablePath;
    NSInputStream *stream = [NSInputStream inputStreamWithFileAtPath:path];
    [stream open];
    CC_SHA256_CTX context; CC_SHA256_Init(&context);
    uint8_t bytes[65536]; NSInteger count;
    while ((count = [stream read:bytes maxLength:sizeof(bytes)]) > 0)
        CC_SHA256_Update(&context, bytes, (CC_LONG)count);
    NSError *error = stream.streamError; [stream close];
    if (count < 0 || error) return @{@"executablePath":path ?: @"", @"error":error.localizedDescription ?: @"executable read failed"};
    uint8_t digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest, &context);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (uint8_t value : digest) [hex appendFormat:@"%02x", value];
    return @{@"executablePath":path ?: @"", @"executableSHA256":hex};
}
static NSDictionary *SPProbeAppleFRCIdentity(void) {
    Class frc = NSClassFromString(@"SPFRCEngine");
    const BOOL supported = frc && ((BOOL (*)(id, SEL))objc_msgSend)((id)frc, @selector(isAvailable));
    NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
    return @{ @"engineID": @"apple.frc", @"api": @"VideoToolbox frame-rate conversion via SPFRCEngine",
        @"OSVersion": NSProcessInfo.processInfo.operatingSystemVersionString,
        @"OSVersionComponents": @[@(os.majorVersion), @(os.minorVersion), @(os.patchVersion)],
        @"engineClassAvailable": @(frc != Nil), @"isSupportedViaEngine": @(supported),
        @"supportScope": @"SPFRCEngine.isAvailable resolves OS/API capability; it does not prove a configured session or successful frame processing.",
        @"rifeModelResourceRequired": @NO };
}
static NSDictionary *SPProbeRect(NSRect r) {
    return @{ @"x": @(r.origin.x), @"y": @(r.origin.y), @"width": @(r.size.width), @"height": @(r.size.height) };
}
static NSString *SPProbeFourCC(OSType format) {
    const uint8_t bytes[4] = { (uint8_t)(format >> 24), (uint8_t)(format >> 16), (uint8_t)(format >> 8), (uint8_t)format };
    BOOL printable = YES;
    for (NSUInteger i = 0; i < 4; ++i) printable = printable && bytes[i] >= 32 && bytes[i] <= 126;
    return printable ? [[NSString alloc] initWithBytes:bytes length:4 encoding:NSASCIIStringEncoding]
        : [NSString stringWithFormat:@"0x%08x", (unsigned)format];
}
// Copy only JSON scalar color metadata, never an attachment object description,
// ICC payload, borrowed sample or SCK surface. Used once, on the capture queue.
static id SPProbeColorAttachmentJSON(CVPixelBufferRef buffer, CFStringRef key) {
    CFTypeRef value = CVBufferCopyAttachment(buffer, key, nullptr);
    if (!value) return NSNull.null;
    id result = NSNull.null;
    const CFTypeID type = CFGetTypeID(value);
    if (type == CFStringGetTypeID()) result = [(__bridge NSString *)value copy];
    else if (type == CFBooleanGetTypeID()) result = @(CFBooleanGetValue((CFBooleanRef)value));
    else if (type == CFNumberGetTypeID()) {
        double number = 0;
        if (CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &number) && std::isfinite(number)) result = @(number);
    } else result = @{ @"unsupportedCFTypeID": @(type) };
    CFRelease(value);
    return result;
}
static NSDictionary *SPProbeFirstCaptureMetadata(CMSampleBufferRef sample, CVPixelBufferRef buffer, uint64_t host, uint64_t callback) {
    const OSType format = CVPixelBufferGetPixelFormatType(buffer);
    CMFormatDescriptionRef description = CMSampleBufferGetFormatDescription(sample);
    CFTypeRef space = CVBufferCopyAttachment(buffer, kCVImageBufferCGColorSpaceKey, nullptr);
    NSString *spaceName = nil;
    const BOOL validSpace = space && CFGetTypeID(space) == CGColorSpaceGetTypeID();
    if (validSpace) {
        CFStringRef name = CGColorSpaceCopyName((CGColorSpaceRef)space);
        if (name) { spaceName = [(__bridge NSString *)name copy]; CFRelease(name); }
    }
    NSDictionary *result = @{ @"callbackOrdinal": @(callback), @"hostTicks": @(host),
        @"pixelBufferFourCC": SPProbeFourCC(format), @"pixelBufferFormatType": @(format),
        @"sampleFormatSubtypeFourCC": description ? SPProbeFourCC(CMFormatDescriptionGetMediaSubType(description)) : (id)NSNull.null,
        @"sampleFormatSubtype": description ? @(CMFormatDescriptionGetMediaSubType(description)) : (id)NSNull.null,
        @"width": @(CVPixelBufferGetWidth(buffer)), @"height": @(CVPixelBufferGetHeight(buffer)),
        @"colorPrimaries": SPProbeColorAttachmentJSON(buffer, kCVImageBufferColorPrimariesKey),
        @"transferFunction": SPProbeColorAttachmentJSON(buffer, kCVImageBufferTransferFunctionKey),
        @"yCbCrMatrix": SPProbeColorAttachmentJSON(buffer, kCVImageBufferYCbCrMatrixKey),
        @"cgColorSpaceAttachmentPresent": @(space != nullptr), @"cgColorSpaceAttachmentTypeValid": @(validSpace),
        @"cgColorSpaceName": spaceName ?: (id)NSNull.null,
        @"scope": @"First valid/data-ready complete SCK image buffer, before content gating/copy. Scalar CVBuffer color attachments copied once; missing values stay null, no inferred color space or image content." };
    if (space) CFRelease(space);
    return result;
}
static NSDictionary *SPProbeScreenshot(CGImageRef image) {
    if (!image) return @{ @"imagePresent": @NO, @"nonblankSample": @NO };
    uint8_t pixels[32 * 32 * 4] = {};
    CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, 32, 32, 8, 32 * 4, color, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(color);
    if (!context) return @{ @"imagePresent": @YES, @"nonblankSample": @NO, @"sampleUnavailable": @YES };
    CGContextDrawImage(context, CGRectMake(0, 0, 32, 32), image); CGContextRelease(context);
    int minimum = 255, maximum = 0;
    for (int i = 0; i < 32 * 32; ++i) {
        const int y = (54 * pixels[i * 4] + 183 * pixels[i * 4 + 1] + 19 * pixels[i * 4 + 2]) >> 8;
        minimum = MIN(minimum, y); maximum = MAX(maximum, y);
    }
    return @{ @"imagePresent": @YES, @"width": @(CGImageGetWidth(image)), @"height": @(CGImageGetHeight(image)),
        @"sampleLumaMin": @(minimum), @"sampleLumaMax": @(maximum), @"nonblankSample": @(maximum - minimum >= 12),
        @"scope": @"Sampled spatial luma variation in this exact own-window image; no image saved and no quality acceptance." };
}
static NSDictionary *SPProbePreflight(double minimumIdle) {
    NSDictionary *session = CFBridgingRelease(CGSessionCopyCurrentDictionary());
    const BOOL present = session != nil;
    const BOOL onConsole = [session[(__bridge NSString *)kCGSessionOnConsoleKey] boolValue];
    const BOOL loginDone = [session[(__bridge NSString *)kCGSessionLoginDoneKey] boolValue];
    NSNumber *sessionUID = session[(__bridge NSString *)kCGSessionUserIDKey];
    const BOOL matchingUID = sessionUID && sessionUID.unsignedIntValue == getuid();
    id lock = session[@"CGSSessionScreenIsLocked"];
    if (!lock) lock = session[@"kCGSSessionScreenIsLocked"];
    const BOOL asleep = CGDisplayIsAsleep(CGMainDisplayID());
    const double idle = CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateHIDSystemState, kCGAnyInputEventType);
    const BOOL idleKnown = std::isfinite(idle) && idle >= 0;
    const BOOL allowed = present && onConsole && loginDone && matchingUID && ![lock boolValue] && !asleep && idleKnown && idle >= minimumIdle;
    return @{ @"allowed": @(allowed), @"sessionAvailable": @(present), @"onConsole": @(onConsole),
        @"loginDone": @(loginDone), @"sessionUIDMatchesProcess": @(matchingUID), @"displayAsleep": @(asleep),
        @"lockKeyPresent": @(lock != nil), @"explicitLock": @([lock boolValue]),
        @"lockInterpretation": @"On-console logged-in session, awake display and no explicit lock flag; absent lock key is not affirmative unlocked evidence.",
        @"hidIdleSeconds": idleKnown ? @(idle) : (id)NSNull.null, @"minimumIdleSeconds": @(minimumIdle) };
}
static NSColor *SPProbeColor(unsigned rgb) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 255) / 255.0 green:((rgb >> 8) & 255) / 255.0 blue:(rgb & 255) / 255.0 alpha:1];
}
static void SPProbeFill(unsigned rgb, NSRect rect) { [SPProbeColor(rgb) setFill]; NSRectFill(rect); }
static void SPProbeText(NSString *text, double x, double baseline, double size, BOOL mono, unsigned color) {
    NSFont *font = mono ? [NSFont monospacedSystemFontOfSize:size weight:NSFontWeightSemibold] : [NSFont systemFontOfSize:size];
    [text drawAtPoint:NSMakePoint(x, baseline - size) withAttributes:@{ NSFontAttributeName: font, NSForegroundColorAttributeName: SPProbeColor(color) }];
}

@interface SPProbeWindow : NSWindow @end
@implementation SPProbeWindow
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

// Independent presentation baseline: no production presenter, captured buffer,
// or processing engine. The SDK supplies this update's drawable directly.
@interface SPProbeBareMetalView : NSView <CAMetalDisplayLinkDelegate> {
    CAMetalLayer *_metal;
    CAMetalDisplayLink *_link;
    id<MTLCommandQueue> _commands;
    id<MTLRenderPipelineState> _pipeline;
    NSLock *_lock;
    NSMutableArray<NSMutableDictionary *> *_frames;
    NSMutableArray<NSNumber *> *_callbackIntervals, *_presentedIntervals;
    uint64_t _callbackCount, _scheduledCount, _gpuCompleted, _gpuFailed, _presentedCallbacks, _validPresented, _zeroPresented;
    double _firstValidHost, _lastCallback, _lastPresentedTime;
    NSString *_firstFailure;
}
- (BOOL)startWithError:(NSString **)error;
- (void)stop;
- (NSString *)currentFailure;
- (NSDictionary *)snapshotIncludingFrames:(BOOL)includeFrames;
@end
@implementation SPProbeBareMetalView
- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _lock = [NSLock new]; _frames = [NSMutableArray array];
    _callbackIntervals = [NSMutableArray array]; _presentedIntervals = [NSMutableArray array];
    _metal = [CAMetalLayer layer]; _metal.pixelFormat = MTLPixelFormatBGRA8Unorm;
    _metal.framebufferOnly = YES; _metal.presentsWithTransaction = NO;
    self.wantsLayer = YES; self.layer = _metal;
    return self;
}
- (void)layout {
    [super layout];
    _metal.contentsScale = self.window.backingScaleFactor ?: 1;
    _metal.drawableSize = [self convertRectToBacking:self.bounds].size;
}
- (BOOL)startWithError:(NSString **)error {
    _metal.device = MTLCreateSystemDefaultDevice(); _commands = [_metal.device newCommandQueue];
    if (!_commands) { if (error) *error = @"bare Metal device/command queue unavailable"; return NO; }
    [self layout];
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\nstruct VOut { float4 position [[position]]; };\n"
        @"vertex VOut v(uint i [[vertex_id]]) { float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; VOut o; o.position=float4(p[i],0,1); return o; }\n"
        @"fragment float4 f(VOut o [[stage_in]],constant uint3 &c [[buffer(0)]]) { float2 p=o.position.xy; uint bit=min(uint(p.x/max(float(c.y)/16.0f,1.0f)),15u); bool on=((c.x>>bit)&1u)!=0; float3 a=on?float3(.88,.94,.98):float3(.08,.14,.20); if(p.y<float(c.z)*.15f) a=float3(float(c.x&255u)/255.0f,.65,.45); return float4(a,1); }\n";
    NSError *failure = nil;
    id<MTLLibrary> library = [_metal.device newLibraryWithSource:source options:nil error:&failure];
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"v"]; descriptor.fragmentFunction = [library newFunctionWithName:@"f"];
    descriptor.colorAttachments[0].pixelFormat = _metal.pixelFormat;
    if (library) _pipeline = [_metal.device newRenderPipelineStateWithDescriptor:descriptor error:&failure];
    if (!_pipeline) { if (error) *error = failure.localizedDescription ?: @"bare Metal pipeline unavailable"; return NO; }
    _link = [[CAMetalDisplayLink alloc] initWithMetalLayer:_metal]; _link.delegate = self;
    _link.preferredFrameRateRange = CAFrameRateRangeMake(60, 60, 60); _link.preferredFrameLatency = 1;
    _link.paused = NO;
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    return YES;
}
- (void)metalDisplayLink:(CAMetalDisplayLink *)link needsUpdate:(CAMetalDisplayLinkUpdate *)update {
    @autoreleasepool {
        const uint64_t callbackHost = mach_absolute_time();
        const double now = (double)SPProbeNs(callbackHost) / 1e9;
        id<CAMetalDrawable> drawable = update.drawable;
        [_lock lock];
        const uint64_t frame = ++_callbackCount;
        if (_lastCallback > 0) [_callbackIntervals addObject:@(now - _lastCallback)]; _lastCallback = now;
        NSMutableDictionary *record = [@{ @"frame": @(frame), @"callbackHost": @(callbackHost), @"callbackHostSeconds": @(now),
            @"callbackMediaTime": @(CACurrentMediaTime()), @"targetTimestamp": @(update.targetTimestamp),
            @"targetPresentationTimestamp": @(update.targetPresentationTimestamp), @"drawableID": @(drawable.drawableID),
            @"drawableWidth": @(drawable.texture.width), @"drawableHeight": @(drawable.texture.height) } mutableCopy];
        [_frames addObject:record]; [_lock unlock];
        id<MTLCommandBuffer> command = [_commands commandBuffer];
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = drawable.texture; pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore; pass.colorAttachments[0].clearColor = MTLClearColorMake(.06, .09, .12, 1);
        id<MTLRenderCommandEncoder> encoder = command ? [command renderCommandEncoderWithDescriptor:pass] : nil;
        if (!encoder) { [_lock lock]; record[@"encodingFailure"] = @YES; if (!_firstFailure) _firstFailure = @"bare Metal command/encoder unavailable"; [_lock unlock]; return; }
        [encoder setRenderPipelineState:_pipeline];
        // uint3 has 16-byte alignment in Metal; a fourth pad keeps the ABI exact.
        const uint32_t counter[4] = { (uint32_t)frame, (uint32_t)drawable.texture.width, (uint32_t)drawable.texture.height, 0 };
        [encoder setFragmentBytes:counter length:sizeof(counter) atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [encoder endEncoding];
        __weak SPProbeBareMetalView *weakSelf = self;
        [command addScheduledHandler:^(id<MTLCommandBuffer> scheduled) {
            const uint64_t host = mach_absolute_time();
            SPProbeBareMetalView *strong = weakSelf; if (!strong) return;
            [strong->_lock lock]; strong->_scheduledCount++; record[@"scheduledHost"] = @(host); [strong->_lock unlock];
        }];
        [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            const uint64_t host = mach_absolute_time();
            SPProbeBareMetalView *strong = weakSelf; if (!strong) return;
            [strong->_lock lock];
            const BOOL success = completed.status == MTLCommandBufferStatusCompleted;
            if (success) strong->_gpuCompleted++; else { strong->_gpuFailed++; if (!strong->_firstFailure) strong->_firstFailure = completed.error.localizedDescription ?: @"bare Metal GPU command failed"; }
            record[@"gpuCompletedHost"] = @(host); record[@"gpuCompleted"] = @(success);
            record[@"gpuStartTime"] = @(completed.GPUStartTime); record[@"gpuEndTime"] = @(completed.GPUEndTime);
            if (!success) record[@"gpuError"] = completed.error.localizedDescription ?: @"unknown";
            [strong->_lock unlock];
        }];
        [drawable addPresentedHandler:^(id<MTLDrawable> presented) {
            const uint64_t callbackHost = mach_absolute_time();
            SPProbeBareMetalView *strong = weakSelf; if (!strong) return;
            const double time = presented.presentedTime, host = (double)SPProbeNs(callbackHost) / 1e9;
            [strong->_lock lock]; strong->_presentedCallbacks++;
            record[@"presentedHandlerHost"] = @(callbackHost); record[@"presentedTime"] = @(time);
            const BOOL valid = std::isfinite(time) && time > 0; record[@"validPresentedTime"] = @(valid);
            if (valid) {
                strong->_validPresented++; if (strong->_firstValidHost == 0) strong->_firstValidHost = host;
                if (strong->_lastPresentedTime > 0) [strong->_presentedIntervals addObject:@(time - strong->_lastPresentedTime)];
                strong->_lastPresentedTime = time;
            } else strong->_zeroPresented++;
            [strong->_lock unlock];
        }];
        // Immediate ordinary presentation: no delayed slot, target-minus-1ms
        // timer, SCK work or production queue admission on this arm.
        [_lock lock]; record[@"presentRequestHost"] = @(mach_absolute_time()); [_lock unlock];
        [command presentDrawable:drawable];
        [_lock lock]; record[@"commitHost"] = @(mach_absolute_time()); [_lock unlock];
        [command commit];
    }
}
- (NSDictionary *)snapshotIncludingFrames:(BOOL)includeFrames {
    [_lock lock];
    NSMutableDictionary *value = [@{ @"displayLinkCallbacks": @(_callbackCount), @"scheduledCallbacks": @(_scheduledCount),
        @"validPresentedCallbacks": @(_validPresented), @"zeroPresentedCallbacks": @(_zeroPresented),
        @"presentedCallbacks": @(_presentedCallbacks), @"countedSource": @0, @"countedSynthetic": @0,
        @"countedPattern": @(_validPresented), @"unscoredPresented": @0, @"gpuCompletedCallbacks": @(_gpuCompleted),
        @"gpuFailedCallbacks": @(_gpuFailed), @"firstValidCallbackHost": @(_firstValidHost),
        @"callbackIntervalsSecondsSinceSnapshot": [_callbackIntervals copy],
        @"presentedTimeIntervalsSecondsSinceSnapshot": [_presentedIntervals copy],
        @"pendingGPUCompletionRecords": @(_callbackCount - _gpuCompleted - _gpuFailed),
        @"pendingPresentedHandlerRecords": @(_callbackCount - _presentedCallbacks),
        @"firstFailure": _firstFailure ?: (id)NSNull.null,
        @"counterScope": @"Independent bare-Metal bit-pattern frames. GPU completion does not imply presentedTime > 0; intervals retain callback arrival order, including any nonpositive intervals." } mutableCopy];
    [_callbackIntervals removeAllObjects]; [_presentedIntervals removeAllObjects];
    if (includeFrames) { NSMutableArray *frames = [NSMutableArray arrayWithCapacity:_frames.count]; for (NSDictionary *frame in _frames) [frames addObject:[frame copy]]; value[@"frames"] = frames; }
    [_lock unlock]; return value;
}
- (void)stop { [_link invalidate]; _link.delegate = nil; _link = nil; }
- (NSString *)currentFailure { [_lock lock]; NSString *failure = [_firstFailure copy]; [_lock unlock]; return failure; }
@end

// Deliberately mostly static, matching browser-samples/index.html. Flashing the
// background each tick would bypass the production sparse-fingerprint gate.
@interface SPProbePatternView : NSView {
    NSString *_sourceHeading, *_sourceFooter;
}
@property(nonatomic) NSUInteger contentFPS;
@property uint64_t frameNumber;
@property uint64_t timerTicks;
@property uint64_t contentUpdates;
@property uint64_t drawCalls;
@property uint64_t skippedSlots;
@property(nonatomic) uint64_t lastDrawContentID;
@property(nonatomic) uint64_t lastDrawStartedHostTicks;
@property(nonatomic) uint64_t lastDrawCompletedHostTicks;
- (void)configureSourceFPS:(NSUInteger)fps staticPattern:(BOOL)staticPattern;
@end
@implementation SPProbePatternView
- (void)configureSourceFPS:(NSUInteger)fps staticPattern:(BOOL)staticPattern {
    self.contentFPS = fps;
    _sourceHeading = staticPattern ? @"静态遮挡窗口" : [NSString stringWithFormat:@"%lu FPS 内容样本", (unsigned long)fps];
    _sourceFooter = staticPattern ? @"静态图案 / 自有窗口诊断" : [NSString stringWithFormat:@"固定 %lu FPS / 自有窗口诊断", (unsigned long)fps];
}
- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    self.drawCalls++;
    self.lastDrawContentID = self.frameNumber; self.lastDrawStartedHostTicks = mach_absolute_time();
    SPProbeFill(0x101820, self.bounds);
    [NSGraphicsContext saveGraphicsState];
    const double scale = MIN(self.bounds.size.width / 1280.0, self.bounds.size.height / 720.0);
    NSAffineTransform *transform = [NSAffineTransform transform];
    [transform translateXBy:(self.bounds.size.width - 1280 * scale) / 2 yBy:(self.bounds.size.height - 720 * scale) / 2];
    [transform scaleBy:scale]; [transform concat];
    SPProbeText(_sourceHeading, 48, 54, 23, NO, 0xdce9f2);
    SPProbeText(@"小川帧流 / 固定内容帧率", 48, 86, 18, NO, 0xa1b5c2);
    const double t = self.frameNumber / (double)self.contentFPS;
    const double x = 72 + fmod(t * 192, 1008);
    SPProbeFill(0x263b49, NSMakeRect(48, 328, 1184, 2));
    SPProbeFill(0xffb35c, NSMakeRect(x, 194, 128, 128));
    for (int i = 0; i < 8; ++i) SPProbeFill(0x182633, NSMakeRect(x + 13 + i * 14, 209, 3, 98));
    const double bx = 72 + (1008 - fmod(t * 128, 1008));
    [SPProbeColor(0x71d6c1) setFill]; [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(bx - 44, 410, 88, 88)] fill];
    SPProbeFill(0x263b49, NSMakeRect(48, 512, 1184, 2));
    SPProbeText([NSString stringWithFormat:@"FRAME %07llu", (unsigned long long)self.frameNumber], 48, 588, 38, YES, 0xf4f8fa);
    for (int i = 0; i < 16; ++i) SPProbeFill((self.frameNumber >> i) & 1 ? 0xe1edf4 : 0x344957, NSMakeRect(650 + i * 32, 554, 24, 36));
    SPProbeText(_sourceFooter, 48, 658, 17, NO, 0xa1b5c2);
    [NSGraphicsContext restoreGraphicsState];
    self.lastDrawCompletedHostTicks = mach_absolute_time();
}
@end

// Main-thread writer, exported only after its timer is stopped. No per-update
// objects, IO or locks; the existing display call remains synchronous.
struct SPProbeSourceUpdate {
    uint64_t sequence, contentID, timerTicks, contentUpdates, updateStartedHostTicks, displayReturnedHostTicks;
    uint64_t drawCallsBefore, drawCallsAfter, lastDrawContentID, lastDrawStartedHostTicks, lastDrawCompletedHostTicks;
    bool initialContent;
};
static_assert(std::is_pod<SPProbeSourceUpdate>::value, "source update records must remain POD");

// Finalization only. Keep physical Media bins separate from callback-host bins;
// neither path assumes that mach and Media absolute origins are equal.
static NSNumber *SPProbeNumber(id value) { return [value isKindOfClass:NSNumber.class] ? value : nil; }
static NSArray *SPProbePresentedIdentity(NSDictionary *info) {
    NSMutableArray *key = [NSMutableArray arrayWithObject:@"output"];
    for (NSString *name in @[@"generation", @"configVersion", @"measurementEpoch", @"clockEpoch", @"frameID"]) {
        NSNumber *number = SPProbeNumber(info[name]); if (!number) return nil; [key addObject:number];
    }
    return [key copy];
}
static double SPProbeTimestampArithmeticErrorNs(double seconds) {
    const double ns = seconds * 1e9;
    return 1 + std::abs(std::nextafter(seconds, INFINITY) - seconds) * 1e9 + std::abs(std::nextafter(ns, INFINITY) - ns);
}
static NSDictionary *SPProbeExactSecondObservations(NSArray *timeline, NSDictionary *phase, NSDictionary *presentationOrder) {
    const uint64_t startTicks = [phase[@"measurementStartHostTicks"] unsignedLongLongValue];
    const uint64_t endTicks = [phase[@"measurementEndHostTicks"] unsignedLongLongValue];
    if (!startTicks || endTicks <= startTicks) return @{ @"phase": phase[@"index"] ?: @-1,
        @"status": @"unknown", @"reason": @"missing complete phase host boundaries; no nominal duration substituted" };
    const int64_t startNs = SPProbeNs(startTicks), endNs = SPProbeNs(endTicks), secondNs = 1000000000;
    NSMutableDictionary<NSArray *, NSDictionary *> *admissions = [NSMutableDictionary dictionary];
    NSArray *admissionEvents = presentationOrder[@"airCadenceCausalTrace"][@"output"][@"events"];
    for (NSDictionary *event in admissionEvents) if ([event[@"kind"] isEqual:@"admitted"]) {
        NSArray *identity = SPProbePresentedIdentity(event); if (identity) admissions[identity] = event;
    }
    NSMutableDictionary<NSArray *, NSDictionary *> *firstPositive = [NSMutableDictionary dictionary];
    NSMutableSet *conflictingIdentities = [NSMutableSet set];
    NSUInteger invalidIdentity = 0, duplicatePositive = 0, unjoinedPositive = 0, unscoredPositive = 0;
    for (NSDictionary *row in timeline) for (NSDictionary *info in row[@"drawable"][@"presentedEventsSinceSnapshot"]) {
        const double media = [SPProbeNumber(info[@"presentedTime"]) doubleValue];
        if (!std::isfinite(media) || media <= 0) continue;
        if (![info[@"counts"] boolValue] || [info[@"redraw"] boolValue]) { unscoredPositive++; continue; }
        NSArray *identity = SPProbePresentedIdentity(info);
        const uint64_t callbackTicks = [SPProbeNumber(info[@"presentedHost"]) unsignedLongLongValue];
        if (!identity || !callbackTicks || !SPProbeNumber(info[@"synthetic"])) { invalidIdentity++; continue; }
        NSDictionary *admitted = admissions[identity];
        if (admissionEvents && !admitted) { unjoinedPositive++; continue; }
        if (admitted && (![admitted[@"counts"] boolValue] || [admitted[@"redraw"] boolValue])) { unscoredPositive++; continue; }
        const BOOL synthetic = [info[@"synthetic"] boolValue];
        if (admitted && ![admitted[@"type"] isEqual:(synthetic ? @"synthetic" : @"original")]) {
            [conflictingIdentities addObject:identity]; continue;
        }
        const int64_t mediaNs = (int64_t)llround(media * 1e9);
        NSDictionary *old = firstPositive[identity];
        if (old) {
            duplicatePositive++;
            if ([old[@"synthetic"] boolValue] != synthetic) [conflictingIdentities addObject:identity];
            if ([old[@"mediaNs"] longLongValue] <= mediaNs) continue;
        }
        firstPositive[identity] = @{ @"mediaNs": @(mediaNs), @"callbackTicks": @(callbackTicks), @"synthetic": @(synthetic),
            @"arithmeticErrorNs": @(SPProbeTimestampArithmeticErrorNs(media)) };
    }
    for (NSArray *identity in conflictingIdentities) [firstPositive removeObjectForKey:identity];
    NSArray *frames = [firstPositive.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"mediaNs"] compare:b[@"mediaNs"]];
    }];
    int64_t first = INT64_MAX, last = 0;
    double anchorError = 0;
    NSUInteger cohortFrames = 0;
    for (NSDictionary *frame in frames) {
        const uint64_t callback = [frame[@"callbackTicks"] unsignedLongLongValue];
        if (callback < startTicks || callback >= endTicks) continue;
        const int64_t media = [frame[@"mediaNs"] longLongValue];
        if (media < first) { first = media; anchorError = [frame[@"arithmeticErrorNs"] doubleValue]; }
        last = std::max(last, media); cohortFrames++;
    }
    struct CountBin { uint64_t source = 0, synthetic = 0, count = 0, unknownType = 0, lower = 0, upper = 0; };
    const size_t hostCount = (size_t)((endNs - startNs) / secondNs);
    const size_t mediaCount = cohortFrames >= 2 && last >= first ? (size_t)((last - first) / secondNs) : 0;
    std::vector<CountBin> hostBins(hostCount), mediaBins(mediaCount);
    NSUInteger hostTailFrames = 0, mediaTailFrames = 0, lateCallbacksInMediaSpan = 0, priorCallbacksInMediaSpan = 0, coincidentTimes = 0;
    std::vector<int64_t> actualTimes;
    std::vector<double> actualErrors;
    std::vector<int> actualTypes; // 1=source, 2=synthetic, 0=conflicting identities at this actual time.
    for (NSDictionary *frame in frames) {
        const uint64_t callback = [frame[@"callbackTicks"] unsignedLongLongValue];
        const BOOL synthetic = [frame[@"synthetic"] boolValue];
        if (callback >= startTicks && callback < endTicks) {
            const size_t index = (size_t)((SPProbeNs(callback) - startNs) / secondNs);
            if (index < hostCount) { if (synthetic) hostBins[index].synthetic++; else hostBins[index].source++; }
            else hostTailFrames++;
        }
        const int64_t media = [frame[@"mediaNs"] longLongValue];
        if (cohortFrames < 2 || media < first || media > last) continue;
        if (callback >= endTicks) lateCallbacksInMediaSpan++;
        if (callback < startTicks) priorCallbacksInMediaSpan++;
        if (!actualTimes.empty() && actualTimes.back() == media) {
            coincidentTimes++; actualErrors.back() = std::max(actualErrors.back(), [frame[@"arithmeticErrorNs"] doubleValue]);
            actualTypes.back() = 0;
        }
        else { actualTimes.push_back(media); actualErrors.push_back([frame[@"arithmeticErrorNs"] doubleValue]); actualTypes.push_back(synthetic ? 2 : 1); }
    }
    NSUInteger ambiguousMediaTimes = 0;
    for (size_t position = 0; position < actualTimes.size(); ++position) {
        const int64_t media = actualTimes[position];
        const int type = actualTypes[position]; ambiguousMediaTimes += type == 0;
        const int64_t relative = media - first, central = relative / secondNs;
        const double error = media == first ? 0 : actualErrors[position] + anchorError;
        const int64_t lower = (int64_t)std::floor(((double)relative - error) / secondNs);
        const int64_t upper = (int64_t)std::floor(((double)relative + error) / secondNs);
        if (central >= 0 && (size_t)central < mediaCount) {
            auto &bin = mediaBins[(size_t)central]; bin.count++;
            if (type == 2) bin.synthetic++; else if (type == 1) bin.source++; else bin.unknownType++;
        } else mediaTailFrames++;
        for (int64_t index = lower; index <= upper; ++index) if (index >= 0 && (size_t)index < mediaCount) {
            mediaBins[(size_t)index].upper++;
            if (lower == upper && type != 0) mediaBins[(size_t)index].lower++;
        }
    }
    NSMutableArray *hostRows = [NSMutableArray array], *mediaRows = [NSMutableArray array];
    NSUInteger host47 = 0, media47 = 0, mediaPass = 0, mediaUnknown = 0;
    for (size_t index = 0; index < hostCount; ++index) {
        const auto &bin = hostBins[index]; const uint64_t count = bin.source + bin.synthetic; host47 += count >= 47;
        [hostRows addObject:@{ @"index": @(index), @"startHostNs": @(startNs + (int64_t)index * secondNs),
            @"endHostNs": @(startNs + (int64_t)(index + 1) * secondNs), @"source": @(bin.source), @"synthetic": @(bin.synthetic),
            @"newFrames": @(count), @"atLeast47": @(count >= 47) }];
    }
    for (size_t index = 0; index < mediaCount; ++index) {
        const auto &bin = mediaBins[index]; const uint64_t count = bin.count;
        NSString *status = bin.lower >= 47 ? @"pass" : (bin.upper < 47 ? @"fail" : @"unknown");
        media47 += count >= 47; mediaPass += bin.lower >= 47; mediaUnknown += [status isEqual:@"unknown"];
        [mediaRows addObject:@{ @"index": @(index), @"startPresentedTimeMediaNs": @(first + (int64_t)index * secondNs),
            @"endPresentedTimeMediaNs": @(first + (int64_t)(index + 1) * secondNs), @"source": @(bin.source), @"synthetic": @(bin.synthetic),
            @"newFrames": @(count), @"unknownTypeTimes": @(bin.unknownType), @"lowerCount": @(bin.lower), @"upperCount": @(bin.upper), @"atLeast47": @(count >= 47), @"statusGe47": status }];
    }
    std::vector<double> periods;
    double periodError = 0;
    NSMutableDictionary *tokens = [NSMutableDictionary dictionary];
    for (NSDictionary *event in presentationOrder[@"airCadenceCausalTrace"][@"slots"][@"output"][@"callbacks"][@"events"])
        if ([event[@"outcome"] isEqual:@"created-token"] && SPProbeNumber(event[@"createdToken"])) tokens[event[@"createdToken"]] = event;
    for (NSNumber *token in tokens) {
        NSDictionary *a = tokens[token], *b = tokens[@(token.unsignedLongLongValue + 1)]; if (!b) continue;
        BOOL sameContext = YES;
        for (NSString *key in @[@"generation", @"configVersion", @"measurementEpoch", @"clockEpoch"])
            sameContext = sameContext && [a[key] isEqual:b[key]];
        NSNumber *ta = SPProbeNumber(a[@"targetPresentationTimestampMediaSeconds"]), *tb = SPProbeNumber(b[@"targetPresentationTimestampMediaSeconds"]);
        if (!sameContext || !ta || !tb) continue;
        const double delta = (tb.doubleValue - ta.doubleValue) * 1e9;
        if (std::isfinite(delta) && delta > 0) {
            periods.push_back(delta);
            periodError = std::max(periodError, SPProbeTimestampArithmeticErrorNs(ta.doubleValue) + SPProbeTimestampArithmeticErrorNs(tb.doubleValue));
        }
    }
    NSMutableDictionary *holes = [@{ @"status": @"unknown", @"adjacentIntervals": @(actualTimes.empty() ? 0 : actualTimes.size() - 1),
        @"scope": @"Distinct actual positive Media times; same-time identities disclosed. No phase-edge gap inferred. Vsync spacing comes only from consecutive actual created display tokens in the same context; scheduled targets are never gap endpoints." } mutableCopy];
    if (!periods.empty() && actualTimes.size() >= 2) {
        std::sort(periods.begin(), periods.end()); const size_t n = periods.size();
        const double period = (periods[(n - 1) / 2] + periods[n / 2]) / 2;
        NSUInteger central = 0, definite = 0, unknown = 0;
        for (size_t index = 1; index < actualTimes.size(); ++index) {
            const double gap = (double)(actualTimes[index] - actualTimes[index - 1]), error = actualErrors[index] + actualErrors[index - 1];
            central += gap >= 3 * period;
            if (gap - error >= 3 * (period + periodError)) definite++;
            else if (!(gap + error < 3 * (period - periodError))) unknown++;
        }
        const double denominator = (double)(actualTimes.size() - 1);
        [holes addEntriesFromDictionary:@{ @"status": @"observed", @"observedVsyncNs": @(period), @"observedVsyncArithmeticErrorNs": @(periodError),
            @"observedVsyncSamples": @(periods.size()), @"gapsAtLeast3Vsync": @(central), @"centralFraction": @(central / denominator),
            @"definiteHoleCount": @(definite), @"numericBoundaryUnknownCount": @(unknown),
            @"fractionLower": @(definite / denominator), @"fractionUpper": @((definite + unknown) / denominator),
            @"numericScope": @"Outward binary64/integer-ns arithmetic bounds; no physical-refresh jitter calibration." }];
    }
    return @{ @"phase": phase[@"index"] ?: @-1, @"phaseComplete": phase[@"complete"] ?: @NO,
        @"measurementStartHostTicks": @(startTicks), @"measurementEndHostTicks": @(endTicks),
        @"admissionJoinAvailable": @(admissionEvents != nil), @"unjoinedPositiveRecords": @(unjoinedPositive), @"invalidIdentityRecords": @(invalidIdentity),
        @"conflictingFrameIdentities": @(conflictingIdentities.count), @"duplicatePositiveRecords": @(duplicatePositive), @"unscoredPositiveRecords": @(unscoredPositive),
        @"callbackObservationScope": @"Raw callbacks are copied under the existing lock after each snapshotHostTicks sample. Capture is stopped before the final copy, but GPU is not drained; any later callback tail remains unknown. Processor trace has its own cutoff, not an atomic shared snapshot.",
        @"mediaPresented": @{ @"role": @"primary", @"status": mediaCount ? @"first_actual_positive_anchored" : @"unknown",
            @"anchorPresentedTimeMediaNs": cohortFrames ? @(first) : (id)NSNull.null, @"lastPresentedTimeMediaNs": cohortFrames ? @(last) : (id)NSNull.null,
            @"cohortUniquePositiveFrames": @(cohortFrames), @"completeOneSecondBins": @(mediaCount), @"retainedFullSeconds": @(mediaCount),
            @"tailDurationNs": cohortFrames ? @(last - first - (int64_t)mediaCount * secondNs) : (id)NSNull.null, @"tailFrames": @(mediaTailFrames),
            @"binsAtLeast47": @(media47), @"fractionAtLeast47": mediaCount ? @(double(media47) / mediaCount) : (id)NSNull.null,
            @"fractionAtLeast47Lower": mediaCount ? @(double(mediaPass) / mediaCount) : (id)NSNull.null,
            @"fractionAtLeast47Upper": mediaCount ? @(double(mediaPass + mediaUnknown) / mediaCount) : (id)NSNull.null,
            @"lateCallbackFramesInsideMediaSpan": @(lateCallbacksInMediaSpan), @"priorCallbackFramesInsideMediaSpan": @(priorCallbacksInMediaSpan),
            @"coincidentPositiveTimeIdentities": @(coincidentTimes), @"ambiguousPositiveTimes": @(ambiguousMediaTimes), @"bins": mediaRows, @"holes": holes,
            @"scope": @"First actual positive Media time from the phase callback cohort anchors complete half-open 1s bins. All observed first positive identities physically inside its first/last Media span are included, with cohort-external callbacks disclosed. Main counts are unique actual Media times, not identity multiplicity. Multiple identities at one time contribute at most one upper count, have unknown source/synthetic attribution and cannot support a definite lower count. Media seconds rounded to ns; count intervals preserve arithmetic and identity uncertainty. No mach/Media origin equality or physical/human acceptance asserted." },
        @"callbackHost": @{ @"role": @"auxiliary_positive_presented_callback_rate", @"completeOneSecondBins": @(hostCount),
            @"tailDurationNs": @(endNs - startNs - (int64_t)hostCount * secondNs), @"tailFrames": @(hostTailFrames),
            @"binsAtLeast47": @(host47), @"fractionAtLeast47": hostCount ? @(double(host47) / hostCount) : (id)NSNull.null, @"bins": hostRows },
        @"gateScope": @"Exact-second >=47 observations only. Coverage/ontime/source-loss/deadline/CPU/resource gates require their distinct denominators and existing full trace; functionalComplete is not App24->48 acceptance." };
}

// Capture-queue POD writer. Foundation objects are created only at final export.
struct SPProbeCaptureGateReceipt {
    uint64_t sequence, gateAdmissionSequence, captureHostTicks, sourceGeneration;
    int64_t ptsNum, ptsEpoch;
    int32_t ptsDen;
    uint32_t ptsFlags;
    bool validPTS;
};
static_assert(std::is_trivially_copyable<SPProbeCaptureGateReceipt>::value, "capture receipts must remain POD");
using SPProbeCaptureGateRing = std::array<SPProbeCaptureGateReceipt, 65536>;
static void SPProbeRecordCaptureGateReceipt(SPProbeCaptureGateRing &ring, uint64_t &total, uint64_t &invalidTotal,
    uint64_t gateAdmissionSequence, uint64_t captureHostTicks, CMTime pts, bool validPTS, uint64_t sourceGeneration) {
    const uint64_t sequence = ++total;
    auto &receipt = ring[(sequence - 1) % ring.size()];
    receipt.sequence = sequence;
    receipt.gateAdmissionSequence = gateAdmissionSequence;
    receipt.captureHostTicks = captureHostTicks;
    receipt.sourceGeneration = sourceGeneration;
    receipt.ptsNum = pts.value;
    receipt.ptsDen = pts.timescale;
    receipt.ptsEpoch = pts.epoch;
    receipt.ptsFlags = (uint32_t)pts.flags;
    receipt.validPTS = validPTS;
    if (!validPTS) ++invalidTotal;
}
static NSDictionary *SPProbeCaptureGateRow(const SPProbeCaptureGateReceipt &receipt) {
    return @{ @"sequence": @(receipt.sequence), @"gateAdmissionSequence": @(receipt.gateAdmissionSequence),
        @"captureHostTicks": @(receipt.captureHostTicks), @"sourceGeneration": @(receipt.sourceGeneration),
        @"ptsNum": @(receipt.ptsNum), @"ptsDen": @(receipt.ptsDen), @"ptsEpoch": @(receipt.ptsEpoch),
        @"ptsFlags": @(receipt.ptsFlags), @"validPTS": @(receipt.validPTS), @"clockEpoch": NSNull.null };
}
static NSDictionary *SPProbeExportCaptureGateReceipts(const SPProbeCaptureGateRing &ring, uint64_t total,
    uint64_t invalidTotal, uint64_t gateAdmittedTotal, uint64_t sourceGeneration, uint64_t cutoffHostTicks,
    uint64_t formalStartHostTicks, uint64_t formalEndHostTicks) {
    const uint64_t retained = MIN(total, (uint64_t)ring.size());
    return @{ @"schema": @"odf-capture-gate-receipts-v1", @"capacity": @((uint64_t)ring.size()),
        @"count": @(retained), @"exportedCount": @(retained), @"total": @(total), @"gateAdmittedTotal": @(gateAdmittedTotal),
        @"dropped": @(total - retained), @"overflow": @(total > retained), @"invalidTotal": @(invalidTotal),
        @"exportCutoffHostTicks": @(cutoffHostTicks), @"sourceGeneration": @(sourceGeneration),
        @"formalStartHostTicks": formalStartHostTicks ? @(formalStartHostTicks) : (id)NSNull.null,
        @"formalEndHostTicks": formalEndHostTicks ? @(formalEndHostTicks) : (id)NSNull.null,
        @"sourceGenerationScope": @"Probe-local counter advances only after an owned SCStream instance is successfully constructed, before output registration and startCapture. Processor generation and clockEpoch are separate; clockEpoch is not observed.",
        @"scope": @"Gate-admitted complete samples before owned-buffer copy. Raw host/CMTime come from that same sample. Final capture-queue export after admission stops; invalid or overflow evidence remains unknown. Formal counts use only the original phase0 host bounds; association and quality records do not add formal evidence." };
}
// Called only inside the serial source-queue fence. The prefix is an entry-
// clock cohort for the already frozen Main marker, not a Main-time counter.
static NSDictionary *SPProbeCaptureEntryPrefix(const SPProbeCaptureGateRing &ring, uint64_t total,
    uint64_t rawCounter, NSDictionary *fence) {
    const uint64_t cutoff = [SPProbeNumber(fence[@"requestedCutoffHostTicks"]) unsignedLongLongValue];
    const uint64_t fenced = [SPProbeNumber(fence[@"actualFenceHostTicks"]) unsignedLongLongValue];
    const uint64_t generation = [SPProbeNumber(fence[@"sourceGeneration"]) unsignedLongLongValue];
    const uint64_t retained = std::min(total, (uint64_t)ring.size());
    BOOL continuous = total <= ring.size(), sameGeneration = generation > 0, hostOrdered = YES, fencedEntries = YES;
    uint64_t previousHost = 0, prefix = 0;
    const SPProbeCaptureGateReceipt *lastBefore = nullptr, *firstAtOrAfter = nullptr;
    for (uint64_t index = total - retained; index < total; ++index) {
        const auto &row = ring[index % ring.size()];
        continuous = continuous && row.sequence == index + 1 && row.gateAdmissionSequence == index + 1;
        sameGeneration = sameGeneration && row.sourceGeneration == generation;
        hostOrdered = hostOrdered && row.captureHostTicks > 0 && (!index || row.captureHostTicks >= previousHost);
        fencedEntries = fencedEntries && row.captureHostTicks < fenced;
        previousHost = row.captureHostTicks;
        if (row.captureHostTicks < cutoff) { prefix = row.sequence; lastBefore = &row; }
        else if (!firstAtOrAfter) firstAtOrAfter = &row;
    }
    const BOOL known = cutoff > 0 && fenced >= cutoff && [fence[@"sourceQueueFenced"] boolValue]
        && [fence[@"captureHostSource"] isEqual:@"serial_capture_callback_entry"] && rawCounter == total
        && continuous && sameGeneration && hostOrdered && fencedEntries;
    NSMutableDictionary *result = [fence mutableCopy];
    result[@"type"] = @"fenced_entry_prefix"; result[@"known"] = @(known);
    result[@"rawCounterAtFence"] = @(rawCounter); result[@"receiptTotalAtFence"] = @(total);
    result[@"prefixSequence"] = known ? @(prefix) : (id)NSNull.null;
    result[@"lastBefore"] = lastBefore ? SPProbeCaptureGateRow(*lastBefore) : (id)NSNull.null;
    result[@"firstAtOrAfter"] = firstAtOrAfter ? SPProbeCaptureGateRow(*firstAtOrAfter) : (id)NSNull.null;
    result[@"continuousNoDrop"] = @(continuous); result[@"sameSourceGeneration"] = @(sameGeneration);
    result[@"captureHostsNondecreasing"] = @(hostOrdered); result[@"allEntriesBeforeActualFence"] = @(fencedEntries);
    result[@"lastRetainedSequence"] = retained ? @(ring[(total - 1) % ring.size()].sequence) : (id)NSNull.null;
    result[@"completeProducedTailAtFence"] = @(continuous && rawCounter == total && fencedEntries);
    result[@"cohortRule"] = @"captureHostTicks < requestedCutoffHostTicks";
    return result;
}

static NSDictionary *SPProbeSourceUpdateRow(const SPProbeSourceUpdate &event) {
    const BOOL directDrawObserved = event.drawCallsAfter > event.drawCallsBefore && event.lastDrawContentID == event.contentID &&
        event.lastDrawStartedHostTicks >= event.updateStartedHostTicks && event.lastDrawCompletedHostTicks >= event.lastDrawStartedHostTicks &&
        event.lastDrawCompletedHostTicks <= event.displayReturnedHostTicks;
    return @{ @"sequence": @(event.sequence), @"contentID": @(event.contentID), @"initialContent": @(event.initialContent),
        @"timerTicks": @(event.timerTicks), @"contentUpdates": @(event.contentUpdates),
        @"updateStartedHostTicks": @(event.updateStartedHostTicks), @"displayReturnedHostTicks": @(event.displayReturnedHostTicks),
        @"drawCallsBefore": @(event.drawCallsBefore), @"drawCallsAfter": @(event.drawCallsAfter),
        @"lastDrawContentID": event.lastDrawStartedHostTicks ? @(event.lastDrawContentID) : (id)NSNull.null,
        @"lastDrawStartedHostTicks": event.lastDrawStartedHostTicks ? @(event.lastDrawStartedHostTicks) : (id)NSNull.null,
        @"lastDrawCompletedHostTicks": event.lastDrawCompletedHostTicks ? @(event.lastDrawCompletedHostTicks) : (id)NSNull.null,
        @"directDrawObservedForContent": @(directDrawObserved) };
}


struct SPProbeSnapshotTiming {
    uint64_t sequence, beginHostTicks, endHostTicks, threadID, endThreadID, snapshotHostTicks;
    int64_t phase;
    bool isMainThread;
};

static NSDictionary *SPProbeSnapshotTimingJSON(const SPProbeSnapshotTiming &row) {
    return @{ @"sequence":@(row.sequence), @"beginHostTicks":@(row.beginHostTicks),
        @"endHostTicks":@(row.endHostTicks), @"threadID":@(row.threadID), @"endThreadID":@(row.endThreadID),
        @"snapshotHostTicks":@(row.snapshotHostTicks), @"phase":@(row.phase),
        @"isMainThread":@(row.isMainThread) };
}

static NSDictionary *SPProbeStatsWithBoundary(NSDictionary *stats, NSDictionary *boundary, NSDictionary *context) {
    NSMutableDictionary *result = [stats mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *slots = [result[@"presentationSlots"] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *output = [slots[@"output"] mutableCopy] ?: [NSMutableDictionary dictionary];
    output[@"preparedTexture"] = boundary[@"presentationSlots"][@"output"][@"preparedTexture"] ?: @{};
    slots[@"output"] = output; result[@"presentationSlots"] = slots;
    NSMutableDictionary *failures = [result[@"presentationFailuresLifetime"] mutableCopy] ?: [NSMutableDictionary dictionary];
    failures[@"output.display-submit-deadline"] = [boundary[@"enabled"] boolValue]
        ? boundary[@"presentationFailuresLifetime"][@"output.display-submit-deadline"] : (id)NSNull.null;
    result[@"presentationFailuresLifetime"] = failures;
    for (NSString *key in @[@"sourceGeneration", @"configVersion", @"measurementEpoch", @"clockEpoch",
            @"engineID", @"qualityID", @"rifeStreamEnabled", @"rateRequestedMultiplier", @"selectionGuardNs"])
        result[key] = context[key] ?: (id)NSNull.null;
    result[@"statsBoundaryCountersSampling"] = boundary;
    result[@"statsContextSampling"] = context[@"statsSampling"] ?: (id)NSNull.null;
    return result;
}

@interface SPSelfWindowCaptureProbe : NSObject {
    uint64_t _keeperFormalStartTicks, _keeperStopRequestTicks;
    NSObject *_sessionRecorder;
    void (^_sharedOptionsCompletion)(NSDictionary *);
    BOOL _sharedFunctionalComplete;
    BOOL _keeperComparisonMarked;
    SPPresentedVideoRecorder *_qualityRecorder;
    double _qualitySeconds, _qualityBeginMediaTime, _qualityEndMediaTime;
    BOOL _qualityStarting, _qualityFinishing, _qualityFinished;
    SPProbeCaptureGateRing _captureGateReceiptRing;
    std::vector<SPProbeCaptureGateReceipt> _captureGateFrozen;
    id _formalAirTraceSnapshot, _associationAirTraceSnapshot, _finalAirTraceSnapshot;
    NSString *_exportProgressPath;
    uint64_t _traceWriteStartHostTicks;
    uint64_t _captureGateReceiptTotal, _captureGateInvalidTotal;
    std::atomic<uint64_t> _captureReceiptSourceGeneration;
    BOOL _associationPending;
    std::atomic_bool _associationLastInputPTSValid;
    std::atomic<uint64_t> _associationLastInputCaptureHost;
    std::atomic<int64_t> _associationLastInputPTSNum, _associationLastInputPTSEpoch;
    std::atomic<int32_t> _associationLastInputPTSDen;

    dispatch_queue_t _captureQueue, _snapshotQueue;
    std::array<SPProbeSnapshotTiming, 2048> _snapshotTimingRows;
    uint64_t _snapshotTimingTotal, _mainThreadID, _mainThreadSampleHostTicks;
    NSUInteger _snapshotPending, _statsPrimingPending;
    NSDictionary *_snapshotMainStats;
    NSMutableDictionary *_formalEndSnapshot, *_finalStatsSnapshot;
    BOOL _snapshotFinalizeDeferred, _snapshotFinalizeComplete;
    std::atomic<uint64_t> _captureReceiptTotalSnapshot, _captureInputVersion;
    std::atomic<uint64_t> _presentedGeneration, _presentedConfig, _presentedEpoch, _presentedClock;
    uint64_t _positivePresentedHostTicks;
    double _positivePresentedTime;
    NSUInteger _sourceBoundaryPending;
    std::atomic_bool _stopping;
    NSLock *_drawableLock;
    NSMutableArray<NSDictionary *> *_drawableEvents;
    std::atomic<uint64_t> _drawableValid, _drawableSource, _drawableSynthetic, _drawableUnscored, _gpuCompletions;
    std::atomic<double> _firstDrawableHost;
    std::atomic<uint64_t> _callbacks, _complete, _idle, _invalid, _gateAdmitted, _gateDuplicates, _copied, _copyFailed;
    std::atomic<uint64_t> _formatBuffers, _formatRequestedMatches, _formatUnexpected, _formatChanges;
    std::atomic<uint32_t> _formatFirst, _formatLast;
    NSString *_requestedCaptureFormat;
    OSType _requestedCapturePixelFormat;
    std::atomic<int> _bufferWidth, _bufferHeight;
    std::atomic<double> _firstCallbackHost, _lastCallbackHost, _maxCallbackGap;
    NSMutableArray<NSNumber *> *_callbackGapsMs;
    NSMutableDictionary *_captureStatuses;
    NSObject *_bridge;
    SPLiveProcessor *_processor;
    SPLivePreviewView *_hiddenPreview, *_outputView;
    SPProbeBareMetalView *_bareView;
    SPProbeWindow *_sourceWindow, *_outputWindow;
    SPProbePatternView *_pattern;
    SCStream *_stream;
    NSTimer *_tickTimer, *_monitorTimer;
    NSMutableArray *_notifications;
    NSMutableDictionary *_report;
    NSMutableArray *_timeline, *_phases;
    NSDictionary *_previousSnapshot;
    NSString *_outputPath, *_dylibPath, *_controlLayout, *_arm;
    double _widthPoints, _heightPoints, _seconds, _minimumIdle;
    NSUInteger _sourceFPS;
    uint64_t _sourceStartHostTicks, _sourceUpdateTotal;
    std::array<SPProbeSourceUpdate, 65536> _sourceUpdates;
    double _startHost, _sourceStart, _phaseStart, _lastSnapshotHost, _lastIdle;
    NSInteger _phase;
    BOOL _streamStarted, _streamStartPending, _planCommitted, _didFinalize, _controlOnly;
    double _planCommitHost;
    BOOL _resizeMode, _resizeEvidencePending;
    BOOL _releaseValidation, _summaryOnly, _releaseQualitySwitch;
    NSUInteger _releaseSwitchIndex;
    SPLivePlanRequest *_releaseRequest;
    NSMutableArray *_resizeTransitions, *_resizePolicyEvents, *_captureLifecycle;
    std::atomic_int _resizeExpectedWidth, _resizeExpectedHeight, _resizeExpectedIndex;
    std::atomic_bool _resizeBufferRecorded;

}
@property (atomic, strong) NSDictionary *firstCaptureMetadata;
@property (nonatomic, readonly) BOOL finished;
@property (nonatomic, readonly) int exitCode;
- (instancetype)initWithOptions:(NSDictionary *)options;
- (void)start;
- (void)finish:(BOOL)complete;
- (void)finishAfterQuality:(BOOL)complete;
- (void)beginQualityPhase;
- (void)beginAssociationTail;
- (BOOL)recordExportProgress:(NSString *)stage fields:(NSDictionary *)fields;
- (void)stopStreamAndFinalize:(BOOL)complete;
- (void)prepareSharedDiagnosticOptions:(NSDictionary *)context completion:(void (^)(NSDictionary *))completion;
- (void)writeReleaseSummary:(BOOL)complete;
- (void)recordSourceUpdateStarted:(uint64_t)started drawCallsBefore:(uint64_t)drawCalls initial:(BOOL)initial;
- (NSDictionary *)captureFormatSnapshot;
- (void)observeSample:(CMSampleBufferRef)sample productGeneration:(uint64_t)productGeneration
    streamGeneration:(uint64_t)streamGeneration host:(uint64_t)host;
- (void)observeGateAdmission:(CMSampleBufferRef)sample productGeneration:(uint64_t)productGeneration
    streamGeneration:(uint64_t)streamGeneration host:(uint64_t)host;
- (void)monitorResizeScenario;
- (void)finishAfterNormalCapture:(BOOL)complete;

- (NSDictionary *)processorStatsCheckpoint;
- (void)primeStatsCache:(NSString *)reason;
- (NSDictionary *)measurementReadyProof;
- (void)captureSourceEntryPrefixForMarker:(uint64_t)marker phase:(NSMutableDictionary *)phase begin:(BOOL)begin;
- (void)finalizeAfterCapture:(BOOL)complete format:(NSDictionary *)captureFormat receipts:(NSDictionary *)captureReceipts;
@end

@implementation SPSelfWindowCaptureProbe
- (instancetype)initWithOptions:(NSDictionary *)options {
    if (!(self = [super init])) return nil;
    _outputPath = options[@"output"]; _exportProgressPath = [_outputPath stringByAppendingString:@".stages.ndjson"]; _dylibPath = options[@"dylib"]; _arm = options[@"arm"]; _controlOnly = [options[@"control-only"] boolValue];
    _widthPoints = [options[@"source-width-points"] doubleValue]; _heightPoints = [options[@"source-height-points"] doubleValue];
    _seconds = [options[@"seconds"] doubleValue]; _minimumIdle = [options[@"minimum-idle-seconds"] doubleValue];
    _sourceFPS = [options[@"source-fps"] unsignedIntegerValue];
    _releaseValidation = [options[@"release-validation"] boolValue];
    _summaryOnly = _releaseValidation && [options[@"release-trace"] isEqual:@"summary"];
    _releaseQualitySwitch = _releaseValidation && [options[@"release-config"] isEqual:@"quality-switch"];
    _requestedCaptureFormat = [options[@"capture-format"] copy];
    _requestedCapturePixelFormat = [_requestedCaptureFormat isEqual:@"bgra"] ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    _formatBuffers.store(0); _formatRequestedMatches.store(0); _formatUnexpected.store(0); _formatChanges.store(0);
    _formatFirst.store(0); _formatLast.store(0);
    _phase = -1; _stopping.store(false); _startHost = SPProbeNow(); _traceWriteStartHostTicks = mach_absolute_time();
    _captureQueue = dispatch_queue_create("app.openduckframe.self-window-probe.capture", DISPATCH_QUEUE_SERIAL);
    _snapshotQueue = dispatch_queue_create("app.openduckframe.self-window-probe.snapshot",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    pthread_threadid_np(nullptr, &_mainThreadID); _mainThreadSampleHostTicks = mach_absolute_time();
    _drawableLock = [NSLock new]; _drawableEvents = [NSMutableArray array];
    _callbackGapsMs = [NSMutableArray array]; _captureStatuses = [NSMutableDictionary dictionary];
    _timeline = [NSMutableArray array]; _phases = [NSMutableArray array]; _notifications = [NSMutableArray array];
    _report = [@{ @"schema": @1, @"pid": @(getpid()), @"options": options, @"arm": _arm, @"controlOnly": @(_controlOnly),
        @"scope": @"Self-owned-window ScreenCaptureKit, real production content gate/owned copy/processor and actual drawable presented handlers. No external windows, Safari, physical-display or human quality acceptance.",
        @"captureAPI": @"getCurrentProcessShareableContentWithCompletionHandler:", @"globalEnumeration": @NO,
        @"permissionRequests": @NO, @"focusActivation": @NO,
        @"gpuCompletionCounterScope": @"surfaceReady is warmup-token gated and this probe does not arm that token; gpuCompletedCallbacks is not total render throughput. Presented-event gpuHost is CPU completed-handler arrival, not a hardware GPU end timestamp.",
        @"configuredSourceFPS": @(_sourceFPS), @"requestedCaptureFormat": _requestedCaptureFormat,
        @"sourceUpdatesEnabled": @(![_arm isEqual:@"bare"]),
        @"sourcePattern": [NSString stringWithFormat:@"browser-samples/index.html mostly-static 1280x720 motion geometry, paced at %lu new content slots/sec", (unsigned long)_sourceFPS],
        @"mainBundle": NSBundle.mainBundle.bundlePath ?: @"", @"timeline": _timeline, @"phases": _phases } mutableCopy];
    mach_timebase_info_data_t timebase = {}; mach_timebase_info(&timebase);
    _report[@"machTimebase"] = @{ @"numer": @(timebase.numer), @"denom": @(timebase.denom),
        @"scope": @"HostTicks multiplied by numer/denom are nanoseconds." };
    _report[@"stage"] = _releaseValidation ? @"release-normal-entry" : @"beta-normal-entry";
    if (_releaseValidation) {
        _report[@"releaseValidation"] = @{@"traceMode":options[@"release-trace"],
            @"configuration":options[@"release-config"], @"bundleID":NSBundle.mainBundle.bundleIdentifier ?: @"",
            @"version":NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"",
            @"ODFAirBeta":@([NSBundle.mainBundle.infoDictionary[@"ODFAirBeta"] boolValue]),
            @"requestPath":@"SPLiveProcessor.updateRequest production eligibility"};
    }
    _resizeMode = [options[@"entry-mode"] isEqual:@"resize"];
    _resizeTransitions = [NSMutableArray array]; _resizePolicyEvents = [NSMutableArray array]; _captureLifecycle = [NSMutableArray array];
    _resizeExpectedWidth.store(0); _resizeExpectedHeight.store(0); _resizeExpectedIndex.store(0); _resizeBufferRecorded.store(false);
    _report[@"entryMode"] = options[@"entry-mode"] ?: @"unknown";
    _report[@"performanceGateApplicable"] = @(!_resizeMode && !_summaryOnly);
    _report[@"fixtureControllerBaseSHA256"] = @"b5874dffe69a71ee0f2b0762741726590763b983ea81da958c45bd3096b1586b";
    _report[@"entryBinary"] = @{ @"executable":NSBundle.mainBundle.executablePath ?: @"", @"controller":@"linked-diagnostic-controller" };

    _report[@"writePeriodLimitSeconds"] = @720;
    _report[@"writePeriodStartHostTicks"] = @(_traceWriteStartHostTicks);
    _report[@"formalSecondsRequested"] = @(_seconds);
    _qualitySeconds = [options[@"quality-seconds"] doubleValue];
    _report[@"qualitySecondsRequested"] = @(_qualitySeconds);
    _report[@"setupStatus"] = @"unobserved";
    _report[@"stageExpectedPixels"] = SPBetaExpectedPixels(2200, _resizeMode ? 1400 : 1600);
    _report[@"initialExpectedPixels"] = SPBetaExpectedPixels(2200, 1600);
    for (NSString *key in @[@"captureActualPixels", @"rifeProcessPixels", @"synthOutputPixels", @"originalOutputPixels", @"syntheticBufferPixels", @"presenterOutputPixels", @"syntheticPresentedRect", @"originalPresentedRect"])
        _report[key] = NSNull.null;
    if ([_arm isEqual:@"bare"]) {
        _report[@"scope"] = @"Independent CAMetalDisplayLink drawable baseline, immediate bit-pattern encoding/presentDrawable/commit and static own occluder. No SCK, production library, processor, external windows, physical-display or human quality acceptance.";
        _report[@"captureAPI"] = @"none"; _report[@"sourcePattern"] = @"Static own-window occluder; independent output updates its binary counter on each 60Hz display-link callback.";
        _report[@"gpuCompletionCounterScope"] = @"Bare command-buffer completion callback count. gpuCompletedHost is CPU callback arrival; gpuStartTime/gpuEndTime are the command buffer GPU timestamps, not callback host.";
        _report[@"plan"] = @{ @"state": @"not-applicable", @"processorCreated": @NO, @"rifePreparationRequested": @NO };
        _report[@"runtimeLimitSeconds"] = @30;
    } else _report[@"plan"] = @{ @"state": @"not-requested", @"interpolationRequested": @(SPProbeInterpolates(_arm)),
        @"rifePreparationRequested": @([_arm isEqual:@"rife"]), @"applePreparationRequested": @([_arm isEqual:@"apple"]) };
    return self;
}
- (void)recordSourceUpdateStarted:(uint64_t)started drawCallsBefore:(uint64_t)drawCalls initial:(BOOL)initial {
    if (_summaryOnly) return;
    SPProbeSourceUpdate event{}; event.sequence = ++_sourceUpdateTotal;
    event.contentID = _pattern.frameNumber; event.timerTicks = _pattern.timerTicks; event.contentUpdates = _pattern.contentUpdates;
    event.updateStartedHostTicks = started; event.displayReturnedHostTicks = mach_absolute_time();
    event.drawCallsBefore = drawCalls; event.drawCallsAfter = _pattern.drawCalls; event.lastDrawContentID = _pattern.lastDrawContentID;
    event.lastDrawStartedHostTicks = _pattern.lastDrawStartedHostTicks; event.lastDrawCompletedHostTicks = _pattern.lastDrawCompletedHostTicks;
    event.initialContent = initial; _sourceUpdates[(event.sequence - 1) % _sourceUpdates.size()] = event;
}
- (void)recordProgress:(NSString *)stage {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self recordProgress:stage]; }); return; }
    NSMutableArray *events = _report[@"progress"];
    if (!events) { events = [NSMutableArray array]; _report[@"progress"] = events; }
    [events addObject:@{ @"stage": stage, @"hostElapsedSeconds": @(SPProbeNow() - _startHost) }];
    NSData *json = [NSJSONSerialization dataWithJSONObject:@{ @"pid": @(getpid()), @"events": events } options:NSJSONWritingPrettyPrinted error:nil];
    [json writeToFile:[_outputPath stringByAppendingString:@".progress.json"] options:NSDataWritingAtomic error:nil];
}
- (BOOL)recordExportProgress:(NSString *)stage fields:(NSDictionary *)fields {
    NSError *error = nil;
    const BOOL result = spAirDiagnostic::appendProgress(_exportProgressPath, stage, fields, &error);
    if (!result) {
        NSDictionary *failure = @{ @"reason":error.localizedDescription ?: @"durable progress failed", @"stage":stage,
            @"hostTicks":@(mach_absolute_time()) };
        void (^retainFailure)(void) = ^{ if (!self->_report[@"toolFirstFailure"]) self->_report[@"toolFirstFailure"] = failure; };
        if (NSThread.isMainThread) retainFailure(); else dispatch_sync(dispatch_get_main_queue(), retainFailure);
    }
    return result;
}
- (void)fail:(NSString *)reason details:(id)details {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self fail:reason details:details]; }); return; }
    if (!_report[@"firstFailure"]) _report[@"firstFailure"] = @{ @"reason": reason ?: @"unknown", @"details": details ?: NSNull.null, @"hostElapsedSeconds": @(SPProbeNow() - _startHost) };
    [self finish:NO];
}
- (NSDictionary *)windowSnapshot {
    NSRect source = _sourceWindow.frame, output = _outputWindow.frame;
    NSRect screen = _sourceWindow.screen.frame;
    NSRect overlap = NSIntersectionRect(source, output);
    NSRect sourceOnScreen = NSIntersectionRect(source, screen), outputOnScreen = NSIntersectionRect(output, screen);
    const double overlapArea = NSIsEmptyRect(overlap) ? 0 : overlap.size.width * overlap.size.height;
    const double sourceArea = NSIsEmptyRect(sourceOnScreen) ? 0 : sourceOnScreen.size.width * sourceOnScreen.size.height;
    const double outputArea = NSIsEmptyRect(outputOnScreen) ? 0 : outputOnScreen.size.width * outputOnScreen.size.height;
    return @{ @"sourceWindowID": @(_sourceWindow.windowNumber), @"outputWindowID": @(_outputWindow.windowNumber),
        @"sourceFramePoints": SPProbeRect(source), @"outputFramePoints": SPProbeRect(output), @"screenFramePoints": SPProbeRect(screen),
        @"overlapPoints": SPProbeRect(overlap), @"overlapAreaPoints2": @(overlapArea),
        @"sourceOnScreenAreaPoints2": @(sourceArea), @"outputOnScreenAreaPoints2": @(outputArea),
        @"ownWindowGeometricUncoveredAreaPoints2": _phase == 1 ? @{ @"source": @(MAX(0.0, sourceArea - overlapArea)), @"output": @(outputArea) } : @{ @"source": @(sourceArea), @"output": @(MAX(0.0, outputArea - overlapArea)) },
        @"areaScope": @"Geometric intersection of these own windows and their screen; other-app occlusion is represented only by AppKit occlusion state.",
        @"sourceVisible": @(_sourceWindow.isVisible), @"outputVisible": @(_outputWindow.isVisible),
        @"sourceOcclusionVisible": @((_sourceWindow.occlusionState & NSWindowOcclusionStateVisible) != 0),
        @"outputOcclusionVisible": @((_outputWindow.occlusionState & NSWindowOcclusionStateVisible) != 0),
        @"sourceOnActiveSpace": @(_sourceWindow.isOnActiveSpace), @"outputOnActiveSpace": @(_outputWindow.isOnActiveSpace),
        @"sourceBackingScale": @(_sourceWindow.backingScaleFactor), @"outputBackingScale": @(_outputWindow.backingScaleFactor),
        @"outputDrawableSize": SPProbeRect([_outputWindow.contentView convertRectToBacking:_outputWindow.contentView.bounds]),
        @"sourceKey": @(_sourceWindow.isKeyWindow), @"outputKey": @(_outputWindow.isKeyWindow) };
}
- (void)primeStatsCache:(NSString *)reason {
    if (!_processor) return;
    ++_statsPrimingPending;
    const uint64_t requested = mach_absolute_time();
    [_processor requestStatsSnapshotOnQueue:_snapshotQueue completion:^(NSDictionary *stats) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_snapshotMainStats = stats;
            --self->_statsPrimingPending;
            NSMutableArray *primes = self->_report[@"statsPriming"];
            if (!primes) { primes = [NSMutableArray array]; self->_report[@"statsPriming"] = primes; }
            [primes addObject:@{ @"reason":reason, @"requestHostTicks":@(requested),
                @"completionObservedHostTicks":@(mach_absolute_time()), @"statsSampling":stats[@"statsSampling"] ?: NSNull.null }];
            if (!self->_stopping.load() && self->_phase < 0) [self monitor];
        });
    }];
}
- (NSDictionary *)processorStatsCheckpoint {
    NSAssert(NSThread.isMainThread, @"Logical processor checkpoints belong to main");
    NSDictionary *stats = _snapshotMainStats ?: @{};
    NSDictionary *boundary = _processor ? [_processor statsBoundaryCountersSnapshot] : @{};
    return SPProbeStatsWithBoundary(stats, boundary, stats);
}
- (NSDictionary *)snapshot {
    NSAssert(NSThread.isMainThread, @"Source/window checkpoint must stay on main");
    const uint64_t snapshotHostTicks = mach_absolute_time();
    const double now = (double)SPProbeNs(snapshotHostTicks) / 1e9;
    const uint64_t captureReadBegin = mach_absolute_time();
    const uint64_t version = _captureInputVersion.load(std::memory_order_acquire);
    const uint64_t inputHost = _associationLastInputCaptureHost.load();
    const BOOL validPTS = _associationLastInputPTSValid.load();
    const int64_t ptsNum = _associationLastInputPTSNum.load(), ptsEpoch = _associationLastInputPTSEpoch.load();
    const int32_t ptsDen = _associationLastInputPTSDen.load();
    const BOOL coherent = !(version & 1) && version == _captureInputVersion.load(std::memory_order_acquire);
    const uint64_t errorsBegin = mach_absolute_time();
    NSDictionary *errors = _bridge ? [_bridge ownedCopyErrorCounters] : @{};
    const uint64_t errorsEnd = mach_absolute_time();
    NSDictionary *capture = @{ @"callbacks":@(_callbacks.load()), @"complete":@(_complete.load()),
        @"idle":@(_idle.load()), @"invalid":@(_invalid.load()),
        @"gateAdmitted":@(_gateAdmitted.load()), @"gateDuplicates":@(_gateDuplicates.load()),
        @"receiptTotal":@(_captureReceiptTotalSnapshot.load(std::memory_order_acquire)),
        @"sourceGeneration":@(_captureReceiptSourceGeneration.load()),
        @"copied":@(_copied.load()), @"copyFailed":@(_copyFailed.load()),
        @"bufferWidth":@(_bufferWidth.load()), @"bufferHeight":@(_bufferHeight.load()),
        @"firstCallbackHost":@(_firstCallbackHost.load()), @"lastCallbackHost":@(_lastCallbackHost.load()),
        @"maxCallbackGapSeconds":@(_maxCallbackGap.load()), @"formatObservation":[self captureFormatSnapshot],
        @"lastGateAdmittedInput":@{ @"captureHostTicks":coherent && inputHost ? @(inputHost) : (id)NSNull.null,
            @"validPTS":coherent ? @(validPTS) : (id)NSNull.null, @"coherent":@(coherent),
            @"ptsNum":coherent && validPTS ? @(ptsNum) : (id)NSNull.null,
            @"ptsDen":coherent && validPTS ? @(ptsDen) : (id)NSNull.null,
            @"ptsEpoch":coherent && validPTS ? @(ptsEpoch) : (id)NSNull.null,
            @"sourceGeneration":@(_captureReceiptSourceGeneration.load()), @"clockEpoch":NSNull.null },
        @"helpers":@{ @"ownedCopy":errors, @"ownedCopyErrorSampling":@{ @"beginHostTicks":@(errorsBegin), @"endHostTicks":@(errorsEnd) } },
        @"scalarReadBeginHostTicks":@(captureReadBegin), @"receiptSnapshotHostTicks":@(mach_absolute_time()) };
    NSDictionary *drawable = @{ @"validPresentedCallbacks":@(_drawableValid.load()), @"countedSource":@(_drawableSource.load()),
        @"countedPattern":@0, @"countedSynthetic":@(_drawableSynthetic.load()), @"unscoredPresented":@(_drawableUnscored.load()),
        @"gpuCompletedCallbacks":@(_gpuCompletions.load()), @"firstValidCallbackHost":@(_firstDrawableHost.load()),
        @"counterScope":@"Probe-owned actual atomic callback counts sampled at the logical main checkpoint; utility event-copy brackets are separate." };
    if (_bareView) drawable = [_bareView snapshotIncludingFrames:NO];
    NSDictionary *stats = [self processorStatsCheckpoint];
    NSMutableDictionary *row = [@{ @"hostElapsedSeconds":@(now - _startHost), @"snapshotHostTicks":@(snapshotHostTicks), @"phase":@(_phase),
        @"phaseElapsedSeconds":@(_phase >= 0 ? now - _phaseStart : 0),
        @"intervalSeconds":@(_lastSnapshotHost > 0 ? now - _lastSnapshotHost : 0),
        @"source":@{ @"configuredContentFPS":@(_sourceFPS), @"updatesEnabled":@(_bareView == nil), @"timerTicks":@(_pattern.timerTicks),
            @"contentUpdates":@(_pattern.contentUpdates), @"drawCalls":@(_pattern.drawCalls), @"skippedContentSlots":@(_pattern.skippedSlots), @"frameNumber":@(_pattern.frameNumber) },
        @"capture":capture, @"drawable":drawable, @"processor":stats, @"windows":[self windowSnapshot] } mutableCopy];
    if (_previousSnapshot) {
        NSMutableDictionary *delta = [NSMutableDictionary dictionary];
        for (NSString *key in @[@"validPresentedCallbacks", @"countedSource", @"countedSynthetic", @"countedPattern", @"unscoredPresented", @"gpuCompletedCallbacks"])
            delta[key] = @([drawable[key] unsignedLongLongValue] - [_previousSnapshot[@"drawable"][key] unsignedLongLongValue]);
        const double dt = now - _lastSnapshotHost;
        row[@"drawableDelta"] = delta;
        row[@"countedDrawableFPS"] = @(dt > 0 ? ([delta[@"countedSource"] doubleValue] + [delta[@"countedSynthetic"] doubleValue] + [delta[@"countedPattern"] doubleValue]) / dt : 0);
        row[@"validPresentedCallbackFPS"] = @(dt > 0 ? [delta[@"validPresentedCallbacks"] doubleValue] / dt : 0);
        row[@"processorEpochChanged"] = @(_processor && (![stats[@"measurementEpoch"] isEqual:_previousSnapshot[@"processor"][@"measurementEpoch"]] || ![stats[@"configVersion"] isEqual:_previousSnapshot[@"processor"][@"configVersion"]]));
    }
    if (_sessionRecorder) [row addEntriesFromDictionary:[_sessionRecorder diagnosticCallbackRange]];
    _previousSnapshot = row; _lastSnapshotHost = now;
    NSDictionary *checkpoint = [row copy];
    const uint64_t checkpointEndHostTicks = mach_absolute_time();
    ++_snapshotPending;
    dispatch_group_t ready = dispatch_group_create();
    __block SPProbeSnapshotTiming timing{};
    dispatch_async(_snapshotQueue, ^{
        timing.beginHostTicks = mach_absolute_time(); pthread_threadid_np(nullptr, &timing.threadID);
        timing.isMainThread = NSThread.isMainThread; timing.snapshotHostTicks = snapshotHostTicks;
        timing.phase = [checkpoint[@"phase"] longLongValue];
        NSCAssert(!timing.isMainThread, @"Snapshot request must use utility");
    });
    __block NSDictionary *captureDetails, *sampledStats;
    dispatch_group_enter(ready);
    dispatch_async(_captureQueue, ^{
        const uint64_t began = mach_absolute_time();
        NSDictionary *helpers = self->_bridge ? [self->_bridge snapshotAtHostNs:SPProbeNs(mach_absolute_time()) generation:1] : @{};
        captureDetails = @{ @"statuses":[self->_captureStatuses copy],
            @"callbackGapsMsSinceSnapshot":[self->_callbackGapsMs copy],
            @"helpers":helpers,
            @"detailSampleBeginHostTicks":@(began), @"detailSampleEndHostTicks":@(mach_absolute_time()) };
        [self->_callbackGapsMs removeAllObjects];
        dispatch_group_leave(ready);
    });
    if (_processor) {
        dispatch_group_enter(ready);
        [_processor requestStatsSnapshotOnQueue:_snapshotQueue completion:^(NSDictionary *value) {
            sampledStats = value; dispatch_group_leave(ready);
        }];
    }
    dispatch_group_notify(ready, _snapshotQueue, ^{
        @autoreleasepool {
            NSCAssert(!NSThread.isMainThread, @"Snapshot assembly must use utility");

            NSMutableDictionary *assembledCapture = [checkpoint[@"capture"] mutableCopy];
            [assembledCapture addEntriesFromDictionary:captureDetails];
            NSDictionary *normalSource = captureDetails[@"helpers"][@"normalCapture"] ?: @{};
            assembledCapture[@"copied"] = normalSource[@"accepted"] ?: (id)NSNull.null;
            assembledCapture[@"copyFailed"] = normalSource[@"poolDrops"] ?: (id)NSNull.null;
            assembledCapture[@"gateDuplicates"] = normalSource[@"contentDuplicates"] ?: (id)NSNull.null;
            assembledCapture[@"descriptiveCounterScope"] = @"Normal source counts observed during the asynchronous capture-detail sample. Main owned-copy safety leaves retain their independent bracket.";
            NSMutableDictionary *helpers = [assembledCapture[@"helpers"] mutableCopy] ?: [NSMutableDictionary dictionary];
            NSMutableDictionary *owned = [helpers[@"ownedCopy"] mutableCopy] ?: [NSMutableDictionary dictionary];
            [owned addEntriesFromDictionary:checkpoint[@"capture"][@"helpers"][@"ownedCopy"]];
            helpers[@"ownedCopy"] = owned;
            helpers[@"ownedCopyErrorSampling"] = checkpoint[@"capture"][@"helpers"][@"ownedCopyErrorSampling"];
            assembledCapture[@"helpers"] = helpers;
            NSMutableDictionary *assembledDrawable = [checkpoint[@"drawable"] mutableCopy];
            const uint64_t eventReadBegin = mach_absolute_time();
            [self->_drawableLock lock];
            assembledDrawable[@"presentedEventsSinceSnapshot"] = [self->_drawableEvents copy];
            [self->_drawableEvents removeAllObjects]; [self->_drawableLock unlock];
            assembledDrawable[@"eventCopyBeginHostTicks"] = @(eventReadBegin);
            assembledDrawable[@"eventCopyEndHostTicks"] = @(mach_absolute_time());
            NSDictionary *assembledStats = SPProbeStatsWithBoundary(sampledStats ?: @{},
                checkpoint[@"processor"][@"statsBoundaryCountersSampling"], checkpoint[@"processor"]);
            pthread_threadid_np(nullptr, &timing.endThreadID); timing.endHostTicks = mach_absolute_time();
            timing.sequence = ++self->_snapshotTimingTotal;
            self->_snapshotTimingRows[(timing.sequence - 1) % self->_snapshotTimingRows.size()] = timing;
            dispatch_async(dispatch_get_main_queue(), ^{
                row[@"capture"] = assembledCapture; row[@"drawable"] = assembledDrawable; row[@"processor"] = assembledStats;
                row[@"snapshotAssembly"] = @{ @"mainCheckpointEndHostTicks":@(checkpointEndHostTicks),
                    @"beginHostTicks":@(timing.beginHostTicks), @"endHostTicks":@(timing.endHostTicks),
                    @"threadID":@(timing.threadID), @"endThreadID":@(timing.endThreadID), @"isMainThread":@(timing.isMainThread),
                    @"completionObservedHostTicks":@(mach_absolute_time()),
                    @"scope":@"Logical main checkpoint and formal/association boundaries are unchanged by asynchronous assembly; exact main gate leaves override later descriptive samples." };
                if (sampledStats) self->_snapshotMainStats = sampledStats;
                if (row == self->_formalEndSnapshot) self->_report[@"formalEndProcessorStats"] = assembledStats;
                if (row == self->_finalStatsSnapshot) self->_report[@"finalProcessorStats"] = assembledStats;
                --self->_snapshotPending;
                if (!self->_snapshotPending && self->_snapshotFinalizeDeferred) {
                    self->_snapshotFinalizeDeferred = NO;
                    [self finalizeKeeperDocument:self->_snapshotFinalizeComplete];
                }
            });
        }
    });
    return row;
}
- (NSDictionary *)captureFormatSnapshot {
    const uint64_t observed = _formatBuffers.load(std::memory_order_relaxed);
    const OSType first = _formatFirst.load(std::memory_order_relaxed), last = _formatLast.load(std::memory_order_relaxed);
    return @{ @"requestedCaptureFormat": _requestedCaptureFormat, @"requestedFourCC": SPProbeFourCC(_requestedCapturePixelFormat),
        @"requestedPixelFormatType": @(_requestedCapturePixelFormat), @"observedImageBuffers": @(observed),
        @"requestedFormatMatches": @(_formatRequestedMatches.load(std::memory_order_relaxed)),
        @"unexpectedFormatBuffers": @(_formatUnexpected.load(std::memory_order_relaxed)),
        @"actualFormatChanges": @(_formatChanges.load(std::memory_order_relaxed)),
        @"firstActualFourCC": observed ? SPProbeFourCC(first) : (id)NSNull.null,
        @"firstActualPixelFormatType": observed ? @(first) : (id)NSNull.null,
        @"lastActualFourCC": observed ? SPProbeFourCC(last) : (id)NSNull.null,
        @"lastActualPixelFormatType": observed ? @(last) : (id)NSNull.null,
        @"firstFrame": self.firstCaptureMetadata ?: (id)NSNull.null,
        @"scope": @"Whole-run atomic scalar counts of valid/data-ready complete SCK image buffers before gate/copy, including warmup and all phases; idle/invalid/missing-buffer callbacks excluded. Changes compare consecutive observed formats. Atomic scalar snapshot with immutable first-frame metadata, no reset, no pixel sampling or content-ID/source one-to-one claim; color differences are observations, not acceptance gates." };
}
- (NSDictionary *)measurementReadyProof {
    [_drawableLock lock];
    NSDictionary *positive = @{@"sourceGeneration":@(_presentedGeneration.load()), @"configVersion":@(_presentedConfig.load()),
        @"measurementEpoch":@(_presentedEpoch.load()), @"clockEpoch":@(_presentedClock.load()),
        @"presentedHost":@(_positivePresentedHostTicks), @"presentedTime":@(_positivePresentedTime)};
    [_drawableLock unlock];
    Class gate = NSClassFromString(@"SPAirBetaMeasurementGate");
    NSString *key = _releaseValidation ? @"airWindowOptimizationReadiness" : @"airBetaMeasurementReadiness";
    return gate ? [gate evaluateReadiness:_snapshotMainStats[key] ?: @{} positive:positive]
        : @{@"ready":@NO, @"reason":@"linked measurement gate unavailable"};
}

- (void)captureSourceEntryPrefixForMarker:(uint64_t)marker phase:(NSMutableDictionary *)phase begin:(BOOL)begin {
    if (_summaryOnly) return;
    ++_sourceBoundaryPending;
    [_bridge captureEntryFenceAtCutoffHostTicks:marker handler:^(NSDictionary *fence) {
        NSDictionary *prefix = SPProbeCaptureEntryPrefix(self->_captureGateReceiptRing, self->_captureGateReceiptTotal,
            self->_gateAdmitted.load(), fence);
        dispatch_async(dispatch_get_main_queue(), ^{
            phase[begin ? @"startCaptureEntryPrefix" : @"endCaptureEntryPrefix"] = prefix;
            --self->_sourceBoundaryPending;
            if (self->_sourceBoundaryPending == 0 && self->_snapshotPending == 0 && self->_snapshotFinalizeDeferred) {
                self->_snapshotFinalizeDeferred = NO;
                [self finalizeKeeperDocument:self->_snapshotFinalizeComplete];
            }
        });
    }];
}

- (void)beginPhase:(NSInteger)phase {
    NSDictionary *readyProof = phase == 0 && [_arm isEqual:@"rife"] ? [self measurementReadyProof] : nil;
    if (readyProof && ![readyProof[@"ready"] boolValue]) return;
    _phase = phase; _phaseStart = SPProbeNow();
    if (phase == 1) {
        [_outputWindow setFrame:_sourceWindow.frame display:YES];
        [_outputWindow orderFront:nil];
    }
    [_outputView refreshVisibilitySnapshot];
    [_phases addObject:[@{ @"index": @(phase), @"arm": _arm, @"layout": phase == 1 ? @"output-overlays-source" : _controlLayout,
        @"startHostElapsedSeconds": @(_phaseStart - _startHost), @"requestedSeconds": @(_seconds),
        @"startWindows": [self windowSnapshot], @"complete": @NO } mutableCopy]];
    // A zero-length boundary snapshot prevents startup and layout transitions
    // from being counted as full measured seconds.
    _previousSnapshot = nil; _lastSnapshotHost = 0;
    NSDictionary *boundary = [self snapshot]; [_timeline addObject:boundary];
    NSMutableDictionary *record = _phases.lastObject;
    record[@"measurementStartHostElapsedSeconds"] = boundary[@"hostElapsedSeconds"];
    record[@"measurementStartHostTicks"] = boundary[@"snapshotHostTicks"];
    record[@"startValidPresentedCallbacks"] = boundary[@"drawable"][@"validPresentedCallbacks"];
    if (phase == 0) {
        record[@"startCaptureGateAdmitted"] = boundary[@"capture"][@"gateAdmitted"];
        record[@"startCaptureReceiptTotal"] = boundary[@"capture"][@"receiptTotal"];
        record[@"startCaptureSourceGeneration"] = boundary[@"capture"][@"sourceGeneration"];
        record[@"startCaptureReceiptSnapshotHostTicks"] = boundary[@"capture"][@"receiptSnapshotHostTicks"];
        record[@"measurementReadyProof"] = readyProof ?: @{};
        _report[@"measurementReadyProof"] = record[@"measurementReadyProof"];
        [self captureSourceEntryPrefixForMarker:[record[@"measurementStartHostTicks"] unsignedLongLongValue] phase:record begin:YES];
        _keeperFormalStartTicks = [record[@"measurementStartHostTicks"] unsignedLongLongValue];
        _keeperComparisonMarked = NO;
        const uint64_t marker = mach_absolute_time();
        [_processor markResidentKeepAlivePhase:@"prefix_reference"];
        _report[@"keeperFrequencyWindows"] = [@{ @"formalStartHostTicks": @(_keeperFormalStartTicks),
            @"referenceStartHostTicks": @(_keeperFormalStartTicks), @"referenceEndOffsetNs": @10000000000LL,
            @"comparisonStartOffsetNs": @10000000000LL, @"referenceCompleteSecondBins": @10,
            @"prefixMarkerHostTicks": @(marker), @"startSourceContentID": @(_pattern.frameNumber),
            @"startSourceUpdateSequence": @(_sourceUpdateTotal),
            @"scope": @"Frequency reference is formal CPU bins[0,10); comparison is bins[10,last complete). All24-to48 gates use the entire requested formal phase0. No extra preroll or source/processor reset." } mutableCopy];
    }
}
- (void)monitor {
    if (_stopping.load()) return;
    if (SPProbeNs(mach_absolute_time() - _traceWriteStartHostTicks) >= 720000000000LL) {
        if (!_report[@"toolFirstFailure"]) _report[@"toolFirstFailure"] = @{ @"reason":@"trace write period exceeded720 seconds", @"hostTicks":@(mach_absolute_time()) };
        [self recordExportProgress:@"writing-period-exceeded" fields:@{ @"limitSeconds":@720 }];
        [_processor setPresentedVideoRecorder:nil];
        [self finishAfterQuality:NO];
        return;
    }
    NSString *bareFailure = [_bareView currentFailure];
    if (bareFailure) { [self fail:@"bare Metal rendering failure" details:bareFailure]; return; }
    if (_bareView && SPProbeNow() - _startHost >= 30) { [self fail:@"bare Metal runtime limit (30 seconds)" details:nil]; return; }
    NSDictionary *preflight = SPProbePreflight(_minimumIdle);
    const double idle = [preflight[@"hidIdleSeconds"] doubleValue];
    if (![preflight[@"allowed"] boolValue] || (_lastIdle > 0 && idle + .25 < _lastIdle)) {
        [self fail:@"session/display/HID precondition changed" details:preflight]; return;
    }
    _lastIdle = idle;
    if (_qualityStarting || _qualityFinishing || _associationPending) return;
    [_outputView refreshVisibilitySnapshot]; [_hiddenPreview refreshVisibilitySnapshot];
    const BOOL outputVisible = _outputWindow.isVisible && _outputWindow.isOnActiveSpace && (_outputWindow.occlusionState & NSWindowOcclusionStateVisible);
    const BOOL sourceVisible = _sourceWindow.isVisible && _sourceWindow.isOnActiveSpace && (_phase == 1 || (_sourceWindow.occlusionState & NSWindowOcclusionStateVisible));
    if (SPProbeNow() - _sourceStart > 2 && (!outputVisible || !sourceVisible)) {
        [self fail:@"owned diagnostic window became unavailable" details:[self windowSnapshot]]; return;
    }
    if (_phase < 0) {
        [_drawableLock lock]; BOOL hasDrawable = _drawableValid > 0; [_drawableLock unlock];
        if (_bareView) hasDrawable = [[_bareView snapshotIncludingFrames:NO][@"validPresentedCallbacks"] unsignedLongLongValue] > 0;
        if (((_streamStarted && _planCommitted) || _bareView) && hasDrawable && sourceVisible && outputVisible) {
            if (_processor) {
                NSDictionary *cached = _snapshotMainStats;
                const BOOL matches = cached && [cached[@"sourceGeneration"] isEqual:@(_presentedGeneration.load())] &&
                    [cached[@"configVersion"] isEqual:@(_presentedConfig.load())] &&
                    [cached[@"measurementEpoch"] isEqual:@(_presentedEpoch.load())] &&
                    [cached[@"clockEpoch"] isEqual:@(_presentedClock.load())];
                NSDictionary *readyProof = [self measurementReadyProof];
                const BOOL finalReady = ![_arm isEqual:@"rife"] || [readyProof[@"ready"] boolValue];
                if (!matches || !finalReady) {
                    _report[@"startupReadinessLastObservation"] = readyProof;
                    if (SPProbeNow() - _startHost > 45) [self fail:@"startup timeout: actual stats cache context not ready" details:cached ?: @{}];
                    else if (!_statsPrimingPending) [self primeStatsCache:@"startup-ready"];
                    return;
                }
            }
            _report[@"startup"] = @{ @"seconds": @(SPProbeNow() - _startHost), @"planCommittedHostElapsedSeconds": _bareView ? (id)NSNull.null : @(_planCommitHost - _startHost), @"firstDrawableIsPresentedHandler": @YES };
            [self beginPhase:0];
        } else if (SPProbeNow() - _startHost > 45) [self fail:@"startup timeout: capture, requested committed plan or drawable not ready" details:[self processorStatsCheckpoint]];
        return;
    }
    if (_resizeMode) [self monitorResizeScenario];
    const double now = SPProbeNow();
    if (_releaseQualitySwitch && _phase == 0 && _releaseSwitchIndex < 2 &&
        now - _phaseStart >= (_releaseSwitchIndex == 0 ? 3.0 : 6.0)) {
        SPLivePlanRequest *request = [_releaseRequest copy];
        request.requestID = 2 + _releaseSwitchIndex;
        request.qualityID = _releaseSwitchIndex == 0 ? @"hq" : @"fast";
        NSMutableArray *changes = _report[@"configurationChanges"];
        if (!changes) { changes = [NSMutableArray array]; _report[@"configurationChanges"] = changes; }
        [changes addObject:@{@"requestID":@(request.requestID), @"qualityID":request.qualityID,
            @"requestHostTicks":@(mach_absolute_time()), @"phaseSeconds":@(now - _phaseStart),
            @"beforeProcessor":[self processorStatsCheckpoint]}];
        ++_releaseSwitchIndex;
        [_processor updateRequest:request];
    }
    const double phaseDuration = _phase == 2 ? _qualitySeconds : _seconds;
    const double phaseElapsed = _phase == 2 ? CACurrentMediaTime() - _qualityBeginMediaTime : now - _phaseStart;
    const BOOL phaseEnded = _phase == 2 ? CACurrentMediaTime() >= _qualityEndMediaTime : phaseElapsed >= phaseDuration;
    if (_phase == 0 && !_keeperComparisonMarked &&
        SPProbeNs(mach_absolute_time() - _keeperFormalStartTicks) >= 10000000000LL) {
        _keeperComparisonMarked = YES;
        const uint64_t marker = mach_absolute_time();
        [_processor markResidentKeepAlivePhase:@"comparison"];
        NSMutableDictionary *windows = _report[@"keeperFrequencyWindows"];
        windows[@"comparisonMarkerHostTicks"] = @(marker);
        windows[@"comparisonMarkerScope"] = @"Asynchronous phase annotation; arithmetic comparison boundary stays exactly formal+10s.";
    }
    if (now - _lastSnapshotHost >= 1 || phaseEnded) [_timeline addObject:[self snapshot]];
    if (phaseEnded) {
        NSMutableDictionary *phase = _phases.lastObject;
        phase[@"complete"] = @YES; phase[@"actualSeconds"] = @(now - _phaseStart); phase[@"endWindows"] = [self windowSnapshot];
        NSDictionary *end = _timeline.lastObject;
        const double dt = [end[@"hostElapsedSeconds"] doubleValue] - [phase[@"measurementStartHostElapsedSeconds"] doubleValue];
        const uint64_t valid = [end[@"drawable"][@"validPresentedCallbacks"] unsignedLongLongValue];
        const uint64_t delta = valid - [phase[@"startValidPresentedCallbacks"] unsignedLongLongValue];
        phase[@"measurementEndHostElapsedSeconds"] = end[@"hostElapsedSeconds"]; phase[@"endValidPresentedCallbacks"] = @(valid);
        phase[@"measurementEndHostTicks"] = end[@"snapshotHostTicks"];
        phase[@"validPresentedCallbackDelta"] = @(delta); phase[@"measuredDurationSeconds"] = @(dt);
        phase[@"meanValidPresentedCallbackFPS"] = @(dt > 0 ? delta / dt : 0);
        if (_phase == 0) {
            phase[@"kind"] = @"formal";
            phase[@"endCaptureGateAdmitted"] = end[@"capture"][@"gateAdmitted"];
            phase[@"endCaptureReceiptTotal"] = end[@"capture"][@"receiptTotal"];
            phase[@"endCaptureSourceGeneration"] = end[@"capture"][@"sourceGeneration"];
            phase[@"endCaptureReceiptSnapshotHostTicks"] = end[@"capture"][@"receiptSnapshotHostTicks"];
            [self captureSourceEntryPrefixForMarker:[phase[@"measurementEndHostTicks"] unsignedLongLongValue] phase:phase begin:NO];
            NSMutableDictionary *frequency = _report[@"keeperFrequencyWindows"];
            frequency[@"formalEndHostTicks"] = phase[@"measurementEndHostTicks"];
            frequency[@"formalEndMarkerObservedHostTicks"] = @(mach_absolute_time());
            _report[@"formalPhase"] = [phase copy];
            _formalEndSnapshot = (NSMutableDictionary *)end;
            _report[@"formalEndProcessorStats"] = end[@"processor"] ?: @{};
            _report[@"formalEndCaptureFormatObservation"] = end[@"capture"][@"formatObservation"] ?: @{};
            _report[@"formalCaptureActualPixels"] = @[end[@"capture"][@"bufferWidth"], end[@"capture"][@"bufferHeight"]];
            _report[@"formalSourceTraceCutoffSequence"] = @(_sourceUpdateTotal);
            [self recordExportProgress:@"formal-closed" fields:@{ @"formalStartHostTicks":phase[@"measurementStartHostTicks"] ?: NSNull.null,
                @"formalEndHostTicks":phase[@"measurementEndHostTicks"] ?: NSNull.null, @"actualSeconds":phase[@"actualSeconds"] ?: NSNull.null }];
            if (_summaryOnly) [self finish:YES]; else [self beginAssociationTail];
            return;
        }
        if (_phase == 2) {
            phase[@"kind"] = @"quality-only";
            phase[@"endMediaTime"] = @(CACurrentMediaTime());
            _report[@"qualityPhase"] = [phase copy];
        }
        if (_phase == 0 && !_controlOnly) [self beginPhase:1]; else [self finish:YES];
    }
}
- (void)start {
    NSDictionary *preflight = SPProbePreflight(_minimumIdle); _report[@"preflight"] = preflight;
    if (![preflight[@"allowed"] boolValue]) { [self fail:@"blocked before creating windows" details:preflight]; return; }
    _lastIdle = [preflight[@"hidIdleSeconds"] doubleValue];
    if (@available(macOS 14.4, *)) {} else { [self fail:@"current-process SCK requires macOS 14.4" details:nil]; return; }
    const BOOL bare = [_arm isEqual:@"bare"];
    Class processorType = Nil, viewType = Nil, bridgeType = Nil, requestType = Nil;
    if (!bare) {
    processorType = NSClassFromString(@"SPLiveProcessor"); viewType = NSClassFromString(@"SPLivePreviewView");
    bridgeType = NSClassFromString(@"SPAirBetaWindowCaptureFacade"); requestType = NSClassFromString(@"SPLivePlanRequest");
    if (!processorType || !viewType || !bridgeType || !requestType) { [self fail:@"linked Beta diagnostic classes missing" details:nil]; return; }
    [self recordProgress:@"same-binary-production-classes-linked"];
    if ([_arm isEqual:@"apple"]) {
        NSDictionary *identity = SPProbeAppleFRCIdentity(); _report[@"appleFRCIdentity"] = identity;
        if (![identity[@"isSupportedViaEngine"] boolValue]) { [self fail:@"Apple FRC capability unavailable" details:identity]; return; }
    }
    [self recordProgress:@"production-classes-resolved"];
    }
    NSScreen *screen = NSScreen.mainScreen;
    NSRect usable = screen.visibleFrame;
    if (!screen || _widthPoints > usable.size.width || _heightPoints > usable.size.height) { [self fail:@"requested source points do not fit awake screen" details:SPProbeRect(usable)]; return; }
    NSRect sourceFrame = NSMakeRect(usable.origin.x + 16, NSMaxY(usable) - _heightPoints - 16, _widthPoints, _heightPoints);
    sourceFrame.origin.x = MIN(sourceFrame.origin.x, NSMaxX(usable) - _widthPoints);
    sourceFrame.origin.y = MAX(usable.origin.y, sourceFrame.origin.y);
    NSRect outputFrame = sourceFrame;
    if (usable.size.width >= 2 * _widthPoints + 48) { outputFrame.origin.x += _widthPoints + 16; _controlLayout = @"separated-own-windows"; }
    else { outputFrame.origin.y -= MIN(160.0, _heightPoints / 4); outputFrame.origin.x += MIN(96.0, MAX(0.0, NSMaxX(usable) - NSMaxX(sourceFrame))); _controlLayout = @"source-uncovered-offset-partially-visible-output"; }
    _sourceWindow = [[SPProbeWindow alloc] initWithContentRect:sourceFrame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    _outputWindow = [[SPProbeWindow alloc] initWithContentRect:outputFrame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    for (NSWindow *window in @[_sourceWindow, _outputWindow]) { window.releasedWhenClosed = NO; window.ignoresMouseEvents = YES; window.animationBehavior = NSWindowAnimationBehaviorNone; window.level = NSNormalWindowLevel; }
    _sourceWindow.title = bare ? @"ODF static own occluder" : [NSString stringWithFormat:@"ODF self-owned %lu FPS source", (unsigned long)_sourceFPS];
    _outputWindow.title = bare ? @"ODF independent bare Metal output" : @"ODF self-owned production output";
    _pattern = [[SPProbePatternView alloc] initWithFrame:NSMakeRect(0, 0, _widthPoints, _heightPoints)];
    [_pattern configureSourceFPS:_sourceFPS staticPattern:bare]; _sourceWindow.contentView = _pattern;
    __weak SPSelfWindowCaptureProbe *weakSelf = self;
    if (bare) {
        _bareView = [[SPProbeBareMetalView alloc] initWithFrame:NSMakeRect(0, 0, _widthPoints, _heightPoints)];
        _outputWindow.contentView = _bareView;
    } else {
    _outputView = [[viewType alloc] initWithFrame:NSMakeRect(0, 0, _widthPoints, _heightPoints)]; _outputWindow.contentView = _outputView;
    [_outputView setFollowTargetContent:YES];
    _hiddenPreview = [[viewType alloc] initWithFrame:NSMakeRect(0, 0, 32, 32)];
    _processor = [processorType new]; _bridge = [[bridgeType alloc] initWithProcessor:_processor];
    _captureQueue = [_bridge observationQueue];
    _bridge.sampleHandler = ^(CMSampleBufferRef sample, uint64_t productGeneration, uint64_t streamGeneration, uint64_t host) {
        SPSelfWindowCaptureProbe *strong = weakSelf; if (strong) [strong observeSample:sample productGeneration:productGeneration streamGeneration:streamGeneration host:host];
    };
    _bridge.gateHandler = ^(CMSampleBufferRef sample, uint64_t productGeneration, uint64_t streamGeneration, uint64_t host) {
        SPSelfWindowCaptureProbe *strong = weakSelf; if (strong) [strong observeGateAdmission:sample productGeneration:productGeneration streamGeneration:streamGeneration host:host];
    };
    _bridge.constructionHandler = ^(uint64_t streamGeneration, uint64_t productGeneration, uint64_t host) {
        SPSelfWindowCaptureProbe *strong = weakSelf; if (!strong) return;
        dispatch_async(strong->_captureQueue, ^{
            strong->_captureReceiptSourceGeneration = streamGeneration;
            [strong->_captureLifecycle addObject:@{ @"sourceGeneration":@(streamGeneration), @"productSourceGeneration":@(productGeneration), @"streamCreatedHostTicks":@(host) }];
        });
    };
    _bridge.statusHandler = ^(NSString *text, BOOL failed) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SPSelfWindowCaptureProbe *strong = weakSelf; if (!strong) return;
            strong->_streamStartPending = NO;
            if (failed) { [strong fail:@"normal capture start or stream failed" details:text]; return; }
            strong->_streamStarted = YES;
            [strong recordProgress:@"normal-WindowCaptureSource-started"];
            if (strong->_stopping.load()) [strong stopStreamAndFinalize:NO];
        });
    };
    _bridge.resizeEventHandler = ^(NSDictionary *event) {
        SPSelfWindowCaptureProbe *strong = weakSelf; if (!strong) return;
        if (strong->_resizePolicyEvents.count < 32) [strong->_resizePolicyEvents addObject:[event copy]];
    };
    _processor.preview = _hiddenPreview; _processor.outputPreview = _outputView; [_processor installPresentationHooks];
    void (^productionPresented)(NSDictionary *) = [_outputView.presented copy];
    _outputView.presented = ^(NSDictionary *info) {
        if (productionPresented) productionPresented(info);
        SPSelfWindowCaptureProbe *strong = weakSelf; if (!strong) return;
        [strong->_drawableLock lock];
        if ([info[@"presentedTime"] doubleValue] > 0) {
            strong->_drawableValid++;
            strong->_presentedGeneration.store([info[@"generation"] unsignedLongLongValue]);
            strong->_presentedConfig.store([info[@"configVersion"] unsignedLongLongValue]);
            strong->_presentedEpoch.store([info[@"measurementEpoch"] unsignedLongLongValue]);
            strong->_presentedClock.store([info[@"clockEpoch"] unsignedLongLongValue]);
            strong->_positivePresentedHostTicks = [info[@"presentedHost"] unsignedLongLongValue];
            strong->_positivePresentedTime = [info[@"presentedTime"] doubleValue];
            if (strong->_firstDrawableHost == 0) { strong->_firstDrawableHost = SPProbeNow(); [strong recordProgress:@"first-valid-drawable-presented-handler"]; }
            if (![info[@"counts"] boolValue]) strong->_drawableUnscored++;
            else if ([info[@"synthetic"] boolValue]) strong->_drawableSynthetic++; else strong->_drawableSource++;
        }
        // Bounded by 60s/phase and the display refresh; retain the exact callback
        // fields for gap, wait and epoch interpretation rather than infer them.
        if (!strong->_sessionRecorder && !strong->_summaryOnly) [strong->_drawableEvents addObject:info];
        [strong->_drawableLock unlock];
    };
    if (!_summaryOnly)
        _sessionRecorder = [_bridge makeSessionRecorderWithPreview:_outputView directory:_outputPath.stringByDeletingLastPathComponent];
    [_sessionRecorder configureDiagnosticOutputPath:_outputPath];
    [_sessionRecorder setDiagnosticOptionsProvider:^(NSDictionary *context, void (^completion)(NSDictionary *)) {
        SPSelfWindowCaptureProbe *strong = weakSelf;
        if (strong) [strong prepareSharedDiagnosticOptions:context completion:completion];
    }];
    void (^productionReady)(NSDictionary *) = [_outputView.surfaceReady copy];
    _outputView.surfaceReady = ^(NSDictionary *info) { if (productionReady) productionReady(info); SPSelfWindowCaptureProbe *strong = weakSelf; if (strong && [info[@"gpuCompleted"] boolValue]) { [strong->_drawableLock lock]; strong->_gpuCompletions++; [strong->_drawableLock unlock]; } };
    _processor.planHandler = ^(NSInteger state, NSString *engine, NSString *model, NSString *reason, uint64_t requestID) {
        dispatch_async(dispatch_get_main_queue(), ^{ SPSelfWindowCaptureProbe *strong = weakSelf; if (!strong || strong->_stopping.load()) return;
            strong->_report[@"plan"] = @{ @"state": @(state), @"engine": engine ?: @"", @"model": model ?: @"", @"reason": reason ?: @"",
                @"requestID": @(requestID), @"interpolationRequested": @(SPProbeInterpolates(strong->_arm)),
                @"rifePreparationRequested": @([strong->_arm isEqual:@"rife"]), @"applePreparationRequested": @([strong->_arm isEqual:@"apple"]) };
            if (state == 2) {
                if ([strong->_arm isEqual:@"apple"] && (![engine isEqual:@"apple.frc"] || ![model isEqual:@"vt.frc.normal"])) {
                    [strong fail:@"committed Apple FRC identity mismatch" details:strong->_report[@"plan"]]; return;
                }
                strong->_planCommitted = YES; strong->_planCommitHost = SPProbeNow();
                [strong primeStatsCache:@"planCommitted"];
            }
            else if (state == 0) [strong fail:@"requested production plan did not commit" details:reason ?: @""];
        });
    };
    // Production uses this flag to color its status, including recoverable
    // budget warnings. Plan rejection and the existing stream/startup checks
    // decide whether this diagnostic can execute the requested configuration.
    _processor.statusHandler = ^(NSString *status, BOOL failed, uint64_t requestID) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SPSelfWindowCaptureProbe *strong = weakSelf; if (!strong || strong->_didFinalize) return;
            NSMutableArray *events = strong->_report[@"processorStatusEvents"];
            if (!events) { events = [NSMutableArray array]; strong->_report[@"processorStatusEvents"] = events; }
            NSDictionary *event = @{ @"status": status ?: @"", @"failedFlag": @(failed), @"requestID": @(requestID),
                @"hostElapsedSeconds": @(SPProbeNow() - strong->_startHost),
                @"scope": @"Production UI status flag, not an execution stop; plan/stream errors and timeouts remain authoritative." };
            [events addObject:event];
            if (failed && !strong->_report[@"firstFailedStatus"]) strong->_report[@"firstFailedStatus"] = event;
        });
    };
    [self primeStatsCache:@"start"];
    [_processor setRawCadenceRefreshHz:60 captureLimit:0 displayID:CGMainDisplayID()];
    }
    [_outputWindow orderFront:nil]; [_sourceWindow orderFront:nil];
    [_outputView refreshVisibilitySnapshot];
    _sourceStartHostTicks = mach_absolute_time(); _sourceStart = (double)SPProbeNs(_sourceStartHostTicks) / 1e9;
    const uint64_t initialDrawCalls = _pattern.drawCalls; [_pattern display];
    if (!bare) [self recordSourceUpdateStarted:_sourceStartHostTicks drawCallsBefore:initialDrawCalls initial:YES];
    if (!bare) {
    _tickTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / _sourceFPS repeats:YES block:^(NSTimer *timer) {
        SPSelfWindowCaptureProbe *strong = weakSelf; if (!strong || strong->_stopping.load()) return;
        SPProbePatternView *pattern = strong->_pattern; pattern.timerTicks++;
        const uint64_t slot = (uint64_t)floor((SPProbeNow() - strong->_sourceStart) * strong->_sourceFPS);
        if (slot != pattern.frameNumber) { if (slot > pattern.frameNumber + 1) pattern.skippedSlots += slot - pattern.frameNumber - 1;
            const uint64_t started = mach_absolute_time(), drawsBefore = pattern.drawCalls;
            pattern.frameNumber = slot; pattern.contentUpdates++; [pattern setNeedsDisplay:YES]; [pattern display];
            [strong recordSourceUpdateStarted:started drawCallsBefore:drawsBefore initial:NO]; }
    }];
    }
    _monitorTimer = [NSTimer scheduledTimerWithTimeInterval:.2 repeats:YES block:^(NSTimer *timer) { [weakSelf monitor]; }];
    for (NSString *name in @[NSWorkspaceSessionDidResignActiveNotification, NSWorkspaceScreensDidSleepNotification]) {
        id token = [NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { [weakSelf fail:@"workspace session resigned or screens slept" details:note.name]; }]; [_notifications addObject:@[NSWorkspace.sharedWorkspace.notificationCenter, token]];
    }
    id token = [NSDistributedNotificationCenter.defaultCenter addObserverForName:@"com.apple.screenIsLocked" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { [weakSelf fail:@"screen lock observed" details:note.name]; }]; [_notifications addObject:@[NSDistributedNotificationCenter.defaultCenter, token]];
    if (bare) {
        NSString *failure = nil;
        const BOOL selectorValid = [_bareView respondsToSelector:@selector(metalDisplayLink:needsUpdate:)];
        _report[@"metalDisplayLinkSelectorVerified"] = @(selectorValid);
        _report[@"bareConfiguration"] = @{ @"refreshHz": @60, @"preferredFrameLatency": @1,
            @"presentationMethod": @"command-buffer presentDrawable then immediate commit in display-link callback",
            @"captureStarted": @NO, @"productionLibraryLoaded": @NO, @"processorCreated": @NO,
            @"windowRoles": @"sourceWindow is a static own occluder; outputWindow contains independent CAMetalLayer" };
        if (!selectorValid || ![_bareView startWithError:&failure]) { [self fail:@"bare Metal startup failed" details:failure]; return; }
        [self recordProgress:@"bare-metal-display-link-started"];
        return;
    }
    [SCShareableContent getCurrentProcessShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SPSelfWindowCaptureProbe *strong = weakSelf; if (!strong || strong->_stopping.load()) return;
            if (error || !content) { [strong fail:@"current-process SCK content unavailable; no permission fallback" details:error.localizedDescription]; return; }
            SCWindow *owned = nil;
            for (SCWindow *window in content.windows) if (window.windowID == strong->_sourceWindow.windowNumber && window.owningApplication.processID == getpid()) { owned = window; break; }
            if (!owned) { [strong fail:@"exact owned source window not in current-process SCK content" details:@{ @"windowID": @(strong->_sourceWindow.windowNumber), @"pid": @(getpid()) }]; return; }
            SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:owned];
            // currentProcess deliberately redacts SCWindow/filter geometry.
            // This exact source belongs to us, so use its real AppKit backing
            // bounds instead of converting redacted zero metadata to 2x2.
            NSRect ownBacking = [strong->_pattern convertRectToBacking:strong->_pattern.bounds];
            const int width = ((int)llround(ownBacking.size.width)) & ~1;
            const int height = ((int)llround(ownBacking.size.height)) & ~1;
            if (width < 128 || height < 128) { [strong fail:@"invalid own source backing bounds" details:SPProbeRect(ownBacking)]; return; }
            if (width != 2200 || height != 1600 || strong->_sourceWindow.backingScaleFactor != 2) {
                strong->_report[@"setupStatus"] = @"setup_failed";
                [strong fail:@"stage-two own backing dimensions mismatch" details:SPProbeRect(ownBacking)]; return;
            }
            strong->_report[@"ownedCapture"] = @{ @"exactWindowID": @(owned.windowID), @"ownerPID": @(owned.owningApplication.processID),
                @"ownerMatchesProcess": @(owned.owningApplication.processID == getpid()), @"scWindowFrame": SPProbeRect(owned.frame),
                @"filterContentRect": SPProbeRect(filter.contentRect), @"pointPixelScale": @(filter.pointPixelScale), @"configuredWidth": @(width), @"configuredHeight": @(height),
                @"configurationGeometrySource": @"exact own NSView backing bounds; current-process SCK metadata is redacted", @"ownSourceBackingBounds": SPProbeRect(ownBacking),
                @"requestedCaptureFormat": strong->_requestedCaptureFormat, @"pixelFormat": SPProbeFourCC(strong->_requestedCapturePixelFormat),
                @"pixelFormatType": @(strong->_requestedCapturePixelFormat), @"colorSpace": @"ITU-R BT.709", @"queueDepth": @3, @"minimumFrameInterval": @0,
                @"queueDepthObservation": @"Configured only; internal SCK pool occupancy is not observable." };
            const BOOL apple = [strong->_arm isEqual:@"apple"], interpolate = SPProbeInterpolates(strong->_arm);
            SPLivePlanRequest *request = [requestType new]; request.requestID = 1; request.interpolationEnabled = interpolate;
            request.engineID = apple ? @"apple.frc" : @"rife.metal"; request.modelID = apple ? @"vt.frc.normal" : @"rife-v4.25";
            request.qualityID = apple ? @"normal" : @"fast"; request.quality = SPFRCQualityNormal; request.rifeStreamEnabled = !apple && interpolate;
            request.rateKind = SPLiveRateMultiplier; request.multiplier = interpolate ? 2 : 1; request.captureCapFPS = 0;
            request.scaleEnabled = NO; request.outputWidth = width; request.outputHeight = height; request.viewMode = SPLiveViewEnhanced; request.displayRefreshHz = 60;
            if (strong->_releaseValidation) {
                request.captureSourceKind = SPLiveCaptureSourceKindWindow;
                strong->_releaseRequest = [request copy];
                strong->_report[@"releaseRequestedConfiguration"] = @{@"engineID":request.engineID,
                    @"modelID":request.modelID, @"qualityID":request.qualityID,
                    @"rifeStreamEnabled":@(request.rifeStreamEnabled), @"multiplier":@(request.multiplier),
                    @"scaleEnabled":@(request.scaleEnabled), @"captureCapFPS":@(request.captureCapFPS),
                    @"captureSourceKind":@(request.captureSourceKind)};
            }
            strong->_report[@"planRequestedDimensionsPixels"] = @{ @"width": @(width), @"height": @(height) };
            if (apple) strong->_report[@"appleRequestedConfiguration"] = @{ @"engineID": request.engineID, @"modelID": request.modelID,
                @"qualityID": request.qualityID, @"quality": @(request.quality), @"multiplier": @(request.multiplier),
                @"rateKind": @(request.rateKind), @"rifeStreamEnabled": @(request.rifeStreamEnabled),
                @"scaleEnabled": @(request.scaleEnabled), @"sourceFPS": @(strong->_sourceFPS),
                @"captureWidth": @(width), @"captureHeight": @(height), @"requestedCaptureFormat": strong->_requestedCaptureFormat,
                @"continuousEnvironment": NSProcessInfo.processInfo.environment[@"CHUANFLOW_FRC_CONTINUOUS"] ?: (id)NSNull.null };
            [strong->_sessionRecorder armWithWindowID:owned.windowID ownerPID:owned.owningApplication.processID generation:0];
            [strong->_processor updateRequest:request];
            [strong recordProgress:@"checking-exact-own-window-screenshot"];
            SCStreamConfiguration *shot = [SCStreamConfiguration new]; shot.width = width; shot.height = height;
            shot.pixelFormat = kCVPixelFormatType_32BGRA; shot.showsCursor = NO; shot.capturesAudio = NO;
            [SCScreenshotManager captureImageWithFilter:filter configuration:shot completionHandler:^(CGImageRef image, NSError *shotError) {
                CGImageRef retained = image ? CGImageRetain(image) : NULL;
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSDictionary *imageInfo = SPProbeScreenshot(retained); if (retained) CGImageRelease(retained);
                    if (strong->_stopping.load()) return;
                    strong->_report[@"ownWindowScreenshotPreflight"] = @{ @"image": imageInfo,
                        @"errorDomain": shotError.domain ?: @"", @"errorCode": @(shotError.code), @"error": shotError.localizedDescription ?: @"" };
                    if (shotError || ![imageInfo[@"nonblankSample"] boolValue]) { [strong fail:@"exact own-window screenshot unavailable; stop without permission fallback" details:strong->_report[@"ownWindowScreenshotPreflight"]]; return; }
                    [strong recordProgress:@"exact-own-window-screenshot-nonblank"];
                    strong->_streamStartPending = YES;
                    [strong->_bridge startOwnWindow:(uint32_t)strong->_sourceWindow.windowNumber
                        excludedWindowIDs:@[@(strong->_outputWindow.windowNumber)]];
                });
            }];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                if (!strong->_stopping.load() && !strong->_report[@"ownWindowScreenshotPreflight"]) [strong fail:@"exact own-window screenshot preflight timeout" details:nil];
            });
        });
    }];
}
- (void)observeSample:(CMSampleBufferRef)sample productGeneration:(uint64_t)productGeneration
    streamGeneration:(uint64_t)streamGeneration host:(uint64_t)host {
    if (_stopping.load()) return;
    @autoreleasepool {
        const double now = (double)SPProbeNs(host) / 1e9;
        _callbacks++; if (_firstCallbackHost == 0) _firstCallbackHost = now;
        if (_lastCallbackHost > 0) { const double gap = now - _lastCallbackHost; _maxCallbackGap = MAX(_maxCallbackGap.load(), gap); if (!_summaryOnly) [_callbackGapsMs addObject:@(gap * 1000)]; } _lastCallbackHost = now;
        NSArray *attachments = (__bridge NSArray *)CMSampleBufferGetSampleAttachmentsArray(sample, false);
        NSNumber *statusValue = attachments.firstObject[SCStreamFrameInfoStatus];
        const NSInteger status = statusValue ? statusValue.integerValue : -1;
        NSString *statusKey = [NSString stringWithFormat:@"%ld", (long)status]; _captureStatuses[statusKey] = @([_captureStatuses[statusKey] unsignedLongLongValue] + 1);
        if (status == SCFrameStatusIdle) _idle++;
        if (status != SCFrameStatusComplete) return;
        _complete++;
        if (!CMSampleBufferIsValid(sample) || !CMSampleBufferDataIsReady(sample)) { _invalid++; return; }
        CVPixelBufferRef buffer = CMSampleBufferGetImageBuffer(sample); if (!buffer) { _invalid++; return; }
        const OSType actualFormat = CVPixelBufferGetPixelFormatType(buffer);
        const uint64_t observed = _formatBuffers.fetch_add(1, std::memory_order_relaxed);
        const OSType previousFormat = _formatLast.exchange(actualFormat, std::memory_order_relaxed);
        if (actualFormat == _requestedCapturePixelFormat) _formatRequestedMatches.fetch_add(1, std::memory_order_relaxed);
        else _formatUnexpected.fetch_add(1, std::memory_order_relaxed);
        if (observed && previousFormat != actualFormat) _formatChanges.fetch_add(1, std::memory_order_relaxed);
        if (!observed) {
            _formatFirst.store(actualFormat, std::memory_order_relaxed);
            self.firstCaptureMetadata = SPProbeFirstCaptureMetadata(sample, buffer, host, _callbacks);
        }
        _bufferWidth = (int)CVPixelBufferGetWidth(buffer); _bufferHeight = (int)CVPixelBufferGetHeight(buffer);
        if (!_resizeMode && (_bufferWidth != 2200 || _bufferHeight != 1600)) {
            const int width = _bufferWidth, height = _bufferHeight;
            dispatch_async(dispatch_get_main_queue(), ^{ [self fail:@"normal-entry actual capture dimensions mismatch" details:@{ @"actualPixels":@[@(width), @(height)] }]; });
        }
        if (_resizeMode && _bufferWidth == _resizeExpectedWidth.load() && _bufferHeight == _resizeExpectedHeight.load() && !_resizeBufferRecorded.exchange(true)) {
            const int index = _resizeExpectedIndex.load();
            const CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
            NSDictionary *receipt = @{ @"captureHostTicks":@(host), @"captureUptimeNs":@(SPProbeNs(host)),
                @"bufferPixels":@[@(_bufferWidth.load()), @(_bufferHeight.load())], @"sourceGeneration":@(streamGeneration), @"productSourceGeneration":@(productGeneration),
                @"ptsNum":@(pts.value), @"ptsDen":@(pts.timescale), @"ptsEpoch":@(pts.epoch), @"ptsFlags":@((uint32_t)pts.flags),
                @"validPTS":@(CMTIME_IS_VALID(pts) && !CMTIME_IS_INDEFINITE(pts) && pts.timescale > 0) };
            dispatch_async(dispatch_get_main_queue(), ^{ if (index >= 0 && index < (int)self->_resizeTransitions.count) self->_resizeTransitions[index][@"firstNewBuffer"] = receipt; });
        }
    }
}
- (void)observeGateAdmission:(CMSampleBufferRef)sample productGeneration:(uint64_t)productGeneration
    streamGeneration:(uint64_t)streamGeneration host:(uint64_t)host {
    if (_stopping.load()) return;
    ++_gateAdmitted;
    const CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
    const BOOL validPTS = CMTIME_IS_VALID(pts) && !CMTIME_IS_INDEFINITE(pts) && pts.timescale > 0;
    if (!_summaryOnly)
        SPProbeRecordCaptureGateReceipt(_captureGateReceiptRing, _captureGateReceiptTotal, _captureGateInvalidTotal,
            _gateAdmitted, host, pts, validPTS, streamGeneration);
    _captureReceiptTotalSnapshot.store(_captureGateReceiptTotal, std::memory_order_release);
    _captureInputVersion.fetch_add(1, std::memory_order_acq_rel);
    _associationLastInputCaptureHost = host; _associationLastInputPTSValid = validPTS;
    if (validPTS) { _associationLastInputPTSNum = pts.value; _associationLastInputPTSDen = pts.timescale; _associationLastInputPTSEpoch = pts.epoch; }
    _captureInputVersion.fetch_add(1, std::memory_order_release);
}
- (void)monitorResizeScenario {
    NSAssert(NSThread.isMainThread, @"Resize commands belong to main");
    if (_phase != 0 || _resizeEvidencePending) return;
    const double elapsed = SPProbeNow() - _phaseStart;
    const NSUInteger count = _resizeTransitions.count;
    const double due = count == 0 ? 5.0 : 12.0;
    const BOOL issueCommand = count < 2 && elapsed >= due;
    BOOL needsAfter = NO;
    for (NSDictionary *transition in _resizeTransitions) if (!transition[@"afterProcessor"]) needsAfter = YES;
    if (!issueCommand && !needsAfter) return;
    _resizeEvidencePending = YES;
    ++_snapshotPending;
    const uint64_t requested = mach_absolute_time();
    dispatch_group_t ready = dispatch_group_create();
    __block NSDictionary *capture, *stats;
    __block uint64_t captureBegin, captureEnd;
    dispatch_group_enter(ready);
    dispatch_async(_captureQueue, ^{
        captureBegin = mach_absolute_time();
        capture = [self->_bridge snapshotAtHostNs:SPProbeNs(captureBegin) generation:1][@"normalCapture"] ?: @{};
        captureEnd = mach_absolute_time();
        dispatch_group_leave(ready);
    });
    dispatch_group_enter(ready);
    [_processor requestStatsSnapshotOnQueue:_snapshotQueue completion:^(NSDictionary *observed) {
        stats = observed; dispatch_group_leave(ready);
    }];
    dispatch_group_notify(ready, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSCAssert(!NSThread.isMainThread, @"Resize evidence getters use a worker");
        const uint64_t keeperBegin = mach_absolute_time();
        NSDictionary *keeper = [self->_processor residentKeepAliveSnapshotAtCutoffHostTicks:keeperBegin includeRecords:NO] ?: @{};
        const uint64_t keeperEnd = mach_absolute_time();
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_resizeEvidencePending = NO;
            NSDictionary *sampling = @{ @"requestHostTicks":@(requested), @"captureBeginHostTicks":@(captureBegin),
                @"captureEndHostTicks":@(captureEnd), @"statsSampling":stats[@"statsSampling"] ?: (id)NSNull.null,
                @"keeperBeginHostTicks":@(keeperBegin), @"keeperEndHostTicks":@(keeperEnd),
                @"mainObservedHostTicks":@(mach_absolute_time()) };
            if (!self->_stopping.load() && self->_phase == 0) {
                if (issueCommand && self->_resizeTransitions.count == count) {
                    const int width = count == 0 ? 800 : 1100, height = count == 0 ? 800 : 700;
                    NSMutableDictionary *transition = [@{ @"index":@(count), @"requestedAtPhaseSeconds":@(due),
                        @"commandHostTicks":@(mach_absolute_time()), @"requestedContentPoints":@[@(width), @(height)],
                        @"expectedPixels":SPBetaExpectedPixels(width * 2, height * 2), @"beforeProcessor":stats ?: @{},
                        @"beforeCapture":capture ?: @{}, @"beforeKeeper":keeper, @"beforeEvidenceSampling":sampling } mutableCopy];
                    [self->_resizeTransitions addObject:transition];
                    self->_resizeExpectedWidth.store(width * 2); self->_resizeExpectedHeight.store(height * 2);
                    self->_resizeExpectedIndex.store((int)count); self->_resizeBufferRecorded.store(false);
                    [self->_sourceWindow setContentSize:NSMakeSize(width, height)];
                    transition[@"observedContentBackingPixels"] = SPProbeRect([self->_sourceWindow.contentView convertRectToBacking:self->_sourceWindow.contentView.bounds]);
                } else {
                    for (NSMutableDictionary *transition in self->_resizeTransitions) {
                        if (transition[@"afterProcessor"]) continue;
                        NSDictionary *beta = stats[@"airBeta"] ?: @{};
                        const uint64_t wantedConfirm = [transition[@"index"] unsignedLongLongValue] + 1;
                        if ([beta[@"processingPixels"] isEqual:transition[@"expectedPixels"][@"rifeProcess"]] &&
                            [beta[@"keeper"] isEqual:@"active"] && [capture[@"resize"][@"confirmed"] unsignedLongLongValue] >= wantedConfirm) {
                            transition[@"afterHostTicks"] = @(mach_absolute_time()); transition[@"afterProcessor"] = stats;
                            transition[@"afterCapture"] = capture; transition[@"afterKeeper"] = keeper;
                            transition[@"afterEvidenceSampling"] = sampling;
                        }
                    }
                }
            }
            --self->_snapshotPending;
            if (!self->_snapshotPending && self->_snapshotFinalizeDeferred) {
                self->_snapshotFinalizeDeferred = NO;
                [self finalizeKeeperDocument:self->_snapshotFinalizeComplete];
            }
        });
    });
}
- (void)finalize:(BOOL)complete {
    if (_didFinalize) return; _didFinalize = YES;
    __block NSDictionary *captureFormat;
    __block NSDictionary *captureReceipts;
    NSDictionary *formal = _phases.firstObject ?: @{};
    const uint64_t formalStart = [formal[@"measurementStartHostTicks"] unsignedLongLongValue];
    const uint64_t formalEnd = [formal[@"measurementEndHostTicks"] unsignedLongLongValue];
    dispatch_async(_captureQueue, ^{
        captureFormat = [self captureFormatSnapshot];
        captureReceipts = SPProbeExportCaptureGateReceipts(self->_captureGateReceiptRing, self->_captureGateReceiptTotal,
            self->_captureGateInvalidTotal, self->_gateAdmitted, self->_captureReceiptSourceGeneration,
            mach_absolute_time(), formalStart, formalEnd);
        const uint64_t retained = MIN(self->_captureGateReceiptTotal, (uint64_t)self->_captureGateReceiptRing.size());
        self->_captureGateFrozen.reserve((size_t)retained);
        for (uint64_t index = self->_captureGateReceiptTotal - retained; index < self->_captureGateReceiptTotal; ++index)
            self->_captureGateFrozen.push_back(self->_captureGateReceiptRing[index % self->_captureGateReceiptRing.size()]);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finalizeAfterCapture:complete format:captureFormat receipts:captureReceipts];
        });
    });
}
- (void)finalizeAfterCapture:(BOOL)complete format:(NSDictionary *)captureFormat receipts:(NSDictionary *)captureReceipts {
    _report[@"captureGateReceipts"] = captureReceipts;
    _report[@"captureFormatObservation"] = captureFormat;
    if (_bareView) {
        [_timeline addObject:[self snapshot]];
        NSDictionary *bare = [_bareView snapshotIncludingFrames:YES]; _report[@"bareMetal"] = bare;
        if (bare[@"firstFailure"] != NSNull.null && !_report[@"firstFailure"])
            _report[@"firstFailure"] = @{ @"reason": @"bare Metal rendering failure", @"details": bare[@"firstFailure"] };
    }
    if (_processor) {
        if (_sourceWindow && _outputWindow) [_timeline addObject:[self snapshot]];
        _finalStatsSnapshot = (NSMutableDictionary *)_timeline.lastObject;
        _report[@"finalProcessorStats"] = _finalStatsSnapshot[@"processor"] ?: [self processorStatsCheckpoint];
        // The final trace checkpoint is captured after the existing stop/keeper wait below.
        if ([_arm isEqual:@"apple"]) {
            NSDictionary *stats = _report[@"finalProcessorStats"];
            _report[@"appleActualPlanIdentity"] = @{ @"committed": @(_planCommitted), @"plan": _report[@"plan"] ?: @{},
                @"processorEngineID": stats[@"engineID"] ?: (id)NSNull.null, @"processorModelID": stats[@"modelID"] ?: (id)NSNull.null,
                @"processorQualityID": stats[@"qualityID"] ?: (id)NSNull.null, @"sessionsActual": stats[@"r8SessionsActual"] ?: (id)NSNull.null,
                @"sourceWidth": stats[@"sourceWidth"] ?: (id)NSNull.null, @"sourceHeight": stats[@"sourceHeight"] ?: (id)NSNull.null,
                @"sourcePixelFormat": stats[@"sourcePixelFormat"] ?: (id)NSNull.null };
        }
        [_processor stop];
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        const int64_t remaining = 100000000LL - SPProbeNs(mach_absolute_time() - self->_keeperStopRequestTicks);
        if (remaining > 0) usleep((useconds_t)((remaining + 999) / 1000));
        const uint64_t cutoff = mach_absolute_time();
        dispatch_group_t postStopReady = dispatch_group_create();
        __block NSDictionary *postStopCapture, *postStopProcessor;
        __block uint64_t postStopBegin, postStopEnd;
        dispatch_group_enter(postStopReady);
        dispatch_async(self->_captureQueue, ^{
            postStopBegin = mach_absolute_time();
            postStopCapture = [self->_bridge snapshotAtHostNs:SPProbeNs(postStopBegin) generation:1][@"normalCapture"] ?: @{};
            postStopEnd = mach_absolute_time();
            dispatch_group_leave(postStopReady);
        });
        if (self->_processor) {
            dispatch_group_enter(postStopReady);
            [self->_processor requestStatsSnapshotOnQueue:dispatch_get_global_queue(QOS_CLASS_UTILITY, 0) completion:^(NSDictionary *observed) {
                postStopProcessor = observed; dispatch_group_leave(postStopReady);
            }];
        }
        dispatch_group_notify(postStopReady, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        const uint64_t finalCaptureBegin = mach_absolute_time();
        [self recordExportProgress:@"final-checkpoint-begin" fields:@{ @"scope":@"post-stop after the existing keeper wait" }];
        __block id finalSnapshot;
        if (!self->_summaryOnly) dispatch_sync(dispatch_get_main_queue(), ^{
            finalSnapshot = [self->_processor captureAndSealAirTraceSnapshotAtCutoffHostTicks:0];
        });
        self->_finalAirTraceSnapshot = finalSnapshot;
        NSDictionary *finalTraceMetadata = [self->_processor airTraceSnapshotMetadata:self->_finalAirTraceSnapshot] ?: @{};
        const uint64_t finalCaptureEnd = mach_absolute_time();
        [self recordExportProgress:@"final-checkpoint-end" fields:@{ @"captureBeginHostTicks":@(finalCaptureBegin), @"captureEndHostTicks":@(finalCaptureEnd) }];
        [self recordExportProgress:@"keeper-aggregate-export-begin" fields:nil];
        NSDictionary *keeper = [self->_processor residentKeepAliveSnapshotAtCutoffHostTicks:cutoff includeRecords:!self->_summaryOnly] ?: @{};
        [self recordExportProgress:@"keeper-aggregate-export-end" fields:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_report[@"presentationOrder"] = finalTraceMetadata;
            self->_report[@"finalPresentationCheckpoint"] = @{ @"captureBeginHostTicks":@(finalCaptureBegin), @"captureEndHostTicks":@(finalCaptureEnd),
                @"scope":@"Actual post-stop checkpoint at the existing keeper-wait location. Formal and association retain their independently captured earlier values. Unfinished work remains unknown." };
            const double writeSeconds = (double)SPProbeNs(finalCaptureEnd - self->_traceWriteStartHostTicks) / 1e9;
            self->_report[@"writePeriod"] = @{ @"limitSeconds":@720, @"startHostTicks":@(self->_traceWriteStartHostTicks),
                @"finalCaptureEndHostTicks":@(finalCaptureEnd), @"actualSeconds":@(writeSeconds), @"exceeded":@(writeSeconds > 720),
                @"scope":@"Ends at the actual post-stop capture-and-seal checkpoint; later serialization is export time." };
            if (writeSeconds > 720 && !self->_report[@"toolFirstFailure"]) self->_report[@"toolFirstFailure"] =
                @{ @"reason":@"trace write period exceeded720 seconds", @"hostTicks":@(finalCaptureEnd) };
            self->_report[@"residentKeepAlive"] = keeper;
            self->_report[@"keeperExportHostTicks"] = @(cutoff);
            self->_report[@"keeperDrainScope"] = @"Keeper-only export after SCK stop and original processor export/stop. Acceptance uses each helper's actual request-to-drain duration and pending count, not this later polling time.";
            self->_report[@"normalCapturePostStop"] = @{ @"getterBeginHostTicks":@(postStopBegin),
                @"getterEndHostTicks":@(postStopEnd), @"captureDiagnostics":postStopCapture ?: @{},
                @"processorStats":postStopProcessor ?: @{}, @"processorStatsStale":@([postStopProcessor[@"snapshotStale"] boolValue]),
                @"processorStatsSampling":postStopProcessor[@"statsSampling"] ?: (id)NSNull.null,
                @"scope":@"Actual capture-queue and processor-queue observations after SCK stop and keeper wait, before final sealing and view cleanup. Source and processor sample brackets are separate. Pool retention and process leaks require separate evidence." };
            [self finalizeKeeperDocument:complete];
        });
        });
    });
}
- (NSDictionary *)snapshotTraceMetadata {
    const uint64_t retainedSnapshots = MIN(_snapshotTimingTotal, (uint64_t)_snapshotTimingRows.size());
    return @{ @"schema":@"odf-air-snapshot-trace-v1", @"enabled":@YES,
        @"capacity":@(_snapshotTimingRows.size()), @"total":@(_snapshotTimingTotal),
        @"exportedCount":@(retainedSnapshots), @"dropped":@(_snapshotTimingTotal - retainedSnapshots),
        @"firstseq":retainedSnapshots ? @(_snapshotTimingTotal - retainedSnapshots + 1) : (id)NSNull.null,
        @"lastseq":retainedSnapshots ? @(_snapshotTimingTotal) : (id)NSNull.null,
        @"sealed":@YES, @"sealHostTicks":@(mach_absolute_time()),
        @"mainThreadID":@(_mainThreadID), @"mainThreadSampleHostTicks":@(_mainThreadSampleHostTicks),
        @"scope":@"Utility request-to-assembly intervals; begin/end thread IDs are actual observations on the same serial utility queue. Logical snapshotHostTicks are actual original main checkpoints. Producer capture/stats sample brackets remain separate. No duration threshold." };
}
- (void)finalizeKeeperDocument:(BOOL)complete {
    if (_snapshotPending || _sourceBoundaryPending) { _snapshotFinalizeDeferred = YES; _snapshotFinalizeComplete = complete; return; }
    if (_phases.count) _report[@"formalPhase"] = [_phases.firstObject copy];
    const uint64_t retainedSnapshots = MIN(_snapshotTimingTotal, (uint64_t)_snapshotTimingRows.size());
    _report[@"snapshotTrace"] = [self snapshotTraceMetadata];
    if (_processor) {
        _processor.preview = nil; _processor.outputPreview = nil;
        _outputView.presented = nil; _outputView.surfaceReady = nil; _outputView.presentationFailure = nil;
        _hiddenPreview.presented = nil; _hiddenPreview.presentationFailure = nil;
    }
    [_sourceWindow close]; [_outputWindow close];
    if (_summaryOnly) { [self writeReleaseSummary:complete]; return; }
    const uint64_t sourceRetained = MIN(_sourceUpdateTotal, (uint64_t)_sourceUpdates.size());
    _report[@"sourceUpdateTrace"] = @{ @"enabled": @(![_arm isEqual:@"bare"]), @"configuredContentFPS": @(_sourceFPS),
        @"sourceStartHostTicks": _sourceStartHostTicks ? @(_sourceStartHostTicks) : (id)NSNull.null,
        @"capacity": @(_sourceUpdates.size()), @"total": @(_sourceUpdateTotal), @"dropped": @(_sourceUpdateTotal - sourceRetained),
        @"firstseq": sourceRetained ? @(_sourceUpdateTotal - sourceRetained + 1) : (id)NSNull.null,
        @"lastseq": sourceRetained ? @(_sourceUpdateTotal) : (id)NSNull.null, @"exportedCount": @(sourceRetained),
        @"scope": @"Main-thread POD records for initial content 0 and each actual content-ID advance, exported after timer stop. HostTicks use machTimebase. Timer/content slots use configured FPS; the counter, binary bars and motion advance only on new slots. Late timer slots are skipped, not filled with repeated frames. Direct draw proves drawRect ran for that content during display(), not WindowServer presentation or a decoded SCK content ID; timestamp association alone does not prove capture/source one-to-one identity." };
    NSDictionary *formalStats = _report[@"formalEndProcessorStats"] ?: _report[@"finalProcessorStats"] ?: @{};
    NSDictionary *prescale = formalStats[@"rifeStreamDiagnostics"][@"airRifePrescale"] ?: @{};
    NSDictionary *fused = formalStats[@"rifeStreamDiagnostics"][@"airFusedRifePresent"] ?: @{};
    NSDictionary *presenter = formalStats[@"airFusedRifePresenter"] ?: @{};
    _report[@"airFusedRifePresent"] = fused;
    _report[@"airFusedRifePresenter"] = presenter;
    _report[@"syntheticBufferPixels"] = prescale[@"actualSyntheticPixels"] ?: (id)NSNull.null;
    _report[@"presenterOutputPixels"] = presenter[@"actualDrawablePixels"] ?: (id)NSNull.null;
    _report[@"syntheticPresentedRect"] = presenter[@"syntheticPresentedRect"] ?: (id)NSNull.null;
    _report[@"originalPresentedRect"] = presenter[@"originalPresentedRect"] ?: (id)NSNull.null;
    _report[@"airRifePrescale"] = prescale;
    _report[@"captureActualPixels"] = _report[@"formalCaptureActualPixels"] ?: (_bufferWidth > 0 ? @[@(_bufferWidth.load()), @(_bufferHeight.load())] : (id)NSNull.null);
    _report[@"rifeProcessPixels"] = prescale[@"actualProcessPixels"] ?: (id)NSNull.null;
    _report[@"synthOutputPixels"] = prescale[@"actualSyntheticPixels"] ?: (id)NSNull.null;
    _report[@"originalOutputPixels"] = prescale[@"actualOriginalPixels"] ?: (id)NSNull.null;
    if (_releaseValidation) {
        _report[@"releaseAutomaticPolicy"] = formalStats[@"airWindowOptimization"] ?: @{};
        _report[@"releaseReadiness"] = formalStats[@"airWindowOptimizationReadiness"] ?: @{};
    }
    NSDictionary *expected = _report[@"stageExpectedPixels"];
    NSArray *formalSourcePixels = _report[@"formalCaptureActualPixels"];
    if (_resizeMode && formalSourcePixels.count == 2)
        expected = SPBetaExpectedPixels([formalSourcePixels[0] intValue], [formalSourcePixels[1] intValue]);
    _report[@"setupExpectedPixelsAtEnd"] = expected;
    const BOOL setupMatches = [prescale[@"compiled"] boolValue] && [prescale[@"enabled"] boolValue] &&
        [fused[@"compiled"] boolValue] && [fused[@"enabled"] boolValue] &&
        [presenter[@"compiled"] boolValue] && [presenter[@"enabled"] boolValue] &&
        [_report[@"captureActualPixels"] isEqual:expected[@"capture"]] &&
        [_report[@"rifeProcessPixels"] isEqual:expected[@"rifeProcess"]] &&
        [_report[@"syntheticBufferPixels"] isEqual:expected[@"syntheticBuffer"]] &&
        [_report[@"presenterOutputPixels"] isEqual:expected[@"presenterOutput"]] &&
        [_report[@"originalOutputPixels"] isEqual:expected[@"originalOutput"]] &&
        [presenter[@"actualOriginalBufferPixels"] isEqual:expected[@"capture"]] &&
        [presenter[@"actualSyntheticBufferPixels"] isEqual:expected[@"syntheticBuffer"]] &&
        [presenter[@"rectsExactlyEqual"] isEqual:@YES] &&
        [_report[@"syntheticPresentedRect"] isEqual:_report[@"originalPresentedRect"]];
    _report[@"setupStatus"] = setupMatches ? @"ready" : @"setup_failed";
    if (!setupMatches && !_report[@"firstFailure"])
        _report[@"firstFailure"] = @{ @"reason": @"fused diagnostic setup mismatch", @"details": prescale };
    _report[@"functionalComplete"] = @(complete && !_report[@"firstFailure"]);
    _report[@"elapsedSeconds"] = @(SPProbeNow() - _startHost);
    NSMutableArray *goals = [NSMutableArray array];
    for (NSDictionary *phase in _phases) {
        NSUInteger qualified = 0, floor29 = 0, floor58 = 0;
        for (NSDictionary *row in _timeline) {
            if ([row[@"phase"] integerValue] != [phase[@"index"] integerValue] || !row[@"countedDrawableFPS"]) continue;
            const double interval = [row[@"intervalSeconds"] doubleValue]; if (interval < .9 || interval > 1.5) continue;
            qualified++; floor29 += [row[@"countedDrawableFPS"] doubleValue] >= 29; floor58 += [row[@"countedDrawableFPS"] doubleValue] >= 58;
        }
        [goals addObject:@{ @"phase": phase[@"index"], @"nominalSeconds": phase[@"requestedSeconds"], @"qualifiedHostWindows": @(qualified), @"windowsAtLeast29CountedDrawableFPS": @(floor29), @"windowsAtLeast58CountedDrawableFPS": @(floor58),
            @"scope": @"Short actual presented-handler observations in this self scene, not stable physical FPS or human quality acceptance; incomplete windows remain in timeline." }];
    }
    _report[@"goalObservations"] = goals;
    _report[@"exactSecondObservations"] = @{ @"status":@"deferred_to_cpu",
        @"scope":@"The acceptance reader computes the existing exact-second mathematics from the complete raw traces. No native full-dictionary reconstruction is performed." };
    NSMutableArray *timeline = [_timeline mutableCopy];
    NSDictionary *associationRow = _report[@"associationTimelineSnapshot"];
    if (_sessionRecorder && associationRow && ![timeline containsObject:associationRow]) [timeline addObject:associationRow];
    [_report removeObjectForKey:@"timeline"];
    NSMutableDictionary *document = [_report mutableCopy];
    NSArray *(^extraWriter)(NSError **) = ^NSArray *(NSError **outError) {
        __block NSError *error = nil;
        NSMutableArray *files = [NSMutableArray array];
        NSString *directory = self->_outputPath.stringByDeletingLastPathComponent;
        if (!error) {
            spAirDiagnostic::NDJSONWriter gate(directory, @"capture-gate", self->_exportProgressPath, &error);
            if (gate.valid()) {
                for (const auto &row : self->_captureGateFrozen) {
                    @autoreleasepool { if (!gate.append(SPProbeCaptureGateRow(row), &error)) break; }
                }
                if (!error) {
                    NSDictionary *descriptor = spAirDiagnostic::finishSingleView(gate, @[@"captureGateReceipts", @"records"], &error);
                    if (descriptor) [files addObject:descriptor];
                }
            }
        }
        if (!error) {
            spAirDiagnostic::NDJSONWriter updates(directory, @"source-updates", self->_exportProgressPath, &error);
            if (updates.valid()) {
                for (uint64_t index = self->_sourceUpdateTotal - sourceRetained; index < self->_sourceUpdateTotal; ++index) {
                    @autoreleasepool { if (!updates.append(SPProbeSourceUpdateRow(self->_sourceUpdates[index % self->_sourceUpdates.size()]), &error)) break; }
                }
                if (!error) {
                    NSDictionary *descriptor = spAirDiagnostic::finishSingleView(updates, @[@"sourceUpdateTrace", @"events"], &error);
                    if (descriptor) [files addObject:descriptor];
                }
            }
        }
        if (!error) {
            spAirDiagnostic::NDJSONWriter calls(directory, @"snapshot-calls", self->_exportProgressPath, &error);
            if (calls.valid()) {
                for (uint64_t index = self->_snapshotTimingTotal - retainedSnapshots; index < self->_snapshotTimingTotal; ++index) {
                    @autoreleasepool { if (!calls.append(SPProbeSnapshotTimingJSON(self->_snapshotTimingRows[index % self->_snapshotTimingRows.size()]), &error)) break; }
                }
                if (!error) {
                    NSDictionary *descriptor = spAirDiagnostic::finishSingleView(calls, @[@"snapshotTrace", @"records"], &error);
                    if (descriptor) [files addObject:descriptor];
                }
            }
        }
        if (outError) *outError = error;
        return files;
    };
    NSDictionary *options = @{@"document":document, @"timeline":timeline,
        @"association":_associationAirTraceSnapshot ?: (id)NSNull.null, @"extraTraceWriter":extraWriter};
    if (_sharedOptionsCompletion) {
        void (^completion)(NSDictionary *) = _sharedOptionsCompletion; _sharedOptionsCompletion = nil;
        completion(options);
        return;
    }
    // Preflight-failure and legacy non-session arms still use the same writer.
    NSMutableDictionary *legacy = [options mutableCopy];
    legacy[@"processor"] = _processor ?: (id)NSNull.null;
    legacy[@"formal"] = _formalAirTraceSnapshot ?: (id)NSNull.null;
    legacy[@"final"] = _finalAirTraceSnapshot ?: (id)NSNull.null;
    legacy[@"directory"] = _outputPath.stringByDeletingLastPathComponent;
    legacy[@"outputPath"] = _outputPath; legacy[@"progressPath"] = _exportProgressPath;
    mach_timebase_info_data_t timebase{}; mach_timebase_info(&timebase);
    legacy[@"deadlineHostTicks"] = @(mach_absolute_time() + (uint64_t)(((__uint128_t)38000000000ULL * timebase.denom) / timebase.numer));
    [SPAirBetaSessionExportBridge writeDocumentWithOptions:legacy completion:^(NSDictionary *receipt) {
        dispatch_async(dispatch_get_main_queue(), ^{
            const int code = [receipt[@"complete"] boolValue] ? ([document[@"functionalComplete"] boolValue] ? 0 : 1) : 3;
            self->_exitCode = code; self->_finished = YES; [NSApp stop:nil]; exit(code);
        });
    }];
}

- (void)writeReleaseSummary:(BOOL)complete {
    _report[@"schema"] = @"odf-release-validation-summary-v1";
    _report[@"functionalComplete"] = @(complete && !_report[@"firstFailure"] &&
        (!_releaseQualitySwitch || _releaseSwitchIndex == 2));
    _report[@"elapsedSeconds"] = @(SPProbeNow() - _startHost);
    NSDictionary *formalStats = _report[@"formalEndProcessorStats"] ?: @{};
    _report[@"releaseAutomaticPolicy"] = formalStats[@"airWindowOptimization"] ?: @{};
    _report[@"releaseReadiness"] = formalStats[@"airWindowOptimizationReadiness"] ?: @{};
    [_report removeObjectForKey:@"captureGateReceipts"];
    [_report removeObjectForKey:@"snapshotTrace"];
    _report[@"traceCollection"] = @{@"mode":@"summary", @"perFrameDriverRecords":@NO,
        @"sharedSessionRecorderCreated":@NO, @"processorTraceCheckpointCaptured":@NO,
        @"full22Applicable":@NO, @"scope":@"Actual positive callback scalar deltas and one-second asynchronous stats. Per-frame timing distributions require the separate full-trace run."};
    NSDictionary *document = [_report copy];
    dispatch_async(_snapshotQueue, ^{
        NSMutableDictionary *result = [document mutableCopy];
        result[@"releaseExecutableIdentity"] = SPProbeExecutableIdentity();
        const BOOL identityComplete = result[@"releaseExecutableIdentity"][@"executableSHA256"] != nil;
        result[@"summaryExport"] = @{@"complete":@(identityComplete), @"hostTicks":@(mach_absolute_time())};
        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:&error];
        const BOOL written = data && [data writeToFile:self->_outputPath options:NSDataWritingAtomic error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            const int code = !written || !identityComplete ? 3 : ([result[@"functionalComplete"] boolValue] ? 0 : 1);
            if (error) fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
            self->_exitCode = code; self->_finished = YES;
            [NSApp stop:nil]; exit(code);
        });
    });
}

- (void)beginAssociationTail {
    _associationPending = YES;
    [self recordExportProgress:@"formal-checkpoint-begin" fields:nil];
    _formalAirTraceSnapshot = [_processor captureAirTraceSnapshotAtCutoffHostTicks:0];
    NSMutableDictionary *formalOrder = [[_processor airTraceSnapshotMetadata:_formalAirTraceSnapshot] mutableCopy] ?: [NSMutableDictionary dictionary];
    [self recordExportProgress:@"formal-checkpoint-end" fields:nil];
    formalOrder[@"sourceStoppedScope"] = @"Live snapshot after phase0 closes and before recorder preparation. SCK, source, pipeline and keeper continue; no GPU drain.";
    _report[@"formalPresentationOrder"] = formalOrder;
    [_sessionRecorder adoptDiagnosticFormalCheckpoint:@{@"snapshot":_formalAirTraceSnapshot ?: (id)NSNull.null,
        @"metadata":formalOrder, @"beginHostTicks":_phases.firstObject[@"measurementStartHostTicks"] ?: (id)NSNull.null,
        @"endHostTicks":_phases.firstObject[@"measurementEndHostTicks"] ?: (id)NSNull.null,
        @"complete":_phases.firstObject[@"complete"] ?: @NO}];
    _report[@"formalPresentationScope"] = formalOrder[@"sourceStoppedScope"];
    _report[@"formalPresentationExportHostTicks"] = @(mach_absolute_time());
    _phase = 3;
    const uint64_t startTicks = mach_absolute_time();
    _report[@"associationStartHostTicks"] = @(startTicks);
    _report[@"associationRequestedSeconds"] = @0.2;
    _report[@"associationScope"] = @"Association-only receipts after closed phase0. Source, RIFE and keeper continue without reset. These records do not alter any formal numerator or denominator. Quality recording has not started.";
    [_processor markResidentKeepAlivePhase:@"association_receipt_tail"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (self->_stopping.load()) return;
        NSMutableDictionary *tail = (NSMutableDictionary *)[self snapshot];
        tail[@"kind"] = @"association-only";
        self->_report[@"associationTimelineSnapshot"] = tail;
        [self recordExportProgress:@"association-checkpoint-begin" fields:nil];
        self->_associationAirTraceSnapshot = [self->_processor captureAirTraceSnapshotAtCutoffHostTicks:0];
        NSMutableDictionary *order = [[self->_processor airTraceSnapshotMetadata:self->_associationAirTraceSnapshot] mutableCopy] ?: [NSMutableDictionary dictionary];
        [self recordExportProgress:@"association-checkpoint-end" fields:nil];
        order[@"sourceStoppedScope"] = @"Live association-only export after the200ms receipt tail. Formal presentation evidence is frozen separately; no GPU drain or recording.";
        self->_report[@"associationPresentationOrder"] = order;
        const uint64_t endTicks = mach_absolute_time();
        self->_report[@"associationEndHostTicks"] = @(endTicks);
        self->_report[@"associationActualSeconds"] = @((double)SPProbeNs(endTicks - startTicks) / 1e9);
        self->_report[@"associationSourceTraceCutoffSequence"] = @(self->_sourceUpdateTotal);
        self->_report[@"associationSourceTraceCutoffHostTicks"] = @(endTicks);
        self->_associationPending = NO;
        if (self->_qualitySeconds > 0) [self beginQualityPhase]; else [self finish:YES];
    });
}
- (void)beginQualityPhase {
    [_processor setPresentedVideoReadbackEnabled:YES];
    _report[@"qualityReadbackEnabledHostTicks"] = @(mach_absolute_time());

    _qualityStarting = YES;
    [_processor markResidentKeepAlivePhase:@"quality_preparing"];
    NSString *path = [[_outputPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"quality-presented.mov"];
    _report[@"qualityVideoPath"] = path;
    Class recorderType = NSClassFromString(@"SPPresentedVideoRecorder");
    if (!recorderType) {
        _qualityStarting = NO;
        _report[@"qualityStartupError"] = @"presented-video recorder class unavailable";
        [self finish:YES]; return;
    }
    _qualityRecorder = [[recorderType alloc] initWithOutputURL:[NSURL fileURLWithPath:path] width:2648 height:1668];
    [_qualityRecorder startWithCompletion:^(NSError *error) {
        if (self->_qualityFinishing || self->_stopping.load()) return;
        if (error) {
            self->_qualityStarting = NO;
            self->_report[@"qualityStartupError"] = error.localizedDescription ?: @"quality recorder preparation failed";
            [self finish:YES]; return;
        }
        const BOOL armed = [self->_qualityRecorder armRenderedWindowForDurationSeconds:self->_qualitySeconds didStart:^(NSDictionary *start) {
            if (self->_qualityFinishing || self->_stopping.load()) return;
            self->_qualityStarting = NO;
            self->_qualityBeginMediaTime = [start[@"windowStartMediaTime"] doubleValue];
            self->_qualityEndMediaTime = [start[@"windowEndMediaTimeExclusive"] doubleValue];
            self->_report[@"qualityWindow"] = [start copy];
            self->_report[@"qualityStartNotificationHostTicks"] = @(mach_absolute_time());
            [self->_processor markResidentKeepAlivePhase:@"quality_only"];
            [self beginPhase:2];
            NSMutableDictionary *phase = self->_phases.lastObject;
            phase[@"kind"] = @"quality-only"; phase[@"requestedSeconds"] = @(self->_qualitySeconds);
            phase[@"startMediaTime"] = start[@"windowStartMediaTime"];
            phase[@"endMediaTimeExclusive"] = start[@"windowEndMediaTimeExclusive"];
            phase[@"recordingStartHostTicks"] = start[@"anchorObservedHostTicks"];
            phase[@"observerStartHostTicks"] = phase[@"measurementStartHostTicks"];
            phase[@"observerStartMediaTime"] = @(CACurrentMediaTime());
            phase[@"recordingStartHostScope"] = @"Positive anchor callback receipt. Actual presentation uses the separate Media window.";
            phase[@"scope"] = @"Recorder window starts at its first copied positive actual presentedTime. The phase2 observer starts after didStart delivery; phase0 remains the sole performance gate.";
            self->_report[@"qualityPhase"] = phase;
        }];
        if (!armed) {
            self->_qualityStarting = NO;
            self->_report[@"qualityStartupError"] = @"quality recorder did not arm";
            [self finish:YES]; return;
        }
        [self->_processor setPresentedVideoRecorder:self->_qualityRecorder];
    }];
}
- (void)finish:(BOOL)complete {
    [_processor setPresentedVideoRecorder:nil];
    if (_qualityRecorder && !_qualityFinished) {
        if (_qualityFinishing) return;
        _qualityStarting = NO; _qualityFinishing = YES;
        const uint64_t endTicks = mach_absolute_time();
        const CFTimeInterval endMedia = CACurrentMediaTime();
        _report[@"qualityRecordingStopHostTicks"] = @(endTicks);
        _report[@"qualityRecordingStopMediaTime"] = @(endMedia);
        [_qualityRecorder finishAtMediaTime:endMedia hostTicks:endTicks completion:^(NSDictionary *report) {
            self->_report[@"qualityRecording"] = report ?: @{};
            self->_qualityFinished = YES; self->_qualityFinishing = NO;
            [self->_processor setPresentedVideoReadbackEnabled:NO];
            self->_report[@"qualityReadbackDisabledHostTicks"] = @(mach_absolute_time());
            [self finishAfterQuality:complete];
        }];
        return;
    }
    if (_qualitySeconds > 0 && !_qualityFinished) {
        [_processor setPresentedVideoReadbackEnabled:NO];
        _report[@"qualityReadbackDisabledHostTicks"] = @(mach_absolute_time());
    }
    [self finishAfterQuality:complete];
}
- (void)finishAfterQuality:(BOOL)complete {
    if (_stopping.exchange(true)) return;
    [_tickTimer invalidate]; [_monitorTimer invalidate];
    dispatch_async(_captureQueue, ^{
        const uint64_t began = mach_absolute_time();
        NSDictionary *raw = [self->_bridge snapshotAtHostNs:SPProbeNs(began) generation:1][@"normalCapture"] ?: @{};
        NSMutableDictionary *normal = [[self->_bridge normalCaptureReportForSnapshot:raw] mutableCopy] ?: [NSMutableDictionary dictionary];
        normal[@"sourceSampleBeginHostTicks"] = @(began); normal[@"sourceSampleEndHostTicks"] = @(mach_absolute_time());
        normal[@"streamLifecycle"] = [self->_captureLifecycle copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            normal[@"resizeTransitions"] = [self->_resizeTransitions copy]; normal[@"resizePolicyEvents"] = [self->_resizePolicyEvents copy];
            normal[@"resizeGeometryEvidence"] = [normal[@"callbackCounts"][@"geometryAvailable"] unsignedLongLongValue] > 0 ? @"observed" : @"unknown";
            self->_report[@"normalCapture"] = normal;
            [self finishAfterNormalCapture:complete];
        });
    });
}
- (void)prepareSharedDiagnosticOptions:(NSDictionary *)context completion:(void (^)(NSDictionary *))completion {
    if (_didFinalize) return;
    _didFinalize = YES; _sharedOptionsCompletion = [completion copy];
    _finalAirTraceSnapshot = context[@"final"] == NSNull.null ? nil : context[@"final"];
    for (NSString *key in @[@"presentationOrder", @"recordingBegin", @"recordingSeal", @"nativeStop", @"keeperReadiness", @"finalCheckpointReceipt"])
        if (context[key]) _report[key] = context[key];
    NSDictionary *post = context[@"finalTimelineSnapshot"] ?: @{};
    _report[@"finalProcessorStats"] = post[@"processor"] ?: @{};
    _report[@"normalCapturePostStop"] = @{@"captureDiagnostics":post[@"capture"][@"diagnostics"] ?: @{},
        @"getterBeginHostTicks":post[@"capture"][@"detailSampleBeginHostTicks"] ?: (id)NSNull.null,
        @"getterEndHostTicks":post[@"capture"][@"detailSampleEndHostTicks"] ?: (id)NSNull.null,
        @"processorStats":post[@"processor"] ?: @{},
        @"processorStatsSampling":post[@"processor"][@"statsSampling"] ?: (id)NSNull.null,
        @"scope":@"Actual shared-recorder post-stop capture/processor observations after real native work closure and before export."};
    _report[@"normalCaptureStop"] = @{@"SCKCompletionObserved":context[@"sourceStopAndFence"][@"completionObserved"] ?: (id)NSNull.null,
        @"captureQueueDrained":context[@"sourceStopAndFence"][@"captureQueueDrained"] ?: (id)NSNull.null,
        @"receipt":context[@"sourceStopAndFence"] ?: (id)NSNull.null};
    const uint64_t formalStart = [_phases.firstObject[@"measurementStartHostTicks"] unsignedLongLongValue];
    const uint64_t formalEnd = [_phases.firstObject[@"measurementEndHostTicks"] unsignedLongLongValue];
    dispatch_async(_captureQueue, ^{
        NSDictionary *format = [self captureFormatSnapshot];
        NSDictionary *receipts = SPProbeExportCaptureGateReceipts(self->_captureGateReceiptRing, self->_captureGateReceiptTotal,
            self->_captureGateInvalidTotal, self->_gateAdmitted, self->_captureReceiptSourceGeneration,
            mach_absolute_time(), formalStart, formalEnd);
        const uint64_t retained = MIN(self->_captureGateReceiptTotal, (uint64_t)self->_captureGateReceiptRing.size());
        self->_captureGateFrozen.reserve((size_t)retained);
        for (uint64_t index = self->_captureGateReceiptTotal - retained; index < self->_captureGateReceiptTotal; ++index)
            self->_captureGateFrozen.push_back(self->_captureGateReceiptRing[index % self->_captureGateReceiptRing.size()]);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            const uint64_t sampled = mach_absolute_time();
            NSDictionary *keeper = [self->_processor residentKeepAliveSnapshotAtCutoffHostTicks:sampled includeRecords:YES];
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_report[@"captureGateReceipts"] = receipts; self->_report[@"captureFormatObservation"] = format;
                self->_report[@"residentKeepAlive"] = keeper ?: @{}; self->_report[@"keeperExportHostTicks"] = @(sampled);
                self->_report[@"finalPresentationCheckpoint"] = context[@"finalCheckpointReceipt"] ?: @{};
                self->_report[@"sharedSessionExportPath"] = @YES;
                [self finalizeKeeperDocument:self->_sharedFunctionalComplete];
            });
        });
    });
}
- (void)finishAfterNormalCapture:(BOOL)complete {
    if (_sessionRecorder) {
        _sharedFunctionalComplete = complete;
        for (NSArray *entry in _notifications) [entry[0] removeObserver:entry[1]];
        [_notifications removeAllObjects];
        [_sessionRecorder finishForReason:@"self-window-phase-ended" completion:^(NSDictionary *receipt) {
            const int resultCode = ![receipt[@"complete"] boolValue] ? 3 : (self->_sharedFunctionalComplete ? 0 : 1);
            fprintf(stdout, "%s\n", [receipt[@"documentPath"] UTF8String] ?: self->_outputPath.UTF8String);
            const uint64_t flushBegin = mach_absolute_time();
            const int flushed = fflush(stdout);
            NSDictionary *flush = @{@"channel":@"diagnostic-stdout", @"complete":@(flushed == 0),
                @"beginHostTicks":@(flushBegin), @"endHostTicks":@(mach_absolute_time()), @"exitCode":@(resultCode)};
            [self->_sessionRecorder recordFinalLiveLogReceipt:flush completion:^{
                self->_exitCode = resultCode; self->_finished = YES;
                [NSApp stop:nil]; exit(resultCode);
            }];
        }];
        return;
    }
    _keeperStopRequestTicks = mach_absolute_time();
    _report[@"keeperStopMarkerHostTicks"] = @(_keeperStopRequestTicks);
    NSMutableDictionary *frequencyWindows = _report[@"keeperFrequencyWindows"];
    frequencyWindows[@"formalEndHostTicks"] = _phases.firstObject[@"measurementEndHostTicks"] ?: (id)NSNull.null;
    frequencyWindows[@"stopSourceContentID"] = @(_pattern.frameNumber);
    frequencyWindows[@"stopSourceUpdateSequence"] = @(_sourceUpdateTotal);
    [_processor markResidentKeepAlivePhase:@"stop_requested"];
    [_processor requestStopResidentKeepAliveForDiagnostics:@"self-window-phase-ended"];
    [_bareView stop];
    for (NSArray *entry in _notifications) [entry[0] removeObserver:entry[1]];
    [_notifications removeAllObjects];
    if (_bareView) {
        // Give already-submitted completion/presentation callbacks a short,
        // bounded drain. Any still-pending records remain explicit in JSON.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self finalize:complete]; });
        return;
    }
    if (_streamStartPending) {
        // A stop during asynchronous startup must not leave a later-started
        // stream running after the diagnostic windows have been closed.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (!self->_didFinalize && self->_streamStartPending) {
                if (!self->_report[@"firstFailure"]) self->_report[@"firstFailure"] = @{ @"reason": @"own-window SCK startup cancellation timeout" };
                [self finalize:NO];
            }
        });
        return;
    }
    [self stopStreamAndFinalize:complete];
}
- (void)stopStreamAndFinalize:(BOOL)complete {
    if (_didFinalize) return;
    if (_streamStarted) {
        [_bridge stopCaptureWithCompletion:^(NSString *message) { dispatch_async(dispatch_get_main_queue(), ^{
            self->_report[@"normalCaptureStop"] = @{ @"SCKCompletionObserved":@YES, @"captureQueueDrained":@YES,
                @"hostTicks":@(mach_absolute_time()), @"error":message ?: (id)NSNull.null };
            if (message && !self->_report[@"firstFailure"]) self->_report[@"firstFailure"] = @{ @"reason":@"normal capture stop failed", @"details":message };
            [self finalize:complete && message == nil];
        }); }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (!self->_didFinalize) { if (!self->_report[@"firstFailure"]) self->_report[@"firstFailure"] = @{ @"reason":@"normal capture stop completion timeout" }; [self finalize:NO]; }
        });
    } else [self finalize:complete];
}
@end


@interface SPAirBetaEntryDriver : NSObject
- (instancetype)runWithOptions:(NSDictionary *)options;
@end
@implementation SPAirBetaEntryDriver {
    SPSelfWindowCaptureProbe *_probe;
}
- (instancetype)runWithOptions:(NSDictionary *)options {
    _probe = [[SPSelfWindowCaptureProbe alloc] initWithOptions:options];
    [_probe start];
    return self;
}
@end

// The ordinary recorder and the embedded fixture call this identical bounded
// writer. Options contain CPU values, opaque trace checkpoints and providers.
@interface NSObject (SPAirBetaSessionJournalExportAPI)
- (BOOL)enumerateInstancesIncludingRecords:(BOOL)includeRecords usingBlock:(BOOL (^)(uint64_t, NSDictionary *))block;
- (BOOL)enumerateEventsUsingBlock:(BOOL (^)(uint64_t, NSDictionary *))block;
@end

@implementation SPAirBetaSessionExportBridge
+ (SPAirDiagnosticWriteBudget *)writeDocumentWithOptions:(NSDictionary<NSString *, id> *)options
    completion:(void (^)(NSDictionary<NSString *, id> *))completion {
    const uint64_t requested = mach_absolute_time();
    SPAirDiagnosticWriteBudget *budget = [[SPAirDiagnosticWriteBudget alloc]
        initWithDeadlineHostTicks:[options[@"deadlineHostTicks"] unsignedLongLongValue]];
    NSDictionary *frozen = [options copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            spAirDiagnostic::ScopedWriteBudget guard([budget nativeWriteBudget]);
            __block NSError *error = nil;
            const uint64_t began = mach_absolute_time();
            NSString *directory = frozen[@"directory"], *path = frozen[@"outputPath"], *progress = frozen[@"progressPath"];
            SPLiveProcessor *processor = frozen[@"processor"];
            NSMutableDictionary *document = [frozen[@"document"] mutableCopy] ?: [NSMutableDictionary dictionary];
            NSMutableArray *files = [NSMutableArray array];
            if (![directory isKindOfClass:NSString.class] || ![path isKindOfClass:NSString.class] ||
                ![progress isKindOfClass:NSString.class] || ![processor isKindOfClass:SPLiveProcessor.class]) {
                error = [NSError errorWithDomain:@"OpenDuckFrame.SessionExport" code:1
                    userInfo:@{NSLocalizedDescriptionKey:@"Shared session export options are incomplete"}];
            }
            if (!error) [[NSFileManager defaultManager] createDirectoryAtPath:directory
                withIntermediateDirectories:YES attributes:nil error:&error];
            if (!error) spAirDiagnostic::appendProgress(progress, @"shared-session-export-begin",
                @{@"requestHostTicks":@(requested), @"deadlineHostTicks":frozen[@"deadlineHostTicks"]}, &error);
            id (^optional)(NSString *) = ^id(NSString *key) {
                id value = frozen[key]; return value == NSNull.null ? nil : value;
            };
            NSDictionary *presentation = nil;
            if (!error) presentation = [processor writeAirTraceSnapshotsToDirectory:directory formal:optional(@"formal")
                association:optional(@"association") final:optional(@"final") progressPath:progress error:&error];
            if (!error && !presentation) error = [NSError errorWithDomain:@"OpenDuckFrame.SessionExport" code:2
                userInfo:@{NSLocalizedDescriptionKey:@"Processor trace export returned no manifest"}];
            NSDictionary *services = nil;
            if (!error && frozen[@"retiredServiceTraces"]) {
                services = [processor writeRetiredAirServiceTraces:frozen[@"retiredServiceTraces"] formal:optional(@"formal")
                    association:optional(@"association") toDirectory:directory progressPath:progress error:&error];
                if (!error && !services) error = [NSError errorWithDomain:@"OpenDuckFrame.SessionExport" code:3
                    userInfo:@{NSLocalizedDescriptionKey:@"Detached service trace export returned no manifest"}];
            }
            NSDictionary *prefixes = @{@"formal":@"formalPresentationOrder", @"association":@"associationPresentationOrder", @"final":@"presentationOrder"};
            NSMutableArray *backendFiles = [NSMutableArray arrayWithArray:presentation[@"files"] ?: @[]];
            [backendFiles addObjectsFromArray:services[@"files"] ?: @[]];
            for (NSString *label in services[@"views"] ?: @{}) {
                NSString *key = prefixes[label];
                NSMutableDictionary *view = [document[key] mutableCopy] ?: [NSMutableDictionary dictionary];
                [view addEntriesFromDictionary:services[@"views"][label]]; document[key] = view;
            }
            if (services) document[@"serviceSessionExport"] = @{ @"complete":services[@"complete"] ?: (id)NSNull.null,
                @"stores":services[@"stores"] ?: (id)NSNull.null, @"scope":@"Per-store real sequences and immutable checkpoint versions." };
            for (NSDictionary *raw in backendFiles) {
                NSMutableDictionary *descriptor = [raw mutableCopy];
                NSMutableArray *views = [NSMutableArray array];
                for (NSDictionary *rawView in raw[@"views"]) {
                    NSMutableDictionary *view = [rawView mutableCopy];
                    NSMutableArray *target = [NSMutableArray arrayWithObject:prefixes[rawView[@"name"]]];
                    [target addObjectsFromArray:rawView[@"target"]]; view[@"target"] = target;
                    [views addObject:view];
                }
                descriptor[@"views"] = views; [files addObject:descriptor];
            }
            NSArray *(^extraWriter)(NSError **) = frozen[@"extraTraceWriter"];
            if (!error && extraWriter) {
                NSArray *extraFiles = extraWriter(&error);
                if (extraFiles) [files addObjectsFromArray:extraFiles];
            }
            if (!error) [files addObjectsFromArray:frozen[@"extraFiles"] ?: @[]];
            NSDictionary *(^timelineProvider)(NSUInteger) = frozen[@"timelineProvider"];
            NSArray *timeline = frozen[@"timeline"];
            const NSUInteger count = timelineProvider ? [frozen[@"timelineCount"] unsignedIntegerValue] : timeline.count;
            if (!error) {
                spAirDiagnostic::NDJSONWriter writer(directory, @"timeline", progress, &error);
                if (writer.valid()) {
                    for (NSUInteger index = 0; index < count; ++index) {
                        @autoreleasepool {
                            NSDictionary *row = timelineProvider ? timelineProvider(index) : timeline[index];
                            if (!writer.append(row, &error)) break;
                        }
                    }
                    if (!error) {
                        NSDictionary *descriptor = spAirDiagnostic::finishSingleView(writer, @[@"timeline"], &error);
                        if (descriptor) [files addObject:descriptor];
                    }
                }
            }
            NSObject *journal = optional(@"keeperJournal");
            if (!error && journal) {
                spAirDiagnostic::NDJSONWriter writer(directory, @"keeper-session-instances", progress, &error);
                if (writer.valid()) {
                    auto *output = &writer;
                    const BOOL enumerated = [journal enumerateInstancesIncludingRecords:YES usingBlock:^BOOL(uint64_t sequence, NSDictionary *row) {
                        return output->append(row, &error);
                    }];
                    if (!enumerated && !error) spAirDiagnostic::setError(&error, @"enumerate keeper instances", EIO);
                    if (!error) {
                        NSDictionary *descriptor = spAirDiagnostic::finishSingleView(writer, @[@"keeperSessionJournal", @"instances"], &error);
                        if (descriptor) [files addObject:descriptor];
                    }
                }
            }
            if (!error && journal) {
                spAirDiagnostic::NDJSONWriter writer(directory, @"keeper-session-events", progress, &error);
                if (writer.valid()) {
                    auto *output = &writer;
                    const BOOL enumerated = [journal enumerateEventsUsingBlock:^BOOL(uint64_t sequence, NSDictionary *row) {
                        return output->append(row, &error);
                    }];
                    if (!enumerated && !error) spAirDiagnostic::setError(&error, @"enumerate keeper events", EIO);
                    if (!error) {
                        NSDictionary *descriptor = spAirDiagnostic::finishSingleView(writer, @[@"keeperSessionJournal", @"events"], &error);
                        if (descriptor) [files addObject:descriptor];
                    }
                }
            }
            if (![document[@"schema"] isEqual:@"odf-air-stream-result-v1"]) {
                document[@"legacySchemaPresent"] = @YES;
                document[@"legacySchema"] = document[@"schema"] ?: (id)NSNull.null;
                document[@"schema"] = @"odf-air-stream-result-v1";
            }
            document[@"traceManifest"] = @{@"schema":@"odf-air-stream-trace-manifest-v1", @"files":files};
            const BOOL observationsComplete = [document[@"exportStatus"][@"observationsComplete"] boolValue]
                && (!frozen[@"retiredServiceTraces"] || [services[@"complete"] boolValue]);
            NSMutableDictionary *status = [document[@"exportStatus"] mutableCopy] ?: [NSMutableDictionary dictionary];
            status[@"state"] = !error && observationsComplete ? @"complete" : @"incomplete";
            status[@"complete"] = @(!error && observationsComplete);
            status[@"endHostTicks"] = @(mach_absolute_time());
            if (error) status[@"error"] = error.localizedDescription;
            document[@"exportStatus"] = status;
            document[@"streamExportComplete"] = @(!error && observationsComplete && !document[@"toolFirstFailure"]);
            if (error && !document[@"toolFirstFailure"]) document[@"toolFirstFailure"] =
                @{@"reason":error.localizedDescription, @"hostTicks":@(mach_absolute_time())};
            BOOL written = NO;
            if (!error) {
                spAirDiagnostic::appendProgress(progress, @"manifest-write-begin", @{@"traceFiles":@(files.count)}, &error);
                if (!error) written = spAirDiagnostic::writeJSONFile(path, document, &error);
                if (written) spAirDiagnostic::appendProgress(progress, @"manifest-write-end",
                    @{@"traceFiles":@(files.count), @"streamExportComplete":document[@"streamExportComplete"]}, &error);
            }
            const BOOL complete = written && !error && [document[@"streamExportComplete"] boolValue];
            NSDictionary *receipt = @{@"complete":@(complete), @"documentPath":path ?: (id)NSNull.null,
                @"manifestFileCount":@(files.count), @"error":error.localizedDescription ?: (id)NSNull.null,
                @"requestHostTicks":@(requested), @"beginHostTicks":@(began), @"endHostTicks":@(mach_absolute_time()),
                @"timedOut":@([budget isExpired]), @"cancelled":@([budget isCancelled]),
                @"writer":@"SPAirBetaSessionExportBridge/validated05-stream-writer"};
            NSError *markerError = nil;
            spAirDiagnostic::appendProgress(progress, complete ? @"shared-session-export-complete" : @"shared-session-export-incomplete",
                receipt, &markerError, nullptr);
            NSMutableDictionary *result = [receipt mutableCopy];
            if (markerError) { result[@"complete"] = @NO; result[@"progressError"] = markerError.localizedDescription; }
            completion(result);
        }
    });
    return budget;
}
@end

#endif
