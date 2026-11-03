// OpenDuckFrame - damage map snapshot (timeline tri-state: fluent / partial / none)
//
// Built from byte-level evidence gathered during playback (all-zero packets, broken length chains,
// out-of-range indexes, exhausted content) and decode results, recorded per track and merged into the
// main band for the selected tracks. Unknown spans are not published; evidence is bound to the content
// version and playback generation of the current open. Changes are announced on the main thread through
// playerCoreDidUpdateTimelinePreview (shared with the dust channel).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(int32_t, SPDamageClass) {
    SPDamageClassUnknown = 0,
    SPDamageClassFluent = 1,   // Continuous playback observed without conflicting anomalies
    SPDamageClassPartial = 2,  // Known damage, but audio or video is still available
    SPDamageClassNone = 3,     // Confirmed: no usable content on the selected tracks
    SPDamageClassPending = 4,  // Not downloaded yet (the file is still being written: the unwritten tail of an append, or unfilled ranges of a preallocated / BitTorrent file); not damage
};

typedef struct {
    int32_t cls;      // SPDamageClass
    int32_t track;    // 0 = video, 1 = audio (perTrack only; main is always -1)
    int64_t fromUs;   // Zero-based timeline [from, until)
    int64_t untilUs;
} SPDamageSpanRecord;

@interface SPDamageSnapshot : NSObject
@property (nonatomic, readonly) uint64_t generation;      // Incremented whenever any field changes
@property (nonatomic, readonly) int64_t durationUs;       // Declared duration (not rewritten on PartialEnded)
@property (nonatomic, readonly) int64_t availableEndUs;   // Actual usable end of this open; -1 = truncation not confirmed
@property (nonatomic, readonly) NSData *main;             // SPDamageSpanRecord[] merged for the selected tracks, ascending fromUs
@property (nonatomic, readonly) NSData *perTrack;         // SPDamageSpanRecord[] ordered by track, then fromUs
@property (nonatomic, readonly) NSData *pending;          // SPDamageSpanRecord[] of ranges not downloaded yet: present only while the file is being written, removed as data arrives
@end

NS_ASSUME_NONNULL_END
