//! A window's connection to slime (cmd/slime), the daemon that
//! owns local ptys so they outlive the window. The daemon keeps panes in
//! tabs and tabs in workspaces; a window attaches one workspace and
//! mirrors it. The protocol is internal/daemon's (wire.go).
//!
//! slime runs each pane's terminal; we draw what it sends (CapFrames):
//! frames of the pane's screen, and notices of what else it did (a new
//! title, a clipboard write). Input goes back as events, which slime
//! handles against the terminal. One reader thread reads the connection
//! and hands each pane's messages to its session through a `Sink`.
//!
//! Panes that arrive while the reader runs (a new tab, or one a script
//! added) keep what comes for them on the reader thread, then wait in
//! `arrivals` for the UI thread, which is told with the `notify` message.
//! Adopting one replays what was kept under the connection's lock before
//! the pane goes live, so nothing is lost or reordered at the handoff.
//!
//! The local daemon is reached through its named pipe (`connect`). It
//! also holds the SSH connections to hosts: the host messages on the same
//! connection log in to one (`hostConnect`, with its prompts coming back
//! as `HostEvent`s for the window to take) and report every host's state.
//! A host's own slime is reached through a second connection to the
//! local pipe that the daemon splices to it (`connectRemote`), whose
//! reader attaches before it routes frames.
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

const MsgType = enum(u8) {
    hello = 1,
    list = 2,
    workspace_new = 3,
    workspace_attach = 4,
    workspace_detach = 5,
    workspace_kill = 6,
    workspace_rename = 7,
    workspace_resize = 8,
    tab_new = 9,
    tab_close = 10,
    tab_rename = 11,
    split = 12,
    layout = 13,
    pane_kill = 14,
    resize = 16,
    peek = 17,
    ack = 18,
    event = 19,
    host_connect = 20,
    host_answer = 21,
    host_disconnect = 22,
    host_list = 23,
    bridge = 24,
    hello_reply = 65,
    workspaces = 66,
    workspace = 67,
    attached = 68,
    exit = 71,
    detached = 72,
    @"error" = 73,
    created = 74,
    draw = 75,
    copied = 76,
    notice = 77,
    image = 78,
    hosts = 79,
    host_state = 80,
    prompt = 81,
    pane_text = 82,
    _,
};

alloc: Allocator,
pipe: Pipe,
notify: Notify,
reader: ?std.Thread = null,
/// Frames are written from the UI thread and, while a host's attaches,
/// its reader; each goes out whole.
write_lock: win32.SRWLOCK = .{},
/// The attached workspace.
workspace: u32 = 0,
/// Tags for requests, from the UI thread and, while a host's attaches,
/// its reader.
next_tag: std.atomic.Value(u32) = .init(0),

/// The host this is bridged to; null for the local daemon itself.
remote: ?Remote = null,
/// How attaching went. A host's starts out connecting, and its reader
/// says how it ended (`notify`).
state: std.atomic.Value(State) = .init(.attached),
/// Why attaching failed, once `state` says it did.
failure: Failure = .{},
/// The last Error the daemon sent about the connection (tag 0), which
/// for a bridge says why it ended. Reader thread.
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

/// Guards `panes`, `arrivals`, `structure`, `requested`, `host_events`,
/// and `lost`, and is held while calling a sink, so a session can't go
/// while one runs.
lock: win32.SRWLOCK = .{},
panes: std.AutoHashMapUnmanaged(u32, Slot) = .empty,
arrivals: std.ArrayList(Arrival) = .empty,
/// What the daemon said about hosts since the UI thread last looked
/// (`takeHosts`).
host_events: std.ArrayList(HostEvent) = .empty,
structure: ?*Structure = null,
/// Tags of our own TabNew and Split requests, so their panes can be
/// shown.
requested: std.ArrayList(u32) = .empty,
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

/// A host's slime, reached through the local daemon.
const Remote = struct {
    /// The daemon's id for the host.
    host: u32,
    /// The destination as the sidebar remembers it. Owned.
    dest: []const u16,
    /// The TERM its panes get. Owned.
    term: []const u8,
};

/// A host's state as the daemon reports it (wire.go's HostStatus).
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

