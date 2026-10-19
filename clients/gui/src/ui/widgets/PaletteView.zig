//! A `palette`: the command palette's box, raised over everything near
//! the top of the window, centered: the query's field under a search
//! icon (with a chip naming the step, in the host step), the results
//! under it one to a row, each an icon, its label and detail with the
//! units the query matched in the accent, and at the right the key
//! that does the same; captions name the sections while the query is
//! empty. A footer names the keys. The rows are the results from the
//! palette's `scroll`, as many as fit. Layout is one function, so
//! drawing and hit testing agree.

const std = @import("std");
const Ui = @import("../Ui.zig");
const Painter = @import("../../renderer/Painter.zig");

const Node = Ui.Node;
const Rect = Ui.Rect;
const Id = Ui.Id;
const Color = Ui.Color;
const Palette = Ui.Palette;
const Scrollbar = Ui.Scrollbar;
const withAlpha = @import("../theme.zig").withAlpha;

// Sizes in DIPs.
const width = 600;
/// The box stays this far inside the window's sides.
const side_margin = 32;
/// Under the title bar.
const top_gap = 32;
/// Under the box, at least.
const bottom_gap = 24;
const radius = 10;
const search_height = 44;
const search_pad_x = 14;
const search_icon = 16;
const search_gap = 10;
const chip_height = 24;
const chip_pad_x = 8;
const chip_icon = 14;
const list_pad = 6;
const caption_height = 24;
const caption_pad_x = 10;
const row_height = 32;
const row_pad_x = 10;
const row_radius = 6;
const icon_size = 16;
/// The icon's column, before the label.
const icon_column = 26;
/// Between the label and its detail, and before the key at the right.
const detail_gap = 8;
const right_gap = 16;
const footer_height = 30;
const footer_pad_x = 14;
/// The most rows laid out, whatever the window's height.
pub const max_rows = 64;

pub const Row = struct {
    /// The result's index.
    result: usize,
    rect: Rect,
    /// The caption over it, where its section starts one.
    caption: ?Rect = null,
};

pub const Layout = struct {
    box: Rect,
    /// The search icon, the chip (empty but in the host step), and the
    /// field's inner rect.
    icon: Rect,
    chip: Rect = .{},
    field: Rect,
    /// Where the rows go, and the rows from the palette's `scroll` that
    /// fit; `empty` is the line that says nothing matched.
    list: Rect,
    rows: [max_rows]Row = undefined,
    row_count: usize = 0,
    empty: Rect = .{},
    footer: Rect,
    /// The list's rows: all of them, the ones drawn, and the first.
    metrics: Scrollbar.Metrics = .{ .total = 0, .visible = 0, .start = 0 },
    /// The scrollbar along the list's right edge, while not every row
    /// fits.
    bar: ?Scrollbar.Layout = null,
};

