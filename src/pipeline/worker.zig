//! Worker loop — Thread 2.
//! Reads Redis stream queue messages for run claims (fail-closed when queue is unavailable).
//! Executes pipeline stages from a topology profile (default: Echo → Scout → Warden).
//! Commits stage artifacts to git branch. Runs sequentially per run.

const std = @import("std");
const pg = @import("pg");
const db = @import("../db/pool.zig");
const state = @import("../state/machine.zig");
const agents = @import("agents.zig");
const github_auth = @import("../auth/github.zig");
const backoff = @import("../reliability/backoff.zig");
const err_classify = @import("../reliability/error_classify.zig");
const topology = @import("topology.zig");
const profile_resolver = @import("profile_resolver.zig");
const worker_runtime = @import("worker_runtime.zig");
const worker_rate_limiter = @import("worker_rate_limiter.zig");
const worker_stage_executor = @import("worker_stage_executor.zig");
const metrics = @import("../observability/metrics.zig");
const events = @import("../events/bus.zig");
const queue_consts = @import("../queue/constants.zig");
const queue_redis = @import("../queue/redis.zig");
const obs_log = @import("../observability/logging.zig");
const log = std.log.scoped(.worker);

// ── Worker configuration ──────────────────────────────────────────────────

pub const WorkerConfig = struct {
    pool: *pg.Pool,
    config_dir: []const u8,
    cache_root: []const u8,
    github_app_id: []const u8,
    github_app_private_key: []const u8,
    pipeline_profile_path: []const u8,
    skill_registry: ?*const agents.SkillRegistry = null,
    max_attempts: u32 = 3,
    run_timeout_ms: u64 = 300_000,
    poll_interval_ms: u64 = 2_000,
    rate_limit_capacity: u32 = 30,
    rate_limit_refill_per_sec: f64 = 5.0,
};

// ── Worker state shared between HTTP and worker threads ──────────────────

pub const WorkerState = struct {
    running: std.atomic.Value(bool),
    in_flight_runs: std.atomic.Value(u32),

    pub fn init() WorkerState {
        return .{
            .running = std.atomic.Value(bool).init(true),
            .in_flight_runs = std.atomic.Value(u32).init(0),
        };
    }

    pub fn beginRun(self: *WorkerState) void {
        _ = self.in_flight_runs.fetchAdd(1, .acq_rel);
        metrics.setWorkerInFlightRuns(self.currentInFlightRuns());
    }

    pub fn endRun(self: *WorkerState) void {
        const prev = self.in_flight_runs.fetchSub(1, .acq_rel);
        std.debug.assert(prev > 0);
        metrics.setWorkerInFlightRuns(self.currentInFlightRuns());
    }

    pub fn currentInFlightRuns(self: *const WorkerState) u32 {
        return self.in_flight_runs.load(.acquire);
    }
};

// ── Run context ───────────────────────────────────────────────────────────

const WorkerError = worker_runtime.WorkerError;

const WorkerAllocator = std.heap.GeneralPurposeAllocator(.{});
const TenantRateLimiter = worker_rate_limiter.TenantRateLimiter;

// ── Entry point ───────────────────────────────────────────────────────────

