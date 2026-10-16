//! A single DirectWrite font face (one family + weight + style).
//!
//! IDWriteFontFace is size independent; the em size is only applied
//! when rasterizing, so one Face serves every font size and DPI.
const Face = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("../win32/win32.zig");
const com = win32.com;
const dwrite = win32.dwrite;

face: *dwrite.IFontFace,
metrics: dwrite.FONT_METRICS,

pub const Error = com.Error || error{FontNotFound};

pub fn init(
    collection: *dwrite.IFontCollection,
    family: [:0]const u16,
    weight: dwrite.FONT_WEIGHT,
    style: dwrite.FONT_STYLE,
) Error!Face {
    var index: u32 = 0;
    var exists: win32.BOOL = win32.FALSE;
    try com.check(collection.findFamilyName(family.ptr, &index, &exists), "IDWriteFontCollection::FindFamilyName");
    if (exists == win32.FALSE) return error.FontNotFound;

    var font_family: ?*dwrite.IFontFamily = null;
    try com.check(collection.getFontFamily(index, &font_family), "IDWriteFontCollection::GetFontFamily");
    defer com.releaseOpt(&font_family);

    // DirectWrite simulates bold/oblique if the family lacks that face.
    var font: ?*dwrite.IFont = null;
    try com.check(
        font_family.?.getFirstMatchingFont(weight, dwrite.FONT_STRETCH_NORMAL, style, &font),
        "IDWriteFontFamily::GetFirstMatchingFont",
    );
    defer com.releaseOpt(&font);

    var face: ?*dwrite.IFontFace = null;
    try com.check(font.?.createFontFace(&face), "IDWriteFont::CreateFontFace");

    var metrics: dwrite.FONT_METRICS = undefined;
    face.?.getMetrics(&metrics);
    return .{ .face = face.?, .metrics = metrics };
}

pub fn deinit(self: *Face) void {
    com.release(self.face);
    self.* = undefined;
}

/// The glyph index for a codepoint, or null if the face doesn't have it.
pub fn glyphIndex(self: *const Face, cp: u21) ?u16 {
    const cps = [_]u32{cp};
    var glyphs = [_]u16{0};
    if (self.face.getGlyphIndices(&cps, &glyphs) < 0) return null;
    return if (glyphs[0] == 0) null else glyphs[0];
}

/// Horizontal advance of a glyph in design units.
pub fn advance(self: *const Face, glyph: u16) ?u32 {
    const glyphs = [_]u16{glyph};
    var metrics: [1]dwrite.GLYPH_METRICS = undefined;
    if (self.face.getDesignGlyphMetrics(&glyphs, &metrics) < 0) return null;
    return metrics[0].advanceWidth;
}

pub const Bitmap = struct {
    /// Bitmap position relative to the pen position on the baseline.
    /// `top` is negative above the baseline.
    left: i32,
    top: i32,
    width: u32,
    height: u32,
    /// 8-bit coverage, tightly packed rows. Empty for blank glyphs.
    pixels: []u8,

    pub fn deinit(self: *Bitmap, alloc: Allocator) void {
        alloc.free(self.pixels);
        self.* = undefined;
    }
};

/// Rasterize a glyph to grayscale coverage at `em_px` pixels per em.
pub fn rasterize(
    self: *const Face,
    alloc: Allocator,
    factory: *dwrite.IFactory2,
    glyph: u16,
    em_px: f32,
) (com.Error || Allocator.Error)!Bitmap {
    const glyphs = [_]u16{glyph};
    const run: dwrite.GLYPH_RUN = .{
        .fontFace = self.face,
        .fontEmSize = em_px,
        .glyphCount = 1,
        .glyphIndices = &glyphs,
    };

    var analysis: ?*dwrite.IGlyphRunAnalysis = null;
    try com.check(factory.createGlyphRunAnalysis(
        &run,
        dwrite.RENDERING_MODE_NATURAL_SYMMETRIC,
        dwrite.MEASURING_MODE_NATURAL,
        dwrite.GRID_FIT_MODE_DEFAULT,
        dwrite.TEXT_ANTIALIAS_MODE_GRAYSCALE,
        0,
        0,
        &analysis,
    ), "IDWriteFactory2::CreateGlyphRunAnalysis");
    defer com.releaseOpt(&analysis);

    // With grayscale antialiasing the 1x1 texture holds coverage values,
    // not just on/off pixels.
    var bounds: win32.RECT = undefined;
    try com.check(
        analysis.?.getAlphaTextureBounds(dwrite.TEXTURE_ALIASED_1x1, &bounds),
        "IDWriteGlyphRunAnalysis::GetAlphaTextureBounds",
    );

    const width: u32 = @intCast(@max(0, bounds.right - bounds.left));
    const height: u32 = @intCast(@max(0, bounds.bottom - bounds.top));
    const pixels = try alloc.alloc(u8, @as(usize, width) * height);
    errdefer alloc.free(pixels);
    if (pixels.len > 0) {
        try com.check(
            analysis.?.createAlphaTexture(dwrite.TEXTURE_ALIASED_1x1, &bounds, pixels),
            "IDWriteGlyphRunAnalysis::CreateAlphaTexture",
        );
    }

    return .{
        .left = bounds.left,
        .top = bounds.top,
        .width = width,
        .height = height,
        .pixels = pixels,
    };
}
