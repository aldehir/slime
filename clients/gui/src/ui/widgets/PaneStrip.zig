//! A `pane` in the terminal area. The renderer draws its terminal as a
//! rounded box with a border and a shadow; over it goes a title strip at
//! its top that holds its title and its buttons (faint until the mouse is
//! over one). A pane without focus is dimmed.
//!
//! Dragging a pane by its title strip (`Tree.drag`) leaves it dimmed
//! where it was, puts a small picture of it by the mouse, and highlights
//! where it would land.

const std = @import("std");
const Ui = @import("../Ui.zig");
const Painter = @import("../../renderer/Painter.zig");

const Node = Ui.Node;
const Rect = Ui.Rect;
const Id = Ui.Id;
const Tree = Ui.Tree;

// Sizes in DIPs.
/// Between panes, and around them (`Ui.paneArea`), with room for their
/// shadows.
pub const gap = 10;
/// The title strip's height.
pub const title_height = 30;
pub const button_size = 20;
/// Between the last icon and the pane's right edge.
const margin = 3;
/// Before the title, and the focus dot before it.
const title_pad = 14;
/// A drop highlight's corners.
const drop_radius = 8;

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

/// Whether a pane `frame_w` wide has room for `n` buttons and some title.
pub fn fits(ui: *const Ui, frame_w: f32, n: usize) bool {
    const count: f32 = @floatFromInt(n);
    return frame_w >= (count + 2) * ui.px(button_size) + ui.px(margin);
}

/// The strip at the top of the pane's frame.
fn titleRect(ui: *const Ui, node: *const Node) Rect {
    const f = node.rect;
    return .{ .x = f.x, .y = f.y, .w = f.w, .h = @min(f.h, ui.px(title_height)) };
}

/// The buttons at the right of the strip, each a button's width, the
/// last at the margin.
pub fn layout(ui: *const Ui, node: *Node) void {
    const buttons = node.kind.pane.buttons;
    const strip = titleRect(ui, node);
    const size = ui.px(button_size);
    for (buttons, 0..) |*b, i| {
        const from_right: f32 = @floatFromInt(buttons.len - 1 - i);
        b.rect = .{
            .x = strip.right() - ui.px(margin) - size - from_right * size,
            .y = strip.y + @round((strip.h - size) / 2),
            .w = size,
            .h = size,
        };
        ui.layoutNode(b);
    }
}

/// A button, else the title strip, else the terminal.
pub fn hitTest(ui: *const Ui, node: *const Node, x: f32, y: f32) ?Id {
    for (node.kind.pane.buttons) |*b| if (ui.hitNode(b, x, y)) |id| return id;
    if (titleRect(ui, node).contains(x, y)) return node.id.with(.title);
    return node.id;
}

pub fn paint(ui: *const Ui, p: *Painter, node: *const Node) void {
    const pane = node.kind.pane;
    const strip = titleRect(ui, node);
    // The title, after a focus dot while the tab has several panes, up
    // to the icons.
    var x = strip.x + ui.px(title_pad);
    if (pane.dot) {
        p.dot(x + ui.px(3), strip.y + strip.h / 2, ui.px(3), ui.theme.accent);
        x += ui.px(14);
    }
    const right = if (pane.buttons.len > 0) pane.buttons[0].rect.x - ui.px(6) else strip.right() - ui.px(title_pad);
    const r: Rect = .{ .x = x, .y = strip.y, .w = @max(0, right - x), .h = strip.h };
    if (pane.focused) {
        p.text(pane.title, ui.fonts.get(.body_strong), r, ui.theme.text_strong);
    } else {
        p.text(pane.title, ui.fonts.get(.body), r, ui.theme.text_muted);
    }
    ui.paintChildren(p, node);
    if (pane.dimmed) p.fillRounded(node.rect, ui.px(10), .{ pane.bg[0], pane.bg[1], pane.bg[2], dim });
}

/// The part of the frame to capture for a dragged pane's picture: the
/// pane as `paint` drew it.
pub fn dragCapture(tree: *const Tree) ?Rect {
    const d = tree.drag orelse return null;
    if (d.mouse == null) return null;
    return d.source;
}

