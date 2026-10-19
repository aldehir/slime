//! WebView2, the browser in browser panes, hosted in visual mode: its
//! output goes to a DirectComposition visual we place, and we forward
//! the mouse to it. mingw has no WebView2 headers, so slot numbers here
//! are from the NuGet package's build/native/include/WebView2.h,
//! Microsoft.Web.WebView2 1.0.4258.31 (the version build.zig fetches the
//! loader from). Inherited slots count, as in `com.zig`. The interfaces
//! are append-only, so a newer runtime keeps these slots; one older than
//! an interface fails its `com.query`.
//!
//! The handlers WebView2 calls back are ours to implement (`Handler`):
//! each is IUnknown and an `Invoke` taking the sender and its arguments.

const std = @import("std");
const win32 = @import("win32.zig");
const com = @import("com.zig");

const HRESULT = win32.HRESULT;
const GUID = win32.GUID;
const BOOL = win32.BOOL;

/// `CreateCoreWebView2EnvironmentWithOptions`, from WebView2Loader.dll.
/// A null user data folder is the exe's directory, which a build tree
/// shouldn't hold; options may be null for the defaults.
pub const CreateEnvironmentWithOptions = *const fn (
    browser_folder: ?win32.LPCWSTR,
    user_data_folder: ?win32.LPCWSTR,
    options: ?*anyopaque,
    handler: *EnvironmentCompletedHandler,
) callconv(.winapi) HRESULT;

/// `GetAvailableCoreWebView2BrowserVersionString`: the runtime's version,
/// or an error without one. The string is CoTaskMemFree'd.
pub const GetAvailableBrowserVersionString = *const fn (
    browser_folder: ?win32.LPCWSTR,
    version: *?win32.LPWSTR,
) callconv(.winapi) HRESULT;

pub const EventRegistrationToken = extern struct { value: i64 = 0 };

/// A GUID from its registry form, `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`,
/// as the header's MIDL_INTERFACE has it.
pub fn guid(comptime s: []const u8) GUID {
    return comptime parse: {
        if (s.len != 36) @compileError("bad GUID " ++ s);
        const int = std.fmt.parseInt;
        var data4: [8]u8 = undefined;
        for (0..2) |i| data4[i] = int(u8, s[19 + 2 * i ..][0..2], 16) catch unreachable;
        for (0..6) |i| data4[2 + i] = int(u8, s[24 + 2 * i ..][0..2], 16) catch unreachable;
        break :parse .{
            .data1 = int(u32, s[0..8], 16) catch unreachable,
            .data2 = int(u16, s[9..13], 16) catch unreachable,
            .data3 = int(u16, s[14..18], 16) catch unreachable,
            .data4 = data4,
        };
    };
}

