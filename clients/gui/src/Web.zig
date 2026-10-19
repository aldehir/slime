//! The browsers in browser panes: WebView2, hosted in visual mode. Each
//! placed browser pane gets a `View`, a WebView whose output goes into a
//! visual we hang under the pane's container visual (`D3D11.
//! setPaneVisual`), sized to the pane's page and faded with it; the
//! window forwards the mouse to it, and its keys go to it directly, but
//! for the app's bindings, which it hands back (`Events.key`).
//!
//! WebView2Loader.dll, beside the exe, is loaded on the first browser
//! pane placed; with it or the runtime missing, browser panes stand in
//! with the reason. Views share an environment (a browser process group
//! and a user data folder) per host they browse from, keyed by host id
//! with 0 for local; only local has one yet. Everything here runs on the
//! UI thread, which is a COM single-threaded apartment (main.zig), and
//! WebView2 calls back on it from the message loop.
//!
//! A view lives as long as its pane is in the window: shown while it's
//! placed in the active tab, hidden in another tab or behind a zoom, and
//! closed when its session goes (`detach`), its pane ends, or its browser
//! fails. A failed view leaves the pane's stand-in saying why
//! (`Session.Browser.failed`), and a click there makes a new one.

const Web = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32/win32.zig");
const com = win32.com;
const dcomp = win32.dcomp;
const wv = win32.webview2;
const Session = @import("Session.zig");
const Renderer = @import("renderer/D3D11.zig");
const Daemon = @import("Daemon.zig");

const log = std.log.scoped(.web);

const L = std.unicode.utf8ToUtf16LeStringLiteral;

/// Why a browser pane has no browser.
pub const runtime_missing = "WebView2 runtime not found";
pub const loader_missing = "WebView2Loader.dll is missing beside slime-gui.exe";
const start_failed = "The browser couldn't start. Click to try again.";
const browser_exited = "The browser closed. Click to reload.";
const page_crashed = "The page crashed. Click to reload.";
const page_hung = "The page stopped responding. Click to reload.";

alloc: Allocator,
/// The window, which parents every WebView and takes their input.
hwnd: win32.HWND,
events: Events,
/// The window's renderer, whose composition tree the views hang in. Set
/// once it's made, before anything is placed.
renderer: ?*Renderer = null,
loader: Loader = .unloaded,
/// One per host browsed from, made with the first view on it.
envs: std.ArrayList(*Env) = .empty,
/// Every open view.
views: std.ArrayList(*View) = .empty,
/// The window's DPI over 96, as pages are rasterized.
scale: f64 = 1,

/// What views tell the window. Each runs on the UI thread, from the
/// message loop.
pub const Events = struct {
    ctx: *anyopaque,
    /// A pane's page, title, history, loading, or failure changed: draw
    /// again.
    changed: *const fn (*anyopaque, *Session) void,
    /// A pane's WebView got (true) or lost the keyboard on its own.
    focus: *const fn (*anyopaque, *Session, bool) void,
    /// Tab (true) or shift+tab out of a pane's page.
    tab_out: *const fn (*anyopaque, *Session, bool) void,
    /// A key a page was about to get (a WM_(SYS)KEYDOWN/UP and its
    /// virtual key): returns true if one of the app's bindings took it.
    key: *const fn (*anyopaque, u32, u32) bool,
    /// A page's cursor changed.
    cursor: *const fn (*anyopaque) void,
};

const Loader = union(enum) {
    unloaded,
    /// No loader, or no runtime: logged once, with what the pane says.
    missing: []const u8,
    loaded: wv.CreateEnvironmentWithOptions,
};

pub fn init(alloc: Allocator, hwnd: win32.HWND, events: Events, dpi: u32) Web {
    return .{ .alloc = alloc, .hwnd = hwnd, .events = events, .scale = scaleOf(dpi) };
}

/// After every session is gone, which detached their views.
pub fn deinit(self: *Web) void {
    while (self.views.items.len > 0) self.views.items[0].shut();
    self.views.deinit(self.alloc);
    for (self.envs.items) |e| e.destroy();
    self.envs.deinit(self.alloc);
}

fn scaleOf(dpi: u32) f64 {
    return @as(f64, @floatFromInt(dpi)) / win32.USER_DEFAULT_SCREEN_DPI;
}

