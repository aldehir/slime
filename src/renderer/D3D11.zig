//! Direct3D 11 renderer: device, flip-model swap chain, and the terminal
//! grid pipeline (see shaders.hlsl) for a single window.
const D3D11 = @This();

const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../win32/win32.zig");
const com = win32.com;
const d3d11 = win32.d3d11;
const d3dcompiler = win32.d3dcompiler;
const dxgi = win32.dxgi;
const font = @import("../font/font.zig");
const cells = @import("cells.zig");

const log = std.log.scoped(.d3d11);

const buffer_count = 2;
const buffer_format: dxgi.FORMAT = .B8G8R8A8_UNORM;
const shader_source = @embedFile("shaders.hlsl");

device: *d3d11.IDevice,
context: *d3d11.IDeviceContext,
swap_chain: *dxgi.ISwapChain1,
rtv: ?*d3d11.IRenderTargetView = null,
width: u32,
height: u32,

pipeline: Pipeline,
uniforms: *d3d11.IBuffer,
bg_cells: DynamicBuffer = .{ .stride = @sizeOf(u32) },
instances: DynamicBuffer = .{ .stride = @sizeOf(cells.Instance) },

atlas_texture: ?*d3d11.ITexture2D = null,
atlas_srv: ?*d3d11.IShaderResourceView = null,
atlas_size: u32 = 0,
atlas_generation: u64 = 0,

pub const Error = com.Error;

pub fn init(hwnd: win32.HWND, width: u32, height: u32) Error!D3D11 {
    var device: ?*d3d11.IDevice = null;
    var context: ?*d3d11.IDeviceContext = null;
    try createDevice(&device, &context);
    errdefer com.releaseOpt(&device);
    errdefer com.releaseOpt(&context);

    var factory: ?*dxgi.IFactory2 = null;
    try com.check(
        dxgi.CreateDXGIFactory2(0, &dxgi.IFactory2.iid, @ptrCast(&factory)),
        "CreateDXGIFactory2",
    );
    defer com.releaseOpt(&factory);

    var swap_chain: ?*dxgi.ISwapChain1 = null;
    try com.check(factory.?.createSwapChainForHwnd(device.?, hwnd, &.{
        .Width = width,
        .Height = height,
        .Format = buffer_format,
        .BufferUsage = dxgi.USAGE_RENDER_TARGET_OUTPUT,
        .BufferCount = buffer_count,
        .Scaling = dxgi.SCALING_NONE,
        .SwapEffect = dxgi.SWAP_EFFECT_FLIP_DISCARD,
        .AlphaMode = dxgi.ALPHA_MODE_IGNORE,
    }, &swap_chain), "CreateSwapChainForHwnd");
    errdefer com.releaseOpt(&swap_chain);

    // Fullscreen is ours to implement; don't let DXGI hijack Alt+Enter.
    _ = factory.?.makeWindowAssociation(hwnd, dxgi.MWA_NO_ALT_ENTER);

    var pipeline: Pipeline = try .init(device.?);
    errdefer pipeline.deinit();

    var uniforms: ?*d3d11.IBuffer = null;
    try com.check(device.?.createBuffer(&.{
        .ByteWidth = @sizeOf(cells.Uniforms),
        .Usage = d3d11.USAGE_DYNAMIC,
        .BindFlags = d3d11.BIND_CONSTANT_BUFFER,
        .CPUAccessFlags = d3d11.CPU_ACCESS_WRITE,
    }, &uniforms), "ID3D11Device::CreateBuffer(uniforms)");
    errdefer com.releaseOpt(&uniforms);

    var self: D3D11 = .{
        .device = device.?,
        .context = context.?,
        .swap_chain = swap_chain.?,
        .width = width,
        .height = height,
        .pipeline = pipeline,
        .uniforms = uniforms.?,
    };
    try self.createRenderTarget();
    return self;
}

pub fn deinit(self: *D3D11) void {
    self.context.clearState();
    com.releaseOpt(&self.atlas_srv);
    com.releaseOpt(&self.atlas_texture);
    self.instances.deinit();
    self.bg_cells.deinit();
    com.release(self.uniforms);
    self.pipeline.deinit();
    com.releaseOpt(&self.rtv);
    com.release(self.swap_chain);
    com.release(self.context);
    com.release(self.device);
    self.* = undefined;
}

