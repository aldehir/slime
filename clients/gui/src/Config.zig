//! User configuration: the settings init.lua's `slime.config{...}` set,
//! which the daemon hands every window as one JSON object (config.get).
//! The window takes the keys it understands and warns about the rest;
//! a bad value is logged and keeps its default (there's no UI to report
//! them in yet). The field names are Ghostty's, which the theme files
//! (Ghostty's format, `key = value` lines) still use.
//!
//! ```lua
//! slime.config{
//!   font = { family = { "Cascadia Code", "Consolas" }, size = 12, antialias = "grayscale" },
//!   theme = "Catppuccin Mocha",            -- a file under themes/; or { light = "...", dark = "..." }
//!   colors = { background = "#282c34", foreground = "#ffffff", cursor = "#ffcc00",
//!              cursor_text = "cell-background", selection_background = "#345",
//!              selection_foreground = "cell-foreground", palette = { "#000", "#800" } },
//!   window = { padding = { x = 3, y = { 3, 6 } } },  -- points; a pair is left/top, right/bottom
//!   chrome = { scale = 1 },
//!   selection = { word_chars = " \t'\"" },
//!   clipboard = { read = "ask", write = "allow" },
//!   ssh = { terminfo = true },
//! }
//! ```
//!
//! The theme loads first (`themes` beside init.lua, then beside the
//! executable), and every color the user set applies over it.
const Config = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const ghostty_vt = @import("ghostty-vt");
const font = @import("font/font.zig");

const RGB = ghostty_vt.color.RGB;

const log = std.log.scoped(.config);

/// Font families tried in order; the first one installed is used. Empty
/// tries Cascadia Code, Cascadia Mono, Consolas, then Courier New.
@"font-family": std.ArrayList([]const u8) = .empty,
/// In points.
@"font-size": f32 = 12,
/// `grayscale`, `cleartype` (for RGB-striped displays), or `aliased`, for
/// the terminal's text and the chrome's. The values are Windows
/// Terminal's.
@"font-antialias": font.Antialias = .grayscale,
/// How much larger than the monitor's scale to draw the chrome: the
/// title bar, session list, and dialogs. From 0.5 to 3.
@"chrome-scale": f32 = 1,

/// Ghostty's default colors. Programs can override these with OSC 10/11.
background: RGB = .{ .r = 0x28, .g = 0x2c, .b = 0x34 },
foreground: RGB = .{ .r = 0xff, .g = 0xff, .b = 0xff },
palette: Palette = .{},
/// Null is the foreground color. OSC 12 overrides it.
@"cursor-color": ?TerminalColor = null,
/// The color of text under a block cursor. Null is the cell's background.
@"cursor-text": ?TerminalColor = null,
/// Null for both is the default foreground on the default background,
/// inverted.
@"selection-background": ?TerminalColor = null,
@"selection-foreground": ?TerminalColor = null,

/// In points. Ghostty defaults to 2; 3 keeps our original padding.
@"window-padding-x": Padding = .{ .top_left = 3, .bottom_right = 3 },
@"window-padding-y": Padding = .{ .top_left = 3, .bottom_right = 3 },

/// Characters that end a word for double-click selection. Always
/// includes U+0000.
@"selection-word-chars": WordChars = .{},

/// Whether programs may read the clipboard (OSC 52, OSC 5522). `ask`,
/// Ghostty's default, needs a prompt we don't have yet, so it denies.
@"clipboard-read": ClipboardAccess = .ask,
/// Whether programs may set the clipboard. `ask` denies, as for reads.
@"clipboard-write": ClipboardAccess = .allow,

/// Give SSH sessions TERM=xterm-ghostty, compiling Ghostty's terminfo
/// into ~/.terminfo on hosts that lack it (Ghostty's ssh-terminfo). Hosts
/// it can't be installed on get xterm-256color, as do all with this off.
@"ssh-terminfo": bool = true,

/// A theme name or absolute path, or a light/dark pair to follow the
/// Windows app mode. Names are looked up in `themes` next to init.lua,
/// then in `themes` next to the executable.
theme: ?Theme = null,

/// Owns every string and list above.
_arena: std.heap.ArenaAllocator,

