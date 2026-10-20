//! A `pane` in the terminal area. The renderer draws its terminal as a
//! rounded box with a border and a shadow; over it goes a title strip at
//! its top that holds its title and its buttons (faint until the mouse is
//! over one). A pane without focus is dimmed. A browser pane's strip
//! holds its page's title; under it goes an address row with its
//! history buttons and URL bar, the site's icon (or a globe) at the
//! bar's left, and until a browser draws its page, the page's title and
//! url stand in for it under the row.
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
/// A browser's address row, under its title strip.
pub const bar_height = 38;
/// Between the row's edges and what's in it, and above and below the
/// URL bar in it.
const bar_pad = 6;
const url_inset = 5;
/// Between the URL bar and the history buttons, and its text and its
/// edges.
const url_gap = 3;
const url_pad = 8;
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
/// The search card under the strip's right end (`Tree.Pane.search`):
/// its size, the pill's height, below what width it loses its icon and
/// buttons, and below what width it isn't drawn at all.
const search_width = 300;
const search_height = 32;
const pill_height = 24;
const search_narrow = 240;
const search_min = 120;
const pill_min = 80;
const search_top = 6;
const search_side = 12;
const search_pad = 10;
const search_button = 24;
const search_icon = 14;
const search_count = 60;
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

/// A browser's address row, under the strip.
fn barRect(ui: *const Ui, node: *const Node) Rect {
    const f = node.rect;
    const top = @min(f.h, ui.px(title_height));
    return .{ .x = f.x, .y = f.y + top, .w = f.w, .h = @min(f.h - top, ui.px(bar_height)) };
}

/// The buttons at the right of the strip, each a button's width, the
/// last at the margin; a browser's history buttons at the left of its
/// address row, unless they'd leave its URL bar too narrow (`url_min`):
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
    const bar = barRect(ui, node);
    const left = bar.x + ui.px(bar_pad);
    const bar_y = bar.y + @round((bar.h - size) / 2);
    for (nav, 0..) |*b, i| {
        const from_left: f32 = @floatFromInt(i);
        b.rect = .{ .x = left + from_left * size, .y = bar_y, .w = size, .h = size };
        ui.layoutNode(b);
    }
}

/// A browser pane's URL bar: the rest of its address row after its
/// history buttons, to the pad at the row's right.
fn urlRect(ui: *const Ui, node: *const Node) Rect {
    const pane = node.kind.pane;
    const bar = barRect(ui, node);
    const left = if (pane.nav > 0) pane.buttons[pane.nav - 1].rect.right() + ui.px(url_gap) else bar.x + ui.px(bar_pad);
    const right = bar.right() - ui.px(bar_pad);
    const inset = ui.px(url_inset);
    return .{ .x = left, .y = bar.y + inset, .w = @max(0, right - left), .h = @max(0, bar.h - 2 * inset) };
}

/// Where the search card's parts go: the box under the strip's right
/// end, the field (or the pill's text) in it, the count after it, and
/// the previous, next, and close buttons when the pane has room for
/// them. Null when there's no search, or no room for the box.
const SearchRects = struct {
    box: Rect,
    icon: ?Rect,
    field: Rect,
    count: Rect,
    prev: ?Rect,
    next: ?Rect,
    close: ?Rect,
};

