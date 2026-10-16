//! Direct2D drawing for the window's chrome, in pixels. Handed out by the
//! renderer for the UI pass of a frame, which is drawn over the terminal.
const Painter = @This();

const std = @import("std");
const win32 = @import("../win32/win32.zig");
const com = win32.com;
const d2d1 = win32.d2d1;
const dwrite = win32.dwrite;

ctx: *d2d1.IDeviceContext,
factory: *d2d1.IFactory1,
/// One brush, recolored for each primitive.
brush: *d2d1.ISolidColorBrush,

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

/// Fill the outside of a rounded top-left corner at (`x`, `y`): the part
/// of the `radius` square that a rounded rectangle there leaves out.
pub fn cornerMask(self: *Painter, x: f32, y: f32, radius: f32, c: Color) void {
    var geometry: ?*d2d1.IPathGeometry = null;
    com.check(self.factory.createPathGeometry(&geometry), "ID2D1Factory::CreatePathGeometry") catch return;
    defer com.releaseOpt(&geometry);
    var sink: ?*d2d1.IGeometrySink = null;
    com.check(geometry.?.open(&sink), "ID2D1PathGeometry::Open") catch return;
    defer com.releaseOpt(&sink);

    sink.?.beginFigure(.{ .x = x, .y = y }, d2d1.FIGURE_BEGIN_FILLED);
    sink.?.addLine(.{ .x = x + radius, .y = y });
    sink.?.addArc(&.{
        .point = .{ .x = x, .y = y + radius },
        .size = .{ .width = radius, .height = radius },
        .sweepDirection = d2d1.SWEEP_DIRECTION_COUNTER_CLOCKWISE,
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