/// A question while logging in to a host (wire.go's Prompt), its text
/// in UTF-16 for the chrome.
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

    fn parse(gpa: Allocator, payload: []const u8) !*Prompt {
        const self = try gpa.create(Prompt);
        errdefer gpa.destroy(self);
        self.arena = .init(gpa);
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        var r: Reader = .{ .buf = payload };
        self.kind = @enumFromInt(try r.readU8());
        self.title = try toUtf16(a, try r.readStr());
        self.text = try toUtf16(a, try r.readStr());
        self.detail = try toUtf16(a, try r.readStr());
        self.err = try toUtf16(a, try r.readStr());
        const n = try r.readU32();
        if (n > max_questions) return error.TooManyQuestions;
        const questions = try a.alloc(Question, n);
        for (questions) |*q| q.* = .{
            .label = try toUtf16(a, try r.readStr()),
            .echo = try r.readU8() != 0,
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

/// The button a prompt was answered with (wire.go's Choice).
pub const Choice = enum(u8) {
    cancel = 0,
    accept = 1,
    skip = 2,
};

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
/// its own font).
pub const Area = struct {
    width: u32,
    height: u32,
    cell_width: u32,
    cell_height: u32,
};

/// A grid size and its cell size in pixels.
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
    pane: u32,
    tab: u32,
    /// Owned, in the connection's allocator.
    command: []const u16,
    /// What its programs report doing (OSC 7501), oldest update first.
    /// Owned.
    status: []StatusRecord,
    /// From our own TabNew or Split, so the window shows it.
    requested: bool,

    pub fn deinit(self: *Arrival, alloc: Allocator) void {
        alloc.free(self.command);
        freeStatus(alloc, self.status);
    }
};

/// A program status record as the daemon keeps it (wire.go's
/// StatusRecord). `state` numbers as `ProgramStatus.State`.
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

/// The way a split lays out its children (layout.go's Axis).
pub const Axis = enum(u8) {
    /// Left to right, sharing the width.
    row = 1,
    /// Top to bottom, sharing the height.
    column = 2,
};

/// Where a split puts the new pane beside the old (layout.go's Direction).
pub const Direction = enum(u8) { right = 1, down = 2, left = 3, up = 4 };

/// A tab's layout tree, as the daemon sends it.
pub const Node = union(enum) {
    pane: u32,
    split: struct { axis: Axis, children: []Child },
};

pub const Child = struct {
    /// Basis points of the split's space.
    share: u16,
    node: Node,
};

/// The workspace's tabs, from its last Workspace message, in its order.
pub const Structure = struct {
    arena: std.heap.ArenaAllocator,
    tabs: []const TabLayout,

    pub const TabLayout = struct { id: u32, root: Node };

    fn destroy(self: *Structure, alloc: Allocator) void {
        self.arena.deinit();
        alloc.destroy(self);
    }
};

/// What came since the UI thread last looked (`take`).
pub const Taken = struct {
    /// Panes whose snapshots are in, for sessions to adopt or release.
    arrivals: []Arrival,
    /// The tabs as they are now, if they changed. Every pane in them is
    /// live or among `arrivals`.
    structure: ?*Structure,

    pub fn deinit(self: *Taken, alloc: Allocator) void {
        for (self.arrivals) |*a| a.deinit(alloc);
        alloc.free(self.arrivals);
        if (self.structure) |st| st.destroy(alloc);
    }
};

const Slot = union(enum) {
    /// Attached, and waiting for the UI thread; what comes for it
    /// meanwhile is kept for adoption.
    pending: Pending,
    live: Sink,
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
            const f: Frame = .{ .type = @enumFromInt(rest[0]), .id = 0, .payload = rest[5..][0..len] };
            deliver(sink, f) catch |err| log.warn("bad message {d} from slime: {}", .{ rest[0], err });
            rest = rest[5 + len ..];
        }
    }
};

/// Connect, starting the daemon if it isn't running, and attach the most
/// recently detached workspace, or a new one with a tab running
/// `command`. Panes' frames come at most every `frame_interval` µs. The
/// workspace's panes wait in `arrivals`; `start` the reader after
/// adopting them. UI thread.
pub fn connect(alloc: Allocator, notify: Notify, frame_interval: u32, area: Area, size: Size, command: []const u16) !*Daemon {
    var pipe: Pipe = try .open(true);
    errdefer pipe.close();
    const buf = try alloc.alloc(u8, max_frame);
    defer alloc.free(buf);

    const self = try alloc.create(Daemon);
    errdefer alloc.destroy(self);
    self.* = .{ .alloc = alloc, .pipe = pipe, .notify = notify, .frame_interval = frame_interval };
    errdefer self.freeState();
    try self.attachFirst(buf, area, size, command);
    return self;
}

/// Connect to the slime on host `host` (the daemon's id for it, which it
/// has `connected`), through a second connection to the local daemon's
/// pipe that it splices to the host's. The reader does the rest: it
/// attaches as `connect` does, a new workspace's tab running the host's
/// shell, and posts `notify` once `state` says how that went. The panes
/// then wait in `arrivals`. `term` is the TERM the host's panes get. UI
/// thread.
pub fn connectRemote(alloc: Allocator, notify: Notify, frame_interval: u32, host_id: u32, dest: []const u16, term: []const u8, area: Area, size: Size) !*Daemon {
    var pipe: Pipe = try .open(false);
    errdefer pipe.close();
    const owned_dest = try alloc.dupe(u16, dest);
    errdefer alloc.free(owned_dest);
    const owned_term = try alloc.dupe(u8, term);
    errdefer alloc.free(owned_term);
    const self = try alloc.create(Daemon);
    errdefer alloc.destroy(self);
    self.* = .{
        .alloc = alloc,
        .pipe = pipe,
        .notify = notify,
        .remote = .{ .host = host_id, .dest = owned_dest, .term = owned_term },
        .state = .init(.connecting),
        .area = area,
        .size = size,
        .frame_interval = frame_interval,
    };
    self.reader = try std.Thread.spawn(.{}, remoteLoop, .{self});
    return self;
}

