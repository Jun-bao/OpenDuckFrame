#include <metal_stdlib>
using namespace metal;

kernel void spBudgetDownsampleLuma(texture2d<float, access::read> luma [[texture(0)]],
                                   texture2d<float, access::write> out [[texture(1)]],
                                   constant uint &factor [[buffer(0)]],
                                   constant float &scale [[buffer(1)]],
                                   uint2 gid [[thread_position_in_grid]]) {
    const uint2 osize = uint2(out.get_width(), out.get_height());
    if (any(gid >= osize)) return;
    const uint2 isize = uint2(luma.get_width(), luma.get_height());
    float sum = 0.0;
    for (uint dy = 0; dy < factor; ++dy) {
        for (uint dx = 0; dx < factor; ++dx) {
            uint2 p = min(gid * factor + uint2(dx, dy), isize - 1);
            sum += luma.read(p).r;
        }
    }
    out.write(float4(sum * scale / float(factor * factor), 0, 0, 1), gid);
}

struct SPBudgetBlockResult {
    float sadBest;
    float sadZero;
    float dx;
    float dy;
    float texture;
    float meanA;
    float meanB;
    float pad;
};

constant int kBudgetBlock = 4;
constant int kBudgetRadius = 6;

kernel void spBudgetBlockMatch(texture2d<float, access::read> a [[texture(0)]],
                               texture2d<float, access::read> b [[texture(1)]],
                               device SPBudgetBlockResult *results [[buffer(0)]],
                               constant uint2 &blocks [[buffer(1)]],
                               uint2 gid [[thread_position_in_grid]]) {
    if (any(gid >= blocks)) return;
    const int2 size = int2(a.get_width(), a.get_height());
    const int2 origin = int2(gid) * kBudgetBlock;
    float ablk[kBudgetBlock * kBudgetBlock];
    float meanA = 0.0, meanB = 0.0, tex = 0.0;
    for (int y = 0; y < kBudgetBlock; ++y) {
        for (int x = 0; x < kBudgetBlock; ++x) {
            int2 p = min(origin + int2(x, y), size - 1);
            float v = a.read(uint2(p)).r;
            ablk[y * kBudgetBlock + x] = v;
            meanA += v;
            meanB += b.read(uint2(p)).r;
            int2 px = min(p + int2(1, 0), size - 1);
            int2 py = min(p + int2(0, 1), size - 1);
            tex += fabs(a.read(uint2(px)).r - v) + fabs(a.read(uint2(py)).r - v);
        }
    }
    const float inv = 1.0 / float(kBudgetBlock * kBudgetBlock);
    meanA *= inv; meanB *= inv; tex *= inv * 0.5;
    float best = 1e9, zero = 0.0;
    int bdx = 0, bdy = 0;
    for (int dy = -kBudgetRadius; dy <= kBudgetRadius; ++dy) {
        for (int dx = -kBudgetRadius; dx <= kBudgetRadius; ++dx) {
            float sad = 0.0;
            for (int y = 0; y < kBudgetBlock; ++y) {
                for (int x = 0; x < kBudgetBlock; ++x) {
                    int2 p = clamp(origin + int2(x + dx, y + dy), int2(0), size - 1);
                    sad += fabs(b.read(uint2(p)).r - ablk[y * kBudgetBlock + x]);
                }
            }
            sad *= inv;
            if (dx == 0 && dy == 0) zero = sad;

            const int d2 = dx * dx + dy * dy, b2 = bdx * bdx + bdy * bdy;
            if (sad < best - 1e-6 || (sad < best + 1e-6 && d2 < b2)) { best = sad; bdx = dx; bdy = dy; }
        }
    }
    SPBudgetBlockResult r;
    r.sadBest = best; r.sadZero = zero;
    r.dx = float(bdx); r.dy = float(bdy);
    r.texture = tex; r.meanA = meanA; r.meanB = meanB; r.pad = 0.0;
    results[gid.y * blocks.x + gid.x] = r;
}

struct SPBudgetColor {
    float yScale, yOffset, cScale, cOffset;
    float kr, kb;
    uint tenBit;
    uint pad;
};