pub fn workerLoop(cfg: WorkerConfig, worker_state: *WorkerState) void {
    metrics.setWorkerInFlightRuns(worker_state.currentInFlightRuns());
    var gpa = WorkerAllocator{};
    defer {
        worker_state.running.store(false, .release);
        const inflight = worker_state.currentInFlightRuns();
        if (inflight != 0) {
            log.warn("worker exiting with in_flight_runs={d}", .{inflight});
        }
        _ = finalizeWorkerAllocator(&gpa);
    }
    const alloc = gpa.allocator();

    log.info("worker started poll_interval_ms={d}", .{cfg.poll_interval_ms});

    const prompts = agents.loadPrompts(alloc, cfg.config_dir) catch |err| {
        obs_log.logErr(.worker, err, "failed to load agent prompts config_dir={s}", .{cfg.config_dir});
        return;
    };
    defer {
        alloc.free(prompts.echo);
        alloc.free(prompts.scout);
        alloc.free(prompts.warden);
    }

    var profile = topology.defaultProfile(alloc) catch |err| {
        obs_log.logErr(.worker, err, "failed to initialize default pipeline profile", .{});
        return;
    };
    defer profile.deinit();
    log.info("default pipeline profile loaded profile={s} stages={d}", .{ profile.profile_id, profile.stages.len });

    var token_cache = github_auth.TokenCache.init(alloc, cfg.github_app_id, cfg.github_app_private_key);
    defer token_cache.deinit();
    var tenant_limiter = TenantRateLimiter.init(alloc, cfg.rate_limit_capacity, cfg.rate_limit_refill_per_sec);
    defer tenant_limiter.deinit();

    var queue_client = queue_redis.Client.connectFromEnv(alloc, .worker) catch |err| {
        obs_log.logErr(.worker, err, "redis queue unavailable; worker exiting (fail-closed)", .{});
        return;
    };
    defer queue_client.deinit();

    queue_client.ensureConsumerGroup() catch |err| {
        obs_log.logErr(.worker, err, "redis queue group setup failed; worker exiting (fail-closed)", .{});
        return;
    };

    const consumer_id = queue_redis.makeConsumerId(alloc) catch "worker-local";
    defer if (!std.mem.eql(u8, consumer_id, "worker-local")) alloc.free(consumer_id);
    var last_reclaim_ms: i64 = std.time.milliTimestamp();

    var consecutive_errors: u32 = 0;
    while (worker_state.running.load(.acquire)) {
        var queued_message: ?queue_redis.QueueMessage = null;
        const now_ms = std.time.milliTimestamp();
        if (now_ms - last_reclaim_ms >= queue_consts.reclaim_interval_ms) {
            last_reclaim_ms = now_ms;
            queued_message = queue_client.xautoclaimOne(consumer_id) catch |err| {
                obs_log.logErr(.worker, err, "xautoclaim failed", .{});
                metrics.incWorkerErrors();
                consecutive_errors += 1;
                const max_delay_ms = std.math.mul(u64, cfg.poll_interval_ms, 8) catch cfg.poll_interval_ms;
                const delay_ms = backoff.expBackoffJitter(consecutive_errors - 1, cfg.poll_interval_ms, max_delay_ms);
                worker_runtime.sleepWhileRunning(&worker_state.running, delay_ms);
                continue;
            };
        }

        if (queued_message == null) {
            queued_message = queue_client.xreadgroupOne(consumer_id) catch |err| {
                obs_log.logErr(.worker, err, "xreadgroup failed", .{});
                metrics.incWorkerErrors();
                consecutive_errors += 1;
                const max_delay_ms = std.math.mul(u64, cfg.poll_interval_ms, 8) catch cfg.poll_interval_ms;
                const delay_ms = backoff.expBackoffJitter(consecutive_errors - 1, cfg.poll_interval_ms, max_delay_ms);
                worker_runtime.sleepWhileRunning(&worker_state.running, delay_ms);
                continue;
            };
        }

        defer if (queued_message) |*m| m.deinit(alloc);
        const queued = queued_message orelse {
            consecutive_errors = 0;
            continue;
        };

        processNextRun(
            alloc,
            cfg,
            worker_state,
            &prompts,
            &profile,
            &token_cache,
            &tenant_limiter,
            queued.run_id,
        ) catch |err| {
            if (err != WorkerError.ShutdownRequested) {
                obs_log.logErr(.worker, err, "run processing error", .{});
                metrics.incWorkerErrors();
                consecutive_errors += 1;

                const max_delay_ms = std.math.mul(u64, cfg.poll_interval_ms, 8) catch cfg.poll_interval_ms;
                const delay_ms = backoff.expBackoffJitter(consecutive_errors - 1, cfg.poll_interval_ms, max_delay_ms);
                worker_runtime.sleepWhileRunning(&worker_state.running, delay_ms);
            }
            continue;
        };
        consecutive_errors = 0;

        queue_client.xack(queued.message_id) catch |err| {
            obs_log.logWarnErr(.worker, err, "xack failed message_id={s}", .{queued.message_id});
        };

        if (!worker_state.running.load(.acquire)) break;
    }

    log.info("worker stopped", .{});
}

fn finalizeWorkerAllocator(gpa: *WorkerAllocator) bool {
    return switch (gpa.deinit()) {
        .ok => false,
        .leak => blk: {
            metrics.incWorkerAllocatorLeaks();
            log.warn("worker allocator leak detected", .{});
            break :blk true;
        },
    };
}

fn beginTx(conn: *pg.Conn) !void {
    var tx = try conn.query("BEGIN", .{});
    tx.deinit();
}

fn commitTx(conn: *pg.Conn) !void {
    var tx = try conn.query("COMMIT", .{});
    tx.deinit();
}

fn rollbackTx(conn: *pg.Conn) void {
    var tx = conn.query("ROLLBACK", .{}) catch return;
    tx.deinit();
}

fn beginRunIfActive(worker_state: *WorkerState) WorkerError!void {
    if (!worker_state.running.load(.acquire)) return WorkerError.ShutdownRequested;
    worker_state.beginRun();
}

