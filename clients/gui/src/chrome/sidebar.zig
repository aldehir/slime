//! Tabs in a sidebar under the title bar, grouped by where they run:
//! the local daemon's workspaces, then each remembered SSH host. A
//! workspace's header folds its tabs away (the window lets go of it; the
//! daemon keeps it running) and back, and has buttons to open a tab in
//! it, rename it, hide it, and kill it; a row after the last makes a new
//! one. A host's header has a button that opens another tab there,
//! connecting first if the host isn't connected; a host with no tabs can
//! be forgotten. A "Connect" button at the bottom turns into a field for
//! a host to connect to.
//!
//! Each tab's row folds open to its panes, each a row of its own with
//! what its programs report doing (OSC 7501): working, waiting on the
//! user, done, or failed.

const std = @import("std");
const Chrome = @import("Chrome.zig");
const Painter = @import("../renderer/Painter.zig");

const Rect = Chrome.Rect;
const Hit = Chrome.Hit;
const L = std.unicode.utf8ToUtf16LeStringLiteral;

// Sizes in DIPs.
pub const titlebar_height = 36;
const width = 240;
const pad_x = 12;
const pad_top = 4;
const section_gap = 10;
const header_height = 28;
const row_height = 30;
const row_gap = 2;
/// A pane's row, under its tab's.
const pane_height = 28;
/// How far pane rows are indented: past the tab's fold arrow.
const pane_indent = 26;
/// The fold arrow's column at a tab row's left, and a workspace
/// header's.
const fold_width = 18;
/// Rows' close buttons and headers' buttons, in columns from the right.
const button_size = 20;
const button_gap = 2;
/// The "New workspace" row.
const new_workspace_height = 26;
const connect_height = 32;
const pad_bottom = 12;

pub fn layout(c: *const Chrome, l: *Chrome.Layout) void {
    const top = l.titlebar.bottom();
    const w = @min(c.px(width), l.window.w);
    const h = @max(0, l.window.h - top);
    l.list = .{ .y = top, .w = w, .h = h };
    l.terminal = .{ .x = w, .y = top, .w = l.window.w - w, .h = h };
}

pub fn hitTest(c: *const Chrome, l: *const Chrome.Layout, view: *const Chrome.View, x: f32, y: f32) ?Hit {
    if (!l.list.contains(x, y)) return null;
    if (connectRect(c, l).contains(x, y)) return .connect;
    const rows = rowsArea(c, l);
    if (!rows.contains(x, y)) return .none;
    var walk: Walk = .init(c, l, view);
    while (walk.next()) |item| {
        if (item.rect.y >= rows.bottom()) break;
        if (!item.rect.contains(x, y)) continue;
        const on_button = rowButton(c, item.rect, 0).contains(x, y);
        return switch (item.part) {
            .header => |g| header: {
                const group = view.groups[g];
                if (renaming(view, g)) break :header .{ .rename_field = g };
                if (on_button) break :header .{ .new_tab = g };
                if (group.kind == .workspace) {
                    if (rowButton(c, item.rect, 1).contains(x, y)) break :header .{ .kill_workspace = g };
                    if (rowButton(c, item.rect, 2).contains(x, y)) break :header .{ .rename_workspace = g };
                    if (group.shown and rowButton(c, item.rect, 3).contains(x, y)) break :header .{ .detach_workspace = g };
                } else if (forgettable(group) and rowButton(c, item.rect, 1).contains(x, y)) {
                    break :header .{ .forget_host = g };
                }
                break :header .{ .header = g };
            },
            .tab => |i| if (on_button)
                .{ .close_tab = i }
            else if (x < item.rect.x + c.px(fold_width))
                .{ .fold = i }
            else
                .{ .tab = i },
            .pane => |pn| .{ .tab_pane = .{ .tab = pn.tab, .pane = pn.pane } },
            .new_workspace => .new_workspace,
        };
    }
    return .none;
}

