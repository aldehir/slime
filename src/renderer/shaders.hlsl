// Terminal grid shaders. Two passes, with kitty images (image_vs/ps)
// drawn before, between, and after them by z-index:
//
//   1. bg: a full-screen triangle; each pixel looks up its cell's
//      background color. Default backgrounds are transparent, over the
//      default background (fill_ps) and any kitty images below the
//      background.
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

// The terminal's default background over its whole viewport, before
// anything else: a window draws several terminals (panes), each its own.
float4 fill_ps(float4 pos : SV_Position) : SV_Target {
    return default_bg;
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