fn resolveBinding(cfg: WorkerConfig, role_id: []const u8, skill_id: []const u8) ?agents.RoleBinding {
    if (cfg.skill_registry) |registry| {
        if (agents.resolveRoleWithRegistry(registry, role_id, skill_id)) |binding| return binding;
    }
    return agents.resolveRole(role_id, skill_id);
}

fn processNextRun(
    alloc: std.mem.Allocator,
    cfg: WorkerConfig,
    worker_state: *WorkerState,
    prompts: *const agents.PromptFiles,
    profile: *const topology.Profile,
    token_cache: *github_auth.TokenCache,
    tenant_limiter: *TenantRateLimiter,
    queued_run_id: []const u8,
) !void {
    var claim_arena = std.heap.ArenaAllocator.init(alloc);
    defer claim_arena.deinit();
    const claim_alloc = claim_arena.allocator();

    var conn = try cfg.pool.acquire();
    defer cfg.pool.release(conn);

    try beginTx(conn);
    var tx_open = true;
    errdefer if (tx_open) rollbackTx(conn);

    // Claim a queued run under transaction.
    var result = try conn.query(
        \\SELECT r.run_id, r.workspace_id, r.spec_id, r.tenant_id, r.attempt, r.request_id,
        \\       w.repo_url, w.default_branch,
        \\       s.file_path
        \\FROM runs r
        \\JOIN workspaces w ON w.workspace_id = r.workspace_id
        \\JOIN specs s ON s.spec_id = r.spec_id
        \\WHERE r.run_id = $1 AND r.state = 'SPEC_QUEUED' AND w.paused = false
        \\LIMIT 1
        \\FOR UPDATE OF r SKIP LOCKED
    , .{queued_run_id});
    defer result.deinit();

    const row = (try result.next()) orelse {
        try commitTx(conn);
        tx_open = false;
        return;
    };

    const run_id = try claim_alloc.dupe(u8, try row.get([]u8, 0));
    const workspace_id = try claim_alloc.dupe(u8, try row.get([]u8, 1));
    const spec_id = try claim_alloc.dupe(u8, try row.get([]u8, 2));
    const tenant_id = try claim_alloc.dupe(u8, try row.get([]u8, 3));
    const attempt = @as(u32, @intCast(try row.get(i32, 4)));
    const request_id_raw = try row.get(?[]u8, 5);
    const request_id = try claim_alloc.dupe(u8, request_id_raw orelse "-");
    const repo_url = try claim_alloc.dupe(u8, try row.get([]u8, 6));
    const default_branch = try claim_alloc.dupe(u8, try row.get([]u8, 7));
    const spec_path = try claim_alloc.dupe(u8, try row.get([]u8, 8));

    result.drain() catch |err| {
        obs_log.logWarnErr(.worker, err, "claim query drain failed run_id={s}", .{run_id});
    };

    // Move SPEC_QUEUED -> RUN_PLANNED while the row is still locked.
    _ = try state.transition(conn, run_id, .RUN_PLANNED, .orchestrator, .PLAN_COMPLETE, "claimed by worker");

    try commitTx(conn);
    tx_open = false;

    var workspace_profile: ?topology.Profile = profile_resolver.loadWorkspaceActiveProfile(alloc, conn, workspace_id) catch |err| blk: {
        obs_log.logWarnErr(.worker, err, "active profile load failed; fallback to default workspace_id={s}", .{workspace_id});
        break :blk null;
    };
    defer if (workspace_profile) |*p| p.deinit();

    const effective_profile: *const topology.Profile = if (workspace_profile) |*p| p else profile;
    const using_fallback = workspace_profile == null;
    log.info("workspace profile resolved workspace_id={s} profile={s} fallback_default_v1={}", .{
        workspace_id,
        effective_profile.profile_id,
        using_fallback,
    });

    try beginRunIfActive(worker_state);
    defer worker_state.endRun();

    log.info("claimed run run_id={s} request_id={s} attempt={d}", .{ run_id, request_id, attempt });
    var claimed_detail: [128]u8 = undefined;
    const claimed_detail_slice = std.fmt.bufPrint(
        &claimed_detail,
        "request_id={s} attempt={d}",
        .{ request_id, attempt },
    ) catch "run_claimed";
    events.emit("run_claimed", run_id, claimed_detail_slice);

    worker_stage_executor.executeRun(alloc, .{
        .cache_root = cfg.cache_root,
        .max_attempts = cfg.max_attempts,
        .run_timeout_ms = cfg.run_timeout_ms,
        .skill_registry = cfg.skill_registry,
    }, &worker_state.running, prompts, effective_profile, conn, token_cache, .{
        .run_id = run_id,
        .request_id = request_id,
        .workspace_id = workspace_id,
        .spec_id = spec_id,
        .tenant_id = tenant_id,
        .repo_url = repo_url,
        .default_branch = default_branch,
        .spec_path = spec_path,
        .attempt = attempt,
    }, tenant_limiter) catch |err| {
        if (err == WorkerError.ShutdownRequested or err == WorkerError.RunDeadlineExceeded) {
            const reason_note = if (err == WorkerError.RunDeadlineExceeded) "run deadline exceeded" else "shutdown requested";
            _ = state.transition(conn, run_id, .BLOCKED, .orchestrator, .AGENT_TIMEOUT, reason_note) catch |tx_err| {
                obs_log.logWarnErr(.worker, tx_err, "shutdown transition failed run_id={s}", .{run_id});
            };
            if (err == WorkerError.RunDeadlineExceeded) {
                events.emit("run_deadline_exceeded", run_id, reason_note);
            }
            metrics.incRunsBlocked();
            return err;
        }

        const classified = err_classify.classify(err, null);
        var note_buf: [192]u8 = undefined;
        const note = std.fmt.bufPrint(&note_buf, "class={s} err={s}", .{
            @tagName(classified.class),
            @errorName(err),
        }) catch @errorName(err);
        log.err("run failed run_id={s} class={s} retryable={} err={s}", .{
            run_id,
            @tagName(classified.class),
            classified.retryable,
            @errorName(err),
        });
        var failed_detail: [224]u8 = undefined;
        const failed_detail_slice = std.fmt.bufPrint(
            &failed_detail,
            "request_id={s} class={s} retryable={} err={s}",
            .{ request_id, @tagName(classified.class), classified.retryable, @errorName(err) },
        ) catch "run_failed";
        events.emit("run_failed", run_id, failed_detail_slice);
        _ = state.transition(conn, run_id, .BLOCKED, .orchestrator, classified.reason_code, note) catch |tx_err| {
            obs_log.logWarnErr(.worker, tx_err, "failure transition failed run_id={s}", .{run_id});
        };
        metrics.incRunsBlocked();
    };
    return;
}

