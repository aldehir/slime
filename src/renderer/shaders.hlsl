// Terminal grid shaders. Two passes, with kitty images (image_vs/ps)
// drawn before, between, and after them by z-index:
//
//   1. bg: a full-screen triangle; each pixel looks up its cell's
//      background color. Default backgrounds are transparent, over the
//      cleared frame and any kitty images below the background.
//   2. text: instanced quads for glyphs (sampled from the atlas) and solid
//      rectangles (cursor, underline, strikethrough), blended with
//      premultiplied alpha.
//
// Layouts must match `Uniforms` and `Instance` in cells.zig.

cbuffer Uniforms : register(b0) {
    float2 screen_size;
    float2 cell_size;
    uint2 grid_size;
    float2 grid_offset;
    float4 default_bg;
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

static const uint KIND_GLYPH = 0;

float4 unpack(uint c) {
    return float4(c & 0xff, (c >> 8) & 0xff, (c >> 16) & 0xff, c >> 24) / 255.0;
}

float4 to_ndc(float2 px) {
    return float4(px / screen_size * float2(2, -2) + float2(-1, 1), 0, 1);
}

float4 bg_vs(uint id : SV_VertexID) : SV_Position {
    // (0,0), (2,0), (0,2) in UV space covers the screen with one triangle.
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

float4 text_ps(TextVsOut i) : SV_Target {
    // Quads are pixel aligned, so the interpolated texel coordinate lands
    // on texel centers and Load needs no sampler.
    float a = i.kind == KIND_GLYPH ? atlas.Load(int3(i.tex, 0)) : 1.0;
    a *= i.color.a;
    return float4(i.color.rgb * a, a);
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

Texture2D<float4> image : register(t4);
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