/// Say hello, then attach the most recently detached workspace, or a new
/// one with a tab running `command`, reading the replies in line. Before
/// the reader routes frames.
fn attachFirst(self: *Daemon, buf: []u8, area: Area, size: Size, command: []const u16) !void {
    const alloc = self.alloc;
    try self.handshake(buf);

    // Most recently detached, from the list.
    try self.send(.list, 0, &.{});
    var ws: u32 = 0;
    while (true) {
        const f = try self.pipe.readFrame(buf);
        if (f.type != .workspaces) continue;
        ws = try mostRecentDetached(f.payload);
        break;
    }

    var p: Payload = .{};
    defer p.deinit(alloc);
    const tag = self.nextTag();
    if (ws != 0) {
        try p.putU32(alloc, tag);
        try p.putU32(alloc, ws);
        try p.putArea(alloc, area);
        try self.send(.workspace_attach, 0, p.bytes());
        try self.awaitReply(buf, tag, false);
        log.info("attached workspace {d}", .{self.workspace});
    } else {
        try p.putU32(alloc, tag);
        try p.putStr(alloc, "");
        try self.send(.workspace_new, 0, p.bytes());
        try self.awaitReply(buf, tag, true);
        log.info("created workspace {d}", .{self.workspace});
    }
    // A window needs a pane: a new workspace has none, and an attached one
    // may have lost its last.
    if (self.arrivals.items.len == 0) {
        const t = try self.tabNewTagged(command, size);
        try self.awaitReply(buf, t, true);
    }
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
    var p: Payload = .{};
    defer p.deinit(self.alloc);
    p.putStr(self.alloc, r.term) catch return self.fail(error.OutOfMemory);
    self.send(.bridge, r.host, p.bytes()) catch |err| return self.fail(err);
    // The host's own shell: the command is for its slime to run.
    self.attachFirst(buf, self.area, self.size, &.{}) catch |err| return self.fail(err);
    log.info("attached workspace {d} on {f}", .{ self.workspace, std.unicode.fmtUtf16Le(self.hostLabel()) });
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
    while (it.next()) |slot| switch (slot.*) {
        .pending => |*pend| pend.deinit(self.alloc),
        .live => {},
    };
    self.panes.deinit(self.alloc);
    for (self.arrivals.items) |*a| a.deinit(self.alloc);
    self.arrivals.deinit(self.alloc);
    self.requested.deinit(self.alloc);
    if (self.structure) |st| st.destroy(self.alloc);
    for (self.host_events.items) |*e| e.deinit(self.alloc);
    self.host_events.deinit(self.alloc);
    if (self.remote) |r| {
        self.alloc.free(r.dest);
        self.alloc.free(r.term);
    }
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
/// states come as `HostEvent`s; a host already connected answers with its
/// state. Returns the request's tag, which the answering state carries.
/// UI thread.
pub fn hostConnect(self: *Daemon, dest: []const u16) !u32 {
    const utf8 = try commandUtf8(self.alloc, dest);
    defer self.alloc.free(utf8);
    const t = self.nextTag();
    var p: Payload = .{};
    defer p.deinit(self.alloc);
    try p.putU32(self.alloc, t);
    try p.putStr(self.alloc, utf8);
    try self.send(.host_connect, 0, p.bytes());
    return t;
}

/// Reply to the last prompt for `host_id`, one answer per question. A
/// cancel with no prompt waiting gives up on logging in. UI thread.
pub fn hostAnswer(self: *Daemon, host_id: u32, choice: Choice, answers: []const []const u16) !void {
    var p: Payload = .{};
    defer p.deinit(self.alloc);
    try p.list.append(self.alloc, @intFromEnum(choice));
    try p.putU32(self.alloc, @intCast(answers.len));
    for (answers) |units| {
        const utf8 = try commandUtf8(self.alloc, units);
        defer self.alloc.free(utf8);
        try p.putStr(self.alloc, utf8);
    }
    try self.send(.host_answer, host_id, p.bytes());
}

/// Hang up on `host_id`, ending its bridges, or give up on logging in to
/// it. UI thread.
pub fn hostDisconnect(self: *Daemon, host_id: u32) void {
    self.send(.host_disconnect, host_id, &.{}) catch {};
}

/// Ask for every host; the answer is a `HostEvent.hosts`. UI thread.
pub fn hostList(self: *Daemon) void {
    self.send(.host_list, 0, &.{}) catch {};
}

/// Take the panes waiting for sessions and the latest tabs, together so
/// the tabs name no pane the caller hasn't seen. The caller owns them
/// (`Taken.deinit`) and must `adopt` or `release` each arrival. UI
/// thread.
pub fn take(self: *Daemon) Taken {
    win32.AcquireSRWLockExclusive(&self.lock);
    defer win32.ReleaseSRWLockExclusive(&self.lock);
    const structure = self.structure;
    self.structure = null;
    return .{ .arrivals = self.arrivals.toOwnedSlice(self.alloc) catch &.{}, .structure = structure };
}

/// Make `sink` the pane's: what came while it waited goes first, then
/// what comes live. UI thread.
pub fn adopt(self: *Daemon, pane: u32, sink: Sink) void {
    win32.AcquireSRWLockExclusive(&self.lock);
    defer win32.ReleaseSRWLockExclusive(&self.lock);
    const slot = self.panes.getPtr(pane) orelse {
        // It ended before the UI thread got to it.
        sink.ended(sink.ctx, "ended before it was shown");
        return;
    };
    switch (slot.*) {
        .pending => |*pend| {
            pend.replay(sink);
            pend.deinit(self.alloc);
        },
        .live => {},
    }
    slot.* = .{ .live = sink };
    if (self.lost) sink.ended(sink.ctx, "lost slime");
}

/// Forget a pane: its session is going. Doesn't end it. UI thread.
pub fn release(self: *Daemon, pane: u32) void {
    win32.AcquireSRWLockExclusive(&self.lock);
    defer win32.ReleaseSRWLockExclusive(&self.lock);
    if (self.panes.fetchRemove(pane)) |kv| switch (kv.value) {
        .pending => |pend| {
            var p = pend;
            p.deinit(self.alloc);
        },
        .live => {},
    };
}

/// Send a pane an event (event.zig), which must fit a message. UI
/// thread.
pub fn event(self: *Daemon, pane: u32, data: []const u8) void {
    if (data.len > max_frame - 5) return log.warn("dropped a {d}-byte event: too big", .{data.len});
    self.send(.event, pane, data) catch {};
}

/// Say the pane's frame `seq` and those before it are drawn, which lets
/// more come. UI thread.
pub fn ack(self: *Daemon, pane: u32, seq: u32) void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, seq, .little);
    self.send(.ack, pane, &b) catch {};
}

