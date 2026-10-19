//! A window's connection to slime (cmd/slime), the daemon that
//! owns local ptys so they outlive the window. The daemon keeps panes in
//! tabs and tabs in workspaces; a window lists every workspace
//! (`WorkspaceEvent`) and attaches the ones it shows, beside any other
//! windows on them, mirroring each: the layout, and the focus the daemon
//! keeps for all of them (`focus`). The protocol is internal/daemon's
//! (wire.go): a binary frame path, and a JSON-RPC control plane
//! (internal/rpc) in Call, Reply, and Notify envelopes, which `std.json`
//! reads and writes here.
//!
//! slime runs each pane's terminal; we draw what it sends: frames of
//! the pane's screen, and notices of what else it did (a new title, a
//! clipboard write). Input goes back as events, which slime handles
//! against the terminal. One reader thread reads the connection and
//! hands each pane's messages to its session through a `Sink`.
//!
//! Panes that arrive while the reader runs (a new tab, or one a script
//! added) keep what comes for them on the reader thread, then wait in
//! `arrivals` for the UI thread, which is told with the `notify` message.
//! Adopting one replays what was kept under the connection's lock before
//! the pane goes live, so nothing is lost or reordered at the handoff.
//!
//! The local daemon is reached through its named pipe (`connect`). It
//! also holds the SSH connections to hosts: the host methods on the same
//! connection log in to one (`hostConnect`, with its prompts coming back
//! as `HostEvent`s for the window to take) and, subscribed to, report
//! every host's state. A host's own slime is reached through a second
//! connection to the local pipe that the daemon splices to it
//! (`connectRemote`), whose reader attaches before it routes frames.
const Daemon = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32/win32.zig");
const Screen = @import("Screen.zig");
const Hosts = @import("Hosts.zig");

const log = std.log.scoped(.daemon);

const L = std.unicode.utf8ToUtf16LeStringLiteral;

/// internal/daemon's Version.
const protocol_version = 1;
/// internal/daemon's MaxFrame: a full frame goes whole.
const max_frame = 8 << 20;
/// Long enough for long-path-aware installs.
const max_path = 32 * 1024;
const daemon_name = L("slime.exe");

/// wire.go's envelope types.
const MsgType = enum(u8) {
    hello = 1,
    call = 2,
    ack = 3,
    event = 4,
    resize = 5,
    bridge = 6,
    hello_reply = 65,
    reply = 66,
    notify = 67,
    @"error" = 68,
    draw = 69,
    image = 70,
    copied = 71,
    notice = 72,
    _,
};

/// Unknown fields are the daemon's business: a later one may add some.
const json_opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
/// A call with nothing to say: `{}`. (The empty literal `.{}` is a tuple,
/// which std.json writes as `[]`.)
const no_params = struct {}{};

alloc: Allocator,
pipe: Pipe,
notify: Notify,
reader: ?std.Thread = null,
/// Frames are written from the UI thread and, while a host's attaches,
/// its reader; each goes out whole.
write_lock: win32.SRWLOCK = .{},
/// The daemon's process id, from its hello.
pid: u32 = 0,
/// Ids for calls, from the UI thread and, while a host's attaches, its
/// reader.
next_id: std.atomic.Value(u32) = .init(0),

/// The host this is bridged to; null for the local daemon itself.
remote: ?Remote = null,
/// How attaching went. A host's starts out connecting, and its reader
/// says how it ended (`notify`).
state: std.atomic.Value(State) = .init(.attached),
/// Why attaching failed, once `state` says it did.
failure: Failure = .{},
/// The last Error the daemon sent about the connection, which for a
/// bridge says why it ended. Reader thread.
lost_reason: Failure = .{},
/// What a host's reader attaches with.
area: Area = undefined,
size: Size = undefined,
/// The least time between a pane's frames we ask for, in microseconds:
/// the display's refresh period.
frame_interval: u32 = 0,
/// The reader posts `notify` when panes arrive: from `start` for the
/// local daemon, and once attached for a host's.
posting: std.atomic.Value(bool) = .init(false),

/// Guards `panes`, `arrivals`, `structures`, `attached`, `focus_calls`,
/// `attach_calls`, `host_events`, `workspace_events`, and `lost`, and is
/// held while calling a sink, so a session can't go while one runs.
lock: win32.SRWLOCK = .{},
panes: std.AutoHashMapUnmanaged(PaneRef, Slot) = .empty,
arrivals: std.ArrayList(Arrival) = .empty,
/// What the daemon said about hosts since the UI thread last looked
/// (`takeHosts`).
host_events: std.ArrayList(HostEvent) = .empty,
/// What the daemon said about workspaces not attached here since the UI
/// thread last looked (`takeWorkspaces`). Attached ones come as
/// structures.
workspace_events: std.ArrayList(WorkspaceEvent) = .empty,
/// The latest structure of each attached workspace that changed since
/// the UI thread last looked, in the order they first did.
structures: std.ArrayList(*Structure) = .empty,
/// The workspaces attached here, from `attach` (or `newWorkspace`) until
/// `detach`, or the daemon takes one away: what the reader routes a
/// `workspace.changed` for as a structure. The app keeps what it knows
/// of each (`App.Workspace`); this is only which ones this connection
/// has.
attached: std.AutoHashMapUnmanaged(u32, void) = .empty,
/// Workspaces the daemon said to open here (`workspace.open`): a script
/// run from one of ours made them for this window. Taken by
/// `takeOpens`.
opens: std.ArrayList(u32) = .empty,
/// Ids of our `focus` calls not yet replied to. A structure that comes
/// meanwhile may predate them, so its focus isn't taken.
focus_calls: std.ArrayList(u32) = .empty,
/// Our `attach` and `newWorkspace` calls not yet replied to: each reply
/// is the workspace's structure, or why it failed.
attach_calls: std.ArrayList(AttachCall) = .empty,
/// Ids of our `hostList` calls, whose replies become `hosts` events.
host_lists: std.ArrayList(u32) = .empty,
/// The connection ended; every live pane was told why.
lost: bool = false,
/// `deinit` is hanging up, so the reader's end isn't a loss.
closing: std.atomic.Value(bool) = .init(false),

/// A window message posted from the reader thread when panes arrive, and
/// when a host's slime has attached or failed to.
pub const Notify = struct {
    hwnd: win32.HWND,
    msg: u32,
};

pub const State = enum(u8) { connecting, attached, failed };

/// An `attach` or `newWorkspace` call out: `ws` is 0 for a new one,
/// whose id the reply gives.
const AttachCall = struct { id: u32, ws: u32 };

/// Which workspaces to attach at connect, as the window remembers them:
/// `ids` are only good for the daemon with `pid`, since ids start over
/// with each daemon.
pub const Wanted = struct {
    pid: u32 = 0,
    ids: []const u32 = &.{},
    /// Someone is waiting for a pane: with nothing to attach, make a
    /// workspace, and with no pane in what's attached, a tab. Off, the
    /// connection lists the daemon's workspaces and shows what it has.
    make: bool = true,
};

/// A workspace as the daemon lists it (rpc.WorkspaceDesc), for the
/// window's list of them.
pub const WorkspaceInfo = struct {
    id: u32,
    /// Owned, in the connection's allocator.
    name: []const u16,
    /// How many tabs it has, and the one shown.
    tabs: usize,
    active_tab: TabRef,
    /// Connections viewing it, this one included, if the message said.
    viewers: ?usize,

    fn fromJson(alloc: Allocator, id: u32, name: []const u8, tabs: usize, active_tab: TabRef, viewers: ?usize) !WorkspaceInfo {
        return .{
            .id = id,
            .name = try toUtf16(alloc, name),
            .tabs = tabs,
            .active_tab = active_tab,
            .viewers = viewers,
        };
    }

    pub fn deinit(self: *WorkspaceInfo, alloc: Allocator) void {
        alloc.free(self.name);
    }
};

/// Something the daemon said about workspaces, for the window's list.
/// Changes to a workspace attached here come as its structure instead.
pub const WorkspaceEvent = union(enum) {
    /// Every workspace, answering the list asked for at connect. Owned.
    list: []WorkspaceInfo,
    created: WorkspaceInfo,
    /// Its name, tabs, or active tab changed.
    changed: WorkspaceInfo,
    /// How many connections view it now.
    viewers: struct { id: u32, count: usize },
    destroyed: u32,
    /// Attaching it failed (`attach`), or making one did (`newWorkspace`,
    /// id 0); the reason is logged.
    attach_failed: u32,

    pub fn deinit(self: *WorkspaceEvent, alloc: Allocator) void {
        switch (self.*) {
            .list => |list| {
                for (list) |*w| w.deinit(alloc);
                alloc.free(list);
            },
            .created, .changed => |*w| w.deinit(alloc),
            .viewers, .destroyed, .attach_failed => {},
        }
    }
};

/// A host's slime, reached through the local daemon.
const Remote = struct {
    /// The daemon's id for the host.
    host: u32,
    /// The destination as the sidebar remembers it. Owned.
    dest: []const u16,
    /// The TERM its panes get. Owned.
    term: []const u8,
    /// What the reader attaches. Its ids are owned.
    want: Wanted,
};

/// A host's state as the daemon reports it (rpc.HostState).
pub const HostStatus = enum(u8) {
    connecting = 1,
    connected = 2,
    failed = 3,
    lost = 4,
    gone = 5,
    _,
};

/// A host as the daemon knows it: its id, destination, state, and a
/// status line (what it's doing while connecting, or why it ended).
pub const HostInfo = struct {
    host: u32,
    /// Owned, in the connection's allocator.
    dest: []const u16,
    state: HostStatus,
    /// Owned.
    text: []const u16,

    fn fromJson(alloc: Allocator, h: Json.Host) !HostInfo {
        const dest = try toUtf16(alloc, h.dest);
        errdefer alloc.free(dest);
        const text = try toUtf16(alloc, h.text);
        return .{
            .host = h.id,
            .dest = dest,
            // A state this build doesn't know shows as unknown.
            .state = std.meta.stringToEnum(HostStatus, h.state) orelse @enumFromInt(0xff),
            .text = text,
        };
    }

    fn deinit(self: *HostInfo, alloc: Allocator) void {
        alloc.free(self.dest);
        alloc.free(self.text);
    }
};

/// Something the daemon said about hosts, for the window.
pub const HostEvent = union(enum) {
    /// A host's state changed (or answers a `hostConnect`).
    state: HostInfo,
    /// Logging in to a host asks something of us.
    prompt: struct { host: u32, prompt: *Prompt },
    /// Every host, answering `hostList`. Owned.
    hosts: []HostInfo,

    pub fn deinit(self: *HostEvent, alloc: Allocator) void {
        switch (self.*) {
            .state => |*st| st.deinit(alloc),
            .prompt => |p| p.prompt.destroy(),
            .hosts => |hosts| {
                for (hosts) |*h| h.deinit(alloc);
                alloc.free(hosts);
            },
        }
    }
};

/// A question while logging in to a host (rpc.HostPromptParams), its
/// text in UTF-16 for the chrome.
pub const Prompt = struct {
    arena: std.heap.ArenaAllocator,
    kind: Kind,
    title: []const u16,
    /// The body.
    text: []const u16,
    /// For a monospace box: a key's path, fingerprints.
    detail: []const u16,
    /// Why the last answer didn't work.
    err: []const u16,
    questions: []const Question,

    pub const Kind = enum(u8) {
        password = 1,
        passphrase = 2,
        interactive = 3,
        unknown_host = 4,
        changed_host = 5,
        _,
    };

    /// A field. `label` may run over several lines; the last names the
    /// field.
    pub const Question = struct {
        label: []const u16,
        echo: bool,
    };

    /// More than any login asks at once.
    pub const max_questions = 8;

    fn fromJson(gpa: Allocator, p: Json.HostPrompt) !*Prompt {
        if (p.questions.len > max_questions) return error.TooManyQuestions;
        const self = try gpa.create(Prompt);
        errdefer gpa.destroy(self);
        self.arena = .init(gpa);
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        self.kind = std.meta.stringToEnum(Kind, p.kind) orelse @enumFromInt(0xff);
        self.title = try toUtf16(a, p.title);
        self.text = try toUtf16(a, p.text);
        self.detail = try toUtf16(a, p.detail);
        self.err = try toUtf16(a, p.@"error");
        const questions = try a.alloc(Question, p.questions.len);
        for (questions, p.questions) |*q, src| q.* = .{
            .label = try toUtf16(a, src.label),
            .echo = src.echo,
        };
        self.questions = questions;
        return self;
    }

    pub fn destroy(self: *Prompt) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self);
    }
};

/// The button a prompt was answered with (rpc.Choice).
pub const Choice = enum { cancel, accept, skip };

/// Why attaching to a host's slime failed, for the window to show.
pub const Failure = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const Failure) []const u8 {
        return self.buf[0..self.len];
    }

    fn set(self: *Failure, s: []const u8) void {
        self.len = @min(s.len, self.buf.len);
        @memcpy(self.buf[0..self.len], s[0..self.len]);
    }
};

/// A tab's space in pixels, which its layout's shares divide, and the
/// cell size for panes that haven't said their own (each pane can have
/// its own font). Its fields name rpc.Area's.
pub const Area = struct {
    width: u32,
    height: u32,
    cell_width: u32,
    cell_height: u32,
};

/// A grid size and its cell size in pixels (rpc.Size).
pub const Size = struct {
    cols: u16,
    rows: u16,
    cell_width: u32,
    cell_height: u32,
};

