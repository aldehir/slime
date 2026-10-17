//! The window's own UI around the terminal, drawn with Direct2D over each
//! frame: a title bar with caption buttons, and the list of sessions.
//!
//! The session list has two layouts (`Mode`), each a module with the same
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

pub const Rect = Painter.Rect;
pub const Color = Painter.Color;

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
/// Pixels per DIP.
scale: f32,
fonts: Fonts,
theme: Theme,
/// What the mouse is over, and what a button went down on.
hover: Hit = .none,
pressed: Hit = .none,

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
    /// The button that opens a session in group `i`, connecting first
    /// if it's a host that isn't connected.
    new_session: usize,
    /// The button that removes host group `i` from the list.
    forget_host: usize,
    /// The button that connects to a host, or its field.
    connect,
    session: usize,
    close_session: usize,
    terminal,

    pub fn eql(a: Hit, b: Hit) bool {
        return std.meta.eql(a, b);
    }
};

/// The window's state, as the chrome shows it.
pub const View = struct {
    /// Where sessions run, in the order listed. Their sessions come one
    /// group after another.
    groups: []const Group,
    sessions: []const Session,
    active: usize,
    /// The host being typed after "Connect" was clicked, if it was.
    connect: ?*const TextField = null,
    /// The on phase of the caret's blink, while focused.
    caret_visible: bool = false,
    /// The window has keyboard focus.
    focused: bool,
    maximized: bool,
    /// The terminal's default background.
    terminal_bg: Color,

    /// Frame stats, when built with `-Dstats`. Lines end with LF.
    stats: []const u16 = &.{},

    pub const Group = struct {
        label: []const u16,
        /// How many of `sessions` are in it.
        sessions: usize,
        kind: Kind,

        pub const Kind = enum {
            local,
            /// A host with a live connection, which new sessions join.
            connected,
            /// A remembered host that new sessions connect to.
            disconnected,
        };
    };

    pub const Session = struct {
        title: []const u16,
        /// Output arrived while it wasn't shown.
        activity: bool,
    };

    pub fn title(self: *const View) []const u16 {
        return if (self.active < self.sessions.len) self.sessions[self.active].title else &.{};
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
    /// The session list's own area. Empty when it's in the title bar.
    list: Rect = .{},
    terminal: Rect = .{},
    /// The radius of the terminal area's top-left corner.
    corner: f32 = 0,
    /// Space inside the terminal area, before the grid, at its left and
    /// top, which border the chrome. Added to the configured padding.
    inset: f32 = 0,
};

pub fn init(dpi: u32, theme: Theme) !Chrome {
    const scale = scaleFor(dpi);
    return .{ .scale = scale, .fonts = try .init(scale), .theme = theme };
}

pub fn deinit(self: *Chrome) void {
    self.fonts.deinit();
}

pub fn setDpi(self: *Chrome, dpi: u32) !void {
    const scale = scaleFor(dpi);
    const fonts: Fonts = try .init(scale);
    self.fonts.deinit();
    self.fonts = fonts;
    self.scale = scale;
}

fn scaleFor(dpi: u32) f32 {
    return @as(f32, @floatFromInt(dpi)) / 96.0;
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
        .inset = self.px(10),
    };
    switch (self.mode) {
        inline else => |m| Impl(m).layout(self, &l),
    }
    return l;
}

pub fn hitTest(self: *const Chrome, l: *const Layout, view: *const View, x: f32, y: f32) Hit {
    if (l.terminal.contains(x, y)) return .terminal;
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
    // The terminal draws nothing for hover.
    const h: Hit = if (hit == .terminal or hit == .caption) .none else hit;
    if (self.hover.eql(h)) return false;
    self.hover = h;
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
}

pub fn paint(self: *const Chrome, p: *Painter, l: *const Layout, view: *const View) void {
    p.fill(l.titlebar, self.theme.ground);
    switch (self.mode) {
        inline else => |m| Impl(m).paint(self, p, l, view),
    }
    if (l.corner > 0) p.cornerMask(l.terminal.x, l.terminal.y, l.corner, self.theme.ground);
    p.appIcon(l.icon);
    self.paintToggle(p, l, view);
    self.paintCaptionButtons(p, l, view);
}

pub const ButtonState = enum { rest, hover, pressed };

pub fn buttonState(self: *const Chrome, hit: Hit) ButtonState {
    if (!self.hover.eql(hit)) return .rest;
    return if (self.pressed.eql(hit)) .pressed else .hover;
}