/// The box for `pal` in `frame`: centered under the title bar, with
/// the rows from `pal.scroll` that fit above the window's bottom.
pub fn layoutIn(ui: *const Ui, frame: *const Ui.Frame, pal: *const Palette) Layout {
    const f = &ui.fonts;
    const window = frame.window;
    const w = @min(ui.px(width), @max(0, window.w - 2 * ui.px(side_margin)));
    const x = window.x + @round((window.w - w) / 2);
    const search_h = ui.px(search_height);
    const footer_h = ui.px(footer_height);
    const pad = ui.px(list_pad);
    const row_h = ui.px(row_height);
    const caption_h = ui.px(caption_height);
    // Under the title bar, but up from there in a window too short for
    // a row and its caption under it.
    const least = search_h + 2 * pad + caption_h + row_h + footer_h;
    const top = @max(frame.titlebar.bottom(), @min(frame.titlebar.bottom() + ui.px(top_gap), window.bottom() - ui.px(bottom_gap) - least));
    // Room for the rows: what's under the search row and over the footer.
    const most_list = @max(row_h, window.bottom() - ui.px(bottom_gap) - top - search_h - footer_h - 2 * pad);

    var l: Layout = .{ .box = .{}, .icon = .{}, .field = .{}, .list = .{}, .footer = .{} };
    const left = x + ui.px(search_pad_x);
    const right = x + w - ui.px(search_pad_x);
    const icon = ui.px(search_icon);
    l.icon = .{ .x = left, .y = top + @round((search_h - icon) / 2), .w = icon, .h = icon };
    var field_x = l.icon.right() + ui.px(search_gap);
    if (pal.step == .host) {
        const label = L("Connect to host");
        const chip_w = 2 * ui.px(chip_pad_x) + ui.px(chip_icon) + ui.px(6) + @ceil(f.measure(label, f.get(.section)));
        const chip_h = ui.px(chip_height);
        l.chip = .{ .x = field_x, .y = top + @round((search_h - chip_h) / 2), .w = chip_w, .h = chip_h };
        field_x = l.chip.right() + ui.px(search_gap);
    }
    l.field = .{ .x = field_x, .y = top, .w = @max(0, right - field_x), .h = search_h };

    const list_x = x + pad;
    const list_w = w - 2 * pad;
    var y = top + search_h + pad;
    const list_top = y;
    const captions = pal.queryText().len == 0;
    var i = pal.scroll;
    var last_section: ?Palette.Section = null;
    while (i < pal.count() and l.row_count < max_rows) : (i += 1) {
        const e = pal.entryOf(i).?;
        var row: Row = .{ .result = i, .rect = .{} };
        var h = row_h;
        if (captions and (last_section == null or last_section.? != e.section)) {
            row.caption = .{ .x = list_x, .y = y, .w = list_w, .h = caption_h };
            h += caption_h;
        }
        if (y + h > list_top + most_list and l.row_count > 0) break;
        if (row.caption) |c| row.rect = .{ .x = list_x, .y = c.bottom(), .w = list_w, .h = row_h } else row.rect = .{ .x = list_x, .y = y, .w = list_w, .h = row_h };
        y += h;
        last_section = e.section;
        l.rows[l.row_count] = row;
        l.row_count += 1;
    }
    if (pal.count() == 0) {
        l.empty = .{ .x = list_x, .y = y, .w = list_w, .h = row_h };
        y += row_h;
    }
    // Scrolled near the end, fewer rows are left to draw than fit; the
    // box keeps the height it has from the top, with room under them.
    const full = listHeight(ui, pal, most_list);
    l.list = .{ .x = list_x, .y = list_top, .w = list_w, .h = @max(y - list_top, full) };
    l.metrics = .{ .total = pal.count(), .visible = l.row_count, .start = pal.scroll };
    l.bar = Scrollbar.layout(ui, l.list, l.metrics, barState(ui));
    y = l.list.bottom() + pad;
    l.footer = .{ .x = x, .y = y, .w = w, .h = footer_h };
    y += footer_h;
    l.box = .{ .x = x, .y = top, .w = w, .h = y - top };
    return l;
}

/// The height of the rows from the top of the list that fit in `most`,
/// captions included.
fn listHeight(ui: *const Ui, pal: *const Palette, most: f32) f32 {
    const row_h = ui.px(row_height);
    const caption_h = ui.px(caption_height);
    const captions = pal.queryText().len == 0;
    var h: f32 = 0;
    var last_section: ?Palette.Section = null;
    var n: usize = 0;
    for (0..pal.count()) |i| {
        const e = pal.entryOf(i).?;
        var row_total = row_h;
        if (captions and (last_section == null or last_section.? != e.section)) row_total += caption_h;
        if (h + row_total > most and n > 0) break;
        h += row_total;
        n += 1;
        last_section = e.section;
    }
    return h;
}

/// Wide while the mouse is near the list's edge, dark while dragged.
fn barState(ui: *const Ui) Scrollbar.State {
    const id = Id.window(.scrollbar);
    if (ui.pressed.eql(id)) return .drag;
    if (ui.hover.eql(id)) return .hover;
    return .rest;
}

/// Where the box goes: the node's rect.
pub fn place(ui: *const Ui, frame: *const Ui.Frame, pal: *const Palette) Rect {
    return layoutIn(ui, frame, pal).box;
}

/// How many results are drawn from `pal.scroll`, for keeping the focus
/// among them.
pub fn visibleRows(ui: *const Ui, frame: *const Ui.Frame, pal: *const Palette) usize {
    return layoutIn(ui, frame, pal).row_count;
}