/// Where a live pane's messages go: its session. Each runs on the reader
/// thread (or the UI thread, while adopting), under the connection's
/// lock, and its slices are only valid during the call.
pub const Sink = struct {
    ctx: *anyopaque,
    /// A frame of the pane's screen (frame.zig), to apply in order and
    /// `ack` once drawn.
    draw: *const fn (ctx: *anyopaque, seq: u32, data: []const u8) void,
    /// A piece of a kitty image the pane's frames place, before the
    /// first that does.
    image: *const fn (ctx: *anyopaque, piece: ImagePiece) void,
    notice: *const fn (ctx: *anyopaque, n: Notice) void,
    /// The selection's text, answering a copy event: empty with none.
    copied: *const fn (ctx: *anyopaque, tag: u32, text: []const u8) void,
    /// The pane is gone from us: its child exited (`why` null), or the
    /// workspace or connection was lost (why says how).
    ended: *const fn (ctx: *anyopaque, why: ?[]const u8) void,
};

/// A piece of a kitty image (wire.go's Image): `data` goes at `offset`
/// of its `total` deflated bytes, which inflate to `width * height * 4`
/// of straight RGBA.
pub const ImagePiece = struct {
    id: u32,
    generation: u64,
    width: u32,
    height: u32,
    total: u32,
    offset: u32,
    data: []const u8,
};

/// What a pane did besides change its screen (wire.go's Notice).
pub const Notice = struct {
    kind: Kind,
    /// The new title or pwd (OSC 7's is a file:// URI), or the
    /// clipboard's new text (empty to clear it).
    text: []const u8,
    /// Every program status record, for `status`.
    status: StatusRecords,

    pub const Kind = enum(u8) { title = 1, pwd = 2, bell = 3, clipboard = 4, status = 5, _ };
};

/// Program status records as a message carries them, oldest update
/// first. The ids `next` returns point into the message.
pub const StatusRecords = struct {
    r: Reader,
    left: u32,

    fn init(r: *Reader) !StatusRecords {
        const n = r.readU32() catch 0;
        if (n > r.buf.len / 6) return error.Truncated;
        return .{ .r = r.*, .left = n };
    }

    pub fn next(self: *StatusRecords) ?StatusRecord {
        if (self.left == 0) return null;
        self.left -= 1;
        const id = self.r.readStr() catch return null;
        const state = self.r.readU8() catch return null;
        const progress = self.r.readU8() catch return null;
        return .{ .id = id, .state = state, .progress = if (progress <= 100) progress else null };
    }
};

/// A pane whose attach is in, for the UI thread to make a session of.
pub const Arrival = struct {
    /// Its id, which names its tab and workspace.
    pane: PaneRef,
    /// Owned, in the connection's allocator.
    command: []const u16,
    /// What its programs report doing (OSC 7501), oldest update first.
    /// Owned.
    status: []StatusRecord,

    pub fn deinit(self: *Arrival, alloc: Allocator) void {
        alloc.free(self.command);
        freeStatus(alloc, self.status);
    }
};

/// A program status record as the daemon keeps it (rpc.StatusRecord).
/// `state` numbers as `ProgramStatus.State`.
pub const StatusRecord = struct {
    /// Owned in an `Arrival`.
    id: []const u8,
    state: u8,
    /// 0 to 100, or null for none.
    progress: ?u8,
};

fn freeStatus(alloc: Allocator, status: []StatusRecord) void {
    for (status) |r| alloc.free(r.id);
    alloc.free(status);
}

/// The way a split lays out its children (rpc.Axis).
pub const Axis = enum(u8) {
    /// Left to right, sharing the width.
    row = 1,
    /// Top to bottom, sharing the height.
    column = 2,
};

/// Where a split puts the new pane beside the old (rpc.Direction).
pub const Direction = enum(u8) { right = 1, down = 2, left = 3, up = 4 };

/// A tab's layout tree, as the daemon sends it: `{"pane": "1.2.3"}` or
/// `{"split": {"axis": "row", "children": [{"share": s, "node": n},
/// ...]}}`, which is how std.json reads a tagged union.
pub const Node = union(enum) {
    pane: PaneRef,
    split: struct { axis: Axis, children: []Child },

    /// Written with each split's shares scaled to sum to the whole slime
    /// wants: the window's trees carry pixels.
    pub fn jsonStringify(self: Node, jw: anytype) !void {
        try jw.beginObject();
        switch (self) {
            .pane => |id| {
                try jw.objectField("pane");
                try jw.write(id);
            },
            .split => |sp| {
                try jw.objectField("split");
                try jw.beginObject();
                try jw.objectField("axis");
                try jw.write(sp.axis);
                try jw.objectField("children");
                try jw.beginArray();
                var total: u32 = 0;
                for (sp.children) |c| total += c.share;
                // Scaled from the running total, so rounding doesn't add
                // up; every child keeps at least 1.
                var sum: u32 = 0;
                var given: u32 = 0;
                for (sp.children, 0..) |c, i| {
                    sum += c.share;
                    const left: u32 = @intCast(sp.children.len - 1 - i);
                    const end: u32 = if (total == 0) whole_share * @as(u32, @intCast(i + 1)) / @as(u32, @intCast(sp.children.len)) else @intCast(@as(u64, sum) * whole_share / total);
                    const share = std.math.clamp(end -| given, 1, whole_share - given - left);
                    given += share;
                    try jw.beginObject();
                    try jw.objectField("share");
                    try jw.write(share);
                    try jw.objectField("node");
                    try jw.write(c.node);
                    try jw.endObject();
                }
                try jw.endArray();
                try jw.endObject();
            },
        }
        try jw.endObject();
    }
};

pub const Child = struct {
    /// Basis points of the split's space.
    share: u16,
    node: Node,
};

/// rpc.Whole: what a split's shares sum to.
const whole_share = 10000;

/// Ids are paths (internal/rpc id.go): the daemon numbers workspaces, a
/// workspace its tabs, and a tab its panes, each from a counter that
/// never reuses a number while its owner lives, so a path is never
/// reissued in a daemon's lifetime. On the wire a workspace is its
/// number, a tab "ws.n", and a pane "ws.tab.n"; "" is none. A pane
/// moved to another tab takes that tab's next number.
/// A tab's id (rpc.TabID): workspace `ws`'s tab `n`.
pub const TabRef = struct {
    ws: u32 = 0,
    n: u32 = 0,

    /// No tab: a session of its own, or "" on the wire.
    pub const none: TabRef = .{};

    pub fn isNone(self: TabRef) bool {
        return self.n == 0;
    }

    pub fn eql(a: TabRef, b: TabRef) bool {
        return a.ws == b.ws and a.n == b.n;
    }

    pub fn jsonStringify(self: TabRef, jw: anytype) !void {
        var buf: [24]u8 = undefined;
        const text: []const u8 = if (self.isNone()) "" else std.fmt.bufPrint(&buf, "{d}.{d}", .{ self.ws, self.n }) catch unreachable;
        try jw.write(text);
    }

    pub fn jsonParse(allocator: Allocator, source: anytype, options: std.json.ParseOptions) !TabRef {
        return parseRef(TabRef, try jsonString(allocator, source, options));
    }

    pub fn jsonParseFromValue(_: Allocator, source: std.json.Value, _: std.json.ParseOptions) !TabRef {
        return switch (source) {
            .string => |text| parseRef(TabRef, text),
            else => error.UnexpectedToken,
        };
    }

    pub fn format(self: TabRef, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}.{d}", .{ self.ws, self.n });
    }
};

/// A pane's id (rpc.PaneID): tab (`ws`, `tab`)'s pane `n`.
pub const PaneRef = struct {
    ws: u32 = 0,
    tab: u32 = 0,
    n: u32 = 0,

    /// No pane: a message about none, or "" on the wire.
    pub const none: PaneRef = .{};

    pub fn isNone(self: PaneRef) bool {
        return self.n == 0;
    }

    pub fn eql(a: PaneRef, b: PaneRef) bool {
        return a.ws == b.ws and a.tab == b.tab and a.n == b.n;
    }

    /// The tab it's in.
    pub fn tabRef(self: PaneRef) TabRef {
        return .{ .ws = self.ws, .n = self.tab };
    }

    pub fn jsonStringify(self: PaneRef, jw: anytype) !void {
        var buf: [36]u8 = undefined;
        const text: []const u8 = if (self.isNone()) "" else std.fmt.bufPrint(&buf, "{d}.{d}.{d}", .{ self.ws, self.tab, self.n }) catch unreachable;
        try jw.write(text);
    }

    pub fn jsonParse(allocator: Allocator, source: anytype, options: std.json.ParseOptions) !PaneRef {
        return parseRef(PaneRef, try jsonString(allocator, source, options));
    }

    pub fn jsonParseFromValue(_: Allocator, source: std.json.Value, _: std.json.ParseOptions) !PaneRef {
        return switch (source) {
            .string => |text| parseRef(PaneRef, text),
            else => error.UnexpectedToken,
        };
    }

    pub fn format(self: PaneRef, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}.{d}.{d}", .{ self.ws, self.tab, self.n });
    }
};

/// The next token of a parse, which must be a whole string.
fn jsonString(allocator: Allocator, source: anytype, options: std.json.ParseOptions) ![]const u8 {
    return switch (try source.nextAlloc(allocator, options.allocate orelse .alloc_if_needed)) {
        .string, .allocated_string => |text| text,
        else => error.UnexpectedToken,
    };
}

/// A TabRef or PaneRef from its text: as many positive numbers as it
/// has fields, dotted; "" is none.
fn parseRef(comptime T: type, text: []const u8) error{UnexpectedToken}!T {
    if (text.len == 0) return .none;
    const fields = @typeInfo(T).@"struct".fields;
    var parts: [fields.len]u32 = undefined;
    var it = std.mem.splitScalar(u8, text, '.');
    for (&parts) |*p| {
        const part = it.next() orelse return error.UnexpectedToken;
        p.* = std.fmt.parseUnsigned(u32, part, 10) catch return error.UnexpectedToken;
        if (p.* == 0) return error.UnexpectedToken;
    }
    if (it.next() != null) return error.UnexpectedToken;
    var out: T = undefined;
    inline for (fields, 0..) |f, i| @field(out, f.name) = parts[i];
    return out;
}

/// A workspace's tabs, from its last structure, in its order, with the
/// focus the daemon keeps for every window on it.
pub const Structure = struct {
    arena: std.heap.ArenaAllocator,
    id: u32,
    /// In the arena.
    name: []const u16,
    tabs: []const TabLayout,
    /// The tab shown; none while there are no tabs.
    active_tab: TabRef,
    /// Whether the focus here is current: false while a `focus` call of
    /// ours is unanswered, which the structure may predate.
    focus_known: bool,

    pub const TabLayout = struct {
        id: TabRef,
        root: Node,
        /// The pane that gets input, and the one zoomed (none for none).
        focus: PaneRef,
        zoomed: PaneRef,
    };

    fn destroy(self: *Structure, alloc: Allocator) void {
        self.arena.deinit();
        alloc.destroy(self);
    }
};

/// A tab's focus as the daemon keeps it: the pane with input and the one
/// zoomed (none for none). The tab names the workspace.
pub const Focus = struct {
    tab: TabRef,
    pane: PaneRef,
    zoomed: PaneRef,
};

/// What came since the UI thread last looked (`take`).
pub const Taken = struct {
    /// Panes whose snapshots are in, for sessions to adopt or release.
    arrivals: []Arrival,
    /// The workspaces whose tabs changed, as they are now. Every pane in
    /// them is live or among `arrivals`.
    structures: []*Structure,

    pub fn deinit(self: *Taken, alloc: Allocator) void {
        for (self.arrivals) |*a| a.deinit(alloc);
        alloc.free(self.arrivals);
        for (self.structures) |st| st.destroy(alloc);
        alloc.free(self.structures);
    }
};

/// The control plane's objects as std.json reads them (internal/rpc).
/// Strings point into the parse's arena.
const Json = struct {
    /// A Reply or Notify: whichever fields it has.
    const Envelope = struct {
        id: ?u32 = null,
        method: ?[]const u8 = null,
        params: std.json.Value = .null,
        result: std.json.Value = .null,
        @"error": ?RpcError = null,
    };
    const RpcError = struct { code: i64 = 0, message: []const u8 = "" };
    const Workspace = struct { id: u32, name: []const u8 = "", active_tab: TabRef = .none, tabs: []const Tab = &.{} };
    const Tab = struct { id: TabRef, name: []const u8 = "", tree: Node, focus: PaneRef = .none, zoomed: PaneRef = .none };
    const Created = struct { pane: PaneRef = .none };
    /// `moved_from` is the id the pane had, if it just moved tabs.
    const PaneAttached = struct { id: PaneRef, moved_from: PaneRef = .none, command: []const u8 = "", status: []const Status = &.{} };
    const Status = struct { id: []const u8 = "", state: u8 = 0, progress: i8 = -1 };
    const PaneExited = struct { id: PaneRef, status: u32 = 0 };
    const WorkspaceDetached = struct { id: u32, reason: []const u8 = "" };
    const WorkspaceOpen = struct { id: u32, name: []const u8 = "" };
    const WorkspaceCreated = struct { id: u32, name: []const u8 = "" };
    const WorkspaceDestroyed = struct { id: u32 };
    const WorkspaceViewers = struct { id: u32, viewers: usize = 0 };
    const Host = struct { id: u32, dest: []const u8 = "", state: []const u8 = "", text: []const u8 = "" };
    const HostPrompt = struct {
        host: u32,
        kind: []const u8 = "",
        title: []const u8 = "",
        text: []const u8 = "",
        detail: []const u8 = "",
        @"error": []const u8 = "",
        questions: []const Question = &.{},
    };
    const Question = struct { label: []const u8 = "", echo: bool = false };
    const HostList = struct { hosts: []const Host = &.{} };
    const WorkspaceList = struct { workspaces: []const WorkspaceDesc = &.{} };
    const WorkspaceDesc = struct { id: u32, name: []const u8 = "", attached: bool = false, viewers: usize = 0, detached_at: i64 = 0, active_tab: TabRef = .none, tabs: []const Tab = &.{} };
};

