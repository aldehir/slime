//! User configuration, in Ghostty's config file syntax and with Ghostty's
//! key names wherever we support the same setting: `key = value` lines,
//! `#` comments on lines of their own, surrounding double quotes stripped
//! from values, and an empty value resetting a key to its default. Bad
//! lines are logged and skipped; there's no UI to report them in yet.
//!
//! Loading follows Ghostty: the main file, each `config-file` after the
//! whole file that names it, then the theme, with everything the user set
//! applied over the theme.
const Config = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const ghostty_vt = @import("ghostty-vt");

const RGB = ghostty_vt.color.RGB;

const log = std.log.scoped(.config);

/// Font families tried in order; the first one installed is used. Empty
/// tries Cascadia Code, Cascadia Mono, Consolas, then Courier New.
@"font-family": std.ArrayList([]const u8) = .empty,
/// In points.
@"font-size": f32 = 12,

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

/// The command to run, CreateProcessW syntax. Our own command line
/// overrides it; with neither, %COMSPEC%.
command: ?[]const u8 = null,

/// A theme name or absolute path, or `light:<theme>,dark:<theme>` to
/// follow the Windows app mode. Names are looked up in `themes` next to
/// the config file, then in `themes` next to the executable.
theme: ?Theme = null,

/// Owns every string and list above.
_arena: std.heap.ArenaAllocator,

pub const Palette = struct {
    colors: ghostty_vt.color.Palette = ghostty_vt.color.default,

    /// `N=COLOR`, setting one entry. Repeatable.
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

    fn parse(alloc: Allocator, value: []const u8) !Theme {
        // A colon at index 1 is a drive letter, not a light/dark pair.
        const colon = if (std.mem.indexOfScalar(u8, value, ':')) |i| i != 1 else false;
        if (!colon and std.mem.indexOfScalar(u8, value, ',') == null) {
            const name = try alloc.dupe(u8, value);
            return .{ .light = name, .dark = name };
        }
        var light: ?[]const u8 = null;
        var dark: ?[]const u8 = null;
        var it = std.mem.splitScalar(u8, value, ',');
        while (it.next()) |part| {
            const sep = std.mem.indexOfScalar(u8, part, ':') orelse return error.InvalidTheme;
            const mode = std.mem.trim(u8, part[0..sep], whitespace);
            const name = try alloc.dupe(u8, std.mem.trim(u8, part[sep + 1 ..], whitespace));
            if (std.mem.eql(u8, mode, "light")) {
                light = name;
            } else if (std.mem.eql(u8, mode, "dark")) {
                dark = name;
            } else return error.InvalidTheme;
        }
        return .{ .light = light orelse return error.InvalidTheme, .dark = dark orelse return error.InvalidTheme };
    }
};

pub const LoadOptions = struct {
    /// Where `config.ghostty` (or `config`) and user themes live. Null
    /// loads nothing but defaults.
    dir: ?[]const u8,
    /// Where the bundled themes live.
    resources_dir: ?[]const u8 = null,
    /// Pick the light theme of a light/dark pair.
    light: bool = false,
};

/// The config directory: `%XDG_CONFIG_HOME%\ghostty-win` if that's set,
/// else `%APPDATA%\ghostty-win`.
pub fn defaultDir(alloc: Allocator, environ: *const std.process.Environ.Map) !?[]u8 {
    const base = environ.get("XDG_CONFIG_HOME") orelse environ.get("APPDATA") orelse return null;
    return try std.fs.path.join(alloc, &.{ base, "ghostty-win" });
}

/// Load the configuration. Missing files aren't an error: everything
/// left unset keeps its default.
pub fn load(gpa: Allocator, io: std.Io, opts: LoadOptions) Allocator.Error!Config {
    var self: Config = .{ ._arena = .init(gpa) };
    errdefer self.deinit();
    const alloc = self._arena.allocator();

    // Ghostty 1.3 renamed `config` to `config.ghostty`; either works.
    var loader: Loader = .{ .alloc = alloc, .io = io };
    if (opts.dir) |dir| {
        const main = try std.fs.path.join(alloc, &.{ dir, "config.ghostty" });
        const legacy = try std.fs.path.join(alloc, &.{ dir, "config" });
        try loader.loadFile(if (fileExists(io, main) or !fileExists(io, legacy)) main else legacy, .optional);
    }
    const user = loader.entries.items;

    if (try themeFor(alloc, user, opts.light)) |name| {
        if (try findTheme(alloc, io, name, opts)) |path| {
            var theme_loader: Loader = .{ .alloc = alloc, .io = io, .theme = true };
            try theme_loader.loadFile(path, .required);
            try self.apply(theme_loader.entries.items);
        } else log.warn("theme \"{s}\" not found", .{name});
    }
    try self.apply(user);
    return self;
}