/// Load WebView2Loader.dll from beside the exe and ask it for the
/// runtime, once. Null if either is missing.
fn load(self: *Web) ?wv.CreateEnvironmentWithOptions {
    switch (self.loader) {
        .loaded => |f| return f,
        .missing => return null,
        .unloaded => {},
    }
    self.loader = .{ .missing = loader_missing };
    const dll = win32.LoadLibraryExW(L("WebView2Loader.dll"), null, win32.LOAD_LIBRARY_SEARCH_APPLICATION_DIR) orelse {
        log.warn("no WebView2Loader.dll beside the exe: GetLastError={d}", .{win32.GetLastError()});
        return null;
    };
    self.loader = .{ .missing = runtime_missing };
    const version_fn: wv.GetAvailableBrowserVersionString = @ptrCast(win32.GetProcAddress(dll, "GetAvailableCoreWebView2BrowserVersionString") orelse {
        log.warn("WebView2Loader.dll has no GetAvailableCoreWebView2BrowserVersionString", .{});
        return null;
    });
    const create: wv.CreateEnvironmentWithOptions = @ptrCast(win32.GetProcAddress(dll, "CreateCoreWebView2EnvironmentWithOptions") orelse {
        log.warn("WebView2Loader.dll has no CreateCoreWebView2EnvironmentWithOptions", .{});
        return null;
    });
    var version: ?win32.LPWSTR = null;
    const hr = version_fn(null, &version);
    const v = version orelse {
        log.warn("no WebView2 runtime: HRESULT=0x{X:0>8}", .{@as(u32, @bitCast(hr))});
        return null;
    };
    log.info("WebView2 runtime {f}", .{std.unicode.fmtUtf16Le(std.mem.span(v))});
    win32.CoTaskMemFree(v);
    self.loader = .{ .loaded = create };
    return create;
}

/// The browser processes for one host's panes: one user data folder,
/// made when its first view wants it. Lives as long as the window.
const Env = struct {
    web: *Web,
    host: u32,
    state: union(enum) {
        creating,
        ready: *wv.IEnvironment,
        failed,
    } = .creating,
    /// Views waiting for it, each holding a reference.
    waiting: std.ArrayList(*View) = .empty,
    completed: Callback(wv.EnvironmentCompletedHandler, Env, "completed", envCreated) = .{},

    fn destroy(self: *Env) void {
        switch (self.state) {
            .ready => |e| com.release(e),
            .creating, .failed => {},
        }
        for (self.waiting.items) |v| _ = v.release();
        self.waiting.deinit(self.web.alloc);
        self.web.alloc.destroy(self);
    }

    // Lives as long as the window: WebView2's references are no-ops.
    fn retain(_: *Env) u32 {
        return 1;
    }
    fn release(_: *Env) u32 {
        return 1;
    }
};

/// The environment for host `host` (0 for local), made if it isn't.
fn env(self: *Web, host: u32) !*Env {
    for (self.envs.items) |e| if (e.host == host) return e;
    const create = self.load() orelse return error.RuntimeMissing;
    var folder: [512]u16 = undefined;
    const path = try userDataFolder(&folder, host);
    try self.envs.ensureUnusedCapacity(self.alloc, 1);
    const e = try self.alloc.create(Env);
    e.* = .{ .web = self, .host = host };
    try com.check(createEnvironment(create, path, null, &e.completed.iface), "CreateCoreWebView2EnvironmentWithOptions");
    self.envs.appendAssumeCapacity(e);
    return e;
}

/// Where a host's browser keeps its profile: %LOCALAPPDATA%\slime\webview
/// \local for local (local-<instance> under SLIME_INSTANCE, so a test
/// window doesn't share a running browser's).
fn userDataFolder(buf: *[512]u16, host: u32) ![:0]const u16 {
    // Hosts come with stage 5.
    std.debug.assert(host == 0);
    const n = win32.GetEnvironmentVariableW(L("LOCALAPPDATA"), buf, buf.len);
    if (n == 0 or n >= buf.len) return error.NoAppData;
    var len: usize = n;
    const put = struct {
        fn f(b: *[512]u16, at: *usize, s: []const u16) !void {
            if (at.* + s.len >= b.len) return error.NameTooLong;
            @memcpy(b[at.*..][0..s.len], s);
            at.* += s.len;
        }
    }.f;
    try put(buf, &len, L("\\slime\\webview\\local"));
    var inst: [64]u16 = undefined;
    if (Daemon.instance(&inst)) |name| {
        try put(buf, &len, L("-"));
        try put(buf, &len, name);
    }
    buf[len] = 0;
    return buf[0..len :0];
}

/// Make an environment: its browser process starts with its first
/// WebView. `options` (null for the defaults) will carry a host's proxy
/// arguments.
fn createEnvironment(create: wv.CreateEnvironmentWithOptions, folder: [:0]const u16, options: ?*anyopaque, done: *wv.EnvironmentCompletedHandler) win32.HRESULT {
    return create(null, folder.ptr, options, done);
}

