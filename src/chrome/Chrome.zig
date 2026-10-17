//! The window's own UI around the terminal, drawn with Direct2D over each
//! frame: a title bar with caption buttons, the list of tabs, and over
//! the terminal area, the active tab's panes' corners and buttons.
//!
//! The tab list has two layouts (`Mode`), each a module with the same
//! three functions: `layout` places the list and the terminal, `hitTest`
//! finds what's under a point in the list, and `paint` draws it. The
//! title bar's toggle switches between them. What's drawn is a function
//! of a `View` of the window's state; the chrome itself only tracks the
//! mouse.
const Chrome = @This();

const std = @import("std");
const win32 = @import("../win32/win32.zig");
const com = win32.com;
const dwrite = win32.dwrite;
const Painter = @import("../renderer/Painter.zig");
pub const Theme = @import("theme.zig").Theme;
pub const TextField = @import("TextField.zig");
pub const Dialog = @import("Dialog.zig");
const modal = @import("modal.zig");
const panes = @import("panes.zig");

pub const Rect = Painter.Rect;
pub const Color = Painter.Color;
const L = std.unicode.utf8ToUtf16LeStringLiteral;

pub const Mode = enum {
    /// Sessions listed in a sidebar, grouped by where they run.
    sidebar,
    /// Sessions as tabs in the title bar.
    tabs,
};

fn Impl(comptime mode: Mode) type {
    return switch (mode) {
        .sidebar => @import("sidebar.zig"),
        .tabs => @import("tabs.zig"),
    };
}

mode: Mode = .sidebar,
/// Pixels per DIP: the monitor's scale times `zoom`.
scale: f32,
/// The configured `chrome-scale`, over the monitor's.
zoom: f32 = 1,
fonts: Fonts,
theme: Theme,
/// What the mouse is over, and what a button went down on.
hover: Hit = .none,
pressed: Hit = .none,
/// The button whose tooltip shows: the one under the mouse, once it's
/// rested there.
tip: Hit = .none,

pub const Hit = union(enum) {
    none,
    /// The title bar's empty space, which moves the window.
    caption,
    minimize,
    maximize,
    close,
    toggle_mode,
    /// Group `i`'s header, away from its buttons.
    header: usize,
    /// The button that opens a tab in group `i`, connecting first if
    /// it's a host that isn't connected.
    new_tab: usize,
    /// The button that removes host group `i` from the list.
    forget_host: usize,
    /// The button that connects to a host, or its field.
    connect,
    tab: usize,
    close_tab: usize,
    /// Pane `i` of `View.panes`, away from its buttons.
    terminal: usize,
    /// Pane `i`'s buttons, which show while the mouse is over it.
    split_right: usize,
    split_down: usize,
    zoom: usize,
    /// Between panes, or around them.
    divider,
    /// The terminal area under a dialog, away from its controls.
    dialog,
    dialog_button: usize,
    dialog_field: usize,

    pub fn eql(a: Hit, b: Hit) bool {
        return std.meta.eql(a, b);
    }
};

/// The window's state, as the chrome shows it.
pub const View = struct {
    /// Where tabs run, in the order listed. Their tabs come one group
    /// after another.
    groups: []const Group,
    tabs: []const Tab,
    active: usize,
    /// The active tab's panes on screen, which tile `paneArea` but for
    /// the gaps between them (one pane while one is zoomed).
    panes: []const Pane = &.{},
    /// The host being typed after "Connect" was clicked, if it was.
    connect: ?*const TextField = null,
    /// The on phase of the caret's blink, while focused.
    caret_visible: bool = false,
    /// The active pane's dialog, over the terminal area.
    dialog: ?*const Dialog = null,
    /// Steps of the dialog's spinner.
    spinner: u32 = 0,
    /// The window has keyboard focus.
    focused: bool,
    maximized: bool,
    /// The terminal's default background.
    terminal_bg: Color,

    /// Frame stats, when built with `-Dstats`. Lines end with LF.
    stats: []const u16 = &.{},

    /// The keys for a new tab in the active tab's group and for closing
    /// the active pane, which their tooltips show.
    new_tab_key: []const u16 = &.{},
    close_tab_key: []const u16 = &.{},

    pub const Group = struct {
        label: []const u16,
        /// How many of `tabs` are in it.
        tabs: usize,
        kind: Kind,

        pub const Kind = enum {
            local,
            /// A host with a live connection, which new tabs join.
            connected,
            /// A remembered host that new tabs connect to.
            disconnected,
        };
    };

    pub const Tab = struct {
        title: []const u16,
        /// Output arrived while it wasn't shown.
        activity: bool,
    };

    pub const Pane = struct {
        rect: Rect,
        /// It gets the keys. Others are dimmed while the tab has several.
        focused: bool,
        /// It can be split (it runs in slimed), and zoomed if not alone.
        splittable: bool,
        zoomable: bool,
        zoomed: bool,
        /// Its terminal's default background.
        bg: Color,
    };

    pub fn title(self: *const View) []const u16 {
        return if (self.active < self.tabs.len) self.tabs[self.active].title else &.{};
    }

    /// The group the active tab is in.
    pub fn activeGroup(self: *const View) usize {
        var end: usize = 0;
        for (self.groups, 0..) |g, i| {
            end += g.tabs;
            if (self.active < end) return i;
        }
        return 0;
    }
};

