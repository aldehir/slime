//! A window's connection to slimed (ssh/cmd/slimed), the daemon that
//! owns local ptys so they outlive the window. The daemon keeps panes in
//! tabs and tabs in workspaces; a window attaches one workspace and
//! mirrors it. The protocol is ssh/internal/persist's (wire.go).
//!
//! Attaching delivers each pane's snapshot, for its session to decode
//! into its own terminal, and then the pane's output from exactly where
//! the snapshot ends. One reader thread reads the connection and hands
//! each pane's output to its session through a `Sink`.
//!
//! Panes that arrive while the reader runs (a new tab, or one a script
//! added) collect their snapshot and early output on the reader thread,
//! then wait in `arrivals` for the UI thread, which is told with the
//! `notify` message. Adopting one replays what was buffered under the
//! connection's lock before the pane goes live, so nothing is lost or
//! reordered at the handoff.
//!
//! The local daemon is reached through its named pipe (`connect`). An SSH
//! host's runs there, and is reached through a channel slime-ssh bridges
//! to it (`connectRemote`), whose reader logs in and attaches before it
//! routes frames.
const Slimed = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const ghostty_vt = @import("ghostty-vt");
const win32 = @import("win32/win32.zig");
const SshConnection = @import("SshConnection.zig");

const log = std.log.scoped(.slimed);

const L = std.unicode.utf8ToUtf16LeStringLiteral;

/// ssh/internal/persist's Version.
const protocol_version = 1;
const max_frame = 1 << 20;
/// Long enough for long-path-aware installs.
const max_path = 32 * 1024;
const daemon_name = L("slimed.exe");

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
    input = 15,
    resize = 16,
    peek = 17,
    hello_reply = 65,
    workspaces = 66,
    workspace = 67,
    attached = 68,
    snapshot = 69,
    output = 70,
    exit = 71,
    detached = 72,
    @"error" = 73,
    created = 74,
    _,
};

alloc: Allocator,
pipe: Pipe,
notify: Notify,
reader: ?std.Thread = null,
/// Frames are written from the UI thread (keys, resizes, requests) and
/// the reader thread (query replies); each goes out whole.
write_lock: win32.SRWLOCK = .{},
/// The attached workspace.
workspace: u32 = 0,
/// Tags for requests, from the UI thread and, while a host's attaches,
/// its reader.
next_tag: std.atomic.Value(u32) = .init(0),

/// The channel a host's slimed is reached through; null for the local
/// daemon's pipe. Owned.
channel: ?*SshConnection.Channel = null,
/// How attaching went. A host's starts out connecting, and its reader
/// says how it ended (`notify`).
state: std.atomic.Value(State) = .init(.attached),
/// Why attaching failed, once `state` says it did.
failure: Failure = .{},
/// What a host's reader attaches with.
area: Area = undefined,
size: Size = undefined,
/// The reader posts `notify` when panes arrive: from `start` for the
/// local daemon, and once attached for a host's.
posting: std.atomic.Value(bool) = .init(false),

/// Guards `panes`, `arrivals`, `structure`, `requested`, and `lost`, and
/// is held while calling a sink, so a session can't go while one runs.
lock: win32.SRWLOCK = .{},
panes: std.AutoHashMapUnmanaged(u32, Slot) = .empty,
arrivals: std.ArrayList(Arrival) = .empty,
structure: ?*Structure = null,
/// Tags of our own TabNew and Split requests, so their panes can be
/// shown.
requested: std.ArrayList(u32) = .empty,
/// The connection ended; every live pane was told why.
lost: bool = false,
/// `deinit` is hanging up, so the reader's end isn't a loss.
closing: std.atomic.Value(bool) = .init(false),

/// A window message posted from the reader thread when panes arrive, and
/// when a host's slimed has attached or failed to.
pub const Notify = struct {
    hwnd: win32.HWND,
    msg: u32,
};

pub const State = enum(u8) { connecting, attached, failed };

/// Why attaching to a host's slimed failed, for the window to show.
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