/// Where a header's or row's button is, if it's in view.
pub fn buttonRect(c: *const Chrome, l: *const Chrome.Layout, view: *const Chrome.View, hit: Hit) ?Rect {
    const rows = rowsArea(c, l);
    var walk: Walk = .init(c, l, view);
    while (walk.next()) |item| {
        if (item.rect.bottom() > rows.bottom()) break;
        switch (item.part) {
            .header => |g| switch (hit) {
                .new_tab => |h| if (h == g) return rowButton(c, item.rect, 0),
                .forget_host, .kill_workspace => |h| if (h == g) return rowButton(c, item.rect, 1),
                .rename_workspace => |h| if (h == g) return rowButton(c, item.rect, 2),
                .detach_workspace => |h| if (h == g) return rowButton(c, item.rect, 3),
                else => {},
            },
            .tab => |i| if (hit == .close_tab and hit.close_tab == i) return rowButton(c, item.rect, 0),
            .pane, .new_workspace => {},
        }
    }
    return null;
}

pub fn paint(c: *const Chrome, p: *Painter, l: *const Chrome.Layout, view: *const Chrome.View) void {
    p.fill(l.list, c.theme.ground);
    c.paintTitle(p, l, view);
    p.pushClip(l.list);
    defer p.popClip();

    const rows = rowsArea(c, l);
    p.pushClip(rows);
    var walk: Walk = .init(c, l, view);
    while (walk.next()) |item| {
        if (item.rect.y >= rows.bottom()) break;
        switch (item.part) {
            .header => |g| paintHeader(c, p, item.rect, g, view),
            .tab => |i| paintTab(c, p, item.rect, i, view.tabs[i], i == view.active, view.spinner),
            .pane => |pn| paintPane(c, p, item.rect, pn.tab, pn.pane, view),
            .new_workspace => paintNewWorkspace(c, p, item.rect),
        }
    }
    p.popClip();

    const connect = connectRect(c, l);
    if (view.connect) |field| {
        paintField(c, p, connect, field, L("user@host:port"), view.focused and view.caret_visible);
    } else {
        paintConnect(c, p, connect);
    }
    paintStats(c, p, l, connect.y, view.stats);
}

/// Whether group `g`'s name is being edited.
fn renaming(view: *const Chrome.View, g: usize) bool {
    return if (view.rename) |r| r.group == g else false;
}

/// "Connect", at the bottom of the list.
fn connectRect(c: *const Chrome, l: *const Chrome.Layout) Rect {
    const h = c.px(connect_height);
    return .{
        .x = l.list.x + c.px(pad_x),
        .y = l.list.bottom() - c.px(pad_bottom) - h,
        .w = @max(0, l.list.w - 2 * c.px(pad_x)),
        .h = h,
    };
}

/// Where groups and rows go: above "Connect".
fn rowsArea(c: *const Chrome, l: *const Chrome.Layout) Rect {
    const bottom = connectRect(c, l).y - c.px(section_gap);
    return .{ .x = l.list.x, .y = l.list.y, .w = l.list.w, .h = @max(0, bottom - l.list.y) };
}

/// The frame stats at the bottom left, above `bottom`, in line with the
/// section headers.
fn paintStats(c: *const Chrome, p: *Painter, l: *const Chrome.Layout, bottom: f32, stats: []const u16) void {
    if (stats.len == 0) return;
    const line_h = c.px(16);
    const lines: f32 = @floatFromInt(std.mem.countScalar(u16, stats, '\n') + 1);
    const x = l.list.x + c.px(pad_x) + c.px(2);
    var r: Rect = .{
        .x = x,
        .y = bottom - c.px(10) - lines * line_h,
        .w = @max(0, l.list.right() - c.px(pad_x) - x),
        .h = line_h,
    };
    var it = std.mem.splitScalar(u16, stats, '\n');
    while (it.next()) |line| : (r.y += line_h) p.text(line, c.fonts.mono, r, c.theme.text_muted);
}

fn paintConnect(c: *const Chrome, p: *Painter, r: Rect) void {
    const bg = switch (c.buttonState(.connect)) {
        .rest => c.theme.surface,
        .hover, .pressed => c.theme.surface_hover,
    };
    p.fillRounded(r, c.px(6), bg);
    paintPlug(c, p, .{ .x = r.x + c.px(7), .y = r.y, .w = c.px(20), .h = r.h }, c.theme.text);
    const label_x = r.x + c.px(32);
    p.text(L("Connect…"), c.fonts.body, .{ .x = label_x, .y = r.y, .w = @max(0, r.right() - c.px(8) - label_x), .h = r.h }, c.theme.text);
}

