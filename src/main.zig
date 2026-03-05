//! UseZombie — agent delivery control plane.
//! One Zig binary. Takes a spec. Ships a validated PR.
//!
//! Subcommands:
//!   serve    Start HTTP API server + worker loop (default)
//!   doctor   Verify Postgres, git, agent config, and critical env
//!   run      One-shot: process a spec file without HTTP server

const std = @import("std");
const builtin = @import("builtin");

const db = @import("db/pool.zig");
const runtime_config = @import("config/runtime.zig");
const events_bus = @import("events/bus.zig");
const http_server = @import("http/server.zig");
const http_handler = @import("http/handler.zig");
const worker = @import("pipeline/worker.zig");

const log = std.log.scoped(.zombied);

var shutdown_requested = std.atomic.Value(bool).init(false);
var runtime_log_level = std.atomic.Value(u8).init(@intFromEnum(if (builtin.mode == .Debug) std.log.Level.debug else std.log.Level.info));

// Logging configuration — follow Ghostty pattern
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = zombiedLog,
};

fn parseLogLevel(level_raw: []const u8) ?std.log.Level {
    if (std.ascii.eqlIgnoreCase(level_raw, "debug")) return .debug;
    if (std.ascii.eqlIgnoreCase(level_raw, "info")) return .info;
    if (std.ascii.eqlIgnoreCase(level_raw, "warn") or std.ascii.eqlIgnoreCase(level_raw, "warning")) return .warn;
    if (std.ascii.eqlIgnoreCase(level_raw, "err") or std.ascii.eqlIgnoreCase(level_raw, "error")) return .err;
    return null;
}

fn initRuntimeLogLevel(alloc: std.mem.Allocator) void {
    const level_raw = std.process.getEnvVarOwned(alloc, "LOG_LEVEL") catch return;
    defer alloc.free(level_raw);

    if (parseLogLevel(level_raw)) |lvl| {
        runtime_log_level.store(@intFromEnum(lvl), .release);
    }
}

fn shouldLog(level: std.log.Level) bool {
    const configured: std.log.Level = @enumFromInt(runtime_log_level.load(.acquire));
    return @intFromEnum(level) <= @intFromEnum(configured);
}

fn zombiedLog(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (!shouldLog(level)) return;

    const level_str = comptime switch (level) {
        .err => "err",
        .warn => "warn",
        .info => "info",
        .debug => "debug",
    };
    const scope_str = comptime if (scope == .default) "default" else @tagName(scope);
    const ts = std.time.milliTimestamp();
    var msg_buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch return;
    var line_buf: [8192]u8 = undefined;
    const line = std.fmt.bufPrint(
        &line_buf,
        "ts_ms={d} level={s} scope={s} msg={f}\n",
        .{ ts, level_str, scope_str, std.json.fmt(msg, .{}) },
    ) catch return;
    const stderr = std.fs.File.stderr();
    _ = stderr.write(line) catch {};
}

fn onSignal(sig: i32) callconv(.c) void {
    _ = sig;
    shutdown_requested.store(true, .release);
}

fn installSignalHandlers() void {
    const action = std.posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
    std.posix.sigaction(std.posix.SIG.TERM, &action, null);
}

fn signalWatcher(wstate: *worker.WorkerState) void {
    while (!shutdown_requested.load(.acquire)) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    wstate.running.store(false, .release);
    http_server.stop();
}

// ── CLI ───────────────────────────────────────────────────────────────────

const Subcommand = enum { serve, doctor, run };

fn parseSubcommand() Subcommand {
    var args = std.process.args();
    _ = args.next();
    const cmd = args.next() orelse return .serve;
    return std.meta.stringToEnum(Subcommand, cmd) orelse .serve;
}

fn isHexString(s: []const u8) bool {
    for (s) |ch| {
        if (!std.ascii.isHex(ch)) return false;
    }
    return true;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    initRuntimeLogLevel(alloc);

    if (builtin.mode == .Debug) {
        log.warn("debug build — not for production use", .{});
    }

    const cmd = parseSubcommand();
    switch (cmd) {
        .serve => try cmdServe(alloc),
        .doctor => try cmdDoctor(alloc),
        .run => try cmdRun(alloc),
    }
}

test "parseLogLevel accepts common values" {
    try std.testing.expectEqual(@as(?std.log.Level, .debug), parseLogLevel("DEBUG"));
    try std.testing.expectEqual(@as(?std.log.Level, .info), parseLogLevel("info"));
    try std.testing.expectEqual(@as(?std.log.Level, .warn), parseLogLevel("warning"));
    try std.testing.expectEqual(@as(?std.log.Level, .err), parseLogLevel("error"));
    try std.testing.expectEqual(@as(?std.log.Level, null), parseLogLevel("trace"));
}

fn runCanonicalMigrations(pool: *db.Pool) !void {
    const schema = @import("schema");
    const migrations = [_]db.Migration{
        .{ .version = 1, .sql = schema.initial_sql },
        .{ .version = 2, .sql = schema.vault_sql },
    };
    try db.runMigrations(pool, &migrations);
}

