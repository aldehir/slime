//! A `pane` in the terminal area. The renderer draws its terminal as a
//! rounded box with a border and a shadow; over it goes a title strip at
//! its top that holds its title and its buttons (faint until the mouse is
//! over one). A pane without focus is dimmed. A browser pane's strip
//! holds its history buttons and URL bar in place of the title, the
//! site's icon (or a globe) at the bar's left, and until a browser draws
//! its page, the page's title and url stand in for it under the strip.
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
const BrowserPane = @import("../Tree.zig").BrowserPane;

// Sizes in DIPs.
/// Between panes, and around them (`Ui.paneArea`), with room for their
/// shadows.
pub const gap = 10;
/// The title strip's height.
pub const title_height = 30;
pub const button_size = 20;
/// A browser's history buttons, packed closer to leave its URL bar room.
const nav_size = 18;
/// Between the URL bar and the buttons either side of it, and its text
/// and its edges.
const url_gap = 3;
const url_pad = 7;
/// The URL bar's width: this much of the strip, between `url_min` and
/// `url_max`, so the strip either side of it is left to drag the pane by.
const url_share = 0.5;
const url_max = 640;
/// The least the URL bar keeps beside the history buttons: narrower, they
/// go, and it takes their room.
const url_min = 140;
/// The site's icon in the URL bar, and between it and the url.
const site_icon = 16;
const site_gap = 6;
/// Between the last icon and the pane's right edge.
const margin = 3;
/// Before the title, and the focus dot before it.
const title_pad = 14;
/// A drop highlight's corners.
const drop_radius = 8;

/// How much of a pane's background covers it while another has focus,
/// as Ghostty's `unfocused-split-opacity` of 0.7 leaves.
pub const dim = 0.3;
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
/// last at the margin; a browser's history buttons at its left, after
/// the focus dot, unless they'd leave its URL bar too narrow (`url_min`):
/// then they're dropped from the node.
pub fn layout(ui: *const Ui, node: *Node) void {
    place(ui, node);
    const pane = &node.kind.pane;
    if (pane.nav == 0 or urlRect(ui, node).w >= ui.px(url_min)) return;
    pane.buttons = pane.buttons[pane.nav..];
    pane.nav = 0;
}

fn place(ui: *const Ui, node: *Node) void {
    const pane = node.kind.pane;
    const nav = pane.buttons[0..pane.nav];
    const buttons = pane.buttons[pane.nav..];
    const strip = titleRect(ui, node);
    const size = ui.px(button_size);
    const y = strip.y + @round((strip.h - size) / 2);
    for (buttons, 0..) |*b, i| {
        const from_right: f32 = @floatFromInt(buttons.len - 1 - i);
        b.rect = .{ .x = strip.right() - ui.px(margin) - size - from_right * size, .y = y, .w = size, .h = size };
        ui.layoutNode(b);
    }
    const left = if (pane.dot) strip.x + ui.px(title_pad + 8) else strip.x + ui.px(margin + 3);
    const nav_w = ui.px(nav_size);
    for (nav, 0..) |*b, i| {
        const from_left: f32 = @floatFromInt(i);
        b.rect = .{ .x = left + from_left * nav_w, .y = y, .w = nav_w, .h = size };
        ui.layoutNode(b);
    }
}

/// A browser pane's URL bar: `url_share` of the strip, centered on the
/// pane, whatever its text; kept between its history buttons (or the
/// focus dot) and the buttons at the right, which take precedence over
/// its width and then its place.
fn urlRect(ui: *const Ui, node: *const Node) Rect {
    const pane = node.kind.pane;
    const strip = titleRect(ui, node);
    const left = if (pane.nav > 0)
        pane.buttons[pane.nav - 1].rect.right() + ui.px(url_gap)
    else if (pane.dot) strip.x + ui.px(title_pad + 10) else strip.x + ui.px(margin + 3);
    const right = if (pane.buttons.len > pane.nav) pane.buttons[pane.nav].rect.x - ui.px(url_gap) else strip.right() - ui.px(margin + 3);
    const room = @max(0, right - left);
    const want = @round(std.math.clamp(strip.w * url_share, ui.px(url_min), ui.px(url_max)));
    const w = @min(want, room);
    const x = std.math.clamp(@round(strip.x + (strip.w - w) / 2), left, @max(left, right - w));
    const inset = ui.px(4);
    return .{ .x = x, .y = strip.y + inset, .w = w, .h = @max(0, strip.h - 2 * inset) };
}

