const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const with_bench_tools = b.option(bool, "with-bench-tools", "Enable benchmark tooling (zBench)") orelse false;

    // ── NullClaw dependency ──────────────────────────────────────────────────
    // Use base engines (sqlite for per-run memory) + no channels (we don't
    // need chat channels — UseZombie runs agents programmatically).
    const nullclaw_dep = b.dependency("nullclaw", .{
        .target = target,
        .optimize = optimize,
        .channels = @as([]const u8, "none"),
        .engines = @as([]const u8, "base,sqlite"),
    });
    const nullclaw_mod = nullclaw_dep.module("nullclaw");

    // ── Zap HTTP dependency ──────────────────────────────────────────────────
    const zap_dep = b.dependency("zap", .{
        .target = target,
        .optimize = optimize,
        .openssl = false,
    });
    const zap_mod = zap_dep.module("zap");

    // ── pg.zig (pure-Zig Postgres driver) ────────────────────────────────────
    // OpenSSL is required for TLS connections to PlanetScale / hosted Postgres.
    // Only enabled when the target is Linux (our deployment platform) and the
    // host can provide headers. macOS cross-compile from Linux skips OpenSSL
    // (no macOS OpenSSL headers on Linux runners). macOS native dev uses Homebrew.
    const target_os = target.result.os.tag;
    const host_is_linux = builtin.os.tag == .linux;
    const host_is_darwin = builtin.os.tag == .macos;
    // Enable OpenSSL when headers are available for the target:
    //   Linux host + Linux target: CI deploy build (system libssl-dev)
    //   macOS host: local dev (Homebrew OpenSSL, native target only)
    // Skip for cross-compile where host can't provide target's headers
    // (e.g. Linux host → macOS target has no macOS OpenSSL).
    const enable_openssl = (host_is_linux and target_os == .linux) or (host_is_darwin and target_os == .macos);

    const pg_dep = if (enable_openssl) blk: {
        const ssl_include: std.Build.LazyPath = .{ .cwd_relative = if (host_is_linux)
            "/usr/include"
        else
            "/opt/homebrew/opt/openssl@3/include" };
        const ssl_lib: std.Build.LazyPath = .{ .cwd_relative = if (host_is_linux)
            b.fmt("/usr/lib/{s}", .{@tagName(builtin.cpu.arch) ++ "-linux-gnu"})
        else
            "/opt/homebrew/opt/openssl@3/lib" };
        break :blk b.dependency("pg", .{
            .target = target,
            .optimize = optimize,
            .openssl_include_path = ssl_include,
            .openssl_lib_path = ssl_lib,
        });
    } else b.dependency("pg", .{
        .target = target,
        .optimize = optimize,
    });
    const pg_mod = pg_dep.module("pg");

    // ── posthog-zig (server-side PostHog SDK) ───────────────────────────────
    const posthog_dep = b.dependency("posthog", .{
        .target = target,
        .optimize = optimize,
    });
    const posthog_mod = posthog_dep.module("posthog");

    // ── Schema embed module (root = schema/ so @embedFile is in-bounds) ──────
    const schema_mod = b.createModule(.{
        .root_source_file = b.path("schema/embed.zig"),
    });

    // ── UseZombie executable ───────────────────────────────────────────────────
    const exe = b.addExecutable(.{
        .name = "zombied",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nullclaw", .module = nullclaw_mod },
                .{ .name = "zap", .module = zap_mod },
                .{ .name = "pg", .module = pg_mod },
                .{ .name = "posthog", .module = posthog_mod },
                .{ .name = "schema", .module = schema_mod },
            },
        }),
    });

    // Only strip in ReleaseSmall (musl/minimal builds). ReleaseSafe keeps debug
    // info so panics produce usable stack traces in production.
    if (optimize == .ReleaseSmall) {
        exe.root_module.strip = true;
    }

    b.installArtifact(exe);

    // ── Run step ─────────────────────────────────────────────────────────────
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run zombied").dependOn(&run_cmd.step);

    // ── Test step ─────────────────────────────────────────────────────────────
    const tests = b.addTest(.{
        .name = "zombied-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nullclaw", .module = nullclaw_mod },
                .{ .name = "zap", .module = zap_mod },
                .{ .name = "pg", .module = pg_mod },
                .{ .name = "posthog", .module = posthog_mod },
                .{ .name = "schema", .module = schema_mod },
            },
        }),
    });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);

    if (with_bench_tools) {
        // ── zBench dependency ────────────────────────────────────────────────
        const zbench_dep = b.dependency("zbench", .{
            .target = target,
            .optimize = optimize,
        });
        const zbench_mod = zbench_dep.module("zbench");

        // ── API benchmark gate step (zBench-backed) ─────────────────────────
        const api_bench = b.addExecutable(.{
            .name = "api-bench-runner",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/tools/api_bench_runner.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zbench", .module = zbench_mod },
                },
            }),
        });

        const run_api_bench = b.addRunArtifact(api_bench);
        if (b.args) |args| run_api_bench.addArgs(args);
        b.step("bench-api", "Run API benchmark gate").dependOn(&run_api_bench.step);
    }

    // Installable backend test binary for coverage tooling (kcov/codecov).
    const install_tests = b.addInstallArtifact(tests, .{
        .dest_sub_path = "zombied-tests",
    });
    b.step("test-bin", "Build/install backend test binary for coverage").dependOn(&install_tests.step);
}
