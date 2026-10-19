//! The window's state and what changes it, apart from Win32 and Direct3D:
//! the tabs and their sessions, slime's workspaces and hosts as it last
//! described them, which pane has the keys and what else might (`Mode`),
//! and the mouse's drags. The window turns its messages into a `Msg` and
//! hands each to `update`; what the UI draws is `view`, a tree of widgets
//! built each frame. Whatever still has to reach Win32 (the mouse capture,
//! timers, the clipboard, the window text) goes through `Shell`, which
//! the window implements, so this runs without one in tests.
const App = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const ghostty_vt = @import("ghostty-vt");
const win32 = @import("win32/win32.zig");
const input = @import("input.zig");
const binding = @import("binding.zig");
const Config = @import("Config.zig");
const Session = @import("Session.zig");
const Tab = @import("Tab.zig");
const Daemon = @import("Daemon.zig");
const Hosts = @import("Hosts.zig");
const Shown = @import("Shown.zig");
const Login = @import("Login.zig");
const messages = @import("messages.zig");
const Placement = @import("Placement.zig");
const Ui = @import("ui/Ui.zig");
const view_ = @import("view.zig");

pub const Id = Ui.Id;
const Rect = Ui.Rect;
const TextField = Ui.TextField;
const Dialog = Ui.Dialog;
const Menu = Ui.Menu;
const Tree = Ui.Tree;

const log = std.log.scoped(.app);

const L = std.unicode.utf8ToUtf16LeStringLiteral;
const app_name = L("slime");

const spinner_ms = 100;
/// How long after a tooltip hides the next shows without waiting.
const tip_warm_ms = 1000;

/// How long after a resize output from a background session isn't
/// activity: ConPTY redraws on every resize.
const resize_quiet_ms = 500;

alloc: Allocator,
/// Outlives the app.
config: *const Config,
/// What local sessions run, in CreateProcessW syntax. Outlives the app.
local_command: []const u16,
/// The SSH hosts the sidebar lists. Outlives the app.
hosts: *Hosts,
/// The workspaces the last window showed, for this one to show, and
/// this one's for the next. Outlives the app.
shown: *Shown,
/// The window's UI, whose mouse state (hover, pressed, tooltip) the app
/// drives, and whose frame (the window's regions) the tree is built for.
/// The window owns both and keeps the frame current.
ui: *Ui,
frame: *const Ui.Frame,
shell: Shell,
/// What sessions' readers wake the window with, and where daemon
/// connections post: both the window's handle (`Options.hwnd`).
wake: Session.Wake,
notify: Daemon.Notify,
/// Where the terminal area is and what fits in it, from the window's
/// last `layout`.
geometry: Geometry = .{},

/// Grouped as the sidebar shows them: each shown workspace's tabs in
/// the workspaces' order, then each host's together. Empty while no
/// workspace is shown (the terminal area says so); the window closes
/// when nothing is left to show.
tabs: std.ArrayList(*Tab) = .empty,
/// The tab shown, while there are any. Its focused pane gets input.
active: usize = 0,
next_session_id: u32 = 1,
/// The next `Tab.key`.
next_tab_key: u32 = 1,
/// The tree `view` last built, which the mouse is hit-tested against
/// while it still shows what's there (`tree_stale`), and the arena it's
/// built in, emptied for each.
tree: ?Tree = null,
arena: std.heap.ArenaAllocator,
/// How many trees `view` has built, for tests.
views: u32 = 0,
/// Where the active tab's panes are. Derived: read it through `placed`,
/// which places them anew once it's stale, which every change to what's
/// drawn (`markDirty`) and every tab freed (`destroyTab`) makes it. So
/// it never holds a session that's gone, and nothing that changes the
/// tabs has to place them after.
placement: Placement = .{},
placement_stale: bool = true,

/// Something changed since the last frame. UI thread only. Set through
/// `markDirty`, with the two below.
dirty: bool = false,
/// The last tree no longer shows what's there: `currentTree` builds it
/// again before the mouse is tested against it.
tree_stale: bool = true,

/// The window has keyboard focus.
focused: bool = false,

/// The on phase of the cursor blink.
blink_visible: bool = true,

/// What takes the keyboard from the terminal, if anything.
mode: Mode = .terminal,

/// The connection to slime: local sessions are panes of the workspaces
/// it holds, those shown here. Null if it couldn't be reached.
daemon: ?*Daemon = null,
/// slime's workspaces, as it lists them, in its order. The shown ones
/// are attached on `daemon`, their tabs in `tabs`; the rest are a header
/// each in the sidebar.
workspaces: std.ArrayList(Workspace) = .empty,
/// A workspace just asked for here (shown from the sidebar, or made):
/// its active tab is shown when its tabs come. `activate_new` is for one
/// whose id isn't known yet.
activate_ws: ?u32 = null,
activate_new: bool = false,
/// Connections to slime on SSH hosts, bridged through the local daemon:
/// a host's sessions are panes of the workspace its slime holds for
/// this window.
remotes: std.ArrayList(Remote) = .empty,
/// The hosts the local daemon knows, by its id for each, as it last
/// reported them (`hostsChanged`). Matched to the remembered list by
/// destination. Entries stay while the app lives: logins borrow their
/// labels.
host_states: std.ArrayList(HostEntry) = .empty,

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
/// A divider being dragged, which has the mouse until the button's up.
drag: ?Drag = null,
/// A pane pressed on its title strip, which drags it once the mouse moves
/// far enough, until the button's up.
pane_drag: ?PaneDrag = null,
/// The sidebar's edge being dragged, which has the mouse until the
/// button's up.
sidebar_drag: ?SidebarDrag = null,
/// The tab a middle click went down on, to close it on release.
middle_pressed: ?Id.Target = null,

/// Output from background sessions before this tick count isn't
/// activity. See `resize_quiet_ms`.
quiet_until: u64 = 0,

/// What takes the keyboard from the focused pane's terminal: one of
/// these at a time, or none. The active session's login dialog takes it
/// too, but lives on the session (`keyboard`).
pub const Mode = union(enum) {
    terminal,
    /// The host being typed after "Connect" was clicked.
    connect: TextField,
    /// A workspace's name being edited in its row.
    rename: Rename,
    /// Asking before killing a workspace, over the terminal area.
    confirm: Confirm,
    /// A context menu, over everything, until it's chosen from or
    /// dismissed.
    menu: Menu,
};

/// A workspace's name being edited.
pub const Rename = struct {
    ws: u32,
    field: TextField,
};

/// Asking whether to kill a workspace. The dialog's strings point into
/// the buffers, so it stays where it is.
pub const Confirm = struct {
    ws: u32,
    dialog: Dialog,
    title: [TextField.max_len + 32]u16 = undefined,
    text: [96]u16 = undefined,
};

/// What has the keyboard: the focused pane's terminal (or nothing, with
/// no tabs), or the field or dialog that took it. The one answer to that
/// question, for keys, text, the caret, and the cursor's blink.
pub const Keyboard = union(enum) {
    terminal,
    connect: *TextField,
    rename: *TextField,
    confirm: *Dialog,
    menu: *Menu,
    login: *Login,

    /// The text field typed into, if one has the keyboard.
    pub fn field(self: Keyboard) ?*TextField {
        return switch (self) {
            .connect, .rename => |f| f,
            .login => |l| l.dialog.focused(),
            .terminal, .confirm, .menu => null,
        };
    }
};

const Drag = struct {
    tab: *Tab,
    /// As `Tab.place` made it when the button went down; the tree it
    /// points into doesn't change while dragging (see `cancelDrag`).
    divider: Tab.Divider,
    /// The children's shares then, and the mouse's position across the
    /// divider.
    from: [2]u16,
    origin: i32,
};

const PaneDrag = struct {
    tab: *Tab,
    source: *Session,
    /// Where the button went down.
    start: win32.POINT,
    /// The mouse, once it's moved past the system's drag distance.
    at: ?win32.POINT = null,
    drop: ?Drop = null,
};

/// Where a dragged pane would land, and its highlight.
const Drop = struct {
    place: Tab.Place,
    rect: Rect,
};

const SidebarDrag = struct {
    /// The sidebar's width (DIPs) and the mouse's x when the button went
    /// down.
    from: f32,
    origin: i32,
};

/// The least the terminal area keeps, in DIPs, when the sidebar's edge
/// is dragged toward it.
const min_terminal_width = 200;

/// A host's slime, bridged through the local daemon. A session stands in
/// for its panes until they come (`standIn`).
const Remote = struct {
    conn: *Daemon,
    /// The daemon's id for the host.
    host: u32,
    /// The host's workspaces whose structures have come, with the tab
    /// each shows as active, as `Workspace.active_tab` keeps it for the
    /// local ones. There's no list of a host's workspaces beyond this.
    workspaces: std.ArrayList(RemoteWorkspace) = .empty,
};

const RemoteWorkspace = struct {
    id: u32,
    active_tab: Daemon.TabRef = .none,
};

/// A workspace of the local daemon, as it last described it.
pub const Workspace = struct {
    id: u32,
    /// Owned.
    name: []u16,
    /// Tabs the daemon has in it, shown here or not.
    tabs: usize,
    /// Connections viewing it, this one included.
    viewers: usize,
    /// Attached on `daemon`: its tabs are in `tabs`, or about to be.
    shown: bool,
    /// The tab the daemon shows as active while it's shown, as its
    /// structure last said or we last told it (`syncFocus`).
    active_tab: Daemon.TabRef = .none,
};

/// A host as the local daemon knows it.
const HostEntry = struct {
    id: u32,
    /// As the sidebar remembers it. Owned.
    dest: []const u16,
    state: Daemon.HostStatus,
    /// A status line while connecting, or why it ended. Owned.
    text: []const u16,
    /// This window asked the daemon to connect it, so its prompts come
    /// here.
    ours: bool = false,
};

/// What the window tells the app happened. Mouse and key messages carry
/// their Win32 message and parameters as they came, since the sessions
/// take them that way; positions are client coordinates.
pub const Msg = union(enum) {
    /// The mouse moved, or a button went down or up, in the client area.
    mouse: Mouse,
    /// A wheel turned, at a client position.
    wheel: Mouse,
    /// The mouse left the client area.
    mouse_leave,
    /// Something else took the mouse capture.
    capture_lost,
    /// The mouse over, pressing, or releasing a caption button (the
    /// non-client messages); `hit` is `.none` elsewhere in the frame.
    caption: struct { hit: Id, event: enum { hover, down, up } },
    /// The mouse left the frame.
    caption_leave,
    /// A widget was activated: a click went down and up on it.
    click: Id,
    /// A key went down or up: WM_(SYS)KEYDOWN or WM_(SYS)KEYUP.
    key: Key,
    /// A UTF-16 unit of text, from WM_CHAR, or WM_SYSCHAR if `sys`.
    char: struct { unit: u16, sys: bool },
    /// The window got or lost the keyboard.
    focus: bool,
    /// One of the app's timers fired.
    tick: Timer,
    /// A session's reader handed it a frame or a status.
    output,
    /// A daemon connection posted: panes arrived, or hosts and
    /// workspaces changed.
    daemon_posted,
    /// A session's reader posted about session `id`.
    session: struct { id: u32, what: enum { exited, title, clipboard } },
    /// A right click came up at a client position: what's there may
    /// open its context menu.
    context_menu: win32.POINT,

    pub const Mouse = struct { msg: u32, wparam: win32.WPARAM, pos: win32.POINT };
    pub const Key = struct { msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM };
};

/// The timers the app runs through the shell.
pub const Timer = enum {
    /// Blinks the cursor while the window has focus.
    blink,
    /// Steps a login dialog's spinner while it waits, and the sidebar's
    /// while a program works.
    spinner,
    /// Shows a tooltip once the mouse rests on a button.
    tip,
};

/// What the window does with a message after `update`: nothing more, or
/// what Windows would have (DefWindowProc), for alt+F4.
pub const Result = enum { handled, default };

/// What the mouse cursor should be at a point.
pub const Cursor = union(enum) {
    arrow,
    ibeam,
    size_we,
    size_ns,
    size_all,
    /// A pane's, as its program set it (OSC 22).
    shape: ghostty_vt.MouseShape,
};

/// What the app asks of the window: every Win32 call it still needs.
/// The window implements it; tests fake it.
pub const Shell = struct {
    ctx: *anyopaque,
    vt: *const VTable,

    pub const VTable = struct {
        captureMouse: *const fn (*anyopaque) void,
        releaseMouse: *const fn (*anyopaque) void,
        setTimer: *const fn (*anyopaque, Timer, u32) void,
        killTimer: *const fn (*anyopaque, Timer) void,
        /// Close the window, once the message is handled.
        postClose: *const fn (*anyopaque) void,
        /// The window text, which the taskbar shows.
        setTitle: *const fn (*anyopaque, [:0]const u16) void,
        /// A caption button was clicked: minimize, maximize, close.
        caption: *const fn (*anyopaque, Id.Part) void,
        maximized: *const fn (*anyopaque) bool,
        /// Milliseconds since the system started.
        tickCount: *const fn (*anyopaque) u64,
        /// Whether a virtual key is down.
        keyDown: *const fn (*anyopaque, i32) bool,
        /// The modifiers held now.
        mods: *const fn (*anyopaque) input.Mods,
        /// How far the mouse moves with a button down before it's a drag.
        dragThreshold: *const fn (*anyopaque) [2]i32,
        /// How long the mouse rests before a tooltip, in milliseconds.
        hoverTime: *const fn (*anyopaque) u32,
        /// The caret's blink period, or null when blinking is off.
        caretBlinkTime: *const fn (*anyopaque) ?u32,
        /// Drop the WM_CHAR messages posted for the key being handled.
        dropPendingChars: *const fn (*anyopaque) void,
        clipboardHasText: *const fn (*anyopaque) bool,
        clipboardGet: *const fn (*anyopaque, Allocator) anyerror!?[]u8,
        clipboardSet: *const fn (*anyopaque, []const u8) anyerror!void,
        /// The least time between a pane's frames to ask slime for, in
        /// microseconds.
        frameInterval: *const fn (*anyopaque) u32,
        /// The font size in points, and changing it, which lays the
        /// window out again.
        fontSize: *const fn (*anyopaque) f32,
        setFontSize: *const fn (*anyopaque, f32) void,
        /// Lay the window out again: the UI's frame changed.
        relayout: *const fn (*anyopaque) void,
        /// The frame stats the sidebar shows, if built with them.
        stats: *const fn (*anyopaque) []const u16,
    };

    fn captureMouse(self: Shell) void {
        self.vt.captureMouse(self.ctx);
    }
    fn releaseMouse(self: Shell) void {
        self.vt.releaseMouse(self.ctx);
    }
    fn setTimer(self: Shell, timer: Timer, ms: u32) void {
        self.vt.setTimer(self.ctx, timer, ms);
    }
    fn killTimer(self: Shell, timer: Timer) void {
        self.vt.killTimer(self.ctx, timer);
    }
    fn postClose(self: Shell) void {
        self.vt.postClose(self.ctx);
    }
    fn setTitle(self: Shell, title: [:0]const u16) void {
        self.vt.setTitle(self.ctx, title);
    }
    fn caption(self: Shell, part: Id.Part) void {
        self.vt.caption(self.ctx, part);
    }
    pub fn maximized(self: Shell) bool {
        return self.vt.maximized(self.ctx);
    }
    fn tickCount(self: Shell) u64 {
        return self.vt.tickCount(self.ctx);
    }
    fn keyDown(self: Shell, vk: i32) bool {
        return self.vt.keyDown(self.ctx, vk);
    }
    fn mods(self: Shell) input.Mods {
        return self.vt.mods(self.ctx);
    }
    fn dragThreshold(self: Shell) [2]i32 {
        return self.vt.dragThreshold(self.ctx);
    }
    fn hoverTime(self: Shell) u32 {
        return self.vt.hoverTime(self.ctx);
    }
    fn caretBlinkTime(self: Shell) ?u32 {
        return self.vt.caretBlinkTime(self.ctx);
    }
    fn dropPendingChars(self: Shell) void {
        self.vt.dropPendingChars(self.ctx);
    }
    fn clipboardHasText(self: Shell) bool {
        return self.vt.clipboardHasText(self.ctx);
    }
    fn clipboardGet(self: Shell, alloc: Allocator) anyerror!?[]u8 {
        return self.vt.clipboardGet(self.ctx, alloc);
    }
    fn clipboardSet(self: Shell, text: []const u8) anyerror!void {
        return self.vt.clipboardSet(self.ctx, text);
    }
    fn frameInterval(self: Shell) u32 {
        return self.vt.frameInterval(self.ctx);
    }
    fn fontSize(self: Shell) f32 {
        return self.vt.fontSize(self.ctx);
    }
    fn setFontSize(self: Shell, size_pt: f32) void {
        self.vt.setFontSize(self.ctx, size_pt);
    }
    fn relayout(self: Shell) void {
        self.vt.relayout(self.ctx);
    }
    pub fn stats(self: Shell) []const u16 {
        return self.vt.stats(self.ctx);
    }
};

/// Where the terminal area is and what fits in it, which the window
/// works out from the UI's frame, its font grid, and DPI.
pub const Geometry = struct {
    /// The terminal area, in pixels.
    terminal: struct { width: u32 = 0, height: u32 = 0 } = .{},
    /// The part of it a tab's panes tile, and the gap between them.
    pane_area: Rect = .{},
    gap: f32 = 0,
    /// A pane's title strip, above its terminal.
    title_height: f32 = 0,
    /// Space inside the terminal area, before the grid, at its left and
    /// top, which border the chrome. Already in `padding`.
    inset: u32 = 0,
    /// The space around the grid in a pane: the configured padding at the
    /// current DPI, plus the chrome's inset on every side.
    padding: Placement.Padding = .{},
    cell: Session.CellSize = .{ .width = 1, .height = 1 },
};