pub fn resize(self: *Daemon, pane: u32, size: Size) void {
    var b: [12]u8 = undefined;
    writeSize(&b, size);
    self.send(.resize, pane, &b) catch {};
}

/// Tell the daemon the window's tab area, for sizing panes it lays out
/// while the window is away.
pub fn resizeWorkspace(self: *Daemon, area: Area) void {
    var b: [20]u8 = undefined;
    std.mem.writeInt(u32, b[0..4], self.workspace, .little);
    writeArea(b[4..20], area);
    self.send(.workspace_resize, 0, &b) catch {};
}

/// End a pane, not just our view of it.
pub fn kill(self: *Daemon, pane: u32) void {
    self.send(.pane_kill, pane, &.{}) catch {};
}

/// Ask for a new tab running `command`. Its pane arrives through
/// `arrivals`, marked requested. UI thread.
pub fn tabNew(self: *Daemon, command: []const u16, size: Size) !void {
    _ = try self.tabNewTagged(command, size);
}

fn tabNewTagged(self: *Daemon, command: []const u16, size: Size) !u32 {
    const t = try self.requestTag();
    const cmd = try commandUtf8(self.alloc, command);
    defer self.alloc.free(cmd);
    var p: Payload = .{};
    defer p.deinit(self.alloc);
    try p.putU32(self.alloc, t);
    try p.putU32(self.alloc, self.workspace);
    try p.putStr(self.alloc, cmd);
    try p.putStr(self.alloc, "");
    try p.putSize(self.alloc, size);
    try self.send(.tab_new, 0, p.bytes());
    return t;
}

/// Ask for a pane running `command` on side `dir` of `pane`, taking half
/// its space. It arrives through `arrivals`, marked requested. UI thread.
pub fn split(self: *Daemon, pane: u32, dir: Direction, command: []const u16) !void {
    const t = try self.requestTag();
    const cmd = try commandUtf8(self.alloc, command);
    defer self.alloc.free(cmd);
    var p: Payload = .{};
    defer p.deinit(self.alloc);
    try p.putU32(self.alloc, t);
    try p.putU32(self.alloc, pane);
    try p.list.append(self.alloc, @intFromEnum(dir));
    try p.putU16(self.alloc, 5000);
    try p.putStr(self.alloc, cmd);
    try p.putStr(self.alloc, "");
    try self.send(.split, 0, p.bytes());
}

