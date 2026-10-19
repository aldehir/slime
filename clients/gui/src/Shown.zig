//! The workspaces a window showed, remembered for the next one: the
//! `workspaces` file in the config directory, a list per daemon. A
//! `daemon <pid>` line starts the local daemon's list and a
//! `host <dest> <pid>` line a host's (its destination as the sidebar
//! remembers it), each followed by a workspace id per line. Ids start
//! over with each daemon, so a list only counts for the daemon it was
//! written under (`Daemon.Wanted`). Saved whenever a window shows a
//! different set on one of them.
const Shown = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Daemon = @import("Daemon.zig");

const log = std.log.scoped(.shown);

alloc: Allocator,
io: std.Io,
/// The file, or null with no config directory: then nothing is saved.
path: ?[]u8,
/// The local daemon's list.
local: List = .{},
/// A list per host, in the order first written.
hosts: std.ArrayList(HostList) = .empty,

/// The workspaces shown on one daemon, the one with `pid`.
const List = struct {
    pid: u32 = 0,
    ids: std.ArrayList(u32) = .empty,

    fn deinit(self: *List, alloc: Allocator) void {
        self.ids.deinit(alloc);
    }
};

const HostList = struct {
    /// Owned.
    dest: []u16,
    list: List,
};

/// Read the lists from `dir`. A missing or unreadable file is empty
/// lists.
pub fn load(alloc: Allocator, io: std.Io, dir: ?[]const u8) Allocator.Error!Shown {
    var self: Shown = .{
        .alloc = alloc,
        .io = io,
        .path = if (dir) |d| try std.fs.path.join(alloc, &.{ d, "workspaces" }) else null,
    };
    errdefer self.deinit();
    const path = self.path orelse return self;
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 16)) catch |err| {
        if (err != error.FileNotFound) log.warn("reading {s}: {}", .{ path, err });
        return self;
    };
    defer alloc.free(text);
    try self.parse(text);
    return self;
}

pub fn deinit(self: *Shown) void {
    self.local.deinit(self.alloc);
    for (self.hosts.items) |*h| {
        self.alloc.free(h.dest);
        h.list.deinit(self.alloc);
    }
    self.hosts.deinit(self.alloc);
    if (self.path) |p| self.alloc.free(p);
    self.* = undefined;
}

fn parse(self: *Shown, text: []const u8) Allocator.Error!void {
    // Ids before any heading are the local daemon's, as the file was
    // before hosts had lists.
    var current: *List = &self.local;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "daemon ")) {
            self.local.pid = parsePid(line["daemon ".len..]);
            current = &self.local;
            continue;
        }
        if (std.mem.startsWith(u8, line, "host ")) {
            const rest = std.mem.trim(u8, line["host ".len..], " \t");
            // The pid is after the last space; destinations have none.
            const split = std.mem.lastIndexOfScalar(u8, rest, ' ') orelse rest.len;
            const dest = std.unicode.utf8ToUtf16LeAlloc(self.alloc, rest[0..split]) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            defer self.alloc.free(dest);
            if (dest.len == 0) continue;
            const h = try self.host(dest);
            h.pid = if (split < rest.len) parsePid(rest[split + 1 ..]) else 0;
            current = h;
            continue;
        }
        const id = std.fmt.parseUnsigned(u32, line, 10) catch continue;
        if (id != 0 and std.mem.indexOfScalar(u32, current.ids.items, id) == null) try current.ids.append(self.alloc, id);
    }
}

fn parsePid(text: []const u8) u32 {
    return std.fmt.parseUnsigned(u32, std.mem.trim(u8, text, " \t"), 10) catch 0;
}

/// Host `dest`'s list, made if it has none.
fn host(self: *Shown, dest: []const u16) Allocator.Error!*List {
    for (self.hosts.items) |*h| {
        if (std.mem.eql(u16, h.dest, dest)) return &h.list;
    }
    const owned = try self.alloc.dupe(u16, dest);
    errdefer self.alloc.free(owned);
    try self.hosts.append(self.alloc, .{ .dest = owned, .list = .{} });
    return &self.hosts.items[self.hosts.items.len - 1].list;
}

/// The list for `dest`, or the local daemon's for null, if there is one.
fn find(self: *const Shown, dest: ?[]const u16) ?*const List {
    const d = dest orelse return &self.local;
    for (self.hosts.items) |*h| {
        if (std.mem.eql(u16, h.dest, d)) return &h.list;
    }
    return null;
}

/// What to attach at connect to host `dest`'s daemon, or the local one
/// for null.
pub fn wanted(self: *const Shown, dest: ?[]const u16) Daemon.Wanted {
    const list = self.find(dest) orelse return .{};
    return .{ .pid = list.pid, .ids = list.ids.items };
}