/// A pane attached here. Its key names its tab and workspace.
const Slot = struct {
    state: union(enum) {
        /// Attached, and waiting for the UI thread; what comes for it
        /// meanwhile is kept for adoption.
        pending: Pending,
        live: Sink,
    },
};

const Pending = struct {
    /// Messages for the sink, each u8 type, u32 length, payload.
    kept: std.ArrayList(u8) = .empty,
    command: []const u16 = &.{},
    status: []StatusRecord = &.{},
    /// Handed to `arrivals` already.
    arrived: bool = false,

    fn deinit(self: *Pending, alloc: Allocator) void {
        self.kept.deinit(alloc);
        if (!self.arrived) {
            alloc.free(self.command);
            freeStatus(alloc, self.status);
        }
    }

    fn keep(self: *Pending, alloc: Allocator, f: Frame) !void {
        var head: [5]u8 = undefined;
        head[0] = @intFromEnum(f.type);
        std.mem.writeInt(u32, head[1..5], @intCast(f.payload.len), .little);
        try self.kept.ensureUnusedCapacity(alloc, head.len + f.payload.len);
        self.kept.appendSliceAssumeCapacity(&head);
        self.kept.appendSliceAssumeCapacity(f.payload);
    }

    /// Hand what was kept to `sink`.
    fn replay(self: *const Pending, sink: Sink) void {
        var rest = self.kept.items;
        while (rest.len >= 5) {
            const len = std.mem.readInt(u32, rest[1..5], .little);
            const f: Frame = .{ .type = @enumFromInt(rest[0]), .id = .none, .payload = rest[5..][0..len] };
            deliver(sink, f) catch |err| log.warn("bad message {d} from slime: {}", .{ rest[0], err });
            rest = rest[5 + len ..];
        }
    }
};

/// Connect, starting the daemon if it isn't running, list its workspaces
/// (a `WorkspaceEvent.list`), and attach the ones to show: the one
/// SLIME_WORKSPACE names, else those `want` remembers if this is the
/// daemon it remembers them from, else every one there is; with none, a
/// new one with a tab running `command`. Panes' frames come at most every
/// `frame_interval` µs. The panes wait in `arrivals`; `start` the reader
/// after adopting them. UI thread.
pub fn connect(alloc: Allocator, notify: Notify, frame_interval: u32, area: Area, size: Size, command: []const u16, want: Wanted) !*Daemon {
    var pipe: Pipe = try .open(true);
    errdefer pipe.close();
    const buf = try alloc.alloc(u8, max_frame);
    defer alloc.free(buf);

    const self = try alloc.create(Daemon);
    errdefer alloc.destroy(self);
    self.* = .{ .alloc = alloc, .pipe = pipe, .notify = notify, .frame_interval = frame_interval };
    errdefer self.freeState();
    try self.attachFirst(buf, area, size, command, want);
    return self;
}

/// Connect to the slime on host `host` (the daemon's id for it, which it
/// has `connected`), through a second connection to the local daemon's
/// pipe that it splices to the host's. The reader does the rest: it
/// lists and attaches as `connect` does (`want` says what, any new
/// workspace's tab running the host's shell), and posts `notify` once
/// `state` says how that went. The panes then wait in `arrivals`. `term`
/// is the TERM the host's panes get. UI thread.
pub fn connectRemote(alloc: Allocator, notify: Notify, frame_interval: u32, host_id: u32, dest: []const u16, term: []const u8, area: Area, size: Size, want: Wanted) !*Daemon {
    var pipe: Pipe = try .open(false);
    errdefer pipe.close();
    const owned_dest = try alloc.dupe(u16, dest);
    errdefer alloc.free(owned_dest);
    const owned_term = try alloc.dupe(u8, term);
    errdefer alloc.free(owned_term);
    const owned_ids = try alloc.dupe(u32, want.ids);
    errdefer alloc.free(owned_ids);
    const self = try alloc.create(Daemon);
    errdefer alloc.destroy(self);
    self.* = .{
        .alloc = alloc,
        .pipe = pipe,
        .notify = notify,
        .remote = .{ .host = host_id, .dest = owned_dest, .term = owned_term, .want = .{ .pid = want.pid, .ids = owned_ids, .make = want.make } },
        .state = .init(.connecting),
        .area = area,
        .size = size,
        .frame_interval = frame_interval,
    };
    self.reader = try std.Thread.spawn(.{}, remoteLoop, .{self});
    return self;
}

/// Say hello, subscribe to the workspaces' changes (and the hosts', on
/// the local daemon), list the workspaces, and attach the ones to show,
/// reading the replies in line, before the reader routes frames: the one
/// SLIME_WORKSPACE names (local only), else those `want` remembers if
/// this is the daemon it remembers them from (none, if it remembers
/// none and only lists), else all of them. If `want` says someone waits
/// for a pane: with none left, a new workspace, and a tab running
/// `command` if no attached one has a pane.
fn attachFirst(self: *Daemon, buf: []u8, area: Area, size: Size, command: []const u16, want: Wanted) !void {
    try self.handshake(buf);

    // A host's state changes reach every window; a bridged daemon has
    // none to tell of.
    if (self.remote == null) {
        var sub = try self.awaitReply(buf, try self.call("subscribe", .{ .events = .{ "host.*", "workspace.*" } }), struct {});
        sub.deinit();
    } else {
        var sub = try self.awaitReply(buf, try self.call("subscribe", .{ .events = .{"workspace.*"} }), struct {});
        sub.deinit();
    }

    var list = try self.awaitReply(buf, try self.call("workspace.list", no_params), Json.WorkspaceList);
    defer list.deinit();
    try self.keepList(list.value);

    var ids: std.ArrayList(u32) = .empty;
    defer ids.deinit(self.alloc);
    const requested = if (self.remote == null) requestedWorkspace() else 0;
    if (requested != 0 and listed(list.value, requested)) {
        try ids.append(self.alloc, requested);
    } else {
        const remembered = want.pid == self.pid;
        if (remembered) for (want.ids) |id| {
            if (listed(list.value, id)) try ids.append(self.alloc, id);
        };
        // A window that remembers showing nothing on this daemon shows
        // nothing, while it only lists; one that needs a pane, or has no
        // memory of the daemon, shows everything.
        if (ids.items.len == 0 and (want.make or !remembered)) for (list.value.workspaces) |w| try ids.append(self.alloc, w.id);
    }
    for (ids.items) |id| {
        const call_id = try self.call("workspace.attach", .{ .id = id, .area = area });
        var reply = self.awaitReply(buf, call_id, std.json.Value) catch |err| switch (err) {
            // Gone since the list; the others still show.
            error.Refused => continue,
            else => return err,
        };
        defer reply.deinit();
        _ = try self.applyWorkspace(reply.value);
        log.info("attached workspace {d}", .{id});
    }
    if (!want.make) return;
    if (self.anyAttached() == null) {
        var reply = try self.awaitReply(buf, try self.call("workspace.new", no_params), std.json.Value);
        defer reply.deinit();
        const ws = try self.applyWorkspace(reply.value);
        log.info("created workspace {d}", .{ws});
    }
    // A window needs a pane: a new workspace has none, and attached ones
    // may have lost their last.
    if (self.arrivals.items.len == 0) {
        const ws = self.anyAttached() orelse return;
        var reply = try self.awaitReply(buf, try self.tabNewCall(ws, command, size), struct {});
        reply.deinit();
    }
}

/// Whether `list` has workspace `id`.
fn listed(list: Json.WorkspaceList, id: u32) bool {
    for (list.workspaces) |w| if (w.id == id) return true;
    return false;
}

/// Keep a workspace.list result as a `list` event for the UI thread.
fn keepList(self: *Daemon, list: Json.WorkspaceList) !void {
    const infos = try self.alloc.alloc(WorkspaceInfo, list.workspaces.len);
    var made: usize = 0;
    errdefer {
        for (infos[0..made]) |*w| w.deinit(self.alloc);
        self.alloc.free(infos);
    }
    for (infos, list.workspaces) |*out, w| {
        out.* = try WorkspaceInfo.fromJson(self.alloc, w.id, w.name, w.tabs.len, w.active_tab, w.viewers);
        made += 1;
    }
    win32.AcquireSRWLockExclusive(&self.lock);
    defer win32.ReleaseSRWLockExclusive(&self.lock);
    try self.workspaceEventLocked(.{ .list = infos });
}

/// Start the reader, once the panes from `connect` are adopted.
pub fn start(self: *Daemon) !void {
    self.posting.store(true, .release);
    self.reader = try std.Thread.spawn(.{}, readLoop, .{self});
}

/// Hang up, which detaches the workspace; the daemon keeps it. Every
/// session must have released its pane. UI thread.
pub fn deinit(self: *Daemon) void {
    self.closing.store(true, .release);
    if (self.reader) |t| {
        // Wake it until it's gone: a cancel that lands before it blocks in
        // ReadFile again is lost.
        while (win32.WaitForSingleObject(t.getHandle(), 0) != win32.WAIT_OBJECT_0) {
            _ = win32.CancelIoEx(self.pipe.read_h, null);
            _ = win32.WaitForSingleObject(t.getHandle(), 20);
        }
        t.join();
    }
    self.pipe.close();
    self.freeState();
    self.alloc.destroy(self);
}

/// The daemon's id for the host this is bridged to; null for the local
/// daemon.
pub fn host(self: *const Daemon) ?u32 {
    return if (self.remote) |r| r.host else null;
}

/// The host's destination as the sidebar remembers it; null for the
/// local daemon.
pub fn hostDest(self: *const Daemon) ?[]const u16 {
    return if (self.remote) |r| r.dest else null;
}

/// The host, for showing; empty for the local daemon.
pub fn hostLabel(self: *const Daemon) []const u16 {
    return if (self.remote) |r| Hosts.label(r.dest) else &.{};
}

/// How attaching went. The reader posts `notify` when it changes.
pub fn attachState(self: *const Daemon) State {
    return self.state.load(.acquire);
}

/// Every pane was lost to us: the connection ended, or another window
/// took the workspace. UI thread.
pub fn isLost(self: *Daemon) bool {
    win32.AcquireSRWLockExclusive(&self.lock);
    defer win32.ReleaseSRWLockExclusive(&self.lock);
    return self.lost;
}

/// A host's reader: ask the local daemon for the bridge, attach, then
/// route frames as `readLoop` does.
fn remoteLoop(self: *Daemon) void {
    const buf = self.alloc.alloc(u8, max_frame) catch return self.fail(error.OutOfMemory);
    defer self.alloc.free(buf);
    const r = self.remote.?;
    var p: std.ArrayList(u8) = .empty;
    defer p.deinit(self.alloc);
    putU32(self.alloc, &p, r.host) catch return self.fail(error.OutOfMemory);
    putStr(self.alloc, &p, r.term) catch return self.fail(error.OutOfMemory);
    self.send(.bridge, .none, p.items) catch |err| return self.fail(err);
    // The host's own shell: the command is for its slime to run.
    self.attachFirst(buf, self.area, self.size, &.{}, r.want) catch |err| return self.fail(err);
    log.info("attached {d} workspace(s) on {f}", .{ self.attached.count(), std.unicode.fmtUtf16Le(self.hostLabel()) });
    self.state.store(.attached, .release);
    self.posting.store(true, .release);
    _ = win32.PostMessageW(self.notify.hwnd, self.notify.msg, 0, 0);
    self.route(buf);
}

/// A host's slime couldn't attach: say why, which for a bridge the
/// daemon refused or ended is what it said. Nobody's told if `deinit`
/// is hanging up.
fn fail(self: *Daemon, err: anyerror) void {
    if (self.closing.load(.acquire)) return;
    const text = switch (err) {
        error.Refused => if (self.failure.len > 0) self.failure.text() else "slime refused to attach",
        error.EndOfStream => if (self.lost_reason.len > 0) self.lost_reason.text() else "slime hung up",
        error.VersionMismatch => "its slime doesn't match this slime-gui",
        error.OutOfMemory => "out of memory",
        else => @errorName(err),
    };
    log.info("no slime on {f}: {s}", .{ std.unicode.fmtUtf16Le(self.hostLabel()), text });
    self.failure.set(text);
    self.state.store(.failed, .release);
    _ = win32.PostMessageW(self.notify.hwnd, self.notify.msg, 0, 0);
}

