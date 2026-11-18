// Metal shaders for FrameBoost's own frame generation (v2).
//
// Per new real frame (motion estimation, both directions A->B and B->A):
//   luma pyramid 1/2, 1/4, 1/8  ->  full search at 1/8 (+ temporal predictor from the last pair)
//   -> refine at 1/4 -> median -> fine 16px grid at 1/2 res with sub-pixel precision -> median
// Per display refresh (synthesis at any moment t between A and B):
//   per pixel: test 9 motion candidates (4 nearest blocks of each direction + zero) with a
//   bidirectional patch cost, soft-select the best ones, handle occlusions, blend.
// Present: aspect-fit scaling to the window + optional contrast adaptive sharpening.
let frameBoostShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct MEParams {
    int radius; int blockSize; int window; float lambda;
    float parentScale; int parentDiv; int usePrev; int subpixel;
};
struct SynthParams {
    float t; float cell; float mvScale; int mode;
    int cut; float sigma; float occLo; float occHi;
};
struct PresentParams {
    float2 offset; float scale; float sharpen;
    float2 srcSize; float pad0; float pad1;
};

inline float lum(float4 c) { return dot(c.rgb, float3(0.299, 0.587, 0.114)); }

// full res BGRA -> 1/2 res luma
kernel void luma_half(texture2d<float, access::read>  src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    uint w = src.get_width() - 1, h = src.get_height() - 1;
    uint2 b = gid * 2;
    float s = lum(src.read(uint2(min(b.x, w), min(b.y, h)))) + lum(src.read(uint2(min(b.x + 1, w), min(b.y, h))))
            + lum(src.read(uint2(min(b.x, w), min(b.y + 1, h)))) + lum(src.read(uint2(min(b.x + 1, w), min(b.y + 1, h))));
    dst.write(float4(s * 0.25), gid);
}

// luma level -> next level (half size)
kernel void down2(texture2d<float, access::read>  src [[texture(0)]],
                  texture2d<float, access::write> dst [[texture(1)]],
                  uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    uint w = src.get_width() - 1, h = src.get_height() - 1;
    uint2 b = gid * 2;
    float s = src.read(uint2(min(b.x, w), min(b.y, h))).r + src.read(uint2(min(b.x + 1, w), min(b.y, h))).r
            + src.read(uint2(min(b.x, w), min(b.y + 1, h))).r + src.read(uint2(min(b.x + 1, w), min(b.y + 1, h))).r;
    dst.write(float4(s * 0.25), gid);
}

inline float sad(texture2d<float, access::read> a, texture2d<float, access::read> b,
                 int2 org, int2 d, int win, float bail) {
    int2 mx = int2(a.get_width() - 1, a.get_height() - 1);
    float s = 0.0;
    for (int y = 0; y < win; y++) {
        for (int x = 0; x < win; x++) {
            int2 pa = clamp(org + int2(x, y), int2(0), mx);
            int2 pb = clamp(org + int2(x, y) + d, int2(0), mx);
            s += fabs(a.read(uint2(pa)).r - b.read(uint2(pb)).r);
        }
        if (s > bail) return s;
    }
    return s;
}

// Full search block matching at 1/8 res (+ temporal predictor). Vector unit: 1/8 px.
kernel void me_coarse(texture2d<float, access::read>  a    [[texture(0)]],
                      texture2d<float, access::read>  b    [[texture(1)]],
                      texture2d<float, access::write> mv   [[texture(2)]],
                      texture2d<float, access::read>  prev [[texture(3)]],
                      constant MEParams& p [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= mv.get_width() || gid.y >= mv.get_height()) return;
    int2 org = int2(gid) * p.blockSize - (p.window - p.blockSize) / 2;
    float best = sad(a, b, org, int2(0), p.window, 1e9) * 0.95; // prefer "no motion" (HUD, minimap)
    int2 bd = int2(0);
    for (int dy = -p.radius; dy <= p.radius; dy++) {
        for (int dx = -p.radius; dx <= p.radius; dx++) {
            float pen = p.lambda * float(abs(dx) + abs(dy));
            float s = sad(a, b, org, int2(dx, dy), p.window, best - pen) + pen;
            if (s < best) { best = s; bd = int2(dx, dy); }
        }
    }
    if (p.usePrev != 0) {
        // motion of the previous pair: catches fast pans beyond the search radius
        int2 pv = int2(round(prev.read(gid).xy));
        for (int dy = -2; dy <= 2; dy++) {
            for (int dx = -2; dx <= 2; dx++) {
                int2 d = pv + int2(dx, dy);
                float pen = p.lambda * float(abs(d.x) + abs(d.y)) * 0.5;
                float s = sad(a, b, org, d, p.window, best - pen) + pen;
                if (s < best) { best = s; bd = d; }
            }
        }
    }
    mv.write(float4(float2(bd), 0, 0), gid);
}

