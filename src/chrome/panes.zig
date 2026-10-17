//! The active tab's panes, over the terminal area. The renderer draws
//! each as a rounded box with a border and a shadow; over it go a title
//! strip at its top that holds its title and icons (faint until the mouse is over one) to split
//! it to the right or down and zoom it to fill the tab. Panes without
//! focus are dimmed.
//!
//! Dragging a pane by its title strip leaves it dimmed where it was, puts
//! a small picture of it by the mouse, and highlights where it would
//! land.

const std = @import("std");
const Chrome = @import("Chrome.zig");
const Painter = @import("../renderer/Painter.zig");

const Rect = Chrome.Rect;
const Hit = Chrome.Hit;
const Pane = Chrome.View.Pane;

// Sizes in DIPs.
/// Between panes, and around them (`Chrome.paneArea`), with room for
/// their shadows.
pub const gap = 10;
/// The title strip's height.
pub const title_height = 30;
const button_size = 20;
/// Between the last icon and the pane's right edge.
const margin = 3;
/// Before the title, and the focus dot before it.
const title_pad = 14;
/// A drop highlight's corners.
const drop_radius = 8;

/// The icons' opacity at rest, and while pressed.
const faint = 0.35;
const pressed = 0.7;

/// How much of a pane's background covers it while another has focus,
/// as Ghostty's `unfocused-split-opacity` of 0.7 leaves.
const dim = 0.3;
/// How much of the ground covers a pane being dragged.
const lifted = 0.6;
/// The picture of a dragged pane: its scale, at most this size.
const thumb_scale = 0.45;
const thumb_max_w = 280;
const thumb_max_h = 200;
const thumb_opacity = 0.94;

const Button = enum { split_right, split_down, zoom };

/// What's at a point in the terminal area: a pane's terminal, its title
/// strip, one of its buttons, or a divider between panes.
pub fn hitTest(c: *const Chrome, view: *const Chrome.View, x: f32, y: f32) Hit {
    for (view.panes, 0..) |pane, i| {
        if (!pane.frame.contains(x, y)) continue;
        for (buttons(c, pane)) |b| {
            if (buttonRect(c, pane, b).contains(x, y)) return hitFor(b, i);
        }
        if (titleRect(c, pane).contains(x, y)) return .{ .pane_title = i };
        return .{ .terminal = i };
    }
    for (view.dividers, 0..) |d, i| {
        if (d.contains(x, y)) return .{ .divider = i };
    }
    return .none;
}

/// Where a pane button is, if `hit` is one on screen.
pub fn rect(c: *const Chrome, view: *const Chrome.View, hit: Hit) ?Rect {
    const b: Button, const i = switch (hit) {
        .split_right => |i| .{ .split_right, i },
        .split_down => |i| .{ .split_down, i },
        .zoom => |i| .{ .zoom, i },
        else => return null,
    };
    if (i >= view.panes.len) return null;
    const pane = view.panes[i];
    if (std.mem.indexOfScalar(Button, buttons(c, pane), b) == null) return null;
    return buttonRect(c, pane, b);
}

pub fn paint(c: *const Chrome, p: *Painter, l: *const Chrome.Layout, view: *const Chrome.View) void {
    const several = view.panes.len > 1;
    for (view.panes, 0..) |pane, i| {
        paintTitle(c, p, pane, several);
        for (buttons(c, pane)) |b| {
            const hit = hitFor(b, i);
            const t = c.theme.text_strong;
            const alpha: f32 = switch (c.buttonState(hit)) {
                .rest => faint,
                .hover => 1,
                .pressed => pressed,
            };
            // Each spans 18 of its 24 units: 10 DIPs in this box, whose
            // odd size centers the split's middle line on a pixel.
            const size = c.px(13);
            c.drawIcon(p, switch (b) {
                .split_right => .columns_2,
                .split_down => .rows_2,
                .zoom => if (pane.zoomed) .minimize_2 else .maximize_2,
            }, buttonRect(c, pane, b).center(size, size), .{ t[0], t[1], t[2], alpha });
        }
        if (several and !pane.focused) p.fillRounded(pane.frame, l.corner, .{ pane.bg[0], pane.bg[1], pane.bg[2], dim });
    }
}

/// The part of the frame to capture for a dragged pane's picture: the
/// pane as `paint` drew it.
pub fn dragCapture(view: *const Chrome.View) ?Rect {
    const d = view.pane_drag orelse return null;
    const i = d.source orelse return null;
    if (d.mouse == null or i >= view.panes.len) return null;
    return view.panes[i].frame;
}

/// Over the captured frame: the dragged pane dimmed where it was, where
/// it would land, and `thumb`, its picture, by the mouse.
pub fn paintDrag(c: *const Chrome, p: *Painter, l: *const Chrome.Layout, view: *const Chrome.View, thumb: ?Painter.Image) void {
    const d = view.pane_drag orelse return;
    p.pushClip(l.terminal);
    if (d.source) |i| if (i < view.panes.len) {
        const frame = view.panes[i].frame;
        const g = c.theme.ground;
        p.fillRounded(frame, l.corner, .{ g[0], g[1], g[2], lifted });
        p.strokeRounded(frame, l.corner, c.stroke(), c.theme.outline);
    };
    if (d.drop) |drop| {
        const a = c.theme.accent;
        const radius = c.px(drop_radius);
        p.fillRounded(drop, radius, .{ a[0], a[1], a[2], 0.16 });
        p.strokeRounded(drop, radius, c.px(2), a);
    }
    p.popClip();

    const img = thumb orelse return;
    const at = d.mouse orelse return;
    const scale = @min(thumb_scale, @min(c.px(thumb_max_w) / img.w, c.px(thumb_max_h) / img.h));
    const w = @round(img.w * scale);
    const h = @round(img.h * scale);
    var r: Rect = .{ .x = @round(at.x + c.px(14)), .y = @round(at.y + c.px(14)), .w = w, .h = h };
    // Kept in the window.
    r.x = @min(r.x, @max(0, l.window.w - w));
    r.y = @min(r.y, @max(0, l.window.h - h));
    const radius = @round(l.corner * scale) + c.px(2);
    c.paintShadow(p, r, radius, 4, 1.5);
    p.image(img, r, radius, thumb_opacity);
    p.strokeRounded(r, radius, c.stroke(), c.theme.dialog_outline);
}