fn freeState(self: *Daemon) void {
    var it = self.panes.valueIterator();
    while (it.next()) |slot| switch (slot.state) {
        .pending => |*pend| pend.deinit(self.alloc),
        .live => {},
    };
    self.panes.deinit(self.alloc);
    for (self.arrivals.items) |*a| a.deinit(self.alloc);
    self.arrivals.deinit(self.alloc);
    self.attached.deinit(self.alloc);
    self.focus_calls.deinit(self.alloc);
    self.attach_calls.deinit(self.alloc);
    self.host_lists.deinit(self.alloc);
    self.opens.deinit(self.alloc);
    for (self.structures.items) |st| st.destroy(self.alloc);
    self.structures.deinit(self.alloc);
    for (self.host_events.items) |*e| e.deinit(self.alloc);
    self.host_events.deinit(self.alloc);
    for (self.workspace_events.items) |*e| e.deinit(self.alloc);
    self.workspace_events.deinit(self.alloc);
    if (self.remote) |r| {
        self.alloc.free(r.dest);
        self.alloc.free(r.term);
        self.alloc.free(r.want.ids);
    }
}

/// A connection to nothing, for tests of what the app lists on one: its
/// calls fail quietly, as a lost daemon's do.
pub fn unconnected(alloc: Allocator) Daemon {
    return .{
        .alloc = alloc,
        .pipe = .{ .read_h = win32.INVALID_HANDLE_VALUE, .write_h = win32.INVALID_HANDLE_VALUE, .events = .{ win32.INVALID_HANDLE_VALUE, win32.INVALID_HANDLE_VALUE } },
        .notify = .{ .hwnd = undefined, .msg = 0 },
    };
}

/// Take what the daemon said about hosts since the last look, in order.
/// The caller owns them (`HostEvent.deinit` each, then free the slice).
/// UI thread.
pub fn takeHosts(self: *Daemon) []HostEvent {
    win32.AcquireSRWLockExclusive(&self.lock);
    defer win32.ReleaseSRWLockExclusive(&self.lock);
    return self.host_events.toOwnedSlice(self.alloc) catch &.{};
}

/// Ask the daemon to log in to `dest` (`ssh://[user@]host[:port]`, or
/// whatever its ssh config knows) and put slime there. Its prompts and
/// states come as `HostEvent`s; the reply, and a host already
/// connected's state, come as a `state` event too. Returns the call's
/// id. UI thread.
pub fn hostConnect(self: *Daemon, dest: []const u16) !u32 {
    const utf8 = try commandUtf8(self.alloc, dest);
    defer self.alloc.free(utf8);
    return self.call("host.connect", .{ .dest = utf8 });
}

/// Reply to the last prompt for `host_id`, one answer per question. A
/// cancel with no prompt waiting gives up on logging in. UI thread.
pub fn hostAnswer(self: *Daemon, host_id: u32, choice: Choice, answers: []const []const u16) !void {
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const utf8 = try a.alloc([]const u8, answers.len);
    for (utf8, answers) |*out, units| out.* = try commandUtf8(a, units);
    _ = try self.call("host.answer", .{ .host = host_id, .choice = choice, .answers = utf8 });
}

/// Hang up on `host_id`, ending its bridges, or give up on logging in to
/// it. UI thread.
pub fn hostDisconnect(self: *Daemon, host_id: u32) void {
    _ = self.call("host.disconnect", .{ .host = host_id }) catch {};
}

/// Ask for every host; the answer is a `HostEvent.hosts`. UI thread.
pub fn hostList(self: *Daemon) void {
    const id = self.call("host.list", no_params) catch return;
    win32.AcquireSRWLockExclusive(&self.lock);
    defer win32.ReleaseSRWLockExclusive(&self.lock);
    self.host_lists.append(self.alloc, id) catch {};
}

/// Take what the daemon said about workspaces not attached here since the
/// last look, in order. The caller owns them (`WorkspaceEvent.deinit`
/// each, then free the slice). UI thread.
pub fn takeWorkspaces(self: *Daemon) []WorkspaceEvent {
    win32.AcquireSRWLockExclusive(&self.lock);
    defer win32.ReleaseSRWLockExclusive(&self.lock);
    return self.workspace_events.toOwnedSlice(self.alloc) catch &.{};
}

/// Take the panes waiting for sessions and the latest tabs of each
/// workspace that changed, together so the tabs name no pane the caller
/// hasn't seen. The caller owns them (`Taken.deinit`) and must `adopt`
/// or `release` each arrival. UI thread.
pub fn take(self: *Daemon) Taken {
    win32.AcquireSRWLockExclusive(&self.lock);
    defer win32.ReleaseSRWLockExclusive(&self.lock);
    return .{
        .arrivals = self.arrivals.toOwnedSlice(self.alloc) catch &.{},
        .structures = self.structures.toOwnedSlice(self.alloc) catch &.{},
    };
}

/// Take the workspaces the daemon said to open here, in order. The
/// caller owns the slice. UI thread.
pub fn takeOpens(self: *Daemon) []u32 {
    win32.AcquireSRWLockExclusive(&self.lock);
    defer win32.ReleaseSRWLockExclusive(&self.lock);
    return self.opens.toOwnedSlice(self.alloc) catch &.{};
}

/// Attach workspace `ws`, with the window's tab area: its panes arrive
/// through `arrivals` with its structure, or a `WorkspaceEvent`
/// says attaching failed. UI thread.
pub fn attach(self: *Daemon, ws: u32, area: Area) !void {
    win32.AcquireSRWLockExclusive(&self.lock);
    try self.attached.ensureUnusedCapacity(self.alloc, 1);
    try self.attach_calls.ensureUnusedCapacity(self.alloc, 1);
    win32.ReleaseSRWLockExclusive(&self.lock);
    const id = try self.call("workspace.attach", .{ .id = ws, .area = area });
    win32.AcquireSRWLockExclusive(&self.lock);
    defer win32.ReleaseSRWLockExclusive(&self.lock);
    // From now: a structure that beats the reply is this workspace's.
    self.attached.putAssumeCapacity(ws, {});
    self.attach_calls.appendAssumeCapacity(.{ .id = id, .ws = ws });
}

/// Let go of workspace `ws`; the daemon keeps it. After its sessions
/// have released their panes: any still waiting are dropped. UI thread.
pub fn detach(self: *Daemon, ws: u32) void {
    _ = self.call("workspace.detach", .{ .id = ws }) catch {};
    win32.AcquireSRWLockExclusive(&self.lock);
    defer win32.ReleaseSRWLockExclusive(&self.lock);
    _ = self.attached.remove(ws);
    self.dropWorkspaceLocked(ws, null);
}

/// Make a workspace named `name` (empty for the daemon's default) with a
/// tab running `command`, attached here: its panes arrive through
/// `arrivals`, or a `WorkspaceEvent` says it failed. UI thread.
pub fn newWorkspace(self: *Daemon, name: []const u16, command: []const u16) !void {
    const utf8 = try commandUtf8(self.alloc, name);
    defer self.alloc.free(utf8);
    const cmd = try commandUtf8(self.alloc, command);
    defer self.alloc.free(cmd);
    win32.AcquireSRWLockExclusive(&self.lock);
    try self.attach_calls.ensureUnusedCapacity(self.alloc, 1);
    win32.ReleaseSRWLockExclusive(&self.lock);
    const id = try self.call("workspace.new", .{ .name = utf8, .tabs = .{.{ .pane = .{ .command = cmd } }} });
    win32.AcquireSRWLockExclusive(&self.lock);
    defer win32.ReleaseSRWLockExclusive(&self.lock);
    self.attach_calls.appendAssumeCapacity(.{ .id = id, .ws = 0 });
}

/// End workspace `ws` and everything in it. UI thread.
pub fn killWorkspace(self: *Daemon, ws: u32) void {
    _ = self.call("workspace.kill", .{ .id = ws }) catch {};
}

/// Rename workspace `ws`. The name comes back in its structure, or a
/// `changed` event. UI thread.
pub fn renameWorkspace(self: *Daemon, ws: u32, name: []const u16) !void {
    const utf8 = try commandUtf8(self.alloc, name);
    defer self.alloc.free(utf8);
    _ = try self.call("workspace.rename", .{ .id = ws, .name = utf8 });
}

/// Whether workspace `ws` is attached here. Any thread.
fn isAttached(self: *Daemon, ws: u32) bool {
    win32.AcquireSRWLockExclusive(&self.lock);
    defer win32.ReleaseSRWLockExclusive(&self.lock);
    return self.attached.contains(ws);
}

/// Some workspace attached here, if any.
fn anyAttached(self: *Daemon) ?u32 {
    win32.AcquireSRWLockExclusive(&self.lock);
    defer win32.ReleaseSRWLockExclusive(&self.lock);
    var it = self.attached.keyIterator();
    return if (it.next()) |k| k.* else null;
}

/// Make `sink` the pane's: what came while it waited goes first, then
/// what comes live. UI thread.
pub fn adopt(self: *Daemon, pane: PaneRef, sink: Sink) void {
    win32.AcquireSRWLockExclusive(&self.lock);
    defer win32.ReleaseSRWLockExclusive(&self.lock);
    const slot = self.panes.getPtr(pane) orelse {
        // It ended before the UI thread got to it.
        sink.ended(sink.ctx, "ended before it was shown");
        return;
    };
    switch (slot.state) {
        .pending => |*pend| {
            pend.replay(sink);
            pend.deinit(self.alloc);
        },
        .live => {},
    }
    slot.state = .{ .live = sink };
    if (self.lost) sink.ended(sink.ctx, "lost slime");
}

/// Forget a pane: its session is going. Doesn't end it. UI thread.
pub fn release(self: *Daemon, pane: PaneRef) void {
    win32.AcquireSRWLockExclusive(&self.lock);
    defer win32.ReleaseSRWLockExclusive(&self.lock);
    if (self.panes.fetchRemove(pane)) |kv| switch (kv.value.state) {
        .pending => |pend| {
            var p = pend;
            p.deinit(self.alloc);
        },
        .live => {},
    };
}

/// Send a pane an event (event.zig), which must fit a message. UI
/// thread.
pub fn event(self: *Daemon, pane: PaneRef, data: []const u8) void {
    if (data.len > max_frame - header_len) return log.warn("dropped a {d}-byte event: too big", .{data.len});
    self.send(.event, pane, data) catch {};
}

/// Say the pane's frame `seq` and those before it are drawn, which lets
/// more come. UI thread.
pub fn ack(self: *Daemon, pane: PaneRef, seq: u32) void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, seq, .little);
    self.send(.ack, pane, &b) catch {};
}

pub fn resize(self: *Daemon, pane: PaneRef, size: Size) void {
    var b: [12]u8 = undefined;
    writeSize(&b, size);
    self.send(.resize, pane, &b) catch {};
}

/// Tell the daemon the window's tab area, for every workspace attached
/// here, for sizing panes it lays out while the window is away. UI
/// thread.
pub fn resizeWorkspaces(self: *Daemon, area: Area) void {
    var ids: [64]u32 = undefined;
    var n: usize = 0;
    win32.AcquireSRWLockExclusive(&self.lock);
    var it = self.attached.keyIterator();
    while (it.next()) |k| : (n += 1) {
        if (n == ids.len) break;
        ids[n] = k.*;
    }
    win32.ReleaseSRWLockExclusive(&self.lock);
    for (ids[0..n]) |ws| _ = self.call("workspace.resize", .{ .id = ws, .area = area }) catch {};
}

/// End a pane, not just our view of it.
pub fn kill(self: *Daemon, pane: PaneRef) void {
    _ = self.call("pane.kill", .{ .id = pane }) catch {};
}

/// Ask for a new tab in workspace `ws` running `command`. Its pane
/// arrives through `arrivals`, focused in the structure that comes with
/// it: a viewer's own new pane takes the focus. UI thread.
pub fn tabNew(self: *Daemon, ws: u32, command: []const u16, size: Size) !void {
    _ = try self.tabNewCall(ws, command, size);
}

fn tabNewCall(self: *Daemon, ws: u32, command: []const u16, size: Size) !u32 {
    const cmd = try commandUtf8(self.alloc, command);
    defer self.alloc.free(cmd);
    return self.call("tab.new", .{ .workspace = ws, .command = cmd, .size = size });
}

/// Ask for a pane running `command` on side `dir` of `pane`, taking half
/// its space. It arrives through `arrivals`, focused as `tabNew`'s. UI
/// thread.
pub fn split(self: *Daemon, pane: PaneRef, dir: Direction, command: []const u16) !void {
    const cmd = try commandUtf8(self.alloc, command);
    defer self.alloc.free(cmd);
    _ = try self.call("pane.split", .{ .pane = pane, .direction = dir, .share = 5000, .command = cmd });
}

/// Replace tab `tab`'s tree with `root`, which must hold the same panes:
/// a divider was dragged. Each split's shares are scaled to sum to the
/// whole slime wants. The tree comes back as workspace.changed. UI
/// thread.
pub fn layout(self: *Daemon, tab: TabRef, root: Node) !void {
    _ = try self.call("tab.layout", .{ .id = tab, .tree = root });
}

/// Tell the daemon the focus moved here: `f.tab` is shown in its
/// workspace, with `f.pane` focused and `f.zoomed` zoomed (none for
/// none). Every other window on the workspace follows; this one doesn't
/// hear its own change, and takes no focus from a structure until the
/// reply says this one is in. UI thread.
pub fn focus(self: *Daemon, f: Focus) !void {
    win32.AcquireSRWLockExclusive(&self.lock);
    try self.focus_calls.ensureUnusedCapacity(self.alloc, 1);
    win32.ReleaseSRWLockExclusive(&self.lock);
    const id = try self.call("workspace.focus", .{ .tab = f.tab, .pane = f.pane, .zoomed = f.zoomed });
    win32.AcquireSRWLockExclusive(&self.lock);
    defer win32.ReleaseSRWLockExclusive(&self.lock);
    // The reply can't have come yet: it's read under this lock.
    self.focus_calls.appendAssumeCapacity(id);
}

