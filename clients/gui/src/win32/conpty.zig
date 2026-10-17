//! The pseudoconsole API from our bundled conpty.dll (the
//! Microsoft.Windows.Console.ConPTY package) rather than kernel32's
//! inbox version. Loaded at runtime from the exe's directory so that unit
//! tests, which run from the cache without the DLL, still start.

const std = @import("std");
const win32 = @import("win32.zig");

const log = std.log.scoped(.conpty);

pub const HPCON = *opaque {};

pub const COORD = extern struct { X: i16, Y: i16 };

// CreatePseudoConsole flags, from the package's conpty.h.
pub const PSEUDOCONSOLE_INHERIT_CURSOR = 0x1;
pub const PSEUDOCONSOLE_GLYPH_WIDTH_GRAPHEMES = 0x08;

pub const Api = struct {
    create: *const fn (COORD, win32.HANDLE, win32.HANDLE, u32, *HPCON) callconv(.winapi) win32.HRESULT,
    resize: *const fn (HPCON, COORD) callconv(.winapi) win32.HRESULT,
    close: *const fn (HPCON) callconv(.winapi) void,

    /// Load conpty.dll from the application directory only, so a DLL in
    /// the working directory can't stand in for it. Never unloaded.
    pub fn load() !Api {
        const dll = win32.LoadLibraryExW(
            std.unicode.utf8ToUtf16LeStringLiteral("conpty.dll"),
            null,
            win32.LOAD_LIBRARY_SEARCH_APPLICATION_DIR,
        ) orelse return win32.lastError("LoadLibraryExW(conpty.dll)");
        return .{
            .create = try proc(dll, "ConptyCreatePseudoConsole", @FieldType(Api, "create")),
            .resize = try proc(dll, "ConptyResizePseudoConsole", @FieldType(Api, "resize")),
            .close = try proc(dll, "ConptyClosePseudoConsole", @FieldType(Api, "close")),
        };
    }

    fn proc(dll: win32.HMODULE, name: [*:0]const u8, comptime T: type) !T {
        const p = win32.GetProcAddress(dll, name) orelse {
            log.err("conpty.dll has no {s}", .{name});
            return error.Win32;
        };
        return @ptrCast(p);
    }
};
