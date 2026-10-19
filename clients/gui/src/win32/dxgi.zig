//! DXGI interfaces. Slot numbers are from dxgi.h / dxgi1_2.h / dxgi1_3.h
//! / dxgi1_5.h.

const win32 = @import("win32.zig");
const com = @import("com.zig");

const HRESULT = win32.HRESULT;
const GUID = win32.GUID;

pub const FORMAT = enum(u32) {
    UNKNOWN = 0,
    R8G8B8A8_UNORM = 28,
    R8_UNORM = 61,
    B8G8R8A8_UNORM = 87,
    _,
};

pub const USAGE_RENDER_TARGET_OUTPUT: u32 = 0x20;
pub const SCALING_STRETCH: u32 = 0;
pub const SCALING_NONE: u32 = 1;
pub const SWAP_EFFECT_FLIP_DISCARD: u32 = 4;
pub const ALPHA_MODE_PREMULTIPLIED: u32 = 1;
pub const ALPHA_MODE_IGNORE: u32 = 3;
pub const MWA_NO_ALT_ENTER: u32 = 0x2;
pub const CREATE_FACTORY_DEBUG: u32 = 0x1;
pub const SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT: u32 = 0x40;
pub const SWAP_CHAIN_FLAG_ALLOW_TEARING: u32 = 0x800;
pub const PRESENT_ALLOW_TEARING: u32 = 0x200;
pub const FEATURE_PRESENT_ALLOW_TEARING: u32 = 0;

pub const ERROR_DEVICE_REMOVED: HRESULT = @bitCast(@as(u32, 0x887A0005));
pub const ERROR_DEVICE_RESET: HRESULT = @bitCast(@as(u32, 0x887A0007));

pub const SAMPLE_DESC = extern struct {
    Count: u32 = 1,
    Quality: u32 = 0,
};

pub const SWAP_CHAIN_DESC1 = extern struct {
    Width: u32,
    Height: u32,
    Format: FORMAT,
    Stereo: win32.BOOL = win32.FALSE,
    SampleDesc: SAMPLE_DESC = .{},
    BufferUsage: u32,
    BufferCount: u32,
    Scaling: u32,
    SwapEffect: u32,
    AlphaMode: u32,
    Flags: u32 = 0,
};

pub const IFactory2 = extern struct {
    vtable: com.VTable,

    pub const iid: GUID = .{
        .data1 = 0x50c83a1c,
        .data2 = 0xe072,
        .data3 = 0x4c48,
        .data4 = .{ 0x87, 0xb0, 0x36, 0x30, 0xfa, 0x36, 0xa6, 0xd0 },
    };

    pub fn makeWindowAssociation(self: *IFactory2, hwnd: win32.HWND, flags: u32) HRESULT {
        return com.call(self, 8, fn (win32.HWND, u32) HRESULT, .{ hwnd, flags });
    }

    pub fn createSwapChainForHwnd(
        self: *IFactory2,
        device: *anyopaque,
        hwnd: win32.HWND,
        desc: *const SWAP_CHAIN_DESC1,
        out: *?*ISwapChain1,
    ) HRESULT {
        return com.call(self, 15, fn (
            *anyopaque,
            win32.HWND,
            *const SWAP_CHAIN_DESC1,
            ?*const anyopaque, // DXGI_SWAP_CHAIN_FULLSCREEN_DESC
            ?*anyopaque, // IDXGIOutput (restrict to output)
            *?*ISwapChain1,
        ) HRESULT, .{ device, hwnd, desc, null, null, out });
    }

    /// A swap chain for a DirectComposition visual's content: flip model,
    /// `SCALING_STRETCH`, and the window's size up to the caller.
    pub fn createSwapChainForComposition(
        self: *IFactory2,
        device: *anyopaque,
        desc: *const SWAP_CHAIN_DESC1,
        out: *?*ISwapChain1,
    ) HRESULT {
        return com.call(self, 24, fn (
            *anyopaque,
            *const SWAP_CHAIN_DESC1,
            ?*anyopaque, // IDXGIOutput (restrict to output)
            *?*ISwapChain1,
        ) HRESULT, .{ device, desc, null, out });
    }
};

pub const IFactory5 = extern struct {
    vtable: com.VTable,

    pub const iid: GUID = .{
        .data1 = 0x7632e1f5,
        .data2 = 0xee65,
        .data3 = 0x4dca,
        .data4 = .{ 0x87, 0xfd, 0x84, 0xcd, 0x75, 0xf8, 0x83, 0x8d },
    };

    pub fn checkFeatureSupport(self: *IFactory5, feature: u32, data: *anyopaque, size: u32) HRESULT {
        return com.call(self, 28, fn (u32, *anyopaque, u32) HRESULT, .{ feature, data, size });
    }
};

pub const ISwapChain2 = extern struct {
    vtable: com.VTable,

    pub const iid: GUID = .{
        .data1 = 0xa8be2ac4,
        .data2 = 0x199f,
        .data3 = 0x4946,
        .data4 = .{ 0xb3, 0x31, 0x79, 0x59, 0x9f, 0xb9, 0x8d, 0xe7 },
    };

    pub fn setMaximumFrameLatency(self: *ISwapChain2, latency: u32) HRESULT {
        return com.call(self, 31, fn (u32) HRESULT, .{latency});
    }

    pub fn getFrameLatencyWaitableObject(self: *ISwapChain2) ?win32.HANDLE {
        return com.call(self, 33, fn () ?win32.HANDLE, .{});
    }
};

pub const ISwapChain1 = extern struct {
    vtable: com.VTable,

    pub fn present(self: *ISwapChain1, sync_interval: u32, flags: u32) HRESULT {
        return com.call(self, 8, fn (u32, u32) HRESULT, .{ sync_interval, flags });
    }

    pub fn getBuffer(self: *ISwapChain1, index: u32, iid: *const GUID, out: *?*anyopaque) HRESULT {
        return com.call(self, 9, fn (u32, *const GUID, *?*anyopaque) HRESULT, .{ index, iid, out });
    }

    pub fn resizeBuffers(
        self: *ISwapChain1,
        count: u32,
        width: u32,
        height: u32,
        format: FORMAT,
        flags: u32,
    ) HRESULT {
        return com.call(self, 13, fn (u32, u32, u32, FORMAT, u32) HRESULT, .{
            count, width, height, format, flags,
        });
    }
};

/// Queried from the D3D11 device to create a Direct2D device on it.
pub const IDevice = extern struct {
    vtable: com.VTable,

    pub const iid: GUID = .{
        .data1 = 0x54ec77fa,
        .data2 = 0x1377,
        .data3 = 0x44e6,
        .data4 = .{ 0x8c, 0x32, 0x88, 0xfd, 0x5f, 0x44, 0xc8, 0x4c },
    };
};

/// A swap chain buffer as Direct2D takes it.
pub const ISurface = extern struct {
    vtable: com.VTable,

    pub const iid: GUID = .{
        .data1 = 0xcafcb56c,
        .data2 = 0x6ac3,
        .data3 = 0x4889,
        .data4 = .{ 0xbf, 0x47, 0x9e, 0x23, 0xbb, 0xd2, 0x60, 0xec },
    };
};

pub extern "dxgi" fn CreateDXGIFactory2(flags: u32, riid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT;
