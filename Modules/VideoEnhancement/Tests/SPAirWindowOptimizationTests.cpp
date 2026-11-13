#include "SPAirWindowOptimization.hpp"
#include <cassert>
#include <cstdio>
#include <cstring>
#include <initializer_list>

using sp::AirWindowOptimizationInput;

static AirWindowOptimizationInput eligible(const char *hardware) {
    AirWindowOptimizationInput input;
    input.hardware = hardware;
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
    // The Air recipe is silicon scoped. M3 Air and M5 Air are supported.
    assert(sp::airWindowHardwareSupported("Mac15,12"));
    assert(sp::airWindowHardwareSupported("Mac15,13"));
    assert(sp::airWindowHardwareSupported("Mac17,3"));
    assert(!sp::airWindowHardwareSupported("Mac17,4"));
    assert(!sp::airWindowHardwareSupported("Mac16,10"));
    assert(!sp::airWindowHardwareSupported("Mac14,2"));
    assert(!sp::airWindowHardwareSupported(""));
    assert(!sp::airWindowHardwareSupported(nullptr));

    // Every supported board reaches the recipe with an otherwise eligible request.
    for (const char *hardware : {"Mac15,12", "Mac15,13", "Mac17,3"}) {
        AirWindowOptimizationInput input = eligible(hardware);
        assert(sp::airWindowOptimizationReason(input) == nullptr);
    }

    // An unsupported board is rejected by hardware, not by a later condition.
    AirWindowOptimizationInput other = eligible("Mac14,2");
    assert(std::strcmp(sp::airWindowOptimizationReason(other), "hardware-not-supported") == 0);

    // The remaining gates are unchanged by the hardware list.
    AirWindowOptimizationInput notCompiled = eligible("Mac17,3");
    notCompiled.compiled = false;
    assert(std::strcmp(sp::airWindowOptimizationReason(notCompiled), "feature-not-compiled") == 0);

    AirWindowOptimizationInput notWindow = eligible("Mac17,3");
    notWindow.sourceKind = 2;
    assert(std::strcmp(sp::airWindowOptimizationReason(notWindow), "source-is-not-window") == 0);

    AirWindowOptimizationInput noRife = eligible("Mac17,3");
    noRife.rife425 = false;
    assert(std::strcmp(sp::airWindowOptimizationReason(noRife), "requires-rife-4.25") == 0);

    AirWindowOptimizationInput notFast = eligible("Mac17,3");
    notFast.fast = false;
    assert(std::strcmp(sp::airWindowOptimizationReason(notFast), "requires-fast-quality") == 0);

    AirWindowOptimizationInput x3 = eligible("Mac17,3");
    x3.multiplier = 3;
    assert(std::strcmp(sp::airWindowOptimizationReason(x3), "requires-x2") == 0);

    AirWindowOptimizationInput noStream = eligible("Mac17,3");
    noStream.stream = false;
    assert(std::strcmp(sp::airWindowOptimizationReason(noStream), "requires-stream") == 0);

    AirWindowOptimizationInput scaled = eligible("Mac17,3");
    scaled.scale = true;
    assert(std::strcmp(sp::airWindowOptimizationReason(scaled), "requires-scale-off") == 0);

    AirWindowOptimizationInput noModel = eligible("Mac17,3");
    noModel.original = false;
    noModel.productionFourStage = false;
    assert(std::strcmp(sp::airWindowOptimizationReason(noModel), "requires-supported-model") == 0);

    AirWindowOptimizationInput noGpu = eligible("Mac17,3");
    noGpu.gpuIO = false;
    assert(std::strcmp(sp::airWindowOptimizationReason(noGpu), "requires-gpu-io") == 0);

    AirWindowOptimizationInput noAccumulate = eligible("Mac17,3");
    noAccumulate.accumulate = false;
    assert(std::strcmp(sp::airWindowOptimizationReason(noAccumulate), "requires-accumulate-mask") == 0);

    std::printf("AirWindowOptimizationTests: OK\n");
    return 0;
}
