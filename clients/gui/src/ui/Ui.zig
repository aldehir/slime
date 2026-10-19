//! The window's own UI around the terminal, drawn with Direct2D over each
//! frame from a `Tree` of widgets: a title bar with caption buttons, a
//! sidebar listing the tabs, and over the terminal area, the active
//! tab's panes' title strips, a dialog, a context menu, a tooltip. `frame` splits the
//! window into those regions; `layout` places a tree's nodes, `hitTest`
//! finds what's under a point, and `paint` draws it. The tree is a
//! function of the app's state (`view.zig`); the UI itself only tracks
//! the mouse, as `Id`s of what it's over, and the scale, fonts, and
//! theme every widget draws with.
//!
//! Each `Tree.Kind` is drawn by a module under `widgets/`, which may
//! define, for a node of its kinds:
//!
//! - `measure(ui, node) Size`: the size it wants, a side null where it
//!   takes what its parent gives. Without it, it takes everything.
//! - `layout(ui, node)`: with `node.rect` set, place its children.
//!   Leaves leave it out.
//! - `hitTest(ui, node, x, y) ?Id`: what's at a point inside its rect,
//!   or null for the default: its children, last to first, then its own
//!   id. Only for widgets whose parts aren't child nodes.
//! - `paint(ui, painter, node)`: draw it, and its children if it has
//!   any (`paintChildren`). Without it, only the children are drawn.
//!
//! Widgets keep no state between frames: hover, pressed, and the tooltip
//! live here, by id. (State a widget would keep, like a scroll offset,
//! would go in a map by id here too.)
const Ui = @This();

const std = @import("std");
const win32 = @import("../win32/win32.zig");
const com = win32.com;
const dwrite = win32.dwrite;
const Painter = @import("../renderer/Painter.zig");
const colors = @import("theme.zig");
pub const Theme = colors.Theme;
pub const TextField = @import("TextField.zig");
pub const Dialog = @import("Dialog.zig");
pub const Menu = @import("Menu.zig");
pub const Id = @import("Id.zig");
pub const Tree = @import("Tree.zig").Tree;
pub const Node = @import("Tree.zig").Node;
pub const Kind = @import("Tree.zig").Kind;
pub const Size = @import("Tree.zig").Size;
pub const Font = @import("Tree.zig").Font;
const widgets = struct {
    const Containers = @import("widgets/Containers.zig");
    const Label = @import("widgets/Label.zig");
    const IconButton = @import("widgets/IconButton.zig");
    const Button = @import("widgets/Button.zig");
    const TextFieldView = @import("widgets/TextFieldView.zig");
    const Status = @import("widgets/Status.zig");
    const TreeList = @import("widgets/TreeList.zig");
    const PaneStrip = @import("widgets/PaneStrip.zig");
    const Modal = @import("widgets/Modal.zig");
    const Popup = @import("widgets/Popup.zig");
    const CaptionButton = @import("widgets/CaptionButton.zig");
    const Tooltip = @import("widgets/Tooltip.zig");
};

pub const Rect = Painter.Rect;
pub const Color = Painter.Color;
const L = std.unicode.utf8ToUtf16LeStringLiteral;

// Sizes in DIPs.
/// The title bar's height with the sidebar, and without it.
pub const titlebar_height = 36;
pub const titlebar_height_plain = 40;
/// The sidebar's width to start with, and the range dragging its edge
/// keeps it in.
pub const default_sidebar_width = 240;
pub const min_sidebar_width = 160;
pub const max_sidebar_width = 600;
/// How far either side of the sidebar's edge takes hold of it.
pub const sidebar_edge_grip = 4;
/// The notice's line height, and the space over and under its lines.
pub const notice_line_height = 18;
pub const notice_pad = 7;

/// Pixels per DIP: the monitor's scale times `zoom`.
scale: f32,
/// The configured `chrome-scale`, over the monitor's.
zoom: f32 = 1,
fonts: Fonts,
theme: Theme,
/// The tabs are listed in a sidebar; hidden, the terminal area takes
/// the width.
sidebar_shown: bool = true,
/// The sidebar's width in DIPs, as its edge was last dragged.
sidebar_width: f32 = default_sidebar_width,
/// Lines in the notice under the title bar (what's wrong with the
/// config); 0 while there's none.
notice_lines: u8 = 0,
/// What the mouse is over, and what a button went down on.
hover: Id = .none,
pressed: Id = .none,
/// The button whose tooltip shows: the one under the mouse, once it's
/// rested there.
tip: Id = .none,