fn envCreated(e: *Env, hr: win32.HRESULT, result: ?*wv.IEnvironment) win32.HRESULT {
    const waiting = e.waiting;
    e.waiting = .empty;
    defer {
        for (waiting.items) |v| _ = v.release();
        var list = waiting;
        list.deinit(e.web.alloc);
    }
    const environment = result orelse {
        log.err("making the browser environment failed: HRESULT=0x{X:0>8}", .{@as(u32, @bitCast(hr))});
        e.state = .failed;
        for (waiting.items) |v| v.fail(start_failed);
        return com.S_OK;
    };
    _ = com.call(environment, 1, fn () u32, .{});
    e.state = .{ .ready = environment };
    for (waiting.items) |v| v.create();
    return com.S_OK;
}

/// A COM object WebView2 calls back, embedded in `Outer` as `field`:
/// `invoke` gets the outer struct, and references count on it.
fn Callback(
    comptime H: type,
    comptime Outer: type,
    comptime field: []const u8,
    comptime invoke: fn (*Outer, H.A, H.B) win32.HRESULT,
) type {
    return struct {
        iface: H = .{ .vtable = &vtable },

        const Self = @This();
        const vtable: H.VTable = .{
            .QueryInterface = queryInterface,
            .AddRef = addRef,
            .Release = release,
            .Invoke = call,
        };

        fn outer(iface: *H) *Outer {
            const self: *Self = @fieldParentPtr("iface", iface);
            return @fieldParentPtr(field, self);
        }

        fn queryInterface(iface: *H, iid: *const win32.GUID, out: *?*anyopaque) callconv(.winapi) win32.HRESULT {
            if (com.guidEql(iid, &com.IID_IUnknown) or com.guidEql(iid, &H.iid)) {
                _ = outer(iface).retain();
                out.* = iface;
                return com.S_OK;
            }
            out.* = null;
            return com.E_NOINTERFACE;
        }

        fn addRef(iface: *H) callconv(.winapi) u32 {
            return outer(iface).retain();
        }

        fn release(iface: *H) callconv(.winapi) u32 {
            return outer(iface).release();
        }

        fn call(iface: *H, a: H.A, b: H.B) callconv(.winapi) win32.HRESULT {
            return invoke(outer(iface), a, b);
        }
    };
}