// ── serve ─────────────────────────────────────────────────────────────────

fn cmdServe(alloc: std.mem.Allocator) !void {
    log.info("starting zombied serve", .{});

    var serve_cfg = runtime_config.ServeConfig.load(alloc) catch |err| {
        switch (err) {
            runtime_config.ValidationError.MissingApiKey,
            runtime_config.ValidationError.InvalidApiKeyList,
            runtime_config.ValidationError.MissingEncryptionMasterKey,
            runtime_config.ValidationError.InvalidEncryptionMasterKey,
            runtime_config.ValidationError.MissingGitHubAppId,
            runtime_config.ValidationError.MissingGitHubAppPrivateKey,
            runtime_config.ValidationError.InvalidPort,
            runtime_config.ValidationError.InvalidMaxAttempts,
            runtime_config.ValidationError.InvalidWorkerConcurrency,
            runtime_config.ValidationError.InvalidRateLimitCapacity,
            runtime_config.ValidationError.InvalidRateLimitRefillPerSec,
            => runtime_config.ServeConfig.printValidationError(err),
            else => std.debug.print("fatal: failed to load runtime config: {}\n", .{err}),
        }
        std.process.exit(1);
    };
    defer serve_cfg.deinit();

    const api_pool = db.initFromEnvForRole(alloc, .api) catch |err| {
        std.debug.print("fatal: api database init failed: {}\n", .{err});
        std.process.exit(1);
    };
    defer api_pool.deinit();

    const worker_pool = db.initFromEnvForRole(alloc, .worker) catch |err| {
        std.debug.print("fatal: worker database init failed: {}\n", .{err});
        std.process.exit(1);
    };
    defer worker_pool.deinit();

    runCanonicalMigrations(api_pool) catch |err| {
        std.debug.print("fatal: schema migration failed: {}\n", .{err});
        std.process.exit(1);
    };

    std.fs.makeDirAbsolute(serve_cfg.cache_root) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => log.warn("could not create cache root {s}: {}", .{ serve_cfg.cache_root, err }),
    };

    var wstate = worker.WorkerState.init();

    var ctx = http_handler.Context{
        .pool = api_pool,
        .alloc = alloc,
        .api_keys = serve_cfg.api_keys,
        .worker_state = &wstate,
    };

    const wcfg = worker.WorkerConfig{
        .pool = worker_pool,
        .config_dir = serve_cfg.config_dir,
        .cache_root = serve_cfg.cache_root,
        .github_app_id = serve_cfg.github_app_id,
        .github_app_private_key = serve_cfg.github_app_private_key,
        .max_attempts = serve_cfg.max_attempts,
        .rate_limit_capacity = serve_cfg.rate_limit_capacity,
        .rate_limit_refill_per_sec = serve_cfg.rate_limit_refill_per_sec,
    };

    shutdown_requested.store(false, .release);
    installSignalHandlers();

    var event_bus = events_bus.Bus.init();
    events_bus.install(&event_bus);
    defer events_bus.uninstall();

    const worker_count: usize = @max(@as(usize, @intCast(serve_cfg.worker_concurrency)), 1);
    var worker_threads = try alloc.alloc(std.Thread, worker_count);
    defer alloc.free(worker_threads);
    var spawned_workers: usize = 0;
    var signal_thread: ?std.Thread = null;
    var event_thread: ?std.Thread = null;
    errdefer {
        wstate.running.store(false, .release);
        shutdown_requested.store(true, .release);
        event_bus.stop();
        if (signal_thread) |*t| t.join();
        if (event_thread) |*t| t.join();
        while (spawned_workers > 0) {
            spawned_workers -= 1;
            worker_threads[spawned_workers].join();
        }
    }
    for (worker_threads) |*t| {
        t.* = try std.Thread.spawn(.{}, worker.workerLoop, .{ wcfg, &wstate });
        spawned_workers += 1;
    }
    signal_thread = try std.Thread.spawn(.{}, signalWatcher, .{&wstate});
    event_thread = try std.Thread.spawn(.{}, events_bus.runThread, .{&event_bus});

    log.info("HTTP server starting port={d} worker_concurrency={d}", .{ serve_cfg.port, worker_count });
    http_server.serve(&ctx, .{ .port = serve_cfg.port }) catch |err| {
        log.err("http server exited with error: {}", .{err});
    };

    // Server exited. Ensure worker and watcher terminate and join both.
    wstate.running.store(false, .release);
    shutdown_requested.store(true, .release);
    event_bus.stop();
    for (worker_threads) |*t| t.join();
    if (signal_thread) |*t| t.join();
    if (event_thread) |*t| t.join();
}

// ── doctor ────────────────────────────────────────────────────────────────

