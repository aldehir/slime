//! Renders the app icon from assets/icon's SVGs. build.zig runs it on the
//! host:
//!
//!   icon <full.svg> <small.svg> <out.ico> <png-dir>
//!
//! Direct2D's SVG renderer rasterizes, WIC encodes PNGs. The .ico holds
//! a PNG-compressed image per size (Vista+). Sizes up to `small_max` use
//! the small SVG: no background, tight crop, bolder smile.
//!
//! Self-contained rather than importing src/win32, which belongs to the
//! app's module. Slot numbers for ID2D1DeviceContext5 are from the
//! Windows SDK's d2d1_3.h; Zig's mingw headers stop at DeviceContext3.

const std = @import("std");

const small_max = 48;

/// Small icons at 100-200% scale (16-32), large ones (32-64), and 256
/// for Explorer's big views. Windows downscales the next size up.
const ico_sizes = [_]u32{ 16, 20, 24, 28, 32, 40, 48, 56, 64, 128, 256 };
const png_sizes = [_]u32{ 16, 24, 32, 48, 64, 128, 256, 512, 1024 };

/// The SVGs' width and height. The render scales from it to each size.
const svg_size = 1024;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 5) {
        std.log.err("usage: icon <full.svg> <small.svg> <out.ico> <png-dir>", .{});
        std.process.exit(2);
    }

    const cwd = std.Io.Dir.cwd();
    const full = try cwd.readFileAlloc(io, args[1], arena, .limited(1 << 20));
    const small = try cwd.readFileAlloc(io, args[2], arena, .limited(1 << 20));

    try check(CoInitializeEx(null, COINIT_MULTITHREADED), "CoInitializeEx");
    defer CoUninitialize();
    var r: Renderer = undefined;
    try check(CoCreateInstance(&CLSID_WICImagingFactory, null, CLSCTX_INPROC_SERVER, &IWICImagingFactory.iid, @ptrCast(&r.wic)), "CoCreateInstance(WICImagingFactory)");
    defer release(r.wic);
    try check(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, &ID2D1Factory.iid, null, @ptrCast(&r.d2d)), "D2D1CreateFactory");
    defer release(r.d2d);

    var png_dir = try cwd.createDirPathOpen(io, args[4], .{});
    defer png_dir.close(io);
    for (png_sizes) |size| {
        const png = try r.png(arena, if (size <= small_max) small else full, size);
        const name = try std.fmt.allocPrint(arena, "slime-{d}.png", .{size});
        try png_dir.writeFile(io, .{ .sub_path = name, .data = png });
    }

    var pngs: [ico_sizes.len][]const u8 = undefined;
    for (ico_sizes, &pngs) |size, *png| {
        png.* = try r.png(arena, if (size <= small_max) small else full, size);
    }
    var ico: std.Io.Writer.Allocating = .init(arena);
    try writeIco(&ico.writer, &ico_sizes, &pngs);
    try cwd.writeFile(io, .{ .sub_path = args[3], .data = ico.written() });
}

/// ICONDIR, then an ICONDIRENTRY per image, then the images. A width or
/// height of 0 means 256.
fn writeIco(w: *std.Io.Writer, sizes: []const u32, pngs: []const []const u8) !void {
    try w.writeInt(u16, 0, .little); // reserved
    try w.writeInt(u16, 1, .little); // type: icon
    try w.writeInt(u16, @intCast(sizes.len), .little);
    var offset: u32 = @intCast(6 + 16 * sizes.len);
    for (sizes, pngs) |size, png| {
        const dim: u8 = if (size >= 256) 0 else @intCast(size);
        try w.writeByte(dim);
        try w.writeByte(dim);
        try w.writeByte(0); // palette colors
        try w.writeByte(0); // reserved
        try w.writeInt(u16, 1, .little); // planes
        try w.writeInt(u16, 32, .little); // bits per pixel
        try w.writeInt(u32, @intCast(png.len), .little);
        try w.writeInt(u32, offset, .little);
        offset += @intCast(png.len);
    }
    for (pngs) |png| try w.writeAll(png);
}

