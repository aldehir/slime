//! Key bindings: which key presses run an app action instead of going to
//! the child. Actions take Ghostty's names, which init.lua's slime.bind
//! uses to rebind them. Triggers are virtual keys, which follow the
//! keyboard layout (VK_OEM_PLUS is whichever key types '+'), parsed from
//! chords such as "ctrl+shift+d".

const std = @import("std");
const Allocator = std.mem.Allocator;
const ghostty_vt = @import("ghostty-vt");
const win32 = @import("win32/win32.zig");

const log = std.log.scoped(.binding);

const Mods = ghostty_vt.input.KeyMods;

pub const Action = union(enum) {
    copy_to_clipboard,
    paste_from_clipboard,
    new_tab,
    close_surface,
    next_tab,
    previous_tab,
    /// In points.
    increase_font_size: f32,
    decrease_font_size: f32,
    reset_font_size,
    new_split: SplitDirection,
    goto_split: GotoSplit,
    /// By `amount` cells.
    resize_split: ResizeSplit,
    equalize_splits,
    toggle_split_zoom,
    /// Open the command palette, or close it.
    toggle_command_palette,
    /// A function init.lua bound, which the daemon runs
    /// (action.invoke{lua}) for the focused pane.
    lua: u32,
    /// An action init.lua defined, which the daemon runs by name with
    /// args (a JSON object, or empty) for the focused pane.
    invoke: Invoke,
};

pub const SplitDirection = enum { right, down, left, up };

pub const GotoSplit = enum { previous, next, up, left, down, right };

pub const ResizeSplit = struct {
    direction: SplitDirection,
    amount: u16,
};

pub const Invoke = struct {
    name: []const u8,
    args: []const u8 = "",
};

pub const Trigger = struct {
    vk: u32,
    mods: Mods.Keys = .{},

    pub fn eql(a: Trigger, b: Trigger) bool {
        return a.vk == b.vk and a.mods.int() == b.mods.int();
    }
};

pub const Binding = struct {
    /// The key that runs the action: the last of a sequence.
    trigger: Trigger,
    /// The keys pressed before it, for a sequence such as "ctrl+b>c".
    prefix: []const Trigger = &.{},
    action: Action,
    /// The key goes to the child when the action can't run (copy with no
    /// selection), Ghostty's `performable:` prefix.
    performable: bool = false,
    /// Once run, the sequence's earlier keys stay pressed, so its last
    /// key again runs it again (tmux's `bind -r`), until the window's
    /// timer runs out or a key that isn't a repeat ends it. Nothing
    /// without a prefix: a key alone repeats as it's held.
    repeat: bool = false,
    /// init.lua's, not a default: named ahead of the defaults.
    user: bool = false,

    /// Whether `prefix` then `trigger` are `keys`.
    fn matches(b: Binding, keys: []const Trigger) bool {
        if (keys.len != b.prefix.len + 1) return false;
        for (b.prefix, keys[0..b.prefix.len]) |p, k| if (!p.eql(k)) return false;
        return b.trigger.eql(keys[b.prefix.len]);
    }

    /// Whether `keys` are the first keys of the binding's, which then
    /// goes on.
    fn startsWith(b: Binding, keys: []const Trigger) bool {
        if (keys.len > b.prefix.len) return false;
        for (b.prefix[0..keys.len], keys) |p, k| if (!p.eql(k)) return false;
        return true;
    }
};

const ctrl: Mods.Keys = .{ .ctrl = true };
const shift: Mods.Keys = .{ .shift = true };
const ctrl_shift: Mods.Keys = .{ .ctrl = true, .shift = true };
const ctrl_alt: Mods.Keys = .{ .ctrl = true, .alt = true };
const ctrl_alt_shift: Mods.Keys = .{ .ctrl = true, .alt = true, .shift = true };