fn cmdDoctor(alloc: std.mem.Allocator) !void {
    var ok = true;
    var stdout_buf: [8192]u8 = undefined;
    var stdout_w = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_w.interface;

    try stdout.print("zombied doctor\n\n", .{});

    db_check: {
        const pool = db.initFromEnvForRole(alloc, .api) catch {
            try stdout.print("  [FAIL] DATABASE_URL_API or DATABASE_URL not set/invalid\n", .{});
            ok = false;
            break :db_check;
        };
        pool.deinit();
        try stdout.print("  [OK]   API database config\n", .{});
    }

    worker_db_check: {
        const pool = db.initFromEnvForRole(alloc, .worker) catch {
            try stdout.print("  [FAIL] DATABASE_URL_WORKER or DATABASE_URL not set/invalid\n", .{});
            ok = false;
            break :worker_db_check;
        };
        pool.deinit();
        try stdout.print("  [OK]   Worker database config\n", .{});
    }

    {
        const key = std.process.getEnvVarOwned(alloc, "ENCRYPTION_MASTER_KEY") catch null;
        if (key) |k| {
            defer alloc.free(k);
            if (k.len == 64) {
                try stdout.print("  [OK]   ENCRYPTION_MASTER_KEY set\n", .{});
            } else {
                try stdout.print("  [FAIL] ENCRYPTION_MASTER_KEY must be 64 hex chars\n", .{});
                ok = false;
            }
        } else {
            try stdout.print("  [FAIL] ENCRYPTION_MASTER_KEY not set\n", .{});
            ok = false;
        }
    }

    {
        const app_id = std.process.getEnvVarOwned(alloc, "GITHUB_APP_ID") catch null;
        if (app_id) |id| {
            defer alloc.free(id);
            if (id.len > 0) {
                try stdout.print("  [OK]   GITHUB_APP_ID set\n", .{});
            } else {
                try stdout.print("  [FAIL] GITHUB_APP_ID is empty\n", .{});
                ok = false;
            }
        } else {
            try stdout.print("  [FAIL] GITHUB_APP_ID not set\n", .{});
            ok = false;
        }
    }

    {
        const key = std.process.getEnvVarOwned(alloc, "GITHUB_APP_PRIVATE_KEY") catch null;
        if (key) |k| {
            defer alloc.free(k);
            if (k.len > 0) {
                try stdout.print("  [OK]   GITHUB_APP_PRIVATE_KEY set\n", .{});
            } else {
                try stdout.print("  [FAIL] GITHUB_APP_PRIVATE_KEY is empty\n", .{});
                ok = false;
            }
        } else {
            try stdout.print("  [FAIL] GITHUB_APP_PRIVATE_KEY not set\n", .{});
            ok = false;
        }
    }

    {
        const config_dir = std.process.getEnvVarOwned(alloc, "AGENT_CONFIG_DIR") catch
            try alloc.dupe(u8, "./config");
        defer alloc.free(config_dir);

        const required_files = [_][]const u8{
            "echo-prompt.md", "scout-prompt.md", "warden-prompt.md",
            "echo.json",      "scout.json",      "warden.json",
        };
        for (required_files) |fname| {
            const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ config_dir, fname });
            defer alloc.free(path);
            if (std.fs.accessAbsolute(path, .{})) |_| {
                try stdout.print("  [OK]   config/{s}\n", .{fname});
            } else |_| {
                try stdout.print("  [FAIL] config/{s} missing\n", .{fname});
                ok = false;
            }
        }
    }

    {
        const key = std.process.getEnvVarOwned(alloc, "API_KEY") catch null;
        if (key) |k| {
            defer alloc.free(k);
            try stdout.print("  [OK]   API_KEY set\n", .{});
        } else {
            try stdout.print("  [FAIL] API_KEY not set\n", .{});
            ok = false;
        }
    }

    try stdout.print("\n{s}\n", .{
        if (ok) "All checks passed." else "Some checks failed — fix before running serve.",
    });
    try stdout.flush();
    if (!ok) std.process.exit(1);
}

// ── run (one-shot) ────────────────────────────────────────────────────────

fn cmdRun(alloc: std.mem.Allocator) !void {
    var args = std.process.args();
    _ = args.next();
    _ = args.next();
    const spec_path = args.next() orelse {
        std.debug.print("usage: zombied run <spec_path>\n", .{});
        std.process.exit(1);
    };

    log.info("one-shot run spec_path={s}", .{spec_path});

    const spec_content = std.fs.cwd().readFileAlloc(alloc, spec_path, 512 * 1024) catch |err| {
        std.debug.print("error reading spec: {}\n", .{err});
        std.process.exit(1);
    };
    defer alloc.free(spec_content);

    const pool = db.initFromEnvForRole(alloc, .worker) catch |err| {
        std.debug.print("fatal: database init failed: {}\n", .{err});
        std.process.exit(1);
    };
    defer pool.deinit();

    runCanonicalMigrations(pool) catch |err| {
        log.warn("one-shot migration run skipped due to error: {}", .{err});
    };

    log.info("spec loaded ({d} bytes) — pipeline runs via `zombied serve`", .{spec_content.len});
    log.info("one-shot mode: POST /v1/runs to trigger pipeline", .{});
}

test {
    _ = @import("types.zig");
    _ = @import("state/machine.zig");
    _ = @import("secrets/crypto.zig");
    _ = @import("db/pool.zig");
}
