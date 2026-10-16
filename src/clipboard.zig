//! The Windows clipboard, as UTF-8 text with LF line endings on our
//! side and CF_UNICODETEXT with CRLF on the system's.

const std = @import("std");
const win32 = @import("win32/win32.zig");

/// Replace the clipboard's contents with `text`.
pub fn set(hwnd: win32.HWND, text: []const u8) !void {
    const newlines = std.mem.count(u8, text, "\n");
    const len = (std.unicode.calcUtf16LeLen(text) catch return error.InvalidUtf8) + newlines;

    // The clipboard takes ownership of the memory once SetClipboardData
    // succeeds.
    const mem = win32.GlobalAlloc(win32.GMEM_MOVEABLE, (len + 1) * @sizeOf(u16)) orelse
        return win32.lastError("GlobalAlloc");
    var owned = true;
    defer if (owned) {
        _ = win32.GlobalFree(mem);
    };

    {
        const ptr: [*]u16 = @ptrCast(@alignCast(win32.GlobalLock(mem) orelse return win32.lastError("GlobalLock")));
        defer _ = win32.GlobalUnlock(mem);
        var n: usize = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (n > 0) {
                ptr[n..][0..2].* = .{ '\r', '\n' };
                n += 2;
            }
            n += std.unicode.utf8ToUtf16Le(ptr[n..len], line) catch unreachable;
        }
        std.debug.assert(n == len);
        ptr[len] = 0;
    }

    if (win32.OpenClipboard(hwnd) == 0) return win32.lastError("OpenClipboard");
    defer _ = win32.CloseClipboard();
    if (win32.EmptyClipboard() == 0) return win32.lastError("EmptyClipboard");
    if (win32.SetClipboardData(win32.CF_UNICODETEXT, mem) == null) return win32.lastError("SetClipboardData");
    owned = false;
}

/// Whether the clipboard holds text.
pub fn hasText() bool {
    return win32.IsClipboardFormatAvailable(win32.CF_UNICODETEXT) != 0;
}

/// The clipboard's text, or null if it holds none. Owned by the caller.
pub fn get(alloc: std.mem.Allocator, hwnd: win32.HWND) !?[]u8 {
    if (win32.OpenClipboard(hwnd) == 0) return win32.lastError("OpenClipboard");
    defer _ = win32.CloseClipboard();
    const mem = win32.GetClipboardData(win32.CF_UNICODETEXT) orelse return null;

    const ptr: [*]const u16 = @ptrCast(@alignCast(win32.GlobalLock(mem) orelse return win32.lastError("GlobalLock")));
    defer _ = win32.GlobalUnlock(mem);
    // Stop at the terminator, which the memory should but needn't have.
    const units = ptr[0 .. win32.GlobalSize(mem) / @sizeOf(u16)];
    const utf16 = units[0 .. std.mem.indexOfScalar(u16, units, 0) orelse units.len];

    const text = try std.unicode.utf16LeToUtf8Alloc(alloc, utf16);
    // CRLF to LF, in place.
    var n: usize = 0;
    for (text, 0..) |c, i| {
        if (c == '\r' and i + 1 < text.len and text[i + 1] == '\n') continue;
        text[n] = c;
        n += 1;
    }
    return try alloc.realloc(text, n);
}
