const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Single static library — no runtime DLL discovery, no XML at runtime.
    const iso_mod = b.createModule(.{
        .root_source_file = b.path("src/iso8583.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "iso8583",
        .root_module = iso_mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // ── Tests ────────────────────────────────────────────────────────────

    const test_step = b.step("test", "Run all tests");

    // Core unit tests (refAllDeclsRecursive)
    const unit_tests = b.addTest(.{
        .root_module = iso_mod,
    });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // Comprehensive test suites
    const test_files = &.{
        "src/test_encoding.zig",
        "src/test_mti.zig",
        "src/test_bitmap.zig",
        "src/test_simd.zig",
        "src/test_spec.zig",
        "src/test_validate.zig",
        "src/test_integration.zig",
    };
    inline for (test_files) |path| {
        const mod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        const t = b.addTest(.{
            .root_module = mod,
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // ── Benchmark ────────────────────────────────────────────────────────

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const bench = b.addExecutable(.{
        .name = "iso8583-bench",
        .root_module = bench_mod,
    });
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&b.addRunArtifact(bench).step);

    // ── Example ──────────────────────────────────────────────────────────

    const example_mod = b.createModule(.{
        .root_source_file = b.path("examples/basic.zig"),
        .target = target,
        .optimize = optimize,
    });
    const example = b.addExecutable(.{
        .name = "iso8583-example",
        .root_module = example_mod,
    });
    example.root_module.addImport("iso8583", iso_mod);
    const example_step = b.step("example", "Run basic example");
    example_step.dependOn(&b.addRunArtifact(example).step);
}
