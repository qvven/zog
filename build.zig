const std = @import("std");
const builtin = @import("builtin");

// zog tracks the Zig 0.16.x comptime reflection API. Newer dev builds (0.17+)
// renamed parts of `std.builtin.Type`, so guard the range here to fail with a
// clear message instead of a wall of reflection errors. `minimum_zig_version`
// in build.zig.zon only sets a floor; this also rejects too-new compilers.
comptime {
    const v = builtin.zig_version;
    // Compare fields directly: SemanticVersion.order treats a pre-release like
    // `0.17.0-dev` as < `0.17.0`, which would let 0.17 dev builds slip past an
    // `order` check against 0.17.0.
    const too_old = v.major == 0 and v.minor < 16;
    const too_new = v.major > 0 or (v.major == 0 and v.minor >= 17);
    if (too_old or too_new) {
        @compileError(std.fmt.comptimePrint(
            "zog requires Zig 0.16.x; found {d}.{d}.{d}. " ++
                "Newer dev builds changed the comptime reflection API.",
            .{ v.major, v.minor, v.patch },
        ));
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Public library module.
    const mod = b.addModule("zog", .{
        .root_source_file = b.path("src/zog.zig"),
        .target = target,
    });

    // Internal demo executable, kept for manual output checks.
    const exe = b.addExecutable(.{
        .name = "main",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zog", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const examples_step = b.step("examples", "Build the examples");
    addExample(b, target, optimize, mod, examples_step, "basic", "examples/basic.zig");
    addExample(b, target, optimize, mod, examples_step, "json", "examples/json.zig");
    addExample(b, target, optimize, mod, examples_step, "scopes", "examples/scopes.zig");
    addExample(b, target, optimize, mod, examples_step, "structured", "examples/structured.zig");

    const run_step = b.step("run", "Run the demo");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    const check_step = b.step("check", "Run tests and build the examples");
    check_step.dependOn(test_step);
    check_step.dependOn(examples_step);
}

fn addExample(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    mod: *std.Build.Module,
    examples_step: *std.Build.Step,
    name: []const u8,
    source_path: []const u8,
) void {
    const root_module = b.createModule(.{
        .root_source_file = b.path(source_path),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zog", .module = mod },
        },
    });
    const example = b.addExecutable(.{
        .name = name,
        .root_module = root_module,
    });
    examples_step.dependOn(&b.addInstallArtifact(example, .{}).step);
}
