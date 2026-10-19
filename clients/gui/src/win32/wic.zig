//! Windows Imaging Component, for the PNGs a browser hands us (a page's
//! picture, its favicon). Slot numbers are from mingw's wincodec.h.

const win32 = @import("win32.zig");
const com = @import("com.zig");

const HRESULT = win32.HRESULT;
const GUID = win32.GUID;

pub const CLSID_ImagingFactory: GUID = .{
    .data1 = 0xcacaf262,
    .data2 = 0x9370,
    .data3 = 0x4615,
    .data4 = .{ 0xa1, 0x3b, 0x9f, 0x55, 0x39, 0xda, 0x4c, 0x0a },
};

/// Premultiplied BGRA, 8 bits each: what Direct2D draws.
pub const GUID_PixelFormat32bppPBGRA: GUID = .{
    .data1 = 0x6fddc324,
    .data2 = 0x4e03,
    .data3 = 0x4bfe,
    .data4 = .{ 0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x10 },
};

pub const DecodeMetadataCacheOnDemand = 0;
pub const BitmapDitherTypeNone = 0;
pub const BitmapPaletteTypeCustom = 0;

/// IWICImagingFactory.
pub const IImagingFactory = extern struct {
    vtable: com.VTable,

    pub const iid: GUID = .{
        .data1 = 0xec5ec8a9,
        .data2 = 0xc395,
        .data3 = 0x4314,
        .data4 = .{ 0x9c, 0x77, 0x54, 0xd7, 0xa9, 0x35, 0xff, 0x70 },
    };

    pub fn createDecoderFromStream(self: *IImagingFactory, stream: *win32.IStream, out: *?*IBitmapDecoder) HRESULT {
        return com.call(self, 4, fn (*win32.IStream, ?*const GUID, u32, *?*IBitmapDecoder) HRESULT, .{ stream, null, DecodeMetadataCacheOnDemand, out });
    }

    pub fn createFormatConverter(self: *IImagingFactory, out: *?*IFormatConverter) HRESULT {
        return com.call(self, 10, fn (*?*IFormatConverter) HRESULT, .{out});
    }
};

/// IWICBitmapDecoder.
pub const IBitmapDecoder = extern struct {
    vtable: com.VTable,

    pub fn getFrame(self: *IBitmapDecoder, index: u32, out: *?*IBitmapSource) HRESULT {
        return com.call(self, 13, fn (u32, *?*IBitmapSource) HRESULT, .{ index, out });
    }
};

/// IWICBitmapSource, which a decoded frame (IWICBitmapFrameDecode) is.
pub const IBitmapSource = extern struct {
    vtable: com.VTable,

    pub fn getSize(self: *IBitmapSource, w: *u32, h: *u32) HRESULT {
        return com.call(self, 3, fn (*u32, *u32) HRESULT, .{ w, h });
    }
};

/// IWICFormatConverter, an IWICBitmapSource of another's pixels.
pub const IFormatConverter = extern struct {
    vtable: com.VTable,

    pub fn initialize(self: *IFormatConverter, source: *IBitmapSource, format: *const GUID) HRESULT {
        return com.call(self, 8, fn (*IBitmapSource, *const GUID, u32, ?*anyopaque, f64, u32) HRESULT, .{ source, format, BitmapDitherTypeNone, null, 0, BitmapPaletteTypeCustom });
    }
};
