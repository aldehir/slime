//! DirectWrite interfaces. Slot numbers are from dwrite.h / dwrite_2.h.

const std = @import("std");
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

pub const TEXT_ALIGNMENT_LEADING: u32 = 0;
pub const TEXT_ALIGNMENT_TRAILING: u32 = 1;
pub const TEXT_ALIGNMENT_CENTER: u32 = 2;
pub const PARAGRAPH_ALIGNMENT_CENTER: u32 = 2;
pub const WORD_WRAPPING_NO_WRAP: u32 = 1;
pub const TRIMMING_GRANULARITY_CHARACTER: u32 = 1;

pub const FONT_WEIGHT = enum(u32) {
    NORMAL = 400,
    SEMI_BOLD = 600,
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

    pub fn createTextFormat(
        self: *IFactory2,
        family: win32.LPCWSTR,
        weight: FONT_WEIGHT,
        size: f32,
        out: *?*ITextFormat,
    ) HRESULT {
        return com.call(self, 15, fn (win32.LPCWSTR, ?*IFontCollection, FONT_WEIGHT, FONT_STYLE, u32, f32, win32.LPCWSTR, *?*ITextFormat) HRESULT, .{
            family,
            null,
            weight,
            .NORMAL,
            FONT_STRETCH_NORMAL,
            size,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            out,
        });
    }

    pub fn createTextLayout(self: *IFactory2, text: []const u16, format: *ITextFormat, max_width: f32, max_height: f32, out: *?*ITextLayout) HRESULT {
        return com.call(self, 18, fn ([*]const u16, u32, *ITextFormat, f32, f32, *?*ITextLayout) HRESULT, .{
            text.ptr, @as(u32, @intCast(text.len)), format, max_width, max_height, out,
        });
    }

    pub fn createEllipsisTrimmingSign(self: *IFactory2, format: *ITextFormat, out: *?*IInlineObject) HRESULT {
        return com.call(self, 20, fn (*ITextFormat, *?*IInlineObject) HRESULT, .{ format, out });
    }

    pub fn createTextAnalyzer(self: *IFactory2, out: *?*ITextAnalyzer) HRESULT {
        return com.call(self, 21, fn (*?*ITextAnalyzer) HRESULT, .{out});
    }

    pub fn getSystemFontFallback(self: *IFactory2, out: *?*IFontFallback) HRESULT {
        return com.call(self, 26, fn (*?*IFontFallback) HRESULT, .{out});
    }

    /// Split a run into its color layers, in palette 0. Returns E_NOCOLOR
    /// if the run has no color glyphs.
    pub fn translateColorGlyphRun(
        self: *IFactory2,
        origin_x: f32,
        origin_y: f32,
        run: *const GLYPH_RUN,
        out: *?*IColorGlyphRunEnumerator,
    ) HRESULT {
        return com.call(self, 28, fn (
            f32,
            f32,
            *const GLYPH_RUN,
            ?*const anyopaque, // DWRITE_GLYPH_RUN_DESCRIPTION
            u32,
            ?*const anyopaque, // DWRITE_MATRIX
            u32,
            *?*IColorGlyphRunEnumerator,
        ) HRESULT, .{ origin_x, origin_y, run, null, MEASURING_MODE_NATURAL, null, 0, out });
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

pub const TRIMMING = extern struct {
    granularity: u32,
    delimiter: u32 = 0,
    delimiterCount: u32 = 0,
};

pub const TEXT_METRICS = extern struct {
    left: f32,
    top: f32,
    width: f32,
    widthIncludingTrailingWhitespace: f32,
    height: f32,
    layoutWidth: f32,
    layoutHeight: f32,
    maxBidiReorderingDepth: u32,
    lineCount: u32,
};

pub const ITextFormat = extern struct {
    vtable: com.VTable,

    pub fn setTextAlignment(self: *ITextFormat, alignment: u32) HRESULT {
        return com.call(self, 3, fn (u32) HRESULT, .{alignment});
    }

    pub fn setParagraphAlignment(self: *ITextFormat, alignment: u32) HRESULT {
        return com.call(self, 4, fn (u32) HRESULT, .{alignment});
    }

    pub fn setWordWrapping(self: *ITextFormat, wrapping: u32) HRESULT {
        return com.call(self, 5, fn (u32) HRESULT, .{wrapping});
    }

    pub fn setTrimming(self: *ITextFormat, trimming: *const TRIMMING, sign: ?*IInlineObject) HRESULT {
        return com.call(self, 9, fn (*const TRIMMING, ?*IInlineObject) HRESULT, .{ trimming, sign });
    }
};

pub const ITextLayout = extern struct {
    vtable: com.VTable,

    pub fn getMetrics(self: *ITextLayout, out: *TEXT_METRICS) HRESULT {
        return com.call(self, 60, fn (*TEXT_METRICS) HRESULT, .{out});
    }
};

pub const IInlineObject = extern struct { vtable: com.VTable };

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

    pub fn getFamilyNames(self: *IFontFamily, out: *?*ILocalizedStrings) HRESULT {
        return com.call(self, 6, fn (*?*ILocalizedStrings) HRESULT, .{out});
    }

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

    pub fn getFontFamily(self: *IFont, out: *?*IFontFamily) HRESULT {
        return com.call(self, 3, fn (*?*IFontFamily) HRESULT, .{out});
    }

    pub fn createFontFace(self: *IFont, out: *?*IFontFace) HRESULT {
        return com.call(self, 13, fn (*?*IFontFace) HRESULT, .{out});
    }
};

pub const ILocalizedStrings = extern struct {
    vtable: com.VTable,

    /// Copy string `index` into `buf`, truncating if needed.
    pub fn getString(self: *ILocalizedStrings, index: u32, buf: []u16) HRESULT {
        return com.call(self, 8, fn (u32, [*]u16, u32) HRESULT, .{ index, buf.ptr, @as(u32, @intCast(buf.len)) });
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

pub const IFontFace2 = extern struct {
    vtable: com.VTable,

    pub const iid: GUID = .{
        .data1 = 0xd8b768ff,
        .data2 = 0x64bc,
        .data3 = 0x4e66,
        .data4 = .{ 0x98, 0x2b, 0xec, 0x8e, 0x87, 0xf6, 0x93, 0xf7 },
    };

    pub fn isColorFont(self: *IFontFace2) bool {
        return com.call(self, 30, fn () BOOL, .{}) != win32.FALSE;
    }
};

pub const E_NOCOLOR: HRESULT = @bitCast(@as(u32, 0x8898500C));

/// A layer's `paletteIndex` when it's drawn in the text color.
pub const NO_PALETTE_INDEX: u16 = 0xFFFF;

/// Straight (not premultiplied) RGBA.
pub const COLOR_F = extern struct { r: f32, g: f32, b: f32, a: f32 };

pub const COLOR_GLYPH_RUN = extern struct {
    glyphRun: GLYPH_RUN,
    glyphRunDescription: ?*const anyopaque,
    baselineOriginX: f32,
    baselineOriginY: f32,
    runColor: COLOR_F,
    paletteIndex: u16,
};

pub const IColorGlyphRunEnumerator = extern struct {
    vtable: com.VTable,

    pub fn moveNext(self: *IColorGlyphRunEnumerator, has_run: *BOOL) HRESULT {
        return com.call(self, 3, fn (*BOOL) HRESULT, .{has_run});
    }

    /// Valid until the next `moveNext`.
    pub fn getCurrentRun(self: *IColorGlyphRunEnumerator, out: *?*const COLOR_GLYPH_RUN) HRESULT {
        return com.call(self, 4, fn (*?*const COLOR_GLYPH_RUN) HRESULT, .{out});
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

pub const READING_DIRECTION_LEFT_TO_RIGHT: u32 = 0;
pub const E_NOT_SUFFICIENT_BUFFER: HRESULT = @bitCast(@as(u32, 0x8007007A));

pub const SCRIPT_ANALYSIS = extern struct {
    script: u16,
    shapes: u32,
};

/// DWRITE_SHAPING_TEXT_PROPERTIES and DWRITE_SHAPING_GLYPH_PROPERTIES
/// are 16-bit bitfields we only pass between GetGlyphs and
/// GetGlyphPlacements.
pub const SHAPING_TEXT_PROPERTIES = u16;
pub const SHAPING_GLYPH_PROPERTIES = u16;

pub const IFontFallback = extern struct {
    vtable: com.VTable,

    /// Find a font for the text at `position` in `source`. `mapped_len`
    /// is how much of the text the returned font covers; `out` is null
    /// if no font covers it.
    pub fn mapCharacters(
        self: *IFontFallback,
        source: *ITextAnalysisSource,
        position: u32,
        len: u32,
        base_collection: ?*IFontCollection,
        base_family: ?win32.LPCWSTR,
        weight: FONT_WEIGHT,
        style: FONT_STYLE,
        mapped_len: *u32,
        out: *?*IFont,
        scale: *f32,
    ) HRESULT {
        return com.call(self, 3, fn (
            *ITextAnalysisSource,
            u32,
            u32,
            ?*IFontCollection,
            ?win32.LPCWSTR,
            FONT_WEIGHT,
            FONT_STYLE,
            u32,
            *u32,
            *?*IFont,
            *f32,
        ) HRESULT, .{
            source, position, len,                 base_collection, base_family,
            weight, style,    FONT_STRETCH_NORMAL, mapped_len,      out,
            scale,
        });
    }
};

pub const ITextAnalyzer = extern struct {
    vtable: com.VTable,

    pub fn analyzeScript(
        self: *ITextAnalyzer,
        source: *ITextAnalysisSource,
        position: u32,
        len: u32,
        sink: *ITextAnalysisSink,
    ) HRESULT {
        return com.call(self, 3, fn (*ITextAnalysisSource, u32, u32, *ITextAnalysisSink) HRESULT, .{
            source, position, len, sink,
        });
    }

    /// Shape `text` into glyphs with the font's default OpenType features.
    /// Returns E_NOT_SUFFICIENT_BUFFER if `glyphs` is too small.
    pub fn getGlyphs(
        self: *ITextAnalyzer,
        text: []const u16,
        face: *IFontFace,
        analysis: *const SCRIPT_ANALYSIS,
        locale: win32.LPCWSTR,
        cluster_map: []u16,
        text_props: []SHAPING_TEXT_PROPERTIES,
        glyphs: []u16,
        glyph_props: []SHAPING_GLYPH_PROPERTIES,
        glyph_count: *u32,
    ) HRESULT {
        return com.call(self, 7, fn (
            [*]const u16,
            u32,
            *IFontFace,
            BOOL,
            BOOL,
            *const SCRIPT_ANALYSIS,
            win32.LPCWSTR,
            ?*anyopaque, // IDWriteNumberSubstitution
            ?*const anyopaque, // features
            ?*const u32, // feature range lengths
            u32, // feature range count
            u32,
            [*]u16,
            [*]SHAPING_TEXT_PROPERTIES,
            [*]u16,
            [*]SHAPING_GLYPH_PROPERTIES,
            *u32,
        ) HRESULT, .{
            text.ptr,        @as(u32, @intCast(text.len)), face,       win32.FALSE,
            win32.FALSE,     analysis,                     locale,     null,
            null,            null,                         0,          @as(u32, @intCast(glyphs.len)),
            cluster_map.ptr, text_props.ptr,               glyphs.ptr, glyph_props.ptr,
            glyph_count,
        });
    }

    pub fn getGlyphPlacements(
        self: *ITextAnalyzer,
        text: []const u16,
        cluster_map: []const u16,
        text_props: []SHAPING_TEXT_PROPERTIES,
        glyphs: []const u16,
        glyph_props: []const SHAPING_GLYPH_PROPERTIES,
        face: *IFontFace,
        em_size: f32,
        analysis: *const SCRIPT_ANALYSIS,
        locale: win32.LPCWSTR,
        advances: []f32,
        offsets: []GLYPH_OFFSET,
    ) HRESULT {
        return com.call(self, 8, fn (
            [*]const u16,
            [*]const u16,
            [*]SHAPING_TEXT_PROPERTIES,
            u32,
            [*]const u16,
            [*]const SHAPING_GLYPH_PROPERTIES,
            u32,
            *IFontFace,
            f32,
            BOOL,
            BOOL,
            *const SCRIPT_ANALYSIS,
            win32.LPCWSTR,
            ?*const anyopaque, // features
            ?*const u32, // feature range lengths
            u32, // feature range count
            [*]f32,
            [*]GLYPH_OFFSET,
        ) HRESULT, .{
            text.ptr,     cluster_map.ptr, text_props.ptr,                 @as(u32, @intCast(text.len)),
            glyphs.ptr,   glyph_props.ptr, @as(u32, @intCast(glyphs.len)), face,
            em_size,      win32.FALSE,     win32.FALSE,                    analysis,
            locale,       null,            null,                           0,
            advances.ptr, offsets.ptr,
        });
    }
};

/// Implemented by us: DirectWrite reads the text being analyzed through
/// this interface. Embed as the first field of the implementing struct.
pub const ITextAnalysisSource = extern struct {
    vtable: *const VTable,

    pub const iid: GUID = .{
        .data1 = 0x688e1a58,
        .data2 = 0x5094,
        .data3 = 0x47c8,
        .data4 = .{ 0xad, 0xc8, 0xfb, 0xce, 0xa6, 0x0a, 0xe9, 0x2b },
    };

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ITextAnalysisSource, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ITextAnalysisSource) callconv(.winapi) u32,
        Release: *const fn (*ITextAnalysisSource) callconv(.winapi) u32,
        GetTextAtPosition: *const fn (*ITextAnalysisSource, u32, *?[*]const u16, *u32) callconv(.winapi) HRESULT,
        GetTextBeforePosition: *const fn (*ITextAnalysisSource, u32, *?[*]const u16, *u32) callconv(.winapi) HRESULT,
        GetParagraphReadingDirection: *const fn (*ITextAnalysisSource) callconv(.winapi) u32,
        GetLocaleName: *const fn (*ITextAnalysisSource, u32, *u32, *?[*:0]const u16) callconv(.winapi) HRESULT,
        GetNumberSubstitution: *const fn (*ITextAnalysisSource, u32, *u32, *?*anyopaque) callconv(.winapi) HRESULT,
    };
};

/// Implemented by us: DirectWrite reports analysis results through this
/// interface. Embed as the first field of the implementing struct.
pub const ITextAnalysisSink = extern struct {
    vtable: *const VTable,

    pub const iid: GUID = .{
        .data1 = 0x5810cd44,
        .data2 = 0x0ca0,
        .data3 = 0x4701,
        .data4 = .{ 0xb3, 0xfa, 0xbe, 0xc5, 0x18, 0x2a, 0xe4, 0xf6 },
    };

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ITextAnalysisSink, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ITextAnalysisSink) callconv(.winapi) u32,
        Release: *const fn (*ITextAnalysisSink) callconv(.winapi) u32,
        SetScriptAnalysis: *const fn (*ITextAnalysisSink, u32, u32, *const SCRIPT_ANALYSIS) callconv(.winapi) HRESULT,
        SetLineBreakpoints: *const fn (*ITextAnalysisSink, u32, u32, *const anyopaque) callconv(.winapi) HRESULT,
        SetBidiLevel: *const fn (*ITextAnalysisSink, u32, u32, u8, u8) callconv(.winapi) HRESULT,
        SetNumberSubstitution: *const fn (*ITextAnalysisSink, u32, u32, ?*anyopaque) callconv(.winapi) HRESULT,
    };
};

pub extern "dwrite" fn DWriteCreateFactory(
    factory_type: u32,
    iid: *const GUID,
    out: *?*anyopaque,
) callconv(.winapi) HRESULT;
