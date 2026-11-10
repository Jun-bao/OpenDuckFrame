#pragma once

#include <cstring>
#include <cstdint>

namespace sp {

struct AirWindowOptimizationInput {
    const char *hardware = "";
    int64_t sourceKind = 0;
    bool interpolation = false;
    bool rife425 = false;
    bool fast = false;
    bool multiplierRate = false;
    int64_t multiplier = 0;
    bool stream = false;
    bool scale = false;
    bool original = false;
    bool gpuIO = false;
    bool accumulate = false;
    bool compiled = false;
};

inline bool airWindowHardwareSupported(const char *hardware) {
    return hardware && (!std::strcmp(hardware, "Mac15,12") || !std::strcmp(hardware, "Mac15,13"));
}

inline const char *airWindowOptimizationReason(const AirWindowOptimizationInput &input) {
    if (!input.compiled) return "feature-not-compiled";
    if (!airWindowHardwareSupported(input.hardware)) return "hardware-not-supported";
    if (input.sourceKind != 1) return "source-is-not-window";
    if (!input.interpolation || !input.rife425) return "requires-rife-4.25";
    if (!input.fast) return "requires-fast-quality";
    if (!input.multiplierRate || input.multiplier != 2) return "requires-x2";
    if (!input.stream) return "requires-stream";
    if (input.scale) return "requires-scale-off";
    if (!input.original) return "requires-original-model";
    if (!input.gpuIO) return "requires-gpu-io";
    if (!input.accumulate) return "requires-accumulate-mask";
    return nullptr;
}

} // namespace sp
