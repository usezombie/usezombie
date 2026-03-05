//! Worker loop — Thread 2.
//! Polls Postgres for SPEC_QUEUED runs via SELECT FOR UPDATE SKIP LOCKED.
//! Executes Echo → Scout → Warden pipeline. Commits artifacts to git branch.
//! Runs sequentially: one spec at a time for M1.

const std = @import("std");
const pg = @import("pg");
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
const rate_limit = @import("../reliability/rate_limit.zig");
const metrics = @import("../observability/metrics.zig");
const log = std.log.scoped(.worker);

// ── Worker configuration ──────────────────────────────────────────────────

pub const WorkerConfig = struct {
    pool: *pg.Pool,
    config_dir: []const u8,
    cache_root: []const u8,
    github_app_id: []const u8,
    github_app_private_key: []const u8,
    max_attempts: u32 = 3,
    poll_interval_ms: u64 = 2_000,
    rate_limit_capacity: u32 = 30,
    rate_limit_refill_per_sec: f64 = 5.0,
};

// ── Worker state shared between HTTP and worker threads ──────────────────

pub const WorkerState = struct {
    running: std.atomic.Value(bool),

    pub fn init() WorkerState {
        return .{ .running = std.atomic.Value(bool).init(true) };
    }
};

// ── Run context ───────────────────────────────────────────────────────────

const RunContext = struct {
    run_id: []const u8,
    workspace_id: []const u8,
    spec_id: []const u8,
    tenant_id: []const u8,
    repo_url: []const u8,
    default_branch: []const u8,
    spec_path: []const u8,
    attempt: u32,
};

const WorkerError = error{
    ShutdownRequested,
    PathTraversal,
    MissingGitHubInstallation,
};

const ProcessOutcome = enum {
    idle,
    worked,
};

const TenantRateLimiter = struct {
    alloc: std.mem.Allocator,
    buckets: std.StringHashMap(rate_limit.TokenBucket),
    capacity: u32,
    refill_per_sec: f64,

    fn init(alloc: std.mem.Allocator, capacity: u32, refill_per_sec: f64) TenantRateLimiter {
        return .{
            .alloc = alloc,
            .buckets = std.StringHashMap(rate_limit.TokenBucket).init(alloc),
            .capacity = capacity,
            .refill_per_sec = refill_per_sec,
        };
    }

    fn deinit(self: *TenantRateLimiter) void {
        var it = self.buckets.iterator();
        while (it.next()) |entry| self.alloc.free(entry.key_ptr.*);
        self.buckets.deinit();
    }

    fn acquire(self: *TenantRateLimiter, tenant_id: []const u8, cost: f64) !void {
        while (true) {
            const now_ms = std.time.milliTimestamp();
            const bucket = try self.getOrCreateBucket(tenant_id, now_ms);
            if (bucket.allow(now_ms, cost)) return;

            const wait_ms = @max(bucket.waitMsUntil(now_ms, cost), 1);
            std.Thread.sleep(wait_ms * std.time.ns_per_ms);
        }
    }

    fn getOrCreateBucket(self: *TenantRateLimiter, tenant_id: []const u8, now_ms: i64) !*rate_limit.TokenBucket {
        if (self.buckets.getPtr(tenant_id)) |bucket| return bucket;

        const key_copy = try self.alloc.dupe(u8, tenant_id);
        errdefer self.alloc.free(key_copy);

        try self.buckets.put(key_copy, rate_limit.TokenBucket.init(self.capacity, self.refill_per_sec, now_ms));
        return self.buckets.getPtr(key_copy).?;
    }
};

// ── Entry point ───────────────────────────────────────────────────────────