fn searchRects(ui: *const Ui, node: *const Node) ?SearchRects {
    const sv = node.kind.pane.search orelse return null;
    const f = node.rect;
    const strip = titleRect(ui, node);
    const side = ui.px(search_side);
    const pill = sv.field == null;
    const room = f.w - 2 * side;
    var w = @min(ui.px(search_width), room);
    if (pill) w = @min(w, ui.px(if (sv.needle.len > 0) 190 else 110));
    if (w < ui.px(if (pill) pill_min else search_min)) return null;
    const h = ui.px(if (pill) pill_height else search_height);
    const box: Rect = .{ .x = f.right() - side - w, .y = strip.bottom() + ui.px(search_top), .w = w, .h = h };
    const pad = ui.px(search_pad);
    const button = ui.px(search_button);
    const wide = !pill and w >= ui.px(search_narrow);
    var right = box.right() - (if (wide or pill) ui.px(6) else pad);
    var close: ?Rect = null;
    var next: ?Rect = null;
    var prev: ?Rect = null;
    const by = box.y + @round((h - button) / 2);
    if (wide) {
        close = .{ .x = right - button, .y = by, .w = button, .h = button };
        next = .{ .x = right - 2 * button, .y = by, .w = button, .h = button };
        prev = .{ .x = right - 3 * button, .y = by, .w = button, .h = button };
        right -= 3 * button + ui.px(4);
    } else if (pill) {
        // The pill ends the search too.
        close = .{ .x = right - button, .y = by, .w = button, .h = button };
        right -= button + ui.px(2);
    }
    const count_w = ui.px(search_count);
    const count: Rect = .{ .x = right - count_w, .y = box.y, .w = count_w, .h = h };
    var left = box.x + pad;
    var icon: ?Rect = null;
    if (wide) {
        const size = ui.px(search_icon);
        icon = .{ .x = left, .y = box.y + @round((h - size) / 2), .w = size, .h = size };
        left += size + ui.px(8);
    }
    const field: Rect = .{ .x = left, .y = box.y, .w = @max(0, count.x - ui.px(6) - left), .h = h };
    return .{ .box = box, .icon = icon, .field = field, .count = count, .prev = prev, .next = next, .close = close };
}

/// The search card or pill, over the terminal.
fn paintSearch(ui: *const Ui, p: *Painter, node: *const Node) void {
    const sv = node.kind.pane.search orelse return;
    const r = searchRects(ui, node) orelse return;
    const t = &ui.theme;
    const pill = sv.field == null;
    const radius = ui.px(if (pill) 12 else 8);
    const border = if (sv.none) t.danger else if (pill) t.outline else t.accent;
    // A raised box, as a dialog's: the strip's translucent field tint
    // would show the border color through.
    p.fillRounded(r.box.inset(-ui.px(2), -ui.px(2)), radius + ui.px(2), t.pane_shadow);
    ui.fillBordered(p, r.box, radius, t.dialog, border);
    if (r.icon) |box| ui.drawIcon(p, .search, box, t.text_muted);

    // The field, or the pill's needle.
    const field = r.field;
    if (sv.field) |f| {
        ui.paintEditText(p, field, f, .{ .caret = sv.caret });
    } else if (sv.needle.len > 0) {
        p.pushClip(field);
        defer p.popClip();
        p.text(sv.needle, ui.fonts.get(.mono), field, t.text);
    }

    // The count: current over total, a plus while the total grows.
    var buf: [40]u16 = undefined;
    var text: []const u16 = &.{};
    if (sv.matches > 0 or sv.none) {
        var utf8: [40]u8 = undefined;
        const s = std.fmt.bufPrint(&utf8, "{d} / {d}{s}", .{ sv.current, sv.matches, if (sv.partial) "+" else "" }) catch "";
        const n = std.unicode.utf8ToUtf16Le(&buf, s) catch 0;
        text = buf[0..n];
    }
    p.text(text, ui.fonts.get(.hint), r.count, if (sv.none) t.danger else t.text_muted);

    const lit = sv.matches > 0;
    const button_color = if (lit) t.text_muted else t.text_inactive;
    if (r.prev) |b| ui.drawIcon(p, .chevron_up, b.inset(ui.px(5), ui.px(5)), button_color);
    if (r.next) |b| ui.drawIcon(p, .chevron_down, b.inset(ui.px(5), ui.px(5)), button_color);
    if (r.close) |b| ui.drawIcon(p, .x, b.inset(ui.px(5), ui.px(5)), t.text_muted);
}