/// Send a Call of `method` with `params` (any value std.json writes as
/// an object) and return its id.
fn call(self: *Daemon, method: []const u8, params: anytype) !u32 {
    const id = self.nextId();
    const body = try encodeCall(self.alloc, id, method, params);
    defer self.alloc.free(body);
    try self.send(.call, .none, body);
    return id;
}

/// A JSON-RPC request, as rpc.Request lays it out.
fn encodeCall(alloc: Allocator, id: u32, method: []const u8, params: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(alloc, .{
        .jsonrpc = "2.0",
        .id = id,
        .method = method,
        .params = params,
    }, .{});
}

fn commandUtf8(alloc: Allocator, command: []const u16) ![]u8 {
    return std.unicode.utf16LeToUtf8Alloc(alloc, command) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadCommand,
    };
}

fn nextId(self: *Daemon) u32 {
    while (true) {
        const t = self.next_id.fetchAdd(1, .monotonic) +% 1;
        if (t != 0) return t;
    }
}

fn send(self: *Daemon, msg: MsgType, id: PaneRef, payload: []const u8) !void {
    win32.AcquireSRWLockExclusive(&self.write_lock);
    defer win32.ReleaseSRWLockExclusive(&self.write_lock);
    try self.pipe.send(msg, id, payload);
}

/// A call's result, parsed as `R` into an arena of its own.
fn Result(comptime R: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        value: R,

        fn deinit(self: *@This()) void {
            self.arena.deinit();
        }
    };
}

/// Read frames in line until the reply to call `id`, handling the rest
/// as the reader would, and return its result. A reply with an error
/// fails with `error.Refused`, the message kept in `failure`. Before the
/// reader starts.
fn awaitReply(self: *Daemon, buf: []u8, id: u32, comptime R: type) !Result(R) {
    while (true) {
        const f = try self.pipe.readFrame(buf);
        if (f.type != .reply) {
            try self.handle(f);
            continue;
        }
        var arena: std.heap.ArenaAllocator = .init(self.alloc);
        errdefer arena.deinit();
        const a = arena.allocator();
        const env = try std.json.parseFromSliceLeaky(Json.Envelope, a, f.payload, json_opts);
        if (env.id != id) {
            self.replied(env);
            arena.deinit();
            continue;
        }
        if (env.@"error") |e| {
            log.err("slime: {s} (code {d})", .{ e.message, e.code });
            self.failure.set(e.message);
            return error.Refused;
        }
        self.replied(env);
        const value = try std.json.parseFromValueLeaky(R, a, env.result, json_opts);
        return .{ .arena = arena, .value = value };
    }
}

/// Reader thread for the local daemon.
fn readLoop(self: *Daemon) void {
    const buf = self.alloc.alloc(u8, max_frame) catch {
        if (!self.closing.load(.acquire)) self.loseAll("out of memory");
        return;
    };
    defer self.alloc.free(buf);
    self.route(buf);
}

/// Route frames until the connection ends, then tell every live pane:
/// for a host's, why the daemon ended the bridge, if it said.
fn route(self: *Daemon, buf: []u8) void {
    while (true) {
        const f = self.pipe.readFrame(buf) catch break;
        self.handle(f) catch |err| {
            log.warn("bad message {d} from slime: {}", .{ @intFromEnum(f.type), err });
        };
    }
    if (self.closing.load(.acquire)) return;
    self.loseAll(if (self.lost_reason.len > 0) self.lost_reason.text() else "lost slime");
}

/// Act on one frame.
fn handle(self: *Daemon, f: Frame) !void {
    switch (f.type) {
        .notify, .reply => {
            var arena: std.heap.ArenaAllocator = .init(self.alloc);
            defer arena.deinit();
            const a = arena.allocator();
            const env = try std.json.parseFromSliceLeaky(Json.Envelope, a, f.payload, json_opts);
            if (f.type == .reply) {
                if (env.@"error") |e| log.warn("slime: {s} (code {d})", .{ e.message, e.code });
                self.replied(env);
                return;
            }
            const method = env.method orelse return error.NoMethod;
            try self.notified(a, method, env.params);
        },
        .draw, .image, .notice, .copied => {
            win32.AcquireSRWLockExclusive(&self.lock);
            defer win32.ReleaseSRWLockExclusive(&self.lock);
            if (self.panes.getPtr(f.id)) |slot| switch (slot.state) {
                .pending => |*pend| try pend.keep(self.alloc, f),
                .live => |sink| try deliver(sink, f),
            };
        },
        .@"error" => {
            var r: Reader = .{ .buf = f.payload };
            const msg = try r.readStr();
            log.warn("slime: {s}", .{msg});
            self.lost_reason.set(msg);
        },
        else => {},
    }
}

/// Act on a notification. `a` is an arena for the parse.
fn notified(self: *Daemon, a: Allocator, method: []const u8, params: std.json.Value) !void {
    const Event = enum {
        @"pane.attached",
        @"pane.exited",
        @"workspace.changed",
        @"workspace.detached",
        @"workspace.open",
        @"workspace.created",
        @"workspace.destroyed",
        @"workspace.viewer_joined",
        @"workspace.viewer_left",
        @"host.changed",
        @"host.prompt",
    };
    const ev = std.meta.stringToEnum(Event, method) orelse return;
    switch (ev) {
        .@"pane.attached" => {
            const p = try std.json.parseFromValueLeaky(Json.PaneAttached, a, params, json_opts);
            const command = try toUtf16(self.alloc, p.command);
            errdefer self.alloc.free(command);
            const status = try self.alloc.alloc(StatusRecord, p.status.len);
            var made: usize = 0;
            errdefer freeStatus(self.alloc, status[0..made]);
            for (status, p.status) |*rec, src| {
                rec.* = .{
                    .id = try self.alloc.dupe(u8, src.id),
                    .state = src.state,
                    .progress = if (src.progress >= 0 and src.progress <= 100) @intCast(src.progress) else null,
                };
                made += 1;
            }
            win32.AcquireSRWLockExclusive(&self.lock);
            defer win32.ReleaseSRWLockExclusive(&self.lock);
            const gop = try self.panes.getOrPut(self.alloc, p.id);
            if (gop.found_existing) switch (gop.value_ptr.state) {
                .pending => |*old| old.deinit(self.alloc),
                .live => {},
            };
            gop.value_ptr.* = .{ .state = .{ .pending = .{ .command = command, .status = status } } };
        },
        .@"pane.exited" => {
            const p = try std.json.parseFromValueLeaky(Json.PaneExited, a, params, json_opts);
            win32.AcquireSRWLockExclusive(&self.lock);
            defer win32.ReleaseSRWLockExclusive(&self.lock);
            if (self.panes.fetchRemove(p.id)) |kv| switch (kv.value.state) {
                .pending => |pend| {
                    var pd = pend;
                    pd.deinit(self.alloc);
                },
                .live => |sink| sink.ended(sink.ctx, null),
            };
        },
        .@"workspace.changed" => {
            // An attached workspace's is its structure; another's just
            // updates the list.
            const id = switch (params) {
                .object => |o| switch (o.get("id") orelse return error.NoWorkspace) {
                    .integer => |i| std.math.cast(u32, i) orelse return error.NoWorkspace,
                    else => return error.NoWorkspace,
                },
                else => return error.NoWorkspace,
            };
            if (self.isAttached(id)) {
                _ = try self.applyWorkspace(params);
            } else {
                const ws = try std.json.parseFromValueLeaky(Json.Workspace, a, params, json_opts);
                const info = try WorkspaceInfo.fromJson(self.alloc, ws.id, ws.name, ws.tabs.len, ws.active_tab, null);
                win32.AcquireSRWLockExclusive(&self.lock);
                defer win32.ReleaseSRWLockExclusive(&self.lock);
                try self.workspaceEventLocked(.{ .changed = info });
            }
        },
        .@"workspace.detached" => {
            const p = try std.json.parseFromValueLeaky(Json.WorkspaceDetached, a, params, json_opts);
            win32.AcquireSRWLockExclusive(&self.lock);
            defer win32.ReleaseSRWLockExclusive(&self.lock);
            if (self.attached.remove(p.id)) {
                var buf: [256]u8 = undefined;
                self.dropWorkspaceLocked(p.id, std.fmt.bufPrint(&buf, "detached: {s}", .{p.reason}) catch "detached");
            }
        },
        .@"workspace.created" => {
            const p = try std.json.parseFromValueLeaky(Json.WorkspaceCreated, a, params, json_opts);
            const info = try WorkspaceInfo.fromJson(self.alloc, p.id, p.name, 0, .none, 0);
            win32.AcquireSRWLockExclusive(&self.lock);
            defer win32.ReleaseSRWLockExclusive(&self.lock);
            try self.workspaceEventLocked(.{ .created = info });
        },
        .@"workspace.destroyed" => {
            const p = try std.json.parseFromValueLeaky(Json.WorkspaceDestroyed, a, params, json_opts);
            win32.AcquireSRWLockExclusive(&self.lock);
            defer win32.ReleaseSRWLockExclusive(&self.lock);
            if (self.attached.remove(p.id)) self.dropWorkspaceLocked(p.id, "workspace destroyed");
            try self.workspaceEventLocked(.{ .destroyed = p.id });
        },
        .@"workspace.viewer_joined", .@"workspace.viewer_left" => {
            const p = try std.json.parseFromValueLeaky(Json.WorkspaceViewers, a, params, json_opts);
            win32.AcquireSRWLockExclusive(&self.lock);
            defer win32.ReleaseSRWLockExclusive(&self.lock);
            try self.workspaceEventLocked(.{ .viewers = .{ .id = p.id, .count = p.viewers } });
        },
        .@"workspace.open" => {
            const p = try std.json.parseFromValueLeaky(Json.WorkspaceOpen, a, params, json_opts);
            win32.AcquireSRWLockExclusive(&self.lock);
            defer win32.ReleaseSRWLockExclusive(&self.lock);
            try self.opens.append(self.alloc, p.id);
            if (self.posting.load(.acquire)) _ = win32.PostMessageW(self.notify.hwnd, self.notify.msg, 0, 0);
        },
        .@"host.changed" => {
            const h = try std.json.parseFromValueLeaky(Json.Host, a, params, json_opts);
            const info = try HostInfo.fromJson(self.alloc, h);
            win32.AcquireSRWLockExclusive(&self.lock);
            defer win32.ReleaseSRWLockExclusive(&self.lock);
            try self.hostEventLocked(.{ .state = info });
        },
        .@"host.prompt" => {
            const p = try std.json.parseFromValueLeaky(Json.HostPrompt, a, params, json_opts);
            const prompt = try Prompt.fromJson(self.alloc, p);
            errdefer prompt.destroy();
            win32.AcquireSRWLockExclusive(&self.lock);
            defer win32.ReleaseSRWLockExclusive(&self.lock);
            try self.hostEventLocked(.{ .prompt = .{ .host = p.host, .prompt = prompt } });
        },
    }
}

/// A reply came: if it answers a `focus` call, structures from now on
/// carry its focus; if it answers an `attach` or `newWorkspace`, its
/// result is the workspace's structure, or the failure is passed on; if
/// it answers `hostList`, keep the hosts.
fn replied(self: *Daemon, env: Json.Envelope) void {
    const id = env.id orelse return;
    const attaching: ?AttachCall = attaching: {
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        for (self.attach_calls.items, 0..) |call_out, i| {
            if (call_out.id != id) continue;
            _ = self.attach_calls.swapRemove(i);
            break :attaching call_out;
        }
        break :attaching null;
    };
    if (attaching) |at| {
        if (env.@"error" == null) {
            if (self.applyWorkspace(env.result)) |_| return else |err| log.warn("bad workspace from slime: {}", .{err});
        }
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        if (at.ws != 0) _ = self.attached.remove(at.ws);
        self.workspaceEventLocked(.{ .attach_failed = at.ws }) catch {};
        return;
    }
    win32.AcquireSRWLockExclusive(&self.lock);
    defer win32.ReleaseSRWLockExclusive(&self.lock);
    if (std.mem.indexOfScalar(u32, self.focus_calls.items, id)) |i| {
        _ = self.focus_calls.orderedRemove(i);
        return;
    }
    if (std.mem.indexOfScalar(u32, self.host_lists.items, id)) |i| {
        _ = self.host_lists.swapRemove(i);
        var arena: std.heap.ArenaAllocator = .init(self.alloc);
        defer arena.deinit();
        const list = std.json.parseFromValueLeaky(Json.HostList, arena.allocator(), env.result, json_opts) catch return;
        const hosts = self.alloc.alloc(HostInfo, list.hosts.len) catch return;
        var made: usize = 0;
        errdefer {
            for (hosts[0..made]) |*h| h.deinit(self.alloc);
            self.alloc.free(hosts);
        }
        for (hosts, list.hosts) |*h, src| {
            h.* = HostInfo.fromJson(self.alloc, src) catch return;
            made += 1;
        }
        self.hostEventLocked(.{ .hosts = hosts }) catch {};
    }
}

