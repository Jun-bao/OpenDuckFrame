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
    bool productionFourStage = false;
    bool gpuIO = false;
    bool accumulate = false;
    bool compiled = false;
};

// Air window optimization is validated on the fanless Air silicon: the M3 Air
// (Mac15,12 / Mac15,13) and the M5 Air (Mac17,3). Every other Air variant runs
// the same recipe, so the gate is the silicon class rather than one board.
inline bool airWindowHardwareSupported(const char *hardware) {
    return hardware && (!std::strcmp(hardware, "Mac15,12") || !std::strcmp(hardware, "Mac15,13") ||
                         !std::strcmp(hardware, "Mac17,3"));
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
    if (!input.original && !input.productionFourStage) return "requires-supported-model";
    if (!input.gpuIO) return "requires-gpu-io";
    if (!input.accumulate) return "requires-accumulate-mask";
    return nullptr;
}

} // namespace sp
