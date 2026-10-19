//! A top-level Win32 window: our own title bar and tab list (see `Ui`)
//! around the active tab's panes, each a session's terminal. The window
//! is the shell: it owns the HWND, the renderer, the font grid, and the
//! UI, turns window messages into an `App.Msg` each, and draws the tree
//! `App.view` builds. Heap allocated so that its address can be stored
//! in the HWND's user data.
//!
//! The window draws its own title bar. WM_NCCALCSIZE gives the caption's
//! space to the client area, keeping the other borders, and WM_NCHITTEST
//! tells Windows which parts of it move the window and which are caption
//! buttons, so dragging, snapping, and Snap Layouts still work.
const Window = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const ghostty_vt = @import("ghostty-vt");
const win32 = @import("win32/win32.zig");
const font = @import("font/font.zig");
const input = @import("input.zig");
const clipboard = @import("clipboard.zig");
const Stats = @import("Stats.zig");
const Config = @import("Config.zig");
const App = @import("App.zig");
const Session = @import("Session.zig");
const Tab = @import("Tab.zig");
const Hosts = @import("Hosts.zig");
const Shown = @import("Shown.zig");
const Daemon = @import("Daemon.zig");
const binding = @import("binding.zig");
const Placement = @import("Placement.zig");
const messages = @import("messages.zig");
const Ui = @import("ui/Ui.zig");
const Id = Ui.Id;
const build_options = @import("build_options");
const Renderer = @import("renderer/D3D11.zig");
const Painter = Renderer.Painter;

const log = std.log.scoped(.window);

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("slime");

/// The icon resource in src/slime.rc.
const icon_id = 1;

const WM_APP_CHILD_EXITED = messages.WM_APP_CHILD_EXITED;
const WM_APP_TITLE_CHANGED = messages.WM_APP_TITLE_CHANGED;
const WM_APP_CLIPBOARD_WRITE = messages.WM_APP_CLIPBOARD_WRITE;
const WM_APP_DAEMON = messages.WM_APP_DAEMON;

/// Room for the stats report, in UTF-16 units.
const max_stats_len = 160;

const stats_timer_id = 1;
/// Draws pending output while DefWindowProc's modal move/size loop runs
/// instead of ours.
const sizemove_timer_id = 2;
/// The app's timers (`App.Timer`), after ours.
const blink_timer_id = 4;
const spinner_timer_id = 5;
const tip_timer_id = 6;

alloc: Allocator,
io: std.Io,
/// Outlives the window.
config: *const Config,
hwnd: ?win32.HWND = null,
/// The last stats report, which the sidebar shows.
stats_text: [max_stats_len]u16 = undefined,
stats_len: usize = 0,
dpi: u32 = win32.USER_DEFAULT_SCREEN_DPI,

/// Shared by every session: they all draw at the same size.
grid: font.Grid,
ui: Ui,
/// The window's regions, from the last `layout`.
frame: Ui.Frame = .{},

/// Set last during creation; messages sent during CreateWindowExW
/// (WM_SIZE, etc.) arrive before everything else is ready.
renderer: ?Renderer = null,

/// The state and what changes it. Points at `ui` and `frame`, and back
/// here as its shell.
app: App,

/// Scratch for `render`.
frame_panes: std.ArrayList(Renderer.Pane) = .empty,
/// What the renderer draws a browser pane's box from: no grid, the
/// configured background. Never built, so never holds anything.
blank: struct {
    cells: @import("renderer/cells.zig").Cells = .{},
    images: @import("renderer/image.zig").Images = .{},
    textures: Renderer.ImageTextures = .{},
} = .{},

/// Auto-reset event slime's readers set after handing a session a
/// frame (or program status). The message loop waits on it alongside
/// messages and calls `outputArrived`. Not a posted message: those are
/// retrieved before input and timers, so a steady stream of them starves
/// the keyboard.
output_event: win32.HANDLE,

/// TrackMouseEvent is armed for the mouse leaving the client area, and
/// for leaving the caption buttons.
tracking_mouse: bool = false,
tracking_nc_mouse: bool = false,

/// Only used with `-Dstats`.
stats: Stats = .{},

