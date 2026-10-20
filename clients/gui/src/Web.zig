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
//! with 0 for local: a host's panes browse the host's network through
//! its daemon's SOCKS proxy (`browserArgs`). Everything here runs on the
//! UI thread, which is a COM single-threaded apartment (main.zig), and
//! WebView2 calls back on it from the message loop.
//!
//! A view lives as long as its pane is in the window: shown while it's
//! placed in the active tab, hidden in another tab or behind a zoom, and
//! closed when its session goes (`detach`), its pane ends, its browser
//! fails, or its host's connection ends or comes back on another proxy
//! (`hostChanged`). A failed view leaves the pane's stand-in saying why
//! (`Session.Browser.failed`), and a click there makes a new one; one
//! closed for its host makes a new one by itself once it can. One hidden
//! longer than `browser.idle` is closed too (`closeIdle`), and the next
//! placement opens the pane's url again.
//!
//! A page opening a window on a click splits its pane with a browser
//! pane there (`Events.new_window`); one opening it by itself opens
//! nothing. Camera, microphone, and location are denied;
//! other permissions are asked about in the window's dialog
//! (`Events.permission`), one at a time per pane.

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
const Config = @import("Config.zig");
const input = @import("input.zig");
const Painter = Renderer.Painter;

const log = std.log.scoped(.web);

const L = std.unicode.utf8ToUtf16LeStringLiteral;

/// Why a browser pane has no browser.
pub const runtime_missing = "WebView2 runtime not found";
pub const loader_missing = "WebView2Loader.dll is missing beside slime-gui.exe";
const start_failed = "The browser couldn't start. Click to try again.";
const browser_exited = "The browser closed. Click to reload.";
const page_crashed = "The page crashed. Click to reload.";
const page_hung = "The page stopped responding. Click to reload.";
/// The pane's host is between connections, or its browser between
/// proxies: the next placement after tries again.
const reconnecting = "Reconnecting the host's browser…";

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
    key: *const fn (*anyopaque, u32, win32.WPARAM, win32.LPARAM) bool,
    /// A page's cursor changed.
    cursor: *const fn (*anyopaque) void,
    /// Host `id` (not 0) while it's connected; null while it isn't.
    host: *const fn (*anyopaque, u32) ?Host,
    /// Draw again: panes waiting on a host's browser may get one.
    redraw: *const fn (*anyopaque) void,
    /// A pane's page opens a window at a url: returns true if it went
    /// into a new pane.
    new_window: *const fn (*anyopaque, *Session, []const u16) bool,
    /// A pane's page at `site` asks to `what` (`permissionPolicy`):
    /// returns true if the window asks the user, whose answer comes to
    /// `answer`.
    permission: *const fn (*anyopaque, *Session, []const u16, []const u8) bool,
};

