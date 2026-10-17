//! Our implementations of the DirectWrite callback interfaces that text
//! analysis (font fallback and script itemization) reads text from and
//! reports results to.
//!
//! These are stack-allocated, single-use COM objects: DirectWrite only
//! holds them for the duration of the call we pass them to, so reference
//! counting is a no-op.

const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("../win32/win32.zig");
const com = win32.com;
const dwrite = win32.dwrite;

const GUID = win32.GUID;
const HRESULT = win32.HRESULT;

const locale = std.unicode.utf8ToUtf16LeStringLiteral("en-us");

/// IDWriteTextAnalysisSource over a single UTF-16 string, left to right,
/// in one locale.
pub const Source = struct {
    iface: dwrite.ITextAnalysisSource = .{ .vtable = &vtable },
    text: []const u16,

    pub fn init(text: []const u16) Source {
        return .{ .text = text };
    }

    fn from(iface: *dwrite.ITextAnalysisSource) *Source {
        return @fieldParentPtr("iface", iface);
    }

    const vtable: dwrite.ITextAnalysisSource.VTable = .{
        .QueryInterface = queryInterface,
        .AddRef = addRef,
        .Release = release,
        .GetTextAtPosition = getTextAtPosition,
        .GetTextBeforePosition = getTextBeforePosition,
        .GetParagraphReadingDirection = getParagraphReadingDirection,
        .GetLocaleName = getLocaleName,
        .GetNumberSubstitution = getNumberSubstitution,
    };

    fn queryInterface(iface: *dwrite.ITextAnalysisSource, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        if (com.guidEql(iid, &com.IID_IUnknown) or com.guidEql(iid, &dwrite.ITextAnalysisSource.iid)) {
            out.* = iface;
            return com.S_OK;
        }
        out.* = null;
        return com.E_NOINTERFACE;
    }

    fn addRef(_: *dwrite.ITextAnalysisSource) callconv(.winapi) u32 {
        return 1;
    }

    fn release(_: *dwrite.ITextAnalysisSource) callconv(.winapi) u32 {
        return 1;
    }

    fn getTextAtPosition(iface: *dwrite.ITextAnalysisSource, pos: u32, text: *?[*]const u16, len: *u32) callconv(.winapi) HRESULT {
        const self = from(iface);
        if (pos >= self.text.len) {
            text.* = null;
            len.* = 0;
        } else {
            text.* = self.text[pos..].ptr;
            len.* = @intCast(self.text.len - pos);
        }
        return com.S_OK;
    }

    fn getTextBeforePosition(iface: *dwrite.ITextAnalysisSource, pos: u32, text: *?[*]const u16, len: *u32) callconv(.winapi) HRESULT {
        const self = from(iface);
        if (pos == 0 or pos > self.text.len) {
            text.* = null;
            len.* = 0;
        } else {
            text.* = self.text.ptr;
            len.* = pos;
        }
        return com.S_OK;
    }

    fn getParagraphReadingDirection(_: *dwrite.ITextAnalysisSource) callconv(.winapi) u32 {
        return dwrite.READING_DIRECTION_LEFT_TO_RIGHT;
    }

    fn getLocaleName(iface: *dwrite.ITextAnalysisSource, pos: u32, len: *u32, name: *?[*:0]const u16) callconv(.winapi) HRESULT {
        const self = from(iface);
        len.* = @intCast(self.text.len -| pos);
        name.* = locale;
        return com.S_OK;
    }

    fn getNumberSubstitution(iface: *dwrite.ITextAnalysisSource, pos: u32, len: *u32, out: *?*anyopaque) callconv(.winapi) HRESULT {
        const self = from(iface);
        len.* = @intCast(self.text.len -| pos);
        out.* = null;
        return com.S_OK;
    }
};

/// A range of text sharing one script, as itemized by AnalyzeScript.
pub const ScriptRun = struct {
    pos: u32,
    len: u32,
    analysis: dwrite.SCRIPT_ANALYSIS,
};

/// IDWriteTextAnalysisSink that collects script runs. Other analysis
/// results are ignored.
pub const ScriptSink = struct {
    iface: dwrite.ITextAnalysisSink = .{ .vtable = &vtable },
    alloc: Allocator,
    runs: *std.ArrayList(ScriptRun),

    /// Set if appending failed; the HRESULT DirectWrite sees loses it.
    oom: bool = false,

    pub fn init(alloc: Allocator, runs: *std.ArrayList(ScriptRun)) ScriptSink {
        return .{ .alloc = alloc, .runs = runs };
    }

    fn from(iface: *dwrite.ITextAnalysisSink) *ScriptSink {
        return @fieldParentPtr("iface", iface);
    }

    const vtable: dwrite.ITextAnalysisSink.VTable = .{
        .QueryInterface = queryInterface,
        .AddRef = addRef,
        .Release = release,
        .SetScriptAnalysis = setScriptAnalysis,
        .SetLineBreakpoints = setLineBreakpoints,
        .SetBidiLevel = setBidiLevel,
        .SetNumberSubstitution = setNumberSubstitution,
    };

    fn queryInterface(iface: *dwrite.ITextAnalysisSink, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        if (com.guidEql(iid, &com.IID_IUnknown) or com.guidEql(iid, &dwrite.ITextAnalysisSink.iid)) {
            out.* = iface;
            return com.S_OK;
        }
        out.* = null;
        return com.E_NOINTERFACE;
    }

    fn addRef(_: *dwrite.ITextAnalysisSink) callconv(.winapi) u32 {
        return 1;
    }

    fn release(_: *dwrite.ITextAnalysisSink) callconv(.winapi) u32 {
        return 1;
    }

    fn setScriptAnalysis(iface: *dwrite.ITextAnalysisSink, pos: u32, len: u32, analysis: *const dwrite.SCRIPT_ANALYSIS) callconv(.winapi) HRESULT {
        const self = from(iface);
        self.runs.append(self.alloc, .{ .pos = pos, .len = len, .analysis = analysis.* }) catch {
            self.oom = true;
            return com.E_OUTOFMEMORY;
        };
        return com.S_OK;
    }

    fn setLineBreakpoints(_: *dwrite.ITextAnalysisSink, _: u32, _: u32, _: *const anyopaque) callconv(.winapi) HRESULT {
        return com.S_OK;
    }

    fn setBidiLevel(_: *dwrite.ITextAnalysisSink, _: u32, _: u32, _: u8, _: u8) callconv(.winapi) HRESULT {
        return com.S_OK;
    }

    fn setNumberSubstitution(_: *dwrite.ITextAnalysisSink, _: u32, _: u32, _: ?*anyopaque) callconv(.winapi) HRESULT {
        return com.S_OK;
    }
};

pub const locale_name: win32.LPCWSTR = locale;