static inline float3 spBudgetYuvToRgb(float y, float cb, float cr, constant SPBudgetColor &c) {
    const float kg = 1.0 - c.kr - c.kb;
    float r = y + 2.0 * (1.0 - c.kr) * cr;
    float b = y + 2.0 * (1.0 - c.kb) * cb;
    float g = (y - c.kr * r - c.kb * b) / kg;
    return clamp(float3(r, g, b), 0.0, 1.0);
}

kernel void spBudgetToRGBA(texture2d<float, access::read> lumaTex [[texture(0)]],
                           texture2d<float, access::read> chromaTex [[texture(1)]],
                           texture2d<half, access::write> out [[texture(2)]],
                           constant SPBudgetColor &c [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
    const uint2 size = uint2(out.get_width(), out.get_height());
    if (any(gid >= size)) return;
    const uint2 lp = min(gid, uint2(lumaTex.get_width(), lumaTex.get_height()) - 1);
    const uint2 cp = min(gid / 2, uint2(chromaTex.get_width(), chromaTex.get_height()) - 1);
    float y = lumaTex.read(lp).r * c.yScale + c.yOffset;
    float2 cc = chromaTex.read(cp).rg * c.cScale + c.cOffset;
    float3 rgb = spBudgetYuvToRgb(y, cc.x, cc.y, c);
    out.write(half4(half3(rgb), half(1.0)), gid);
}

kernel void spBudgetToRGBAPlanar(texture2d<float, access::read> lumaTex [[texture(0)]],
                                 texture2d<float, access::read> cbTex [[texture(1)]],
                                 texture2d<half, access::write> out [[texture(2)]],
                                 texture2d<float, access::read> crTex [[texture(3)]],
                                 constant SPBudgetColor &c [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    const uint2 size = uint2(out.get_width(), out.get_height());
    if (any(gid >= size)) return;
    const uint2 lp = min(gid, uint2(lumaTex.get_width(), lumaTex.get_height()) - 1);
    const uint2 cp = min(gid / 2, uint2(cbTex.get_width(), cbTex.get_height()) - 1);
    float y = lumaTex.read(lp).r * c.yScale + c.yOffset;
    float2 cc = float2(cbTex.read(cp).r, crTex.read(cp).r) * c.cScale + c.cOffset;
    float3 rgb = spBudgetYuvToRgb(y, cc.x, cc.y, c);
    out.write(half4(half3(rgb), half(1.0)), gid);
}

static inline float spBudgetQuantize(float v, uint tenBit) {

    if (tenBit == 0) return v;
    float code10 = clamp(round(clamp(v, 0.0, 1.0) * (65535.0 / 64.0)), 0.0, 1023.0);
    return (code10 * 64.0) / 65535.0;
}

kernel void spBudgetFromRGBA(texture2d<half, access::read> in [[texture(0)]],
                             texture2d<float, access::write> lumaTex [[texture(1)]],
                             texture2d<float, access::write> chromaTex [[texture(2)]],
                             constant SPBudgetColor &c [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
    const uint2 csize = uint2(chromaTex.get_width(), chromaTex.get_height());
    if (any(gid >= csize)) return;
    const uint2 isize = uint2(in.get_width(), in.get_height());
    const uint2 lsize = uint2(lumaTex.get_width(), lumaTex.get_height());
    float cbSum = 0.0, crSum = 0.0;
    for (uint dy = 0; dy < 2; ++dy) {
        for (uint dx = 0; dx < 2; ++dx) {
            uint2 p = gid * 2 + uint2(dx, dy);
            float3 rgb = float3(in.read(min(p, isize - 1)).rgb);
            float y = c.kr * rgb.r + (1.0 - c.kr - c.kb) * rgb.g + c.kb * rgb.b;
            cbSum += (rgb.b - y) / (2.0 * (1.0 - c.kb));
            crSum += (rgb.r - y) / (2.0 * (1.0 - c.kr));
            if (all(p < lsize)) {
                float v = (y - c.yOffset) / c.yScale;
                lumaTex.write(float4(spBudgetQuantize(v, c.tenBit), 0, 0, 1), p);
            }
        }
    }
    float2 cc = float2(cbSum, crSum) * 0.25;
    float2 v = (cc - c.cOffset) / c.cScale;
    chromaTex.write(float4(spBudgetQuantize(v.x, c.tenBit), spBudgetQuantize(v.y, c.tenBit), 0, 1), gid);
}