/// The active session's title, centered in the title bar.
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
    /// Numbers that change in place, like the stats.
    mono: *dwrite.ITextFormat,

    const L = std.unicode.utf8ToUtf16LeStringLiteral;
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
        const specs = .{
            .{ "body", ui, dwrite.FONT_WEIGHT.NORMAL, 13, dwrite.TEXT_ALIGNMENT_LEADING },
            .{ "body_strong", ui, dwrite.FONT_WEIGHT.SEMI_BOLD, 13, dwrite.TEXT_ALIGNMENT_LEADING },
            .{ "title", ui, dwrite.FONT_WEIGHT.NORMAL, 12.5, dwrite.TEXT_ALIGNMENT_CENTER },
            .{ "section", ui, dwrite.FONT_WEIGHT.SEMI_BOLD, 11, dwrite.TEXT_ALIGNMENT_LEADING },
            .{ "hint", ui, dwrite.FONT_WEIGHT.NORMAL, 10.5, dwrite.TEXT_ALIGNMENT_CENTER },
            .{ "mono", mono, dwrite.FONT_WEIGHT.NORMAL, 10.5, dwrite.TEXT_ALIGNMENT_LEADING },
        };
        var made: usize = 0;
        errdefer inline for (specs, 0..) |spec, i| {
            if (i < made) com.release(@field(self, spec[0]));
        };
        inline for (specs) |spec| {
            @field(self, spec[0]) = try createFormat(f, spec[1], spec[2], spec[3] * scale, spec[4]);
            made += 1;
        }
        return self;
    }

    fn deinit(self: *Fonts) void {
        inline for (.{ "body", "body_strong", "title", "section", "hint", "mono" }) |name| com.release(@field(self, name));
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

    fn createFormat(factory: *dwrite.IFactory2, family: [:0]const u16, weight: dwrite.FONT_WEIGHT, size: f32, alignment: u32) !*dwrite.ITextFormat {
        var format: ?*dwrite.ITextFormat = null;
        try com.check(factory.createTextFormat(family.ptr, weight, size, &format), "IDWriteFactory::CreateTextFormat");
        errdefer com.releaseOpt(&format);
        const f = format.?;
        try com.check(f.setTextAlignment(alignment), "IDWriteTextFormat::SetTextAlignment");
        try com.check(f.setParagraphAlignment(dwrite.PARAGRAPH_ALIGNMENT_CENTER), "IDWriteTextFormat::SetParagraphAlignment");
        try com.check(f.setWordWrapping(dwrite.WORD_WRAPPING_NO_WRAP), "IDWriteTextFormat::SetWordWrapping");
        var sign: ?*dwrite.IInlineObject = null;
        try com.check(factory.createEllipsisTrimmingSign(f, &sign), "IDWriteFactory::CreateEllipsisTrimmingSign");
        defer com.releaseOpt(&sign);
        try com.check(f.setTrimming(&.{ .granularity = dwrite.TRIMMING_GRANULARITY_CHARACTER }, sign), "IDWriteTextFormat::SetTrimming");
        return f;
    }

    /// The width of `text` laid out in `format`, in pixels.
    pub fn measure(self: *const Fonts, text: []const u16, format: *dwrite.ITextFormat) f32 {
        var text_layout: ?*dwrite.ITextLayout = null;
        // DirectWrite rejects infinite and huge bounds.
        const unbounded = 100_000;
        const hr = self.factory.createTextLayout(text, format, unbounded, unbounded, &text_layout);
        if (hr < 0) {
            com.check(hr, "IDWriteFactory::CreateTextLayout") catch {};
            return 0;
        }
        defer com.releaseOpt(&text_layout);
        var metrics: dwrite.TEXT_METRICS = undefined;
        if (text_layout.?.getMetrics(&metrics) < 0) return 0;
        return metrics.widthIncludingTrailingWhitespace;
    }
};

test "layout and hit testing" {
    var chrome: Chrome = .{ .scale = 1, .fonts = undefined, .theme = undefined };
    const view: View = .{
        .groups = &.{.{ .label = &.{}, .sessions = 2, .kind = .local }},
        .sessions = &.{ .{ .title = &.{}, .activity = false }, .{ .title = &.{}, .activity = true } },
        .active = 0,
        .focused = true,
        .maximized = false,
        .terminal_bg = .{ 0, 0, 0, 1 },
    };
    var l = chrome.layout(1000, 600);
    try std.testing.expectEqual(Hit.close, chrome.hitTest(&l, &view, 999, 5));
    try std.testing.expectEqual(Hit.caption, chrome.hitTest(&l, &view, 500, 5));
    try std.testing.expectEqual(Hit.toggle_mode, chrome.hitTest(&l, &view, l.toggle.x + 1, 5));
    try std.testing.expectEqual(Hit.caption, chrome.hitTest(&l, &view, l.icon.x + 1, l.icon.y + 1));
    try std.testing.expectEqual(Hit.terminal, chrome.hitTest(&l, &view, l.terminal.x + 1, l.terminal.y + 1));
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
