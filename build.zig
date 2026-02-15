const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const use_llvm = b.option(bool, "use-llvm", "Use llvm and lld") orelse false;

    // Main executable
    const exe = b.addExecutable(.{
        .name = "zix",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_lld = use_llvm,
        .use_llvm = use_llvm,
    });
    // Large stack for deep Nix evaluation (recursive let bindings, imports)
    exe.stack_size = 128 * 1024 * 1024; // 128 MB
    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the Nix parser/evaluator");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Lexer tests
    const lexer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lexer.zig"),
            .target = target,
        }),
    });
    const run_lexer_tests = b.addRunArtifact(lexer_tests);
    test_step.dependOn(&run_lexer_tests.step);

    // Parser tests
    const parser_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/parser.zig"),
            .target = target,
        }),
        .use_lld = use_llvm,
        .use_llvm = use_llvm,
    });
    const run_parser_tests = b.addRunArtifact(parser_tests);
    test_step.dependOn(&run_parser_tests.step);

    // Evaluator tests
    const eval_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/eval.zig"),
            .target = target,
        }),
        .use_lld = use_llvm,
        .use_llvm = use_llvm,
    });
    const run_eval_tests = b.addRunArtifact(eval_tests);
    test_step.dependOn(&run_eval_tests.step);

    // Store tests
    const store_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/store.zig"),
            .target = target,
        }),
        .use_lld = use_llvm,
        .use_llvm = use_llvm,
    });
    const run_store_tests = b.addRunArtifact(store_tests);
    test_step.dependOn(&run_store_tests.step);

    // FlakeRef tests
    const flakeref_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/flakeref.zig"),
            .target = target,
        }),
        .use_lld = use_llvm,
        .use_llvm = use_llvm,
    });
    const run_flakeref_tests = b.addRunArtifact(flakeref_tests);
    test_step.dependOn(&run_flakeref_tests.step);

    // Lockfile tests
    const lockfile_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lockfile.zig"),
            .target = target,
        }),
        .use_lld = use_llvm,
        .use_llvm = use_llvm,
    });
    const run_lockfile_tests = b.addRunArtifact(lockfile_tests);
    test_step.dependOn(&run_lockfile_tests.step);

    // Flake tests
    const flake_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/flake.zig"),
            .target = target,
        }),
        .use_lld = use_llvm,
        .use_llvm = use_llvm,
    });
    const run_flake_tests = b.addRunArtifact(flake_tests);
    test_step.dependOn(&run_flake_tests.step);
}
