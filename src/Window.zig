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
const SshConnection = @import("SshConnection.zig");
const Slimed = @import("Slimed.zig");
const Hosts = @import("Hosts.zig");
const Login = @import("Login.zig");
const Chrome = @import("chrome/Chrome.zig");
const build_options = @import("build_options");
const Renderer = @import("renderer/D3D11.zig");
const Painter = Renderer.Painter;

const log = std.log.scoped(.window);

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("slime");

/// The icon resource in src/slime.rc.
const icon_id = 1;

/// Posted from a thread pool wait when a session's child exits, or from
/// its reader thread when an SSH session's channel ends. WPARAM is the
/// session's ID, as for the messages below.
pub const WM_APP_CHILD_EXITED = win32.WM_APP + 0;
/// Posted from a reader thread when the child sets the title.
pub const WM_APP_TITLE_CHANGED = win32.WM_APP + 1;
/// Posted from a reader thread when the child writes the clipboard.
pub const WM_APP_CLIPBOARD_WRITE = win32.WM_APP + 2;
/// Posted from an SSH connection's reader thread when logging in has
/// something to show. WPARAM is the channel (session) ID, or 0 once
/// logged in.
pub const WM_APP_SSH_LOGIN = win32.WM_APP + 3;
/// Posted from slimed's connection reader when panes arrive for
/// sessions (`Slimed.takeArrivals`).
pub const WM_APP_SLIMED = win32.WM_APP + 4;

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
/// Steps a login dialog's spinner while it waits.
const spinner_timer_id = 5;
const spinner_ms = 100;
/// Shows a tooltip once the mouse rests on a button.
const tip_timer_id = 6;
/// How long after a tooltip hides the next shows without waiting.
const tip_warm_ms = 1000;

/// The keys tooltips name.
const new_session_key = binding.label(&binding.defaults, .new_tab);
const close_session_key = binding.label(&binding.defaults, .close_surface);

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
/// What local sessions run, in CreateProcessW syntax. Outlives the
/// window.
local_command: []const u16,
/// The SSH hosts the sidebar lists. Outlives the window.
hosts: *Hosts,
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
/// Grouped as the sidebar shows them: local sessions first, then each
/// connection's together.
sessions: std.ArrayList(*Session) = .empty,
/// The session shown and given input.
active: usize = 0,
next_session_id: u32 = 1,
/// Scratch for `view`, with room for every session and group.
view_sessions: std.ArrayList(Chrome.View.Session) = .empty,
view_groups: std.ArrayList(Chrome.View.Group) = .empty,

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

/// The host being typed after "Connect" was clicked. Takes the keyboard
/// while set.
connect_field: ?Chrome.TextField = null,

/// The connection to slimed, with `persist-sessions`: local sessions are
/// panes of the workspace it holds for this window.
slimed: ?*Slimed = null,

/// Until when the next tooltip shows at once. See `tip_warm_ms`.
tip_warm_until: u64 = 0,

