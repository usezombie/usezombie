//! UseZombie — agent delivery control plane.
//! One Zig binary. Takes a spec. Ships a validated PR.
//!
//! Subcommands:
//!   serve    Start HTTP API server + worker loop (default)
//!   doctor   Verify Postgres, git, agent config, LLM key
//!   run      One-shot: process a spec file without HTTP server

const std = @import("std");
const builtin = @import("builtin");

const db = @import("db/pool.zig");
const http_server = @import("http/server.zig");
const http_handler = @import("http/handler.zig");
const worker = @import("pipeline/worker.zig");

const log = std.log.scoped(.zombied);

// Logging configuration — follow Ghostty pattern
pub const std_options: std.Options = .{
    .log_level = if (builtin.mode == .Debug) .debug else .info,
    .logFn = zombiedLog,
};

fn zombiedLog(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    const prefix = comptime switch (level) {
        .err => "ERR",
        .warn => "WRN",
        .info => "INF",
        .debug => "DBG",
    };
    const scope_str = comptime if (scope == .default) "" else "[" ++ @tagName(scope) ++ "] ";
    const ts = std.time.milliTimestamp();
    // Use a stack buffer to format; write directly to stderr fd.
    var msg_buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch return;
    var line_buf: [256]u8 = undefined;
    const header = std.fmt.bufPrint(&line_buf, "{d} {s} {s}", .{ ts, prefix, scope_str }) catch return;
    const stderr = std.fs.File.stderr();
    _ = stderr.write(header) catch {};
    _ = stderr.write(msg) catch {};
    _ = stderr.write("\n") catch {};
}

// ── CLI ───────────────────────────────────────────────────────────────────

const Subcommand = enum { serve, doctor, run };

fn parseSubcommand() Subcommand {
    var args = std.process.args();
    _ = args.next(); // skip binary name
    const cmd = args.next() orelse return .serve;
    return std.meta.stringToEnum(Subcommand, cmd) orelse .serve;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

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

// ── serve ─────────────────────────────────────────────────────────────────

fn cmdServe(alloc: std.mem.Allocator) !void {
    log.info("starting zombied serve", .{});

    const port_str = std.process.getEnvVarOwned(alloc, "PORT") catch null;
    defer if (port_str) |ps| alloc.free(ps);
    const port: u16 = if (port_str) |ps| std.fmt.parseInt(u16, ps, 10) catch 3000 else 3000;

    // Init Postgres pool
    const pool = db.initFromEnv(alloc) catch |err| {
        std.debug.print("fatal: database init failed: {}\n", .{err});
        std.process.exit(1);
    };
    defer pool.deinit();

    // Run schema migrations
    const schema_sql = @import("schema").initial_sql;
    db.runMigrations(pool, schema_sql) catch |err| {
        log.warn("schema migration warning: {}", .{err});
    };

    // Load API key
    const api_key = std.process.getEnvVarOwned(alloc, "API_KEY") catch {
        std.debug.print("fatal: API_KEY not set\n", .{});
        std.process.exit(1);
    };
    defer alloc.free(api_key);

    // Load worker config
    const cache_root = std.process.getEnvVarOwned(alloc, "GIT_CACHE_ROOT") catch
        try alloc.dupe(u8, "/tmp/zombie-git-cache");
    defer alloc.free(cache_root);

    const github_app_id = std.process.getEnvVarOwned(alloc, "GITHUB_APP_ID") catch
        try alloc.dupe(u8, "");
    defer alloc.free(github_app_id);

    const config_dir = std.process.getEnvVarOwned(alloc, "AGENT_CONFIG_DIR") catch
        try alloc.dupe(u8, "./config");
    defer alloc.free(config_dir);

    const max_attempts_str = std.process.getEnvVarOwned(alloc, "DEFAULT_MAX_ATTEMPTS") catch null;
    defer if (max_attempts_str) |s| alloc.free(s);
    const max_attempts: u32 = if (max_attempts_str) |s| std.fmt.parseInt(u32, s, 10) catch 3 else 3;

    // Ensure cache root exists
    std.fs.makeDirAbsolute(cache_root) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => log.warn("could not create cache root {s}: {}", .{ cache_root, err }),
    };

    // HTTP handler context
    var ctx = http_handler.Context{
        .pool = pool,
        .alloc = alloc,
        .api_key = api_key,
    };

    // Worker state (shared between threads)
    var wstate = worker.WorkerState.init();

    // Thread 2: worker loop
    const wcfg = worker.WorkerConfig{
        .pool = pool,
        .config_dir = config_dir,
        .cache_root = cache_root,
        .github_app_id = github_app_id,
        .max_attempts = max_attempts,
    };
    const worker_thread = try std.Thread.spawn(.{}, worker.workerLoop, .{ wcfg, &wstate });
    _ = worker_thread;

    // Thread 1: Zap HTTP server (blocks until stop)
    log.info("HTTP server starting port={d}", .{port});
    try http_server.serve(&ctx, .{ .port = port });
}

