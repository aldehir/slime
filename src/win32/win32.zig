//! Hand-written Win32 bindings. Only what we use is declared here; add
//! to it as needed rather than pulling in a full binding generator.

const std = @import("std");

pub const com = @import("com.zig");
pub const dxgi = @import("dxgi.zig");
pub const d3d11 = @import("d3d11.zig");
pub const d3dcompiler = @import("d3dcompiler.zig");
pub const dwrite = @import("dwrite.zig");
pub const conpty = @import("conpty.zig");

pub const BOOL = i32;
pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;
pub const HRESULT = i32;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const LPCWSTR = [*:0]const u16;
pub const LPWSTR = [*:0]u16;

pub const HANDLE = *anyopaque;
pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
pub const HMODULE = *opaque {};
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

pub const SRWLOCK = extern struct { ptr: ?*anyopaque = null };

pub const STARTUPINFOW = extern struct {
    cb: u32,
    lpReserved: ?LPWSTR = null,
    lpDesktop: ?LPWSTR = null,
    lpTitle: ?LPWSTR = null,
    dwX: u32 = 0,
    dwY: u32 = 0,
    dwXSize: u32 = 0,
    dwYSize: u32 = 0,
    dwXCountChars: u32 = 0,
    dwYCountChars: u32 = 0,
    dwFillAttribute: u32 = 0,
    dwFlags: u32 = 0,
    wShowWindow: u16 = 0,
    cbReserved2: u16 = 0,
    lpReserved2: ?*u8 = null,
    hStdInput: ?HANDLE = null,
    hStdOutput: ?HANDLE = null,
    hStdError: ?HANDLE = null,
};

pub const STARTUPINFOEXW = extern struct {
    StartupInfo: STARTUPINFOW = .{ .cb = @sizeOf(STARTUPINFOEXW) },
    lpAttributeList: ?*anyopaque = null,
};

pub const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: u32,
    dwThreadId: u32,
};

pub const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: i64 = 0,
    PerJobUserTimeLimit: i64 = 0,
    LimitFlags: u32 = 0,
    MinimumWorkingSetSize: usize = 0,
    MaximumWorkingSetSize: usize = 0,
    ActiveProcessLimit: u32 = 0,
    Affinity: usize = 0,
    PriorityClass: u32 = 0,
    SchedulingClass: u32 = 0,
};

pub const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION = .{},
    IoInfo: [6]u64 = @splat(0),
    ProcessMemoryLimit: usize = 0,
    JobMemoryLimit: usize = 0,
    PeakProcessMemoryUsed: usize = 0,
    PeakJobMemoryUsed: usize = 0,
};

/// Only the leading fields we read; the rest is padding. Byte packed in
/// dwmapi.h (292 bytes).
pub const DWM_TIMING_INFO = extern struct {
    cbSize: u32 align(1) = @sizeOf(DWM_TIMING_INFO),
    rateRefreshNumerator: u32 align(1) = 0,
    rateRefreshDenominator: u32 align(1) = 0,
    qpcRefreshPeriod: u64 align(1) = 0,
    rest: [272]u8 = @splat(0),

    comptime {
        std.debug.assert(@sizeOf(DWM_TIMING_INFO) == 292);
    }
};

pub const WAITORTIMERCALLBACK = *const fn (?*anyopaque, u8) callconv(.winapi) void;

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
pub const WM_KEYDOWN = 0x0100;
pub const WM_KEYUP = 0x0101;
pub const WM_CHAR = 0x0102;
pub const WM_DEADCHAR = 0x0103;
pub const WM_SYSKEYDOWN = 0x0104;
pub const WM_SYSKEYUP = 0x0105;
pub const WM_SYSCHAR = 0x0106;
pub const WM_SYSDEADCHAR = 0x0107;
pub const WM_QUIT = 0x0012;
pub const WM_DISPLAYCHANGE = 0x007E;
pub const WM_TIMER = 0x0113;
pub const WM_ENTERSIZEMOVE = 0x0231;
pub const WM_EXITSIZEMOVE = 0x0232;
pub const WM_SETCURSOR = 0x0020;
pub const WM_MOUSEMOVE = 0x0200;
pub const WM_LBUTTONDOWN = 0x0201;
pub const WM_LBUTTONUP = 0x0202;
pub const WM_RBUTTONDOWN = 0x0204;
pub const WM_RBUTTONUP = 0x0205;
pub const WM_MBUTTONDOWN = 0x0207;
pub const WM_MBUTTONUP = 0x0208;
pub const WM_MOUSEWHEEL = 0x020A;
pub const WM_XBUTTONDOWN = 0x020B;
pub const WM_XBUTTONUP = 0x020C;
pub const WM_MOUSEHWHEEL = 0x020E;
pub const WM_DPICHANGED = 0x02E0;
pub const WM_APP = 0x8000;