/// Where a live pane's output and end go: its session.
pub const Sink = struct {
    ctx: *anyopaque,
    /// Output for the pane's terminal.
    output: *const fn (ctx: *anyopaque, data: []const u8) void,
    /// The pane is gone from us: its child exited (`why` null), or the
    /// workspace or connection was lost (why says how).
    ended: *const fn (ctx: *anyopaque, why: ?[]const u8) void,
};

/// A pane whose snapshot is in, for the UI thread to make a session of.
pub const Arrival = struct {
    pane: u32,
    tab: u32,
    /// Owned, in the connection's allocator; so is `command`.
    snapshot: []u8,
    command: []const u16,
    /// win32-input-mode, which a snapshot doesn't carry.
    win32_input: bool,
    /// What its programs report doing (OSC 7501), which a snapshot
    /// doesn't carry either, oldest update first. Owned.
    status: []StatusRecord,
    /// From our own TabNew or Split, so the window shows it.
    requested: bool,

    pub fn deinit(self: *Arrival, alloc: Allocator) void {
        alloc.free(self.snapshot);
        alloc.free(self.command);
        freeStatus(alloc, self.status);
    }
};

/// A program status record as the daemon keeps it (wire.go's
/// StatusRecord). `state` numbers as `ProgramStatus.State`.
pub const StatusRecord = struct {
    /// Owned.
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
    /// Snapshot coming in, or in and waiting for the UI thread; output
    /// that comes meanwhile is kept for adoption.
    pending: Pending,
    live: Sink,
};

const Pending = struct {
    want: ?usize = null,
    snapshot: std.ArrayList(u8) = .empty,
    output: std.ArrayList(u8) = .empty,
    command: []const u16 = &.{},
    win32_input: bool = false,
    status: []StatusRecord = &.{},
    /// Handed to `arrivals` already.
    arrived: bool = false,

    fn deinit(self: *Pending, alloc: Allocator) void {
        self.snapshot.deinit(alloc);
        self.output.deinit(alloc);
        if (!self.arrived) {
            alloc.free(self.command);
            freeStatus(alloc, self.status);
        }
    }
};

/// Connect, starting the daemon if it isn't running, and attach the most
/// recently detached workspace, or a new one with a tab running
/// `command`. The workspace's panes wait in `arrivals`; `start` the
/// reader after adopting them. UI thread.
pub fn connect(alloc: Allocator, notify: Notify, area: Area, size: Size, command: []const u16) !*Slimed {
    var pipe: Pipe = try .open(true);
    errdefer pipe.close();
    const buf = try alloc.alloc(u8, max_frame);
    defer alloc.free(buf);

    const self = try alloc.create(Slimed);
    errdefer alloc.destroy(self);
    self.* = .{ .alloc = alloc, .pipe = pipe, .notify = notify };
    errdefer self.freeState();
    try self.attachFirst(buf, area, size, command);
    return self;
}

/// Connect to a host's slimed through `channel` (`SshConnection.openSlimed`),
/// which logs in first if its connection hasn't. The reader does the
/// rest: it attaches as `connect` does, a new workspace's tab running the
/// host's shell, and posts `notify` once `state` says how that went. The
/// panes then wait in `arrivals`. Takes the channel, even on failure. UI
/// thread.
pub fn connectRemote(alloc: Allocator, notify: Notify, channel: *SshConnection.Channel, area: Area, size: Size) !*Slimed {
    errdefer {
        channel.close();
        channel.deinit();
    }
    const self = try alloc.create(Slimed);
    errdefer alloc.destroy(self);
    self.* = .{
        .alloc = alloc,
        .pipe = .ofChannel(channel),
        .notify = notify,
        .channel = channel,
        .state = .init(.connecting),
        .area = area,
        .size = size,
    };
    self.reader = try std.Thread.spawn(.{}, remoteLoop, .{self});
    return self;
}