fn openWorkerTestConn(alloc: std.mem.Allocator) !?struct { pool: *db.Pool, conn: *pg.Conn } {
    const url = std.process.getEnvVarOwned(alloc, "WORKER_DB_TEST_URL") catch
        std.process.getEnvVarOwned(alloc, "DATABASE_URL") catch return null;
    defer alloc.free(url);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const opts = try db.parseUrl(arena.allocator(), url);
    const pool = try pg.Pool.init(alloc, opts);
    errdefer pool.deinit();
    const conn = try pool.acquire();
    return .{ .pool = pool, .conn = conn };
}

test "integration: workspace active profile is loaded for worker execution" {
    const db_ctx = (try openWorkerTestConn(std.testing.allocator)) orelse return error.SkipZigTest;
    defer db_ctx.pool.release(db_ctx.conn);
    defer db_ctx.pool.deinit();

    {
        var q = try db_ctx.conn.query(
            \\CREATE TEMP TABLE agent_profile_versions (
            \\  profile_version_id TEXT PRIMARY KEY,
            \\  compiled_profile_json TEXT,
            \\  is_valid BOOLEAN NOT NULL
            \\) ON COMMIT DROP
        , .{});
        q.deinit();
    }
    {
        var q = try db_ctx.conn.query(
            \\CREATE TEMP TABLE workspace_active_profile (
            \\  workspace_id TEXT PRIMARY KEY,
            \\  profile_version_id TEXT NOT NULL
            \\) ON COMMIT DROP
        , .{});
        q.deinit();
    }

    const compiled =
        \\{
        \\  "profile_id": "acme-harness-v1",
        \\  "stages": [
        \\    {"stage_id":"plan","role":"planner","skill":"echo"},
        \\    {"stage_id":"implement","role":"implementer","skill":"scout"},
        \\    {"stage_id":"verify","role":"security","skill":"warden","gate":true,"on_pass":"done","on_fail":"retry"}
        \\  ]
        \\}
    ;
    {
        var q = try db_ctx.conn.query(
            "INSERT INTO agent_profile_versions (profile_version_id, compiled_profile_json, is_valid) VALUES ('pver_1', $1, TRUE)",
            .{compiled},
        );
        q.deinit();
    }
    {
        var q = try db_ctx.conn.query(
            "INSERT INTO workspace_active_profile (workspace_id, profile_version_id) VALUES ('ws_1', 'pver_1')",
            .{},
        );
        q.deinit();
    }

    var profile = (try profile_resolver.loadWorkspaceActiveProfile(std.testing.allocator, db_ctx.conn, "ws_1")) orelse return error.TestUnexpectedResult;
    defer profile.deinit();
    try std.testing.expectEqualStrings("acme-harness-v1", profile.profile_id);
    try std.testing.expectEqual(@as(usize, 3), profile.stages.len);
}