// Window styles
pub const WS_OVERLAPPEDWINDOW: u32 = 0x00CF0000;
pub const WS_EX_NOREDIRECTIONBITMAP: u32 = 0x00200000;
pub const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
pub const SW_SHOWDEFAULT = 10;
pub const GWLP_USERDATA = -21;
pub const SIZE_MINIMIZED = 1;
pub const SWP_NOZORDER = 0x0004;
pub const SWP_NOACTIVATE = 0x0010;
// Cursor resource IDs (MAKEINTRESOURCE values, which aren't u16-aligned).
pub const IDC_ARROW: usize = 32512;
pub const IDC_IBEAM: usize = 32513;
pub const IDC_WAIT: usize = 32514;
pub const IDC_CROSS: usize = 32515;
pub const IDC_SIZENWSE: usize = 32642;
pub const IDC_SIZENESW: usize = 32643;
pub const IDC_SIZEWE: usize = 32644;
pub const IDC_SIZENS: usize = 32645;
pub const IDC_SIZEALL: usize = 32646;
pub const IDC_NO: usize = 32648;
pub const IDC_HAND: usize = 32649;
pub const IDC_APPSTARTING: usize = 32650;
pub const IDC_HELP: usize = 32651;
pub const HTCLIENT = 1;
pub const USER_DEFAULT_SCREEN_DPI = 96;

pub const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: DPI_AWARENESS_CONTEXT =
    @ptrFromInt(@as(usize, @bitCast(@as(isize, -4))));

pub const DWMWA_USE_IMMERSIVE_DARK_MODE = 20;

pub const PM_REMOVE = 0x0001;
pub const QS_ALLINPUT = 0x04FF;
pub const MWMO_INPUTAVAILABLE = 0x0004;
pub const WAIT_OBJECT_0 = 0;
pub const CREATE_WAITABLE_TIMER_MANUAL_RESET = 0x00000001;
pub const CREATE_WAITABLE_TIMER_HIGH_RESOLUTION = 0x00000002;
pub const TIMER_ALL_ACCESS = 0x001F0003;
pub const MAPVK_VK_TO_CHAR = 2;

// Mouse
pub const MK_LBUTTON = 0x0001;
pub const MK_RBUTTON = 0x0002;
pub const MK_SHIFT = 0x0004;
pub const MK_CONTROL = 0x0008;
pub const MK_MBUTTON = 0x0010;
pub const MK_XBUTTON1 = 0x0020;
pub const MK_XBUTTON2 = 0x0040;
pub const XBUTTON1 = 0x0001;
pub const WHEEL_DELTA = 120;
pub const WHEEL_PAGESCROLL: u32 = 0xFFFFFFFF;
pub const SPI_GETWHEELSCROLLLINES = 0x0068;

// Virtual keys
pub const VK_SHIFT = 0x10;
pub const VK_CONTROL = 0x11;
pub const VK_MENU = 0x12;
pub const VK_CAPITAL = 0x14;
pub const VK_LWIN = 0x5B;
pub const VK_RWIN = 0x5C;
pub const VK_NUMPAD0 = 0x60;
pub const VK_NUMPAD9 = 0x69;
pub const VK_DECIMAL = 0x6E;
pub const VK_F4 = 0x73;
pub const VK_NUMLOCK = 0x90;
pub const VK_RSHIFT = 0xA1;
pub const VK_RCONTROL = 0xA3;
pub const VK_RMENU = 0xA5;
pub const VK_PROCESSKEY = 0xE5;
pub const VK_PACKET = 0xE7;

// Processes and jobs
pub const STARTF_USESTDHANDLES = 0x00000100;
pub const CREATE_SUSPENDED = 0x00000004;
pub const CREATE_UNICODE_ENVIRONMENT = 0x00000400;
pub const EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
pub const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x00020016;
pub const JobObjectExtendedLimitInformation = 9;
pub const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
pub const WT_EXECUTEONLYONCE = 0x00000008;
pub const INFINITE: u32 = 0xFFFFFFFF;
pub const LOAD_LIBRARY_SEARCH_APPLICATION_DIR = 0x00000200;

pub const ERROR_BROKEN_PIPE = 109;