/// The window's regions, in client pixels.
pub const Frame = struct {
    window: Rect = .{},
    titlebar: Rect = .{},
    /// The notice under the title bar. Empty while there's none.
    notice: Rect = .{},
    /// The sidebar. Empty while hidden.
    sidebar: Rect = .{},
    terminal: Rect = .{},
    /// The radius of each pane's corners.
    corner: f32 = 0,
    /// Space inside the terminal area, before the grid, at its left and
    /// top, which border the chrome. Added to the configured padding.
    inset: f32 = 0,
};

pub fn init(dpi: u32, zoom: f32, theme: Theme) !Ui {
    const z = std.math.clamp(zoom, min_zoom, max_zoom);
    const scale = scaleFor(dpi, z);
    return .{ .scale = scale, .zoom = z, .fonts = try .init(scale), .theme = theme };
}

pub fn deinit(self: *Ui) void {
    self.fonts.deinit();
}

pub fn setDpi(self: *Ui, dpi: u32) !void {
    const scale = scaleFor(dpi, self.zoom);
    const fonts: Fonts = try .init(scale);
    self.fonts.deinit();
    self.fonts = fonts;
    self.scale = scale;
}

/// Change `chrome-scale` (a config reload), keeping the rest as it is.
pub fn setZoom(self: *Ui, dpi: u32, zoom: f32) !void {
    self.zoom = std.math.clamp(zoom, min_zoom, max_zoom);
    try self.setDpi(dpi);
}

/// The range `chrome-scale` is clamped to.
const min_zoom = 0.5;
const max_zoom = 3;

fn scaleFor(dpi: u32, zoom: f32) f32 {
    return @as(f32, @floatFromInt(dpi)) / 96.0 * zoom;
}

/// `dip` device independent pixels as whole pixels.
pub fn px(self: *const Ui, dip: f32) f32 {
    return @round(dip * self.scale);
}

/// Where the regions go in a window `width` by `height`.
pub fn frame(self: *const Ui, width: f32, height: f32) Frame {
    const bar_h = self.px(if (self.sidebar_shown) titlebar_height else titlebar_height_plain);
    const lines: f32 = @floatFromInt(self.notice_lines);
    const notice_h = if (lines > 0) self.px(2 * notice_pad + lines * notice_line_height) else 0;
    const side_w = if (self.sidebar_shown) @min(self.px(self.sidebar_width), width) else 0;
    const top = bar_h + notice_h;
    const h = @max(0, height - top);
    return .{
        .window = .{ .w = width, .h = height },
        .titlebar = .{ .w = width, .h = bar_h },
        .notice = .{ .y = bar_h, .w = width, .h = notice_h },
        .sidebar = .{ .y = top, .w = side_w, .h = h },
        .terminal = .{ .x = side_w, .y = top, .w = width - side_w, .h = h },
        .corner = self.px(10),
        .inset = self.px(10),
    };
}

/// The part of the terminal area a tab's panes tile, leaving the chrome's
/// ground around them but at the top, under the title bar.
pub fn paneArea(self: *const Ui, f: *const Frame) Rect {
    const m = self.paneGap();
    const t = f.terminal;
    return .{ .x = t.x + m, .y = t.y, .w = @max(0, t.w - 2 * m), .h = @max(0, t.h - m) };
}

/// Between panes, and around them in the terminal area.
pub fn paneGap(self: *const Ui) f32 {
    return self.px(widgets.PaneStrip.gap);
}

/// The height of a pane's title strip, above its terminal.
pub fn paneTitleHeight(self: *const Ui) f32 {
    return self.px(widgets.PaneStrip.title_height);
}

/// The height of a browser pane's address row, under its title strip.
pub fn paneBarHeight(self: *const Ui) f32 {
    return self.px(widgets.PaneStrip.bar_height);
}

pub fn toggleSidebar(self: *Ui) void {
    self.sidebar_shown = !self.sidebar_shown;
    self.hover = .none;
    self.pressed = .none;
    self.tip = .none;
}