pub const Palette = struct {
    colors: ghostty_vt.color.Palette = ghostty_vt.color.default,

    /// `N=COLOR`, setting one entry (a theme file's line). Repeatable.
    fn parse(self: *Palette, _: Allocator, value: []const u8) !void {
        const entry = try ghostty_vt.color.parsePaletteEntry(value);
        self.colors[entry.index] = entry.color;
    }
};

/// A color, or one of the colors of the cell it applies to.
pub const TerminalColor = union(enum) {
    color: RGB,
    @"cell-foreground",
    @"cell-background",

    fn parse(value: []const u8) !TerminalColor {
        if (std.mem.eql(u8, value, "cell-foreground")) return .@"cell-foreground";
        if (std.mem.eql(u8, value, "cell-background")) return .@"cell-background";
        return .{ .color = try RGB.parse(value) };
    }

    /// The color for a cell drawn in `fg` on `bg`, after any inverse.
    pub fn resolve(self: TerminalColor, fg: RGB, bg: RGB) RGB {
        return switch (self) {
            .color => |c| c,
            .@"cell-foreground" => fg,
            .@"cell-background" => bg,
        };
    }
};

/// Padding on the two sides of one axis: `N`, or `A,B` for left/top then
/// right/bottom.
pub const Padding = struct {
    top_left: u32,
    bottom_right: u32,

    fn parse(self: *Padding, _: Allocator, value: []const u8) !void {
        if (std.mem.indexOfScalar(u8, value, ',')) |comma| {
            self.top_left = try parseUnsigned(value[0..comma]);
            self.bottom_right = try parseUnsigned(value[comma + 1 ..]);
        } else {
            self.top_left = try parseUnsigned(value);
            self.bottom_right = self.top_left;
        }
    }

    fn parseUnsigned(value: []const u8) !u32 {
        return std.fmt.parseInt(u32, std.mem.trim(u8, value, whitespace), 10);
    }

    /// A number, or a pair.
    fn fromJson(self: *Padding, value: std.json.Value) !void {
        switch (value) {
            .integer, .float => {
                self.top_left = try unsignedOf(value);
                self.bottom_right = self.top_left;
            },
            .array => |a| {
                if (a.items.len != 2) return error.InvalidValue;
                self.top_left = try unsignedOf(a.items[0]);
                self.bottom_right = try unsignedOf(a.items[1]);
            },
            else => return error.InvalidValue,
        }
    }
};

pub const ClipboardAccess = enum {
    allow,
    deny,
    ask,
};

pub const WordChars = struct {
    codepoints: []const u21 = &.{ 0, ' ', '\t', '\'', '"', '\u{2502}', '`', '|', ':', ';', ',', '(', ')', '[', ']', '{', '}', '<', '>', '$' },

    /// A string with Zig escapes (`\t`, `\"`, `\u{2502}`).
    fn parse(self: *WordChars, alloc: Allocator, value: []const u8) !void {
        var list: std.ArrayList(u21) = .empty;
        try list.append(alloc, 0);
        var view = try std.unicode.Utf8View.init(value);
        var it = view.iterator();
        while (it.i < value.len) {
            if (value[it.i] == '\\') {
                switch (std.zig.string_literal.parseEscapeSequence(value, &it.i)) {
                    .success => |cp| try list.append(alloc, cp),
                    .failure => return error.InvalidEscape,
                }
            } else {
                try list.append(alloc, it.nextCodepoint().?);
            }
        }
        self.codepoints = list.items;
    }
};

pub const Theme = struct {
    light: []const u8,
    dark: []const u8,

    /// A name, or `{ light = ..., dark = ... }`.
    fn fromJson(alloc: Allocator, value: std.json.Value) !Theme {
        switch (value) {
            .string => |name| {
                const owned = try alloc.dupe(u8, name);
                return .{ .light = owned, .dark = owned };
            },
            .object => |o| {
                const light = o.get("light") orelse return error.InvalidValue;
                const dark = o.get("dark") orelse return error.InvalidValue;
                if (light != .string or dark != .string) return error.InvalidValue;
                return .{ .light = try alloc.dupe(u8, light.string), .dark = try alloc.dupe(u8, dark.string) };
            },
            else => return error.InvalidValue,
        }
    }
};