/// The spinner's timer is running, and its step.
spinning: bool = false,
spinner_step: u32 = 0,

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
/// (CreateProcessW syntax, or an `ssh://` URL, which is remembered in
/// `hosts`). Local sessions opened later run `local_command`.
pub fn create(alloc: Allocator, io: std.Io, config: *const Config, hosts: *Hosts, command_line: []const u16, local_command: []const u16) !*Window {
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
        .local_command = local_command,
        .hosts = hosts,
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
    self.grid = try .init(alloc, io, config.@"font-family".items, config.@"font-size", self.dpi, config.@"font-antialias");
    errdefer self.grid.deinit();
    self.chrome = try .init(self.dpi, config.@"chrome-scale", theme);
    errdefer self.chrome.deinit();

    const size = self.clientSize();
    self.updateLayout(size);
    self.renderer = try Renderer.init(hwnd, size.width, size.height, config.@"font-antialias");
    errdefer {
        self.renderer.?.deinit();
        self.renderer = null;
    }

    try self.reserveGroups();
    const ssh_scheme = std.unicode.utf8ToUtf16LeStringLiteral("ssh://");
    if (std.mem.startsWith(u16, command_line, ssh_scheme)) {
        try self.spawnSession(.{ .host = try hosts.add(command_line) });
    } else if (!(config.@"persist-sessions" and self.connectSlimed(command_line))) {
        try self.spawnSession(.{ .command = command_line });
    }
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
    // Hanging up detaches the workspace; slimed keeps it for the next
    // window.
    if (self.slimed) |conn| conn.deinit();
    self.view_sessions.deinit(self.alloc);
    self.view_groups.deinit(self.alloc);
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

/// Where a new session runs.
const Target = union(enum) {
    /// A command line on this machine, CreateProcessW syntax.
    command: []const u16,
    /// A shell on remembered host `i`: on a live connection its sessions
    /// use, else a new one.
    host: usize,
    /// A pane of our slimed workspace.
    slimed: *const Slimed.Arrival,
};

/// With `persist-sessions`: connect to slimed and attach the workspace
/// detached last (a new one running `command` if none), making a session
/// of each pane. Returns whether any came.
fn connectSlimed(self: *Window, command: []const u16) bool {
    const conn = Slimed.connect(self.alloc, .{ .hwnd = self.hwnd.?, .msg = WM_APP_SLIMED }, self.slimedArea(), self.slimedSize(), command) catch |err| {
        log.err("connecting to slimed failed: {}; sessions won't outlive the window", .{err});
        return false;
    };
    self.slimed = conn;
    self.adoptArrivals();
    conn.start() catch |err| {
        log.err("starting slimed's reader failed: {}", .{err});
        self.destroySessions();
        conn.deinit();
        self.slimed = null;
        return false;
    };
    if (self.sessions.items.len > 0) self.activate(0);
    return self.sessions.items.len > 0;
}

/// Make sessions of the panes slimed delivered. The one we asked for is
/// shown; others (a script's) are added without taking focus.
fn adoptArrivals(self: *Window) void {
    const conn = self.slimed orelse return;
    const arrivals = conn.takeArrivals();
    defer {
        for (arrivals) |*a| a.deinit(self.alloc);
        self.alloc.free(arrivals);
    }
    for (arrivals) |*a| {
        const shown: ?*Session = if (self.sessions.items.len > 0) self.activeSession() else null;
        self.spawnSession(.{ .slimed = a }) catch |err| {
            log.err("showing slimed pane {d} failed: {}", .{ a.pane, err });
            conn.release(a.pane);
            continue;
        };
        if (!a.requested) if (shown) |s| if (self.sessionIndex(s.id)) |i| self.activate(i);
    }
    self.dirty = true;
}

/// The grid a slimed pane gets: the terminal area, as for any session.
fn slimedSize(self: *const Window) Slimed.Size {
    const grid = self.gridSize();
    const cell = self.cellSizePx();
    return .{ .cols = grid.cols, .rows = grid.rows, .cell_width = cell.width, .cell_height = cell.height };
}

/// The pixels a tab's panes share, inside the padding, and the cell size
/// of panes that haven't said their own.
fn slimedArea(self: *const Window) Slimed.Area {
    const size = self.terminalSize();
    const pad = self.paddingPx();
    const cell = self.cellSizePx();
    return .{
        .width = size.width -| pad.left -| pad.right,
        .height = size.height -| pad.top -| pad.bottom,
        .cell_width = cell.width,
        .cell_height = cell.height,
    };
}

/// Start a session on `target`, at the end of its group, and show it.
/// One that joins a connection doesn't log in again, and starts in the
/// directory the active session's shell last reported (OSC 7) if that's
/// on the same connection.
fn spawnSession(self: *Window, target: Target) !void {
    try self.sessions.ensureUnusedCapacity(self.alloc, 1);
    try self.view_sessions.ensureTotalCapacity(self.alloc, self.sessions.items.len + 1);
    try self.reserveGroups();
    const grid_size = self.gridSize();
    // Channel IDs are session IDs, and the helper takes 0 to mean the
    // connection.
    if (self.next_session_id == 0) self.next_session_id = 1;

    var new_conn: ?*SshConnection = null;
    const conn: ?*SshConnection = switch (target) {
        .command, .slimed => null,
        .host => |h| self.hostConnection(h) orelse conn: {
            new_conn = try SshConnection.spawn(self.alloc, self.hosts.items.items[h], .{ .hwnd = self.hwnd.?, .msg = WM_APP_SSH_LOGIN });
            break :conn new_conn;
        },
    };
    var cwd_buf: [4096]u8 = undefined;
    const launch: Session.Launch = if (conn) |c| .{ .ssh = .{
        .conn = c,
        .title = c.label(),
        .cwd = if (self.sessions.items.len > 0 and self.activeSession().sshConnection() == c)
            self.activeSession().pwd(&cwd_buf)
        else
            null,
    } } else switch (target) {
        .command => |command| .{ .command = command },
        .slimed => |a| .{ .slimed = .{ .conn = self.slimed.?, .arrival = a } },
        .host => unreachable,
    };
    const s = Session.create(self, self.next_session_id, launch, grid_size.cols, grid_size.rows) catch |err| {
        if (new_conn) |c| c.shutdownIfUnused();
        return err;
    };
    self.next_session_id +%= 1;

    const at = self.groupEnd(self.groupOf(s));
    self.sessions.insertAssumeCapacity(at, s);
    if (self.sessions.items.len == 1) return;
    // The rows from `at` on moved down.
    if (at <= self.active) self.active += 1;
    _ = self.chrome.setHover(.none);
    self.middle_pressed = null;
    self.activate(at);
}

/// Room in `view`'s scratch for Local and every host.
fn reserveGroups(self: *Window) !void {
    try self.view_groups.ensureTotalCapacity(self.alloc, 1 + self.hosts.items.items.len);
}

/// The sidebar group `s` is listed in: 0 for Local, else 1 plus its
/// host's index. Sessions are kept in group order.
fn groupOf(self: *const Window, s: *const Session) usize {
    const conn = s.sshConnection() orelse return 0;
    // A host isn't forgotten while sessions use it.
    return 1 + (self.hosts.indexOf(conn.destination) orelse return 0);
}

/// Where a session in group `g` goes: after the group's last.
fn groupEnd(self: *const Window, g: usize) usize {
    var i: usize = 0;
    while (i < self.sessions.items.len and self.groupOf(self.sessions.items[i]) <= g) i += 1;
    return i;
}

/// A live connection to host `h` that its sessions use, the active
/// session's if it's one.
fn hostConnection(self: *const Window, h: usize) ?*SshConnection {
    if (self.sessions.items.len > 0) {
        const active = self.activeSession();
        if (self.groupOf(active) == h + 1) if (active.sshConnection()) |c| if (c.isAlive()) return c;
    }
    for (self.sessions.items) |s| {
        if (self.groupOf(s) != h + 1) continue;
        if (s.sshConnection()) |c| if (c.isAlive()) return c;
    }
    return null;
}

/// A session in the active session's group.
fn newSession(self: *Window) void {
    self.newSessionIn(self.groupOf(self.activeSession()));
}

/// A session in sidebar group `g`: a local one, or one on a host.
fn newSessionIn(self: *Window, g: usize) void {
    // In slimed, the session comes when its pane does (WM_APP_SLIMED).
    if (g == 0) if (self.slimed) |conn| {
        conn.tabNew(self.local_command, self.slimedSize()) catch |err| {
            log.err("new tab in slimed failed: {}; running it directly", .{err});
            self.spawnSession(.{ .command = self.local_command }) catch |e| log.err("new session failed: {}", .{e});
        };
        return;
    };
    const target: Target = if (g == 0) .{ .command = self.local_command } else .{ .host = g - 1 };
    self.spawnSession(target) catch |err| log.err("new session failed: {}", .{err});
}

/// Drop the host behind group `g` from the sidebar, if no session uses
/// it.
fn forgetHost(self: *Window, g: usize) void {
    if (g == 0 or g > self.hosts.items.items.len) return;
    for (self.sessions.items) |s| {
        if (self.groupOf(s) == g) return;
    }
    self.hosts.remove(g - 1);
    _ = self.chrome.setHover(.none);
    self.dirty = true;
}

/// Close session `i`, killing what runs in it. Closing the last one
/// closes the window.
fn closeSession(self: *Window, i: usize) void {
    if (self.sessions.items.len <= 1) {
        // Closing the window only detaches a slimed session.
        self.sessions.items[i].kill();
        _ = win32.PostMessageW(self.hwnd, win32.WM_CLOSE, 0, 0);
        return;
    }
    const was_active = i == self.active;
    if (was_active) self.deactivate();
    const s = self.sessions.orderedRemove(i);
    s.kill();
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
    self.updateSpinner();
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
    if (!focused) self.hideTip();
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
    if (self.connect_field != null) self.dirty = true;
}

/// Show the host field in place of "Connect".
fn startConnect(self: *Window) void {
    if (self.connect_field != null) return;
    // Destinations go on the helper's command line unquoted.
    self.connect_field = .{ .reject = std.unicode.utf8ToUtf16LeStringLiteral(" \t\"") };
    self.resetBlink();
    self.dirty = true;
}

fn cancelConnect(self: *Window) void {
    if (self.connect_field == null) return;
    self.connect_field = null;
    self.dirty = true;
}

/// Connect to the host in the field, `ssh://` being implied, and close
/// the field.
fn submitConnect(self: *Window) void {
    const field = &(self.connect_field orelse return);
    const scheme = std.unicode.utf8ToUtf16LeStringLiteral("ssh://");
    var buf: [scheme.len + Chrome.TextField.max_len]u16 = undefined;
    const host = field.text();
    const dest = if (std.mem.startsWith(u16, host, scheme)) host else dest: {
        @memcpy(buf[0..scheme.len], scheme);
        @memcpy(buf[scheme.len..][0..host.len], host);
        break :dest buf[0 .. scheme.len + host.len];
    };
    if (dest.len > scheme.len) connect: {
        const h = self.hosts.add(dest) catch |err| break :connect log.err("connect failed: {}", .{err});
        self.spawnSession(.{ .host = h }) catch |err| log.err("connect failed: {}", .{err});
    }
    self.cancelConnect();
}

/// A key down while the host field is open. Returns false for keys it
/// doesn't take.
fn connectKey(self: *Window, vk: u32) bool {
    const field = &(self.connect_field orelse return false);
    switch (vk) {
        win32.VK_RETURN => self.submitConnect(),
        win32.VK_ESCAPE => self.cancelConnect(),
        else => if (!self.editKey(field, vk, true)) return false,
    }
    self.keyHandled();
    return true;
}

/// Edit `field` for an editing key, as Windows edit controls do.
/// `copyable` is false for passwords. Returns false for other keys.
fn editKey(self: *Window, field: *Chrome.TextField, vk: u32, copyable: bool) bool {
    const ctrl = win32.GetKeyState(win32.VK_CONTROL) < 0;
    const shift = win32.GetKeyState(win32.VK_SHIFT) < 0;
    switch (vk) {
        win32.VK_LEFT => field.press(.left, ctrl, shift),
        win32.VK_RIGHT => field.press(.right, ctrl, shift),
        win32.VK_HOME => field.press(.home, ctrl, shift),
        win32.VK_END => field.press(.end, ctrl, shift),
        win32.VK_BACK => field.press(.backspace, ctrl, false),
        win32.VK_DELETE => if (shift) self.fieldCopy(field, true, copyable) else field.press(.delete, ctrl, false),
        win32.VK_INSERT => if (ctrl) self.fieldCopy(field, false, copyable) else if (shift) self.fieldPaste(field) else return false,
        'A' => if (ctrl) field.press(.select_all, false, false) else return false,
        'C' => if (ctrl) self.fieldCopy(field, false, copyable) else return false,
        'X' => if (ctrl) self.fieldCopy(field, true, copyable) else return false,
        'V' => if (ctrl) self.fieldPaste(field) else return false,
        else => return false,
    }
    return true;
}

/// After a field took a key: drop its text (Enter's CR would reach the
/// session next), and show the change.
fn keyHandled(self: *Window) void {
    var m: win32.MSG = undefined;
    while (win32.PeekMessageW(&m, self.hwnd, win32.WM_CHAR, win32.WM_DEADCHAR, win32.PM_REMOVE) != 0) {}
    self.resetBlink();
    self.dirty = true;
}

/// Copy `field`'s selection, cutting it if `cut`. A password's isn't
/// copied, or cut.
fn fieldCopy(self: *Window, field: *Chrome.TextField, cut: bool, copyable: bool) void {
    const units = field.selected();
    if (units.len == 0 or !copyable) return;
    const text = std.unicode.utf16LeToUtf8Alloc(self.alloc, units) catch return;
    defer self.alloc.free(text);
    clipboard.set(self.hwnd.?, text) catch |err| return log.warn("copy failed: {}", .{err});
    if (cut) field.press(.delete, false, false);
}

/// Paste the clipboard's first line into `field`.
fn fieldPaste(self: *Window, field: *Chrome.TextField) void {
    const text = (clipboard.get(self.alloc, self.hwnd) catch |err| return log.warn("paste failed: {}", .{err})) orelse return;
    defer self.alloc.free(text);
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, text, " \t\r\n"), '\n');
    const line = lines.first();
    const units = std.unicode.utf8ToUtf16LeAlloc(self.alloc, line) catch return;
    defer self.alloc.free(units);
    field.insert(units);
}

