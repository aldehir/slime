const std = @import("std");

/// The ConPTY we ship instead of the OS's inbox one: conpty.dll loads
/// OpenConsole.exe from an arch subdirectory next to itself. NuGet serves
/// the package as a .nupkg, which `zig fetch` doesn't recognize, so
/// scripts/fetch-conpty.ps1 downloads it into tools/.
const conpty_version = "1.25.260930003";
const conpty_sha256 = "02b07b349af66d801159bdf9e440d4a1ce78bb951f37fc8609731665afdae7ee";
const conpty_dir = "tools/conpty-" ++ conpty_version;

/// Everything beside the exe: the daemon (slimed.exe) with its ConPTY and
/// its Linux builds for SSH hosts, and the window (clients/gui), built as
/// a path dependency that installs into the same prefix.
pub fn build(b: *std.Build) void {
    // Building libghostty-vt's C++ dependencies against MSVC needs the
    // environment from scripts/setup-msvc.ps1.
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .msvc },
    });
    const optimize = b.standardOptimizeOption(.{});

    // The window's options, passed through to clients/gui/build.zig,
    // which has the same defaults when built on its own.
    const gui = b.dependency("gui", .{
        .target = target,
        .optimize = optimize,
        .console = b.option(
            bool,
            "console",
            "Build with the console subsystem (default: true in Debug)",
        ) orelse (optimize == .Debug),
        .stats = b.option(
            bool,
            "stats",
            "Show frame timing and throughput in the window title (default: true in Debug)",
        ) orelse (optimize == .Debug),
        .@"max-fps" = b.option(
            u32,
            "max-fps",
            "Frame rate cap (default: 0, the display's refresh rate)",
        ) orelse 0,
    });
    b.getInstallStep().dependOn(gui.builder.getInstallStep());
    b.step("icons", "Render the app icon PNGs into zig-out/icons").dependOn(&gui.builder.top_level_steps.get("icons").?.step);

    installConpty(b);
    const remote = b.option(bool, "remote", "Build slimed and its builds for SSH hosts (need Go; default: if Go is found)");
    if (remote orelse true) installGoHelpers(b, remote != null);

    const run_cmd = b.addRunArtifact(gui.artifact("slime"));
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the app").dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&gui.builder.top_level_steps.get("test").?.step);
    terminfoSteps(b, test_step);
}

/// The xterm-ghostty terminfo source slimed embeds, generated from
/// ghostty's own definition. It's checked in so slimed builds with Go
/// alone; `zig build terminfo` regenerates it, and the tests fail when it
/// no longer matches the submodule.
fn terminfoSteps(b: *std.Build, test_step: *std.Build.Step) void {
    const checked_in = "internal/terminfo/xterm-ghostty.terminfo";
    const tool = b.addExecutable(.{
        .name = "terminfo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/terminfo.zig"),
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

/// The daemon, next to the exe: slimed.exe, which runs every session
/// and connects to SSH hosts, with slimed for Linux in `remote/` for it
/// to install on them. Go caches its own builds, so this runs `go build`
/// every time rather than tracking the sources. Without Go it warns and
/// leaves them out, unless `-Dremote=true` asked for them.
fn installGoHelpers(b: *std.Build, required: bool) void {
    const go = b.findProgram(&.{"go"}, &.{}) catch {
        if (required) {
            b.getInstallStep().dependOn(&b.addFail("go not found; -Dremote=true needs it to build slimed").step);
            return;
        }
        std.log.warn("go not found; building without slimed (slime will have nothing to run sessions in)", .{});
        return;
    };
    // slimed links libghostty-vt with cgo (internal/vt), as a static
    // library for each target from a nested build of the submodule, which
    // tracks its own sources. internal/vt/slime.zig is compiled in for
    // slimed's own exports. scripts/build-vt-lib.ps1 does the same.
    const extra = b.fmt("-Dvt-extra={s}", .{b.path("internal/vt/slime.zig").getPath(b)});
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
        copy.addCopyFileToSource(prefix.path(b, b.fmt("lib/{s}", .{t.lib})), b.fmt("internal/vt/lib/{s}/libghostty-vt.a", .{t.go}));
    }
    goBuild(b, go, "slimed").step.dependOn(&copy.step);
    installRemote(b, go, &copy.step);
}

/// The systems slimed is built for to install on SSH hosts, with the
/// `zig cc` target cgo compiles for each.
const remote_targets = [_]struct { os: []const u8, arch: []const u8, zig: []const u8 }{
    .{ .os = "linux", .arch = "amd64", .zig = "x86_64-linux-musl" },
};

/// slimed for each of `remote_targets`, as files in `remote/` next to the
/// exe (internal/remote): `go build` for the target, then build/pack.zig
/// gzips them and writes the manifest. Linked fully static against musl,
/// so it runs whatever the host's libc, and stripped by the C linker
/// too: -s alone leaves the Zig library's debug info.
fn installRemote(b: *std.Build, go: []const u8, libs: *std.Build.Step) void {
    const tool = b.addExecutable(.{
        .name = "pack",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/pack.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
        }),
    });
    const pack = b.addRunArtifact(tool);
    const dir = pack.addOutputDirectoryArg("remote");
    for (remote_targets) |t| {
        const run = b.addSystemCommand(&.{ go, "build", "-trimpath", "-ldflags=-s -w -linkmode external -extldflags '-static -s'", "-o" });
        const exe = run.addOutputFileArg(b.fmt("slimed-{s}-{s}", .{ t.os, t.arch }));
        run.addArg("./cmd/slimed");
        run.setCwd(b.path("."));
        run.setEnvironmentVariable("GOOS", t.os);
        run.setEnvironmentVariable("GOARCH", t.arch);
        run.setEnvironmentVariable("CGO_ENABLED", "1");
        run.setEnvironmentVariable("CC", b.fmt("\"{s}\" cc -target {s}", .{ b.graph.zig_exe, t.zig }));
        run.has_side_effects = true;
        run.step.dependOn(libs);
        pack.addArgs(&.{ t.os, t.arch });
        pack.addFileArg(exe);
    }
    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = dir,
        .install_dir = .bin,
        .install_subdir = "remote",
    }).step);
}

/// `go build` of cmd/`name`, installed as `name`.exe.
fn goBuild(b: *std.Build, go: []const u8, comptime name: []const u8) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{ go, "build", "-trimpath", "-ldflags=-s -w", "-o" });
    const out = run.addOutputFileArg(name ++ ".exe");
    run.addArg("./cmd/" ++ name);
    run.setCwd(b.path("."));
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

/// slimed's ConPTY, next to it.
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