/// A connected host, as a browser on it needs it. Borrowed.
pub const Host = struct {
    /// Its destination, which names its profile folder.
    dest: []const u16,
    /// Its daemon's SOCKS proxy, `socks5://127.0.0.1:<port>`; empty when
    /// it has none.
    proxy: []const u16,
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
    for (self.envs.items) |e| {
        e.letGo();
        e.unhold();
    }
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
/// made when its first view wants it. Local's lives as long as the
/// window; a host's until the host's proxy changes or its connection
/// ends (`retire`). Counted: the list holds one reference, and its
/// creation one until it's done.
const Env = struct {
    web: *Web,
    host: u32,
    refs: u32 = 1,
    state: union(enum) {
        creating,
        ready: *wv.IEnvironment,
        failed,
        /// Let go, its browser process still running: no view is made on
        /// its folder until that has exited (`exited`), since a browser
        /// started with other arguments wouldn't take them. Holds the
        /// environment until then.
        closing: *wv.IEnvironment,
        /// Let go while it was being made: `envCreated` drops it. Its
        /// panes wait as they do on `closing`.
        retired,
    } = .creating,
    /// The proxy it was made with, which its browser keeps; empty for
    /// none. Owned.
    proxy: []u16 = &.{},
    /// Its browser's arguments, from `proxy`, which `options` gives.
    /// Owned.
    args: ?[:0]u16 = null,
    /// Its browser process, once a WebView has said.
    pid: u32 = 0,
    /// Our BrowserProcessExited handler's, while `closing` has one on.
    exit_token: ?wv.EventRegistrationToken = null,
    /// Views waiting for it, each holding a reference.
    waiting: std.ArrayList(*View) = .empty,
    completed: Callback(wv.EnvironmentCompletedHandler, Env, "completed", envCreated) = .{},
    exited: Callback(wv.BrowserProcessExitedEventHandler, Env, "exited", browserExited) = .{},
    options: Options = .{},

    fn hold(self: *Env) void {
        self.refs += 1;
    }

    fn unhold(self: *Env) void {
        self.refs -= 1;
        if (self.refs == 0) self.destroy();
    }

    // WebView2's references aren't counted: the loader lets go of one
    // on the creation handler that it never took. Ours keep it.
    fn retain(_: *Env) u32 {
        return 1;
    }
    fn release(_: *Env) u32 {
        return 1;
    }

    fn destroy(self: *Env) void {
        self.letGo();
        for (self.waiting.items) |v| _ = v.release();
        self.waiting.deinit(self.web.alloc);
        self.web.alloc.free(self.proxy);
        if (self.args) |a| self.web.alloc.free(a);
        self.web.alloc.destroy(self);
    }

    /// Release the environment, if it holds one, its exit handler taken
    /// off first: the handler is in this `Env`, which goes after.
    fn letGo(self: *Env) void {
        switch (self.state) {
            .ready, .closing => |e| {
                if (self.exit_token) |token| if (com.query(e, wv.IEnvironment5)) |e5| {
                    defer com.release(e5);
                    _ = e5.removeBrowserProcessExited(token);
                };
                self.exit_token = null;
                com.release(e);
            },
            .creating, .failed, .retired => {},
        }
        self.state = .failed;
    }
};

/// What an environment is made with (ICoreWebView2EnvironmentOptions):
/// its browser's arguments; the rest are what the SDK's own options
/// default to. Lives in its `Env`, as long as its creation.
const Options = struct {
    iface: wv.EnvironmentOptions = .{ .vtable = &vtable },

    const vtable: wv.EnvironmentOptions.VTable = .{
        .QueryInterface = queryInterface,
        .AddRef = addRef,
        .Release = release,
        .get_AdditionalBrowserArguments = getArgs,
        .put_AdditionalBrowserArguments = put,
        .get_Language = getNone,
        .put_Language = put,
        .get_TargetCompatibleBrowserVersion = getTarget,
        .put_TargetCompatibleBrowserVersion = put,
        .get_AllowSingleSignOnUsingOSPrimaryAccount = getSingleSignOn,
        .put_AllowSingleSignOnUsingOSPrimaryAccount = putSingleSignOn,
    };

    fn outer(iface: *wv.EnvironmentOptions) *Env {
        const self: *Options = @fieldParentPtr("iface", iface);
        return @fieldParentPtr("options", self);
    }

    fn queryInterface(iface: *wv.EnvironmentOptions, iid: *const win32.GUID, out: *?*anyopaque) callconv(.winapi) win32.HRESULT {
        // The later EnvironmentOptions2.. aren't ours: their defaults.
        if (com.guidEql(iid, &com.IID_IUnknown) or com.guidEql(iid, &wv.EnvironmentOptions.iid)) {
            _ = outer(iface).retain();
            out.* = iface;
            return com.S_OK;
        }
        out.* = null;
        return com.E_NOINTERFACE;
    }

    fn addRef(iface: *wv.EnvironmentOptions) callconv(.winapi) u32 {
        return outer(iface).retain();
    }

    fn release(iface: *wv.EnvironmentOptions) callconv(.winapi) u32 {
        return outer(iface).release();
    }

    fn getArgs(iface: *wv.EnvironmentOptions, out: *?win32.LPWSTR) callconv(.winapi) win32.HRESULT {
        return coString(if (outer(iface).args) |a| a else null, out);
    }

    fn getNone(_: *wv.EnvironmentOptions, out: *?win32.LPWSTR) callconv(.winapi) win32.HRESULT {
        out.* = null;
        return com.S_OK;
    }

    fn getTarget(_: *wv.EnvironmentOptions, out: *?win32.LPWSTR) callconv(.winapi) win32.HRESULT {
        return coString(L(wv.target_browser_version), out);
    }

    fn put(_: *wv.EnvironmentOptions, _: ?win32.LPCWSTR) callconv(.winapi) win32.HRESULT {
        return com.E_NOTIMPL;
    }

    fn getSingleSignOn(_: *wv.EnvironmentOptions, out: *win32.BOOL) callconv(.winapi) win32.HRESULT {
        out.* = 0;
        return com.S_OK;
    }

    fn putSingleSignOn(_: *wv.EnvironmentOptions, _: win32.BOOL) callconv(.winapi) win32.HRESULT {
        return com.E_NOTIMPL;
    }

    /// `s` in memory the caller frees with CoTaskMemFree.
    fn coString(s: ?[]const u16, out: *?win32.LPWSTR) win32.HRESULT {
        const src = s orelse {
            out.* = null;
            return com.S_OK;
        };
        const mem = win32.CoTaskMemAlloc((src.len + 1) * 2) orelse return com.E_OUTOFMEMORY;
        const dst: [*]u16 = @ptrCast(@alignCast(mem));
        @memcpy(dst[0..src.len], src);
        dst[src.len] = 0;
        out.* = @ptrCast(dst);
        return com.S_OK;
    }
};

/// The environment for host `host` (0 for local), made if it isn't. A
/// host's needs the host connected.
fn env(self: *Web, host: u32) !*Env {
    for (self.envs.items) |e| if (e.host == host) return e;
    const create = self.load() orelse return error.RuntimeMissing;
    var name: []const u16 = L("local");
    var name_buf: [host_folder_len]u16 = undefined;
    var proxy: []const u16 = &.{};
    if (host != 0) {
        const h = self.events.host(self.events.ctx, host) orelse return error.HostDown;
        name_buf = hostFolder(h.dest);
        name = &name_buf;
        proxy = h.proxy;
    }
    var folder: [512]u16 = undefined;
    const path = try userDataFolder(&folder, name);
    try self.envs.ensureUnusedCapacity(self.alloc, 1);
    const e = try self.alloc.create(Env);
    e.* = .{ .web = self, .host = host };
    errdefer e.destroy();
    e.proxy = try self.alloc.dupe(u16, proxy);
    e.args = browserArgs(self.alloc, proxy) catch |err| {
        log.err("host {d}'s proxy {f} isn't one a browser takes", .{ host, std.unicode.fmtUtf16Le(proxy) });
        return err;
    };
    log.info("browser for host {d}: {f} {f}", .{ host, std.unicode.fmtUtf16Le(path), std.unicode.fmtUtf16Le(if (e.args) |a| a else &.{}) });
    // Local's are the defaults.
    const options: ?*wv.EnvironmentOptions = if (host == 0) null else &e.options.iface;
    // Listed, and held until it's made, before: the loader may call back
    // before it returns.
    self.envs.appendAssumeCapacity(e);
    e.hold();
    com.check(createEnvironment(create, path, options, &e.completed.iface), "CreateCoreWebView2EnvironmentWithOptions") catch |err| {
        _ = self.envs.pop();
        e.refs = 1;
        return err;
    };
    return e;
}

/// The arguments a browser browsing a host through its daemon's SOCKS
/// proxy `proxy` (`socks5://127.0.0.1:<port>`) starts with: every
/// connection through the proxy, which resolves names on the host, and
/// no name resolved here but the proxy's own, which Chromium's
/// prefetcher would otherwise look up past it. Loopback goes through
/// too (`<-loopback>` undoes Chromium's implicit bypass): localhost is
/// the host's. WebRTC sends no UDP but through the proxy, which takes
/// none: SOCKS is TCP here, and a STUN or TURN server at an IP would
/// otherwise be reached from this machine's network. Null for no proxy.
pub fn browserArgs(alloc: Allocator, proxy: []const u16) !?[:0]u16 {
    if (proxy.len == 0) return null;
    const scheme = L("socks5://");
    if (!std.mem.startsWith(u16, proxy, scheme)) return error.BadProxy;
    // It goes on a command line: nothing that would end or quote it.
    for (proxy) |c| if (c <= ' ' or c == '"') return error.BadProxy;
    const addr = proxy[scheme.len..];
    const colon = std.mem.lastIndexOfScalar(u16, addr, ':') orelse return error.BadProxy;
    if (colon == 0) return error.BadProxy;
    return try std.mem.concatWithSentinel(alloc, u16, &.{
        L("--proxy-server="),
        proxy,
        L(" --host-resolver-rules=\"MAP * ~NOTFOUND , EXCLUDE "),
        addr[0..colon],
        L("\" --proxy-bypass-list=\"<-loopback>\""),
        L(" --force-webrtc-ip-handling-policy=disable_non_proxied_udp"),
    }, 0);
}

test browserArgs {
    const alloc = std.testing.allocator;
    const args = (try browserArgs(alloc, L("socks5://127.0.0.1:40123"))).?;
    defer alloc.free(args);
    try std.testing.expectEqualSlices(u16, L("--proxy-server=socks5://127.0.0.1:40123 --host-resolver-rules=\"MAP * ~NOTFOUND , EXCLUDE 127.0.0.1\" --proxy-bypass-list=\"<-loopback>\" --force-webrtc-ip-handling-policy=disable_non_proxied_udp"), args);
    try std.testing.expectEqual(@as(?[:0]u16, null), try browserArgs(alloc, L("")));
    try std.testing.expectError(error.BadProxy, browserArgs(alloc, L("http://127.0.0.1:8080")));
    try std.testing.expectError(error.BadProxy, browserArgs(alloc, L("socks5://127.0.0.1:1\" --evil")));
    try std.testing.expectError(error.BadProxy, browserArgs(alloc, L("socks5://:1080")));
}

const host_folder_len = "host-".len + 16;

/// The profile folder's name for the host at `dest`: `host-` and the
/// first 8 bytes of the SHA-256 of its UTF-8, in hex, so one destination
/// keeps its cookies across runs and another's are apart.
pub fn hostFolder(dest: []const u16) [host_folder_len]u16 {
    var sha: std.crypto.hash.sha2.Sha256 = .init(.{});
    var it: std.unicode.Utf16LeIterator = .init(dest);
    while (true) {
        const cp = it.nextCodepoint() catch std.unicode.replacement_character orelse break;
        var utf8: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &utf8) catch unreachable;
        sha.update(utf8[0..n]);
    }
    var digest: [32]u8 = undefined;
    sha.final(&digest);
    var name: [host_folder_len]u16 = undefined;
    for ("host-", 0..) |c, i| name[i] = c;
    const hex = std.fmt.bytesToHex(digest[0..8], .lower);
    for (hex, 0..) |c, i| name[5 + i] = c;
    return name;
}

