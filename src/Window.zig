//! A top-level Win32 window: our own title bar and session list (see
//! `Chrome`) around the active session's terminal. Heap allocated so that
//! its address can be stored in the HWND's user data.
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
const binding = @import("binding.zig");
const clipboard = @import("clipboard.zig");
const Stats = @import("Stats.zig");
const Config = @import("Config.zig");
const Session = @import("Session.zig");
const Chrome = @import("chrome/Chrome.zig");
const build_options = @import("build_options");
const Renderer = @import("renderer/D3D11.zig");
const Painter = Renderer.Painter;

const log = std.log.scoped(.window);

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("slime");

/// The icon resource in src/slime.rc.
const icon_id = 1;

/// Posted from a thread pool wait when a session's child exits. WPARAM
/// is the session's ID, as for the messages below.
pub const WM_APP_CHILD_EXITED = win32.WM_APP + 0;
/// Posted from a reader thread when the child sets the title.
pub const WM_APP_TITLE_CHANGED = win32.WM_APP + 1;
/// Posted from a reader thread when the child writes the clipboard.
pub const WM_APP_CLIPBOARD_WRITE = win32.WM_APP + 2;

/// Room for the stats report, in UTF-16 units.
const max_stats_len = 160;

const stats_timer_id = 1;
/// Draws pending output while DefWindowProc's modal move/size loop runs
/// instead of ours.
const sizemove_timer_id = 2;
/// Scrolls the viewport while a selection drag is above or below it.
pub const autoscroll_timer_id = 3;
/// Blinks the cursor while the window has focus.
const blink_timer_id = 4;

/// How long a frame waits for a cursor that output just hid to come
/// back. See `updateHold`.
const cursor_hold_ms = 4;
/// How long synchronized output (mode 2026) can hold frames back before
/// we reset it, Ghostty's `sync_reset_ms`.
const sync_hold_ms = 1000;
/// How long after a resize output from a background session isn't
/// activity: ConPTY redraws on every resize.
const resize_quiet_ms = 500;

alloc: Allocator,
io: std.Io,
/// Outlives the window.
config: *const Config,
/// What new sessions run, in CreateProcessW syntax. Outlives the window.
command_line: []const u16,
hwnd: ?win32.HWND = null,
/// The last stats report, which the chrome shows.
stats_text: [max_stats_len]u16 = undefined,
stats_len: usize = 0,
dpi: u32 = win32.USER_DEFAULT_SCREEN_DPI,

/// Shared by every session: they all draw at the same size.
grid: font.Grid,
chrome: Chrome,
/// Where everything is, from the last `layout`.
chrome_layout: Chrome.Layout = undefined,

/// Set last during creation; messages sent during CreateWindowExW
/// (WM_SIZE, etc.) arrive before everything else is ready.
renderer: ?Renderer = null,

/// Never empty once created: closing the last session closes the window.
sessions: std.ArrayList(*Session) = .empty,
/// The session shown and given input.
active: usize = 0,
next_session_id: u32 = 1,
/// Scratch for `view`, with room for every session.
view_sessions: std.ArrayList(Chrome.View.Session) = .empty,

/// Auto-reset event every session's reader thread sets after feeding
/// output to its terminal. The message loop waits on it alongside
/// messages and calls `outputArrived`. Not a posted message: those are
/// retrieved before input and timers, so a steady stream of them starves
/// the keyboard.
output_event: win32.HANDLE,

/// Something changed since the last frame. UI thread only.
dirty: bool = false,

/// Why frames are being held back, if they are. `hold_timer` fires when
/// the hold runs out. UI thread only.
hold: Hold = .none,
hold_timer: win32.HANDLE,

/// The last frame showed the terminal's cursor (blinking aside).
cursor_shown: bool = false,

/// The window has keyboard focus.
focused: bool = false,

/// The on phase of the cursor blink.
blink_visible: bool = true,

/// The virtual key of the last key binding run, so its release isn't
/// sent to the child either.
bound_key: ?u32 = null,

/// A mouse button went down over the terminal, which then gets the mouse
/// until every button is up.
mouse_in_terminal: bool = false,
/// The session a middle click went down on, to close it on release.
middle_pressed: ?usize = null,
/// TrackMouseEvent is armed for the mouse leaving the client area, and
/// for leaving the caption buttons.
tracking_mouse: bool = false,
tracking_nc_mouse: bool = false,

