//! Direct3D 11 interfaces. Slot numbers are from d3d11.h.

const win32 = @import("win32.zig");
const com = @import("com.zig");
const dxgi = @import("dxgi.zig");

const BOOL = win32.BOOL;
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

pub const USAGE_DEFAULT: u32 = 0;
pub const USAGE_DYNAMIC: u32 = 2;
pub const BIND_CONSTANT_BUFFER: u32 = 0x4;
pub const BIND_SHADER_RESOURCE: u32 = 0x8;
pub const CPU_ACCESS_WRITE: u32 = 0x10000;
pub const RESOURCE_MISC_BUFFER_STRUCTURED: u32 = 0x40;
pub const MAP_WRITE_DISCARD: u32 = 4;

pub const BLEND_ONE: u32 = 2;
pub const BLEND_INV_SRC_ALPHA: u32 = 6;
pub const BLEND_INV_SRC1_COLOR: u32 = 17;
pub const BLEND_INV_SRC1_ALPHA: u32 = 19;
pub const BLEND_OP_ADD: u32 = 1;
pub const COLOR_WRITE_ENABLE_ALL: u8 = 0xF;

pub const FILTER_MIN_MAG_LINEAR_MIP_POINT: u32 = 0x14;
pub const TEXTURE_ADDRESS_CLAMP: u32 = 3;
pub const COMPARISON_NEVER: u32 = 1;

pub const PRIMITIVE_TOPOLOGY_TRIANGLELIST: u32 = 4;
pub const PRIMITIVE_TOPOLOGY_TRIANGLESTRIP: u32 = 5;

pub const VIEWPORT = extern struct {
    TopLeftX: f32 = 0,
    TopLeftY: f32 = 0,
    Width: f32,
    Height: f32,
    MinDepth: f32 = 0,
    MaxDepth: f32 = 1,
};

pub const BUFFER_DESC = extern struct {
    ByteWidth: u32,
    Usage: u32,
    BindFlags: u32,
    CPUAccessFlags: u32 = 0,
    MiscFlags: u32 = 0,
    StructureByteStride: u32 = 0,
};

pub const BOX = extern struct {
    left: u32,
    top: u32,
    front: u32 = 0,
    right: u32,
    bottom: u32,
    back: u32 = 1,
};

pub const TEXTURE2D_DESC = extern struct {
    Width: u32,
    Height: u32,
    MipLevels: u32 = 1,
    ArraySize: u32 = 1,
    Format: dxgi.FORMAT,
    SampleDesc: dxgi.SAMPLE_DESC = .{},
    Usage: u32,
    BindFlags: u32,
    CPUAccessFlags: u32 = 0,
    MiscFlags: u32 = 0,
};

pub const RENDER_TARGET_BLEND_DESC = extern struct {
    BlendEnable: BOOL = win32.FALSE,
    SrcBlend: u32 = BLEND_ONE,
    DestBlend: u32 = 1, // D3D11_BLEND_ZERO
    BlendOp: u32 = BLEND_OP_ADD,
    SrcBlendAlpha: u32 = BLEND_ONE,
    DestBlendAlpha: u32 = 1, // D3D11_BLEND_ZERO
    BlendOpAlpha: u32 = BLEND_OP_ADD,
    RenderTargetWriteMask: u8 = COLOR_WRITE_ENABLE_ALL,
};

pub const BLEND_DESC = extern struct {
    AlphaToCoverageEnable: BOOL = win32.FALSE,
    IndependentBlendEnable: BOOL = win32.FALSE,
    RenderTarget: [8]RENDER_TARGET_BLEND_DESC = @splat(.{}),
};

pub const SAMPLER_DESC = extern struct {
    Filter: u32,
    AddressU: u32 = TEXTURE_ADDRESS_CLAMP,
    AddressV: u32 = TEXTURE_ADDRESS_CLAMP,
    AddressW: u32 = TEXTURE_ADDRESS_CLAMP,
    MipLODBias: f32 = 0,
    MaxAnisotropy: u32 = 1,
    ComparisonFunc: u32 = COMPARISON_NEVER,
    BorderColor: [4]f32 = @splat(0),
    MinLOD: f32 = 0,
    MaxLOD: f32 = 3.402823466e+38,
};

