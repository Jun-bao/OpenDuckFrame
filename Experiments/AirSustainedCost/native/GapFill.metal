#include <metal_stdlib>
using namespace metal;

// Independent integer work with an observable write. No model input or resource.
kernel void air_gap_fill(device uint *scratch [[buffer(0)]],
                         constant uint &iterations [[buffer(1)]],
                         uint tid [[thread_position_in_grid]]) {
    uint value = tid ^ 0xA511E9B3u;
    for (uint index = 0; index < iterations; ++index) {
        value ^= value << 13;
        value ^= value >> 17;
        value ^= value << 5;
        value += 0x9E3779B9u ^ index;
    }
    scratch[tid] = value;
}
