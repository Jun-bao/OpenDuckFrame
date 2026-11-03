#pragma once

#include <cstddef>
#include <cstdint>

namespace spav1 {

// 5.3.1 obu_type
inline constexpr int kObuSequenceHeader = 1;
inline constexpr int kObuTemporalDelimiter = 2;
inline constexpr int kObuFrameHeader = 3;
inline constexpr int kObuTileGroup = 4;
inline constexpr int kObuMetadata = 5;
inline constexpr int kObuFrame = 6;
inline constexpr int kObuRedundantFrameHeader = 7;
inline constexpr int kObuPadding = 15;

// 6.8.2 frame_type
inline constexpr int kFrameKey = 0;
inline constexpr int kFrameInter = 1;
inline constexpr int kFrameIntraOnly = 2;
inline constexpr int kFrameSwitch = 3;

// SELECT_SCREEN_CONTENT_TOOLS / SELECT_INTEGER_MV
inline constexpr int kSelect = 2;

inline constexpr int kMaxObusPerTemporalUnit = 64;

struct SequenceHeader {
    bool usable = false;
    int operatingPointIdc = 0;
    int orderHintBits = 0;
    int forceScreenContentTools = kSelect;  // 0/1/kSelect
    int forceIntegerMv = kSelect;           // 0/1/kSelect
};

struct FrameInfo {
    bool showExisting = false;
    bool showFrame = false;
    int frameType = kFrameKey;
    int refreshFrameFlags = 0;
};

enum class Action {
    SendAsIs,
    DropPacket,
    TruncateToPrefix,
};

struct ScanResult {
    Action action = Action::SendAsIs;
    int keepBytes = 0;
    int droppedFrames = 0;
    int frames = 0;
    bool structureOk = false;
    bool sawKeyFrame = false;
};

class BitReader {
public:
    BitReader(const uint8_t *data, size_t size) : data_(data), bits_(size * 8) {}
    uint32_t f(int n) {
        uint32_t v = 0;
        for (int i = 0; i < n; ++i) {
            if (pos_ >= bits_) { err_ = true; return 0; }
            v = (v << 1) | ((data_[pos_ >> 3] >> (7 - (pos_ & 7))) & 1u);
            ++pos_;
        }
        return v;
    }
    // 4.10.3 uvlc()
    uint32_t uvlc() {
        int leadingZeros = 0;
        while (true) {
            if (f(1)) break;
            if (err_) return 0;
            if (++leadingZeros >= 32) return UINT32_MAX;
        }
        return f(leadingZeros) + (1u << leadingZeros) - 1u;
    }
    bool error() const { return err_; }

private:
    const uint8_t *data_;
    size_t bits_;
    size_t pos_ = 0;
    bool err_ = false;
};

inline size_t readLeb128(const uint8_t *data, size_t size, size_t at, uint64_t *out) {
    uint64_t value = 0;
    for (int i = 0; i < 8; ++i) {
        if (at >= size) return 0;
        const uint8_t byte = data[at++];
        value |= (uint64_t)(byte & 0x7f) << (i * 7);
        if (!(byte & 0x80)) { *out = value; return at; }
    }
    return 0;
}

inline bool parseSequenceHeader(const uint8_t *data, size_t size, SequenceHeader *out) {
    *out = SequenceHeader();
    BitReader r(data, size);
    r.f(3);                              // seq_profile
    r.f(1);                              // still_picture
    if (r.f(1)) return false;
    if (r.f(1)) {                        // timing_info_present_flag
        r.f(32);                         // num_units_in_display_tick
        r.f(32);                         // time_scale
        if (r.f(1)) r.uvlc();            // equal_picture_interval / num_ticks…
        if (r.f(1)) return false;
    }
    const uint32_t initialDisplayDelayPresent = r.f(1);
    if (r.f(5) != 0) return false;
    out->operatingPointIdc = (int)r.f(12);
    if (r.f(5) > 7) r.f(1);              // seq_level_idx[0] / seq_tier[0]
    if (initialDisplayDelayPresent) {
        if (r.f(1)) r.f(4);              // initial_display_delay_present_for_this_op / minus_1
    }
    const int frameWidthBits = (int)r.f(4) + 1;
    const int frameHeightBits = (int)r.f(4) + 1;
    r.f(frameWidthBits);                 // max_frame_width_minus_1
    r.f(frameHeightBits);                // max_frame_height_minus_1
    if (r.f(1)) return false;
    r.f(1);                              // use_128x128_superblock
    r.f(1);                              // enable_filter_intra
    r.f(1);                              // enable_intra_edge_filter
    r.f(1);                              // enable_interintra_compound
    r.f(1);                              // enable_masked_compound
    r.f(1);                              // enable_warped_motion
    r.f(1);                              // enable_dual_filter
    const uint32_t enableOrderHint = r.f(1);
    if (enableOrderHint) {
        r.f(1);                          // enable_jnt_comp
        r.f(1);                          // enable_ref_frame_mvs
    }
    if (r.f(1)) {                        // seq_choose_screen_content_tools
        out->forceScreenContentTools = kSelect;
    } else {
        out->forceScreenContentTools = (int)r.f(1);
    }
    if (out->forceScreenContentTools > 0) {
        if (r.f(1)) out->forceIntegerMv = kSelect;   // seq_choose_integer_mv
        else out->forceIntegerMv = (int)r.f(1);
    } else {
        out->forceIntegerMv = kSelect;
    }
    out->orderHintBits = enableOrderHint ? (int)r.f(3) + 1 : 0;
    if (r.error()) return false;
    out->usable = true;
    return true;
}

inline bool parseFrameHeader(const uint8_t *data, size_t size, const SequenceHeader &seq,
                             FrameInfo *out) {
    *out = FrameInfo();
    if (!seq.usable) return false;
    BitReader r(data, size);
    if (r.f(1)) {                        // show_existing_frame
        r.f(3);                          // frame_to_show_map_idx
        out->showExisting = true;
        out->showFrame = true;
        out->refreshFrameFlags = -1;
        return !r.error();
    }
    const int frameType = (int)r.f(2);
    const bool frameIsIntra = (frameType == kFrameKey || frameType == kFrameIntraOnly);
    const bool showFrame = r.f(1) != 0;
    if (!showFrame) r.f(1);              // showable_frame
    const bool errorResilient =
        (frameType == kFrameSwitch || (frameType == kFrameKey && showFrame)) ? true
                                                                            : (r.f(1) != 0);
    r.f(1);                              // disable_cdf_update
    int allowScreenContentTools = seq.forceScreenContentTools;
    if (seq.forceScreenContentTools == kSelect) allowScreenContentTools = (int)r.f(1);
    if (allowScreenContentTools) {
        if (seq.forceIntegerMv == kSelect) r.f(1);   // force_integer_mv
    }
    if (frameType != kFrameSwitch) r.f(1);           // frame_size_override_flag
    r.f(seq.orderHintBits);                          // order_hint
    if (!(frameIsIntra || errorResilient)) r.f(3);   // primary_ref_frame
    out->frameType = frameType;
    out->showFrame = showFrame;
    if (frameType == kFrameSwitch || (frameType == kFrameKey && showFrame)) {
        out->refreshFrameFlags = 0xff;
    } else {
        out->refreshFrameFlags = (int)r.f(8);
    }
    return !r.error();
}

inline ScanResult scanTemporalUnit(const uint8_t *tu, size_t len, SequenceHeader *seq) {
    ScanResult result;
    if (!tu || len == 0 || !seq) return result;

    size_t at = 0;
    long firstDropped = -1;
    bool keptAfterDrop = false;
    bool droppingTiles = false;
    bool prefixHasSequenceHeader = false;
    int keptFrames = 0;
    int obuCount = 0;

    while (at < len) {
        if (++obuCount > kMaxObusPerTemporalUnit) return result;
        const size_t obuStart = at;
        const uint8_t header = tu[at];
        if (header & 0x80) return result;             // obu_forbidden_bit
        const int type = (header >> 3) & 0xf;
        const bool hasExtension = ((header >> 2) & 1) != 0;
        const bool hasSizeField = ((header >> 1) & 1) != 0;
        ++at;
        if (hasExtension) {
            if (at >= len) return result;
            ++at;                                     // temporal_id / spatial_id / reserved
        }
        if (!hasSizeField) return result;
        uint64_t payloadSize = 0;
        const size_t payloadAt = readLeb128(tu, len, at, &payloadSize);
        if (payloadAt == 0) return result;
        if (payloadSize > len - payloadAt) return result;
        const uint8_t *payload = tu + payloadAt;
        at = payloadAt + (size_t)payloadSize;

        bool dropThisObu = false;
        switch (type) {
            case kObuSequenceHeader: {
                if (!parseSequenceHeader(payload, (size_t)payloadSize, seq)) return result;
                droppingTiles = false;
                prefixHasSequenceHeader = true;
                break;
            }
            case kObuFrameHeader:
            case kObuFrame:
            case kObuRedundantFrameHeader: {
                if (!seq->usable) return result;
                if (hasExtension && seq->operatingPointIdc != 0) return result;
                FrameInfo info;
                if (!parseFrameHeader(payload, (size_t)payloadSize, *seq, &info)) return result;
                if (type != kObuRedundantFrameHeader) {
                    ++result.frames;
                    droppingTiles = !info.showExisting && info.refreshFrameFlags == 0;
                    if (!droppingTiles) ++keptFrames;
                    if (!info.showExisting && info.frameType == kFrameKey && info.showFrame) {
                        result.sawKeyFrame = true;
                    }
                }
                dropThisObu = droppingTiles;
                break;
            }
            case kObuTileGroup:
                dropThisObu = droppingTiles;
                break;
            case kObuTemporalDelimiter:
            case kObuMetadata:
            case kObuPadding:
                break;
            default:
                return result;
        }

        if (dropThisObu) {
            if (firstDropped < 0) firstDropped = (long)obuStart;
            if (type == kObuFrameHeader || type == kObuFrame) ++result.droppedFrames;
        } else if (firstDropped >= 0) {
            keptAfterDrop = true;
        }
    }

    if (at != len) return result;
    result.structureOk = true;
    if (result.frames == 0) return result;
    if (firstDropped < 0) return result;
    if (keptAfterDrop) return result;

    if (keptFrames == 0 && !prefixHasSequenceHeader) {
        result.action = Action::DropPacket;
        result.keepBytes = 0;
        return result;
    }
    if (firstDropped == 0) return result;
    result.keepBytes = (int)firstDropped;
    result.action = Action::TruncateToPrefix;
    return result;
}

inline bool parseAv1CodecConfigRecord(const uint8_t *extradata, size_t size,
                                      SequenceHeader *seq) {
    if (!extradata || size <= 4 || !seq) return false;
    if ((extradata[0] & 0x80) == 0) return false;
    ScanResult scan = scanTemporalUnit(extradata + 4, size - 4, seq);
    (void)scan;
    return seq->usable;
}

}  // namespace spav1