/// Say hello, then attach the most recently detached workspace, or a new
/// one with a tab running `command`, reading the replies in line. Before
/// the reader routes frames.
fn attachFirst(self: *Slimed, buf: []u8, area: Area, size: Size, command: []const u16) !void {
    const alloc = self.alloc;
    try handshake(&self.pipe, buf);

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
pub fn start(self: *Slimed) !void {
    self.posting.store(true, .release);
    self.reader = try std.Thread.spawn(.{}, readLoop, .{self});
}

/// Hang up, which detaches the workspace; the daemon keeps it. Every
/// session must have released its pane. UI thread.
pub fn deinit(self: *Slimed) void {
    self.closing.store(true, .release);
    // Closing a host's channel has the helper close its ends, which ends
    // the reader's read, or its wait to log in.
    if (self.channel) |ch| ch.close();
    if (self.reader) |t| {
        // Wake it until it's gone: a cancel that lands before it blocks in
        // ReadFile again is lost.
        while (win32.WaitForSingleObject(t.getHandle(), 0) != win32.WAIT_OBJECT_0) {
            if (self.channel == null)
                _ = win32.CancelIoEx(self.pipe.read_h, null)
            else
                _ = win32.CancelSynchronousIo(t.getHandle());
            _ = win32.WaitForSingleObject(t.getHandle(), 20);
        }
        t.join();
    }
    self.pipe.close();
    if (self.channel) |ch| ch.deinit();
    self.freeState();
    self.alloc.destroy(self);
}

/// The SSH connection a host's slimed is reached through; null for the
/// local daemon.
pub fn host(self: *const Slimed) ?*SshConnection {
    return if (self.channel) |ch| ch.conn else null;
}

/// How attaching went. The reader posts `notify` when it changes.
pub fn attachState(self: *const Slimed) State {
    return self.state.load(.acquire);
}

/// Every pane was lost to us: the connection ended, or another window
/// took the workspace. UI thread.
pub fn isLost(self: *Slimed) bool {
    win32.AcquireSRWLockExclusive(&self.lock);
    defer win32.ReleaseSRWLockExclusive(&self.lock);
    return self.lost;
}

/// A host's reader: attach, then route frames as `readLoop` does.
fn remoteLoop(self: *Slimed) void {
    const buf = self.alloc.alloc(u8, max_frame) catch return self.fail(error.OutOfMemory);
    defer self.alloc.free(buf);
    // The host's own shell: the command is for its slimed to run.
    self.attachFirst(buf, self.area, self.size, &.{}) catch |err| return self.fail(err);
    log.info("attached workspace {d} on {f}", .{ self.workspace, std.unicode.fmtUtf16Le(self.host().?.label()) });
    self.state.store(.attached, .release);
    self.posting.store(true, .release);
    _ = win32.PostMessageW(self.notify.hwnd, self.notify.msg, 0, 0);
    self.route(buf);
}

/// A host's slimed couldn't attach: say why, which for a channel that
/// ended is what the helper said. Nobody's told if `deinit` is hanging
/// up.
fn fail(self: *Slimed, err: anyerror) void {
    if (self.closing.load(.acquire)) return;
    const ch = self.channel.?;
    const text = switch (err) {
        error.EndOfStream => if (ch.ended(5000)) |e| e.text() else "slimed hung up",
        error.VersionMismatch => "its slimed doesn't match this slime",
        error.Refused => "slimed refused to attach",
        error.OutOfMemory => "out of memory",
        else => @errorName(err),
    };
    log.info("no slimed on {f}: {s}", .{ std.unicode.fmtUtf16Le(ch.conn.label()), text });
    self.failure.set(text);
    self.state.store(.failed, .release);
    _ = win32.PostMessageW(self.notify.hwnd, self.notify.msg, 0, 0);
}

fn freeState(self: *Slimed) void {
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
}

/// Take the panes waiting for sessions and the latest tabs, together so
/// the tabs name no pane the caller hasn't seen. The caller owns them
/// (`Taken.deinit`) and must `adopt` or `release` each arrival. UI
/// thread.
pub fn take(self: *Slimed) Taken {
    win32.AcquireSRWLockExclusive(&self.lock);
    defer win32.ReleaseSRWLockExclusive(&self.lock);
    const structure = self.structure;
    self.structure = null;
    return .{ .arrivals = self.arrivals.toOwnedSlice(self.alloc) catch &.{}, .structure = structure };
}

/// Make `sink` the pane's: what came while it waited goes first, then
/// the live output. UI thread.
pub fn adopt(self: *Slimed, pane: u32, sink: Sink) void {
    win32.AcquireSRWLockExclusive(&self.lock);
    defer win32.ReleaseSRWLockExclusive(&self.lock);
    const slot = self.panes.getPtr(pane) orelse {
        // It ended before the UI thread got to it.
        sink.ended(sink.ctx, "ended before it was shown");
        return;
    };
    switch (slot.*) {
        .pending => |*pend| {
            if (pend.output.items.len > 0) sink.output(sink.ctx, pend.output.items);
            pend.deinit(self.alloc);
        },
        .live => {},
    }
    slot.* = .{ .live = sink };
    if (self.lost) sink.ended(sink.ctx, "lost slimed");
}

/// Forget a pane: its session is going. Doesn't end it. UI thread.
pub fn release(self: *Slimed, pane: u32) void {
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

/// Send input to a pane. Called from both the UI thread and the reader
/// thread (query replies), like `Pty.write`.
pub fn write(self: *Slimed, pane: u32, data: []const u8) void {
    var rest = data;
    while (rest.len > 0) {
        const n = @min(rest.len, Payload.input_chunk);
        self.send(.input, pane, rest[0..n]) catch return;
        rest = rest[n..];
    }
}

pub fn resize(self: *Slimed, pane: u32, size: Size) void {
    var b: [12]u8 = undefined;
    writeSize(&b, size);
    self.send(.resize, pane, &b) catch {};
}

/// Tell the daemon the window's tab area, for sizing panes it lays out
/// while the window is away.
pub fn resizeWorkspace(self: *Slimed, area: Area) void {
    var b: [20]u8 = undefined;
    std.mem.writeInt(u32, b[0..4], self.workspace, .little);
    writeArea(b[4..20], area);
    self.send(.workspace_resize, 0, &b) catch {};
}

/// End a pane, not just our view of it.
pub fn kill(self: *Slimed, pane: u32) void {
    self.send(.pane_kill, pane, &.{}) catch {};
}

/// Ask for a new tab running `command`. Its pane arrives through
/// `arrivals`, marked requested. UI thread.
pub fn tabNew(self: *Slimed, command: []const u16, size: Size) !void {
    _ = try self.tabNewTagged(command, size);
}

fn tabNewTagged(self: *Slimed, command: []const u16, size: Size) !u32 {
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
pub fn split(self: *Slimed, pane: u32, dir: Direction, command: []const u16) !void {
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
/// whole slimed wants. The tree comes back as a Workspace message. UI
/// thread.
pub fn layout(self: *Slimed, tab: u32, root: Node) !void {
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
fn requestTag(self: *Slimed) !u32 {
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

fn nextTag(self: *Slimed) u32 {
    while (true) {
        const t = self.next_tag.fetchAdd(1, .monotonic) +% 1;
        if (t != 0) return t;
    }
}

fn send(self: *Slimed, msg: MsgType, id: u32, payload: []const u8) !void {
    win32.AcquireSRWLockExclusive(&self.write_lock);
    defer win32.ReleaseSRWLockExclusive(&self.write_lock);
    try self.pipe.send(msg, id, payload);
}

/// Read frames in line until the Workspace reply tagged `t` (and Created,
/// if `created`), as the reader would. Before the reader starts.
fn awaitReply(self: *Slimed, buf: []u8, t: u32, created: bool) !void {
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
                log.err("slimed: {s}", .{msg});
                if (et == t) return error.Refused;
            },
            else => _ = try self.handle(f),
        }
    }
}

/// Reader thread for the local daemon.
fn readLoop(self: *Slimed) void {
    const buf = self.alloc.alloc(u8, max_frame) catch {
        if (!self.closing.load(.acquire)) self.loseAll("out of memory");
        return;
    };
    defer self.alloc.free(buf);
    self.route(buf);
}

/// Route frames until the connection ends, then tell every live pane:
/// for a host's, why its channel ended (the connection broke, say).
fn route(self: *Slimed, buf: []u8) void {
    while (true) {
        const f = self.pipe.readFrame(buf) catch break;
        _ = self.handle(f) catch |err| {
            log.warn("bad message {d} from slimed: {}", .{ @intFromEnum(f.type), err });
        };
    }
    if (self.closing.load(.acquire)) return;
    var why: []const u8 = "lost slimed";
    if (self.channel) |ch| if (ch.ended(1000)) |e| {
        if (e.text().len > 0) why = e.text();
    };
    self.loseAll(why);
}

/// Act on one frame. Returns a Workspace message's tag, else 0.
fn handle(self: *Slimed, f: Frame) !u32 {
    var r: Reader = .{ .buf = f.payload };
    win32.AcquireSRWLockExclusive(&self.lock);
    defer win32.ReleaseSRWLockExclusive(&self.lock);
    switch (f.type) {
        .attached => {
            _ = try r.readU32(); // tag
            const len = try r.readU32();
            var win32_input = false;
            const modes = try r.readU32();
            for (0..modes) |_| {
                const mode = try r.readU16();
                const ansi = try r.readU8() != 0;
                const enabled = try r.readU8() != 0;
                if (mode == 9001 and !ansi) win32_input = enabled;
            }
            const command = toUtf16(self.alloc, r.readStr() catch "") catch return error.OutOfMemory;
            errdefer self.alloc.free(command);
            const status = try readStatus(self.alloc, &r);
            errdefer freeStatus(self.alloc, status);
            var pend: Pending = .{ .want = len, .command = command, .win32_input = win32_input, .status = status };
            try pend.snapshot.ensureTotalCapacityPrecise(self.alloc, len);
            const gop = try self.panes.getOrPut(self.alloc, f.id);
            if (gop.found_existing) switch (gop.value_ptr.*) {
                .pending => |*old| old.deinit(self.alloc),
                .live => {},
            };
            gop.value_ptr.* = .{ .pending = pend };
        },
        .snapshot => if (self.panes.getPtr(f.id)) |slot| switch (slot.*) {
            .pending => |*pend| {
                if (pend.snapshot.items.len + f.payload.len > pend.want orelse 0) return error.BadSnapshot;
                pend.snapshot.appendSliceAssumeCapacity(f.payload);
            },
            .live => {},
        },
        .output => if (self.panes.getPtr(f.id)) |slot| switch (slot.*) {
            .pending => |*pend| try pend.output.appendSlice(self.alloc, f.payload),
            .live => |sink| sink.output(sink.ctx, f.payload),
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
            _ = try r.readU32(); // tag
            log.warn("slimed: {s}", .{try r.readStr()});
        },
        else => {},
    }
    return 0;
}

/// A Workspace message: panes in it whose snapshots are in go to
/// `arrivals`, in layout order, and its tabs replace `structure`. Returns
/// its tag.
fn workspaceChanged(self: *Slimed, r: *Reader) !u32 {
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
            if (pend.arrived or pend.want == null or pend.snapshot.items.len != pend.want.?) continue;
            const snapshot = try pend.snapshot.toOwnedSlice(self.alloc);
            errdefer self.alloc.free(snapshot);
            try self.arrivals.append(self.alloc, .{
                .pane = pane,
                .tab = tab,
                .snapshot = snapshot,
                .command = pend.command,
                .win32_input = pend.win32_input,
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

/// An Attached message's status records, at its end. A daemon too old to
/// send them sends none.
fn readStatus(a: Allocator, r: *Reader) ![]StatusRecord {
    const n = r.readU32() catch return &.{};
    if (n > r.buf.len / 6) return error.Truncated;
    const out = try a.alloc(StatusRecord, n);
    var made: usize = 0;
    errdefer {
        for (out[0..made]) |rec| a.free(rec.id);
        a.free(out);
    }
    for (out) |*rec| {
        const id = try a.dupe(u8, try r.readStr());
        errdefer a.free(id);
        const state = try r.readU8();
        const progress = try r.readU8();
        rec.* = .{ .id = id, .state = state, .progress = if (progress <= 100) progress else null };
        made += 1;
    }
    return out;
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

fn loseAll(self: *Slimed, why: []const u8) void {
    win32.AcquireSRWLockExclusive(&self.lock);
    defer win32.ReleaseSRWLockExclusive(&self.lock);
    self.loseAllLocked(why);
}

/// Tell every live pane it's gone from us. Pending ones are dropped.
fn loseAllLocked(self: *Slimed, why: []const u8) void {
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

/// Say hello, and check the daemon writes snapshots we can read.
fn handshake(pipe: *Pipe, buf: []u8) !void {
    var hello: [4]u8 = undefined;
    std.mem.writeInt(u32, &hello, protocol_version, .little);
    try pipe.send(.hello, 0, &hello);
    const f = try pipe.readFrame(buf);
    if (f.type != .hello_reply) return error.BadReply;
    var r: Reader = .{ .buf = f.payload };
    const version = try r.readU32();
    const snapshot_version = try r.readU16();
    if (version != protocol_version) {
        log.err("slimed speaks protocol {d}, we speak {d}", .{ version, protocol_version });
        return error.VersionMismatch;
    }
    if (snapshot_version != ghostty_vt.snapshot.envelope.version) {
        log.err("slimed writes snapshot format {d}, we read {d}", .{ snapshot_version, ghostty_vt.snapshot.envelope.version });
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

/// `\\.\pipe\slimed-<user SID>`, NUL-terminated: one daemon per user.
/// With SLIMED_INSTANCE set, `-<instance>` follows, as the daemon names
/// it (persist.Address).
fn pipeName(buf: *WideBuf) ![:0]const u16 {
    var token_buf: [256]u8 align(@alignOf(win32.TOKEN_USER)) = undefined;
    const sid = try currentUser(&token_buf);
    var str: ?win32.LPWSTR = null;
    if (win32.ConvertSidToStringSidW(sid, &str) == 0) return win32.lastError("ConvertSidToStringSidW");
    defer _ = win32.LocalFree(str);
    try buf.put(L("\\\\.\\pipe\\slimed-"));
    try buf.put(std.mem.span(str.?));
    var inst: [64]u16 = undefined;
    if (instance(&inst)) |name| {
        try buf.put(L("-"));
        try buf.put(name);
    }
    return buf.z();
}

/// SLIMED_INSTANCE, if it's set: a daemon of its own, for tests.
fn instance(buf: *[64]u16) ?[]const u16 {
    const len = win32.GetEnvironmentVariableW(L("SLIMED_INSTANCE"), buf, buf.len);
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
        log.err("slimed's pipe is served by another user's process (pid {d})", .{pid});
        return error.ForeignServer;
    }
}

/// Run slimed so it outlives us: detached, and out of any job we're in.
///
/// It runs from a copy in %LOCALAPPDATA%\slime\bin, named for the size
/// and time of the slimed.exe next to us: a running exe can't be
/// replaced, and the daemon runs as long as its sessions, so running ours
/// in place would stop the next build from installing over it. It loads
/// the ConPTY next to us (which doesn't change between builds). Its log
/// goes to %LOCALAPPDATA%\slime\slimed.log (slimed-<instance>.log with
/// SLIMED_INSTANCE).
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
        if (win32.GetFileAttributesExW(try src.z(), win32.GetFileExInfoStandard, &attrs) == 0)
            return win32.lastError("GetFileAttributesExW(slimed.exe)");

        var base: WideBuf = .{};
        try base.put(appdata[0..len]);
        try base.put(L("\\slime"));
        try makeDir(&base);
        try log_path.put(base.slice());
        try log_path.put(L("\\slimed"));
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
        const name = std.fmt.bufPrint(&name_buf, "\\slimed-{x}-{x}.exe", .{ size, attrs.ftLastWriteTime }) catch unreachable;
        try exe.put(base.slice());
        try exe.putAscii(name);
        if (win32.CopyFileW(try src.z(), try exe.z(), win32.TRUE) == 0 and win32.GetLastError() != win32.ERROR_FILE_EXISTS)
            return win32.lastError("CopyFileW(slimed.exe)");
    }
    if (exe.len == 0) try exe.put(src.slice());

    // No trailing backslash before a closing quote, which would escape
    // it.
    var cmd: WideBuf = .{};
    try cmd.put(L("\""));
    try cmd.put(exe.slice());
    try cmd.put(L("\" serve --conpty \""));
    try cmd.put(dir);
    try cmd.put(L("\""));
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
            log.info("started slimed (pid {d}){s}", .{ pi.dwProcessId, if (extra == 0) " inside our job" else "" });
            return;
        }
    }
    return win32.lastError("CreateProcessW(slimed.exe)");
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

/// The connection: the daemon's pipe, or a host's channel. Reads are the
/// reader's (or `connect`'s, before the reader starts); writes take the
/// connection's write lock.
///
/// The daemon's pipe is opened for overlapped I/O. Windows serializes
/// synchronous I/O on a handle, so a blocking read, which the reader
/// thread is in most of the time, would hold up every write behind it.
/// Reads and writes each wait on their own event instead. A channel's
/// anonymous pipes are synchronous, but one each way, so they don't.
const Pipe = struct {
    read_h: win32.HANDLE,
    write_h: win32.HANDLE,
    /// The daemon's pipe's, for reads and writes; null for a channel.
    events: ?[2]win32.HANDLE,

    fn open(start_daemon: bool) !Pipe {
        const h = try openPipe(start_daemon);
        errdefer _ = win32.CloseHandle(h);
        const read_event = win32.CreateEventW(null, win32.TRUE, win32.FALSE, null) orelse return win32.lastError("CreateEventW");
        errdefer _ = win32.CloseHandle(read_event);
        const write_event = win32.CreateEventW(null, win32.TRUE, win32.FALSE, null) orelse return win32.lastError("CreateEventW");
        return .{ .read_h = h, .write_h = h, .events = .{ read_event, write_event } };
    }

    /// The channel's pipes, which stay the channel's.
    fn ofChannel(ch: *SshConnection.Channel) Pipe {
        return .{ .read_h = ch.output, .write_h = ch.input, .events = null };
    }

    fn close(self: *Pipe) void {
        const events = self.events orelse return;
        _ = win32.CloseHandle(self.read_h);
        for (events) |e| _ = win32.CloseHandle(e);
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
            if (self.events) |events| {
                var ov: win32.OVERLAPPED = .{ .hEvent = events[1] };
                if (win32.WriteFile(self.write_h, rest.ptr, len, null, &ov) == 0 and win32.GetLastError() != win32.ERROR_IO_PENDING)
                    return error.BrokenPipe;
                if (win32.GetOverlappedResult(self.write_h, &ov, &n, win32.TRUE) == 0) return error.BrokenPipe;
            } else if (win32.WriteFile(self.write_h, rest.ptr, len, &n, null) == 0) return error.BrokenPipe;
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
            if (self.events) |events| {
                var ov: win32.OVERLAPPED = .{ .hEvent = events[0] };
                if (win32.ReadFile(self.read_h, buf[got..].ptr, len, null, &ov) == 0 and win32.GetLastError() != win32.ERROR_IO_PENDING)
                    return error.EndOfStream;
                if (win32.GetOverlappedResult(self.read_h, &ov, &n, win32.TRUE) == 0) return error.EndOfStream;
            } else if (win32.ReadFile(self.read_h, buf[got..].ptr, len, &n, null) == 0) return error.EndOfStream;
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

/// A request's payload. Input goes in chunks of `input_chunk` bytes, so
/// the frames for keys and pastes build on the stack.
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

test "frames match the Go side's wire format" {
    // ssh/internal/persist: Resize{Size{0x0102, 0x0304, 0x05060708,
    // 0x090a0b0c}} on 2.
    var b: [12]u8 = undefined;
    writeSize(&b, .{ .cols = 0x0102, .rows = 0x0304, .cell_width = 0x05060708, .cell_height = 0x090a0b0c });
    try std.testing.expectEqualSlices(u8, &.{
        0x02, 0x01, 0x04, 0x03,
        0x08, 0x07, 0x06, 0x05,
        0x0c, 0x0b, 0x0a, 0x09,
    }, &b);
}
