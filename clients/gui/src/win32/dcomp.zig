//! DirectComposition interfaces. Slot numbers are from mingw's dcomp.h,
//! except `IVisual3`, which mingw lacks: that one is from the Windows SDK's
//! um/dcomp.h (10.0.26100.0). Where a method is overloaded, the vtable
//! has the overloads in reverse declaration order, the animated one
//! first; mingw's non-MSVC branch lists them in that order.

const win32 = @import("win32.zig");
const com = @import("com.zig");

const HRESULT = win32.HRESULT;
const GUID = win32.GUID;

/// IDCompositionDesktopDevice, through IDCompositionDevice2 (Windows 8.1).
pub const IDesktopDevice = extern struct {
    vtable: com.VTable,

    pub const iid: GUID = .{
        .data1 = 0x5f4633fe,
        .data2 = 0x1e08,
        .data3 = 0x4cb8,
        .data4 = .{ 0x8c, 0x75, 0xce, 0x24, 0x33, 0x3f, 0x56, 0x02 },
    };

    pub fn commit(self: *IDesktopDevice) HRESULT {
        return com.call(self, 3, fn () HRESULT, .{});
    }

    pub fn createVisual(self: *IDesktopDevice, out: *?*IVisual) HRESULT {
        return com.call(self, 6, fn (*?*IVisual) HRESULT, .{out});
    }

    pub fn createRectangleClip(self: *IDesktopDevice, out: *?*IRectangleClip) HRESULT {
        return com.call(self, 22, fn (*?*IRectangleClip) HRESULT, .{out});
    }

    pub fn createTargetForHwnd(self: *IDesktopDevice, hwnd: win32.HWND, topmost: bool, out: *?*ITarget) HRESULT {
        return com.call(self, 24, fn (win32.HWND, win32.BOOL, *?*ITarget) HRESULT, .{
            hwnd, if (topmost) win32.TRUE else win32.FALSE, out,
        });
    }
};

pub const ITarget = extern struct {
    vtable: com.VTable,

    pub fn setRoot(self: *ITarget, visual: ?*IVisual) HRESULT {
        return com.call(self, 3, fn (?*IVisual) HRESULT, .{visual});
    }
};

/// IDCompositionVisual; the device's visuals are IDCompositionVisual2s,
/// which add nothing called here.
pub const IVisual = extern struct {
    vtable: com.VTable,

    pub fn setOffsetX(self: *IVisual, x: f32) HRESULT {
        return com.call(self, 4, fn (f32) HRESULT, .{x});
    }

    pub fn setOffsetY(self: *IVisual, y: f32) HRESULT {
        return com.call(self, 6, fn (f32) HRESULT, .{y});
    }

    pub fn setClip(self: *IVisual, clip: ?*IRectangleClip) HRESULT {
        return com.call(self, 13, fn (?*IRectangleClip) HRESULT, .{clip});
    }

    /// A swap chain, a surface, or null.
    pub fn setContent(self: *IVisual, content: ?*anyopaque) HRESULT {
        return com.call(self, 15, fn (?*anyopaque) HRESULT, .{content});
    }

    /// With `reference` null, `insert_above` false puts `visual` over
    /// every sibling and true under them; otherwise it goes just over or
    /// under `reference`.
    pub fn addVisual(self: *IVisual, visual: *IVisual, insert_above: bool, reference: ?*IVisual) HRESULT {
        return com.call(self, 16, fn (*IVisual, win32.BOOL, ?*IVisual) HRESULT, .{
            visual, if (insert_above) win32.TRUE else win32.FALSE, reference,
        });
    }

    pub fn removeVisual(self: *IVisual, visual: *IVisual) HRESULT {
        return com.call(self, 17, fn (*IVisual) HRESULT, .{visual});
    }
};

/// IDCompositionVisual3 (Windows 10), through IDCompositionVisual2 and
/// IDCompositionVisualDebug, queried from a device-3 visual.
pub const IVisual3 = extern struct {
    vtable: com.VTable,

    pub const iid: GUID = .{
        .data1 = 0x2775f462,
        .data2 = 0xb6c1,
        .data3 = 0x4015,
        .data4 = .{ 0xb0, 0xbe, 0xb3, 0xe7, 0xd6, 0xa4, 0x97, 0x6d },
    };

    pub fn setOpacity(self: *IVisual3, opacity: f32) HRESULT {
        return com.call(self, 30, fn (f32) HRESULT, .{opacity});
    }

    pub fn setVisible(self: *IVisual3, visible: bool) HRESULT {
        return com.call(self, 33, fn (win32.BOOL) HRESULT, .{if (visible) win32.TRUE else win32.FALSE});
    }

    pub fn visual(self: *IVisual3) *IVisual {
        return @ptrCast(self);
    }
};

pub const IRectangleClip = extern struct {
    vtable: com.VTable,

    pub fn setLeft(self: *IRectangleClip, v: f32) HRESULT {
        return com.call(self, 4, fn (f32) HRESULT, .{v});
    }

    pub fn setTop(self: *IRectangleClip, v: f32) HRESULT {
        return com.call(self, 6, fn (f32) HRESULT, .{v});
    }

    pub fn setRight(self: *IRectangleClip, v: f32) HRESULT {
        return com.call(self, 8, fn (f32) HRESULT, .{v});
    }

    pub fn setBottom(self: *IRectangleClip, v: f32) HRESULT {
        return com.call(self, 10, fn (f32) HRESULT, .{v});
    }

    pub fn setBottomLeftRadiusX(self: *IRectangleClip, v: f32) HRESULT {
        return com.call(self, 20, fn (f32) HRESULT, .{v});
    }

    pub fn setBottomLeftRadiusY(self: *IRectangleClip, v: f32) HRESULT {
        return com.call(self, 22, fn (f32) HRESULT, .{v});
    }

    pub fn setBottomRightRadiusX(self: *IRectangleClip, v: f32) HRESULT {
        return com.call(self, 24, fn (f32) HRESULT, .{v});
    }

    pub fn setBottomRightRadiusY(self: *IRectangleClip, v: f32) HRESULT {
        return com.call(self, 26, fn (f32) HRESULT, .{v});
    }
};

/// Windows 10. `rendering_device` may be null when every visual's content
/// is a swap chain.
pub extern "dcomp" fn DCompositionCreateDevice3(rendering_device: ?*anyopaque, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT;