/// The module that draws nodes of kind `tag`.
fn Widget(comptime tag: std.meta.Tag(Kind)) type {
    return switch (tag) {
        .column, .row, .stack, .canvas, .spacer, .hit_area => widgets.Containers,
        .label, .lines => widgets.Label,
        .icon, .icon_button => widgets.IconButton,
        .button => widgets.Button,
        .text_field => widgets.TextFieldView,
        .status => widgets.Status,
        .fold, .tree => widgets.TreeList,
        .pane => widgets.PaneStrip,
        .dialog => widgets.Modal,
        .menu => widgets.Popup,
        .caption_button => widgets.CaptionButton,
    };
}

/// The size `node` wants.
pub fn measure(self: *const Ui, node: *const Node) Size {
    switch (node.kind) {
        inline else => |_, tag| {
            const W = Widget(tag);
            return if (@hasDecl(W, "measure")) W.measure(self, node) else .{};
        },
    }
}

/// Place every node of `tree` in its frame's window.
pub fn layout(self: *const Ui, tree: *Tree) void {
    tree.root.rect = tree.frame.window;
    self.layoutNode(&tree.root);
}

/// Place `node`'s children, its own rect being set.
pub fn layoutNode(self: *const Ui, node: *Node) void {
    switch (node.kind) {
        inline else => |_, tag| {
            const W = Widget(tag);
            if (@hasDecl(W, "layout")) W.layout(self, node);
        },
    }
}

/// The child nodes a container holds, for the default hit testing and
/// painting. A `tree`'s rows aren't nodes; it handles its own.
pub fn children(node: *const Node) []Node {
    return switch (node.kind) {
        .column => |c| c.children,
        .row => |r| r.children,
        .stack, .canvas => |nodes| nodes,
        .pane => |p| p.buttons,
        else => &.{},
    };
}

/// What's under a point.
pub fn hitTest(self: *const Ui, tree: *const Tree, x: f32, y: f32) Id {
    return self.hitNode(&tree.root, x, y) orelse .none;
}

/// What's under a point in `node`: what its widget says, else its
/// children last to first (the last drawn is on top), else itself.
pub fn hitNode(self: *const Ui, node: *const Node, x: f32, y: f32) ?Id {
    if (!node.rect.contains(x, y)) return null;
    switch (node.kind) {
        inline else => |_, tag| {
            const W = Widget(tag);
            if (@hasDecl(W, "hitTest")) if (W.hitTest(self, node, x, y)) |id| return id;
        },
    }
    const nodes = children(node);
    var i = nodes.len;
    while (i > 0) {
        i -= 1;
        if (self.hitNode(&nodes[i], x, y)) |id| return id;
    }
    return if (node.id.target == .none) null else node.id;
}

/// The node with `id`, if the tree has one. The first in drawing order
/// where several share it.
pub fn find(tree: *const Tree, id: Id) ?*const Node {
    return findIn(&tree.root, id);
}

pub fn findIn(node: *const Node, id: Id) ?*const Node {
    if (node.id.eql(id)) return node;
    switch (node.kind) {
        .tree => |t| return widgets.TreeList.find(t.rows, id),
        else => {},
    }
    for (children(node)) |*child| if (findIn(child, id)) |n| return n;
    return null;
}

/// What a paint pass draws: the whole tree into one target, or, while
/// the renderer has content of its own over the ground (a browser pane's),
/// the ground and what must be over that content (dialogs, the menu, the
/// tooltip) in two.
pub const Layer = enum { all, ground, over };

/// Draw `tree`'s `layer`, then the tooltip over it if that's in the layer.
pub fn paint(self: *const Ui, p: *Painter, tree: *const Tree, layer: Layer) void {
    if (layer == .all) {
        self.paintNode(p, &tree.root);
    } else {
        // What's over is decided by the root's children: the regions the
        // builder stacked last.
        const root = &tree.root;
        if (root.clip) p.pushClip(root.rect);
        defer if (root.clip) p.popClip();
        for (children(root)) |*child| if (isOver(child) == (layer == .over)) self.paintNode(p, child);
    }
    if (layer != .ground) widgets.Tooltip.paint(self, p, tree);
}

/// Whether `paint`'s `.over` layer draws anything.
pub fn hasOver(self: *const Ui, tree: *const Tree) bool {
    if (self.tip.target != .none or dragCapture(tree) != null) return true;
    for (children(&tree.root)) |*child| if (isOver(child)) return true;
    return false;
}

fn isOver(node: *const Node) bool {
    return switch (node.kind) {
        .dialog, .menu => true,
        else => false,
    };
}

