#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import "SPVideoDecoding.h"

struct AVCodecParameters;
struct AVPacket;

#ifdef __cplusplus
extern "C"
#endif
BOOL SPVideoToolboxDriverLoaded(void);

@interface SPVideoDecoder : NSObject <SPVideoDecoding>

+ (void)warmUpDecoderForCodecID:(int)codecID;

@property (nonatomic, copy) NSData *firstPacketHint;

@property (nonatomic) int outputWidthHint;
@property (nonatomic) int outputHeightHint;

- (int)setupWithCodecParameters:(const struct AVCodecParameters *)par
              timeBaseNumerator:(int64_t)tbNum
            timeBaseDenominator:(int64_t)tbDen;

- (SPDecodedVideoOutput)decodePacketOutput:(const struct AVPacket *)pkt;

// MEMC safety scan. VideoToolbox does not reliably attach FieldCount/
// FieldDetail to interlaced output (including streams whose SPS changes from
// progressive to interlaced mid-playback). The compressed-bitstream parser is
// therefore created only while interpolation is committed On. Off destroys it
// immediately. The decoder still remembers rare parameter-set changes while
// doing its mandatory bitstream conversion/NAL walk, so a one-shot config
// change that happened during Off cannot be misidentified after a later On.
- (void)setInterpolationScanEnabled:(BOOL)enabled
                    codecParameters:(const struct AVCodecParameters *)par;
// Preserve a positive coded-interlace verdict when Core replaces a VT decoder
// after an in-band parameter-set change. The replacement codecpar may still
// carry the container's stale progressive/unknown field_order.
- (void)requestFrameLocalDeinterlacingForKnownCodedContent;

- (void)flush;
- (void)shutdown;

@property (nonatomic, readonly) BOOL isHardwareDecoding;

@property (nonatomic, readonly) int lastError;

@end