pub const MAPPED_SUBRESOURCE = extern struct {
    pData: ?*anyopaque,
    RowPitch: u32,
    DepthPitch: u32,
};

/// Interfaces we only create, bind, and release. Every resource type
/// (buffers, textures) derives from ID3D11Resource, so `resource()`
/// upcasts.
pub const IResource = extern struct { vtable: com.VTable };
pub const IRenderTargetView = extern struct { vtable: com.VTable };
pub const IShaderResourceView = extern struct { vtable: com.VTable };
pub const IVertexShader = extern struct { vtable: com.VTable };
pub const IPixelShader = extern struct { vtable: com.VTable };
pub const IBlendState = extern struct { vtable: com.VTable };
pub const ISamplerState = extern struct { vtable: com.VTable };

pub const IBuffer = extern struct {
    vtable: com.VTable,

    pub fn resource(self: *IBuffer) *IResource {
        return @ptrCast(self);
    }
};

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

    pub fn createBuffer(self: *IDevice, desc: *const BUFFER_DESC, out: *?*IBuffer) HRESULT {
        return com.call(self, 3, fn (*const BUFFER_DESC, ?*const anyopaque, *?*IBuffer) HRESULT, .{
            desc, null, out,
        });
    }

    pub fn createTexture2D(self: *IDevice, desc: *const TEXTURE2D_DESC, out: *?*ITexture2D) HRESULT {
        return com.call(self, 5, fn (*const TEXTURE2D_DESC, ?*const anyopaque, *?*ITexture2D) HRESULT, .{
            desc, null, out,
        });
    }

    /// Passing a null desc creates a view of the whole resource.
    pub fn createShaderResourceView(self: *IDevice, res: *IResource, out: *?*IShaderResourceView) HRESULT {
        return com.call(self, 7, fn (*IResource, ?*const anyopaque, *?*IShaderResourceView) HRESULT, .{
            res, null, out,
        });
    }

    pub fn createRenderTargetView(self: *IDevice, res: *IResource, out: *?*IRenderTargetView) HRESULT {
        return com.call(self, 9, fn (*IResource, ?*const anyopaque, *?*IRenderTargetView) HRESULT, .{
            res, null, out,
        });
    }

    pub fn createVertexShader(self: *IDevice, bytecode: []const u8, out: *?*IVertexShader) HRESULT {
        return com.call(self, 12, fn ([*]const u8, usize, ?*anyopaque, *?*IVertexShader) HRESULT, .{
            bytecode.ptr, bytecode.len, null, out,
        });
    }

    pub fn createPixelShader(self: *IDevice, bytecode: []const u8, out: *?*IPixelShader) HRESULT {
        return com.call(self, 15, fn ([*]const u8, usize, ?*anyopaque, *?*IPixelShader) HRESULT, .{
            bytecode.ptr, bytecode.len, null, out,
        });
    }

    pub fn createBlendState(self: *IDevice, desc: *const BLEND_DESC, out: *?*IBlendState) HRESULT {
        return com.call(self, 20, fn (*const BLEND_DESC, *?*IBlendState) HRESULT, .{ desc, out });
    }

    pub fn createSamplerState(self: *IDevice, desc: *const SAMPLER_DESC, out: *?*ISamplerState) HRESULT {
        return com.call(self, 23, fn (*const SAMPLER_DESC, *?*ISamplerState) HRESULT, .{ desc, out });
    }
};