/// Create the window, showing the workspaces the last window did (or
/// what slime has, or a new one running `command_line`, CreateProcessW
/// syntax; empty for slime's shell). An `ssh://` URL opens that host
/// too, and is remembered in `hosts`. Local sessions opened later run
/// `local_command`. `daemon` is the connection `config` and `keymap`
/// came from, if one was made; the window owns it from here and goes
/// on with it.
pub fn create(alloc: Allocator, io: std.Io, config: *const Config, keymap: []const binding.Entry, hosts: *Hosts, shown: *Shown, command_line: []const u16, local_command: []const u16, daemon: ?*Daemon) !*Window {
    // Ours until the app has it.
    var pending = daemon;
    errdefer if (pending) |conn| conn.deinit();

    const instance = win32.GetModuleHandleW(null);
    try registerClass(instance);

    const self = try alloc.create(Window);
    errdefer alloc.destroy(self);
    const output_event = win32.CreateEventW(null, win32.FALSE, win32.FALSE, null) orelse
        return win32.lastError("CreateEventW");
    errdefer _ = win32.CloseHandle(output_event);
    self.* = .{
        .alloc = alloc,
        .io = io,
        .config = config,
        .output_event = output_event,
        .grid = undefined,
        .ui = undefined,
        .app = undefined,
    };

    // WS_EX_NOREDIRECTIONBITMAP: we present through a flip-model swap
    // chain, so DWM doesn't need a GDI redirection surface for us.
    _ = win32.CreateWindowExW(
        win32.WS_EX_NOREDIRECTIONBITMAP,
        class_name,
        class_name,
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

    // The chrome follows the terminal's colors, and the frame Windows
    // draws (border, system menu) follows the chrome.
    const theme: Ui.Theme = .init(config.background, config.foreground);
    const dark: win32.BOOL = if (theme.light) win32.FALSE else win32.TRUE;
    _ = win32.DwmSetWindowAttribute(hwnd, win32.DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, @sizeOf(win32.BOOL));

    self.dpi = win32.GetDpiForWindow(hwnd);
    self.grid = try .init(alloc, io, config.@"font-family".items, config.@"font-size", self.dpi, config.@"font-antialias");
    errdefer self.grid.deinit();
    self.ui = try .init(self.dpi, config.@"chrome-scale", theme);
    errdefer self.ui.deinit();

    const size = self.clientSize();
    self.updateLayout(size);
    self.app = try App.init(.{
        .alloc = alloc,
        .config = config,
        .keymap = keymap,
        .daemon = pending,
        .local_command = local_command,
        .hosts = hosts,
        .shown = shown,
        .ui = &self.ui,
        .frame = &self.frame,
        .shell = self.shell(),
        .hwnd = hwnd,
        .output_event = output_event,
        .stats_bytes = if (build_options.stats) &self.stats.bytes else null,
    });
    pending = null;
    errdefer self.app.deinit();
    self.renderer = try Renderer.init(self.alloc, hwnd, size.width, size.height, config.@"font-antialias");
    errdefer {
        self.renderer.?.deinit();
        self.renderer = null;
    }
    // Sessions hold GPU resources: gone before the renderer.
    errdefer self.app.destroyTabs();

    self.app.layout(self.geometry());
    try self.app.start(command_line);

    // Have the frame recomputed now that WM_NCCALCSIZE can be answered.
    _ = win32.SetWindowPos(hwnd, null, 0, 0, 0, 0, win32.SWP_FRAMECHANGED | win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);

    if (build_options.stats) {
        self.stats = .init();
        _ = win32.SetTimer(hwnd, stats_timer_id, 1000, null);
    }

    _ = win32.ShowWindow(hwnd, win32.SW_SHOWDEFAULT);
    return self;
}

/// Free the window. The HWND must already be destroyed (the message
/// loop has exited).
pub fn destroy(self: *Window) void {
    if (self.renderer) |*r| {
        // Sessions hold GPU resources.
        self.app.destroyTabs();
        r.deinit();
        self.ui.deinit();
        self.grid.deinit();
    }
    self.app.deinit();
    self.frame_panes.deinit(self.alloc);
    _ = win32.CloseHandle(self.output_event);
    self.alloc.destroy(self);
}

/// The message loop's view of frame pacing: when `output_event` fires,
/// call `outputArrived`; while `needsFrame`, also wait on `frameGate` and
/// pass it to `frameGateFired` when it fires. Drawing then happens at most
/// once per display refresh, and right away when the terminal was idle.
pub fn outputArrived(self: *Window) void {
    _ = self.app.update(.output);
}

pub fn needsFrame(self: *const Window) bool {
    return self.app.dirty;
}

pub fn frameGate(self: *const Window) win32.HANDLE {
    return self.renderer.?.frameGate();
}

pub fn frameGateFired(self: *Window, gate: win32.HANDLE) void {
    const r = &self.renderer.?;
    // The pace timer only moves us on to waiting for the swap chain.
    if (gate != r.frame_waitable) return;
    r.frameAcquired();
    // A synchronous render (resize, WM_PAINT) may have drawn it already;
    // the acquired frame then waits for the next change.
    if (self.app.dirty) self.render();
}

/// Change every session's font size, keeping the window's size: the grid
/// gains or loses cells instead.
fn setFontSize(self: *Window, size_pt: f32) void {
    const size = std.math.clamp(size_pt, 1, 255);
    if (size == self.grid.size_pt) return;
    self.grid.setSize(size);
    self.layout();
}

/// The caption buttons, which come as non-client messages.
fn captionHit(ht: win32.WPARAM) Id {
    return switch (ht) {
        win32.HTMINBUTTON => .window(.minimize),
        win32.HTMAXBUTTON => .window(.maximize),
        win32.HTCLOSE => .window(.close),
        else => .none,
    };
}

fn captionClick(self: *Window, part: Id.Part) void {
    const hwnd = self.hwnd.?;
    switch (part) {
        .minimize => _ = win32.ShowWindow(hwnd, win32.SW_MINIMIZE),
        .maximize => _ = win32.ShowWindow(hwnd, if (win32.IsZoomed(hwnd) != 0) win32.SW_RESTORE else win32.SW_MAXIMIZE),
        .close => _ = win32.PostMessageW(hwnd, win32.WM_CLOSE, 0, 0),
        else => {},
    }
}

/// The sizing border's thickness: what Windows puts above a maximized
/// window's client area, off screen, and the top resize edge otherwise.
fn frameThickness(hwnd: win32.HWND) i32 {
    const dpi = win32.GetDpiForWindow(hwnd);
    return win32.GetSystemMetricsForDpi(win32.SM_CYFRAME, dpi) + win32.GetSystemMetricsForDpi(win32.SM_CXPADDEDBORDER, dpi);
}

/// WM_NCHITTEST for the client area, which includes the title bar.
fn hitTestFrame(self: *Window, lparam: win32.LPARAM) win32.LRESULT {
    const hwnd = self.hwnd.?;
    var pos: win32.POINT = .{ .x = win32.xLparam(lparam), .y = win32.yLparam(lparam) };
    _ = win32.ScreenToClient(hwnd, &pos);
    // The top resize edge, which the caption took with it.
    const frame = frameThickness(hwnd);
    if (win32.IsZoomed(hwnd) == 0 and pos.y < frame) {
        const width: i32 = @intCast(self.clientSize().width);
        if (pos.x < 2 * frame) return win32.HTTOPLEFT;
        if (pos.x >= width - 2 * frame) return win32.HTTOPRIGHT;
        return win32.HTTOP;
    }
    const hit = self.app.hitAt(pos);
    if (hit.target != .window) return win32.HTCLIENT;
    return switch (hit.part) {
        .caption => win32.HTCAPTION,
        .minimize => win32.HTMINBUTTON,
        .maximize => win32.HTMAXBUTTON,
        .close => win32.HTCLOSE,
        else => win32.HTCLIENT,
    };
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

/// The size of the terminal area, in pixels.
fn terminalSize(self: *const Window) ClientSize {
    const t = self.frame.terminal;
    return .{ .width = @intFromFloat(t.w), .height = @intFromFloat(t.h) };
}

/// The space around the grid in a pane: the configured padding, in
/// points, as pixels at the current DPI, plus the chrome's inset on every
/// side.
fn paddingPx(self: *const Window) Placement.Padding {
    const x = self.config.@"window-padding-x";
    const y = self.config.@"window-padding-y";
    const inset: u32 = @intFromFloat(self.frame.inset);
    return .{
        .left = x.top_left * self.dpi / 72 + inset,
        .right = x.bottom_right * self.dpi / 72 + inset,
        .top = y.top_left * self.dpi / 72 + inset,
        .bottom = y.bottom_right * self.dpi / 72 + inset,
    };
}

/// Where the terminal area is and what fits in it, for the app: from
/// the UI's frame, the font grid, and the DPI.
fn geometry(self: *const Window) App.Geometry {
    const size = self.terminalSize();
    const m = self.grid.metrics;
    return .{
        .terminal = .{ .width = size.width, .height = size.height },
        .pane_area = self.ui.paneArea(&self.frame),
        .gap = self.ui.paneGap(),
        .title_height = self.ui.paneTitleHeight(),
        .inset = @intFromFloat(self.frame.inset),
        .padding = self.paddingPx(),
        .cell = .{ .width = m.cell_width, .height = m.cell_height },
    };
}

fn render(self: *Window) void {
    const r = &(self.renderer orelse return);
    self.renderFallible(r) catch |err| log.err("render failed: {}", .{err});
}

/// The widget tree, as the renderer draws it over the terminal: the app's
/// tree, painted by the UI.
const Overlay = struct {
    ui: *const Ui,
    tree: *const Ui.Tree,

    pub fn paint(self: Overlay, p: *Painter, layer: Ui.Layer) void {
        self.ui.paint(p, self.tree, layer);
    }

    pub fn hasOver(self: Overlay) bool {
        return self.ui.hasOver(self.tree);
    }

    pub fn capture(self: Overlay) ?Ui.Rect {
        return Ui.dragCapture(self.tree);
    }

    pub fn paintOver(self: Overlay, p: *Painter, thumb: ?Painter.Image) void {
        self.ui.paintDrag(p, self.tree, thumb);
    }
};

fn renderFallible(self: *Window, r: *Renderer) !void {
    r.waitForFrame();
    const app = &self.app;
    app.dirty = false;
    const stats = build_options.stats;
    var t: i64 = if (stats) Stats.now() else 0;
    self.frame_panes.clearRetainingCapacity();
    // With nothing shown, the chrome alone is drawn.
    const tab: ?*Tab = if (app.hasTabs()) app.activeTab() else null;
    // The host field, a rename, or a dialog has the keyboard while open.
    const terminal_keys = app.keyboard() == .terminal;
    if (tab) |tb| {
        for (app.placed().panes.items) |p| {
            const s = p.session;
            // A browser's box, under its stand-in.
            const term = s.term() orelse {
                self.blank.cells.default_bg = self.config.background;
                try self.frame_panes.append(self.alloc, .{
                    .cells = &self.blank.cells,
                    .images = &self.blank.images,
                    .textures = &self.blank.textures,
                    .frame = p.frame,
                    .viewport = .{},
                    .grid_offset = .{ 0, 0 },
                });
                continue;
            };
            s.applyFrames();
            if (stats) t = self.stats.lap(.update, t);
            // Panes without focus show a hollow cursor, as an unfocused
            // window's does.
            const focus = s == tb.focus;
            try term.cells.build(self.alloc, &term.screen, &self.grid, .{
                .focused = focus and app.focused and terminal_keys,
                .blink_visible = app.blink_visible,
            }, .{
                .cursor_color = self.config.@"cursor-color",
                .cursor_text = self.config.@"cursor-text",
                .selection_background = self.config.@"selection-background",
                .selection_foreground = self.config.@"selection-foreground",
            });
            if (stats) t = self.stats.lap(.build, t);
            try self.frame_panes.append(self.alloc, .{
                .cells = &term.cells,
                .images = &term.images,
                .textures = &term.textures,
                .frame = p.frame,
                .viewport = p.rect,
                .grid_offset = .{ @floatFromInt(p.pad.left), @floatFromInt(p.pad.top) },
            });
        }
    }
    var shadows: [2]Renderer.BoxStyle.Shadow = undefined;
    try r.draw(self.alloc, .{
        .atlas = &self.grid.atlas,
        .color_atlas = &self.grid.color_atlas,
        .lcd_atlas = &self.grid.lcd_atlas,
        .metrics = self.grid.metrics,
        .panes = self.frame_panes.items,
        // The chrome's ground, around and between the panes.
        .background = self.ui.theme.ground,
        .box = self.paneBox(&shadows),
    }, Overlay{ .ui = &self.ui, .tree = app.view() });
    // More frames may come for what's drawn.
    for (app.placed().panes.items) |p| p.session.drawn();
    if (stats) {
        _ = self.stats.lap(.draw, t);
        self.stats.frames += 1;
    }
}

/// How the renderer draws each pane: rounded as the chrome's corners,
/// with a hairline border and the UI's two shadows, which `shadows`
/// holds.
fn paneBox(self: *const Window, shadows: *[2]Renderer.BoxStyle.Shadow) Renderer.BoxStyle {
    const c = &self.ui;
    for (shadows, c.shadows()) |*out, s| out.* = .{ .color = s.color, .sigma = s.sigma, .offset = s.offset };
    return .{
        .radius = self.frame.corner,
        .border_width = c.stroke(),
        .border = c.theme.pane_border,
        .shadows = shadows,
    };
}

/// Take the last second's stats for the sidebar to show.
fn showStats(self: *Window) void {
    var utf8: [max_stats_len]u8 = undefined;
    const text = self.stats.report(&utf8);
    self.stats_len = std.unicode.utf8ToUtf16Le(&self.stats_text, text) catch 0;
    self.app.markDirty();
}

fn updateLayout(self: *Window, size: ClientSize) void {
    self.frame = self.ui.frame(@floatFromInt(size.width), @floatFromInt(size.height));
}

/// Fit the swap chain, the chrome, and every pane's grid to the client
/// area and redraw.
fn layout(self: *Window) void {
    const r = &(self.renderer orelse return);
    const size = self.clientSize();
    if (size.width == 0 or size.height == 0) return;

    r.resize(size.width, size.height) catch |err| {
        log.err("resize failed: {}", .{err});
        return;
    };
    self.updateLayout(size);
    self.app.layout(self.geometry());

    // Render synchronously so live resize doesn't show stale frames.
    self.render();
}

/// The app's way to Win32: this window.
fn shell(self: *Window) App.Shell {
    return .{ .ctx = self, .vt = &shell_vtable };
}

const shell_vtable: App.Shell.VTable = .{
    .captureMouse = shellCaptureMouse,
    .releaseMouse = shellReleaseMouse,
    .setTimer = shellSetTimer,
    .killTimer = shellKillTimer,
    .postClose = shellPostClose,
    .setTitle = shellSetTitle,
    .caption = shellCaption,
    .maximized = shellMaximized,
    .tickCount = shellTickCount,
    .keyDown = shellKeyDown,
    .mods = shellMods,
    .dragThreshold = shellDragThreshold,
    .hoverTime = shellHoverTime,
    .caretBlinkTime = shellCaretBlinkTime,
    .dropPendingChars = shellDropPendingChars,
    .clipboardHasText = shellClipboardHasText,
    .clipboardGet = shellClipboardGet,
    .clipboardSet = shellClipboardSet,
    .frameInterval = shellFrameInterval,
    .fontSize = shellFontSize,
    .setFontSize = shellSetFontSize,
    .relayout = shellRelayout,
    .stats = shellStats,
};

fn fromCtx(ctx: *anyopaque) *Window {
    return @ptrCast(@alignCast(ctx));
}

fn timerId(timer: App.Timer) usize {
    return switch (timer) {
        .blink => blink_timer_id,
        .spinner => spinner_timer_id,
        .tip => tip_timer_id,
    };
}

fn shellCaptureMouse(ctx: *anyopaque) void {
    _ = win32.SetCapture(fromCtx(ctx).hwnd.?);
}

fn shellReleaseMouse(_: *anyopaque) void {
    _ = win32.ReleaseCapture();
}

fn shellSetTimer(ctx: *anyopaque, timer: App.Timer, ms: u32) void {
    _ = win32.SetTimer(fromCtx(ctx).hwnd, timerId(timer), ms, null);
}

fn shellKillTimer(ctx: *anyopaque, timer: App.Timer) void {
    _ = win32.KillTimer(fromCtx(ctx).hwnd, timerId(timer));
}

fn shellPostClose(ctx: *anyopaque) void {
    _ = win32.PostMessageW(fromCtx(ctx).hwnd, win32.WM_CLOSE, 0, 0);
}

fn shellSetTitle(ctx: *anyopaque, title: [:0]const u16) void {
    _ = win32.SetWindowTextW(fromCtx(ctx).hwnd.?, title);
}

fn shellCaption(ctx: *anyopaque, part: Id.Part) void {
    fromCtx(ctx).captionClick(part);
}

fn shellMaximized(ctx: *anyopaque) bool {
    return win32.IsZoomed(fromCtx(ctx).hwnd.?) != 0;
}

fn shellTickCount(_: *anyopaque) u64 {
    return win32.GetTickCount64();
}

fn shellKeyDown(_: *anyopaque, vk: i32) bool {
    return win32.GetKeyState(vk) < 0;
}

fn shellMods(_: *anyopaque) input.Mods {
    return input.currentMods();
}

fn shellDragThreshold(ctx: *anyopaque) [2]i32 {
    const dpi = fromCtx(ctx).dpi;
    return .{ win32.GetSystemMetricsForDpi(win32.SM_CXDRAG, dpi), win32.GetSystemMetricsForDpi(win32.SM_CYDRAG, dpi) };
}

fn shellHoverTime(_: *anyopaque) u32 {
    var ms: u32 = 400;
    _ = win32.SystemParametersInfoW(win32.SPI_GETMOUSEHOVERTIME, 0, &ms, 0);
    return ms;
}

fn shellCaretBlinkTime(_: *anyopaque) ?u32 {
    const ms = win32.GetCaretBlinkTime();
    return if (ms == 0 or ms == win32.INFINITE) null else ms;
}

/// Drop the text TranslateMessage posted for the key being handled.
fn shellDropPendingChars(ctx: *anyopaque) void {
    var m: win32.MSG = undefined;
    while (win32.PeekMessageW(&m, fromCtx(ctx).hwnd, win32.WM_CHAR, win32.WM_DEADCHAR, win32.PM_REMOVE) != 0) {}
}

fn shellClipboardHasText(_: *anyopaque) bool {
    return clipboard.hasText();
}

fn shellClipboardGet(ctx: *anyopaque, alloc: Allocator) anyerror!?[]u8 {
    return clipboard.get(alloc, fromCtx(ctx).hwnd);
}

fn shellClipboardSet(ctx: *anyopaque, text: []const u8) anyerror!void {
    return clipboard.set(fromCtx(ctx).hwnd.?, text);
}

/// The least time between a pane's frames to ask slime for, in
/// microseconds: the display's refresh period.
fn shellFrameInterval(ctx: *anyopaque) u32 {
    const r = &(fromCtx(ctx).renderer orelse return 0);
    return std.math.cast(u32, @divTrunc(r.refresh_period, 10)) orelse 0;
}

fn shellFontSize(ctx: *anyopaque) f32 {
    return fromCtx(ctx).grid.size_pt;
}

fn shellSetFontSize(ctx: *anyopaque, size_pt: f32) void {
    fromCtx(ctx).setFontSize(size_pt);
}

fn shellRelayout(ctx: *anyopaque) void {
    fromCtx(ctx).layout();
}

fn shellStats(ctx: *anyopaque) []const u16 {
    const self = fromCtx(ctx);
    return self.stats_text[0..self.stats_len];
}

fn registerClass(instance: ?win32.HINSTANCE) !void {
    const Static = struct {
        var registered = false;
    };
    if (Static.registered) return;

    const wc: win32.WNDCLASSEXW = .{
        // A second click within the system's time and distance arrives
        // as a WM_*BUTTONDBLCLK instead of a WM_*BUTTONDOWN.
        .style = win32.CS_DBLCLKS,
        .lpfnWndProc = wndProc,
        .hInstance = instance,
        // Windows picks the small icon from the same resource.
        .hIcon = win32.LoadIconW(instance, icon_id),
        .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
        .lpszClassName = class_name,
    };
    if (win32.RegisterClassExW(&wc) == 0) return win32.lastError("RegisterClassExW");
    Static.registered = true;
}

/// The system cursor for a shape the child set with OSC 22.
fn mouseCursor(shape: ghostty_vt.MouseShape) usize {
    return switch (shape) {
        .text, .vertical_text => win32.IDC_IBEAM,
        .pointer, .alias, .copy, .grab, .grabbing => win32.IDC_HAND,
        .help, .context_menu => win32.IDC_HELP,
        .progress => win32.IDC_APPSTARTING,
        .wait => win32.IDC_WAIT,
        .cell, .crosshair => win32.IDC_CROSS,
        .move, .all_scroll => win32.IDC_SIZEALL,
        .no_drop, .not_allowed => win32.IDC_NO,
        .col_resize, .e_resize, .w_resize, .ew_resize => win32.IDC_SIZEWE,
        .row_resize, .n_resize, .s_resize, .ns_resize => win32.IDC_SIZENS,
        .ne_resize, .sw_resize, .nesw_resize => win32.IDC_SIZENESW,
        .nw_resize, .se_resize, .nwse_resize => win32.IDC_SIZENWSE,
        .default, .zoom_in, .zoom_out => win32.IDC_ARROW,
    };
}

/// The system cursor for what the app wants at a point.
fn systemCursor(cursor: App.Cursor) usize {
    return switch (cursor) {
        .arrow => win32.IDC_ARROW,
        .ibeam => win32.IDC_IBEAM,
        .size_we => win32.IDC_SIZEWE,
        .size_ns => win32.IDC_SIZENS,
        .size_all => win32.IDC_SIZEALL,
        .shape => |shape| mouseCursor(shape),
    };
}

/// A key message, as the app takes it.
fn keyMsg(msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) App.Msg {
    return .{ .key = .{ .msg = msg, .wparam = wparam, .lparam = lparam } };
}

/// What the app's answer means for the window procedure.
fn result(hwnd: win32.HWND, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM, r: App.Result) win32.LRESULT {
    return switch (r) {
        .handled => 0,
        .default => win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    };
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

    // Only the frame is ours to handle until the renderer is up.
    if (self.renderer == null and msg != win32.WM_NCCALCSIZE)
        return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const app = &self.app;

    switch (msg) {
        // Take the caption's space for the client area, keeping the
        // other borders. A maximized window hangs its borders off
        // screen, so its client area starts below the top one.
        win32.WM_NCCALCSIZE => {
            if (wparam == 0) return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
            const params: *win32.NCCALCSIZE_PARAMS = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const top = params.rgrc[0].top;
            const result_ = win32.DefWindowProcW(hwnd, msg, wparam, lparam);
            if (result_ != 0) return result_;
            params.rgrc[0].top = top;
            if (win32.IsZoomed(hwnd) != 0) params.rgrc[0].top += frameThickness(hwnd);
            return 0;
        },

        win32.WM_NCHITTEST => {
            const hit = win32.DefWindowProcW(hwnd, msg, wparam, lparam);
            if (hit != win32.HTCLIENT) return hit;
            return self.hitTestFrame(lparam);
        },

        // The caption buttons are drawn and pressed by us; anything else
        // in the non-client area (moving, sizing) is Windows'.
        win32.WM_NCMOUSEMOVE => {
            if (!self.tracking_nc_mouse) {
                var tme: win32.TRACKMOUSEEVENT = .{ .dwFlags = win32.TME_LEAVE | win32.TME_NONCLIENT, .hwndTrack = hwnd };
                self.tracking_nc_mouse = win32.TrackMouseEvent(&tme) != 0;
            }
            _ = app.update(.{ .caption = .{ .hit = captionHit(wparam), .event = .hover } });
            return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        win32.WM_NCMOUSELEAVE => {
            self.tracking_nc_mouse = false;
            _ = app.update(.caption_leave);
            return 0;
        },

        win32.WM_NCLBUTTONDOWN, win32.WM_NCLBUTTONDBLCLK => {
            const hit = captionHit(wparam);
            if (hit.target == .none) return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
            _ = app.update(.{ .caption = .{ .hit = hit, .event = .down } });
            return 0;
        },

        win32.WM_NCLBUTTONUP => {
            const hit = captionHit(wparam);
            _ = app.update(.{ .caption = .{ .hit = hit, .event = .up } });
            if (hit.target == .none) return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
            return 0;
        },

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

        win32.WM_ENTERSIZEMOVE => {
            _ = win32.SetTimer(hwnd, sizemove_timer_id, 16, null);
            return 0;
        },

        win32.WM_EXITSIZEMOVE => {
            _ = win32.KillTimer(hwnd, sizemove_timer_id);
            // The window may now be on a display with another refresh rate.
            if (self.renderer) |*r| r.updateRefreshRate();
            return 0;
        },

        win32.WM_DISPLAYCHANGE => {
            if (self.renderer) |*r| r.updateRefreshRate();
            return 0;
        },

        win32.WM_TIMER => {
            switch (wparam) {
                stats_timer_id => if (build_options.stats) self.showStats(),
                blink_timer_id => _ = app.update(.{ .tick = .blink }),
                spinner_timer_id => _ = app.update(.{ .tick = .spinner }),
                tip_timer_id => _ = app.update(.{ .tick = .tip }),
                sizemove_timer_id => {
                    if (win32.WaitForSingleObject(self.output_event, 0) == win32.WAIT_OBJECT_0) self.outputArrived();
                    if (app.dirty) self.render();
                },
                else => {},
            }
            return 0;
        },

        win32.WM_SETFOCUS, win32.WM_KILLFOCUS => {
            _ = app.update(.{ .focus = msg == win32.WM_SETFOCUS });
            return 0;
        },

        WM_APP_CHILD_EXITED => {
            _ = app.update(.{ .session = .{ .id = @intCast(wparam), .what = .exited } });
            return 0;
        },

        WM_APP_DAEMON => {
            _ = app.update(.daemon_posted);
            return 0;
        },

        WM_APP_TITLE_CHANGED => {
            _ = app.update(.{ .session = .{ .id = @intCast(wparam), .what = .title } });
            return 0;
        },

        WM_APP_CLIPBOARD_WRITE => {
            _ = app.update(.{ .session = .{ .id = @intCast(wparam), .what = .clipboard } });
            return 0;
        },

        win32.WM_KEYDOWN, win32.WM_KEYUP, win32.WM_SYSKEYDOWN, win32.WM_SYSKEYUP => {
            return result(hwnd, msg, wparam, lparam, app.update(keyMsg(msg, wparam, lparam)));
        },

        win32.WM_CHAR, win32.WM_SYSCHAR => {
            _ = app.update(.{ .char = .{ .unit = @truncate(wparam), .sys = msg == win32.WM_SYSCHAR } });
            return 0;
        },

        win32.WM_DEADCHAR, win32.WM_SYSDEADCHAR => return 0,

        win32.WM_MOUSEMOVE,
        win32.WM_LBUTTONDOWN,
        win32.WM_LBUTTONUP,
        win32.WM_LBUTTONDBLCLK,
        win32.WM_RBUTTONDOWN,
        win32.WM_RBUTTONDBLCLK,
        win32.WM_MBUTTONDOWN,
        win32.WM_MBUTTONUP,
        win32.WM_MBUTTONDBLCLK,
        => {
            self.mouseInput(msg, wparam, lparam);
            return 0;
        },

        // A right click opens a context menu as it comes up, as
        // DefWindowProc's WM_CONTEXTMENU would.
        win32.WM_RBUTTONUP => {
            self.mouseInput(msg, wparam, lparam);
            _ = app.update(.{ .context_menu = .{ .x = win32.xLparam(lparam), .y = win32.yLparam(lparam) } });
            return 0;
        },

        // These alone return TRUE when handled.
        win32.WM_XBUTTONDOWN, win32.WM_XBUTTONUP, win32.WM_XBUTTONDBLCLK => {
            self.mouseInput(msg, wparam, lparam);
            return win32.TRUE;
        },

        win32.WM_MOUSELEAVE => {
            self.tracking_mouse = false;
            _ = app.update(.mouse_leave);
            return 0;
        },

        // Losing the capture mid-drag (alt+tab, a modal window) ends it.
        win32.WM_CAPTURECHANGED => {
            if (lparam != @as(isize, @bitCast(@intFromPtr(hwnd)))) _ = app.update(.capture_lost);
            return 0;
        },

        win32.WM_MOUSEWHEEL, win32.WM_MOUSEHWHEEL => {
            // Unlike other mouse messages, the position is in screen
            // coordinates.
            var pos: win32.POINT = .{ .x = win32.xLparam(lparam), .y = win32.yLparam(lparam) };
            _ = win32.ScreenToClient(hwnd, &pos);
            _ = app.update(.{ .wheel = .{ .msg = msg, .wparam = wparam, .pos = pos } });
            return 0;
        },

        win32.WM_SETCURSOR => {
            if (win32.loword(lparam) != win32.HTCLIENT)
                return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
            var pos: win32.POINT = undefined;
            _ = win32.GetCursorPos(&pos);
            _ = win32.ScreenToClient(hwnd, &pos);
            _ = win32.SetCursor(win32.LoadCursorW(null, systemCursor(app.cursor(pos))));
            return win32.TRUE;
        },

        win32.WM_DPICHANGED => {
            const rect: *const win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            self.dpi = win32.hiword(wparam);
            self.grid.setDpi(self.dpi);
            self.ui.setDpi(self.dpi) catch |err| log.err("chrome DPI change failed: {}", .{err});
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

/// A client area mouse message: arm the leave notification, then let the
/// app have it.
fn mouseInput(self: *Window, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) void {
    if (msg == win32.WM_MOUSEMOVE and !self.tracking_mouse) {
        var tme: win32.TRACKMOUSEEVENT = .{ .dwFlags = win32.TME_LEAVE, .hwndTrack = self.hwnd.? };
        self.tracking_mouse = win32.TrackMouseEvent(&tme) != 0;
    }
    const pos: win32.POINT = .{ .x = win32.xLparam(lparam), .y = win32.yLparam(lparam) };
    _ = self.app.update(.{ .mouse = .{ .msg = msg, .wparam = wparam, .pos = pos } });
}