pub const LoadOptions = struct {
    /// Where init.lua is: its `themes` directory comes first. Null looks
    /// only beside the executable.
    dir: ?[]const u8,
    /// Where the bundled themes live.
    resources_dir: ?[]const u8 = null,
    /// Pick the light theme of a light/dark pair.
    light: bool = false,
};

/// The config directory: `%XDG_CONFIG_HOME%\slime` if that's set,
/// else `%APPDATA%\slime`: where the daemon's init.lua is unless
/// SLIME_CONFIG says otherwise, and where the window keeps its own
/// files (hosts, workspaces).
pub fn defaultDir(alloc: Allocator, environ: *const std.process.Environ.Map) !?[]u8 {
    const base = environ.get("XDG_CONFIG_HOME") orelse environ.get("APPDATA") orelse return null;
    return try std.fs.path.join(alloc, &.{ base, "slime" });
}

/// The defaults alone: what a window uses with no daemon to ask.
pub fn init(gpa: Allocator) Config {
    return .{ ._arena = .init(gpa) };
}

/// Build the config from `settings`, the object the daemon describes
/// init.lua's slime.config with (null or not an object: the defaults).
/// The theme it names loads first; every color it sets applies over it.
pub fn load(gpa: Allocator, io: std.Io, settings: std.json.Value, opts: LoadOptions) Allocator.Error!Config {
    var self: Config = .init(gpa);
    errdefer self.deinit();
    const alloc = self._arena.allocator();
    const root = switch (settings) {
        .object => |o| o,
        .null => return self,
        else => {
            log.warn("settings aren't a table", .{});
            return self;
        },
    };

    if (root.get("theme")) |value| {
        if (Theme.fromJson(alloc, value)) |theme| {
            self.theme = theme;
            const name = if (opts.light) theme.light else theme.dark;
            if (try findTheme(alloc, io, name, opts)) |path| {
                try self.loadTheme(io, path);
            } else log.warn("theme \"{s}\" not found", .{name});
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => log.warn("theme: a name or {{ light, dark }}", .{}),
        }
    }

    var it = root.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        const value = kv.value_ptr.*;
        if (std.mem.eql(u8, key, "theme") or std.mem.eql(u8, key, "shell")) continue; // handled above; the daemon's
        const Section = enum { font, colors, window, chrome, selection, clipboard, ssh };
        const section = std.meta.stringToEnum(Section, key) orelse {
            log.warn("unknown setting \"{s}\"", .{key});
            continue;
        };
        const fields = switch (value) {
            .object => |o| o,
            else => {
                log.warn("{s}: a table is needed", .{key});
                continue;
            },
        };
        var fit = fields.iterator();
        while (fit.next()) |f| {
            const name = f.key_ptr.*;
            self.setJson(alloc, section, name, f.value_ptr.*) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.UnknownKey => log.warn("unknown setting {s}.{s}", .{ key, name }),
                else => log.warn("{s}.{s}: invalid value: {}", .{ key, name, err }),
            };
        }
    }
    return self;
}

pub fn deinit(self: *Config) void {
    self._arena.deinit();
    self.* = undefined;
}