const Renderer = struct {
    wic: *IWICImagingFactory,
    d2d: *ID2D1Factory,

    /// Render `svg` to a `size` x `size` PNG.
    fn png(self: Renderer, arena: std.mem.Allocator, svg: []const u8, size: u32) ![]u8 {
        var bitmap: *IWICBitmap = undefined;
        try check(self.wic.createBitmap(size, size, &GUID_WICPixelFormat32bppPBGRA, &bitmap), "CreateBitmap");
        defer release(bitmap);
        try self.render(bitmap, svg, size);
        return self.encode(arena, bitmap, size);
    }

    fn render(self: Renderer, bitmap: *IWICBitmap, svg: []const u8, size: u32) !void {
        const props: D2D1_RENDER_TARGET_PROPERTIES = .{
            .type = D2D1_RENDER_TARGET_TYPE_SOFTWARE,
            .pixel_format = .{ .format = DXGI_FORMAT_B8G8R8A8_UNORM, .alpha_mode = D2D1_ALPHA_MODE_PREMULTIPLIED },
            .dpi_x = 96,
            .dpi_y = 96,
        };
        var rt: *ID2D1RenderTarget = undefined;
        try check(self.d2d.createWicBitmapRenderTarget(bitmap, &props, &rt), "CreateWicBitmapRenderTarget");
        defer release(rt);
        const dc = query(rt, ID2D1DeviceContext5) orelse return error.NoSvgSupport;
        defer release(dc);

        const stream = SHCreateMemStream(svg.ptr, @intCast(svg.len)) orelse return error.OutOfMemory;
        defer release(stream);
        var doc: *anyopaque = undefined;
        try check(dc.createSvgDocument(stream, .{ .width = svg_size, .height = svg_size }, &doc), "CreateSvgDocument");
        defer release(@as(*IUnknown, @ptrCast(@alignCast(doc))));

        const s = @as(f32, @floatFromInt(size)) / svg_size;
        dc.beginDraw();
        dc.setTransform(&.{ s, 0, 0, s, 0, 0 });
        dc.clear(&.{ 0, 0, 0, 0 });
        dc.drawSvgDocument(doc);
        try check(dc.endDraw(), "EndDraw");
    }

    /// Encode as straight-alpha BGRA, the PNG encoder's native format.
    fn encode(self: Renderer, arena: std.mem.Allocator, bitmap: *IWICBitmap, size: u32) ![]u8 {
        var converter: *IWICFormatConverter = undefined;
        try check(self.wic.createFormatConverter(&converter), "CreateFormatConverter");
        defer release(converter);
        try check(converter.initialize(bitmap, &GUID_WICPixelFormat32bppBGRA), "IWICFormatConverter::Initialize");

        const stream = SHCreateMemStream(null, 0) orelse return error.OutOfMemory;
        defer release(stream);
        var encoder: *IWICBitmapEncoder = undefined;
        try check(self.wic.createEncoder(&GUID_ContainerFormatPng, &encoder), "CreateEncoder");
        defer release(encoder);
        try check(encoder.initialize(stream), "IWICBitmapEncoder::Initialize");
        var frame: *IWICBitmapFrameEncode = undefined;
        try check(encoder.createNewFrame(&frame), "CreateNewFrame");
        defer release(frame);
        try check(frame.initialize(), "IWICBitmapFrameEncode::Initialize");
        try check(frame.setSize(size, size), "SetSize");
        var format = GUID_WICPixelFormat32bppBGRA;
        try check(frame.setPixelFormat(&format), "SetPixelFormat");
        if (!std.meta.eql(format, GUID_WICPixelFormat32bppBGRA)) return error.UnsupportedPixelFormat;
        try check(frame.writeSource(converter), "WriteSource");
        try check(frame.commit(), "IWICBitmapFrameEncode::Commit");
        try check(encoder.commit(), "IWICBitmapEncoder::Commit");

        var len: u64 = 0;
        try check(stream.seek(0, STREAM_SEEK_END, &len), "IStream::Seek");
        try check(stream.seek(0, STREAM_SEEK_SET, null), "IStream::Seek");
        const buf = try arena.alloc(u8, @intCast(len));
        var read: u32 = 0;
        try check(stream.read(buf.ptr, @intCast(buf.len), &read), "IStream::Read");
        if (read != buf.len) return error.ShortRead;
        return buf;
    }
};

// Bindings. Methods are called by vtable slot, as in src/win32/com.zig.

const HRESULT = i32;

const GUID = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

fn check(hr: HRESULT, comptime what: []const u8) error{HResult}!void {
    if (hr >= 0) return;
    std.log.err("{s} failed: HRESULT=0x{X:0>8}", .{ what, @as(u32, @bitCast(hr)) });
    return error.HResult;
}

const VTable = [*]const *const anyopaque;

inline fn call(self: anytype, comptime slot: usize, comptime Fn: type, args: anytype) @typeInfo(Fn).@"fn".return_type.? {
    const f: *const WithThis(@TypeOf(self), Fn) = @ptrCast(self.vtable[slot]);
    return @call(.auto, f, .{self} ++ args);
}

fn WithThis(comptime Self: type, comptime Fn: type) type {
    const info = @typeInfo(Fn).@"fn";
    var params: [info.params.len + 1]type = undefined;
    params[0] = Self;
    for (info.params, 1..) |p, i| params[i] = p.type.?;
    return @Fn(&params, &@splat(.{}), info.return_type.?, .{ .@"callconv" = .winapi });
}

