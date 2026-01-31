const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build the C library as an artifact
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "cj5",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    lib.addCSourceFile(.{
        .file = b.path("cj5.c"),
        .flags = &.{"-std=c99"},
    });

    // Add include path so @cImport can find cj5.h
    lib.addIncludePath(b.path("."));
    lib.installHeader(b.path("cj5.h"), "cj5.h");

    b.installArtifact(lib);

    // Create the Zig module that wraps the C library
    const cj5_mod = b.addModule("cj5", .{
        .root_source_file = b.path("cj5.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link the C library to the module
    cj5_mod.linkLibrary(lib);

    // Add tests
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("cj5.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.linkLibrary(lib);

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run cj5 tests");
    test_step.dependOn(&run_tests.step);
}
