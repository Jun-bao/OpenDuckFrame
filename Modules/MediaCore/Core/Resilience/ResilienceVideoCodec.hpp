// OpenDuckFrame - resilient playback: video codec parameter-set and header evidence (avcC/hvcC bootstrap, VP8/VP9, MJPEG DHT, MP4 RAP/ctts, ProRes, TS Annex-B chains)
//
// Split out of the umbrella header by section; function bodies, constants and inline
// attributes are unchanged. Callers keep including the umbrella; this file only guarantees
// that it compiles on its own.
#pragma once

#include "ResilienceOpenDiagnosis.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <functional>
#include <string>
#include <utility>
#include <vector>

namespace spresil {

struct H264ConfigBootstrap {
    bool ok = false;
    BitstreamLayout layout;
    std::vector<uint8_t> extradata;
    int spsCount = 0, ppsCount = 0;
};

template <class Fn>
inline bool avccForEachParamSet(const uint8_t* e, int n, Fn&& fn) {
    if (!e || n < 7 || e[0] != 1) return false;
    size_t off = 5;
    const int numSps = e[off++] & 0x1f;
    if (numSps == 0) return false;
    for (int i = 0; i < numSps; ++i) {
        if (off + 2 > (size_t)n) return false;
        const size_t len = be16(e + off);
        off += 2;
        if (len == 0 || off + len > (size_t)n || !fn(e + off, len, true)) return false;
        off += len;
    }
    if (off >= (size_t)n) return false;
    const int numPps = e[off++];
    if (numPps == 0) return false;
    for (int i = 0; i < numPps; ++i) {
        if (off + 2 > (size_t)n) return false;
        const size_t len = be16(e + off);
        off += 2;
        if (len == 0 || off + len > (size_t)n || !fn(e + off, len, false)) return false;
        off += len;
    }
    return true;
}

inline bool avccRecordValid(const uint8_t* e, int n) {
    return avccForEachParamSet(e, n, [](const uint8_t* nal, size_t, bool sps) { return (nal[0] & 0x1f) == (sps ? 7 : 8); });
}

namespace detail {

struct H264SpsInfo {
    bool ok = false;
    uint32_t chroma = 1;
    uint32_t wMbs = 0, hMap = 0;
    bool frameMbsOnly = true;
    uint32_t cropL = 0, cropR = 0, cropT = 0, cropB = 0;
    bool timing = false;
    uint32_t numUnitsInTick = 0, timeScale = 0;
};
inline H264SpsInfo parseH264Sps(const uint8_t* nal, size_t len) {
    H264SpsInfo s;
    if (!nal || len < 4 || (nal[0] & 0x1f) != 7) return s;
    H264BitReader br(nal + 1, len - 1, 512);
    const uint32_t profile = br.bits(8);
    br.bits(8); br.bits(8); br.ue();
    if (profile == 100 || profile == 110 || profile == 122 || profile == 244 || profile == 44 || profile == 83 || profile == 86 ||
        profile == 118 || profile == 128 || profile == 138 || profile == 139 || profile == 134 || profile == 135) {
        s.chroma = br.ue();
        if (s.chroma == 3) br.bits(1);
        br.ue(); br.ue(); br.bits(1);
        if (br.bits(1)) {
            for (int i = 0; i < (s.chroma != 3 ? 8 : 12) && !br.bad; ++i) {
                if (!br.bits(1)) continue;
                const int sz = i < 6 ? 16 : 64;
                int last = 8, next = 8;
                for (int j = 0; j < sz && !br.bad; ++j) {
                    if (next != 0) { const int32_t delta = br.se(); next = (last + delta + 256) % 256; }
                    last = next == 0 ? last : next;
                }
            }
        }
    }
    br.ue(); // log2_max_frame_num
    const uint32_t pocType = br.ue();
    if (pocType == 0) br.ue();
    else if (pocType == 1) {
        br.bits(1); br.se(); br.se();
        const uint32_t cycle = br.ue();
        if (cycle > 255) return s;
        for (uint32_t i = 0; i < cycle && !br.bad; ++i) br.se();
    }
    br.ue(); br.bits(1);
    s.wMbs = br.ue() + 1; s.hMap = br.ue() + 1;
    s.frameMbsOnly = br.bits(1) != 0;
    if (!s.frameMbsOnly) br.bits(1); // mb_adaptive
    br.bits(1);
    if (br.bits(1)) { s.cropL = br.ue(); s.cropR = br.ue(); s.cropT = br.ue(); s.cropB = br.ue(); }
    if (br.bad) return s;
    s.ok = true;
    if (!br.bits(1)) return s; // vui_parameters_present
    if (br.bits(1)) { if (br.bits(8) == 255) { br.bits(16); br.bits(16); } }
    if (br.bits(1)) br.bits(1);
    if (br.bits(1)) { br.bits(3); br.bits(1); if (br.bits(1)) { br.bits(8); br.bits(8); br.bits(8); } }
    if (br.bits(1)) { br.ue(); br.ue(); }
    if (br.bad || !br.bits(1)) return s; // timing_info_present
    s.numUnitsInTick = br.bits(32);
    s.timeScale = br.bits(32);
    s.timing = !br.bad && s.numUnitsInTick > 0 && s.timeScale > 0;
    return s;
}
} // namespace detail

inline bool h264SpsTiming(const uint8_t* nal, size_t len, uint32_t& numUnitsInTick, uint32_t& timeScale) {
    const detail::H264SpsInfo s = detail::parseH264Sps(nal, len);
    if (!s.timing) return false;
    numUnitsInTick = s.numUnitsInTick;
    timeScale = s.timeScale;
    return true;
}

inline bool h264SpsDims(const uint8_t* nal, size_t len, int& width, int& height) {
    const detail::H264SpsInfo s = detail::parseH264Sps(nal, len);
    if (!s.ok || s.chroma > 3 || s.wMbs > 1024 || s.hMap > 1024) return false;
    const uint32_t cux = s.chroma == 0 ? 1 : (s.chroma == 3 ? 1 : 2);
    const uint32_t cuy = (s.chroma == 0 ? 1 : (s.chroma == 1 ? 2 : 1)) * (s.frameMbsOnly ? 1 : 2);
    const int64_t w = (int64_t)s.wMbs * 16 - (int64_t)(s.cropL + s.cropR) * cux;
    const int64_t h = (int64_t)(s.frameMbsOnly ? 1 : 2) * s.hMap * 16 - (int64_t)(s.cropT + s.cropB) * cuy;
    if (w <= 0 || h <= 0 || w > 16384 || h > 16384) return false;
    width = (int)w; height = (int)h;
    return true;
}

inline bool hevcSpsTiming(const uint8_t* n, size_t len, uint32_t& numUnitsInTick, uint32_t& timeScale) {
    if (!n || len < 16 || ((n[0] >> 1) & 0x3f) != 33) return false;
    detail::H264BitReader br(n + 2, len - 2, 1024);
    br.bits(4);
    const int maxSub = (int)br.bits(3);
    br.bits(1);
    for (int i = 0; i < 12; ++i) br.bits(8);
    bool prof[8] = {}, lev[8] = {};
    for (int i = 0; i < maxSub; ++i) { prof[i] = br.bits(1) != 0; lev[i] = br.bits(1) != 0; }
    if (maxSub > 0) for (int i = maxSub; i < 8; ++i) br.bits(2);
    for (int i = 0; i < maxSub; ++i) { if (prof[i]) br.skip(88); if (lev[i]) br.skip(8); }
    br.ue();
    const uint32_t chroma = br.ue();
    if (chroma == 3) br.bits(1);
    br.ue(); br.ue();
    if (br.bits(1)) { br.ue(); br.ue(); br.ue(); br.ue(); }
    br.ue(); br.ue();
    const uint32_t log2MaxPocLsb = br.ue() + 4;
    const bool subLayerOrdering = br.bits(1) != 0;
    for (int i = subLayerOrdering ? 0 : maxSub; i <= maxSub; ++i) { br.ue(); br.ue(); br.ue(); }
    br.ue(); br.ue(); br.ue(); br.ue(); br.ue(); br.ue();
    if (br.bits(1) && br.bits(1)) { // scaling_list_enabled + sps_scaling_list_data_present
        for (int sizeId = 0; sizeId < 4 && !br.bad; ++sizeId) {
            for (int matrixId = 0; matrixId < 6 && !br.bad; matrixId += (sizeId == 3) ? 3 : 1) {
                if (!br.bits(1)) { br.ue(); continue; }
                const int coefNum = std::min(64, 1 << (4 + (sizeId << 1)));
                if (sizeId > 1) br.se();
                for (int i = 0; i < coefNum && !br.bad; ++i) br.se();
            }
        }
    }
    br.bits(1); br.bits(1);
    if (br.bits(1)) { br.bits(4); br.bits(4); br.ue(); br.ue(); br.bits(1); }
    const uint32_t numSets = br.ue();
    if (br.bad || numSets > 64) return false;
    std::vector<int> numDeltaPocs(numSets, 0);
    for (uint32_t idx = 0; idx < numSets && !br.bad; ++idx) {
        bool inter = false;
        if (idx != 0) inter = br.bits(1) != 0;
        if (inter) {
            br.bits(1); br.ue();
            const int refN = numDeltaPocs[idx - 1];
            int cnt = 0;
            for (int j = 0; j <= refN && !br.bad; ++j) {
                const bool used = br.bits(1) != 0;
                bool useDelta = true;
                if (!used) useDelta = br.bits(1) != 0;
                if (used || useDelta) ++cnt;
            }
            numDeltaPocs[idx] = cnt;
        } else {
            const uint32_t neg = br.ue(), pos = br.ue();
            if (neg > 16 || pos > 16) return false;
            for (uint32_t i = 0; i < neg && !br.bad; ++i) { br.ue(); br.bits(1); }
            for (uint32_t i = 0; i < pos && !br.bad; ++i) { br.ue(); br.bits(1); }
            numDeltaPocs[idx] = (int)(neg + pos);
        }
    }
    if (br.bits(1)) { // long_term_ref_pics_present
        const uint32_t nlt = br.ue();
        if (nlt > 32) return false;
        for (uint32_t i = 0; i < nlt && !br.bad; ++i) { br.bits((int)log2MaxPocLsb); br.bits(1); }
    }
    br.bits(1); br.bits(1);
    if (br.bad || !br.bits(1)) return false; // vui_parameters_present
    if (br.bits(1)) { if (br.bits(8) == 255) { br.bits(16); br.bits(16); } }
    if (br.bits(1)) br.bits(1);
    if (br.bits(1)) { br.bits(3); br.bits(1); if (br.bits(1)) { br.bits(8); br.bits(8); br.bits(8); } }
    if (br.bits(1)) { br.ue(); br.ue(); }
    br.bits(1); br.bits(1); br.bits(1);
    if (br.bits(1)) { br.ue(); br.ue(); br.ue(); br.ue(); }
    if (br.bad || !br.bits(1)) return false; // vui_timing_info_present
    numUnitsInTick = br.bits(32);
    timeScale = br.bits(32);
    return !br.bad && numUnitsInTick > 0 && timeScale > 0;
}

inline int h264SliceType(const uint8_t* nal, size_t len) {
    if (!nal || len < 2) return -1;
    const int type = nal[0] & 0x1f;
    if (!(type >= 1 && type <= 5)) return -1;
    detail::H264BitReader br(nal + 1, len - 1);
    br.ue();
    const uint32_t st = br.ue();
    return (br.bad || st > 9) ? -1 : (int)st;
}

inline bool h264PpsEntropyBit(const uint8_t* nal, size_t len, size_t& byteAt, uint8_t& mask) {
    if (!nal || len < 3 || (nal[0] & 0x1f) != 8) return false;
    for (size_t i = 1; i + 2 < len && i < 5; ++i) if (nal[i] == 0 && nal[i + 1] == 0 && nal[i + 2] == 3) return false;
    detail::H264BitReader br(nal + 1, len - 1, 8);
    const uint32_t ppsId = br.ue(), spsId = br.ue();
    if (br.bad || ppsId > 255 || spsId > 31 || br.pos >= 24) return false;
    byteAt = 1 + (br.pos >> 3);
    mask = (uint8_t)(0x80 >> (br.pos & 7));
    return byteAt < len;
}

inline bool hevcPpsSliceFields(const uint8_t* nal, size_t len, uint32_t& ppsId, bool& dependentEnabled, int& extraBits) {
    if (!nal || len < 3 || ((nal[0] >> 1) & 0x3f) != 34) return false;
    detail::H264BitReader br(nal + 2, len - 2, 16);
    ppsId = br.ue(); br.ue();
    dependentEnabled = br.bits(1) != 0;
    br.bits(1); // output_flag_present_flag
    extraBits = (int)br.bits(3);
    return !br.bad && ppsId <= 63;
}

inline int hevcFirstSliceType(const uint8_t* nal, size_t len, const std::vector<std::pair<uint32_t, int>>& ppsExtraBits) {
    if (!nal || len < 4) return -1;
    const int type = (nal[0] >> 1) & 0x3f;
    if (type > 21) return -1;
    detail::H264BitReader br(nal + 2, len - 2, 16);
    if (br.bits(1) != 1) return -1;
    if (type >= 16 && type <= 23) br.bits(1);
    const uint32_t ppsId = br.ue();
    int extra = -1;
    for (const auto& p : ppsExtraBits) if (p.first == ppsId) extra = p.second;
    if (br.bad || extra < 0) return -1;
    br.skip((size_t)extra);
    const uint32_t st = br.ue();
    return (br.bad || st > 2) ? -1 : (int)st;
}

namespace detail {

struct H264ParamEvidence {
    std::vector<std::pair<uint32_t, std::vector<uint8_t>>> sps;
    std::vector<std::pair<uint32_t, uint32_t>> pps;              // pps_id → sps_id
    std::vector<std::vector<uint8_t>> ppsBytes;
    int idr = 0, vcl = 0, badRef = 0;
    void addNal(const uint8_t* n, size_t len) {
        if (len < 2) return;
        const int type = n[0] & 0x1f;
        if (type == 7) {
            H264BitReader br(n + 1, len - 1);
            br.bits(24); // profile_idc / constraint / level_idc
            const uint32_t id = br.ue();
            if (!br.bad) sps.push_back({id, std::vector<uint8_t>(n, n + len)});
        } else if (type == 8) {
            H264BitReader br(n + 1, len - 1);
            const uint32_t ppsId = br.ue(), spsId = br.ue();
            if (!br.bad) { pps.push_back({ppsId, spsId}); ppsBytes.push_back(std::vector<uint8_t>(n, n + len)); }
        } else if (type >= 1 && type <= 5) {
            ++vcl;
            if (type == 5) ++idr;
            H264BitReader br(n + 1, len - 1);
            br.ue(); br.ue(); // first_mb_in_slice, slice_type
            const uint32_t ppsId = br.ue();
            bool known = false;
            for (auto& p : pps) if (p.first == ppsId) known = true;
            if (br.bad || !known) ++badRef;
        }
    }
    bool consistent() const {
        if (sps.empty() || pps.empty() || idr == 0 || badRef > 0) return false;
        for (auto& p : pps) {
            bool ok = false;
            for (auto& sp : sps) if (sp.first == p.second) ok = true;
            if (!ok) return false;
        }
        return true;
    }
};
} // namespace detail

inline H264ConfigBootstrap bootstrapH264Config(const uint8_t* d, size_t n, const uint8_t* extradata, int extradataSize) {
    H264ConfigBootstrap out;
    if (!d || n < 8) return out;
    struct Cand { BitstreamLayout layout; detail::H264ParamEvidence ev; };
    std::vector<Cand> cands;
    for (int lenSize = 4; lenSize >= 1; --lenSize) {
        const PacketInspection pi = inspectLengthPrefixed(d, n, lenSize, false);
        if (pi.structure != PacketStructure::Intact || pi.units < 2 || !pi.hasVcl) continue;
        detail::H264ParamEvidence ev;
        size_t off = 0;
        while (off + (size_t)lenSize < n) {
            uint32_t len = 0;
            for (int i = 0; i < lenSize; ++i) len = (len << 8) | d[off + (size_t)i];
            off += (size_t)lenSize;
            ev.addNal(d + off, len);
            off += len;
        }
        if (ev.consistent()) cands.push_back({BitstreamLayout{Bitstream::LengthPrefixed, lenSize, false}, ev});
    }
    if (startsWithStartCode(d, n)) {
        detail::H264ParamEvidence ev;
        size_t i = 0;
        while (i + 3 < n) {
            size_t sc = n;
            for (size_t j = i; j + 2 < n; ++j) {
                if (d[j] == 0 && d[j + 1] == 0 && d[j + 2] == 1) { sc = j; break; }
            }
            if (sc >= n) break;
            const size_t nalStart = sc + 3;
            size_t nalEnd = n;
            for (size_t j = nalStart; j + 2 < n; ++j) {
                if (d[j] == 0 && d[j + 1] == 0 && (d[j + 2] == 1 || (j + 3 < n && d[j + 2] == 0 && d[j + 3] == 1))) { nalEnd = j; break; }
            }
            if (nalEnd > nalStart) ev.addNal(d + nalStart, nalEnd - nalStart);
            i = nalEnd;
        }
        if (ev.consistent()) cands.push_back({BitstreamLayout{Bitstream::StartCode, 4, false}, ev});
    }
    if (cands.empty()) return out;
    const Cand* pick = nullptr;
    if (cands.size() == 1) {
        pick = &cands[0];
    } else {

        const BitstreamLayout declared = classifyLayout(true, false, false, false, extradata, extradataSize);
        for (const Cand& c : cands) {
            if (c.layout.kind == declared.kind && (c.layout.kind != Bitstream::LengthPrefixed || c.layout.nalLengthSize == declared.nalLengthSize)) pick = &c;
        }
        if (!pick) return out;
    }
    out.layout = pick->layout;
    out.spsCount = (int)pick->ev.sps.size();
    out.ppsCount = (int)pick->ev.pps.size();
    if (pick->layout.kind == Bitstream::StartCode) {
        static const uint8_t sc4[4] = {0, 0, 0, 1};
        for (auto& sp : pick->ev.sps) { out.extradata.insert(out.extradata.end(), sc4, sc4 + 4); out.extradata.insert(out.extradata.end(), sp.second.begin(), sp.second.end()); }
        for (auto& pp : pick->ev.ppsBytes) { out.extradata.insert(out.extradata.end(), sc4, sc4 + 4); out.extradata.insert(out.extradata.end(), pp.begin(), pp.end()); }
    } else {
        const auto& sps0 = pick->ev.sps[0].second;
        if (sps0.size() < 4 || pick->ev.sps.size() > 31 || pick->ev.ppsBytes.size() > 255) return out;
        out.extradata = {1, sps0[1], sps0[2], sps0[3], (uint8_t)(0xFC | (pick->layout.nalLengthSize - 1)),
                         (uint8_t)(0xE0 | pick->ev.sps.size())};
        for (auto& sp : pick->ev.sps) {
            if (sp.second.size() > 0xFFFF) return out;
            out.extradata.push_back((uint8_t)(sp.second.size() >> 8)); out.extradata.push_back((uint8_t)sp.second.size());
            out.extradata.insert(out.extradata.end(), sp.second.begin(), sp.second.end());
        }
        out.extradata.push_back((uint8_t)pick->ev.ppsBytes.size());
        for (auto& pp : pick->ev.ppsBytes) {
            if (pp.size() > 0xFFFF) return out;
            out.extradata.push_back((uint8_t)(pp.size() >> 8)); out.extradata.push_back((uint8_t)pp.size());
            out.extradata.insert(out.extradata.end(), pp.begin(), pp.end());
        }
    }
    out.ok = true;
    return out;
}

inline bool h264ConfigSuspect(const uint8_t* extradata, int extradataSize, const uint8_t* pkt, size_t n) {
    if (extradata && extradataSize > 0 && !avccRecordValid(extradata, extradataSize) &&
        !startsWithStartCode(extradata, (size_t)extradataSize)) return true;
    const BitstreamLayout l = classifyLayout(true, false, false, false, extradata, extradataSize);
    if (l.kind == Bitstream::LengthPrefixed && pkt && n > 0) {
        const PacketInspection pi = inspectLengthPrefixed(pkt, n, l.nalLengthSize, false);
        return pi.structure != PacketStructure::Intact;
    }
    return false;
}

struct HevcConfigBootstrap {
    bool ok = false;
    BitstreamLayout layout;
    std::vector<uint8_t> extradata;
    int vpsCount = 0, spsCount = 0, ppsCount = 0;
};

template <class Fn>
inline bool hvccForEachNal(const uint8_t* e, int n, Fn&& fn) {
    if (!e || n < 23 || e[0] != 1) return false;
    size_t off = 22;
    const int arrays = e[off++];
    for (int a = 0; a < arrays; ++a) {
        if (off + 3 > (size_t)n) return false;
        const int type = e[off] & 0x3f;
        const size_t count = be16(e + off + 1);
        off += 3;
        for (size_t i = 0; i < count; ++i) {
            if (off + 2 > (size_t)n) return false;
            const size_t len = be16(e + off);
            off += 2;
            if (len < 2 || off + len > (size_t)n || !fn(type, e + off, len)) return false;
            off += len;
        }
    }
    return true;
}

inline bool hvccRecordValid(const uint8_t* e, int n) {
    bool sps = false, pps = false;
    if (!hvccForEachNal(e, n, [&](int type, const uint8_t* nal, size_t) {
            if (((nal[0] >> 1) & 0x3f) != type) return false;
            if (type == 33) sps = true;
            if (type == 34) pps = true;
            return true;
        })) return false;
    return e[22] == 0 || (sps && pps);
}

namespace detail {
struct HevcSpsInfo {
    bool ok = false;
    uint32_t id = 0;
    int maxSubLayersMinus1 = 0;
    bool nested = false;
    uint8_t ptl[12] = {0};
    int chroma = 1, width = 0, height = 0, bdLuma = 8, bdChroma = 8;

