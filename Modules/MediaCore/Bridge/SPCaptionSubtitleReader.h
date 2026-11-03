// On-demand windowed reader for embedded text subtitle cues. It owns its
// demuxer and interrupt state, discards unrelated streams and uses throttled
// background I/O. Interleaved containers still require reading video bytes;
// sequential caption jobs therefore yield block reads to foreground playback.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPCaptionSubtitleCue : NSObject
@property (nonatomic) double start;   // Zero-based media time in seconds.
@property (nonatomic) double end;
@property (nonatomic, copy) NSString *text; // Plain text with ASS overrides removed and escaped line breaks expanded.
@end

@interface SPCaptionSubtitleReader : NSObject

@property (nonatomic) unsigned spLogId;

// Signed playback timeline origin in microseconds. Set before the first read
// to align cue times with the player. Otherwise derive the container start time,
// falling back to the earliest declared stream start without discarding its sign.
@property (nonatomic) int64_t timelineOriginUs;

// Container stream index, matching subtitleTrackList.
- (instancetype)initWithPath:(NSString *)path subtitleStreamIndex:(int)streamIndex;

- (BOOL)open;
- (BOOL)openWithShouldPause:(nullable BOOL (^)(void))shouldPause NS_SWIFT_NAME(open(shouldPause:));
// Last synchronous open/read failure. Cancellation sets no error; clean EOF returns an empty array.
@property (nonatomic, readonly, nullable) NSError *lastError;

// Read cues whose starts lie in [start, start + duration), sorted by start time.
// Empty intervals and clean EOF return an empty array; failures or abort return nil.
// Skip isolated damaged packets while preserving the sequential cursor. Persistent
// I/O or resource failures remain errors. Adjacent windows reuse the cursor and
// lookahead cue; repeated windows use their snapshot, while jumps perform a seek.
- (nullable NSArray<SPCaptionSubtitleCue *> *)readCuesFromSeconds:(double)start
                                                  durationSeconds:(double)duration;
// Check shouldPause before reads; wait in place while playback has priority.
- (nullable NSArray<SPCaptionSubtitleCue *> *)readCuesFromSeconds:(double)start
                                                  durationSeconds:(double)duration
                                                      shouldPause:(nullable BOOL (^)(void))shouldPause;

- (void)abort;

@end

NS_ASSUME_NONNULL_END