/// A result's row, the field, or the box itself.
pub fn hitTest(ui: *const Ui, node: *const Node, x: f32, y: f32) ?Id {
    const v = node.kind.palette;
    const l = layoutIn(ui, v.frame, v.palette);
    // The strip along the edge wins over the rows' right ends.
    if (l.bar != null and Scrollbar.strip(ui, l.list).contains(x, y)) return Id.window(.scrollbar);
    for (l.rows[0..l.row_count]) |row| {
        if (row.rect.contains(x, y)) return .{ .target = .{ .palette = @intCast(row.result) } };
    }
    if (l.field.contains(x, y) or l.icon.contains(x, y) or l.chip.contains(x, y)) return Id.window(.field);
    return node.id;
}

pub fn paint(ui: *const Ui, p: *Painter, node: *const Node) void {
    const v = node.kind.palette;
    const pal = v.palette;
    const t = &ui.theme;
    const f = &ui.fonts;
    const l = layoutIn(ui, v.frame, pal);
    const r = l.box;
    ui.paintShadow(p, r, ui.px(radius));
    ui.fillBordered(p, r, ui.px(radius), t.dialog, t.pane_border);

    // The search row.
    ui.drawIcon(p, .search, l.icon, t.text_muted);
    if (pal.step == .host) {
        const c = l.chip;
        p.fillRounded(c, ui.px(5), withAlpha(t.accent, 0.14));
        const ci = ui.px(chip_icon);
        ui.drawIcon(p, .plug, .{ .x = c.x + ui.px(chip_pad_x), .y = c.y + @round((c.h - ci) / 2), .w = ci, .h = ci }, t.accent);
        const label_x = c.x + ui.px(chip_pad_x) + ci + ui.px(6);
        p.text(L("Connect to host"), f.get(.section), .{ .x = label_x, .y = c.y, .w = c.right() - label_x, .h = c.h }, t.accent);
    }
    if (pal.query.len == 0) {
        const placeholder = switch (pal.step) {
            .commands => L("Type a command or a tab name…"),
            .host => L("[user@]host[:port]"),
        };
        p.text(placeholder, f.get(.body), l.field, t.text_inactive);
    }
    ui.paintEditText(p, l.field, &pal.query, .{ .caret = v.caret, .color = t.text_strong });
    const stroke = ui.stroke();
    const divider_y = Ui.crisp(l.field.bottom(), stroke);
    p.line(r.x + stroke, divider_y, r.right() - stroke, divider_y, stroke, t.dialog_outline);

    // The rows.
    const mouse_on_list = ui.hover.target == .palette;
    for (l.rows[0..l.row_count]) |row| {
        const e = pal.entryOf(row.result).?;
        const res = pal.results.items[row.result];
        if (row.caption) |c| {
            // Low in its line, close over the rows it names.
            const lift = ui.px(6);
            p.text(Palette.caption(e.section), f.get(.section), .{ .x = c.x + ui.px(caption_pad_x), .y = c.y + lift, .w = c.w - 2 * ui.px(caption_pad_x), .h = c.h - lift }, t.text_muted);
        }
        const id: Id = .{ .target = .{ .palette = @intCast(row.result) } };
        const state = ui.buttonState(id);
        const lit = state != .rest or (!mouse_on_list and pal.focus == row.result);
        const rr = row.rect;
        if (lit) p.fillRounded(rr, ui.px(row_radius), if (state == .pressed) t.button_pressed else t.button_hover);
        const inner = rr.inset(ui.px(row_pad_x), 0);
        const color = if (lit) t.text_strong else t.text;
        if (e.icon) |icon| {
            const column: Rect = .{ .x = inner.x, .y = inner.y, .w = ui.px(icon_column), .h = inner.h };
            ui.drawIcon(p, icon, column.center(ui.px(icon_size), ui.px(icon_size)), if (lit) t.text_strong else t.text_muted);
        }
        var right_edge = inner.right();
        if (e.right.len > 0) {
            const rw = @ceil(f.measure(e.right, f.get(.tip)));
            p.text(e.right, f.get(.tip), .{ .x = inner.right() - rw, .y = inner.y, .w = rw, .h = inner.h }, t.text_muted);
            right_edge -= rw + ui.px(right_gap);
        }
        const text_x = inner.x + ui.px(icon_column);
        const text: Rect = .{ .x = text_x, .y = inner.y, .w = @max(0, right_edge - text_x), .h = inner.h };
        p.pushClip(text);
        defer p.popClip();
        var x = text.x;
        x += paintMarked(ui, p, e.label, res.label_hits, x, text, .body, .body_strong, color);
        if (e.detail.len > 0) {
            x += ui.px(detail_gap);
            _ = paintMarked(ui, p, e.detail, res.detail_hits, x, text, .tip, .tip_strong, t.text_muted);
        }
    }
    if (pal.count() == 0) {
        p.text(switch (pal.step) {
            .commands => L("Nothing matches"),
            .host => L("No hosts match"),
        }, f.get(.body), l.empty.inset(ui.px(row_pad_x) + ui.px(icon_column), 0), t.text_inactive);
    }

    if (l.bar) |bar| Scrollbar.paint(ui, p, bar, barState(ui));

    // The footer.
    const fy = Ui.crisp(l.footer.y, stroke);
    p.line(r.x + stroke, fy, r.right() - stroke, fy, stroke, t.dialog_outline);
    const foot = l.footer.inset(ui.px(footer_pad_x), 0);
    const hints: []const u16 = switch (pal.step) {
        .commands => L("↑↓ move   ↵ run   Esc close"),
        .host => L("↑↓ move   ↵ connect   Esc back"),
    };
    p.text(hints, f.get(.tip), foot, t.text_muted);
    var buf: [32]u8 = undefined;
    var units: [32]u16 = undefined;
    const digits = if (pal.count() == 0) "" else std.fmt.bufPrint(&buf, "{d} of {d}", .{ pal.focus + 1, pal.count() }) catch "";
    for (digits, 0..) |d, i| units[i] = d;
    const count = units[0..digits.len];
    const cw = @ceil(f.measure(count, f.get(.tip)));
    p.text(count, f.get(.tip), .{ .x = foot.right() - cw, .y = foot.y, .w = cw, .h = foot.h }, t.text_muted);
}