/// The active session's login dialog, which has the keyboard unless the
/// host field does.
fn activeLogin(self: *const Window) ?*Login {
    if (self.connect_field != null) return null;
    return self.activeSession().login;
}

/// A key down for the active session's login dialog. Returns false for
/// keys it doesn't take.
fn loginKey(self: *Window, vk: u32) bool {
    const login = self.activeLogin() orelse return false;
    const d = &login.dialog;
    switch (vk) {
        win32.VK_RETURN => if (d.enterAction()) |action| self.loginAction(action),
        win32.VK_SPACE => if (d.focusedButton()) |b| self.loginAction(b.action) else return false,
        win32.VK_ESCAPE => self.loginAction(d.escapeAction()),
        // Ctrl+Tab still switches sessions.
        win32.VK_TAB => if (win32.GetKeyState(win32.VK_CONTROL) < 0)
            return false
        else
            d.cycleFocus(win32.GetKeyState(win32.VK_SHIFT) >= 0),
        else => {
            const field = d.focused() orelse return false;
            if (!self.editKey(field, vk, d.fields[d.focus.field].echo)) return false;
        },
    }
    self.keyHandled();
    return true;
}

/// Act on a login dialog's button for the active session.
fn loginAction(self: *Window, action: Chrome.Dialog.Action) void {
    const s = self.activeSession();
    const login = s.login orelse return;
    const conn = s.sshConnection() orelse return;
    switch (action) {
        .accept, .skip => {
            var buf: [Chrome.Dialog.max_fields][]const u16 = undefined;
            const choice: SshConnection.Choice = if (action == .accept) .accept else .skip;
            conn.sendAnswer(s.id, choice, login.answers(&buf)) catch |err| log.warn("answering failed: {}", .{err});
            login.answered();
        },
        .cancel => {
            // A prompt takes it as its answer; while the server works on
            // one, it gives up on logging in.
            conn.sendAnswer(s.id, .cancel, &.{}) catch {};
            self.closeLogin(s);
        },
        .close => self.closeLogin(s),
    }
    self.updateSpinner();
    self.dirty = true;
}