const GridSize = struct { cols: u16, rows: u16 };

pub const Options = struct {
    alloc: Allocator,
    config: *const Config,
    local_command: []const u16,
    hosts: *Hosts,
    shown: *Shown,
    ui: *Ui,
    frame: *const Ui.Frame,
    shell: Shell,
    /// The window, which other threads post to (`messages`), and the
    /// event sessions' readers set when output comes.
    hwnd: win32.HWND,
    output_event: win32.HANDLE,
    /// Counts the bytes sessions receive, when built with `-Dstats`.
    stats_bytes: ?*std.atomic.Value(u64) = null,
};

pub fn init(opts: Options) !App {
    return .{
        .alloc = opts.alloc,
        .config = opts.config,
        .local_command = opts.local_command,
        .hosts = opts.hosts,
        .shown = opts.shown,
        .ui = opts.ui,
        .frame = opts.frame,
        .shell = opts.shell,
        .wake = .{
            .hwnd = opts.hwnd,
            .output_event = opts.output_event,
            .bytes = opts.stats_bytes,
            .clipboard_write = opts.config.@"clipboard-write",
        },
        .notify = .{ .hwnd = opts.hwnd, .msg = messages.WM_APP_DAEMON },
        .arena = .init(opts.alloc),
    };
}

/// Connect to slime and show the workspaces the last window did (or
/// what slime has, or a new one running `command_line`, CreateProcessW
/// syntax). An `ssh://` URL opens that host too, and is remembered in
/// `hosts`. After `layout`, so the panes get their sizes.
pub fn start(self: *App, command_line: []const u16) !void {
    // Hosts are reached through the local daemon too, so a host URL still
    // shows the local workspaces, and opens the host beside them.
    const ssh_scheme = std.unicode.utf8ToUtf16LeStringLiteral("ssh://");
    const on_host = std.mem.startsWith(u16, command_line, ssh_scheme);
    try self.connectDaemon(if (on_host) self.local_command else command_line);
    errdefer self.destroyTabs();
    if (self.daemon) |conn| conn.hostList();
    if (on_host) try self.openOnHost(try self.hosts.add(command_line));
    self.showTitle();
}

/// Free everything. The tabs may already be gone (`destroyTabs`), which
/// the window does while its renderer is still up.
pub fn deinit(self: *App) void {
    self.destroyTabs();
    // Hanging up detaches the workspaces; slime keeps them for the next
    // window.
    if (self.daemon) |conn| conn.deinit();
    for (self.workspaces.items) |w| self.alloc.free(w.name);
    self.workspaces.deinit(self.alloc);
    for (self.remotes.items) |*r| self.freeRemote(r);
    self.remotes.deinit(self.alloc);
    for (self.host_states.items) |e| {
        self.alloc.free(e.dest);
        self.alloc.free(e.text);
    }
    self.host_states.deinit(self.alloc);
    self.arena.deinit();
    self.placement.deinit(self.alloc);
    self.* = undefined;
}

/// Free every tab and its sessions, which hold GPU resources: before the
/// renderer goes.
pub fn destroyTabs(self: *App) void {
    for (self.tabs.items) |t| self.destroyTab(t);
    self.tabs.clearAndFree(self.alloc);
    self.active = 0;
}

/// Free a tab and its sessions, which only lets go of daemon panes.
fn destroyTab(self: *App, t: *Tab) void {
    // Its panes may be placed.
    self.placement_stale = true;
    var it = t.iterator();
    while (it.next()) |s| s.destroy();
    t.destroy(self.alloc);
}

/// Something changed that the next frame shows: the tree and the
/// placement are built again before they're read.
pub fn markDirty(self: *App) void {
    self.dirty = true;
    self.tree_stale = true;
    self.placement_stale = true;
}

/// Act on what the window said happened.
pub fn update(self: *App, msg: Msg) Result {
    switch (msg) {
        .mouse => |m| self.mouseInput(m),
        .wheel => |m| self.wheelInput(m),
        .mouse_leave => _ = self.setHover(.none),
        .capture_lost => self.captureLost(),
        .caption => |c| switch (c.event) {
            .hover => _ = self.setHover(c.hit),
            .down => self.setPressed(c.hit),
            .up => {
                const pressed = self.ui.pressed;
                self.setPressed(.none);
                if (c.hit.target != .none and pressed.eql(c.hit)) self.shell.caption(c.hit.part);
            },
        },
        .caption_leave => {
            if (isCaptionButton(self.ui.hover)) _ = self.setHover(.none);
            if (isCaptionButton(self.ui.pressed)) self.setPressed(.none);
        },
        .click => |hit| self.widgetClick(hit),
        .key => |k| return self.keyInput(k),
        .char => |c| self.charInput(c.unit, c.sys),
        .focus => |focused| self.setFocus(focused),
        .tick => |timer| switch (timer) {
            .blink => self.blinkTick(),
            .spinner => {
                self.spinner_step +%= 1;
                self.markDirty();
            },
            .tip => {
                self.shell.killTimer(.tip);
                if (self.ui.showTip(self.currentTree())) self.markDirty();
            },
        },
        .output => self.outputArrived(),
        .daemon_posted => self.daemonPosted(),
        .session => |s| self.sessionEvent(s.id, s.what),
        .context_menu => |pos| self.contextMenu(pos),
    }
    return .handled;
}

/// Whether `hit` is one of the caption buttons.
fn isCaptionButton(hit: Id) bool {
    return hit.target == .window and switch (hit.part) {
        .minimize, .maximize, .close => true,
        else => false,
    };
}

/// A session's reader posted about session `id`.
fn sessionEvent(self: *App, id: u32, what: @FieldType(@FieldType(Msg, "session"), "what")) void {
    const found = self.findSession(id) orelse return;
    const s = found.s;
    switch (what) {
        .exited => {
            // A daemon pane lost to us while it runs stays to say why.
            if (s.daemonLoss()) |loss| {
                if (!s.ended) s.showEnded(loss.text());
                self.markDirty();
                return;
            }
            self.closePane(found.tab, s);
        },
        .title => {
            s.titleUpdate();
            if (s == self.activeSession()) self.showTitle();
            self.markDirty();
        },
        .clipboard => s.clipboardWriteFlush(),
    }
}

/// Losing the capture mid-drag (alt+tab, a modal window) ends it.
fn captureLost(self: *App) void {
    if (self.drag != null) self.endDrag();
    if (self.sidebar_drag != null) self.endSidebarDrag();
    // A pane drag that lost the mouse lands nowhere.
    self.cancelDrag();
    if (self.mouse_in_terminal) {
        self.mouse_in_terminal = false;
        if (self.focusedSession()) |s| s.cancelSelection();
    }
    self.setPressed(.none);
}

/// The tab shown. Only while there are tabs (`hasTabs`).
pub fn activeTab(self: *const App) *Tab {
    return self.tabs.items[self.active];
}

/// The active tab's focused pane, which gets input. Only while there
/// are tabs.
pub fn activeSession(self: *const App) *Session {
    return self.activeTab().focus;
}

/// Whether anything is shown in the terminal area. Without tabs, the
/// chrome alone takes input.
pub fn hasTabs(self: *const App) bool {
    return self.tabs.items.len > 0;
}

/// The active tab's focused pane, if there is one. Safe while `active`
/// points past the tabs, which it can between a change to them and the
/// fix-up after (a capture released there comes straight back here).
pub fn focusedSession(self: *const App) ?*Session {
    return if (self.active < self.tabs.items.len) self.activeSession() else null;
}

const Found = struct { tab: usize, s: *Session };

/// The session `id` names, and its tab.
fn findSession(self: *const App, id: u32) ?Found {
    for (self.tabs.items, 0..) |t, i| {
        if (t.findSession(id)) |s| return .{ .tab = i, .s = s };
    }
    return null;
}

/// The session showing `conn`'s pane `id`.
fn daemonSession(self: *const App, conn: *Daemon, id: Daemon.PaneRef) ?*Session {
    for (self.tabs.items) |t| {
        if (t.conn != conn) continue;
        if (t.findPane(id)) |s| return s;
    }
    return null;
}

fn tabIndex(self: *const App, t: *const Tab) ?usize {
    return std.mem.indexOfScalar(*Tab, self.tabs.items, @constCast(t));
}

/// The place of the tab `target` names, if it's listed.
fn tabIndexOf(self: *const App, target: Id.Target) ?usize {
    const key = switch (target) {
        .tab => |k| k,
        else => return null,
    };
    for (self.tabs.items, 0..) |t, i| {
        if (t.key == key) return i;
    }
    return null;
}

/// The workspace `target` names, if it's listed.
fn workspaceOf(self: *App, target: Id.Target) ?*Workspace {
    return switch (target) {
        .workspace => |id| self.workspaceEntry(id),
        else => null,
    };
}

/// The session `target` names, and its tab.
fn sessionOf(self: *const App, target: Id.Target) ?Found {
    return switch (target) {
        .pane => |id| self.findSession(id),
        else => null,
    };
}

/// A `Tab.key` no tab has had.
fn nextTabKey(self: *App) u32 {
    if (self.next_tab_key == 0) self.next_tab_key = 1;
    const key = self.next_tab_key;
    self.next_tab_key +%= 1;
    return key;
}

/// What a new session shows.
const Target = union(enum) {
    /// A pane of a workspace slime holds for us.
    daemon: struct { conn: *Daemon, arrival: *const Daemon.Arrival },
    /// Nothing yet, on a host (its destination as the sidebar remembers
    /// it): standing in for its slime's panes until they come.
    waiting: []const u16,
    /// Why nothing can run, titled `title`.
    failed: struct { title: []const u16, why: []const u8 },
};

/// Connect to slime and show the workspaces the last window did (else
/// what slime has, else a new one running `command`), making a tab of
/// each of their tabs. If that fails, a tab says why.
fn connectDaemon(self: *App, command: []const u16) !void {
    const conn = Daemon.connect(self.alloc, self.notify, self.shell.frameInterval(), self.daemonArea(), self.daemonSize(), command, self.shown.wanted()) catch |err| {
        log.err("connecting to slime failed: {}", .{err});
        return self.spawnFailed("couldn't start slime", err);
    };
    self.daemon = conn;
    self.workspacesChanged(conn);
    self.daemonChanged(conn);
    conn.start() catch |err| {
        log.err("starting slime's reader failed: {}", .{err});
        self.destroyTabs();
        conn.deinit();
        self.daemon = null;
        return self.spawnFailed("couldn't read from slime", err);
    };
    if (self.tabs.items.len == 0) return self.spawnFailed("slime showed nothing", error.NoPanes);
}

/// A local tab saying why nothing could run in it: `what`, failing with
/// `err`.
fn spawnFailed(self: *App, what: []const u8, err: anyerror) !void {
    var buf: [256]u8 = undefined;
    const why = std.fmt.bufPrint(&buf, "{s}: {t}", .{ what, err }) catch what;
    try self.spawnSession(.{ .failed = .{ .title = app_name, .why = why } });
}

/// Take up what `conn` sent: make sessions of the panes that arrived,
/// and lay out tabs as their workspaces have them, focused as slime
/// says: a pane we asked for (a new tab or split) is shown and focused;
/// a script's is added without taking focus.
fn daemonChanged(self: *App, conn: *Daemon) void {
    var taken = conn.take();
    defer taken.deinit(self.alloc);

    var arrived: std.AutoHashMapUnmanaged(Daemon.PaneRef, *Session) = .empty;
    defer arrived.deinit(self.alloc);
    for (taken.arrivals) |*a| {
        const s = self.createSession(.{ .daemon = .{ .conn = conn, .arrival = a } }, self.gridSize()) catch |err| {
            log.err("showing daemon pane {f} failed: {}", .{ a.pane, err });
            conn.release(a.pane);
            continue;
        };
        arrived.put(self.alloc, a.pane, s) catch {
            s.destroy();
            continue;
        };
    }
    for (taken.structures) |st| {
        var wanted = false;
        if (conn == self.daemon) {
            const was_shown = if (self.workspaceEntry(st.id)) |w| w.shown else false;
            self.workspaceShown(st);
            // One the user just showed or made is what they want to see.
            wanted = self.activate_ws == st.id or (!was_shown and self.activate_new);
        }
        self.applyStructure(conn, st, &arrived) catch |err| log.err("laying out slime's tabs failed: {}", .{err});
        if (!wanted) continue;
        self.activate_ws = null;
        self.activate_new = false;
        for (self.tabs.items, 0..) |t, k| {
            if (t.conn == conn and t.ws == st.id and (t.id.eql(st.active_tab) or st.active_tab.isNone())) {
                self.activate(k);
                break;
            }
        }
    }
    // Panes no tab holds (which slime doesn't send) aren't shown.
    var left = arrived.valueIterator();
    while (left.next()) |s| s.*.destroy();

    self.closeIfNothingLeft();
    self.markDirty();
}

/// Nothing is shown, and nothing is left to show: close the window. A
/// hidden workspace with tabs keeps it open, empty, to show one from
/// the sidebar.
fn closeIfNothingLeft(self: *App) void {
    if (self.hasTabs()) return;
    for (self.workspaces.items) |w| if (w.tabs > 0 or w.shown) return;
    self.shell.postClose();
}

/// Take up what the local daemon said about its workspaces: keep the
/// list as it has it, and let go of the tabs of one it took away.
fn workspacesChanged(self: *App, conn: *Daemon) void {
    const events = conn.takeWorkspaces();
    defer {
        for (events) |*e| e.deinit(self.alloc);
        self.alloc.free(events);
    }
    if (conn != self.daemon) return;
    for (events) |e| switch (e) {
        .list => |list| for (list) |w| self.workspaceInfo(w),
        .created, .changed => |w| self.workspaceInfo(w),
        .viewers => |v| if (self.workspaceEntry(v.id)) |w| {
            w.viewers = v.count;
        },
        .destroyed => |id| self.workspaceGone(id),
        .attach_failed => |id| if (self.workspaceEntry(id)) |w| {
            w.shown = false;
            self.rememberShown();
        },
    };
    _ = self.ui.setHover(.none);
    self.markDirty();
}

/// Record what the daemon said of workspace `w`, adding it to the list
/// if it's new. Whether it's shown here is `workspaceShown`'s to say:
/// one attached at connect has a structure, which says so.
fn workspaceInfo(self: *App, w: Daemon.WorkspaceInfo) void {
    const entry = self.workspaceEntry(w.id) orelse entry: {
        const name = self.alloc.dupe(u16, w.name) catch return;
        self.workspaces.append(self.alloc, .{ .id = w.id, .name = name, .tabs = 0, .viewers = 0, .shown = false }) catch {
            self.alloc.free(name);
            return;
        };
        break :entry &self.workspaces.items[self.workspaces.items.len - 1];
    };
    if (!std.mem.eql(u16, entry.name, w.name)) {
        const name = self.alloc.dupe(u16, w.name) catch return;
        self.alloc.free(entry.name);
        entry.name = name;
    }
    entry.tabs = w.tabs;
    if (w.viewers) |n| entry.viewers = n;
}

/// A structure came for workspace `st`: it's shown here, named and
/// sized as the structure says.
fn workspaceShown(self: *App, st: *const Daemon.Structure) void {
    self.workspaceInfo(.{ .id = st.id, .name = st.name, .tabs = st.tabs.len, .active_tab = st.active_tab, .viewers = null });
    const entry = self.workspaceEntry(st.id) orelse return;
    if (!entry.shown) {
        entry.shown = true;
        self.rememberShown();
    }
}

/// Workspace `id` is gone: so are its tabs here, and its row.
fn workspaceGone(self: *App, id: u32) void {
    self.cancelDrag();
    var i: usize = 0;
    while (i < self.tabs.items.len) {
        const t = self.tabs.items[i];
        if (t.conn == self.daemon and t.ws == id) self.dropTab(i) else i += 1;
    }
    switch (self.mode) {
        .rename => |r| if (r.ws == id) self.cancelRename(),
        .confirm => |c| if (c.ws == id) self.closeConfirm(),
        .menu => |m| if (std.meta.eql(m.target, Id.Target{ .workspace = id })) self.closeMenu(),
        .terminal, .connect => {},
    }
    for (self.workspaces.items, 0..) |w, k| {
        if (w.id != id) continue;
        self.alloc.free(w.name);
        _ = self.workspaces.orderedRemove(k);
        break;
    }
    self.rememberShown();
    self.closeIfNothingLeft();
}

fn workspaceEntry(self: *App, id: u32) ?*Workspace {
    for (self.workspaces.items) |*w| {
        if (w.id == id) return w;
    }
    return null;
}

/// Remember which workspaces are shown, for the next window.
fn rememberShown(self: *App) void {
    const conn = self.daemon orelse return;
    var ids: [64]u32 = undefined;
    var n: usize = 0;
    for (self.workspaces.items) |w| {
        if (!w.shown or n == ids.len) continue;
        ids[n] = w.id;
        n += 1;
    }
    self.shown.set(conn.pid, ids[0..n]);
}

/// Show workspace `id`: attach it, so its tabs come (`daemon_posted`).
fn showWorkspace(self: *App, id: u32) void {
    const conn = self.daemon orelse return;
    const entry = self.workspaceEntry(id) orelse return;
    if (entry.shown or conn.isLost()) return;
    conn.attach(id, self.daemonArea()) catch |err| return log.err("showing workspace {d} failed: {}", .{ id, err });
    entry.shown = true;
    self.activate_ws = id;
    self.rememberShown();
    self.markDirty();
}