/// Where everything goes, in client pixels.
pub const Layout = struct {
    window: Rect,
    titlebar: Rect,
    /// The app icon, at the far left. Part of the caption: it moves the
    /// window.
    icon: Rect,
    toggle: Rect,
    /// The title bar between the toggle and the caption buttons.
    title: Rect,
    minimize: Rect,
    maximize: Rect,
    close: Rect,
    /// The tab list's own area. Empty when it's in the title bar.
    list: Rect = .{},
    terminal: Rect = .{},
    /// The radius of each pane's corners.
    corner: f32 = 0,
    /// Space inside the terminal area, before the grid, at its left and
    /// top, which border the chrome. Added to the configured padding.
    inset: f32 = 0,
};

pub fn init(dpi: u32, zoom: f32, theme: Theme) !Chrome {
    const z = std.math.clamp(zoom, min_zoom, max_zoom);
    const scale = scaleFor(dpi, z);
    return .{ .scale = scale, .zoom = z, .fonts = try .init(scale), .theme = theme };
}

pub fn deinit(self: *Chrome) void {
    self.fonts.deinit();
}

pub fn setDpi(self: *Chrome, dpi: u32) !void {
    const scale = scaleFor(dpi, self.zoom);
    const fonts: Fonts = try .init(scale);
    self.fonts.deinit();
    self.fonts = fonts;
    self.scale = scale;
}

/// The range `chrome-scale` is clamped to.
const min_zoom = 0.5;
const max_zoom = 3;

fn scaleFor(dpi: u32, zoom: f32) f32 {
    return @as(f32, @floatFromInt(dpi)) / 96.0 * zoom;
}

/// `dip` device independent pixels as whole pixels.
pub fn px(self: *const Chrome, dip: f32) f32 {
    return @round(dip * self.scale);
}

pub fn layout(self: *const Chrome, width: f32, height: f32) Layout {
    const bar_h = switch (self.mode) {
        inline else => |m| self.px(Impl(m).titlebar_height),
    };
    const button_w = self.px(46);
    const close: Rect = .{ .x = width - button_w, .w = button_w, .h = bar_h };
    const maximize: Rect = .{ .x = close.x - button_w, .w = button_w, .h = bar_h };
    const minimize: Rect = .{ .x = maximize.x - button_w, .w = button_w, .h = bar_h };
    const icon_size = self.px(18);
    const icon: Rect = .{ .x = self.px(12), .y = @round((bar_h - icon_size) / 2), .w = icon_size, .h = icon_size };
    const toggle: Rect = .{ .x = icon.right() + self.px(6), .w = self.px(40), .h = bar_h };
    var l: Layout = .{
        .window = .{ .w = width, .h = height },
        .titlebar = .{ .w = width, .h = bar_h },
        .icon = icon,
        .toggle = toggle,
        .title = .{ .x = toggle.right(), .w = @max(0, minimize.x - toggle.right()), .h = bar_h },
        .minimize = minimize,
        .maximize = maximize,
        .close = close,
        .corner = self.px(10),
        .inset = self.px(10),
    };
    switch (self.mode) {
        inline else => |m| Impl(m).layout(self, &l),
    }
    return l;
}

/// The part of the terminal area a tab's panes tile, leaving the chrome's
/// ground around them but at the top, under the title bar.
pub fn paneArea(self: *const Chrome, l: *const Layout) Rect {
    const m = self.paneGap();
    const t = l.terminal;
    return .{ .x = t.x + m, .y = t.y, .w = @max(0, t.w - 2 * m), .h = @max(0, t.h - m) };
}

