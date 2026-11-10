#import "SPLiveProcessor.h"
#import <CoreMedia/CoreMedia.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach_time.h>
#include "SPFPSMeter.hpp"
#include "SPRateBudget.hpp"
#include "SPRateSchedule.hpp"
#include "SPRifePairAffineClock.hpp"
#include "SPPresentationBudget.hpp"
#include "SPLiveHeldPolicy.hpp"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdlib>
#include <deque>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <vector>

@class SPOwnedPixelBuffer;
// There is no real RIFE dependency. Any unexpected model submission is a test
// failure; the completion itself is the verbatim production implementation.
@interface SPRifeBridge : NSObject
- (BOOL)submitLivePrevious:(CVPixelBufferRef)previous current:(CVPixelBufferRef)current
               previousID:(uint64_t)previousID currentID:(uint64_t)currentID
              previousPTS:(CMTime)previousPTS currentPTS:(CMTime)currentPTS
               generation:(uint64_t)generation clockEpoch:(uint64_t)clockEpoch
                timesteps:(NSArray<NSNumber *> *)timesteps token:(uint64_t)token
               completion:(void (^)(uint64_t, NSArray<SPOwnedPixelBuffer *> *, double, NSError *))completion;
@end
@implementation SPRifeBridge
- (BOOL)submitLivePrevious:(CVPixelBufferRef)previous current:(CVPixelBufferRef)current
               previousID:(uint64_t)previousID currentID:(uint64_t)currentID
              previousPTS:(CMTime)previousPTS currentPTS:(CMTime)currentPTS
               generation:(uint64_t)generation clockEpoch:(uint64_t)clockEpoch
                timesteps:(NSArray<NSNumber *> *)timesteps token:(uint64_t)token
               completion:(void (^)(uint64_t, NSArray<SPOwnedPixelBuffer *> *, double, NSError *))completion {
    (void)previous; (void)current; (void)previousID; (void)currentID;
    (void)previousPTS; (void)currentPTS; (void)generation; (void)clockEpoch;
    (void)timesteps; (void)token; (void)completion;
    fprintf(stderr, "FAIL probe contract: unexpected real-model submission\n");
    abort();
}
@end

@implementation SPLivePlanRequest
@end

#include "RateBudgetProbeStructures.inc"

// Minimal construction only. Every method under test, its callee that releases
// leases, and the test hook below are extracted from the production source.
@implementation SPLiveProcessor {
    dispatch_queue_t _q;
    SPLivePlanRequest *_request;
    SPRifeBridge *_rife;
    BOOL _sessionReady, _stopped, _nativeBudgetActive, _rateBudgetPassthrough;
    int _inflight, _effectiveMultiplier, _sourceWidth, _sourceHeight;
    uint64_t _sourceGeneration, _configVersion, _clockEpoch, _measurementEpoch, _inflightEpoch;
    int64_t _rifeBusySinceHost;
    std::unordered_map<uint64_t, SPLiveHeld> _held;
    sp::RateBudget _rateBudget;
    sp::FPSMeter _fpsMeter;
    std::mutex _rawCadenceMutex;
    sp::NativeCadenceGate _nativeCadence;
    BOOL _rateBudgetProbeActive;
    uint64_t _rateBudgetProbeRound, _rateBudgetProbeJobs, _rateBudgetProbeLastFrameB;
    uint64_t _rateBudgetProbeInFlightToken, _rateBudgetProbeInFlightEpoch;
    int _rateBudgetProbeCollected;
    int64_t _rateBudgetProbeNextHost;
    double _rateBudgetProbeMedianMs;
    std::deque<SPLiveJob *> _rateBudgetProbePending;
    std::vector<double> _rateBudgetProbeTaskCosts, _rateBudgetProbePhaseCosts;
}
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _q = dispatch_queue_create("app.openduckframe.probe-contract", DISPATCH_QUEUE_SERIAL);
    _request = [[SPLivePlanRequest alloc] init];
    return self;
}
#include "RateBudgetProbeMethods.inc"
@end

static void check(BOOL condition, NSString *scenario, NSString *message, NSDictionary *result) {
    if (condition) return;
    fprintf(stderr, "FAIL probe contract %s: %s\n%s\n", scenario.UTF8String,
            message.UTF8String, result.description.UTF8String);
    exit(1);
}

int main(void) {
    @autoreleasepool {
        for (NSString *scenario in @[@"current", @"config", @"generation", @"clock", @"stopped", @"queued"]) {
            SPLiveProcessor *processor = [[SPLiveProcessor alloc] init];
            NSDictionary *result = [processor ownedContractRateBudgetProbeCancellation:scenario];
            check([result[@"setup"] boolValue], scenario, @"fixture must start with an eligible compute probe", result);
            check([result[@"inflightAfter"] intValue] == [result[@"inflightBaseline"] intValue],
                  scenario, @"inflight did not return to baseline", result);
            check([result[@"tokenAfter"] unsignedLongLongValue] == 0, scenario, @"probe token not cleared", result);
            check(![result[@"activeAfter"] boolValue] && [result[@"pendingAfter"] intValue] == 0,
                  scenario, @"probe round or queued jobs still active", result);
            if ([scenario isEqualToString:@"generation"]) {
                check([result[@"oldHeldRemoved"] boolValue], scenario, @"old generation held map not removed", result);
                check([result[@"pinsAfter"] intValue] == 2, scenario, @"stale completion touched new-generation sentinel pins", result);
                check([result[@"releasedAfterCallback"] intValue] == 2,
                      scenario, @"old generation retained source leases not released by callback", result);
            } else {
                check([result[@"pinsBefore"] intValue] == 2 && [result[@"pinsAfter"] intValue] == 0,
                      scenario, @"source pins must fall from two to zero", result);
            }
            check([result[@"releasedAfterCleanup"] intValue] == [result[@"buffersCreated"] intValue],
                  scenario, @"source buffer lease leak", result);
            if ([scenario isEqualToString:@"current"]) {
                check(std::abs([result[@"phaseCostAfter"] doubleValue] - 5.0) < 0.000001 &&
                      std::abs([result[@"probeMedianAfter"] doubleValue] - 5.0) < 0.000001,
                      scenario, @"positive control did not update real policy P", result);
            } else {
                check([result[@"phaseCostAfter"] doubleValue] == [result[@"phaseCostBefore"] doubleValue] &&
                      [result[@"probeMedianAfter"] doubleValue] == [result[@"probeMedianBefore"] doubleValue],
                      scenario, @"invalid/cancelled probe changed P or the probe median", result);
            }
            printf("PASS probe contract %s: %s\n", scenario.UTF8String,
                   [scenario isEqualToString:@"generation"] ?
                   "old leases released; replacement pins preserved; token/inflight cleared; P unchanged" :
                   ([scenario isEqualToString:@"current"] ? "real completion updates P and releases source pins" :
                    "pins 2->0; token/inflight cleared; P unchanged; round ended"));
        }
    }
    return 0;
}