/// Hide workspace `id`: let go of its tabs, which slime keeps running.
fn hideWorkspace(self: *App, id: u32) void {
    const conn = self.daemon orelse return;
    const entry = self.workspaceEntry(id) orelse return;
    if (!entry.shown) return;
    self.cancelDrag();
    var i: usize = 0;
    while (i < self.tabs.items.len) {
        const t = self.tabs.items[i];
        if (t.conn == conn and t.ws == id) self.dropTab(i) else i += 1;
    }
    conn.detach(id);
    entry.shown = false;
    // Shown again, its structure says.
    entry.active_tab = .none;
    self.rememberShown();
    _ = self.ui.setHover(.none);
    self.closeIfNothingLeft();
    self.markDirty();
}

/// Make a workspace with a tab running the local command, shown here.
fn newWorkspace(self: *App) void {
    const conn = self.localDaemon() orelse return;
    conn.newWorkspace(&.{}, self.local_command) catch |err| return log.err("new workspace failed: {}", .{err});
    self.activate_new = true;
}

/// Ask before killing workspace `id`, unless it has nothing running.
fn askKillWorkspace(self: *App, id: u32) void {
    const conn = self.daemon orelse return;
    const entry = self.workspaceEntry(id) orelse return;
    if (entry.tabs == 0) return conn.killWorkspace(id);
    self.cancelConnect();
    self.cancelRename();
    self.mode = .{ .confirm = .{ .ws = id, .dialog = undefined } };
    const c = &self.mode.confirm;
    const prefix = std.unicode.utf8ToUtf16LeStringLiteral("Kill workspace \u{201c}");
    const suffix = std.unicode.utf8ToUtf16LeStringLiteral("\u{201d}?");
    const name = entry.name[0..@min(entry.name.len, c.title.len - prefix.len - suffix.len)];
    @memcpy(c.title[0..prefix.len], prefix);
    @memcpy(c.title[prefix.len..][0..name.len], name);
    @memcpy(c.title[prefix.len + name.len ..][0..suffix.len], suffix);
    var utf8: [96]u8 = undefined;
    const text = std.fmt.bufPrint(&utf8, "Its {d} tab{s} and everything running in them will end.", .{ entry.tabs, if (entry.tabs == 1) "" else "s" }) catch "Everything running in it will end.";
    const text_len = std.unicode.utf8ToUtf16Le(&c.text, text) catch 0;
    c.dialog = .{
        .icon = .warning,
        .danger = true,
        .title = c.title[0 .. prefix.len + name.len + suffix.len],
        .text = c.text[0..text_len],
    };
    c.dialog.addButton(.{ .label = std.unicode.utf8ToUtf16LeStringLiteral("Cancel"), .action = .cancel, .style = .primary });
    c.dialog.addButton(.{ .label = std.unicode.utf8ToUtf16LeStringLiteral("Kill"), .action = .accept, .style = .danger });
    c.dialog.focus = .{ .button = 0 };
    _ = self.ui.setHover(.none);
    self.resetBlink();
    self.markDirty();
}

/// Act on the kill dialog's button.
fn confirmAction(self: *App, action: Dialog.Action) void {
    const ws = switch (self.mode) {
        .confirm => |c| c.ws,
        else => return,
    };
    if (action == .accept) if (self.daemon) |conn| conn.killWorkspace(ws);
    self.closeConfirm();
}

fn closeConfirm(self: *App) void {
    if (self.mode != .confirm) return;
    self.mode = .terminal;
    _ = self.ui.setHover(.none);
    self.markDirty();
}

/// Edit workspace `id`'s name in its header.
fn startRename(self: *App, id: u32) void {
    const entry = self.workspaceEntry(id) orelse return;
    self.cancelConnect();
    self.closeConfirm();
    self.mode = .{ .rename = .{ .ws = id, .field = .{} } };
    const field = &self.mode.rename.field;
    field.insert(entry.name);
    field.press(.select_all, false, false);
    _ = self.ui.setHover(.none);
    self.resetBlink();
    self.markDirty();
}

fn cancelRename(self: *App) void {
    if (self.mode != .rename) return;
    self.mode = .terminal;
    self.markDirty();
}

/// Send the name in the field and close it. The name comes back from
/// slime.
fn submitRename(self: *App) void {
    const r = switch (self.mode) {
        .rename => |*r| r,
        else => return,
    };
    const name = std.mem.trim(u16, r.field.text(), &.{ ' ', '\t' });
    if (name.len > 0) if (self.daemon) |conn| {
        conn.renameWorkspace(r.ws, name) catch |err| log.err("renaming workspace {d} failed: {}", .{ r.ws, err });
    };
    self.cancelRename();
}

/// A key down while a workspace's name is being edited. Returns false
/// for keys it doesn't take.
fn renameKey(self: *App, field: *TextField, vk: u32) bool {
    switch (vk) {
        win32.VK_RETURN => self.submitRename(),
        win32.VK_ESCAPE => self.cancelRename(),
        else => if (!self.editKey(field, vk, true)) return false,
    }
    self.keyHandled();
    return true;
}

/// A key down for the kill dialog. Returns false for keys it doesn't
/// take.
fn confirmKey(self: *App, d: *Dialog, vk: u32) bool {
    switch (vk) {
        win32.VK_RETURN => if (d.enterAction()) |action| self.confirmAction(action),
        win32.VK_SPACE => if (d.focusedButton()) |b| self.confirmAction(b.action) else return false,
        win32.VK_ESCAPE => self.confirmAction(.cancel),
        win32.VK_TAB => if (self.shell.keyDown(win32.VK_CONTROL)) return false else d.cycleFocus(!self.shell.keyDown(win32.VK_SHIFT)),
        else => return false,
    }
    self.keyHandled();
    return true;
}

/// Open `target`'s context menu at `anchor`, with the entries for what
/// it is now. Takes the keyboard from a field or dialog.
fn openMenu(self: *App, target: Id.Target, anchor: Menu.Anchor) void {
    var m: Menu = .{ .target = target, .anchor = anchor };
    switch (target) {
        // Local's header makes a workspace, or a tab with no daemon to
        // list workspaces, as its button does.
        .local => if (self.workspaces.items.len == 0)
            m.add(.{ .label = L("New tab"), .icon = .plus, .action = .{ .part = .new_tab } })
        else
            m.add(.{ .label = L("New workspace"), .icon = .plus, .action = .{ .part = .new_tab } }),
        .workspace => |id| {
            const w = self.workspaceEntry(id) orelse return;
            m.add(.{ .label = L("New tab"), .icon = .plus, .action = .{ .part = .new_tab } });
            m.separator();
            if (w.shown)
                m.add(.{ .label = L("Hide"), .icon = .eye_off, .action = .{ .part = .hide } })
            else
                m.add(.{ .label = L("Show"), .icon = .eye, .action = .{ .part = .show } });
            m.add(.{ .label = L("Rename"), .icon = .pencil, .action = .{ .part = .rename } });
            m.separator();
            m.add(.{ .label = L("Kill"), .icon = .trash, .action = .{ .part = .kill }, .danger = true });
        },
        .host => |h| {
            if (h >= self.hosts.items.items.len) return;
            const live = self.hostLive(h);
            m.add(.{ .label = if (live) L("New tab") else L("Connect"), .icon = if (live) .plus else .plug, .action = .{ .part = .new_tab } });
            m.separator();
            m.add(.{ .label = L("Forget host"), .icon = .x, .action = .{ .part = .forget }, .disabled = self.hostHasTabs(h) });
        },
        .tab => {
            if (self.tabIndexOf(target) == null) return;
            m.add(.{ .label = L("Close tab"), .icon = .x, .action = .{ .part = .close }, .danger = true });
        },
        .pane => {
            const found = self.sessionOf(target) orelse return;
            const s = found.s;
            const t = self.tabs.items[found.tab];
            // Only slime's panes split and zoom.
            const in_slime = s.daemonPane() != null;
            m.add(.{ .label = L("Copy"), .icon = .copy, .action = .{ .binding = .copy_to_clipboard }, .disabled = !s.hasSelection() });
            m.add(.{ .label = L("Paste"), .icon = .clipboard, .action = .{ .binding = .paste_from_clipboard }, .disabled = !self.shell.clipboardHasText() });
            m.separator();
            m.add(.{ .label = L("Split right"), .icon = .columns_2, .action = .{ .binding = .{ .new_split = .right } }, .disabled = !in_slime });
            m.add(.{ .label = L("Split down"), .icon = .rows_2, .action = .{ .binding = .{ .new_split = .down } }, .disabled = !in_slime });
            if (t.count() > 1) {
                const zoomed = t.zoom == s;
                m.add(.{ .label = if (zoomed) L("Unzoom") else L("Zoom"), .icon = if (zoomed) .minimize_2 else .maximize_2, .action = .{ .binding = .toggle_split_zoom } });
            }
            m.separator();
            m.add(.{ .label = L("Close pane"), .icon = .x, .action = .{ .binding = .close_surface }, .danger = true });
        },
        else => return,
    }
    self.cancelConnect();
    self.cancelRename();
    self.closeConfirm();
    self.mode = .{ .menu = m };
    self.hideTip();
    _ = self.ui.setHover(.none);
    self.setPressed(.none);
    self.markDirty();
}

fn closeMenu(self: *App) void {
    if (self.mode != .menu) return;
    self.mode = .terminal;
    _ = self.ui.setHover(.none);
    self.setPressed(.none);
    self.markDirty();
}

/// Whether the open menu is still about something that's listed. What
/// it was about can go while it's open: a tab closed by another window,
/// a workspace killed.
fn menuTargetExists(self: *App) bool {
    const target = switch (self.mode) {
        .menu => |m| m.target,
        else => return true,
    };
    return switch (target) {
        .local => true,
        .host => |h| h < self.hosts.items.items.len,
        .workspace => |id| self.workspaceEntry(id) != null,
        .tab => self.tabIndexOf(target) != null,
        .pane => self.sessionOf(target) != null,
        else => false,
    };
}

/// A right click came up at `pos`: open the menu of the row or pane
/// there, in place of any open. A field being edited keeps its click.
fn contextMenu(self: *App, pos: win32.POINT) void {
    self.closeMenu();
    const hit = self.hitAt(pos);
    if (hit.part == .field) return;
    switch (hit.target) {
        .local, .host, .workspace, .tab, .pane => {},
        else => return,
    }
    self.openMenu(hit.target, .{ .point = .{ .x = @floatFromInt(pos.x), .y = @floatFromInt(pos.y) } });
}

/// Open the focused pane's menu under its title strip, for the Menu key.
fn menuForFocused(self: *App) void {
    const s = self.focusedSession() orelse return;
    const p = self.placed().find(s) orelse return;
    const strip: Rect = .{ .x = p.frame.x, .y = p.frame.y, .w = p.frame.w, .h = self.geometry.title_height };
    self.openMenu(.{ .pane = s.id }, .{ .below = strip });
}

/// Act on the open menu's entry `i`: close the menu, then do what the
/// entry says, as a click on the control would, or the key.
fn chooseItem(self: *App, i: usize) void {
    const m = switch (self.mode) {
        .menu => |m| m,
        else => return,
    };
    const e = m.entry(i) orelse return;
    if (e.disabled) return;
    self.closeMenu();
    switch (e.action) {
        .part => |part| self.widgetClick(.{ .target = m.target, .part = part }),
        .binding => |action| {
            // Bindings act on the focused pane: a pane's menu makes it so.
            if (m.target == .pane) self.showPane(m.target);
            _ = self.runAction(action);
        },
    }
}

/// A key down for a context menu. Returns false for keys it doesn't
/// take.
fn menuKey(self: *App, m: *Menu, vk: u32) bool {
    switch (vk) {
        win32.VK_DOWN => m.moveFocus(true),
        win32.VK_UP => m.moveFocus(false),
        win32.VK_HOME => m.focusEnd(true),
        win32.VK_END => m.focusEnd(false),
        win32.VK_RETURN, win32.VK_SPACE => if (m.focus) |i| self.chooseItem(i) else return false,
        win32.VK_ESCAPE => self.closeMenu(),
        else => return false,
    }
    self.keyHandled();
    return true;
}

/// The sidebar group of local workspace `id`, if it's listed.
pub fn workspaceGroup(self: *const App, id: u32) ?usize {
    for (self.workspaces.items, 0..) |w, i| {
        if (w.id == id) return i;
    }
    return null;
}

/// How many places in the sidebar's order come before the hosts': one
/// per workspace, and one for local tabs in none.
pub fn localGroups(self: *const App) usize {
    return self.workspaces.items.len + 1;
}

/// Lay out `conn`'s tabs of workspace `st.id` as `st` has them, in its
/// order: replace the trees of tabs we have, add tabs we don't, and drop
/// tabs and panes it no longer has. Its focus is slime's, shared with
/// every window on the workspace: each tab's focused and zoomed pane,
/// and the tab shown, which is followed when one of the workspace's tabs
/// is the one shown here. Sessions placed from `arrived` are taken out
/// of it.
fn applyStructure(self: *App, conn: *Daemon, st: *const Daemon.Structure, arrived: *std.AutoHashMapUnmanaged(Daemon.PaneRef, *Session)) !void {
    const alloc = self.alloc;
    self.cancelDrag();
    const was_active: ?*Tab = if (self.tabs.items.len > 0) self.activeTab() else null;
    const was_focus: ?*Session = if (was_active) |t| t.focus else null;
    const shown_ws = if (was_active) |t| t.conn == conn and t.ws == st.id else false;

    const Lookup = struct {
        app: *App,
        conn: *Daemon,
        arrived: *std.AutoHashMapUnmanaged(Daemon.PaneRef, *Session),
        pub fn session(l: @This(), id: Daemon.PaneRef) ?*Session {
            return l.arrived.get(id) orelse l.app.daemonSession(l.conn, id);
        }
    };
    const lookup: Lookup = .{ .app = self, .conn = conn, .arrived = arrived };
    const roots = try alloc.alloc(?Tab.Node, st.tabs.len);
    defer alloc.free(roots);
    @memset(roots, null);
    defer for (roots) |r| if (r) |n| Tab.freeNode(alloc, n);
    var used: std.AutoHashMapUnmanaged(*Session, void) = .empty;
    defer used.deinit(alloc);
    for (st.tabs, roots) |lt, *root| {
        root.* = try Tab.fromLayout(alloc, lt.root, lookup);
        const node = root.* orelse continue;
        var walk: Tab = .{ .id = .none, .root = node, .focus = Tab.first(node) };
        var it = walk.iterator();
        while (it.next()) |s| try used.put(alloc, s, {});
    }
    try self.tabs.ensureUnusedCapacity(alloc, st.tabs.len);

    // Panes of ours slime no longer has, freed once no tree holds them.
    var dropped: std.ArrayList(*Session) = .empty;
    defer dropped.deinit(alloc);
    for (self.tabs.items) |t| {
        if (t.conn != conn or t.ws != st.id) continue;
        var it = t.iterator();
        while (it.next()) |s| if (!used.contains(s)) try dropped.append(alloc, s);
    }

    // The workspace's tabs as slime orders them: ours with their new
    // trees, and new ones. Each takes slime's focus, unless a focus call
    // of ours is still out, which it may predate.
    var ordered: std.ArrayList(*Tab) = .empty;
    defer ordered.deinit(alloc);
    try ordered.ensureTotalCapacity(alloc, st.tabs.len);
    for (st.tabs, roots) |lt, *root| {
        const node = root.* orelse continue;
        const t = for (self.tabs.items) |t| {
            if (t.conn != conn or t.ws != st.id or !t.id.eql(lt.id)) continue;
            t.setRoot(alloc, node);
            break t;
        } else try Tab.create(alloc, self.nextTabKey(), conn, st.id, lt.id, node, Tab.first(node));
        root.* = null;
        ordered.appendAssumeCapacity(t);
        if (st.focus_known) {
            if (t.findPane(lt.focus)) |s| t.focus = s;
            t.zoom = if (!lt.zoomed.isNone()) t.findPane(lt.zoomed) else null;
            t.sent_focus = focusOf(t);
        }
    }
    // They go where the workspace's tabs were, else at the end of their
    // group; the tabs slime no longer has go.
    var at: ?usize = null;
    var i: usize = 0;
    while (i < self.tabs.items.len) {
        const t = self.tabs.items[i];
        if (t.conn != conn or t.ws != st.id) {
            i += 1;
            continue;
        }
        if (at == null) at = i;
        _ = self.tabs.orderedRemove(i);
        if (std.mem.indexOfScalar(*Tab, ordered.items, t) == null) t.destroy(alloc);
    }
    if (ordered.items.len > 0) {
        const from = at orelse self.groupEnd(self.groupOf(ordered.items[0]));
        for (ordered.items, 0..) |t, k| self.tabs.insertAssumeCapacity(from + k, t);
    }

    if (was_focus) |f| if (std.mem.indexOfScalar(*Session, dropped.items, f) != null) {
        // First: releasing the capture comes back as `capture_lost`.
        const had_mouse = self.mouse_in_terminal;
        self.mouse_in_terminal = false;
        if (had_mouse) self.shell.releaseMouse();
    };
    // Some may be placed.
    self.placement_stale = true;
    for (dropped.items) |s| s.destroy();
    var kept = used.keyIterator();
    while (kept.next()) |s| if (s.*.daemonPane()) |id| {
        _ = arrived.remove(id);
    };

    _ = self.ui.setHover(.none);
    self.middle_pressed = null;
    for (self.tabs.items) |t| self.layoutTab(t);
    if (st.focus_known) self.setActiveTabIn(conn, st.id, st.active_tab);
    if (self.tabs.items.len == 0) {
        self.active = 0;
        self.showTitle();
        self.updateSpinner();
        return;
    }

    // Where the active tab was, if it's still here; else the one in its
    // place. slime's active tab is followed while this workspace's tabs
    // are what's shown: a tab of another workspace or daemon stays.
    const still: ?usize = if (was_active) |t| self.tabIndex(t) else null;
    var active = still orelse @min(self.active, self.tabs.items.len - 1);
    if (st.focus_known) {
        if (still == null or shown_ws) for (self.tabs.items, 0..) |t, k| {
            if (t.conn == conn and t.ws == st.id and t.id.eql(st.active_tab)) active = k;
        };
    }
    self.active = active;
    const now_focus = self.activeTab().focus;
    if (now_focus == was_focus) return;
    // The pane that lost the focus hears, if it's still here.
    if (was_focus) |f| if (self.focused and still != null and was_active.?.contains(f)) f.reportFocus(false);
    self.activated();
}

