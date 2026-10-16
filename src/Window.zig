//! A top-level Win32 window showing one terminal. Heap allocated so that
//! its address can be stored in the HWND's user data, and so the stream's
//! pointer to `terminal` stays valid.
const Window = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const ghostty_vt = @import("ghostty-vt");
const win32 = @import("win32/win32.zig");
const font = @import("font/font.zig");
const Renderer = @import("renderer/D3D11.zig");
const Cells = @import("renderer/cells.zig").Cells;
const demo = @import("demo.zig");

const log = std.log.scoped(.window);

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ghostty-win");

const font_size_pt = 12;

/// Space between the window edge and the grid, in 96-DPI pixels.
const padding = 4;

/// Ghostty's default colors. Programs can override these with OSC 10/11.
const default_colors: ghostty_vt.Terminal.Colors = .{
    .background = .init(.{ .r = 0x28, .g = 0x2c, .b = 0x34 }),
    .foreground = .init(.{ .r = 0xff, .g = 0xff, .b = 0xff }),
    .cursor = .unset,
    .palette = .default,
};

alloc: Allocator,
hwnd: ?win32.HWND = null,
dpi: u32 = win32.USER_DEFAULT_SCREEN_DPI,

grid: font.Grid,
terminal: ghostty_vt.Terminal,
stream: ghostty_vt.TerminalStream,
render_state: ghostty_vt.RenderState = .empty,
cells: Cells = .{},

/// Set last during creation; messages sent during CreateWindowExW
/// (WM_SIZE, etc.) arrive before everything else is ready.
renderer: ?Renderer = null,

pub fn create(alloc: Allocator, io: std.Io, title: [:0]const u16) !*Window {
    const instance = win32.GetModuleHandleW(null);
    try registerClass(instance);

    const self = try alloc.create(Window);
    errdefer alloc.destroy(self);
    self.* = .{
        .alloc = alloc,
        .grid = undefined,
        .terminal = undefined,
        .stream = undefined,
    };

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

    self.dpi = win32.GetDpiForWindow(hwnd);
    self.grid = try .init(alloc, font_size_pt, self.dpi);
    errdefer self.grid.deinit();

    const size = self.clientSize();
    const grid_size = self.gridSize(size.width, size.height);
    self.terminal = try .init(io, alloc, .{
        .cols = grid_size.cols,
        .rows = grid_size.rows,
        .colors = default_colors,
    });
    errdefer self.terminal.deinit(alloc);
    self.stream = self.terminal.vtStream();
    errdefer self.stream.deinit();
    demo.write(&self.stream);

    self.renderer = try Renderer.init(hwnd, size.width, size.height);

    _ = win32.ShowWindow(hwnd, win32.SW_SHOWDEFAULT);
    return self;
}

/// Free the window. The HWND must already be destroyed (the message
/// loop has exited).
pub fn destroy(self: *Window) void {
    if (self.renderer) |*r| {
        r.deinit();
        self.cells.deinit(self.alloc);
        self.render_state.deinit(self.alloc);
        self.stream.deinit();
        self.terminal.deinit(self.alloc);
        self.grid.deinit();
    }
    self.alloc.destroy(self);
}

const ClientSize = struct { width: u32, height: u32 };

fn clientSize(self: *const Window) ClientSize {
    var rect: win32.RECT = undefined;
    _ = win32.GetClientRect(self.hwnd.?, &rect);
    return .{
        .width = @intCast(rect.right - rect.left),
        .height = @intCast(rect.bottom - rect.top),
    };
}

fn paddingPx(self: *const Window) u32 {
    return padding * self.dpi / win32.USER_DEFAULT_SCREEN_DPI;
}

/// The number of whole cells that fit in a client area.
fn gridSize(self: *const Window, width: u32, height: u32) struct { cols: u16, rows: u16 } {
    const m = self.grid.metrics;
    const pad = 2 * self.paddingPx();
    return .{
        .cols = @intCast(std.math.clamp((width -| pad) / m.cell_width, 1, std.math.maxInt(u16))),
        .rows = @intCast(std.math.clamp((height -| pad) / m.cell_height, 1, std.math.maxInt(u16))),
    };
}

fn render(self: *Window) void {
    const r = &(self.renderer orelse return);
    self.renderFallible(r) catch |err| log.err("render failed: {}", .{err});
}

fn renderFallible(self: *Window, r: *Renderer) !void {
    try self.render_state.update(self.alloc, &self.terminal);
    try self.cells.build(self.alloc, &self.render_state, &self.grid);
    const pad: f32 = @floatFromInt(self.paddingPx());
    try r.draw(&self.cells, &self.grid.atlas, self.grid.metrics, .{ pad, pad });
}

/// Fit the swap chain and terminal grid to the client area and redraw.
fn layout(self: *Window) void {
    const r = &(self.renderer orelse return);
    const size = self.clientSize();
    if (size.width == 0 or size.height == 0) return;

    r.resize(size.width, size.height) catch |err| {
        log.err("resize failed: {}", .{err});
        return;
    };

    const grid_size = self.gridSize(size.width, size.height);
    if (grid_size.cols != self.terminal.cols or grid_size.rows != self.terminal.rows) {
        self.terminal.resize(self.alloc, .{
            .cols = grid_size.cols,
            .rows = grid_size.rows,
            .cell_size_px = .{
                .width = self.grid.metrics.cell_width,
                .height = self.grid.metrics.cell_height,
            },
        }) catch |err| log.err("terminal resize failed: {}", .{err});
    }

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
            if (wparam != win32.SIZE_MINIMIZED) self.layout();
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
            self.dpi = win32.hiword(wparam);
            if (self.renderer != null) self.grid.setDpi(self.dpi);
            _ = win32.SetWindowPos(
                hwnd,
                null,
                rect.left,
                rect.top,
                rect.right - rect.left,
                rect.bottom - rect.top,
                win32.SWP_NOZORDER | win32.SWP_NOACTIVATE,
            );

            // The client size may not change (so no WM_SIZE), but the
            // cell size did.
            self.layout();
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
