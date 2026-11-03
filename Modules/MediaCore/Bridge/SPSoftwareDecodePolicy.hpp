#pragma once

#include <cstdint>

namespace spswdec {

inline constexpr int kAv1MaxFrameDelay = 4;

inline constexpr int64_t kAv1ContextBytesPerPixel = 11;

inline constexpr int64_t kAv1WallMinBytes = 128ll * 1024 * 1024;
inline constexpr int64_t kAv1WallMaxBytes = 384ll * 1024 * 1024;

inline int64_t av1BudgetWallBytes(int64_t physicalMemoryBytes) {
    if (physicalMemoryBytes <= 0) return kAv1WallMinBytes;
    const int64_t scaled = physicalMemoryBytes / 32;
    if (scaled < kAv1WallMinBytes) return kAv1WallMinBytes;
    if (scaled > kAv1WallMaxBytes) return kAv1WallMaxBytes;
    return scaled;
}

inline int64_t av1FrameContextBytes(int width, int height, bool tenBit) {
    if (width <= 0 || height <= 0) return 0;
    return (int64_t)width * (int64_t)height * kAv1ContextBytesPerPixel *
           (tenBit ? 2 : 1);
}

struct Av1DelayInput {
    int width = 0;
    int height = 0;
    bool tenBit = false;
    bool singleFrameMode = false;
    bool previewMode = false;
    int64_t wallBytes = 0;
    int64_t claimedBytes = 0;
};

struct Av1DelayPlan {
    int maxFrameDelay = 0;
    int64_t claimBytes = 0;
    int64_t perContextBytes = 0;
};

inline Av1DelayPlan av1FrameDelayPlan(const Av1DelayInput &in) {
    Av1DelayPlan plan;
    if (in.singleFrameMode || in.previewMode) return plan;
    const int64_t per = av1FrameContextBytes(in.width, in.height, in.tenBit);
    plan.perContextBytes = per;
    if (per <= 0 || in.wallBytes <= 0) return plan;

    int64_t remain = in.wallBytes - in.claimedBytes;
    if (remain < 0) remain = 0;

    int64_t perWindowCeiling = in.wallBytes * 3 / 4;
    if (perWindowCeiling < per) perWindowCeiling = per;
    const int64_t grantable = remain < perWindowCeiling ? remain : perWindowCeiling;

    int64_t extra = grantable / per;
    if (extra <= 0) return plan;
    if (extra > kAv1MaxFrameDelay - 1) extra = kAv1MaxFrameDelay - 1;
    plan.maxFrameDelay = 1 + (int)extra;
    plan.claimBytes = extra * per;
    return plan;
}

}  // namespace spswdec
