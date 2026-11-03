// OpenDuckFrame - unified dispatch for packet-level fixes on the decode thread (input: codec lane + packet bytes; output: fix plans; pure, unit-testable)
//
// The ProRes / MJPEG / VP8 / VP9 lanes used to each decide, make the packet writable, patch bytes, count and log inside
// the decode loop. The decision and the bytes to change now live here; the decode thread applies plans in order, keeps
// its own counters and logs, and handles dropHard. The AV1 sequence-header copy (session state) and the MPEG start-code
// prefix (layout-dependent inspection) stay where they were. Stateful budgets are passed in; this header holds no state.
#pragma once

#include "SPResilience.hpp"

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace sp {

enum class PacketCodecLane : uint8_t { None = 0, ProRes, Mjpeg, Vp8, Vp9 };

enum class PacketFixKind : uint8_t {
    ProResFrameSize = 1,
    ProResGeometry,
    ProResDropHard,
    JpegDhtCounts,
    JpegSegmentLengths,
    Vp8KeyframeSync,
    Vp9FixedFields,
    Vp9SuperframeMarker,
};

struct PacketFixPlan {
    PacketFixKind kind;
    std::vector<spresil::ByteFix> fixes;
    bool dropHard = false;
    std::string what;
    size_t count = 0;
};

inline std::vector<PacketFixPlan> planPacketFixes(PacketCodecLane lane, const uint8_t* d, size_t n, int proresDropBudgetLeft) {
    std::vector<PacketFixPlan> plans;
    if (!d) return plans;
    switch (lane) {
    case PacketCodecLane::None:
        break;
    case PacketCodecLane::ProRes: {
        if (n <= 36 || proresDropBudgetLeft <= 0) break;
        const spresil::ProresFrameInfo pinfo = spresil::proresInspectFrame(d, n);
        spresil::ByteFix sz;
        if (pinfo.ok && spresil::proresFrameSizeFieldFix(d, n, sz)) {
            plans.push_back({PacketFixKind::ProResFrameSize, {sz}, false, "frame_size", 1});
        } else if (pinfo.parsed && !pinfo.ok && !pinfo.slackOnly) {
            spresil::ByteFix fx; std::string what;
            if (spresil::proresFrameGeometryFix(d, n, fx, &what)) plans.push_back({PacketFixKind::ProResGeometry, {fx}, false, what, 1});
            else if (pinfo.hard) plans.push_back({PacketFixKind::ProResDropHard, {}, true, "geometry-out-of-range", 0});
        }
        break;
    }
    case PacketCodecLane::Mjpeg: {

        if (n <= 4) break;
        std::vector<spresil::ByteFix> countFixes;
        if (spresil::jpegRepairDhtCounts(d, n, countFixes) && !countFixes.empty())
            plans.push_back({PacketFixKind::JpegDhtCounts, countFixes, false, "", countFixes.size()});
        std::vector<spresil::JpegLengthFix> lens;
        if (spresil::jpegRepairSegmentLengths(d, n, lens) && !lens.empty()) {
            PacketFixPlan p{PacketFixKind::JpegSegmentLengths, {}, false, "", lens.size()};
            for (const spresil::JpegLengthFix& fx : lens) {
                p.fixes.push_back({fx.at, (uint8_t)(fx.len >> 8)});
                p.fixes.push_back({fx.at + 1, (uint8_t)fx.len});
            }
            plans.push_back(std::move(p));
        }
        break;
    }
    case PacketCodecLane::Vp8: {
        if (n <= 10) break;
        spresil::ByteFix fx;
        if (spresil::vp8KeyframeSyncFix(d, n, fx)) plans.push_back({PacketFixKind::Vp8KeyframeSync, {fx}, false, "sync", 1});
        break;
    }
    case PacketCodecLane::Vp9: {
        if (n > 10) {
            std::vector<spresil::ByteFix> fxs;
            if (spresil::vp9PacketFixedFieldFixes(d, n, fxs) && !fxs.empty())
                plans.push_back({PacketFixKind::Vp9FixedFields, fxs, false, fxs[0].at == 0 ? "frame_marker" : "sync", fxs.size()});
        }
        if (n > 4) {
            spresil::Vp9SuperframeFix fx;
            if (spresil::vp9SuperframeIndexCandidate(d, n, fx)) {
                PacketFixPlan p{PacketFixKind::Vp9SuperframeMarker, {}, false, fx.fixEnd ? "end" : "start", 1};
                if (fx.fixEnd) p.fixes.push_back({n - 1, fx.marker});
                if (fx.fixStart) p.fixes.push_back({n - fx.idxLen, fx.marker});
                plans.push_back(std::move(p));
            }
        }
        break;
    }
    }
    return plans;
}

inline size_t applyPacketFixes(uint8_t* d, size_t n, const PacketFixPlan& plan) {
    size_t applied = 0;
    for (const spresil::ByteFix& fx : plan.fixes) {
        if (fx.at < n) { d[fx.at] = fx.value; ++applied; }
    }
    return applied;
}

} // namespace sp