    uint32_t cropL = 0, cropR = 0, cropT = 0, cropB = 0;
    bool geomOk = false;
};

inline HevcSpsInfo parseHevcSps(const uint8_t* n, size_t len) {
    HevcSpsInfo s;
    if (len < 16) return s;
    H264BitReader br(n + 2, len - 2, 160);
    br.bits(4); // sps_video_parameter_set_id
    s.maxSubLayersMinus1 = (int)br.bits(3);
    s.nested = br.bits(1) != 0;
    for (int i = 0; i < 12; ++i) s.ptl[i] = (uint8_t)br.bits(8);
    bool prof[8] = {}, lev[8] = {};
    for (int i = 0; i < s.maxSubLayersMinus1; ++i) { prof[i] = br.bits(1) != 0; lev[i] = br.bits(1) != 0; }
    if (s.maxSubLayersMinus1 > 0) for (int i = s.maxSubLayersMinus1; i < 8; ++i) br.bits(2);
    for (int i = 0; i < s.maxSubLayersMinus1; ++i) { if (prof[i]) br.skip(88); if (lev[i]) br.skip(8); }
    s.id = br.ue();
    const uint32_t chroma = br.ue();
    s.chroma = (int)chroma;
    if (chroma == 3) br.bits(1);
    const uint32_t w = br.ue(), h = br.ue();
    s.width = (int)w; s.height = (int)h;
    if (br.bits(1)) { s.cropL = br.ue(); s.cropR = br.ue(); s.cropT = br.ue(); s.cropB = br.ue(); }
    s.geomOk = !br.bad && chroma <= 3 && w != 0 && h != 0 && w <= 16384 && h <= 16384;
    s.bdLuma = 8 + (int)br.ue(); s.bdChroma = 8 + (int)br.ue();
    s.ok = !br.bad && s.id <= 15 && s.chroma <= 3 && s.width > 0 && s.height > 0 && s.width <= 16384 && s.height <= 16384 &&
           s.bdLuma <= 16 && s.bdChroma <= 16;
    return s;
}

struct HevcParamEvidence {
    std::vector<std::vector<uint8_t>> vps, spsBytes, ppsBytes;
    std::vector<HevcSpsInfo> sps;
    std::vector<std::pair<uint32_t, uint32_t>> pps; // pps_id → sps_id
    int irap = 0, vcl = 0, badRef = 0, badHeader = 0;
    void addNal(const uint8_t* n, size_t len) {
        if (len < 2) { ++badHeader; return; }
        const int type = (n[0] >> 1) & 0x3f;
        if ((n[0] & 0x80) || (n[1] & 0x07) == 0) { ++badHeader; return; } // forbidden / temporal_id_plus1=0
        if (type == 32) vps.push_back(std::vector<uint8_t>(n, n + len));
        else if (type == 33) {
            HevcSpsInfo s = parseHevcSps(n, len);
            if (s.ok) { sps.push_back(s); spsBytes.push_back(std::vector<uint8_t>(n, n + len)); } else ++badRef;
        } else if (type == 34) {
            if (len < 3) { ++badRef; return; }
            H264BitReader br(n + 2, len - 2);
            const uint32_t ppsId = br.ue(), spsId = br.ue();
            if (!br.bad && ppsId <= 63 && spsId <= 15) { pps.push_back({ppsId, spsId}); ppsBytes.push_back(std::vector<uint8_t>(n, n + len)); }
            else ++badRef;
        } else if (type <= 31) {
            ++vcl;
            if (type >= 16 && type <= 21) ++irap;
            if (len < 3) { ++badRef; return; }
            H264BitReader br(n + 2, len - 2);
            br.bits(1); // first_slice_segment_in_pic_flag
            if (type >= 16 && type <= 23) br.bits(1); // no_output_of_prior_pics_flag
            const uint32_t ppsId = br.ue();
            bool known = false;
            for (auto& p : pps) if (p.first == ppsId) known = true;
            if (br.bad || !known) ++badRef;
        }
    }
    bool consistent() const {
        if (vps.empty() || sps.empty() || pps.empty() || irap == 0 || badRef > 0 || badHeader > 0) return false;
        for (auto& p : pps) {
            bool ok = false;
            for (auto& s : sps) if (s.id == p.second) ok = true;
            if (!ok) return false;
        }
        return true;
    }
};
} // namespace detail

inline HevcConfigBootstrap bootstrapHevcConfig(const uint8_t* d, size_t n, const uint8_t* extradata, int extradataSize) {
    HevcConfigBootstrap out;
    if (!d || n < 8) return out;
    struct Cand { BitstreamLayout layout; detail::HevcParamEvidence ev; };
    std::vector<Cand> cands;
    for (int lenSize = 4; lenSize >= 1; --lenSize) {
        const PacketInspection pi = inspectLengthPrefixed(d, n, lenSize, true);
        if (pi.structure != PacketStructure::Intact || pi.units < 2 || !pi.hasVcl) continue;
        detail::HevcParamEvidence ev;
        size_t off = 0;
        while (off + (size_t)lenSize < n) {
            uint32_t len = 0;
            for (int i = 0; i < lenSize; ++i) len = (len << 8) | d[off + (size_t)i];
            off += (size_t)lenSize;
            ev.addNal(d + off, len);
            off += len;
        }
        if (ev.consistent()) cands.push_back({BitstreamLayout{Bitstream::LengthPrefixed, lenSize, true}, ev});
    }
    if (startsWithStartCode(d, n)) {
        detail::HevcParamEvidence ev;
        size_t i = 0;
        while (i + 3 < n) {
            size_t sc = n;
            for (size_t j = i; j + 2 < n; ++j) {
                if (d[j] == 0 && d[j + 1] == 0 && d[j + 2] == 1) { sc = j; break; }
            }
            if (sc >= n) break;
            const size_t nalStart = sc + 3;
            size_t nalEnd = n;
            for (size_t j = nalStart; j + 2 < n; ++j) {
                if (d[j] == 0 && d[j + 1] == 0 && (d[j + 2] == 1 || (j + 3 < n && d[j + 2] == 0 && d[j + 3] == 1))) { nalEnd = j; break; }
            }
            if (nalEnd > nalStart) ev.addNal(d + nalStart, nalEnd - nalStart);
            i = nalEnd;
        }
        if (ev.consistent()) cands.push_back({BitstreamLayout{Bitstream::StartCode, 4, true}, ev});
    }
    if (cands.empty()) return out;
    const Cand* pick = nullptr;
    if (cands.size() == 1) {
        pick = &cands[0];
    } else {
        const BitstreamLayout declared = classifyLayout(false, true, false, false, extradata, extradataSize);
        for (const Cand& c : cands) {
            if (c.layout.kind == declared.kind && (c.layout.kind != Bitstream::LengthPrefixed || c.layout.nalLengthSize == declared.nalLengthSize)) pick = &c;
        }
        if (!pick) return out;
    }
    out.layout = pick->layout;
    out.vpsCount = (int)pick->ev.vps.size();
    out.spsCount = (int)pick->ev.sps.size();
    out.ppsCount = (int)pick->ev.pps.size();
    if (pick->layout.kind == Bitstream::StartCode) {
        static const uint8_t sc4[4] = {0, 0, 0, 1};
        for (const auto* group : {&pick->ev.vps, &pick->ev.spsBytes, &pick->ev.ppsBytes}) {
            for (auto& nal : *group) { out.extradata.insert(out.extradata.end(), sc4, sc4 + 4); out.extradata.insert(out.extradata.end(), nal.begin(), nal.end()); }
        }
    } else {
        const detail::HevcSpsInfo& s = pick->ev.sps[0];
        std::vector<uint8_t>& e = out.extradata;
        e.push_back(1);
        e.insert(e.end(), s.ptl, s.ptl + 12);
        e.push_back(0xF0); e.push_back(0x00);                       // min_spatial_segmentation_idc = 0
        e.push_back(0xFC);                                          // parallelismType = 0
        e.push_back((uint8_t)(0xFC | (s.chroma & 3)));
        e.push_back((uint8_t)(0xF8 | ((s.bdLuma - 8) & 7)));
        e.push_back((uint8_t)(0xF8 | ((s.bdChroma - 8) & 7)));
        e.push_back(0); e.push_back(0);
        e.push_back((uint8_t)((((s.maxSubLayersMinus1 + 1) & 7) << 3) | (s.nested ? 4 : 0) | (pick->layout.nalLengthSize - 1)));
        e.push_back(3);
        auto array = [&](int type, const std::vector<std::vector<uint8_t>>& nals) -> bool {
            if (nals.size() > 0xFFFF) return false;
            e.push_back((uint8_t)(0x80 | type));
            e.push_back((uint8_t)(nals.size() >> 8)); e.push_back((uint8_t)nals.size());
            for (auto& nal : nals) {
                if (nal.size() > 0xFFFF) return false;
                e.push_back((uint8_t)(nal.size() >> 8)); e.push_back((uint8_t)nal.size());
                e.insert(e.end(), nal.begin(), nal.end());
            }
            return true;
        };
        if (!array(32, pick->ev.vps) || !array(33, pick->ev.spsBytes) || !array(34, pick->ev.ppsBytes)) { out.extradata.clear(); return out; }
    }
    out.ok = true;
    return out;
}

inline bool hevcConfigSuspect(const uint8_t* extradata, int extradataSize, const uint8_t* pkt, size_t n) {
    if (extradata && extradataSize > 0 && !hvccRecordValid(extradata, extradataSize) &&
        !startsWithStartCode(extradata, (size_t)extradataSize)) return true;
    const BitstreamLayout l = classifyLayout(false, true, false, false, extradata, extradataSize);
    if (l.kind == Bitstream::LengthPrefixed && pkt && n > 0) {
        const PacketInspection pi = inspectLengthPrefixed(pkt, n, l.nalLengthSize, true);
        return pi.structure != PacketStructure::Intact;
    }
    return false;
}

inline bool vp8KeyframeSyncFix(const uint8_t* d, size_t n, ByteFix& out) {
    if (!d || n < 10) return false;
    const uint32_t tag = (uint32_t)d[0] | ((uint32_t)d[1] << 8) | ((uint32_t)d[2] << 16);
    if (tag & 1) return false;
    if (((tag >> 1) & 7) > 3) return false;          // profile 0..3
    if ((tag >> 5) > n - 10) return false;
    const uint32_t w = ((uint32_t)d[6] | ((uint32_t)d[7] << 8)) & 0x3fff, h = ((uint32_t)d[8] | ((uint32_t)d[9] << 8)) & 0x3fff;
    if (w == 0 || h == 0) return false;
    static const uint8_t sync[3] = {0x9d, 0x01, 0x2a};
    int bits = 0; size_t at = 0;
    for (size_t i = 0; i < 3; ++i) { const uint8_t x = (uint8_t)(d[3 + i] ^ sync[i]); if (x) { bits += popcount8(x); at = 3 + i; } }
    if (bits != 1) return false;
    out = {at, sync[at - 3]};
    return true;
}

inline bool vp9FrameHeaderFix(const uint8_t* d, size_t n, ByteFix& out) {
    if (!d || n < 10) return false;
    size_t pos = 0;
    auto bit = [&]() -> uint32_t { const uint32_t v = (d[pos >> 3] >> (7 - (pos & 7))) & 1; ++pos; return v; };
    const uint32_t marker = (uint32_t)(d[0] >> 6);
    bool markerFixed = false;
    if (marker != 2) {
        if (popcount32(marker ^ 2u) != 1) return false;
        markerFixed = true;
    }
    pos = 2;
    const uint32_t profile = bit() | (bit() << 1);
    if (profile == 3 && bit() != 0) return false;
    if (bit() != 0) return false;                  // show_existing_frame
    const uint32_t frameType = bit();
    bit(); bit();                                  // show_frame, error_resilient_mode
    if (frameType != 0) return false;
    const size_t syncAt = pos;
    uint32_t sync = 0;
    for (int i = 0; i < 24; ++i) sync = (sync << 1) | bit();
    if (sync != 0x498342u) {
        if (markerFixed) return false;
        const uint32_t diff = sync ^ 0x498342u;
        if (popcount32(diff) != 1) return false;
        int k = 0; while (!((diff >> k) & 1)) ++k;
        const size_t absBit = syncAt + (size_t)(23 - k);
        const size_t byte = absBit >> 3;
        const uint8_t mask = (uint8_t)(0x80 >> (absBit & 7));
        if (byte >= n) return false;
        out = {byte, (uint8_t)(d[byte] ^ mask)};
        return true;
    }
    if (!markerFixed) return false;
    out = {0, (uint8_t)((d[0] & 0x3f) | 0x80)};
    return true;
}

inline bool vp9PacketFixedFieldFixes(const uint8_t* d, size_t n, std::vector<ByteFix>& fixes) {
    fixes.clear();
    if (!d || n < 10) return false;
    std::vector<std::pair<size_t, size_t>> frames;
    const uint8_t last = d[n - 1];
    if ((last & 0xE0) == 0xC0) {
        const int count = (last & 7) + 1, szBytes = ((last >> 3) & 3) + 1;
        const size_t idxLen = 2 + (size_t)count * (size_t)szBytes;
        if (idxLen + 1 <= n && d[n - idxLen] == last) {
            const size_t start = n - idxLen;
            size_t off = 0; bool ok = true;
            for (int f = 0; f < count && ok; ++f) {
                size_t sz = 0;
                for (int b = 0; b < szBytes; ++b) sz |= (size_t)d[start + 1 + (size_t)f * (size_t)szBytes + (size_t)b] << (8 * b);
                if (sz == 0 || sz > start - off) { ok = false; break; }
                frames.push_back({off, sz});
                off += sz;
            }
            if (!ok || off != start) frames.clear();
        }
    }
    if (frames.empty()) frames.push_back({0, n});
    for (const auto& f : frames) {
        ByteFix fx;
        if (vp9FrameHeaderFix(d + f.first, f.second, fx)) { fx.at += f.first; fixes.push_back(fx); }
    }
    return !fixes.empty();
}

inline bool jpegDhtBodyValid(const uint8_t* t, size_t n, bool baseline8) {
    size_t p = 0; bool any = false; bool seen[8] = {false, false, false, false, false, false, false, false};
    while (p < n) {
        if (p + 17 > n) return false;
        const int tc = t[p] >> 4, th = t[p] & 15;
        if (tc > 1 || th > 3 || seen[tc * 4 + th]) return false;
        seen[tc * 4 + th] = true;
        int64_t slots = 1; size_t total = 0;
        for (int i = 0; i < 16; ++i) { const int v = t[p + 1 + (size_t)i]; slots = slots * 2 - v; if (slots <= 0) return false; total += (size_t)v; }
        if (total == 0 || total > 256 || p + 17 + total > n) return false;
        bool used[256] = {false};
        for (size_t i = 0; i < total; ++i) {
            const uint8_t s = t[p + 17 + i];
            if (used[s]) return false;
            used[s] = true;
            if (tc == 0) { if (s > (baseline8 ? 11 : 15)) return false; }
            else { const int size = s & 15, run = s >> 4; if (size > (baseline8 ? 10 : 14)) return false; if (size == 0 && run != 0 && run != 15) return false; }
        }
        p += 17 + total; any = true;
    }
    return any && p == n;
}

inline bool jpegRepairDhtCounts(const uint8_t* d, size_t n, std::vector<ByteFix>& fixes) {
    fixes.clear();
    if (!d || n < 4 || d[0] != 0xFF || d[1] != 0xD8) return false;
    auto markerAt = [&](size_t p) -> int {
        if (p + 1 >= n || d[p] != 0xFF || d[p + 1] == 0x00 || d[p + 1] == 0xFF) return -1;
        return d[p + 1];
    };
    std::vector<std::pair<size_t, size_t>> dht;
    bool baseline8 = false, haveSof = false, closed = false;
    size_t pos = 2;
    for (int seg = 0; seg < 64 && !closed; ++seg) {
        while (pos + 1 < n && d[pos] == 0xFF && d[pos + 1] == 0xFF) ++pos;
        const int m = markerAt(pos);
        if (m < 0 || m == 0xD9) return false;
        if ((m >= 0xD0 && m <= 0xD7) || m == 0x01) { pos += 2; continue; }
        if (pos + 4 > n) return false;
        const size_t len = ((size_t)d[pos + 2] << 8) | d[pos + 3];
        if (len < 2 || pos + 2 + len > n) return false;
        const size_t body = pos + 4, next = pos + 2 + len;
        if (m == 0xC0 || m == 0xC1) {
            if (haveSof || len < 8) return false;
            baseline8 = d[body] == 8; haveSof = true;
        } else if (m == 0xC2 || m == 0xC3 || (m >= 0xC5 && m <= 0xC7) || (m >= 0xC9 && m <= 0xCB) || (m >= 0xCD && m <= 0xCF)) {
            return false;
        } else if (m == 0xC4) {
            dht.push_back({body, len - 2});
        } else if (m == 0xDA) {
            if (!haveSof) return false;

            if (dht.empty()) return false;
            bool anyInvalid = false;
            for (const auto& seg : dht) {
                if (seg.second < 17) return false;
                if (!jpegDhtBodyValid(d + seg.first, seg.second, baseline8)) anyInvalid = true;
            }
            if (!anyInvalid) return false;
            for (size_t q = next; q + 1 < n; ++q) {
                if (d[q] != 0xFF) continue;
                const uint8_t nx = d[q + 1];
                if (nx == 0x00 || (nx >= 0xD0 && nx <= 0xD7) || nx == 0xFF) continue;
                if (nx == 0xD9) { closed = true; break; }
                return false;
            }
            if (!closed) return false;
            break;
        }
        if (markerAt(next) < 0) return false;
        pos = next;
    }
    if (!closed || dht.empty()) return false;
    for (const auto& seg : dht) {
        const uint8_t* t = d + seg.first; const size_t len = seg.second;
        if (len < 17) return false;
        if (jpegDhtBodyValid(t, len, baseline8)) continue;

        std::vector<size_t> starts;
        for (size_t p = 0; p + 17 <= len; ) {
            if ((t[p] >> 4) > 1 || (t[p] & 15) > 3) break;
            starts.push_back(p);
            size_t total = 0; for (int i = 0; i < 16; ++i) total += t[p + 1 + (size_t)i];
            p += 17 + total;
        }
        std::vector<uint8_t> trial(t, t + len);
        int hits = 0; ByteFix hit;
        for (size_t s : starts) {
            for (size_t off = s + 1; off < s + 17 && off < len; ++off) {
                for (int k = 0; k < 8; ++k) {
                    trial[off] = (uint8_t)(t[off] ^ (1 << k));
                    if (jpegDhtBodyValid(trial.data(), len, baseline8)) { ++hits; hit = {seg.first + off, trial[off]}; }
                    trial[off] = t[off];
                }
            }
        }
        if (hits != 1) { fixes.clear(); return false; }
        fixes.push_back(hit);
    }
    return !fixes.empty();
}

enum class RapClass : uint8_t { Unknown = 0, Idr, IntraOrRecovery, Predicted };

inline RapClass avcSampleRapClass(const uint8_t* d, size_t n, int nalLen, bool hevc, const std::vector<std::pair<uint32_t, int>>* hevcPpsExtra = nullptr) {
    if (!d || n == 0 || nalLen < 1 || nalLen > 4) return RapClass::Unknown;
    bool idr = false, recovery = false, sawIntra = false, sawPred = false, sawVcl = false;
    size_t off = 0;
    while (off + (size_t)nalLen <= n) {
        uint32_t len = 0;
        for (int i = 0; i < nalLen; ++i) len = (len << 8) | d[off + (size_t)i];
        off += (size_t)nalLen;
        if (len < 2 || len > n - off) return RapClass::Unknown;
        const uint8_t* nal = d + off;
        if (hevc) {
            const int type = (nal[0] >> 1) & 0x3f;
            if (type >= 16 && type <= 23) idr = true;
            else if (type <= 9 || (type >= 16 && type <= 21)) {
                sawVcl = true;
                if (hevcPpsExtra) {
                    const int st = hevcFirstSliceType(nal, len, *hevcPpsExtra);
                    if (st == 2) sawIntra = true; else if (st == 0 || st == 1) sawPred = true;
                }
            }
        } else {
            const int type = nal[0] & 0x1f;
            if (type == 5) idr = true;
            else if (type == 1) {
                sawVcl = true;
                const int st = h264SliceType(nal, len);
                if (st == 2 || st == 4 || st == 7 || st == 9) sawIntra = true; else if (st >= 0) sawPred = true;
            } else if (type == 6 && len >= 3) {
                size_t p = 1; uint32_t ptype = 0;
                while (p < len && nal[p] == 0xFF) { ptype += 255; ++p; }
                if (p < len) ptype += nal[p];
                if (ptype == 6) recovery = true;
            }
        }
        off += len;
    }
    if (idr) return RapClass::Idr;
    if (recovery || (sawVcl && sawIntra && !sawPred)) return RapClass::IntraOrRecovery;
    if (sawPred) return RapClass::Predicted;
    return RapClass::Unknown;
}

inline std::vector<std::pair<uint32_t, int>> hvccPpsSliceFields(const uint8_t* e, int n) {
    std::vector<std::pair<uint32_t, int>> out;
    hvccForEachNal(e, n, [&](int type, const uint8_t* nal, size_t l) {
        if (l < 3) return false;
        if (type == 34) {
            uint32_t id = 0; bool dep = false; int extra = 0;
            if (hevcPpsSliceFields(nal, l, id, dep, extra)) out.push_back({id, extra});
        }
        return true;
    });
    return out;
}

struct Mp4CttsCandidate {
    size_t run = 0;
    uint32_t oldValue = 0, newValue = 0;
    size_t conflictFirst = 0, conflictLast = 0;
    size_t runFirst = 0, runLast = 0;
};

inline int64_t mp4CttsOffsetSpan(const std::vector<std::pair<uint32_t, uint32_t>>& runs, bool version1) {
    int64_t lo = INT64_MAX, hi = INT64_MIN;
    for (const auto& r : runs) {
        const int64_t v = version1 ? (int64_t)(int32_t)r.second : (int64_t)r.second;
        lo = std::min(lo, v); hi = std::max(hi, v);
    }
    return runs.empty() ? 0 : hi - lo;
}
inline bool mp4CttsConflictImpossible(const std::vector<uint32_t>& deltas, int64_t offsetSpan, int reorderBound) {
    const size_t k = (size_t)std::max(reorderBound, 0) + 1, N = deltas.size();
    if (offsetSpan <= 0 || N <= k) return true;
    uint64_t span = 0;
    for (size_t i = 0; i < k; ++i) span += deltas[i];
    for (size_t i = 0;; ++i) {
        if ((int64_t)std::min<uint64_t>(span, (uint64_t)INT64_MAX) < offsetSpan) return false;
        if (i + k + 1 >= N) return true;
        span += deltas[i + k]; span -= deltas[i];
    }
}

inline bool mp4CttsSingleBitCandidate(const std::vector<uint32_t>& deltas, const std::vector<std::pair<uint32_t, uint32_t>>& runs,
                                      bool version1, int reorderBound, Mp4CttsCandidate& out, const AbortFn* abort = nullptr) {
    const size_t N = deltas.size();
    if (N == 0 || runs.empty() || N > 4000000) return false;
    uint64_t total = 0; for (const auto& r : runs) total += r.first;
    if (total != N) return false;
    if (mp4CttsConflictImpossible(deltas, mp4CttsOffsetSpan(runs, version1), reorderBound)) return false;
    auto stop = [abort] { return abort && *abort && (*abort)(); };
    std::vector<int64_t> dts(N), cts(N);
    std::vector<uint32_t> runOf(N);
    { int64_t t = 0; size_t i = 0; for (size_t r = 0; r < runs.size(); ++r) for (uint32_t k = 0; k < runs[r].first; ++k, ++i) runOf[i] = (uint32_t)r; for (size_t j = 0; j < N; ++j) { dts[j] = t; t += deltas[j]; } }
    auto ctsOf = [&](uint32_t raw) -> int64_t { return version1 ? (int64_t)(int32_t)raw : (int64_t)raw; };
    for (size_t i = 0; i < N; ++i) cts[i] = dts[i] + ctsOf(runs[runOf[i]].second);
    auto depthAt = [&](size_t i) -> int { int c = 0; for (size_t j = i + 1; j < N && j < i + 64; ++j) if (cts[j] < cts[i]) ++c; return c; };
    std::vector<size_t> conflicts;
    for (size_t i = 0; i < N; ++i) {
        if ((i & 4095) == 0 && stop()) return false;
        if (depthAt(i) > reorderBound) conflicts.push_back(i);
    }
    if (conflicts.empty()) return false;
    std::vector<uint32_t> suspect;
    for (size_t i : conflicts) { const uint32_t r = runOf[i]; bool have = false; for (uint32_t s : suspect) if (s == r) have = true; if (!have) suspect.push_back(r); }
    if (suspect.size() > 4) return false;
    int hits = 0; Mp4CttsCandidate hit;
    for (uint32_t r : suspect) {
        size_t first = 0; for (uint32_t k = 0; k < r; ++k) first += runs[k].first;
        const size_t last = first + runs[r].first - 1;
        for (int bit = 0; bit < 32; ++bit) {
            const uint32_t val = runs[r].second ^ (1u << bit);
            bool supported = false;
            for (size_t k = 0; k < runs.size(); ++k) if (k != r && runs[k].second == val) { supported = true; break; }
            if (!supported) continue;
            const int64_t nv = ctsOf(val);
            for (size_t i = first; i <= last; ++i) cts[i] = dts[i] + nv;
            bool ok = true;
            const size_t lo = first > 64 ? first - 64 : 0, hi = std::min(N, last + 65);
            for (size_t i = lo; i < hi && ok; ++i) if (depthAt(i) > reorderBound) ok = false;
            if (ok) {
                std::vector<int64_t> sorted(cts.begin() + (long)lo, cts.begin() + (long)hi);
                std::sort(sorted.begin(), sorted.end());
                for (size_t i = 1; i < sorted.size(); ++i) if (sorted[i] == sorted[i - 1]) { ok = false; break; }
            }
            for (size_t i = first; i <= last; ++i) cts[i] = dts[i] + ctsOf(runs[r].second);
            if (!ok) continue;
            ++hits;
            hit.run = r; hit.oldValue = runs[r].second; hit.newValue = val; hit.runFirst = first; hit.runLast = last;
            hit.conflictFirst = conflicts.front(); hit.conflictLast = conflicts.back();
        }
    }
    if (hits != 1) return false;
    out = hit;
    return true;
}

struct ProresFrameInfo {
    bool parsed = false;
    bool ok = false;
    bool hard = false;
    bool slackOnly = false;
    bool progressive = true;
    uint16_t width = 0, height = 0;
    int slices = 0;
};
namespace detail {

inline uint32_t proresPictureCheck(const uint8_t* d, size_t n, size_t q, int mbW, int mbH, bool alpha, bool& hard, bool& slack, int& slicesOut) {
    hard = false; slack = false; slicesOut = 0;
    if (q + 8 > n) { hard = true; return 0; }
    const int ph = d[q] >> 3;
    const uint32_t picSize = be32(d + q + 1);
    const int l2w = d[q + 7] >> 4, l2h = d[q + 7] & 15;
    if (ph < 8 || q + (size_t)ph > n || picSize > n - q || l2w > 3 || l2h != 0) { hard = true; return 0; }
    const int sliceW = 1 << l2w;
    const int perRow = (mbW >> l2w) + __builtin_popcount(mbW & (sliceW - 1));
    const int64_t count = (int64_t)mbH * perRow;
    if (count <= 0 || count > 65535 || q + (size_t)ph + 2 * (size_t)count > n) { hard = true; return 0; }
    slicesOut = (int)count;
    const size_t table = q + (size_t)ph;
    size_t s = table + 2 * (size_t)count;
    const size_t picEnd = q + picSize;
    if (s > picEnd) return 0;
    bool allSlicesOk = true;
    for (int64_t i = 0; i < count; ++i) {
        const uint32_t z = be16(d + table + 2 * (size_t)i);
        if (z < 6 || s + z > n) { hard = true; return 0; }
        if (s + z > picEnd) return 0;
        const int sh = d[s] >> 3;
        const uint32_t y = be16(d + s + 2), u = be16(d + s + 4);
        bool sliceOk = sh >= 6 && (uint32_t)sh <= z && d[s + 1] >= 1 && d[s + 1] <= 224 && y >= 1 && u >= 1 && (uint64_t)y + u + sh < z;
        if (sliceOk && sh >= 8) { const uint32_t v = be16(d + s + 6); sliceOk = alpha ? ((uint64_t)y + u + v + sh <= z) : ((uint64_t)y + u + v + sh == z); }
        if (!sliceOk) allSlicesOk = false;
        s += z;
    }
    if (!allSlicesOk) return 0;
    if (s != picEnd) { slack = s < picEnd; return 0; }
    return picSize;
}
} // namespace detail

inline ProresFrameInfo proresInspectFrame(const uint8_t* d, size_t n) {
    ProresFrameInfo r;
    if (!d || n < 36 || std::memcmp(d + 4, "icpf", 4) != 0) return r;
    const uint32_t fh = be16(d + 8);
    if (be16(d + 10) > 1) return r;
    r.width = (uint16_t)be16(d + 16); r.height = (uint16_t)be16(d + 18);
    if (r.width == 0 || r.height == 0 || r.width > 8192 || r.height > 8192) return r;
    const int frameType = (d[20] >> 2) & 3;
    const int alphaInfo = d[25] & 15;
    if (alphaInfo > 2) return r;
    r.parsed = true;
    r.progressive = frameType == 0;
    const uint8_t flags = d[27];
    const size_t minimum = 20 + ((flags & 2) ? 64 : 0) + ((flags & 1) ? 64 : 0);
    if (fh < minimum || fh > 4096 || 8 + (size_t)fh + 8 > n) { r.hard = true; return r; }
    const int mbW = (r.width + 15) >> 4;
    const int mbH = r.progressive ? (r.height + 15) >> 4 : (r.height + 31) >> 5;
    size_t q = 8 + fh;
    const int pictures = r.progressive ? 1 : 2;
    for (int p = 0; p < pictures; ++p) {
        bool hard = false, slack = false; int slices = 0;
        const uint32_t ps = detail::proresPictureCheck(d, n, q, mbW, mbH, alphaInfo != 0, hard, slack, slices);
        r.slices += slices;
        if (ps == 0) { r.hard = hard; r.slackOnly = slack; return r; }
        q += ps;
    }
    for (size_t i = q; i < n; ++i) if (d[i] != 0) return r;
    r.ok = true;
    return r;
}

inline bool proresFrameGeometryFix(const uint8_t* d, size_t n, ByteFix& fix, std::string* what = nullptr) {
    const ProresFrameInfo info = proresInspectFrame(d, n);
    if (!info.parsed || info.ok || info.slackOnly || !info.progressive || (d[25] & 15) != 0) return false;
    std::vector<uint8_t> buf(d, d + n);
    struct Cand { size_t at; uint8_t mask; const char* field; };
    std::vector<Cand> found;
    auto tryFlip = [&](size_t at, uint8_t mask, const char* field) {
        if (at >= n) return;
        buf[at] ^= mask;
        const ProresFrameInfo t = proresInspectFrame(buf.data(), buf.size());
        buf[at] ^= mask;
        if (!t.ok) return;
        for (const Cand& c : found) if (c.at == at && c.mask == mask) return;
        found.push_back({at, mask, field});
    };
    for (int b = 0; b < 16; ++b) tryFlip(8 + (b < 8 ? 1 : 0), (uint8_t)(1u << (b & 7)), "frame_header_size");
    const uint32_t fh = be16(d + 8);
    const size_t q = 8 + fh;
    if (fh >= 20 && fh <= 4096 && q + 8 <= n) {
        for (int b = 0; b < 5; ++b) tryFlip(q, (uint8_t)(0x08u << b), "picture_header_size");
        for (int b = 0; b < 32; ++b) tryFlip(q + 1 + (size_t)(3 - b / 8), (uint8_t)(1u << (b & 7)), "picture_size");
        tryFlip(q + 7, 0x10, "slice_width"); tryFlip(q + 7, 0x20, "slice_width");
        const int ph = d[q] >> 3, l2w = d[q + 7] >> 4, l2h = d[q + 7] & 15;
        const uint32_t picSize = be32(d + q + 1);
        if (ph >= 8 && l2w <= 3 && l2h == 0 && picSize <= n - q) {
            const int mbW = (info.width + 15) >> 4, mbH = (info.height + 15) >> 4;
            const int64_t count = (int64_t)mbH * ((mbW >> l2w) + __builtin_popcount(mbW & ((1 << l2w) - 1)));
            if (count > 0 && count <= 65535 && q + (size_t)ph + 2 * (size_t)count <= n) {
                const size_t table = q + (size_t)ph;
                int64_t sum = 0;
                for (int64_t i = 0; i < count; ++i) sum += be16(d + table + 2 * (size_t)i);
                const int64_t delta = (int64_t)picSize - ph - 2 * count - sum;
                const uint64_t mag = (uint64_t)(delta < 0 ? -delta : delta);
                if (delta != 0 && mag <= 0xFFFF && (mag & (mag - 1)) == 0) {
                    for (int64_t i = 0; i < count; ++i) {
                        const uint32_t z = be16(d + table + 2 * (size_t)i);
                        const bool has = (z & mag) != 0;
                        if (delta > 0 ? has : !has) continue;
                        tryFlip(table + 2 * (size_t)i + (mag >= 256 ? 0 : 1), (uint8_t)(mag >= 256 ? mag >> 8 : mag), "slice_size");
                    }
                }
            }
        }
    }
    if (found.size() != 1) return false;
    fix.at = found[0].at;
    fix.value = (uint8_t)(d[found[0].at] ^ found[0].mask);
    if (what) *what = found[0].field;
    return true;
}

inline bool proresFrameSizeFieldFix(const uint8_t* d, size_t n, ByteFix& fix) {
    if (!d || n < 36 || n > 0xFFFFFFFFull || std::memcmp(d + 4, "icpf", 4) != 0) return false;
    const uint32_t declared = be32(d);
    const uint32_t diff = declared ^ (uint32_t)n;
    if (diff == 0 || (diff & (diff - 1)) != 0) return false;
    if (!proresInspectFrame(d, n).ok) return false;
    int byte = 0; uint32_t m = diff;
    while (m > 0xFF) { m >>= 8; ++byte; }
    fix.at = (size_t)(3 - byte);
    fix.value = (uint8_t)(d[fix.at] ^ (uint8_t)m);
    return true;
}

inline bool tsVideoEsChainHasVcl(const uint8_t* es, size_t n, bool hevc) {
    if (!es || n < 5) return false;
    size_t p = 0;
    if (es[0] == 0 && es[1] == 0 && es[2] == 1) p = 3;
    else if (es[0] == 0 && es[1] == 0 && es[2] == 0 && es[3] == 1) p = 4;
    else return false;
    bool vcl = false;
    int nals = 0;
    while (p < n && nals < 64) {
        size_t next = n;
        for (size_t k = p; k + 2 < n; ++k) if (es[k] == 0 && es[k + 1] == 0 && (es[k + 2] == 1 || (es[k + 2] == 0 && k + 3 < n && es[k + 3] == 1))) { next = k; break; }
        size_t len = next - p;
        while (len > 0 && es[p + len - 1] == 0) --len;
        if (len == 0) return false;
        const uint8_t h = es[p];
        if (h & 0x80) return false;
        if (hevc) {
            if (len < 2) return false;
            const int type = (h >> 1) & 0x3f;
            if (type > 40 || (es[p + 1] & 7) == 0) return false;
            if (type <= 31) vcl = true;
        } else {
            const int type = h & 0x1f;
            if (type < 1 || type > 12) return false;
            if (type <= 5) vcl = true;
        }
        ++nals;
        if (next >= n) break;
        p = next + ((es[next + 2] == 1) ? 3 : 4);
    }
    return vcl;
}

} // namespace spresil
