//! A top-level Win32 window that owns a renderer. Heap allocated so that
//! its address can be stored in the HWND's user data.
const Window = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32/win32.zig");
const Renderer = @import("renderer/D3D11.zig");

const log = std.log.scoped(.window);

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ghostty-win");

/// Ghostty's default background, #282c34.
const background: [4]f32 = .{ 0x28.0 / 255.0, 0x2c.0 / 255.0, 0x34.0 / 255.0, 1.0 };

alloc: Allocator,
hwnd: ?win32.HWND = null,

/// Created after the HWND exists; messages sent during CreateWindowExW
/// (WM_SIZE, etc.) arrive before it does.
renderer: ?Renderer = null,

pub fn create(alloc: Allocator, title: [:0]const u16) !*Window {
    const instance = win32.GetModuleHandleW(null);
    try registerClass(instance);

    const self = try alloc.create(Window);
    errdefer alloc.destroy(self);
    self.* = .{ .alloc = alloc };

    // WS_EX_NOREDIRECTIONBITMAP: we present through a flip-model swap
    // chain, so DWM doesn't need a GDI redirection surface for us.
    _ = win32.CreateWindowExW(
        win32.WS_EX_NOREDIRECTIONBITMAP,
        class_name,
        title.ptr,
        win32.WS_OVERLAPPEDWINDOW,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        null,
        null,
        instance,
        self,
    ) orelse return win32.lastError("CreateWindowExW");
    const hwnd = self.hwnd.?;
    errdefer _ = win32.DestroyWindow(hwnd);

    const dark: win32.BOOL = win32.TRUE;
    _ = win32.DwmSetWindowAttribute(hwnd, win32.DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, @sizeOf(win32.BOOL));

    const size = self.clientSize();
    self.renderer = try Renderer.init(hwnd, size.width, size.height);

    _ = win32.ShowWindow(hwnd, win32.SW_SHOWDEFAULT);
    return self;
}

/// Free the window. The HWND must already be destroyed (the message
/// loop has exited).
pub fn destroy(self: *Window) void {
    if (self.renderer) |*r| r.deinit();
    self.alloc.destroy(self);
}

fn clientSize(self: *const Window) struct { width: u32, height: u32 } {
    var rect: win32.RECT = undefined;
    _ = win32.GetClientRect(self.hwnd.?, &rect);
    return .{
        .width = @intCast(rect.right - rect.left),
        .height = @intCast(rect.bottom - rect.top),
    };
}

fn render(self: *Window) void {
    const r = &(self.renderer orelse return);
    r.render(background) catch |err| log.err("render failed: {}", .{err});
}

fn resize(self: *Window, width: u32, height: u32) void {
    const r = &(self.renderer orelse return);
    r.resize(width, height) catch |err| {
        log.err("resize failed: {}", .{err});
        return;
    };

    // Render synchronously so live resize doesn't show stale frames.
    self.render();
}

fn registerClass(instance: ?win32.HINSTANCE) !void {
    const Static = struct {
        var registered = false;
    };
    if (Static.registered) return;

    const wc: win32.WNDCLASSEXW = .{
        .lpfnWndProc = wndProc,
        .hInstance = instance,
        .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
        .lpszClassName = class_name,
    };
    if (win32.RegisterClassExW(&wc) == 0) return win32.lastError("RegisterClassExW");
    Static.registered = true;
}

fn wndProc(hwnd: win32.HWND, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
    if (msg == win32.WM_NCCREATE) {
        const cs: *const win32.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        const self: *Window = @ptrCast(@alignCast(cs.lpCreateParams.?));
        self.hwnd = hwnd;
        _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const ptr = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
    if (ptr == 0) return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *Window = @ptrFromInt(@as(usize, @bitCast(ptr)));

    switch (msg) {
        win32.WM_SIZE => {
            if (wparam != win32.SIZE_MINIMIZED) {
                self.resize(win32.loword(lparam), win32.hiword(lparam));
            }
            return 0;
        },

        win32.WM_PAINT => {
            self.render();
            _ = win32.ValidateRect(hwnd, null);
            return 0;
        },

        // The swap chain covers the whole client area.
        win32.WM_ERASEBKGND => return 1,

        win32.WM_DPICHANGED => {
            const rect: *const win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            log.info("dpi changed to {d}", .{win32.hiword(wparam)});
            _ = win32.SetWindowPos(
                hwnd,
                null,
                rect.left,
                rect.top,
                rect.right - rect.left,
                rect.bottom - rect.top,
                win32.SWP_NOZORDER | win32.SWP_NOACTIVATE,
            );
            return 0;
        },

        win32.WM_DESTROY => {
            _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, 0);
            self.hwnd = null;
            win32.PostQuitMessage(0);
            return 0;
        },

        else => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