/// Ghostty's defaults where it has them.
pub const defaults = [_]Binding{
    .{ .trigger = .{ .vk = 'C', .mods = ctrl_shift }, .action = .copy_to_clipboard, .performable = true },
    .{ .trigger = .{ .vk = win32.VK_INSERT, .mods = ctrl }, .action = .copy_to_clipboard },
    .{ .trigger = .{ .vk = 'V', .mods = ctrl_shift }, .action = .paste_from_clipboard, .performable = true },
    .{ .trigger = .{ .vk = win32.VK_INSERT, .mods = shift }, .action = .paste_from_clipboard },
    .{ .trigger = .{ .vk = 'T', .mods = ctrl_shift }, .action = .new_tab },
    .{ .trigger = .{ .vk = 'W', .mods = ctrl_shift }, .action = .close_surface },
    .{ .trigger = .{ .vk = win32.VK_TAB, .mods = ctrl }, .action = .next_tab },
    .{ .trigger = .{ .vk = win32.VK_TAB, .mods = ctrl_shift }, .action = .previous_tab },
    .{ .trigger = .{ .vk = win32.VK_NEXT, .mods = ctrl }, .action = .next_tab },
    .{ .trigger = .{ .vk = win32.VK_PRIOR, .mods = ctrl }, .action = .previous_tab },
    .{ .trigger = .{ .vk = win32.VK_OEM_PLUS, .mods = ctrl_shift }, .action = .{ .increase_font_size = 1 } },
    .{ .trigger = .{ .vk = win32.VK_OEM_MINUS, .mods = ctrl_shift }, .action = .{ .decrease_font_size = 1 } },
    .{ .trigger = .{ .vk = '0', .mods = ctrl_shift }, .action = .reset_font_size },
    // Windows' default input language hotkeys take ctrl+shift+0 (direct
    // switch to the Japanese IME), so it never arrives on most machines.
    .{ .trigger = .{ .vk = '0', .mods = ctrl }, .action = .reset_font_size },
    // Only slime's tabs split; elsewhere the keys go to the child.
    .{ .trigger = .{ .vk = 'O', .mods = ctrl_shift }, .action = .{ .new_split = .right }, .performable = true },
    .{ .trigger = .{ .vk = 'E', .mods = ctrl_shift }, .action = .{ .new_split = .down }, .performable = true },
    .{ .trigger = .{ .vk = win32.VK_RETURN, .mods = ctrl_shift }, .action = .toggle_split_zoom, .performable = true },
    .{ .trigger = .{ .vk = win32.VK_UP, .mods = ctrl_alt }, .action = .{ .goto_split = .up }, .performable = true },
    .{ .trigger = .{ .vk = win32.VK_DOWN, .mods = ctrl_alt }, .action = .{ .goto_split = .down }, .performable = true },
    .{ .trigger = .{ .vk = win32.VK_LEFT, .mods = ctrl_alt }, .action = .{ .goto_split = .left }, .performable = true },
    .{ .trigger = .{ .vk = win32.VK_RIGHT, .mods = ctrl_alt }, .action = .{ .goto_split = .right }, .performable = true },
    // Ghostty's ctrl+super chords are the shell's on Windows (ctrl+win+
    // arrows switch desktops), so these take ctrl+shift and ctrl+alt+shift.
    .{ .trigger = .{ .vk = win32.VK_OEM_4, .mods = ctrl_shift }, .action = .{ .goto_split = .previous }, .performable = true },
    .{ .trigger = .{ .vk = win32.VK_OEM_6, .mods = ctrl_shift }, .action = .{ .goto_split = .next }, .performable = true },
    .{ .trigger = .{ .vk = win32.VK_UP, .mods = ctrl_alt_shift }, .action = .{ .resize_split = .{ .direction = .up, .amount = 1 } }, .performable = true },
    .{ .trigger = .{ .vk = win32.VK_DOWN, .mods = ctrl_alt_shift }, .action = .{ .resize_split = .{ .direction = .down, .amount = 1 } }, .performable = true },
    .{ .trigger = .{ .vk = win32.VK_LEFT, .mods = ctrl_alt_shift }, .action = .{ .resize_split = .{ .direction = .left, .amount = 1 } }, .performable = true },
    .{ .trigger = .{ .vk = win32.VK_RIGHT, .mods = ctrl_alt_shift }, .action = .{ .resize_split = .{ .direction = .right, .amount = 1 } }, .performable = true },
    .{ .trigger = .{ .vk = win32.VK_OEM_PLUS, .mods = ctrl_alt_shift }, .action = .equalize_splits, .performable = true },
    .{ .trigger = .{ .vk = 'P', .mods = ctrl_shift }, .action = .toggle_command_palette },
};

/// The binding for a key pressed with `mods`, with no sequence under
/// way. Lock keys and sides don't matter.
pub fn findIn(bindings: []const Binding, vk: u32, mods: Mods) ?Binding {
    const key: Trigger = .{ .vk = vk, .mods = mods.keys() };
    for (bindings) |b| {
        if (b.prefix.len == 0 and b.trigger.eql(key)) return b;
    }
    return null;
}

/// The most keys in a sequence.
pub const max_keys = 8;

/// What a key press does to the keymap (`Keymap.press`).
pub const Press = union(enum) {
    /// Not bound: the key goes on to whoever's next.
    none,
    /// The last key of a sequence, or a key bound alone: run it.
    binding: Binding,
    /// A sequence is under way: the key is kept, and the next one looked
    /// up after it.
    pending,
    /// The key isn't in the sequence under way, which it ends; neither it
    /// nor the keys before it go on.
    cancelled,
};

/// A binding as the daemon's keymap lists it (rpc.Binding): the chord,
/// and a window action by name with args (JSON), a config action to
/// invoke, or a function to run by id; none of them unbinds the key.
pub const Entry = struct {
    key: []const u8,
    action: []const u8 = "",
    args: []const u8 = "",
    lua: u32 = 0,
    repeat: bool = false,
};