test hostFolder {
    // echo -n ssh://alde@pi:2222 | sha256sum
    try std.testing.expectEqualSlices(u16, L("host-97729a595990bf71"), &hostFolder(L("ssh://alde@pi:2222")));
    const a = hostFolder(L("ssh://devbox"));
    try std.testing.expectEqualSlices(u16, &a, &hostFolder(L("ssh://devbox")));
    try std.testing.expect(!std.mem.eql(u16, &a, &hostFolder(L("ssh://devbox2"))));
}

/// Where a host's browser keeps its profile: %LOCALAPPDATA%\slime\webview
/// \<name>, `local` for local or `hostFolder`'s (with -<instance> under
/// SLIME_INSTANCE, so a test window doesn't share a running browser's).
fn userDataFolder(buf: *[512]u16, name: []const u16) ![:0]const u16 {
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
    try put(buf, &len, L("\\slime\\webview\\"));
    try put(buf, &len, name);
    var inst: [64]u16 = undefined;
    if (Daemon.instance(&inst)) |instance| {
        try put(buf, &len, L("-"));
        try put(buf, &len, instance);
    }
    buf[len] = 0;
    return buf[0..len :0];
}

/// Make an environment: its browser process starts with its first
/// WebView. `options` is null for the defaults.
fn createEnvironment(create: wv.CreateEnvironmentWithOptions, folder: [:0]const u16, options: ?*wv.EnvironmentOptions, done: *wv.EnvironmentCompletedHandler) win32.HRESULT {
    return create(null, folder.ptr, options, done);
}