/// A tab's focus as `workspace.focus` takes it.
fn focusOf(t: *const Tab) Daemon.Focus {
    return .{
        .tab = t.id,
        .pane = t.focus.daemonPane() orelse .none,
        .zoomed = if (t.zoom) |z| z.daemonPane() orelse .none else .none,
    };
}

/// Tell the active tab's daemon where the focus is, if that's news to
/// it: the tab shown, its focused pane, and its zoom. Every other window
/// on the workspace follows. After anything that moves them.
fn syncFocus(self: *App) void {
    if (self.tabs.items.len == 0) return;
    const t = self.activeTab();
    const conn = t.conn orelse return;
    const f = focusOf(t);
    if (f.pane.isNone()) return;
    if (self.activeTabIn(conn, t.ws).eql(t.id) and t.sent_focus != null and std.meta.eql(t.sent_focus.?, f)) return;
    t.sent_focus = f;
    self.setActiveTabIn(conn, t.ws, t.id);
    conn.focus(f) catch |err| log.warn("telling slime the focus failed: {}", .{err});
}

/// The grid a daemon pane gets: the terminal area, as for any session.
fn daemonSize(self: *const App) Daemon.Size {
    const grid = self.gridSize();
    const cell = self.geometry.cell;
    return .{ .cols = grid.cols, .rows = grid.rows, .cell_width = cell.width, .cell_height = cell.height };
}

/// The pixels a tab's panes share, inside the padding, and the cell size
/// of panes that haven't said their own.
fn daemonArea(self: *const App) Daemon.Area {
    const size = self.geometry.terminal;
    const pad = self.geometry.padding;
    const cell = self.geometry.cell;
    return .{
        .width = size.width -| pad.left -| pad.right,
        .height = size.height -| pad.top -| pad.bottom,
        .cell_width = cell.width,
        .cell_height = cell.height,
    };
}

/// The number of whole cells that fit in the terminal area.
fn gridSize(self: *const App) GridSize {
    const size = self.geometry.terminal;
    const cell = self.geometry.cell;
    const pad = self.geometry.padding;
    return .{
        .cols = @intCast(std.math.clamp((size.width -| pad.left -| pad.right) / cell.width, 1, std.math.maxInt(u16))),
        .rows = @intCast(std.math.clamp((size.height -| pad.top -| pad.bottom) / cell.height, 1, std.math.maxInt(u16))),
    };
}

/// Start a session on `target` in a tab of its own, at the end of its
/// group, and show it.
fn spawnSession(self: *App, target: Target) !void {
    try self.tabs.ensureUnusedCapacity(self.alloc, 1);
    const s = try self.createSession(target, self.gridSize());
    const t = Tab.create(self.alloc, self.nextTabKey(), null, 0, .none, .{ .pane = s }, s) catch |err| {
        s.kill();
        s.destroy();
        return err;
    };
    const at = self.groupEnd(self.groupOf(t));
    self.tabs.insertAssumeCapacity(at, t);
    self.layoutTab(t);
    if (self.tabs.items.len == 1) {
        // Shown as `activated` would show it, with no focus to take from
        // another pane.
        self.showTitle();
        self.markDirty();
        return;
    }
    // The rows from `at` on moved down.
    if (at <= self.active) self.active += 1;
    _ = self.ui.setHover(.none);
    self.middle_pressed = null;
    self.activate(at);
}

/// Start a session on `target` with a grid of `size`.
fn createSession(self: *App, target: Target, size: GridSize) !*Session {
    const launch: Session.Launch = switch (target) {
        .daemon => |sl| .{ .daemon = .{ .conn = sl.conn, .arrival = sl.arrival } },
        .waiting => |dest| .{ .waiting = .{ .dest = dest, .title = Hosts.label(dest) } },
        .failed => |f| .{ .failed = .{ .title = f.title, .why = f.why } },
    };
    return Session.create(self.alloc, self.wake, self.sessionEnv(), self.nextSessionId(), launch, size.cols, size.rows);
}

/// What a session asks the app on the UI thread.
fn sessionEnv(self: *App) Session.Env {
    return .{ .config = self.config, .ctx = self, .cell_size = sessionCellSize, .on_input = sessionInput };
}

fn sessionCellSize(ctx: *anyopaque) Session.CellSize {
    const self: *App = @ptrCast(@alignCast(ctx));
    return self.geometry.cell;
}

fn sessionInput(ctx: *anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    self.resetBlink();
}

/// A new session id. Channel ids are session ids, and the helper takes 0
/// to mean the connection.
fn nextSessionId(self: *App) u32 {
    if (self.next_session_id == 0) self.next_session_id = 1;
    const id = self.next_session_id;
    self.next_session_id +%= 1;
    return id;
}

/// Where `t` is listed, as the sidebar orders tabs: its workspace's
/// place, for a local tab in one; after every workspace for a local tab
/// in none (there while slime couldn't be reached, or no longer lists
/// it); then each host's. Tabs are kept in this order.
pub fn groupOf(self: *const App, t: *const Tab) usize {
    const dest = t.focus.hostDest() orelse return self.workspaceGroup(t.ws) orelse self.workspaces.items.len;
    // A host isn't forgotten while sessions use it.
    return self.localGroups() + (self.hosts.indexOf(dest) orelse return self.workspaces.items.len);
}

/// The place of host `h`'s tabs in the sidebar's order (`groupOf`).
fn hostGroup(self: *const App, h: usize) usize {
    return self.localGroups() + h;
}

/// Where a tab in group `g` goes: after the group's last.
fn groupEnd(self: *const App, g: usize) usize {
    var i: usize = 0;
    while (i < self.tabs.items.len and self.groupOf(self.tabs.items[i]) <= g) i += 1;
    return i;
}

/// What the daemon knows of the host at `dest`, if anything.
fn hostEntry(self: *App, dest: []const u16) ?*HostEntry {
    for (self.host_states.items) |*e| {
        if (std.mem.eql(u16, e.dest, dest)) return e;
    }
    return null;
}

fn hostEntryById(self: *App, id: u32) ?*HostEntry {
    for (self.host_states.items) |*e| {
        if (e.id == id) return e;
    }
    return null;
}

/// The daemon holds a connection to remembered host `h`, or is making
/// one.
pub fn hostLive(self: *App, h: usize) bool {
    const e = self.hostEntry(self.hosts.items.items[h]) orelse return false;
    return e.state == .connected or e.state == .connecting;
}

/// The session standing in for host `dest`'s panes, while one does.
fn standIn(self: *const App, dest: []const u16) ?Found {
    for (self.tabs.items, 0..) |t, i| {
        var it = t.iterator();
        while (it.next()) |s| {
            if (s.ended or s.daemonPane() != null) continue;
            const d = s.hostDest() orelse continue;
            if (std.mem.eql(u16, d, dest)) return .{ .tab = i, .s = s };
        }
    }
    return null;
}

/// A tab where the active tab is: its workspace, or its host. With
/// nothing shown, or an active tab in neither, the first shown
/// workspace's, else a new workspace.
fn newSession(self: *App) void {
    if (self.hasTabs()) {
        const t = self.activeTab();
        if (t.focus.hostDest()) |dest| {
            if (self.hosts.indexOf(dest)) |h| return self.openOnHost(h) catch |err| log.err("new session failed: {}", .{err});
        } else if (self.workspaceGroup(t.ws)) |w| {
            return self.newTabInWorkspace(w);
        }
    }
    for (self.workspaces.items, 0..) |w, i| {
        if (w.shown) return self.newTabInWorkspace(i);
    }
    self.newWorkspace();
}

/// The local daemon, for a new tab or workspace: a tab says why not if
/// it can't be had.
fn localDaemon(self: *App) ?*Daemon {
    const conn = self.daemon orelse {
        self.connectDaemon(self.local_command) catch |err| log.err("new session failed: {}", .{err});
        return null;
    };
    if (conn.isLost()) {
        // Its tabs say how; slime comes back with the next window.
        self.spawnFailed("lost slime", error.Disconnected) catch |err| log.err("new session failed: {}", .{err});
        return null;
    }
    return conn;
}

/// A tab in workspace `w`, shown first if it's hidden. The tab comes
/// when its pane does (`daemon_posted`).
fn newTabInWorkspace(self: *App, w: usize) void {
    const conn = self.localDaemon() orelse return;
    if (w >= self.workspaces.items.len) return;
    const ws = self.workspaces.items[w].id;
    if (!self.workspaces.items[w].shown) self.showWorkspace(ws);
    conn.tabNew(ws, self.local_command, self.daemonSize()) catch |err| log.err("new tab in slime failed: {}", .{err});
}

/// A session on remembered host `h`: a tab of the workspace the host's
/// slime holds for us, through the daemon we're attached to there, or
/// else one we bridge to, once the daemon has the host connected. Until
/// then a session stands in, where logging in asks what it needs; the
/// panes replace it once they come (`remoteChanged`). A host the daemon
/// can't connect, or slime can't run on, gets the reason there; ssh.exe
/// in a local tab still reaches it.
fn openOnHost(self: *App, h: usize) !void {
    const dest = self.hosts.items.items[h];
    if (self.remoteOn(dest)) |r| switch (r.conn.attachState()) {
        // The tab comes when its pane does (`daemon_posted`), in
        // whichever of the host's workspaces is attached.
        .attached => return r.conn.tabNew(r.conn.anyAttached() orelse return, &.{}, self.daemonSize()),
        // Still attaching: show where.
        .connecting => {
            if (self.standIn(dest)) |found| self.activate(found.tab);
            return;
        },
        .failed => {},
    };
    const daemon = self.daemon orelse {
        try self.spawnSession(.{ .waiting = dest });
        self.activeSession().showEnded("no local slime to connect through");
        return;
    };
    if (self.standIn(dest)) |found| {
        // Logging in, or waiting for the daemon: show where.
        self.activate(found.tab);
        return;
    }
    if (self.hostEntry(dest)) |e| switch (e.state) {
        .connected => return self.bridgeHost(e),
        .connecting => {
            // Another window is logging in; wait for it.
            try self.spawnSession(.{ .waiting = dest });
            return;
        },
        else => {},
    };
    try self.spawnSession(.{ .waiting = dest });
    const s = self.activeSession();
    _ = daemon.hostConnect(dest) catch |err| {
        log.err("connecting to {f} failed: {}", .{ std.unicode.fmtUtf16Le(dest), err });
        s.showEnded(@errorName(err));
        return;
    };
    // The entry comes with the daemon's first state; until then the
    // stand-in waits.
    if (self.hostEntry(dest)) |e| e.ours = true;
    s.login = Login.create(self.alloc, Hosts.label(dest)) catch null;
    self.updateSpinner();
}

/// Our daemon on host `dest` that's attached, or attaching, and not lost.
fn remoteOn(self: *App, dest: []const u16) ?*Remote {
    for (self.remotes.items) |*r| {
        if (!std.mem.eql(u16, r.conn.hostDest().?, dest)) continue;
        if (r.conn.attachState() == .failed or r.conn.isLost()) continue;
        return r;
    }
    return null;
}

/// Bridge to the slime on host `e`, which the daemon has connected. A
/// session stands in for its panes (one already, if logging in made it)
/// until they come.
fn bridgeHost(self: *App, e: *HostEntry) !void {
    try self.remotes.ensureUnusedCapacity(self.alloc, 1);
    const found = self.standIn(e.dest) orelse found: {
        try self.spawnSession(.{ .waiting = e.dest });
        break :found self.standIn(e.dest).?;
    };
    const s = found.s;
    if (s.login != null) self.closeLogin(s);
    const remote = Daemon.connectRemote(self.alloc, self.notify, self.shell.frameInterval(), e.id, e.dest, Session.sshTerm(self.config), self.daemonArea(), self.daemonSize()) catch |err| {
        log.err("bridging to slime on {f} failed: {}", .{ std.unicode.fmtUtf16Le(e.dest), err });
        s.showEnded(@errorName(err));
        return;
    };
    self.remotes.appendAssumeCapacity(.{ .conn = remote, .host = e.id });
}

/// Take up what slime connections posted: panes that arrived, what the
/// daemon said about workspaces and hosts, workspaces to show here, and
/// how attaching to hosts' went.
fn daemonPosted(self: *App) void {
    if (self.daemon) |conn| {
        self.workspacesChanged(conn);
        self.daemonChanged(conn);
        self.hostsChanged(conn);
        self.openWorkspaces(conn);
    }
    var i: usize = 0;
    while (i < self.remotes.items.len) {
        switch (self.remotes.items[i].conn.attachState()) {
            .connecting => {},
            .attached => self.remoteChanged(&self.remotes.items[i]),
            .failed => {
                self.remoteFailed(i);
                continue;
            },
        }
        i += 1;
    }
    self.pruneRemotes();
}

/// Show the workspaces `conn` was told to open here: a script run from
/// one of this window's panes made them.
fn openWorkspaces(self: *App, conn: *Daemon) void {
    const ids = conn.takeOpens();
    defer self.alloc.free(ids);
    for (ids) |id| self.showWorkspace(id);
}

/// Take up what host's slime `r` sent. Once its panes have come, they
/// replace the session that stood in for them, and the tabs of daemons
/// we lost on the host, which showed the same panes as they were.
fn remoteChanged(self: *App, r: *Remote) void {
    self.daemonChanged(r.conn);
    const dest = r.conn.hostDest().?;
    const found = self.standIn(dest) orelse return;
    // In tabs of their own by now.
    const first = for (self.tabs.items) |t| {
        if (t.conn == r.conn) break t;
    } else return;
    var show = found.tab == self.active;
    self.dropTab(found.tab);
    var i: usize = 0;
    while (i < self.tabs.items.len) {
        const old = self.tabs.items[i].conn;
        if (old == null or old == r.conn or old.?.hostDest() == null or !old.?.isLost() or
            !std.mem.eql(u16, old.?.hostDest().?, dest))
        {
            i += 1;
            continue;
        }
        show = show or i == self.active;
        self.dropTab(i);
    }
    if (show) self.activate(self.tabIndex(first).?);
}

/// Host's slime `remotes[i]` couldn't attach: let it go. Its stand-in
/// says why.
fn remoteFailed(self: *App, i: usize) void {
    var r = self.remotes.orderedRemove(i);
    // After the stand-in is done with the failure's text.
    defer self.freeRemote(&r);
    const found = self.standIn(r.conn.hostDest().?) orelse return;
    self.markDirty();
    found.s.showEnded(r.conn.failure.text());
}

/// Let go of hosts' daemons nothing shows any more: one whose stand-in
/// was closed before its panes came, or whose tabs have all gone.
fn pruneRemotes(self: *App) void {
    var i: usize = 0;
    while (i < self.remotes.items.len) {
        const r = &self.remotes.items[i];
        const shown = self.standIn(r.conn.hostDest().?) != null or for (self.tabs.items) |t| {
            if (t.conn == r.conn) break true;
        } else false;
        if (shown or r.conn.attachState() == .failed) {
            i += 1;
            continue;
        }
        var gone = self.remotes.orderedRemove(i);
        self.freeRemote(&gone);
    }
}

/// Hang up on a host's slime and forget what it showed.
fn freeRemote(self: *App, r: *Remote) void {
    r.conn.deinit();
    r.workspaces.deinit(self.alloc);
}

/// The remote on connection `conn`, if it's one of ours.
fn remoteOf(self: *App, conn: *const Daemon) ?*Remote {
    for (self.remotes.items) |*r| {
        if (r.conn == conn) return r;
    }
    return null;
}

/// The tab the daemon shows as active in workspace `ws` of `conn`, as
/// its structure last said or we last told it. None if nothing has said.
fn activeTabIn(self: *App, conn: *const Daemon, ws: u32) Daemon.TabRef {
    if (conn == self.daemon) return if (self.workspaceEntry(ws)) |w| w.active_tab else .none;
    const r = self.remoteOf(conn) orelse return .none;
    for (r.workspaces.items) |w| {
        if (w.id == ws) return w.active_tab;
    }
    return .none;
}

/// Note the tab shown as active in workspace `ws` of `conn`. A host's
/// workspace is first heard of this way.
fn setActiveTabIn(self: *App, conn: *const Daemon, ws: u32, tab: Daemon.TabRef) void {
    if (conn == self.daemon) {
        if (self.workspaceEntry(ws)) |w| w.active_tab = tab;
        return;
    }
    const r = self.remoteOf(conn) orelse return;
    for (r.workspaces.items) |*w| {
        if (w.id != ws) continue;
        w.active_tab = tab;
        return;
    }
    r.workspaces.append(self.alloc, .{ .id = ws, .active_tab = tab }) catch {};
}