/// Between panes, and around them in the terminal area.
pub fn paneGap(self: *const Chrome) f32 {
    return self.px(panes.gap);
}

pub fn hitTest(self: *const Chrome, l: *const Layout, view: *const View, x: f32, y: f32) Hit {
    if (l.terminal.contains(x, y)) {
        if (view.dialog) |d| return modal.hitTest(self, l.terminal, d, x, y);
        return panes.hitTest(self, view, x, y);
    }
    if (l.close.contains(x, y)) return .close;
    if (l.maximize.contains(x, y)) return .maximize;
    if (l.minimize.contains(x, y)) return .minimize;
    if (l.toggle.contains(x, y)) return .toggle_mode;
    const hit = switch (self.mode) {
        inline else => |m| Impl(m).hitTest(self, l, view, x, y),
    };
    if (hit) |h| return h;
    if (l.titlebar.contains(x, y)) return .caption;
    return .none;
}

/// Track what the mouse is over. Returns true if that changed what's
/// drawn.
pub fn setHover(self: *Chrome, hit: Hit) bool {
    // The caption draws nothing for hover. A pane shows its buttons.
    const h: Hit = if (hit == .caption or hit == .divider) .none else hit;
    if (self.hover.eql(h)) return false;
    self.hover = h;
    self.tip = .none;
    return true;
}

/// Buttons that are only an icon, which tooltips name.
pub fn hasTip(hit: Hit) bool {
    return switch (hit) {
        .toggle_mode, .new_tab, .forget_host, .close_tab, .split_right, .split_down, .zoom => true,
        else => false,
    };
}

/// Show the tooltip of the button under the mouse, if it has one.
/// Returns true if that changed what's drawn.
pub fn showTip(self: *Chrome) bool {
    if (!hasTip(self.hover) or self.pressed != .none or self.tip.eql(self.hover)) return false;
    self.tip = self.hover;
    return true;
}

pub fn hideTip(self: *Chrome) bool {
    if (self.tip == .none) return false;
    self.tip = .none;
    return true;
}

pub fn setPressed(self: *Chrome, hit: Hit) bool {
    if (self.pressed.eql(hit)) return false;
    self.pressed = hit;
    return true;
}

pub fn toggleMode(self: *Chrome) void {
    self.mode = switch (self.mode) {
        .sidebar => .tabs,
        .tabs => .sidebar,
    };
    self.hover = .none;
    self.pressed = .none;
    self.tip = .none;
}

pub fn paint(self: *const Chrome, p: *Painter, l: *const Layout, view: *const View) void {
    p.fill(l.titlebar, self.theme.ground);
    switch (self.mode) {
        inline else => |m| Impl(m).paint(self, p, l, view),
    }
    p.pushClip(l.terminal);
    panes.paint(self, p, l, view);
    p.popClip();
    if (view.dialog) |d| modal.paint(self, p, l.terminal, d, .{
        .focused = view.focused,
        .caret_visible = view.caret_visible,
        .spinner = view.spinner,
        .terminal_bg = view.terminal_bg,
    });
    p.appIcon(l.icon);
    self.paintToggle(p, l, view);
    self.paintCaptionButtons(p, l, view);
    self.paintTip(p, l, view);
}

/// What a button's tooltip says, and the key that does the same, if
/// there is one.
fn tipText(self: *const Chrome, view: *const View, hit: Hit) struct { []const u16, []const u16 } {
    const none: []const u16 = &.{};
    return switch (hit) {
        .toggle_mode => .{ switch (self.mode) {
            .sidebar => L("Hide sidebar"),
            .tabs => L("Show sidebar"),
        }, none },
        .new_tab => |g| if (g < view.groups.len and view.groups[g].kind == .disconnected)
            .{ L("Connect"), none }
        else
            .{ L("New tab"), if (g == view.activeGroup()) view.new_tab_key else none },
        .forget_host => .{ L("Forget host"), none },
        .split_right => .{ L("Split right"), none },
        .split_down => .{ L("Split down"), none },
        .zoom => |i| .{ if (i < view.panes.len and view.panes[i].zoomed) L("Unzoom") else L("Zoom"), none },
        .close_tab => |i| .{ L("Close tab"), if (i == view.active) view.close_tab_key else none },
        else => .{ none, none },
    };
}

