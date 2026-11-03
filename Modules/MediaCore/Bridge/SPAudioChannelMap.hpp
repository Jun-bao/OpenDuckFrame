#pragma once

#include <array>
#include <cstdint>
#include <cstring>
#include <CoreAudioTypes/CoreAudioTypes.h>

namespace sp {

enum : uint64_t {
    kSPChFL  = 1ull << 0,  kSPChFR  = 1ull << 1,  kSPChFC  = 1ull << 2,
    kSPChLFE = 1ull << 3,  kSPChBL  = 1ull << 4,  kSPChBR  = 1ull << 5,
    kSPChSL  = 1ull << 9,  kSPChSR  = 1ull << 10,
    kSPMaskStereo = kSPChFL | kSPChFR,
    kSPMask5Point1 = kSPMaskStereo | kSPChFC | kSPChLFE | kSPChBL | kSPChBR,
    kSPMask7Point1 = kSPMask5Point1 | kSPChSL | kSPChSR,
};

constexpr int kSPAudioMaxChannels = 8;
constexpr int kSPAudioMaxDeviceChannels = 64;

struct AudioOutputLayout {
    int channels = 2;
    uint64_t mask = kSPMaskStereo;
    int deviceChannels = 0;
    bool useMap = false;
    std::array<int32_t, kSPAudioMaxDeviceChannels> map{};

    bool operator==(const AudioOutputLayout &o) const {
        if (channels != o.channels || mask != o.mask || deviceChannels != o.deviceChannels ||
            useMap != o.useMap) return false;
        if (!useMap) return true;
        const int n = deviceChannels < kSPAudioMaxDeviceChannels ? deviceChannels
                                                                 : kSPAudioMaxDeviceChannels;
        return std::memcmp(map.data(), o.map.data(), (size_t)n * sizeof(int32_t)) == 0;
    }
    bool operator!=(const AudioOutputLayout &o) const { return !(*this == o); }
    const char *name() const {
        return mask == kSPMask7Point1 ? "7.1" : mask == kSPMask5Point1 ? "5.1" : "stereo";
    }
};

inline int channelIndexInMask(uint64_t mask, uint64_t bit) {
    if (!(mask & bit)) return -1;
    return __builtin_popcountll(mask & (bit - 1));
}

inline void initStereo(AudioOutputLayout *out, int deviceChannels) {
    *out = AudioOutputLayout{};
    out->deviceChannels = deviceChannels;
    out->map.fill(-1);
}

inline bool resolveOutputLayout(const uint32_t *labels, int count, AudioOutputLayout *out) {
    initStereo(out, count);
    if (!labels || count < 6) return false;

    int fl = -1, fr = -1, fc = -1, lfe = -1;
    int ls = -1, rs = -1;
    int lsd = -1, rsd = -1;
    int rls = -1, rrs = -1;
    const int n = count < kSPAudioMaxDeviceChannels ? count : kSPAudioMaxDeviceChannels;
    for (int i = 0; i < n; i++) {
        switch (labels[i]) {
            case kAudioChannelLabel_Left:                if (fl  < 0) fl  = i; break;
            case kAudioChannelLabel_Right:               if (fr  < 0) fr  = i; break;
            case kAudioChannelLabel_Center:              if (fc  < 0) fc  = i; break;
            case kAudioChannelLabel_LFEScreen:           if (lfe < 0) lfe = i; break;
            case kAudioChannelLabel_LeftSurround:        if (ls  < 0) ls  = i; break;
            case kAudioChannelLabel_RightSurround:       if (rs  < 0) rs  = i; break;
            case kAudioChannelLabel_LeftSurroundDirect:  if (lsd < 0) lsd = i; break;
            case kAudioChannelLabel_RightSurroundDirect: if (rsd < 0) rsd = i; break;
            case kAudioChannelLabel_RearSurroundLeft:    if (rls < 0) rls = i; break;
            case kAudioChannelLabel_RearSurroundRight:   if (rrs < 0) rrs = i; break;
            default: break;
        }
    }
    if (fl < 0 || fr < 0 || fc < 0 || lfe < 0) return false;
    const bool hasLs = ls >= 0 && rs >= 0;
    const bool hasLsd = lsd >= 0 && rsd >= 0;
    const bool hasRls = rls >= 0 && rrs >= 0;
    const int pairs = (int)hasLs + (int)hasLsd + (int)hasRls;
    if (pairs == 0) return false;

    int sideL, sideR, backL, backR;
    if (pairs >= 2) {
        if (hasLsd)      { sideL = lsd; sideR = rsd; }
        else             { sideL = ls;  sideR = rs;  }
        if (hasRls)      { backL = rls; backR = rrs; }
        else             { backL = ls;  backR = rs;  }
        out->mask = kSPMask7Point1;
        out->channels = 8;
    } else {
        if (hasLs)       { backL = ls;  backR = rs;  }
        else if (hasLsd) { backL = lsd; backR = rsd; }
        else             { backL = rls; backR = rrs; }
        sideL = sideR = -1;
        out->mask = kSPMask5Point1;
        out->channels = 6;
    }
    out->useMap = true;
    out->map.fill(-1);
    auto set = [&](int devIdx, uint64_t bit) {
        if (devIdx >= 0 && devIdx < kSPAudioMaxDeviceChannels)
            out->map[(size_t)devIdx] = channelIndexInMask(out->mask, bit);
    };
    set(fl, kSPChFL); set(fr, kSPChFR); set(fc, kSPChFC); set(lfe, kSPChLFE);
    set(backL, kSPChBL); set(backR, kSPChBR);
    if (out->channels == 8) { set(sideL, kSPChSL); set(sideR, kSPChSR); }
    return true;
}

inline bool resolvePositionalLayout(const char *spec, int deviceChannels, AudioOutputLayout *out) {
    initStereo(out, deviceChannels);
    if (!spec) return false;
    uint64_t mask; int ch;
    if (std::strcmp(spec, "7.1") == 0)      { mask = kSPMask7Point1; ch = 8; }
    else if (std::strcmp(spec, "5.1") == 0) { mask = kSPMask5Point1; ch = 6; }
    else return false;
    if (deviceChannels < ch) return false;
    out->mask = mask;
    out->channels = ch;
    out->useMap = true;
    out->map.fill(-1);
    for (int i = 0; i < ch; i++) out->map[(size_t)i] = i;
    return true;
}

} // namespace sp