pub fn deinit(self: *Config) void {
    self._arena.deinit();
    self.* = undefined;
}

/// The theme to load: the last `theme` the user set, resolved to one
/// name.
fn themeFor(alloc: Allocator, entries: []const Entry, light: bool) !?[]const u8 {
    var theme: ?Theme = null;
    for (entries) |e| {
        if (!std.mem.eql(u8, e.key, "theme")) continue;
        theme = if (e.value.len == 0) null else Theme.parse(alloc, e.value) catch continue;
    }
    const t = theme orelse return null;
    return if (light) t.light else t.dark;
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

/// Apply entries in order, logging the ones that don't parse.
fn apply(self: *Config, entries: []const Entry) Allocator.Error!void {
    for (entries) |e| self.set(e.key, e.value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnknownKey => log.warn("{s}:{d}: unknown key \"{s}\"", .{ e.path, e.line, e.key }),
        else => log.warn("{s}:{d}: invalid value for {s}: {}", .{ e.path, e.line, e.key, err }),
    };
}

fn set(self: *Config, key: []const u8, value: []const u8) !void {
    const alloc = self._arena.allocator();
    inline for (@typeInfo(Config).@"struct".fields) |field| {
        if (comptime field.name[0] == '_') continue;
        if (std.mem.eql(u8, key, field.name)) {
            const ptr = &@field(self, field.name);
            if (value.len == 0) {
                ptr.* = field.defaultValue().?;
                return;
            }
            switch (field.type) {
                f32 => ptr.* = try std.fmt.parseFloat(f32, value),
                RGB => ptr.* = try RGB.parse(value),
                ?TerminalColor => ptr.* = try TerminalColor.parse(value),
                ?Theme => ptr.* = try Theme.parse(alloc, value),
                ?[]const u8 => ptr.* = try alloc.dupe(u8, value),
                std.ArrayList([]const u8) => try ptr.append(alloc, try alloc.dupe(u8, value)),
                else => try ptr.parse(alloc, value),
            }
            return;
        }
    }
    return error.UnknownKey;
}

const whitespace = " \t";

const Entry = struct {
    key: []const u8,
    value: []const u8,
    path: []const u8,
    line: u32,
};

/// Reads config files into entries, following `config-file`.
const Loader = struct {
    alloc: Allocator,
    io: std.Io,
    /// Loading a theme, which can't set `theme` or include other files.
    theme: bool = false,
    entries: std.ArrayList(Entry) = .empty,
    /// Every file loaded so far, to refuse cycles.
    loaded: std.ArrayList([]const u8) = .empty,

    fn loadFile(self: *Loader, path: []const u8, need: enum { optional, required }) Allocator.Error!void {
        for (self.loaded.items) |p| if (std.ascii.eqlIgnoreCase(p, path)) {
            log.warn("{s}: already loaded, skipping", .{path});
            return;
        };
        try self.loaded.append(self.alloc, path);

        const text = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.alloc, .limited(1 << 20)) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (!(err == error.FileNotFound and need == .optional)) log.warn("{s}: {}", .{ path, err });
            return;
        };
        log.info("loading {s}", .{path});

        var includes: std.ArrayList([]const u8) = .empty;
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
            const unquoted = if (quoted) value[1 .. value.len - 1] else value;

            if (std.mem.eql(u8, key, "theme") or std.mem.eql(u8, key, "config-file")) {
                if (self.theme) {
                    log.warn("{s}:{d}: themes can't set {s}", .{ path, number, key });
                    continue;
                }
            }
            if (std.mem.eql(u8, key, "config-file")) {
                // A leading ? makes the file optional, unless quoted.
                if (unquoted.len > 0) try includes.append(self.alloc, if (quoted) unquoted else value);
                continue;
            }
            try self.entries.append(self.alloc, .{ .key = key, .value = unquoted, .path = path, .line = number });
        }

        // Included files apply after the whole file naming them.
        const dir = std.fs.path.dirname(path) orelse ".";
        for (includes.items) |include| {
            const optional = include[0] == '?';
            const name = if (optional) include[1..] else include;
            const resolved = if (std.fs.path.isAbsolute(name)) name else try std.fs.path.join(self.alloc, &.{ dir, name });
            try self.loadFile(resolved, if (optional) .optional else .required);
        }
    }
};

/// Parse `text` as the user's config with no files involved.
fn testConfig(text: []const u8) !Config {
    var self: Config = .{ ._arena = .init(std.testing.allocator) };
    errdefer self.deinit();
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        try self.set(std.mem.trim(u8, line[0..eq], whitespace), std.mem.trim(u8, line[eq + 1 ..], whitespace));
    }
    return self;
}

