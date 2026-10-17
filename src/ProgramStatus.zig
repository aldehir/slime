//! What the programs in a terminal say they are doing, by the Program
//! Status Protocol (OSC 7501): each report sets one record, by its id
//! (none for the program itself), replacing it whole. `clear` removes a
//! record and those under it. A new shell prompt drops what was in
//! progress, since its program is gone; `done` and `error` stay until
//! the program replaces or clears them.
//!
//! The terminal parses and checks the reports (`program_status` effect);
//! this keeps the records and sums them up for the sidebar.
const ProgramStatus = @This();

const std = @import("std");
const ghostty_vt = @import("ghostty-vt");

const Report = ghostty_vt.osc.Command.ProgramStatus.Report;
const max_id_bytes = ghostty_vt.osc.program_status.max_id_bytes;

/// The specification's minimum. When it's full, the record updated
/// longest ago makes way.
pub const max_records = 64;

pub const State = enum {
    idle,
    working,
    done,
    /// Waiting on the user.
    blocked,
    /// The protocol's `error`.
    failed,
};

records: [max_records]Record = undefined,
len: usize = 0,
/// Counts updates, to find the record updated longest ago.
clock: u64 = 0,

const Record = struct {
    id_buf: [max_id_bytes]u8,
    id_len: usize,
    state: State,
    progress: ?u8,
    updated: u64,

    fn id(self: *const Record) []const u8 {
        return self.id_buf[0..self.id_len];
    }
};

/// What the sidebar shows for a terminal: its most pressing record.
pub const Summary = struct {
    state: State,
    /// From 0 to 100, for `working` and `blocked`; null if unknown.
    progress: ?u8 = null,
};

pub fn report(self: *ProgramStatus, r: Report) void {
    const id = r.readOption(.id) orelse "";
    const state: State = switch (r.state) {
        .clear => return self.clear(id),
        .idle => .idle,
        .working => .working,
        .done => .done,
        .blocked => .blocked,
        .@"error" => .failed,
    };
    self.set(id, state, r.readOption(.progress));
}

/// Put back a record kept elsewhere (by slimed while no window was
/// attached), as a report of it would set it.
pub fn restore(self: *ProgramStatus, id: []const u8, state: State, progress: ?u8) void {
    self.set(id, state, progress);
}

fn set(self: *ProgramStatus, id: []const u8, state: State, progress: ?u8) void {
    if (id.len > max_id_bytes) return;
    self.clock += 1;
    const rec = for (self.records[0..self.len]) |*rec| {
        if (std.mem.eql(u8, rec.id(), id)) break rec;
    } else if (self.len < max_records) rec: {
        self.len += 1;
        break :rec &self.records[self.len - 1];
    } else oldest: {
        var oldest = &self.records[0];
        for (self.records[1..self.len]) |*rec| {
            if (rec.updated < oldest.updated) oldest = rec;
        }
        break :oldest oldest;
    };
    @memcpy(rec.id_buf[0..id.len], id);
    rec.id_len = id.len;
    rec.state = state;
    rec.progress = progress;
    rec.updated = self.clock;
}

/// Remove the record `id` and those under it, or all with no id.
fn clear(self: *ProgramStatus, id: []const u8) void {
    if (id.len == 0) {
        self.len = 0;
        return;
    }
    self.removeIf(id, struct {
        fn under(prefix: []const u8, rec: *const Record) bool {
            const r = rec.id();
            return std.mem.startsWith(u8, r, prefix) and (r.len == prefix.len or r[prefix.len] == '/');
        }
    }.under);
}

/// A shell drew a new prompt: whatever ran before it has exited.
pub fn promptStarted(self: *ProgramStatus) void {
    self.removeIf({}, struct {
        fn gone(_: void, rec: *const Record) bool {
            return switch (rec.state) {
                .working, .blocked, .idle => true,
                .done, .failed => false,
            };
        }
    }.gone);
}

fn removeIf(self: *ProgramStatus, ctx: anytype, comptime pred: fn (@TypeOf(ctx), *const Record) bool) void {
    var kept: usize = 0;
    for (self.records[0..self.len]) |rec| {
        if (pred(ctx, &rec)) continue;
        self.records[kept] = rec;
        kept += 1;
    }
    self.len = kept;
}

/// The most pressing record: one waiting on the user, then a failure,
/// then work in progress, then work done, then a program at rest. Null
/// with no records.
pub fn summary(self: *const ProgramStatus) ?Summary {
    var best: ?*const Record = null;
    for (self.records[0..self.len]) |*rec| {
        if (best == null or rank(rec.state) > rank(best.?.state) or
            (rank(rec.state) == rank(best.?.state) and rec.updated > best.?.updated)) best = rec;
    }
    const rec = best orelse return null;
    return .{ .state = rec.state, .progress = rec.progress };
}

fn rank(state: State) u8 {
    return switch (state) {
        .idle => 0,
        .done => 1,
        .working => 2,
        .failed => 3,
        .blocked => 4,
    };
}

test ProgramStatus {
    var s: ProgramStatus = .{};
    try std.testing.expect(s.summary() == null);

    s.set("", .working, 40);
    try std.testing.expectEqual(Summary{ .state = .working, .progress = 40 }, s.summary().?);
    // A report replaces its record whole.
    s.set("", .working, null);
    try std.testing.expectEqual(Summary{ .state = .working }, s.summary().?);
    try std.testing.expectEqual(@as(usize, 1), s.len);

    // A child waiting on the user outranks its parent's work.
    s.set("deploy/eu", .blocked, null);
    s.set("deploy", .working, null);
    try std.testing.expectEqual(State.blocked, s.summary().?.state);
    // Clearing a record clears those under it, and nothing else.
    s.clear("deploy");
    try std.testing.expectEqual(@as(usize, 1), s.len);
    s.set("deployed", .done, null);
    s.clear("deploy");
    try std.testing.expectEqual(@as(usize, 2), s.len);

    // A new prompt drops work in progress; done stays.
    s.promptStarted();
    try std.testing.expectEqual(Summary{ .state = .done }, s.summary().?);
    s.clear("");
    try std.testing.expect(s.summary() == null);

    // When full, the record updated longest ago goes.
    var buf: [8]u8 = undefined;
    for (0..max_records + 1) |i| s.set(std.fmt.bufPrint(&buf, "r{d}", .{i}) catch unreachable, .idle, null);
    try std.testing.expectEqual(@as(usize, max_records), s.len);
    for (s.records[0..s.len]) |*rec| try std.testing.expect(!std.mem.eql(u8, rec.id(), "r0"));
}
