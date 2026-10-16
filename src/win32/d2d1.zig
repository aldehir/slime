//! Direct2D interfaces, for drawing the window's chrome onto the swap
//! chain. Slot numbers are from d2d1.h / d2d1_1.h.

const win32 = @import("win32.zig");
const com = @import("com.zig");
const dxgi = @import("dxgi.zig");
const dwrite = @import("dwrite.zig");

const HRESULT = win32.HRESULT;
const GUID = win32.GUID;

pub const FACTORY_TYPE_SINGLE_THREADED: u32 = 0;
pub const ALPHA_MODE_IGNORE: u32 = 3;
pub const BITMAP_OPTIONS_TARGET: u32 = 0x1;
pub const BITMAP_OPTIONS_CANNOT_DRAW: u32 = 0x2;
pub const TEXT_ANTIALIAS_MODE_GRAYSCALE: u32 = 2;
pub const DRAW_TEXT_OPTIONS_CLIP: u32 = 0x2;
pub const FIGURE_BEGIN_FILLED: u32 = 0;
pub const FIGURE_END_CLOSED: u32 = 1;
pub const SWEEP_DIRECTION_COUNTER_CLOCKWISE: u32 = 0;
pub const SWEEP_DIRECTION_CLOCKWISE: u32 = 1;
pub const ARC_SIZE_SMALL: u32 = 0;

/// Premultiplied is not required: colors are straight RGBA.
pub const COLOR_F = [4]f32;

pub const POINT_2F = extern struct { x: f32, y: f32 };
pub const SIZE_F = extern struct { width: f32, height: f32 };

pub const RECT_F = extern struct {
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,
};

pub const ROUNDED_RECT = extern struct {
    rect: RECT_F,
    radiusX: f32,
    radiusY: f32,
};

pub const ELLIPSE = extern struct {
    point: POINT_2F,
    radiusX: f32,
    radiusY: f32,
};

pub const ARC_SEGMENT = extern struct {
    point: POINT_2F,
    size: SIZE_F,
    rotationAngle: f32 = 0,
    sweepDirection: u32,
    arcSize: u32 = ARC_SIZE_SMALL,
};

pub const PIXEL_FORMAT = extern struct {
    format: dxgi.FORMAT,
    alphaMode: u32,
};

pub const BITMAP_PROPERTIES1 = extern struct {
    pixelFormat: PIXEL_FORMAT,
    dpiX: f32 = 96,
    dpiY: f32 = 96,
    bitmapOptions: u32,
    colorContext: ?*anyopaque = null,
};

pub const IFactory1 = extern struct {
    vtable: com.VTable,

    pub const iid: GUID = .{
        .data1 = 0xbb12d362,
        .data2 = 0xdaee,
        .data3 = 0x4b9a,
        .data4 = .{ 0xaa, 0x1d, 0x14, 0xba, 0x40, 0x1c, 0xfa, 0x1f },
    };

    pub fn createPathGeometry(self: *IFactory1, out: *?*IPathGeometry) HRESULT {
        return com.call(self, 10, fn (*?*IPathGeometry) HRESULT, .{out});
    }

    pub fn createDevice(self: *IFactory1, device: *dxgi.IDevice, out: *?*IDevice) HRESULT {
        return com.call(self, 17, fn (*dxgi.IDevice, *?*IDevice) HRESULT, .{ device, out });
    }
};

pub const IDevice = extern struct {
    vtable: com.VTable,

    pub fn createDeviceContext(self: *IDevice, options: u32, out: *?*IDeviceContext) HRESULT {
        return com.call(self, 4, fn (u32, *?*IDeviceContext) HRESULT, .{ options, out });
    }
};