/// Set one setting of a section from its JSON value.
fn setJson(self: *Config, alloc: Allocator, section: anytype, name: []const u8, value: std.json.Value) !void {
    const eql = std.mem.eql;
    switch (section) {
        .font => if (eql(u8, name, "family")) {
            self.@"font-family" = .empty;
            switch (value) {
                .string => |s| try self.@"font-family".append(alloc, try alloc.dupe(u8, s)),
                .array => |a| for (a.items) |item| {
                    if (item != .string) return error.InvalidValue;
                    try self.@"font-family".append(alloc, try alloc.dupe(u8, item.string));
                },
                else => return error.InvalidValue,
            }
        } else if (eql(u8, name, "size")) {
            const size = try floatOf(value);
            if (size <= 0 or size > 200) return error.InvalidValue;
            self.@"font-size" = size;
        } else if (eql(u8, name, "antialias")) {
            self.@"font-antialias" = try enumOf(font.Antialias, value);
        } else return error.UnknownKey,
        .colors => if (eql(u8, name, "background")) {
            self.background = try RGB.parse(try stringOf(value));
        } else if (eql(u8, name, "foreground")) {
            self.foreground = try RGB.parse(try stringOf(value));
        } else if (eql(u8, name, "cursor")) {
            self.@"cursor-color" = try TerminalColor.parse(try stringOf(value));
        } else if (eql(u8, name, "cursor_text")) {
            self.@"cursor-text" = try TerminalColor.parse(try stringOf(value));
        } else if (eql(u8, name, "selection_background")) {
            self.@"selection-background" = try TerminalColor.parse(try stringOf(value));
        } else if (eql(u8, name, "selection_foreground")) {
            self.@"selection-foreground" = try TerminalColor.parse(try stringOf(value));
        } else if (eql(u8, name, "palette")) {
            try self.setPalette(value);
        } else return error.UnknownKey,
        .window => if (eql(u8, name, "padding")) {
            const pad = switch (value) {
                .object => |o| o,
                else => return error.InvalidValue,
            };
            var pit = pad.iterator();
            while (pit.next()) |p| {
                if (eql(u8, p.key_ptr.*, "x")) {
                    try self.@"window-padding-x".fromJson(p.value_ptr.*);
                } else if (eql(u8, p.key_ptr.*, "y")) {
                    try self.@"window-padding-y".fromJson(p.value_ptr.*);
                } else return error.UnknownKey;
            }
        } else return error.UnknownKey,
        .chrome => if (eql(u8, name, "scale")) {
            const scale = try floatOf(value);
            if (scale < 0.5 or scale > 3) return error.InvalidValue;
            self.@"chrome-scale" = scale;
        } else return error.UnknownKey,
        .selection => if (eql(u8, name, "word_chars")) {
            try self.@"selection-word-chars".parse(alloc, try stringOf(value));
        } else return error.UnknownKey,
        .clipboard => if (eql(u8, name, "read")) {
            self.@"clipboard-read" = try enumOf(ClipboardAccess, value);
        } else if (eql(u8, name, "write")) {
            self.@"clipboard-write" = try enumOf(ClipboardAccess, value);
        } else return error.UnknownKey,
        .ssh => if (eql(u8, name, "terminfo")) {
            self.@"ssh-terminfo" = switch (value) {
                .bool => |b| b,
                else => return error.InvalidValue,
            };
        } else return error.UnknownKey,
    }
}

/// The palette: a list of colors from index 0, or a table of index to
/// color.
fn setPalette(self: *Config, value: std.json.Value) !void {
    switch (value) {
        .array => |a| {
            if (a.items.len > self.palette.colors.len) return error.InvalidValue;
            for (a.items, 0..) |item, i| self.palette.colors[i] = try RGB.parse(try stringOf(item));
        },
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |kv| {
                const index = std.fmt.parseInt(u8, kv.key_ptr.*, 10) catch return error.InvalidValue;
                self.palette.colors[index] = try RGB.parse(try stringOf(kv.value_ptr.*));
            }
        },
        else => return error.InvalidValue,
    }
}

fn stringOf(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => error.InvalidValue,
    };
}

fn floatOf(value: std.json.Value) !f32 {
    return switch (value) {
        .integer => |i| @floatFromInt(i),
        .float => |f| @floatCast(f),
        else => error.InvalidValue,
    };
}

fn unsignedOf(value: std.json.Value) !u32 {
    return switch (value) {
        .integer => |i| std.math.cast(u32, i) orelse error.InvalidValue,
        .float => |f| if (f >= 0 and f == @trunc(f) and f <= std.math.maxInt(u32)) @intFromFloat(f) else error.InvalidValue,
        else => error.InvalidValue,
    };
}

fn enumOf(comptime T: type, value: std.json.Value) !T {
    return std.meta.stringToEnum(T, try stringOf(value)) orelse error.InvalidValue;
}