pub fn workerLoop(cfg: WorkerConfig, worker_state: *WorkerState) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        worker_state.running.store(false, .release);
        _ = gpa.deinit();
    }
    const alloc = gpa.allocator();

    log.info("worker started poll_interval_ms={d}", .{cfg.poll_interval_ms});

    const prompts = agents.loadPrompts(alloc, cfg.config_dir) catch |err| {
        log.err("failed to load agent prompts: {}", .{err});
        return;
    };
    defer {
        alloc.free(prompts.echo);
        alloc.free(prompts.scout);
        alloc.free(prompts.warden);
    }

    var token_cache = github_auth.TokenCache.init(alloc, cfg.github_app_id, cfg.github_app_private_key);
    defer token_cache.deinit();
    var tenant_limiter = TenantRateLimiter.init(alloc, cfg.rate_limit_capacity, cfg.rate_limit_refill_per_sec);
    defer tenant_limiter.deinit();

    var consecutive_errors: u32 = 0;
    while (worker_state.running.load(.acquire)) {
        const outcome = processNextRun(alloc, cfg, worker_state, &prompts, &token_cache, &tenant_limiter) catch |err| {
            if (err != WorkerError.ShutdownRequested) {
                log.err("run processing error: {}", .{err});
                metrics.incWorkerErrors();
                consecutive_errors += 1;

                const max_delay_ms = std.math.mul(u64, cfg.poll_interval_ms, 8) catch cfg.poll_interval_ms;
                const delay_ms = backoff.expBackoffJitter(consecutive_errors - 1, cfg.poll_interval_ms, max_delay_ms);
                std.Thread.sleep(delay_ms * std.time.ns_per_ms);
            }
            continue;
        };
        consecutive_errors = 0;

        if (!worker_state.running.load(.acquire)) break;

        switch (outcome) {
            .idle => std.Thread.sleep(cfg.poll_interval_ms * std.time.ns_per_ms),
            .worked => std.Thread.sleep(@min(cfg.poll_interval_ms, 200) * std.time.ns_per_ms),
        }
    }

    log.info("worker stopped", .{});
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