/// Remember `ids` as shown on the daemon with `pid` on host `dest` (the
/// local one for null), if that's a change.
pub fn set(self: *Shown, dest: ?[]const u16, pid: u32, ids: []const u32) void {
    if (self.find(dest)) |list| {
        if (list.pid == pid and std.mem.eql(u32, list.ids.items, ids)) return;
    }
    const list = if (dest) |d| self.host(d) catch return else &self.local;
    list.ids.clearRetainingCapacity();
    list.ids.appendSlice(self.alloc, ids) catch return;
    list.pid = pid;
    self.save();
}

fn save(self: *const Shown) void {
    const path = self.path orelse return;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(self.alloc);
    self.format(&text) catch return log.warn("saving {s}: out of memory", .{path});
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |dir| cwd.createDirPath(self.io, dir) catch {};
    cwd.writeFile(self.io, .{ .sub_path = path, .data = text.items }) catch |err|
        log.warn("saving {s}: {}", .{ path, err });
}

fn format(self: *const Shown, text: *std.ArrayList(u8)) Allocator.Error!void {
    var buf: [32]u8 = undefined;
    try text.appendSlice(self.alloc, std.fmt.bufPrint(&buf, "daemon {d}\n", .{self.local.pid}) catch unreachable);
    try formatIds(self.alloc, text, self.local.ids.items);
    for (self.hosts.items) |h| {
        // One with an unpaired surrogate isn't kept.
        const dest = std.unicode.utf16LeToUtf8Alloc(self.alloc, h.dest) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer self.alloc.free(dest);
        try text.appendSlice(self.alloc, "host ");
        try text.appendSlice(self.alloc, dest);
        try text.appendSlice(self.alloc, std.fmt.bufPrint(&buf, " {d}\n", .{h.list.pid}) catch unreachable);
        try formatIds(self.alloc, text, h.list.ids.items);
    }
}

fn formatIds(alloc: Allocator, text: *std.ArrayList(u8), ids: []const u32) Allocator.Error!void {
    var buf: [16]u8 = undefined;
    for (ids) |id| try text.appendSlice(alloc, std.fmt.bufPrint(&buf, "{d}\n", .{id}) catch unreachable);
}

const L = std.unicode.utf8ToUtf16LeStringLiteral;

test "parse and format" {
    var shown: Shown = .{ .alloc = std.testing.allocator, .io = undefined, .path = null };
    defer shown.deinit();
    try shown.parse("daemon 4242\r\n\n# comment\n 7 \n9\n7\nx\n0\nhost ssh://devbox 31\n3\nhost ssh://alde@pi:2222\n5\n5\nhost ssh://devbox 31\n4\n");
    try std.testing.expectEqual(@as(u32, 4242), shown.local.pid);
    try std.testing.expectEqualSlices(u32, &.{ 7, 9 }, shown.local.ids.items);
    const w = shown.wanted(null);
    try std.testing.expectEqual(@as(u32, 4242), w.pid);
    try std.testing.expectEqualSlices(u32, &.{ 7, 9 }, w.ids);
    // A host's list, continued where the file names it again; one with
    // no pid; one not there.
    try std.testing.expectEqual(@as(usize, 2), shown.hosts.items.len);
    const devbox = shown.wanted(L("ssh://devbox"));
    try std.testing.expectEqual(@as(u32, 31), devbox.pid);
    try std.testing.expectEqualSlices(u32, &.{ 3, 4 }, devbox.ids);
    const pi = shown.wanted(L("ssh://alde@pi:2222"));
    try std.testing.expectEqual(@as(u32, 0), pi.pid);
    try std.testing.expectEqualSlices(u32, &.{5}, pi.ids);
    try std.testing.expectEqual(@as(u32, 0), shown.wanted(L("ssh://nowhere")).pid);
    try std.testing.expectEqual(@as(usize, 0), shown.wanted(L("ssh://nowhere")).ids.len);

    shown.set(null, 4243, &.{ 2, 3 });
    shown.set(L("ssh://devbox"), 32, &.{6});
    shown.set(L("ssh://build01"), 1, &.{});
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    try shown.format(&text);
    try std.testing.expectEqualStrings("daemon 4243\n2\n3\nhost ssh://devbox 32\n6\nhost ssh://alde@pi:2222 0\n5\nhost ssh://build01 1\n", text.items);
}

test "a file from before hosts had lists is the local daemon's" {
    var shown: Shown = .{ .alloc = std.testing.allocator, .io = undefined, .path = null };
    defer shown.deinit();
    try shown.parse("daemon 7\n1\n2\n");
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, shown.wanted(null).ids);
    try std.testing.expectEqual(@as(usize, 0), shown.hosts.items.len);
}