/// Keep a host event for the UI thread, which is told. Under the lock;
/// takes `e` even on failure.
fn hostEventLocked(self: *Daemon, e: HostEvent) !void {
    var ev = e;
    self.host_events.append(self.alloc, ev) catch |err| {
        ev.deinit(self.alloc);
        return err;
    };
    if (self.posting.load(.acquire)) _ = win32.PostMessageW(self.notify.hwnd, self.notify.msg, 0, 0);
}

/// Keep a workspace event for the UI thread, which is told. Under the
/// lock; takes `e` even on failure.
fn workspaceEventLocked(self: *Daemon, e: WorkspaceEvent) !void {
    var ev = e;
    self.workspace_events.append(self.alloc, ev) catch |err| {
        ev.deinit(self.alloc);
        return err;
    };
    if (self.posting.load(.acquire)) _ = win32.PostMessageW(self.notify.hwnd, self.notify.msg, 0, 0);
}

/// An attached workspace's structure (rpc.Workspace), from
/// workspace.changed or the reply to an attach or a workspace.new: the
/// workspace is attached from now, panes in it that attached go to
/// `arrivals`, in layout order, and its tabs replace its last
/// structure in `structures`. Returns the workspace's id.
fn applyWorkspace(self: *Daemon, value: std.json.Value) !u32 {
    const st = try self.alloc.create(Structure);
    st.* = .{ .arena = .init(self.alloc), .id = 0, .name = &.{}, .tabs = &.{}, .active_tab = .none, .focus_known = true };
    errdefer st.destroy(self.alloc);
    const a = st.arena.allocator();
    const ws = try std.json.parseFromValueLeaky(Json.Workspace, a, value, json_opts);
    const tabs = try a.alloc(Structure.TabLayout, ws.tabs.len);
    for (tabs, ws.tabs) |*out, t| out.* = .{ .id = t.id, .root = t.tree, .focus = t.focus, .zoomed = t.zoomed };
    st.id = ws.id;
    st.name = try toUtf16(a, ws.name);
    st.tabs = tabs;
    st.active_tab = ws.active_tab;

    win32.AcquireSRWLockExclusive(&self.lock);
    defer win32.ReleaseSRWLockExclusive(&self.lock);
    try self.attached.put(self.alloc, ws.id, {});
    st.focus_known = self.focus_calls.items.len == 0;
    for (tabs) |t| try self.arriveLocked(t.root);
    for (self.structures.items) |*old| {
        if (old.*.id != ws.id) continue;
        old.*.destroy(self.alloc);
        old.* = st;
        break;
    } else try self.structures.append(self.alloc, st);
    if (self.posting.load(.acquire)) _ = win32.PostMessageW(self.notify.hwnd, self.notify.msg, 0, 0);
    return ws.id;
}

/// Hand the pending panes of a tab's tree to `arrivals`, in order.
fn arriveLocked(self: *Daemon, node: Node) !void {
    switch (node) {
        .pane => |pane| {
            const slot = self.panes.getPtr(pane) orelse return;
            const pend = switch (slot.state) {
                .pending => |*p| p,
                .live => return,
            };
            if (pend.arrived) return;
            try self.arrivals.append(self.alloc, .{
                .pane = pane,
                .command = pend.command,
                .status = pend.status,
            });
            pend.arrived = true;
        },
        .split => |sp| for (sp.children) |c| try self.arriveLocked(c.node),
    }
}

/// Drop every pane of workspace `ws`: live ones are told `why`, if
/// given (the daemon took the workspace away); pending ones go quietly.
/// Under the lock.
fn dropWorkspaceLocked(self: *Daemon, ws: u32, why: ?[]const u8) void {
    var gone: std.ArrayList(PaneRef) = .empty;
    defer gone.deinit(self.alloc);
    var it = self.panes.iterator();
    while (it.next()) |kv| {
        if (kv.key_ptr.ws != ws) continue;
        switch (kv.value_ptr.state) {
            .pending => |*pend| {
                // Its arrival, if handed out, still names it: the UI
                // thread's adopt finds no slot and ends it at once.
                pend.deinit(self.alloc);
                gone.append(self.alloc, kv.key_ptr.*) catch {};
            },
            .live => |sink| if (why) |reason| {
                sink.ended(sink.ctx, reason);
                gone.append(self.alloc, kv.key_ptr.*) catch {};
            },
        }
    }
    for (gone.items) |id| _ = self.panes.remove(id);
}

/// Hand a pane's message to its session.
fn deliver(sink: Sink, f: Frame) !void {
    var r: Reader = .{ .buf = f.payload };
    switch (f.type) {
        .draw => {
            const seq = try r.readU32();
            sink.draw(sink.ctx, seq, r.buf);
        },
        .image => {
            const id = try r.readU32();
            const generation = try r.readU64();
            const width = try r.readU32();
            const height = try r.readU32();
            const total = try r.readU32();
            const offset = try r.readU32();
            sink.image(sink.ctx, .{
                .id = id,
                .generation = generation,
                .width = width,
                .height = height,
                .total = total,
                .offset = offset,
                .data = r.buf,
            });
        },
        .notice => {
            const kind: Notice.Kind = @enumFromInt(try r.readU8());
            const text = try r.readStr();
            sink.notice(sink.ctx, .{ .kind = kind, .text = text, .status = try .init(&r) });
        },
        .copied => {
            const tag = try r.readU32();
            sink.copied(sink.ctx, tag, try r.readStr());
        },
        else => {},
    }
}

fn loseAll(self: *Daemon, why: []const u8) void {
    win32.AcquireSRWLockExclusive(&self.lock);
    defer win32.ReleaseSRWLockExclusive(&self.lock);
    self.loseAllLocked(why);
}

/// Tell every live pane it's gone from us, and the UI thread, whose list
/// of the daemon's workspaces is stale. Pending ones are dropped.
fn loseAllLocked(self: *Daemon, why: []const u8) void {
    if (self.lost) return;
    self.lost = true;
    log.info("{s}", .{why});
    var it = self.panes.valueIterator();
    while (it.next()) |slot| switch (slot.state) {
        .pending => |*pend| pend.deinit(self.alloc),
        .live => |sink| sink.ended(sink.ctx, why),
    };
    self.panes.clearRetainingCapacity();
    if (self.posting.load(.acquire)) _ = win32.PostMessageW(self.notify.hwnd, self.notify.msg, 0, 0);
}

/// `s` as UTF-16, or its bytes as Latin-1 if it isn't UTF-8.
fn toUtf16(a: Allocator, s: []const u8) ![]const u16 {
    return std.unicode.utf8ToUtf16LeAlloc(a, s) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            const out = try a.alloc(u16, s.len);
            for (out, s) |*o, b| o.* = b;
            return out;
        },
    };
}

/// Say hello, asking for frames every `frame_interval` µs, and check the
/// daemon's frames are laid out as ours. A bridge the local daemon
/// refuses answers with an Error instead, kept in `failure`.
fn handshake(self: *Daemon, buf: []u8) !void {
    var hello: [8]u8 = undefined;
    std.mem.writeInt(u32, hello[0..4], protocol_version, .little);
    std.mem.writeInt(u32, hello[4..8], self.frame_interval, .little);
    try self.send(.hello, .none, &hello);
    const f = try self.pipe.readFrame(buf);
    if (f.type == .@"error") {
        var er: Reader = .{ .buf = f.payload };
        self.failure.set(try er.readStr());
        return error.Refused;
    }
    if (f.type != .hello_reply) return error.BadReply;
    var r: Reader = .{ .buf = f.payload };
    const version = try r.readU32();
    self.pid = try r.readU32();
    // A daemon too old to say draws no frames.
    const frame_layout = r.readU64() catch 0;
    if (version != protocol_version) {
        log.err("slime speaks protocol {d}, we speak {d}", .{ version, protocol_version });
        return error.VersionMismatch;
    }
    if (frame_layout != Screen.Codec.layout_id) {
        log.err("slime's frames are laid out as {x}, ours as {x}", .{ frame_layout, Screen.Codec.layout_id });
        return error.VersionMismatch;
    }
}

fn openPipe(start_daemon: bool) !win32.HANDLE {
    var name_buf: WideBuf = .{};
    const name = try pipeName(&name_buf);
    var started = false;
    const deadline = win32.GetTickCount64() + 5000;
    while (true) {
        // SECURITY_IDENTIFICATION: the daemon may learn who we are but
        // not act as us.
        const h = win32.CreateFileW(
            name,
            win32.GENERIC_READ | win32.GENERIC_WRITE,
            0,
            null,
            win32.OPEN_EXISTING,
            win32.FILE_FLAG_OVERLAPPED | win32.SECURITY_SQOS_PRESENT | win32.SECURITY_IDENTIFICATION,
            null,
        );
        if (h != win32.INVALID_HANDLE_VALUE) {
            checkServer(h) catch |err| {
                _ = win32.CloseHandle(h);
                return err;
            };
            return h;
        }
        switch (win32.GetLastError()) {
            win32.ERROR_PIPE_BUSY => _ = win32.WaitNamedPipeW(name, 1000),
            win32.ERROR_FILE_NOT_FOUND => {
                if (!start_daemon) return error.NotRunning;
                if (!started) {
                    try startDaemon();
                    started = true;
                }
                if (win32.GetTickCount64() > deadline) return error.DaemonDidntStart;
                win32.Sleep(20);
            },
            else => return win32.lastError("CreateFileW"),
        }
        if (win32.GetTickCount64() > deadline) return error.DaemonDidntStart;
    }
}

/// `\\.\pipe\slime-<user SID>`, NUL-terminated: one daemon per user.
/// With SLIME_INSTANCE set, `-<instance>` follows, as the daemon names
/// it (daemon.Address).
fn pipeName(buf: *WideBuf) ![:0]const u16 {
    var token_buf: [256]u8 align(@alignOf(win32.TOKEN_USER)) = undefined;
    const sid = try currentUser(&token_buf);
    var str: ?win32.LPWSTR = null;
    if (win32.ConvertSidToStringSidW(sid, &str) == 0) return win32.lastError("ConvertSidToStringSidW");
    defer _ = win32.LocalFree(str);
    try buf.put(L("\\\\.\\pipe\\slime-"));
    try buf.put(std.mem.span(str.?));
    var inst: [64]u16 = undefined;
    if (instance(&inst)) |name| {
        try buf.put(L("-"));
        try buf.put(name);
    }
    return buf.z();
}

/// SLIME_INSTANCE, if it's set: a daemon of its own, for tests.
fn instance(buf: *[64]u16) ?[]const u16 {
    const len = win32.GetEnvironmentVariableW(L("SLIME_INSTANCE"), buf, buf.len);
    if (len == 0 or len >= buf.len) return null;
    return buf[0..len];
}

/// SLIME_WORKSPACE, if it's set to a workspace id: the one to attach,
/// shown or not, so a second window can join a first's. 0 otherwise.
fn requestedWorkspace() u32 {
    var buf: [16]u16 = undefined;
    const len = win32.GetEnvironmentVariableW(L("SLIME_WORKSPACE"), &buf, buf.len);
    if (len == 0 or len >= buf.len) return 0;
    var digits: [16]u8 = undefined;
    for (buf[0..len], digits[0..len]) |u, *d| d.* = if (u < 0x80) @intCast(u) else return 0;
    return std.fmt.parseUnsigned(u32, digits[0..len], 10) catch 0;
}

fn currentUser(buf: *align(@alignOf(win32.TOKEN_USER)) [256]u8) !*win32.SID {
    return tokenUser(win32.GetCurrentProcess(), buf);
}

/// The user a process runs as, in `buf`.
fn tokenUser(process: win32.HANDLE, buf: *align(@alignOf(win32.TOKEN_USER)) [256]u8) !*win32.SID {
    var token: win32.HANDLE = undefined;
    if (win32.OpenProcessToken(process, win32.TOKEN_QUERY, &token) == 0) return win32.lastError("OpenProcessToken");
    defer _ = win32.CloseHandle(token);
    var len: u32 = 0;
    if (win32.GetTokenInformation(token, win32.TokenUser, buf, buf.len, &len) == 0) return win32.lastError("GetTokenInformation");
    const user: *const win32.TOKEN_USER = @ptrCast(buf);
    return user.User.Sid;
}

/// Refuse a pipe served by anyone but us: another user could have
/// created the name before our daemon did.
fn checkServer(pipe: win32.HANDLE) !void {
    var pid: u32 = 0;
    if (win32.GetNamedPipeServerProcessId(pipe, &pid) == 0) return win32.lastError("GetNamedPipeServerProcessId");
    const process = win32.OpenProcess(win32.PROCESS_QUERY_LIMITED_INFORMATION, win32.FALSE, pid) orelse
        return win32.lastError("OpenProcess");
    defer _ = win32.CloseHandle(process);
    var theirs_buf: [256]u8 align(@alignOf(win32.TOKEN_USER)) = undefined;
    var ours_buf: [256]u8 align(@alignOf(win32.TOKEN_USER)) = undefined;
    if (win32.EqualSid(try tokenUser(process, &theirs_buf), try currentUser(&ours_buf)) == 0) {
        log.err("slime's pipe is served by another user's process (pid {d})", .{pid});
        return error.ForeignServer;
    }
}