/// The title, after a focus dot while the tab has several panes, up to
/// the icons.
fn paintTitle(c: *const Chrome, p: *Painter, pane: Pane, several: bool) void {
    const strip = titleRect(c, pane);
    var x = strip.x + c.px(title_pad);
    if (several and pane.focused) {
        p.dot(x + c.px(3), strip.y + strip.h / 2, c.px(3), c.theme.accent);
        x += c.px(14);
    }
    const shown = buttons(c, pane);
    const right = if (shown.len > 0) buttonRect(c, pane, shown[0]).x - c.px(6) else strip.right() - c.px(title_pad);
    const r: Rect = .{ .x = x, .y = strip.y, .w = @max(0, right - x), .h = strip.h };
    if (pane.focused) {
        p.text(pane.title, c.fonts.body_strong, r, c.theme.text_strong);
    } else {
        p.text(pane.title, c.fonts.body, r, c.theme.text_muted);
    }
}

/// The strip at the top of a pane's frame.
fn titleRect(c: *const Chrome, pane: Pane) Rect {
    return .{ .x = pane.frame.x, .y = pane.frame.y, .w = pane.frame.w, .h = @min(pane.frame.h, c.px(title_height)) };
}

/// The buttons a pane has, left to right.
/// None in a pane too narrow to hold them with room for some title.
fn buttons(c: *const Chrome, pane: Pane) []const Button {
    if (!pane.splittable) return &.{};
    const all: []const Button = if (pane.zoomable) &.{ .split_right, .split_down, .zoom } else &.{ .split_right, .split_down };
    const n: f32 = @floatFromInt(all.len);
    if (pane.frame.w < (n + 2) * c.px(button_size) + c.px(margin)) return &.{};
    return all;
}

fn hitFor(b: Button, i: usize) Hit {
    return switch (b) {
        .split_right => .{ .split_right = i },
        .split_down => .{ .split_down = i },
        .zoom => .{ .zoom = i },
    };
}

/// Button `b` at the right of the pane's title strip, counted from the
/// right.
fn buttonRect(c: *const Chrome, pane: Pane, b: Button) Rect {
    const shown = buttons(c, pane);
    const index = std.mem.indexOfScalar(Button, shown, b) orelse 0;
    const from_right: f32 = @floatFromInt(shown.len - 1 - index);
    const size = c.px(button_size);
    const strip = titleRect(c, pane);
    return .{
        .x = strip.right() - c.px(margin) - size - from_right * size,
        .y = strip.y + @round((strip.h - size) / 2),
        .w = size,
        .h = size,
    };
}

test "pane buttons" {
    const c: Chrome = .{ .scale = 1, .fonts = undefined, .theme = undefined };
    const panes = [_]Pane{
        .{ .frame = .{ .w = 400, .h = 300 }, .rect = .{ .y = 30, .w = 400, .h = 270 }, .title = &.{}, .focused = true, .splittable = true, .zoomable = true, .zoomed = false, .bg = .{ 0, 0, 0, 1 } },
        .{ .frame = .{ .x = 401, .w = 400, .h = 300 }, .rect = .{ .x = 401, .y = 30, .w = 400, .h = 270 }, .title = &.{}, .focused = false, .splittable = true, .zoomable = true, .zoomed = false, .bg = .{ 0, 0, 0, 1 } },
    };
    const view: Chrome.View = .{
        .groups = &.{},
        .tabs = &.{},
        .active = 0,
        .panes = &panes,
        .dividers = &.{.{ .x = 400, .w = 1, .h = 300 }},
        .focused = true,
        .maximized = false,
        .terminal_bg = .{ 0, 0, 0, 1 },
    };
    try std.testing.expectEqual(Hit{ .terminal = 0 }, hitTest(&c, &view, 10, 100));
    try std.testing.expectEqual(Hit{ .pane_title = 0 }, hitTest(&c, &view, 10, 10));
    try std.testing.expectEqual(Hit{ .divider = 0 }, hitTest(&c, &view, 400.5, 10));
    try std.testing.expectEqual(Hit.none, hitTest(&c, &view, 400.5, 400));
    const zoom = rect(&c, &view, .{ .zoom = 1 }).?;
    try std.testing.expectEqual(@as(f32, 801 - margin), zoom.right());
    try std.testing.expect(zoom.bottom() <= title_height);
    try std.testing.expectEqual(Hit{ .zoom = 1 }, hitTest(&c, &view, zoom.x + 1, zoom.y + 1));
    const split = rect(&c, &view, .{ .split_right = 1 }).?;
    try std.testing.expectEqual(Hit{ .split_right = 1 }, hitTest(&c, &view, split.x + 1, split.y + 1));
    try std.testing.expect(split.right() <= zoom.x);

    // A pane too narrow for its icons has none; its strip is all title.
    var narrow = panes;
    narrow[1].frame.w = 80;
    var small = view;
    small.panes = &narrow;
    try std.testing.expect(rect(&c, &small, .{ .zoom = 1 }) == null);
    try std.testing.expectEqual(Hit{ .pane_title = 1 }, hitTest(&c, &small, 401 + 80 - 10, 10));
}
