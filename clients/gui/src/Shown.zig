//! The workspaces a window showed, remembered for the next one: the
//! `workspaces` file in the config directory, the daemon's pid on the
//! first line and a workspace id on each after. Ids start over with each
//! daemon, so the list only counts for the daemon it was written under
//! (`Daemon.Wanted`). Saved whenever the window shows a different set.
const Shown = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Daemon = @import("Daemon.zig");

const log = std.log.scoped(.shown);

alloc: Allocator,
io: std.Io,
/// The file, or null with no config directory: then nothing is saved.
path: ?[]u8,
pid: u32 = 0,
ids: std.ArrayList(u32) = .empty,

/// Read the list from `dir`. A missing or unreadable file is an empty
/// list.
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
    self.ids.deinit(self.alloc);
    if (self.path) |p| self.alloc.free(p);
    self.* = undefined;
}

fn parse(self: *Shown, text: []const u8) Allocator.Error!void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "daemon ")) {
            self.pid = std.fmt.parseUnsigned(u32, std.mem.trim(u8, line["daemon ".len..], " \t"), 10) catch 0;
            continue;
        }
        const id = std.fmt.parseUnsigned(u32, line, 10) catch continue;
        if (id != 0 and std.mem.indexOfScalar(u32, self.ids.items, id) == null) try self.ids.append(self.alloc, id);
    }
}

/// What to attach at connect.
pub fn wanted(self: *const Shown) Daemon.Wanted {
    return .{ .pid = self.pid, .ids = self.ids.items };
}

/// Remember `ids` as shown under the daemon with `pid`, if that's a
/// change.
pub fn set(self: *Shown, pid: u32, ids: []const u32) void {
    if (self.pid == pid and std.mem.eql(u32, self.ids.items, ids)) return;
    self.ids.clearRetainingCapacity();
    self.ids.appendSlice(self.alloc, ids) catch return;
    self.pid = pid;
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
    try text.appendSlice(self.alloc, std.fmt.bufPrint(&buf, "daemon {d}\n", .{self.pid}) catch unreachable);
    for (self.ids.items) |id| try text.appendSlice(self.alloc, std.fmt.bufPrint(&buf, "{d}\n", .{id}) catch unreachable);
}

test "parse and format" {
    var shown: Shown = .{ .alloc = std.testing.allocator, .io = undefined, .path = null };
    defer shown.deinit();
    try shown.parse("daemon 4242\r\n\n# comment\n 7 \n9\n7\nx\n0\n");
    try std.testing.expectEqual(@as(u32, 4242), shown.pid);
    try std.testing.expectEqualSlices(u32, &.{ 7, 9 }, shown.ids.items);
    const w = shown.wanted();
    try std.testing.expectEqual(@as(u32, 4242), w.pid);
    try std.testing.expectEqualSlices(u32, &.{ 7, 9 }, w.ids);

    shown.set(4243, &.{ 2, 3 });
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    try shown.format(&text);
    try std.testing.expectEqualStrings("daemon 4243\n2\n3\n", text.items);
}
