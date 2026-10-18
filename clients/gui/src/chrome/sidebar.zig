//! Tabs in a sidebar under the title bar, as a tree: a section for Local
//! and one for each remembered SSH host; under Local a row per
//! workspace, under a workspace its tabs, under a tab its panes. A
//! workspace's row folds its tabs away (the window lets go of it; the
//! daemon keeps it running) and back, and has buttons to open a tab in
//! it, rename it, hide it, and kill it; Local's header has one that
//! makes a workspace. A host's header has a button that opens another
//! tab there, connecting first if the host isn't connected, and its tabs
//! sit right under it; a host with no tabs can be forgotten. A "Connect"
//! button at the bottom turns into a field for a host to connect to.
//!
//! Rows under a row are joined to it by a guide: a trunk down from the
//! parent's fold arrow with a branch to each child, turning into the
//! last one with a rounded corner. Each tab's row folds open to its
//! panes, each a row with what its programs report doing (OSC 7501):
//! working, waiting on the user, done, or failed.

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
/// A workspace's row.
const workspace_height = 28;
const row_height = 30;
const row_gap = 2;
/// A pane's row, under its tab's.
const pane_height = 28;
/// How far each level under a row is set in from it: past the row's
/// fold arrow, with room for the guide's branch. The rows right under a
/// section header are flush with it.
const indent = 22;
/// The fold arrow's column at a row's left. The guide's trunk runs down
/// its middle.
const fold_width = 18;
/// A pane row's icon, in from its left.
const pane_pad = 6;
/// The guide's thickness, the radius of its corner into the last child,
/// and how short of the child's row its branch stops.
const guide_width = 2;
const guide_radius = 6;
const guide_gap = 4;
/// Rows' close buttons and headers' buttons, in columns from the right.
const button_size = 20;
const button_gap = 2;
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
            .header => |g| if (on_button)
                .{ .new_tab = g }
            else if (forgettable(view.groups[g]) and rowButton(c, item.rect, 1).contains(x, y))
                .{ .forget_host = g }
            else
                .{ .header = g },
            .workspace => |w| ws: {
                if (renaming(view, w)) break :ws .{ .rename_field = w };
                if (on_button) break :ws .{ .workspace_tab = w };
                if (rowButton(c, item.rect, 1).contains(x, y)) break :ws .{ .kill_workspace = w };
                if (rowButton(c, item.rect, 2).contains(x, y)) break :ws .{ .rename_workspace = w };
                if (view.workspaces[w].shown and rowButton(c, item.rect, 3).contains(x, y)) break :ws .{ .detach_workspace = w };
                break :ws .{ .workspace = w };
            },
            .tab => |t| if (on_button)
                .{ .close_tab = t.tab }
            else if (x < item.rect.x + c.px(fold_width))
                .{ .fold = t.tab }
            else
                .{ .tab = t.tab },
            .pane => |pn| .{ .tab_pane = .{ .tab = pn.tab, .pane = pn.pane } },
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
                .forget_host => |h| if (h == g) return rowButton(c, item.rect, 1),
                else => {},
            },
            .workspace => |w| switch (hit) {
                .workspace_tab => |h| if (h == w) return rowButton(c, item.rect, 0),
                .kill_workspace => |h| if (h == w) return rowButton(c, item.rect, 1),
                .rename_workspace => |h| if (h == w) return rowButton(c, item.rect, 2),
                .detach_workspace => |h| if (h == w) return rowButton(c, item.rect, 3),
                else => {},
            },
            .tab => |t| if (hit == .close_tab and hit.close_tab == t.tab) return rowButton(c, item.rect, 0),
            .pane => {},
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
    // Where each level's trunk has got to: the bottom of the row it
    // hangs from, then the middle of the last child drawn.
    var trunk: [Walk.max_depth + 2]f32 = @splat(0);
    var walk: Walk = .init(c, l, view);
    while (walk.next()) |item| {
        if (item.rect.y >= rows.bottom()) break;
        const r = item.rect;
        if (item.guided) {
            paintGuide(c, p, r, &trunk[item.depth], item.last);
            trunk[item.depth] = r.y + r.h / 2;
        }
        trunk[item.depth + 1] = r.bottom();
        switch (item.part) {
            .header => |g| paintHeader(c, p, r, g, view.groups[g]),
            .workspace => |w| paintWorkspace(c, p, r, w, view),
            .tab => |t| paintTab(c, p, r, t.tab, view.tabs[t.tab], t.tab == view.active, view.spinner),
            .pane => |pn| paintPane(c, p, r, pn.tab, pn.pane, view),
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

/// The guide into a child row `r`: the trunk down from `from` (where it
/// left off above) in the parent's fold column, and a branch toward the
/// row, stopping short of it. Into the last child the trunk turns with a
/// rounded corner.
fn paintGuide(c: *const Chrome, p: *Painter, r: Rect, from: *const f32, last: bool) void {
    const w = c.px(guide_width);
    const color = c.theme.outline;
    const x = Chrome.crisp(r.x - c.px(indent) + c.px(fold_width) / 2, w);
    const cy = Chrome.crisp(r.y + r.h / 2, w);
    const radius = c.px(guide_radius);
    const end = r.x - c.px(guide_gap);
    if (last) {
        p.elbow(x, from.*, cy, radius, end, w, color);
    } else {
        p.line(x, from.*, x, cy, w, color);
        p.line(x, cy, end, cy, w, color);
    }
}

/// Whether workspace `w`'s name is being edited.
fn renaming(view: *const Chrome.View, w: usize) bool {
    return if (view.rename) |r| r.workspace == w else false;
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

/// A text field in `r`: its text scrolled to keep the caret in view, with
/// the selection behind it, and `placeholder` while empty.
fn paintField(c: *const Chrome, p: *Painter, r: Rect, field: *const Chrome.TextField, placeholder: []const u16, caret: bool) void {
    const radius = c.px(6);
    c.fillBordered(p, r, radius, c.theme.surface, c.theme.accent);

    const inner = r.inset(c.px(10), 0);
    if (field.len == 0) p.text(placeholder, c.fonts.body, inner, c.theme.text_inactive);
    c.paintEditText(p, inner, field, .{ .caret = caret });
}

/// Section `g`'s header: its name in capitals, with a button at the
/// right that makes a workspace under Local, or opens a tab on a host
/// (a plug while it isn't connected); a host with no tabs gets one to
/// forget it while the mouse is over the header.
fn paintHeader(c: *const Chrome, p: *Painter, r: Rect, g: usize, group: Chrome.View.Group) void {
    const button = rowButton(c, r, 0);
    const hit: Hit = .{ .new_tab = g };
    const hovered = c.hover.eql(hit);
    paintIconButton(c, p, button, hit);
    const color = if (hovered) c.theme.text_strong else c.theme.text_muted;
    if (group.kind == .disconnected) {
        paintPlug(c, p, button, color);
    } else {
        // Lucide's plus spans 14 of its 24 units: 10 DIPs in this box,
        // whose odd size centers the lines on pixels.
        const icon = c.px(17);
        c.drawIcon(p, .plus, button.center(icon, icon), color);
    }

    var label_right = button.x - c.px(4);
    const show_forget = forgettable(group) and switch (c.hover) {
        .header, .new_tab, .forget_host => |h| h == g,
        else => false,
    };
    if (show_forget) {
        const forget = rowButton(c, r, 1);
        const forget_hit: Hit = .{ .forget_host = g };
        paintIconButton(c, p, forget, forget_hit);
        // Lucide's x spans 12 of its 24 units: 8 DIPs in this box.
        const icon = c.px(16);
        c.drawIcon(p, .x, forget.center(icon, icon), if (c.hover.eql(forget_hit)) c.theme.text_strong else c.theme.text_muted);
        label_right = forget.x - c.px(4);
    }

    const label_x = r.x + c.px(2);
    const label: Rect = .{ .x = label_x, .y = r.y, .w = @max(0, label_right - label_x), .h = r.h };
    var buf: [256]u16 = undefined;
    p.text(upper(&buf, group.label), c.fonts.section, label, c.theme.text_muted);
}

/// Workspace `w`'s row: a fold arrow (its tabs are listed while shown),
/// its name, and buttons at the right: one to open a tab in it always;
/// while the mouse is over the row, kill, rename, and (while shown)
/// hide. At rest a hidden workspace shows how many tabs it has, and one
/// other windows show, an eye.
fn paintWorkspace(c: *const Chrome, p: *Painter, r: Rect, w: usize, view: *const Chrome.View) void {
    const ws = view.workspaces[w];
    const label_left = r.x + c.px(fold_width) + c.px(4);
    if (view.rename) |rename| if (rename.workspace == w) {
        paintFold(c, p, .{ .x = r.x, .y = r.y, .w = c.px(fold_width), .h = r.h }, !ws.shown, c.theme.text_muted);
        paintField(c, p, .{ .x = r.x + c.px(fold_width), .y = r.y, .w = @max(0, r.right() - r.x - c.px(fold_width)), .h = r.h }, rename.field, L("Workspace name"), view.focused and view.caret_visible);
        return;
    };

    const hovered = switch (c.hover) {
        .workspace, .workspace_tab, .kill_workspace, .rename_workspace, .detach_workspace => |h| h == w,
        else => false,
    };
    if (c.hover.eql(.{ .workspace = w })) p.fillRounded(r, c.px(6), c.theme.row_hover);
    const text = if (hovered) c.theme.text_strong else if (ws.shown) c.theme.text_muted else c.theme.text_inactive;
    paintFold(c, p, .{ .x = r.x, .y = r.y, .w = c.px(fold_width), .h = r.h }, !ws.shown, text);

    const button = rowButton(c, r, 0);
    const hit: Hit = .{ .workspace_tab = w };
    paintIconButton(c, p, button, hit);
    const icon = c.px(17);
    c.drawIcon(p, .plus, button.center(icon, icon), if (c.hover.eql(hit)) c.theme.text_strong else c.theme.text_muted);
    var label_right = button.x - c.px(4);
    if (hovered) {
        // Kill, rename, and hide, from the right. Each icon spans 16 to
        // 18 of its 24 units: about 11 DIPs in these boxes.
        const kill = rowButton(c, r, 1);
        const kill_hit: Hit = .{ .kill_workspace = w };
        paintIconButton(c, p, kill, kill_hit);
        c.drawIcon(p, .trash, kill.center(c.px(16), c.px(16)), if (c.hover.eql(kill_hit)) c.theme.danger else c.theme.text_muted);
        const rename = rowButton(c, r, 2);
        const rename_hit: Hit = .{ .rename_workspace = w };
        paintIconButton(c, p, rename, rename_hit);
        c.drawIcon(p, .pencil, rename.center(c.px(16), c.px(16)), if (c.hover.eql(rename_hit)) c.theme.text_strong else c.theme.text_muted);
        label_right = rename.x - c.px(4);
        if (ws.shown) {
            const hide = rowButton(c, r, 3);
            const hide_hit: Hit = .{ .detach_workspace = w };
            paintIconButton(c, p, hide, hide_hit);
            c.drawIcon(p, .eye_off, hide.center(c.px(17), c.px(17)), if (c.hover.eql(hide_hit)) c.theme.text_strong else c.theme.text_muted);
            label_right = hide.x - c.px(4);
        }
    } else {
        var slot = rowButton(c, r, 1);
        if (ws.others > 0) {
            c.drawIcon(p, .eye, slot.center(c.px(17), c.px(17)), c.theme.text_muted);
            label_right = slot.x - c.px(4);
            slot = rowButton(c, r, 2);
        }
        if (!ws.shown and ws.count > 0) {
            var buf: [12]u8 = undefined;
            var units: [12]u16 = undefined;
            const digits = std.fmt.bufPrint(&buf, "{d}", .{ws.count}) catch "";
            for (digits, units[0..digits.len]) |d, *u| u.* = d;
            const tw = @ceil(c.fonts.measure(units[0..digits.len], c.fonts.body)) + c.px(4);
            const count: Rect = .{ .x = slot.right() - tw, .y = r.y, .w = tw, .h = r.h };
            p.text(units[0..digits.len], c.fonts.body, count, c.theme.text_inactive);
            label_right = count.x - c.px(4);
        }
    }

    const label: Rect = .{ .x = label_left, .y = r.y, .w = @max(0, label_right - label_left), .h = r.h };
    p.text(ws.label, c.fonts.body_strong, label, text);
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
    return group.kind != .local and group.tabs == 0;
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

/// Pane `j` of tab `i`, under its tab, and what its programs report at
/// its right.
fn paintPane(c: *const Chrome, p: *Painter, r: Rect, i: usize, j: usize, view: *const Chrome.View) void {
    const tab = view.tabs[i];
    const pane = tab.panes[j];
    const hit: Hit = .{ .tab_pane = .{ .tab = i, .pane = j } };
    const focused = i == view.active and j == tab.focus;
    if (focused or c.hover.eql(hit)) p.fillRounded(r, c.px(6), c.theme.row_hover);

    const icon = c.px(14);
    const x = r.x + c.px(pane_pad);
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

/// The list's parts from the top. Local's header, then its workspaces,
/// each followed by its tabs while shown; then Local's tabs in no
/// workspace; then each host's header and tabs. A tab's row is followed
/// by its panes' unless folded. Each part's rect is set in by its depth.
const Walk = struct {
    groups: []const Chrome.View.Group,
    workspaces: []const Chrome.View.Workspace,
    tabs: []const Chrome.View.Tab,
    x: f32,
    w: f32,
    /// The top of the next part.
    y: f32,
    header_h: f32,
    workspace_h: f32,
    row_h: f32,
    pane_h: f32,
    row_gap: f32,
    section_gap: f32,
    indent: f32,
    group: usize = 0,
    header_done: bool = false,
    /// Local's workspaces given out, and the tabs given out of the
    /// current one (or the current group, after them).
    workspace: usize = 0,
    in_parent: usize = 0,
    /// The parent's tab count, once its row is out.
    parent_tabs: usize = 0,
    /// The parent is a workspace row, so its tabs get guides.
    under_workspace: bool = false,
    /// Local's own tabs, after its workspaces, were given out.
    local_tabs_done: bool = false,
    tab: usize = 0,
    /// The next pane of the last tab given out, while it's open.
    pane: ?usize = null,
    pane_depth: u8 = 0,

    /// Panes under tabs under workspaces under Local.
    const max_depth = 3;

    const Item = struct {
        part: union(enum) {
            header: usize,
            workspace: usize,
            tab: struct { tab: usize },
            pane: struct { tab: usize, pane: usize },
        },
        rect: Rect,
        /// How many levels in from a section header.
        depth: u8,
        /// It hangs from a row (a workspace's or a tab's), joined to it
        /// by a guide; `last` says it's that row's last child.
        guided: bool = false,
        last: bool = false,
    };

    fn init(c: *const Chrome, l: *const Chrome.Layout, view: *const Chrome.View) Walk {
        return .{
            .groups = view.groups,
            .workspaces = view.workspaces,
            .tabs = view.tabs,
            .x = l.list.x + c.px(pad_x),
            .w = @max(0, l.list.w - 2 * c.px(pad_x)),
            .y = l.list.y + c.px(pad_top),
            .header_h = c.px(header_height),
            .workspace_h = c.px(workspace_height),
            .row_h = c.px(row_height),
            .pane_h = c.px(pane_height),
            .row_gap = c.px(row_gap),
            .section_gap = c.px(section_gap),
            .indent = c.px(indent),
        };
    }

    fn next(self: *Walk) ?Item {
        if (self.pane) |j| {
            const t = self.tab - 1;
            const n = if (t < self.tabs.len) self.tabs[t].panes.len else 0;
            if (j < n) {
                self.pane = j + 1;
                // Each pane's row is set off from the row above it.
                self.y += self.row_gap;
                return .{
                    .part = .{ .pane = .{ .tab = t, .pane = j } },
                    .rect = self.take(self.pane_h, 0, self.pane_depth),
                    .depth = self.pane_depth,
                    .guided = true,
                    .last = j + 1 == n,
                };
            }
            self.pane = null;
            self.y += self.row_gap;
        }
        while (self.group < self.groups.len) {
            if (!self.header_done) {
                self.header_done = true;
                self.in_parent = 0;
                self.parent_tabs = 0;
                self.under_workspace = false;
                if (self.group != 0) self.parent_tabs = self.groups[self.group].tabs;
                return .{ .part = .{ .header = self.group }, .rect = self.take(self.header_h, 0, 0), .depth = 0 };
            }
            if (self.in_parent < self.parent_tabs) {
                self.in_parent += 1;
                self.tab += 1;
                const t = self.tab - 1;
                const open = t < self.tabs.len and !self.tabs[t].folded;
                const depth: u8 = if (self.under_workspace) 2 else 1;
                if (open) {
                    self.pane = 0;
                    self.pane_depth = depth + 1;
                }
                return .{
                    .part = .{ .tab = .{ .tab = t } },
                    .rect = self.take(self.row_h, if (open) 0 else self.row_gap, depth),
                    .depth = depth,
                    .guided = self.under_workspace,
                    .last = self.in_parent == self.parent_tabs,
                };
            }
            // Local: its next workspace, then its own tabs.
            if (self.group == 0 and self.workspace < self.workspaces.len) {
                const w = self.workspace;
                self.workspace += 1;
                const ws = self.workspaces[w];
                self.in_parent = 0;
                self.parent_tabs = if (ws.shown) ws.tabs else 0;
                self.under_workspace = true;
                return .{ .part = .{ .workspace = w }, .rect = self.take(self.workspace_h, self.row_gap, 1), .depth = 1 };
            }
            if (self.group == 0 and !self.local_tabs_done) {
                self.local_tabs_done = true;
                self.under_workspace = false;
                self.in_parent = 0;
                self.parent_tabs = self.groups[0].tabs;
                continue;
            }
            self.group += 1;
            self.header_done = false;
            self.y += self.section_gap;
        }
        return null;
    }

    /// The next `h` of the list at `depth`, with `gap` after it. Depth 1
    /// is flush with its section header; each level under that is set
    /// in.
    fn take(self: *Walk, h: f32, gap: f32, depth: u8) Rect {
        const in = @as(f32, @floatFromInt(depth -| 1)) * self.indent;
        const r: Rect = .{ .x = self.x + in, .y = self.y, .w = @max(0, self.w - in), .h = h };
        self.y += h + gap;
        return r;
    }
};

test "sections, workspaces, rows, and their buttons" {
    const c: Chrome = .{ .scale = 1, .fonts = undefined, .theme = undefined };
    const view: Chrome.View = .{
        .groups = &.{
            .{ .label = &.{}, .tabs = 0, .kind = .local },
            .{ .label = &.{}, .tabs = 1, .kind = .connected },
            .{ .label = &.{}, .tabs = 0, .kind = .disconnected },
        },
        .workspaces = &.{
            .{ .label = &.{}, .tabs = 0, .shown = false, .count = 3 },
            .{ .label = &.{}, .tabs = 2, .shown = true },
        },
        .tabs = &.{
            .{ .title = &.{}, .activity = false, .panes = &.{.{ .title = &.{} }}, .folded = true },
            .{ .title = &.{}, .activity = false, .panes = &.{ .{ .title = &.{} }, .{ .title = &.{}, .status = .working } } },
            .{ .title = &.{}, .activity = false, .panes = &.{.{ .title = &.{} }} },
        },
        .active = 0,
        .focused = true,
        .maximized = false,
        .terminal_bg = .{ 0, 0, 0, 1 },
    };
    const l = c.layout(1000, 600);
    var walk: Walk = .init(&c, &l, &view);
    const local = walk.next().?;
    try std.testing.expectEqual(@as(usize, 0), local.part.header);
    try std.testing.expectEqual(@as(u8, 0), local.depth);
    const hidden = walk.next().?;
    try std.testing.expectEqual(@as(usize, 0), hidden.part.workspace);
    try std.testing.expectEqual(local.rect.x, hidden.rect.x);
    const shown = walk.next().?;
    try std.testing.expectEqual(@as(usize, 1), shown.part.workspace);
    // The shown workspace's tabs, set in again and guided; the first is
    // folded, the second lists its two panes, deeper still.
    const first = walk.next().?;
    try std.testing.expectEqual(@as(usize, 0), first.part.tab.tab);
    try std.testing.expectEqual(@as(u8, 2), first.depth);
    try std.testing.expectEqual(shown.rect.x + indent, first.rect.x);
    try std.testing.expect(first.guided and !first.last);
    const second = walk.next().?;
    try std.testing.expectEqual(@as(usize, 1), second.part.tab.tab);
    try std.testing.expect(second.guided and second.last);
    const pane = walk.next().?;
    try std.testing.expectEqual(@as(usize, 1), pane.part.pane.tab);
    try std.testing.expectEqual(@as(usize, 0), pane.part.pane.pane);
    try std.testing.expectEqual(@as(u8, 3), pane.depth);
    try std.testing.expectEqual(second.rect.x + indent, pane.rect.x);
    try std.testing.expectEqual(second.rect.bottom() + row_gap, pane.rect.y);
    try std.testing.expect(pane.guided and !pane.last);
    const pane2 = walk.next().?;
    try std.testing.expectEqual(@as(usize, 1), pane2.part.pane.pane);
    try std.testing.expect(pane2.last);
    // The host's header, then its tab right under it, unguided.
    const host = walk.next().?;
    try std.testing.expectEqual(@as(usize, 1), host.part.header);
    try std.testing.expect(host.rect.y > pane2.rect.bottom());
    const host_tab = walk.next().?;
    try std.testing.expectEqual(@as(usize, 2), host_tab.part.tab.tab);
    try std.testing.expectEqual(@as(u8, 1), host_tab.depth);
    try std.testing.expect(!host_tab.guided);
    try std.testing.expectEqual(@as(usize, 0), walk.next().?.part.pane.pane);
    const forgotten = walk.next().?;
    try std.testing.expectEqual(@as(usize, 2), forgotten.part.header);
    try std.testing.expect(walk.next() == null);

    const connect = connectRect(&c, &l);
    try std.testing.expectEqual(l.list.bottom() - pad_bottom, connect.bottom());
    try std.testing.expectEqual(Hit.connect, c.hitTest(&l, &view, connect.x + 1, connect.y + 1));
    // Local's button makes a workspace; a host's, a tab.
    try std.testing.expectEqual(Hit{ .new_tab = 0 }, c.hitTest(&l, &view, rowButton(&c, local.rect, 0).x + 1, local.rect.y + 5));
    try std.testing.expectEqual(Hit{ .new_tab = 2 }, c.hitTest(&l, &view, rowButton(&c, forgotten.rect, 0).x + 1, forgotten.rect.y + 5));
    try std.testing.expectEqual(Hit{ .header = 2 }, c.hitTest(&l, &view, forgotten.rect.x + 2, forgotten.rect.y + 2));
    // Only a host with no tabs can be forgotten.
    try std.testing.expectEqual(Hit{ .header = 1 }, c.hitTest(&l, &view, rowButton(&c, host.rect, 1).x + 1, host.rect.y + 5));
    try std.testing.expectEqual(Hit{ .forget_host = 2 }, c.hitTest(&l, &view, rowButton(&c, forgotten.rect, 1).x + 1, forgotten.rect.y + 5));
    // A workspace's row and buttons; a hidden one has no hide button.
    try std.testing.expectEqual(Hit{ .workspace = 1 }, c.hitTest(&l, &view, shown.rect.x + 2, shown.rect.y + 2));
    try std.testing.expectEqual(Hit{ .workspace_tab = 1 }, c.hitTest(&l, &view, rowButton(&c, shown.rect, 0).x + 1, shown.rect.y + 5));
    try std.testing.expectEqual(Hit{ .kill_workspace = 1 }, c.hitTest(&l, &view, rowButton(&c, shown.rect, 1).x + 1, shown.rect.y + 5));
    try std.testing.expectEqual(Hit{ .rename_workspace = 1 }, c.hitTest(&l, &view, rowButton(&c, shown.rect, 2).x + 1, shown.rect.y + 5));
    try std.testing.expectEqual(Hit{ .detach_workspace = 1 }, c.hitTest(&l, &view, rowButton(&c, shown.rect, 3).x + 1, shown.rect.y + 5));
    try std.testing.expectEqual(Hit{ .workspace = 0 }, c.hitTest(&l, &view, rowButton(&c, hidden.rect, 3).x + 1, hidden.rect.y + 5));
    // Tabs and panes.
    try std.testing.expectEqual(Hit{ .fold = 1 }, c.hitTest(&l, &view, second.rect.x + 2, second.rect.y + 2));
    try std.testing.expectEqual(Hit{ .tab = 1 }, c.hitTest(&l, &view, second.rect.x + fold_width + 10, second.rect.y + 2));
    try std.testing.expectEqual(Hit{ .close_tab = 1 }, c.hitTest(&l, &view, rowButton(&c, second.rect, 0).x + 1, second.rect.y + 5));
    try std.testing.expectEqual(Hit{ .tab_pane = .{ .tab = 1, .pane = 0 } }, c.hitTest(&l, &view, pane.rect.x + 40, pane.rect.y + 2));
    // The guide's margin left of a child, and between sections.
    try std.testing.expectEqual(Hit.none, c.hitTest(&l, &view, pane.rect.x - 5, pane.rect.y + 2));
    try std.testing.expectEqual(Hit.none, c.hitTest(&l, &view, second.rect.x + 2, host.rect.y - 5));
}

test "a workspace being renamed is all field" {
    const c: Chrome = .{ .scale = 1, .fonts = undefined, .theme = undefined };
    const field: Chrome.TextField = .{};
    const view: Chrome.View = .{
        .groups = &.{.{ .label = &.{}, .tabs = 0, .kind = .local }},
        .workspaces = &.{.{ .label = &.{}, .tabs = 0, .shown = true }},
        .tabs = &.{},
        .active = 0,
        .rename = .{ .workspace = 0, .field = &field },
        .focused = true,
        .maximized = false,
        .terminal_bg = .{ 0, 0, 0, 1 },
    };
    const l = c.layout(1000, 600);
    var walk: Walk = .init(&c, &l, &view);
    _ = walk.next().?;
    const row = walk.next().?.rect;
    try std.testing.expect(walk.next() == null);
    try std.testing.expectEqual(Hit{ .rename_field = 0 }, c.hitTest(&l, &view, row.x + 2, row.y + 2));
    try std.testing.expectEqual(Hit{ .rename_field = 0 }, c.hitTest(&l, &view, rowButton(&c, row, 0).x + 1, row.y + 5));
}

test "Local's own tabs come after its workspaces" {
    const c: Chrome = .{ .scale = 1, .fonts = undefined, .theme = undefined };
    const view: Chrome.View = .{
        .groups = &.{.{ .label = &.{}, .tabs = 1, .kind = .local }},
        .workspaces = &.{.{ .label = &.{}, .tabs = 1, .shown = true }},
        .tabs = &.{
            .{ .title = &.{}, .activity = false, .folded = true },
            .{ .title = &.{}, .activity = false, .folded = true },
        },
        .active = 0,
        .focused = true,
        .maximized = false,
        .terminal_bg = .{ 0, 0, 0, 1 },
    };
    const l = c.layout(1000, 600);
    var walk: Walk = .init(&c, &l, &view);
    _ = walk.next().?;
    _ = walk.next().?;
    const in_ws = walk.next().?;
    try std.testing.expectEqual(@as(usize, 0), in_ws.part.tab.tab);
    try std.testing.expectEqual(@as(u8, 2), in_ws.depth);
    const loose = walk.next().?;
    try std.testing.expectEqual(@as(usize, 1), loose.part.tab.tab);
    try std.testing.expectEqual(@as(u8, 1), loose.depth);
    try std.testing.expect(!loose.guided);
    try std.testing.expect(walk.next() == null);
}
