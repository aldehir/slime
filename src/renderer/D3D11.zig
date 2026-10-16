//! Direct3D 11 renderer: device, flip-model swap chain, and frame
//! presentation for a single window.
const D3D11 = @This();

const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../win32/win32.zig");
const com = win32.com;
const d3d11 = win32.d3d11;
const dxgi = win32.dxgi;

const log = std.log.scoped(.d3d11);

const buffer_count = 2;
const buffer_format: dxgi.FORMAT = .B8G8R8A8_UNORM;

device: *d3d11.IDevice,
context: *d3d11.IDeviceContext,
swap_chain: *dxgi.ISwapChain1,
rtv: ?*d3d11.IRenderTargetView = null,
width: u32,
height: u32,

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

    var self: D3D11 = .{
        .device = device.?,
        .context = context.?,
        .swap_chain = swap_chain.?,
        .width = width,
        .height = height,
    };
    try self.createRenderTarget();
    return self;
}

pub fn deinit(self: *D3D11) void {
    self.context.clearState();
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

/// Draw a frame and present it, waiting for vblank.
pub fn render(self: *D3D11, background: [4]f32) error{ DeviceLost, HResult }!void {
    const rtv = self.rtv orelse return;
    self.context.omSetRenderTargets(&.{rtv});
    self.context.rsSetViewports(&.{.{
        .Width = @floatFromInt(self.width),
        .Height = @floatFromInt(self.height),
    }});
    self.context.clearRenderTargetView(rtv, &background);

    const hr = self.swap_chain.present(1, 0);
    if (hr == dxgi.ERROR_DEVICE_REMOVED or hr == dxgi.ERROR_DEVICE_RESET) {
        // TODO: recreate the device and all GPU resources.
        return error.DeviceLost;
    }
    try com.check(hr, "IDXGISwapChain::Present");
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
    const levels = [_]d3d11.FEATURE_LEVEL{ .@"11_1", .@"11_0", .@"10_1", .@"10_0" };
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