/// Run slime so it outlives us: detached, and out of any job we're in.
///
/// It runs from a copy in %LOCALAPPDATA%\slime\bin, named for the size
/// and time of the slime.exe next to us: a running exe can't be
/// replaced, and the daemon runs as long as its sessions, so running ours
/// in place would stop the next build from installing over it. It loads
/// the ConPTY next to us (which doesn't change between builds), and the
/// builds of slime for hosts from `remote/` next to us. Its log
/// goes to %LOCALAPPDATA%\slime\slime.log (slime-<instance>.log with
/// SLIME_INSTANCE).
fn startDaemon() !void {
    var dir_buf: [max_path]u16 = undefined;
    const dir = try exeDir(&dir_buf);
    var src: WideBuf = .{};
    try src.put(dir);
    try src.put(L("\\"));
    try src.put(daemon_name);

    var exe: WideBuf = .{};
    var log_path: WideBuf = .{};
    copy: {
        var appdata: [260]u16 = undefined;
        const len = win32.GetEnvironmentVariableW(L("LOCALAPPDATA"), &appdata, appdata.len);
        if (len == 0 or len >= appdata.len) break :copy;
        var attrs: win32.WIN32_FILE_ATTRIBUTE_DATA = undefined;
        if (win32.GetFileAttributesExW(try src.z(), win32.GetFileExInfoStandard, &attrs) == 0) {
            if (win32.GetLastError() == win32.ERROR_FILE_NOT_FOUND) return error.DaemonNotFound;
            return win32.lastError("GetFileAttributesExW(slime.exe)");
        }

        var base: WideBuf = .{};
        try base.put(appdata[0..len]);
        try base.put(L("\\slime"));
        try makeDir(&base);
        try log_path.put(base.slice());
        try log_path.put(L("\\slime"));
        var inst: [64]u16 = undefined;
        if (instance(&inst)) |name| {
            try log_path.put(L("-"));
            try log_path.put(name);
        }
        try log_path.put(L(".log"));
        try base.put(L("\\bin"));
        try makeDir(&base);

        var name_buf: [64]u8 = undefined;
        const size = @as(u64, attrs.nFileSizeHigh) << 32 | attrs.nFileSizeLow;
        const name = std.fmt.bufPrint(&name_buf, "\\slime-{x}-{x}.exe", .{ size, attrs.ftLastWriteTime }) catch unreachable;
        try exe.put(base.slice());
        try exe.putAscii(name);
        if (win32.CopyFileW(try src.z(), try exe.z(), win32.TRUE) == 0 and win32.GetLastError() != win32.ERROR_FILE_EXISTS)
            return win32.lastError("CopyFileW(slime.exe)");
    }
    if (exe.len == 0) try exe.put(src.slice());

    // No trailing backslash before a closing quote, which would escape
    // it.
    var cmd: WideBuf = .{};
    try cmd.put(L("\""));
    try cmd.put(exe.slice());
    try cmd.put(L("\" serve --conpty \""));
    try cmd.put(dir);
    try cmd.put(L("\" --remote \""));
    try cmd.put(dir);
    try cmd.put(L("\\remote\""));
    if (log_path.len > 0) {
        try cmd.put(L(" --log \""));
        try cmd.put(log_path.slice());
        try cmd.put(L("\""));
    }
    const cmd_z = try cmd.z();

    const flags = win32.DETACHED_PROCESS | win32.CREATE_NEW_PROCESS_GROUP | win32.CREATE_UNICODE_ENVIRONMENT;
    // Breaking away fails when our job doesn't allow it; then the daemon
    // dies with the job, but at least it runs.
    for ([_]u32{ win32.CREATE_BREAKAWAY_FROM_JOB, 0 }) |extra| {
        var si: win32.STARTUPINFOEXW = .{ .StartupInfo = .{ .cb = @sizeOf(win32.STARTUPINFOW) } };
        var pi: win32.PROCESS_INFORMATION = undefined;
        if (win32.CreateProcessW(null, @constCast(cmd_z.ptr), null, null, win32.FALSE, flags | extra, null, null, &si, &pi) != 0) {
            _ = win32.CloseHandle(pi.hThread);
            _ = win32.CloseHandle(pi.hProcess);
            log.info("started slime (pid {d}){s}", .{ pi.dwProcessId, if (extra == 0) " inside our job" else "" });
            return;
        }
    }
    return win32.lastError("CreateProcessW(slime.exe)");
}

fn makeDir(path: *WideBuf) !void {
    if (win32.CreateDirectoryW(try path.z(), null) == 0 and win32.GetLastError() != win32.ERROR_ALREADY_EXISTS)
        return win32.lastError("CreateDirectoryW");
}

/// Our executable's directory, without a trailing backslash.
fn exeDir(buf: *[max_path]u16) ![]const u16 {
    const n = win32.GetModuleFileNameW(null, buf, buf.len);
    if (n == 0 or n >= buf.len) return win32.lastError("GetModuleFileNameW");
    return buf[0 .. std.mem.lastIndexOfScalar(u16, buf[0..n], '\\') orelse return error.Win32];
}

/// A path or command line being built, kept NUL-terminable. Several live
/// on the UI thread's stack at once, so they're shorter than the longest
/// path Windows allows.
const WideBuf = struct {
    buf: [4096]u16 = undefined,
    len: usize = 0,

    fn put(self: *WideBuf, s: []const u16) !void {
        if (self.len + s.len >= self.buf.len) return error.NameTooLong;
        @memcpy(self.buf[self.len..][0..s.len], s);
        self.len += s.len;
    }

    fn putAscii(self: *WideBuf, s: []const u8) !void {
        if (self.len + s.len >= self.buf.len) return error.NameTooLong;
        for (s, self.buf[self.len..][0..s.len]) |c, *d| d.* = c;
        self.len += s.len;
    }

    fn slice(self: *const WideBuf) []const u16 {
        return self.buf[0..self.len];
    }

    fn z(self: *WideBuf) ![:0]const u16 {
        self.buf[self.len] = 0;
        return self.buf[0..self.len :0];
    }
};

/// The connection: the daemon's pipe. Reads are the reader's (or
/// `connect`'s, before the reader starts); writes take the connection's
/// write lock.
///
/// The pipe is opened for overlapped I/O. Windows serializes synchronous
/// I/O on a handle, so a blocking read, which the reader thread is in
/// most of the time, would hold up every write behind it. Reads and
/// writes each wait on their own event instead.
const Pipe = struct {
    /// Frames up to this size, as keys and calls are, go in one write
    /// from the stack.
    const input_chunk = 16 * 1024;

    read_h: win32.HANDLE,
    write_h: win32.HANDLE,
    /// For reads and writes.
    events: [2]win32.HANDLE,

    fn open(start_daemon: bool) !Pipe {
        const h = try openPipe(start_daemon);
        errdefer _ = win32.CloseHandle(h);
        const read_event = win32.CreateEventW(null, win32.TRUE, win32.FALSE, null) orelse return win32.lastError("CreateEventW");
        errdefer _ = win32.CloseHandle(read_event);
        const write_event = win32.CreateEventW(null, win32.TRUE, win32.FALSE, null) orelse return win32.lastError("CreateEventW");
        return .{ .read_h = h, .write_h = h, .events = .{ read_event, write_event } };
    }

    fn close(self: *Pipe) void {
        _ = win32.CloseHandle(self.read_h);
        for (self.events) |e| _ = win32.CloseHandle(e);
    }

    fn send(self: *Pipe, msg: MsgType, id: PaneRef, payload: []const u8) !void {
        var header: [4 + header_len]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], @intCast(header_len + payload.len), .little);
        header[4] = @intFromEnum(msg);
        std.mem.writeInt(u32, header[5..9], id.ws, .little);
        std.mem.writeInt(u32, header[9..13], id.tab, .little);
        std.mem.writeInt(u32, header[13..17], id.n, .little);
        // One write for small frames, so a pipe trace shows whole frames.
        if (payload.len <= input_chunk) {
            var buf: [header.len + input_chunk]u8 = undefined;
            @memcpy(buf[0..header.len], &header);
            @memcpy(buf[header.len..][0..payload.len], payload);
            return self.writeAll(buf[0 .. header.len + payload.len]);
        }
        try self.writeAll(&header);
        try self.writeAll(payload);
    }

    /// Failing is expected once the daemon has gone, so it isn't logged.
    fn writeAll(self: *Pipe, data: []const u8) !void {
        var rest = data;
        while (rest.len > 0) {
            const len: u32 = @intCast(@min(rest.len, std.math.maxInt(u32)));
            var n: u32 = 0;
            var ov: win32.OVERLAPPED = .{ .hEvent = self.events[1] };
            if (win32.WriteFile(self.write_h, rest.ptr, len, null, &ov) == 0 and win32.GetLastError() != win32.ERROR_IO_PENDING)
                return error.BrokenPipe;
            if (win32.GetOverlappedResult(self.write_h, &ov, &n, win32.TRUE) == 0) return error.BrokenPipe;
            rest = rest[n..];
        }
    }

    fn readFrame(self: *Pipe, buf: []u8) !Frame {
        var len_buf: [4]u8 = undefined;
        try self.readExact(&len_buf);
        const len = std.mem.readInt(u32, &len_buf, .little);
        if (len < header_len or len > buf.len) return error.BadFrame;
        try self.readExact(buf[0..len]);
        return .{
            .type = @enumFromInt(buf[0]),
            .id = .{
                .ws = std.mem.readInt(u32, buf[1..5], .little),
                .tab = std.mem.readInt(u32, buf[5..9], .little),
                .n = std.mem.readInt(u32, buf[9..13], .little),
            },
            .payload = buf[header_len..len],
        };
    }

    /// Fails at EOF, and when `deinit` cancels the read.
    fn readExact(self: *Pipe, buf: []u8) !void {
        var got: usize = 0;
        while (got < buf.len) {
            const len: u32 = @intCast(buf.len - got);
            var n: u32 = 0;
            var ov: win32.OVERLAPPED = .{ .hEvent = self.events[0] };
            if (win32.ReadFile(self.read_h, buf[got..].ptr, len, null, &ov) == 0 and win32.GetLastError() != win32.ERROR_IO_PENDING)
                return error.EndOfStream;
            if (win32.GetOverlappedResult(self.read_h, &ov, &n, win32.TRUE) == 0) return error.EndOfStream;
            if (n == 0) return error.EndOfStream;
            got += n;
        }
    }
};

/// wire.go's frame after its length: a u8 type, the pane's id as three
/// u32s (zero when the message isn't about one pane), and the payload.
const header_len = 1 + 12;

const Frame = struct {
    type: MsgType,
    id: PaneRef,
    payload: []const u8,
};

fn writeSize(b: *[12]u8, size: Size) void {
    std.mem.writeInt(u16, b[0..2], size.cols, .little);
    std.mem.writeInt(u16, b[2..4], size.rows, .little);
    std.mem.writeInt(u32, b[4..8], size.cell_width, .little);
    std.mem.writeInt(u32, b[8..12], size.cell_height, .little);
}

const Reader = struct {
    buf: []const u8,

    fn take(self: *Reader, n: usize) ![]const u8 {
        if (self.buf.len < n) return error.Truncated;
        const b = self.buf[0..n];
        self.buf = self.buf[n..];
        return b;
    }

    fn readU8(self: *Reader) !u8 {
        return (try self.take(1))[0];
    }

    fn readU64(self: *Reader) !u64 {
        return std.mem.readInt(u64, (try self.take(8))[0..8], .little);
    }

    fn readU16(self: *Reader) !u16 {
        return std.mem.readInt(u16, (try self.take(2))[0..2], .little);
    }

    fn readU32(self: *Reader) !u32 {
        return std.mem.readInt(u32, (try self.take(4))[0..4], .little);
    }

    fn readStr(self: *Reader) ![]const u8 {
        return self.take(try self.readU32());
    }
};

/// A u32 length and bytes: a string in a binary payload.
fn putStr(alloc: Allocator, list: *std.ArrayList(u8), s: []const u8) !void {
    try putU32(alloc, list, @intCast(s.len));
    try list.appendSlice(alloc, s);
}

