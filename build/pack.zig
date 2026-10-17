//! Packs the slimed builds for other systems into the `remote` directory
//! that goes beside the exe (internal/remote): each gzipped as
//! slimed-<os>-<arch>.gz, and a manifest naming them, one per line as
//! `os arch sha256 size`. build.zig runs it on the host:
//!
//!   pack <out-dir> [<os> <arch> <exe>]...
//!
//! The gzip header carries no name or time, so the same build packs to
//! the same bytes, and so to the same id on hosts.

const std = @import("std");
const flate = std.compress.flate;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2 or (args.len - 2) % 3 != 0) {
        std.log.err("usage: pack <out-dir> [<os> <arch> <exe>]...", .{});
        std.process.exit(2);
    }

    const cwd = std.Io.Dir.cwd();
    var out_dir = try cwd.createDirPathOpen(io, args[1], .{});
    defer out_dir.close(io);

    var manifest: std.Io.Writer.Allocating = .init(arena);
    var i: usize = 2;
    while (i < args.len) : (i += 3) {
        const os_name, const arch, const exe_path = .{ args[i], args[i + 1], args[i + 2] };
        const exe = try cwd.readFileAlloc(io, exe_path, arena, .limited(256 << 20));
        const gz = try gzip(arena, exe);
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(gz, &digest, .{});
        const name = try std.fmt.allocPrint(arena, "slimed-{s}-{s}.gz", .{ os_name, arch });
        try out_dir.writeFile(io, .{ .sub_path = name, .data = gz });
        try manifest.writer.print("{s} {s} {x} {d}\n", .{ os_name, arch, &digest, gz.len });
    }
    try out_dir.writeFile(io, .{ .sub_path = "manifest", .data = manifest.written() });
}

/// `data`, gzipped at the best level: it's compressed once and sent to
/// hosts many times.
fn gzip(arena: std.mem.Allocator, data: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(arena, data.len / 2);
    const window = try arena.alloc(u8, flate.max_window_len);
    var compress = try flate.Compress.init(&out.writer, window, .gzip, .best);
    try compress.writer.writeAll(data);
    try compress.finish();
    return out.written();
}