fn release(self: anytype) void {
    _ = call(self, 2, fn () u32, .{});
}

fn query(self: anytype, comptime T: type) ?*T {
    var out: ?*anyopaque = null;
    if (call(self, 0, fn (*const GUID, *?*anyopaque) HRESULT, .{ &T.iid, &out }) < 0) return null;
    return @ptrCast(@alignCast(out));
}

const IUnknown = extern struct { vtable: VTable };

const COINIT_MULTITHREADED: u32 = 0;
const CLSCTX_INPROC_SERVER: u32 = 1;
const STREAM_SEEK_SET: u32 = 0;
const STREAM_SEEK_END: u32 = 2;

extern "ole32" fn CoInitializeEx(?*anyopaque, u32) callconv(.winapi) HRESULT;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
extern "ole32" fn CoCreateInstance(*const GUID, ?*anyopaque, u32, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT;
extern "shlwapi" fn SHCreateMemStream(?[*]const u8, u32) callconv(.winapi) ?*IStream;
extern "d2d1" fn D2D1CreateFactory(u32, *const GUID, ?*const anyopaque, *?*anyopaque) callconv(.winapi) HRESULT;

const IStream = extern struct {
    vtable: VTable,

    fn read(self: *IStream, buf: [*]u8, len: u32, read_len: *u32) HRESULT {
        return call(self, 3, fn ([*]u8, u32, *u32) HRESULT, .{ buf, len, read_len });
    }

    fn seek(self: *IStream, move: i64, origin: u32, new_pos: ?*u64) HRESULT {
        return call(self, 5, fn (i64, u32, ?*u64) HRESULT, .{ move, origin, new_pos });
    }
};

// Direct2D (d2d1.h, d2d1_3.h)

const D2D1_FACTORY_TYPE_SINGLE_THREADED: u32 = 0;
const D2D1_RENDER_TARGET_TYPE_SOFTWARE: u32 = 1;
const D2D1_ALPHA_MODE_PREMULTIPLIED: u32 = 1;
const DXGI_FORMAT_B8G8R8A8_UNORM: u32 = 87;

const D2D1_RENDER_TARGET_PROPERTIES = extern struct {
    type: u32,
    pixel_format: extern struct { format: u32, alpha_mode: u32 },
    dpi_x: f32,
    dpi_y: f32,
    usage: u32 = 0,
    min_level: u32 = 0,
};

const D2D1_SIZE_F = extern struct { width: f32, height: f32 };

const ID2D1Factory = extern struct {
    vtable: VTable,

    const iid: GUID = .{
        .data1 = 0x06152247,
        .data2 = 0x6f50,
        .data3 = 0x465a,
        .data4 = .{ 0x92, 0x45, 0x11, 0x8b, 0xfd, 0x3b, 0x60, 0x07 },
    };

    fn createWicBitmapRenderTarget(self: *ID2D1Factory, bitmap: *IWICBitmap, props: *const D2D1_RENDER_TARGET_PROPERTIES, out: **ID2D1RenderTarget) HRESULT {
        return call(self, 13, fn (*IWICBitmap, *const D2D1_RENDER_TARGET_PROPERTIES, **ID2D1RenderTarget) HRESULT, .{ bitmap, props, out });
    }
};

const ID2D1RenderTarget = extern struct { vtable: VTable };

/// ID2D1RenderTarget's methods are reached through it too.
const ID2D1DeviceContext5 = extern struct {
    vtable: VTable,

    const iid: GUID = .{
        .data1 = 0x7836d248,
        .data2 = 0x68cc,
        .data3 = 0x4df6,
        .data4 = .{ 0xb9, 0xe8, 0xde, 0x99, 0x1b, 0xf6, 0x2e, 0xb7 },
    };

    fn setTransform(self: *ID2D1DeviceContext5, m: *const [6]f32) void {
        call(self, 30, fn (*const [6]f32) void, .{m});
    }

    fn clear(self: *ID2D1DeviceContext5, color: *const [4]f32) void {
        call(self, 47, fn (*const [4]f32) void, .{color});
    }

    fn beginDraw(self: *ID2D1DeviceContext5) void {
        call(self, 48, fn () void, .{});
    }

    fn endDraw(self: *ID2D1DeviceContext5) HRESULT {
        return call(self, 49, fn (?*u64, ?*u64) HRESULT, .{ null, null });
    }

    fn createSvgDocument(self: *ID2D1DeviceContext5, stream: *IStream, viewport: D2D1_SIZE_F, out: **anyopaque) HRESULT {
        return call(self, 115, fn (*IStream, D2D1_SIZE_F, **anyopaque) HRESULT, .{ stream, viewport, out });
    }

    fn drawSvgDocument(self: *ID2D1DeviceContext5, doc: *anyopaque) void {
        call(self, 116, fn (*anyopaque) void, .{doc});
    }
};

// WIC (wincodec.h)

const CLSID_WICImagingFactory: GUID = .{
    .data1 = 0xcacaf262,
    .data2 = 0x9370,
    .data3 = 0x4615,
    .data4 = .{ 0xa1, 0x3b, 0x9f, 0x55, 0x39, 0xda, 0x4c, 0x0a },
};

const GUID_ContainerFormatPng: GUID = .{
    .data1 = 0x1b7cfaf4,
    .data2 = 0x713f,
    .data3 = 0x473c,
    .data4 = .{ 0xbb, 0xcd, 0x61, 0x37, 0x42, 0x5f, 0xae, 0xaf },
};

const GUID_WICPixelFormat32bppBGRA: GUID = .{
    .data1 = 0x6fddc324,
    .data2 = 0x4e03,
    .data3 = 0x4bfe,
    .data4 = .{ 0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x0f },
};

const GUID_WICPixelFormat32bppPBGRA: GUID = .{
    .data1 = 0x6fddc324,
    .data2 = 0x4e03,
    .data3 = 0x4bfe,
    .data4 = .{ 0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x10 },
};

const WICBitmapCacheOnLoad: u32 = 2;
const WICBitmapEncoderNoCache: u32 = 2;
const WICBitmapDitherTypeNone: u32 = 0;
const WICBitmapPaletteTypeCustom: u32 = 0;

const IWICImagingFactory = extern struct {
    vtable: VTable,

    const iid: GUID = .{
        .data1 = 0xec5ec8a9,
        .data2 = 0xc395,
        .data3 = 0x4314,
        .data4 = .{ 0x9c, 0x77, 0x54, 0xd7, 0xa9, 0x35, 0xff, 0x70 },
    };

    fn createEncoder(self: *IWICImagingFactory, format: *const GUID, out: **IWICBitmapEncoder) HRESULT {
        return call(self, 8, fn (*const GUID, ?*const GUID, **IWICBitmapEncoder) HRESULT, .{ format, null, out });
    }

    fn createFormatConverter(self: *IWICImagingFactory, out: **IWICFormatConverter) HRESULT {
        return call(self, 10, fn (**IWICFormatConverter) HRESULT, .{out});
    }

    fn createBitmap(self: *IWICImagingFactory, width: u32, height: u32, format: *const GUID, out: **IWICBitmap) HRESULT {
        return call(self, 17, fn (u32, u32, *const GUID, u32, **IWICBitmap) HRESULT, .{ width, height, format, WICBitmapCacheOnLoad, out });
    }
};

const IWICBitmap = extern struct { vtable: VTable };

const IWICFormatConverter = extern struct {
    vtable: VTable,

    fn initialize(self: *IWICFormatConverter, source: *IWICBitmap, format: *const GUID) HRESULT {
        return call(self, 8, fn (*IWICBitmap, *const GUID, u32, ?*anyopaque, f64, u32) HRESULT, .{
            source, format, WICBitmapDitherTypeNone, null, 0, WICBitmapPaletteTypeCustom,
        });
    }
};

const IWICBitmapEncoder = extern struct {
    vtable: VTable,

    fn initialize(self: *IWICBitmapEncoder, stream: *IStream) HRESULT {
        return call(self, 3, fn (*IStream, u32) HRESULT, .{ stream, WICBitmapEncoderNoCache });
    }

    fn createNewFrame(self: *IWICBitmapEncoder, out: **IWICBitmapFrameEncode) HRESULT {
        return call(self, 10, fn (**IWICBitmapFrameEncode, ?*?*anyopaque) HRESULT, .{ out, null });
    }

    fn commit(self: *IWICBitmapEncoder) HRESULT {
        return call(self, 11, fn () HRESULT, .{});
    }
};

const IWICBitmapFrameEncode = extern struct {
    vtable: VTable,

    fn initialize(self: *IWICBitmapFrameEncode) HRESULT {
        return call(self, 3, fn (?*anyopaque) HRESULT, .{null});
    }

    fn setSize(self: *IWICBitmapFrameEncode, width: u32, height: u32) HRESULT {
        return call(self, 4, fn (u32, u32) HRESULT, .{ width, height });
    }

    fn setPixelFormat(self: *IWICBitmapFrameEncode, format: *GUID) HRESULT {
        return call(self, 6, fn (*GUID) HRESULT, .{format});
    }

    fn writeSource(self: *IWICBitmapFrameEncode, source: *IWICFormatConverter) HRESULT {
        return call(self, 11, fn (*IWICFormatConverter, ?*const anyopaque) HRESULT, .{ source, null });
    }

    fn commit(self: *IWICBitmapFrameEncode) HRESULT {
        return call(self, 12, fn () HRESULT, .{});
    }
};