/// The bindings in force: the defaults, with init.lua's over them; and
/// the sequence under way, if a key that starts one was pressed.
pub const Keymap = struct {
    arena: std.heap.ArenaAllocator,
    /// In the arena, as are the strings the actions hold.
    bindings: std.ArrayList(Binding) = .empty,
    /// The keys of a sequence pressed so far.
    pending_buf: [max_keys]Trigger = undefined,
    pending_len: usize = 0,
    /// The pending keys are a repeatable binding's prefix, kept after it
    /// ran: the window ends that when its timer runs out.
    repeating: bool = false,

    /// The defaults alone.
    pub fn init(gpa: Allocator) Allocator.Error!Keymap {
        var self: Keymap = .{ .arena = .init(gpa) };
        try self.apply(&.{});
        return self;
    }

    pub fn deinit(self: *Keymap) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Start from the defaults again and apply `entries` in order: each
    /// replaces the binding of its keys, or adds one; one with nothing to
    /// run removes it. A key runs an action or starts a sequence, never
    /// both, so a binding also replaces the ones its keys start, and the
    /// ones that start it, as Rex's do. An entry that doesn't parse is
    /// logged and skipped. A sequence under way ends.
    pub fn apply(self: *Keymap, entries: []const Entry) Allocator.Error!void {
        _ = self.arena.reset(.retain_capacity);
        self.bindings = .empty;
        self.cancel();
        const a = self.arena.allocator();
        try self.bindings.appendSlice(a, &defaults);
        for (entries) |e| {
            var buf: [max_keys]Trigger = undefined;
            const keys = parseSequence(&buf, e.key) catch |err| {
                log.warn("binding \"{s}\": {}", .{ e.key, err });
                continue;
            };
            const unbind = e.lua == 0 and e.action.len == 0;
            var i: usize = 0;
            while (i < self.bindings.items.len) {
                const old = self.bindings.items[i];
                const same = old.matches(keys);
                // The old one never runs once these keys are bound: an
                // action where a sequence now begins, or a sequence
                // whose first keys now act. An unbind takes exactly its
                // keys: "ctrl+b" leaves "ctrl+b>c" bound.
                const hidden = !unbind and (old.startsWith(keys) or
                    (old.prefix.len + 1 < keys.len and old.matches(keys[0 .. old.prefix.len + 1])));
                if (same or hidden) {
                    if (hidden) log.warn("binding \"{s}\" hides {s}, bound {f}", .{ e.key, @tagName(old.action), fmtKeys(old) });
                    _ = self.bindings.orderedRemove(i);
                } else i += 1;
            }
            const action = try actionOf(a, e) orelse continue;
            try self.bindings.append(a, .{
                .trigger = keys[keys.len - 1],
                .prefix = try a.dupe(Trigger, keys[0 .. keys.len - 1]),
                .action = action,
                .repeat = e.repeat,
                .user = true,
            });
        }
    }

    /// A key went down with `mods`: what it does, given the sequence
    /// under way. A press that's `.none` leaves a sequence as it was, so
    /// a modifier going down on its own doesn't end one (ctrl+b then c
    /// is pressed as ctrl, b, c).
    pub fn press(self: *Keymap, vk: u32, mods: Mods) Press {
        const key: Trigger = .{ .vk = vk, .mods = mods.keys() };
        if (self.pending_len == max_keys) {
            self.cancel();
            return .cancelled;
        }
        self.pending_buf[self.pending_len] = key;
        const keys = self.pending_buf[0 .. self.pending_len + 1];
        var starts_one = false;
        for (self.bindings.items) |b| {
            if (b.matches(keys)) {
                // A repeatable binding's prefix stays pressed, so its key
                // again runs it again.
                self.repeating = b.repeat and b.prefix.len > 0;
                self.pending_len = if (self.repeating) b.prefix.len else 0;
                return .{ .binding = b };
            }
            if (b.startsWith(keys)) starts_one = true;
        }
        if (starts_one) {
            self.pending_len += 1;
            self.repeating = false;
            return .pending;
        }
        if (self.pending_len == 0) return .none;
        // A key that's no repeat ends the repeat, and then does what it
        // does on its own: only the keys of a sequence typed out are
        // owed.
        const was_repeating = self.repeating;
        self.cancel();
        if (was_repeating) return self.press(vk, mods);
        return .cancelled;
    }

    /// The keys of the sequence under way, if one is.
    pub fn pending(self: *const Keymap) []const Trigger {
        return self.pending_buf[0..self.pending_len];
    }

    /// Whether the keys under way are a repeatable binding's, kept after
    /// it ran.
    pub fn isRepeating(self: *const Keymap) bool {
        return self.repeating;
    }

    /// End the sequence under way: Escape, or the focus going.
    pub fn cancel(self: *Keymap) void {
        self.pending_len = 0;
        self.repeating = false;
    }

    pub fn find(self: *const Keymap, vk: u32, mods: Mods) ?Binding {
        return findIn(self.bindings.items, vk, mods);
    }

    pub fn label(self: *const Keymap, action: Action) Label {
        return labelIn(self.bindings.items, action);
    }
};

/// What an entry runs, in `a`: a window action by name, else a config
/// action to invoke by that name; null for an unbind.
fn actionOf(a: Allocator, e: Entry) Allocator.Error!?Action {
    if (e.lua != 0) return .{ .lua = e.lua };
    if (e.action.len == 0) return null;
    var args: ?std.json.Value = null;
    if (e.args.len > 0) {
        args = std.json.parseFromSliceLeaky(std.json.Value, a, e.args, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => blk: {
                log.warn("binding \"{s}\": args aren't JSON: {}", .{ e.key, err });
                break :blk null;
            },
        };
    }
    if (fromName(e.action, args)) |action| return action;
    return .{ .invoke = .{ .name = try a.dupe(u8, e.action), .args = try a.dupe(u8, e.args) } };
}