/// ID2D1DeviceContext, with the ID2D1RenderTarget methods it inherits.
pub const IDeviceContext = extern struct {
    vtable: com.VTable,

    pub fn createSolidColorBrush(self: *IDeviceContext, color: *const COLOR_F, out: *?*ISolidColorBrush) HRESULT {
        return com.call(self, 8, fn (*const COLOR_F, ?*const anyopaque, *?*ISolidColorBrush) HRESULT, .{ color, null, out });
    }

    pub fn drawLine(self: *IDeviceContext, p0: POINT_2F, p1: POINT_2F, brush: *ISolidColorBrush, width: f32) void {
        com.call(self, 15, fn (POINT_2F, POINT_2F, *ISolidColorBrush, f32, ?*anyopaque) void, .{ p0, p1, brush, width, null });
    }

    pub fn fillRectangle(self: *IDeviceContext, rect: *const RECT_F, brush: *ISolidColorBrush) void {
        com.call(self, 17, fn (*const RECT_F, *ISolidColorBrush) void, .{ rect, brush });
    }

    pub fn drawRoundedRectangle(self: *IDeviceContext, rect: *const ROUNDED_RECT, brush: *ISolidColorBrush, width: f32) void {
        com.call(self, 18, fn (*const ROUNDED_RECT, *ISolidColorBrush, f32, ?*anyopaque) void, .{ rect, brush, width, null });
    }

    pub fn fillRoundedRectangle(self: *IDeviceContext, rect: *const ROUNDED_RECT, brush: *ISolidColorBrush) void {
        com.call(self, 19, fn (*const ROUNDED_RECT, *ISolidColorBrush) void, .{ rect, brush });
    }

    pub fn fillEllipse(self: *IDeviceContext, ellipse: *const ELLIPSE, brush: *ISolidColorBrush) void {
        com.call(self, 21, fn (*const ELLIPSE, *ISolidColorBrush) void, .{ ellipse, brush });
    }

    pub fn fillGeometry(self: *IDeviceContext, geometry: *IPathGeometry, brush: *ISolidColorBrush) void {
        com.call(self, 23, fn (*IPathGeometry, *ISolidColorBrush, ?*anyopaque) void, .{ geometry, brush, null });
    }

    pub fn drawText(
        self: *IDeviceContext,
        text: []const u16,
        format: *dwrite.ITextFormat,
        rect: *const RECT_F,
        brush: *ISolidColorBrush,
        options: u32,
    ) void {
        com.call(self, 27, fn ([*]const u16, u32, *dwrite.ITextFormat, *const RECT_F, *ISolidColorBrush, u32, u32) void, .{
            text.ptr,
            @as(u32, @intCast(text.len)),
            format,
            rect,
            brush,
            options,
            dwrite.MEASURING_MODE_NATURAL,
        });
    }

    pub fn setTextAntialiasMode(self: *IDeviceContext, mode: u32) void {
        com.call(self, 34, fn (u32) void, .{mode});
    }

    pub fn pushAxisAlignedClip(self: *IDeviceContext, rect: *const RECT_F) void {
        // D2D1_ANTIALIAS_MODE_ALIASED: our clips are pixel aligned.
        com.call(self, 45, fn (*const RECT_F, u32) void, .{ rect, 1 });
    }

    pub fn popAxisAlignedClip(self: *IDeviceContext) void {
        com.call(self, 46, fn () void, .{});
    }

    pub fn beginDraw(self: *IDeviceContext) void {
        com.call(self, 48, fn () void, .{});
    }

    pub fn endDraw(self: *IDeviceContext) HRESULT {
        return com.call(self, 49, fn (?*u64, ?*u64) HRESULT, .{ null, null });
    }

    pub fn createBitmapFromDxgiSurface(
        self: *IDeviceContext,
        surface: *dxgi.ISurface,
        props: *const BITMAP_PROPERTIES1,
        out: *?*IBitmap1,
    ) HRESULT {
        return com.call(self, 62, fn (*dxgi.ISurface, *const BITMAP_PROPERTIES1, *?*IBitmap1) HRESULT, .{ surface, props, out });
    }

    pub fn setTarget(self: *IDeviceContext, target: ?*IBitmap1) void {
        com.call(self, 74, fn (?*IBitmap1) void, .{target});
    }
};