/// Output from background sessions before this tick count isn't
/// activity. See `resize_quiet_ms`.
quiet_until: u64 = 0,

/// Only used with `-Dstats`.
stats: Stats = .{},

const Hold = enum {
    none,
    /// The cursor the last frame showed was hidden.
    cursor,
    /// Synchronized output (mode 2026) is set.
    sync,
};

/// Create the window with one session running `command_line`
/// (CreateProcessW syntax).
pub fn create(alloc: Allocator, io: std.Io, config: *const Config, command_line: []const u16) !*Window {
    const instance = win32.GetModuleHandleW(null);
    try registerClass(instance);

    const self = try alloc.create(Window);
    errdefer alloc.destroy(self);
    const output_event = win32.CreateEventW(null, win32.FALSE, win32.FALSE, null) orelse
        return win32.lastError("CreateEventW");
    errdefer _ = win32.CloseHandle(output_event);
    // Manual reset, so a hold that ran out stays due until it's handled.
    const hold_timer = win32.CreateWaitableTimerExW(
        null,
        null,
        win32.CREATE_WAITABLE_TIMER_MANUAL_RESET | win32.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,
        win32.TIMER_ALL_ACCESS,
    ) orelse return win32.lastError("CreateWaitableTimerExW");
    errdefer _ = win32.CloseHandle(hold_timer);
    self.* = .{
        .alloc = alloc,
        .io = io,
        .config = config,
        .command_line = command_line,
        .output_event = output_event,
        .hold_timer = hold_timer,
        .grid = undefined,
        .chrome = undefined,
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
    const theme: Chrome.Theme = .init(config.background, config.foreground);
    const dark: win32.BOOL = if (theme.light) win32.FALSE else win32.TRUE;
    _ = win32.DwmSetWindowAttribute(hwnd, win32.DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, @sizeOf(win32.BOOL));

    self.dpi = win32.GetDpiForWindow(hwnd);
    self.grid = try .init(alloc, io, config.@"font-family".items, config.@"font-size", self.dpi);
    errdefer self.grid.deinit();
    self.chrome = try .init(self.dpi, theme);
    errdefer self.chrome.deinit();

    const size = self.clientSize();
    self.updateLayout(size);
    self.renderer = try Renderer.init(hwnd, size.width, size.height);
    errdefer {
        self.renderer.?.deinit();
        self.renderer = null;
    }

    try self.spawnSession();
    errdefer self.destroySessions();
    self.showTitle();

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
        self.destroySessions();
        r.deinit();
        self.chrome.deinit();
        self.grid.deinit();
    }
    self.view_sessions.deinit(self.alloc);
    _ = win32.CloseHandle(self.output_event);
    _ = win32.CloseHandle(self.hold_timer);
    self.alloc.destroy(self);
}

fn destroySessions(self: *Window) void {
    for (self.sessions.items) |s| s.destroy();
    self.sessions.clearAndFree(self.alloc);
}

pub fn activeSession(self: *const Window) *Session {
    return self.sessions.items[self.active];
}

fn sessionIndex(self: *const Window, id: u32) ?usize {
    for (self.sessions.items, 0..) |s, i| {
        if (s.id == id) return i;
    }
    return null;
}

/// Start a session running the window's command, and show it.
fn spawnSession(self: *Window) !void {
    try self.sessions.ensureUnusedCapacity(self.alloc, 1);
    try self.view_sessions.ensureTotalCapacity(self.alloc, self.sessions.items.len + 1);
    const grid_size = self.gridSize();
    const s = try Session.create(self, self.next_session_id, self.command_line, grid_size.cols, grid_size.rows);
    self.next_session_id +%= 1;
    self.sessions.appendAssumeCapacity(s);
    if (self.sessions.items.len > 1) self.activate(self.sessions.items.len - 1);
}

fn newSession(self: *Window) void {
    self.spawnSession() catch |err| log.err("new session failed: {}", .{err});
}