/// An absolute path as is, else the first `themes\<name>` that exists in
/// the config directory, then the resources directory.
fn findTheme(alloc: Allocator, io: std.Io, name: []const u8, opts: LoadOptions) !?[]const u8 {
    if (std.fs.path.isAbsolute(name)) return name;
    if (std.mem.indexOfAny(u8, name, "/\\") != null) {
        log.warn("theme \"{s}\" must be a name or an absolute path", .{name});
        return null;
    }
    for ([_]?[]const u8{ opts.dir, opts.resources_dir }) |dir| {
        const path = try std.fs.path.join(alloc, &.{ dir orelse continue, "themes", name });
        if (fileExists(io, path)) return path;
    }
    return null;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Read a theme file, Ghostty's format: `key = value` lines, `#`
/// comments on lines of their own, surrounding double quotes stripped
/// from values. Only the color keys apply; the rest are logged.
fn loadTheme(self: *Config, io: std.Io, path: []const u8) Allocator.Error!void {
    const alloc = self._arena.allocator();
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 20)) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        log.warn("{s}: {}", .{ path, err });
        return;
    };
    log.info("loading theme {s}", .{path});
    try self.applyTheme(text, path);
}

fn applyTheme(self: *Config, text: []const u8, path: []const u8) Allocator.Error!void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var number: u32 = 0;
    while (lines.next()) |raw| {
        number += 1;
        const line = std.mem.trim(u8, raw, whitespace ++ "\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            log.warn("{s}:{d}: expected key = value", .{ path, number });
            continue;
        };
        const key = std.mem.trim(u8, line[0..eq], whitespace);
        const value = std.mem.trim(u8, line[eq + 1 ..], whitespace);
        const quoted = value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"';
        self.setThemeKey(key, if (quoted) value[1 .. value.len - 1] else value) catch |err| switch (err) {
            error.UnknownKey => log.warn("{s}:{d}: themes set colors only, not \"{s}\"", .{ path, number, key }),
            else => log.warn("{s}:{d}: invalid value for {s}: {}", .{ path, number, key, err }),
        };
    }
}

/// The keys a theme file may set, by their Ghostty names: the colors.
/// An empty value resets one to its default.
fn setThemeKey(self: *Config, key: []const u8, value: []const u8) !void {
    const alloc = self._arena.allocator();
    inline for (@typeInfo(Config).@"struct".fields) |field| {
        if (comptime themeKey(field.name)) {
            if (std.mem.eql(u8, key, field.name)) {
                const ptr = &@field(self, field.name);
                if (value.len == 0) {
                    ptr.* = field.defaultValue().?;
                    return;
                }
                switch (field.type) {
                    RGB => ptr.* = try RGB.parse(value),
                    ?TerminalColor => ptr.* = try TerminalColor.parse(value),
                    else => try ptr.parse(alloc, value),
                }
                return;
            }
        }
    }
    return error.UnknownKey;
}

fn themeKey(comptime name: []const u8) bool {
    for ([_][]const u8{ "background", "foreground", "palette", "cursor-color", "cursor-text", "selection-background", "selection-foreground" }) |k| {
        if (std.mem.eql(u8, name, k)) return true;
    }
    return false;
}

const whitespace = " \t";

/// Parse `text` as the settings object, with no files involved.
fn testConfig(text: []const u8) !Config {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
    defer parsed.deinit();
    return load(std.testing.allocator, std.testing.io, parsed.value, .{ .dir = null });
}

test "colors and fonts" {
    var c = try testConfig(
        \\{"font": {"family": ["A", "B"], "size": 10.5, "antialias": "cleartype"},
        \\ "colors": {"background": "#1e1e2e", "foreground": "cdd6f4", "palette": {"1": "#f38ba8", "15": "white"},
        \\            "cursor": "cell-foreground", "selection_background": "#345"},
        \\ "shell": {"command": "pwsh"}}
    );
    defer c.deinit();
    try std.testing.expectEqual(2, c.@"font-family".items.len);
    try std.testing.expectEqualStrings("B", c.@"font-family".items[1]);
    try std.testing.expectEqual(10.5, c.@"font-size");
    try std.testing.expectEqual(.cleartype, c.@"font-antialias");
    try std.testing.expectEqual(RGB{ .r = 0x1e, .g = 0x1e, .b = 0x2e }, c.background);
    try std.testing.expectEqual(RGB{ .r = 0xcd, .g = 0xd6, .b = 0xf4 }, c.foreground);
    try std.testing.expectEqual(RGB{ .r = 0xf3, .g = 0x8b, .b = 0xa8 }, c.palette.colors[1]);
    try std.testing.expectEqual(RGB{ .r = 0xff, .g = 0xff, .b = 0xff }, c.palette.colors[15]);
    try std.testing.expectEqual(ghostty_vt.color.default[2], c.palette.colors[2]);
    try std.testing.expectEqual(TerminalColor.@"cell-foreground", c.@"cursor-color".?);
    try std.testing.expectEqual(RGB{ .r = 0x33, .g = 0x44, .b = 0x55 }, c.@"selection-background".?.color);

    var list = try testConfig(
        \\{"font": {"family": "Consolas"}, "colors": {"palette": ["#000000", "#111111"]}}
    );
    defer list.deinit();
    try std.testing.expectEqualStrings("Consolas", list.@"font-family".items[0]);
    try std.testing.expectEqual(RGB{ .r = 0x11, .g = 0x11, .b = 0x11 }, list.palette.colors[1]);
    try std.testing.expectEqual(ghostty_vt.color.default[2], list.palette.colors[2]);
}