pub fn paintNode(self: *const Ui, p: *Painter, node: *const Node) void {
    if (node.clip) p.pushClip(node.rect);
    defer if (node.clip) p.popClip();
    switch (node.kind) {
        inline else => |_, tag| {
            const W = Widget(tag);
            if (@hasDecl(W, "paint")) W.paint(self, p, node) else self.paintChildren(p, node);
        },
    }
}

pub fn paintChildren(self: *const Ui, p: *Painter, node: *const Node) void {
    for (children(node)) |*child| self.paintNode(p, child);
}

/// The part of the frame `paintDrag` wants a copy of, if any.
pub fn dragCapture(tree: *const Tree) ?Rect {
    return widgets.PaneStrip.dragCapture(tree);
}

/// Over the frame `paint` drew: a pane being dragged, with `thumb`, the
/// copy `dragCapture` asked for.
pub fn paintDrag(self: *const Ui, p: *Painter, tree: *const Tree, thumb: ?Painter.Image) void {
    widgets.PaneStrip.paintDrag(self, p, tree, thumb);
}

/// Track what the mouse is over. Returns true if that changed what's
/// drawn.
pub fn setHover(self: *Ui, hit: Id) bool {
    // The caption, dividers, and corners draw nothing for hover, nor
    // does a pane's title strip; a pane shows its buttons.
    const h: Id = if (hit.part == .caption or hit.part == .title or hit.target == .divider or hit.target == .corner) .none else hit;
    if (self.hover.eql(h)) return false;
    self.hover = h;
    self.tip = .none;
    return true;
}

/// Whether `id` is a button a tooltip names: an icon button with a tip.
pub fn hasTip(tree: *const Tree, id: Id) bool {
    const node = find(tree, id) orelse return false;
    return switch (node.kind) {
        .icon_button => |b| b.tip.len > 0,
        else => false,
    };
}

/// Show the tooltip of the button under the mouse, if it has one.
/// Returns true if that changed what's drawn.
pub fn showTip(self: *Ui, tree: *const Tree) bool {
    if (!hasTip(tree, self.hover) or self.pressed.target != .none or self.tip.eql(self.hover)) return false;
    self.tip = self.hover;
    return true;
}

pub fn hideTip(self: *Ui) bool {
    if (self.tip.target == .none) return false;
    self.tip = .none;
    return true;
}

pub fn setPressed(self: *Ui, hit: Id) bool {
    if (self.pressed.eql(hit)) return false;
    self.pressed = hit;
    return true;
}

pub const ButtonState = enum { rest, hover, pressed };

pub fn buttonState(self: *const Ui, id: Id) ButtonState {
    if (!self.hover.eql(id)) return .rest;
    return if (self.pressed.eql(id)) .pressed else .hover;
}

/// A shadow under a pane or a raised widget: a Gaussian blur of its box
/// in `color`, fallen `offset` pixels.
pub const Shadow = struct {
    color: Color,
    /// The blur's standard deviation, in pixels.
    sigma: f32,
    offset: f32,
};

/// The shadows under every pane and raised widget: one tight at the edge
/// and one soft around it. A blur reaches about 3 sigma, so the soft one
/// fades out within the gap between panes rather than running under the
/// sidebar, which would cut it off.
pub fn shadows(self: *const Ui) [2]Shadow {
    const s = self.theme.pane_shadow;
    return .{
        .{ .color = s, .sigma = self.px(1), .offset = self.px(1) },
        .{ .color = colors.withAlpha(s, s[3] * 0.7), .sigma = self.px(3), .offset = self.px(2) },
    };
}

/// The pane shadows (`shadows`) under the rounded rect `r`, as Direct2D
/// can draw them: each blur as rings of one faint color, each out to
/// where the blur has that ring's share of its strength left, so together
/// they step down its curve. The box itself, drawn over, hides the rest.
pub fn paintShadow(self: *const Ui, p: *Painter, r: Rect, radius: f32) void {
    for (self.shadows()) |s| {
        const fallen: Rect = .{ .x = r.x, .y = r.y + s.offset, .w = r.w, .h = r.h };
        // At the box's edge a blur is at half strength; the rings share it.
        const color = colors.withAlpha(s.color, s.color[3] * 0.5 / blur_rings.len);
        for (blur_rings) |sigmas| {
            const spread = sigmas * s.sigma;
            p.fillRounded(fallen.inset(-spread, -spread), radius + spread, color);
        }
    }
}