/// A button, else a browser's URL bar, else the title strip, else the
/// terminal.
pub fn hitTest(ui: *const Ui, node: *const Node, x: f32, y: f32) ?Id {
    for (node.kind.pane.buttons) |*b| if (ui.hitNode(b, x, y)) |id| return id;
    if (node.kind.pane.browser != null and urlRect(ui, node).contains(x, y)) return node.id.with(.field);
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
    if (pane.browser) |b| {
        paintUrl(ui, p, urlRect(ui, node), b, pane.focused);
        if (!b.live) paintPage(ui, p, b);
    } else {
        const right = if (pane.buttons.len > 0) pane.buttons[0].rect.x - ui.px(6) else strip.right() - ui.px(title_pad);
        const r: Rect = .{ .x = x, .y = strip.y, .w = @max(0, right - x), .h = strip.h };
        if (pane.focused) {
            p.text(pane.title, ui.fonts.get(.body_strong), r, ui.theme.text_strong);
        } else {
            p.text(pane.title, ui.fonts.get(.body), r, ui.theme.text_muted);
        }
    }
    ui.paintChildren(p, node);
    if (pane.dimmed) p.fillRounded(node.rect, ui.px(10), .{ pane.bg[0], pane.bg[1], pane.bg[2], dim });
}

/// The URL bar: the field being edited, with its caret and selection,
/// or the url on a quieter box.
fn paintUrl(ui: *const Ui, p: *Painter, r: Rect, b: BrowserPane, focused: bool) void {
    if (r.w < 1 or r.h < 1) return;
    const radius = ui.px(6);
    var inner = r.inset(ui.px(url_pad), 0);
    if (b.field != null) {
        ui.fillBordered(p, r, radius, ui.theme.surface, ui.theme.accent);
    } else {
        p.fillRounded(r, radius, ui.theme.field);
    }
    // The site's icon, where the bar has room for it and some url.
    const size = ui.px(site_icon);
    if (inner.w >= 4 * size) {
        const icon: Rect = .{ .x = inner.x, .y = r.y + @round((r.h - size) / 2), .w = size, .h = size };
        if (b.favicon) |img| {
            p.image(img, icon, 0, 1);
        } else {
            ui.drawIcon(p, .globe, icon.inset(ui.px(1), ui.px(1)), if (focused) ui.theme.text_muted else ui.theme.text_inactive);
        }
        const skip = size + ui.px(site_gap);
        inner = .{ .x = inner.x + skip, .y = inner.y, .w = inner.w - skip, .h = inner.h };
    }
    if (b.field) |field| {
        ui.paintEditText(p, inner, field, .{ .caret = b.caret });
        return;
    }
    p.pushClip(inner);
    defer p.popClip();
    p.text(shownUrl(b.url), ui.fonts.get(.body), inner, if (focused) ui.theme.text else ui.theme.text_muted);
}

/// A url as the bar shows it at rest: without `https://`, as browsers
/// do, so a narrow bar starts with the host.
fn shownUrl(url: []const u16) []const u16 {
    const https = std.unicode.utf8ToUtf16LeStringLiteral("https://");
    return if (std.mem.startsWith(u16, url, https) and url.len > https.len) url[https.len..] else url;
}

