//! Direct2D drawing for the window's chrome, in pixels. Handed out by the
//! renderer for the UI pass of a frame, which is drawn over the terminal.
const Painter = @This();

const std = @import("std");
const win32 = @import("../win32/win32.zig");
const com = win32.com;
const d2d1 = win32.d2d1;
const dwrite = win32.dwrite;
const lucide_svgs = @import("lucide");

ctx: *d2d1.IDeviceContext,
factory: *d2d1.IFactory1,
/// One brush, recolored for each primitive.
brush: *d2d1.ISolidColorBrush,
icon: ?Icon = null,
lucide: ?*const LucideIcons = null,

/// An SVG image parsed once, drawn at any size.
pub const Icon = struct {
    ctx: *d2d1.IDeviceContext5,
    doc: *d2d1.ISvgDocument,
    /// The SVG's width and height, which it's parsed at and scaled from.
    size: f32,

    /// Parse `svg`, whose root is `size` x `size`. Null if Direct2D can't
    /// draw SVG (before Windows 10 1703) or the SVG doesn't parse.
    pub fn init(ctx: *d2d1.IDeviceContext, svg: []const u8, size: f32) ?Icon {
        const ctx5 = com.query(ctx, d2d1.IDeviceContext5) orelse return null;
        var doc: ?*d2d1.ISvgDocument = null;
        defer if (doc == null) com.release(ctx5);
        const stream = win32.SHCreateMemStream(svg.ptr, @intCast(svg.len)) orelse return null;
        defer com.release(stream);
        com.check(ctx5.createSvgDocument(stream, .{ .width = size, .height = size }, &doc), "ID2D1DeviceContext5::CreateSvgDocument") catch return null;
        return .{ .ctx = ctx5, .doc = doc.?, .size = size };
    }

    pub fn deinit(self: Icon) void {
        com.release(self.doc);
        com.release(self.ctx);
    }

    /// Draw scaled to the square `r`.
    fn draw(self: Icon, r: Rect) void {
        const s = r.w / self.size;
        self.ctx.setTransform(&.{ s, 0, 0, s, r.x, r.y });
        self.ctx.drawSvgDocument(self.doc);
        self.ctx.setTransform(&.{ 1, 0, 0, 1, 0, 0 });
    }
};

/// Lucide icons (see assets/icons/lucide), by name.
pub const Lucide = std.meta.DeclEnum(lucide_svgs);
pub const LucideIcons = std.EnumArray(Lucide, Icon);

/// Parse every Lucide icon. Null if one fails, as where Direct2D can't
/// draw SVG.
pub fn initLucide(ctx: *d2d1.IDeviceContext) ?LucideIcons {
    var icons: LucideIcons = undefined;
    inline for (comptime std.enums.values(Lucide), 0..) |name, i| {
        icons.set(name, Icon.init(ctx, @field(lucide_svgs, @tagName(name)), 24) orelse {
            for (std.enums.values(Lucide)[0..i]) |done| icons.get(done).deinit();
            return null;
        });
    }
    return icons;
}

pub fn deinitLucide(icons: *const LucideIcons) void {
    for (icons.values) |icon| icon.deinit();
}

/// Straight (not premultiplied) RGBA.
pub const Color = [4]f32;

pub fn rgb(hex: u24) Color {
    return rgba(hex, 1);
}

pub fn rgba(hex: u24, a: f32) Color {
    return .{
        @as(f32, @floatFromInt(hex >> 16)) / 255.0,
        @as(f32, @floatFromInt(hex >> 8 & 0xff)) / 255.0,
        @as(f32, @floatFromInt(hex & 0xff)) / 255.0,
        a,
    };
}

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn right(self: Rect) f32 {
        return self.x + self.w;
    }

    pub fn bottom(self: Rect) f32 {
        return self.y + self.h;
    }

    pub fn contains(self: Rect, x: f32, y: f32) bool {
        return x >= self.x and x < self.right() and y >= self.y and y < self.bottom();
    }

    /// Shrunk by `dx` on the left and right and `dy` on the top and bottom.
    pub fn inset(self: Rect, dx: f32, dy: f32) Rect {
        return .{ .x = self.x + dx, .y = self.y + dy, .w = @max(0, self.w - 2 * dx), .h = @max(0, self.h - 2 * dy) };
    }

    /// A `w` x `h` rectangle centered in this one, on whole pixels.
    pub fn center(self: Rect, w: f32, h: f32) Rect {
        return .{ .x = @round(self.x + (self.w - w) / 2), .y = @round(self.y + (self.h - h) / 2), .w = w, .h = h };
    }

    fn d2d(self: Rect) d2d1.RECT_F {
        return .{ .left = self.x, .top = self.y, .right = self.right(), .bottom = self.bottom() };
    }
};

fn color(self: *Painter, c: Color) *d2d1.ISolidColorBrush {
    self.brush.setColor(&c);
    return self.brush;
}

pub fn fill(self: *Painter, r: Rect, c: Color) void {
    self.ctx.fillRectangle(&r.d2d(), self.color(c));
}

pub fn fillRounded(self: *Painter, r: Rect, radius: f32, c: Color) void {
    self.ctx.fillRoundedRectangle(&.{ .rect = r.d2d(), .radiusX = radius, .radiusY = radius }, self.color(c));
}

