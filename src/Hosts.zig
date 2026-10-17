//! SSH hosts the sidebar remembers across runs, connected or not: the
//! `hosts` file in the config directory, one `ssh://` URL per line, in
//! the order they're listed. Saved whenever the list changes.
const Hosts = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.hosts);

const L = std.unicode.utf8ToUtf16LeStringLiteral;

alloc: Allocator,
io: std.Io,
/// The file, or null with no config directory: then nothing is saved.
path: ?[]u8,
/// UTF-16, as the window uses them. Owned.
items: std.ArrayList([]u16) = .empty,

/// Read the list from `dir`. A missing or unreadable file is an empty
/// list.
pub fn load(alloc: Allocator, io: std.Io, dir: ?[]const u8) Allocator.Error!Hosts {
    var self: Hosts = .{
        .alloc = alloc,
        .io = io,
        .path = if (dir) |d| try std.fs.path.join(alloc, &.{ d, "hosts" }) else null,
    };
    errdefer self.deinit();
    const path = self.path orelse return self;
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 20)) catch |err| {
        if (err != error.FileNotFound) log.warn("reading {s}: {}", .{ path, err });
        return self;
    };
    defer alloc.free(text);
    try self.parse(text);
    return self;
}

pub fn deinit(self: *Hosts) void {
    for (self.items.items) |h| self.alloc.free(h);
    self.items.deinit(self.alloc);
    if (self.path) |p| self.alloc.free(p);
    self.* = undefined;
}

fn parse(self: *Hosts, text: []const u8) Allocator.Error!void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const dest = std.unicode.utf8ToUtf16LeAlloc(self.alloc, line) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        if (self.indexOf(dest) != null) {
            self.alloc.free(dest);
            continue;
        }
        self.items.append(self.alloc, dest) catch |err| {
            self.alloc.free(dest);
            return err;
        };
    }
}

/// `dest` without its `ssh://`, for showing.
pub fn label(dest: []const u16) []const u16 {
    const scheme = L("ssh://");
    return if (std.mem.startsWith(u16, dest, scheme)) dest[scheme.len..] else dest;
}

pub fn indexOf(self: *const Hosts, dest: []const u16) ?usize {
    for (self.items.items, 0..) |h, i| {
        if (std.mem.eql(u16, h, dest)) return i;
    }
    return null;
}

/// `dest`'s place in the list, adding it at the end if it's new.
pub fn add(self: *Hosts, dest: []const u16) Allocator.Error!usize {
    if (self.indexOf(dest)) |i| return i;
    const owned = try self.alloc.dupe(u16, dest);
    errdefer self.alloc.free(owned);
    try self.items.append(self.alloc, owned);
    self.save();
    return self.items.items.len - 1;
}

pub fn remove(self: *Hosts, i: usize) void {
    self.alloc.free(self.items.orderedRemove(i));
    self.save();
}

fn save(self: *const Hosts) void {
    const path = self.path orelse return;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(self.alloc);
    self.format(&text) catch return log.warn("saving {s}: out of memory", .{path});
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |dir| cwd.createDirPath(self.io, dir) catch {};
    cwd.writeFile(self.io, .{ .sub_path = path, .data = text.items }) catch |err|
        log.warn("saving {s}: {}", .{ path, err });
}

fn format(self: *const Hosts, text: *std.ArrayList(u8)) Allocator.Error!void {
    for (self.items.items) |h| {
        // One with an unpaired surrogate isn't kept.
        const line = std.unicode.utf16LeToUtf8Alloc(self.alloc, h) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer self.alloc.free(line);
        try text.appendSlice(self.alloc, line);
        try text.append(self.alloc, '\n');
    }
}

test label {
    try std.testing.expectEqualSlices(u16, L("alde@pi:2222"), label(L("ssh://alde@pi:2222")));
    try std.testing.expectEqualSlices(u16, L("devbox"), label(L("devbox")));
}

test "parse and format" {
    var hosts: Hosts = .{ .alloc = std.testing.allocator, .io = undefined, .path = null };
    defer hosts.deinit();
    try hosts.parse("ssh://devbox\r\n\n# comment\n  ssh://alde@pi:2222 \nssh://devbox\n");
    try std.testing.expectEqual(@as(usize, 2), hosts.items.items.len);
    try std.testing.expectEqual(@as(?usize, 1), hosts.indexOf(L("ssh://alde@pi:2222")));
    try std.testing.expectEqual(@as(usize, 2), try hosts.add(L("ssh://build01")));
    try std.testing.expectEqual(@as(usize, 0), try hosts.add(L("ssh://devbox")));
    hosts.remove(0);

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    try hosts.format(&text);
    try std.testing.expectEqualStrings("ssh://alde@pi:2222\nssh://build01\n", text.items);
}
