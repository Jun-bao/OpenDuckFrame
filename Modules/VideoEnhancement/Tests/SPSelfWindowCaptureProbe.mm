// Standalone accessory-app diagnostic: bare Metal, captured passthrough, or
// captured RIFE or Apple FRC. Capture uses only the exact own window; never requests TCC/AX.
#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <CoreFoundation/CoreFoundation.h>
#import <mach/mach_time.h>
#import <unistd.h>
#include <atomic>
#include <cmath>
#include <memory>
#include <array>
#include <algorithm>
#include <vector>
#include <type_traits>
#import "SPLiveProcessor.h"
#import "SPFRCEngine.h"

@interface NSObject (SPSelfWindowCaptureBridgeAPI)
- (BOOL)acceptsBuffer:(CVPixelBufferRef)buffer generation:(uint64_t)generation hostNs:(int64_t)hostNs;
- (SPOwnedPixelBuffer *)copyBuffer:(CVPixelBufferRef)buffer;
- (BOOL)lastFailurePoolExhausted;
- (NSDictionary *)snapshotAtHostNs:(int64_t)hostNs generation:(uint64_t)generation;
@end

static int64_t SPProbeNs(uint64_t host) {
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&timebase); });
    return (int64_t)(((__uint128_t)host * timebase.numer) / timebase.denom);
}
static double SPProbeNow(void) { return (double)SPProbeNs(mach_absolute_time()) / 1e9; }
static BOOL SPProbeInterpolates(NSString *arm) { return [arm isEqual:@"rife"] || [arm isEqual:@"apple"]; }
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

@interface SPSelfWindowCaptureProbe : NSObject <SCStreamOutput, SCStreamDelegate> {
    dispatch_queue_t _captureQueue;
    std::atomic_bool _stopping;
    NSLock *_drawableLock;
    NSMutableArray<NSDictionary *> *_drawableEvents;
    uint64_t _drawableValid, _drawableSource, _drawableSynthetic, _drawableUnscored, _gpuCompletions;
    double _firstDrawableHost;
    uint64_t _callbacks, _complete, _idle, _invalid, _gateAdmitted, _gateDuplicates, _copied, _copyFailed;
    std::atomic<uint64_t> _formatBuffers, _formatRequestedMatches, _formatUnexpected, _formatChanges;
    std::atomic<uint32_t> _formatFirst, _formatLast;
    NSDictionary *_firstCaptureMetadata;
    NSString *_requestedCaptureFormat;
    OSType _requestedCapturePixelFormat;
    int _bufferWidth, _bufferHeight;
    double _firstCallbackHost, _lastCallbackHost, _maxCallbackGap;
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
    std::array<SPProbeSourceUpdate, 8192> _sourceUpdates;
    double _startHost, _sourceStart, _phaseStart, _lastSnapshotHost, _lastIdle;
    NSInteger _phase;
    BOOL _streamStarted, _streamStartPending, _planCommitted, _didFinalize, _controlOnly;
    double _planCommitHost;
}
@property (nonatomic, readonly) BOOL finished;
@property (nonatomic, readonly) int exitCode;
- (instancetype)initWithOptions:(NSDictionary *)options;
- (void)start;
- (void)finish:(BOOL)complete;
- (void)stopStreamAndFinalize:(BOOL)complete;
- (void)recordSourceUpdateStarted:(uint64_t)started drawCallsBefore:(uint64_t)drawCalls initial:(BOOL)initial;
- (NSDictionary *)captureFormatSnapshotOnCaptureQueue;
@end