/// The button `hit` is, if it's on screen.
fn buttonRect(self: *const Chrome, l: *const Layout, view: *const View, hit: Hit) ?Rect {
    if (hit == .toggle_mode) return l.toggle;
    if (panes.rect(self, view, hit)) |r| return r;
    return switch (self.mode) {
        inline else => |m| Impl(m).buttonRect(self, l, view, hit),
    };
}

/// The tooltip under its button, or over it if there's no room below,
/// kept inside the window.
fn paintTip(self: *const Chrome, p: *Painter, l: *const Layout, view: *const View) void {
    if (self.tip == .none) return;
    const anchor = self.buttonRect(l, view, self.tip) orelse return;
    const label, const key = self.tipText(view, self.tip);
    if (label.len == 0) return;
    const font = self.fonts.tip;
    const pad = self.px(9);
    const gap = self.px(12);
    const label_w = @ceil(self.fonts.measure(label, font));
    const key_w = if (key.len > 0) @ceil(self.fonts.measure(key, font)) else 0;
    const w = pad + label_w + (if (key.len > 0) gap + key_w else 0) + pad;
    const h = self.px(26);
    const margin = self.px(8);
    const offset = self.px(6);
    var r: Rect = .{
        .x = @round(std.math.clamp(anchor.x + (anchor.w - w) / 2, margin, @max(margin, l.window.w - margin - w))),
        .y = anchor.bottom() + offset,
        .w = w,
        .h = h,
    };
    if (r.bottom() > l.window.h - margin) r.y = anchor.y - offset - h;

    const radius = self.px(6);
    self.paintShadow(p, r, radius, 3, 1);
    self.fillBordered(p, r, radius, self.theme.dialog, self.theme.dialog_outline);
    p.text(label, font, .{ .x = r.x + pad, .y = r.y, .w = label_w, .h = h }, self.theme.text_strong);
    if (key.len > 0) p.text(key, font, .{ .x = r.right() - pad - key_w, .y = r.y, .w = key_w, .h = h }, self.theme.text_muted);
}

/// A soft shadow around the rounded rect `r`: `rings` rings `step` DIPs
/// apart, each faint, so they add up to a fade outward.
pub fn paintShadow(self: *const Chrome, p: *Painter, r: Rect, radius: f32, rings: f32, step: f32) void {
    var i = rings;
    while (i > 0) : (i -= 1) {
        const spread = self.px(i * step);
        const ring: Rect = .{ .x = r.x - spread, .y = r.y - spread, .w = r.w + 2 * spread, .h = r.h + 2 * spread };
        p.fillRounded(ring, radius + spread, .{ 0, 0, 0, 0.06 });
    }
}

pub const ButtonState = enum { rest, hover, pressed };

pub fn buttonState(self: *const Chrome, hit: Hit) ButtonState {
    if (!self.hover.eql(hit)) return .rest;
    return if (self.pressed.eql(hit)) .pressed else .hover;
}

/// The active tab's title, centered in the title bar.
pub fn paintTitle(self: *const Chrome, p: *Painter, l: *const Layout, view: *const View) void {
    const color = if (view.focused) self.theme.text_muted else self.theme.text_inactive;
    p.text(view.title(), self.fonts.title, l.title.inset(self.px(8), 0), color);
}

fn paintToggle(self: *const Chrome, p: *Painter, l: *const Layout, view: *const View) void {
    const r = l.toggle;
    switch (self.buttonState(.toggle_mode)) {
        .rest => {},
        .hover => p.fill(r, self.theme.button_hover),
        .pressed => p.fill(r, self.theme.button_pressed),
    }
    const color = if (view.focused) self.theme.text else self.theme.text_inactive;
    const size = self.px(20);
    self.drawIcon(p, .panel_left, r.center(size, size), color);
}

