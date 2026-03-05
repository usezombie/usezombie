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

    while (worker_state.running.load(.acquire)) {
        processNextRun(alloc, cfg, worker_state, &prompts, &token_cache) catch |err| {
            if (err != WorkerError.ShutdownRequested) {
                log.err("run processing error: {}", .{err});
            }
        };

        if (!worker_state.running.load(.acquire)) break;
        std.Thread.sleep(cfg.poll_interval_ms * std.time.ns_per_ms);
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
) !void {
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
        return;
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

    result.drain() catch {};

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
    }) catch |err| {
        if (err == WorkerError.ShutdownRequested) {
            _ = state.transition(conn, run_id, .BLOCKED, .orchestrator, .AGENT_CRASH, "shutdown requested") catch {};
            return err;
        }

        log.err("run failed run_id={s}: {}", .{ run_id, err });
        _ = state.transition(conn, run_id, .BLOCKED, .orchestrator, .AGENT_CRASH, @errorName(err)) catch {};
    };
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

fn executeRun(
    alloc: std.mem.Allocator,
    cfg: WorkerConfig,
    worker_state: *WorkerState,
    prompts: *const agents.PromptFiles,
    conn: *pg.Conn,
    token_cache: *github_auth.TokenCache,
    ctx: RunContext,
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
    const echo_result = try agents.runEcho(
        run_alloc,
        wt.path,
        prompts.echo,
        spec_content,
        memory_context,
    );

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

        const scout_result = try agents.runScout(
            run_alloc,
            wt.path,
            prompts.scout,
            echo_result.content,
            defects,
        );

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

        const warden_result = try agents.runWarden(
            run_alloc,
            wt.path,
            prompts.warden,
            spec_content,
            echo_result.content,
            scout_result.content,
        );

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

                const github_token = try token_cache.getInstallationToken(run_alloc, installation_id);
                defer run_alloc.free(github_token);

                try git.push(run_alloc, wt.path, branch, github_token);

                const pr_title = try std.fmt.allocPrint(run_alloc, "usezombie: {s}", .{ctx.spec_id});

                const created_pr = try git.createPullRequest(
                    run_alloc,
                    ctx.repo_url,
                    branch,
                    ctx.default_branch,
                    pr_title,
                    warden_result.content,
                    github_token,
                );
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
                return;
            };

            const summary_path = try std.fmt.allocPrint(run_alloc, "docs/runs/{s}/run_summary.md", .{ctx.run_id});

            commitArtifact(run_alloc, conn, ctx, &wt, summary_path, summary_content, "orchestrator: add run_summary.md", .orchestrator, attempt) catch |err| {
                log.warn("run_summary.md commit failed (non-fatal): {}", .{err});
            };

            log.info("run completed run_id={s} pr_url={s}", .{ ctx.run_id, pr_final });
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

        log.info("retrying run_id={s} attempt={d}", .{ ctx.run_id, attempt + 1 });
    }

    // Retries exhausted → BLOCKED
    _ = try state.transition(conn, ctx.run_id, .BLOCKED, .orchestrator, .RETRIES_EXHAUSTED, null);
    _ = try state.transition(conn, ctx.run_id, .NOTIFIED_BLOCKED, .orchestrator, .NOTIFICATION_SENT, null);

    log.warn("run blocked (retries exhausted) run_id={s}", .{ctx.run_id});
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