/// A browser pane's WebView. Counted: its session holds one reference
/// while it's attached, and WebView2 one for each handler it keeps.
pub const View = struct {
    web: *Web,
    /// The pane, until it goes (`detach`) or the view is shut.
    session: ?*Session,
    /// The renderer's key for the pane's container visual.
    key: u64,
    refs: u32 = 1,
    state: enum { waiting, creating, ready, closed } = .waiting,
    comp: ?*wv.ICompositionController = null,
    controller: ?*wv.IController = null,
    webview: ?*wv.IWebView = null,
    /// The WebView's root visual target, ours.
    visual: ?*dcomp.IVisual = null,
    /// The pane's container, the renderer's, while it's placed.
    container: ?*dcomp.IVisual = null,
    bounds: win32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    shown: bool = false,
    /// The WebView has the keyboard, as its GotFocus and LostFocus say.
    focused: bool = false,
    /// MoveFocus was called and no focus event has come since.
    focus_asked: bool = false,
    /// `show` placed it this frame.
    placed_mark: bool = false,

    created: Callback(wv.CompositionControllerCompletedHandler, View, "created", controllerCreated) = .{},
    navigation_starting: Callback(wv.NavigationStartingEventHandler, View, "navigation_starting", navigationStarting) = .{},
    navigation_completed: Callback(wv.NavigationCompletedEventHandler, View, "navigation_completed", navigationCompleted) = .{},
    source_changed: Callback(wv.SourceChangedEventHandler, View, "source_changed", sourceChanged) = .{},
    history_changed: Callback(wv.HistoryChangedEventHandler, View, "history_changed", historyChanged) = .{},
    title_changed: Callback(wv.DocumentTitleChangedEventHandler, View, "title_changed", titleChanged) = .{},
    new_window: Callback(wv.NewWindowRequestedEventHandler, View, "new_window", newWindow) = .{},
    process_failed: Callback(wv.ProcessFailedEventHandler, View, "process_failed", processFailed) = .{},
    cursor_changed: Callback(wv.CursorChangedEventHandler, View, "cursor_changed", cursorChanged) = .{},
    got_focus: Callback(wv.FocusChangedEventHandler, View, "got_focus", gotFocus) = .{},
    lost_focus: Callback(wv.FocusChangedEventHandler, View, "lost_focus", lostFocus) = .{},
    move_focus: Callback(wv.MoveFocusRequestedEventHandler, View, "move_focus", moveFocusRequested) = .{},
    accelerator: Callback(wv.AcceleratorKeyPressedEventHandler, View, "accelerator", acceleratorKey) = .{},

    fn retain(self: *View) u32 {
        self.refs += 1;
        return self.refs;
    }

    fn release(self: *View) u32 {
        self.refs -= 1;
        const left = self.refs;
        if (left == 0) self.web.alloc.destroy(self);
        return left;
    }

    fn browser(self: *View) ?*Session.Browser {
        const s = self.session orelse return null;
        return s.browser();
    }

    /// Make the WebView, now that the environment is ready.
    fn create(self: *View) void {
        if (self.state != .waiting) return;
        const e = self.web.readyEnv(0) orelse return self.fail(start_failed);
        const env3 = com.query(e, wv.IEnvironment3) orelse {
            log.err("the WebView2 runtime is too old: no ICoreWebView2Environment3", .{});
            return self.fail(start_failed);
        };
        defer com.release(env3);
        self.state = .creating;
        _ = self.retain();
        com.check(env3.createCompositionController(self.web.hwnd, &self.created.iface), "ICoreWebView2Environment3::CreateCoreWebView2CompositionController") catch {
            _ = self.release();
            return self.fail(start_failed);
        };
    }

    /// The pane went: let the WebView go. Its session is being destroyed.
    pub fn detach(self: *View) void {
        self.session = null;
        self.shut();
    }

    /// End the WebView and take the view out of the window, leaving the
    /// pane's stand-in, and drop the session's reference.
    fn shut(self: *View) void {
        if (self.state == .closed) return;
        self.state = .closed;
        if (self.browser()) |b| b.view = null;
        self.session = null;
        const web = self.web;
        for (web.views.items, 0..) |v, i| if (v == self) {
            _ = web.views.swapRemove(i);
            break;
        };
        self.unplace();
        if (self.controller) |c| _ = c.close();
        com.releaseOpt(&self.webview);
        com.releaseOpt(&self.controller);
        com.releaseOpt(&self.comp);
        com.releaseOpt(&self.visual);
        if (web.renderer) |r| r.commit() catch {};
        _ = self.release();
    }

    /// Shut the view, its pane standing in saying `why`.
    fn fail(self: *View, why: []const u8) void {
        const s = self.session;
        if (self.browser()) |b| {
            b.failed = why;
            b.loading = false;
        }
        self.shut();
        if (s) |session| self.web.events.changed(self.web.events.ctx, session);
    }

    /// Take the view's visual out of the tree.
    fn unplace(self: *View) void {
        const r = self.web.renderer orelse return;
        if (self.container) |c| {
            if (self.visual) |v| _ = c.removeVisual(v);
            r.removePaneVisual(self.key);
            self.container = null;
        }
    }

    /// Show the view over `p`, as the pane's page, `opacity` faded.
    fn place(self: *View, r: *Renderer, p: Place) void {
        const container = r.setPaneVisual(self.key, .{
            .rect = .{
                .x = @floatFromInt(p.bounds.left),
                .y = @floatFromInt(p.bounds.top),
                .w = @floatFromInt(p.bounds.right - p.bounds.left),
                .h = @floatFromInt(p.bounds.bottom - p.bounds.top),
            },
            .radius = p.radius,
            .opacity = p.opacity,
        }) catch return;
        if (self.container != container) {
            self.container = container;
            if (self.visual) |v| com.check(container.addVisual(v, true, null), "IDCompositionVisual::AddVisual") catch {};
        }
        if (self.state == .ready) {
            if (!self.shown or !std.meta.eql(self.bounds, p.bounds)) _ = self.controller.?.putBounds(p.bounds);
            if (!self.shown) _ = self.controller.?.putIsVisible(true);
        }
        self.bounds = p.bounds;
        self.shown = true;
    }

    /// Out of sight, kept: another tab is shown, or another pane zoomed.
    fn hide(self: *View) void {
        self.unplace();
        if (self.shown and self.state == .ready) _ = self.controller.?.putIsVisible(false);
        self.shown = false;
    }
};

/// The page of a pane whose content is `rect`, under its strip: inside
/// its border at the sides and bottom, on whole pixels.
pub fn pageBounds(rect: Renderer.Painter.Rect, border: f32) win32.RECT {
    return .{
        .left = @intFromFloat(@ceil(rect.x + border)),
        .top = @intFromFloat(@round(rect.y)),
        .right = @intFromFloat(@floor(rect.x + rect.w - border)),
        .bottom = @intFromFloat(@floor(rect.y + rect.h - border)),
    };
}

test pageBounds {
    const b = pageBounds(.{ .x = 10.5, .y = 40, .w = 400, .h = 300 }, 1);
    try std.testing.expectEqual(win32.RECT{ .left = 12, .top = 40, .right = 409, .bottom = 339 }, b);
}

/// Where a placed view shows.
pub const Place = struct {
    /// The page, in client pixels: what the WebView's bounds are, and
    /// where its visual goes.
    bounds: win32.RECT,
    /// The pane's bottom corners.
    radius: f32,
    opacity: f32 = 1,
};

/// Host `host`'s environment, once it's made.
fn readyEnv(self: *Web, host: u32) ?*wv.IEnvironment {
    for (self.envs.items) |e| if (e.host == host) return switch (e.state) {
        .ready => |environment| environment,
        else => null,
    };
    return null;
}

