#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>

inline size_t spVideoFrameQueueCapacity(int width, int height, double sourceFPS,
                                        double cadenceMultiplier) {
    const size_t frameBytes = (size_t)std::max(width, 1) * (size_t)std::max(height, 1) * 3;
    size_t cap = 75u * 1024 * 1024 / std::max(frameBytes, (size_t)1);
    const double fps = sourceFPS > 0 ? sourceFPS : 30.0;
    const double multiplier = cadenceMultiplier > 1.0 ? cadenceMultiplier : 1.0;
    const size_t durFrames = (size_t)std::ceil(fps * multiplier * 0.125);
    const size_t memCeil = 150u * 1024 * 1024 / std::max(frameBytes, (size_t)1);
    cap = std::max(cap, std::min(durFrames, memCeil));
    return std::max((size_t)2, std::min(cap, (size_t)8));
}

inline size_t spVideoFrameQueueFloor(double sourceFPS, double cadenceMultiplier) {
    const double fps = sourceFPS > 0 ? sourceFPS : 30.0;
    const double multiplier = cadenceMultiplier > 1.0 ? cadenceMultiplier : 1.0;
    return std::max((size_t)2, std::min((size_t)std::ceil(fps * multiplier * 0.125), (size_t)8));
}
