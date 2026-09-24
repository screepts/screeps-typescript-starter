const std = @import("std");
const zlint = @import("zlint");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .wasm32,
            .os_tag = .freestanding,
        },
    });
    const optimize = std.Build.standardOptimizeOption(b, .{
        .preferred_optimize_mode = .ReleaseSmall,
    });

    const native_target = b.graph.host;

    const mod = b.addModule("spud", .{
        .root_source_file = b.path("src/root.zig"),
        // for native target tests
        .target = native_target,
    });

    // const exe = b.addExecutable(.{
    //     .name = "spud",
    //     .root_module = b.createModule(.{
    //         .root_source_file = b.path("src/main.zig"),
    //         .target = native_target,
    //         .optimize = optimize,
    //         .imports = &.{
    //             .{ .name = "spud", .module = mod },
    //         },
    //     }),
    // });
    // b.installArtifact(exe);

    // MAYBE: use for deploy
    // const run_step = b.step("run", "Run something");
    // const run_cmd = b.addRunArtifact(exe);
    // run_step.dependOn(&run_cmd.step);
    // run_cmd.step.dependOn(b.getInstallStep());

    // if (b.args) |args| {
    //     run_cmd.addArgs(args);
    // }

    const wasm = b.addExecutable(.{
        .name = "spud",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/entry.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "spud", .module = mod },
            },
        }),
    });
    wasm.entry = .disabled;
    wasm.lto = .thin;
    wasm.rdynamic = true;
    wasm.export_memory = true;

    b.installArtifact(wasm);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // broken https://github.com/DonIsaac/zlint/issues/433 - use zlint binary instead
    //const zlint_dep = b.dependency("zlint", .{});
    //lint_step.dependOn(&zlint.addRunLint(b, zlint_dep).step);
    _ = zlint;
    const lint_run = std.Build.Step.Run.create(b, "lint");
    lint_run.addArg("zlint");
    const lint_step = b.step("lint", "run zlint");
    lint_step.dependOn(&lint_run.step);
}