/// A rounded outline `width` thick, inside `r`.
pub fn strokeRounded(self: *Painter, r: Rect, radius: f32, width: f32, c: Color) void {
    const in = r.inset(width / 2, width / 2);
    self.ctx.drawRoundedRectangle(&.{ .rect = in.d2d(), .radiusX = radius, .radiusY = radius }, self.color(c), width);
}

pub fn line(self: *Painter, x0: f32, y0: f32, x1: f32, y1: f32, width: f32, c: Color) void {
    self.ctx.drawLine(.{ .x = x0, .y = y0 }, .{ .x = x1, .y = y1 }, self.color(c), width);
}

pub fn dot(self: *Painter, cx: f32, cy: f32, radius: f32, c: Color) void {
    self.ctx.fillEllipse(&.{ .point = .{ .x = cx, .y = cy }, .radiusX = radius, .radiusY = radius }, self.color(c));
}

pub const Corner = enum { top_left, top_right, bottom_left, bottom_right };

/// Fill the outside of rounded corners on `r`: the parts of the `radius`
/// squares in its corners that a rounded rectangle leaves out.
pub fn cornerMasks(self: *Painter, r: Rect, radius: f32, c: Color) void {
    if (radius <= 0) return;
    for (std.enums.values(Corner)) |corner| self.cornerMask(r, corner, radius, c);
}

/// Fill the outside of `r`'s rounded corner `corner`.
pub fn cornerMask(self: *Painter, r: Rect, corner: Corner, radius: f32, c: Color) void {
    // From the corner, along its horizontal edge, then around to its
    // vertical one. Mirroring one axis turns the arc the other way.
    const right = corner == .top_right or corner == .bottom_right;
    const bottom = corner == .bottom_left or corner == .bottom_right;
    const x = if (right) r.right() else r.x;
    const y = if (bottom) r.bottom() else r.y;
    const sx: f32 = if (right) -1 else 1;
    const sy: f32 = if (bottom) -1 else 1;
    var geometry: ?*d2d1.IPathGeometry = null;
    com.check(self.factory.createPathGeometry(&geometry), "ID2D1Factory::CreatePathGeometry") catch return;
    defer com.releaseOpt(&geometry);
    var sink: ?*d2d1.IGeometrySink = null;
    com.check(geometry.?.open(&sink), "ID2D1PathGeometry::Open") catch return;
    defer com.releaseOpt(&sink);

    sink.?.beginFigure(.{ .x = x, .y = y }, d2d1.FIGURE_BEGIN_FILLED);
    sink.?.addLine(.{ .x = x + sx * radius, .y = y });
    sink.?.addArc(&.{
        .point = .{ .x = x, .y = y + sy * radius },
        .size = .{ .width = radius, .height = radius },
        .sweepDirection = if (sx * sy > 0) d2d1.SWEEP_DIRECTION_COUNTER_CLOCKWISE else d2d1.SWEEP_DIRECTION_CLOCKWISE,
    });
    sink.?.endFigure(d2d1.FIGURE_END_CLOSED);
    com.check(sink.?.close(), "ID2D1GeometrySink::Close") catch return;
    self.ctx.fillGeometry(geometry.?, self.color(c));
}

/// Draw text laid out by `format` (alignment, trimming) in `r`, clipped
/// to it.
pub fn text(self: *Painter, str: []const u16, format: *dwrite.ITextFormat, r: Rect, c: Color) void {
    if (str.len == 0 or r.w <= 0) return;
    self.ctx.drawText(str, format, &r.d2d(), self.color(c), d2d1.DRAW_TEXT_OPTIONS_CLIP);
}

/// Draw the app icon scaled to the square `r`, if there is one.
pub fn appIcon(self: *Painter, r: Rect) void {
    const icon = self.icon orelse return;
    icon.draw(r);
}

/// Draw the Lucide icon `name` scaled to the square `r`, its strokes
/// `width` pixels thick in `c`. Lucide strokes in `currentColor`, so
/// setting the root's `color` recolors the whole icon.
pub fn lucideIcon(self: *Painter, name: Lucide, r: Rect, width: f32, c: Color) void {
    const icon = (self.lucide orelse return).get(name);
    var root: ?*d2d1.ISvgElement = null;
    icon.doc.getRoot(&root);
    defer com.releaseOpt(&root);
    const stroke = width * icon.size / r.w;
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    com.check(root.?.setAttributeValue(L("color"), d2d1.SVG_ATTRIBUTE_POD_TYPE_COLOR, &c, @sizeOf(Color)), "ID2D1SvgElement::SetAttributeValue(color)") catch return;
    com.check(root.?.setAttributeValue(L("stroke-width"), d2d1.SVG_ATTRIBUTE_POD_TYPE_FLOAT, &stroke, @sizeOf(f32)), "ID2D1SvgElement::SetAttributeValue(stroke-width)") catch return;
    icon.draw(r);
}

pub fn pushClip(self: *Painter, r: Rect) void {
    self.ctx.pushAxisAlignedClip(&r.d2d());
}

pub fn popClip(self: *Painter) void {
    self.ctx.popAxisAlignedClip();
}

test "Rect" {
    const r: Rect = .{ .x = 10, .y = 20, .w = 30, .h = 40 };
    try std.testing.expect(r.contains(10, 20));
    try std.testing.expect(!r.contains(40, 20));
    try std.testing.expectEqual(Rect{ .x = 12, .y = 21, .w = 26, .h = 38 }, r.inset(2, 1));
    try std.testing.expectEqual(Rect{ .x = 20, .y = 35, .w = 10, .h = 10 }, r.center(10, 10));
}
