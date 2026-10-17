// Terminal grid shaders. Two passes, with kitty images (image_vs/ps)
// drawn before, between, and after them by z-index:
//
//   1. bg: a full-screen triangle; each pixel looks up its cell's
//      background color. Default backgrounds are transparent, over the
//      pane (box_ps) and any kitty images below the background.
//   2. text: instanced quads for glyphs (sampled from the coverage atlas,
//      the RGBA one for color glyphs, or the ClearType one) and solid
//      rectangles (cursor, underline, strikethrough), blended with a
//      premultiplied alpha per channel (dual-source blending).
//
// Everything is drawn into a viewport, the window's terminal area, which
// clips it. Positions are in render target pixels, as SV_Position is.
//
// Layouts must match `Uniforms` and `Instance` in cells.zig.

cbuffer Uniforms : register(b0) {
    float4 default_bg;
    float2 viewport_origin;
    float2 viewport_size;
    float2 cell_size;
    uint2 grid_size;
    float2 grid_offset;
};

struct Instance {
    float2 pos;
    float2 size;
    uint2 atlas_pos;
    uint color;
    uint kind;
};

StructuredBuffer<uint> bg_cells : register(t0);
StructuredBuffer<Instance> instances : register(t1);
Texture2D<float> atlas : register(t2);
Texture2D<float4> color_atlas : register(t3);
Texture2D<float4> lcd_atlas : register(t4);

static const uint KIND_GLYPH = 0;
static const uint KIND_COLOR_GLYPH = 2;
static const uint KIND_LCD_GLYPH = 3;

float4 unpack(uint c) {
    return float4(c & 0xff, (c >> 8) & 0xff, (c >> 16) & 0xff, c >> 24) / 255.0;
}

float4 to_ndc(float2 px) {
    return float4((px - viewport_origin) / viewport_size * float2(2, -2) + float2(-1, 1), 0, 1);
}

float4 bg_vs(uint id : SV_VertexID) : SV_Position {
    // (0,0), (2,0), (0,2) in UV space covers the viewport with one triangle.
    float2 uv = float2((id << 1) & 2, id & 2);
    return float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
}

float4 bg_ps(float4 pos : SV_Position) : SV_Target {
    float2 p = pos.xy - grid_offset;
    if (p.x < 0 || p.y < 0) return 0;
    uint2 cell = uint2(p / cell_size);
    if (cell.x >= grid_size.x || cell.y >= grid_size.y) return 0;
    return unpack(bg_cells[cell.y * grid_size.x + cell.x]);
}

struct TextVsOut {
    float4 pos : SV_Position;
    float2 tex : TEXCOORD0;
    nointerpolation float4 color : COLOR0;
    nointerpolation uint kind : KIND;
};

TextVsOut text_vs(uint vid : SV_VertexID, uint iid : SV_InstanceID) {
    Instance inst = instances[iid];

    // Triangle strip corners: (0,0), (1,0), (0,1), (1,1).
    float2 corner = float2(vid & 1, vid >> 1);

    TextVsOut o;
    o.pos = to_ndc(grid_offset + inst.pos + corner * inst.size);
    o.tex = inst.atlas_pos + corner * inst.size;
    o.color = unpack(inst.color);
    o.kind = inst.kind;
    return o;
}

// The color, premultiplied, and the coverage each channel blends by.
struct TextPsOut {
    float4 color : SV_Target0;
    float4 coverage : SV_Target1;
};

TextPsOut text_ps(TextVsOut i) {
    // Quads are pixel aligned, so the interpolated texel coordinate lands
    // on texel centers and Load needs no sampler. Color glyphs are
    // premultiplied and keep only their cell color's alpha.
    int3 texel = int3(i.tex, 0);
    TextPsOut o;
    if (i.kind == KIND_COLOR_GLYPH) {
        o.color = color_atlas.Load(texel) * i.color.a;
        o.coverage = o.color.a;
        return o;
    }

    float4 c;
    if (i.kind == KIND_LCD_GLYPH) c = lcd_atlas.Load(texel);
    else c = i.kind == KIND_GLYPH ? atlas.Load(texel) : 1.0;
    c *= i.color.a;
    o.color = float4(i.color.rgb * c.rgb, c.a);
    o.coverage = c;
    return o;
}

