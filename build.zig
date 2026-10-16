const std = @import("std");

/// The ConPTY we ship instead of the OS's inbox one: conpty.dll loads
/// OpenConsole.exe from an arch subdirectory next to itself. NuGet serves
/// the package as a .nupkg, which `zig fetch` doesn't recognize, so
/// scripts/fetch-conpty.ps1 downloads it into tools/.
const conpty_version = "1.25.260930003";
const conpty_sha256 = "02b07b349af66d801159bdf9e440d4a1ce78bb951f37fc8609731665afdae7ee";
const conpty_dir = "tools/conpty-" ++ conpty_version;

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
        "Frame rate cap (default: 0, the display's refresh rate)",
    ) orelse 0);
    exe_mod.addOptions("build_options", options);

    for ([_][]const u8{ "user32", "advapi32", "d3d11", "dxgi", "dwmapi", "dwrite", "d3dcompiler" }) |lib| {
        exe_mod.linkSystemLibrary(lib, .{});
    }

    if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        exe_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }

    // The app icon, rendered from assets/icon by a host tool. Zig's cache
    // reruns it only when the tool or an SVG changes.
    const icon = renderIcon(b);
    exe_mod.addWin32ResourceFile(.{
        .file = b.path("src/slime.rc"),
        .include_paths = &.{icon.ico.dirname()},
    });

    const exe = b.addExecutable(.{
        .name = "slime",
        .root_module = exe_mod,
    });
    exe.subsystem = if (console) .console else .windows;

    // The GUI subsystem defaults to the CRT's WinMain entry. Keep using
    // the regular `main` (and std.process.Init) in both modes.
    exe.entry = .{ .symbol_name = "mainCRTStartup" };
    b.installArtifact(exe);
    installConpty(b);

    // Themes for the `theme` config key, in `themes` next to the exe.
    if (b.lazyDependency("iterm2_themes", .{})) |themes| {
        b.installDirectory(.{
            .source_dir = themes.path(""),
            .install_dir = .bin,
            .install_subdir = "themes",
            .exclude_extensions = &.{".md"},
        });
    }

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

fn installConpty(b: *std.Build) void {
    const dll = b.addInstallBinFile(b.path(conpty_dir ++ "/conpty.dll"), "conpty.dll");
    const host = b.addInstallBinFile(b.path(conpty_dir ++ "/OpenConsole.exe"), "x64/OpenConsole.exe");
    b.getInstallStep().dependOn(&dll.step);
    b.getInstallStep().dependOn(&host.step);

    b.build_root.handle.access(b.graph.io, conpty_dir ++ "/conpty.dll", .{}) catch {
        const fetch = b.addSystemCommand(&.{
            "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
        });
        fetch.addFileArg(b.path("scripts/fetch-conpty.ps1"));
        fetch.addArgs(&.{ "-Version", conpty_version, "-Sha256", conpty_sha256, "-Out" });
        fetch.addArg(b.pathFromRoot(conpty_dir));
        dll.step.dependOn(&fetch.step);
        host.step.dependOn(&fetch.step);
    };
}