/// A button, else the search card's parts, else the title strip (which
/// drags the pane), else a browser's URL bar or the rest of its address
/// row (which does nothing: the strip above is enough to drag by), else
/// the terminal.
pub fn hitTest(ui: *const Ui, node: *const Node, x: f32, y: f32) ?Id {
    for (node.kind.pane.buttons) |*b| if (ui.hitNode(b, x, y)) |id| return id;
    if (searchRects(ui, node)) |r| if (r.box.contains(x, y)) {
        if (r.prev) |b| if (b.contains(x, y)) return node.id.with(.search_prev);
        if (r.next) |b| if (b.contains(x, y)) return node.id.with(.search_next);
        if (r.close) |b| if (b.contains(x, y)) return node.id.with(.search_close);
        return node.id.with(.search);
    };
    if (titleRect(ui, node).contains(x, y)) return node.id.with(.title);
    if (node.kind.pane.browser != null) {
        if (urlRect(ui, node).contains(x, y)) return node.id.with(.field);
        if (barRect(ui, node).contains(x, y)) return node.id.with(.body);
    }
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
    const right = if (pane.buttons.len > pane.nav) pane.buttons[pane.nav].rect.x - ui.px(6) else strip.right() - ui.px(title_pad);
    const r: Rect = .{ .x = x, .y = strip.y, .w = @max(0, right - x), .h = strip.h };
    if (pane.focused) {
        p.text(pane.title, ui.fonts.get(.body_strong), r, ui.theme.text_strong);
    } else {
        p.text(pane.title, ui.fonts.get(.body), r, ui.theme.text_muted);
    }
    if (pane.browser) |b| {
        paintUrl(ui, p, urlRect(ui, node), b, pane.focused);
        if (!b.live) paintPage(ui, p, b);
    }
    paintSearch(ui, p, node);
    ui.paintChildren(p, node);
    if (pane.dimmed) p.fillRounded(node.rect, ui.px(10), .{ pane.bg[0], pane.bg[1], pane.bg[2], dim });
}

/// The URL bar: the field being edited, with its caret and selection,
/// or the url on a quieter box.
fn paintUrl(ui: *const Ui, p: *Painter, r: Rect, b: BrowserPane, focused: bool) void {
    if (r.w < 1 or r.h < 1) return;
    const radius = ui.px(6);
    if (b.field != null) {
        ui.fillBordered(p, r, radius, ui.theme.surface, ui.theme.accent);
    } else {
        p.fillRounded(r, radius, ui.theme.field);
    }
    const inner = urlText(ui, r);
    if (siteIcon(ui, r)) |icon| {
        if (b.favicon) |img| {
            p.image(img, icon, 0, 1);
        } else {
            ui.drawIcon(p, .globe, icon.inset(ui.px(1), ui.px(1)), if (focused) ui.theme.text_muted else ui.theme.text_inactive);
        }
    }
    if (b.field) |field| {
        ui.paintEditText(p, inner, field, .{ .caret = b.caret });
        return;
    }
    p.pushClip(inner);
    defer p.popClip();
    p.text(shownUrl(b.url), ui.fonts.get(.body), inner, if (focused) ui.theme.text else ui.theme.text_muted);
}

/// The site's icon in URL bar `r`, where the bar has room for it and
/// some url.
fn siteIcon(ui: *const Ui, r: Rect) ?Rect {
    const inner = r.inset(ui.px(url_pad), 0);
    const size = ui.px(site_icon);
    if (inner.w < 4 * size) return null;
    return .{ .x = inner.x, .y = r.y + @round((r.h - size) / 2), .w = size, .h = size };
}

/// Where URL bar `r` has its text: after the site's icon.
fn urlText(ui: *const Ui, r: Rect) Rect {
    const inner = r.inset(ui.px(url_pad), 0);
    const icon = siteIcon(ui, r) orelse return inner;
    const skip = icon.w + ui.px(site_gap);
    return .{ .x = inner.x + skip, .y = inner.y, .w = inner.w - skip, .h = inner.h };
}

/// Where the field being edited in pane `node` has its text: the URL
/// bar's (`url`) or the search card's.
pub fn fieldText(ui: *const Ui, node: *const Node, url: bool) ?Rect {
    if (url) return if (node.kind.pane.browser != null) urlText(ui, urlRect(ui, node)) else null;
    const r = searchRects(ui, node) orelse return null;
    return r.field;
}

