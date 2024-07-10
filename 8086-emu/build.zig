const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const simLib = b.addStaticLibrary(.{
        .name = "8086-sim",
        .target = target,
        .optimize = optimize,
    });
    simLib.addCSourceFile(.{
        .file = b.path("vendor/computer_enhance/perfaware/sim86/sim86_lib.cpp"),
        .flags = &[_][]const u8{},
    });
    simLib.addIncludePath(b.path("vendor/computer_enhance/perfaware/sim86/sharedder"));
    simLib.installHeader(b.path("vendor/computer_enhance/perfaware/sim86/shared/sim86_shared.h"), "sim86_shared.h");
    b.installArtifact(simLib);

    const exe = b.addExecutable(.{
        .name = "8086-emu",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);
    exe.linkLibrary(simLib);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