/// Take up what the daemon said about hosts: keep each host's state,
/// show its prompts and status in the session standing in for it, and
/// bridge to it once it's connected.
fn hostsChanged(self: *App, conn: *Daemon) void {
    const events = conn.takeHosts();
    defer {
        for (events) |*e| e.deinit(self.alloc);
        self.alloc.free(events);
    }
    for (events) |*e| switch (e.*) {
        .hosts => |hosts| for (hosts) |h| self.hostState(h),
        .state => |h| self.hostState(h),
        .prompt => |p| {
            const login = login: {
                const entry = self.hostEntryById(p.host) orelse break :login null;
                const found = self.standIn(entry.dest) orelse break :login null;
                if (found.s == self.activeSession()) self.resetBlink();
                break :login self.loginFor(found.s, entry);
            } orelse {
                // Nothing to show it in: give up on logging in.
                conn.hostAnswer(p.host, .cancel, &.{}) catch {};
                continue;
            };
            login.ask(p.prompt);
            // The login owns it now.
            e.* = .{ .hosts = &.{} };
        },
    };
    self.updateSpinner();
    self.markDirty();
}

/// Record host `h`'s state, and act on it for the session standing in
/// for the host, if one does.
fn hostState(self: *App, h: Daemon.HostInfo) void {
    const e = self.hostEntryById(h.host) orelse e: {
        const dest = self.alloc.dupe(u16, h.dest) catch return;
        // A stand-in already logging in asked for this host.
        const ours = if (self.standIn(dest)) |found| found.s.login != null else false;
        self.host_states.append(self.alloc, .{ .id = h.host, .dest = dest, .state = h.state, .text = &.{}, .ours = ours }) catch {
            self.alloc.free(dest);
            return;
        };
        break :e &self.host_states.items[self.host_states.items.len - 1];
    };
    const text = self.alloc.dupe(u16, h.text) catch return;
    self.alloc.free(e.text);
    e.text = text;
    e.state = h.state;
    self.markDirty();

    const connecting = h.state == .connecting;
    defer if (!connecting and h.state != .connected) {
        e.ours = false;
    };
    const found = self.standIn(e.dest) orelse return;
    const s = found.s;
    switch (h.state) {
        .connecting => {
            // The stand-in that asked gets the prompts; any other just
            // follows along.
            const login = self.loginFor(s, e) orelse return;
            if (e.text.len > 0) login.info(e.text);
        },
        .connected => {
            if (self.remoteOn(e.dest) != null) return;
            self.bridgeHost(e) catch |err| {
                log.err("bridging to {f} failed: {}", .{ std.unicode.fmtUtf16Le(e.dest), err });
                s.showEnded(@errorName(err));
            };
        },
        .failed, .lost, .gone, _ => {
            var buf: [512]u8 = undefined;
            const why = std.unicode.utf16LeToUtf8(&buf, e.text) catch 0;
            if (s.login) |login| login.fail(buf[0..why]);
            s.showEnded(if (why > 0) buf[0..why] else "connection failed");
        },
    }
}

/// The login dialog of the session standing in for host `e`, made if it
/// has none.
fn loginFor(self: *App, s: *Session, e: *const HostEntry) ?*Login {
    if (s.login) |l| return l;
    s.login = Login.create(self.alloc, Hosts.label(e.dest)) catch return null;
    return s.login;
}

/// A stand-in is closing: if the daemon is logging in to its host for
/// us, give up on that.
fn standInClosing(self: *App, s: *Session) void {
    if (s.daemonPane() != null or s.ended) return;
    const dest = s.hostDest() orelse return;
    const e = self.hostEntry(dest) orelse return;
    const daemon = self.daemon orelse return;
    if (e.state == .connecting and e.ours) daemon.hostDisconnect(e.id);
}

/// What a new pane in `conn` runs: the local command, or for a host's,
/// its shell.
fn daemonCommand(self: *const App, conn: *const Daemon) []const u16 {
    return if (conn.host() == null) self.local_command else &.{};
}

/// Split the active tab's pane `s`, starting a shell on side `dir` of
/// it. The new pane comes from slime (`daemon_posted`).
fn splitPane(self: *App, s: *Session, dir: Daemon.Direction) void {
    const pane = s.daemonPane() orelse return;
    const t = self.activeTab();
    const conn = t.conn orelse return;
    if (t.zoom != null) {
        t.zoom = null;
        self.layoutTab(t);
        self.syncFocus();
    }
    conn.split(pane, dir, self.daemonCommand(conn)) catch |err| log.err("split failed: {}", .{err});
    self.markDirty();
}

/// Zoom the active tab's pane `s` to fill the tab, or unzoom it.
fn toggleZoom(self: *App, s: *Session) void {
    const t = self.activeTab();
    t.zoom = if (t.zoom == s) null else s;
    self.focusPane(s);
    _ = self.ui.setHover(.none);
    self.layoutTab(t);
    self.syncFocus();
    self.markDirty();
}

/// Show every pane of tab `t` again, if one is zoomed.
fn unzoom(self: *App, t: *Tab) void {
    if (t.zoom == null) return;
    t.zoom = null;
    _ = self.ui.setHover(.none);
    self.layoutTab(t);
    if (t == self.activeTab()) self.syncFocus();
    self.markDirty();
}

/// Focus the pane `to` picks in the active tab, from the focused one.
fn gotoPane(self: *App, to: binding.GotoSplit) void {
    const t = self.activeTab();
    if (t.count() < 2) return;
    // The panes' places, to look between, are the unzoomed ones.
    self.unzoom(t);
    const next = switch (to) {
        .previous => t.following(t.focus, false),
        .next => t.following(t.focus, true),
        inline else => |side| self.placed().neighbor(t.focus, @field(Daemon.Direction, @tagName(side))) orelse return,
    };
    self.focusPane(next);
    self.markDirty();
}

/// Move the divider beside the focused pane `cells` cells toward `side`,
/// as dragging it would, and send slime the tree.
fn resizePane(self: *App, side: Daemon.Direction, cells: u16) void {
    const t = self.activeTab();
    self.unzoom(t);
    const d = t.dividerFor(self.placed().dividers.items, t.focus, side) orelse return;
    const m = self.geometry.cell;
    const cell: f32 = @floatFromInt(if (d.axis() == .row) m.width else m.height);
    const px = cell * @as(f32, @floatFromInt(cells));
    const before = d.shares();
    d.drag(before, if (side == .right or side == .down) px else -px, self.paneMin(d.axis()));
    if (std.meta.eql(before, d.shares())) return;
    self.layoutTab(t);
    self.sendLayout(t);
    self.markDirty();
}

/// Give the active tab's panes the same sizes, and send slime the tree.
fn equalizePanes(self: *App) void {
    const t = self.activeTab();
    if (t.count() < 2) return;
    t.equalize();
    self.layoutTab(t);
    self.sendLayout(t);
    self.markDirty();
}

/// Start dragging divider `i` of the active tab, if slime has its tree.
fn startDrag(self: *App, i: usize, pos: win32.POINT) void {
    const t = self.activeTab();
    const dividers = self.placed().dividers.items;
    if (t.conn == null or i >= dividers.len) return;
    const d = dividers[i];
    self.hideTip();
    self.drag = .{ .tab = t, .divider = d, .from = d.shares(), .origin = across(d, pos) };
    self.shell.captureMouse();
}

/// The mouse's position across divider `d`'s axis.
fn across(d: Tab.Divider, pos: win32.POINT) i32 {
    return if (d.axis() == .row) pos.x else pos.y;
}

/// The least a pane takes along `axis` when a divider moves: room for a
/// few cells.
fn paneMin(self: *const App, axis: Tab.Axis) f32 {
    const m = self.geometry.cell;
    const pad = self.geometry.padding;
    return @floatFromInt(if (axis == .row) pad.left + pad.right + 4 * m.width else pad.top + pad.bottom + 2 * m.height);
}

/// Move the dragged divider to the mouse, resizing the panes either side
/// as it goes.
fn dragTo(self: *App, d: Drag, pos: win32.POINT) void {
    const before = d.divider.shares();
    d.divider.drag(d.from, @floatFromInt(across(d.divider, pos) - d.origin), self.paneMin(d.divider.axis()));
    if (std.meta.eql(before, d.divider.shares())) return;
    self.layoutTab(d.tab);
    self.markDirty();
}

/// Let go of the dragged divider and send slime the tree it left.
fn endDrag(self: *App) void {
    const d = self.drag orelse return;
    // First: releasing the capture comes back as `capture_lost`.
    self.drag = null;
    self.shell.releaseMouse();
    if (std.meta.eql(d.from, d.divider.shares())) return;
    self.sendLayout(d.tab);
}

/// Send slime tab `t`'s tree, changed here.
fn sendLayout(self: *App, t: *const Tab) void {
    const conn = t.conn orelse return;
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const root = (t.toLayout(arena.allocator()) catch return) orelse return;
    conn.layout(t.id, root) catch |err| log.err("sending the layout failed: {}", .{err});
}

/// Start dragging the sidebar's edge from the mouse at `pos`.
fn startSidebarDrag(self: *App, pos: win32.POINT) void {
    self.hideTip();
    self.sidebar_drag = .{ .from = self.ui.sidebar_width, .origin = pos.x };
    self.shell.captureMouse();
}

/// Move the sidebar's edge to the mouse, within the sidebar's range and
/// leaving the terminal area its least, laying the window out again as
/// it goes.
fn sidebarDragTo(self: *App, d: SidebarDrag, pos: win32.POINT) void {
    const dx = @as(f32, @floatFromInt(pos.x - d.origin)) / self.ui.scale;
    const room = self.frame.window.w / self.ui.scale - min_terminal_width;
    const most = @max(Ui.min_sidebar_width, @min(Ui.max_sidebar_width, room));
    const w = std.math.clamp(d.from + dx, Ui.min_sidebar_width, most);
    if (w == self.ui.sidebar_width) return;
    self.ui.sidebar_width = w;
    self.shell.relayout();
}

fn endSidebarDrag(self: *App) void {
    // First: releasing the capture comes back as `capture_lost`.
    self.sidebar_drag = null;
    self.shell.releaseMouse();
}

/// Drop a drag (of a divider or a pane) whose tree is about to change, as
/// it stands: slime's tree, or the pane closing, decides the layout now.
fn cancelDrag(self: *App) void {
    if (self.drag == null and self.pane_drag == null) return;
    self.drag = null;
    if (self.pane_drag != null) self.markDirty();
    self.pane_drag = null;
    self.shell.releaseMouse();
}

/// The button went down on pane `s`'s title strip: focus it, and drag it
/// if the mouse moves on with the button down.
fn startPaneDrag(self: *App, s: *Session, pos: win32.POINT) void {
    self.focusPane(s);
    self.hideTip();
    self.pane_drag = .{ .tab = self.activeTab(), .source = s, .start = pos };
    self.shell.captureMouse();
}

/// Follow the mouse with the dragged pane: once it's gone past the
/// system's drag distance, find where the pane would land. Only a tab of
/// several daemon panes rearranges; others just took focus.
fn paneDragTo(self: *App, d: *PaneDrag, pos: win32.POINT) void {
    if (d.tab.conn == null or d.tab.count() < 2) return;
    if (d.at == null) {
        const dx, const dy = self.shell.dragThreshold();
        if (@abs(pos.x - d.start.x) <= dx and @abs(pos.y - d.start.y) <= dy) return;
        // The panes each fill the tab while one is zoomed: show them all.
        if (d.tab.zoom != null) {
            d.tab.zoom = null;
            self.layoutTab(d.tab);
            self.syncFocus();
        }
    }
    d.at = pos;
    d.drop = self.dropAt(d, pos);
    self.markDirty();
}

/// Let go of the dragged pane, moving it where it was dropped.
fn endPaneDrag(self: *App) void {
    const d = self.pane_drag orelse return;
    // First: releasing the capture comes back as `capture_lost`.
    self.pane_drag = null;
    self.shell.releaseMouse();
    self.markDirty();
    const drop = d.drop orelse return;
    d.tab.move(self.alloc, d.source, drop.place) catch |err| return log.err("moving the pane failed: {}", .{err});
    self.layoutTab(d.tab);
    self.sendLayout(d.tab);
    self.syncFocus();
}

/// Where the dragged pane would land at `pos`: along a side of the tab
/// near its edge, else in the pane under the mouse, beside it on the
/// side the mouse is toward, or in its place from its middle.
fn dropAt(self: *App, d: *const PaneDrag, pos: win32.POINT) ?Drop {
    const x: f32 = @floatFromInt(pos.x);
    const y: f32 = @floatFromInt(pos.y);
    const area = self.geometry.pane_area;
    if (!area.contains(x, y)) return null;
    const band = self.ui.px(24);
    const edge: ?Daemon.Direction = if (x < area.x + band)
        .left
    else if (x >= area.right() - band)
        .right
    else if (y < area.y + band)
        .up
    else if (y >= area.bottom() - band)
        .down
    else
        null;
    if (edge) |side| return .{
        .place = .{ .edge = side },
        .rect = half(area, side).inset(self.ui.px(4), self.ui.px(4)),
    };

    const under = self.placed().at(x, y) orelse return null;
    const target = under.session;
    if (target == d.source) return null;
    const f = under.frame;
    const inset = self.ui.px(6);
    // The middle 40% each way swaps; else the side the mouse is toward,
    // as diagonals from the corners divide it.
    const nx = (x - (f.x + f.w / 2)) / f.w;
    const ny = (y - (f.y + f.h / 2)) / f.h;
    if (@abs(nx) < 0.2 and @abs(ny) < 0.2) return .{
        .place = .{ .swap = target },
        .rect = f.inset(inset, inset),
    };
    const side: Daemon.Direction = if (@abs(nx) > @abs(ny))
        (if (nx < 0) .left else .right)
    else
        (if (ny < 0) .up else .down);
    return .{
        .place = .{ .beside = .{ .target = target, .side = side } },
        .rect = half(f, side).inset(inset, inset),
    };
}

/// The half of `r` on `side`.
fn half(r: Rect, side: Daemon.Direction) Rect {
    return switch (side) {
        .left => .{ .x = r.x, .y = r.y, .w = @round(r.w / 2), .h = r.h },
        .right => .{ .x = r.x + @round(r.w / 2), .y = r.y, .w = r.w - @round(r.w / 2), .h = r.h },
        .up => .{ .x = r.x, .y = r.y, .w = r.w, .h = @round(r.h / 2) },
        .down => .{ .x = r.x, .y = r.y + @round(r.h / 2), .w = r.w, .h = r.h - @round(r.h / 2) },
    };
}

/// The active tab's pane on screen that `target` names.
fn shownPane(self: *const App, target: Id.Target) ?*Session {
    const found = self.sessionOf(target) orelse return null;
    if (found.tab != self.active or !self.activeTab().shows(found.s)) return null;
    return found.s;
}

/// Show the tab of the pane `target` names and give the pane the keys.
fn showPane(self: *App, target: Id.Target) void {
    const found = self.sessionOf(target) orelse return;
    self.activate(found.tab);
    self.focusPane(found.s);
}

/// Give the active tab's pane `s` the keys.
fn focusPane(self: *App, s: *Session) void {
    const t = self.activeTab();
    if (t.focus == s or !t.contains(s)) return;
    self.deactivate();
    t.focus = s;
    self.activated();
}

/// Whether a tab is on remembered host `h`.
fn hostHasTabs(self: *const App, h: usize) bool {
    for (self.tabs.items) |t| {
        if (self.groupOf(t) == self.hostGroup(h)) return true;
    }
    return false;
}

/// Drop remembered host `h` from the sidebar, if no tab uses it.
fn forgetHost(self: *App, h: usize) void {
    if (h >= self.hosts.items.items.len or self.hostHasTabs(h)) return;
    self.hosts.remove(h);
    _ = self.ui.setHover(.none);
    self.markDirty();
}

/// Close pane `s` of tab `ti`, killing what runs in it. Closing a tab's
/// last pane closes the tab.
fn closePane(self: *App, ti: usize, s: *Session) void {
    self.cancelDrag();
    const t = self.tabs.items[ti];
    if (t.count() <= 1) return self.closeTab(ti);
    const focused = ti == self.active and s == t.focus;
    if (focused) self.deactivate();
    _ = t.remove(self.alloc, s);
    self.layoutTab(t);
    self.standInClosing(s);
    s.kill();
    // It may be placed.
    self.placement_stale = true;
    s.destroy();
    _ = self.ui.setHover(.none);
    if (focused) self.activated();
    self.pruneRemotes();
    self.markDirty();
}

/// Close tab `i`, killing what runs in its panes. Closing the last one
/// closes the window, unless a workspace in the sidebar has more.
fn closeTab(self: *App, i: usize) void {
    self.cancelDrag();
    var it = self.tabs.items[i].iterator();
    while (it.next()) |s| {
        self.standInClosing(s);
        s.kill();
    }
    self.dropTab(i);
    self.pruneRemotes();
    self.closeIfNothingLeft();
}

/// Take tab `i` out and free it with its sessions, which lets go of
/// slime's panes without ending them.
fn dropTab(self: *App, i: usize) void {
    const was_active = i == self.active;
    if (was_active) self.deactivate();
    self.destroyTab(self.tabs.orderedRemove(i));
    // Rows moved under the mouse.
    _ = self.ui.setHover(.none);
    self.middle_pressed = null;
    if (self.tabs.items.len == 0) {
        self.active = 0;
        self.showTitle();
        self.updateSpinner();
    } else if (i < self.active) {
        self.active -= 1;
    } else if (was_active) {
        self.active = @min(i, self.tabs.items.len - 1);
        self.activated();
    }
    self.markDirty();
}