/// ID2D1DeviceContext5 (Windows 10 1703+), for SVG. Its slots are from
/// the Windows SDK's d2d1_3.h; Zig's mingw headers stop at
/// ID2D1DeviceContext3.
pub const IDeviceContext5 = extern struct {
    vtable: com.VTable,

    pub const iid: GUID = .{
        .data1 = 0x7836d248,
        .data2 = 0x68cc,
        .data3 = 0x4df6,
        .data4 = .{ 0xb9, 0xe8, 0xde, 0x99, 0x1b, 0xf6, 0x2e, 0xb7 },
    };

    /// A 3x2 matrix, row major: m11 m12 m21 m22 dx dy.
    pub fn setTransform(self: *IDeviceContext5, m: *const [6]f32) void {
        com.call(self, 30, fn (*const [6]f32) void, .{m});
    }

    pub fn createSvgDocument(self: *IDeviceContext5, stream: *win32.IStream, viewport: SIZE_F, out: *?*ISvgDocument) HRESULT {
        return com.call(self, 115, fn (*win32.IStream, SIZE_F, *?*ISvgDocument) HRESULT, .{ stream, viewport, out });
    }

    pub fn drawSvgDocument(self: *IDeviceContext5, doc: *ISvgDocument) void {
        com.call(self, 116, fn (*ISvgDocument) void, .{doc});
    }
};

pub const ISvgDocument = extern struct {
    vtable: com.VTable,

    /// The `<svg>` element, AddRef'd.
    pub fn getRoot(self: *ISvgDocument, out: *?*ISvgElement) void {
        com.call(self, 7, fn (*?*ISvgElement) void, .{out});
    }
};

/// D2D1_SVG_ATTRIBUTE_POD_TYPE
pub const SVG_ATTRIBUTE_POD_TYPE_FLOAT = 0;
pub const SVG_ATTRIBUTE_POD_TYPE_COLOR = 1;

pub const ISvgElement = extern struct {
    vtable: com.VTable,

    /// The SetAttributeValue overload taking a plain value. Slot 28, not
    /// the 30 its declaration order gives: MSVC groups a method's
    /// overloads at the first one's slot, in reverse order.
    pub fn setAttributeValue(self: *ISvgElement, name: [*:0]const u16, @"type": u32, value: *const anyopaque, size: u32) HRESULT {
        return com.call(self, 28, fn ([*:0]const u16, u32, *const anyopaque, u32) HRESULT, .{ name, @"type", value, size });
    }
};

pub const IBitmap1 = extern struct { vtable: com.VTable };

pub const ISolidColorBrush = extern struct {
    vtable: com.VTable,

    pub fn setColor(self: *ISolidColorBrush, color: *const COLOR_F) void {
        com.call(self, 8, fn (*const COLOR_F) void, .{color});
    }
};

pub const IPathGeometry = extern struct {
    vtable: com.VTable,

    pub fn open(self: *IPathGeometry, out: *?*IGeometrySink) HRESULT {
        return com.call(self, 17, fn (*?*IGeometrySink) HRESULT, .{out});
    }
};

pub const IGeometrySink = extern struct {
    vtable: com.VTable,

    pub fn beginFigure(self: *IGeometrySink, start: POINT_2F, begin: u32) void {
        com.call(self, 5, fn (POINT_2F, u32) void, .{ start, begin });
    }

    pub fn endFigure(self: *IGeometrySink, end: u32) void {
        com.call(self, 8, fn (u32) void, .{end});
    }

    pub fn close(self: *IGeometrySink) HRESULT {
        return com.call(self, 9, fn () HRESULT, .{});
    }

    pub fn addLine(self: *IGeometrySink, point: POINT_2F) void {
        com.call(self, 10, fn (POINT_2F) void, .{point});
    }

    pub fn addArc(self: *IGeometrySink, arc: *const ARC_SEGMENT) void {
        com.call(self, 14, fn (*const ARC_SEGMENT) void, .{arc});
    }
};

pub extern "d2d1" fn D2D1CreateFactory(
    factory_type: u32,
    iid: *const GUID,
    options: ?*const anyopaque,
    out: *?*anyopaque,
) callconv(.winapi) HRESULT;
