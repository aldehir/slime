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

    for ([_][]const u8{ "user32", "advapi32", "d3d11", "dxgi", "dwmapi", "dwrite", "d3dcompiler", "d2d1", "shlwapi" }) |lib| {
        exe_mod.linkSystemLibrary(lib, .{});
    }
    // Drawn in the title bar, as the taskbar shows it at small sizes.
    exe_mod.addAnonymousImport("slime-small.svg", .{ .root_source_file = b.path("assets/icon/slime-small.svg") });
    // The chrome's icons, embedded by the module next to them.
    exe_mod.addAnonymousImport("lucide", .{ .root_source_file = b.path("assets/icons/lucide/lucide.zig") });
    // The frame codec slimed's library shares (src/Screen.zig).
    exe_mod.addAnonymousImport("frame", .{ .root_source_file = b.path("ssh/internal/vt/frame.zig") });

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
        .name = "slime",
        .root_module = exe_mod,
    });
    exe.subsystem = if (console) .console else .windows;

    // The GUI subsystem defaults to the CRT's WinMain entry. Keep using
    // the regular `main` (and std.process.Init) in both modes.
    exe.entry = .{ .symbol_name = "mainCRTStartup" };
    b.installArtifact(exe);
    installConpty(b);
    const ssh = b.option(bool, "ssh", "Build the slime-ssh and slimed helpers (need Go; default: if Go is found)");
    if (ssh orelse true) installGoHelpers(b, ssh != null);

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
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    terminfoSteps(b, test_step);
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

/// The xterm-ghostty terminfo source the SSH helper embeds, generated
/// from ghostty's own definition. It's checked in so the helper builds
/// with Go alone; `zig build terminfo` regenerates it, and the tests fail
/// when it no longer matches the submodule.
fn terminfoSteps(b: *std.Build, test_step: *std.Build.Step) void {
    const checked_in = "ssh/internal/terminfo/xterm-ghostty.terminfo";
    const tool = b.addExecutable(.{
        .name = "terminfo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/build/terminfo.zig"),
            .target = b.graph.host,
            .imports = &.{.{
                .name = "terminfo",
                .module = b.createModule(.{
                    .root_source_file = b.path("ghostty/src/terminfo/main.zig"),
                    .target = b.graph.host,
                }),
            }},
        }),
    });

    const generate = b.addRunArtifact(tool);
    const source = generate.addOutputFileArg("xterm-ghostty.terminfo");
    const update = b.addUpdateSourceFiles();
    update.addCopyFileToSource(source, checked_in);
    b.step("terminfo", "Regenerate " ++ checked_in ++ " from ghostty's terminfo").dependOn(&update.step);

    const check = b.addRunArtifact(tool);
    check.addArg("--check");
    check.addFileArg(b.path(checked_in));
    test_step.dependOn(&check.step);
}

/// The Go helpers, next to the exe: slime-ssh.exe for `ssh://` commands,
/// and slimed.exe for `persist-sessions`. slime-ssh carries slimed for
/// Linux, to install on hosts it connects to. Go caches its own builds,
/// so this runs `go build` every time rather than tracking the sources.
/// Without Go it warns and leaves them out, unless `-Dssh=true` asked for
/// them.
fn installGoHelpers(b: *std.Build, required: bool) void {
    const go = b.findProgram(&.{"go"}, &.{}) catch {
        if (required) {
            b.getInstallStep().dependOn(&b.addFail("go not found; -Dssh=true needs it to build slime-ssh and slimed").step);
            return;
        }
        std.log.warn("go not found; building without slime-ssh and slimed (ssh:// commands and persist-sessions won't work)", .{});
        return;
    };
    // slimed links libghostty-vt with cgo (ssh/internal/vt), as a static
    // library for each target from a nested build of the submodule, which
    // tracks its own sources. ssh/internal/vt/slime.zig is compiled in
    // for slimed's own exports. scripts/build-vt-lib.ps1 does the same.
    const extra = b.fmt("-Dvt-extra={s}", .{b.path("ssh/internal/vt/slime.zig").getPath(b)});
    const copy = b.addUpdateSourceFiles();
    for ([_]struct { zig: []const u8, go: []const u8, lib: []const u8 }{
        .{ .zig = "x86_64-windows-gnu", .go = "windows_amd64", .lib = "ghostty-vt-static.lib" },
        .{ .zig = "x86_64-linux-musl", .go = "linux_amd64", .lib = "libghostty-vt.a" },
    }) |t| {
        const lib = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "-Demit-lib-vt", b.fmt("-Dtarget={s}", .{t.zig}), "-Doptimize=ReleaseFast", extra, "--prefix" });
        const prefix = lib.addOutputDirectoryArg(b.fmt("vt-{s}", .{t.zig}));
        lib.setCwd(b.path("ghostty"));
        lib.has_side_effects = true;
        // Named as an archive on both, for cgo's -l (its flag check
        // rejects a .lib path).
        copy.addCopyFileToSource(prefix.path(b, b.fmt("lib/{s}", .{t.lib})), b.fmt("ssh/internal/vt/lib/{s}/libghostty-vt.a", .{t.go}));
    }
    goBuild(b, go, "slimed").step.dependOn(&copy.step);

    // slime-pack builds slimed for each Linux target into
    // ssh/internal/payload/bin, which slime-ssh embeds.
    const pack = b.addSystemCommand(&.{ go, "run", "./cmd/slime-pack" });
    pack.setCwd(b.path("ssh"));
    pack.setEnvironmentVariable("ZIG", b.graph.zig_exe);
    pack.has_side_effects = true;
    pack.step.dependOn(&copy.step);
    goBuild(b, go, "slime-ssh").step.dependOn(&pack.step);
}

/// `go build` of ssh/cmd/`name`, installed as `name`.exe.
fn goBuild(b: *std.Build, go: []const u8, comptime name: []const u8) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{ go, "build", "-trimpath", "-ldflags=-s -w", "-o" });
    const out = run.addOutputFileArg(name ++ ".exe");
    run.addArg("./cmd/" ++ name);
    run.setCwd(b.path("ssh"));
    run.setEnvironmentVariable("GOOS", "windows");
    run.setEnvironmentVariable("GOARCH", "amd64");
    // slimed needs cgo for libghostty-vt, compiled by our Zig rather than
    // whatever C compiler is on PATH.
    run.setEnvironmentVariable("CGO_ENABLED", "1");
    run.setEnvironmentVariable("CC", b.fmt("\"{s}\" cc -target x86_64-windows-gnu", .{b.graph.zig_exe}));
    run.has_side_effects = true;
    b.getInstallStep().dependOn(&b.addInstallBinFile(out, name ++ ".exe").step);
    return run;
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
