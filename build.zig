const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The exported library module. A consumer that only calls the library
    // resolves this and nothing else.
    const mod = b.addModule("docgen", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // A consumer that runs the command as a build step asks for the artifact:
    // b.dependency("docgen", .{ .exe = true }). The root package always builds
    // it.
    const is_root = b.pkg_hash.len == 0;
    const want_exe = is_root or (b.option(bool, "exe", "Build the docgen executable") orelse false);
    if (!want_exe) return;

    // The executable's parser and buffered stdio. These are eager: a nested
    // dependency does not get the build runner's second configure pass, so a
    // lazy dependency would leave the artifact unbuilt.
    const cli_dep = b.dependency("cli", .{
        .target = target,
        .optimize = optimize,
    });
    const stdx_dep = b.dependency("stdx", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "docgen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "docgen", .module = mod },
                .{ .name = "cli", .module = cli_dep.module("cli") },
                .{ .name = "stdx", .module = stdx_dep.module("stdx") },
            },
        }),
    });
    b.installArtifact(exe);

    // Tests and docs are developer-only. A consumer that wants the artifact
    // stops here.
    if (!is_root) return;

    // testingx provides the test runner. It is lazy because only this root
    // build uses it. On the first configure pass it is not fetched yet,
    // `lazyDependency` returns null, and the build runner fetches it before
    // rerunning this script.
    const testingx_dep = b.lazyDependency("testingx", .{ .target = target });
    const test_runner: ?std.Build.Step.Compile.TestRunner = if (testingx_dep) |dep|
        .{ .path = dep.path("src/runner.zig"), .mode = .simple }
    else
        null;

    const run_step = b.step("run", "Run docgen");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| run_cmd.addArgs(args);

    const mod_tests = b.addTest(.{ .root_module = mod, .test_runner = test_runner });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    run_mod_tests.addArg(b.fmt("--seed=0x{x}", .{b.graph.random_seed}));

    const exe_tests = b.addTest(.{ .root_module = exe.root_module, .test_runner = test_runner });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    run_exe_tests.addArg(b.fmt("--seed=0x{x}", .{b.graph.random_seed}));

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const docs_run = b.addRunArtifact(exe);
    docs_run.addArgs(&.{
        "--root",     "src/root.zig",
        "--title",    "docgen",
        "--repo-url", "https://github.com/baskingspot/docgen",
        "--rev",      "main",
        "--out",
    });
    const docs_out = docs_run.addOutputDirectoryArg("docs");
    const docs_install = b.addInstallDirectory(.{
        .source_dir = docs_out,
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate the API reference");
    docs_step.dependOn(&docs_install.step);
}