/// Show tab `i` and give its focused pane input.
fn activate(self: *App, i: usize) void {
    if (i == self.active or i >= self.tabs.items.len) return;
    self.deactivate();
    self.active = i;
    self.activated();
}

/// Let go of the focused pane before switching away from it.
fn deactivate(self: *App) void {
    const s = self.focusedSession() orelse return;
    // First: releasing the capture comes back as `capture_lost`.
    const had_mouse = self.mouse_in_terminal;
    self.mouse_in_terminal = false;
    if (had_mouse) self.shell.releaseMouse();
    s.cancelSelection();
    if (self.focused) s.reportFocus(false);
}

/// Take up the pane that just got focus, in the tab now shown.
fn activated(self: *App) void {
    const s = self.activeSession();
    var it = self.activeTab().iterator();
    while (it.next()) |p| {
        p.activity = false;
        p.unseen.store(false, .release);
    }
    if (self.focused) s.reportFocus(true);
    self.resetBlink();
    self.updateSpinner();
    self.showTitle();
    self.syncFocus();
    self.markDirty();
}

/// Show the next or previous tab, wrapping around.
fn cycle(self: *App, forward: bool) void {
    const n = self.tabs.items.len;
    if (n == 0) return;
    self.activate(if (forward) (self.active + 1) % n else (self.active + n - 1) % n);
}

/// A session's reader handed it a frame or a status: the active tab's
/// panes draw, and the others' rows show activity.
fn outputArrived(self: *App) void {
    const quiet = self.shell.tickCount() < self.quiet_until;
    var status_changed = false;
    for (self.tabs.items, 0..) |t, i| {
        var it = t.iterator();
        while (it.next()) |s| {
            if (s.status_changed.swap(false, .acq_rel)) status_changed = true;
            if (!s.unseen.swap(false, .acq_rel)) continue;
            if (i == self.active) {
                if (!t.shows(s)) continue;
                self.markDirty();
            } else if (!s.activity and !quiet) {
                s.activity = true;
                self.markDirty();
            }
        }
    }
    if (status_changed) {
        self.markDirty();
        self.updateSpinner();
    }
}

/// Run the key binding a key press triggers (see `binding.defaults`).
/// Returns true if the key is consumed, which also holds for the release
/// of a key that ran a binding.
fn keyBinding(self: *App, msg: u32, wparam: win32.WPARAM) bool {
    const vk: u32 = @truncate(wparam);
    if (msg == win32.WM_KEYUP or msg == win32.WM_SYSKEYUP) {
        if (self.bound_key != vk) return false;
        self.bound_key = null;
        return true;
    }

    const b = binding.find(&binding.defaults, vk, self.shell.mods()) orelse return false;
    if (!self.runAction(b.action) and b.performable) return false;

    // Drop the text TranslateMessage posted for the key (ctrl+shift+c
    // gives 0x03).
    self.shell.dropPendingChars();
    self.bound_key = vk;
    return true;
}

/// Returns false if the action couldn't run: copy with no selection,
/// paste with no text on the clipboard, a pane action in a tab slime
/// doesn't run, or with nothing shown.
fn runAction(self: *App, action: binding.Action) bool {
    const s = self.focusedSession() orelse switch (action) {
        .new_tab => {
            self.newSession();
            return true;
        },
        .increase_font_size => |pt| {
            self.shell.setFontSize(self.shell.fontSize() + pt);
            return true;
        },
        .decrease_font_size => |pt| {
            self.shell.setFontSize(self.shell.fontSize() - pt);
            return true;
        },
        .reset_font_size => {
            self.shell.setFontSize(self.config.@"font-size");
            return true;
        },
        else => return false,
    };
    switch (action) {
        .new_split, .goto_split, .resize_split, .equalize_splits, .toggle_split_zoom => if (self.activeTab().conn == null) return false,
        else => {},
    }
    switch (action) {
        .copy_to_clipboard => return s.copySelection(),
        .paste_from_clipboard => {
            if (!self.shell.clipboardHasText()) return false;
            s.paste();
        },
        .new_tab => self.newSession(),
        .close_surface => self.closePane(self.active, s),
        .next_tab => self.cycle(true),
        .previous_tab => self.cycle(false),
        .increase_font_size => |pt| self.shell.setFontSize(self.shell.fontSize() + pt),
        .decrease_font_size => |pt| self.shell.setFontSize(self.shell.fontSize() - pt),
        .reset_font_size => self.shell.setFontSize(self.config.@"font-size"),
        .new_split => |dir| self.splitPane(s, switch (dir) {
            inline else => |d| @field(Daemon.Direction, @tagName(d)),
        }),
        .goto_split => |to| self.gotoPane(to),
        .resize_split => |r| self.resizePane(switch (r.direction) {
            inline else => |d| @field(Daemon.Direction, @tagName(d)),
        }, r.amount),
        .equalize_splits => self.equalizePanes(),
        .toggle_split_zoom => if (self.activeTab().count() > 1 or self.activeTab().zoom != null) self.toggleZoom(s),
    }
    return true;
}

/// Track keyboard focus: the cursor blinks only while focused and is a
/// hollow block otherwise, and the active session's child hears about it.
fn setFocus(self: *App, focused: bool) void {
    if (self.focused == focused) return;
    self.focused = focused;
    self.markDirty();
    if (!focused) self.hideTip();
    // Menus go with the focus, as Windows' do.
    if (!focused) self.closeMenu();
    if (focused) {
        self.resetBlink();
    } else {
        self.shell.killTimer(.blink);
    }
    if (self.focusedSession()) |s| s.reportFocus(focused);
}

/// Start the blink over in its on phase. Blinking follows the system's
/// caret blink rate, and is off when the user turned caret blinking off.
fn resetBlink(self: *App) void {
    if (!self.blink_visible) {
        self.blink_visible = true;
        self.markDirty();
    }
    if (!self.focused) return;
    if (self.shell.caretBlinkTime()) |ms| {
        // Setting an existing timer restarts it.
        self.shell.setTimer(.blink, ms);
    } else {
        self.shell.killTimer(.blink);
    }
}

fn blinkTick(self: *App) void {
    self.blink_visible = !self.blink_visible;
    // Only redraw if the last frame's cursor blinks. One that starts
    // blinking later picks up the phase from here.
    if (self.focusedSession()) |s| {
        const c = s.screen.cursor;
        if (c.visible and c.blinking) self.markDirty();
    }
    switch (self.keyboard()) {
        .connect, .rename => self.markDirty(),
        .terminal, .confirm, .menu, .login => {},
    }
}

/// Show the host field in place of "Connect".
fn startConnect(self: *App) void {
    if (self.mode == .connect) return;
    // Destinations go on the helper's command line unquoted.
    self.mode = .{ .connect = .{ .reject = std.unicode.utf8ToUtf16LeStringLiteral(" \t\"") } };
    self.resetBlink();
    self.markDirty();
}

fn cancelConnect(self: *App) void {
    if (self.mode != .connect) return;
    self.mode = .terminal;
    self.markDirty();
}

/// Connect to the host in the field, `ssh://` being implied, and close
/// the field.
fn submitConnect(self: *App, field: *TextField) void {
    const scheme = std.unicode.utf8ToUtf16LeStringLiteral("ssh://");
    var buf: [scheme.len + TextField.max_len]u16 = undefined;
    const host = field.text();
    const dest = if (std.mem.startsWith(u16, host, scheme)) host else dest: {
        @memcpy(buf[0..scheme.len], scheme);
        @memcpy(buf[scheme.len..][0..host.len], host);
        break :dest buf[0 .. scheme.len + host.len];
    };
    if (dest.len > scheme.len) connect: {
        const h = self.hosts.add(dest) catch |err| break :connect log.err("connect failed: {}", .{err});
        self.openOnHost(h) catch |err| log.err("connect failed: {}", .{err});
    }
    self.cancelConnect();
}

/// A key down while the host field is open. Returns false for keys it
/// doesn't take.
fn connectKey(self: *App, field: *TextField, vk: u32) bool {
    switch (vk) {
        win32.VK_RETURN => self.submitConnect(field),
        win32.VK_ESCAPE => self.cancelConnect(),
        else => if (!self.editKey(field, vk, true)) return false,
    }
    self.keyHandled();
    return true;
}

/// Edit `field` for an editing key, as Windows edit controls do.
/// `copyable` is false for passwords. Returns false for other keys.
fn editKey(self: *App, field: *TextField, vk: u32, copyable: bool) bool {
    const ctrl = self.shell.keyDown(win32.VK_CONTROL);
    const shift = self.shell.keyDown(win32.VK_SHIFT);
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
fn keyHandled(self: *App) void {
    self.shell.dropPendingChars();
    self.resetBlink();
    self.markDirty();
}

/// Copy `field`'s selection, cutting it if `cut`. A password's isn't
/// copied, or cut.
fn fieldCopy(self: *App, field: *TextField, cut: bool, copyable: bool) void {
    const units = field.selected();
    if (units.len == 0 or !copyable) return;
    const text = std.unicode.utf16LeToUtf8Alloc(self.alloc, units) catch return;
    defer self.alloc.free(text);
    self.shell.clipboardSet(text) catch |err| return log.warn("copy failed: {}", .{err});
    if (cut) field.press(.delete, false, false);
}

/// Paste the clipboard's first line into `field`.
fn fieldPaste(self: *App, field: *TextField) void {
    const text = (self.shell.clipboardGet(self.alloc) catch |err| return log.warn("paste failed: {}", .{err})) orelse return;
    defer self.alloc.free(text);
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, text, " \t\r\n"), '\n');
    const line = lines.first();
    const units = std.unicode.utf8ToUtf16LeAlloc(self.alloc, line) catch return;
    defer self.alloc.free(units);
    field.insert(units);
}

/// What has the keyboard: the host field, a rename, or the kill dialog
/// if one is open, else the active session's login dialog if it has
/// one, else its terminal.
pub fn keyboard(self: *App) Keyboard {
    switch (self.mode) {
        .connect => |*f| return .{ .connect = f },
        .rename => |*r| return .{ .rename = &r.field },
        .confirm => |*c| return .{ .confirm = &c.dialog },
        .menu => |*m| return .{ .menu = m },
        .terminal => {},
    }
    const s = self.focusedSession() orelse return .terminal;
    return if (s.login) |l| .{ .login = l } else .terminal;
}

/// The active session's login dialog, while it has the keyboard.
fn activeLogin(self: *App) ?*Login {
    return switch (self.keyboard()) {
        .login => |l| l,
        else => null,
    };
}

/// The dialog over the terminal area, if one is up: the kill dialog, or
/// the active session's login.
fn activeDialog(self: *App) ?*Dialog {
    return switch (self.keyboard()) {
        .confirm => |d| d,
        .login => |l| &l.dialog,
        else => null,
    };
}

/// A key down for the active session's login dialog. Returns false for
/// keys it doesn't take.
fn loginKey(self: *App, login: *Login, vk: u32) bool {
    const d = &login.dialog;
    switch (vk) {
        win32.VK_RETURN => if (d.enterAction()) |action| self.loginAction(action),
        win32.VK_SPACE => if (d.focusedButton()) |b| self.loginAction(b.action) else return false,
        win32.VK_ESCAPE => self.loginAction(d.escapeAction()),
        // Ctrl+Tab still switches sessions.
        win32.VK_TAB => if (self.shell.keyDown(win32.VK_CONTROL))
            return false
        else
            d.cycleFocus(!self.shell.keyDown(win32.VK_SHIFT)),
        else => {
            const field = d.focused() orelse return false;
            if (!self.editKey(field, vk, d.fields[d.focus.field].echo)) return false;
        },
    }
    self.keyHandled();
    return true;
}

/// Act on a login dialog's button for the active session.
fn loginAction(self: *App, action: Dialog.Action) void {
    const s = self.focusedSession() orelse return;
    const login = s.login orelse return;
    const daemon = self.daemon orelse return;
    const e = self.hostEntry(s.hostDest() orelse return) orelse return;
    switch (action) {
        .accept, .skip => {
            var buf: [Dialog.max_fields][]const u16 = undefined;
            const choice: Daemon.Choice = if (action == .accept) .accept else .skip;
            daemon.hostAnswer(e.id, choice, login.answers(&buf)) catch |err| log.warn("answering failed: {}", .{err});
            login.answered();
        },
        .cancel => {
            // A prompt takes it as its answer; while the server works on
            // one, it gives up on logging in.
            daemon.hostAnswer(e.id, .cancel, &.{}) catch {};
            self.closeLogin(s);
        },
        .close => self.closeLogin(s),
    }
    self.updateSpinner();
    self.markDirty();
}

fn closeLogin(self: *App, s: *Session) void {
    const login = s.login orelse return;
    login.destroy();
    s.login = null;
    _ = self.ui.setHover(.none);
    self.updateSpinner();
    self.markDirty();
}

/// Run the spinner's timer while the active session's dialog waits, or a
/// pane is working.
fn updateSpinner(self: *App) void {
    const login: ?*Login = if (self.focusedSession()) |s| s.login else null;
    const waiting = if (login) |l| l.dialog.state == .waiting else self.anyWorking();
    if (waiting == self.spinning) return;
    self.spinning = waiting;
    if (waiting) {
        self.shell.setTimer(.spinner, spinner_ms);
    } else {
        self.shell.killTimer(.spinner);
    }
}

/// A pane reports work in progress, which the sidebar shows turning.
fn anyWorking(self: *App) bool {
    for (self.tabs.items) |t| {
        var it = t.iterator();
        while (it.next()) |s| {
            const summary = s.statusSummary() orelse continue;
            if (summary.state == .working) return true;
        }
    }
    return false;
}

/// The tree of widgets for the app's state now, laid out in the window's
/// frame: built in the arena, which is emptied first, so the last tree
/// is gone. The renderer calls this once a frame; `hitAt` reuses the
/// tree while nothing has changed (`currentTree`).
pub fn view(self: *App) *const Tree {
    // A menu about something that's gone goes too.
    if (!self.menuTargetExists()) self.closeMenu();
    // The builder reads the placement.
    _ = self.placed();
    _ = self.arena.reset(.retain_capacity);
    self.tree = view_.build(self, self.arena.allocator()) catch |err| tree: {
        log.err("building the view failed: {}", .{err});
        break :tree .{ .root = .{ .kind = .{ .canvas = &.{} } }, .frame = self.frame.* };
    };
    self.ui.layout(&self.tree.?);
    self.tree_stale = false;
    self.views +%= 1;
    return &self.tree.?;
}

/// The tree as things are now: the last one built, unless something has
/// changed since (`tree_stale`), when it's built again. So the mouse is
/// never tested against widgets that have moved or gone.
fn currentTree(self: *App) *const Tree {
    if (self.tree == null or self.tree_stale) return self.view();
    return &self.tree.?;
}

/// Where the active tab's panes are, placed anew if anything changed
/// since they were (`placement_stale`). The only way to read `placement`.
pub fn placed(self: *App) *const Placement {
    if (self.placement_stale) {
        self.placement_stale = false;
        self.placement.clear();
        if (self.active < self.tabs.items.len) self.placeTab(self.tabs.items[self.active], &self.placement);
    }
    return &self.placement;
}

/// What's under a client position.
pub fn hitAt(self: *App, pos: win32.POINT) Id {
    return self.ui.hitTest(self.currentTree(), @floatFromInt(pos.x), @floatFromInt(pos.y));
}

/// What the mouse cursor should be at a client position: a text field's
/// I-beam, a divider's or a dragged pane's sizing arrows, or the shape a
/// pane's program set.
pub fn cursor(self: *App, pos: win32.POINT) Cursor {
    var cursor_: Cursor = .arrow;
    const hit = self.hitAt(pos);
    // A dialog's field, or a workspace's name being edited.
    if (hit.part == .field) cursor_ = .ibeam;
    const divider: ?Tab.Divider = if (self.drag) |d| d.divider else switch (hit.target) {
        .divider => |i| if (i < self.placed().dividers.items.len) self.placed().dividers.items[i] else null,
        else => null,
    };
    if (divider) |d| cursor_ = if (d.axis() == .row) .size_we else .size_ns;
    if (self.sidebar_drag != null or hit.eql(.window(.sidebar_edge))) cursor_ = .size_we;
    if (self.pane_drag) |d| if (d.at != null) {
        cursor_ = .size_all;
    };
    const pane = if (self.mouse_in_terminal) self.focusedSession() else if (hit.part == .terminal) self.shownPane(hit.target) else null;
    if (pane) |s| cursor_ = .{ .shape = s.mouseShape() };
    return cursor_;
}

/// A client position relative to pane `s`'s terminal. A pane that isn't
/// placed (which the mouse can't be over) takes the position as is.
fn toPane(self: *App, s: *const Session, pos: win32.POINT) win32.POINT {
    const p = self.placed().find(s) orelse return pos;
    return .{ .x = pos.x - @as(i32, @intFromFloat(p.rect.x)), .y = pos.y - @as(i32, @intFromFloat(p.rect.y)) };
}

/// Track what the mouse is over, and time the tooltip of a button it
/// moves onto. Returns true if the hover changed.
fn setHover(self: *App, hit: Id) bool {
    const had_tip = self.ui.tip.target != .none;
    if (!self.ui.setHover(hit)) return false;
    // The keyboard follows the mouse through a menu's entries.
    if (hit.target == .menu and self.mode == .menu) self.mode.menu.focus = hit.target.menu;
    self.markDirty();
    self.shell.killTimer(.tip);
    const now = self.shell.tickCount();
    if (had_tip) self.tip_warm_until = now + tip_warm_ms;
    if (!Ui.hasTip(self.currentTree(), self.ui.hover)) return true;
    if (now < self.tip_warm_until) {
        _ = self.ui.showTip(self.currentTree());
        return true;
    }
    self.shell.setTimer(.tip, self.shell.hoverTime());
    return true;
}