fn envCreated(e: *Env, hr: win32.HRESULT, result: ?*wv.IEnvironment) win32.HRESULT {
    // Its creation's reference.
    defer e.unhold();
    const waiting = e.waiting;
    e.waiting = .empty;
    defer {
        for (waiting.items) |v| _ = v.release();
        var list = waiting;
        list.deinit(e.web.alloc);
    }
    if (e.state != .creating) {
        // Retired while it was made: its views went then. No WebView ran
        // on it, so no browser process holds its folder.
        e.web.drop(e);
        return com.S_OK;
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

/// Whether a host's environment, made with proxy `made_with`, still
/// serves the host, which is now `now` (null: not connected). Its
/// browser keeps the arguments it started with, so a new proxy needs a
/// new environment, and a host that's gone needs none.
pub fn keepsEnv(made_with: []const u16, now: ?Host) bool {
    const h = now orelse return false;
    return std.mem.eql(u16, made_with, h.proxy);
}

test keepsEnv {
    const proxy = L("socks5://127.0.0.1:40123");
    try std.testing.expect(keepsEnv(proxy, .{ .dest = L("ssh://devbox"), .proxy = proxy }));
    // Reconnected on another port.
    try std.testing.expect(!keepsEnv(proxy, .{ .dest = L("ssh://devbox"), .proxy = L("socks5://127.0.0.1:40124") }));
    // Lost, or disconnected.
    try std.testing.expect(!keepsEnv(proxy, null));
    // Proxy turned off, or on.
    try std.testing.expect(!keepsEnv(proxy, .{ .dest = L("ssh://devbox"), .proxy = L("") }));
    try std.testing.expect(!keepsEnv(L(""), .{ .dest = L("ssh://devbox"), .proxy = proxy }));
    try std.testing.expect(keepsEnv(L(""), .{ .dest = L("ssh://devbox"), .proxy = L("") }));
}

/// Host `host`'s state or proxy changed: if its environment no longer
/// serves it (`keepsEnv`), the environment goes, and its views with it.
/// Either way its panes may try again: one waiting on the host may have
/// it now.
pub fn hostChanged(self: *Web, host: u32) void {
    if (host == 0) return;
    const now = self.events.host(self.events.ctx, host);
    for (self.envs.items) |e| if (e.host == host) {
        if (e.state != .closing and e.state != .retired and !keepsEnv(e.proxy, now)) self.retire(e);
        break;
    };
    self.events.redraw(self.events.ctx);
}

/// Let host environment `e` go: close its views, their panes standing in
/// until a new one is up, and drop it once its browser process has
/// exited, so the next environment on its folder starts a browser with
/// its own arguments.
fn retire(self: *Web, e: *Env) void {
    log.info("letting host {d}'s browser go", .{e.host});
    var i: usize = self.views.items.len;
    while (i > 0) {
        i -= 1;
        const v = self.views.items[i];
        if (v.host == e.host) v.fail(reconnecting);
    }
    switch (e.state) {
        .creating => e.state = .retired,
        .failed => self.drop(e),
        .ready => |environment| {
            e.state = .{ .closing = environment };
            if (browserRunning(e.pid)) if (com.query(environment, wv.IEnvironment5)) |e5| {
                defer com.release(e5);
                var token: wv.EventRegistrationToken = .{};
                if (e5.addBrowserProcessExited(&e.exited.iface, &token) >= 0) {
                    e.exit_token = token;
                    return;
                }
            };
            self.drop(e);
        },
        .closing, .retired => {},
    }
}

/// Whether process `pid` (0 for none known) is still running, and is a
/// WebView2 browser: a pid reused by another program since isn't.
fn browserRunning(pid: u32) bool {
    if (pid == 0) return false;
    const h = win32.OpenProcess(win32.SYNCHRONIZE | win32.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return false;
    defer _ = win32.CloseHandle(h);
    if (win32.WaitForSingleObject(h, 0) != win32.WAIT_TIMEOUT) return false;
    var path: [win32.MAX_PATH]u16 = undefined;
    var len: u32 = path.len;
    if (win32.QueryFullProcessImageNameW(h, 0, &path, &len) == 0) return false;
    return isBrowserImage(path[0..len]);
}

/// Whether the exe at `path` is WebView2's browser.
pub fn isBrowserImage(path: []const u16) bool {
    const name = L("msedgewebview2.exe");
    if (path.len < name.len) return false;
    const base = path[path.len - name.len ..];
    if (path.len > name.len and path[path.len - name.len - 1] != '\\') return false;
    for (base, name) |a, b| if (std.ascii.toLower(@intCast(@min(a, 0x7f))) != b) return false;
    return true;
}

test isBrowserImage {
    try std.testing.expect(isBrowserImage(L("C:\\Program Files (x86)\\Microsoft\\EdgeWebView\\Application\\155.0.4283.62\\msedgewebview2.exe")));
    try std.testing.expect(isBrowserImage(L("C:\\X\\MSEdgeWebView2.EXE")));
    try std.testing.expect(!isBrowserImage(L("C:\\Windows\\notepad.exe")));
    try std.testing.expect(!isBrowserImage(L("C:\\X\\notmsedgewebview2.exe")));
}

fn browserExited(e: *Env, _: *wv.IEnvironment, _: *wv.IUnknown) win32.HRESULT {
    log.info("host {d}'s browser exited", .{e.host});
    if (e.state == .closing) e.web.drop(e);
    return com.S_OK;
}

/// Take `e` out of the list and let it go; panes waiting on its host
/// try again.
fn drop(self: *Web, e: *Env) void {
    const i = for (self.envs.items, 0..) |x, i| {
        if (x == e) break i;
    } else return;
    _ = self.envs.swapRemove(i);
    e.letGo();
    e.unhold();
    self.events.redraw(self.events.ctx);
}

/// Stop waiting for host environment `e`'s browser to exit: its views
/// close, and it goes now, so the next placement makes a new one.
fn forceDrop(self: *Web, e: *Env) void {
    log.warn("not waiting for host {d}'s browser to exit", .{e.host});
    var i: usize = self.views.items.len;
    while (i > 0) {
        i -= 1;
        const v = self.views.items[i];
        if (v.host == e.host) v.fail(reconnecting);
    }
    self.drop(e);
}

/// A click on browser pane `s`'s stand-in: its browser gets another go.
/// One waiting on its host's old browser stops waiting (`forceDrop`);
/// one whose environment failed to start drops it, and the next
/// placement makes another.
pub fn retry(self: *Web, s: *Session) void {
    const b = s.browser() orelse return;
    const was = b.failed orelse return;
    b.failed = null;
    const host = hostOf(s);
    for (self.envs.items) |e| if (e.host == host) {
        switch (e.state) {
            .closing, .retired => if (was.ptr == reconnecting.ptr) self.forceDrop(e),
            .failed => if (was.ptr == start_failed.ptr) self.drop(e),
            .creating, .ready => {},
        }
        break;
    };
}

const TestEvents = struct {
    redraws: usize = 0,

    fn events(self: *TestEvents) Events {
        return .{
            .ctx = self,
            .changed = changed,
            .focus = onFocus,
            .tab_out = onFocus,
            .key = key,
            .cursor = redraw,
            .host = host,
            .redraw = redraw,
            .new_window = newWin,
            .permission = permit,
        };
    }
    fn changed(_: *anyopaque, _: *Session) void {}
    fn newWin(_: *anyopaque, _: *Session, _: []const u16) bool {
        return false;
    }
    fn permit(_: *anyopaque, _: *Session, _: []const u16, _: []const u8) bool {
        return false;
    }
    fn onFocus(_: *anyopaque, _: *Session, _: bool) void {}
    fn key(_: *anyopaque, _: u32, _: win32.WPARAM, _: win32.LPARAM) bool {
        return false;
    }
    fn host(_: *anyopaque, _: u32) ?Host {
        return null;
    }
    fn redraw(ctx: *anyopaque) void {
        const self: *TestEvents = @ptrCast(@alignCast(ctx));
        self.redraws += 1;
    }
};

test "drop takes a host's environment out past local's" {
    const alloc = std.testing.allocator;
    var events: TestEvents = .{};
    var web: Web = .init(alloc, @ptrFromInt(0x1000), events.events(), 96);
    defer web.deinit();
    const local = try alloc.create(Env);
    local.* = .{ .web = &web, .host = 0, .state = .failed };
    try web.envs.append(alloc, local);
    const host = try alloc.create(Env);
    host.* = .{ .web = &web, .host = 7, .state = .failed };
    try web.envs.append(alloc, host);

    web.drop(host);
    try std.testing.expectEqual(@as(usize, 1), web.envs.items.len);
    try std.testing.expectEqual(local, web.envs.items[0]);
    try std.testing.expectEqual(@as(usize, 1), events.redraws);
    // Once only: a second drop (envCreated after a retire) does nothing.
    web.drop(host);
    try std.testing.expectEqual(@as(usize, 1), events.redraws);
}

test "an environment retired while it's made waits, and a click drops it" {
    const alloc = std.testing.allocator;
    var events: TestEvents = .{};
    var web: Web = .init(alloc, @ptrFromInt(0x1000), events.events(), 96);
    defer web.deinit();
    const e = try alloc.create(Env);
    e.* = .{ .web = &web, .host = 7 };
    try web.envs.append(alloc, e);
    // Its creation's reference, which `envCreated` would let go.
    e.hold();

    web.retire(e);
    try std.testing.expect(e.state == .retired);
    // Not retired again while it waits.
    web.hostChanged(7);
    try std.testing.expect(e.state == .retired);
    try std.testing.expectEqual(@as(usize, 1), web.envs.items.len);

    web.forceDrop(e);
    try std.testing.expectEqual(@as(usize, 0), web.envs.items.len);
    // `envCreated` coming after finds it gone: drop does nothing.
    web.drop(e);
    e.unhold();
}

test "a click on a pane whose browser couldn't start drops the failed environment" {
    const alloc = std.testing.allocator;
    var events: TestEvents = .{};
    var web: Web = .init(alloc, @ptrFromInt(0x1000), events.events(), 96);
    defer web.deinit();
    var config: Config = .init(alloc);
    defer config.deinit();
    var s = try Session.testBrowser(alloc, &config, L("https://example.com/"));
    defer s.deinitContent();
    const e = try alloc.create(Env);
    e.* = .{ .web = &web, .host = 0, .state = .failed };
    try web.envs.append(alloc, e);
    const b = s.browser().?;

    // Another failure leaves it: a crashed page's environment is fine.
    b.failed = page_crashed;
    web.retry(&s);
    try std.testing.expectEqual(@as(?[]const u8, null), b.failed);
    try std.testing.expectEqual(@as(usize, 1), web.envs.items.len);

    b.failed = start_failed;
    web.retry(&s);
    try std.testing.expectEqual(@as(?[]const u8, null), b.failed);
    try std.testing.expectEqual(@as(usize, 0), web.envs.items.len);
}

/// A permission request's arguments, or its deferral, with no browser
/// behind them: what `Pending.answer` calls, counted.
const FakeRequest = extern struct {
    vtable: com.VTable = @ptrCast(&slots),
    state: i32 = -1,
    completed: u32 = 0,
    released: u32 = 0,

    const slots = [_]*const anyopaque{
        @ptrCast(&queryInterface), @ptrCast(&addRef),   @ptrCast(&release),
        @ptrCast(&complete),       @ptrCast(&unused),   @ptrCast(&unused),
        @ptrCast(&unused),         @ptrCast(&putState), @ptrCast(&unused),
    };

    fn queryInterface(_: *FakeRequest, _: *const win32.GUID, out: *?*anyopaque) callconv(.winapi) win32.HRESULT {
        out.* = null;
        return com.E_NOINTERFACE;
    }
    fn addRef(_: *FakeRequest) callconv(.winapi) u32 {
        return 1;
    }
    fn release(self: *FakeRequest) callconv(.winapi) u32 {
        self.released += 1;
        return 0;
    }
    /// The deferral's Complete.
    fn complete(self: *FakeRequest) callconv(.winapi) win32.HRESULT {
        self.completed += 1;
        return com.S_OK;
    }
    /// The arguments' put_State.
    fn putState(self: *FakeRequest, state: i32) callconv(.winapi) win32.HRESULT {
        self.state = state;
        return com.S_OK;
    }
    fn unused(_: *FakeRequest) callconv(.winapi) win32.HRESULT {
        return com.E_NOTIMPL;
    }
};

test "a view shut with a question open answers it, and its pane stops asking" {
    const alloc = std.testing.allocator;
    var events: TestEvents = .{};
    var web: Web = .init(alloc, @ptrFromInt(0x1000), events.events(), 96);
    defer web.deinit();
    var config: Config = .init(alloc);
    defer config.deinit();
    var s = try Session.testBrowser(alloc, &config, L("https://example.com/"));
    defer s.deinitContent();
    const b = s.browser().?;
    var args: FakeRequest = .{};
    var deferral: FakeRequest = .{};

    const v = try alloc.create(View);
    v.* = .{ .web = &web, .session = &s, .key = s.id };
    try web.views.append(alloc, v);
    b.view = v;
    v.pending = .{ .args = @ptrCast(&args), .deferral = @ptrCast(&deferral) };
    b.asking = true;

    // Its page crashed: the view goes, and the question with it.
    v.fail(page_crashed);
    try std.testing.expect(!b.asking);
    try std.testing.expectEqual(@as(?*View, null), b.view);
    try std.testing.expectEqualSlices(u8, page_crashed, b.failed.?);
    try std.testing.expectEqual(@as(usize, 0), web.views.items.len);
    try std.testing.expectEqual(@intFromEnum(wv.PermissionState.deny), args.state);
    try std.testing.expectEqual(@as(u32, 1), deferral.completed);
    try std.testing.expectEqual(@as(u32, 1), args.released);
    try std.testing.expectEqual(@as(u32, 1), deferral.released);
}

/// A COM object WebView2 calls back, embedded in `Outer` as `field`:
/// `invoke` gets the outer struct, and references count on it. A
/// one-argument handler's `invoke` takes void for the second.
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
            .Invoke = if (H.B == void) call1 else call,
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

        fn call1(iface: *H, a: H.A) callconv(.winapi) win32.HRESULT {
            return invoke(outer(iface), a, {});
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
    /// The host whose environment it's made in (`hostOf`).
    host: u32 = 0,
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
    /// When it was hidden (GetTickCount64), while it is.
    hidden_at: ?u64 = null,
    /// The page's picture being made for a drag (`capture`), and whether
    /// it's still wanted.
    preview_stream: ?*win32.IStream = null,
    want_preview: bool = false,
    /// A permission the window is asking the user about.
    pending: ?Pending = null,
    /// The navigation slime sent the page on (`followTo`), which isn't
    /// reported back wherever it lands (`Session.Browser.followed`):
    /// `asked` from its Navigate to its NavigationStarting, then `on`,
    /// with its id, until it completes.
    following: union(enum) { none, asked, on: u64 } = .none,

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
    zoom_changed: Callback(wv.ZoomFactorChangedEventHandler, View, "zoom_changed", zoomChanged) = .{},
    captured: Callback(wv.CapturePreviewCompletedHandler, View, "captured", previewCaptured) = .{},
    favicon_changed: Callback(wv.FaviconChangedEventHandler, View, "favicon_changed", faviconChanged) = .{},
    favicon_got: Callback(wv.GetFaviconCompletedHandler, View, "favicon_got", faviconGot) = .{},
    permission: Callback(wv.PermissionRequestedEventHandler, View, "permission", permissionRequested) = .{},

    /// A permission request held open (`GetDeferral`) for the user's
    /// answer.
    const Pending = struct {
        args: *wv.IPermissionRequestedEventArgs,
        deferral: *wv.IDeferral,

        /// Answer, and let it go. A dismissed question is denied for
        /// this request alone; an answer the user chose is kept for the
        /// site, as browsers keep them.
        fn answer(self: Pending, a: Answer) void {
            if (a == .dismiss) if (com.query(self.args, wv.IPermissionRequestedEventArgs3)) |args3| {
                defer com.release(args3);
                _ = args3.putSavesInProfile(false);
            };
            _ = self.args.putState(if (a == .allow) .allow else .deny);
            _ = self.deferral.complete();
            com.release(self.deferral);
            com.release(self.args);
        }
    };

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
        const e = self.web.readyEnv(self.host) orelse return self.fail(start_failed);
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
        // While it has the session, whose question it ends.
        self.settle(.dismiss);
        self.session = null;
        const web = self.web;
        for (web.views.items, 0..) |v, i| if (v == self) {
            _ = web.views.swapRemove(i);
            break;
        };
        self.unplace();
        self.want_preview = false;
        com.releaseOpt(&self.preview_stream);
        if (self.controller) |c| _ = c.close();
        com.releaseOpt(&self.webview);
        com.releaseOpt(&self.controller);
        com.releaseOpt(&self.comp);
        com.releaseOpt(&self.visual);
        if (web.renderer) |r| r.commit() catch {};
        _ = self.release();
    }

    /// Answer the pending permission, if there is one.
    fn settle(self: *View, a: Answer) void {
        const p = self.pending orelse return;
        self.pending = null;
        if (self.browser()) |b| b.asking = false;
        p.answer(a);
    }

    /// Shut the view, its pane standing in saying `why`. The view may be
    /// gone after.
    fn fail(self: *View, why: []const u8) void {
        const s = self.session;
        const events = self.web.events;
        if (self.browser()) |b| {
            b.failed = why;
            b.loading = false;
        }
        self.shut();
        if (s) |session| events.changed(events.ctx, session);
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
        self.hidden_at = null;
    }

    /// Out of sight, kept: another tab is shown, or another pane zoomed.
    fn hide(self: *View) void {
        self.unplace();
        if (self.shown and self.state == .ready) _ = self.controller.?.putIsVisible(false);
        if (self.hidden_at == null) self.hidden_at = win32.GetTickCount64();
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
    // Its browser's, which a new one after a crash replaces.
    for (web.envs.items) |e| if (e.host == self.host) {
        _ = w.getBrowserProcessId(&e.pid);
    };

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
    try com.check(controller.addZoomFactorChanged(&self.zoom_changed.iface, &token), "add_ZoomFactorChanged");
    try com.check(w.addPermissionRequested(&self.permission.iface, &token), "add_PermissionRequested");
    // Without it (a runtime before 1.0.1185), the globe stays.
    if (com.query(w, wv.IWebView15)) |w15| {
        defer com.release(w15);
        com.check(w15.addFaviconChanged(&self.favicon_changed.iface, &token), "add_FaviconChanged") catch {};
    }

    self.state = .ready;
    // Placed while it was made: show it there.
    if (self.container) |c| try com.check(c.addVisual(visual.?, true, null), "IDCompositionVisual::AddVisual");
    _ = controller.putBounds(self.bounds);
    _ = controller.putIsVisible(self.shown);
    if (self.browser()) |b| if (b.zoom != 1) {
        _ = controller.putZoomFactor(b.zoom);
    };
    try r.commit();
    // Where slime sent it while it was made is slime's; its own url (a
    // new pane's, one closed while hidden) is reported as it lands.
    if (self.browser()) |b| {
        if (b.followed != null) followTo(self, b.url) else _ = navigate(self, b.url);
    }
    if (self.session) |s| web.events.changed(web.events.ctx, s);
}

/// Go to `url`. False if the WebView wouldn't.
fn navigate(self: *View, url: []const u16) bool {
    const w = self.webview orelse return false;
    const z = self.web.alloc.dupeZ(u16, url) catch return false;
    defer self.web.alloc.free(z);
    log.debug("pane {d} goes to {f}", .{ self.key, std.unicode.fmtUtf16Le(url) });
    com.check(w.navigate(z), "ICoreWebView2::Navigate") catch {
        log.warn("can't go to {f}", .{std.unicode.fmtUtf16Le(url)});
        return false;
    };
    return true;
}

/// Go to `url` because slime said: where it lands isn't reported.
fn followTo(self: *View, url: []const u16) void {
    self.following = .asked;
    if (!navigate(self, url)) self.following = .none;
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
    _ = s.visited(url, if (title) |t| std.mem.span(t) else &.{});
    self.web.events.changed(self.web.events.ctx, s);
}

/// A navigation the user made here (a link, a gesture, our Navigate)
/// is theirs, and reported as it lands; slime's (`followTo`), its
/// redirects, and the page's script going on from it aren't, so two
/// windows on a page that bounces to a fresh url don't send each other
/// round.
fn navigationStarting(self: *View, _: *wv.IWebView, args: *wv.INavigationStartingEventArgs) win32.HRESULT {
    const s = self.session orelse return com.S_OK;
    const b = s.browser() orelse return com.S_OK;
    var redirected: win32.BOOL = 0;
    var user: win32.BOOL = 0;
    var id: u64 = 0;
    _ = args.getIsRedirected(&redirected);
    _ = args.getIsUserInitiated(&user);
    _ = args.getNavigationId(&id);
    if (redirected == 0) {
        if (self.following == .asked) {
            self.following = .{ .on = id };
        } else if (user != 0) {
            self.following = .none;
            s.ownNavigation();
        }
    }
    b.loading = true;
    self.web.events.changed(self.web.events.ctx, s);
    return com.S_OK;
}

fn navigationCompleted(self: *View, _: *wv.IWebView, args: *wv.INavigationCompletedEventArgs) win32.HRESULT {
    const b = self.browser() orelse return com.S_OK;
    var id: u64 = 0;
    _ = args.getNavigationId(&id);
    switch (self.following) {
        .on => |on| if (on == id) {
            self.following = .none;
        },
        .none, .asked => {},
    }
    b.loading = false;
    self.web.events.changed(self.web.events.ctx, self.session.?);
    return com.S_OK;
}

fn sourceChanged(self: *View, _: *wv.IWebView, args: *wv.ISourceChangedEventArgs) win32.HRESULT {
    // A change within the page once slime's navigation is done (an
    // in-page link) is the user's.
    var new_document: win32.BOOL = 1;
    _ = args.getIsNewDocument(&new_document);
    if (new_document == 0 and self.following == .none) if (self.session) |s| s.ownNavigation();
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

/// A page opening a window on a click opens it in a pane split off its
/// own, or, where the window can't split it, in its own. One its script
/// opens by itself (a timer, a load) opens nothing: a page can't fill
/// the window with panes, or take the focus.
fn newWindow(self: *View, _: *wv.IWebView, args: *wv.INewWindowRequestedEventArgs) win32.HRESULT {
    _ = args.putHandled(true);
    var uri: ?win32.LPWSTR = null;
    if (args.getUri(&uri) < 0) return com.S_OK;
    defer win32.CoTaskMemFree(uri);
    const url = std.mem.span(uri orelse return com.S_OK);
    if (url.len == 0) return com.S_OK;
    var user: win32.BOOL = 0;
    _ = args.getIsUserInitiated(&user);
    if (user == 0) {
        log.debug("pane {d}'s page opened a window by itself, at {f}: not opened", .{ self.key, std.unicode.fmtUtf16Le(url) });
        return com.S_OK;
    }
    const s = self.session orelse return com.S_OK;
    if (self.web.events.new_window(self.web.events.ctx, s, url)) return com.S_OK;
    self.following = .none;
    s.ownNavigation();
    _ = navigate(self, url);
    return com.S_OK;
}

fn faviconChanged(self: *View, w: *wv.IWebView, _: ?*wv.IUnknown) win32.HRESULT {
    const w15 = com.query(w, wv.IWebView15) orelse return com.S_OK;
    defer com.release(w15);
    var uri: ?win32.LPWSTR = null;
    _ = w15.getFaviconUri(&uri);
    defer win32.CoTaskMemFree(uri);
    if (!hasFavicon(if (uri) |u| std.mem.span(u) else null)) {
        setFavicon(self, null);
        return com.S_OK;
    }
    com.check(w15.getFavicon(.png, &self.favicon_got.iface), "ICoreWebView2_15::GetFavicon") catch setFavicon(self, null);
    return com.S_OK;
}

fn faviconGot(self: *View, hr: win32.HRESULT, stream: ?*win32.IStream) win32.HRESULT {
    if (self.state != .ready) return com.S_OK;
    const r = self.web.renderer orelse return com.S_OK;
    const png = stream orelse {
        if (hr < 0) log.warn("pane {d}'s favicon: HRESULT=0x{X:0>8}", .{ self.key, @as(u32, @bitCast(hr)) });
        setFavicon(self, null);
        return com.S_OK;
    };
    setFavicon(self, r.decodeImage(png) catch null);
    return com.S_OK;
}

/// Show `img` as the pane's icon; null for the globe.
fn setFavicon(self: *View, img: ?Painter.Image) void {
    const b = self.browser() orelse {
        if (img) |i| com.release(i.bitmap);
        return;
    };
    if (img == null and b.favicon == null) return;
    Session.Browser.setImage(&b.favicon, img);
    self.web.events.changed(self.web.events.ctx, self.session.?);
}

/// Whether a page whose favicon is at `uri` has one to show: one that
/// has none, or one that won't decode, shows the globe.
pub fn hasFavicon(uri: ?[]const u16) bool {
    const u = uri orelse return false;
    return u.len > 0;
}

test hasFavicon {
    try std.testing.expect(hasFavicon(L("https://www.iana.org/favicon.ico")));
    // A data: page, or one that has none.
    try std.testing.expect(!hasFavicon(L("")));
    try std.testing.expect(!hasFavicon(null));
}

fn previewCaptured(self: *View, hr: win32.HRESULT, _: void) win32.HRESULT {
    const stream = self.preview_stream orelse return com.S_OK;
    self.preview_stream = null;
    defer com.release(stream);
    if (!self.want_preview or self.state != .ready) return com.S_OK;
    if (hr < 0) {
        log.warn("capturing pane {d}'s page failed: HRESULT=0x{X:0>8}", .{ self.key, @as(u32, @bitCast(hr)) });
        return com.S_OK;
    }
    const r = self.web.renderer orelse return com.S_OK;
    const img = r.decodeImage(stream) catch return com.S_OK;
    const b = self.browser() orelse {
        com.release(img.bitmap);
        return com.S_OK;
    };
    Session.Browser.setImage(&b.preview, img);
    self.web.events.redraw(self.web.events.ctx);
    return com.S_OK;
}

fn permissionRequested(self: *View, _: *wv.IWebView, args: *wv.IPermissionRequestedEventArgs) win32.HRESULT {
    var kind: wv.PermissionKind = .unknown;
    _ = args.getPermissionKind(&kind);
    var uri: ?win32.LPWSTR = null;
    _ = args.getUri(&uri);
    defer win32.CoTaskMemFree(uri);
    const site = siteOf(if (uri) |u| std.mem.span(u) else &.{});
    const what = switch (permissionPolicy(kind)) {
        .deny => {
            log.info("pane {d}: {f} asked for permission {d}: denied", .{ self.key, std.unicode.fmtUtf16Le(site), @intFromEnum(kind) });
            return deny(args);
        },
        .ask => |what| what,
    };
    // One question at a time: another while one is open is denied.
    const s = self.session orelse return deny(args);
    if (self.pending != null) return deny(args);
    var deferral: ?*wv.IDeferral = null;
    if (args.getDeferral(&deferral) < 0 or deferral == null) return deny(args);
    _ = com.call(args, 1, fn () u32, .{});
    self.pending = .{ .args = args, .deferral = deferral.? };
    if (s.browser()) |b| b.asking = true;
    if (!self.web.events.permission(self.web.events.ctx, s, site, what)) self.settle(.dismiss);
    return com.S_OK;
}

fn deny(args: *wv.IPermissionRequestedEventArgs) win32.HRESULT {
    _ = args.putState(.deny);
    return com.S_OK;
}

pub const Policy = union(enum) {
    deny,
    /// The dialog says the site wants to do this.
    ask: []const u8,
};

/// What a page asking for permission `kind` gets: denied without asking
/// (camera, microphone, and location, which a terminal's browser has no
/// business with, and kinds we can't name), or asked about.
pub fn permissionPolicy(kind: wv.PermissionKind) Policy {
    return switch (kind) {
        .camera, .microphone, .geolocation, .unknown => .deny,
        .notifications => .{ .ask = "show notifications" },
        .other_sensors => .{ .ask = "use your device's motion sensors" },
        .clipboard_read => .{ .ask = "read the clipboard" },
        .multiple_automatic_downloads => .{ .ask = "download several files" },
        .file_read_write => .{ .ask = "read and change files" },
        .autoplay => .{ .ask = "play media by itself" },
        .local_fonts => .{ .ask = "use your installed fonts" },
        .midi_system_exclusive_messages => .{ .ask = "control your MIDI devices" },
        .window_management => .{ .ask = "manage windows on your displays" },
        .persistent_storage => .{ .ask = "store data permanently" },
        _ => .deny,
    };
}

test permissionPolicy {
    try std.testing.expect(permissionPolicy(.camera) == .deny);
    try std.testing.expect(permissionPolicy(.microphone) == .deny);
    try std.testing.expect(permissionPolicy(.geolocation) == .deny);
    try std.testing.expect(permissionPolicy(@enumFromInt(99)) == .deny);
    try std.testing.expectEqualStrings("show notifications", permissionPolicy(.notifications).ask);
    try std.testing.expectEqualStrings("read the clipboard", permissionPolicy(.clipboard_read).ask);
}

/// Who's asking, as the dialog names it: the host of `uri`, with its
/// port; "This page" for one with none (data:, file:).
pub fn siteOf(uri: []const u16) []const u16 {
    const none = L("This page");
    const colon = std.mem.indexOfScalar(u16, uri, ':') orelse return none;
    if (!std.mem.startsWith(u16, uri[colon..], L("://"))) return none;
    var rest = uri[colon + 3 ..];
    if (std.mem.indexOfAny(u16, rest, L("/?#"))) |end| rest = rest[0..end];
    // Credentials aren't the site.
    if (std.mem.lastIndexOfScalar(u16, rest, '@')) |at| rest = rest[at + 1 ..];
    return if (rest.len == 0) none else rest;
}

test siteOf {
    try std.testing.expectEqualSlices(u16, L("example.com"), siteOf(L("https://example.com/a?b")));
    try std.testing.expectEqualSlices(u16, L("localhost:8080"), siteOf(L("http://user:pw@localhost:8080")));
    try std.testing.expectEqualSlices(u16, L("This page"), siteOf(L("data:text/html,<a href=\"https://example.org/\">")));
    try std.testing.expectEqualSlices(u16, L("This page"), siteOf(L("file:///C:/x.html")));
}

/// What the user made of a permission question: an answer, or none
/// (Escape, the dialog replaced or gone).
pub const Answer = enum { allow, deny, dismiss };

/// The user answered pane `s`'s permission question.
pub fn answer(self: *Web, s: *Session, a: Answer) void {
    _ = self;
    const b = s.browser() orelse return;
    const v = b.view orelse return;
    v.settle(a);
}

/// A drag of pane `s` began (`on`) or ended: make a picture of its page
/// for the dragged pane's, or let it go.
pub fn capture(self: *Web, s: *Session, on: bool) void {
    _ = self;
    const b = s.browser() orelse return;
    const v = b.view orelse return;
    v.want_preview = on;
    if (!on) return Session.Browser.setImage(&b.preview, null);
    if (v.state != .ready or v.preview_stream != null) return;
    const stream = win32.SHCreateMemStream(null, 0) orelse return;
    v.preview_stream = stream;
    com.check(v.webview.?.capturePreview(.png, stream, &v.captured.iface), "ICoreWebView2::CapturePreview") catch {
        com.releaseOpt(&v.preview_stream);
    };
}

/// Close the views hidden longer than `idle_ms` (0: never) at tick
/// `now`: their panes stand in, and open their url again when next
/// placed. One asking a question is kept.
pub fn closeIdle(self: *Web, now: u64, idle_ms: u64) void {
    var i: usize = self.views.items.len;
    while (i > 0) {
        i -= 1;
        const v = self.views.items[i];
        if (v.pending != null) continue;
        const left = idleLeft(v.hidden_at, now, idle_ms) orelse continue;
        if (left > 0) continue;
        log.info("closing pane {d}'s browser, hidden {d} s", .{ v.key, (now - v.hidden_at.?) / 1000 });
        v.shut();
    }
}

/// How long until the first hidden view is idle long enough to close,
/// in ms; null if none will be.
pub fn nextIdle(self: *const Web, now: u64, idle_ms: u64) ?u64 {
    var next: ?u64 = null;
    for (self.views.items) |v| {
        if (v.pending != null) continue;
        const left = idleLeft(v.hidden_at, now, idle_ms) orelse continue;
        next = if (next) |n| @min(n, left) else left;
    }
    return next;
}

/// How long, at tick `now`, until a view hidden at `hidden_at` (null:
/// shown) has been hidden `idle_ms` (0: it never closes), in ms; 0 once
/// it has. Null for never.
pub fn idleLeft(hidden_at: ?u64, now: u64, idle_ms: u64) ?u64 {
    const at = hidden_at orelse return null;
    if (idle_ms == 0) return null;
    const hidden = now -| at;
    return idle_ms -| hidden;
}

test idleLeft {
    // Shown, or idle closing turned off.
    try std.testing.expectEqual(@as(?u64, null), idleLeft(null, 5000, 1000));
    try std.testing.expectEqual(@as(?u64, null), idleLeft(1000, 5000, 0));
    try std.testing.expectEqual(@as(?u64, 600), idleLeft(1000, 1400, 1000));
    try std.testing.expectEqual(@as(?u64, 0), idleLeft(1000, 2000, 1000));
    try std.testing.expectEqual(@as(?u64, 0), idleLeft(1000, 9000, 1000));
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
    var lparam: i32 = 0;
    if (args.getKeyEventKind(&kind) < 0 or args.getVirtualKey(&vk) < 0 or args.getKeyEventLParam(&lparam) < 0) return com.S_OK;
    const msg = wv.keyMessage(kind) orelse return com.S_OK;
    // Ctrl+0 is the page's, as in a browser, back to its own size: the
    // WebView's would go back to the zoom `zoomChanged` kept.
    if (msg == win32.WM_KEYDOWN and (vk == '0' or vk == win32.VK_NUMPAD0)) {
        const m = input.currentMods();
        if (m.ctrl and !m.shift and !m.alt and !m.super) {
            setZoom(self, 1);
            _ = args.putHandled(true);
            return com.S_OK;
        }
    }
    if (self.web.events.key(self.web.events.ctx, msg, vk, lparam)) _ = args.putHandled(true);
    return com.S_OK;
}

/// The user zoomed the page (Ctrl+wheel, Ctrl+plus), which WebView2
/// keeps for the page alone: make it the WebView's, which holds across
/// reloads and navigations, and the pane's, for a view made again.
fn zoomChanged(self: *View, controller: *wv.IController, _: ?*wv.IUnknown) win32.HRESULT {
    var zoom: f64 = 1;
    if (controller.getZoomFactor(&zoom) < 0) return com.S_OK;
    setZoom(self, zoom);
    return com.S_OK;
}

fn setZoom(self: *View, zoom: f64) void {
    if (self.controller) |c| _ = c.putZoomFactor(zoom);
    if (self.browser()) |b| b.zoom = zoom;
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
    if (s.ended or (b.failed != null and b.failed.?.ptr != reconnecting.ptr)) {
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
    const host = hostOf(s);
    const e = self.env(host) catch |err| {
        self.standIn(s, switch (err) {
            error.RuntimeMissing => self.loader.missing,
            error.HostDown => reconnecting,
            else => start_failed,
        });
        return null;
    };
    switch (e.state) {
        .failed => {
            b.failed = start_failed;
            return null;
        },
        .closing, .retired => {
            self.standIn(s, reconnecting);
            return null;
        },
        .creating, .ready => {},
    }
    self.views.ensureUnusedCapacity(self.alloc, 1) catch return null;
    e.waiting.ensureUnusedCapacity(self.alloc, 1) catch return null;
    const v = self.alloc.create(View) catch return null;
    v.* = .{ .web = self, .session = s, .key = s.id, .host = host };
    self.views.appendAssumeCapacity(v);
    b.view = v;
    b.failed = null;
    switch (e.state) {
        .ready => v.create(),
        .creating => {
            _ = v.retain();
            e.waiting.appendAssumeCapacity(v);
        },
        .failed, .closing, .retired => unreachable,
    }
    return b.view;
}

/// The host whose network browser pane `s` browses: its workspace's
/// connection's, 0 for the local daemon's.
fn hostOf(s: *const Session) u32 {
    return switch (s.transport orelse return 0) {
        .daemon => |p| p.conn.host() orelse 0,
        .waiting => 0,
    };
}

/// Leave pane `s` standing in, saying `why`; drawn again once for it, as
/// placing asks again each frame.
fn standIn(self: *Web, s: *Session, why: []const u8) void {
    const b = s.browser() orelse return;
    if (b.failed) |f| if (f.ptr == why.ptr) return;
    b.failed = why;
    self.events.changed(self.events.ctx, s);
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
    followTo(v, b.url);
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
    const v = b.view orelse return;
    const w = v.webview orelse return;
    if (nav == .back or nav == .forward) {
        v.following = .none;
        s.ownNavigation();
    }
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
