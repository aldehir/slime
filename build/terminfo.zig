//! Writes Ghostty's terminfo entry (xterm-ghostty) as terminfo source,
//! which the SSH helper embeds and installs on hosts that lack it.
//! build.zig runs it on the host:
//!
//!   terminfo <out>             write the source
//!   terminfo --check <file>    fail if <file> isn't what would be written

const std = @import("std");
const terminfo = @import("terminfo");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var out: std.Io.Writer.Allocating = .init(arena);
    try terminfo.ghostty.encode(&out.writer);
    const source = out.written();
    const cwd = std.Io.Dir.cwd();

    if (args.len == 3 and std.mem.eql(u8, args[1], "--check")) {
        const have = cwd.readFileAlloc(io, args[2], arena, .limited(1 << 20)) catch |err| {
            std.log.err("{s}: {}", .{ args[2], err });
            std.process.exit(1);
        };
        if (!std.mem.eql(u8, have, source)) {
            std.log.err("{s} is out of date with ghostty's terminfo; run `zig build terminfo`", .{args[2]});
            std.process.exit(1);
        }
        return;
    }
    if (args.len != 2) {
        std.log.err("usage: terminfo <out> | terminfo --check <file>", .{});
        std.process.exit(2);
    }
    try cwd.writeFile(io, .{ .sub_path = args[1], .data = source });
}
