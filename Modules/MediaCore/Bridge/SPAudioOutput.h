#import <Foundation/Foundation.h>

@interface SPAudioOutput : NSObject

- (BOOL)setup;

- (uint64_t)outputChannelMask;

- (int)outputChannels;

- (BOOL)outputLayoutChangePending;
- (BOOL)applyPendingOutputLayout;
@property (nonatomic, copy) void (^outputLayoutChangeHandler)(void);
- (NSString *)outputLayoutDescription;
- (NSString *)outputLayoutName;
- (void)start;
- (void)stop;
// Full media close only, after the caller has joined the PCM writer and called
// stop. Release per-session scratch while retaining the prewarmed AudioUnit.
// Not a pause/seek operation; reset is still required before the next session.
- (void)releaseSessionScratch;

- (void)reset;

- (void)abortWrites;

- (void)markSetupFailed;

- (void)writePCM:(const float *)data frames:(int)count rate:(double)rate;

- (BOOL)writePCM:(const float *)data frames:(int)count rate:(double)rate expectedEpoch:(int32_t)epoch;

- (BOOL)writePCM:(const float *)data frames:(int)count channels:(int)channels
            rate:(double)rate expectedEpoch:(int32_t)epoch;
- (int32_t)currentEpoch;

- (void)requestRate:(double)rate;
- (BOOL)rateSwitchPending;
- (int64_t)rateSwitchPlayedFrame;

- (void)servicePendingRateSwitchWithEpoch:(int32_t)epoch;

- (void)drainStretchAtEOFWithEpoch:(int32_t)epoch;

- (int64_t)clockFrames;

- (int64_t)bufferedFrames;
// Software master gain from 0 to 5 (100% = 1, 500% = 5). The AudioUnit stays
// at unity; the render callback applies a zero-lookahead sample-peak limiter.
- (void)setVolume:(float)volume;

@property (nonatomic, readonly) BOOL isRunning;
@end
