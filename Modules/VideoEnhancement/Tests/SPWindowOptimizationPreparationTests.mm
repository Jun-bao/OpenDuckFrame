#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <dlfcn.h>
#import "SPRifeBridge.h"

static CVPixelBufferRef source(int width, int height, uint8_t luma) {
    CVPixelBufferRef buffer = NULL;
    NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{},
                            (id)kCVPixelBufferMetalCompatibilityKey: @YES};
    if (CVPixelBufferCreate(NULL, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                           (__bridge CFDictionaryRef)attrs, &buffer) != kCVReturnSuccess) return NULL;
    CVPixelBufferLockBaseAddress(buffer, 0);
    for (size_t plane = 0; plane < 2; ++plane)
        memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane), plane ? 128 : luma,
               CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane));
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    return buffer;
}

static NSDictionary *check(Class cls, NSBundle *bundle, int width, int height, double hz, BOOL bounded) {
    SPRifeBridge *bridge = [[cls alloc] initWithResourceBundle:bundle];
    bridge.liveStreamEnabled = YES;
    NSError *error = nil;
    BOOL ready = [bridge prepareWindowModelID:@"rife-v4.25" quality:@"fast" width:width height:height refreshHz:hz error:&error];
    NSDictionary *preparation = bridge.windowPreparationDiagnostics;
    BOOL mode = ready && bridge.airPerformanceEnabled == bounded &&
        [preparation[@"mode"] isEqual:bounded ? @"bounded-window" : @"native"];
    CVPixelBufferRef previous = source(width, height, 32), current = source(width, height, 180);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block BOOL output = NO;
    __block NSString *failure = error.localizedDescription;
    BOOL accepted = ready && previous && current && [bridge submitLivePrevious:previous current:current
        previousID:1 currentID:2 previousPTS:CMTimeMake(0, 30) currentPTS:CMTimeMake(1, 30)
        generation:1 clockEpoch:1 timesteps:@[@0.5] token:1
        completion:^(uint64_t token, NSArray<SPOwnedPixelBuffer *> *frames, double seconds, NSError *err) {
            CVPixelBufferRef frame = frames.firstObject.buffer;
            output = token == 1 && !err && frames.count == 1 && frame &&
                CVPixelBufferGetWidth(frame) == bridge.processingWidth &&
                CVPixelBufferGetHeight(frame) == bridge.processingHeight;
            failure = err.localizedDescription;
            dispatch_semaphore_signal(done);
        }];
    BOOL completed = accepted && dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) == 0;
    [bridge invalidate];
    if (previous) CVPixelBufferRelease(previous);
    if (current) CVPixelBufferRelease(current);
    return @{ @"ok": @(mode && completed && output), @"ready": @(ready), @"accepted": @(accepted),
        @"actualGeneratedFrame": @(output), @"expectedBounded": @(bounded),
        @"preparation": preparation ?: @{}, @"error": failure ?: @"" };
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3 || !dlopen(argv[1], RTLD_NOW | RTLD_LOCAL)) return 2;
        Class cls = NSClassFromString(@"SPRifeBridge");
        NSBundle *bundle = [NSBundle bundleWithPath:@(argv[2])];
        if (!cls || !bundle || ![cls windowOptimizationCapabilitiesSupported]) return 3;
        // A relaxed test budget proves native dimensions are retained. The tiny
        // second budget deterministically exercises fallback without faking timing.
        NSDictionary *native = check(cls, bundle, 1280, 720, 1, NO);
        NSDictionary *bounded = check(cls, bundle, 3420, 2148, 1000000, YES);
        SPRifeBridge *file = [[cls alloc] initWithResourceBundle:bundle];
        NSError *error = nil;
        BOOL fileUnchanged = [file prepareModelID:@"rife-v4.25" quality:@"fast" width:320 height:192 error:&error] &&
            !file.airPerformanceEnabled && file.processingWidth == 320 && file.processingHeight == 192;
        [file invalidate];
        SPRifeBridge *invalid = [[cls alloc] initWithResourceBundle:bundle];
        BOOL rejected = ![invalid prepareWindowModelID:@"rife-v4.25" quality:@"fast" width:32768 height:2 refreshHz:60 error:&error];
        [invalid invalidate];
        BOOL ok = [native[@"ok"] boolValue] && [bounded[@"ok"] boolValue] && fileUnchanged && rejected;
        NSDictionary *result = @{ @"ok": @(ok), @"native": native, @"bounded": bounded,
            @"ordinaryPreparationUnchanged": @(fileUnchanged), @"oversizedRejected": @(rejected),
            @"scope": @"real GPU preparation and generated frames; forced test budgets; no capture, presentation or sustained FPS" };
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
        fwrite(json.bytes, 1, json.length, stdout); putchar('\n');
        return ok ? 0 : 1;
    }
}