// Refinement: test upscaled parent vectors (block + 4 neighbours), local search, optional sub-pixel fit.
kernel void me_refine(texture2d<float, access::read>  a      [[texture(0)]],
                      texture2d<float, access::read>  b      [[texture(1)]],
                      texture2d<float, access::read>  parent [[texture(2)]],
                      texture2d<float, access::write> mv     [[texture(3)]],
                      constant MEParams& p [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= mv.get_width() || gid.y >= mv.get_height()) return;
    int2 org = int2(gid) * p.blockSize - (p.window - p.blockSize) / 2;
    int2 pg = int2(gid) / p.parentDiv;
    int2 gmax = int2(parent.get_width() - 1, parent.get_height() - 1);
    const int2 offs[9] = { int2(0,0), int2(1,0), int2(-1,0), int2(0,1), int2(0,-1), int2(1,1), int2(-1,-1), int2(1,-1), int2(-1,1) };
    float best = sad(a, b, org, int2(0), p.window, 1e9) * 0.95;
    int2 bd = int2(0);
    for (int i = 0; i < 9; i++) {
        int2 g = clamp(pg + offs[i], int2(0), gmax);
        int2 c = int2(round(parent.read(uint2(g)).xy * p.parentScale));
        float s = sad(a, b, org, c, p.window, best);
        if (s < best) { best = s; bd = c; }
    }
    int2 center = bd;
    for (int dy = -p.radius; dy <= p.radius; dy++) {
        for (int dx = -p.radius; dx <= p.radius; dx++) {
            if (dx == 0 && dy == 0) continue;
            int2 d = center + int2(dx, dy);
            float s = sad(a, b, org, d, p.window, best);
            if (s < best) { best = s; bd = d; }
        }
    }
    float2 v = float2(bd);
    if (p.subpixel != 0) {
        float s0 = sad(a, b, org, bd, p.window, 1e9);
        float sxm = sad(a, b, org, bd + int2(-1, 0), p.window, 1e9), sxp = sad(a, b, org, bd + int2(1, 0), p.window, 1e9);
        float sym = sad(a, b, org, bd + int2(0, -1), p.window, 1e9), syp = sad(a, b, org, bd + int2(0, 1), p.window, 1e9);
        float dxn = sxm - 2.0 * s0 + sxp, dyn = sym - 2.0 * s0 + syp;
        if (dxn > 1e-5) v.x += clamp((sxm - sxp) / (2.0 * dxn), -0.5, 0.5);
        if (dyn > 1e-5) v.y += clamp((sym - syp) / (2.0 * dyn), -0.5, 0.5);
    }
    mv.write(float4(v, 0, 0), gid);
}

