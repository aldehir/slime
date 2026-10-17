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

/// Stroke an arc of the circle at (`cx`, `cy`) with radius `r`, from
/// `start` radians clockwise through `sweep` (under a full turn), `width`
/// thick.
pub fn arc(self: *Painter, cx: f32, cy: f32, r: f32, start: f32, sweep: f32, width: f32, c: Color) void {
    var geometry: ?*d2d1.IPathGeometry = null;
    com.check(self.factory.createPathGeometry(&geometry), "ID2D1Factory::CreatePathGeometry") catch return;
    defer com.releaseOpt(&geometry);
    var sink: ?*d2d1.IGeometrySink = null;
    com.check(geometry.?.open(&sink), "ID2D1PathGeometry::Open") catch return;
    defer com.releaseOpt(&sink);

    const end = start + sweep;
    sink.?.beginFigure(.{ .x = cx + r * @cos(start), .y = cy + r * @sin(start) }, d2d1.FIGURE_BEGIN_HOLLOW);
    sink.?.addArc(&.{
        .point = .{ .x = cx + r * @cos(end), .y = cy + r * @sin(end) },
        .size = .{ .width = r, .height = r },
        .sweepDirection = d2d1.SWEEP_DIRECTION_CLOCKWISE,
        .arcSize = if (sweep > std.math.pi) d2d1.ARC_SIZE_LARGE else d2d1.ARC_SIZE_SMALL,
    });
    sink.?.endFigure(d2d1.FIGURE_END_OPEN);
    com.check(sink.?.close(), "ID2D1GeometrySink::Close") catch return;
    self.ctx.drawGeometry(geometry.?, self.color(c), width);
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

/// Pixels the renderer captured, for drawing scaled.
pub const Image = struct {
    bitmap: *d2d1.IBitmap1,
    w: f32,
    h: f32,
};

/// Draw `img` scaled into `r` with high-quality filtering, inside rounded
/// corners of `radius`, at `opacity`.
pub fn image(self: *Painter, img: Image, r: Rect, radius: f32, opacity: f32) void {
    var mask: ?*d2d1.IRoundedRectangleGeometry = null;
    com.check(self.factory.createRoundedRectangleGeometry(&.{ .rect = r.d2d(), .radiusX = radius, .radiusY = radius }, &mask), "ID2D1Factory::CreateRoundedRectangleGeometry") catch return;
    defer com.releaseOpt(&mask);
    self.ctx.pushLayer(&.{ .contentBounds = r.d2d(), .geometricMask = mask, .opacity = opacity });
    self.ctx.drawBitmap(img.bitmap, &r.d2d(), 1, d2d1.INTERPOLATION_MODE_HIGH_QUALITY_CUBIC);
    self.ctx.popLayer();
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