/// Replace tab `tab`'s tree with `root`, which must hold the same panes:
/// a divider was dragged. Each split's shares are scaled to sum to the
/// whole slime wants. The tree comes back as a Workspace message. UI
/// thread.
pub fn layout(self: *Daemon, tab: u32, root: Node) !void {
    var p: Payload = .{};
    defer p.deinit(self.alloc);
    try p.putU32(self.alloc, tab);
    try putNode(self.alloc, &p, root);
    try self.send(.layout, 0, p.bytes());
}

/// layout.go's Whole: what a split's shares sum to.
const whole_share = 10000;

fn putNode(alloc: Allocator, p: *Payload, node: Node) !void {
    switch (node) {
        .pane => |id| {
            try p.list.append(alloc, 0);
            try p.putU32(alloc, id);
        },
        .split => |sp| {
            try p.list.append(alloc, 1);
            try p.list.append(alloc, @intFromEnum(sp.axis));
            try p.putU16(alloc, @intCast(sp.children.len));
            var total: u32 = 0;
            for (sp.children) |c| total += c.share;
            // Scaled from the running total, so rounding doesn't add up;
            // every child keeps at least 1.
            var sum: u32 = 0;
            var given: u32 = 0;
            for (sp.children, 0..) |c, i| {
                sum += c.share;
                const left: u32 = @intCast(sp.children.len - 1 - i);
                const end: u32 = if (total == 0) whole_share * @as(u32, @intCast(i + 1)) / @as(u32, @intCast(sp.children.len)) else @intCast(@as(u64, sum) * whole_share / total);
                const share = std.math.clamp(end -| given, 1, whole_share - given - left);
                given += share;
                try p.putU16(alloc, @intCast(share));
                try putNode(alloc, p, c.node);
            }
        },
    }
}

/// A tag for a request whose panes the window shows when they come.
fn requestTag(self: *Daemon) !u32 {
    const t = self.nextTag();
    win32.AcquireSRWLockExclusive(&self.lock);
    defer win32.ReleaseSRWLockExclusive(&self.lock);
    try self.requested.append(self.alloc, t);
    return t;
}

fn commandUtf8(alloc: Allocator, command: []const u16) ![]u8 {
    return std.unicode.utf16LeToUtf8Alloc(alloc, command) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadCommand,
    };
}

fn nextTag(self: *Daemon) u32 {
    while (true) {
        const t = self.next_tag.fetchAdd(1, .monotonic) +% 1;
        if (t != 0) return t;
    }
}

fn send(self: *Daemon, msg: MsgType, id: u32, payload: []const u8) !void {
    win32.AcquireSRWLockExclusive(&self.write_lock);
    defer win32.ReleaseSRWLockExclusive(&self.write_lock);
    try self.pipe.send(msg, id, payload);
}

/// Read frames in line until the Workspace reply tagged `t` (and Created,
/// if `created`), as the reader would. Before the reader starts.
fn awaitReply(self: *Daemon, buf: []u8, t: u32, created: bool) !void {
    var got_workspace = false;
    var got_created = !created;
    while (!got_workspace or !got_created) {
        const f = try self.pipe.readFrame(buf);
        switch (f.type) {
            .workspace => if (try self.handle(f) == t) {
                got_workspace = true;
            },
            .created => {
                var r: Reader = .{ .buf = f.payload };
                if (try r.readU32() == t) got_created = true;
            },
            .@"error" => {
                var r: Reader = .{ .buf = f.payload };
                const et = try r.readU32();
                const msg = try r.readStr();
                log.err("slime: {s}", .{msg});
                if (et == t) return error.Refused;
            },
            else => _ = try self.handle(f),
        }
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
        _ = self.handle(f) catch |err| {
            log.warn("bad message {d} from slime: {}", .{ @intFromEnum(f.type), err });
        };
    }
    if (self.closing.load(.acquire)) return;
    self.loseAll(if (self.lost_reason.len > 0) self.lost_reason.text() else "lost slime");
}

