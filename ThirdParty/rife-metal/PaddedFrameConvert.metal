#include <metal_stdlib>
using namespace metal;

/// BGRA8 texture to packed fp16 RGB on the logical padded grid.
/// Match the CPU's right/bottom edge replication before rifeBGRAToRGB.
/// A bgra8Unorm texture read already returns RGB channels in .rgb order.
kernel void rifeBGRAToRGBPadded(
    texture2d<half, access::read> input [[texture(0)]],
    device half *output                [[buffer(0)]],
    constant uint2 &outDim              [[buffer(1)]],
    uint2 gid                          [[thread_position_in_grid]]
) {
    if (gid.x >= outDim.x || gid.y >= outDim.y) return;
    uint2 sourceCoord = min(gid, uint2(input.get_width() - 1, input.get_height() - 1));
    half4 c = input.read(sourceCoord);
    uint outIdx = (gid.y * outDim.x + gid.x) * 3;
    output[outIdx + 0] = c.r;
    output[outIdx + 1] = c.g;
    output[outIdx + 2] = c.b;
}