pub extern "kernel32" fn GetModuleHandleW(?LPCWSTR) callconv(.winapi) ?HINSTANCE;
pub extern "kernel32" fn GetLastError() callconv(.winapi) u32;
pub extern "kernel32" fn QueryPerformanceCounter(*i64) callconv(.winapi) BOOL;
pub extern "kernel32" fn QueryPerformanceFrequency(*i64) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateEventW(?*anyopaque, BOOL, BOOL, ?LPCWSTR) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn SetEvent(HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateWaitableTimerExW(?*anyopaque, ?LPCWSTR, u32, u32) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GetSystemTimePreciseAsFileTime(*i64) callconv(.winapi) void;
pub extern "kernel32" fn SetWaitableTimer(HANDLE, *const i64, i32, ?*anyopaque, ?*anyopaque, BOOL) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitForSingleObject(HANDLE, u32) callconv(.winapi) u32;
pub extern "kernel32" fn CloseHandle(HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreatePipe(*HANDLE, *HANDLE, ?*anyopaque, u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn ReadFile(HANDLE, [*]u8, u32, ?*u32, ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn WriteFile(HANDLE, [*]const u8, u32, ?*u32, ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetCommandLineW() callconv(.winapi) LPCWSTR;
pub extern "kernel32" fn GetEnvironmentVariableW(LPCWSTR, ?[*]u16, u32) callconv(.winapi) u32;
pub extern "kernel32" fn LoadLibraryExW(LPCWSTR, ?HANDLE, u32) callconv(.winapi) ?HMODULE;
pub extern "kernel32" fn GetProcAddress(HMODULE, [*:0]const u8) callconv(.winapi) ?*const anyopaque;
pub extern "kernel32" fn InitializeProcThreadAttributeList(?*anyopaque, u32, u32, *usize) callconv(.winapi) BOOL;
pub extern "kernel32" fn UpdateProcThreadAttribute(*anyopaque, u32, usize, ?*const anyopaque, usize, ?*anyopaque, ?*usize) callconv(.winapi) BOOL;
pub extern "kernel32" fn DeleteProcThreadAttributeList(*anyopaque) callconv(.winapi) void;
pub extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?LPCWSTR,
    lpCommandLine: ?LPWSTR,
    lpProcessAttributes: ?*anyopaque,
    lpThreadAttributes: ?*anyopaque,
    bInheritHandles: BOOL,
    dwCreationFlags: u32,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: ?LPCWSTR,
    lpStartupInfo: *STARTUPINFOEXW,
    lpProcessInformation: *PROCESS_INFORMATION,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn ResumeThread(HANDLE) callconv(.winapi) u32;
pub extern "kernel32" fn CreateJobObjectW(?*anyopaque, ?LPCWSTR) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn SetInformationJobObject(HANDLE, i32, *const anyopaque, u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn AssignProcessToJobObject(HANDLE, HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn RegisterWaitForSingleObject(*HANDLE, HANDLE, WAITORTIMERCALLBACK, ?*anyopaque, u32, u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn UnregisterWaitEx(HANDLE, ?HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn AcquireSRWLockExclusive(*SRWLOCK) callconv(.winapi) void;
pub extern "kernel32" fn ReleaseSRWLockExclusive(*SRWLOCK) callconv(.winapi) void;

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
pub extern "user32" fn LoadCursorW(?HINSTANCE, usize) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn GetMessageW(*MSG, ?HWND, u32, u32) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn PostQuitMessage(i32) callconv(.winapi) void;
pub extern "user32" fn MsgWaitForMultipleObjectsEx(u32, ?[*]const HANDLE, u32, u32, u32) callconv(.winapi) u32;
pub extern "user32" fn KillTimer(?HWND, usize) callconv(.winapi) BOOL;
pub extern "user32" fn SetTimer(?HWND, usize, u32, ?*const anyopaque) callconv(.winapi) usize;
pub extern "user32" fn SetWindowTextW(HWND, LPCWSTR) callconv(.winapi) BOOL;
pub extern "user32" fn PostMessageW(?HWND, u32, WPARAM, LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn PeekMessageW(*MSG, ?HWND, u32, u32, u32) callconv(.winapi) BOOL;
pub extern "user32" fn GetKeyState(i32) callconv(.winapi) i16;
pub extern "user32" fn MapVirtualKeyW(u32, u32) callconv(.winapi) u32;
pub extern "user32" fn SetCapture(HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
pub extern "user32" fn ScreenToClient(HWND, *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn SetCursor(?HCURSOR) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn SystemParametersInfoW(u32, u32, ?*anyopaque, u32) callconv(.winapi) BOOL;

pub extern "dwmapi" fn DwmGetCompositionTimingInfo(?HWND, *DWM_TIMING_INFO) callconv(.winapi) HRESULT;
pub extern "dwmapi" fn DwmSetWindowAttribute(HWND, u32, *const anyopaque, u32) callconv(.winapi) HRESULT;

pub inline fn loword(v: anytype) u16 {
    return @truncate(@as(usize, @bitCast(v)));
}

pub inline fn hiword(v: anytype) u16 {
    return @truncate(@as(usize, @bitCast(v)) >> 16);
}

/// The signed x coordinate in a mouse message's lParam (GET_X_LPARAM).
pub inline fn xLparam(v: LPARAM) i32 {
    return @as(i16, @bitCast(loword(v)));
}

/// The signed y coordinate in a mouse message's lParam (GET_Y_LPARAM).
pub inline fn yLparam(v: LPARAM) i32 {
    return @as(i16, @bitCast(hiword(v)));
}

/// Log the thread's last Win32 error and return a generic error.
pub fn lastError(comptime what: []const u8) error{Win32} {
    std.log.scoped(.win32).err("{s} failed: GetLastError={d}", .{ what, GetLastError() });
    return error.Win32;
}

test {
    std.testing.refAllDecls(@This());
}