/// The row that makes a workspace, after the last one's tabs: faint
/// until the mouse is over it.
fn paintNewWorkspace(c: *const Chrome, p: *Painter, r: Rect) void {
    const hovered = c.hover.eql(.new_workspace);
    if (hovered) p.fillRounded(r, c.px(6), switch (c.buttonState(.new_workspace)) {
        .pressed => c.theme.button_pressed,
        else => c.theme.row_hover,
    });
    const color = if (hovered) c.theme.text_strong else c.theme.text_inactive;
    const icon = c.px(17);
    c.drawIcon(p, .plus, (Rect{ .x = r.x, .y = r.y, .w = c.px(fold_width + 24), .h = r.h }).center(icon, icon), color);
    const text_x = r.x + c.px(fold_width + 24);
    p.text(L("New workspace"), c.fonts.body, .{ .x = text_x, .y = r.y, .w = @max(0, r.right() - c.px(8) - text_x), .h = r.h }, color);
}

/// A text field in `r`: its text scrolled to keep the caret in view, with
/// the selection behind it, and `placeholder` while empty.
fn paintField(c: *const Chrome, p: *Painter, r: Rect, field: *const Chrome.TextField, placeholder: []const u16, caret: bool) void {
    const radius = c.px(6);
    c.fillBordered(p, r, radius, c.theme.surface, c.theme.accent);

    const inner = r.inset(c.px(10), 0);
    if (field.len == 0) p.text(placeholder, c.fonts.body, inner, c.theme.text_inactive);
    c.paintEditText(p, inner, field, .{ .caret = caret });
}

/// Group `g`'s header: its name in capitals, with a fold arrow for a
/// workspace (its tabs are listed while shown), and buttons at the
/// right: one to open a tab in it always; a host with no tabs gets one
/// to forget it, and a workspace its kill, rename, and (while shown)
/// hide buttons, while the mouse is over the header. A workspace hidden
/// shows how many tabs it has instead, and one other windows show, an
/// eye.
fn paintHeader(c: *const Chrome, p: *Painter, r: Rect, g: usize, view: *const Chrome.View) void {
    const group = view.groups[g];
    const is_ws = group.kind == .workspace;
    const label_left = if (is_ws) r.x + c.px(fold_width) else r.x + c.px(2);
    if (view.rename) |rename| if (rename.group == g) {
        if (is_ws) paintFold(c, p, .{ .x = r.x, .y = r.y, .w = c.px(fold_width), .h = r.h }, !group.shown, c.theme.text_muted);
        paintField(c, p, .{ .x = label_left, .y = r.y, .w = @max(0, r.right() - label_left), .h = r.h }, rename.field, L("Workspace name"), view.focused and view.caret_visible);
        return;
    };

    const hovered = switch (c.hover) {
        .header, .new_tab, .forget_host, .kill_workspace, .rename_workspace, .detach_workspace => |h| h == g,
        else => false,
    };
    if (is_ws and c.hover.eql(.{ .header = g })) p.fillRounded(r, c.px(6), c.theme.row_hover);

    const button = rowButton(c, r, 0);
    const hit: Hit = .{ .new_tab = g };
    paintIconButton(c, p, button, hit);
    const color = if (c.hover.eql(hit)) c.theme.text_strong else c.theme.text_muted;
    if (group.kind == .disconnected) {
        paintPlug(c, p, button, color);
    } else {
        // Lucide's plus spans 14 of its 24 units: 10 DIPs in this box,
        // whose odd size centers the lines on pixels.
        const icon = c.px(17);
        c.drawIcon(p, .plus, button.center(icon, icon), color);
    }

    var label_right = button.x - c.px(4);
    if (hovered and forgettable(group)) {
        const forget = rowButton(c, r, 1);
        const forget_hit: Hit = .{ .forget_host = g };
        paintIconButton(c, p, forget, forget_hit);
        // Lucide's x spans 12 of its 24 units: 8 DIPs in this box.
        const icon = c.px(16);
        c.drawIcon(p, .x, forget.center(icon, icon), if (c.hover.eql(forget_hit)) c.theme.text_strong else c.theme.text_muted);
        label_right = forget.x - c.px(4);
    }
    if (is_ws) {
        paintFold(c, p, .{ .x = r.x, .y = r.y, .w = c.px(fold_width), .h = r.h }, !group.shown, if (hovered) c.theme.text_strong else c.theme.text_muted);
        if (hovered) {
            // Kill, rename, and hide, from the right. Each icon spans 16
            // to 18 of its 24 units: about 11 DIPs in these boxes.
            const kill = rowButton(c, r, 1);
            const kill_hit: Hit = .{ .kill_workspace = g };
            paintIconButton(c, p, kill, kill_hit);
            c.drawIcon(p, .trash, kill.center(c.px(16), c.px(16)), if (c.hover.eql(kill_hit)) c.theme.danger else c.theme.text_muted);
            const rename = rowButton(c, r, 2);
            const rename_hit: Hit = .{ .rename_workspace = g };
            paintIconButton(c, p, rename, rename_hit);
            c.drawIcon(p, .pencil, rename.center(c.px(16), c.px(16)), if (c.hover.eql(rename_hit)) c.theme.text_strong else c.theme.text_muted);
            label_right = rename.x - c.px(4);
            if (group.shown) {
                const hide = rowButton(c, r, 3);
                const hide_hit: Hit = .{ .detach_workspace = g };
                paintIconButton(c, p, hide, hide_hit);
                c.drawIcon(p, .eye_off, hide.center(c.px(17), c.px(17)), if (c.hover.eql(hide_hit)) c.theme.text_strong else c.theme.text_muted);
                label_right = hide.x - c.px(4);
            }
        } else {
            // At rest: how many tabs a hidden workspace has, and whether
            // another window shows it.
            var slot = rowButton(c, r, 1);
            if (group.others > 0) {
                c.drawIcon(p, .eye, slot.center(c.px(17), c.px(17)), c.theme.text_muted);
                label_right = slot.x - c.px(4);
                slot = rowButton(c, r, 2);
            }
            if (!group.shown and group.count > 0) {
                var buf: [12]u8 = undefined;
                var units: [12]u16 = undefined;
                const digits = std.fmt.bufPrint(&buf, "{d}", .{group.count}) catch "";
                for (digits, units[0..digits.len]) |d, *u| u.* = d;
                const w = @ceil(c.fonts.measure(units[0..digits.len], c.fonts.body)) + c.px(4);
                const count: Rect = .{ .x = slot.right() - w, .y = r.y, .w = w, .h = r.h };
                p.text(units[0..digits.len], c.fonts.body, count, c.theme.text_inactive);
                label_right = count.x - c.px(4);
            }
        }
    }

    const label: Rect = .{ .x = label_left, .y = r.y, .w = @max(0, label_right - label_left), .h = r.h };
    var buf: [256]u16 = undefined;
    p.text(upper(&buf, group.label), c.fonts.section, label, if (is_ws and group.shown) c.theme.text_muted else if (is_ws) c.theme.text_inactive else c.theme.text_muted);
}

