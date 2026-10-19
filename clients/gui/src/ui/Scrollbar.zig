//! An overlay scrollbar for a list that shows `visible` of `total`
//! rows from `start`: a thin thumb along the list's right edge, which
//! widens over a faint track while the mouse is near the edge or on
//! it, and darkens while dragged. It takes no room from the rows. The
//! owner lays it out from its list's rect, hit tests the strip along
//! the edge (`strip`), and turns a drag into a start row (`startAt`).
const Scrollbar = @This();

const std = @import("std");
const Ui = @import("Ui.zig");
const Painter = @import("../renderer/Painter.zig");

const Rect = Ui.Rect;
const withAlpha = @import("theme.zig").withAlpha;

// Sizes in DIPs.
/// The thumb at rest, and under the mouse.
pub const thin = 3;
pub const wide = 6;
/// From the list's right edge, at rest and under the mouse.
const inset_thin = 3;
const inset_wide = 2;
/// The track keeps this much from the list's top and bottom.
const end_pad = 2;
const min_thumb = 24;
/// How far from the edge the mouse widens the bar, and takes hold of
/// it: the hit strip.
pub const strip_width = 16;

pub const Metrics = struct {
    total: usize,
    visible: usize,
    start: usize,

    /// How far the list can scroll: the first row of the last page.
    pub fn most(self: Metrics) usize {
        return self.total -| self.visible;
    }
};

pub const State = enum { rest, hover, drag };

pub const Layout = struct {
    track: Rect,
    thumb: Rect,
};

/// Whether a list of `m` needs a bar at all.
pub fn needed(m: Metrics) bool {
    return m.total > m.visible and m.visible > 0;
}

/// The track and thumb along `list`'s right edge, wide or thin, for a
/// list of `m`. Null while every row fits.
pub fn layout(ui: *const Ui, list: Rect, m: Metrics, state: State) ?Layout {
    if (!needed(m)) return null;
    const w = ui.px(if (state == .rest) thin else wide);
    const inset = ui.px(if (state == .rest) inset_thin else inset_wide);
    const track: Rect = .{ .x = list.right() - inset - w, .y = list.y + ui.px(end_pad), .w = w, .h = @max(0, list.h - 2 * ui.px(end_pad)) };
    const share = @as(f32, @floatFromInt(m.visible)) / @as(f32, @floatFromInt(m.total));
    const h = @min(track.h, @max(ui.px(min_thumb), @round(track.h * share)));
    const room = track.h - h;
    const at = @as(f32, @floatFromInt(@min(m.start, m.most()))) / @as(f32, @floatFromInt(@max(m.most(), 1)));
    return .{ .track = track, .thumb = .{ .x = track.x, .y = track.y + @round(room * at), .w = w, .h = h } };
}

/// The strip along `list`'s right edge the mouse widens the bar in.
pub fn strip(ui: *const Ui, list: Rect) Rect {
    const w = @min(list.w, ui.px(strip_width));
    return .{ .x = list.right() - w, .y = list.y, .w = w, .h = list.h };
}

/// The start row for the thumb's top at `y` in `l`'s track: the drag's
/// mouse less where in the thumb it took hold.
pub fn startAt(l: Layout, m: Metrics, y: f32) usize {
    const room = l.track.h - l.thumb.h;
    if (room <= 0) return 0;
    const share = std.math.clamp((y - l.track.y) / room, 0, 1);
    return @intFromFloat(@round(share * @as(f32, @floatFromInt(m.most()))));
}

pub fn paint(ui: *const Ui, p: *Painter, l: Layout, state: State) void {
    const t = &ui.theme;
    if (state != .rest) p.fillRounded(l.track, l.track.w / 2, withAlpha(t.text, 0.06));
    const alpha: f32 = switch (state) {
        .rest => 0.3,
        .hover => 0.5,
        .drag => 0.65,
    };
    p.fillRounded(l.thumb, l.thumb.w / 2, withAlpha(t.text, alpha));
}

test "the thumb is the visible share of the track, placed by the start, never under its least" {
    const ui: Ui = .{ .scale = 1, .fonts = .none, .theme = undefined };
    const list: Rect = .{ .x = 100, .y = 50, .w = 300, .h = 204 };
    try std.testing.expect(layout(&ui, list, .{ .total = 5, .visible = 8, .start = 0 }, .rest) == null);
    const top = layout(&ui, list, .{ .total = 20, .visible = 8, .start = 0 }, .rest).?;
    // 200 of track, 8 of 20 rows: an 80 thumb at the top, 3 wide at inset 3.
    try std.testing.expectEqual(Rect{ .x = 394, .y = 52, .w = 3, .h = 200 }, top.track);
    try std.testing.expectEqual(Rect{ .x = 394, .y = 52, .w = 3, .h = 80 }, top.thumb);
    const end = layout(&ui, list, .{ .total = 20, .visible = 8, .start = 12 }, .hover).?;
    try std.testing.expectEqual(@as(f32, 6), end.thumb.w);
    try std.testing.expectEqual(@as(f32, 392), end.thumb.x);
    try std.testing.expectEqual(end.track.bottom(), end.thumb.bottom());
    // A long list's thumb stays grabbable.
    const long = layout(&ui, list, .{ .total = 1000, .visible = 8, .start = 0 }, .rest).?;
    try std.testing.expectEqual(@as(f32, min_thumb), long.thumb.h);
    // Dragging maps the thumb's top back to a start row.
    const m: Metrics = .{ .total = 20, .visible = 8, .start = 0 };
    try std.testing.expectEqual(@as(usize, 0), startAt(top, m, 52));
    try std.testing.expectEqual(@as(usize, 12), startAt(top, m, 52 + 120));
    try std.testing.expectEqual(@as(usize, 6), startAt(top, m, 52 + 60));
    try std.testing.expectEqual(@as(usize, 12), startAt(top, m, 1000));
    try std.testing.expectEqual(Rect{ .x = 384, .y = 50, .w = 16, .h = 204 }, strip(&ui, list));
}