// 3x3 component-wise median: removes outlier vectors.
kernel void median3(texture2d<float, access::read>  src [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    int2 mx = int2(src.get_width() - 1, src.get_height() - 1);
    float xs[9]; float ys[9]; int n = 0;
    for (int dy = -1; dy <= 1; dy++)
        for (int dx = -1; dx <= 1; dx++) {
            float2 v = src.read(uint2(clamp(int2(gid) + int2(dx, dy), int2(0), mx))).xy;
            xs[n] = v.x; ys[n] = v.y; n++;
        }
    for (int i = 1; i < 9; i++) {
        float kx = xs[i]; int j = i - 1;
        while (j >= 0 && xs[j] > kx) { xs[j + 1] = xs[j]; j--; }
        xs[j + 1] = kx;
        float ky = ys[i]; j = i - 1;
        while (j >= 0 && ys[j] > ky) { ys[j + 1] = ys[j]; j--; }
        ys[j + 1] = ky;
    }
    dst.write(float4(xs[4], ys[4], 0, 0), gid);
}

// bidirectional patch cost on 1/2 res luma (coords in full-res pixels)
inline float pcost(texture2d<float, access::sample> LA, texture2d<float, access::sample> LB, sampler s, float2 a, float2 b) {
    a *= 0.5; b *= 0.5;
    float c = fabs(LA.sample(s, a).r - LB.sample(s, b).r) * 2.0;
    c += fabs(LA.sample(s, a + float2( 1.5, 0)).r - LB.sample(s, b + float2( 1.5, 0)).r);
    c += fabs(LA.sample(s, a + float2(-1.5, 0)).r - LB.sample(s, b + float2(-1.5, 0)).r);
    c += fabs(LA.sample(s, a + float2(0,  1.5)).r - LB.sample(s, b + float2(0,  1.5)).r);
    c += fabs(LA.sample(s, a + float2(0, -1.5)).r - LB.sample(s, b + float2(0, -1.5)).r);
    return c * (1.0 / 6.0);
}

// Motion compensated synthesis at source resolution.
kernel void synthesize(texture2d<float, access::sample> A   [[texture(0)]],
                       texture2d<float, access::sample> B   [[texture(1)]],
                       texture2d<float, access::sample> LA  [[texture(2)]],
                       texture2d<float, access::sample> LB  [[texture(3)]],
                       texture2d<float, access::read>   F01 [[texture(4)]],
                       texture2d<float, access::read>   F10 [[texture(5)]],
                       texture2d<float, access::write>  out [[texture(6)]],
                       constant SynthParams& p [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::linear);
    float2 q = float2(gid) + 0.5;
    float t = p.t;
    if (p.mode == 0 || t >= 0.999) { out.write(float4(B.sample(s, q).rgb, 1), gid); return; }
    if (t <= 0.001) { out.write(float4(A.sample(s, q).rgb, 1), gid); return; }
    if (p.cut != 0) { out.write(float4((t < 0.5 ? A.sample(s, q) : B.sample(s, q)).rgb, 1), gid); return; }
    if (p.mode == 2) { out.write(float4(mix(A.sample(s, q).rgb, B.sample(s, q).rgb, t), 1), gid); return; }

    float2 g = q / p.cell - 0.5;
    int2 gi = int2(floor(g));
    float2 f = g - float2(gi);
    int2 gmax = int2(F01.get_width() - 1, F01.get_height() - 1);
    float2 cand[9]; float cost[9];
    for (int k = 0; k < 4; k++) {
        int2 o = int2(k & 1, k >> 1);
        uint2 gg = uint2(clamp(gi + o, int2(0), gmax));
        float w = (o.x == 1 ? f.x : 1.0 - f.x) * (o.y == 1 ? f.y : 1.0 - f.y);
        float pen = (1.0 - w) * 0.015;
        cand[k]     =  F01.read(gg).xy * p.mvScale;  cost[k]     = pen;
        cand[4 + k] = -F10.read(gg).xy * p.mvScale;  cost[4 + k] = pen + 0.002;
    }
    cand[8] = float2(0); cost[8] = 0.008;
    float best = 1e9;
    for (int k = 0; k < 9; k++) {
        float2 v = cand[k];
        cost[k] += pcost(LA, LB, s, q - t * v, q + (1.0 - t) * v);
        best = min(best, cost[k]);
    }
    // occluded areas (visible in only one frame): lean towards the nearer real frame
    float occ = smoothstep(p.occLo, p.occHi, best);
    float alpha = mix(t, t < 0.5 ? 0.0 : 1.0, occ);
    float3 acc = float3(0); float wsum = 0;
    for (int k = 0; k < 9; k++) {
        float w = exp(-(cost[k] - best) / p.sigma);
        if (w < 0.03) continue;
        float2 v = cand[k];
        float3 c = mix(A.sample(s, q - t * v).rgb, B.sample(s, q + (1.0 - t) * v).rgb, alpha);
        acc += c * w; wsum += w;
    }
    out.write(float4(acc / max(wsum, 1e-5), 1), gid);
}

// Aspect-fit scaling to the window + contrast adaptive sharpening.
kernel void present(texture2d<float, access::sample> src [[texture(0)]],
                    texture2d<float, access::write>  out [[texture(1)]],
                    constant PresentParams& p [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::linear);
    float2 q = (float2(gid) + 0.5 - p.offset) / p.scale;
    if (q.x < 0 || q.y < 0 || q.x >= p.srcSize.x || q.y >= p.srcSize.y) { out.write(float4(0, 0, 0, 1), gid); return; }
    float3 c = src.sample(s, q).rgb;
    if (p.sharpen > 0.001) {
        float3 n = src.sample(s, q + float2(0, -1)).rgb, so = src.sample(s, q + float2(0, 1)).rgb;
        float3 e = src.sample(s, q + float2(1, 0)).rgb, w = src.sample(s, q + float2(-1, 0)).rgb;
        float3 mn = min(c, min(min(n, so), min(e, w)));
        float3 mx = max(c, max(max(n, so), max(e, w)));
        float3 amp = sqrt(clamp(min(mn, 1.0 - mx) / max(mx, 1e-4), 0.0, 1.0));
        float3 wt = -amp / mix(8.0, 5.0, p.sharpen);
        c = clamp((c + (n + so + e + w) * wt) / (1.0 + 4.0 * wt), 0.0, 1.0);
    }
    out.write(float4(c, 1), gid);
}
"""