fn controllerCreated(self: *View, hr: win32.HRESULT, result: ?*wv.ICompositionController) win32.HRESULT {
    defer _ = self.release();
    if (self.state != .creating) {
        // Shut while it was being made.
        if (result) |comp| if (com.query(comp, wv.IController)) |c| {
            _ = c.close();
            com.release(c);
        };
        return com.S_OK;
    }
    const comp = result orelse {
        log.err("making a WebView failed: HRESULT=0x{X:0>8}", .{@as(u32, @bitCast(hr))});
        self.fail(start_failed);
        return com.S_OK;
    };
    setUp(self, comp) catch {
        if (com.query(comp, wv.IController)) |c| {
            _ = c.close();
            com.release(c);
        }
        self.fail(start_failed);
        return com.S_OK;
    };
    return com.S_OK;
}

/// Take the new WebView: its visual, scale, and events, then the pane's
/// page.
fn setUp(self: *View, comp: *wv.ICompositionController) !void {
    const web = self.web;
    const r = web.renderer orelse return error.NoRenderer;
    const controller = com.query(comp, wv.IController) orelse return error.NoController;
    _ = com.call(comp, 1, fn () u32, .{});
    self.comp = comp;
    self.controller = controller;
    var webview: ?*wv.IWebView = null;
    try com.check(controller.getCoreWebView2(&webview), "ICoreWebView2Controller::get_CoreWebView2");
    self.webview = webview.?;
    const w = webview.?;

    var visual: ?*dcomp.IVisual = null;
    try com.check(r.comp.device.createVisual(&visual), "IDCompositionDevice2::CreateVisual");
    self.visual = visual.?;
    try com.check(comp.putRootVisualTarget(visual.?), "ICoreWebView2CompositionController::put_RootVisualTarget");
    if (com.query(controller, wv.IController3)) |c3| {
        defer com.release(c3);
        _ = c3.putBoundsMode(.raw_pixels);
        _ = c3.putShouldDetectMonitorScaleChanges(false);
        _ = c3.putRasterizationScale(web.scale);
    }

    var token: wv.EventRegistrationToken = .{};
    try com.check(w.addNavigationStarting(&self.navigation_starting.iface, &token), "add_NavigationStarting");
    try com.check(w.addNavigationCompleted(&self.navigation_completed.iface, &token), "add_NavigationCompleted");
    try com.check(w.addSourceChanged(&self.source_changed.iface, &token), "add_SourceChanged");
    try com.check(w.addHistoryChanged(&self.history_changed.iface, &token), "add_HistoryChanged");
    try com.check(w.addDocumentTitleChanged(&self.title_changed.iface, &token), "add_DocumentTitleChanged");
    try com.check(w.addNewWindowRequested(&self.new_window.iface, &token), "add_NewWindowRequested");
    try com.check(w.addProcessFailed(&self.process_failed.iface, &token), "add_ProcessFailed");
    try com.check(comp.addCursorChanged(&self.cursor_changed.iface, &token), "add_CursorChanged");
    try com.check(controller.addGotFocus(&self.got_focus.iface, &token), "add_GotFocus");
    try com.check(controller.addLostFocus(&self.lost_focus.iface, &token), "add_LostFocus");
    try com.check(controller.addMoveFocusRequested(&self.move_focus.iface, &token), "add_MoveFocusRequested");
    try com.check(controller.addAcceleratorKeyPressed(&self.accelerator.iface, &token), "add_AcceleratorKeyPressed");

    self.state = .ready;
    // Placed while it was made: show it there.
    if (self.container) |c| try com.check(c.addVisual(visual.?, true, null), "IDCompositionVisual::AddVisual");
    _ = controller.putBounds(self.bounds);
    _ = controller.putIsVisible(self.shown);
    try r.commit();
    if (self.browser()) |b| navigate(self, b.url);
    if (self.session) |s| web.events.changed(web.events.ctx, s);
}

/// Go to `url`.
fn navigate(self: *View, url: []const u16) void {
    const w = self.webview orelse return;
    const z = self.web.alloc.dupeZ(u16, url) catch return;
    defer self.web.alloc.free(z);
    log.debug("pane {d} goes to {f}", .{ self.key, std.unicode.fmtUtf16Le(url) });
    com.check(w.navigate(z), "ICoreWebView2::Navigate") catch
        log.warn("can't go to {f}", .{std.unicode.fmtUtf16Le(url)});
}