/// Draw `text` from `x` in the row `line`, the units `hits` marks in
/// the accent and `strong`, the rest in `color` and `font`. Returns the
/// width drawn.
fn paintMarked(ui: *const Ui, p: *Painter, text: []const u16, hits: Palette.Hits, x: f32, line: Rect, font: Ui.Font, strong: Ui.Font, color: Color) f32 {
    const f = &ui.fonts;
    var at = x;
    var i: usize = 0;
    while (i < text.len) {
        const marked = i < Palette.max_text and hits.isSet(i);
        var end = i + 1;
        while (end < text.len and (end < Palette.max_text and hits.isSet(end)) == marked) end += 1;
        const run = text[i..end];
        const format = f.get(if (marked) strong else font);
        const w = f.measure(run, format);
        // Laid out wider than it is, so it's never trimmed; the row clips.
        p.text(run, format, .{ .x = at, .y = line.y, .w = w + ui.px(8), .h = line.h }, if (marked) ui.theme.accent else color);
        at += w;
        i = end;
    }
    return at - x;
}

const L = std.unicode.utf8ToUtf16LeStringLiteral;

test "the box is centered under the title bar, its rows are hit, and the rest is the box" {
    const ui: Ui = .{ .scale = 1, .fonts = .none, .theme = undefined };
    const frame = ui.frame(1000, 600);
    var pal: Palette = .init(std.testing.allocator);
    defer pal.deinit();
    pal.beginRebuild();
    try pal.add(.{ .label = L("cmd"), .section = .tab, .action = .{ .tab = 1 } });
    try pal.add(.{ .label = L("New tab"), .section = .command, .action = .{ .binding = .new_tab } });
    try pal.add(.{ .label = L("New workspace"), .section = .command, .action = .{ .part = Id.window(.new_tab) } });
    try pal.endRebuild();
    const l = layoutIn(&ui, &frame, &pal);
    try std.testing.expectEqual(@as(f32, width), l.box.w);
    try std.testing.expectEqual(@as(f32, 200), l.box.x);
    try std.testing.expectEqual(frame.titlebar.bottom() + top_gap, l.box.y);
    // Three rows under two captions (the query is empty), then the footer.
    try std.testing.expectEqual(@as(usize, 3), l.row_count);
    try std.testing.expect(l.rows[0].caption != null);
    try std.testing.expect(l.rows[1].caption != null);
    try std.testing.expect(l.rows[2].caption == null);
    try std.testing.expectEqual(l.rows[1].rect.bottom(), l.rows[2].rect.y);
    try std.testing.expectEqual(l.box.bottom(), l.footer.bottom());

    const node: Node = .{ .id = Id.window(.palette), .kind = .{ .palette = .{ .palette = &pal, .frame = &frame, .caret = false } }, .rect = l.box };
    try std.testing.expectEqual(Id{ .target = .{ .palette = 1 } }, hitTest(&ui, &node, l.rows[1].rect.x + 5, l.rows[1].rect.y + 5).?);
    try std.testing.expectEqual(Id.window(.field), hitTest(&ui, &node, l.field.x + 5, l.field.y + 5).?);
    try std.testing.expectEqual(Id.window(.palette), hitTest(&ui, &node, l.footer.x + 5, l.footer.y + 5).?);
    try std.testing.expectEqual(Id.window(.palette), hitTest(&ui, &node, l.rows[0].caption.?.x + 5, l.rows[0].caption.?.y + 5).?);

    // A short window shows what fits, from the scroll: here two rows,
    // each under its section's caption.
    const short = ui.frame(1000, 36 + top_gap + search_height + 2 * list_pad + footer_height + bottom_gap + 2 * caption_height + 2 * row_height);
    const fit = layoutIn(&ui, &short, &pal);
    try std.testing.expectEqual(@as(usize, 2), fit.row_count);
    try std.testing.expectEqual(@as(usize, 2), visibleRows(&ui, &short, &pal));
    // Not every row fits: a bar along the list's edge, whose strip is hit
    // before the row under it; with every row shown, none.
    try std.testing.expect(l.bar == null);
    const bar = fit.bar.?;
    try std.testing.expectEqual(fit.list.right() - 3 - 3, bar.thumb.x);
    try std.testing.expectEqual(bar.track.y, bar.thumb.y);
    const short_node: Node = .{ .id = Id.window(.palette), .kind = .{ .palette = .{ .palette = &pal, .frame = &short, .caret = false } }, .rect = fit.box };
    try std.testing.expectEqual(Id.window(.scrollbar), hitTest(&ui, &short_node, fit.list.right() - 4, fit.rows[0].rect.y + 5).?);
    try std.testing.expectEqual(Id{ .target = .{ .palette = 0 } }, hitTest(&ui, &short_node, fit.list.right() - 30, fit.rows[0].rect.y + 5).?);
    pal.scroll = 2;
    const scrolled = layoutIn(&ui, &short, &pal);
    try std.testing.expectEqual(@as(usize, 1), scrolled.row_count);
    try std.testing.expectEqual(@as(usize, 2), scrolled.rows[0].result);
    // One row left to draw, but the box keeps its height.
    try std.testing.expectEqual(fit.box.h, scrolled.box.h);
    // Too short for the box under the title bar: it moves up to fit.
    const tiny = ui.frame(1000, 36 + 20 + search_height + 2 * list_pad + footer_height + bottom_gap + caption_height + row_height);
    const up = layoutIn(&ui, &tiny, &pal);
    try std.testing.expectEqual(@as(f32, 36 + 20), up.box.y);
    try std.testing.expectEqual(tiny.window.bottom() - bottom_gap, up.box.bottom());
    // With a query, no captions.
    pal.scroll = 0;
    pal.query.insert(L("new"));
    pal.beginRebuild();
    try pal.add(.{ .label = L("New tab"), .section = .command, .action = .{ .binding = .new_tab } });
    try pal.endRebuild();
    try std.testing.expect(layoutIn(&ui, &frame, &pal).rows[0].caption == null);
    // Nothing: a line saying so.
    pal.beginRebuild();
    try pal.endRebuild();
    const none = layoutIn(&ui, &frame, &pal);
    try std.testing.expectEqual(@as(usize, 0), none.row_count);
    try std.testing.expectEqual(@as(f32, row_height), none.empty.h);
}