test "colors" {
    var c = try testConfig(
        \\background = #1e1e2e
        \\foreground = cdd6f4
        \\palette = 1=#f38ba8
        \\palette = 15 = white
        \\cursor-color = cell-foreground
        \\selection-background = #345
    );
    defer c.deinit();
    try std.testing.expectEqual(RGB{ .r = 0x1e, .g = 0x1e, .b = 0x2e }, c.background);
    try std.testing.expectEqual(RGB{ .r = 0xcd, .g = 0xd6, .b = 0xf4 }, c.foreground);
    try std.testing.expectEqual(RGB{ .r = 0xf3, .g = 0x8b, .b = 0xa8 }, c.palette.colors[1]);
    try std.testing.expectEqual(RGB{ .r = 0xff, .g = 0xff, .b = 0xff }, c.palette.colors[15]);
    try std.testing.expectEqual(ghostty_vt.color.default[2], c.palette.colors[2]);
    try std.testing.expectEqual(TerminalColor.@"cell-foreground", c.@"cursor-color".?);
    try std.testing.expectEqual(RGB{ .r = 0x33, .g = 0x44, .b = 0x55 }, c.@"selection-background".?.color);
}

test "empty value resets" {
    var c = try testConfig(
        \\background = #000000
        \\palette = 1=#000000
        \\background =
        \\palette =
        \\font-family = A
        \\font-family =
        \\font-family = B
    );
    defer c.deinit();
    try std.testing.expectEqual(RGB{ .r = 0x28, .g = 0x2c, .b = 0x34 }, c.background);
    try std.testing.expectEqual(ghostty_vt.color.default[1], c.palette.colors[1]);
    try std.testing.expectEqual(1, c.@"font-family".items.len);
    try std.testing.expectEqualStrings("B", c.@"font-family".items[0]);
}

test "padding, word chars, theme" {
    var c = try testConfig(
        \\window-padding-x = 2,4
        \\window-padding-y = 6
        \\selection-word-chars = \t;\u{2502}
        \\theme = light: Catppuccin Latte , dark:Catppuccin Mocha
    );
    defer c.deinit();
    try std.testing.expectEqual(Padding{ .top_left = 2, .bottom_right = 4 }, c.@"window-padding-x");
    try std.testing.expectEqual(Padding{ .top_left = 6, .bottom_right = 6 }, c.@"window-padding-y");
    try std.testing.expectEqualSlices(u21, &.{ 0, '\t', ';', 0x2502 }, c.@"selection-word-chars".codepoints);
    try std.testing.expectEqualStrings("Catppuccin Latte", c.theme.?.light);
    try std.testing.expectEqualStrings("Catppuccin Mocha", c.theme.?.dark);

    try std.testing.expectError(error.InvalidTheme, Theme.parse(c._arena.allocator(), "light:A"));
    const path = try Theme.parse(c._arena.allocator(), "C:\\themes\\mine");
    try std.testing.expectEqualStrings("C:\\themes\\mine", path.dark);
}

test "unknown key and bad value" {
    var c: Config = .{ ._arena = .init(std.testing.allocator) };
    defer c.deinit();
    try std.testing.expectError(error.UnknownKey, c.set("font-thicken", "true"));
    try std.testing.expectError(error.InvalidFormat, c.set("background", "nope"));
}

test "load: theme under user settings, config-file after its file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "themes");
    try tmp.dir.writeFile(io, .{ .sub_path = "themes/Dark", .data = "background = #111111\nforeground = #222222\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "themes/Light", .data = "background = #eeeeee\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "config.ghostty", .data =
    \\config-file = extra
    \\config-file = ?missing
    \\theme = light:Light,dark:Dark
    \\foreground = #333333
    \\font-size = 10
    \\
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "extra", .data = "font-size = 14\r\n" });

    const dir = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);

    var dark = try load(std.testing.allocator, io, .{ .dir = dir });
    defer dark.deinit();
    try std.testing.expectEqual(RGB{ .r = 0x11, .g = 0x11, .b = 0x11 }, dark.background);
    try std.testing.expectEqual(RGB{ .r = 0x33, .g = 0x33, .b = 0x33 }, dark.foreground);
    try std.testing.expectEqual(14, dark.@"font-size");

    var light = try load(std.testing.allocator, io, .{ .dir = dir, .light = true });
    defer light.deinit();
    try std.testing.expectEqual(RGB{ .r = 0xee, .g = 0xee, .b = 0xee }, light.background);
}
