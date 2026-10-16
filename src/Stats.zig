//! Frame timing and output throughput, reported in the window title once
//! a second. Enabled with `-Dstats` (default in Debug builds).
const Stats = @This();

const std = @import("std");
const win32 = @import("win32/win32.zig");

pub const Phase = enum { update, build, draw };

frames: u32 = 0,
/// QueryPerformanceCounter ticks spent in each phase this interval.
ticks: std.EnumArray(Phase, i64) = .initFill(0),
/// Child output fed to the terminal. Added to by the reader thread.
bytes: std.atomic.Value(u64) = .init(0),
interval_start: i64 = 0,

pub fn init() Stats {
    return .{ .interval_start = now() };
}

pub fn now() i64 {
    var t: i64 = undefined;
    _ = win32.QueryPerformanceCounter(&t);
    return t;
}

/// Add the time since `start` to `phase` and return the current time,
/// so phases can be chained.
pub fn lap(self: *Stats, phase: Phase, start: i64) i64 {
    const t = now();
    self.ticks.getPtr(phase).* += t - start;
    return t;
}

/// Format the interval since the last call as a title suffix and reset.
pub fn report(self: *Stats, buf: []u8) []const u8 {
    var freq: i64 = undefined;
    _ = win32.QueryPerformanceFrequency(&freq);
    const t = now();
    const secs = @as(f64, @floatFromInt(t - self.interval_start)) / @as(f64, @floatFromInt(freq));
    const frames: f64 = @floatFromInt(@max(self.frames, 1));
    const ms_per_tick = 1000.0 / @as(f64, @floatFromInt(freq));

    var ms: std.EnumArray(Phase, f64) = undefined;
    for (std.enums.values(Phase)) |p| {
        ms.set(p, @as(f64, @floatFromInt(self.ticks.get(p))) * ms_per_tick / frames);
    }
    const bytes: f64 = @floatFromInt(self.bytes.swap(0, .monotonic));

    const text = std.fmt.bufPrint(
        buf,
        "{d:.0} fps \u{b7} update {d:.2} \u{b7} build {d:.2} \u{b7} draw {d:.2} ms \u{b7} {d:.1} MB/s",
        .{
            @as(f64, @floatFromInt(self.frames)) / secs,
            ms.get(.update),
            ms.get(.build),
            ms.get(.draw),
            bytes / secs / (1024 * 1024),
        },
    ) catch buf[0..0];

    self.frames = 0;
    self.ticks = .initFill(0);
    self.interval_start = t;
    return text;
}