fn closeLogin(self: *Window, s: *Session) void {
    const login = s.login orelse return;
    login.destroy();
    s.login = null;
    _ = self.chrome.setHover(.none);
    self.updateSpinner();
    self.dirty = true;
}

/// The helper asked or reported something while logging in (WPARAM is
/// the channel, 0 when it logged in).
fn loginChanged(self: *Window, id: u32) void {
    defer self.updateSpinner();
    self.dirty = true;
    if (id == 0) {
        // Logged in: nothing more to show.
        for (self.sessions.items) |s| {
            const conn = s.sshConnection() orelse continue;
            if (s.login != null and conn.isConnected()) self.closeLogin(s);
        }
        return;
    }
    const s = self.sessions.items[self.sessionIndex(id) orelse return];
    const conn = s.sshConnection() orelse return;
    var taken = conn.takeLogin();
    defer taken.deinit(conn.alloc);
    if (taken.prompt == null and taken.info == null) return;
    const login = s.login orelse login: {
        s.login = Login.create(self.alloc, conn.label()) catch return;
        break :login s.login.?;
    };
    if (taken.info) |text| login.info(text);
    if (taken.prompt) |prompt| {
        login.ask(prompt);
        taken.prompt = null;
    }
    if (s == self.activeSession()) self.resetBlink();
}