fn paintCaptionButtons(self: *const Chrome, p: *Painter, l: *const Layout, view: *const View) void {
    const glyph = if (view.focused) self.theme.text else self.theme.text_inactive;
    const w = self.stroke();
    const g = self.px(10);

    for ([_]Hit{ .minimize, .maximize, .close }, [_]Rect{ l.minimize, l.maximize, l.close }) |hit, r| {
        const state = self.buttonState(hit);
        const bg: ?Color = switch (state) {
            .rest => null,
            .hover => if (hit == .close) self.theme.close_hover else self.theme.button_hover,
            .pressed => if (hit == .close) self.theme.close_pressed else self.theme.button_pressed,
        };
        if (bg) |c| p.fill(r, c);
        const color = if (hit == .close and state != .rest) self.theme.close_glyph else glyph;
        const box = r.center(g, g);
        switch (hit) {
            .minimize => {
                const y = crisp(box.y + g / 2, w);
                p.line(box.x, y, box.right(), y, w, color);
            },
            .maximize => if (view.maximized) {
                // Restore: a window behind another.
                const d = self.px(2);
                const front: Rect = .{ .x = box.x, .y = box.y + d, .w = g - d, .h = g - d };
                p.strokeRounded(.{ .x = box.x + d, .y = box.y, .w = g - d, .h = g - d }, self.px(1.5), w, color);
                p.fill(front, bg orelse self.theme.ground);
                p.strokeRounded(front, self.px(1.5), w, color);
            } else {
                p.strokeRounded(box, self.px(1.5), w, color);
            },
            .close => {
                p.line(box.x, box.y, box.right(), box.bottom(), w, color);
                p.line(box.right(), box.y, box.x, box.bottom(), w, color);
            },
            else => unreachable,
        }
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
pub fn paintEditText(self: *const Chrome, p: *Painter, inner: Rect, field: *const TextField, opts: EditTextOptions) void {
    var dots: [TextField.max_len]u16 = undefined;
    const text = if (opts.mask) dots: {
        @memset(dots[0..field.len], 0x25CF);
        break :dots dots[0..field.len];
    } else field.text();
    const font = self.fonts.body;

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
pub fn fillBordered(self: *const Chrome, p: *Painter, r: Rect, radius: f32, fill: Color, border: Color) void {
    const w = self.stroke();
    p.fillRounded(r, radius, border);
    p.fillRounded(r.inset(w, w), @max(0, radius - w), fill);
}

/// The width of icon strokes.
pub fn stroke(self: *const Chrome) f32 {
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
pub fn drawIcon(self: *const Chrome, p: *Painter, name: Painter.Lucide, box: Rect, color: Color) void {
    p.lucideIcon(name, box, self.stroke(), color);
}

/// Text formats for the chrome, sized for the current scale. All lay out
/// one line, centered vertically, trimmed with an ellipsis.
pub const Fonts = struct {
    factory: *dwrite.IFactory2,
    /// List rows and buttons.
    body: *dwrite.ITextFormat,
    /// The active row.
    body_strong: *dwrite.ITextFormat,
    /// The window title, centered.
    title: *dwrite.ITextFormat,
    /// Section headers in the list.
    section: *dwrite.ITextFormat,
    /// Key hints, centered.
    hint: *dwrite.ITextFormat,
    /// Tooltips.
    tip: *dwrite.ITextFormat,
    /// Numbers that change in place, like the stats.
    mono: *dwrite.ITextFormat,
    /// A dialog's title.
    heading: *dwrite.ITextFormat,
    /// Paragraphs, wrapped, from the top.
    prose: *dwrite.ITextFormat,
    /// Paths and fingerprints, wrapped anywhere they must be.
    mono_prose: *dwrite.ITextFormat,
    /// Button labels, centered.
    button: *dwrite.ITextFormat,
    button_strong: *dwrite.ITextFormat,

    const ui_families = [_][:0]const u16{ L("Segoe UI Variable Text"), L("Segoe UI") };
    const mono_families = [_][:0]const u16{ L("Cascadia Mono"), L("Consolas") };

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

        var self: Fonts = undefined;
        self.factory = f;
        const one_line: ?u32 = null;
        const specs = .{
            .{ "body", ui, dwrite.FONT_WEIGHT.NORMAL, 13, dwrite.TEXT_ALIGNMENT_LEADING, one_line },
            .{ "body_strong", ui, dwrite.FONT_WEIGHT.SEMI_BOLD, 13, dwrite.TEXT_ALIGNMENT_LEADING, one_line },
            .{ "title", ui, dwrite.FONT_WEIGHT.NORMAL, 12.5, dwrite.TEXT_ALIGNMENT_CENTER, one_line },
            .{ "section", ui, dwrite.FONT_WEIGHT.SEMI_BOLD, 11, dwrite.TEXT_ALIGNMENT_LEADING, one_line },
            .{ "hint", ui, dwrite.FONT_WEIGHT.NORMAL, 10.5, dwrite.TEXT_ALIGNMENT_CENTER, one_line },
            .{ "tip", ui, dwrite.FONT_WEIGHT.NORMAL, 12, dwrite.TEXT_ALIGNMENT_LEADING, one_line },
            .{ "mono", mono, dwrite.FONT_WEIGHT.NORMAL, 10.5, dwrite.TEXT_ALIGNMENT_LEADING, one_line },
            .{ "heading", ui, dwrite.FONT_WEIGHT.SEMI_BOLD, 15, dwrite.TEXT_ALIGNMENT_LEADING, one_line },
            .{ "prose", ui, dwrite.FONT_WEIGHT.NORMAL, 12.5, dwrite.TEXT_ALIGNMENT_LEADING, @as(?u32, dwrite.WORD_WRAPPING_WRAP) },
            .{ "mono_prose", mono, dwrite.FONT_WEIGHT.NORMAL, 12, dwrite.TEXT_ALIGNMENT_LEADING, @as(?u32, dwrite.WORD_WRAPPING_EMERGENCY_BREAK) },
            .{ "button", ui, dwrite.FONT_WEIGHT.NORMAL, 13, dwrite.TEXT_ALIGNMENT_CENTER, one_line },
            .{ "button_strong", ui, dwrite.FONT_WEIGHT.SEMI_BOLD, 13, dwrite.TEXT_ALIGNMENT_CENTER, one_line },
        };
        var made: usize = 0;
        errdefer inline for (specs, 0..) |spec, i| {
            if (i < made) com.release(@field(self, spec[0]));
        };
        inline for (specs) |spec| {
            @field(self, spec[0]) = try createFormat(f, spec[1], spec[2], spec[3] * scale, spec[4], spec[5]);
            made += 1;
        }
        return self;
    }

    fn deinit(self: *Fonts) void {
        inline for (.{ "body", "body_strong", "title", "section", "hint", "tip", "mono", "heading", "prose", "mono_prose", "button", "button_strong" }) |name| com.release(@field(self, name));
        com.release(self.factory);
        self.* = undefined;
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
        var text_layout: ?*dwrite.ITextLayout = null;
        const hr = self.factory.createTextLayout(text, format, width, unbounded, &text_layout);
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

test "layout and hit testing" {
    var chrome: Chrome = .{ .scale = 1, .fonts = undefined, .theme = undefined };
    const view: View = .{
        .groups = &.{.{ .label = &.{}, .tabs = 2, .kind = .local }},
        .tabs = &.{ .{ .title = &.{}, .activity = false }, .{ .title = &.{}, .activity = true } },
        .active = 0,
        .panes = &.{.{ .rect = .{ .x = 240, .y = 36, .w = 760, .h = 564 }, .focused = true, .splittable = false, .zoomable = false, .zoomed = false, .bg = .{ 0, 0, 0, 1 } }},
        .focused = true,
        .maximized = false,
        .terminal_bg = .{ 0, 0, 0, 1 },
    };
    var l = chrome.layout(1000, 600);
    try std.testing.expectEqual(Hit.close, chrome.hitTest(&l, &view, 999, 5));
    try std.testing.expectEqual(Hit.caption, chrome.hitTest(&l, &view, 500, 5));
    try std.testing.expectEqual(Hit.toggle_mode, chrome.hitTest(&l, &view, l.toggle.x + 1, 5));
    try std.testing.expectEqual(Hit.caption, chrome.hitTest(&l, &view, l.icon.x + 1, l.icon.y + 1));
    try std.testing.expectEqual(Hit{ .terminal = 0 }, chrome.hitTest(&l, &view, l.terminal.x + 1, l.terminal.y + 1));
    try std.testing.expect(l.list.w > 0 and l.terminal.x == l.list.right());

    chrome.toggleMode();
    l = chrome.layout(1000, 600);
    try std.testing.expectEqual(@as(f32, 0), l.list.w);
    try std.testing.expectEqual(@as(f32, 0), l.terminal.x);
    try std.testing.expectEqual(l.window.w, l.terminal.w);
}

test crisp {
    try std.testing.expectEqual(@as(f32, 10.5), crisp(10.2, 1));
    try std.testing.expectEqual(@as(f32, 10), crisp(10.2, 2));
}
