//! DirectWrite interfaces. Slot numbers are from dwrite.h / dwrite_2.h.

const win32 = @import("win32.zig");
const com = @import("com.zig");

const BOOL = win32.BOOL;
const HRESULT = win32.HRESULT;
const GUID = win32.GUID;

pub const FACTORY_TYPE_SHARED: u32 = 0;
pub const FONT_STRETCH_NORMAL: u32 = 5;
pub const RENDERING_MODE_NATURAL_SYMMETRIC: u32 = 5;
pub const MEASURING_MODE_NATURAL: u32 = 0;
pub const GRID_FIT_MODE_DEFAULT: u32 = 0;
pub const TEXT_ANTIALIAS_MODE_GRAYSCALE: u32 = 1;
pub const TEXTURE_ALIASED_1x1: u32 = 0;

pub const FONT_WEIGHT = enum(u32) {
    NORMAL = 400,
    BOLD = 700,
    _,
};

pub const FONT_STYLE = enum(u32) {
    NORMAL = 0,
    OBLIQUE = 1,
    ITALIC = 2,
};

pub const FONT_METRICS = extern struct {
    designUnitsPerEm: u16,
    ascent: u16,
    descent: u16,
    lineGap: i16,
    capHeight: u16,
    xHeight: u16,
    underlinePosition: i16,
    underlineThickness: u16,
    strikethroughPosition: i16,
    strikethroughThickness: u16,
};

pub const GLYPH_METRICS = extern struct {
    leftSideBearing: i32,
    advanceWidth: u32,
    rightSideBearing: i32,
    topSideBearing: i32,
    advanceHeight: u32,
    bottomSideBearing: i32,
    verticalOriginY: i32,
};

pub const GLYPH_OFFSET = extern struct {
    advanceOffset: f32,
    ascenderOffset: f32,
};

pub const GLYPH_RUN = extern struct {
    fontFace: *IFontFace,
    fontEmSize: f32,
    glyphCount: u32,
    glyphIndices: [*]const u16,
    glyphAdvances: ?[*]const f32 = null,
    glyphOffsets: ?[*]const GLYPH_OFFSET = null,
    isSideways: BOOL = win32.FALSE,
    bidiLevel: u32 = 0,
};

pub const IFactory2 = extern struct {
    vtable: com.VTable,

    pub const iid: GUID = .{
        .data1 = 0x0439fc60,
        .data2 = 0xca44,
        .data3 = 0x4994,
        .data4 = .{ 0x8d, 0xee, 0x3a, 0x9a, 0xf7, 0xb7, 0x32, 0xec },
    };

    pub fn getSystemFontCollection(self: *IFactory2, out: *?*IFontCollection) HRESULT {
        return com.call(self, 3, fn (*?*IFontCollection, BOOL) HRESULT, .{ out, win32.FALSE });
    }

    /// IDWriteFactory2::CreateGlyphRunAnalysis, the overload that takes
    /// grid fit and antialias modes.
    pub fn createGlyphRunAnalysis(
        self: *IFactory2,
        run: *const GLYPH_RUN,
        rendering_mode: u32,
        measuring_mode: u32,
        grid_fit_mode: u32,
        antialias_mode: u32,
        origin_x: f32,
        origin_y: f32,
        out: *?*IGlyphRunAnalysis,
    ) HRESULT {
        return com.call(self, 30, fn (
            *const GLYPH_RUN,
            ?*const anyopaque, // DWRITE_MATRIX
            u32,
            u32,
            u32,
            u32,
            f32,
            f32,
            *?*IGlyphRunAnalysis,
        ) HRESULT, .{
            run,
            null,
            rendering_mode,
            measuring_mode,
            grid_fit_mode,
            antialias_mode,
            origin_x,
            origin_y,
            out,
        });
    }
};

pub const IFontCollection = extern struct {
    vtable: com.VTable,

    pub fn getFontFamily(self: *IFontCollection, index: u32, out: *?*IFontFamily) HRESULT {
        return com.call(self, 4, fn (u32, *?*IFontFamily) HRESULT, .{ index, out });
    }

    pub fn findFamilyName(self: *IFontCollection, name: win32.LPCWSTR, index: *u32, exists: *BOOL) HRESULT {
        return com.call(self, 5, fn (win32.LPCWSTR, *u32, *BOOL) HRESULT, .{ name, index, exists });
    }
};

pub const IFontFamily = extern struct {
    vtable: com.VTable,

    pub fn getFirstMatchingFont(
        self: *IFontFamily,
        weight: FONT_WEIGHT,
        stretch: u32,
        style: FONT_STYLE,
        out: *?*IFont,
    ) HRESULT {
        return com.call(self, 7, fn (FONT_WEIGHT, u32, FONT_STYLE, *?*IFont) HRESULT, .{
            weight, stretch, style, out,
        });
    }
};

pub const IFont = extern struct {
    vtable: com.VTable,

    pub fn createFontFace(self: *IFont, out: *?*IFontFace) HRESULT {
        return com.call(self, 13, fn (*?*IFontFace) HRESULT, .{out});
    }
};

pub const IFontFace = extern struct {
    vtable: com.VTable,

    pub fn getMetrics(self: *IFontFace, out: *FONT_METRICS) void {
        com.call(self, 8, fn (*FONT_METRICS) void, .{out});
    }

    pub fn getDesignGlyphMetrics(self: *IFontFace, glyphs: []const u16, out: []GLYPH_METRICS) HRESULT {
        return com.call(self, 10, fn ([*]const u16, u32, [*]GLYPH_METRICS, BOOL) HRESULT, .{
            glyphs.ptr, @as(u32, @intCast(glyphs.len)), out.ptr, win32.FALSE,
        });
    }

    pub fn getGlyphIndices(self: *IFontFace, codepoints: []const u32, out: []u16) HRESULT {
        return com.call(self, 11, fn ([*]const u32, u32, [*]u16) HRESULT, .{
            codepoints.ptr, @as(u32, @intCast(codepoints.len)), out.ptr,
        });
    }
};

pub const IGlyphRunAnalysis = extern struct {
    vtable: com.VTable,

    pub fn getAlphaTextureBounds(self: *IGlyphRunAnalysis, texture_type: u32, out: *win32.RECT) HRESULT {
        return com.call(self, 3, fn (u32, *win32.RECT) HRESULT, .{ texture_type, out });
    }

    pub fn createAlphaTexture(
        self: *IGlyphRunAnalysis,
        texture_type: u32,
        bounds: *const win32.RECT,
        out: []u8,
    ) HRESULT {
        return com.call(self, 4, fn (u32, *const win32.RECT, [*]u8, u32) HRESULT, .{
            texture_type, bounds, out.ptr, @as(u32, @intCast(out.len)),
        });
    }
};

pub extern "dwrite" fn DWriteCreateFactory(
    factory_type: u32,
    iid: *const GUID,
    out: *?*anyopaque,
) callconv(.winapi) HRESULT;