pub const IDeviceContext = extern struct {
    vtable: com.VTable,

    pub fn vsSetConstantBuffers(self: *IDeviceContext, start: u32, buffers: []const ?*IBuffer) void {
        com.call(self, 7, fn (u32, u32, [*]const ?*IBuffer) void, .{
            start, @as(u32, @intCast(buffers.len)), buffers.ptr,
        });
    }

    pub fn psSetShaderResources(self: *IDeviceContext, start: u32, views: []const ?*IShaderResourceView) void {
        com.call(self, 8, fn (u32, u32, [*]const ?*IShaderResourceView) void, .{
            start, @as(u32, @intCast(views.len)), views.ptr,
        });
    }

    pub fn psSetShader(self: *IDeviceContext, shader: ?*IPixelShader) void {
        com.call(self, 9, fn (?*IPixelShader, ?*anyopaque, u32) void, .{ shader, null, 0 });
    }

    pub fn psSetSamplers(self: *IDeviceContext, start: u32, samplers: []const ?*ISamplerState) void {
        com.call(self, 10, fn (u32, u32, [*]const ?*ISamplerState) void, .{
            start, @as(u32, @intCast(samplers.len)), samplers.ptr,
        });
    }

    pub fn vsSetShader(self: *IDeviceContext, shader: ?*IVertexShader) void {
        com.call(self, 11, fn (?*IVertexShader, ?*anyopaque, u32) void, .{ shader, null, 0 });
    }

    pub fn draw(self: *IDeviceContext, vertex_count: u32, start: u32) void {
        com.call(self, 13, fn (u32, u32) void, .{ vertex_count, start });
    }

    pub fn map(self: *IDeviceContext, res: *IResource, map_type: u32, out: *MAPPED_SUBRESOURCE) HRESULT {
        return com.call(self, 14, fn (*IResource, u32, u32, u32, *MAPPED_SUBRESOURCE) HRESULT, .{
            res, 0, map_type, 0, out,
        });
    }

    pub fn unmap(self: *IDeviceContext, res: *IResource) void {
        com.call(self, 15, fn (*IResource, u32) void, .{ res, 0 });
    }

    pub fn psSetConstantBuffers(self: *IDeviceContext, start: u32, buffers: []const ?*IBuffer) void {
        com.call(self, 16, fn (u32, u32, [*]const ?*IBuffer) void, .{
            start, @as(u32, @intCast(buffers.len)), buffers.ptr,
        });
    }

    pub fn drawInstanced(self: *IDeviceContext, vertices: u32, instances: u32, start_vertex: u32, start_instance: u32) void {
        com.call(self, 21, fn (u32, u32, u32, u32) void, .{ vertices, instances, start_vertex, start_instance });
    }

    pub fn iaSetPrimitiveTopology(self: *IDeviceContext, topology: u32) void {
        com.call(self, 24, fn (u32) void, .{topology});
    }

    pub fn vsSetShaderResources(self: *IDeviceContext, start: u32, views: []const ?*IShaderResourceView) void {
        com.call(self, 25, fn (u32, u32, [*]const ?*IShaderResourceView) void, .{
            start, @as(u32, @intCast(views.len)), views.ptr,
        });
    }

    pub fn omSetRenderTargets(self: *IDeviceContext, rtvs: []const *IRenderTargetView) void {
        com.call(self, 33, fn (u32, [*]const *IRenderTargetView, ?*anyopaque) void, .{
            @as(u32, @intCast(rtvs.len)), rtvs.ptr, null,
        });
    }

    pub fn omSetBlendState(self: *IDeviceContext, state: ?*IBlendState) void {
        com.call(self, 35, fn (?*IBlendState, ?*const [4]f32, u32) void, .{ state, null, 0xffffffff });
    }

    pub fn rsSetViewports(self: *IDeviceContext, viewports: []const VIEWPORT) void {
        com.call(self, 44, fn (u32, [*]const VIEWPORT) void, .{
            @as(u32, @intCast(viewports.len)), viewports.ptr,
        });
    }

    /// Upload `data` to all of subresource 0.
    /// Copy `box` of `src` to (`x`, `y`) in `dst`, both subresource 0.
    pub fn copySubresourceRegion(self: *IDeviceContext, dst: *IResource, x: u32, y: u32, src: *IResource, box: *const BOX) void {
        com.call(self, 46, fn (*IResource, u32, u32, u32, u32, *IResource, u32, *const BOX) void, .{ dst, 0, x, y, 0, src, 0, box });
    }

    pub fn updateSubresource(self: *IDeviceContext, res: *IResource, data: [*]const u8, row_pitch: u32) void {
        com.call(self, 48, fn (*IResource, u32, ?*const anyopaque, [*]const u8, u32, u32) void, .{
            res, 0, null, data, row_pitch, 0,
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