/// Over the captured frame: the dragged pane dimmed where it was, where
/// it would land, and `thumb`, its picture, by the mouse.
pub fn paintDrag(ui: *const Ui, p: *Painter, tree: *const Tree, thumb: ?Painter.Image) void {
    const d = tree.drag orelse return;
    const f = &tree.frame;
    p.pushClip(f.terminal);
    if (d.source) |frame| {
        const g = ui.theme.ground;
        p.fillRounded(frame, f.corner, .{ g[0], g[1], g[2], lifted });
        p.strokeRounded(frame, f.corner, ui.stroke(), ui.theme.outline);
    }
    if (d.drop) |drop| {
        const a = ui.theme.accent;
        const radius = ui.px(drop_radius);
        p.fillRounded(drop, radius, .{ a[0], a[1], a[2], 0.16 });
        p.strokeRounded(drop, radius, ui.px(2), a);
    }
    p.popClip();

    const img = thumb orelse return;
    const at = d.mouse orelse return;
    const scale = @min(thumb_scale, @min(ui.px(thumb_max_w) / img.w, ui.px(thumb_max_h) / img.h));
    const w = @round(img.w * scale);
    const h = @round(img.h * scale);
    var r: Rect = .{ .x = @round(at.x + ui.px(14)), .y = @round(at.y + ui.px(14)), .w = w, .h = h };
    // Kept in the window.
    r.x = @min(r.x, @max(0, f.window.w - w));
    r.y = @min(r.y, @max(0, f.window.h - h));
    const radius = @round(f.corner * scale) + ui.px(2);
    ui.paintShadow(p, r, radius, 4, 1.5);
    p.image(img, r, radius, thumb_opacity);
    p.strokeRounded(r, radius, ui.stroke(), ui.theme.dialog_outline);
}

/// A pane with split and zoom buttons, for the tests.
fn testPane(id: Id, frame: Rect, buttons: []Node) Node {
    return .{ .id = id.with(.terminal), .kind = .{ .pane = .{ .title = &.{}, .focused = true, .bg = undefined, .buttons = buttons } }, .rect = frame };
}

fn testButton(id: Id, part: Id.Part) Node {
    return .{ .id = id.with(part), .kind = .{ .icon_button = .{ .icon = .columns_2, .size = 13, .style = .faint } } };
}

test "pane buttons" {
    const ui: Ui = .{ .scale = 1, .fonts = .none, .theme = undefined };
    const first: Id = .{ .target = .{ .pane = 5 } };
    const second: Id = .{ .target = .{ .pane = 8 } };
    var second_buttons = [_]Node{ testButton(second, .split_right), testButton(second, .split_down), testButton(second, .zoom) };
    var panes = [_]Node{
        testPane(first, .{ .w = 400, .h = 300 }, &.{}),
        testPane(second, .{ .x = 401, .w = 400, .h = 300 }, &second_buttons),
        .{ .id = .{ .target = .{ .divider = 0 } }, .kind = .hit_area, .rect = .{ .x = 400, .w = 1, .h = 300 } },
    };
    var node: Node = .{ .kind = .{ .canvas = &panes }, .rect = .{ .w = 801, .h = 600 } };
    ui.layoutNode(&node);
    try std.testing.expectEqual(first.with(.terminal), ui.hitNode(&node, 10, 100).?);
    try std.testing.expectEqual(first.with(.title), ui.hitNode(&node, 10, 10).?);
    try std.testing.expectEqual(Id{ .target = .{ .divider = 0 } }, ui.hitNode(&node, 400.5, 10).?);
    try std.testing.expect(ui.hitNode(&node, 400.5, 400) == null);
    const zoom = second_buttons[2].rect;
    try std.testing.expectEqual(@as(f32, 801 - margin), zoom.right());
    try std.testing.expect(zoom.bottom() <= title_height);
    try std.testing.expectEqual(second.with(.zoom), ui.hitNode(&node, zoom.x + 1, zoom.y + 1).?);
    const split = second_buttons[0].rect;
    try std.testing.expectEqual(second.with(.split_right), ui.hitNode(&node, split.x + 1, split.y + 1).?);
    try std.testing.expect(split.right() <= zoom.x);
    // Three buttons need room for some title beside them.
    try std.testing.expect(fits(&ui, 400, 3));
    try std.testing.expect(!fits(&ui, 80, 3));
}