/// Act on one frame. Returns a Workspace message's tag, else 0.
fn handle(self: *Daemon, f: Frame) !u32 {
    var r: Reader = .{ .buf = f.payload };
    win32.AcquireSRWLockExclusive(&self.lock);
    defer win32.ReleaseSRWLockExclusive(&self.lock);
    switch (f.type) {
        .attached => {
            const command = toUtf16(self.alloc, r.readStr() catch "") catch return error.OutOfMemory;
            errdefer self.alloc.free(command);
            const status = try readStatus(self.alloc, &r);
            errdefer freeStatus(self.alloc, status);
            const gop = try self.panes.getOrPut(self.alloc, f.id);
            if (gop.found_existing) switch (gop.value_ptr.*) {
                .pending => |*old| old.deinit(self.alloc),
                .live => {},
            };
            gop.value_ptr.* = .{ .pending = .{ .command = command, .status = status } };
        },
        .draw, .image, .notice, .copied => if (self.panes.getPtr(f.id)) |slot| switch (slot.*) {
            .pending => |*pend| try pend.keep(self.alloc, f),
            .live => |sink| try deliver(sink, f),
        },
        .exit => if (self.panes.fetchRemove(f.id)) |kv| switch (kv.value) {
            .pending => |pend| {
                var p = pend;
                p.deinit(self.alloc);
            },
            .live => |sink| sink.ended(sink.ctx, null),
        },
        .workspace => return self.workspaceChanged(&r),
        .detached => {
            const ws = try r.readU32();
            const reason = try r.readStr();
            if (ws == self.workspace) {
                var buf: [256]u8 = undefined;
                self.loseAllLocked(std.fmt.bufPrint(&buf, "detached: {s}", .{reason}) catch "detached");
            }
        },
        .@"error" => {
            const tag = try r.readU32();
            const msg = try r.readStr();
            log.warn("slime: {s}", .{msg});
            if (tag == 0) self.lost_reason.set(msg);
        },
        .host_state => {
            _ = try r.readU32(); // tag
            const dest = try toUtf16(self.alloc, try r.readStr());
            errdefer self.alloc.free(dest);
            const state: HostStatus = @enumFromInt(try r.readU8());
            const text = try toUtf16(self.alloc, try r.readStr());
            errdefer self.alloc.free(text);
            try self.hostEventLocked(.{ .state = .{ .host = f.id, .dest = dest, .state = state, .text = text } });
        },
        .prompt => {
            const prompt = try Prompt.parse(self.alloc, f.payload);
            errdefer prompt.destroy();
            try self.hostEventLocked(.{ .prompt = .{ .host = f.id, .prompt = prompt } });
        },
        .hosts => {
            const n = try r.readU32();
            if (n > r.buf.len / 13) return error.Truncated;
            const hosts = try self.alloc.alloc(HostInfo, n);
            var made: usize = 0;
            errdefer {
                for (hosts[0..made]) |*h| h.deinit(self.alloc);
                self.alloc.free(hosts);
            }
            for (hosts) |*h| {
                const id = try r.readU32();
                const dest = try toUtf16(self.alloc, try r.readStr());
                errdefer self.alloc.free(dest);
                const state: HostStatus = @enumFromInt(try r.readU8());
                const text = try toUtf16(self.alloc, try r.readStr());
                h.* = .{ .host = id, .dest = dest, .state = state, .text = text };
                made += 1;
            }
            try self.hostEventLocked(.{ .hosts = hosts });
        },
        else => {},
    }
    return 0;
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

/// A Workspace message: panes in it that attached go to `arrivals`, in
/// layout order, and its tabs replace `structure`. Returns its tag.
fn workspaceChanged(self: *Daemon, r: *Reader) !u32 {
    const st = try self.alloc.create(Structure);
    st.* = .{ .arena = .init(self.alloc), .tabs = &.{} };
    errdefer st.destroy(self.alloc);
    var tree = r.*;
    st.tabs = try readStructure(st.arena.allocator(), &tree);

    const t = try r.readU32();
    self.workspace = try r.readU32();
    _ = try r.readStr(); // name
    const requested = for (self.requested.items, 0..) |x, i| {
        if (x == t) {
            _ = self.requested.swapRemove(i);
            break true;
        }
    } else false;
    const tabs = try r.readU32();
    for (0..tabs) |_| {
        const tab = try r.readU32();
        _ = try r.readStr(); // name
        var ids: [64]u32 = undefined;
        var n: usize = 0;
        try readPanes(r, &ids, &n, 0);
        for (ids[0..n]) |pane| {
            const slot = self.panes.getPtr(pane) orelse continue;
            const pend = switch (slot.*) {
                .pending => |*p| p,
                .live => continue,
            };
            if (pend.arrived) continue;
            try self.arrivals.append(self.alloc, .{
                .pane = pane,
                .tab = tab,
                .command = pend.command,
                .status = pend.status,
                .requested = requested,
            });
            pend.arrived = true;
        }
    }
    if (self.structure) |old| old.destroy(self.alloc);
    self.structure = st;
    if (self.posting.load(.acquire)) _ = win32.PostMessageW(self.notify.hwnd, self.notify.msg, 0, 0);
    return t;
}

/// An Attached message's status records, at its end, owned.
fn readStatus(a: Allocator, r: *Reader) ![]StatusRecord {
    var it: StatusRecords = try .init(r);
    const out = try a.alloc(StatusRecord, it.left);
    var made: usize = 0;
    errdefer {
        for (out[0..made]) |rec| a.free(rec.id);
        a.free(out);
    }
    for (out) |*rec| {
        const got = it.next() orelse return error.Truncated;
        rec.* = got;
        rec.id = try a.dupe(u8, got.id);
        made += 1;
    }
    return out;
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

/// The tabs of a Workspace message, read from its tag on.
fn readStructure(a: Allocator, r: *Reader) ![]const Structure.TabLayout {
    _ = try r.readU32(); // tag
    _ = try r.readU32(); // workspace
    _ = try r.readStr(); // name
    const n = try r.readU32();
    if (n > r.buf.len) return error.Truncated;
    const tabs = try a.alloc(Structure.TabLayout, n);
    for (tabs) |*tab| {
        tab.id = try r.readU32();
        _ = try r.readStr(); // name
        tab.root = try readNode(a, r, 0);
    }
    return tabs;
}

fn readNode(a: Allocator, r: *Reader, depth: usize) !Node {
    if (depth > 32) return error.TooDeep;
    switch (try r.readU8()) {
        0 => return .{ .pane = try r.readU32() },
        1 => {
            const axis = std.enums.fromInt(Axis, try r.readU8()) orelse return error.BadLayout;
            const n = try r.readU16();
            if (n > r.buf.len) return error.Truncated;
            const children = try a.alloc(Child, n);
            for (children) |*c| {
                c.share = try r.readU16();
                c.node = try readNode(a, r, depth + 1);
            }
            return .{ .split = .{ .axis = axis, .children = children } };
        },
        else => return error.BadLayout,
    }
}

/// The pane ids in a layout tree, in order. More than `ids` holds are
/// left out.
fn readPanes(r: *Reader, ids: []u32, n: *usize, depth: usize) !void {
    if (depth > 32) return error.TooDeep;
    switch (try r.readU8()) {
        0 => {
            const id = try r.readU32();
            if (n.* < ids.len) {
                ids[n.*] = id;
                n.* += 1;
            }
        },
        1 => {
            _ = try r.readU8(); // axis
            const count = try r.readU16();
            for (0..count) |_| {
                _ = try r.readU16(); // share
                try readPanes(r, ids, n, depth + 1);
            }
        },
        else => return error.BadLayout,
    }
}

fn loseAll(self: *Daemon, why: []const u8) void {
    win32.AcquireSRWLockExclusive(&self.lock);
    defer win32.ReleaseSRWLockExclusive(&self.lock);
    self.loseAllLocked(why);
}

/// Tell every live pane it's gone from us. Pending ones are dropped.
fn loseAllLocked(self: *Daemon, why: []const u8) void {
    if (self.lost) return;
    self.lost = true;
    log.info("{s}", .{why});
    var it = self.panes.valueIterator();
    while (it.next()) |slot| switch (slot.*) {
        .pending => |*pend| pend.deinit(self.alloc),
        .live => |sink| sink.ended(sink.ctx, why),
    };
    self.panes.clearRetainingCapacity();
}

/// The id of the workspace detached last in a Workspaces payload, or 0.
fn mostRecentDetached(payload: []const u8) !u32 {
    var r: Reader = .{ .buf = payload };
    var best: u32 = 0;
    var best_at: u64 = 0;
    const n = try r.readU32();
    for (0..n) |_| {
        const id = try r.readU32();
        _ = try r.readStr(); // name
        const attached = try r.readU8() != 0;
        const at = try r.readU64();
        const tabs = try r.readU32();
        for (0..tabs) |_| {
            _ = try r.readU32();
            _ = try r.readStr();
            var ids: [1]u32 = undefined;
            var count: usize = 0;
            try readPanes(&r, &ids, &count, 0);
        }
        if (!attached and (best == 0 or at > best_at)) {
            best = id;
            best_at = at;
        }
    }
    return best;
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
    try self.send(.hello, 0, &hello);
    const f = try self.pipe.readFrame(buf);
    if (f.type == .@"error") {
        var er: Reader = .{ .buf = f.payload };
        _ = try er.readU32(); // tag
        self.failure.set(try er.readStr());
        return error.Refused;
    }
    if (f.type != .hello_reply) return error.BadReply;
    var r: Reader = .{ .buf = f.payload };
    const version = try r.readU32();
    _ = try r.readU32(); // pid
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

/// Open the daemon's pipe, first starting the daemon if `start_daemon` and none
/// is running.
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

    fn send(self: *Pipe, msg: MsgType, id: u32, payload: []const u8) !void {
        var header: [9]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], @intCast(5 + payload.len), .little);
        header[4] = @intFromEnum(msg);
        std.mem.writeInt(u32, header[5..9], id, .little);
        // One write for small frames, so a pipe trace shows whole frames.
        if (payload.len <= Payload.input_chunk) {
            var buf: [9 + Payload.input_chunk]u8 = undefined;
            @memcpy(buf[0..9], &header);
            @memcpy(buf[9..][0..payload.len], payload);
            return self.writeAll(buf[0 .. 9 + payload.len]);
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
        if (len < 5 or len > buf.len) return error.BadFrame;
        try self.readExact(buf[0..len]);
        return .{
            .type = @enumFromInt(buf[0]),
            .id = std.mem.readInt(u32, buf[1..5], .little),
            .payload = buf[5..len],
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

const Frame = struct {
    type: MsgType,
    id: u32,
    payload: []const u8,
};

fn writeSize(b: *[12]u8, size: Size) void {
    std.mem.writeInt(u16, b[0..2], size.cols, .little);
    std.mem.writeInt(u16, b[2..4], size.rows, .little);
    std.mem.writeInt(u32, b[4..8], size.cell_width, .little);
    std.mem.writeInt(u32, b[8..12], size.cell_height, .little);
}

fn writeArea(b: *[16]u8, area: Area) void {
    std.mem.writeInt(u32, b[0..4], area.width, .little);
    std.mem.writeInt(u32, b[4..8], area.height, .little);
    std.mem.writeInt(u32, b[8..12], area.cell_width, .little);
    std.mem.writeInt(u32, b[12..16], area.cell_height, .little);
}

/// A request's payload. Messages up to `input_chunk` bytes, as keys
/// are, build on the stack.
const Payload = struct {
    const input_chunk = 16 * 1024;

    list: std.ArrayList(u8) = .empty,

    fn deinit(self: *Payload, alloc: Allocator) void {
        self.list.deinit(alloc);
    }

    fn bytes(self: *const Payload) []const u8 {
        return self.list.items;
    }

    fn putU32(self: *Payload, alloc: Allocator, v: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try self.list.appendSlice(alloc, &b);
    }

    fn putU16(self: *Payload, alloc: Allocator, v: u16) !void {
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, v, .little);
        try self.list.appendSlice(alloc, &b);
    }

    fn putStr(self: *Payload, alloc: Allocator, s: []const u8) !void {
        try self.putU32(alloc, @intCast(s.len));
        try self.list.appendSlice(alloc, s);
    }

    fn putSize(self: *Payload, alloc: Allocator, size: Size) !void {
        var b: [12]u8 = undefined;
        writeSize(&b, size);
        try self.list.appendSlice(alloc, &b);
    }

    fn putArea(self: *Payload, alloc: Allocator, area: Area) !void {
        var b: [16]u8 = undefined;
        writeArea(&b, area);
        try self.list.appendSlice(alloc, &b);
    }
};

/// Reads payload fields. Bytes past the known fields are ignored, so the
/// daemon can add fields to a message.
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

test "a layout's shares are sent summing to the whole" {
    const alloc = std.testing.allocator;
    var inner = [_]Child{ .{ .share = 1, .node = .{ .pane = 2 } }, .{ .share = 1, .node = .{ .pane = 3 } }, .{ .share = 1, .node = .{ .pane = 4 } } };
    var outer = [_]Child{ .{ .share = 7000, .node = .{ .pane = 1 } }, .{ .share = 2000, .node = .{ .split = .{ .axis = .column, .children = &inner } } } };
    var p: Payload = .{};
    defer p.deinit(alloc);
    try putNode(alloc, &p, .{ .split = .{ .axis = .row, .children = &outer } });

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var r: Reader = .{ .buf = p.bytes() };
    const back = try readNode(arena.allocator(), &r, 0);
    const row = back.split.children;
    try std.testing.expectEqual(@as(u16, 7777), row[0].share);
    try std.testing.expectEqual(@as(u16, 2223), row[1].share);
    const column = row[1].node.split.children;
    try std.testing.expectEqual(@as(u16, 3333), column[0].share);
    try std.testing.expectEqual(@as(u16, 3333), column[1].share);
    try std.testing.expectEqual(@as(u16, 3334), column[2].share);
    try std.testing.expectEqual(@as(u32, 4), column[2].node.pane);
}

test "prompts parse as the Go side sends them" {
    // internal/daemon Prompt{Kind: PromptPassword, Title: "T",
    // Questions: [{Label: "pw: "}]}.
    const payload = [_]u8{1} ++ [_]u8{ 1, 0, 0, 0, 'T' } ++ [_]u8{0} ** 12 ++ [_]u8{ 1, 0, 0, 0 } ++
        [_]u8{ 4, 0, 0, 0, 'p', 'w', ':', ' ', 0 };
    const p = try Prompt.parse(std.testing.allocator, &payload);
    defer p.destroy();
    try std.testing.expectEqual(Prompt.Kind.password, p.kind);
    try std.testing.expectEqualSlices(u16, L("T"), p.title);
    try std.testing.expectEqual(@as(usize, 1), p.questions.len);
    try std.testing.expectEqualSlices(u16, L("pw: "), p.questions[0].label);
    try std.testing.expect(!p.questions[0].echo);
    try std.testing.expectError(error.Truncated, Prompt.parse(std.testing.allocator, payload[0..20]));
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
