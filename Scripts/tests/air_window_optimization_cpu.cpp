#include "SPAirWindowOptimization.hpp"
#include "SPLiveDisplayQueue.h"
#include <cassert>
#include <iostream>

int main() {
    sp::AirWindowOptimizationInput baseline;
    baseline.hardware = "Mac15,12";
    baseline.sourceKind = 1;
    baseline.interpolation = baseline.rife425 = baseline.fast = true;
    baseline.multiplierRate = baseline.stream = true;
    baseline.multiplier = 2;
    baseline.original = baseline.gpuIO = baseline.accumulate = baseline.compiled = true;
    assert(!sp::airWindowOptimizationReason(baseline));
    auto input = baseline;
    input.hardware = "Mac15,13";
    assert(!sp::airWindowOptimizationReason(input));
    input.hardware = "Mac14,13";
    assert(sp::airWindowOptimizationReason(input));
    for (int64_t source : {0LL, 2LL, 3LL, 4294967297LL}) {
        input = baseline; input.sourceKind = source;
        assert(sp::airWindowOptimizationReason(input));
    }
    for (auto member : {&sp::AirWindowOptimizationInput::interpolation,
                        &sp::AirWindowOptimizationInput::rife425,
                        &sp::AirWindowOptimizationInput::fast,
                        &sp::AirWindowOptimizationInput::multiplierRate,
                        &sp::AirWindowOptimizationInput::stream,
                        &sp::AirWindowOptimizationInput::original,
                        &sp::AirWindowOptimizationInput::gpuIO,
                        &sp::AirWindowOptimizationInput::accumulate,
                        &sp::AirWindowOptimizationInput::compiled}) {
        input = baseline; input.*member = false;
        assert(sp::airWindowOptimizationReason(input));
    }
    input = baseline; input.scale = true;
    assert(sp::airWindowOptimizationReason(input));
    for (int64_t multiplier : {1LL, 3LL, 4LL, 4294967298LL}) {
        input = baseline; input.multiplier = multiplier;
        assert(sp::airWindowOptimizationReason(input));
    }
    const sp::DisplaySlotContext context{1, 2, 3, 4};
    sp::DisplaySlotWindow slot{1, context, 10000000, 16000000, 1000000};
    assert(sp::displaySlotDecision(slot, 1, context, 8500000) == sp::DisplaySlotDecision::waiting);
    slot.selectionGuardNs = 2000000;
    assert(sp::displaySlotDecision(slot, 1, context, 8500000) == sp::DisplaySlotDecision::ready);
    const auto frozen = slot;
    slot.selectionGuardNs = 1000000;
    assert(sp::displaySlotSelectionGuardNs(frozen) == 2000000);
    assert(sp::displaySlotSelectionGuardNs(slot) == 1000000);
    assert(sp::displaySlotDecision(frozen, 1, context, 10000000) == sp::DisplaySlotDecision::expired);
    const sp::DisplaySlotWindow legacy{1, context, 10000000, 16000000};
    assert(sp::displaySlotSelectionGuardNs(legacy) == sp::displaySelectionGuardNs);
    std::cout << "window gates and per-slot guard passed\n";
}