@implementation SPSelfWindowCaptureProbe
- (instancetype)initWithOptions:(NSDictionary *)options {
    if (!(self = [super init])) return nil;
    _outputPath = options[@"output"]; _dylibPath = options[@"dylib"]; _arm = options[@"arm"]; _controlOnly = [options[@"control-only"] boolValue];
    _widthPoints = [options[@"source-width-points"] doubleValue]; _heightPoints = [options[@"source-height-points"] doubleValue];
    _seconds = [options[@"seconds"] doubleValue]; _minimumIdle = [options[@"minimum-idle-seconds"] doubleValue];
    _sourceFPS = [options[@"source-fps"] unsignedIntegerValue];
    _requestedCaptureFormat = [options[@"capture-format"] copy];
    _requestedCapturePixelFormat = [_requestedCaptureFormat isEqual:@"bgra"] ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    _formatBuffers.store(0); _formatRequestedMatches.store(0); _formatUnexpected.store(0); _formatChanges.store(0);
    _formatFirst.store(0); _formatLast.store(0);
    _phase = -1; _stopping.store(false); _startHost = SPProbeNow();
    _captureQueue = dispatch_queue_create("app.openduckframe.self-window-probe.capture", DISPATCH_QUEUE_SERIAL);
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
- (NSDictionary *)snapshot {
    const uint64_t snapshotHostTicks = mach_absolute_time();
    const double now = (double)SPProbeNs(snapshotHostTicks) / 1e9;
    __block NSDictionary *capture;
    dispatch_sync(_captureQueue, ^{
        capture = @{ @"callbacks": @(self->_callbacks), @"complete": @(self->_complete), @"idle": @(self->_idle),
            @"invalid": @(self->_invalid), @"statuses": [self->_captureStatuses copy],
            @"formatObservation": [self captureFormatSnapshotOnCaptureQueue],
            @"gateAdmitted": @(self->_gateAdmitted), @"gateDuplicates": @(self->_gateDuplicates),
            @"copied": @(self->_copied), @"copyFailed": @(self->_copyFailed),
            @"bufferWidth": @(self->_bufferWidth), @"bufferHeight": @(self->_bufferHeight),
            @"firstCallbackHost": @(self->_firstCallbackHost), @"lastCallbackHost": @(self->_lastCallbackHost),
            @"maxCallbackGapSeconds": @(self->_maxCallbackGap), @"callbackGapsMsSinceSnapshot": [self->_callbackGapsMs copy],
            @"helpers": self->_bridge ? [self->_bridge snapshotAtHostNs:SPProbeNs(mach_absolute_time()) generation:1] : @{} };
        [self->_callbackGapsMs removeAllObjects];
    });
    [_drawableLock lock];
    NSDictionary *drawable = @{ @"validPresentedCallbacks": @(_drawableValid), @"countedSource": @(_drawableSource), @"countedPattern": @0,
        @"countedSynthetic": @(_drawableSynthetic), @"unscoredPresented": @(_drawableUnscored),
        @"gpuCompletedCallbacks": @(_gpuCompletions), @"firstValidCallbackHost": @(_firstDrawableHost),
        @"presentedEventsSinceSnapshot": [_drawableEvents copy],
        @"counterScope": @"Probe-owned callback-lifetime counters do not reset with processor epochs; valid requires drawable.presentedTime > 0. GPU completion is separate." };
    [_drawableEvents removeAllObjects]; [_drawableLock unlock];
    if (_bareView) drawable = [_bareView snapshotIncludingFrames:NO];
    NSDictionary *stats = _processor.stats ?: @{};
    NSMutableDictionary *row = [@{ @"hostElapsedSeconds": @(now - _startHost), @"snapshotHostTicks": @(snapshotHostTicks), @"phase": @(_phase),
        @"phaseElapsedSeconds": @(_phase >= 0 ? now - _phaseStart : 0),
        @"intervalSeconds": @(_lastSnapshotHost > 0 ? now - _lastSnapshotHost : 0),
        @"source": @{ @"configuredContentFPS": @(_sourceFPS), @"updatesEnabled": @(_bareView == nil), @"timerTicks": @(_pattern.timerTicks), @"contentUpdates": @(_pattern.contentUpdates),
            @"drawCalls": @(_pattern.drawCalls), @"skippedContentSlots": @(_pattern.skippedSlots), @"frameNumber": @(_pattern.frameNumber) },
        @"capture": capture, @"drawable": drawable, @"processor": stats, @"windows": [self windowSnapshot] } mutableCopy];
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
    _previousSnapshot = row; _lastSnapshotHost = now;
    return row;
}
- (NSDictionary *)captureFormatSnapshotOnCaptureQueue {
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
        @"firstFrame": _firstCaptureMetadata ?: (id)NSNull.null,
        @"scope": @"Whole-run atomic scalar counts of valid/data-ready complete SCK image buffers before gate/copy, including warmup and all phases; idle/invalid/missing-buffer callbacks excluded. Changes compare consecutive observed formats. Capture-queue snapshot, no reset, no pixel sampling or content-ID/source one-to-one claim; color differences are observations, not acceptance gates." };
}
- (void)beginPhase:(NSInteger)phase {
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
}
- (void)monitor {
    if (_stopping.load()) return;
    NSString *bareFailure = [_bareView currentFailure];
    if (bareFailure) { [self fail:@"bare Metal rendering failure" details:bareFailure]; return; }
    if (_bareView && SPProbeNow() - _startHost >= 30) { [self fail:@"bare Metal runtime limit (30 seconds)" details:nil]; return; }
    NSDictionary *preflight = SPProbePreflight(_minimumIdle);
    const double idle = [preflight[@"hidIdleSeconds"] doubleValue];
    if (![preflight[@"allowed"] boolValue] || (_lastIdle > 0 && idle + .25 < _lastIdle)) {
        [self fail:@"session/display/HID precondition changed" details:preflight]; return;
    }
    _lastIdle = idle;
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
            _report[@"startup"] = @{ @"seconds": @(SPProbeNow() - _startHost), @"planCommittedHostElapsedSeconds": _bareView ? (id)NSNull.null : @(_planCommitHost - _startHost), @"firstDrawableIsPresentedHandler": @YES };
            [self beginPhase:0];
        } else if (SPProbeNow() - _startHost > 45) [self fail:@"startup timeout: capture, requested committed plan or drawable not ready" details:_processor.stats ?: @{}];
        return;
    }
    const double now = SPProbeNow();
    if (now - _lastSnapshotHost >= 1 || now - _phaseStart >= _seconds) [_timeline addObject:[self snapshot]];
    if (now - _phaseStart >= _seconds) {
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
    [self recordProgress:@"loading-production-library"];
    auto loadFinished = std::make_shared<std::atomic_bool>(false);
    NSString *loadOutput = [_outputPath copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (loadFinished->load()) return;
        NSDictionary *failure = @{ @"functionalComplete": @NO, @"firstFailure": @{ @"reason": @"production library load exceeded 10 seconds" }, @"captureStarted": @NO, @"windowsCreated": @NO };
        NSData *json = [NSJSONSerialization dataWithJSONObject:failure options:NSJSONWritingPrettyPrinted error:nil];
        [json writeToFile:loadOutput options:NSDataWritingWithoutOverwriting error:nil];
        _exit(1); // No windows or capture exist at this bounded loading stage.
    });
    void *loaded = dlopen(_dylibPath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    loadFinished->store(true);
    if (!loaded) { const char *error = dlerror(); [self fail:@"dlopen" details:error ? @(error) : @"unknown"]; return; }
    [self recordProgress:@"production-library-loaded"];
    processorType = NSClassFromString(@"SPLiveProcessor"); viewType = NSClassFromString(@"SPLivePreviewView"); bridgeType = NSClassFromString(@"SPSelfWindowCaptureBridge"); requestType = NSClassFromString(@"SPLivePlanRequest");
    if (!processorType || !viewType || !bridgeType || !requestType) { [self fail:@"diagnostic classes missing" details:nil]; return; }
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
    _processor = [processorType new]; _bridge = [bridgeType new];
    _processor.preview = _hiddenPreview; _processor.outputPreview = _outputView; [_processor installPresentationHooks];
    void (^productionPresented)(NSDictionary *) = [_outputView.presented copy];
    _outputView.presented = ^(NSDictionary *info) {
        if (productionPresented) productionPresented(info);
        SPSelfWindowCaptureProbe *strong = weakSelf; if (!strong) return;
        [strong->_drawableLock lock];
        if ([info[@"presentedTime"] doubleValue] > 0) {
            strong->_drawableValid++;
            if (strong->_firstDrawableHost == 0) { strong->_firstDrawableHost = SPProbeNow(); [strong recordProgress:@"first-valid-drawable-presented-handler"]; }
            if (![info[@"counts"] boolValue]) strong->_drawableUnscored++;
            else if ([info[@"synthetic"] boolValue]) strong->_drawableSynthetic++; else strong->_drawableSource++;
        }
        // Bounded by 60s/phase and the display refresh; retain the exact callback
        // fields for gap, wait and epoch interpretation rather than infer them.
        [strong->_drawableEvents addObject:info]; [strong->_drawableLock unlock];
    };
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
    [_processor adoptSourceGeneration:1];
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
            strong->_report[@"ownedCapture"] = @{ @"exactWindowID": @(owned.windowID), @"ownerPID": @(owned.owningApplication.processID),
                @"ownerMatchesProcess": @(owned.owningApplication.processID == getpid()), @"scWindowFrame": SPProbeRect(owned.frame),
                @"filterContentRect": SPProbeRect(filter.contentRect), @"pointPixelScale": @(filter.pointPixelScale), @"configuredWidth": @(width), @"configuredHeight": @(height),
                @"configurationGeometrySource": @"exact own NSView backing bounds; current-process SCK metadata is redacted", @"ownSourceBackingBounds": SPProbeRect(ownBacking),
                @"requestedCaptureFormat": strong->_requestedCaptureFormat, @"pixelFormat": SPProbeFourCC(strong->_requestedCapturePixelFormat),
                @"pixelFormatType": @(strong->_requestedCapturePixelFormat), @"colorSpace": @"ITU-R BT.709", @"queueDepth": @3, @"minimumFrameInterval": @0,
                @"queueDepthObservation": @"Configured only; internal SCK pool occupancy is not observable." };
            SCStreamConfiguration *config = [SCStreamConfiguration new]; config.width = width; config.height = height;
            config.pixelFormat = strong->_requestedCapturePixelFormat; config.queueDepth = 3; config.minimumFrameInterval = kCMTimeZero;
            config.showsCursor = NO; config.capturesAudio = NO; config.colorSpaceName = kCGColorSpaceITUR_709;
            const BOOL apple = [strong->_arm isEqual:@"apple"], interpolate = SPProbeInterpolates(strong->_arm);
            SPLivePlanRequest *request = [requestType new]; request.requestID = 1; request.interpolationEnabled = interpolate;
            request.engineID = apple ? @"apple.frc" : @"rife.metal"; request.modelID = apple ? @"vt.frc.normal" : @"rife-v4.25";
            request.qualityID = apple ? @"normal" : @"fast"; request.quality = SPFRCQualityNormal; request.rifeStreamEnabled = !apple && interpolate;
            request.rateKind = SPLiveRateMultiplier; request.multiplier = interpolate ? 2 : 1; request.captureCapFPS = 0;
            request.scaleEnabled = NO; request.outputWidth = width; request.outputHeight = height; request.viewMode = SPLiveViewEnhanced; request.displayRefreshHz = 60;
            strong->_report[@"planRequestedDimensionsPixels"] = @{ @"width": @(width), @"height": @(height) };
            if (apple) strong->_report[@"appleRequestedConfiguration"] = @{ @"engineID": request.engineID, @"modelID": request.modelID,
                @"qualityID": request.qualityID, @"quality": @(request.quality), @"multiplier": @(request.multiplier),
                @"rateKind": @(request.rateKind), @"rifeStreamEnabled": @(request.rifeStreamEnabled),
                @"scaleEnabled": @(request.scaleEnabled), @"sourceFPS": @(strong->_sourceFPS),
                @"captureWidth": @(width), @"captureHeight": @(height), @"requestedCaptureFormat": strong->_requestedCaptureFormat,
                @"continuousEnvironment": NSProcessInfo.processInfo.environment[@"CHUANFLOW_FRC_CONTINUOUS"] ?: (id)NSNull.null };
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
                    BOOL outputSelectorValid = [strong respondsToSelector:@selector(stream:didOutputSampleBuffer:ofType:)];
                    strong->_report[@"streamOutputSelectorVerified"] = @(outputSelectorValid);
                    if (!outputSelectorValid) { [strong fail:@"SCK output selector does not match SDK protocol" details:nil]; return; }
                    strong->_stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:strong];
                    NSError *addError = nil;
                    if (![strong->_stream addStreamOutput:strong type:SCStreamOutputTypeScreen sampleHandlerQueue:strong->_captureQueue error:&addError]) { [strong fail:@"add own-window SCK output failed" details:addError.localizedDescription]; return; }
                    strong->_streamStartPending = YES;
                    [strong->_stream startCaptureWithCompletionHandler:^(NSError *startError) { dispatch_async(dispatch_get_main_queue(), ^{
                        strong->_streamStartPending = NO; strong->_streamStarted = startError == nil;
                        if (!startError) [strong recordProgress:@"own-window-SCK-started"];
                        if (strong->_stopping.load()) { [strong stopStreamAndFinalize:NO]; return; }
                        if (startError) [strong fail:@"start own-window SCK failed; no permission fallback" details:startError.localizedDescription];
                    }); }];
                });
            }];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                if (!strong->_stopping.load() && !strong->_report[@"ownWindowScreenshotPreflight"]) [strong fail:@"exact own-window screenshot preflight timeout" details:nil];
            });
        });
    }];
}
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sample ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen || _stopping.load()) return;
    @autoreleasepool {
        const uint64_t host = mach_absolute_time(); const double now = (double)SPProbeNs(host) / 1e9;
        _callbacks++; if (_firstCallbackHost == 0) _firstCallbackHost = now;
        if (_lastCallbackHost > 0) { const double gap = now - _lastCallbackHost; _maxCallbackGap = MAX(_maxCallbackGap, gap); [_callbackGapsMs addObject:@(gap * 1000)]; } _lastCallbackHost = now;
        NSArray *attachments = (__bridge NSArray *)CMSampleBufferGetSampleAttachmentsArray(sample, false);
        NSNumber *statusValue = attachments.firstObject[SCStreamFrameInfoStatus];
        const NSInteger status = statusValue ? statusValue.integerValue : -1;
        NSString *statusKey = [NSString stringWithFormat:@"%ld", (long)status]; _captureStatuses[statusKey] = @([_captureStatuses[statusKey] unsignedLongLongValue] + 1);
        [_processor noteCaptureStatus:status];
        if (status == SCFrameStatusIdle) _idle++;
        if (status != SCFrameStatusComplete) return;
        _complete++; if (_complete == 1) [self recordProgress:@"first-complete-capture-frame"];
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
            _firstCaptureMetadata = SPProbeFirstCaptureMetadata(sample, buffer, host, _callbacks);
        }
        _bufferWidth = (int)CVPixelBufferGetWidth(buffer); _bufferHeight = (int)CVPixelBufferGetHeight(buffer);
        if (![_bridge acceptsBuffer:buffer generation:1 hostNs:SPProbeNs(host)]) { _gateDuplicates++; return; } _gateAdmitted++;
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
        const BOOL validPTS = CMTIME_IS_VALID(pts) && !CMTIME_IS_INDEFINITE(pts) && pts.timescale > 0;
        int64_t num = validPTS ? pts.value : SPProbeNs(host), den = validPTS ? pts.timescale : 1000000000;
        [_processor noteRawCapturePTSNum:num ptsDen:validPTS ? den : 0 host:(int64_t)host width:_bufferWidth height:_bufferHeight generation:1];
        SPOwnedPixelBuffer *owned = [_bridge copyBuffer:buffer];
        if (!owned) { _copyFailed++; if ([_bridge lastFailurePoolExhausted]) [_processor noteCapturePoolPressureForGeneration:1]; return; }
        _copied++;
        [_processor pushPixelBuffer:owned.buffer ptsNum:num ptsDen:den host:(int64_t)host readyHost:(int64_t)mach_absolute_time() generation:1];
    }
}
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error { [self fail:@"own-window SCK stopped" details:error.localizedDescription]; }
- (void)finalize:(BOOL)complete {
    if (_didFinalize) return; _didFinalize = YES;
    __block NSDictionary *captureFormat;
    dispatch_sync(_captureQueue, ^{ captureFormat = [self captureFormatSnapshotOnCaptureQueue]; });
    _report[@"captureFormatObservation"] = captureFormat;
    if (_bareView) {
        [_timeline addObject:[self snapshot]];
        NSDictionary *bare = [_bareView snapshotIncludingFrames:YES]; _report[@"bareMetal"] = bare;
        if (bare[@"firstFailure"] != NSNull.null && !_report[@"firstFailure"])
            _report[@"firstFailure"] = @{ @"reason": @"bare Metal rendering failure", @"details": bare[@"firstFailure"] };
    }
    if (_processor) {
        if (_sourceWindow && _outputWindow) [_timeline addObject:[self snapshot]];
        _report[@"finalProcessorStats"] = _processor.stats ?: @{};
        _report[@"presentationOrder"] = [_processor presentationOrderDiagnostics] ?: @{};
        if ([_arm isEqual:@"apple"]) {
            NSDictionary *stats = _report[@"finalProcessorStats"];
            _report[@"appleActualPlanIdentity"] = @{ @"committed": @(_planCommitted), @"plan": _report[@"plan"] ?: @{},
                @"processorEngineID": stats[@"engineID"] ?: (id)NSNull.null, @"processorModelID": stats[@"modelID"] ?: (id)NSNull.null,
                @"processorQualityID": stats[@"qualityID"] ?: (id)NSNull.null, @"sessionsActual": stats[@"r8SessionsActual"] ?: (id)NSNull.null,
                @"sourceWidth": stats[@"sourceWidth"] ?: (id)NSNull.null, @"sourceHeight": stats[@"sourceHeight"] ?: (id)NSNull.null,
                @"sourcePixelFormat": stats[@"sourcePixelFormat"] ?: (id)NSNull.null };
        }
        [_processor stop];
        _processor.preview = nil; _processor.outputPreview = nil;
        _outputView.presented = nil; _outputView.surfaceReady = nil; _outputView.presentationFailure = nil;
        _hiddenPreview.presented = nil; _hiddenPreview.presentationFailure = nil;
    }
    [_sourceWindow close]; [_outputWindow close];
    const uint64_t sourceRetained = MIN(_sourceUpdateTotal, (uint64_t)_sourceUpdates.size());
    NSMutableArray *sourceEvents = [NSMutableArray arrayWithCapacity:(NSUInteger)sourceRetained];
    for (uint64_t index = _sourceUpdateTotal - sourceRetained; index < _sourceUpdateTotal; ++index) {
        const auto &event = _sourceUpdates[index % _sourceUpdates.size()];
        const BOOL directDrawObserved = event.drawCallsAfter > event.drawCallsBefore && event.lastDrawContentID == event.contentID &&
            event.lastDrawStartedHostTicks >= event.updateStartedHostTicks && event.lastDrawCompletedHostTicks >= event.lastDrawStartedHostTicks &&
            event.lastDrawCompletedHostTicks <= event.displayReturnedHostTicks;
        [sourceEvents addObject:@{ @"sequence": @(event.sequence), @"contentID": @(event.contentID), @"initialContent": @(event.initialContent),
            @"timerTicks": @(event.timerTicks), @"contentUpdates": @(event.contentUpdates),
            @"updateStartedHostTicks": @(event.updateStartedHostTicks), @"displayReturnedHostTicks": @(event.displayReturnedHostTicks),
            @"drawCallsBefore": @(event.drawCallsBefore), @"drawCallsAfter": @(event.drawCallsAfter),
            @"lastDrawContentID": event.lastDrawStartedHostTicks ? @(event.lastDrawContentID) : (id)NSNull.null,
            @"lastDrawStartedHostTicks": event.lastDrawStartedHostTicks ? @(event.lastDrawStartedHostTicks) : (id)NSNull.null,
            @"lastDrawCompletedHostTicks": event.lastDrawCompletedHostTicks ? @(event.lastDrawCompletedHostTicks) : (id)NSNull.null,
            @"directDrawObservedForContent": @(directDrawObserved) }];
    }
    _report[@"sourceUpdateTrace"] = @{ @"enabled": @(![_arm isEqual:@"bare"]), @"configuredContentFPS": @(_sourceFPS),
        @"sourceStartHostTicks": _sourceStartHostTicks ? @(_sourceStartHostTicks) : (id)NSNull.null,
        @"capacity": @(_sourceUpdates.size()), @"total": @(_sourceUpdateTotal), @"dropped": @(_sourceUpdateTotal - sourceRetained),
        @"firstseq": sourceRetained ? @(_sourceUpdateTotal - sourceRetained + 1) : (id)NSNull.null,
        @"lastseq": sourceRetained ? @(_sourceUpdateTotal) : (id)NSNull.null, @"events": sourceEvents,
        @"scope": @"Main-thread POD records for initial content 0 and each actual content-ID advance, exported after timer stop. HostTicks use machTimebase. Timer/content slots use configured FPS; the counter, binary bars and motion advance only on new slots. Late timer slots are skipped, not filled with repeated frames. Direct draw proves drawRect ran for that content during display(), not WindowServer presentation or a decoded SCK content ID; timestamp association alone does not prove capture/source one-to-one identity." };
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
    if (!_bareView) {
        NSMutableArray *exactSeconds = [NSMutableArray array];
        for (NSDictionary *phase in _phases)
            [exactSeconds addObject:SPProbeExactSecondObservations(_timeline, phase, _report[@"presentationOrder"] ?: @{})];
        _report[@"exactSecondObservations"] = exactSeconds;
    }
    NSError *jsonError = nil; NSData *json = [NSJSONSerialization dataWithJSONObject:_report options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&jsonError];
    NSError *writeError = nil; const BOOL written = json && [json writeToFile:_outputPath options:NSDataWritingWithoutOverwriting error:&writeError];
    _exitCode = !written ? 3 : ([_report[@"functionalComplete"] boolValue] ? 0 : 1);
    if (!written) fprintf(stderr, "result write failed: %s\n", (jsonError ?: writeError).localizedDescription.UTF8String);
    else fprintf(stdout, "%s\n", _outputPath.UTF8String);
    _finished = YES; [NSApp stop:nil];
    [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:NO];
}
- (void)finish:(BOOL)complete {
    if (_stopping.exchange(true)) return;
    [_tickTimer invalidate]; [_monitorTimer invalidate];
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
        [_stream stopCaptureWithCompletionHandler:^(NSError *error) { dispatch_async(dispatch_get_main_queue(), ^{
            if (error && !self->_report[@"firstFailure"]) self->_report[@"firstFailure"] = @{ @"reason": @"stop own-window SCK failed", @"details": error.localizedDescription ?: @"unknown" };
            [self finalize:complete && !error];
        }); }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (!self->_didFinalize) { if (!self->_report[@"firstFailure"]) self->_report[@"firstFailure"] = @{ @"reason": @"stop own-window SCK timeout" }; [self finalize:NO]; }
        });
    } else [self finalize:complete];
}
@end