/// The window action called `name`, with its payload from `args`
/// (direction, amount), or null if the name is no window action's.
pub fn fromName(name: []const u8, args: ?std.json.Value) ?Action {
    const tag = std.meta.stringToEnum(std.meta.Tag(Action), name) orelse return null;
    return switch (tag) {
        .copy_to_clipboard => .copy_to_clipboard,
        .paste_from_clipboard => .paste_from_clipboard,
        .new_tab => .new_tab,
        .close_surface => .close_surface,
        .next_tab => .next_tab,
        .previous_tab => .previous_tab,
        .reset_font_size => .reset_font_size,
        .equalize_splits => .equalize_splits,
        .toggle_split_zoom => .toggle_split_zoom,
        .toggle_command_palette => .toggle_command_palette,
        .increase_font_size => .{ .increase_font_size = argNumber(args, "amount", 1) },
        .decrease_font_size => .{ .decrease_font_size = argNumber(args, "amount", 1) },
        .new_split => .{ .new_split = argEnum(SplitDirection, args, "direction", .right) },
        .goto_split => .{ .goto_split = argEnum(GotoSplit, args, "direction", .next) },
        .resize_split => .{ .resize_split = .{
            .direction = argEnum(SplitDirection, args, "direction", .right),
            .amount = @intFromFloat(@max(1, @min(1000, argNumber(args, "amount", 1)))),
        } },
        .lua, .invoke => null,
    };
}

fn argValue(args: ?std.json.Value, key: []const u8) ?std.json.Value {
    const obj = args orelse return null;
    return switch (obj) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn argNumber(args: ?std.json.Value, key: []const u8, default: f32) f32 {
    return switch (argValue(args, key) orelse return default) {
        .integer => |i| @floatFromInt(i),
        .float => |f| @floatCast(f),
        else => default,
    };
}

fn argEnum(comptime T: type, args: ?std.json.Value, key: []const u8, default: T) T {
    return switch (argValue(args, key) orelse return default) {
        .string => |s| std.meta.stringToEnum(T, s) orelse default,
        else => default,
    };
}

pub const ParseError = error{ NoKey, TwoKeys, UnknownKey, TooManyKeys };

/// A key, or a sequence of them joined by `>` ("ctrl+b>c"), as init.lua
/// writes it, into `buf`: the keys, in order.
pub fn parseSequence(buf: *[max_keys]Trigger, chord: []const u8) ParseError![]Trigger {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, chord, '>');
    while (it.next()) |key| {
        if (n == max_keys) return error.TooManyKeys;
        buf[n] = try parse(key);
        n += 1;
    }
    return buf[0..n];
}

/// A chord as init.lua writes it: modifiers (ctrl, shift, alt, super),
/// then a key, joined by `+`; case and spaces don't matter. A key is a
/// letter, a digit, a punctuation mark or its name (plus, minus, comma,
/// period, slash, backslash, semicolon, apostrophe, bracketleft,
/// bracketright, grave), or one of tab, enter, escape, space,
/// backspace, delete, insert, home, end, pageup, pagedown, up, down,
/// left, right, f1 to f24.
pub fn parse(chord: []const u8) ParseError!Trigger {
    var t: Trigger = .{ .vk = 0 };
    if (chord.len == 0) return error.NoKey;
    var it = std.mem.splitScalar(u8, chord, '+');
    while (it.next()) |raw| {
        var buf: [16]u8 = undefined;
        const trimmed = std.mem.trim(u8, raw, " \t");
        if (trimmed.len > buf.len) return error.UnknownKey;
        const part = std.ascii.lowerString(&buf, trimmed);
        if (part.len == 0) {
            // "ctrl++" splits as "ctrl", "", "": the plus key, named by
            // the two empty parts that end it.
            if (it.peek() == null and std.mem.endsWith(u8, chord, "++")) {
                if (t.vk != 0) return error.TwoKeys;
                t.vk = win32.VK_OEM_PLUS;
                continue;
            }
            if (it.peek() != null and it.peek().?.len == 0 and std.mem.endsWith(u8, chord, "++")) continue;
            return error.UnknownKey;
        }
        if (std.mem.eql(u8, part, "ctrl") or std.mem.eql(u8, part, "control")) {
            t.mods.ctrl = true;
        } else if (std.mem.eql(u8, part, "shift")) {
            t.mods.shift = true;
        } else if (std.mem.eql(u8, part, "alt") or std.mem.eql(u8, part, "option")) {
            t.mods.alt = true;
        } else if (std.mem.eql(u8, part, "super") or std.mem.eql(u8, part, "win") or std.mem.eql(u8, part, "cmd") or std.mem.eql(u8, part, "meta")) {
            t.mods.super = true;
        } else {
            if (t.vk != 0) return error.TwoKeys;
            t.vk = keyVk(part) orelse return error.UnknownKey;
        }
    }
    if (t.vk == 0) return error.NoKey;
    return t;
}

