#pragma once
#include <cstdint>

namespace sp {
// Preserve an already-selected native SR factor on a capture-size change.
// Non-native or non-integral dimensions are left for normal validation.
inline bool resizedNativeSROutput(int oldW, int oldH, int outW, int outH,
                                  int newW, int newH, int &newOutW, int &newOutH) {
    if (oldW < 2 || oldH < 2 || newW < 2 || newH < 2 || outW <= oldW || outH <= oldH ||
        (int64_t)outW * oldH != (int64_t)outH * oldW) return false;
    int64_t w = (int64_t)newW * outW, h = (int64_t)newH * outH;
    if (w % oldW || h % oldH) return false;
    w /= oldW; h /= oldH;
    if (w < 2 || h < 2 || w > 3840 || h > 2160 || (w & 1) || (h & 1)) return false;
    newOutW = (int)w; newOutH = (int)h; return true;
}
}
