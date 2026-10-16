//! Minimal COM support.
//!
//! A COM interface pointer points at an object whose first field is a
//! pointer to a table of function pointers. Rather than declaring every
//! slot of every vtable, interface wrappers call methods by slot index.
//! Slot numbers come from the vtable order in the mingw headers bundled
//! with Zig (lib/libc/include/any-windows-any). Inherited slots count:
//! every interface starts with IUnknown's QueryInterface/AddRef/Release.

const std = @import("std");
const win32 = @import("win32.zig");

const log = std.log.scoped(.com);

/// Embed as the only field of an interface wrapper struct.
pub const VTable = [*]const *const anyopaque;

/// Call the method at `slot` of `self`'s vtable. `Fn` is the method's
/// signature excluding the implicit `this` parameter.
pub inline fn call(
    self: anytype,
    comptime slot: usize,
    comptime Fn: type,
    args: anytype,
) Return(Fn) {
    const f: *const WithThis(@TypeOf(self), Fn) = @ptrCast(self.vtable[slot]);
    return @call(.auto, f, .{self} ++ args);
}

/// IUnknown::Release (slot 2). Valid for every COM interface.
pub fn release(self: anytype) void {
    _ = call(self, 2, fn () u32, .{});
}

/// Release a COM pointer if non-null and set it to null.
pub fn releaseOpt(ptr: anytype) void {
    if (ptr.*) |p| release(p);
    ptr.* = null;
}

pub const S_OK: win32.HRESULT = 0;
pub const E_NOINTERFACE: win32.HRESULT = @bitCast(@as(u32, 0x80004002));
pub const E_OUTOFMEMORY: win32.HRESULT = @bitCast(@as(u32, 0x8007000E));

pub const IID_IUnknown: win32.GUID = .{
    .data1 = 0,
    .data2 = 0,
    .data3 = 0,
    .data4 = .{ 0xc0, 0, 0, 0, 0, 0, 0, 0x46 },
};

pub fn guidEql(a: *const win32.GUID, b: *const win32.GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

pub const Error = error{HResult};

/// Convert a failing HRESULT into an error, logging what failed.
pub fn check(hr: win32.HRESULT, comptime what: []const u8) Error!void {
    if (hr >= 0) return;
    log.err("{s} failed: HRESULT=0x{X:0>8}", .{ what, @as(u32, @bitCast(hr)) });
    return error.HResult;
}

fn Return(comptime Fn: type) type {
    return @typeInfo(Fn).@"fn".return_type.?;
}

/// Prepend a `this: Self` parameter to `Fn` and give it the winapi
/// calling convention.
fn WithThis(comptime Self: type, comptime Fn: type) type {
    const info = @typeInfo(Fn).@"fn";
    var params: [info.params.len + 1]type = undefined;
    params[0] = Self;
    for (info.params, 1..) |p, i| params[i] = p.type.?;
    return @Fn(&params, &@splat(.{}), info.return_type.?, .{ .@"callconv" = .winapi });
}