fn processNextRun(
    alloc: std.mem.Allocator,
    cfg: WorkerConfig,
    worker_state: *WorkerState,
    prompts: *const agents.PromptFiles,
    token_cache: *github_auth.TokenCache,
    tenant_limiter: *TenantRateLimiter,
) !ProcessOutcome {
    var conn = try cfg.pool.acquire();
    defer cfg.pool.release(conn);

    try beginTx(conn);
    var tx_open = true;
    errdefer if (tx_open) rollbackTx(conn);

    // Claim a queued run under transaction.
    var result = try conn.query(
        \\SELECT r.run_id, r.workspace_id, r.spec_id, r.tenant_id, r.attempt,
        \\       w.repo_url, w.default_branch,
        \\       s.file_path
        \\FROM runs r
        \\JOIN workspaces w ON w.workspace_id = r.workspace_id
        \\JOIN specs s ON s.spec_id = r.spec_id
        \\WHERE r.state = 'SPEC_QUEUED' AND w.paused = false
        \\ORDER BY r.created_at ASC
        \\LIMIT 1
        \\FOR UPDATE OF r SKIP LOCKED
    , .{});
    defer result.deinit();

    const row = (try result.next()) orelse {
        try commitTx(conn);
        tx_open = false;
        return .idle;
    };

    const run_id = try alloc.dupe(u8, try row.get([]u8, 0));
    defer alloc.free(run_id);
    const workspace_id = try alloc.dupe(u8, try row.get([]u8, 1));
    defer alloc.free(workspace_id);
    const spec_id = try alloc.dupe(u8, try row.get([]u8, 2));
    defer alloc.free(spec_id);
    const tenant_id = try alloc.dupe(u8, try row.get([]u8, 3));
    defer alloc.free(tenant_id);
    const attempt = @as(u32, @intCast(try row.get(i32, 4)));
    const repo_url = try alloc.dupe(u8, try row.get([]u8, 5));
    defer alloc.free(repo_url);
    const default_branch = try alloc.dupe(u8, try row.get([]u8, 6));
    defer alloc.free(default_branch);
    const spec_path = try alloc.dupe(u8, try row.get([]u8, 7));
    defer alloc.free(spec_path);

    result.drain() catch |err| {
        log.warn("claim query drain failed run_id={s}: {}", .{ run_id, err });
    };

    // Move SPEC_QUEUED -> RUN_PLANNED while the row is still locked.
    _ = try state.transition(conn, run_id, .RUN_PLANNED, .orchestrator, .PLAN_COMPLETE, "claimed by worker");

    try commitTx(conn);
    tx_open = false;

    if (!worker_state.running.load(.acquire)) return WorkerError.ShutdownRequested;

    log.info("claimed run run_id={s} attempt={d}", .{ run_id, attempt });

    executeRun(alloc, cfg, worker_state, prompts, conn, token_cache, .{
        .run_id = run_id,
        .workspace_id = workspace_id,
        .spec_id = spec_id,
        .tenant_id = tenant_id,
        .repo_url = repo_url,
        .default_branch = default_branch,
        .spec_path = spec_path,
        .attempt = attempt,
    }, tenant_limiter) catch |err| {
        if (err == WorkerError.ShutdownRequested) {
            _ = state.transition(conn, run_id, .BLOCKED, .orchestrator, .AGENT_TIMEOUT, "shutdown requested") catch |tx_err| {
                log.warn("shutdown transition failed run_id={s}: {}", .{ run_id, tx_err });
            };
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
        _ = state.transition(conn, run_id, .BLOCKED, .orchestrator, classified.reason_code, note) catch |tx_err| {
            log.warn("failure transition failed run_id={s}: {}", .{ run_id, tx_err });
        };
        metrics.incRunsBlocked();
    };
    return .worked;
}

fn isWithinPath(base: []const u8, candidate: []const u8) bool {
    if (!std.mem.startsWith(u8, candidate, base)) return false;
    if (candidate.len == base.len) return true;
    return candidate[base.len] == std.fs.path.sep;
}

fn resolveSpecPath(
    alloc: std.mem.Allocator,
    worktree_path: []const u8,
    relative_spec_path: []const u8,
) ![]const u8 {
    const joined = try std.fs.path.join(alloc, &.{ worktree_path, relative_spec_path });
    defer alloc.free(joined);

    const canonical_spec = try std.fs.realpathAlloc(alloc, joined);
    errdefer alloc.free(canonical_spec);

    const canonical_worktree = try std.fs.realpathAlloc(alloc, worktree_path);
    defer alloc.free(canonical_worktree);

    if (!isWithinPath(canonical_worktree, canonical_spec)) {
        return WorkerError.PathTraversal;
    }

    return canonical_spec;
}

fn loadInstallationId(
    alloc: std.mem.Allocator,
    conn: *pg.Conn,
    workspace_id: []const u8,
) ![]u8 {
    const fallback = std.process.getEnvVarOwned(alloc, "GITHUB_INSTALLATION_ID") catch null;

    const kek = secrets.loadKek(alloc) catch {
        if (fallback) |id| return id;
        return WorkerError.MissingGitHubInstallation;
    };

    const from_vault = secrets.load(alloc, conn, workspace_id, "github_app_installation_id", kek) catch {
        if (fallback) |id| return id;
        return WorkerError.MissingGitHubInstallation;
    };

    if (fallback) |id| alloc.free(id);
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
};

fn opGetInstallationToken(ctx: TokenRetryCtx, _: u32) ![]u8 {
    return ctx.cache.getInstallationToken(ctx.alloc, ctx.installation_id);
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

fn executeRun(
    alloc: std.mem.Allocator,
    cfg: WorkerConfig,
    worker_state: *WorkerState,
    prompts: *const agents.PromptFiles,
    conn: *pg.Conn,
    token_cache: *github_auth.TokenCache,
    ctx: RunContext,
    tenant_limiter: *TenantRateLimiter,
) !void {
    var run_arena = std.heap.ArenaAllocator.init(alloc);
    defer run_arena.deinit();
    const run_alloc = run_arena.allocator();

    if (!worker_state.running.load(.acquire)) return WorkerError.ShutdownRequested;

    // ── Set up git worktree ───────────────────────────────────────────────
    const bare_path = try git.ensureBareClone(
        run_alloc,
        cfg.cache_root,
        ctx.workspace_id,
        ctx.repo_url,
    );

    var wt = try git.createWorktree(run_alloc, bare_path, ctx.run_id, ctx.default_branch);
    defer {
        git.removeWorktree(run_alloc, bare_path, wt.path);
        wt.deinit();
    }

    const branch = try std.fmt.allocPrint(run_alloc, "zombie/run-{s}", .{ctx.run_id});

    // ── Read spec from worktree (canonicalized path) ─────────────────────
    const spec_abs = try resolveSpecPath(run_alloc, wt.path, ctx.spec_path);
    const spec_file = try std.fs.openFileAbsolute(spec_abs, .{});
    defer spec_file.close();
    const spec_content = try spec_file.readToEndAlloc(run_alloc, 512 * 1024);

    // ── Load workspace memories for Echo ─────────────────────────────────
    const memory_context = try memory.loadForEcho(run_alloc, conn, ctx.workspace_id, 20);

    // ── Phase 1: Echo (planning) ─────────────────────────────────────────
    try tenant_limiter.acquire(ctx.tenant_id, 1.0);
    const echo_result = try agents.runEcho(
        run_alloc,
        wt.path,
        prompts.echo,
        spec_content,
        memory_context,
    );
    metrics.incAgentEchoCalls();
    metrics.addAgentTokens(echo_result.token_count);

    agents.emitNullclawRunEvent(ctx.run_id, ctx.attempt, .echo, echo_result);
    try state.writeUsage(conn, ctx.run_id, ctx.attempt, .echo, echo_result.token_count, echo_result.wall_seconds);

    // Commit plan.json to feature branch
    const plan_path = try std.fmt.allocPrint(run_alloc, "docs/runs/{s}/plan.json", .{ctx.run_id});
    try commitArtifact(run_alloc, conn, ctx, &wt, plan_path, echo_result.content, "echo: add plan.json", .echo, ctx.attempt);

    // ── Phase 2: Scout (building) — with retry loop ──────────────────────
    var attempt = ctx.attempt;
    var defects: ?[]const u8 = null;

    // Accumulate token and wall-clock totals across all agent calls
    var total_tokens: u64 = echo_result.token_count;
    var total_wall_seconds: u64 = echo_result.wall_seconds;

    while (attempt <= cfg.max_attempts) : (attempt += 1) {
        if (!worker_state.running.load(.acquire)) return WorkerError.ShutdownRequested;

        _ = try state.transition(conn, ctx.run_id, .PATCH_IN_PROGRESS, .orchestrator, .PATCH_STARTED, null);

        try tenant_limiter.acquire(ctx.tenant_id, 1.0);
        const scout_result = try reliable.call(agents.AgentResult, ScoutRetryCtx{
            .alloc = run_alloc,
            .workspace_path = wt.path,
            .prompt = prompts.scout,
            .plan_content = echo_result.content,
            .defects_content = defects,
        }, opRunScout, .{
            .max_retries = 1,
            .base_delay_ms = 1_000,
            .max_delay_ms = 8_000,
        });
        metrics.incAgentScoutCalls();
        metrics.addAgentTokens(scout_result.token_count);

        agents.emitNullclawRunEvent(ctx.run_id, attempt, .scout, scout_result);
        total_tokens += scout_result.token_count;
        total_wall_seconds += scout_result.wall_seconds;
        try state.writeUsage(conn, ctx.run_id, attempt, .scout, scout_result.token_count, scout_result.wall_seconds);

        // Commit implementation.md
        const impl_path = try std.fmt.allocPrint(run_alloc, "docs/runs/{s}/implementation.md", .{ctx.run_id});
        try commitArtifact(run_alloc, conn, ctx, &wt, impl_path, scout_result.content, "scout: add implementation.md", .scout, attempt);

        _ = try state.transition(conn, ctx.run_id, .PATCH_READY, .scout, .PATCH_COMMITTED, null);

        // ── Phase 3: Warden (validation) ─────────────────────────────────
        _ = try state.transition(conn, ctx.run_id, .VERIFICATION_IN_PROGRESS, .orchestrator, .PATCH_STARTED, null);

        try tenant_limiter.acquire(ctx.tenant_id, 1.0);
        const warden_result = try reliable.call(agents.AgentResult, WardenRetryCtx{
            .alloc = run_alloc,
            .workspace_path = wt.path,
            .prompt = prompts.warden,
            .spec_content = spec_content,
            .plan_content = echo_result.content,
            .implementation_summary = scout_result.content,
        }, opRunWarden, .{
            .max_retries = 1,
            .base_delay_ms = 1_000,
            .max_delay_ms = 8_000,
        });
        metrics.incAgentWardenCalls();
        metrics.addAgentTokens(warden_result.token_count);

        agents.emitNullclawRunEvent(ctx.run_id, attempt, .warden, warden_result);
        total_tokens += warden_result.token_count;
        total_wall_seconds += warden_result.wall_seconds;
        try state.writeUsage(conn, ctx.run_id, attempt, .warden, warden_result.token_count, warden_result.wall_seconds);

        // Commit validation.md
        const validation_path = try std.fmt.allocPrint(run_alloc, "docs/runs/{s}/validation.md", .{ctx.run_id});
        try commitArtifact(run_alloc, conn, ctx, &wt, validation_path, warden_result.content, "warden: add validation.md", .warden, attempt);

        // Save workspace memories from Warden
        const observations = try agents.extractObservations(run_alloc, warden_result.content);
        if (observations.len > 0) {
            _ = try memory.saveFromWarden(conn, ctx.workspace_id, ctx.run_id, observations);
        }

        const passed = agents.parseWardenVerdict(warden_result.content);

        if (passed) {
            // ── PASS: create PR ──────────────────────────────────────────
            _ = try state.transition(conn, ctx.run_id, .PR_PREPARED, .warden, .VALIDATION_PASSED, null);

            var pr_url = try getExistingPrUrl(run_alloc, conn, ctx.run_id);
            if (pr_url == null) {
                const installation_id = try loadInstallationId(run_alloc, conn, ctx.workspace_id);
                defer run_alloc.free(installation_id);

                const github_token = try reliable.call([]u8, TokenRetryCtx{
                    .cache = token_cache,
                    .alloc = run_alloc,
                    .installation_id = installation_id,
                }, opGetInstallationToken, .{
                    .max_retries = 2,
                    .base_delay_ms = 500,
                    .max_delay_ms = 5_000,
                });
                defer run_alloc.free(github_token);

                try reliable.call(void, PushRetryCtx{
                    .alloc = run_alloc,
                    .wt_path = wt.path,
                    .branch = branch,
                    .github_token = github_token,
                }, opPushBranch, .{
                    .max_retries = 2,
                    .base_delay_ms = 1_000,
                    .max_delay_ms = 10_000,
                });

                const pr_title = try std.fmt.allocPrint(run_alloc, "usezombie: {s}", .{ctx.spec_id});

                var pr_retry_ctx = PrRetryCtx{
                    .alloc = run_alloc,
                    .repo_url = ctx.repo_url,
                    .branch = branch,
                    .base_branch = ctx.default_branch,
                    .title = pr_title,
                    .body = warden_result.content,
                    .github_token = github_token,
                };
                const created_pr = try reliable.callWithDetail([]u8, &pr_retry_ctx, opCreatePr, prDetail, .{
                    .max_retries = 2,
                    .base_delay_ms = 1_000,
                    .max_delay_ms = 10_000,
                });
                pr_url = created_pr;
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
                log.warn("run_summary.md alloc failed (non-fatal): {}", .{err});
                log.info("run completed run_id={s} pr_url={s}", .{ ctx.run_id, pr_final });
                metrics.incRunsCompleted();
                return;
            };

            const summary_path = try std.fmt.allocPrint(run_alloc, "docs/runs/{s}/run_summary.md", .{ctx.run_id});

            commitArtifact(run_alloc, conn, ctx, &wt, summary_path, summary_content, "orchestrator: add run_summary.md", .orchestrator, attempt) catch |err| {
                log.warn("run_summary.md commit failed (non-fatal): {}", .{err});
            };

            log.info("run completed run_id={s} pr_url={s}", .{ ctx.run_id, pr_final });
            metrics.incRunsCompleted();
            return;
        }

        // ── FAIL: prepare for retry if budget remains ──────────────────
        _ = try state.transition(conn, ctx.run_id, .VERIFICATION_FAILED, .warden, .VALIDATION_FAILED, null);

        if (attempt >= cfg.max_attempts) break;

        // Commit defects file and retry Scout
        const defects_path = try std.fmt.allocPrint(
            run_alloc,
            "docs/runs/{s}/attempt_{d}_defects.md",
            .{ ctx.run_id, attempt },
        );
        try commitArtifact(run_alloc, conn, ctx, &wt, defects_path, warden_result.content, "warden: add defects", .warden, attempt);

        defects = try run_alloc.dupe(u8, warden_result.content);

        // Increment attempt counter in DB
        _ = try state.incrementAttempt(conn, ctx.run_id);

        // Adaptive retry delay with jitter.
        const retry_index = attempt - ctx.attempt;
        const delay_ms = backoff.expBackoffJitter(retry_index, 1_000, 30_000);
        metrics.incRunRetries();
        metrics.addBackoffWaitMs(delay_ms);
        std.Thread.sleep(delay_ms * std.time.ns_per_ms);

        log.info("retrying run_id={s} attempt={d}", .{ ctx.run_id, attempt + 1 });
    }

    // Retries exhausted → BLOCKED
    _ = try state.transition(conn, ctx.run_id, .BLOCKED, .orchestrator, .RETRIES_EXHAUSTED, null);
    _ = try state.transition(conn, ctx.run_id, .NOTIFIED_BLOCKED, .orchestrator, .NOTIFICATION_SENT, null);

    log.warn("run blocked (retries exhausted) run_id={s}", .{ctx.run_id});
    metrics.incRunsBlocked();
}

// ── Artifact helpers ─────────────────────────────────────────────────────

fn commitArtifact(
    alloc: std.mem.Allocator,
    conn: *pg.Conn,
    ctx: RunContext,
    wt: *git.WorktreeHandle,
    rel_path: []const u8,
    content: []const u8,
    msg: []const u8,
    actor: types.Actor,
    attempt: u32,
) !void {
    // Write + commit to git
    try git.commitFile(alloc, wt.path, rel_path, content, msg, "UseZombie Bot", "bot@usezombie.dev");

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

test "isWithinPath respects directory boundaries" {
    try std.testing.expect(isWithinPath("/tmp/wt", "/tmp/wt/docs/spec.md"));
    try std.testing.expect(isWithinPath("/tmp/wt", "/tmp/wt"));
    try std.testing.expect(!isWithinPath("/tmp/wt", "/tmp/wt-other/spec.md"));
    try std.testing.expect(!isWithinPath("/tmp/wt", "/tmp/other/spec.md"));
}