/// Where each of six rings of a blur ends, in sigmas: where the Gaussian's
/// tail is down to (i - 1/2) / 12 for ring i, so an even share of its
/// strength is lost between one ring and the next.
const blur_rings = [_]f32{ 1.73, 1.15, 0.81, 0.55, 0.32, 0.105 };

/// A glow around `r` in `color`, for what has the keyboard, drawn before
/// it: rings a stroke apart.
pub fn paintGlow(self: *const Ui, p: *Painter, r: Rect, radius: f32, color: Color) void {
    paintRings(p, r, radius, 4, self.stroke(), colors.withAlpha(color, 0.09));
}

/// `rings` rings of `color` around `r`, `step` pixels apart, which add up
/// to a fade outward.
fn paintRings(p: *Painter, r: Rect, radius: f32, rings: f32, step: f32, color: Color) void {
    var i = rings;
    while (i > 0) : (i -= 1) {
        const spread = i * step;
        const ring: Rect = .{ .x = r.x - spread, .y = r.y - spread, .w = r.w + 2 * spread, .h = r.h + 2 * spread };
        p.fillRounded(ring, radius + spread, color);
    }
}

pub const EditTextOptions = struct {
    caret: bool,
    /// Dots for the text, for passwords.
    mask: bool = false,
    color: ?Color = null,
};

/// A text field's text in `inner`, scrolled to keep the caret in view,
/// with its selection behind it and the caret if `opts.caret`.
pub fn paintEditText(self: *const Ui, p: *Painter, inner: Rect, field: *const TextField, opts: EditTextOptions) void {
    var dots: [TextField.max_len]u16 = undefined;
    const text = if (opts.mask) dots: {
        @memset(dots[0..field.len], 0x25CF);
        break :dots dots[0..field.len];
    } else field.text();
    const font = self.fonts.get(.body);

    const caret_x = self.fonts.measure(text[0..field.caret], font);
    // Room for the caret at the right edge.
    const scroll = @max(0, caret_x - (inner.w - self.stroke()));
    const x = inner.x - scroll;
    p.pushClip(inner);
    defer p.popClip();
    const sel = field.selection();
    if (sel.start != sel.end) {
        const x0 = x + self.fonts.measure(text[0..sel.start], font);
        const x1 = x + self.fonts.measure(text[0..sel.end], font);
        p.fill(.{ .x = @round(x0), .y = inner.y + self.px(7), .w = @round(x1) - @round(x0), .h = inner.h - self.px(14) }, self.theme.selection);
    }
    // Laid out wider than it is, so it's never trimmed.
    p.text(text, font, .{ .x = x, .y = inner.y, .w = self.fonts.measure(text, font) + inner.w, .h = inner.h }, opts.color orelse self.theme.text);
    if (opts.caret) {
        const cx = crisp(x + caret_x, self.stroke());
        p.line(cx, inner.y + self.px(8), cx, inner.bottom() - self.px(8), self.stroke(), self.theme.text_strong);
    }
}

/// The rounded rect `r` filled with `fill`, inside a border of `border`.
/// Both are fills, the inner one a stroke's width in on a radius that
/// much smaller, so the edges meet with no seam at the corners, as a
/// stroke over a fill leaves.
pub fn fillBordered(self: *const Ui, p: *Painter, r: Rect, radius: f32, fill: Color, border: Color) void {
    const w = self.stroke();
    p.fillRounded(r, radius, border);
    p.fillRounded(r.inset(w, w), @max(0, radius - w), fill);
}

/// The width of icon strokes.
pub fn stroke(self: *const Ui) f32 {
    return @max(1, @round(self.scale));
}

/// `v` moved so a horizontal or vertical line `width` thick covers whole
/// pixels.
pub fn crisp(v: f32, width: f32) f32 {
    return if (@mod(width, 2) == 1) @floor(v) + 0.5 else @round(v);
}

/// The Lucide icon `name` scaled to the square `box`. Its strokes are
/// `stroke` wide at any size, rather than Lucide's 2 of 24 units, so
/// straight lines are crisp where `box` puts them on pixel centers.
pub fn drawIcon(self: *const Ui, p: *Painter, name: Painter.Lucide, box: Rect, color: Color) void {
    p.lucideIcon(name, box, self.stroke(), color);
}

