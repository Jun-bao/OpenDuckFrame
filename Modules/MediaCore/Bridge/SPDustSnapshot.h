// Main-thread read-only particle-timeline snapshot from the thumbnail worker.
// Keyframe timestamp/byte-offset pairs describe per-GOP bitrate; verified
// thumbnail coverage and sampled color control appearance. The playback
// demuxer is never accessed. Snapshot state belongs to one media session.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    int64_t tsUs;   // Zero-based media timestamp, in microseconds.
    int64_t pos;    // File byte offset from the index entry.
} SPDustKey;

typedef struct {
    int64_t keyUs;    // Thumbnail keyframe timestamp, in zero-based microseconds.
    int64_t fromUs;   // Verified coverage interval [from, until], in microseconds.
    int64_t untilUs;
    float hue;        // HSV hue in [0, 1], selected by a saturation/brightness-weighted histogram.
    float sat;        // Mean saturation in [0, 1].
    float luma;       // Mean brightness in [0, 1].
    float valid;      // One when color is available; zero for coverage-only samples.
} SPDustCover;

@interface SPThumbDustSnapshot : NSObject
@property (nonatomic, readonly) uint64_t generation;      // Increments whenever snapshot fields change.
@property (nonatomic, readonly) NSData *keys;             // SPDustKey array, sorted by tsUs.
@property (nonatomic, readonly) NSData *covers;           // SPDustCover array, sorted by keyUs.
@property (nonatomic, readonly) int64_t sweepSpacingUs;   // Scan-bucket width in microseconds; zero means no active scan plan.
@end

NS_ASSUME_NONNULL_END