fn putU32(alloc: Allocator, list: *std.ArrayList(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try list.appendSlice(alloc, &b);
}

test "a layout's shares are sent summing to the whole" {
    const alloc = std.testing.allocator;
    const p = struct {
        fn p(n: u32) PaneRef {
            return .{ .ws = 1, .tab = 1, .n = n };
        }
    }.p;
    var inner = [_]Child{ .{ .share = 1, .node = .{ .pane = p(2) } }, .{ .share = 1, .node = .{ .pane = p(3) } }, .{ .share = 1, .node = .{ .pane = p(4) } } };
    var outer = [_]Child{ .{ .share = 7000, .node = .{ .pane = p(1) } }, .{ .share = 2000, .node = .{ .split = .{ .axis = .column, .children = &inner } } } };
    const root: Node = .{ .split = .{ .axis = .row, .children = &outer } };
    const json = try std.json.Stringify.valueAlloc(alloc, root, .{});
    defer alloc.free(json);
    try std.testing.expect(std.mem.startsWith(u8, json, "{\"split\":{\"axis\":\"row\",\"children\":[{\"share\":7777,\"node\":{\"pane\":\"1.1.1\"}}"));

    var parsed = try std.json.parseFromSlice(Node, alloc, json, json_opts);
    defer parsed.deinit();
    const row = parsed.value.split.children;
    try std.testing.expectEqual(@as(u16, 7777), row[0].share);
    try std.testing.expectEqual(@as(u16, 2223), row[1].share);
    const column = row[1].node.split.children;
    try std.testing.expectEqual(Axis.column, row[1].node.split.axis);
    try std.testing.expectEqual(@as(u16, 3333), column[0].share);
    try std.testing.expectEqual(@as(u16, 3333), column[1].share);
    try std.testing.expectEqual(@as(u16, 3334), column[2].share);
    try std.testing.expect(column[2].node.pane.eql(p(4)));
}

test "ids are dotted strings on the wire, and none is empty" {
    const alloc = std.testing.allocator;
    const json = try std.json.Stringify.valueAlloc(alloc, .{ .tab = TabRef{ .ws = 1, .n = 2 }, .pane = PaneRef{ .ws = 1, .tab = 2, .n = 3 }, .zoomed = PaneRef.none }, .{});
    defer alloc.free(json);
    try std.testing.expectEqualStrings(
        \\{"tab":"1.2","pane":"1.2.3","zoomed":""}
    , json);
    const Both = struct { tab: TabRef = .none, pane: PaneRef = .none };
    var parsed = try std.json.parseFromSlice(Both, alloc,
        \\{"tab":"4.5","pane":"4.5.6"}
    , json_opts);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.tab.eql(.{ .ws = 4, .n = 5 }));
    try std.testing.expect(parsed.value.pane.eql(.{ .ws = 4, .tab = 5, .n = 6 }));
    try std.testing.expect(parsed.value.pane.tabRef().eql(parsed.value.tab));
    var empty = try std.json.parseFromSlice(Both, alloc,
        \\{"tab":"","pane":""}
    , json_opts);
    defer empty.deinit();
    try std.testing.expect(empty.value.tab.isNone() and empty.value.pane.isNone());
    for ([_][]const u8{
        \\{"pane":"1.2"}
        ,
        \\{"pane":3}
        ,
        \\{"pane":"1.2.0"}
        ,
        \\{"pane":"1.2.3.4"}
        ,
        \\{"tab":"1.2.3"}
        ,
        \\{"tab":"a.b"}
    }) |bad| {
        try std.testing.expectError(error.UnexpectedToken, std.json.parseFromSlice(Both, alloc, bad, json_opts));
    }
    // From a Value too, as replies are read.
    var value = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"pane":"7.8.9"}
    , json_opts);
    defer value.deinit();
    const from_value = try std.json.parseFromValueLeaky(Both, value.arena.allocator(), value.value, json_opts);
    try std.testing.expect(from_value.pane.eql(.{ .ws = 7, .tab = 8, .n = 9 }));
}

test "a call is a JSON-RPC request as the daemon reads it" {
    const alloc = std.testing.allocator;
    const b = try encodeCall(alloc, 7, "pane.split", .{ .pane = PaneRef{ .ws = 1, .tab = 1, .n = 3 }, .direction = Direction.left, .share = 5000, .command = "pwsh" });
    defer alloc.free(b);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":7,"method":"pane.split","params":{"pane":"1.1.3","direction":"left","share":5000,"command":"pwsh"}}
    , b);
    const none = try encodeCall(alloc, 3, "workspace.list", no_params);
    defer alloc.free(none);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":3,"method":"workspace.list","params":{}}
    , none);
    const sub = try encodeCall(alloc, 1, "subscribe", .{ .events = .{"host.*"} });
    defer alloc.free(sub);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"method":"subscribe","params":{"events":["host.*"]}}
    , sub);
    const at = try encodeCall(alloc, 2, "workspace.attach", .{ .id = 9, .area = Area{ .width = 720, .height = 432, .cell_width = 9, .cell_height = 18 } });
    defer alloc.free(at);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":2,"method":"workspace.attach","params":{"id":9,"area":{"width":720,"height":432,"cell_width":9,"cell_height":18}}}
    , at);
    // zoomed none goes as "", which unzooms: the Go side tells it from
    // omitted.
    const f = try encodeCall(alloc, 4, "workspace.focus", Focus{ .tab = .{ .ws = 9, .n = 2 }, .pane = .{ .ws = 9, .tab = 2, .n = 4 }, .zoomed = .none });
    defer alloc.free(f);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":4,"method":"workspace.focus","params":{"tab":"9.2","pane":"9.2.4","zoomed":""}}
    , f);
}

test "a workspace parses as the daemon sends it" {
    // internal/rpc Workspace{ID: 9, Name: "main", ActiveTab: 9.2, Tabs:
    // [{ID: 9.2, Name: "build", Tree: row(60% 9.2.3, 40% col(50% 9.2.4,
    // 50% 9.2.5)), Focus: 9.2.4, Zoomed: 9.2.4}, {ID: 9.6, Tree: 9.6.7,
    // Focus: 9.6.7}]}.
    const json =
        \\{"id":9,"name":"main","active_tab":"9.2","tabs":[{"id":"9.2","name":"build","tree":{"split":{"axis":"row","children":[{"share":6000,"node":{"pane":"9.2.3"}},{"share":4000,"node":{"split":{"axis":"column","children":[{"share":5000,"node":{"pane":"9.2.4"}},{"share":5000,"node":{"pane":"9.2.5"}}]}}}]}},"focus":"9.2.4","zoomed":"9.2.4"},{"id":"9.6","tree":{"pane":"9.6.7"},"focus":"9.6.7"}]}
    ;
    var parsed = try std.json.parseFromSlice(Json.Workspace, std.testing.allocator, json, json_opts);
    defer parsed.deinit();
    const ws = parsed.value;
    try std.testing.expectEqual(@as(u32, 9), ws.id);
    try std.testing.expect(ws.active_tab.eql(.{ .ws = 9, .n = 2 }));
    try std.testing.expectEqual(@as(usize, 2), ws.tabs.len);
    try std.testing.expect(ws.tabs[0].id.eql(.{ .ws = 9, .n = 2 }));
    try std.testing.expect(ws.tabs[0].focus.eql(.{ .ws = 9, .tab = 2, .n = 4 }));
    try std.testing.expect(ws.tabs[0].zoomed.eql(.{ .ws = 9, .tab = 2, .n = 4 }));
    try std.testing.expect(ws.tabs[1].zoomed.isNone());
    const row = ws.tabs[0].tree.split;
    try std.testing.expectEqual(Axis.row, row.axis);
    try std.testing.expect(row.children[0].node.pane.eql(.{ .ws = 9, .tab = 2, .n = 3 }));
    try std.testing.expectEqual(@as(u16, 6000), row.children[0].share);
    try std.testing.expect(row.children[1].node.split.children[1].node.pane.eql(.{ .ws = 9, .tab = 2, .n = 5 }));
    try std.testing.expect(ws.tabs[1].tree.pane.eql(.{ .ws = 9, .tab = 6, .n = 7 }));
    try std.testing.expectEqualStrings("", ws.tabs[1].name);
}

test "pane and workspace events parse as the daemon sends them" {
    const alloc = std.testing.allocator;
    var at = try std.json.parseFromSlice(Json.PaneAttached, alloc,
        \\{"id":"9.2.3","command":"pwsh -NoLogo","status":[{"id":"","state":1,"progress":40},{"id":"deploy/eu","state":3,"progress":-1}]}
    , json_opts);
    defer at.deinit();
    try std.testing.expect(at.value.id.eql(.{ .ws = 9, .tab = 2, .n = 3 }));
    try std.testing.expect(at.value.moved_from.isNone());
    try std.testing.expectEqualStrings("pwsh -NoLogo", at.value.command);
    try std.testing.expectEqual(@as(usize, 2), at.value.status.len);
    try std.testing.expectEqual(@as(i8, -1), at.value.status[1].progress);
    try std.testing.expectEqualStrings("deploy/eu", at.value.status[1].id);

    var moved = try std.json.parseFromSlice(Json.PaneAttached, alloc,
        \\{"id":"9.4.1","moved_from":"9.2.3","command":"pwsh"}
    , json_opts);
    defer moved.deinit();
    try std.testing.expect(moved.value.moved_from.eql(.{ .ws = 9, .tab = 2, .n = 3 }));

    var ex = try std.json.parseFromSlice(Json.PaneExited, alloc,
        \\{"id":"9.2.3","status":3221225786}
    , json_opts);
    defer ex.deinit();
    try std.testing.expectEqual(@as(u32, 0xc000013a), ex.value.status);

    var det = try std.json.parseFromSlice(Json.WorkspaceDetached, alloc,
        \\{"id":9,"reason":"attached elsewhere"}
    , json_opts);
    defer det.deinit();
    try std.testing.expectEqualStrings("attached elsewhere", det.value.reason);

    var open = try std.json.parseFromSlice(Json.WorkspaceOpen, alloc,
        \\{"id":14,"name":"dev"}
    , json_opts);
    defer open.deinit();
    try std.testing.expectEqual(@as(u32, 14), open.value.id);
    try std.testing.expectEqualStrings("dev", open.value.name);

    var created = try std.json.parseFromSlice(Json.Created, alloc,
        \\{"pane":"9.2.3"}
    , json_opts);
    defer created.deinit();
    try std.testing.expect(created.value.pane.eql(.{ .ws = 9, .tab = 2, .n = 3 }));

    // A reply envelope, with a field this build doesn't know.
    var env = try std.json.parseFromSlice(Json.Envelope, alloc,
        \\{"jsonrpc":"2.0","id":7,"result":{"pane":"9.2.3"},"later":true}
    , json_opts);
    defer env.deinit();
    try std.testing.expectEqual(@as(?u32, 7), env.value.id);
    try std.testing.expectEqualStrings("9.2.3", env.value.result.object.get("pane").?.string);
    var bad = try std.json.parseFromSlice(Json.Envelope, alloc,
        \\{"jsonrpc":"2.0","id":8,"error":{"code":1000,"message":"no such pane"}}
    , json_opts);
    defer bad.deinit();
    try std.testing.expectEqualStrings("no such pane", bad.value.@"error".?.message);
}

test "prompts parse as the Go side sends them" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(Json.HostPrompt, alloc,
        \\{"host":11,"kind":"password","title":"T","questions":[{"label":"pw: "}]}
    , json_opts);
    defer parsed.deinit();
    const p = try Prompt.fromJson(alloc, parsed.value);
    defer p.destroy();
    try std.testing.expectEqual(Prompt.Kind.password, p.kind);
    try std.testing.expectEqualSlices(u16, L("T"), p.title);
    try std.testing.expectEqual(@as(usize, 0), p.text.len);
    try std.testing.expectEqual(@as(usize, 1), p.questions.len);
    try std.testing.expectEqualSlices(u16, L("pw: "), p.questions[0].label);
    try std.testing.expect(!p.questions[0].echo);
}

test "a host's state parses as the Go side sends it" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(Json.Host, alloc,
        \\{"id":12,"dest":"dev2","state":"failed","text":"Permission denied"}
    , json_opts);
    defer parsed.deinit();
    var info = try HostInfo.fromJson(alloc, parsed.value);
    defer info.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 12), info.host);
    try std.testing.expectEqual(HostStatus.failed, info.state);
    try std.testing.expectEqualSlices(u16, L("dev2"), info.dest);
    try std.testing.expectEqualSlices(u16, L("Permission denied"), info.text);

    var odd = try std.json.parseFromSlice(Json.Host, alloc,
        \\{"id":13,"dest":"dev3","state":"hibernating"}
    , json_opts);
    defer odd.deinit();
    var unknown = try HostInfo.fromJson(alloc, odd.value);
    defer unknown.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0xff), @intFromEnum(unknown.state));
}

test "workspace.list parses as the daemon sends it" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(Json.WorkspaceList, alloc,
        \\{"workspaces":[{"id":1,"name":"a","attached":true,"viewers":2,"tabs":[]},{"id":3,"name":"c","attached":false,"detached_at":1700000005000,"active_tab":"3.4","tabs":[{"id":"3.4","tree":{"pane":"3.4.5"}}]}],"panes":[]}
    , json_opts);
    defer parsed.deinit();
    const list = parsed.value;
    try std.testing.expect(listed(list, 3));
    try std.testing.expect(!listed(list, 2));
    try std.testing.expectEqual(@as(usize, 2), list.workspaces.len);
    try std.testing.expectEqual(@as(usize, 2), list.workspaces[0].viewers);
    try std.testing.expectEqual(@as(usize, 1), list.workspaces[1].tabs.len);
    var info = try WorkspaceInfo.fromJson(alloc, list.workspaces[1].id, list.workspaces[1].name, list.workspaces[1].tabs.len, list.workspaces[1].active_tab, list.workspaces[1].viewers);
    defer info.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 3), info.id);
    try std.testing.expectEqualSlices(u16, L("c"), info.name);
    try std.testing.expectEqual(@as(usize, 1), info.tabs);
    try std.testing.expect(info.active_tab.eql(.{ .ws = 3, .n = 4 }));
    try std.testing.expectEqual(@as(?usize, 0), info.viewers);

    const new = try encodeCall(alloc, 5, "workspace.new", .{ .name = "dev", .tabs = .{.{ .pane = .{ .command = "pwsh" } }} });
    defer alloc.free(new);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":5,"method":"workspace.new","params":{"name":"dev","tabs":[{"pane":{"command":"pwsh"}}]}}
    , new);
}

test "frames match the Go side's wire format" {
    // internal/daemon: Resize{Size{0x0102, 0x0304, 0x05060708,
    // 0x090a0b0c}} on 2.
    var b: [12]u8 = undefined;
    writeSize(&b, .{ .cols = 0x0102, .rows = 0x0304, .cell_width = 0x05060708, .cell_height = 0x090a0b0c });
    try std.testing.expectEqualSlices(u8, &.{
        0x02, 0x01, 0x04, 0x03,
        0x08, 0x07, 0x06, 0x05,
        0x0c, 0x0b, 0x0a, 0x09,
    }, &b);
}