static void SPProbeUsage(void) {
    fprintf(stderr, "Usage: SelfProbe --output /absolute/new.json [--preflight-only | --inspect --dylib /absolute/Release.dylib | --prepared-lifetime-only --dylib /absolute/Release.dylib | --arm bare|passthrough|rife|apple (default rife) [--dylib /absolute/Release.dylib (required except bare)] [--control-only] [--source-fps 24|30 (default 30) --capture-format nv12|bgra (default nv12) --source-width-points 1324 --source-height-points 834 --seconds 12 (5..60) --minimum-idle-seconds 60]]\n");
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        NSMutableDictionary *options = [@{ @"arm": @"rife", @"control-only": @NO, @"source-fps": @30, @"capture-format": @"nv12", @"source-width-points": @1324, @"source-height-points": @834, @"seconds": @12, @"minimum-idle-seconds": @60 } mutableCopy];
        BOOL preflightOnly = NO, inspect = NO, preparedLifetimeOnly = NO;
        NSSet *numeric = [NSSet setWithArray:@[@"source-width-points", @"source-height-points", @"seconds", @"minimum-idle-seconds"]];
        for (int i = 1; i < argc; ++i) {
            NSString *arg = @(argv[i]);
            if ([arg isEqual:@"--preflight-only"]) { preflightOnly = YES; continue; }
            if ([arg isEqual:@"--inspect"]) { inspect = YES; continue; }
            if ([arg isEqual:@"--prepared-lifetime-only"]) { preparedLifetimeOnly = YES; continue; }
            if ([arg isEqual:@"--control-only"]) { options[@"control-only"] = @YES; continue; }
            if (![arg hasPrefix:@"--"] || i + 1 >= argc) { SPProbeUsage(); return 2; }
            NSString *key = [arg substringFromIndex:2], *value = @(argv[++i]);
            if ([key isEqual:@"source-fps"]) {
                if (![value isEqual:@"24"] && ![value isEqual:@"30"]) { SPProbeUsage(); return 2; }
                options[key] = @([value integerValue]);
            } else if ([key isEqual:@"capture-format"]) {
                if (![value isEqual:@"nv12"] && ![value isEqual:@"bgra"]) { SPProbeUsage(); return 2; }
                options[key] = value;
            } else if ([numeric containsObject:key]) options[key] = @([value doubleValue]);
            else if ([key isEqual:@"dylib"] || [key isEqual:@"output"] || [key isEqual:@"arm"]) options[key] = value;
            else { SPProbeUsage(); return 2; }
        }
        NSString *output = options[@"output"], *dylib = options[@"dylib"];
        const BOOL validArm = [@[@"bare", @"passthrough", @"rife", @"apple"] containsObject:options[@"arm"]];
        const BOOL requiresDylib = !preflightOnly && (inspect || preparedLifetimeOnly || ![options[@"arm"] isEqual:@"bare"]);
        if (!validArm || !output.isAbsolutePath || [NSFileManager.defaultManager fileExistsAtPath:output] || (requiresDylib && !dylib.isAbsolutePath) || (preflightOnly && inspect) || (preparedLifetimeOnly && (preflightOnly || inspect))) { SPProbeUsage(); return 2; }
        if ([options[@"seconds"] doubleValue] < 5 || [options[@"seconds"] doubleValue] > 60 || [options[@"source-width-points"] doubleValue] < 320 || [options[@"source-width-points"] doubleValue] > 1700 || [options[@"source-height-points"] doubleValue] < 240 || [options[@"source-height-points"] doubleValue] > 1100 || [options[@"minimum-idle-seconds"] doubleValue] < 10 || [options[@"minimum-idle-seconds"] doubleValue] > 3600) { SPProbeUsage(); return 2; }
        if (preparedLifetimeOnly) {
            [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
            NSMutableDictionary *result = [@{ @"mode": @"prepared-lifetime-only", @"requestedCaptureFormat": options[@"capture-format"], @"windowsCreated": @NO,
                @"captureStarted": @NO, @"modelPrepared": @NO,
                @"scope": @"Bounded offscreen GPU texture use, completion and pixel-pool return; no display/FPS or human quality acceptance." } mutableCopy];
            void *loaded = dlopen(dylib.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
            Class view = NSClassFromString(@"SPLivePreviewView"); SEL selector = NSSelectorFromString(@"runPreparedTextureLifetimeProbe");
            if (!loaded || !view || ![view respondsToSelector:selector]) {
                const char *error = loaded ? nullptr : dlerror();
                result[@"ok"] = @NO; result[@"firstFailure"] = error ? @(error) : @"prepared lifetime probe selector unavailable";
            } else {
                __block NSDictionary *probeResult = nil; dispatch_semaphore_t done = dispatch_semaphore_create(0);
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    probeResult = ((NSDictionary *(*)(id, SEL))objc_msgSend)(view, selector); dispatch_semaphore_signal(done);
                });
                const double started = SPProbeNow();
                BOOL finished = NO;
                while (SPProbeNow() - started < 30) {
                    if (dispatch_semaphore_wait(done, DISPATCH_TIME_NOW) == 0) { finished = YES; break; }
                    CFRunLoopRunInMode(kCFRunLoopDefaultMode, .02, false);
                }
                result[@"probe"] = finished ? (probeResult ?: @{}) : @{};
                result[@"ok"] = @(finished && [probeResult[@"ok"] boolValue]);
                if (!finished) result[@"firstFailure"] = @"prepared lifetime probe exceeded 30 seconds";
            }
            NSError *error = nil; NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
            if (!json || ![json writeToFile:output options:NSDataWritingWithoutOverwriting error:&error]) { fprintf(stderr, "result write failed: %s\n", error.localizedDescription.UTF8String); return 3; }
            fprintf(stdout, "%s\n", output.UTF8String); return [result[@"ok"] boolValue] ? 0 : 1;
        }
        if (preflightOnly || inspect) {
            NSMutableDictionary *result = [@{ @"mode": preflightOnly ? @"preflight-only" : @"inspect", @"arm": options[@"arm"], @"controlOnly": options[@"control-only"], @"configuredSourceFPS": options[@"source-fps"], @"requestedCaptureFormat": options[@"capture-format"], @"preflight": SPProbePreflight([options[@"minimum-idle-seconds"] doubleValue]), @"windowsCreated": @NO, @"captureStarted": @NO, @"modelPrepared": @NO, @"mainBundle": NSBundle.mainBundle.bundlePath ?: @"" } mutableCopy];
            BOOL ok = YES;
            if (inspect) {
                void *loaded = dlopen(dylib.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL); const char *loadError = loaded ? nullptr : dlerror();
                NSMutableDictionary *classes = [NSMutableDictionary dictionary];
                for (NSString *name in @[@"SPLiveProcessor", @"SPLivePlanRequest", @"SPLivePreviewView", @"SPSelfWindowCaptureBridge"]) { classes[name] = @(NSClassFromString(name) != Nil); ok = ok && [classes[name] boolValue]; }
                result[@"classes"] = classes; result[@"dylibLoaded"] = @(loaded != nullptr);
                if (loadError) result[@"firstFailure"] = @(loadError);
                if ([options[@"arm"] isEqual:@"apple"]) {
                    NSDictionary *identity = SPProbeAppleFRCIdentity(); result[@"appleFRCIdentity"] = identity;
                    result[@"originalModelResourceRequired"] = @NO;
                    ok = ok && loaded && [identity[@"engineClassAvailable"] boolValue] && [identity[@"isSupportedViaEngine"] boolValue];
                } else {
                    NSBundle *modelBundle = [NSBundle bundleWithURL:[NSBundle.mainBundle URLForResource:@"RifeMetal_RifeMetal" withExtension:@"bundle"]];
                    NSURL *model = [modelBundle URLForResource:@"rife-v4.25" withExtension:@"rmw"];
                    result[@"originalModelResource"] = model.path ?: (id)NSNull.null;
                    result[@"originalModelResourceExists"] = @(model && [NSFileManager.defaultManager fileExistsAtPath:model.path]);
                    ok = ok && loaded && [result[@"originalModelResourceExists"] boolValue];
                }
                result[@"experimentTrialBundleFlag"] = @([[NSBundle.mainBundle objectForInfoDictionaryKey:@"ODFExperimentTrial"] boolValue]);
            } else ok = [result[@"preflight"][@"allowed"] boolValue];
            result[@"ok"] = @(ok); NSError *error = nil; NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
            if (!json || ![json writeToFile:output options:NSDataWritingWithoutOverwriting error:&error]) { fprintf(stderr, "result write failed: %s\n", error.localizedDescription.UTF8String); return 3; }
            fprintf(stdout, "%s\n", output.UTF8String); return ok ? 0 : 1;
        }
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        SPSelfWindowCaptureProbe *probe = [[SPSelfWindowCaptureProbe alloc] initWithOptions:options];
        dispatch_async(dispatch_get_main_queue(), ^{ [probe start]; });
        [NSApp run];
        return probe.finished ? probe.exitCode : 1;
    }
}
