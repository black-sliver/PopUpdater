const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const clap = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });

    const minizign = b.dependency("minizign", .{
        .target = target,
        .optimize = optimize,
    });

    const lib_mod = b.addModule("PopUpdater", .{
        .root_source_file = b.path("src/lib.zig"),
        .imports = &.{
            .{ .name = "minizign", .module = minizign.module("minizign") },
        },
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .imports = &.{
            .{ .name = "PopUpdater", .module = lib_mod },
            .{ .name = "clap", .module = clap.module("clap") },
        },
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "PopUpdater",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    // expose zig build run -- args...
    const run_cmd = b.addRunArtifact(exe);

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // expose zig build test
    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}