/// A callback interface we implement: IUnknown, then `Invoke(a, b)`.
/// Embed as the first field of the implementing struct.
pub fn Handler(comptime iid_: []const u8, comptime A_: type, comptime B_: type) type {
    return extern struct {
        const Self = @This();
        vtable: *const VTable,

        pub const iid: GUID = guid(iid_);
        pub const A = A_;
        pub const B = B_;

        pub const VTable = extern struct {
            QueryInterface: *const fn (*Self, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
            AddRef: *const fn (*Self) callconv(.winapi) u32,
            Release: *const fn (*Self) callconv(.winapi) u32,
            Invoke: *const fn (*Self, A_, B_) callconv(.winapi) HRESULT,
        };
    };
}

pub const EnvironmentCompletedHandler = Handler("4e8a3389-c9d8-4bd2-b6b5-124fee6cc14d", HRESULT, ?*IEnvironment);
pub const CompositionControllerCompletedHandler = Handler("02fab84b-1428-4fb7-ad45-1b2e64736184", HRESULT, ?*ICompositionController);
pub const NavigationStartingEventHandler = Handler("9adbe429-f36d-432b-9ddc-f8881fbd76e3", *IWebView, *IUnknown);
pub const NavigationCompletedEventHandler = Handler("d33a35bf-1c49-4f98-93ab-006e0533fe1c", *IWebView, *IUnknown);
pub const SourceChangedEventHandler = Handler("3c067f9f-5388-4772-8b48-79f7ef1ab37c", *IWebView, *IUnknown);
pub const HistoryChangedEventHandler = Handler("c79a420c-efd9-4058-9295-3e8b4bcab645", *IWebView, ?*IUnknown);
pub const DocumentTitleChangedEventHandler = Handler("f5f2b923-953e-4042-9f95-f3a118e1afd4", *IWebView, ?*IUnknown);
pub const NewWindowRequestedEventHandler = Handler("d4c185fe-c81c-4989-97af-2d3fa7ab5651", *IWebView, *INewWindowRequestedEventArgs);
pub const ProcessFailedEventHandler = Handler("79e0aea4-990b-42d9-aa1d-0fcc2e5bc7f1", *IWebView, *IProcessFailedEventArgs);
pub const CursorChangedEventHandler = Handler("9da43ccc-26e1-4dad-b56c-d8961c94c571", *ICompositionController, ?*IUnknown);
/// GotFocus and LostFocus both.
pub const FocusChangedEventHandler = Handler("05ea24bd-6452-4926-9014-4b82b498135d", *IController, ?*IUnknown);
pub const MoveFocusRequestedEventHandler = Handler("69035451-6dc7-4cb8-9bce-b2bd70ad289f", *IController, *IMoveFocusRequestedEventArgs);
pub const AcceleratorKeyPressedEventHandler = Handler("b29c7e28-fa79-41a8-8e44-65811c76dcb2", *IController, *IAcceleratorKeyPressedEventArgs);

/// Event arguments we don't read.
pub const IUnknown = extern struct {
    vtable: com.VTable,
};

/// ICoreWebView2Environment.
pub const IEnvironment = extern struct {
    vtable: com.VTable,

    pub const iid: GUID = guid("b96d755e-0319-4e92-a296-23436f46a1fc");
};

/// ICoreWebView2Environment3, through Environment2.
pub const IEnvironment3 = extern struct {
    vtable: com.VTable,

    pub const iid: GUID = guid("80a22ae3-be7c-4ce2-afe1-5a50056cdeeb");

    /// A WebView whose output goes to a visual (`ICompositionController.
    /// putRootVisualTarget`), with `parent` taking its focus and input.
    pub fn createCompositionController(self: *IEnvironment3, parent: win32.HWND, handler: *CompositionControllerCompletedHandler) HRESULT {
        return com.call(self, 9, fn (win32.HWND, *CompositionControllerCompletedHandler) HRESULT, .{ parent, handler });
    }
};

pub const MoveFocusReason = enum(i32) { programmatic = 0, next = 1, previous = 2 };

/// ICoreWebView2Controller.
pub const IController = extern struct {
    vtable: com.VTable,

    pub const iid: GUID = guid("4d00c0d1-9434-4eb6-8078-8697a560334f");

    pub fn putIsVisible(self: *IController, visible: bool) HRESULT {
        return com.call(self, 4, fn (BOOL) HRESULT, .{@as(BOOL, @intFromBool(visible))});
    }

    /// In the parent window's client pixels.
    pub fn putBounds(self: *IController, bounds: win32.RECT) HRESULT {
        return com.call(self, 6, fn (win32.RECT) HRESULT, .{bounds});
    }

    pub fn moveFocus(self: *IController, reason: MoveFocusReason) HRESULT {
        return com.call(self, 12, fn (MoveFocusReason) HRESULT, .{reason});
    }

    pub fn addMoveFocusRequested(self: *IController, h: *MoveFocusRequestedEventHandler, token: *EventRegistrationToken) HRESULT {
        return com.call(self, 13, fn (*MoveFocusRequestedEventHandler, *EventRegistrationToken) HRESULT, .{ h, token });
    }

    pub fn addGotFocus(self: *IController, h: *FocusChangedEventHandler, token: *EventRegistrationToken) HRESULT {
        return com.call(self, 15, fn (*FocusChangedEventHandler, *EventRegistrationToken) HRESULT, .{ h, token });
    }

    pub fn addLostFocus(self: *IController, h: *FocusChangedEventHandler, token: *EventRegistrationToken) HRESULT {
        return com.call(self, 17, fn (*FocusChangedEventHandler, *EventRegistrationToken) HRESULT, .{ h, token });
    }

    pub fn addAcceleratorKeyPressed(self: *IController, h: *AcceleratorKeyPressedEventHandler, token: *EventRegistrationToken) HRESULT {
        return com.call(self, 19, fn (*AcceleratorKeyPressedEventHandler, *EventRegistrationToken) HRESULT, .{ h, token });
    }

    /// Ends the WebView: its handlers are let go, and the browser process
    /// with the environment's last one.
    pub fn close(self: *IController) HRESULT {
        return com.call(self, 24, fn () HRESULT, .{});
    }

    pub fn getCoreWebView2(self: *IController, out: *?*IWebView) HRESULT {
        return com.call(self, 25, fn (*?*IWebView) HRESULT, .{out});
    }
};

/// ICoreWebView2Controller3, through Controller2.
pub const IController3 = extern struct {
    vtable: com.VTable,

    pub const iid: GUID = guid("f9614724-5d2b-41dc-aef7-73d62b51543b");

    pub fn putRasterizationScale(self: *IController3, scale: f64) HRESULT {
        return com.call(self, 29, fn (f64) HRESULT, .{scale});
    }

    pub fn putShouldDetectMonitorScaleChanges(self: *IController3, detect: bool) HRESULT {
        return com.call(self, 31, fn (BOOL) HRESULT, .{@as(BOOL, @intFromBool(detect))});
    }

    pub fn putBoundsMode(self: *IController3, mode: BoundsMode) HRESULT {
        return com.call(self, 35, fn (BoundsMode) HRESULT, .{mode});
    }
};

pub const BoundsMode = enum(i32) { raw_pixels = 0, rasterization_scale = 1 };

/// The kinds `sendMouseInput` takes, which are the window messages' own
/// numbers.
pub const MouseEventKind = enum(i32) {
    move = 0x0200,
    left_down = 0x0201,
    left_up = 0x0202,
    left_double_click = 0x0203,
    right_down = 0x0204,
    right_up = 0x0205,
    right_double_click = 0x0206,
    middle_down = 0x0207,
    middle_up = 0x0208,
    middle_double_click = 0x0209,
    wheel = 0x020A,
    x_down = 0x020B,
    x_up = 0x020C,
    x_double_click = 0x020D,
    horizontal_wheel = 0x020E,
    leave = 0x02A3,
    _,
};

/// ICoreWebView2CompositionController.
pub const ICompositionController = extern struct {
    vtable: com.VTable,

    pub const iid: GUID = guid("3df9b733-b9ae-4a15-86b4-eb9ee9826469");

    /// An IDCompositionVisual the WebView draws into. Needs a commit.
    pub fn putRootVisualTarget(self: *ICompositionController, target: ?*anyopaque) HRESULT {
        return com.call(self, 4, fn (?*anyopaque) HRESULT, .{target});
    }

    /// `keys` are the message's MK_ flags; `data` its wheel delta or X
    /// button; `point` relative to the bounds.
    pub fn sendMouseInput(self: *ICompositionController, kind: MouseEventKind, keys: u32, data: u32, point: win32.POINT) HRESULT {
        return com.call(self, 5, fn (MouseEventKind, u32, u32, win32.POINT) HRESULT, .{ kind, keys, data, point });
    }

    /// The page's cursor, which stays the WebView's.
    pub fn getCursor(self: *ICompositionController, out: *?win32.HCURSOR) HRESULT {
        return com.call(self, 7, fn (*?win32.HCURSOR) HRESULT, .{out});
    }

    pub fn addCursorChanged(self: *ICompositionController, h: *CursorChangedEventHandler, token: *EventRegistrationToken) HRESULT {
        return com.call(self, 9, fn (*CursorChangedEventHandler, *EventRegistrationToken) HRESULT, .{ h, token });
    }
};

/// ICoreWebView2. Strings it returns are CoTaskMemFree'd.
pub const IWebView = extern struct {
    vtable: com.VTable,

    pub const iid: GUID = guid("76eceacb-0462-4d94-ac83-423a6793775e");

    pub fn getSource(self: *IWebView, out: *?win32.LPWSTR) HRESULT {
        return com.call(self, 4, fn (*?win32.LPWSTR) HRESULT, .{out});
    }

    pub fn navigate(self: *IWebView, uri: win32.LPCWSTR) HRESULT {
        return com.call(self, 5, fn (win32.LPCWSTR) HRESULT, .{uri});
    }

    pub fn addNavigationStarting(self: *IWebView, h: *NavigationStartingEventHandler, token: *EventRegistrationToken) HRESULT {
        return com.call(self, 7, fn (*NavigationStartingEventHandler, *EventRegistrationToken) HRESULT, .{ h, token });
    }

    pub fn addSourceChanged(self: *IWebView, h: *SourceChangedEventHandler, token: *EventRegistrationToken) HRESULT {
        return com.call(self, 11, fn (*SourceChangedEventHandler, *EventRegistrationToken) HRESULT, .{ h, token });
    }

    pub fn addHistoryChanged(self: *IWebView, h: *HistoryChangedEventHandler, token: *EventRegistrationToken) HRESULT {
        return com.call(self, 13, fn (*HistoryChangedEventHandler, *EventRegistrationToken) HRESULT, .{ h, token });
    }

    pub fn addNavigationCompleted(self: *IWebView, h: *NavigationCompletedEventHandler, token: *EventRegistrationToken) HRESULT {
        return com.call(self, 15, fn (*NavigationCompletedEventHandler, *EventRegistrationToken) HRESULT, .{ h, token });
    }

    pub fn addProcessFailed(self: *IWebView, h: *ProcessFailedEventHandler, token: *EventRegistrationToken) HRESULT {
        return com.call(self, 25, fn (*ProcessFailedEventHandler, *EventRegistrationToken) HRESULT, .{ h, token });
    }

    pub fn reload(self: *IWebView) HRESULT {
        return com.call(self, 31, fn () HRESULT, .{});
    }

    pub fn getCanGoBack(self: *IWebView, out: *BOOL) HRESULT {
        return com.call(self, 38, fn (*BOOL) HRESULT, .{out});
    }

    pub fn getCanGoForward(self: *IWebView, out: *BOOL) HRESULT {
        return com.call(self, 39, fn (*BOOL) HRESULT, .{out});
    }

    pub fn goBack(self: *IWebView) HRESULT {
        return com.call(self, 40, fn () HRESULT, .{});
    }

    pub fn goForward(self: *IWebView) HRESULT {
        return com.call(self, 41, fn () HRESULT, .{});
    }

    pub fn stop(self: *IWebView) HRESULT {
        return com.call(self, 43, fn () HRESULT, .{});
    }

    pub fn addNewWindowRequested(self: *IWebView, h: *NewWindowRequestedEventHandler, token: *EventRegistrationToken) HRESULT {
        return com.call(self, 44, fn (*NewWindowRequestedEventHandler, *EventRegistrationToken) HRESULT, .{ h, token });
    }

    pub fn addDocumentTitleChanged(self: *IWebView, h: *DocumentTitleChangedEventHandler, token: *EventRegistrationToken) HRESULT {
        return com.call(self, 46, fn (*DocumentTitleChangedEventHandler, *EventRegistrationToken) HRESULT, .{ h, token });
    }

    pub fn getDocumentTitle(self: *IWebView, out: *?win32.LPWSTR) HRESULT {
        return com.call(self, 48, fn (*?win32.LPWSTR) HRESULT, .{out});
    }
};

/// ICoreWebView2NewWindowRequestedEventArgs.
pub const INewWindowRequestedEventArgs = extern struct {
    vtable: com.VTable,

    pub fn getUri(self: *INewWindowRequestedEventArgs, out: *?win32.LPWSTR) HRESULT {
        return com.call(self, 3, fn (*?win32.LPWSTR) HRESULT, .{out});
    }

    /// Without a new window put, handled means no window opens.
    pub fn putHandled(self: *INewWindowRequestedEventArgs, handled: bool) HRESULT {
        return com.call(self, 6, fn (BOOL) HRESULT, .{@as(BOOL, @intFromBool(handled))});
    }
};

pub const ProcessFailedKind = enum(i32) {
    browser_process_exited = 0,
    render_process_exited = 1,
    render_process_unresponsive = 2,
    _,
};

/// ICoreWebView2ProcessFailedEventArgs.
pub const IProcessFailedEventArgs = extern struct {
    vtable: com.VTable,

    pub fn getProcessFailedKind(self: *IProcessFailedEventArgs, out: *ProcessFailedKind) HRESULT {
        return com.call(self, 3, fn (*ProcessFailedKind) HRESULT, .{out});
    }
};

/// ICoreWebView2MoveFocusRequestedEventArgs.
pub const IMoveFocusRequestedEventArgs = extern struct {
    vtable: com.VTable,

    pub fn getReason(self: *IMoveFocusRequestedEventArgs, out: *MoveFocusReason) HRESULT {
        return com.call(self, 3, fn (*MoveFocusReason) HRESULT, .{out});
    }

    pub fn putHandled(self: *IMoveFocusRequestedEventArgs, handled: bool) HRESULT {
        return com.call(self, 5, fn (BOOL) HRESULT, .{@as(BOOL, @intFromBool(handled))});
    }
};

pub const KeyEventKind = enum(i32) { key_down = 0, key_up = 1, system_key_down = 2, system_key_up = 3, _ };

/// ICoreWebView2AcceleratorKeyPressedEventArgs.
pub const IAcceleratorKeyPressedEventArgs = extern struct {
    vtable: com.VTable,

    pub fn getKeyEventKind(self: *IAcceleratorKeyPressedEventArgs, out: *KeyEventKind) HRESULT {
        return com.call(self, 3, fn (*KeyEventKind) HRESULT, .{out});
    }

    pub fn getVirtualKey(self: *IAcceleratorKeyPressedEventArgs, out: *u32) HRESULT {
        return com.call(self, 4, fn (*u32) HRESULT, .{out});
    }

    pub fn getKeyEventLParam(self: *IAcceleratorKeyPressedEventArgs, out: *i32) HRESULT {
        return com.call(self, 5, fn (*i32) HRESULT, .{out});
    }

    /// The page doesn't get the key.
    pub fn putHandled(self: *IAcceleratorKeyPressedEventArgs, handled: bool) HRESULT {
        return com.call(self, 8, fn (BOOL) HRESULT, .{@as(BOOL, @intFromBool(handled))});
    }
};

/// The window message a key event stands for.
pub fn keyMessage(kind: KeyEventKind) ?u32 {
    return switch (kind) {
        .key_down => win32.WM_KEYDOWN,
        .key_up => win32.WM_KEYUP,
        .system_key_down => win32.WM_SYSKEYDOWN,
        .system_key_up => win32.WM_SYSKEYUP,
        _ => null,
    };
}

test guid {
    const g = guid("b96d755e-0319-4e92-a296-23436f46a1fc");
    try std.testing.expectEqual(@as(u32, 0xb96d755e), g.data1);
    try std.testing.expectEqual(@as(u16, 0x0319), g.data2);
    try std.testing.expectEqual(@as(u16, 0x4e92), g.data3);
    try std.testing.expectEqualSlices(u8, &.{ 0xa2, 0x96, 0x23, 0x43, 0x6f, 0x46, 0xa1, 0xfc }, &g.data4);
}

test "handlers are IUnknown and Invoke" {
    try std.testing.expectEqual(4 * @sizeOf(usize), @sizeOf(EnvironmentCompletedHandler.VTable));
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(FocusChangedEventHandler));
    try std.testing.expectEqual(@as(usize, 3), @offsetOf(MoveFocusRequestedEventHandler.VTable, "Invoke") / @sizeOf(usize));
}

test "mouse kinds are the window messages" {
    try std.testing.expectEqual(@as(i32, win32.WM_MOUSEMOVE), @intFromEnum(MouseEventKind.move));
    try std.testing.expectEqual(@as(i32, win32.WM_MOUSEHWHEEL), @intFromEnum(MouseEventKind.horizontal_wheel));
    try std.testing.expectEqual(@as(i32, win32.WM_XBUTTONDBLCLK), @intFromEnum(MouseEventKind.x_double_click));
    try std.testing.expectEqual(@as(i32, win32.WM_MOUSELEAVE), @intFromEnum(MouseEventKind.leave));
    try std.testing.expectEqual(@as(?u32, win32.WM_SYSKEYUP), keyMessage(.system_key_up));
}