/// The virtual key named `name`, lower case.
fn keyVk(name: []const u8) ?u32 {
    if (name.len == 1) return switch (name[0]) {
        'a'...'z' => |c| c - 'a' + 'A',
        '0'...'9' => |c| c,
        '-' => win32.VK_OEM_MINUS,
        '=' => win32.VK_OEM_PLUS,
        ',' => win32.VK_OEM_COMMA,
        '.' => win32.VK_OEM_PERIOD,
        '/' => win32.VK_OEM_2,
        '`' => win32.VK_OEM_3,
        '[' => win32.VK_OEM_4,
        '\\' => win32.VK_OEM_5,
        ']' => win32.VK_OEM_6,
        ';' => win32.VK_OEM_1,
        '\'' => win32.VK_OEM_7,
        else => null,
    };
    if (name.len >= 2 and name[0] == 'f') {
        if (std.fmt.parseUnsigned(u8, name[1..], 10)) |n| {
            if (n >= 1 and n <= 24) return win32.VK_F1 + n - 1;
        } else |_| {}
    }
    const names = std.StaticStringMap(u32).initComptime(.{
        .{ "tab", win32.VK_TAB },
        .{ "enter", win32.VK_RETURN },
        .{ "return", win32.VK_RETURN },
        .{ "escape", win32.VK_ESCAPE },
        .{ "esc", win32.VK_ESCAPE },
        .{ "space", win32.VK_SPACE },
        .{ "backspace", win32.VK_BACK },
        .{ "delete", win32.VK_DELETE },
        .{ "del", win32.VK_DELETE },
        .{ "insert", win32.VK_INSERT },
        .{ "ins", win32.VK_INSERT },
        .{ "home", win32.VK_HOME },
        .{ "end", win32.VK_END },
        .{ "pageup", win32.VK_PRIOR },
        .{ "page_up", win32.VK_PRIOR },
        .{ "prior", win32.VK_PRIOR },
        .{ "pagedown", win32.VK_NEXT },
        .{ "page_down", win32.VK_NEXT },
        .{ "next", win32.VK_NEXT },
        .{ "up", win32.VK_UP },
        .{ "down", win32.VK_DOWN },
        .{ "left", win32.VK_LEFT },
        .{ "right", win32.VK_RIGHT },
        .{ "plus", win32.VK_OEM_PLUS },
        .{ "equal", win32.VK_OEM_PLUS },
        .{ "equals", win32.VK_OEM_PLUS },
        .{ "minus", win32.VK_OEM_MINUS },
        .{ "comma", win32.VK_OEM_COMMA },
        .{ "period", win32.VK_OEM_PERIOD },
        .{ "slash", win32.VK_OEM_2 },
        .{ "backslash", win32.VK_OEM_5 },
        .{ "semicolon", win32.VK_OEM_1 },
        .{ "apostrophe", win32.VK_OEM_7 },
        .{ "quote", win32.VK_OEM_7 },
        .{ "bracketleft", win32.VK_OEM_4 },
        .{ "bracketright", win32.VK_OEM_6 },
        .{ "grave", win32.VK_OEM_3 },
        .{ "backquote", win32.VK_OEM_3 },
    });
    return names.get(name);
}

/// A key's name for a hint, e.g. "Ctrl+Shift+T", or a sequence's,
/// "Ctrl+B, C".
pub const Label = struct {
    buf: [64]u16 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Label) []const u16 {
        return self.buf[0..self.len];
    }

    /// False, with nothing added, if `text` doesn't fit.
    fn append(self: *Label, text: []const u8) bool {
        if (self.len + text.len > self.buf.len) return false;
        for (text) |c| {
            self.buf[self.len] = c;
            self.len += 1;
        }
        return true;
    }
};

/// The keys that run `action`, named: the last init.lua bound to it,
/// else the first default. Empty if none does or a key has no name
/// here.
pub fn labelIn(bindings: []const Binding, action: Action) Label {
    var found: ?Binding = null;
    for (bindings) |b| {
        if (!std.meta.eql(b.action, action)) continue;
        if (found == null or b.user) found = b;
    }
    const b = found orelse return .{};
    var out: Label = .{};
    for (b.prefix) |key| {
        if (!labelKey(&out, key) or !out.append(", ")) return .{};
    }
    if (!labelKey(&out, b.trigger)) return .{};
    return out;
}

/// Add `key`'s name to `out`. False if it has none here, or doesn't fit.
fn labelKey(out: *Label, key: Trigger) bool {
    var key_buf: [3]u8 = undefined;
    const name: []const u8 = switch (key.vk) {
        'A'...'Z', '0'...'9' => |vk| key: {
            key_buf[0] = @intCast(vk);
            break :key key_buf[0..1];
        },
        win32.VK_F1...win32.VK_F1 + 23 => |vk| std.fmt.bufPrint(&key_buf, "F{d}", .{vk - win32.VK_F1 + 1}) catch unreachable,
        win32.VK_TAB => "Tab",
        win32.VK_RETURN => "Enter",
        win32.VK_ESCAPE => "Esc",
        win32.VK_SPACE => "Space",
        win32.VK_BACK => "Backspace",
        win32.VK_DELETE => "Del",
        win32.VK_HOME => "Home",
        win32.VK_END => "End",
        win32.VK_LEFT => "Left",
        win32.VK_UP => "Up",
        win32.VK_RIGHT => "Right",
        win32.VK_DOWN => "Down",
        win32.VK_INSERT => "Insert",
        win32.VK_PRIOR => "PgUp",
        win32.VK_NEXT => "PgDn",
        win32.VK_OEM_PLUS => "+",
        win32.VK_OEM_MINUS => "-",
        win32.VK_OEM_COMMA => ",",
        win32.VK_OEM_PERIOD => ".",
        win32.VK_OEM_1 => ";",
        win32.VK_OEM_2 => "/",
        win32.VK_OEM_3 => "`",
        win32.VK_OEM_4 => "[",
        win32.VK_OEM_5 => "\\",
        win32.VK_OEM_6 => "]",
        win32.VK_OEM_7 => "'",
        else => return false,
    };
    const mods = key.mods;
    if (mods.ctrl and !out.append("Ctrl+")) return false;
    if (mods.shift and !out.append("Shift+")) return false;
    if (mods.alt and !out.append("Alt+")) return false;
    if (mods.super and !out.append("Win+")) return false;
    return out.append(name);
}