/// Resize the swap chain buffers to the new client area size.
pub fn resize(self: *D3D11, width: u32, height: u32) Error!void {
    if (width == 0 or height == 0) return;
    if (width == self.width and height == self.height) return;

    // All references to the back buffers must be released before
    // ResizeBuffers, including the ones bound to the pipeline.
    self.context.clearState();
    com.releaseOpt(&self.rtv);

    try com.check(
        self.swap_chain.resizeBuffers(0, width, height, .UNKNOWN, 0),
        "IDXGISwapChain::ResizeBuffers",
    );
    self.width = width;
    self.height = height;
    try self.createRenderTarget();
}

/// Draw the grid and present, waiting for vblank.
pub fn draw(
    self: *D3D11,
    frame: *const cells.Cells,
    atlas: *const font.Atlas,
    metrics: font.Grid.Metrics,
    grid_offset: [2]f32,
) error{ DeviceLost, HResult }!void {
    const rtv = self.rtv orelse return;
    const ctx = self.context;

    try self.uploadAtlas(atlas);
    try self.bg_cells.upload(self.device, ctx, std.mem.sliceAsBytes(frame.bg.items));
    try self.instances.upload(self.device, ctx, std.mem.sliceAsBytes(frame.instances.items));

    const uniforms = frame.uniforms(metrics, self.width, self.height, grid_offset);
    var mapped: d3d11.MAPPED_SUBRESOURCE = undefined;
    try com.check(ctx.map(self.uniforms.resource(), d3d11.MAP_WRITE_DISCARD, &mapped), "Map(uniforms)");
    @as(*cells.Uniforms, @ptrCast(@alignCast(mapped.pData.?))).* = uniforms;
    ctx.unmap(self.uniforms.resource());

    ctx.omSetRenderTargets(&.{rtv});
    ctx.rsSetViewports(&.{.{
        .Width = @floatFromInt(self.width),
        .Height = @floatFromInt(self.height),
    }});
    ctx.clearRenderTargetView(rtv, &uniforms.default_bg);

    if (frame.bg.items.len > 0) {
        ctx.iaSetPrimitiveTopology(d3d11.PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        ctx.vsSetShader(self.pipeline.bg_vs);
        ctx.psSetShader(self.pipeline.bg_ps);
        ctx.psSetConstantBuffers(0, &.{self.uniforms});
        ctx.psSetShaderResources(0, &.{self.bg_cells.srv});
        ctx.omSetBlendState(null);
        ctx.draw(3, 0);
    }

    if (frame.instances.items.len > 0) {
        ctx.iaSetPrimitiveTopology(d3d11.PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
        ctx.vsSetShader(self.pipeline.text_vs);
        ctx.vsSetConstantBuffers(0, &.{self.uniforms});
        ctx.vsSetShaderResources(1, &.{self.instances.srv});
        ctx.psSetShader(self.pipeline.text_ps);
        ctx.psSetShaderResources(2, &.{self.atlas_srv});
        ctx.omSetBlendState(self.pipeline.blend);
        ctx.drawInstanced(4, @intCast(frame.instances.items.len), 0, 0);
    }

    const hr = self.swap_chain.present(1, 0);
    if (hr == dxgi.ERROR_DEVICE_REMOVED or hr == dxgi.ERROR_DEVICE_RESET) {
        // TODO: recreate the device and all GPU resources.
        return error.DeviceLost;
    }
    try com.check(hr, "IDXGISwapChain::Present");
}

/// Mirror the CPU atlas on the GPU, reallocating if it grew.
fn uploadAtlas(self: *D3D11, atlas: *const font.Atlas) Error!void {
    if (self.atlas_size != atlas.size) {
        com.releaseOpt(&self.atlas_srv);
        com.releaseOpt(&self.atlas_texture);
        self.atlas_size = 0;

        try com.check(self.device.createTexture2D(&.{
            .Width = atlas.size,
            .Height = atlas.size,
            .Format = .R8_UNORM,
            .Usage = d3d11.USAGE_DEFAULT,
            .BindFlags = d3d11.BIND_SHADER_RESOURCE,
        }, &self.atlas_texture), "ID3D11Device::CreateTexture2D(atlas)");
        try com.check(
            self.device.createShaderResourceView(self.atlas_texture.?.resource(), &self.atlas_srv),
            "ID3D11Device::CreateShaderResourceView(atlas)",
        );
        self.atlas_size = atlas.size;
        self.atlas_generation = atlas.generation -% 1;
        log.debug("atlas texture {d}x{d}", .{ atlas.size, atlas.size });
    }

    if (self.atlas_generation != atlas.generation) {
        self.context.updateSubresource(self.atlas_texture.?.resource(), atlas.data.ptr, atlas.size);
        self.atlas_generation = atlas.generation;
    }
}

fn createRenderTarget(self: *D3D11) Error!void {
    var back_buffer: ?*d3d11.ITexture2D = null;
    try com.check(
        self.swap_chain.getBuffer(0, &d3d11.ITexture2D.iid, @ptrCast(&back_buffer)),
        "IDXGISwapChain::GetBuffer",
    );
    defer com.releaseOpt(&back_buffer);

    try com.check(
        self.device.createRenderTargetView(back_buffer.?.resource(), &self.rtv),
        "ID3D11Device::CreateRenderTargetView",
    );
}

fn createDevice(device: *?*d3d11.IDevice, context: *?*d3d11.IDeviceContext) Error!void {
    // Structured buffers in vertex/pixel shaders need feature level 11.
    const levels = [_]d3d11.FEATURE_LEVEL{ .@"11_1", .@"11_0" };
    const base_flags = d3d11.CREATE_DEVICE_BGRA_SUPPORT;

    // The debug layer needs the "Graphics Tools" optional Windows feature,
    // so fall back to a regular device if it's missing.
    const attempts = [_]struct { driver: d3d11.DRIVER_TYPE, flags: u32 }{
        .{ .driver = .HARDWARE, .flags = base_flags | d3d11.CREATE_DEVICE_DEBUG },
        .{ .driver = .HARDWARE, .flags = base_flags },
        .{ .driver = .WARP, .flags = base_flags },
    };

    for (attempts) |a| {
        if (builtin.mode != .Debug and a.flags & d3d11.CREATE_DEVICE_DEBUG != 0) continue;

        var level: d3d11.FEATURE_LEVEL = undefined;
        const hr = d3d11.D3D11CreateDevice(
            null,
            a.driver,
            null,
            a.flags,
            &levels,
            levels.len,
            d3d11.SDK_VERSION,
            device,
            &level,
            context,
        );
        if (hr >= 0) {
            log.info("device created driver={t} feature_level=0x{x} debug={}", .{
                a.driver,
                @intFromEnum(level),
                a.flags & d3d11.CREATE_DEVICE_DEBUG != 0,
            });
            return;
        }
        log.warn("D3D11CreateDevice driver={t} flags=0x{x} failed: HRESULT=0x{X:0>8}", .{
            a.driver,
            a.flags,
            @as(u32, @bitCast(hr)),
        });
    }

    return error.HResult;
}

/// Shaders and fixed-function state.
const Pipeline = struct {
    bg_vs: *d3d11.IVertexShader,
    bg_ps: *d3d11.IPixelShader,
    text_vs: *d3d11.IVertexShader,
    text_ps: *d3d11.IPixelShader,
    blend: *d3d11.IBlendState,

    fn init(device: *d3d11.IDevice) Error!Pipeline {
        var bg_vs: ?*d3d11.IVertexShader = null;
        var bg_ps: ?*d3d11.IPixelShader = null;
        var text_vs: ?*d3d11.IVertexShader = null;
        var text_ps: ?*d3d11.IPixelShader = null;
        var blend: ?*d3d11.IBlendState = null;
        errdefer {
            com.releaseOpt(&bg_vs);
            com.releaseOpt(&bg_ps);
            com.releaseOpt(&text_vs);
            com.releaseOpt(&text_ps);
            com.releaseOpt(&blend);
        }

        try createShader(device, "bg_vs", &bg_vs);
        try createShader(device, "bg_ps", &bg_ps);
        try createShader(device, "text_vs", &text_vs);
        try createShader(device, "text_ps", &text_ps);

        // Premultiplied alpha: out = src + dst * (1 - src.a).
        var desc: d3d11.BLEND_DESC = .{};
        desc.RenderTarget[0] = .{
            .BlendEnable = win32.TRUE,
            .SrcBlend = d3d11.BLEND_ONE,
            .DestBlend = d3d11.BLEND_INV_SRC_ALPHA,
            .SrcBlendAlpha = d3d11.BLEND_ONE,
            .DestBlendAlpha = d3d11.BLEND_INV_SRC_ALPHA,
        };
        try com.check(device.createBlendState(&desc, &blend), "ID3D11Device::CreateBlendState");

        return .{
            .bg_vs = bg_vs.?,
            .bg_ps = bg_ps.?,
            .text_vs = text_vs.?,
            .text_ps = text_ps.?,
            .blend = blend.?,
        };
    }

    fn deinit(self: *Pipeline) void {
        com.release(self.bg_vs);
        com.release(self.bg_ps);
        com.release(self.text_vs);
        com.release(self.text_ps);
        com.release(self.blend);
        self.* = undefined;
    }

    /// Compile `entry` from shaders.hlsl. The shader type comes from the
    /// output pointer: vertex shaders use vs_5_0, pixel shaders ps_5_0.
    fn createShader(device: *d3d11.IDevice, comptime entry: [:0]const u8, out: anytype) Error!void {
        const is_vs = @TypeOf(out) == *?*d3d11.IVertexShader;
        const flags = d3dcompiler.COMPILE_ENABLE_STRICTNESS | if (builtin.mode == .Debug)
            d3dcompiler.COMPILE_DEBUG | d3dcompiler.COMPILE_SKIP_OPTIMIZATION
        else
            d3dcompiler.COMPILE_OPTIMIZATION_LEVEL3;

        var code: ?*d3dcompiler.IBlob = null;
        var errors: ?*d3dcompiler.IBlob = null;
        defer com.releaseOpt(&code);
        defer com.releaseOpt(&errors);
        const hr = d3dcompiler.D3DCompile(
            shader_source.ptr,
            shader_source.len,
            "shaders.hlsl",
            null,
            null,
            entry,
            if (is_vs) "vs_5_0" else "ps_5_0",
            flags,
            0,
            &code,
            &errors,
        );
        if (errors) |e| log.err("{s}: {s}", .{ entry, e.slice() });
        try com.check(hr, "D3DCompile(" ++ entry ++ ")");

        const bytecode = code.?.slice();
        if (is_vs) {
            try com.check(device.createVertexShader(bytecode, out), "CreateVertexShader(" ++ entry ++ ")");
        } else {
            try com.check(device.createPixelShader(bytecode, out), "CreatePixelShader(" ++ entry ++ ")");
        }
    }
};

/// A CPU-writable structured buffer bound as a shader resource. It grows
/// to the next power of two when the data outgrows it.
const DynamicBuffer = struct {
    stride: u32,
    buffer: ?*d3d11.IBuffer = null,
    srv: ?*d3d11.IShaderResourceView = null,
    capacity: u32 = 0,

    fn deinit(self: *DynamicBuffer) void {
        com.releaseOpt(&self.srv);
        com.releaseOpt(&self.buffer);
    }

    fn upload(self: *DynamicBuffer, device: *d3d11.IDevice, ctx: *d3d11.IDeviceContext, bytes: []const u8) Error!void {
        const count: u32 = @intCast(bytes.len / self.stride);
        if (count == 0) return;

        if (count > self.capacity) {
            self.deinit();
            self.capacity = 0;
            const capacity = @max(64, std.math.ceilPowerOfTwoAssert(u32, count));
            try com.check(device.createBuffer(&.{
                .ByteWidth = capacity * self.stride,
                .Usage = d3d11.USAGE_DYNAMIC,
                .BindFlags = d3d11.BIND_SHADER_RESOURCE,
                .CPUAccessFlags = d3d11.CPU_ACCESS_WRITE,
                .MiscFlags = d3d11.RESOURCE_MISC_BUFFER_STRUCTURED,
                .StructureByteStride = self.stride,
            }, &self.buffer), "ID3D11Device::CreateBuffer(structured)");
            try com.check(
                device.createShaderResourceView(self.buffer.?.resource(), &self.srv),
                "ID3D11Device::CreateShaderResourceView(structured)",
            );
            self.capacity = capacity;
        }

        var mapped: d3d11.MAPPED_SUBRESOURCE = undefined;
        try com.check(ctx.map(self.buffer.?.resource(), d3d11.MAP_WRITE_DISCARD, &mapped), "Map(structured)");
        @memcpy(@as([*]u8, @ptrCast(mapped.pData.?))[0..bytes.len], bytes);
        ctx.unmap(self.buffer.?.resource());
    }
};
