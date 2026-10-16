//! Direct3D 11 interfaces. Slot numbers are from d3d11.h.

const win32 = @import("win32.zig");
const com = @import("com.zig");

const HRESULT = win32.HRESULT;
const GUID = win32.GUID;

pub const SDK_VERSION: u32 = 7;

pub const DRIVER_TYPE = enum(u32) {
    HARDWARE = 1,
    WARP = 5,
    _,
};

pub const FEATURE_LEVEL = enum(u32) {
    @"10_0" = 0xa000,
    @"10_1" = 0xa100,
    @"11_0" = 0xb000,
    @"11_1" = 0xb100,
    _,
};

pub const CREATE_DEVICE_DEBUG: u32 = 0x2;
pub const CREATE_DEVICE_BGRA_SUPPORT: u32 = 0x20;

pub const VIEWPORT = extern struct {
    TopLeftX: f32 = 0,
    TopLeftY: f32 = 0,
    Width: f32,
    Height: f32,
    MinDepth: f32 = 0,
    MaxDepth: f32 = 1,
};

/// Opaque handles we only pass around. ID3D11Texture2D derives from
/// ID3D11Resource, so a texture pointer can be passed where a resource
/// is expected.
pub const IResource = extern struct { vtable: com.VTable };
pub const IRenderTargetView = extern struct { vtable: com.VTable };

pub const ITexture2D = extern struct {
    vtable: com.VTable,

    pub const iid: GUID = .{
        .data1 = 0x6f15aaf2,
        .data2 = 0xd208,
        .data3 = 0x4e89,
        .data4 = .{ 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c },
    };

    pub fn resource(self: *ITexture2D) *IResource {
        return @ptrCast(self);
    }
};

pub const IDevice = extern struct {
    vtable: com.VTable,

    pub fn createRenderTargetView(
        self: *IDevice,
        res: *IResource,
        out: *?*IRenderTargetView,
    ) HRESULT {
        return com.call(self, 9, fn (
            *IResource,
            ?*const anyopaque, // D3D11_RENDER_TARGET_VIEW_DESC
            *?*IRenderTargetView,
        ) HRESULT, .{ res, null, out });
    }
};

pub const IDeviceContext = extern struct {
    vtable: com.VTable,

    pub fn omSetRenderTargets(self: *IDeviceContext, rtvs: []const *IRenderTargetView) void {
        com.call(self, 33, fn (u32, [*]const *IRenderTargetView, ?*anyopaque) void, .{
            @as(u32, @intCast(rtvs.len)), rtvs.ptr, null,
        });
    }

    pub fn rsSetViewports(self: *IDeviceContext, viewports: []const VIEWPORT) void {
        com.call(self, 44, fn (u32, [*]const VIEWPORT) void, .{
            @as(u32, @intCast(viewports.len)), viewports.ptr,
        });
    }

    pub fn clearRenderTargetView(self: *IDeviceContext, rtv: *IRenderTargetView, color: *const [4]f32) void {
        com.call(self, 50, fn (*IRenderTargetView, *const [4]f32) void, .{ rtv, color });
    }

    pub fn clearState(self: *IDeviceContext) void {
        com.call(self, 110, fn () void, .{});
    }
};

pub extern "d3d11" fn D3D11CreateDevice(
    adapter: ?*anyopaque,
    driver_type: DRIVER_TYPE,
    software: ?*anyopaque,
    flags: u32,
    feature_levels: ?[*]const FEATURE_LEVEL,
    num_feature_levels: u32,
    sdk_version: u32,
    device: ?*?*IDevice,
    feature_level: ?*FEATURE_LEVEL,
    context: ?*?*IDeviceContext,
) callconv(.winapi) HRESULT;