test "padding, word chars, theme, clipboard, and bad values keep defaults" {
    var c = try testConfig(
        \\{"window": {"padding": {"x": [2, 4], "y": 6}},
        \\ "selection": {"word_chars": "\\t;\\u{2502}"},
        \\ "theme": {"light": "Catppuccin Latte", "dark": "Catppuccin Mocha"},
        \\ "clipboard": {"write": "deny"}, "chrome": {"scale": 1.25}, "ssh": {"terminfo": false},
        \\ "font": {"size": -1, "antialias": "subpixel", "weight": 3}, "colors": {"background": "nope"}, "nonsense": 1}
    );
    defer c.deinit();
    try std.testing.expectEqual(Padding{ .top_left = 2, .bottom_right = 4 }, c.@"window-padding-x");
    try std.testing.expectEqual(Padding{ .top_left = 6, .bottom_right = 6 }, c.@"window-padding-y");
    try std.testing.expectEqualSlices(u21, &.{ 0, '\t', ';', 0x2502 }, c.@"selection-word-chars".codepoints);
    try std.testing.expectEqualStrings("Catppuccin Latte", c.theme.?.light);
    try std.testing.expectEqualStrings("Catppuccin Mocha", c.theme.?.dark);
    try std.testing.expectEqual(.ask, c.@"clipboard-read");
    try std.testing.expectEqual(.deny, c.@"clipboard-write");
    try std.testing.expectEqual(1.25, c.@"chrome-scale");
    try std.testing.expect(!c.@"ssh-terminfo");
    try std.testing.expectEqual(12, c.@"font-size");
    try std.testing.expectEqual(.grayscale, c.@"font-antialias");
    try std.testing.expectEqual(RGB{ .r = 0x28, .g = 0x2c, .b = 0x34 }, c.background);

    var none = try testConfig("null");
    defer none.deinit();
    try std.testing.expectEqual(12, none.@"font-size");
}

test "theme under user colors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "themes");
    try tmp.dir.writeFile(io, .{ .sub_path = "themes/Dark", .data = "# a theme\nbackground = #111111\nforeground = #222222\npalette = 3=#333333\ncursor-color = #444444\nfont-size = 9\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "themes/Light", .data = "background = \"#eeeeee\"\n" });
    const dir = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"theme": {"light": "Light", "dark": "Dark"}, "colors": {"foreground": "#333333"}, "font": {"size": 14}}
    , .{});
    defer parsed.deinit();
    var dark = try load(std.testing.allocator, io, parsed.value, .{ .dir = dir });
    defer dark.deinit();
    try std.testing.expectEqual(RGB{ .r = 0x11, .g = 0x11, .b = 0x11 }, dark.background);
    try std.testing.expectEqual(RGB{ .r = 0x33, .g = 0x33, .b = 0x33 }, dark.foreground);
    try std.testing.expectEqual(RGB{ .r = 0x33, .g = 0x33, .b = 0x33 }, dark.palette.colors[3]);
    try std.testing.expectEqual(RGB{ .r = 0x44, .g = 0x44, .b = 0x44 }, dark.@"cursor-color".?.color);
    try std.testing.expectEqual(14, dark.@"font-size");

    var light = try load(std.testing.allocator, io, parsed.value, .{ .dir = dir, .light = true });
    defer light.deinit();
    try std.testing.expectEqual(RGB{ .r = 0xee, .g = 0xee, .b = 0xee }, light.background);
}