/// Lucide's plug, centered in `area`. It spans 16 of its 24 units: 11
/// DIPs in this box, about the plus's size. Its prongs land on pixel edges
/// at this size, so a half pixel moves them onto centers.
fn paintPlug(c: *const Chrome, p: *Painter, area: Rect, color: Chrome.Color) void {
    const icon = c.px(16);
    var box = area.center(icon, icon);
    box.x += 0.5;
    c.drawIcon(p, .plug, box, color);
}

/// A small button's background under the mouse.
fn paintIconButton(c: *const Chrome, p: *Painter, r: Rect, hit: Hit) void {
    if (!c.hover.eql(hit)) return;
    p.fillRounded(r, c.px(4), switch (c.buttonState(hit)) {
        .pressed => c.theme.button_pressed,
        else => c.theme.button_hover,
    });
}

/// A host with no tabs, which can be dropped from the list.
fn forgettable(group: Chrome.View.Group) bool {
    return (group.kind == .connected or group.kind == .disconnected) and group.tabs == 0;
}

/// `text` in capitals, as section headers are, cut to fit `buf`. Only
/// ASCII letters change: labels are host names.
fn upper(buf: []u16, text: []const u16) []const u16 {
    const n = @min(buf.len, text.len);
    for (buf[0..n], text[0..n]) |*out, unit| {
        out.* = if (unit >= 'a' and unit <= 'z') unit - ('a' - 'A') else unit;
    }
    return buf[0..n];
}