/// A binding's keys for the log, as init.lua writes them: "ctrl+b>c".
fn fmtKeys(b: Binding) FmtKeys {
    return .{ .b = b };
}

const FmtKeys = struct {
    b: Binding,

    pub fn format(self: FmtKeys, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.b.prefix) |key| {
            try fmtKey(key, w);
            try w.writeByte('>');
        }
        try fmtKey(self.b.trigger, w);
    }

    fn fmtKey(key: Trigger, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (key.mods.ctrl) try w.writeAll("ctrl+");
        if (key.mods.shift) try w.writeAll("shift+");
        if (key.mods.alt) try w.writeAll("alt+");
        if (key.mods.super) try w.writeAll("super+");
        var label: Label = .{};
        if (labelKey(&label, .{ .vk = key.vk })) {
            for (label.slice()) |c| try w.writeByte(std.ascii.toLower(@intCast(c)));
        } else try w.print("vk{d}", .{key.vk});
    }
};

test labelIn {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    try std.testing.expectEqualSlices(u16, L("Ctrl+Shift+T"), labelIn(&defaults, .new_tab).slice());
    try std.testing.expectEqualSlices(u16, L("Ctrl+Shift+C"), labelIn(&defaults, .copy_to_clipboard).slice());
    try std.testing.expectEqualSlices(u16, L("Ctrl+Shift+E"), labelIn(&defaults, .{ .new_split = .down }).slice());
    try std.testing.expectEqualSlices(u16, L("Ctrl+Shift+Enter"), labelIn(&defaults, .toggle_split_zoom).slice());
    try std.testing.expectEqual(@as(usize, 0), labelIn(&.{}, .new_tab).len);
}

test findIn {
    const plus = findIn(&defaults, win32.VK_OEM_PLUS, .{ .ctrl = true, .shift = true, .num_lock = true }).?;
    try std.testing.expectEqual(Action{ .increase_font_size = 1 }, plus.action);
    try std.testing.expectEqual(Action.previous_tab, findIn(&defaults, win32.VK_TAB, .{ .ctrl = true, .shift = true }).?.action);
    try std.testing.expectEqual(null, findIn(&defaults, win32.VK_OEM_PLUS, .{ .ctrl = true }));
    try std.testing.expectEqual(Action.reset_font_size, findIn(&defaults, '0', .{ .ctrl = true }).?.action);
    try std.testing.expectEqual(null, findIn(&defaults, '0', .{ .ctrl = true, .shift = true, .alt = true }));
}

test parse {
    const expectTrigger = struct {
        fn f(chord: []const u8, vk: u32, mods: Mods.Keys) !void {
            const t = try parse(chord);
            try std.testing.expectEqual(vk, t.vk);
            try std.testing.expectEqual(mods.int(), t.mods.int());
        }
    }.f;
    try expectTrigger("ctrl+shift+d", 'D', ctrl_shift);
    try expectTrigger("Ctrl + Alt + Shift + Up", win32.VK_UP, ctrl_alt_shift);
    try expectTrigger("ctrl+f5", win32.VK_F1 + 4, ctrl);
    try expectTrigger("ctrl+shift+plus", win32.VK_OEM_PLUS, ctrl_shift);
    try expectTrigger("ctrl+shift+=", win32.VK_OEM_PLUS, ctrl_shift);
    try expectTrigger("ctrl++", win32.VK_OEM_PLUS, ctrl);
    try expectTrigger("win+[", win32.VK_OEM_4, .{ .super = true });
    try expectTrigger("enter", win32.VK_RETURN, .{});
    try expectTrigger("control+3", '3', ctrl);
    try std.testing.expectError(error.NoKey, parse("ctrl+shift"));
    try std.testing.expectError(error.NoKey, parse(""));
    try std.testing.expectError(error.TwoKeys, parse("ctrl+a+b"));
    try std.testing.expectError(error.UnknownKey, parse("ctrl+hyper"));
    try std.testing.expectError(error.UnknownKey, parse("f25"));
}

