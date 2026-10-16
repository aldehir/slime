const std = @import("std");

pub fn build(b: *std.Build) void {
    // Building libghostty-vt's C++ dependencies against MSVC needs the
    // environment from env.ps1.
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
    for ([_][]const u8{ "user32", "d3d11", "dxgi", "dwmapi" }) |lib| {
        exe_mod.linkSystemLibrary(lib, .{});
    }

    if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        exe_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }

    const exe = b.addExecutable(.{
        .name = "ghostty-win",
        .root_module = exe_mod,
    });
    exe.subsystem = if (console) .console else .windows;

    // The GUI subsystem defaults to the CRT's WinMain entry. Keep using
    // the regular `main` (and std.process.Init) in both modes.
    exe.entry = .{ .symbol_name = "mainCRTStartup" };
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the app").dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{ .root_module = exe_mod });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(unit_tests).step);
}