fn paintTab(c: *const Chrome, p: *Painter, r: Rect, i: usize, tab: Chrome.View.Tab, active: bool, step: u32) void {
    const close_hovered = c.hover.eql(.{ .close_tab = i });
    const hovered = close_hovered or c.hover.eql(.{ .tab = i }) or c.hover.eql(.{ .fold = i });
    // The active tab is told by its brighter text, and its focused pane's
    // highlight; folded, it keeps the highlight itself.
    if (hovered or (active and tab.folded)) p.fillRounded(r, c.px(6), c.theme.row_hover);

    paintFold(c, p, .{ .x = r.x, .y = r.y, .w = c.px(fold_width), .h = r.h }, tab.folded, if (c.hover.eql(.{ .fold = i })) c.theme.text_strong else c.theme.text_muted);
    // Lucide's panels-top-left spans 18 of its 24 units: 12 DIPs here.
    const icon = c.px(16);
    const icon_color = if (active) c.theme.text_strong else c.theme.text_muted;
    c.drawIcon(p, .panels_top_left, .{ .x = r.x + c.px(fold_width), .y = r.y + @round((r.h - icon) / 2), .w = icon, .h = icon }, icon_color);

    const close = rowButton(c, r, 0);
    const text_x = r.x + c.px(fold_width + 24);
    // Folded, its panes' most pressing status stands in for theirs.
    const folded_status: ?Chrome.View.TabPane = if (tab.folded) mostPressing(tab.panes) else null;
    const text_right = if (hovered or tab.activity or folded_status != null) close.x - c.px(4) else r.right() - c.px(8);
    const text_rect: Rect = .{ .x = text_x, .y = r.y, .w = @max(0, text_right - text_x), .h = r.h };
    if (active) {
        p.text(tab.title, c.fonts.body_strong, text_rect, c.theme.text_strong);
    } else {
        p.text(tab.title, c.fonts.body, text_rect, c.theme.text_muted);
    }

    if (!hovered) if (folded_status) |pane| return paintStatus(c, p, close, pane, step);
    if (hovered) {
        if (close_hovered) p.fillRounded(close, c.px(4), switch (c.buttonState(.{ .close_tab = i })) {
            .pressed => c.theme.button_pressed,
            else => c.theme.button_hover,
        });
        // Lucide's x spans 12 of its 24 units: 8 DIPs in this box.
        const g = c.px(16);
        c.drawIcon(p, .x, close.center(g, g), if (close_hovered) c.theme.text_strong else c.theme.text_muted);
    } else if (tab.activity) {
        p.dot(close.x + close.w / 2, close.y + close.h / 2, c.px(3), c.theme.accent);
    }
}

/// The pane with the most pressing status: waiting on the user, then
/// failed, working, and done. Null if none has a status worth showing.
fn mostPressing(panes: []const Chrome.View.TabPane) ?Chrome.View.TabPane {
    var best: ?Chrome.View.TabPane = null;
    var best_rank: u8 = 0;
    for (panes) |pane| {
        const r: u8 = switch (pane.status orelse continue) {
            .idle => continue,
            .done => 1,
            .working => 2,
            .failed => 3,
            .blocked => 4,
        };
        if (r > best_rank) {
            best = pane;
            best_rank = r;
        }
    }
    return best;
}

/// A fold arrow, centered in `area`: down while open, right while folded.
fn paintFold(c: *const Chrome, p: *Painter, area: Rect, folded: bool, color: Chrome.Color) void {
    const h = c.px(3);
    const cx = @round(area.x + area.w / 2);
    const cy = @round(area.y + area.h / 2);
    const w = c.stroke();
    if (folded) {
        p.line(cx - h / 2, cy - h, cx + h / 2, cy, w, color);
        p.line(cx + h / 2, cy, cx - h / 2, cy + h, w, color);
    } else {
        p.line(cx - h, cy - h / 2, cx, cy + h / 2, w, color);
        p.line(cx, cy + h / 2, cx + h, cy - h / 2, w, color);
    }
}

