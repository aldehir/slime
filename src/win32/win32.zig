//! Hand-written Win32 bindings. Only what we use is declared here; add
//! to it as needed rather than pulling in a full binding generator.

const std = @import("std");

pub const com = @import("com.zig");
pub const dxgi = @import("dxgi.zig");
pub const d3d11 = @import("d3d11.zig");
pub const d3dcompiler = @import("d3dcompiler.zig");
pub const dwrite = @import("dwrite.zig");

pub const BOOL = i32;
pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;
pub const HRESULT = i32;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const LPCWSTR = [*:0]const u16;

pub const HWND = *opaque {};
pub const HINSTANCE = *opaque {};
pub const HICON = *opaque {};
pub const HCURSOR = *opaque {};
pub const HBRUSH = *opaque {};
pub const HMENU = *opaque {};
pub const DPI_AWARENESS_CONTEXT = *opaque {};

pub const GUID = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

pub const POINT = extern struct { x: i32, y: i32 };

pub const RECT = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

pub const MSG = extern struct {
    hwnd: ?HWND,
    message: u32,
    wParam: WPARAM,
    lParam: LPARAM,
    time: u32,
    pt: POINT,
    lPrivate: u32,
};

pub const WNDPROC = *const fn (HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;

pub const WNDCLASSEXW = extern struct {
    cbSize: u32 = @sizeOf(WNDCLASSEXW),
    style: u32 = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?HINSTANCE,
    hIcon: ?HICON = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?HBRUSH = null,
    lpszMenuName: ?LPCWSTR = null,
    lpszClassName: LPCWSTR,
    hIconSm: ?HICON = null,
};

pub const CREATESTRUCTW = extern struct {
    lpCreateParams: ?*anyopaque,
    hInstance: ?HINSTANCE,
    hMenu: ?HMENU,
    hwndParent: ?HWND,
    cy: i32,
    cx: i32,
    y: i32,
    x: i32,
    style: i32,
    lpszName: ?LPCWSTR,
    lpszClass: ?LPCWSTR,
    dwExStyle: u32,
};

// Window messages
pub const WM_CREATE = 0x0001;
pub const WM_DESTROY = 0x0002;
pub const WM_SIZE = 0x0005;
pub const WM_PAINT = 0x000F;
pub const WM_CLOSE = 0x0010;
pub const WM_ERASEBKGND = 0x0014;
pub const WM_NCCREATE = 0x0081;
pub const WM_DPICHANGED = 0x02E0;

// Window styles
pub const WS_OVERLAPPEDWINDOW: u32 = 0x00CF0000;
pub const WS_EX_NOREDIRECTIONBITMAP: u32 = 0x00200000;
pub const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
pub const SW_SHOWDEFAULT = 10;
pub const GWLP_USERDATA = -21;
pub const SIZE_MINIMIZED = 1;
pub const SWP_NOZORDER = 0x0004;
pub const SWP_NOACTIVATE = 0x0010;
pub const IDC_ARROW: LPCWSTR = @ptrFromInt(32512);
pub const USER_DEFAULT_SCREEN_DPI = 96;

pub const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: DPI_AWARENESS_CONTEXT =
    @ptrFromInt(@as(usize, @bitCast(@as(isize, -4))));

pub const DWMWA_USE_IMMERSIVE_DARK_MODE = 20;

pub extern "kernel32" fn GetModuleHandleW(?LPCWSTR) callconv(.winapi) ?HINSTANCE;
pub extern "kernel32" fn GetLastError() callconv(.winapi) u32;

pub extern "user32" fn SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT) callconv(.winapi) BOOL;
pub extern "user32" fn GetDpiForWindow(HWND) callconv(.winapi) u32;
pub extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) u16;
pub extern "user32" fn CreateWindowExW(
    dwExStyle: u32,
    lpClassName: LPCWSTR,
    lpWindowName: LPCWSTR,
    dwStyle: u32,
    x: i32,
    y: i32,
    nWidth: i32,
    nHeight: i32,
    hWndParent: ?HWND,
    hMenu: ?HMENU,
    hInstance: ?HINSTANCE,
    lpParam: ?*anyopaque,
) callconv(.winapi) ?HWND;
pub extern "user32" fn DestroyWindow(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn DefWindowProcW(HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn ShowWindow(HWND, i32) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPos(HWND, ?HWND, i32, i32, i32, i32, u32) callconv(.winapi) BOOL;
pub extern "user32" fn GetClientRect(HWND, *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn ValidateRect(HWND, ?*const RECT) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowLongPtrW(HWND, i32, isize) callconv(.winapi) isize;
pub extern "user32" fn GetWindowLongPtrW(HWND, i32) callconv(.winapi) isize;
pub extern "user32" fn LoadCursorW(?HINSTANCE, LPCWSTR) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn GetMessageW(*MSG, ?HWND, u32, u32) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn PostQuitMessage(i32) callconv(.winapi) void;

pub extern "dwmapi" fn DwmSetWindowAttribute(HWND, u32, *const anyopaque, u32) callconv(.winapi) HRESULT;

pub inline fn loword(v: anytype) u16 {
    return @truncate(@as(usize, @bitCast(v)));
}

pub inline fn hiword(v: anytype) u16 {
    return @truncate(@as(usize, @bitCast(v)) >> 16);
}

/// Log the thread's last Win32 error and return a generic error.
pub fn lastError(comptime what: []const u8) error{Win32} {
    std.log.scoped(.win32).err("{s} failed: GetLastError={d}", .{ what, GetLastError() });
    return error.Win32;
}

test {
    std.testing.refAllDecls(@This());
}
