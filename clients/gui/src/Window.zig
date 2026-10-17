//! A top-level Win32 window: our own title bar and tab list (see
//! `Chrome`) around the active tab's panes, each a session's terminal. Heap allocated so that
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
const Tab = @import("Tab.zig");
const Daemon = @import("Daemon.zig");
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

/// Posted from slime's reader when a session's pane ends: its child
/// exited, or the pane was lost to us. WPARAM is the session's ID, as for
/// the messages below.
pub const WM_APP_CHILD_EXITED = win32.WM_APP + 0;
/// Posted from a reader thread when the child sets the title.
pub const WM_APP_TITLE_CHANGED = win32.WM_APP + 1;
/// Posted from a reader thread when the child writes the clipboard, or
/// a copy's text comes.
pub const WM_APP_CLIPBOARD_WRITE = win32.WM_APP + 2;
/// Posted from a daemon connection's reader when panes arrive for
/// sessions (`Daemon.take`), and when a host's has attached or failed
/// to.
pub const WM_APP_DAEMON = win32.WM_APP + 4;

/// Room for the stats report, in UTF-16 units.
const max_stats_len = 160;

const stats_timer_id = 1;
/// Draws pending output while DefWindowProc's modal move/size loop runs
/// instead of ours.
const sizemove_timer_id = 2;
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
const split_right_key = binding.label(&binding.defaults, .{ .new_split = .right });
const split_down_key = binding.label(&binding.defaults, .{ .new_split = .down });
const zoom_key = binding.label(&binding.defaults, .toggle_split_zoom);

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

/// Never empty once created: closing the last tab closes the window.
/// Grouped as the sidebar shows them: local tabs first, then each
/// connection's together.
tabs: std.ArrayList(*Tab) = .empty,
/// The tab shown. Its focused pane gets input.
active: usize = 0,
next_session_id: u32 = 1,
/// Scratch for `view`, with room for every group.
view_tabs: std.ArrayList(Chrome.View.Tab) = .empty,
view_tab_panes: std.ArrayList(Chrome.View.TabPane) = .empty,
view_groups: std.ArrayList(Chrome.View.Group) = .empty,
view_panes: std.ArrayList(Chrome.View.Pane) = .empty,
view_dividers: std.ArrayList(Chrome.Rect) = .empty,
/// The active tab's panes on screen, as `view` lists them.
shown: std.ArrayList(*Session) = .empty,
/// Scratch for `render`.
frame_panes: std.ArrayList(Renderer.Pane) = .empty,

/// Auto-reset event slime's readers set after handing a session a
/// frame (or program status). The message loop waits on it alongside
/// messages and calls `outputArrived`. Not a posted message: those are
/// retrieved before input and timers, so a steady stream of them starves
/// the keyboard.
output_event: win32.HANDLE,

/// Something changed since the last frame. UI thread only.
dirty: bool = false,

/// The window has keyboard focus.
focused: bool = false,

/// The on phase of the cursor blink.
blink_visible: bool = true,

/// The host being typed after "Connect" was clicked. Takes the keyboard
/// while set.
connect_field: ?Chrome.TextField = null,

/// The connection to slime: local sessions are panes of the workspace
/// it holds for this window. Null if it couldn't be reached.
daemon: ?*Daemon = null,
/// Connections to slime on SSH hosts, bridged through the local daemon:
/// a host's sessions are panes of the workspace its slime holds for
/// this window.
remotes: std.ArrayList(Remote) = .empty,
/// The hosts the local daemon knows, by its id for each, as it last
/// reported them (`hostsChanged`). Matched to the remembered list by
/// destination. Entries stay while the window lives: logins borrow their
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
/// The tab a middle click went down on, to close it on release.
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
    rect: Chrome.Rect,
};

/// A host's slime, bridged through the local daemon. A session stands in
/// for its panes until they come (`standIn`).
const Remote = struct {
    conn: *Daemon,
    /// The daemon's id for the host.
    host: u32,
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

/// Create the window, attaching the workspace slime kept for it, or a
/// new one running `command_line` (CreateProcessW syntax). An `ssh://`
/// URL opens that host instead, and is remembered in `hosts`. Local
/// sessions opened later run `local_command`.
pub fn create(alloc: Allocator, io: std.Io, config: *const Config, hosts: *Hosts, command_line: []const u16, local_command: []const u16) !*Window {
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
        .local_command = local_command,
        .hosts = hosts,
        .output_event = output_event,
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
    // Hosts are reached through the local daemon too, so a host URL still
    // attaches the local workspace, and opens the host beside it.
    const ssh_scheme = std.unicode.utf8ToUtf16LeStringLiteral("ssh://");
    const on_host = std.mem.startsWith(u16, command_line, ssh_scheme);
    try self.connectDaemon(if (on_host) local_command else command_line);
    errdefer self.destroyTabs();
    if (self.daemon) |conn| conn.hostList();
    if (on_host) try self.openOnHost(try hosts.add(command_line));
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
        self.destroyTabs();
        r.deinit();
        self.chrome.deinit();
        self.grid.deinit();
    }
    // Hanging up detaches the workspace; slime keeps it for the next
    // window.
    if (self.daemon) |conn| conn.deinit();
    for (self.remotes.items) |r| r.conn.deinit();
    self.remotes.deinit(self.alloc);
    for (self.host_states.items) |e| {
        self.alloc.free(e.dest);
        self.alloc.free(e.text);
    }
    self.host_states.deinit(self.alloc);
    self.view_tabs.deinit(self.alloc);
    self.view_tab_panes.deinit(self.alloc);
    self.view_groups.deinit(self.alloc);
    self.view_panes.deinit(self.alloc);
    self.view_dividers.deinit(self.alloc);
    self.shown.deinit(self.alloc);
    self.frame_panes.deinit(self.alloc);
    _ = win32.CloseHandle(self.output_event);
    self.alloc.destroy(self);
}

fn destroyTabs(self: *Window) void {
    for (self.tabs.items) |t| self.destroyTab(t);
    self.tabs.clearAndFree(self.alloc);
}

/// Free a tab and its sessions, which only lets go of daemon panes.
fn destroyTab(self: *Window, t: *Tab) void {
    var it = t.iterator();
    while (it.next()) |s| s.destroy();
    t.destroy(self.alloc);
}

pub fn activeTab(self: *const Window) *Tab {
    return self.tabs.items[self.active];
}

/// The active tab's focused pane, which gets input.
pub fn activeSession(self: *const Window) *Session {
    return self.activeTab().focus;
}

const Found = struct { tab: usize, s: *Session };

/// The session `id` names, and its tab.
fn findSession(self: *const Window, id: u32) ?Found {
    for (self.tabs.items, 0..) |t, i| {
        if (t.findSession(id)) |s| return .{ .tab = i, .s = s };
    }
    return null;
}

/// The session showing `conn`'s pane `id`.
fn daemonSession(self: *const Window, conn: *Daemon, id: u32) ?*Session {
    for (self.tabs.items) |t| {
        if (t.conn != conn) continue;
        if (t.findPane(id)) |s| return s;
    }
    return null;
}