/// Close session `i`, killing what runs in it. Closing the last one
/// closes the window.
fn closeSession(self: *Window, i: usize) void {
    if (self.sessions.items.len <= 1) {
        _ = win32.PostMessageW(self.hwnd, win32.WM_CLOSE, 0, 0);
        return;
    }
    const was_active = i == self.active;
    if (was_active) self.deactivate();
    const s = self.sessions.orderedRemove(i);
    s.destroy();
    // Rows moved under the mouse.
    _ = self.chrome.setHover(.none);
    self.middle_pressed = null;
    if (i < self.active) {
        self.active -= 1;
    } else if (was_active) {
        self.active = @min(i, self.sessions.items.len - 1);
        self.activated();
    }
    self.dirty = true;
}

/// Show session `i` and give it input.
fn activate(self: *Window, i: usize) void {
    if (i == self.active or i >= self.sessions.items.len) return;
    self.deactivate();
    self.active = i;
    self.activated();
}

/// Let go of the active session before switching away from it.
fn deactivate(self: *Window) void {
    const s = self.activeSession();
    if (self.mouse_in_terminal) _ = win32.ReleaseCapture();
    self.mouse_in_terminal = false;
    s.cancelSelection();
    if (self.focused) s.reportFocus(false);
}

/// Take up the session that just became active.
fn activated(self: *Window) void {
    const s = self.activeSession();
    s.activity = false;
    s.unseen.store(false, .release);
    if (self.focused) s.reportFocus(true);
    // Holds were for the last session's updates.
    self.hold = .none;
    self.cursor_shown = false;
    self.resetBlink();
    self.showTitle();
    self.dirty = true;
}

/// Show the next or previous session, wrapping around.
fn cycle(self: *Window, forward: bool) void {
    const n = self.sessions.items.len;
    self.activate(if (forward) (self.active + 1) % n else (self.active + n - 1) % n);
}

/// The message loop's view of frame pacing: when `output_event` fires,
/// call `outputArrived`; while `needsFrame`, also wait on `frameGate` and
/// pass it to `frameGateFired` when it fires. Drawing then happens at most
/// once per display refresh, and right away when the terminal was idle.
pub fn outputArrived(self: *Window) void {
    const quiet = win32.GetTickCount64() < self.quiet_until;
    for (self.sessions.items, 0..) |s, i| {
        if (!s.unseen.swap(false, .acq_rel)) continue;
        if (i == self.active) {
            self.dirty = true;
            self.updateHold();
        } else if (!s.activity and !quiet) {
            s.activity = true;
            self.dirty = true;
        }
    }
}

pub fn needsFrame(self: *const Window) bool {
    return self.dirty;
}

pub fn frameGate(self: *const Window) win32.HANDLE {
    if (self.hold != .none) return self.hold_timer;
    return self.renderer.?.frameGate();
}

pub fn frameGateFired(self: *Window, gate: win32.HANDLE) void {
    if (gate == self.hold_timer) return self.holdExpired();
    const r = &self.renderer.?;
    // The pace timer only moves us on to waiting for the swap chain.
    if (gate != r.frame_waitable) return;
    r.frameAcquired();
    // A synchronous render (resize, WM_PAINT) may have drawn it already;
    // the acquired frame then waits for the next change.
    if (self.dirty) self.render();
}

/// Hold frames back while the child is partway through an update: while
/// synchronized output (mode 2026) is set, and briefly after it hides
/// the cursor the last frame showed. ConPTY passes console writes on as
/// they're made, so PSReadLine's `?25l`, line redraw, and `?25h` often
/// arrive in separate reads; drawing between them flashes a frame
/// without the cursor on every key.
fn updateHold(self: *Window) void {
    const s = self.activeSession();
    s.lockTerminal();
    const sync = s.terminal.modes.get(.synchronized_output);
    const cursor_hidden = !s.terminal.modes.get(.cursor_visible);
    s.unlockTerminal();

    const hold: Hold = if (sync) .sync else if (cursor_hidden and self.cursor_shown) .cursor else .none;
    if (hold == self.hold) return;
    self.hold = hold;
    const ms: i64 = switch (hold) {
        .none => return,
        .cursor => cursor_hold_ms,
        .sync => sync_hold_ms,
    };
    // Negative due times are relative, in 100 ns units. Setting the timer
    // also unsignals it.
    const due = -ms * 10_000;
    _ = win32.SetWaitableTimer(self.hold_timer, &due, 0, null, null, win32.FALSE);
}

