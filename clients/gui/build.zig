const std = @import("std");

/// The Win32 window: slime-gui.exe. Built on its own from this directory, or
/// as a path dependency of the repository's build.zig, which installs
/// it beside the daemon.
pub fn build(b: *std.Build) void {
    // Building libghostty-vt's C++ dependencies against MSVC needs the
    // environment from scripts/setup-msvc.ps1.
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .msvc },
    });
    const optimize = b.standardOptimizeOption(.{});

    // A console subsystem build keeps stderr (std.log) visible while
    // developing. Release builds are pure GUI apps.
    const console = b.option(
        bool,
        "console",
        "Build with the console subsystem (default: true in Debug)",
    ) orelse (optimize == .Debug);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const options = b.addOptions();
    options.addOption(bool, "stats", b.option(
        bool,
        "stats",
        "Show frame timing and throughput in the window title (default: true in Debug)",
    ) orelse (optimize == .Debug));
    options.addOption(u32, "max_fps", b.option(
        u32,
        "max-fps",
        "Frame rate cap (default: 300; 0 paces to the display's refresh rate)",
    ) orelse 300);
    exe_mod.addOptions("build_options", options);

    for ([_][]const u8{ "user32", "advapi32", "d3d11", "dxgi", "dwmapi", "dwrite", "d3dcompiler", "d2d1", "dcomp", "shlwapi", "ole32" }) |lib| {
        exe_mod.linkSystemLibrary(lib, .{});
    }
    // Drawn in the title bar, as the taskbar shows it at small sizes.
    exe_mod.addAnonymousImport("slime-small.svg", .{ .root_source_file = b.path("assets/icon/slime-small.svg") });
    // The chrome's icons, embedded by the module next to them.
    exe_mod.addAnonymousImport("lucide", .{ .root_source_file = b.path("assets/icons/lucide/lucide.zig") });
    // The bundled themes for the `theme` config key, embedded: hundreds
    // of small files are slow to unpack and copy around next to the exe.
    exe_mod.addAnonymousImport("themes", .{ .root_source_file = embedThemes(b) });
    // The frame and event codecs slime's library defines (src/Screen.zig),
    // imported from the daemon's tree rather than copied.
    exe_mod.addAnonymousImport("frame", .{ .root_source_file = b.path("../../internal/vt/frame.zig") });
    exe_mod.addAnonymousImport("event", .{ .root_source_file = b.path("../../internal/vt/event.zig") });

    if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        exe_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
        // Already compiled into ghostty-vt for kitty graphics; we use its
        // PNG decoder, which libghostty-vt leaves to the embedder.
        if (dep.builder.lazyDependency("wuffs", .{
            .target = target,
            .optimize = optimize,
        })) |wuffs| exe_mod.addImport("wuffs", wuffs.module("wuffs"));
    }
    exe_mod.addImport("z2d", b.dependency("z2d", .{
        .target = target,
        .optimize = optimize,
    }).module("z2d"));

    // The app icon, rendered from assets/icon by a host tool. Zig's cache
    // reruns it only when the tool or an SVG changes.
    const icon = renderIcon(b);
    exe_mod.addWin32ResourceFile(.{
        .file = b.path("src/slime.rc"),
        .include_paths = &.{icon.ico.dirname()},
    });

    const exe = b.addExecutable(.{
        .name = "slime-gui",
        .root_module = exe_mod,
    });
    exe.subsystem = if (console) .console else .windows;

    // The GUI subsystem defaults to the CRT's WinMain entry. Keep using
    // the regular `main` (and std.process.Init) in both modes.
    exe.entry = .{ .symbol_name = "mainCRTStartup" };
    b.installArtifact(exe);

    const icons = b.addInstallDirectory(.{
        .source_dir = icon.png_dir,
        .install_dir = .prefix,
        .install_subdir = "icons",
    });
    b.step("icons", "Render the app icon PNGs into zig-out/icons").dependOn(&icons.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the app").dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{ .root_module = exe_mod });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(unit_tests).step);
}

/// A module listing every theme of the iTerm2-Color-Schemes release
/// (`iterm2_themes`) with its text embedded, sorted by name:
/// `pub const list = [_]Theme{ .{ .name, .text }, ... }`. The files are
/// copied beside the generated source so `@embedFile` can reach them.
/// Empty until the lazy dependency is fetched, which reruns the build.
fn embedThemes(b: *std.Build) std.Build.LazyPath {
    const io = b.graph.io;
    const wf = b.addWriteFiles();
    var source: std.Io.Writer.Allocating = .init(b.allocator);
    const w = &source.writer;
    w.writeAll("pub const Theme = struct { name: []const u8, text: []const u8 };\npub const list = [_]Theme{\n") catch @panic("OOM");
    if (b.lazyDependency("iterm2_themes", .{})) |dep| {
        _ = wf.addCopyDirectory(dep.path(""), "themes", .{ .exclude_extensions = &.{".md"} });
        var names: std.ArrayList([]const u8) = .empty;
        var dir = dep.builder.build_root.handle.openDir(io, ".", .{ .iterate = true }) catch @panic("themes: can't open the dependency");
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch @panic("themes: can't list the dependency")) |entry| {
            if (entry.kind != .file or std.mem.endsWith(u8, entry.name, ".md")) continue;
            names.append(b.allocator, b.dupe(entry.name)) catch @panic("OOM");
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lessThan(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lessThan);
        for (names.items) |name| {
            w.print("    .{{ .name = \"{f}\", .text = @embedFile(\"themes/{f}\") }},\n", .{ std.zig.fmtString(name), std.zig.fmtString(name) }) catch @panic("OOM");
        }
    }
    w.writeAll("};\n") catch @panic("OOM");
    return wf.add("themes.zig", source.written());
}

const Icon = struct {
    ico: std.Build.LazyPath,
    png_dir: std.Build.LazyPath,
};

fn renderIcon(b: *std.Build) Icon {
    const tool = b.addExecutable(.{
        .name = "icon",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/build/icon.zig"),
            .target = b.graph.host,
        }),
    });
    const run = b.addRunArtifact(tool);
    run.addFileArg(b.path("assets/icon/slime.svg"));
    run.addFileArg(b.path("assets/icon/slime-small.svg"));
    const ico = run.addOutputFileArg("slime.ico");
    const png_dir = run.addOutputDirectoryArg("png");
    return .{ .ico = ico, .png_dir = png_dir };
}
