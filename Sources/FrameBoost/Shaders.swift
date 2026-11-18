// Metal shaders for FrameBoost's own frame generation.
// Pipeline per new source frame:  luma pyramid -> coarse block matching -> refine -> median filter
// Per display refresh:            motion-compensated synthesis at time t (0..1) between frame A and B.
let frameBoostShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct MEParams { int radius; int blockSize; int window; float lambda; };
struct SynthParams {
    float t; float scale; float2 offset;
    float2 srcSize; float cell; float mvScale;
    int mode; int pad0; int pad1; int pad2;
};

inline float lum(float4 c) { return dot(c.rgb, float3(0.299, 0.587, 0.114)); }

// full res BGRA -> 1/4 res luma (box filter 4x4)
kernel void luma_down4(texture2d<float, access::read>  src [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    uint w = src.get_width() - 1, h = src.get_height() - 1;
    uint2 base = gid * 4;
    float s = 0.0;
    for (uint y = 0; y < 4; y++)
        for (uint x = 0; x < 4; x++)
            s += lum(src.read(uint2(min(base.x + x, w), min(base.y + y, h))));
    dst.write(float4(s / 16.0), gid);
}

// 1/4 -> 1/8 luma
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

// Full search block matching at 1/8 res. Output: vector (in 1/8 px) per block.
kernel void me_coarse(texture2d<float, access::read>  a  [[texture(0)]],
                      texture2d<float, access::read>  b  [[texture(1)]],
                      texture2d<float, access::write> mv [[texture(2)]],
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
    mv.write(float4(float2(bd), 0, 0), gid);
}

// Refinement at 1/4 res: test upscaled coarse vectors of block + neighbours, then +-2 local search.
kernel void me_refine(texture2d<float, access::read>  a      [[texture(0)]],
                      texture2d<float, access::read>  b      [[texture(1)]],
                      texture2d<float, access::read>  coarse [[texture(2)]],
                      texture2d<float, access::write> mv     [[texture(3)]],
                      constant MEParams& p [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= mv.get_width() || gid.y >= mv.get_height()) return;
    int2 org = int2(gid) * p.blockSize - (p.window - p.blockSize) / 2;
    int2 gmax = int2(coarse.get_width() - 1, coarse.get_height() - 1);
    const int2 offs[5] = { int2(0,0), int2(1,0), int2(-1,0), int2(0,1), int2(0,-1) };
    float best = sad(a, b, org, int2(0), p.window, 1e9) * 0.95;
    int2 bd = int2(0);
    for (int i = 0; i < 5; i++) {
        int2 g = clamp(int2(gid) + offs[i], int2(0), gmax);
        int2 c = int2(round(coarse.read(uint2(g)).xy * 2.0));
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
    mv.write(float4(float2(bd), 0, 0), gid);
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

// Motion compensated synthesis directly into the output (letterboxed).
kernel void synthesize(texture2d<float, access::sample> A   [[texture(0)]],
                       texture2d<float, access::sample> B   [[texture(1)]],
                       texture2d<float, access::sample> F01 [[texture(2)]],
                       texture2d<float, access::sample> F10 [[texture(3)]],
                       texture2d<float, access::write>  out [[texture(4)]],
                       constant SynthParams& p [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::linear);
    float2 q = (float2(gid) + 0.5 - p.offset) / p.scale;
    if (q.x < 0 || q.y < 0 || q.x >= p.srcSize.x || q.y >= p.srcSize.y) { out.write(float4(0, 0, 0, 1), gid); return; }
    float t = p.t;
    if (p.mode == 0 || t >= 0.999) { out.write(float4(B.sample(s, q).rgb, 1), gid); return; }
    if (t <= 0.001) { out.write(float4(A.sample(s, q).rgb, 1), gid); return; }
    if (p.mode == 2) { out.write(float4(mix(A.sample(s, q).rgb, B.sample(s, q).rgb, t), 1), gid); return; }

    // fixed point iteration: find the vector of the pixel that actually lands on q
    float2 v = F01.sample(s, q / p.cell).xy * p.mvScale;
    float2 w = F10.sample(s, q / p.cell).xy * p.mvScale;
    for (int i = 0; i < 3; i++) {
        v = F01.sample(s, (q - t * v) / p.cell).xy * p.mvScale;
        w = F10.sample(s, (q - (1.0 - t) * w) / p.cell).xy * p.mvScale;
    }
    float2 p0 = q - t * v;
    float2 p1 = q - (1.0 - t) * w;
    float3 c0 = A.sample(s, p0).rgb;
    float3 c1 = B.sample(s, p1).rgb;
    // occlusion handling: forward and backward vectors must agree, otherwise trust the closer frame
    float inc = length(v + w);
    float w0 = (1.0 - t), w1 = t;
    if (inc > 6.0) {
        // A-pixel lands at p0+v in B: the backward vector there must be -v (else it gets covered)
        float eA = length(F10.sample(s, (p0 + v) / p.cell).xy * p.mvScale + v);
        float eB = length(F01.sample(s, (p1 + w) / p.cell).xy * p.mvScale + w);
        w0 *= exp(-eA * 0.08);
        w1 *= exp(-eB * 0.08);
    }
    float3 c = (c0 * w0 + c1 * w1) / max(w0 + w1, 1e-4);
    out.write(float4(c, 1), gid);
}
"""