/// The WebView's url and title as the daemon hears them, and the pane
/// shows them.
fn reportVisit(self: *View) void {
    const s = self.session orelse return;
    const w = self.webview orelse return;
    var source: ?win32.LPWSTR = null;
    if (w.getSource(&source) < 0) return;
    defer win32.CoTaskMemFree(source);
    var title: ?win32.LPWSTR = null;
    _ = w.getDocumentTitle(&title);
    defer win32.CoTaskMemFree(title);
    var url: []const u16 = if (source) |src| std.mem.span(src) else &.{};
    // A data: url's source is empty: it's where it was sent.
    if (url.len == 0) url = (s.browser() orelse return).url;
    s.visited(url, if (title) |t| std.mem.span(t) else &.{});
    self.web.events.changed(self.web.events.ctx, s);
}

fn navigationStarting(self: *View, _: *wv.IWebView, _: *wv.IUnknown) win32.HRESULT {
    const b = self.browser() orelse return com.S_OK;
    b.loading = true;
    self.web.events.changed(self.web.events.ctx, self.session.?);
    return com.S_OK;
}

fn navigationCompleted(self: *View, _: *wv.IWebView, _: *wv.IUnknown) win32.HRESULT {
    const b = self.browser() orelse return com.S_OK;
    b.loading = false;
    self.web.events.changed(self.web.events.ctx, self.session.?);
    return com.S_OK;
}

fn sourceChanged(self: *View, _: *wv.IWebView, _: *wv.IUnknown) win32.HRESULT {
    reportVisit(self);
    return com.S_OK;
}

fn titleChanged(self: *View, _: *wv.IWebView, _: ?*wv.IUnknown) win32.HRESULT {
    reportVisit(self);
    return com.S_OK;
}

fn historyChanged(self: *View, w: *wv.IWebView, _: ?*wv.IUnknown) win32.HRESULT {
    const b = self.browser() orelse return com.S_OK;
    var back: win32.BOOL = 0;
    var forward: win32.BOOL = 0;
    _ = w.getCanGoBack(&back);
    _ = w.getCanGoForward(&forward);
    b.can_go_back = back != 0;
    b.can_go_forward = forward != 0;
    self.web.events.changed(self.web.events.ctx, self.session.?);
    return com.S_OK;
}

/// A page opening a window opens it here instead.
fn newWindow(self: *View, _: *wv.IWebView, args: *wv.INewWindowRequestedEventArgs) win32.HRESULT {
    _ = args.putHandled(true);
    var uri: ?win32.LPWSTR = null;
    if (args.getUri(&uri) < 0) return com.S_OK;
    defer win32.CoTaskMemFree(uri);
    if (uri) |u| navigate(self, std.mem.span(u));
    return com.S_OK;
}

fn processFailed(self: *View, _: *wv.IWebView, args: *wv.IProcessFailedEventArgs) win32.HRESULT {
    var kind: wv.ProcessFailedKind = undefined;
    if (args.getProcessFailedKind(&kind) < 0) return com.S_OK;
    const why = switch (kind) {
        .browser_process_exited => browser_exited,
        .render_process_exited => page_crashed,
        .render_process_unresponsive => page_hung,
        // A frame's, a helper's, the GPU's: the browser carries on.
        _ => return com.S_OK,
    };
    log.warn("browser for pane {d}: {s}", .{ self.key, why });
    self.fail(why);
    return com.S_OK;
}

fn cursorChanged(self: *View, comp: *wv.ICompositionController, _: ?*wv.IUnknown) win32.HRESULT {
    const b = self.browser() orelse return com.S_OK;
    var cursor: ?win32.HCURSOR = null;
    if (comp.getCursor(&cursor) < 0) return com.S_OK;
    // Copied: the WebView's may go with the next.
    const copy = if (cursor) |c| win32.CopyIcon(c) else null;
    if (b.cursor) |old| _ = win32.DestroyIcon(old);
    b.cursor = copy;
    self.web.events.cursor(self.web.events.ctx);
    return com.S_OK;
}

fn gotFocus(self: *View, _: *wv.IController, _: ?*wv.IUnknown) win32.HRESULT {
    log.debug("pane {d}'s page has the keyboard", .{self.key});
    self.focused = true;
    self.focus_asked = false;
    if (self.session) |s| self.web.events.focus(self.web.events.ctx, s, true);
    return com.S_OK;
}

fn lostFocus(self: *View, _: *wv.IController, _: ?*wv.IUnknown) win32.HRESULT {
    log.debug("pane {d}'s page lost the keyboard", .{self.key});
    self.focused = false;
    self.focus_asked = false;
    if (self.session) |s| self.web.events.focus(self.web.events.ctx, s, false);
    return com.S_OK;
}

fn moveFocusRequested(self: *View, _: *wv.IController, args: *wv.IMoveFocusRequestedEventArgs) win32.HRESULT {
    var reason: wv.MoveFocusReason = .programmatic;
    _ = args.getReason(&reason);
    if (reason == .programmatic) return com.S_OK;
    _ = args.putHandled(true);
    if (self.session) |s| self.web.events.tab_out(self.web.events.ctx, s, reason == .next);
    return com.S_OK;
}

