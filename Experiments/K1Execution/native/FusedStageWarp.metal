#include <metal_stdlib>
using namespace metal;

/// Non-final v4.25 stage: flow split, four backward warps, and NHWC packing.
/// Flow is [1, H, W, 4] fp16; xy warps the first frame and zw the second.
/// The original RG16Float split and RGBA16Float warp intermediates only copy
/// half values. Keep the sample result as half4 before writing the same values
/// to packed RGB and four-channel feature buffers.
kernel void rifeFusedStageWarp(
    texture2d<half, access::sample> first         [[texture(0)]],
    texture2d<half, access::sample> second        [[texture(1)]],
    texture2d<half, access::sample> firstFeatures [[texture(2)]],
    texture2d<half, access::sample> secondFeatures [[texture(3)]],
    device const half4 *flow                     [[buffer(0)]],
    device packed_half3 *firstOutput             [[buffer(1)]],
    device packed_half3 *secondOutput            [[buffer(2)]],
    device half4 *firstFeatureOutput             [[buffer(3)]],
    device half4 *secondFeatureOutput            [[buffer(4)]],
    constant uint2 &outDim                       [[buffer(5)]],
    uint2 gid                                   [[thread_position_in_grid]]
) {
    if (gid.x >= outDim.x || gid.y >= outDim.y) return;
    constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::linear);

    uint index = gid.y * outDim.x + gid.x;
    half4 fRead = flow[index];
    float2 firstCoord = float2(gid) + float2(0.5, 0.5) + float2(fRead.xy);
    float2 secondCoord = float2(gid) + float2(0.5, 0.5) + float2(fRead.zw);

    half4 firstSample = first.sample(s, firstCoord);
    half4 secondSample = second.sample(s, secondCoord);
    half4 firstFeatureSample = firstFeatures.sample(s, firstCoord);
    half4 secondFeatureSample = secondFeatures.sample(s, secondCoord);

    firstOutput[index] = packed_half3(firstSample.rgb);
    secondOutput[index] = packed_half3(secondSample.rgb);
    firstFeatureOutput[index] = firstFeatureSample;
    secondFeatureOutput[index] = secondFeatureSample;
}