/// A url as the bar shows it at rest: without `https://`, as browsers
/// do, so a narrow bar starts with the host.
pub fn shownUrl(url: []const u16) []const u16 {
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

test "a browser pane: its title strip, then an address row with history buttons and its URL bar" {
    const ui: Ui = .{ .scale = 1, .fonts = .none, .theme = undefined };
    const id: Id = .{ .target = .{ .pane = 5 } };
    var buttons = [_]Node{ testButton(id, .back), testButton(id, .forward), testButton(id, .reload), testButton(id, .split_right), testButton(id, .split_down) };
    var node: Node = .{ .id = id.with(.terminal), .kind = .{ .pane = .{
        .title = &.{},
        .focused = true,
        .bg = undefined,
        .buttons = &buttons,
        .nav = 3,
        .browser = .{ .url = &.{}, .page = .{ .y = title_height + bar_height, .w = 400, .h = 300 - title_height - bar_height }, .page_title = &.{} },
    } }, .rect = .{ .w = 400, .h = 300 } };
    ui.layoutNode(&node);
    // The split buttons in the strip at the right, as a terminal's.
    try std.testing.expectEqual(@as(f32, 400 - margin), buttons[4].rect.right());
    try std.testing.expect(buttons[4].rect.bottom() <= title_height);
    // The history buttons at the left of the row under it.
    try std.testing.expectEqual(@as(f32, bar_pad), buttons[0].rect.x);
    try std.testing.expect(buttons[0].rect.y >= title_height);
    try std.testing.expectEqual(buttons[0].rect.right(), buttons[1].rect.x);
    // The bar takes the rest of the row, to its pad at the right.
    const bar = urlRect(&ui, &node);
    try std.testing.expectEqual(buttons[2].rect.right() + url_gap, bar.x);
    try std.testing.expectEqual(@as(f32, 400 - bar_pad), bar.right());
    try std.testing.expectEqual(@as(f32, title_height + url_inset), bar.y);
    try std.testing.expectEqual(@as(f32, bar_height - 2 * url_inset), bar.h);
    // The whole strip drags the pane; the row around the bar is inert.
    try std.testing.expectEqual(id.with(.title), ui.hitNode(&node, 200, 10).?);
    try std.testing.expectEqual(id.with(.body), ui.hitNode(&node, 200, title_height + 1).?);
    try std.testing.expectEqual(id.with(.field), ui.hitNode(&node, bar.x + 5, bar.y + 5).?);
    try std.testing.expectEqual(id.with(.back), ui.hitNode(&node, buttons[0].rect.x + 1, buttons[0].rect.y + 1).?);
    try std.testing.expectEqual(id.with(.split_down), ui.hitNode(&node, buttons[4].rect.x + 1, buttons[4].rect.y + 1).?);
    // Its page is the pane's, as a terminal is.
    try std.testing.expectEqual(id.with(.terminal), ui.hitNode(&node, 200, 200).?);

    // At 175%, a narrow pane leaves the bar too little beside the
    // history buttons, which go, and it takes the row; a wider pane
    // keeps them.
    const big: Ui = .{ .scale = 1.75, .fonts = .none, .theme = undefined };
    var zoom_buttons = [_]Node{ testButton(id, .back), testButton(id, .forward), testButton(id, .reload), testButton(id, .split_right), testButton(id, .split_down), testButton(id, .zoom) };
    for ([_]f32{ 300, 700 }) |w| {
        node.rect = .{ .w = w, .h = 820 };
        node.kind.pane.dot = true;
        node.kind.pane.buttons = &zoom_buttons;
        node.kind.pane.nav = 3;
        big.layoutNode(&node);
        const pane = node.kind.pane;
        const wide = urlRect(&big, &node);
        if (w == 300) {
            try std.testing.expectEqual(@as(usize, 0), pane.nav);
            try std.testing.expectEqual(@as(usize, 3), pane.buttons.len);
            try std.testing.expect(big.hitNode(&node, 50, 10).?.part != .back);
            try std.testing.expectEqual(big.px(bar_pad), wide.x);
            try std.testing.expectEqual(w - big.px(bar_pad), wide.right());
        } else {
            try std.testing.expectEqual(@as(usize, 3), pane.nav);
            try std.testing.expectEqual(id.with(.back), big.hitNode(&node, pane.buttons[0].rect.x + 1, pane.buttons[0].rect.y + 1).?);
            try std.testing.expectEqual(pane.buttons[2].rect.right() + big.px(url_gap), wide.x);
            try std.testing.expect(wide.w >= big.px(url_min));
            // The split buttons stay in the strip, above the row.
            try std.testing.expect(pane.buttons[3].rect.bottom() <= big.px(title_height));
        }
    }
}