// Kitty graphics: one quad per placement, with the placement in a
// constant buffer and its image bound per draw. Images are
// premultiplied, so linear filtering doesn't bleed the color of
// transparent pixels. Layout must match `Placement` in image.zig.

cbuffer ImagePlacement : register(b1) {
    float2 image_pos;
    float2 image_size;
    float2 image_src_pos;
    float2 image_src_size;
};

Texture2D<float4> image : register(t5);
SamplerState image_sampler : register(s0);

struct ImageVsOut {
    float4 pos : SV_Position;
    float2 tex : TEXCOORD0;
};

ImageVsOut image_vs(uint vid : SV_VertexID) {
    float2 corner = float2(vid & 1, vid >> 1);

    ImageVsOut o;
    o.pos = to_ndc(grid_offset + image_pos + corner * image_size);
    o.tex = image_src_pos + corner * image_src_size;
    return o;
}

float4 image_ps(ImageVsOut i) : SV_Target {
    float2 size;
    image.GetDimensions(size.x, size.y);
    return image.Sample(image_sampler, i.tex / size);
}

// A pane's box, before its grid: its shadow (shadow_ps, every pane's
// first, so none falls on a neighbor), then its rounded fill and border
// (box_ps). Both draw a quad over `bounds`, in render target pixels, and
// find each pixel's coverage from its distance to the rounded box, so
// edges are antialiased without masks. Layout must match `Box` in
// D3D11.zig.

cbuffer Box : register(b2) {
    float2 target_size;
    float radius;
    float border_width;
    float4 bounds;
    // The box: x, y, width, height.
    float4 box;
    // Premultiplied.
    float4 fill;
    float4 border;
    float4 shadow;
    float shadow_sigma;
    float3 _box_pad;
};

static const float PI = 3.14159265;

float4 box_vs(uint vid : SV_VertexID) : SV_Position {
    float2 corner = float2(vid & 1, vid >> 1);
    float2 px = bounds.xy + corner * bounds.zw;
    return float4(px / target_size * float2(2, -2) + float2(-1, 1), 0, 1);
}

// Signed distance from `p` to the box's rounded edge: negative inside.
float box_distance(float2 p) {
    float2 half_size = box.zw * 0.5;
    float2 q = abs(p - (box.xy + half_size)) - half_size + radius;
    return length(max(q, 0)) + min(max(q.x, q.y), 0) - radius;
}

float4 box_ps(float4 pos : SV_Position) : SV_Target {
    float d = box_distance(pos.xy);
    float outer = saturate(0.5 - d);
    float inner = saturate(0.5 - (d + border_width));
    // The border over the fill, in a ring inside the edge.
    float4 ring = border + fill * (1 - border.a);
    return fill * inner + ring * (outer - inner);
}

// The blur of a rounded box, after Evan Wallace's "Fast rounded rectangle
// shadows": exact across, a few samples of a Gaussian down.
float gaussian(float x, float sigma) {
    return exp(-(x * x) / (2 * sigma * sigma)) / (sqrt(2 * PI) * sigma);
}

float2 erf2(float2 x) {
    float2 s = sign(x);
    float2 a = abs(x);
    x = 1 + (0.278393 + (0.230389 + 0.078108 * (a * a)) * a) * a;
    x *= x;
    return s - s / (x * x);
}

float shadow_x(float x, float y, float sigma, float corner, float2 half_size) {
    float delta = min(half_size.y - corner - abs(y), 0);
    float curved = half_size.x - corner + sqrt(max(0, corner * corner - delta * delta));
    float2 integral = 0.5 + 0.5 * erf2((x + float2(-curved, curved)) * (sqrt(0.5) / sigma));
    return integral.y - integral.x;
}

float4 shadow_ps(float4 pos : SV_Position) : SV_Target {
    float2 half_size = box.zw * 0.5;
    float2 p = pos.xy - (box.xy + half_size);
    float sigma = max(shadow_sigma, 0.5);
    float corner = min(radius, min(half_size.x, half_size.y));
    float low = p.y - half_size.y;
    float high = p.y + half_size.y;
    float start = clamp(-3 * sigma, low, high);
    float end = clamp(3 * sigma, low, high);
    float step = (end - start) / 4.0;
    float y = start + step * 0.5;
    float value = 0;
    for (int i = 0; i < 4; i++) {
        value += shadow_x(p.x, p.y - y, sigma, corner, half_size) * gaussian(y, sigma) * step;
        y += step;
    }
    return shadow * value;
}
