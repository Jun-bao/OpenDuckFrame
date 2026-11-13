#include "SPAirWindowOptimization.hpp"
#include <cassert>
#include <cstdio>
#include <cstring>
#include <initializer_list>

using sp::AirWindowOptimizationInput;

static AirWindowOptimizationInput eligible() {
    AirWindowOptimizationInput input;
    input.metalAvailable = input.appleGPU = input.unifiedMemory = true;
    input.captureByteLimit = 64ULL * 1024 * 1024;
    input.sourceKind = 1;        // window
    input.interpolation = true;
    input.rife425 = true;
    input.fast = true;
    input.multiplierRate = true;
    input.multiplier = 2;
    input.stream = true;
    input.scale = false;
    input.original = true;
    input.productionFourStage = false;
    input.gpuIO = true;
    input.accumulate = true;
    input.compiled = true;
    return input;
}

int main() {
    // Eligibility has no model-identifier input. Missing required GPU capabilities
    // are rejected independently; different valid memory budgets are accepted.
    auto input = eligible();
    assert(sp::airWindowOptimizationReason(input) == nullptr);
    for (auto member : {&AirWindowOptimizationInput::metalAvailable,
                        &AirWindowOptimizationInput::appleGPU,
                        &AirWindowOptimizationInput::unifiedMemory}) {
        auto missing = input; missing.*member = false;
        assert(std::strcmp(sp::airWindowOptimizationReason(missing),
                           "required-gpu-capabilities-unavailable") == 0);
    }
    input.captureByteLimit = 0;
    assert(sp::airWindowOptimizationReason(input) != nullptr);
    input.captureByteLimit = 16ULL * 1024 * 1024;
    assert(sp::airWindowOptimizationReason(input) == nullptr);
    assert(sp::airWindowNativeFits(4, 60));
    assert(sp::airWindowNativeFits(12.5, 60));
    assert(!sp::airWindowNativeFits(12.6, 60));
    assert(!sp::airWindowNativeFits(30, 60));
    assert(!sp::airWindowNativeFits(0, 60));
    assert(!sp::airWindowNativeFits(NAN, 60));
    assert(!sp::airWindowNativeFits(4, 0));
    assert(!sp::airWindowNativeFits(4, INFINITY));

    // The remaining gates are unchanged by capability admission.
    AirWindowOptimizationInput notCompiled = eligible();
    notCompiled.compiled = false;
    assert(std::strcmp(sp::airWindowOptimizationReason(notCompiled), "feature-not-compiled") == 0);

    AirWindowOptimizationInput notWindow = eligible();
    notWindow.sourceKind = 2;
    assert(std::strcmp(sp::airWindowOptimizationReason(notWindow), "source-is-not-window") == 0);

    AirWindowOptimizationInput noRife = eligible();
    noRife.rife425 = false;
    assert(std::strcmp(sp::airWindowOptimizationReason(noRife), "requires-rife-4.25") == 0);

    AirWindowOptimizationInput notFast = eligible();
    notFast.fast = false;
    assert(std::strcmp(sp::airWindowOptimizationReason(notFast), "requires-fast-quality") == 0);

    AirWindowOptimizationInput x3 = eligible();
    x3.multiplier = 3;
    assert(std::strcmp(sp::airWindowOptimizationReason(x3), "requires-x2") == 0);

    AirWindowOptimizationInput noStream = eligible();
    noStream.stream = false;
    assert(std::strcmp(sp::airWindowOptimizationReason(noStream), "requires-stream") == 0);

    AirWindowOptimizationInput scaled = eligible();
    scaled.scale = true;
    assert(std::strcmp(sp::airWindowOptimizationReason(scaled), "requires-scale-off") == 0);

    AirWindowOptimizationInput noModel = eligible();
    noModel.original = false;
    noModel.productionFourStage = false;
    assert(std::strcmp(sp::airWindowOptimizationReason(noModel), "requires-supported-model") == 0);

    AirWindowOptimizationInput noGpu = eligible();
    noGpu.gpuIO = false;
    assert(std::strcmp(sp::airWindowOptimizationReason(noGpu), "requires-gpu-io") == 0);

    AirWindowOptimizationInput noAccumulate = eligible();
    noAccumulate.accumulate = false;
    assert(std::strcmp(sp::airWindowOptimizationReason(noAccumulate), "requires-accumulate-mask") == 0);

    std::printf("AirWindowOptimizationTests: OK\n");
    return 0;
}