/// What stands in for the page until a browser draws it: its title, its
/// url under it, and why the pane ended, centered in the page's place.
fn paintPage(ui: *const Ui, p: *Painter, b: BrowserPane) void {
    const page = b.page;
    if (page.w < 1 or page.h < 1) return;
    const lines = [_]struct { text: []const u16, color: Painter.Color }{
        .{ .text = b.page_title, .color = ui.theme.text_muted },
        .{ .text = b.url, .color = ui.theme.text_inactive },
        .{ .text = b.ended, .color = ui.theme.text_inactive },
    };
    const n: f32 = if (b.ended.len > 0) 3 else 2;
    const line_h = ui.px(22);
    const pad = ui.px(title_pad);
    var r: Rect = .{ .x = page.x + pad, .y = page.y + @round((page.h - n * line_h) / 2), .w = @max(0, page.w - 2 * pad), .h = line_h };
    p.pushClip(page);
    defer p.popClip();
    for (lines) |line| {
        if (line.text.len == 0) continue;
        p.text(line.text, ui.fonts.get(.title), r, line.color);
        r.y += line_h;
    }
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
    ui.paintShadow(p, r, radius);
    p.image(img, r, radius, thumb_opacity);
    // The page over its box, which the copy of the frame has empty.
    if (d.page) |page| if (d.source) |src| {
        const k = r.w / src.w;
        const at_page: Rect = .{
            .x = r.x + (page.rect.x - src.x) * k,
            .y = r.y + (page.rect.y - src.y) * k,
            .w = page.rect.w * k,
            .h = page.rect.h * k,
        };
        p.imageIn(page.image, at_page, r, radius, thumb_opacity);
    };
    p.strokeRounded(r, radius, ui.stroke(), ui.theme.pane_border);
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

test "a browser pane's strip: history buttons, then its URL bar" {
    const ui: Ui = .{ .scale = 1, .fonts = .none, .theme = undefined };
    const id: Id = .{ .target = .{ .pane = 5 } };
    var buttons = [_]Node{ testButton(id, .back), testButton(id, .forward), testButton(id, .reload), testButton(id, .split_right), testButton(id, .split_down) };
    var node: Node = .{ .id = id.with(.terminal), .kind = .{ .pane = .{
        .title = &.{},
        .focused = true,
        .bg = undefined,
        .buttons = &buttons,
        .nav = 3,
        .browser = .{ .url = &.{}, .page = .{ .y = title_height, .w = 400, .h = 270 }, .page_title = &.{} },
    } }, .rect = .{ .w = 400, .h = 300 } };
    ui.layoutNode(&node);
    try std.testing.expectEqual(@as(f32, margin + 3), buttons[0].rect.x);
    try std.testing.expectEqual(buttons[0].rect.right(), buttons[1].rect.x);
    try std.testing.expectEqual(@as(f32, 400 - margin), buttons[4].rect.right());
    const bar = urlRect(&ui, &node);
    // Half the strip, centered on it, whatever the url; the rest of the
    // strip drags the pane.
    try std.testing.expectEqual(@as(f32, 200), bar.w);
    try std.testing.expectEqual(@as(f32, 100), bar.x);
    try std.testing.expectEqual(id.with(.title), ui.hitNode(&node, 80, bar.y + 5).?);
    try std.testing.expectEqual(id.with(.title), ui.hitNode(&node, 320, bar.y + 5).?);
    try std.testing.expectEqual(id.with(.field), ui.hitNode(&node, bar.x + 5, bar.y + 5).?);
    try std.testing.expectEqual(id.with(.back), ui.hitNode(&node, buttons[0].rect.x + 1, buttons[0].rect.y + 1).?);
    try std.testing.expectEqual(id.with(.split_down), ui.hitNode(&node, buttons[4].rect.x + 1, buttons[4].rect.y + 1).?);
    // Its page is the pane's, as a terminal is.
    try std.testing.expectEqual(id.with(.terminal), ui.hitNode(&node, 200, 200).?);

    // At 175%, focused among two panes: half of a 1300 px window leaves
    // the bar too little beside the history buttons, which go, and the
    // bar moves off center to fit; a wider pane keeps them and the bar
    // centered.
    const big: Ui = .{ .scale = 1.75, .fonts = .none, .theme = undefined };
    var zoom_buttons = [_]Node{ testButton(id, .back), testButton(id, .forward), testButton(id, .reload), testButton(id, .split_right), testButton(id, .split_down), testButton(id, .zoom) };
    for ([_]f32{ 376, 700 }) |w| {
        node.rect = .{ .w = w, .h = 820 };
        node.kind.pane.dot = true;
        node.kind.pane.buttons = &zoom_buttons;
        node.kind.pane.nav = 3;
        big.layoutNode(&node);
        const pane = node.kind.pane;
        const wide = urlRect(&big, &node);
        if (w == 376) {
            try std.testing.expectEqual(@as(usize, 0), pane.nav);
            try std.testing.expectEqual(@as(usize, 3), pane.buttons.len);
            try std.testing.expect(big.hitNode(&node, 50, 10).?.part != .back);
            // All the room there is, short of the minimum.
            try std.testing.expect(wide.w >= 200 and wide.w < big.px(url_min));
            try std.testing.expectEqual(big.px(title_pad + 10), wide.x);
            try std.testing.expectEqual(pane.buttons[pane.nav].rect.x - big.px(url_gap), wide.right());
        } else {
            try std.testing.expectEqual(@as(usize, 3), pane.nav);
            try std.testing.expectEqual(id.with(.back), big.hitNode(&node, pane.buttons[0].rect.x + 1, pane.buttons[0].rect.y + 1).?);
            try std.testing.expectEqual(@as(f32, 350), wide.w);
            try std.testing.expectEqual(@as(f32, 175), wide.x);
            try std.testing.expect(wide.x >= pane.buttons[2].rect.right() + big.px(url_gap));
            try std.testing.expect(wide.right() <= pane.buttons[3].rect.x - big.px(url_gap));
        }
    }
}