fn acceleratorKey(self: *View, _: *wv.IController, args: *wv.IAcceleratorKeyPressedEventArgs) win32.HRESULT {
    var kind: wv.KeyEventKind = undefined;
    var vk: u32 = 0;
    if (args.getKeyEventKind(&kind) < 0 or args.getVirtualKey(&vk) < 0) return com.S_OK;
    const msg = wv.keyMessage(kind) orelse return com.S_OK;
    if (self.web.events.key(self.web.events.ctx, msg, vk)) _ = args.putHandled(true);
    return com.S_OK;
}

/// Begin placing the frame's views: those `show` doesn't place by
/// `endPlacing` are hidden.
pub fn beginPlacing(self: *Web) void {
    for (self.views.items) |v| v.placed_mark = false;
}

/// Show browser pane `s`'s page at `p`, making its WebView if it has
/// none. A pane that ended, or whose browser failed, keeps its stand-in.
pub fn show(self: *Web, s: *Session, p: Place) void {
    const b = s.browser() orelse return;
    if (s.ended or b.failed != null) {
        if (b.view) |v| v.shut();
        return;
    }
    const r = self.renderer orelse return;
    const v = b.view orelse self.open(s) orelse return;
    v.placed_mark = true;
    v.place(r, p);
}

/// Hide the views not shown since `beginPlacing`, and close those whose
/// pane ended.
pub fn endPlacing(self: *Web) void {
    var i: usize = self.views.items.len;
    while (i > 0) {
        i -= 1;
        const v = self.views.items[i];
        if (v.placed_mark) continue;
        if (v.session) |s| if (s.ended) {
            v.shut();
            continue;
        };
        v.hide();
    }
}

/// A view for browser pane `s`, waiting on its environment. Null, with
/// the pane saying why, if there's no browser to make one with.
fn open(self: *Web, s: *Session) ?*View {
    const b = s.browser() orelse return null;
    const e = self.env(0) catch |err| {
        b.failed = if (err == error.RuntimeMissing) self.loader.missing else start_failed;
        self.events.changed(self.events.ctx, s);
        return null;
    };
    if (e.state == .failed) {
        b.failed = start_failed;
        return null;
    }
    self.views.ensureUnusedCapacity(self.alloc, 1) catch return null;
    e.waiting.ensureUnusedCapacity(self.alloc, 1) catch return null;
    const v = self.alloc.create(View) catch return null;
    v.* = .{ .web = self, .session = s, .key = s.id };
    self.views.appendAssumeCapacity(v);
    b.view = v;
    b.failed = null;
    switch (e.state) {
        .ready => v.create(),
        .creating => {
            _ = v.retain();
            e.waiting.appendAssumeCapacity(v);
        },
        .failed => unreachable,
    }
    return b.view;
}

/// The pane's url changed in slime (pane.url, or the URL bar's echo):
/// go there, unless the page is there already (our own report coming
/// back).
pub fn follow(self: *Web, s: *Session) void {
    _ = self;
    const b = s.browser() orelse return;
    const v = b.view orelse return;
    const w = v.webview orelse return;
    var source: ?win32.LPWSTR = null;
    _ = w.getSource(&source);
    defer win32.CoTaskMemFree(source);
    if (!shouldNavigate(if (source) |src| std.mem.span(src) else null, b.url)) return;
    navigate(v, b.url);
}

/// Whether a page at `source` should go to `url`.
pub fn shouldNavigate(source: ?[]const u16, url: []const u16) bool {
    if (url.len == 0) return false;
    const at = source orelse return true;
    return !std.mem.eql(u16, at, url);
}

pub const Nav = @import("App.zig").Nav;

/// A history button.
pub fn go(self: *Web, s: *Session, nav: Nav) void {
    _ = self;
    const b = s.browser() orelse return;
    const w = (b.view orelse return).webview orelse return;
    _ = switch (nav) {
        .back => w.goBack(),
        .forward => w.goForward(),
        .reload => w.reload(),
        .stop => w.stop(),
    };
}

/// A client area mouse message (or WM_MOUSELEAVE) for pane `s`'s page,
/// at client position `pos`.
pub fn mouse(self: *Web, s: *Session, msg: u32, wparam: win32.WPARAM, pos: win32.POINT) void {
    _ = self;
    const b = s.browser() orelse return;
    const v = b.view orelse return;
    if (v.state != .ready) return;
    const in = mouseInput(msg, wparam, pos, v.bounds) orelse return;
    _ = v.comp.?.sendMouseInput(in.kind, in.keys, in.data, in.point);
}

/// What `sendMouseInput` takes for a mouse message.
pub const MouseInput = struct {
    kind: wv.MouseEventKind,
    keys: u32,
    data: u32,
    /// Relative to the WebView's bounds.
    point: win32.POINT,
};