/// Text formats for the UI, sized for the current scale. All lay out
/// one line, centered vertically, trimmed with an ellipsis, but the
/// paragraph ones, which wrap from the top.
pub const Fonts = struct {
    /// Null for no fonts at all (tests), where every text measures 0.
    factory: ?*dwrite.IFactory2,
    formats: std.EnumArray(Font, *dwrite.ITextFormat),

    pub const none: Fonts = .{ .factory = null, .formats = undefined };

    const ui_families = [_][:0]const u16{ L("Segoe UI Variable Text"), L("Segoe UI") };
    const mono_families = [_][:0]const u16{ L("Cascadia Mono"), L("Consolas") };

    const Spec = struct { mono: bool = false, weight: dwrite.FONT_WEIGHT = .NORMAL, size: f32, align_: u32 = dwrite.TEXT_ALIGNMENT_LEADING, wrap: ?u32 = null };

    fn spec(font: Font) Spec {
        return switch (font) {
            // List rows and buttons, and the active row.
            .body => .{ .size = 13 },
            .body_strong => .{ .weight = .SEMI_BOLD, .size = 13 },
            // The window title, centered.
            .title => .{ .size = 12.5, .align_ = dwrite.TEXT_ALIGNMENT_CENTER },
            // Section headers in the list.
            .section => .{ .weight = .SEMI_BOLD, .size = 11 },
            // Key hints, centered.
            .hint => .{ .size = 10.5, .align_ = dwrite.TEXT_ALIGNMENT_CENTER },
            .tip => .{ .size = 12 },
            // Numbers that change in place, like the stats.
            .mono => .{ .mono = true, .size = 10.5 },
            // A dialog's title.
            .heading => .{ .weight = .SEMI_BOLD, .size = 15 },
            // Paragraphs, wrapped, from the top.
            .prose => .{ .size = 12.5, .wrap = dwrite.WORD_WRAPPING_WRAP },
            // Paths and fingerprints, wrapped anywhere they must be.
            .mono_prose => .{ .mono = true, .size = 12, .wrap = dwrite.WORD_WRAPPING_EMERGENCY_BREAK },
            // Button labels, centered.
            .button => .{ .size = 13, .align_ = dwrite.TEXT_ALIGNMENT_CENTER },
            .button_strong => .{ .weight = .SEMI_BOLD, .size = 13, .align_ = dwrite.TEXT_ALIGNMENT_CENTER },
        };
    }

    fn init(scale: f32) !Fonts {
        var factory: ?*dwrite.IFactory2 = null;
        try com.check(
            dwrite.DWriteCreateFactory(dwrite.FACTORY_TYPE_SHARED, &dwrite.IFactory2.iid, @ptrCast(&factory)),
            "DWriteCreateFactory",
        );
        errdefer com.releaseOpt(&factory);
        const f = factory.?;
        const ui = findFamily(f, &ui_families);
        const mono = findFamily(f, &mono_families);

        var self: Fonts = .{ .factory = f, .formats = undefined };
        var made: usize = 0;
        errdefer for (std.enums.values(Font)[0..made]) |font| com.release(self.formats.get(font));
        for (std.enums.values(Font)) |font| {
            const s = spec(font);
            self.formats.set(font, try createFormat(f, if (s.mono) mono else ui, s.weight, s.size * scale, s.align_, s.wrap));
            made += 1;
        }
        return self;
    }

    fn deinit(self: *Fonts) void {
        const f = self.factory orelse return;
        for (std.enums.values(Font)) |font| com.release(self.formats.get(font));
        com.release(f);
        self.* = undefined;
    }

    pub fn get(self: *const Fonts, font: Font) *dwrite.ITextFormat {
        return self.formats.get(font);
    }

    /// The first installed of `families`, else the last.
    fn findFamily(factory: *dwrite.IFactory2, families: []const [:0]const u16) [:0]const u16 {
        var collection: ?*dwrite.IFontCollection = null;
        if (factory.getSystemFontCollection(&collection) < 0) return families[families.len - 1];
        defer com.releaseOpt(&collection);
        for (families) |name| {
            var index: u32 = 0;
            var exists: win32.BOOL = win32.FALSE;
            if (collection.?.findFamilyName(name.ptr, &index, &exists) >= 0 and exists != win32.FALSE) return name;
        }
        return families[families.len - 1];
    }

    /// One line, centered vertically and trimmed with an ellipsis, or
    /// with `wrap`, lines from the top.
    fn createFormat(factory: *dwrite.IFactory2, family: [:0]const u16, weight: dwrite.FONT_WEIGHT, size: f32, alignment: u32, wrap: ?u32) !*dwrite.ITextFormat {
        var format: ?*dwrite.ITextFormat = null;
        try com.check(factory.createTextFormat(family.ptr, weight, size, &format), "IDWriteFactory::CreateTextFormat");
        errdefer com.releaseOpt(&format);
        const f = format.?;
        try com.check(f.setTextAlignment(alignment), "IDWriteTextFormat::SetTextAlignment");
        try com.check(f.setParagraphAlignment(if (wrap != null) dwrite.PARAGRAPH_ALIGNMENT_NEAR else dwrite.PARAGRAPH_ALIGNMENT_CENTER), "IDWriteTextFormat::SetParagraphAlignment");
        try com.check(f.setWordWrapping(wrap orelse dwrite.WORD_WRAPPING_NO_WRAP), "IDWriteTextFormat::SetWordWrapping");
        if (wrap != null) return f;
        var sign: ?*dwrite.IInlineObject = null;
        try com.check(factory.createEllipsisTrimmingSign(f, &sign), "IDWriteFactory::CreateEllipsisTrimmingSign");
        defer com.releaseOpt(&sign);
        try com.check(f.setTrimming(&.{ .granularity = dwrite.TRIMMING_GRANULARITY_CHARACTER }, sign), "IDWriteTextFormat::SetTrimming");
        return f;
    }

    /// The width of `text` laid out in `format`, in pixels.
    pub fn measure(self: *const Fonts, text: []const u16, format: *dwrite.ITextFormat) f32 {
        const m = self.layoutMetrics(text, format, unbounded) orelse return 0;
        return m.widthIncludingTrailingWhitespace;
    }

    /// The height of `text` wrapped to `width` in a wrapping `format`, in
    /// whole pixels.
    pub fn measureHeight(self: *const Fonts, text: []const u16, format: *dwrite.ITextFormat, width: f32) f32 {
        if (text.len == 0) return 0;
        const m = self.layoutMetrics(text, format, @max(1, width)) orelse return 0;
        return @ceil(m.height);
    }

    // DirectWrite rejects infinite and huge bounds.
    const unbounded = 100_000;

    fn layoutMetrics(self: *const Fonts, text: []const u16, format: *dwrite.ITextFormat, width: f32) ?dwrite.TEXT_METRICS {
        const factory = self.factory orelse return null;
        var text_layout: ?*dwrite.ITextLayout = null;
        const hr = factory.createTextLayout(text, format, width, unbounded, &text_layout);
        if (hr < 0) {
            com.check(hr, "IDWriteFactory::CreateTextLayout") catch {};
            return null;
        }
        defer com.releaseOpt(&text_layout);
        var m: dwrite.TEXT_METRICS = undefined;
        if (text_layout.?.getMetrics(&m) < 0) return null;
        return m;
    }
};

