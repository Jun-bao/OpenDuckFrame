#pragma once

#include <cstdint>
#include <cmath>

namespace sp {

struct AirWindowOptimizationInput {
    bool metalAvailable = false;
    bool appleGPU = false;
    bool unifiedMemory = false;
    uint64_t captureByteLimit = 0;
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

inline bool airWindowCapabilitiesSupported(const AirWindowOptimizationInput &input) {
    return input.metalAvailable && input.appleGPU && input.unifiedMemory && input.captureByteLimit > 0;
}

// Preparation timings decide whether the ordinary full-size path has enough
// headroom for one generated picture per display interval. This is admission
// evidence, not a promise of sustained presentation FPS.
inline bool airWindowNativeFits(double taskMs, double refreshHz) {
    return std::isfinite(taskMs) && taskMs > 0 && std::isfinite(refreshHz) && refreshHz > 0 &&
        taskMs <= 0.75 * 1000.0 / refreshHz;
}

inline const char *airWindowOptimizationReason(const AirWindowOptimizationInput &input) {
    if (!input.compiled) return "feature-not-compiled";
    if (!airWindowCapabilitiesSupported(input)) return "required-gpu-capabilities-unavailable";
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