test parseSequence {
    var buf: [max_keys]Trigger = undefined;
    const one = try parseSequence(&buf, "ctrl+shift+d");
    try std.testing.expectEqual(1, one.len);
    try std.testing.expect(one[0].eql(.{ .vk = 'D', .mods = ctrl_shift }));
    const three = try parseSequence(&buf, "ctrl+x > Ctrl+K > s");
    try std.testing.expectEqual(3, three.len);
    try std.testing.expect(three[0].eql(.{ .vk = 'X', .mods = ctrl }));
    try std.testing.expect(three[1].eql(.{ .vk = 'K', .mods = ctrl }));
    try std.testing.expect(three[2].eql(.{ .vk = 'S' }));
    // The plus key keeps its spelling in a sequence.
    const plus = try parseSequence(&buf, "ctrl++>c");
    try std.testing.expect(plus[0].eql(.{ .vk = win32.VK_OEM_PLUS, .mods = ctrl }) and plus[1].eql(.{ .vk = 'C' }));
    try std.testing.expectError(error.NoKey, parseSequence(&buf, "ctrl+b>"));
    try std.testing.expectError(error.NoKey, parseSequence(&buf, ">c"));
    try std.testing.expectError(error.TooManyKeys, parseSequence(&buf, "a>b>c>d>e>f>g>h>i"));
}

test "a sequence runs on its last key, and a key acts or starts one, never both" {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    var km = try Keymap.init(std.testing.allocator);
    defer km.deinit();
    try km.apply(&.{
        .{ .key = "ctrl+b>c", .action = "new_tab" },
        .{ .key = "ctrl+b>ctrl+b>z", .action = "toggle_split_zoom" },
        // Hides the default ctrl+shift+t, which would otherwise run first.
        .{ .key = "ctrl+shift+t>n", .action = "next_tab" },
    });
    const ctrl_mods: Mods = .{ .ctrl = true };
    try std.testing.expectEqual(Press.pending, km.press('B', ctrl_mods));
    try std.testing.expectEqual(1, km.pending().len);
    try std.testing.expectEqual(Action.new_tab, km.press('C', .{}).binding.action);
    try std.testing.expectEqual(0, km.pending().len);
    // A key not in the sequence ends it, and runs nothing.
    try std.testing.expectEqual(Press.pending, km.press('B', ctrl_mods));
    try std.testing.expectEqual(Press.cancelled, km.press('X', .{}));
    try std.testing.expectEqual(Press.none, km.press('X', .{}));
    // A longer one, and cancelling partway.
    try std.testing.expectEqual(Press.pending, km.press('B', ctrl_mods));
    try std.testing.expectEqual(Press.pending, km.press('B', ctrl_mods));
    try std.testing.expectEqual(Action.toggle_split_zoom, km.press('Z', .{}).binding.action);
    try std.testing.expectEqual(Press.pending, km.press('B', ctrl_mods));
    km.cancel();
    try std.testing.expectEqual(Press.none, km.press('C', .{}));
    // The default lost its key to the sequence that starts there, and
    // the defaults around it stand.
    try std.testing.expectEqual(null, km.find('T', .{ .ctrl = true, .shift = true }));
    try std.testing.expectEqual(Press.pending, km.press('T', .{ .ctrl = true, .shift = true }));
    try std.testing.expectEqual(Action.next_tab, km.press('N', .{}).binding.action);
    try std.testing.expectEqual(Action.close_surface, km.press('W', .{ .ctrl = true, .shift = true }).binding.action);
    try std.testing.expectEqualSlices(u16, L("Ctrl+B, C"), km.label(.new_tab).slice());
    try std.testing.expectEqualSlices(u16, L("Ctrl+B, Ctrl+B, Z"), km.label(.toggle_split_zoom).slice());

    // Bound the other way round, the key acts and the sequence is gone.
    try km.apply(&.{
        .{ .key = "ctrl+b>c", .action = "new_tab" },
        .{ .key = "ctrl+b", .action = "reset_font_size" },
    });
    try std.testing.expectEqual(Action.reset_font_size, km.press('B', ctrl_mods).binding.action);
    try std.testing.expectEqual(Press.none, km.press('C', .{}));
    // A later sequence replaces an earlier one of the same keys; an
    // unbind takes exactly its keys, leaving the sequences that start
    // with them.
    try km.apply(&.{
        .{ .key = "ctrl+b>c", .action = "new_tab" },
        .{ .key = "ctrl+b>c", .action = "previous_tab" },
        .{ .key = "ctrl+b" },
    });
    try std.testing.expectEqual(Press.pending, km.press('B', ctrl_mods));
    try std.testing.expectEqual(Action.previous_tab, km.press('C', .{}).binding.action);
    try std.testing.expectEqual(1, km.bindings.items.len - defaults.len);
    // A reload ends a sequence under way.
    try std.testing.expectEqual(Press.pending, km.press('B', ctrl_mods));
    try km.apply(&.{.{ .key = "ctrl+b>c", .action = "new_tab" }});
    try std.testing.expectEqual(0, km.pending().len);
}