test "the frame, with and without the sidebar" {
    var ui: Ui = .{ .scale = 1, .fonts = .none, .theme = undefined };
    var f = ui.frame(1000, 600);
    try std.testing.expectEqual(@as(f32, titlebar_height), f.titlebar.h);
    try std.testing.expect(f.sidebar.w > 0 and f.terminal.x == f.sidebar.right());
    try std.testing.expectEqual(f.window.w, f.terminal.right());
    ui.toggleSidebar();
    f = ui.frame(1000, 600);
    try std.testing.expectEqual(@as(f32, titlebar_height_plain), f.titlebar.h);
    try std.testing.expectEqual(@as(f32, 0), f.sidebar.w);
    try std.testing.expectEqual(@as(f32, 0), f.terminal.x);
    try std.testing.expectEqual(f.window.w, f.terminal.w);
    // Shown again at a dragged width, it takes that.
    ui.toggleSidebar();
    ui.sidebar_width = 300;
    f = ui.frame(1000, 600);
    try std.testing.expectEqual(@as(f32, 300), f.sidebar.w);
    try std.testing.expectEqual(@as(f32, 300), f.terminal.x);
    // A notice takes its lines under the title bar, from the sidebar
    // and the terminal area alike.
    ui.notice_lines = 2;
    f = ui.frame(1000, 600);
    try std.testing.expectEqual(@as(f32, 2 * notice_pad + 2 * notice_line_height), f.notice.h);
    try std.testing.expectEqual(f.titlebar.h, f.notice.y);
    try std.testing.expectEqual(f.notice.bottom(), f.sidebar.y);
    try std.testing.expectEqual(f.notice.bottom(), f.terminal.y);
    try std.testing.expectEqual(@as(f32, 600), f.terminal.bottom());
    ui.notice_lines = 0;
    f = ui.frame(1000, 600);
    try std.testing.expectEqual(@as(f32, 0), f.notice.h);
    try std.testing.expectEqual(f.titlebar.h, f.terminal.y);
}