/// Run the spinner's timer while the active session's dialog waits.
fn updateSpinner(self: *Window) void {
    const waiting = if (self.activeSession().login) |l| l.dialog.state == .waiting else false;
    if (waiting == self.spinning) return;
    self.spinning = waiting;
    if (waiting) {
        _ = win32.SetTimer(self.hwnd, spinner_timer_id, spinner_ms, null);
    } else {
        _ = win32.KillTimer(self.hwnd, spinner_timer_id);
    }
}

/// The chrome's view of the window's state.
fn view(self: *Window) Chrome.View {
    // `spawnSession` and `reserveGroups` keep room for every session and
    // group.
    self.view_sessions.clearRetainingCapacity();
    self.view_groups.clearRetainingCapacity();
    // Local is always listed, for its button, then every host.
    self.view_groups.appendAssumeCapacity(.{ .label = std.unicode.utf8ToUtf16LeStringLiteral("Local"), .sessions = 0, .kind = .local });
    for (self.hosts.items.items, 0..) |dest, h| {
        self.view_groups.appendAssumeCapacity(.{
            .label = SshConnection.labelFor(dest),
            .sessions = 0,
            .kind = if (self.hostConnection(h) != null) .connected else .disconnected,
        });
    }
    for (self.sessions.items) |s| {
        self.view_groups.items[self.groupOf(s)].sessions += 1;
        self.view_sessions.appendAssumeCapacity(.{ .title = s.title(), .activity = s.activity });
    }
    const bg = self.activeSession().cells.default_bg;
    return .{
        .groups = self.view_groups.items,
        .sessions = self.view_sessions.items,
        .connect = if (self.connect_field) |*f| f else null,
        .caret_visible = self.blink_visible,
        .dialog = if (self.activeSession().login) |l| &l.dialog else null,
        .spinner = self.spinner_step,
        .active = self.active,
        .focused = self.focused,
        .maximized = win32.IsZoomed(self.hwnd.?) != 0,
        .terminal_bg = Painter.rgb(@as(u24, bg.r) << 16 | @as(u24, bg.g) << 8 | bg.b),
        .stats = self.stats_text[0..self.stats_len],
        .new_session_key = new_session_key.slice(),
        .close_session_key = close_session_key.slice(),
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

/// Track what the mouse is over, and time the tooltip of a button it
/// moves onto.
fn setHover(self: *Window, hit: Chrome.Hit) void {
    const had_tip = self.chrome.tip != .none;
    if (!self.chrome.setHover(hit)) return;
    self.dirty = true;
    _ = win32.KillTimer(self.hwnd, tip_timer_id);
    const now = win32.GetTickCount64();
    if (had_tip) self.tip_warm_until = now + tip_warm_ms;
    if (!Chrome.hasTip(self.chrome.hover)) return;
    if (now < self.tip_warm_until) {
        _ = self.chrome.showTip();
        return;
    }
    var ms: u32 = 400;
    _ = win32.SystemParametersInfoW(win32.SPI_GETMOUSEHOVERTIME, 0, &ms, 0);
    _ = win32.SetTimer(self.hwnd, tip_timer_id, ms, null);
}

fn hideTip(self: *Window) void {
    _ = win32.KillTimer(self.hwnd, tip_timer_id);
    if (self.chrome.hideTip()) self.dirty = true;
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
    if (press) self.hideTip();
    // Clicking anywhere else closes the host field.
    if (press and hit != .connect) self.cancelConnect();
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
        .new_session => |g| self.newSessionIn(g),
        .forget_host => |g| self.forgetHost(g),
        .connect => self.startConnect(),
        .dialog_button => |i| {
            const d = &(self.activeSession().login orelse return).dialog;
            var buf: [Chrome.Dialog.max_buttons]Chrome.Dialog.Button = undefined;
            const buttons = d.buttons(&buf);
            if (i < buttons.len and !buttons[i].disabled) self.loginAction(buttons[i].action);
        },
        .dialog_field => |i| {
            const d = &(self.activeSession().login orelse return).dialog;
            d.focus = .{ .field = i };
            self.resetBlink();
            self.dirty = true;
        },
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
        // The host field or a login dialog has the keyboard while open.
        .focused = self.focused and self.connect_field == null and s.login == null,
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
        .color_atlas = &self.grid.color_atlas,
        .lcd_atlas = &self.grid.lcd_atlas,
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
    if (self.slimed) |conn| conn.resizeWorkspace(self.slimedArea());

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
                spinner_timer_id => {
                    self.spinner_step +%= 1;
                    self.dirty = true;
                },
                tip_timer_id => {
                    _ = win32.KillTimer(hwnd, tip_timer_id);
                    if (self.chrome.showTip()) self.dirty = true;
                },
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
            const i = self.sessionIndex(@intCast(wparam)) orelse return 0;
            const s = self.sessions.items[i];
            // So does a slimed session lost to us while it runs.
            if (s.slimedLoss()) |loss| {
                if (!s.ended) s.showEnded(loss.text());
                self.dirty = true;
                return 0;
            }
            // A failed SSH channel (login, connection, or open) stays to
            // say why. A shell that exited closes like a local one.
            if (s.sshEnding()) |ending| if (!ending.exited) {
                if (s.login) |login| {
                    // Cancelling closed the dialog already, so this is
                    // the server's doing.
                    login.fail(ending.text());
                    self.updateSpinner();
                }
                s.showEnded(ending.text());
                self.dirty = true;
                return 0;
            };
            self.closeSession(i);
            return 0;
        },

        WM_APP_SSH_LOGIN => {
            self.loginChanged(@intCast(wparam));
            return 0;
        },

        WM_APP_SLIMED => {
            self.adoptArrivals();
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
            if (msg == win32.WM_KEYDOWN or msg == win32.WM_SYSKEYDOWN) self.hideTip();
            if (self.connect_field != null or self.activeLogin() != null) {
                if (msg == win32.WM_KEYDOWN and (self.connectKey(@truncate(wparam)) or self.loginKey(@truncate(wparam)))) return 0;
                if (self.keyBinding(msg, wparam)) return 0;
                // Keep alt+F4; the session gets nothing.
                if (msg == win32.WM_SYSKEYDOWN and wparam == win32.VK_F4) return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                return 0;
            }
            if (self.keyBinding(msg, wparam)) return 0;
            if (self.activeSession().ended) {
                if ((msg == win32.WM_KEYDOWN or msg == win32.WM_SYSKEYDOWN) and !input.isModifier(wparam, lparam)) {
                    // Drop the key's text, which would otherwise go to
                    // the session shown next.
                    var m: win32.MSG = undefined;
                    while (win32.PeekMessageW(&m, self.hwnd, win32.WM_CHAR, win32.WM_DEADCHAR, win32.PM_REMOVE) != 0) {}
                    self.closeSession(self.active);
                }
                return 0;
            }
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
            const field: ?*Chrome.TextField = if (self.connect_field) |*f| f else if (self.activeLogin()) |l| l.dialog.focused() else null;
            if (field != null or self.activeLogin() != null) {
                if (msg == win32.WM_CHAR) if (field) |f| {
                    f.insert(&.{@truncate(wparam)});
                    self.resetBlink();
                    self.dirty = true;
                };
                return 0;
            }
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
            const hit = self.hitAt(pos);
            if (hit == .dialog_field) cursor = win32.IDC_IBEAM;
            if (self.mouse_in_terminal or hit == .terminal) {
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