test "a repeatable binding keeps its prefix pressed, until a key that's no repeat of it" {
    var km = try Keymap.init(std.testing.allocator);
    defer km.deinit();
    try km.apply(&.{
        .{ .key = "ctrl+b>h", .action = "resize_split", .args = "{\"direction\":\"left\"}", .repeat = true },
        .{ .key = "ctrl+b>l", .action = "resize_split", .args = "{\"direction\":\"right\"}", .repeat = true },
        .{ .key = "ctrl+b>c", .action = "new_tab" },
        .{ .key = "ctrl+b>ctrl+b>z", .action = "toggle_split_zoom" },
        // Alone, a key repeats as it's held: the flag means nothing.
        .{ .key = "ctrl+shift+r", .action = "reset_font_size", .repeat = true },
    });
    const ctrl_mods: Mods = .{ .ctrl = true };
    const left: Action = .{ .resize_split = .{ .direction = .left, .amount = 1 } };
    const right: Action = .{ .resize_split = .{ .direction = .right, .amount = 1 } };
    try std.testing.expectEqual(Press.pending, km.press('B', ctrl_mods));
    try std.testing.expect(!km.isRepeating());
    try std.testing.expectEqual(left, km.press('H', .{}).binding.action);
    try std.testing.expect(km.isRepeating());
    try std.testing.expectEqual(1, km.pending().len);
    try std.testing.expectEqual(left, km.press('H', .{}).binding.action);
    // Another repeat of the prefix goes on repeating; a binding of the
    // prefix that isn't one runs, and ends it.
    try std.testing.expectEqual(right, km.press('L', .{}).binding.action);
    try std.testing.expect(km.isRepeating());
    try std.testing.expectEqual(Action.new_tab, km.press('C', .{}).binding.action);
    try std.testing.expect(!km.isRepeating());
    try std.testing.expectEqual(Press.none, km.press('H', .{}));
    // A key that's nothing of the prefix's ends the repeat and goes on
    // as itself: to the program, to its own binding, or into a sequence.
    _ = km.press('B', ctrl_mods);
    _ = km.press('H', .{});
    try std.testing.expectEqual(Press.none, km.press('X', .{}));
    try std.testing.expect(!km.isRepeating());
    _ = km.press('B', ctrl_mods);
    _ = km.press('H', .{});
    try std.testing.expectEqual(Action.close_surface, km.press('W', .{ .ctrl = true, .shift = true }).binding.action);
    _ = km.press('B', ctrl_mods);
    _ = km.press('H', .{});
    try std.testing.expectEqual(Press.pending, km.press('B', ctrl_mods));
    try std.testing.expect(!km.isRepeating());
    try std.testing.expectEqual(2, km.pending().len);
    try std.testing.expectEqual(Action.toggle_split_zoom, km.press('Z', .{}).binding.action);
    // The window's timer ends it through cancel.
    _ = km.press('B', ctrl_mods);
    _ = km.press('H', .{});
    km.cancel();
    try std.testing.expect(!km.isRepeating());
    try std.testing.expectEqual(Press.none, km.press('H', .{}));
    try std.testing.expectEqual(Action.reset_font_size, km.press('R', .{ .ctrl = true, .shift = true }).binding.action);
    try std.testing.expect(!km.isRepeating());
    try std.testing.expectEqual(0, km.pending().len);
}

test Keymap {
    var km = try Keymap.init(std.testing.allocator);
    defer km.deinit();
    try std.testing.expectEqual(defaults.len, km.bindings.items.len);
    try km.apply(&.{
        .{ .key = "ctrl+shift+d", .action = "new_split", .args = "{\"direction\":\"right\"}" },
        .{ .key = "ctrl+shift+t", .action = "dev", .args = "{\"file\":\"a\"}" },
        .{ .key = "ctrl+alt+l", .lua = 3 },
        .{ .key = "ctrl+shift+w" },
        .{ .key = "ctrl+shift+f", .action = "resize_split", .args = "{\"direction\":\"up\",\"amount\":5}" },
        .{ .key = "nope+x", .action = "new_tab" },
        .{ .key = "ctrl+shift+c", .action = "increase_font_size", .args = "not json" },
    });
    try std.testing.expectEqual(Action{ .new_split = .right }, km.find('D', .{ .ctrl = true, .shift = true }).?.action);
    const dev = km.find('T', .{ .ctrl = true, .shift = true }).?.action;
    try std.testing.expectEqualStrings("dev", dev.invoke.name);
    try std.testing.expectEqualStrings("{\"file\":\"a\"}", dev.invoke.args);
    try std.testing.expectEqual(Action{ .lua = 3 }, km.find('L', .{ .ctrl = true, .alt = true }).?.action);
    try std.testing.expectEqual(null, km.find('W', .{ .ctrl = true, .shift = true }));
    try std.testing.expectEqual(Action{ .resize_split = .{ .direction = .up, .amount = 5 } }, km.find('F', .{ .ctrl = true, .shift = true }).?.action);
    try std.testing.expectEqual(Action{ .increase_font_size = 1 }, km.find('C', .{ .ctrl = true, .shift = true }).?.action);
    // The rest of the defaults stand, and the labels follow the keymap:
    // new_tab lost its key to dev.
    try std.testing.expectEqual(@as(usize, 0), km.label(.new_tab).len);
    try std.testing.expectEqual(Action.next_tab, km.find(win32.VK_TAB, .{ .ctrl = true }).?.action);
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    try std.testing.expectEqualSlices(u16, L("Ctrl+Shift+D"), km.label(.{ .new_split = .right }).slice());
    // Applied again, the defaults come back.
    try km.apply(&.{});
    try std.testing.expectEqual(Action.new_tab, km.find('T', .{ .ctrl = true, .shift = true }).?.action);
}