pub fn mouseInput(msg: u32, wparam: win32.WPARAM, pos: win32.POINT, bounds: win32.RECT) ?MouseInput {
    const kind: wv.MouseEventKind = switch (msg) {
        win32.WM_MOUSEMOVE...win32.WM_MOUSEHWHEEL, win32.WM_MOUSELEAVE => @enumFromInt(msg),
        else => return null,
    };
    if (kind == .leave) return .{ .kind = kind, .keys = 0, .data = 0, .point = .{ .x = 0, .y = 0 } };
    const data: u32 = switch (kind) {
        // The delta, signed, as GET_WHEEL_DELTA_WPARAM gives it.
        .wheel, .horizontal_wheel => @bitCast(@as(i32, @as(i16, @bitCast(win32.hiword(wparam))))),
        .x_down, .x_up, .x_double_click => win32.hiword(wparam),
        else => 0,
    };
    return .{
        .kind = kind,
        .keys = win32.loword(wparam),
        .data = data,
        .point = .{ .x = pos.x - bounds.left, .y = pos.y - bounds.top },
    };
}

/// Give pane `s`'s page the keyboard, unless it has it or was asked.
/// `on_window` says the window itself has the focus, which the page then
/// doesn't, whatever it last said.
pub fn focus(self: *Web, s: *Session, on_window: bool) void {
    _ = self;
    const b = s.browser() orelse return;
    const v = b.view orelse return;
    if (on_window) v.focused = false;
    if (v.state != .ready or v.focused or (v.focus_asked and !on_window)) return;
    v.focus_asked = true;
    com.check(v.controller.?.moveFocus(.programmatic), "ICoreWebView2Controller::MoveFocus") catch {
        v.focus_asked = false;
    };
}

/// Forget asking for the focus: the keyboard is someone else's now.
pub fn dropFocusAsks(self: *Web) void {
    for (self.views.items) |v| v.focus_asked = false;
}

/// The window moved to a display of another DPI.
pub fn setDpi(self: *Web, dpi: u32) void {
    self.scale = scaleOf(dpi);
    for (self.views.items) |v| {
        if (v.state != .ready) continue;
        const c3 = com.query(v.controller.?, wv.IController3) orelse continue;
        defer com.release(c3);
        _ = c3.putRasterizationScale(self.scale);
    }
}

test mouseInput {
    const bounds: win32.RECT = .{ .left = 100, .top = 40, .right = 500, .bottom = 400 };
    const click = mouseInput(win32.WM_LBUTTONDOWN, win32.MK_LBUTTON | win32.MK_SHIFT, .{ .x = 130, .y = 45 }, bounds).?;
    try std.testing.expectEqual(wv.MouseEventKind.left_down, click.kind);
    try std.testing.expectEqual(@as(u32, win32.MK_LBUTTON | win32.MK_SHIFT), click.keys);
    try std.testing.expectEqual(win32.POINT{ .x = 30, .y = 5 }, click.point);
    // Above and left of the page, while the mouse is held.
    const drag = mouseInput(win32.WM_MOUSEMOVE, win32.MK_LBUTTON, .{ .x = 90, .y = 10 }, bounds).?;
    try std.testing.expectEqual(win32.POINT{ .x = -10, .y = -30 }, drag.point);
    // A notch down, the delta sign-extended.
    const wheel = mouseInput(win32.WM_MOUSEWHEEL, @as(usize, @as(u16, @bitCast(@as(i16, -120)))) << 16, .{ .x = 100, .y = 40 }, bounds).?;
    try std.testing.expectEqual(@as(u32, @bitCast(@as(i32, -120))), wheel.data);
    const back = mouseInput(win32.WM_XBUTTONUP, @as(usize, win32.XBUTTON1) << 16, .{ .x = 101, .y = 41 }, bounds).?;
    try std.testing.expectEqual(wv.MouseEventKind.x_up, back.kind);
    try std.testing.expectEqual(@as(u32, win32.XBUTTON1), back.data);
    try std.testing.expectEqual(wv.MouseEventKind.leave, mouseInput(win32.WM_MOUSELEAVE, 0, .{ .x = 0, .y = 0 }, bounds).?.kind);
    try std.testing.expect(mouseInput(win32.WM_KEYDOWN, 0, .{ .x = 0, .y = 0 }, bounds) == null);
}

test shouldNavigate {
    // Our own report, echoed: nothing to do.
    try std.testing.expect(!shouldNavigate(L("https://example.com/"), L("https://example.com/")));
    try std.testing.expect(shouldNavigate(L("https://example.com/"), L("https://example.org/")));
    try std.testing.expect(shouldNavigate(null, L("https://example.org/")));
    try std.testing.expect(!shouldNavigate(null, L("")));
}