fn hideTip(self: *App) void {
    self.shell.killTimer(.tip);
    if (self.ui.hideTip()) self.markDirty();
}

fn setPressed(self: *App, hit: Id) void {
    if (self.ui.setPressed(hit)) self.markDirty();
}

/// Handle a client area mouse message: a pane gets it if a button went
/// down there (until all are up) or it's over the pane, and the widgets
/// otherwise. Pressing a button over a pane focuses it.
fn mouseInput(self: *App, m: Msg.Mouse) void {
    const msg = m.msg;
    const wparam = m.wparam;
    const pos = m.pos;
    const held = input.heldButton(wparam) != null;
    const press = if (input.mouseButton(msg, wparam)) |b| b[1] else false;

    if (self.drag) |d| {
        self.dragTo(d, pos);
        if (!held) self.endDrag();
        return;
    }
    if (self.pane_drag) |*d| {
        self.paneDragTo(d, pos);
        if (!held) self.endPaneDrag();
        return;
    }
    if (self.sidebar_drag) |d| {
        self.sidebarDragTo(d, pos);
        if (!held) self.endSidebarDrag();
        return;
    }

    if (self.mouse_in_terminal) {
        if (self.focusedSession()) |s| s.mouseInput(msg, wparam, self.toPane(s, pos));
        if (!held) {
            self.mouse_in_terminal = false;
            // After the session's handled the release, so a selection
            // ends where the button came up.
            self.shell.releaseMouse();
        }
        return;
    }

    var hit = self.hitAt(pos);
    // What a row shows changes with the mouse over it (its buttons
    // appear), so what's under the mouse may too: look again.
    if (self.setHover(hit)) {
        hit = self.hitAt(pos);
        _ = self.setHover(hit);
    }
    if (press) self.hideTip();
    // A press outside an open menu closes it, and goes no further.
    if (press and self.mode == .menu and hit.target != .menu and !hit.eql(.window(.menu))) return self.closeMenu();
    // Clicking anywhere else closes the host field, and a rename.
    if (press and !hit.eql(.window(.connect))) self.cancelConnect();
    if (press and !(hit.part == .field and hit.target == .workspace)) self.cancelRename();
    if (hit.part == .terminal) {
        const pane = self.shownPane(hit.target) orelse return;
        if (press) {
            self.focusPane(pane);
            // Capture the mouse while a button is down, so a drag past
            // the edge still reports and the release comes back to us.
            self.mouse_in_terminal = true;
            self.shell.captureMouse();
        }
        pane.mouseInput(msg, wparam, self.toPane(pane, pos));
        return;
    }

    switch (msg) {
        win32.WM_LBUTTONDOWN => {
            if (hit.target == .divider) return self.startDrag(hit.target.divider, pos);
            if (hit.eql(.window(.sidebar_edge))) return self.startSidebarDrag(pos);
            if (hit.part == .title) if (self.shownPane(hit.target)) |pane| return self.startPaneDrag(pane, pos);
            self.setPressed(hit);
            self.shell.captureMouse();
            // Rows switch on press, as tabs do.
            if (hit.part == .body) switch (hit.target) {
                .tab => if (self.tabIndexOf(hit.target)) |i| self.activate(i),
                .pane => self.showPane(hit.target),
                else => {},
            };
        },
        win32.WM_LBUTTONUP => {
            const pressed = self.ui.pressed;
            self.setPressed(.none);
            self.shell.releaseMouse();
            if (pressed.eql(hit)) self.widgetClick(hit);
        },
        // A tab's row, or its close button.
        win32.WM_MBUTTONDOWN => self.middle_pressed = if (hit.target == .tab and (hit.part == .body or hit.part == .close)) hit.target else null,
        win32.WM_MBUTTONUP => {
            const pressed = self.middle_pressed orelse return;
            self.middle_pressed = null;
            if (!hit.on(pressed) or (hit.part != .body and hit.part != .close)) return;
            if (self.tabIndexOf(pressed)) |i| self.closeTab(i);
        },
        else => {},
    }
}

/// A wheel turned at a client position: the pane under it, or the one
/// with the mouse, scrolls.
fn wheelInput(self: *App, m: Msg.Mouse) void {
    const pane = if (self.mouse_in_terminal) (self.focusedSession() orelse return) else pane: {
        const hit = self.hitAt(m.pos);
        if (hit.part != .terminal) return;
        break :pane self.shownPane(hit.target) orelse return;
    };
    pane.mouseWheel(m.msg, m.wparam, self.toPane(pane, m.pos));
}

/// Act on a click that went down and up on the widget `hit` names.
fn widgetClick(self: *App, hit: Id) void {
    switch (hit.part) {
        .toggle_sidebar => {
            self.ui.toggleSidebar();
            self.shell.relayout();
        },
        // Local's header makes a workspace; a host's, a tab there; a
        // workspace's row, a tab in it. With no daemon to list
        // workspaces, Local's makes a tab.
        .new_tab => switch (hit.target) {
            .local => if (self.workspaces.items.len == 0) self.newSession() else self.newWorkspace(),
            .host => |h| self.openOnHost(h) catch |err| log.err("new session failed: {}", .{err}),
            .workspace => |id| if (self.workspaceGroup(id)) |w| self.newTabInWorkspace(w),
            else => {},
        },
        .forget => switch (hit.target) {
            .host => |h| self.forgetHost(h),
            else => {},
        },
        .body => switch (hit.target) {
            .menu => |i| self.chooseItem(i),
            else => if (self.workspaceOf(hit.target)) |ws| {
                if (ws.shown) self.hideWorkspace(ws.id) else self.showWorkspace(ws.id);
            },
        },
        .show => if (self.workspaceOf(hit.target)) |ws| self.showWorkspace(ws.id),
        .hide => if (self.workspaceOf(hit.target)) |ws| self.hideWorkspace(ws.id),
        .kill => if (self.workspaceOf(hit.target)) |ws| self.askKillWorkspace(ws.id),
        .rename => if (self.workspaceOf(hit.target)) |ws| self.startRename(ws.id),
        .connect => self.startConnect(),
        .button => if (hit.target == .dialog) {
            const i = hit.target.dialog;
            const d = self.activeDialog() orelse return;
            var buf: [Dialog.max_buttons]Dialog.Button = undefined;
            const buttons = d.buttons(&buf);
            if (i >= buttons.len or buttons[i].disabled) return;
            if (self.mode == .confirm) self.confirmAction(buttons[i].action) else self.loginAction(buttons[i].action);
        },
        .field => if (hit.target == .dialog) {
            const d = self.activeDialog() orelse return;
            d.focus = .{ .field = hit.target.dialog };
            self.resetBlink();
            self.markDirty();
        },
        .close => if (self.tabIndexOf(hit.target)) |i| self.closeTab(i),
        .fold => if (self.tabIndexOf(hit.target)) |i| {
            const t = self.tabs.items[i];
            t.folded = !t.folded;
            _ = self.ui.setHover(.none);
            self.markDirty();
        },
        .split_right => if (self.shownPane(hit.target)) |s| self.splitPane(s, .right),
        .split_down => if (self.shownPane(hit.target)) |s| self.splitPane(s, .down),
        .zoom => if (self.shownPane(hit.target)) |s| self.toggleZoom(s),
        else => {},
    }
}

/// A key went down or up: whatever has the keyboard takes it, then the
/// key bindings, then the focused pane's terminal. Alt+F4 is left to
/// Windows (`.default`).
fn keyInput(self: *App, k: Msg.Key) Result {
    const msg = k.msg;
    const wparam = k.wparam;
    const lparam = k.lparam;
    const down = msg == win32.WM_KEYDOWN or msg == win32.WM_SYSKEYDOWN;
    if (down) self.hideTip();
    // Escape drops a pane being dragged where it was.
    if (msg == win32.WM_KEYDOWN and wparam == win32.VK_ESCAPE and self.pane_drag != null) {
        self.cancelDrag();
        return .handled;
    }
    switch (self.keyboard()) {
        .terminal => {},
        inline else => |owner, tag| {
            const vk: u32 = @truncate(wparam);
            const taken = down and switch (tag) {
                .connect => self.connectKey(owner, vk),
                .rename => self.renameKey(owner, vk),
                .confirm => self.confirmKey(owner, vk),
                .menu => self.menuKey(owner, vk),
                .login => self.loginKey(owner, vk),
                .terminal => unreachable,
            };
            if (taken) return .handled;
            if (self.keyBinding(msg, wparam)) return .handled;
            // Keep alt+F4; the session gets nothing.
            if (msg == win32.WM_SYSKEYDOWN and wparam == win32.VK_F4) return .default;
            return .handled;
        },
    }
    if (self.keyBinding(msg, wparam)) return .handled;
    // Nothing shown: the keys have nowhere to go but alt+F4.
    if (!self.hasTabs()) {
        if (msg == win32.WM_SYSKEYDOWN and wparam == win32.VK_F4) return .default;
        return .handled;
    }
    if (self.activeSession().ended) {
        if (down and !input.isModifier(wparam, lparam)) {
            // Drop the key's text, which would otherwise go to the
            // session shown next.
            self.shell.dropPendingChars();
            self.closePane(self.active, self.activeSession());
        }
        return .handled;
    }
    // The Menu key opens the focused pane's menu; shift+F10 is the
    // program's.
    if (down and wparam == win32.VK_APPS) {
        self.menuForFocused();
        return .handled;
    }
    switch (wparam) {
        // The text arrives as WM_CHAR.
        win32.VK_PACKET, win32.VK_PROCESSKEY => {},
        // Keep alt+F4.
        win32.VK_F4 => if (msg == win32.WM_SYSKEYDOWN and self.shell.keyDown(win32.VK_MENU)) {
            return .default;
        } else self.activeSession().keyInput(msg, wparam, lparam),
        else => self.activeSession().keyInput(msg, wparam, lparam),
    }
    // Not passing WM_SYSKEYUP on also keeps a lone alt from entering menu
    // mode.
    return .handled;
}

/// A UTF-16 unit of text: into the field with the keyboard, if one has
/// it, else the focused pane. A dialog without a field swallows it.
fn charInput(self: *App, unit: u16, sys: bool) void {
    switch (self.keyboard()) {
        .terminal => if (self.focusedSession()) |s| s.charInput(unit),
        else => |owner| if (!sys) if (owner.field()) |f| {
            f.insert(&.{unit});
            self.resetBlink();
            self.markDirty();
        },
    }
}

/// Set the window text, which the taskbar shows: the active session's
/// title, or the app's with nothing shown.
fn showTitle(self: *App) void {
    var text: [Session.max_title_len + 1]u16 = undefined;
    const title: []const u16 = if (self.focusedSession()) |s| s.title() else app_name;
    const len = @min(title.len, Session.max_title_len);
    @memcpy(text[0..len], title[0..len]);
    text[len] = 0;
    self.shell.setTitle(text[0..len :0]);
}

/// Fit tab `t`'s panes to the terminal area, whether it's shown or not:
/// a tab's panes keep their sizes in slime while it's out of sight. The
/// active tab's are placed again before they're drawn (`placed`), as
/// anything that changes them makes the placement stale.
fn layoutTab(self: *App, t: *Tab) void {
    var scratch: Placement = .{};
    defer scratch.deinit(self.alloc);
    self.placeTab(t, &scratch);
    self.placement_stale = true;
}

/// Place tab `t`'s panes in the terminal area, into `into`, and fit
/// their grids to them. Each pane's terminal is under its title strip,
/// padded by the geometry's padding (but for the chrome's inset at the
/// top, which the strip stands in for), and the grid is centered in
/// what's left, so the part of a cell that doesn't fit is split between
/// opposite edges rather than all at the right and bottom.
fn placeTab(self: *App, t: *Tab, into: *Placement) void {
    const g = &self.geometry;
    t.place(self.alloc, into, g.pane_area, g.gap) catch |err| {
        log.err("laying out panes failed: {}", .{err});
        into.clear();
    };
    var pad = g.padding;
    pad.top -|= g.inset;
    const strip = g.title_height;
    const m = g.cell;
    for (into.panes.items) |*p| {
        const top = @min(strip, p.frame.h);
        p.rect = .{ .x = p.frame.x, .y = p.frame.y + top, .w = p.frame.w, .h = p.frame.h - top };
        const w = @as(u32, @intFromFloat(p.rect.w)) -| pad.left -| pad.right;
        const h = @as(u32, @intFromFloat(p.rect.h)) -| pad.top -| pad.bottom;
        p.cols = @intCast(std.math.clamp(w / m.width, 1, std.math.maxInt(u16)));
        p.rows = @intCast(std.math.clamp(h / m.height, 1, std.math.maxInt(u16)));
        const spare_x = w -| @as(u32, p.cols) * m.width;
        const spare_y = h -| @as(u32, p.rows) * m.height;
        p.pad = .{
            .left = pad.left + spare_x / 2,
            .right = pad.right + spare_x - spare_x / 2,
            .top = pad.top + spare_y / 2,
            .bottom = pad.bottom + spare_y - spare_y / 2,
        };
        p.session.resize(p.*);
    }
}

/// The terminal area moved or changed size (or the cells did): fit every
/// pane's grid to it, and tell the daemons. The window draws after.
pub fn layout(self: *App, geometry: Geometry) void {
    self.geometry = geometry;
    // The tree is built for the frame; the window draws after. A menu's
    // anchor moved with everything else.
    self.markDirty();
    self.closeMenu();
    self.quiet_until = self.shell.tickCount() + resize_quiet_ms;
    for (self.tabs.items) |t| self.layoutTab(t);
    if (self.daemon) |conn| conn.resizeWorkspaces(self.daemonArea());
    for (self.remotes.items) |remote| if (remote.conn.attachState() == .attached) remote.conn.resizeWorkspaces(self.daemonArea());
}

/// A shell that does nothing and answers with constants, for an app
/// with no window.
pub const TestShell = struct {
    /// What `setTimer` and `killTimer` were last told, per timer.
    timers: std.EnumArray(Timer, ?u32) = .initFill(null),
    captured: bool = false,
    closed: bool = false,
    /// The window text last set, and how many times it was.
    title_buf: [64]u16 = undefined,
    title_len: usize = 0,
    titles: u32 = 0,

    fn captureMouse(ctx: *anyopaque) void {
        self_(ctx).captured = true;
    }
    fn releaseMouse(ctx: *anyopaque) void {
        self_(ctx).captured = false;
    }
    fn setTimer(ctx: *anyopaque, timer: Timer, ms: u32) void {
        self_(ctx).timers.set(timer, ms);
    }
    fn killTimer(ctx: *anyopaque, timer: Timer) void {
        self_(ctx).timers.set(timer, null);
    }
    fn postClose(ctx: *anyopaque) void {
        self_(ctx).closed = true;
    }
    fn setTitle(ctx: *anyopaque, text: [:0]const u16) void {
        const self = self_(ctx);
        self.title_len = @min(text.len, self.title_buf.len);
        @memcpy(self.title_buf[0..self.title_len], text[0..self.title_len]);
        self.titles += 1;
    }
    fn caption(_: *anyopaque, _: Id.Part) void {}
    fn maximized(_: *anyopaque) bool {
        return false;
    }
    fn tickCount(_: *anyopaque) u64 {
        return 1000;
    }
    fn keyDown(_: *anyopaque, _: i32) bool {
        return false;
    }
    fn mods(_: *anyopaque) input.Mods {
        return .{};
    }
    fn dragThreshold(_: *anyopaque) [2]i32 {
        return .{ 4, 4 };
    }
    fn hoverTime(_: *anyopaque) u32 {
        return 400;
    }
    fn caretBlinkTime(_: *anyopaque) ?u32 {
        return 500;
    }
    fn dropPendingChars(_: *anyopaque) void {}
    fn clipboardHasText(_: *anyopaque) bool {
        return false;
    }
    fn clipboardGet(_: *anyopaque, _: Allocator) anyerror!?[]u8 {
        return null;
    }
    fn clipboardSet(_: *anyopaque, _: []const u8) anyerror!void {}
    fn frameInterval(_: *anyopaque) u32 {
        return 0;
    }
    fn fontSize(_: *anyopaque) f32 {
        return 12;
    }
    fn setFontSize(_: *anyopaque, _: f32) void {}
    fn relayout(_: *anyopaque) void {}
    fn stats(_: *anyopaque) []const u16 {
        return &.{};
    }

    fn self_(ctx: *anyopaque) *TestShell {
        return @ptrCast(@alignCast(ctx));
    }

    const vtable: Shell.VTable = .{
        .captureMouse = captureMouse,
        .releaseMouse = releaseMouse,
        .setTimer = setTimer,
        .killTimer = killTimer,
        .postClose = postClose,
        .setTitle = setTitle,
        .caption = caption,
        .maximized = maximized,
        .tickCount = tickCount,
        .keyDown = keyDown,
        .mods = mods,
        .dragThreshold = dragThreshold,
        .hoverTime = hoverTime,
        .caretBlinkTime = caretBlinkTime,
        .dropPendingChars = dropPendingChars,
        .clipboardHasText = clipboardHasText,
        .clipboardGet = clipboardGet,
        .clipboardSet = clipboardSet,
        .frameInterval = frameInterval,
        .fontSize = fontSize,
        .setFontSize = setFontSize,
        .relayout = relayout,
        .stats = stats,
    };

    fn shell(self: *TestShell) Shell {
        return .{ .ctx = self, .vt = &vtable };
    }

    fn title(self: *const TestShell) []const u16 {
        return self.title_buf[0..self.title_len];
    }
};

