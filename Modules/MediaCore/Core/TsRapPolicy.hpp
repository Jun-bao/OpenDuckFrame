#pragma once

#include <cstdint>

namespace sp {

struct SPTsRapLimits {
    int64_t maxSpanUs = 30LL * 1000000;
    int64_t maxBytes = 32LL * 1024 * 1024;
    int64_t maxVideoPackets = 8192;
};

inline int64_t spTsRapWindowUs(int64_t gopUs, int attempt) {
    int64_t win = 2500000;
    if (gopUs > 0) {
        win = gopUs + gopUs / 4 + 250000;
        if (win < 2500000) win = 2500000;
        if (win > 12000000) win = 12000000;
    }
    for (int i = 0; i < attempt; ++i) {
        if (win > (int64_t)1 << 40) break;
        win *= 3;
    }
    return win;
}

inline bool spTsRapExhausted(const SPTsRapLimits& lim, int64_t spanUs,
                             int64_t bytes, int64_t pkts) {
    return spanUs > lim.maxSpanUs || bytes > lim.maxBytes ||
           pkts > lim.maxVideoPackets;
}

inline bool spTsRapGopSampleValid(int64_t spacingUs) {
    return spacingUs > 0 && spacingUs <= 30LL * 1000000;
}

inline int64_t spTsRapBlendGopUs(int64_t currentUs, int64_t spacingUs) {
    if (!spTsRapGopSampleValid(spacingUs)) return currentUs;
    if (currentUs <= 0) return spacingUs;
    return currentUs + (spacingUs - currentUs) / 4;
}

} // namespace sp
