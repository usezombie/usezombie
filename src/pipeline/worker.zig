//! Worker loop — Thread 2.
//! Reads Redis stream queue messages for run claims (fail-closed when queue is unavailable).
//! Executes pipeline stages from a topology profile (default: Echo → Scout → Warden).
//! Commits stage artifacts to git branch. Runs sequentially per run.

const std = @import("std");
const pg = @import("pg");
const db = @import("../db/pool.zig");
const types = @import("../types.zig");
const state = @import("../state/machine.zig");
const agents = @import("agents.zig");
const git = @import("../git/ops.zig");
const github_auth = @import("../auth/github.zig");
const memory = @import("../memory/workspace.zig");
const secrets = @import("../secrets/crypto.zig");
const backoff = @import("../reliability/backoff.zig");
const err_classify = @import("../reliability/error_classify.zig");
const reliable = @import("../reliability/reliable_call.zig");
const topology = @import("topology.zig");
const profile_resolver = @import("profile_resolver.zig");
const side_effect_keys = @import("worker_side_effect_keys.zig");
const worker_runtime = @import("worker_runtime.zig");
const worker_paths = @import("worker_paths.zig");
const worker_rate_limiter = @import("worker_rate_limiter.zig");
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

const RunContext = struct {
    run_id: []const u8,
    request_id: []const u8,
    workspace_id: []const u8,
    spec_id: []const u8,
    tenant_id: []const u8,
    repo_url: []const u8,
    default_branch: []const u8,
    spec_path: []const u8,
    attempt: u32,
};

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

    executeRun(alloc, cfg, worker_state, prompts, effective_profile, conn, token_cache, .{
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

fn loadInstallationId(
    alloc: std.mem.Allocator,
    conn: *pg.Conn,
    workspace_id: []const u8,
) ![]u8 {
    const kek = secrets.loadKek(alloc) catch {
        return WorkerError.MissingGitHubInstallation;
    };

    const from_vault = secrets.load(alloc, conn, workspace_id, "github_app_installation_id", kek) catch {
        return WorkerError.MissingGitHubInstallation;
    };
    return from_vault;
}

fn getExistingPrUrl(alloc: std.mem.Allocator, conn: *pg.Conn, run_id: []const u8) !?[]u8 {
    var result = try conn.query("SELECT pr_url FROM runs WHERE run_id = $1", .{run_id});
    defer result.deinit();

    const row = try result.next() orelse return null;
    const value = try row.get(?[]u8, 0);
    if (value) |pr| {
        return alloc.dupe(u8, pr);
    }
    return null;
}

const TokenRetryCtx = struct {
    cache: *github_auth.TokenCache,
    alloc: std.mem.Allocator,
    installation_id: []const u8,
    last_error_detail: ?[]u8 = null,
};

fn opGetInstallationToken(ctx: *TokenRetryCtx, _: u32) ![]u8 {
    if (ctx.last_error_detail) |d| ctx.alloc.free(d);
    ctx.last_error_detail = null;
    return ctx.cache.getInstallationTokenWithDetail(ctx.alloc, ctx.installation_id, &ctx.last_error_detail);
}

fn tokenDetail(ctx: *TokenRetryCtx, _: anyerror) ?[]const u8 {
    return ctx.last_error_detail;
}

const PushRetryCtx = struct {
    alloc: std.mem.Allocator,
    wt_path: []const u8,
    branch: []const u8,
    github_token: []const u8,
};

fn opPushBranch(ctx: PushRetryCtx, _: u32) !void {
    return git.push(ctx.alloc, ctx.wt_path, ctx.branch, ctx.github_token);
}

const BareCloneRetryCtx = struct {
    alloc: std.mem.Allocator,
    cache_root: []const u8,
    workspace_id: []const u8,
    repo_url: []const u8,
};

fn opEnsureBareClone(ctx: BareCloneRetryCtx, _: u32) ![]const u8 {
    return git.ensureBareClone(ctx.alloc, ctx.cache_root, ctx.workspace_id, ctx.repo_url);
}

const WorktreeRetryCtx = struct {
    alloc: std.mem.Allocator,
    bare_path: []const u8,
    run_id: []const u8,
    base_branch: []const u8,
};

fn opCreateWorktree(ctx: WorktreeRetryCtx, _: u32) !git.WorktreeHandle {
    return git.createWorktree(ctx.alloc, ctx.bare_path, ctx.run_id, ctx.base_branch);
}

const ScoutRetryCtx = struct {
    alloc: std.mem.Allocator,
    workspace_path: []const u8,
    prompt: []const u8,
    plan_content: []const u8,
    defects_content: ?[]const u8,
};

fn opRunScout(ctx: ScoutRetryCtx, _: u32) !agents.AgentResult {
    return agents.runScout(
        ctx.alloc,
        ctx.workspace_path,
        ctx.prompt,
        ctx.plan_content,
        ctx.defects_content,
    );
}

const WardenRetryCtx = struct {
    alloc: std.mem.Allocator,
    workspace_path: []const u8,
    prompt: []const u8,
    spec_content: []const u8,
    plan_content: []const u8,
    implementation_summary: []const u8,
};

fn opRunWarden(ctx: WardenRetryCtx, _: u32) !agents.AgentResult {
    return agents.runWarden(
        ctx.alloc,
        ctx.workspace_path,
        ctx.prompt,
        ctx.spec_content,
        ctx.plan_content,
        ctx.implementation_summary,
    );
}

const PrRetryCtx = struct {
    alloc: std.mem.Allocator,
    repo_url: []const u8,
    branch: []const u8,
    base_branch: []const u8,
    title: []const u8,
    body: []const u8,
    github_token: []const u8,
    last_error_detail: ?[]u8 = null,
};

fn opCreatePr(ctx: *PrRetryCtx, _: u32) ![]u8 {
    ctx.last_error_detail = null;
    return git.createPullRequest(
        ctx.alloc,
        ctx.repo_url,
        ctx.branch,
        ctx.base_branch,
        ctx.title,
        ctx.body,
        ctx.github_token,
        &ctx.last_error_detail,
    );
}

fn prDetail(ctx: *PrRetryCtx, _: anyerror) ?[]const u8 {
    return ctx.last_error_detail;
}

fn tryRecoverPrUrl(
    run_alloc: std.mem.Allocator,
    conn: *pg.Conn,
    token_cache: *github_auth.TokenCache,
    tenant_limiter: *TenantRateLimiter,
    worker_state: *WorkerState,
    deadline_ms: i64,
    ctx: RunContext,
    branch: []const u8,
) !?[]u8 {
    try worker_runtime.ensureRunActive(&worker_state.running, deadline_ms);
    const installation_id = loadInstallationId(run_alloc, conn, ctx.workspace_id) catch return null;
    defer run_alloc.free(installation_id);

    try tenant_limiter.acquireCancelable(ctx.tenant_id, "github_installation_token", 1.0, &worker_state.running, deadline_ms);
    var token_retry_ctx = TokenRetryCtx{
        .cache = token_cache,
        .alloc = run_alloc,
        .installation_id = installation_id,
    };
    defer if (token_retry_ctx.last_error_detail) |d| run_alloc.free(d);
    const github_token = try reliable.callWithDetail(
        []u8,
        &token_retry_ctx,
        opGetInstallationToken,
        tokenDetail,
        worker_runtime.retryOptionsForRun(&worker_state.running, deadline_ms, 2, 500, 5_000, "github_installation_token"),
    );
    defer run_alloc.free(github_token);

    var detail: ?[]u8 = null;
    defer if (detail) |d| run_alloc.free(d);

    try tenant_limiter.acquireCancelable(ctx.tenant_id, "github_pr_lookup", 1.0, &worker_state.running, deadline_ms);
    const existing = try git.findOpenPullRequestByHead(
        run_alloc,
        ctx.repo_url,
        branch,
        github_token,
        &detail,
    );
    if (existing) |pr_url| {
        var side_effect_key_buf: [192]u8 = undefined;
        const side_effect_key = try side_effect_keys.sideEffectKeyPrCreate(run_alloc, &side_effect_key_buf, branch);
        defer side_effect_key.deinit(run_alloc);
        try state.markSideEffectDone(conn, ctx.run_id, side_effect_key.value, pr_url);
        return pr_url;
    }
    return null;
}

const StageRetryCtx = struct {
    alloc: std.mem.Allocator,
    binding: agents.RoleBinding,
    input: agents.RoleInput,
};

fn opRunStage(ctx: StageRetryCtx, _: u32) !agents.AgentResult {
    return agents.runByRole(ctx.alloc, ctx.binding, ctx.input);
}

const CommitRetryCtx = struct {
    alloc: std.mem.Allocator,
    wt_path: []const u8,
    rel_path: []const u8,
    content: []const u8,
    msg: []const u8,
};

fn opCommitArtifact(ctx: CommitRetryCtx, _: u32) !void {
    return git.commitFile(ctx.alloc, ctx.wt_path, ctx.rel_path, ctx.content, ctx.msg, "UseZombie Bot", "bot@usezombie.dev");
}

const StageTransition = union(enum) {
    stage_index: usize,
    done,
    retry,
    blocked,
};

fn resolveBinding(cfg: WorkerConfig, role_id: []const u8, skill_id: []const u8) ?agents.RoleBinding {
    if (cfg.skill_registry) |registry| {
        if (agents.resolveRoleWithRegistry(registry, role_id, skill_id)) |binding| return binding;
    }
    return agents.resolveRole(role_id, skill_id);
}

fn resolveStageTransition(profile: *const topology.Profile, current_index: usize, passed: bool) !StageTransition {
    const stage = profile.stages[current_index];
    const explicit_target = if (passed) stage.on_pass else stage.on_fail;

    if (explicit_target) |target| {
        if (std.ascii.eqlIgnoreCase(target, topology.TRANSITION_DONE)) return .done;
        if (std.ascii.eqlIgnoreCase(target, topology.TRANSITION_RETRY)) return .retry;
        if (std.ascii.eqlIgnoreCase(target, topology.TRANSITION_BLOCKED)) return .blocked;
        if (profile.indexOfStage(target)) |index| return .{ .stage_index = index };
        return WorkerError.InvalidPipelineProfile;
    }

    if (passed) {
        if (current_index + 1 < profile.stages.len) return .{ .stage_index = current_index + 1 };
        return .done;
    }
    return .retry;
}

fn executeRun(
    alloc: std.mem.Allocator,
    cfg: WorkerConfig,
    worker_state: *WorkerState,
    prompts: *const agents.PromptFiles,
    profile: *const topology.Profile,
    conn: *pg.Conn,
    token_cache: *github_auth.TokenCache,
    ctx: RunContext,
    tenant_limiter: *TenantRateLimiter,
) !void {
    const deadline_ms = std.time.milliTimestamp() + @as(i64, @intCast(cfg.run_timeout_ms));
    try worker_runtime.ensureRunActive(&worker_state.running, deadline_ms);

    var run_arena = std.heap.ArenaAllocator.init(alloc);
    defer run_arena.deinit();
    const run_alloc = run_arena.allocator();

    if (!worker_state.running.load(.acquire)) return WorkerError.ShutdownRequested;

    // ── Set up git worktree ───────────────────────────────────────────────
    const bare_path = try reliable.call([]const u8, BareCloneRetryCtx{
        .alloc = run_alloc,
        .cache_root = cfg.cache_root,
        .workspace_id = ctx.workspace_id,
        .repo_url = ctx.repo_url,
    }, opEnsureBareClone, worker_runtime.retryOptionsForRun(&worker_state.running, deadline_ms, 2, 500, 5_000, "git_ensure_bare_clone"));

    var wt = try reliable.call(git.WorktreeHandle, WorktreeRetryCtx{
        .alloc = run_alloc,
        .bare_path = bare_path,
        .run_id = ctx.run_id,
        .base_branch = ctx.default_branch,
    }, opCreateWorktree, worker_runtime.retryOptionsForRun(&worker_state.running, deadline_ms, 2, 500, 5_000, "git_create_worktree"));
    defer {
        git.removeWorktree(run_alloc, bare_path, wt.path);
        wt.deinit();
    }

    const branch = try std.fmt.allocPrint(run_alloc, "zombie/run-{s}", .{ctx.run_id});

    // ── Read spec from worktree (canonicalized path) ─────────────────────
    const spec_abs = try worker_paths.resolveSpecPath(run_alloc, wt.path, ctx.spec_path);
    const spec_file = try std.fs.openFileAbsolute(spec_abs, .{});
    defer spec_file.close();
    const spec_content = try spec_file.readToEndAlloc(run_alloc, 512 * 1024);

    // ── Load workspace memories for Echo ─────────────────────────────────
    const memory_context = try memory.loadForEcho(run_alloc, conn, ctx.workspace_id, 20);

    // ── Stage 1: planning stage (echo role in default profile) ─────────
    const plan_stage = profile.stages[0];
    const plan_binding = resolveBinding(cfg, plan_stage.role_id, plan_stage.skill_id) orelse return WorkerError.InvalidPipelineRole;

    try worker_runtime.ensureRunActive(&worker_state.running, deadline_ms);
    try tenant_limiter.acquireCancelable(ctx.tenant_id, plan_stage.skill_id, 1.0, &worker_state.running, deadline_ms);
    const plan_result = try reliable.call(agents.AgentResult, StageRetryCtx{
        .alloc = run_alloc,
        .binding = plan_binding,
        .input = .{
            .workspace_path = wt.path,
            .prompts = prompts,
            .spec_content = spec_content,
            .memory_context = memory_context,
        },
    }, opRunStage, worker_runtime.retryOptionsForRun(&worker_state.running, deadline_ms, 1, 1_000, 8_000, plan_stage.skill_id));
    metrics.incAgentEchoCalls();
    metrics.addAgentTokens(plan_result.token_count);
    metrics.observeAgentDurationSeconds(plan_result.wall_seconds);

    agents.emitNullclawRunEvent(
        ctx.run_id,
        ctx.request_id,
        ctx.attempt,
        plan_stage.stage_id,
        plan_stage.role_id,
        plan_binding.actor,
        plan_result,
    );
    try state.writeUsage(conn, ctx.run_id, ctx.attempt, plan_binding.actor, plan_result.token_count, plan_result.wall_seconds);

    const plan_path = try std.fmt.allocPrint(run_alloc, "docs/runs/{s}/{s}", .{ ctx.run_id, plan_stage.artifact_name });
    try commitArtifact(
        run_alloc,
        conn,
        ctx,
        &wt,
        worker_state,
        deadline_ms,
        plan_path,
        plan_result.content,
        plan_stage.commit_message,
        plan_binding.actor,
        ctx.attempt,
    );

    if (profile.stages.len < 2) return WorkerError.InvalidPipelineProfile;

    var attempt = ctx.attempt;
    var defects: ?[]const u8 = null;

    var total_tokens: u64 = plan_result.token_count;
    var total_wall_seconds: u64 = plan_result.wall_seconds;

    while (attempt <= cfg.max_attempts) : (attempt += 1) {
        try worker_runtime.ensureRunActive(&worker_state.running, deadline_ms);

        // ── Execute stage graph from stage index 1 ───────────────────────
        _ = try state.transition(conn, ctx.run_id, .PATCH_IN_PROGRESS, .orchestrator, .PATCH_STARTED, null);

        var latest_build_output: []const u8 = plan_result.content;
        var current_stage_index: usize = 1;
        var verification_started = false;
        var final_stage_output: []const u8 = plan_result.content;
        var final_stage_actor: types.Actor = .orchestrator;
        var terminal = StageTransition.retry;

        while (true) {
            const stage = profile.stages[current_stage_index];
            const binding = resolveBinding(cfg, stage.role_id, stage.skill_id) orelse return WorkerError.InvalidPipelineRole;

            if (stage.is_gate and !verification_started) {
                _ = try state.transition(conn, ctx.run_id, .PATCH_READY, .scout, .PATCH_COMMITTED, null);
                _ = try state.transition(conn, ctx.run_id, .VERIFICATION_IN_PROGRESS, .orchestrator, .PATCH_STARTED, null);
                verification_started = true;
            }

            log.info("stage start run_id={s} stage_id={s} role={s} attempt={d}", .{
                ctx.run_id,
                stage.stage_id,
                stage.role_id,
                attempt,
            });

            try tenant_limiter.acquireCancelable(ctx.tenant_id, stage.skill_id, 1.0, &worker_state.running, deadline_ms);
            try worker_runtime.ensureRunActive(&worker_state.running, deadline_ms);
            const stage_result = try reliable.call(agents.AgentResult, StageRetryCtx{
                .alloc = run_alloc,
                .binding = binding,
                .input = .{
                    .workspace_path = wt.path,
                    .prompts = prompts,
                    .spec_content = spec_content,
                    .plan_content = plan_result.content,
                    .defects_content = defects,
                    .implementation_summary = latest_build_output,
                },
            }, opRunStage, worker_runtime.retryOptionsForRun(&worker_state.running, deadline_ms, 1, 1_000, 8_000, stage.skill_id));

            switch (binding.actor) {
                .echo => metrics.incAgentEchoCalls(),
                .scout => metrics.incAgentScoutCalls(),
                .warden => metrics.incAgentWardenCalls(),
                .orchestrator => {},
            }
            metrics.addAgentTokens(stage_result.token_count);
            metrics.observeAgentDurationSeconds(stage_result.wall_seconds);

            agents.emitNullclawRunEvent(
                ctx.run_id,
                ctx.request_id,
                attempt,
                stage.stage_id,
                stage.role_id,
                binding.actor,
                stage_result,
            );
            total_tokens += stage_result.token_count;
            total_wall_seconds += stage_result.wall_seconds;
            try state.writeUsage(conn, ctx.run_id, attempt, binding.actor, stage_result.token_count, stage_result.wall_seconds);

            const stage_path = try std.fmt.allocPrint(run_alloc, "docs/runs/{s}/{s}", .{ ctx.run_id, stage.artifact_name });
            try commitArtifact(run_alloc, conn, ctx, &wt, worker_state, deadline_ms, stage_path, stage_result.content, stage.commit_message, binding.actor, attempt);
            latest_build_output = stage_result.content;
            final_stage_output = stage_result.content;
            final_stage_actor = binding.actor;

            const passed = if (binding.actor == .warden) agents.parseWardenVerdict(stage_result.content) else true;
            if (binding.actor == .warden) {
                const observations = try agents.extractObservations(run_alloc, stage_result.content);
                if (observations.len > 0) {
                    _ = try memory.saveFromWarden(conn, ctx.workspace_id, ctx.run_id, observations);
                }
            }

            terminal = try resolveStageTransition(profile, current_stage_index, passed);
            switch (terminal) {
                .stage_index => |next_index| {
                    current_stage_index = next_index;
                    continue;
                },
                else => break,
            }
        }

        switch (terminal) {
            .done => {
                // ── PASS: create PR ──────────────────────────────────────────
                _ = try state.transition(conn, ctx.run_id, .PR_PREPARED, final_stage_actor, .VALIDATION_PASSED, null);

                var pr_url = try getExistingPrUrl(run_alloc, conn, ctx.run_id);
                if (pr_url == null) {
                    try worker_runtime.ensureRunActive(&worker_state.running, deadline_ms);
                    const installation_id = try loadInstallationId(run_alloc, conn, ctx.workspace_id);
                    defer run_alloc.free(installation_id);

                    try tenant_limiter.acquireCancelable(ctx.tenant_id, "github_installation_token", 1.0, &worker_state.running, deadline_ms);
                    var token_retry_ctx = TokenRetryCtx{
                        .cache = token_cache,
                        .alloc = run_alloc,
                        .installation_id = installation_id,
                    };
                    defer if (token_retry_ctx.last_error_detail) |d| run_alloc.free(d);
                    const github_token = try reliable.callWithDetail(
                        []u8,
                        &token_retry_ctx,
                        opGetInstallationToken,
                        tokenDetail,
                        worker_runtime.retryOptionsForRun(&worker_state.running, deadline_ms, 2, 500, 5_000, "github_installation_token"),
                    );
                    defer run_alloc.free(github_token);

                    var push_side_effect_key_buf: [192]u8 = undefined;
                    const push_side_effect_key = try side_effect_keys.sideEffectKeyPush(run_alloc, &push_side_effect_key_buf, branch);
                    defer push_side_effect_key.deinit(run_alloc);
                    const push_claimed = try state.claimSideEffect(conn, ctx.run_id, push_side_effect_key.value, branch);
                    if (push_claimed) {
                        try worker_runtime.ensureRunActive(&worker_state.running, deadline_ms);
                        try tenant_limiter.acquireCancelable(ctx.tenant_id, "github_push", 1.0, &worker_state.running, deadline_ms);
                        try reliable.call(void, PushRetryCtx{
                            .alloc = run_alloc,
                            .wt_path = wt.path,
                            .branch = branch,
                            .github_token = github_token,
                        }, opPushBranch, worker_runtime.retryOptionsForRun(&worker_state.running, deadline_ms, 2, 1_000, 10_000, "github_push"));
                        try state.markSideEffectDone(conn, ctx.run_id, push_side_effect_key.value, branch);
                    } else {
                        const already_pushed = try git.remoteBranchExists(run_alloc, wt.path, branch, github_token);
                        if (!already_pushed) return WorkerError.SideEffectClaimedNoResult;
                        try state.markSideEffectDone(conn, ctx.run_id, push_side_effect_key.value, branch);
                    }

                    var pr_side_effect_key_buf: [192]u8 = undefined;
                    const pr_side_effect_key = try side_effect_keys.sideEffectKeyPrCreate(run_alloc, &pr_side_effect_key_buf, branch);
                    defer pr_side_effect_key.deinit(run_alloc);
                    const pr_claimed = try state.claimSideEffect(conn, ctx.run_id, pr_side_effect_key.value, branch);
                    if (!pr_claimed) {
                        pr_url = try getExistingPrUrl(run_alloc, conn, ctx.run_id);
                        if (pr_url == null) {
                            pr_url = try tryRecoverPrUrl(run_alloc, conn, token_cache, tenant_limiter, worker_state, deadline_ms, ctx, branch);
                            if (pr_url == null) return WorkerError.SideEffectClaimedNoResult;
                        }
                    }

                    if (pr_url == null) {
                        try worker_runtime.ensureRunActive(&worker_state.running, deadline_ms);
                        const pr_title = try std.fmt.allocPrint(run_alloc, "usezombie: {s}", .{ctx.spec_id});

                        var pr_retry_ctx = PrRetryCtx{
                            .alloc = run_alloc,
                            .repo_url = ctx.repo_url,
                            .branch = branch,
                            .base_branch = ctx.default_branch,
                            .title = pr_title,
                            .body = final_stage_output,
                            .github_token = github_token,
                        };
                        try tenant_limiter.acquireCancelable(ctx.tenant_id, "github_pr_create", 1.0, &worker_state.running, deadline_ms);
                        const created_pr = try reliable.callWithDetail(
                            []u8,
                            &pr_retry_ctx,
                            opCreatePr,
                            prDetail,
                            worker_runtime.retryOptionsForRun(&worker_state.running, deadline_ms, 2, 1_000, 10_000, "github_pr_create"),
                        );
                        pr_url = created_pr;
                        try state.markSideEffectDone(conn, ctx.run_id, pr_side_effect_key.value, created_pr);
                    }
                }

                const pr_final = pr_url orelse return git.GitError.PrFailed;

                // Update run with PR URL
                {
                    const now_ms = std.time.milliTimestamp();
                    var r = try conn.query(
                        "UPDATE runs SET pr_url = $1, updated_at = $2 WHERE run_id = $3",
                        .{ pr_final, now_ms, ctx.run_id },
                    );
                    r.deinit();
                }

                _ = try state.transition(conn, ctx.run_id, .PR_OPENED, .orchestrator, .PR_CREATED, pr_final);
                _ = try state.transition(conn, ctx.run_id, .NOTIFIED, .orchestrator, .NOTIFICATION_SENT, null);
                _ = try state.transition(conn, ctx.run_id, .DONE, .orchestrator, .NOTIFICATION_SENT, null);

                const summary_content = std.fmt.allocPrint(
                    run_alloc,
                    "# Run Summary\n\n" ++
                        "- **run_id**: {s}\n" ++
                        "- **spec_id**: {s}\n" ++
                        "- **final_state**: DONE\n" ++
                        "- **attempt**: {d}\n" ++
                        "- **pr_url**: {s}\n" ++
                        "- **total_tokens**: {d}\n" ++
                        "- **total_wall_seconds**: {d}\n" ++
                        "\n## Artifacts\n\n" ++
                        "- plan.json (echo)\n" ++
                        "- implementation.md (scout)\n" ++
                        "- validation.md (warden)\n" ++
                        "- run_summary.md (orchestrator)\n",
                    .{
                        ctx.run_id,
                        ctx.spec_id,
                        attempt,
                        pr_final,
                        total_tokens,
                        total_wall_seconds,
                    },
                ) catch |err| {
                    obs_log.logWarnErr(.worker, err, "run_summary.md alloc failed (non-fatal) run_id={s}", .{ctx.run_id});
                    log.info("run completed run_id={s} pr_url={s}", .{ ctx.run_id, pr_final });
                    var done_detail: [160]u8 = undefined;
                    const done_detail_slice = std.fmt.bufPrint(
                        &done_detail,
                        "request_id={s} state=done total_wall_seconds={d}",
                        .{ ctx.request_id, total_wall_seconds },
                    ) catch "run_done";
                    events.emit("run_done", ctx.run_id, done_detail_slice);
                    metrics.observeRunTotalWallSeconds(total_wall_seconds);
                    metrics.incRunsCompleted();
                    return;
                };

                const summary_path = try std.fmt.allocPrint(run_alloc, "docs/runs/{s}/run_summary.md", .{ctx.run_id});

                commitArtifact(run_alloc, conn, ctx, &wt, worker_state, deadline_ms, summary_path, summary_content, "orchestrator: add run_summary.md", .orchestrator, attempt) catch |err| {
                    obs_log.logWarnErr(.worker, err, "run_summary.md commit failed (non-fatal) run_id={s}", .{ctx.run_id});
                };

                log.info("run completed run_id={s} pr_url={s}", .{ ctx.run_id, pr_final });
                var done_detail: [160]u8 = undefined;
                const done_detail_slice = std.fmt.bufPrint(
                    &done_detail,
                    "request_id={s} state=done total_wall_seconds={d}",
                    .{ ctx.request_id, total_wall_seconds },
                ) catch "run_done";
                events.emit("run_done", ctx.run_id, done_detail_slice);
                metrics.observeRunTotalWallSeconds(total_wall_seconds);
                metrics.incRunsCompleted();
                return;
            },
            .blocked => {
                _ = try state.transition(conn, ctx.run_id, .BLOCKED, .orchestrator, .VALIDATION_FAILED, "blocked by stage transition graph");
                _ = try state.transition(conn, ctx.run_id, .NOTIFIED_BLOCKED, .orchestrator, .NOTIFICATION_SENT, null);
                metrics.observeRunTotalWallSeconds(total_wall_seconds);
                metrics.incRunsBlocked();
                return;
            },
            .retry => {
                // ── FAIL: prepare for retry if budget remains ───────────────
                _ = try state.transition(conn, ctx.run_id, .VERIFICATION_FAILED, final_stage_actor, .VALIDATION_FAILED, null);

                if (attempt >= cfg.max_attempts) break;

                // Commit defects file and retry from graph entry stage.
                const defects_path = try std.fmt.allocPrint(
                    run_alloc,
                    "docs/runs/{s}/attempt_{d}_defects.md",
                    .{ ctx.run_id, attempt },
                );
                try commitArtifact(run_alloc, conn, ctx, &wt, worker_state, deadline_ms, defects_path, final_stage_output, "warden: add defects", final_stage_actor, attempt);

                defects = try run_alloc.dupe(u8, final_stage_output);

                // Increment attempt counter in DB
                _ = try state.incrementAttempt(conn, ctx.run_id);

                // Adaptive retry delay with jitter.
                const retry_index = attempt - ctx.attempt;
                const delay_ms = backoff.expBackoffJitter(retry_index, 1_000, 30_000);
                metrics.incRunRetries();
                metrics.addBackoffWaitMs(delay_ms);
                try worker_runtime.sleepCooperative(delay_ms, &worker_state.running, deadline_ms);

                log.info("retrying run_id={s} attempt={d}", .{ ctx.run_id, attempt + 1 });
            },
            .stage_index => unreachable,
        }
    }

    // Retries exhausted → BLOCKED
    _ = try state.transition(conn, ctx.run_id, .BLOCKED, .orchestrator, .RETRIES_EXHAUSTED, null);
    _ = try state.transition(conn, ctx.run_id, .NOTIFIED_BLOCKED, .orchestrator, .NOTIFICATION_SENT, null);

    log.warn("run blocked (retries exhausted) run_id={s}", .{ctx.run_id});
    var blocked_detail: [176]u8 = undefined;
    const blocked_detail_slice = std.fmt.bufPrint(
        &blocked_detail,
        "request_id={s} state=blocked reason=retries_exhausted total_wall_seconds={d}",
        .{ ctx.request_id, total_wall_seconds },
    ) catch "run_blocked";
    events.emit("run_blocked", ctx.run_id, blocked_detail_slice);
    metrics.observeRunTotalWallSeconds(total_wall_seconds);
    metrics.incRunsBlocked();
}

// ── Artifact helpers ─────────────────────────────────────────────────────

fn commitArtifact(
    alloc: std.mem.Allocator,
    conn: *pg.Conn,
    ctx: RunContext,
    wt: *git.WorktreeHandle,
    worker_state: *WorkerState,
    deadline_ms: i64,
    rel_path: []const u8,
    content: []const u8,
    msg: []const u8,
    actor: types.Actor,
    attempt: u32,
) !void {
    // Write + commit to git
    try reliable.call(void, CommitRetryCtx{
        .alloc = alloc,
        .wt_path = wt.path,
        .rel_path = rel_path,
        .content = content,
        .msg = msg,
    }, opCommitArtifact, worker_runtime.retryOptionsForRun(&worker_state.running, deadline_ms, 1, 300, 2_000, "git_commit_artifact"));

    // Register in artifacts table
    const checksum = sha256Hex(content);
    const object_key = try std.fmt.allocPrint(alloc, "docs/runs/{s}/{s}", .{ ctx.run_id, std.fs.path.basename(rel_path) });

    const name = std.fs.path.basename(rel_path);
    try state.registerArtifact(conn, ctx.run_id, attempt, name, object_key, &checksum, actor);
}

fn sha256Hex(data: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
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

test "integration: stage transition graph executes pass branch to done" {
    var profile = try topology.defaultProfile(std.testing.allocator);
    defer profile.deinit();

    const verify_idx = profile.indexOfStage(topology.STAGE_VERIFY) orelse return error.TestExpectedEqual;
    const transition = try resolveStageTransition(&profile, verify_idx, true);
    try std.testing.expectEqual(StageTransition.done, transition);
}

test "integration: stage transition graph executes fail branch to retry" {
    var profile = try topology.defaultProfile(std.testing.allocator);
    defer profile.deinit();

    const verify_idx = profile.indexOfStage(topology.STAGE_VERIFY) orelse return error.TestExpectedEqual;
    const transition = try resolveStageTransition(&profile, verify_idx, false);
    try std.testing.expectEqual(StageTransition.retry, transition);
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