/// Draw the held frame anyway.
fn holdExpired(self: *Window) void {
    // The timer may have been set again since it fired.
    if (win32.WaitForSingleObject(self.hold_timer, 0) != win32.WAIT_OBJECT_0) return;
    switch (self.hold) {
        .none => {},
        .cursor => self.cursor_shown = false,
        // Ghostty resets the mode too, so a child that never ends its
        // update can't freeze the screen.
        .sync => {
            const s = self.activeSession();
            s.lockTerminal();
            s.terminal.modes.set(.synchronized_output, false);
            s.unlockTerminal();
        },
    }
    self.hold = .none;
}

/// Run the key binding a key press triggers (see `binding.defaults`).
/// Returns true if the key is consumed, which also holds for the release
/// of a key that ran a binding.
fn keyBinding(self: *Window, msg: u32, wparam: win32.WPARAM) bool {
    const vk: u32 = @truncate(wparam);
    if (msg == win32.WM_KEYUP or msg == win32.WM_SYSKEYUP) {
        if (self.bound_key != vk) return false;
        self.bound_key = null;
        return true;
    }

    const b = binding.find(&binding.defaults, vk, input.currentMods()) orelse return false;
    if (!self.runAction(b.action) and b.performable) return false;

    // Drop the text TranslateMessage posted for the key (ctrl+shift+c
    // gives 0x03).
    var m: win32.MSG = undefined;
    while (win32.PeekMessageW(&m, self.hwnd, win32.WM_CHAR, win32.WM_DEADCHAR, win32.PM_REMOVE) != 0) {}
    self.bound_key = vk;
    return true;
}

/// Returns false if the action couldn't run: copy with no selection,
/// paste with no text on the clipboard.
fn runAction(self: *Window, action: binding.Action) bool {
    const s = self.activeSession();
    switch (action) {
        .copy_to_clipboard => return s.copySelection(),
        .paste_from_clipboard => {
            if (!clipboard.hasText()) return false;
            s.paste();
        },
        .new_tab => self.newSession(),
        .close_surface => self.closeSession(self.active),
        .next_tab => self.cycle(true),
        .previous_tab => self.cycle(false),
        .increase_font_size => |pt| self.setFontSize(self.grid.size_pt + pt),
        .decrease_font_size => |pt| self.setFontSize(self.grid.size_pt - pt),
        .reset_font_size => self.setFontSize(self.config.@"font-size"),
    }
    return true;
}

/// Change every session's font size, keeping the window's size: the grid
/// gains or loses cells instead.
fn setFontSize(self: *Window, size_pt: f32) void {
    const size = std.math.clamp(size_pt, 1, 255);
    if (size == self.grid.size_pt) return;
    self.grid.setSize(size);
    self.layout();
}

/// Track keyboard focus: the cursor blinks only while focused and is a
/// hollow block otherwise, and the active session's child hears about it.
fn setFocus(self: *Window, focused: bool) void {
    if (self.focused == focused) return;
    self.focused = focused;
    self.dirty = true;
    if (focused) {
        self.resetBlink();
    } else {
        _ = win32.KillTimer(self.hwnd, blink_timer_id);
    }
    self.activeSession().reportFocus(focused);
}

/// Start the blink over in its on phase. Blinking follows the system's
/// caret blink rate, and is off when the user turned caret blinking off.
pub fn resetBlink(self: *Window) void {
    if (!self.blink_visible) {
        self.blink_visible = true;
        self.dirty = true;
    }
    if (!self.focused) return;
    const ms = win32.GetCaretBlinkTime();
    if (ms == 0 or ms == win32.INFINITE) {
        _ = win32.KillTimer(self.hwnd, blink_timer_id);
    } else {
        // Setting an existing timer restarts it.
        _ = win32.SetTimer(self.hwnd, blink_timer_id, ms, null);
    }
}

fn blinkTick(self: *Window) void {
    self.blink_visible = !self.blink_visible;
    // Only redraw if the last frame's cursor blinks. One that starts
    // blinking later picks up the phase from here.
    const cursor = self.activeSession().render_state.cursor;
    if (cursor.visible and cursor.blinking) self.dirty = true;
}