/// Pane `j` of tab `i`, under its tab with a guide line down from it, and
/// what its programs report at its right.
fn paintPane(c: *const Chrome, p: *Painter, r: Rect, i: usize, j: usize, view: *const Chrome.View) void {
    const tab = view.tabs[i];
    const pane = tab.panes[j];
    const hit: Hit = .{ .tab_pane = .{ .tab = i, .pane = j } };
    const focused = i == view.active and j == tab.focus;
    // The highlight starts past the guide, which runs on unbroken.
    if (focused or c.hover.eql(hit)) {
        const inset = c.px(fold_width);
        p.fillRounded(.{ .x = r.x + inset, .y = r.y, .w = r.w - inset, .h = r.h }, c.px(6), c.theme.row_hover);
    }
    const guide_x = Chrome.crisp(r.x + c.px(fold_width / 2) + c.px(1), c.stroke());
    const last = j + 1 == tab.panes.len;
    // Up through the gap above, from the row there.
    p.line(guide_x, r.y - c.px(row_gap), guide_x, if (last) r.y + r.h / 2 else r.bottom(), c.stroke(), c.theme.outline);

    const icon = c.px(14);
    const x = r.x + c.px(pane_indent);
    c.drawIcon(p, .terminal, .{ .x = x, .y = r.y + @round((r.h - icon) / 2), .w = icon, .h = icon }, if (focused) c.theme.accent else c.theme.text_muted);
    const slot = rowButton(c, r, 0);
    const text_x = x + c.px(22);
    const text_rect: Rect = .{ .x = text_x, .y = r.y, .w = @max(0, slot.x - c.px(4) - text_x), .h = r.h };
    p.text(pane.title, c.fonts.body, text_rect, if (focused) c.theme.text_strong else c.theme.text_muted);
    paintStatus(c, p, slot, pane, view.spinner);
}

/// What a pane's programs report, in the square `slot`: a turning arc
/// while working, a glowing dot while waiting on the user, a check when
/// done, a cross when failed. Unreported output while it wasn't shown is
/// a small dot.
fn paintStatus(c: *const Chrome, p: *Painter, slot: Rect, pane: Chrome.View.TabPane, step: u32) void {
    const cx = slot.x + slot.w / 2;
    const cy = slot.y + slot.h / 2;
    const status = pane.status orelse {
        if (pane.activity) p.dot(cx, cy, c.px(3), c.theme.accent);
        return;
    };
    switch (status) {
        .idle => {},
        .working => {
            const turn = @as(f32, @floatFromInt(step % 12)) * (std.math.tau / 12.0);
            p.arc(cx, cy, c.px(5), turn, std.math.tau * 0.72, c.px(1.5), c.theme.accent);
        },
        .blocked => {
            const w = c.theme.warning;
            p.dot(cx, cy, c.px(6), .{ w[0], w[1], w[2], 0.22 });
            p.dot(cx, cy, c.px(3.5), w);
        },
        // Lucide's check and x span 16 and 12 of their 24 units.
        .done => c.drawIcon(p, .check, slot.center(c.px(15), c.px(15)), c.theme.success),
        .failed => c.drawIcon(p, .x, slot.center(c.px(16), c.px(16)), c.theme.danger),
    }
}

/// Button `n` of a row or header, counted from the right: 0 is at the
/// right edge, each further one a button's width left.
fn rowButton(c: *const Chrome, row: Rect, n: usize) Rect {
    const size = c.px(button_size);
    return .{
        .x = row.right() - c.px(5) - size - @as(f32, @floatFromInt(n)) * (size + c.px(button_gap)),
        .y = row.y + @round((row.h - size) / 2),
        .w = size,
        .h = size,
    };
}

