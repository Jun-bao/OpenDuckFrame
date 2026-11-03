#include <metal_stdlib>
using namespace metal;

static float spLanczos(float x) {
    const float radius = 3.0;
    if (x == 0.0) return 1.0;
    if (x <= -radius || x >= radius) return 0.0;
    float pix = x * M_PI_F;
    return radius * sin(pix) * sin(pix / radius) / (pix * pix);
}

kernel void spLanczosHorizontal(texture2d<float, access::read> src [[texture(0)]],
                                texture2d<float, access::write> dst [[texture(1)]],
                                uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float center = ((float)gid.x + 0.5) * (float)src.get_width() / (float)dst.get_width() - 0.5;
    int base = (int)floor(center) - 2;
    float4 acc = float4(0);
    float weight = 0;
    for (int i = 0; i < 6; ++i) {
        int x = clamp(base + i, 0, (int)src.get_width() - 1);
        float w = spLanczos(center - float(base + i));
        acc += src.read(uint2((uint)x, gid.y)) * w;
        weight += w;
    }
    dst.write(weight != 0.0 ? acc / weight : float4(0), gid);
}

kernel void spLanczosVertical(texture2d<float, access::read> src [[texture(0)]],
                              texture2d<float, access::write> dst [[texture(1)]],
                              uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float center = ((float)gid.y + 0.5) * (float)src.get_height() / (float)dst.get_height() - 0.5;
    int base = (int)floor(center) - 2;
    float4 acc = float4(0);
    float weight = 0;
    for (int i = 0; i < 6; ++i) {
        int y = clamp(base + i, 0, (int)src.get_height() - 1);
        float w = spLanczos(center - float(base + i));
        acc += src.read(uint2(gid.x, (uint)y)) * w;
        weight += w;
    }
    float4 color = weight != 0.0 ? acc / weight : float4(0);
    color.a = 1.0;
    dst.write(clamp(color, 0.0, 1.0), gid);
}

struct SPPresentVertex {
    float4 position [[position]];
    float2 uv;
};

vertex SPPresentVertex spPresentVertex(uint vid [[vertex_id]],
                                       constant float4 *quad [[buffer(0)]]) {
    SPPresentVertex out;
    out.position = float4(quad[vid].xy, 0.0, 1.0);
    out.uv = quad[vid].zw;
    return out;
}

fragment float4 spPresentFragment(SPPresentVertex in [[stage_in]],
                                  texture2d<float> image [[texture(0)]]) {
    constexpr sampler linear(filter::linear, address::clamp_to_edge);
    return float4(image.sample(linear, in.uv).rgb, 1.0);
}