/// The chrome's view of the window's state.
fn view(self: *Window) Chrome.View {
    // `spawnSession` keeps room for every session.
    self.view_sessions.clearRetainingCapacity();
    for (self.sessions.items) |s| {
        self.view_sessions.appendAssumeCapacity(.{ .title = s.title(), .activity = s.activity });
    }
    const bg = self.activeSession().cells.default_bg;
    return .{
        .sessions = self.view_sessions.items,
        .active = self.active,
        .focused = self.focused,
        .maximized = win32.IsZoomed(self.hwnd.?) != 0,
        .terminal_bg = Painter.rgb(@as(u24, bg.r) << 16 | @as(u24, bg.g) << 8 | bg.b),
        .stats = self.stats_text[0..self.stats_len],
    };
}

/// What's under a client position.
fn hitAt(self: *Window, pos: win32.POINT) Chrome.Hit {
    const v = self.view();
    return self.chrome.hitTest(&self.chrome_layout, &v, @floatFromInt(pos.x), @floatFromInt(pos.y));
}

/// A client position relative to the terminal area.
fn toTerminal(self: *const Window, pos: win32.POINT) win32.POINT {
    const t = self.chrome_layout.terminal;
    return .{ .x = pos.x - @as(i32, @intFromFloat(t.x)), .y = pos.y - @as(i32, @intFromFloat(t.y)) };
}

fn setHover(self: *Window, hit: Chrome.Hit) void {
    if (self.chrome.setHover(hit)) self.dirty = true;
}

fn setPressed(self: *Window, hit: Chrome.Hit) void {
    if (self.chrome.setPressed(hit)) self.dirty = true;
}

/// Handle a client area mouse message: the terminal gets it if a button
/// went down there (until all are up) or it's over the terminal, and the
/// chrome otherwise.
fn mouseInput(self: *Window, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) void {
    const pos: win32.POINT = .{ .x = win32.xLparam(lparam), .y = win32.yLparam(lparam) };
    const s = self.activeSession();
    const held = input.heldButton(wparam) != null;
    const press = if (input.mouseButton(msg, wparam)) |b| b[1] else false;

    if (msg == win32.WM_MOUSEMOVE and !self.tracking_mouse) {
        var tme: win32.TRACKMOUSEEVENT = .{ .dwFlags = win32.TME_LEAVE, .hwndTrack = self.hwnd.? };
        self.tracking_mouse = win32.TrackMouseEvent(&tme) != 0;
    }

    if (self.mouse_in_terminal) {
        s.mouseInput(msg, wparam, self.toTerminal(pos));
        if (!held) {
            self.mouse_in_terminal = false;
            // After the session's handled the release, so a selection
            // ends where the button came up.
            _ = win32.ReleaseCapture();
        }
        return;
    }

    const hit = self.hitAt(pos);
    self.setHover(hit);
    if (hit == .terminal) {
        if (press) {
            // Capture the mouse while a button is down, so a drag past
            // the edge still reports and the release comes back to us.
            self.mouse_in_terminal = true;
            _ = win32.SetCapture(self.hwnd.?);
        }
        s.mouseInput(msg, wparam, self.toTerminal(pos));
        return;
    }

    switch (msg) {
        win32.WM_LBUTTONDOWN => {
            self.setPressed(hit);
            _ = win32.SetCapture(self.hwnd.?);
            // Rows switch on press, as tabs do.
            if (hit == .session) self.activate(hit.session);
        },
        win32.WM_LBUTTONUP => {
            const pressed = self.chrome.pressed;
            self.setPressed(.none);
            _ = win32.ReleaseCapture();
            if (pressed.eql(hit)) self.chromeClick(hit);
        },
        win32.WM_MBUTTONDOWN => self.middle_pressed = switch (hit) {
            .session, .close_session => |i| i,
            else => null,
        },
        win32.WM_MBUTTONUP => {
            const pressed = self.middle_pressed orelse return;
            self.middle_pressed = null;
            switch (hit) {
                .session, .close_session => |i| if (i == pressed) self.closeSession(i),
                else => {},
            }
        },
        else => {},
    }
}