/// The list's parts from the top: each group's header, then its tabs'
/// rows, each followed by its panes' unless folded; after the last
/// workspace, the row that makes one.
const Walk = struct {
    groups: []const Chrome.View.Group,
    tabs: []const Chrome.View.Tab,
    x: f32,
    w: f32,
    /// The top of the next part.
    y: f32,
    header_h: f32,
    row_h: f32,
    pane_h: f32,
    new_ws_h: f32,
    row_gap: f32,
    section_gap: f32,
    group: usize = 0,
    /// Tabs given out of the current group, after its header.
    in_group: usize = 0,
    header_done: bool = false,
    tab: usize = 0,
    /// The next pane of the last tab given out, while it's open.
    pane: ?usize = null,
    /// The new workspace row was given out.
    new_ws_done: bool = false,

    const Item = struct {
        part: union(enum) {
            header: usize,
            tab: usize,
            pane: struct { tab: usize, pane: usize },
            new_workspace,
        },
        rect: Rect,
    };

    fn init(c: *const Chrome, l: *const Chrome.Layout, view: *const Chrome.View) Walk {
        return .{
            .groups = view.groups,
            .tabs = view.tabs,
            .x = l.list.x + c.px(pad_x),
            .w = @max(0, l.list.w - 2 * c.px(pad_x)),
            .y = l.list.y + c.px(pad_top),
            .header_h = c.px(header_height),
            .row_h = c.px(row_height),
            .pane_h = c.px(pane_height),
            .new_ws_h = c.px(new_workspace_height),
            .row_gap = c.px(row_gap),
            .section_gap = c.px(section_gap),
        };
    }

    fn next(self: *Walk) ?Item {
        if (self.pane) |j| {
            const t = self.tab - 1;
            if (t < self.tabs.len and j < self.tabs[t].panes.len) {
                self.pane = j + 1;
                // Each pane's row is set off from the row above it.
                self.y += self.row_gap;
                return .{ .part = .{ .pane = .{ .tab = t, .pane = j } }, .rect = self.take(self.pane_h, 0) };
            }
            self.pane = null;
            self.y += self.row_gap;
        }
        while (self.group < self.groups.len) {
            // After the last workspace's tabs, before the hosts.
            if (!self.new_ws_done and self.group > 0 and self.groups[self.group - 1].kind == .workspace and self.groups[self.group].kind != .workspace) {
                self.new_ws_done = true;
                return .{ .part = .new_workspace, .rect = self.take(self.new_ws_h, self.section_gap) };
            }
            if (!self.header_done) {
                self.header_done = true;
                return .{ .part = .{ .header = self.group }, .rect = self.take(self.header_h, 0) };
            }
            if (self.in_group < self.groups[self.group].tabs) {
                self.in_group += 1;
                self.tab += 1;
                const t = self.tab - 1;
                const open = t < self.tabs.len and !self.tabs[t].folded;
                if (open) self.pane = 0;
                return .{ .part = .{ .tab = t }, .rect = self.take(self.row_h, if (open) 0 else self.row_gap) };
            }
            self.group += 1;
            self.in_group = 0;
            self.header_done = false;
            self.y += self.section_gap;
        }
        if (!self.new_ws_done and self.groups.len > 0 and self.groups[self.groups.len - 1].kind == .workspace) {
            self.new_ws_done = true;
            return .{ .part = .new_workspace, .rect = self.take(self.new_ws_h, 0) };
        }
        return null;
    }

    /// The next `h` of the list, with `gap` after it.
    fn take(self: *Walk, h: f32, gap: f32) Rect {
        const r: Rect = .{ .x = self.x, .y = self.y, .w = self.w, .h = h };
        self.y += h + gap;
        return r;
    }
};