/// An app with no window, daemon, or tabs, on `shell`.
pub const TestApp = struct {
    config: Config = .{ ._arena = .init(std.testing.allocator) },
    hosts: Hosts,
    shown: Shown,
    ui: Ui,
    frame: Ui.Frame,
    app: App = undefined,

    pub fn init(self: *TestApp, shell: *TestShell) !void {
        const alloc = std.testing.allocator;
        self.hosts = try Hosts.load(alloc, undefined, null);
        self.shown = try Shown.load(alloc, undefined, null);
        self.ui = .{ .scale = 1, .fonts = .none, .theme = .init(self.config.background, self.config.foreground) };
        self.frame = self.ui.frame(1000, 600);
        self.app = try App.init(.{
            .alloc = alloc,
            .config = &self.config,
            .local_command = &.{},
            .hosts = &self.hosts,
            .shown = &self.shown,
            .ui = &self.ui,
            .frame = &self.frame,
            .shell = shell.shell(),
            // Never posted to or set: there's no daemon or session.
            .hwnd = undefined,
            .output_event = undefined,
        });
    }

    pub fn deinit(self: *TestApp) void {
        self.app.deinit();
        self.shown.deinit();
        self.hosts.deinit();
        self.config.deinit();
    }
};

test "the connect field opens on its button, takes text, and closes on Escape" {
    var shell: TestShell = .{};
    var t: TestApp = .{ .hosts = undefined, .shown = undefined, .ui = undefined, .frame = undefined };
    try t.init(&shell);
    defer t.deinit();
    const app = &t.app;

    try std.testing.expectEqual(Keyboard.terminal, app.keyboard());
    try std.testing.expectEqual(Result.handled, app.update(.{ .click = .window(.connect) }));
    try std.testing.expect(app.mode == .connect);
    try std.testing.expect(app.dirty);
    app.dirty = false;

    _ = app.update(.{ .char = .{ .unit = 'h', .sys = false } });
    _ = app.update(.{ .char = .{ .unit = 'i', .sys = false } });
    try std.testing.expectEqualSlices(u16, L("hi"), app.keyboard().field().?.text());
    try std.testing.expect(app.dirty);
    // The view shows the field.
    try std.testing.expect(Ui.find(app.view(), .window(.connect)).?.kind == .text_field);

    try std.testing.expectEqual(Result.handled, app.update(.{ .key = .{ .msg = win32.WM_KEYDOWN, .wparam = win32.VK_ESCAPE, .lparam = 0 } }));
    try std.testing.expect(app.mode == .terminal);
    try std.testing.expectEqual(Keyboard.terminal, app.keyboard());
    try std.testing.expect(Ui.find(app.view(), .window(.connect)).?.kind == .button);
    // Its release goes nowhere, and alt+F4 is still Windows'.
    try std.testing.expectEqual(Result.handled, app.update(.{ .key = .{ .msg = win32.WM_KEYUP, .wparam = win32.VK_ESCAPE, .lparam = 0 } }));
    try std.testing.expectEqual(Result.default, app.update(.{ .key = .{ .msg = win32.WM_SYSKEYDOWN, .wparam = win32.VK_F4, .lparam = 0 } }));
}

test "the keyboard goes to the host field, a rename, or the kill dialog, one at a time" {
    var shell: TestShell = .{};
    var t: TestApp = .{ .hosts = undefined, .shown = undefined, .ui = undefined, .frame = undefined };
    try t.init(&shell);
    defer t.deinit();
    const app = &t.app;

    app.mode = .{ .connect = .{} };
    try std.testing.expect(app.keyboard() == .connect);
    try std.testing.expect(app.keyboard().field() != null);

    app.mode = .{ .rename = .{ .ws = 7, .field = .{} } };
    try std.testing.expect(app.keyboard() == .rename);
    try std.testing.expectEqual(&app.mode.rename.field, app.keyboard().field().?);

    app.mode = .{ .confirm = .{ .ws = 7, .dialog = .{ .icon = .warning, .title = &.{} } } };
    try std.testing.expect(app.keyboard() == .confirm);
    try std.testing.expect(app.keyboard().field() == null);
    try std.testing.expectEqual(&app.mode.confirm.dialog, app.activeDialog().?);
    try std.testing.expect(Ui.find(app.view(), .window(.scrim)) != null);
    // Text has nowhere to go, and isn't a terminal's.
    _ = app.update(.{ .char = .{ .unit = 'x', .sys = false } });

    // Opening one closes the others.
    app.mode = .{ .connect = .{} };
    app.closeConfirm();
    try std.testing.expect(app.mode == .connect);
    app.cancelRename();
    try std.testing.expect(app.mode == .connect);
    app.cancelConnect();
    try std.testing.expectEqual(Keyboard.terminal, app.keyboard());
}

test "a right click opens a workspace's menu, which the keyboard works and a click outside closes" {
    var shell: TestShell = .{};
    var t: TestApp = .{ .hosts = undefined, .shown = undefined, .ui = undefined, .frame = undefined };
    try t.init(&shell);
    defer t.deinit();
    const app = &t.app;
    const alloc = std.testing.allocator;
    try app.workspaces.append(alloc, .{ .id = 7, .name = try alloc.dupe(u16, L("alpha")), .tabs = 2, .viewers = 1, .shown = false });

    const row = Ui.find(app.view(), .{ .target = .{ .workspace = 7 } }).?.rect;
    const at: win32.POINT = .{ .x = @intFromFloat(row.x + 30), .y = @intFromFloat(row.y + 5) };
    _ = app.update(.{ .context_menu = at });
    try std.testing.expect(app.mode == .menu);
    try std.testing.expect(app.keyboard() == .menu);
    const m = &app.mode.menu;
    try std.testing.expectEqual(Id.Target{ .workspace = 7 }, m.target);
    // New tab, Show (it's hidden), Rename, and Kill, in groups.
    try std.testing.expectEqual(@as(usize, 6), m.count);
    try std.testing.expectEqualSlices(u16, L("Show"), m.entry(2).?.label);
    try std.testing.expectEqual(Id.Part.show, m.entry(2).?.action.part);
    try std.testing.expect(m.entry(5).?.danger);
    try std.testing.expectEqual(@as(?usize, null), m.focus);
    // The box is at the click, and the window around it is its scrim.
    const built = app.view();
    const box = Ui.find(built, .window(.menu)).?.rect;
    try std.testing.expectEqual(@as(f32, @floatFromInt(at.x)), box.x);
    try std.testing.expectEqual(Id.window(.scrim), app.hitAt(.{ .x = 500, .y = 300 }));

    // Down goes to the first entry; the mouse over another moves it.
    _ = app.update(.{ .key = .{ .msg = win32.WM_KEYDOWN, .wparam = win32.VK_DOWN, .lparam = 0 } });
    try std.testing.expectEqual(@as(?usize, 0), m.focus);
    const second = Ui.find(app.view(), .window(.menu)).?.rect;
    _ = app.update(.{ .mouse = .{ .msg = win32.WM_MOUSEMOVE, .wparam = 0, .pos = .{ .x = @intFromFloat(second.x + 20), .y = @intFromFloat(second.y + 6 + 28 + 9 + 5) } } });
    try std.testing.expectEqual(@as(?usize, 2), m.focus);
    try std.testing.expect(app.ui.hover.eql(.{ .target = .{ .menu = 2 } }));

    // Escape closes it; a press outside does too, and goes no further.
    _ = app.update(.{ .key = .{ .msg = win32.WM_KEYDOWN, .wparam = win32.VK_ESCAPE, .lparam = 0 } });
    try std.testing.expect(app.mode == .terminal);
    _ = app.update(.{ .context_menu = at });
    try std.testing.expect(app.mode == .menu);
    _ = app.update(.{ .mouse = .{ .msg = win32.WM_LBUTTONDOWN, .wparam = win32.MK_LBUTTON, .pos = .{ .x = 500, .y = 300 } } });
    try std.testing.expect(app.mode == .terminal);
    try std.testing.expect(!shell.captured);

    // Losing focus closes it, and so does its workspace going away.
    _ = app.update(.{ .focus = true });
    _ = app.update(.{ .context_menu = at });
    _ = app.update(.{ .focus = false });
    try std.testing.expect(app.mode == .terminal);
    _ = app.update(.{ .context_menu = at });
    app.workspaceGone(7);
    try std.testing.expect(app.mode == .terminal);
    // Nothing there: no menu.
    _ = app.update(.{ .context_menu = .{ .x = 500, .y = 300 } });
    try std.testing.expect(app.mode == .terminal);
}

test "choosing a menu entry clicks the control, after the menu has closed" {
    var shell: TestShell = .{};
    var t: TestApp = .{ .hosts = undefined, .shown = undefined, .ui = undefined, .frame = undefined };
    try t.init(&shell);
    defer t.deinit();
    const app = &t.app;
    const alloc = std.testing.allocator;
    try app.workspaces.append(alloc, .{ .id = 7, .name = try alloc.dupe(u16, L("alpha")), .tabs = 0, .viewers = 1, .shown = true });

    app.openMenu(.{ .workspace = 7 }, .{ .point = .{ .x = 100, .y = 100 } });
    // Rename is the fourth item: Enter on it edits the name in the row.
    app.mode.menu.focus = 3;
    try std.testing.expectEqualSlices(u16, L("Rename"), app.mode.menu.entry(3).?.label);
    _ = app.update(.{ .key = .{ .msg = win32.WM_KEYDOWN, .wparam = win32.VK_RETURN, .lparam = 0 } });
    try std.testing.expect(app.mode == .rename);
    try std.testing.expectEqual(@as(u32, 7), app.mode.rename.ws);
    try std.testing.expectEqualSlices(u16, L("alpha"), app.mode.rename.field.text());
    // Opening a menu ends the rename.
    app.openMenu(.{ .workspace = 7 }, .{ .point = .{ .x = 100, .y = 100 } });
    try std.testing.expect(app.mode == .menu);
    // A click on an entry chooses it too: Hide, as the workspace is shown.
    try std.testing.expectEqualSlices(u16, L("Hide"), app.mode.menu.entry(2).?.label);
    _ = app.update(.{ .click = .{ .target = .{ .menu = 2 } } });
    try std.testing.expect(app.mode == .terminal);
    // A disabled entry can't be chosen.
    _ = try app.hosts.add(L("ssh://devbox"));
    app.openMenu(.{ .host = 0 }, .{ .point = .{ .x = 100, .y = 100 } });
    try std.testing.expect(!app.mode.menu.entry(2).?.disabled);
    app.mode.menu.items[2].entry.disabled = true;
    _ = app.update(.{ .click = .{ .target = .{ .menu = 2 } } });
    try std.testing.expect(app.mode == .menu);
    try std.testing.expectEqual(@as(usize, 1), app.hosts.items.items.len);
}

test "the blink timer toggles the phase and redraws only what blinks" {
    var shell: TestShell = .{};
    var t: TestApp = .{ .hosts = undefined, .shown = undefined, .ui = undefined, .frame = undefined };
    try t.init(&shell);
    defer t.deinit();
    const app = &t.app;

    // Nothing on screen blinks: the phase moves, nothing is drawn.
    try std.testing.expect(app.blink_visible);
    _ = app.update(.{ .tick = .blink });
    try std.testing.expect(!app.blink_visible);
    try std.testing.expect(!app.dirty);
    _ = app.update(.{ .tick = .blink });
    try std.testing.expect(app.blink_visible);
    try std.testing.expect(!app.dirty);

    // A field's caret blinks.
    app.mode = .{ .connect = .{} };
    _ = app.update(.{ .tick = .blink });
    try std.testing.expect(!app.blink_visible);
    try std.testing.expect(app.dirty);
    try std.testing.expect(!Ui.find(app.view(), .window(.connect)).?.kind.text_field.caret);

    // Focus starts the timer at the system's rate, in the on phase, and
    // losing it stops the timer.
    app.dirty = false;
    _ = app.update(.{ .focus = true });
    try std.testing.expect(app.blink_visible);
    try std.testing.expectEqual(@as(?u32, 500), shell.timers.get(.blink));
    _ = app.update(.{ .focus = false });
    try std.testing.expectEqual(@as(?u32, null), shell.timers.get(.blink));
}

test "the tabs can all go and a new one come while the active index is past them" {
    var shell: TestShell = .{};
    var t: TestApp = .{ .hosts = undefined, .shown = undefined, .ui = undefined, .frame = undefined };
    try t.init(&shell);
    defer t.deinit();
    const app = &t.app;

    // The first tab is shown and titled as it comes.
    try app.spawnFailed("a", error.A);
    try std.testing.expect(app.dirty);
    try std.testing.expectEqual(@as(u32, 1), shell.titles);
    try std.testing.expectEqualSlices(u16, app_name, shell.title());
    try std.testing.expectEqual(@as(usize, 1), app.placed().panes.items.len);
    // A second takes over, as a workspace's second tab would.
    try app.spawnFailed("b", error.B);
    try std.testing.expectEqual(@as(usize, 1), app.active);

    // slime's reader couldn't start: the tabs go, and a tab says why.
    app.destroyTabs();
    try std.testing.expectEqual(@as(usize, 0), app.active);
    try std.testing.expect(app.focusedSession() == null);
    try std.testing.expectEqual(@as(usize, 0), app.placed().panes.items.len);
    app.dirty = false;
    try app.spawnFailed("c", error.C);
    try std.testing.expectEqual(@as(usize, 1), app.tabs.items.len);
    try std.testing.expectEqual(app.activeTab().focus, app.focusedSession().?);
    try std.testing.expect(app.dirty);
    try std.testing.expectEqual(app.activeTab().focus, app.placed().panes.items[0].session);

    // A capture released while `active` points past the tabs (as it can
    // for a moment while they change) comes back harmlessly.
    app.active = 5;
    app.mouse_in_terminal = true;
    _ = app.update(.capture_lost);
    try std.testing.expect(!app.mouse_in_terminal);
    try std.testing.expect(app.focusedSession() == null);
    app.active = 0;
}

test "dragging the sidebar's edge resizes it, within its range" {
    var shell: TestShell = .{};
    var t: TestApp = .{ .hosts = undefined, .shown = undefined, .ui = undefined, .frame = undefined };
    try t.init(&shell);
    defer t.deinit();
    const app = &t.app;

    const edge: i32 = @intFromFloat(t.frame.sidebar.right());
    const y: i32 = 300;
    try std.testing.expectEqual(Cursor.size_we, app.cursor(.{ .x = edge - 2, .y = y }));
    _ = app.update(.{ .mouse = .{ .msg = win32.WM_LBUTTONDOWN, .wparam = win32.MK_LBUTTON, .pos = .{ .x = edge, .y = y } } });
    try std.testing.expect(app.sidebar_drag != null);
    try std.testing.expect(shell.captured);
    _ = app.update(.{ .mouse = .{ .msg = win32.WM_MOUSEMOVE, .wparam = win32.MK_LBUTTON, .pos = .{ .x = edge + 60, .y = y } } });
    try std.testing.expectEqual(@as(f32, Ui.default_sidebar_width + 60), app.ui.sidebar_width);
    // Dragged past the window, the sidebar stops at its widest.
    _ = app.update(.{ .mouse = .{ .msg = win32.WM_MOUSEMOVE, .wparam = win32.MK_LBUTTON, .pos = .{ .x = 2000, .y = y } } });
    try std.testing.expectEqual(@as(f32, Ui.max_sidebar_width), app.ui.sidebar_width);
    try std.testing.expectEqual(Cursor.size_we, app.cursor(.{ .x = 2000, .y = y }));
    // And no narrower than its least.
    _ = app.update(.{ .mouse = .{ .msg = win32.WM_MOUSEMOVE, .wparam = win32.MK_LBUTTON, .pos = .{ .x = -100, .y = y } } });
    try std.testing.expectEqual(@as(f32, Ui.min_sidebar_width), app.ui.sidebar_width);
    _ = app.update(.{ .mouse = .{ .msg = win32.WM_LBUTTONUP, .wparam = 0, .pos = .{ .x = -100, .y = y } } });
    try std.testing.expect(app.sidebar_drag == null);
    try std.testing.expect(!shell.captured);
    try std.testing.expectEqual(@as(f32, Ui.min_sidebar_width), app.ui.frame(1000, 600).sidebar.w);
}

test "a mouse move builds the tree at most once, even with a frame pending" {
    var shell: TestShell = .{};
    var t: TestApp = .{ .hosts = undefined, .shown = undefined, .ui = undefined, .frame = undefined };
    try t.init(&shell);
    defer t.deinit();
    const app = &t.app;

    const button = Ui.find(app.view(), .window(.connect)).?.rect;
    const pos: win32.POINT = .{ .x = @intFromFloat(button.x + 2), .y = @intFromFloat(button.y + 2) };
    // Output arrived: a frame is due, but the tree still shows what's
    // there.
    app.dirty = true;
    var before = app.views;
    _ = app.update(.{ .mouse = .{ .msg = win32.WM_MOUSEMOVE, .wparam = 0, .pos = pos } });
    try std.testing.expect(app.ui.hover.eql(.window(.connect)));
    // Once: the hover changed what the tree shows.
    try std.testing.expectEqual(before + 1, app.views);
    // Still over it: nothing changed, so nothing is built.
    before = app.views;
    _ = app.update(.{ .mouse = .{ .msg = win32.WM_MOUSEMOVE, .wparam = 0, .pos = pos } });
    _ = app.cursor(pos);
    try std.testing.expectEqual(before, app.views);
}