fn chromeClick(self: *Window, hit: Chrome.Hit) void {
    switch (hit) {
        .toggle_mode => {
            self.chrome.toggleMode();
            self.layout();
        },
        .new_session => self.newSession(),
        .close_session => |i| self.closeSession(i),
        else => {},
    }
}

/// The caption buttons, which come as non-client messages.
fn captionHit(ht: win32.WPARAM) Chrome.Hit {
    return switch (ht) {
        win32.HTMINBUTTON => .minimize,
        win32.HTMAXBUTTON => .maximize,
        win32.HTCLOSE => .close,
        else => .none,
    };
}

fn captionClick(self: *Window, hit: Chrome.Hit) void {
    const hwnd = self.hwnd.?;
    switch (hit) {
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
    return switch (self.hitAt(pos)) {
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
pub fn terminalSize(self: *const Window) ClientSize {
    const t = self.chrome_layout.terminal;
    return .{ .width = @intFromFloat(t.w), .height = @intFromFloat(t.h) };
}

pub const PaddingPx = struct { left: u32, right: u32, top: u32, bottom: u32 };

/// The space around the grid in the terminal area: the configured
/// padding, in points, as pixels at the current DPI, plus the chrome's
/// inset at the left and top.
pub fn paddingPx(self: *const Window) PaddingPx {
    const x = self.config.@"window-padding-x";
    const y = self.config.@"window-padding-y";
    const inset: u32 = @intFromFloat(self.chrome_layout.inset);
    return .{
        .left = x.top_left * self.dpi / 72 + inset,
        .right = x.bottom_right * self.dpi / 72,
        .top = y.top_left * self.dpi / 72 + inset,
        .bottom = y.bottom_right * self.dpi / 72,
    };
}

/// The number of whole cells that fit in the terminal area.
fn gridSize(self: *const Window) struct { cols: u16, rows: u16 } {
    const size = self.terminalSize();
    const m = self.grid.metrics;
    const pad = self.paddingPx();
    return .{
        .cols = @intCast(std.math.clamp((size.width -| pad.left -| pad.right) / m.cell_width, 1, std.math.maxInt(u16))),
        .rows = @intCast(std.math.clamp((size.height -| pad.top -| pad.bottom) / m.cell_height, 1, std.math.maxInt(u16))),
    };
}

pub fn cellSizePx(self: *const Window) std.meta.Child(@FieldType(ghostty_vt.Terminal.Resize, "cell_size_px")) {
    const m = self.grid.metrics;
    return .{ .width = m.cell_width, .height = m.cell_height };
}

fn render(self: *Window) void {
    const r = &(self.renderer orelse return);
    self.renderFallible(r) catch |err| log.err("render failed: {}", .{err});
}

/// The chrome, as the renderer draws it over the terminal.
const Ui = struct {
    window: *Window,
    view: Chrome.View,

    pub fn paint(self: Ui, p: *Painter) void {
        self.window.chrome.paint(p, &self.window.chrome_layout, &self.view);
    }
};

fn renderFallible(self: *Window, r: *Renderer) !void {
    r.waitForFrame();
    self.dirty = false;
    const s = self.activeSession();
    const stats = build_options.stats;
    var t: i64 = if (stats) Stats.now() else 0;
    {
        s.lockTerminal();
        defer s.unlockTerminal();
        try s.render_state.update(self.alloc, &s.terminal);
        try s.images.update(self.alloc, &s.terminal);
    }
    if (stats) t = self.stats.lap(.update, t);
    self.cursor_shown = s.render_state.cursor.visible;
    try s.cells.build(self.alloc, &s.render_state, &self.grid, .{
        .focused = self.focused,
        .blink_visible = self.blink_visible,
    }, .{
        .cursor_color = self.config.@"cursor-color",
        .cursor_text = self.config.@"cursor-text",
        .selection_background = self.config.@"selection-background",
        .selection_foreground = self.config.@"selection-foreground",
    });
    if (stats) t = self.stats.lap(.build, t);
    const pad = self.paddingPx();
    try r.draw(self.alloc, .{
        .cells = &s.cells,
        .images = &s.images,
        .textures = &s.textures,
        .atlas = &self.grid.atlas,
        .metrics = self.grid.metrics,
        .viewport = self.chrome_layout.terminal,
        .grid_offset = .{ @floatFromInt(pad.left), @floatFromInt(pad.top) },
    }, Ui{ .window = self, .view = self.view() });
    if (stats) {
        _ = self.stats.lap(.draw, t);
        self.stats.frames += 1;
    }
}

/// Take the last second's stats for the chrome to show.
fn showStats(self: *Window) void {
    var utf8: [max_stats_len]u8 = undefined;
    const text = self.stats.report(&utf8);
    self.stats_len = std.unicode.utf8ToUtf16Le(&self.stats_text, text) catch 0;
    self.dirty = true;
}

/// Set the window text, which the taskbar shows: the active session's
/// title.
fn showTitle(self: *Window) void {
    var text: [Session.max_title_len + 1]u16 = undefined;
    const title = self.activeSession().title();
    const len = @min(title.len, Session.max_title_len);
    @memcpy(text[0..len], title[0..len]);
    text[len] = 0;
    _ = win32.SetWindowTextW(self.hwnd.?, text[0..len :0]);
}

fn updateLayout(self: *Window, size: ClientSize) void {
    self.chrome_layout = self.chrome.layout(@floatFromInt(size.width), @floatFromInt(size.height));
}

/// Fit the swap chain, the chrome, and every session's grid to the
/// client area and redraw.
fn layout(self: *Window) void {
    const r = &(self.renderer orelse return);
    const size = self.clientSize();
    if (size.width == 0 or size.height == 0) return;

    r.resize(size.width, size.height) catch |err| {
        log.err("resize failed: {}", .{err});
        return;
    };
    self.updateLayout(size);

    const grid_size = self.gridSize();
    self.quiet_until = win32.GetTickCount64() + resize_quiet_ms;
    for (self.sessions.items) |s| s.resize(grid_size.cols, grid_size.rows);

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

    // Only the frame is ours to handle until the first session runs.
    if (self.sessions.items.len == 0 and msg != win32.WM_NCCALCSIZE)
        return win32.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        // Take the caption's space for the client area, keeping the
        // other borders. A maximized window hangs its borders off
        // screen, so its client area starts below the top one.
        win32.WM_NCCALCSIZE => {
            if (wparam == 0) return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
            const params: *win32.NCCALCSIZE_PARAMS = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const top = params.rgrc[0].top;
            const result = win32.DefWindowProcW(hwnd, msg, wparam, lparam);
            if (result != 0) return result;
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
            self.setHover(captionHit(wparam));
            return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        win32.WM_NCMOUSELEAVE => {
            self.tracking_nc_mouse = false;
            switch (self.chrome.hover) {
                .minimize, .maximize, .close => self.setHover(.none),
                else => {},
            }
            switch (self.chrome.pressed) {
                .minimize, .maximize, .close => self.setPressed(.none),
                else => {},
            }
            return 0;
        },

        win32.WM_NCLBUTTONDOWN, win32.WM_NCLBUTTONDBLCLK => {
            const hit = captionHit(wparam);
            if (hit == .none) return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
            self.setPressed(hit);
            return 0;
        },

        win32.WM_NCLBUTTONUP => {
            const hit = captionHit(wparam);
            const pressed = self.chrome.pressed;
            self.setPressed(.none);
            if (hit == .none) return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
            if (pressed.eql(hit)) self.captionClick(hit);
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
                autoscroll_timer_id => self.activeSession().autoscrollTick(),
                blink_timer_id => self.blinkTick(),
                sizemove_timer_id => {
                    if (win32.WaitForSingleObject(self.output_event, 0) == win32.WAIT_OBJECT_0) self.outputArrived();
                    if (self.dirty) self.render();
                },
                else => {},
            }
            return 0;
        },

        win32.WM_SETFOCUS, win32.WM_KILLFOCUS => {
            self.setFocus(msg == win32.WM_SETFOCUS);
            return 0;
        },

        WM_APP_CHILD_EXITED => {
            if (self.sessionIndex(@intCast(wparam))) |i| self.closeSession(i);
            return 0;
        },

        WM_APP_TITLE_CHANGED => {
            const i = self.sessionIndex(@intCast(wparam)) orelse return 0;
            self.sessions.items[i].titleUpdate();
            if (i == self.active) self.showTitle();
            self.dirty = true;
            return 0;
        },

        WM_APP_CLIPBOARD_WRITE => {
            const i = self.sessionIndex(@intCast(wparam)) orelse return 0;
            self.sessions.items[i].clipboardWriteFlush();
            return 0;
        },

        win32.WM_KEYDOWN, win32.WM_KEYUP, win32.WM_SYSKEYDOWN, win32.WM_SYSKEYUP => {
            if (self.keyBinding(msg, wparam)) return 0;
            switch (wparam) {
                // The text arrives as WM_CHAR.
                win32.VK_PACKET, win32.VK_PROCESSKEY => {},
                // Keep alt+F4.
                win32.VK_F4 => if (msg == win32.WM_SYSKEYDOWN and win32.GetKeyState(win32.VK_MENU) < 0) {
                    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                } else self.activeSession().keyInput(msg, wparam, lparam),
                else => self.activeSession().keyInput(msg, wparam, lparam),
            }
            // Not passing WM_SYSKEYUP on also keeps a lone alt from
            // entering menu mode.
            return 0;
        },

        win32.WM_CHAR, win32.WM_SYSCHAR => {
            self.activeSession().charInput(@truncate(wparam));
            return 0;
        },

        win32.WM_DEADCHAR, win32.WM_SYSDEADCHAR => return 0,

        win32.WM_MOUSEMOVE,
        win32.WM_LBUTTONDOWN,
        win32.WM_LBUTTONUP,
        win32.WM_RBUTTONDOWN,
        win32.WM_RBUTTONUP,
        win32.WM_MBUTTONDOWN,
        win32.WM_MBUTTONUP,
        => {
            self.mouseInput(msg, wparam, lparam);
            return 0;
        },

        // These alone return TRUE when handled.
        win32.WM_XBUTTONDOWN, win32.WM_XBUTTONUP => {
            self.mouseInput(msg, wparam, lparam);
            return win32.TRUE;
        },

        win32.WM_MOUSELEAVE => {
            self.tracking_mouse = false;
            self.setHover(.none);
            return 0;
        },

        // Losing the capture mid-drag (alt+tab, a modal window) ends it.
        win32.WM_CAPTURECHANGED => {
            if (lparam != @as(isize, @bitCast(@intFromPtr(hwnd)))) {
                if (self.mouse_in_terminal) {
                    self.mouse_in_terminal = false;
                    self.activeSession().cancelSelection();
                }
                self.setPressed(.none);
            }
            return 0;
        },

        win32.WM_MOUSEWHEEL, win32.WM_MOUSEHWHEEL => {
            // Unlike other mouse messages, the position is in screen
            // coordinates.
            var pos: win32.POINT = .{ .x = win32.xLparam(lparam), .y = win32.yLparam(lparam) };
            _ = win32.ScreenToClient(hwnd, &pos);
            if (self.mouse_in_terminal or self.hitAt(pos) == .terminal) {
                self.activeSession().mouseWheel(msg, wparam, self.toTerminal(pos));
            }
            return 0;
        },

        win32.WM_SETCURSOR => {
            if (win32.loword(lparam) != win32.HTCLIENT)
                return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
            var pos: win32.POINT = undefined;
            _ = win32.GetCursorPos(&pos);
            _ = win32.ScreenToClient(hwnd, &pos);
            var cursor = win32.IDC_ARROW;
            if (self.mouse_in_terminal or self.hitAt(pos) == .terminal) {
                const s = self.activeSession();
                s.lockTerminal();
                const shape = s.terminal.mouse_shape;
                s.unlockTerminal();
                cursor = mouseCursor(shape);
            }
            _ = win32.SetCursor(win32.LoadCursorW(null, cursor));
            return win32.TRUE;
        },

        win32.WM_DPICHANGED => {
            const rect: *const win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            self.dpi = win32.hiword(wparam);
            self.grid.setDpi(self.dpi);
            self.chrome.setDpi(self.dpi) catch |err| log.err("chrome DPI change failed: {}", .{err});
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