test "layout and hit testing a small tree" {
    const ui: Ui = .{ .scale = 1, .fonts = .none, .theme = undefined };
    const Id_ = Id;
    const pane: Id_ = .{ .target = .{ .pane = 7 }, .part = .terminal };
    var buttons = [_]Node{
        .{ .id = Id_.window(.minimize), .kind = .{ .caption_button = .{ .part = .minimize, .maximized = false, .focused = true } } },
        .{ .id = Id_.window(.close), .kind = .{ .caption_button = .{ .part = .close, .maximized = false, .focused = true } } },
    };
    var bar = [_]Node{
        .{ .kind = .{ .spacer = 12 } },
        .{ .kind = .{ .icon = .{ .icon = null, .size = 18 } } },
        .{ .id = Id_.window(.toggle_sidebar), .kind = .{ .icon_button = .{ .icon = .panel_left, .size = 20, .w = 40, .h = null, .style = .bar, .tip = L("Hide sidebar") } } },
        .{ .kind = .{ .label = .{ .text = &.{}, .color = undefined } } },
        .{ .kind = .{ .row = .{ .children = &buttons } } },
    };
    var regions = [_]Node{
        .{ .id = Id_.window(.caption), .kind = .{ .row = .{ .children = &bar } }, .rect = .{ .w = 1000, .h = 36 } },
        .{ .id = pane, .kind = .{ .pane = .{ .title = &.{}, .focused = true, .bg = undefined } }, .rect = .{ .x = 240, .y = 36, .w = 760, .h = 564 } },
    };
    var tree: Tree = .{ .root = .{ .kind = .{ .canvas = &regions } }, .frame = ui.frame(1000, 600) };
    ui.layout(&tree);
    try std.testing.expectEqual(Id_.window(.close), ui.hitTest(&tree, 999, 5));
    try std.testing.expectEqual(Id_.window(.minimize), ui.hitTest(&tree, 1000 - 46 - 1, 5));
    try std.testing.expectEqual(Id_.window(.caption), ui.hitTest(&tree, 500, 5));
    try std.testing.expectEqual(Id_.window(.toggle_sidebar), ui.hitTest(&tree, 37, 5));
    // The app icon is part of the caption.
    try std.testing.expectEqual(Id_.window(.caption), ui.hitTest(&tree, 13, 10));
    try std.testing.expectEqual(pane, ui.hitTest(&tree, 241, 136));
    try std.testing.expectEqual(pane.with(.title), ui.hitTest(&tree, 241, 37));
    try std.testing.expectEqual(Id_.none, ui.hitTest(&tree, 100, 300));
    // The toggle is found by id, and has a tip; the caption's close has none.
    try std.testing.expect(find(&tree, Id_.window(.toggle_sidebar)) != null);
    try std.testing.expect(hasTip(&tree, Id_.window(.toggle_sidebar)));
    try std.testing.expect(!hasTip(&tree, Id_.window(.close)));
    try std.testing.expectEqual(@as(f32, 40), find(&tree, Id_.window(.toggle_sidebar)).?.rect.w);
    try std.testing.expectEqual(@as(f32, 36), find(&tree, Id_.window(.toggle_sidebar)).?.rect.h);
}

test crisp {
    try std.testing.expectEqual(@as(f32, 10.5), crisp(10.2, 1));
    try std.testing.expectEqual(@as(f32, 10), crisp(10.2, 2));
}

test {
    _ = widgets.Containers;
    _ = widgets.Label;
    _ = widgets.IconButton;
    _ = widgets.Button;
    _ = widgets.TextFieldView;
    _ = widgets.Status;
    _ = widgets.TreeList;
    _ = widgets.PaneStrip;
    _ = widgets.Modal;
    _ = widgets.Popup;
    _ = widgets.CaptionButton;
    _ = widgets.Tooltip;
    _ = Menu;
}
