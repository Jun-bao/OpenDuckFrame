#import <Foundation/Foundation.h>
#include <stdint.h>

struct AVCodecParameters;
struct AVPacket;

@interface SPAudioDecoder : NSObject

@property (nonatomic) unsigned spLogId;

@property (nonatomic, readonly) int outputChannels;

- (int)setupWithCodecParameters:(const struct AVCodecParameters *)par;

- (int)setupWithCodecParameters:(const struct AVCodecParameters *)par
              outputChannelMask:(uint64_t)outputChannelMask;

- (int)decodePacket:(const struct AVPacket *)pkt into:(NSMutableData *)outData;
- (void)flush;
- (void)shutdown;
// Optional native-sample MD5 in FLAC STREAMINFO format: signed, interleaved,
// little-endian samples using ceil(bitsPerSample / 8) bytes per sample.
// Enable before setup. A digest is valid only for uninterrupted decoding since
// setup; flush, unsupported sample formats or stopping accumulation invalidate it.
// nativeMd5Digest returns NO when no valid digest is available.
@property (nonatomic) BOOL nativeMd5Enabled;
- (BOOL)nativeMd5Digest:(uint8_t *)out16 samples:(uint64_t *)samples;
// Stop native-sample MD5 accumulation once the caller no longer needs it.
// Call only on the decoder-owning audio thread. Subsequent digest requests
// return NO; nativeMd5Active reports whether accumulation remains valid.
- (void)stopNativeMd5;
@property (nonatomic, readonly) BOOL nativeMd5Active;
// Counts of decoded output frames with and without decode_error_flags during
// the most recent decodePacket call. Producing PCM alone does not prove that
// the decoder received undamaged audio.
@property (nonatomic, readonly) int lastErrorFlaggedFrames;
@property (nonatomic, readonly) int lastCleanFrames;
// Decoder codec as an FFmpeg AVCodecID integer, and the input sample rate.
// Valid after setup; used by the owning audio thread for packet-level checks.
@property (nonatomic, readonly) int codecIdValue;
@property (nonatomic, readonly) int inputSampleRate;
@end
