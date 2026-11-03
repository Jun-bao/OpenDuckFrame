// Fault-only, bounded reconstruction of a closed H.26x GOP from the current
// source view. The playback demuxer, audio queue and clocks are never rewound.
#pragma once
#include "SPSourceInput.hpp"
#include "SPResilience.hpp"
#include <memory>
#include <vector>

namespace sptrial {
struct PacketIdentity {
    int64_t pos = -1, pts = AV_NOPTS_VALUE, dts = AV_NOPTS_VALUE;
    int size = 0, stream = -1;
    static PacketIdentity from(const AVPacket* p) { return {p->pos, p->pts, p->dts, p->size, p->stream_index}; }
    bool matches(const AVPacket* p) const {
        return pos == p->pos && pts == p->pts && dts == p->dts && size == p->size && stream == p->stream_index;
    }
    bool valid() const { return pos >= 0 && size > 0 && stream >= 0 && (dts != AV_NOPTS_VALUE || pts != AV_NOPTS_VALUE); }
    bool shiftTicks(int64_t offset) {
        for (int64_t* ts : {&pts, &dts}) if (*ts != AV_NOPTS_VALUE) {
            if ((offset > 0 && *ts > INT64_MAX - offset) || (offset < 0 && *ts < INT64_MIN - offset)) { pos = -1; return false; }
            *ts += offset;
        }
        return true;
    }
};
struct PacketDelete { void operator()(AVPacket* p) const { av_packet_free(&p); } };
using OwnedPacket = std::unique_ptr<AVPacket, PacketDelete>;
struct GopReadback {
    std::vector<OwnedPacket> packets;
    int64_t bytesRead = 0;
    size_t retainedBytes = 0;
    bool matched = false;
};
inline size_t replayPacketBytes(const AVPacket* p) {
    if (!p || p->size < 0) return SIZE_MAX;
    size_t bytes = static_cast<size_t>(p->size);
    for (int i = 0; i < p->side_data_elems; ++i) {
        if (p->side_data[i].size > SIZE_MAX - bytes) return SIZE_MAX;
        bytes += p->side_data[i].size;
    }
    return bytes;
}
inline bool sameReplayConfig(const AVCodecParameters* a, const AVCodecParameters* b) {
    return a && b && a->codec_type == AVMEDIA_TYPE_VIDEO && b->codec_type == AVMEDIA_TYPE_VIDEO &&
        a->codec_id == b->codec_id && a->width == b->width && a->height == b->height &&
        a->extradata_size > 0 && a->extradata_size == b->extradata_size &&
        std::memcmp(a->extradata, b->extradata, a->extradata_size) == 0;
}
// First version accepts container-delimited avcC/hvcC streams only. In-band
// parameter sets need their own configuration proof; a KEY flag is never proof
// of a closed reference chain. CRA/BLA/RASL and data partitions are excluded.
inline bool replayNalTypes(const AVPacket* p, const spresil::BitstreamLayout& layout, bool requireIdr, bool allowBrokenTail = false) {
    if (layout.kind != spresil::Bitstream::LengthPrefixed || layout.nalLengthSize < 1 || layout.nalLengthSize > 4 ||
        !p->data || p->size <= 0) return false;
    size_t pos = 0, n = static_cast<size_t>(p->size); bool vcl = false;
    while (pos < n) {
        if (n - pos < static_cast<size_t>(layout.nalLengthSize)) return allowBrokenTail && !requireIdr;
        uint32_t count = 0;
        for (int i = 0; i < layout.nalLengthSize; ++i) count = (count << 8) | p->data[pos++];
        if (count < (layout.hevc ? 2u : 1u) || count > n - pos) return allowBrokenTail && !requireIdr;
        const uint8_t h = p->data[pos];
        if (h & 0x80) return false;
        const int type = layout.hevc ? (h >> 1) & 63 : h & 31;
        if (layout.hevc) {
            const int layer = ((h & 1) << 5) | (p->data[pos + 1] >> 3);
            if (layer != 0 || (p->data[pos + 1] & 7) == 0 ||
                !(type <= 7 || type == 19 || type == 20 || (type >= 35 && type <= 40))) return false;
            if (type <= 31) { if (requireIdr && type != 19 && type != 20) return false; vcl = true; }
        } else {
            if (!(type == 1 || type == 5 || type == 6 || (type >= 9 && type <= 12))) return false;
            if (type == 1 || type == 5) { if (requireIdr && type != 5) return false; vcl = true; }
        }
        pos += count;
    }
    return !requireIdr || vcl;
}
inline GopReadback readClosedGop(sp::ReadSourceView view, const AVInputFormat* format,
                                 const PacketIdentity& key, const PacketIdentity& trigger,
                                 const AVCodecParameters* config, AVRational timeBase,
                                 const spresil::BitstreamLayout& layout, const AVPacket* derivedTrigger,
                                 int64_t timestampOffsetTicks, const InterruptCtx& interrupt) {
    GopReadback result;
    try {
        if (!view || !format || !key.valid() || !trigger.valid() || key.stream != trigger.stream ||
            trigger.pos < key.pos || !derivedTrigger || !config ||
            (config->codec_id != AV_CODEC_ID_H264 && config->codec_id != AV_CODEC_ID_HEVC)) return result;
        if (!config->extradata || config->extradata_size < (layout.hevc ? 23 : 7) || config->extradata[0] != 1) return result;
        const int profile = layout.hevc ? config->extradata[1] & 31 : config->extradata[1];
        if (layout.hevc ? (profile < 1 || profile > 3) :
            (profile != 66 && profile != 77 && profile != 88 && profile != 100)) return result;
        SourceInput input(view, interrupt, 128ll * 1024 * 1024);
        if (input.open(format) < 0) return result;
        AVFormatContext* fc = input.get();
        if (static_cast<unsigned>(key.stream) >= fc->nb_streams) return result;
        if (std::strstr(format->name, "matroska")) {
            // Matroska does not carry DTS. FFmpeg needs stream analysis to
            // establish its B-frame delay before it can reproduce the main
            // demuxer's inferred DTS. Keep exact identity, including NOPTS.
            fc->probesize = 8ll * 1024 * 1024;
            fc->max_analyze_duration = 500000;
            for (unsigned i = 0; i < fc->nb_streams; ++i)
                if (static_cast<int>(i) != key.stream) fc->streams[i]->discard = AVDISCARD_ALL;
            if (avformat_find_stream_info(fc, nullptr) < 0 || !input.usable()) return result;
        }
        AVStream* st = fc->streams[key.stream];
        if (st->time_base.num != timeBase.num || st->time_base.den != timeBase.den || !sameReplayConfig(config, st->codecpar)) return result;
        const int64_t seekTs = key.dts != AV_NOPTS_VALUE ? key.dts : key.pts;
        if (avformat_seek_file(fc, key.stream, INT64_MIN, seekTs, seekTs, AVSEEK_FLAG_BACKWARD) < 0) return result;
        OwnedPacket packet(av_packet_alloc());
        if (!packet) return result;
        bool started = false;
        int videoPackets = 0;
        int64_t previousPos = -1;
        const int64_t offset = timestampOffsetTicks;
        for (int any = 0; any < 4096 && input.usable(); ++any) {
            if (av_read_frame(fc, packet.get()) < 0) break;
            if (packet->stream_index != key.stream) { av_packet_unref(packet.get()); continue; }
            if (++videoPackets > 600) break;
            if (!started) {
                if (!key.matches(packet.get())) break; // No approximate key substitution.
                if (!(packet->flags & AV_PKT_FLAG_KEY) || !replayNalTypes(packet.get(), layout, true)) break;
                started = true;
            } else if (packet->flags & AV_PKT_FLAG_KEY) break;
            if (packet->pos < 0 || packet->pos <= previousPos || packet->pos > trigger.pos) break;
            previousPos = packet->pos;
            if (av_packet_get_side_data(packet.get(), AV_PKT_DATA_NEW_EXTRADATA, nullptr)) break;
            if (!replayNalTypes(packet.get(), layout, false, true)) break;
            const bool final = trigger.matches(packet.get());
            if (packet->pos == trigger.pos && !final) break;
            OwnedPacket candidate;
            if (final) {
                candidate.reset(av_packet_clone(derivedTrigger));
            } else {
                const auto inspection = spresil::inspect(packet->data, packet->size, layout);
                if (!spresil::deliverable(inspection)) { av_packet_unref(packet.get()); continue; }
                if (inspection.resyncFrom > 0 && inspection.resyncFrom < static_cast<size_t>(packet->size)) {
                    if (av_packet_make_writable(packet.get()) < 0) break;
                    const size_t tail = packet->size - inspection.resyncFrom;
                    std::memmove(packet->data + inspection.safePrefix, packet->data + inspection.resyncFrom, tail);
                    av_shrink_packet(packet.get(), static_cast<int>(inspection.safePrefix + tail));
                } else if (inspection.tailBroken && inspection.safePrefix < static_cast<size_t>(packet->size)) {
                    av_shrink_packet(packet.get(), static_cast<int>(inspection.safePrefix));
                }
                if (!replayNalTypes(packet.get(), layout, false)) break;
                // The caller supplies a known constant mapping, never a newly
                // inferred epoch. Reject arithmetic overflow rather than wrap.
                bool safe = true;
                for (int64_t* ts : {&packet->pts, &packet->dts}) if (*ts != AV_NOPTS_VALUE) {
                    if ((offset > 0 && *ts > INT64_MAX - offset) || (offset < 0 && *ts < INT64_MIN - offset)) { safe = false; break; }
                    *ts += offset;
                }
                if (!safe) break;
                candidate.reset(av_packet_clone(packet.get()));
            }
            if (!candidate || !replayNalTypes(candidate.get(), layout, false)) break;
            const size_t bytes = replayPacketBytes(candidate.get());
            if (bytes > 64u * 1024 * 1024 - result.retainedBytes) break;
            result.retainedBytes += bytes;
            result.packets.push_back(std::move(candidate));
            av_packet_unref(packet.get());
            if (final) { result.matched = input.usable() && sameReplayConfig(config, st->codecpar); break; }
        }
        result.bytesRead = input.bytesRead();
        if (!result.matched) { result.packets.clear(); result.retainedBytes = 0; }
    } catch (const std::bad_alloc&) { result = {}; }
    return result;
}
} // namespace sptrial