fn tabIndex(self: *const Window, t: *const Tab) ?usize {
    return std.mem.indexOfScalar(*Tab, self.tabs.items, @constCast(t));
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

/// Connect to slime and attach the workspace detached last (a new one
/// running `command` if none), making a tab of each of its tabs. If that
/// fails, a tab says why.
fn connectDaemon(self: *Window, command: []const u16) !void {
    const conn = Daemon.connect(self.alloc, .{ .hwnd = self.hwnd.?, .msg = WM_APP_DAEMON }, self.frameInterval(), self.daemonArea(), self.daemonSize(), command) catch |err| {
        log.err("connecting to slime failed: {}", .{err});
        return self.spawnFailed("couldn't start slime", err);
    };
    self.daemon = conn;
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
fn spawnFailed(self: *Window, what: []const u8, err: anyerror) !void {
    var buf: [256]u8 = undefined;
    const why = std.fmt.bufPrint(&buf, "{s}: {t}", .{ what, err }) catch what;
    try self.spawnSession(.{ .failed = .{ .title = std.unicode.utf8ToUtf16LeStringLiteral("slime"), .why = why } });
}

/// The least time between a pane's frames to ask slime for, in
/// microseconds: the display's refresh period.
fn frameInterval(self: *const Window) u32 {
    const r = &(self.renderer orelse return 0);
    return std.math.cast(u32, @divTrunc(r.refresh_period, 10)) orelse 0;
}

/// Take up what `conn` sent: make sessions of the panes that arrived,
/// and lay out tabs as its workspace has them, focused as slime says: a
/// pane we asked for (a new tab or split) is shown and focused; a
/// script's is added without taking focus.
fn daemonChanged(self: *Window, conn: *Daemon) void {
    var taken = conn.take();
    defer taken.deinit(self.alloc);

    var arrived: std.AutoHashMapUnmanaged(u32, *Session) = .empty;
    defer arrived.deinit(self.alloc);
    for (taken.arrivals) |*a| {
        const s = self.createSession(.{ .daemon = .{ .conn = conn, .arrival = a } }, self.gridSize()) catch |err| {
            log.err("showing daemon pane {d} failed: {}", .{ a.pane, err });
            conn.release(a.pane);
            continue;
        };
        arrived.put(self.alloc, a.pane, s) catch {
            s.destroy();
            continue;
        };
    }
    if (taken.structure) |st| self.applyStructure(conn, st, &arrived) catch |err| log.err("laying out slime's tabs failed: {}", .{err});
    // Panes no tab holds (which slime doesn't send) aren't shown.
    var left = arrived.valueIterator();
    while (left.next()) |s| s.*.destroy();

    if (self.tabs.items.len == 0) {
        // Every pane is gone: so is the window.
        _ = win32.PostMessageW(self.hwnd, win32.WM_CLOSE, 0, 0);
        return;
    }
    self.dirty = true;
}

/// Lay out `conn`'s tabs as `st` has them, in its order: replace the
/// trees of tabs we have, add tabs we don't, and drop tabs and panes it
/// no longer has. Its focus is slime's, shared with every window on the
/// workspace: each tab's focused and zoomed pane, and the tab shown,
/// which is followed when one of `conn`'s tabs is the one shown here.
/// Sessions placed from `arrived` are taken out of it.
fn applyStructure(self: *Window, conn: *Daemon, st: *const Daemon.Structure, arrived: *std.AutoHashMapUnmanaged(u32, *Session)) !void {
    const alloc = self.alloc;
    self.cancelDrag();
    const was_active: ?*Tab = if (self.tabs.items.len > 0) self.activeTab() else null;
    const was_focus: ?*Session = if (was_active) |t| t.focus else null;
    const shown_conn: ?*Daemon = if (was_active) |t| t.conn else null;

    const Lookup = struct {
        window: *Window,
        conn: *Daemon,
        arrived: *std.AutoHashMapUnmanaged(u32, *Session),
        pub fn session(l: @This(), id: u32) ?*Session {
            return l.arrived.get(id) orelse l.window.daemonSession(l.conn, id);
        }
    };
    const lookup: Lookup = .{ .window = self, .conn = conn, .arrived = arrived };
    const roots = try alloc.alloc(?Tab.Node, st.tabs.len);
    defer alloc.free(roots);
    @memset(roots, null);
    defer for (roots) |r| if (r) |n| Tab.freeNode(alloc, n);
    var used: std.AutoHashMapUnmanaged(*Session, void) = .empty;
    defer used.deinit(alloc);
    for (st.tabs, roots) |lt, *root| {
        root.* = try Tab.fromLayout(alloc, lt.root, lookup);
        const node = root.* orelse continue;
        var walk: Tab = .{ .id = 0, .root = node, .focus = Tab.first(node) };
        var it = walk.iterator();
        while (it.next()) |s| try used.put(alloc, s, {});
    }
    try self.tabs.ensureUnusedCapacity(alloc, st.tabs.len);

    // Panes of ours slime no longer has, freed once no tree holds them.
    var dropped: std.ArrayList(*Session) = .empty;
    defer dropped.deinit(alloc);
    for (self.tabs.items) |t| {
        if (t.conn != conn) continue;
        var it = t.iterator();
        while (it.next()) |s| if (!used.contains(s)) try dropped.append(alloc, s);
    }

    // This daemon's tabs as slime orders them: ours with their new trees,
    // and new ones. Each takes slime's focus, unless a focus call of ours
    // is still out, which it may predate.
    var ordered: std.ArrayList(*Tab) = .empty;
    defer ordered.deinit(alloc);
    try ordered.ensureTotalCapacity(alloc, st.tabs.len);
    for (st.tabs, roots) |lt, *root| {
        const node = root.* orelse continue;
        const t = for (self.tabs.items) |t| {
            if (t.conn != conn or t.id != lt.id) continue;
            t.setRoot(alloc, node);
            break t;
        } else try Tab.create(alloc, conn, lt.id, node, Tab.first(node));
        root.* = null;
        ordered.appendAssumeCapacity(t);
        if (st.focus_known) {
            if (t.findPane(lt.focus)) |s| t.focus = s;
            t.zoom = if (lt.zoomed != 0) t.findPane(lt.zoomed) else null;
            t.sent_focus = focusOf(t);
        }
    }
    // They go where this daemon's tabs were, else at the end of their
    // group; the tabs slime no longer has go.
    var at: ?usize = null;
    var i: usize = 0;
    while (i < self.tabs.items.len) {
        const t = self.tabs.items[i];
        if (t.conn != conn) {
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
        if (self.mouse_in_terminal) _ = win32.ReleaseCapture();
        self.mouse_in_terminal = false;
    };
    for (dropped.items) |s| s.destroy();
    var placed = used.keyIterator();
    while (placed.next()) |s| if (s.*.daemonPane()) |id| {
        _ = arrived.remove(id);
    };

    _ = self.chrome.setHover(.none);
    self.middle_pressed = null;
    for (self.tabs.items) |t| self.layoutTab(t);
    if (self.tabs.items.len == 0) return;

    // Where the active tab was, if it's still here; else the one in its
    // place. slime's active tab is followed while this daemon's tabs are
    // what's shown: a tab of another daemon (a host's) stays.
    const still: ?usize = if (was_active) |t| self.tabIndex(t) else null;
    var active = still orelse @min(self.active, self.tabs.items.len - 1);
    if (st.focus_known) {
        conn.active_tab = st.active_tab;
        if (still == null or shown_conn == conn) for (self.tabs.items, 0..) |t, k| {
            if (t.conn == conn and t.id == st.active_tab) active = k;
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
        .pane = t.focus.daemonPane() orelse 0,
        .zoomed = if (t.zoom) |z| z.daemonPane() orelse 0 else 0,
    };
}

/// Tell the active tab's daemon where the focus is, if that's news to
/// it: the tab shown, its focused pane, and its zoom. Every other window
/// on the workspace follows. After anything that moves them.
fn syncFocus(self: *Window) void {
    if (self.tabs.items.len == 0) return;
    const t = self.activeTab();
    const conn = t.conn orelse return;
    const f = focusOf(t);
    if (f.pane == 0) return;
    if (conn.active_tab == t.id and t.sent_focus != null and std.meta.eql(t.sent_focus.?, f)) return;
    conn.active_tab = t.id;
    t.sent_focus = f;
    conn.focus(f) catch |err| log.warn("telling slime the focus failed: {}", .{err});
}

/// The grid a daemon pane gets: the terminal area, as for any session.
fn daemonSize(self: *const Window) Daemon.Size {
    const grid = self.gridSize();
    const cell = self.cellSizePx();
    return .{ .cols = grid.cols, .rows = grid.rows, .cell_width = cell.width, .cell_height = cell.height };
}

/// The pixels a tab's panes share, inside the padding, and the cell size
/// of panes that haven't said their own.
fn daemonArea(self: *const Window) Daemon.Area {
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

/// Start a session on `target` in a tab of its own, at the end of its
/// group, and show it.
fn spawnSession(self: *Window, target: Target) !void {
    try self.tabs.ensureUnusedCapacity(self.alloc, 1);
    try self.reserveGroups();
    const s = try self.createSession(target, self.gridSize());
    const t = Tab.create(self.alloc, null, 0, .{ .pane = s }, s) catch |err| {
        s.kill();
        s.destroy();
        return err;
    };
    const at = self.groupEnd(self.groupOf(t));
    self.tabs.insertAssumeCapacity(at, t);
    self.layoutTab(t);
    if (self.tabs.items.len == 1) return;
    // The rows from `at` on moved down.
    if (at <= self.active) self.active += 1;
    _ = self.chrome.setHover(.none);
    self.middle_pressed = null;
    self.activate(at);
}

/// Start a session on `target` with a grid of `size`.
fn createSession(self: *Window, target: Target, size: GridSize) !*Session {
    const launch: Session.Launch = switch (target) {
        .daemon => |sl| .{ .daemon = .{ .conn = sl.conn, .arrival = sl.arrival } },
        .waiting => |dest| .{ .waiting = .{ .dest = dest, .title = Hosts.label(dest) } },
        .failed => |f| .{ .failed = .{ .title = f.title, .why = f.why } },
    };
    return Session.create(self, self.nextSessionId(), launch, size.cols, size.rows);
}

/// A new session id. Channel ids are session ids, and the helper takes 0
/// to mean the connection.
fn nextSessionId(self: *Window) u32 {
    if (self.next_session_id == 0) self.next_session_id = 1;
    const id = self.next_session_id;
    self.next_session_id +%= 1;
    return id;
}

/// Room in `view`'s scratch for Local and every host.
fn reserveGroups(self: *Window) !void {
    try self.view_groups.ensureTotalCapacity(self.alloc, 1 + self.hosts.items.items.len);
}

/// The sidebar group `t` is listed in: 0 for Local, else 1 plus its
/// host's index. Tabs are kept in group order.
fn groupOf(self: *const Window, t: *const Tab) usize {
    const dest = t.focus.hostDest() orelse return 0;
    // A host isn't forgotten while sessions use it.
    return 1 + (self.hosts.indexOf(dest) orelse return 0);
}

/// Where a tab in group `g` goes: after the group's last.
fn groupEnd(self: *const Window, g: usize) usize {
    var i: usize = 0;
    while (i < self.tabs.items.len and self.groupOf(self.tabs.items[i]) <= g) i += 1;
    return i;
}

/// What the daemon knows of the host at `dest`, if anything.
fn hostEntry(self: *Window, dest: []const u16) ?*HostEntry {
    for (self.host_states.items) |*e| {
        if (std.mem.eql(u16, e.dest, dest)) return e;
    }
    return null;
}

fn hostEntryById(self: *Window, id: u32) ?*HostEntry {
    for (self.host_states.items) |*e| {
        if (e.id == id) return e;
    }
    return null;
}

/// The daemon holds a connection to remembered host `h`, or is making
/// one.
fn hostLive(self: *Window, h: usize) bool {
    const e = self.hostEntry(self.hosts.items.items[h]) orelse return false;
    return e.state == .connected or e.state == .connecting;
}

/// The session standing in for host `dest`'s panes, while one does.
fn standIn(self: *const Window, dest: []const u16) ?Found {
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

/// A tab in the active tab's group.
fn newSession(self: *Window) void {
    self.newSessionIn(self.groupOf(self.activeTab()));
}

/// A tab in sidebar group `g`: a local one, or one on a host.
fn newSessionIn(self: *Window, g: usize) void {
    if (g != 0) return self.openOnHost(g - 1) catch |err| log.err("new session failed: {}", .{err});
    // The tab comes when its pane does (WM_APP_DAEMON).
    const conn = self.daemon orelse return self.connectDaemon(self.local_command) catch |err| log.err("new session failed: {}", .{err});
    if (conn.isLost()) {
        // Its tabs say how; slime comes back with the next window.
        return self.spawnFailed("lost slime", error.Disconnected) catch |err| log.err("new session failed: {}", .{err});
    }
    conn.tabNew(self.local_command, self.daemonSize()) catch |err| log.err("new tab in slime failed: {}", .{err});
}

/// A session on remembered host `h`: a tab of the workspace the host's
/// slime holds for us, through the daemon we're attached to there, or
/// else one we bridge to, once the daemon has the host connected. Until
/// then a session stands in, where logging in asks what it needs; the
/// panes replace it once they come (`remoteChanged`). A host the daemon
/// can't connect, or slime can't run on, gets the reason there; ssh.exe
/// in a local tab still reaches it.
fn openOnHost(self: *Window, h: usize) !void {
    const dest = self.hosts.items.items[h];
    if (self.remoteOn(dest)) |r| switch (r.conn.attachState()) {
        // The tab comes when its pane does (WM_APP_DAEMON).
        .attached => return r.conn.tabNew(&.{}, self.daemonSize()),
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
fn remoteOn(self: *Window, dest: []const u16) ?*Remote {
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
fn bridgeHost(self: *Window, e: *HostEntry) !void {
    try self.remotes.ensureUnusedCapacity(self.alloc, 1);
    const found = self.standIn(e.dest) orelse found: {
        try self.spawnSession(.{ .waiting = e.dest });
        break :found self.standIn(e.dest).?;
    };
    const s = found.s;
    if (s.login != null) self.closeLogin(s);
    const remote = Daemon.connectRemote(self.alloc, .{ .hwnd = self.hwnd.?, .msg = WM_APP_DAEMON }, self.frameInterval(), e.id, e.dest, Session.sshTerm(self.config), self.daemonArea(), self.daemonSize()) catch |err| {
        log.err("bridging to slime on {f} failed: {}", .{ std.unicode.fmtUtf16Le(e.dest), err });
        s.showEnded(@errorName(err));
        return;
    };
    self.remotes.appendAssumeCapacity(.{ .conn = remote, .host = e.id });
}

/// Take up what slime connections posted: panes that arrived, what the
/// daemon said about hosts, and how attaching to hosts' went.
fn daemonPosted(self: *Window) void {
    if (self.daemon) |conn| {
        self.daemonChanged(conn);
        self.hostsChanged(conn);
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

/// Take up what host's slime `r` sent. Once its panes have come, they
/// replace the session that stood in for them, and the tabs of daemons
/// we lost on the host, which showed the same panes as they were.
fn remoteChanged(self: *Window, r: *Remote) void {
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
fn remoteFailed(self: *Window, i: usize) void {
    const r = self.remotes.orderedRemove(i);
    // After the stand-in is done with the failure's text.
    defer r.conn.deinit();
    const found = self.standIn(r.conn.hostDest().?) orelse return;
    self.dirty = true;
    found.s.showEnded(r.conn.failure.text());
}

/// Let go of hosts' daemons nothing shows any more: one whose stand-in
/// was closed before its panes came, or whose tabs have all gone.
fn pruneRemotes(self: *Window) void {
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
        self.remotes.orderedRemove(i).conn.deinit();
    }
}

/// Take up what the daemon said about hosts: keep each host's state,
/// show its prompts and status in the session standing in for it, and
/// bridge to it once it's connected.
fn hostsChanged(self: *Window, conn: *Daemon) void {
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
    self.dirty = true;
}

/// Record host `h`'s state, and act on it for the session standing in
/// for the host, if one does.
fn hostState(self: *Window, h: Daemon.HostInfo) void {
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
    self.dirty = true;

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
fn loginFor(self: *Window, s: *Session, e: *const HostEntry) ?*Login {
    if (s.login) |l| return l;
    s.login = Login.create(self.alloc, Hosts.label(e.dest)) catch return null;
    return s.login;
}

/// A stand-in is closing: if the daemon is logging in to its host for
/// us, give up on that.
fn standInClosing(self: *Window, s: *Session) void {
    if (s.daemonPane() != null or s.ended) return;
    const dest = s.hostDest() orelse return;
    const e = self.hostEntry(dest) orelse return;
    const daemon = self.daemon orelse return;
    if (e.state == .connecting and e.ours) daemon.hostDisconnect(e.id);
}

/// What a new pane in `conn` runs: the local command, or for a host's,
/// its shell.
fn daemonCommand(self: *const Window, conn: *const Daemon) []const u16 {
    return if (conn.host() == null) self.local_command else &.{};
}

/// Split the active tab's pane `s`, starting a shell on side `dir` of
/// it. The new pane comes from slime (WM_APP_DAEMON).
fn splitPane(self: *Window, s: *Session, dir: Daemon.Direction) void {
    const pane = s.daemonPane() orelse return;
    const t = self.activeTab();
    const conn = t.conn orelse return;
    if (t.zoom != null) {
        t.zoom = null;
        self.layoutTab(t);
        self.syncFocus();
    }
    conn.split(pane, dir, self.daemonCommand(conn)) catch |err| log.err("split failed: {}", .{err});
    self.dirty = true;
}

/// Zoom the active tab's pane `s` to fill the tab, or unzoom it.
fn toggleZoom(self: *Window, s: *Session) void {
    const t = self.activeTab();
    t.zoom = if (t.zoom == s) null else s;
    self.focusPane(s);
    _ = self.chrome.setHover(.none);
    self.layoutTab(t);
    self.syncFocus();
    self.dirty = true;
}

/// Show every pane of tab `t` again, if one is zoomed.
fn unzoom(self: *Window, t: *Tab) void {
    if (t.zoom == null) return;
    t.zoom = null;
    _ = self.chrome.setHover(.none);
    self.layoutTab(t);
    if (t == self.activeTab()) self.syncFocus();
    self.dirty = true;
}

/// Focus the pane `to` picks in the active tab, from the focused one.
fn gotoPane(self: *Window, to: binding.GotoSplit) void {
    const t = self.activeTab();
    if (t.count() < 2) return;
    // The panes' places, to look between, are the unzoomed ones.
    self.unzoom(t);
    const next = switch (to) {
        .previous => t.following(t.focus, false),
        .next => t.following(t.focus, true),
        inline else => |side| t.neighbor(t.focus, @field(Daemon.Direction, @tagName(side))) orelse return,
    };
    self.focusPane(next);
    self.dirty = true;
}

/// Move the divider beside the focused pane `cells` cells toward `side`,
/// as dragging it would, and send slime the tree.
fn resizePane(self: *Window, side: Daemon.Direction, cells: u16) void {
    const t = self.activeTab();
    self.unzoom(t);
    const d = t.dividerFor(t.focus, side) orelse return;
    const m = self.grid.metrics;
    const cell: f32 = @floatFromInt(if (d.axis() == .row) m.cell_width else m.cell_height);
    const px = cell * @as(f32, @floatFromInt(cells));
    const before = d.shares();
    d.drag(before, if (side == .right or side == .down) px else -px, self.paneMin(d.axis()));
    if (std.meta.eql(before, d.shares())) return;
    self.layoutTab(t);
    self.sendLayout(t);
    self.dirty = true;
}

/// Give the active tab's panes the same sizes, and send slime the tree.
fn equalizePanes(self: *Window) void {
    const t = self.activeTab();
    if (t.count() < 2) return;
    t.equalize();
    self.layoutTab(t);
    self.sendLayout(t);
    self.dirty = true;
}

/// Start dragging divider `i` of the active tab, if slime has its tree.
fn startDrag(self: *Window, i: usize, pos: win32.POINT) void {
    const t = self.activeTab();
    if (t.conn == null or i >= t.dividers.items.len) return;
    const d = t.dividers.items[i];
    self.hideTip();
    self.drag = .{ .tab = t, .divider = d, .from = d.shares(), .origin = across(d, pos) };
    _ = win32.SetCapture(self.hwnd.?);
}

/// The mouse's position across divider `d`'s axis.
fn across(d: Tab.Divider, pos: win32.POINT) i32 {
    return if (d.axis() == .row) pos.x else pos.y;
}

/// The least a pane takes along `axis` when a divider moves: room for a
/// few cells.
fn paneMin(self: *const Window, axis: Tab.Axis) f32 {
    const m = self.grid.metrics;
    const pad = self.paddingPx();
    return @floatFromInt(if (axis == .row) pad.left + pad.right + 4 * m.cell_width else pad.top + pad.bottom + 2 * m.cell_height);
}

/// Move the dragged divider to the mouse, resizing the panes either side
/// as it goes.
fn dragTo(self: *Window, d: Drag, pos: win32.POINT) void {
    const before = d.divider.shares();
    d.divider.drag(d.from, @floatFromInt(across(d.divider, pos) - d.origin), self.paneMin(d.divider.axis()));
    if (std.meta.eql(before, d.divider.shares())) return;
    self.layoutTab(d.tab);
    self.dirty = true;
}

/// Let go of the dragged divider and send slime the tree it left.
fn endDrag(self: *Window) void {
    const d = self.drag orelse return;
    // First: releasing the capture comes back as WM_CAPTURECHANGED.
    self.drag = null;
    _ = win32.ReleaseCapture();
    if (std.meta.eql(d.from, d.divider.shares())) return;
    self.sendLayout(d.tab);
}

/// Send slime tab `t`'s tree, changed here.
fn sendLayout(self: *Window, t: *const Tab) void {
    const conn = t.conn orelse return;
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const root = (t.toLayout(arena.allocator()) catch return) orelse return;
    conn.layout(t.id, root) catch |err| log.err("sending the layout failed: {}", .{err});
}

/// Drop a drag (of a divider or a pane) whose tree is about to change, as
/// it stands: slime's tree, or the pane closing, decides the layout now.
fn cancelDrag(self: *Window) void {
    if (self.drag == null and self.pane_drag == null) return;
    self.drag = null;
    if (self.pane_drag != null) self.dirty = true;
    self.pane_drag = null;
    _ = win32.ReleaseCapture();
}

/// The button went down on pane `s`'s title strip: focus it, and drag it
/// if the mouse moves on with the button down.
fn startPaneDrag(self: *Window, s: *Session, pos: win32.POINT) void {
    self.focusPane(s);
    self.hideTip();
    self.pane_drag = .{ .tab = self.activeTab(), .source = s, .start = pos };
    _ = win32.SetCapture(self.hwnd.?);
}

/// Follow the mouse with the dragged pane: once it's gone past the
/// system's drag distance, find where the pane would land. Only a tab of
/// several daemon panes rearranges; others just took focus.
fn paneDragTo(self: *Window, d: *PaneDrag, pos: win32.POINT) void {
    if (d.tab.conn == null or d.tab.count() < 2) return;
    if (d.at == null) {
        const dx = win32.GetSystemMetricsForDpi(win32.SM_CXDRAG, self.dpi);
        const dy = win32.GetSystemMetricsForDpi(win32.SM_CYDRAG, self.dpi);
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
    self.dirty = true;
}

/// Let go of the dragged pane, moving it where it was dropped.
fn endPaneDrag(self: *Window) void {
    const d = self.pane_drag orelse return;
    // First: releasing the capture comes back as WM_CAPTURECHANGED.
    self.pane_drag = null;
    _ = win32.ReleaseCapture();
    self.dirty = true;
    const drop = d.drop orelse return;
    d.tab.move(self.alloc, d.source, drop.place) catch |err| return log.err("moving the pane failed: {}", .{err});
    self.layoutTab(d.tab);
    self.sendLayout(d.tab);
    self.syncFocus();
}

/// Where the dragged pane would land at `pos`: along a side of the tab
/// near its edge, else in the pane under the mouse, beside it on the
/// side the mouse is toward, or in its place from its middle.
fn dropAt(self: *Window, d: *const PaneDrag, pos: win32.POINT) ?Drop {
    const x: f32 = @floatFromInt(pos.x);
    const y: f32 = @floatFromInt(pos.y);
    const area = self.chrome.paneArea(&self.chrome_layout);
    if (!area.contains(x, y)) return null;
    const band = self.chrome.px(24);
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
        .rect = half(area, side).inset(self.chrome.px(4), self.chrome.px(4)),
    };

    var it = d.tab.iterator();
    const target = while (it.next()) |s| {
        if (s.frame.contains(x, y)) break s;
    } else return null;
    if (target == d.source) return null;
    const f = target.frame;
    const inset = self.chrome.px(6);
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
fn half(r: Chrome.Rect, side: Daemon.Direction) Chrome.Rect {
    return switch (side) {
        .left => .{ .x = r.x, .y = r.y, .w = @round(r.w / 2), .h = r.h },
        .right => .{ .x = r.x + @round(r.w / 2), .y = r.y, .w = r.w - @round(r.w / 2), .h = r.h },
        .up => .{ .x = r.x, .y = r.y, .w = r.w, .h = @round(r.h / 2) },
        .down => .{ .x = r.x, .y = r.y + @round(r.h / 2), .w = r.w, .h = r.h - @round(r.h / 2) },
    };
}

/// The active tab's pane `view` listed at `i`.
fn shownPane(self: *const Window, i: usize) ?*Session {
    return if (i < self.shown.items.len) self.shown.items[i] else null;
}

/// Show tab `i` and give its pane `j` (in layout order) the keys.
fn showPane(self: *Window, i: usize, j: usize) void {
    if (i >= self.tabs.items.len) return;
    self.activate(i);
    var it = self.activeTab().iterator();
    var n: usize = 0;
    while (it.next()) |s| : (n += 1) {
        if (n == j) return self.focusPane(s);
    }
}

/// Give the active tab's pane `s` the keys.
fn focusPane(self: *Window, s: *Session) void {
    const t = self.activeTab();
    if (t.focus == s or !t.contains(s)) return;
    self.deactivate();
    t.focus = s;
    self.activated();
}

/// Drop the host behind group `g` from the sidebar, if no tab uses it.
fn forgetHost(self: *Window, g: usize) void {
    if (g == 0 or g > self.hosts.items.items.len) return;
    for (self.tabs.items) |t| {
        if (self.groupOf(t) == g) return;
    }
    self.hosts.remove(g - 1);
    _ = self.chrome.setHover(.none);
    self.dirty = true;
}

/// Close pane `s` of tab `ti`, killing what runs in it. Closing a tab's
/// last pane closes the tab.
fn closePane(self: *Window, ti: usize, s: *Session) void {
    self.cancelDrag();
    const t = self.tabs.items[ti];
    if (t.count() <= 1) return self.closeTab(ti);
    const focused = ti == self.active and s == t.focus;
    if (focused) self.deactivate();
    _ = t.remove(self.alloc, s);
    self.standInClosing(s);
    s.kill();
    s.destroy();
    _ = self.chrome.setHover(.none);
    self.layoutTab(t);
    if (focused) self.activated();
    self.pruneRemotes();
    self.dirty = true;
}

/// Close tab `i`, killing what runs in its panes. Closing the last one
/// closes the window.
fn closeTab(self: *Window, i: usize) void {
    self.cancelDrag();
    if (self.tabs.items.len <= 1) {
        // Closing the window only detaches slime's panes.
        var it = self.tabs.items[i].iterator();
        while (it.next()) |s| {
            self.standInClosing(s);
            s.kill();
        }
        _ = win32.PostMessageW(self.hwnd, win32.WM_CLOSE, 0, 0);
        return;
    }
    var it = self.tabs.items[i].iterator();
    while (it.next()) |s| {
        self.standInClosing(s);
        s.kill();
    }
    self.dropTab(i);
    self.pruneRemotes();
}

/// Take tab `i` out and free it with its sessions, which lets go of
/// slime's panes without ending them. Not the last tab.
fn dropTab(self: *Window, i: usize) void {
    const was_active = i == self.active;
    if (was_active) self.deactivate();
    self.destroyTab(self.tabs.orderedRemove(i));
    // Rows moved under the mouse.
    _ = self.chrome.setHover(.none);
    self.middle_pressed = null;
    if (i < self.active) {
        self.active -= 1;
    } else if (was_active) {
        self.active = @min(i, self.tabs.items.len - 1);
        self.activated();
    }
    self.dirty = true;
}

/// Show tab `i` and give its focused pane input.
fn activate(self: *Window, i: usize) void {
    if (i == self.active or i >= self.tabs.items.len) return;
    self.deactivate();
    self.active = i;
    self.activated();
}

/// Let go of the focused pane before switching away from it.
fn deactivate(self: *Window) void {
    const s = self.activeSession();
    if (self.mouse_in_terminal) _ = win32.ReleaseCapture();
    self.mouse_in_terminal = false;
    s.cancelSelection();
    if (self.focused) s.reportFocus(false);
}

/// Take up the pane that just got focus, in the tab now shown.
fn activated(self: *Window) void {
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
    self.dirty = true;
}

/// Show the next or previous tab, wrapping around.
fn cycle(self: *Window, forward: bool) void {
    const n = self.tabs.items.len;
    self.activate(if (forward) (self.active + 1) % n else (self.active + n - 1) % n);
}

/// The message loop's view of frame pacing: when `output_event` fires,
/// call `outputArrived`; while `needsFrame`, also wait on `frameGate` and
/// pass it to `frameGateFired` when it fires. Drawing then happens at most
/// once per display refresh, and right away when the terminal was idle.
pub fn outputArrived(self: *Window) void {
    const quiet = win32.GetTickCount64() < self.quiet_until;
    var status_changed = false;
    for (self.tabs.items, 0..) |t, i| {
        var it = t.iterator();
        while (it.next()) |s| {
            if (s.status_changed.swap(false, .acq_rel)) status_changed = true;
            if (!s.unseen.swap(false, .acq_rel)) continue;
            if (i == self.active) {
                if (!t.shows(s)) continue;
                self.dirty = true;
            } else if (!s.activity and !quiet) {
                s.activity = true;
                self.dirty = true;
            }
        }
    }
    if (status_changed) {
        self.dirty = true;
        self.updateSpinner();
    }
}

pub fn needsFrame(self: *const Window) bool {
    return self.dirty;
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
    if (self.dirty) self.render();
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
/// paste with no text on the clipboard, a pane action in a tab slime
/// doesn't run.
fn runAction(self: *Window, action: binding.Action) bool {
    const s = self.activeSession();
    switch (action) {
        .new_split, .goto_split, .resize_split, .equalize_splits, .toggle_split_zoom => if (self.activeTab().conn == null) return false,
        else => {},
    }
    switch (action) {
        .copy_to_clipboard => return s.copySelection(),
        .paste_from_clipboard => {
            if (!clipboard.hasText()) return false;
            s.paste();
        },
        .new_tab => self.newSession(),
        .close_surface => self.closePane(self.active, s),
        .next_tab => self.cycle(true),
        .previous_tab => self.cycle(false),
        .increase_font_size => |pt| self.setFontSize(self.grid.size_pt + pt),
        .decrease_font_size => |pt| self.setFontSize(self.grid.size_pt - pt),
        .reset_font_size => self.setFontSize(self.config.@"font-size"),
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
    const cursor = self.activeSession().screen.cursor;
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
        self.openOnHost(h) catch |err| log.err("connect failed: {}", .{err});
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
    const daemon = self.daemon orelse return;
    const e = self.hostEntry(s.hostDest() orelse return) orelse return;
    switch (action) {
        .accept, .skip => {
            var buf: [Chrome.Dialog.max_fields][]const u16 = undefined;
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

/// Run the spinner's timer while the active session's dialog waits.
/// Run the spinner's timer while the active session's dialog waits, or a
/// pane is working.
fn updateSpinner(self: *Window) void {
    const waiting = if (self.activeSession().login) |l| l.dialog.state == .waiting else self.anyWorking();
    if (waiting == self.spinning) return;
    self.spinning = waiting;
    if (waiting) {
        _ = win32.SetTimer(self.hwnd, spinner_timer_id, spinner_ms, null);
    } else {
        _ = win32.KillTimer(self.hwnd, spinner_timer_id);
    }
}

/// A pane reports work in progress, which the sidebar shows turning.
fn anyWorking(self: *Window) bool {
    for (self.tabs.items) |t| {
        var it = t.iterator();
        while (it.next()) |s| {
            const summary = s.statusSummary() orelse continue;
            if (summary.state == .working) return true;
        }
    }
    return false;
}

/// The chrome's view of the window's state.
fn view(self: *Window) Chrome.View {
    // `reserveGroups` keeps room for every group. The rest is grown here,
    // and left out if that fails.
    self.view_tabs.clearRetainingCapacity();
    self.view_tab_panes.clearRetainingCapacity();
    self.view_groups.clearRetainingCapacity();
    self.view_panes.clearRetainingCapacity();
    self.view_dividers.clearRetainingCapacity();
    self.shown.clearRetainingCapacity();
    // Local is always listed, for its button, then every host.
    self.view_groups.appendAssumeCapacity(.{ .label = std.unicode.utf8ToUtf16LeStringLiteral("Local"), .tabs = 0, .kind = .local });
    for (self.hosts.items.items, 0..) |dest, h| {
        self.view_groups.appendAssumeCapacity(.{
            .label = Hosts.label(dest),
            .tabs = 0,
            .kind = if (self.hostLive(h)) .connected else .disconnected,
        });
    }
    for (self.tabs.items) |t| {
        const first = self.view_tab_panes.items.len;
        var focus: usize = 0;
        var pi = t.iterator();
        while (pi.next()) |s| {
            if (s == t.focus) focus = self.view_tab_panes.items.len - first;
            self.view_tab_panes.append(self.alloc, .{
                .title = s.title(),
                .status = if (s.statusSummary()) |summary| summary.state else null,
                .activity = s.activity,
            }) catch break;
        }
        self.view_tabs.append(self.alloc, .{
            .title = t.focus.title(),
            .activity = t.activity(),
            .folded = t.folded,
            .focus = focus,
        }) catch break;
        self.view_groups.items[self.groupOf(t)].tabs += 1;
    }
    // Each tab's panes, now that growing the list can't move them.
    var start: usize = 0;
    for (self.view_tabs.items, self.tabs.items[0..self.view_tabs.items.len]) |*vt, t| {
        const n = @min(t.count(), self.view_tab_panes.items.len - start);
        vt.panes = self.view_tab_panes.items[start..][0..n];
        start += n;
    }
    const tab = self.activeTab();
    const several = tab.count() > 1;
    var it = tab.iterator();
    while (it.next()) |s| {
        if (!tab.shows(s)) continue;
        self.shown.append(self.alloc, s) catch break;
        self.view_panes.append(self.alloc, .{
            .frame = s.frame,
            .rect = s.rect,
            .title = s.title(),
            .focused = s == tab.focus,
            .splittable = s.daemonPane() != null,
            .zoomable = several,
            .zoomed = tab.zoom == s,
            .bg = toColor(s.cells.default_bg),
        }) catch {
            _ = self.shown.pop();
            break;
        };
    }
    for (tab.dividers.items) |d| self.view_dividers.append(self.alloc, d.rect) catch break;
    const pane_drag: ?Chrome.View.PaneDrag = if (self.pane_drag) |d| if (d.at) |at| .{
        .source = std.mem.indexOfScalar(*Session, self.shown.items, d.source),
        .drop = if (d.drop) |drop| drop.rect else null,
        .mouse = .{ .x = @floatFromInt(at.x), .y = @floatFromInt(at.y) },
    } else null else null;
    return .{
        .groups = self.view_groups.items,
        .tabs = self.view_tabs.items,
        .panes = self.view_panes.items,
        .dividers = self.view_dividers.items,
        .pane_drag = pane_drag,
        .connect = if (self.connect_field) |*f| f else null,
        .caret_visible = self.blink_visible,
        .dialog = if (self.activeSession().login) |l| &l.dialog else null,
        .spinner = self.spinner_step,
        .active = self.active,
        .focused = self.focused,
        .maximized = win32.IsZoomed(self.hwnd.?) != 0,
        .terminal_bg = toColor(self.activeSession().cells.default_bg),
        .stats = self.stats_text[0..self.stats_len],
        .new_tab_key = new_session_key.slice(),
        .close_tab_key = close_session_key.slice(),
        .split_right_key = split_right_key.slice(),
        .split_down_key = split_down_key.slice(),
        .zoom_key = zoom_key.slice(),
    };
}

fn toColor(c: ghostty_vt.color.RGB) Chrome.Color {
    return Painter.rgb(@as(u24, c.r) << 16 | @as(u24, c.g) << 8 | c.b);
}

/// What's under a client position.
fn hitAt(self: *Window, pos: win32.POINT) Chrome.Hit {
    const v = self.view();
    return self.chrome.hitTest(&self.chrome_layout, &v, @floatFromInt(pos.x), @floatFromInt(pos.y));
}

/// A client position relative to pane `s`.
fn toPane(s: *const Session, pos: win32.POINT) win32.POINT {
    return .{ .x = pos.x - @as(i32, @intFromFloat(s.rect.x)), .y = pos.y - @as(i32, @intFromFloat(s.rect.y)) };
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

/// Handle a client area mouse message: a pane gets it if a button went
/// down there (until all are up) or it's over the pane, and the chrome
/// otherwise. Pressing a button over a pane focuses it.
fn mouseInput(self: *Window, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) void {
    const pos: win32.POINT = .{ .x = win32.xLparam(lparam), .y = win32.yLparam(lparam) };
    const s = self.activeSession();
    const held = input.heldButton(wparam) != null;
    const press = if (input.mouseButton(msg, wparam)) |b| b[1] else false;

    if (msg == win32.WM_MOUSEMOVE and !self.tracking_mouse) {
        var tme: win32.TRACKMOUSEEVENT = .{ .dwFlags = win32.TME_LEAVE, .hwndTrack = self.hwnd.? };
        self.tracking_mouse = win32.TrackMouseEvent(&tme) != 0;
    }

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

    if (self.mouse_in_terminal) {
        s.mouseInput(msg, wparam, toPane(s, pos));
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
        const pane = self.shownPane(hit.terminal) orelse return;
        if (press) {
            self.focusPane(pane);
            // Capture the mouse while a button is down, so a drag past
            // the edge still reports and the release comes back to us.
            self.mouse_in_terminal = true;
            _ = win32.SetCapture(self.hwnd.?);
        }
        pane.mouseInput(msg, wparam, toPane(pane, pos));
        return;
    }

    switch (msg) {
        win32.WM_LBUTTONDOWN => {
            if (hit == .divider) return self.startDrag(hit.divider, pos);
            if (hit == .pane_title) if (self.shownPane(hit.pane_title)) |pane| return self.startPaneDrag(pane, pos);
            self.setPressed(hit);
            _ = win32.SetCapture(self.hwnd.?);
            // Rows switch on press, as tabs do.
            if (hit == .tab) self.activate(hit.tab);
            if (hit == .tab_pane) self.showPane(hit.tab_pane.tab, hit.tab_pane.pane);
        },
        win32.WM_LBUTTONUP => {
            const pressed = self.chrome.pressed;
            self.setPressed(.none);
            _ = win32.ReleaseCapture();
            if (pressed.eql(hit)) self.chromeClick(hit);
        },
        win32.WM_MBUTTONDOWN => self.middle_pressed = switch (hit) {
            .tab, .close_tab => |i| i,
            else => null,
        },
        win32.WM_MBUTTONUP => {
            const pressed = self.middle_pressed orelse return;
            self.middle_pressed = null;
            switch (hit) {
                .tab, .close_tab => |i| if (i == pressed) self.closeTab(i),
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
        .new_tab => |g| self.newSessionIn(g),
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
        .close_tab => |i| self.closeTab(i),
        .fold => |i| if (i < self.tabs.items.len) {
            const t = self.tabs.items[i];
            t.folded = !t.folded;
            _ = self.chrome.setHover(.none);
            self.dirty = true;
        },
        .split_right => |i| if (self.shownPane(i)) |s| self.splitPane(s, .right),
        .split_down => |i| if (self.shownPane(i)) |s| self.splitPane(s, .down),
        .zoom => |i| if (self.shownPane(i)) |s| self.toggleZoom(s),
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

/// The space around the grid in a pane: the configured padding, in
/// points, as pixels at the current DPI, plus the chrome's inset on every
/// side.
pub fn paddingPx(self: *const Window) PaddingPx {
    const x = self.config.@"window-padding-x";
    const y = self.config.@"window-padding-y";
    const inset: u32 = @intFromFloat(self.chrome_layout.inset);
    return .{
        .left = x.top_left * self.dpi / 72 + inset,
        .right = x.bottom_right * self.dpi / 72 + inset,
        .top = y.top_left * self.dpi / 72 + inset,
        .bottom = y.bottom_right * self.dpi / 72 + inset,
    };
}

const GridSize = struct { cols: u16, rows: u16 };

/// The number of whole cells that fit in the terminal area.
fn gridSize(self: *const Window) GridSize {
    const size = self.terminalSize();
    const m = self.grid.metrics;
    const pad = self.paddingPx();
    return .{
        .cols = @intCast(std.math.clamp((size.width -| pad.left -| pad.right) / m.cell_width, 1, std.math.maxInt(u16))),
        .rows = @intCast(std.math.clamp((size.height -| pad.top -| pad.bottom) / m.cell_height, 1, std.math.maxInt(u16))),
    };
}

pub const CellSize = struct { width: u32, height: u32 };

pub fn cellSizePx(self: *const Window) CellSize {
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

    pub fn capture(self: Ui) ?Chrome.Rect {
        return Chrome.dragCapture(&self.view);
    }

    pub fn paintOver(self: Ui, p: *Painter, thumb: ?Painter.Image) void {
        self.window.chrome.paintDrag(p, &self.window.chrome_layout, &self.view, thumb);
    }
};

fn renderFallible(self: *Window, r: *Renderer) !void {
    r.waitForFrame();
    self.dirty = false;
    const tab = self.activeTab();
    const stats = build_options.stats;
    var t: i64 = if (stats) Stats.now() else 0;
    self.frame_panes.clearRetainingCapacity();
    var it = tab.iterator();
    while (it.next()) |s| {
        if (!tab.shows(s)) continue;
        s.applyFrames();
        if (stats) t = self.stats.lap(.update, t);
        // Panes without focus show a hollow cursor, as an unfocused
        // window's does.
        const focus = s == tab.focus;
        try s.cells.build(self.alloc, &s.screen, &self.grid, .{
            // The host field or a login dialog has the keyboard while open.
            .focused = focus and self.focused and self.connect_field == null and s.login == null,
            .blink_visible = self.blink_visible,
        }, .{
            .cursor_color = self.config.@"cursor-color",
            .cursor_text = self.config.@"cursor-text",
            .selection_background = self.config.@"selection-background",
            .selection_foreground = self.config.@"selection-foreground",
        });
        if (stats) t = self.stats.lap(.build, t);
        try self.frame_panes.append(self.alloc, .{
            .cells = &s.cells,
            .images = &s.images,
            .textures = &s.textures,
            .frame = s.frame,
            .viewport = s.rect,
            .grid_offset = .{ @floatFromInt(s.pad.left), @floatFromInt(s.pad.top) },
        });
    }
    var shadows: [2]Renderer.BoxStyle.Shadow = undefined;
    try r.draw(self.alloc, .{
        .atlas = &self.grid.atlas,
        .color_atlas = &self.grid.color_atlas,
        .lcd_atlas = &self.grid.lcd_atlas,
        .metrics = self.grid.metrics,
        .panes = self.frame_panes.items,
        // The chrome's ground, around and between the panes.
        .background = self.chrome.theme.ground,
        .box = self.paneBox(&shadows),
    }, Ui{ .window = self, .view = self.view() });
    // More frames may come for what's drawn.
    it = tab.iterator();
    while (it.next()) |s| if (tab.shows(s)) s.drawn();
    if (stats) {
        _ = self.stats.lap(.draw, t);
        self.stats.frames += 1;
    }
}

/// How the renderer draws each pane: rounded as the chrome's corners,
/// with a hairline border and two shadows, one tight at its edge and one
/// soft around it. `shadows` holds them. A blur reaches about 3 sigma, so
/// the soft one fades out within the gap between panes rather than
/// running under the sidebar, which would cut it off.
fn paneBox(self: *const Window, shadows: *[2]Renderer.BoxStyle.Shadow) Renderer.BoxStyle {
    const c = &self.chrome;
    const s = c.theme.pane_shadow;
    shadows.* = .{
        .{ .color = s, .sigma = c.px(1), .offset = c.px(1) },
        .{ .color = .{ s[0], s[1], s[2], s[3] * 0.7 }, .sigma = c.px(3), .offset = c.px(2) },
    };
    return .{
        .radius = self.chrome_layout.corner,
        .border_width = c.stroke(),
        .border = c.theme.pane_border,
        .shadows = shadows,
    };
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

/// Place tab `t`'s panes in the terminal area and fit their grids to
/// them. Each pane's terminal is under its title strip, padded by
/// `paddingPx` (but for the chrome's inset at the top, which the strip
/// stands in for), and the grid is centered in what's left, so the part
/// of a cell that doesn't fit is split between opposite edges rather
/// than all at the right and bottom.
fn layoutTab(self: *Window, t: *Tab) void {
    t.place(self.alloc, self.chrome.paneArea(&self.chrome_layout), self.chrome.paneGap()) catch |err| log.err("laying out panes failed: {}", .{err});
    var pad = self.paddingPx();
    pad.top -|= @intFromFloat(self.chrome_layout.inset);
    const strip = self.chrome.paneTitleHeight();
    const m = self.grid.metrics;
    var it = t.iterator();
    while (it.next()) |s| {
        if (!t.shows(s)) continue;
        const top = @min(strip, s.frame.h);
        s.rect = .{ .x = s.frame.x, .y = s.frame.y + top, .w = s.frame.w, .h = s.frame.h - top };
        const w = @as(u32, @intFromFloat(s.rect.w)) -| pad.left -| pad.right;
        const h = @as(u32, @intFromFloat(s.rect.h)) -| pad.top -| pad.bottom;
        const cols: u16 = @intCast(std.math.clamp(w / m.cell_width, 1, std.math.maxInt(u16)));
        const rows: u16 = @intCast(std.math.clamp(h / m.cell_height, 1, std.math.maxInt(u16)));
        const spare_x = w -| @as(u32, cols) * m.cell_width;
        const spare_y = h -| @as(u32, rows) * m.cell_height;
        s.pad = .{
            .left = pad.left + spare_x / 2,
            .right = pad.right + spare_x - spare_x / 2,
            .top = pad.top + spare_y / 2,
            .bottom = pad.bottom + spare_y - spare_y / 2,
        };
        s.resize(cols, rows);
    }
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

    self.quiet_until = win32.GetTickCount64() + resize_quiet_ms;
    for (self.tabs.items) |t| self.layoutTab(t);
    if (self.daemon) |conn| conn.resizeWorkspace(self.daemonArea());
    for (self.remotes.items) |remote| if (remote.conn.attachState() == .attached) remote.conn.resizeWorkspace(self.daemonArea());

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
    if (self.tabs.items.len == 0 and msg != win32.WM_NCCALCSIZE)
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
            const found = self.findSession(@intCast(wparam)) orelse return 0;
            const s = found.s;
            // A daemon pane lost to us while it runs stays to say why.
            if (s.daemonLoss()) |loss| {
                if (!s.ended) s.showEnded(loss.text());
                self.dirty = true;
                return 0;
            }
            self.closePane(found.tab, s);
            return 0;
        },

        WM_APP_DAEMON => {
            self.daemonPosted();
            return 0;
        },

        WM_APP_TITLE_CHANGED => {
            const s = (self.findSession(@intCast(wparam)) orelse return 0).s;
            s.titleUpdate();
            if (s == self.activeSession()) self.showTitle();
            self.dirty = true;
            return 0;
        },

        WM_APP_CLIPBOARD_WRITE => {
            (self.findSession(@intCast(wparam)) orelse return 0).s.clipboardWriteFlush();
            return 0;
        },

        win32.WM_KEYDOWN, win32.WM_KEYUP, win32.WM_SYSKEYDOWN, win32.WM_SYSKEYUP => {
            if (msg == win32.WM_KEYDOWN or msg == win32.WM_SYSKEYDOWN) self.hideTip();
            // Escape drops a pane being dragged where it was.
            if (msg == win32.WM_KEYDOWN and wparam == win32.VK_ESCAPE and self.pane_drag != null) {
                self.cancelDrag();
                return 0;
            }
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
                    self.closePane(self.active, self.activeSession());
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
                if (self.drag != null) self.endDrag();
                // A pane drag that lost the mouse lands nowhere.
                self.cancelDrag();
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
            const pane = if (self.mouse_in_terminal) self.activeSession() else switch (self.hitAt(pos)) {
                .terminal => |i| self.shownPane(i) orelse return 0,
                else => return 0,
            };
            pane.mouseWheel(msg, wparam, toPane(pane, pos));
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
            const divider: ?Tab.Divider = if (self.drag) |d| d.divider else switch (hit) {
                .divider => |i| if (i < self.activeTab().dividers.items.len) self.activeTab().dividers.items[i] else null,
                else => null,
            };
            if (divider) |d| cursor = if (d.axis() == .row) win32.IDC_SIZEWE else win32.IDC_SIZENS;
            if (self.pane_drag) |d| if (d.at != null) {
                cursor = win32.IDC_SIZEALL;
            };
            const pane = if (self.mouse_in_terminal) self.activeSession() else switch (hit) {
                .terminal => |i| self.shownPane(i),
                else => null,
            };
            if (pane) |s| cursor = mouseCursor(s.mouseShape());

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