test "groups, rows, and their buttons" {
    const c: Chrome = .{ .scale = 1, .fonts = undefined, .theme = undefined };
    const view: Chrome.View = .{
        .groups = &.{
            .{ .label = &.{}, .tabs = 0, .kind = .workspace, .shown = false, .count = 3 },
            .{ .label = &.{}, .tabs = 2, .kind = .workspace },
            .{ .label = &.{}, .tabs = 0, .kind = .disconnected },
        },
        .tabs = &.{
            .{ .title = &.{}, .activity = false, .panes = &.{.{ .title = &.{} }}, .folded = true },
            .{ .title = &.{}, .activity = false, .panes = &.{ .{ .title = &.{} }, .{ .title = &.{}, .status = .working } } },
        },
        .active = 0,
        .focused = true,
        .maximized = false,
        .terminal_bg = .{ 0, 0, 0, 1 },
    };
    const l = c.layout(1000, 600);
    var walk: Walk = .init(&c, &l, &view);
    const hidden = walk.next().?;
    try std.testing.expectEqual(@as(usize, 0), hidden.part.header);
    const shown = walk.next().?;
    try std.testing.expectEqual(@as(usize, 1), shown.part.header);
    try std.testing.expect(shown.rect.y > hidden.rect.bottom());
    // The first tab is folded; the second lists its two panes.
    try std.testing.expectEqual(@as(usize, 0), walk.next().?.part.tab);
    const second = walk.next().?.rect;
    const pane = walk.next().?;
    try std.testing.expectEqual(@as(usize, 1), pane.part.pane.tab);
    try std.testing.expectEqual(@as(usize, 0), pane.part.pane.pane);
    try std.testing.expectEqual(second.bottom() + row_gap, pane.rect.y);
    try std.testing.expectEqual(@as(usize, 1), walk.next().?.part.pane.pane);
    // Then the row that makes a workspace, then the host.
    const new_ws = walk.next().?;
    try std.testing.expect(new_ws.part == .new_workspace);
    const forgotten = walk.next().?;
    try std.testing.expectEqual(@as(usize, 2), forgotten.part.header);
    try std.testing.expect(forgotten.rect.y > new_ws.rect.bottom());
    try std.testing.expect(walk.next() == null);
    const connect = connectRect(&c, &l);
    try std.testing.expectEqual(l.list.bottom() - pad_bottom, connect.bottom());
    try std.testing.expectEqual(Hit.connect, c.hitTest(&l, &view, connect.x + 1, connect.y + 1));
    try std.testing.expectEqual(Hit.new_workspace, c.hitTest(&l, &view, new_ws.rect.x + 10, new_ws.rect.y + 2));

    try std.testing.expectEqual(Hit{ .fold = 1 }, c.hitTest(&l, &view, second.x + 2, second.y + 2));
    try std.testing.expectEqual(Hit{ .tab = 1 }, c.hitTest(&l, &view, second.x + fold_width + 10, second.y + 2));
    try std.testing.expectEqual(Hit{ .tab_pane = .{ .tab = 1, .pane = 0 } }, c.hitTest(&l, &view, pane.rect.x + 40, pane.rect.y + 2));
    const close = rowButton(&c, second, 0);
    try std.testing.expectEqual(Hit{ .close_tab = 1 }, c.hitTest(&l, &view, close.x + 1, close.y + 1));
    const plus = rowButton(&c, forgotten.rect, 0);
    try std.testing.expectEqual(Hit{ .new_tab = 2 }, c.hitTest(&l, &view, plus.x + 1, plus.y + 1));
    try std.testing.expectEqual(Hit{ .header = 2 }, c.hitTest(&l, &view, forgotten.rect.x + 2, forgotten.rect.y + 2));
    // Only a host with no tabs can be forgotten.
    const forget = rowButton(&c, forgotten.rect, 1);
    try std.testing.expectEqual(Hit{ .forget_host = 2 }, c.hitTest(&l, &view, forget.x + 1, forget.y + 1));
    // A workspace's header has its buttons; a hidden one has no hide
    // button.
    try std.testing.expectEqual(Hit{ .header = 1 }, c.hitTest(&l, &view, shown.rect.x + 2, shown.rect.y + 2));
    try std.testing.expectEqual(Hit{ .new_tab = 1 }, c.hitTest(&l, &view, rowButton(&c, shown.rect, 0).x + 1, shown.rect.y + 5));
    try std.testing.expectEqual(Hit{ .kill_workspace = 1 }, c.hitTest(&l, &view, rowButton(&c, shown.rect, 1).x + 1, shown.rect.y + 5));
    try std.testing.expectEqual(Hit{ .rename_workspace = 1 }, c.hitTest(&l, &view, rowButton(&c, shown.rect, 2).x + 1, shown.rect.y + 5));
    try std.testing.expectEqual(Hit{ .detach_workspace = 1 }, c.hitTest(&l, &view, rowButton(&c, shown.rect, 3).x + 1, shown.rect.y + 5));
    try std.testing.expectEqual(Hit{ .header = 0 }, c.hitTest(&l, &view, rowButton(&c, hidden.rect, 3).x + 1, hidden.rect.y + 5));
    // Between groups.
    try std.testing.expectEqual(Hit.none, c.hitTest(&l, &view, second.x + 2, forgotten.rect.y - 5));
}

test "a workspace being renamed is all field" {
    const c: Chrome = .{ .scale = 1, .fonts = undefined, .theme = undefined };
    const field: Chrome.TextField = .{};
    const view: Chrome.View = .{
        .groups = &.{.{ .label = &.{}, .tabs = 0, .kind = .workspace }},
        .tabs = &.{},
        .active = 0,
        .rename = .{ .group = 0, .field = &field },
        .focused = true,
        .maximized = false,
        .terminal_bg = .{ 0, 0, 0, 1 },
    };
    const l = c.layout(1000, 600);
    var walk: Walk = .init(&c, &l, &view);
    const header = walk.next().?.rect;
    try std.testing.expect(walk.next().?.part == .new_workspace);
    try std.testing.expectEqual(Hit{ .rename_field = 0 }, c.hitTest(&l, &view, header.x + 2, header.y + 2));
    try std.testing.expectEqual(Hit{ .rename_field = 0 }, c.hitTest(&l, &view, rowButton(&c, header, 0).x + 1, header.y + 5));
}
