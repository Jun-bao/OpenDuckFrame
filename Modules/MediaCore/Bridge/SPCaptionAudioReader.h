// On-demand audio reader for caption generation, independent of playback.
// Owns its demuxer, audio decoder and resampler, producing mono 16 kHz Int16
// PCM. Call synchronously on a dedicated background thread; the first call
// applies throttled disk I/O. abort is safe from any thread.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPCaptionAudioReader : NSObject

// Owning playback instance for log attribution; zero means unassigned.
@property (nonatomic) unsigned spLogId;

// Signed playback timeline origin in microseconds. Set before the first read
// to align cue times with the player. Otherwise derive the container start time,
// falling back to the earliest declared stream start without discarding its sign.
@property (nonatomic) int64_t timelineOriginUs;

// Container stream index, matching audioTrackList. A negative or non-audio
// selection falls back to the first audio stream. Opening is deferred until reading.
- (instancetype)initWithPath:(NSString *)path audioStreamIndex:(int)streamIndex;

// Fixed output sample rate: 16000 Hz.
@property (nonatomic, readonly) int sampleRate;

// Optional explicit open; reads open lazily. Volume and size metadata are valid on success.
- (BOOL)open;
// Admission covers open, metadata, probing and block reads; waits remain cancellable.
- (BOOL)openWithShouldPause:(nullable BOOL (^)(void))shouldPause NS_SWIFT_NAME(open(shouldPause:));
// Read on the calling thread after synchronous open/read returns. Cancellation
// leaves no error; clean EOF produces non-nil empty data.
@property (nonatomic, readonly, nullable) NSError *lastError;
// Whether the file resides on a supported network filesystem.
@property (nonatomic, readonly) BOOL remoteVolume;
@property (nonatomic, readonly) int64_t fileSize;
// Cumulative file bytes read, available from any thread for throughput estimates.
@property (nonatomic, readonly) int64_t bytesRead;

// Read mono Int16 PCM for [start, start + duration) on the zero-based playback
// timeline. Preserve timing gaps as silence and truncate at the real stream end.
// Clean EOF or an empty interval returns empty data. Unrecoverable failure,
// opening failure or cancellation returns nil; failures set lastError except cancellation.
- (nullable NSData *)readMonoPCMFromSeconds:(double)start durationSeconds:(double)duration;
// Check shouldPause before each block: up to 256 KiB locally or 1 MiB remotely.
// When true, wait in place with 100 ms polling until admission or abort.
// Playback takes priority without discarding this sequential job's progress.
- (nullable NSData *)readMonoPCMFromSeconds:(double)start durationSeconds:(double)duration
                                shouldPause:(nullable BOOL (^)(void))shouldPause;

// Thread-safe, idempotent cancellation. Interrupt in-flight reads promptly;
// subsequent reads return nil.
- (void)abort;

@end

NS_ASSUME_NONNULL_END