// ── doctor ────────────────────────────────────────────────────────────────

fn cmdDoctor(alloc: std.mem.Allocator) !void {
    var ok = true;
    var stdout_buf: [8192]u8 = undefined;
    var stdout_w = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_w.interface;

    try stdout.print("zombied doctor\n\n", .{});

    // Check DATABASE_URL + Postgres connectivity
    db_check: {
        const url_check = std.process.getEnvVarOwned(alloc, "DATABASE_URL") catch {
            try stdout.print("  [FAIL] DATABASE_URL not set\n", .{});
            ok = false;
            break :db_check;
        };
        alloc.free(url_check);

        const pool = db.initFromEnv(alloc) catch |err| {
            try stdout.print("  [FAIL] Postgres connection failed: {}\n", .{err});
            ok = false;
            break :db_check;
        };
        defer pool.deinit();
        try stdout.print("  [OK]   Postgres connected\n", .{});
    }

    // Check GITHUB_APP_ID (GitHub App OAuth — required for repo access)
    {
        const app_id = std.process.getEnvVarOwned(alloc, "GITHUB_APP_ID") catch null;
        if (app_id) |id| {
            defer alloc.free(id);
            if (id.len > 0) {
                try stdout.print("  [OK]   GITHUB_APP_ID set\n", .{});
            } else {
                try stdout.print("  [FAIL] GITHUB_APP_ID is empty (repo access will fail)\n", .{});
                ok = false;
            }
        } else {
            try stdout.print("  [FAIL] GITHUB_APP_ID not set (repo access will fail)\n", .{});
            ok = false;
        }
    }

    // Check AGENT_CONFIG_DIR + prompt files
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

    // Check API_KEY
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
    _ = args.next(); // binary
    _ = args.next(); // "run"
    const spec_path = args.next() orelse {
        std.debug.print("usage: zombied run <spec_path>\n", .{});
        std.process.exit(1);
    };

    log.info("one-shot run spec_path={s}", .{spec_path});

    // Read spec file
    const spec_content = std.fs.cwd().readFileAlloc(alloc, spec_path, 512 * 1024) catch |err| {
        std.debug.print("error reading spec: {}\n", .{err});
        std.process.exit(1);
    };
    defer alloc.free(spec_content);

    const pool = db.initFromEnv(alloc) catch |err| {
        std.debug.print("fatal: database init failed: {}\n", .{err});
        std.process.exit(1);
    };
    defer pool.deinit();

    const schema_sql = @import("schema").initial_sql;
    db.runMigrations(pool, schema_sql) catch {};

    log.info("spec loaded ({d} bytes) — pipeline runs via `zombied serve`", .{spec_content.len});
    log.info("one-shot mode: POST /v1/runs to trigger pipeline", .{});
}

test {
    // Pull in all module tests
    _ = @import("types.zig");
    _ = @import("state/machine.zig");
    _ = @import("secrets/crypto.zig");
}