test "integration: worker profile fallback path returns null when no active binding" {
    const db_ctx = (try openWorkerTestConn(std.testing.allocator)) orelse return error.SkipZigTest;
    defer db_ctx.pool.release(db_ctx.conn);
    defer db_ctx.pool.deinit();

    {
        var q = try db_ctx.conn.query(
            \\CREATE TEMP TABLE agent_profile_versions (
            \\  profile_version_id TEXT PRIMARY KEY,
            \\  compiled_profile_json TEXT,
            \\  is_valid BOOLEAN NOT NULL
            \\) ON COMMIT DROP
        , .{});
        q.deinit();
    }
    {
        var q = try db_ctx.conn.query(
            \\CREATE TEMP TABLE workspace_active_profile (
            \\  workspace_id TEXT PRIMARY KEY,
            \\  profile_version_id TEXT NOT NULL
            \\) ON COMMIT DROP
        , .{});
        q.deinit();
    }

    const none = try profile_resolver.loadWorkspaceActiveProfile(std.testing.allocator, db_ctx.conn, "ws_missing");
    try std.testing.expect(none == null);
}

test "integration: default topology roles resolve through registry" {
    var profile = try topology.defaultProfile(std.testing.allocator);
    defer profile.deinit();

    for (profile.stages) |stage| {
        try std.testing.expect(resolveBinding(.{}, stage.role_id, stage.skill_id) != null);
    }
}

test "worker state in-flight run counter tracks begin/end safely" {
    var ws = WorkerState.init();
    try std.testing.expectEqual(@as(u32, 0), ws.currentInFlightRuns());
    ws.beginRun();
    ws.beginRun();
    try std.testing.expectEqual(@as(u32, 2), ws.currentInFlightRuns());
    ws.endRun();
    try std.testing.expectEqual(@as(u32, 1), ws.currentInFlightRuns());
    ws.endRun();
    try std.testing.expectEqual(@as(u32, 0), ws.currentInFlightRuns());
}

test "beginRunIfActive rejects stopped worker without incrementing in-flight" {
    var ws = WorkerState.init();
    ws.running.store(false, .release);

    try std.testing.expectError(WorkerError.ShutdownRequested, beginRunIfActive(&ws));
    try std.testing.expectEqual(@as(u32, 0), ws.currentInFlightRuns());
}

test "beginRunIfActive increments in-flight when running" {
    var ws = WorkerState.init();
    ws.running.store(true, .release);

    try beginRunIfActive(&ws);
    try std.testing.expectEqual(@as(u32, 1), ws.currentInFlightRuns());
    ws.endRun();
    try std.testing.expectEqual(@as(u32, 0), ws.currentInFlightRuns());
}

const CounterRaceCtx = struct {
    ws: *WorkerState,
    iterations: u32,
};

fn runBalancedCounterLoop(ctx: CounterRaceCtx) void {
    var i: u32 = 0;
    while (i < ctx.iterations) : (i += 1) {
        ctx.ws.beginRun();
        ctx.ws.endRun();
    }
}

test "integration: worker state in-flight run counter is balanced across threads" {
    var ws = WorkerState.init();
    const thread_count: usize = 6;
    const iterations: u32 = 500;

    const threads = try std.testing.allocator.alloc(std.Thread, thread_count);
    defer std.testing.allocator.free(threads);

    for (threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, runBalancedCounterLoop, .{CounterRaceCtx{
            .ws = &ws,
            .iterations = iterations,
        }});
    }
    for (threads) |*thread| thread.join();

    try std.testing.expectEqual(@as(u32, 0), ws.currentInFlightRuns());
}

test "integration: finalizeWorkerAllocator returns false for clean allocator" {
    var gpa = WorkerAllocator{};
    const alloc = gpa.allocator();
    const buf = try alloc.alloc(u8, 32);
    alloc.free(buf);

    try std.testing.expect(!finalizeWorkerAllocator(&gpa));
}

test "integration: finalizeWorkerAllocator returns true when leaks are present" {
    var gpa = WorkerAllocator{};
    const alloc = gpa.allocator();
    const leaked = try alloc.alloc(u8, 32);
    _ = leaked;

    try std.testing.expect(finalizeWorkerAllocator(&gpa));
}
