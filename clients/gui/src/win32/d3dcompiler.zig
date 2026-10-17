//! Runtime HLSL compilation via d3dcompiler_47.dll, which ships with
//! Windows 10 and later.

const win32 = @import("win32.zig");
const com = @import("com.zig");

pub const COMPILE_DEBUG: u32 = 0x1;
pub const COMPILE_SKIP_OPTIMIZATION: u32 = 0x4;
pub const COMPILE_ENABLE_STRICTNESS: u32 = 0x800;
pub const COMPILE_OPTIMIZATION_LEVEL3: u32 = 0x8000;

/// ID3DBlob (ID3D10Blob).
pub const IBlob = extern struct {
    vtable: com.VTable,

    pub fn slice(self: *IBlob) []const u8 {
        const ptr = com.call(self, 3, fn () [*]const u8, .{});
        const len = com.call(self, 4, fn () usize, .{});
        return ptr[0..len];
    }
};

pub extern "d3dcompiler" fn D3DCompile(
    data: [*]const u8,
    data_size: usize,
    source_name: ?[*:0]const u8,
    defines: ?*const anyopaque,
    include: ?*anyopaque,
    entrypoint: [*:0]const u8,
    target: [*:0]const u8,
    flags1: u32,
    flags2: u32,
    code: *?*IBlob,
    errors: ?*?*IBlob,
) callconv(.winapi) win32.HRESULT;
