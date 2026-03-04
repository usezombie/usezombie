//! HTTP request handlers for all 6 control-plane endpoints.
//! Uses Zap's request/response API. All responses follow the M1_002 error contract.

const std = @import("std");
const zap = @import("zap");
const pg = @import("pg");
const types = @import("../types.zig");
const state = @import("../state/machine.zig");
const policy = @import("../state/policy.zig");
const log = std.log.scoped(.http);

// ── Handler context (shared across all handlers) ──────────────────────────

pub const Context = struct {
    pool: *pg.Pool,
    alloc: std.mem.Allocator,
    api_key: []const u8, // expected API key from env
};

// ── JSON helpers ──────────────────────────────────────────────────────────

fn writeJson(r: zap.Request, status: zap.http.StatusCode, value: anytype) void {
    var buf: [64 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const json = std.json.Stringify.valueAlloc(fba.allocator(), value, .{}) catch {
        r.setStatus(.internal_server_error);
        r.sendBody("{}") catch {};
        return;
    };
    r.setStatus(status);
    r.setContentType(.JSON) catch {};
    r.sendBody(json) catch {};
}

fn errorResponse(
    r: zap.Request,
    status: zap.http.StatusCode,
    code: []const u8,
    message: []const u8,
    request_id: []const u8,
) void {
    writeJson(r, status, .{
        .@"error" = .{ .code = code, .message = message },
        .request_id = request_id,
    });
}

fn requestId(alloc: std.mem.Allocator) []const u8 {
    var id: [16]u8 = undefined;
    std.crypto.random.bytes(&id);
    const hex = std.fmt.bytesToHex(id, .lower);
    return std.fmt.allocPrint(alloc, "req_{s}", .{hex[0..12]}) catch "req_unknown";
}

/// Validate Authorization header: "Bearer <api_key>"
fn authenticate(r: zap.Request, ctx: *Context) bool {
    const auth = r.getHeader("authorization") orelse return false;
    const prefix = "Bearer ";
    if (!std.mem.startsWith(u8, auth, prefix)) return false;
    return std.mem.eql(u8, auth[prefix.len..], ctx.api_key);
}

// ── Healthz ───────────────────────────────────────────────────────────────

pub fn handleHealthz(_: *Context, r: zap.Request) void {
    r.setStatus(.ok);
    r.setContentType(.JSON) catch {};
    r.sendBody(
        \\{"status":"ok","service":"zombied","version":"0.1.0"}
    ) catch {};
}

// ── POST /v1/runs ─────────────────────────────────────────────────────────

pub fn handleStartRun(ctx: *Context, r: zap.Request) void {
    var arena = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    const req_id = requestId(alloc);

    if (!authenticate(r, ctx)) {
        errorResponse(r, .unauthorized, "UNAUTHORIZED", "Invalid or missing API key", req_id);
        return;
    }

    const body = r.body orelse {
        errorResponse(r, .bad_request, "INVALID_REQUEST", "Request body required", req_id);
        return;
    };

    const Req = struct {
        workspace_id: []const u8,
        spec_id: []const u8,
        mode: []const u8,
        requested_by: []const u8,
        idempotency_key: []const u8,
    };

    const parsed = std.json.parseFromSlice(Req, alloc, body, .{}) catch {
        errorResponse(r, .bad_request, "INVALID_REQUEST", "Malformed JSON or missing required fields", req_id);
        return;
    };
    defer parsed.deinit();
    const req = parsed.value;

    var conn = ctx.pool.acquire() catch {
        errorResponse(r, .service_unavailable, "INTERNAL_ERROR", "Database unavailable", req_id);
        return;
    };
    defer ctx.pool.release(conn);

    // Idempotency: check if this key already exists
    {
        var check = conn.query(
            "SELECT run_id FROM runs WHERE idempotency_key = $1",
            .{req.idempotency_key},
        ) catch {
            errorResponse(r, .internal_server_error, "INTERNAL_ERROR", "Database error", req_id);
            return;
        };
        defer check.deinit();

        if (check.next() catch null) |row| {
            const existing_run_id = row.get([]u8, 0) catch "unknown";
            writeJson(r, .accepted, .{
                .run_id = existing_run_id,
                .state = "SPEC_QUEUED",
                .attempt = @as(u32, 1),
                .request_id = req_id,
            });
            return;
        }
    }

    // Verify workspace exists and is not paused
    {
        var ws_check = conn.query(
            "SELECT paused FROM workspaces WHERE workspace_id = $1",
            .{req.workspace_id},
        ) catch {
            errorResponse(r, .internal_server_error, "INTERNAL_ERROR", "Database error", req_id);
            return;
        };
        defer ws_check.deinit();

        const ws_row = ws_check.next() catch null orelse {
            errorResponse(r, .not_found, "WORKSPACE_NOT_FOUND", "Workspace not found", req_id);
            return;
        };

        const paused = ws_row.get(bool, 0) catch false;
        if (paused) {
            errorResponse(r, .conflict, "WORKSPACE_PAUSED", "Workspace is paused", req_id);
            return;
        }
    }

    // Verify spec exists
    {
        var spec_check = conn.query(
            "SELECT spec_id FROM specs WHERE spec_id = $1 AND workspace_id = $2",
            .{ req.spec_id, req.workspace_id },
        ) catch {
            errorResponse(r, .internal_server_error, "INTERNAL_ERROR", "Database error", req_id);
            return;
        };
        defer spec_check.deinit();

        if (spec_check.next() catch null == null) {
            errorResponse(r, .not_found, "SPEC_NOT_FOUND", "Spec not found", req_id);
            return;
        }
    }

    // Generate run_id
    var raw: [16]u8 = undefined;
    std.crypto.random.bytes(&raw);
    const run_id = std.fmt.allocPrint(alloc, "r_{s}", .{std.fmt.bytesToHex(raw, .lower)[0..16]}) catch "r_unknown";

    const now_ms = std.time.milliTimestamp();
    const branch = std.fmt.allocPrint(alloc, "zombie/run-{s}", .{run_id}) catch "zombie/run-unknown";

    var insert = conn.query(
        \\INSERT INTO runs
        \\  (run_id, workspace_id, spec_id, tenant_id, state, attempt, mode,
        \\   requested_by, idempotency_key, branch, created_at, updated_at)
        \\SELECT $1, $2, $3, tenant_id, 'SPEC_QUEUED', 1, $4, $5, $6, $7, $8, $8
        \\FROM workspaces WHERE workspace_id = $2
    , .{ run_id, req.workspace_id, req.spec_id, req.mode, req.requested_by, req.idempotency_key, branch, now_ms }) catch {
        errorResponse(r, .internal_server_error, "INTERNAL_ERROR", "Failed to create run", req_id);
        return;
    };
    insert.deinit();

    // Record policy_decision event — sensitive action, M1 permissive mode (always allow)
    policy.recordPolicyEvent(conn, req.workspace_id, run_id, .sensitive, .allow, "m1.start_run", req.requested_by) catch |err| {
        log.warn("policy event insert failed (non-fatal): {}", .{err});
    };

    log.info("run created run_id={s} workspace_id={s} spec_id={s}", .{
        run_id, req.workspace_id, req.spec_id,
    });

    writeJson(r, .accepted, .{
        .run_id = run_id,
        .state = "SPEC_QUEUED",
        .attempt = @as(u32, 1),
        .request_id = req_id,
    });
}

// ── GET /v1/runs/:run_id ──────────────────────────────────────────────────

pub fn handleGetRun(ctx: *Context, r: zap.Request, run_id: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const req_id = requestId(alloc);

    if (!authenticate(r, ctx)) {
        errorResponse(r, .unauthorized, "UNAUTHORIZED", "Invalid or missing API key", req_id);
        return;
    }

    var conn = ctx.pool.acquire() catch {
        errorResponse(r, .service_unavailable, "INTERNAL_ERROR", "Database unavailable", req_id);
        return;
    };
    defer ctx.pool.release(conn);

    // Fetch run
    var run_result = conn.query(
        \\SELECT run_id, workspace_id, spec_id, state, attempt, mode,
        \\       requested_by, branch, pr_url, created_at, updated_at
        \\FROM runs WHERE run_id = $1
    , .{run_id}) catch {
        errorResponse(r, .internal_server_error, "INTERNAL_ERROR", "Database error", req_id);
        return;
    };
    defer run_result.deinit();

    const row = run_result.next() catch null orelse {
        errorResponse(r, .not_found, "RUN_NOT_FOUND", "Run not found", req_id);
        return;
    };

    const rid = row.get([]u8, 0) catch "?";
    const workspace_id = row.get([]u8, 1) catch "?";
    const spec_id = row.get([]u8, 2) catch "?";
    const run_state = row.get([]u8, 3) catch "?";
    const attempt = row.get(i32, 4) catch 1;
    const mode = row.get([]u8, 5) catch "api";
    const requested_by = row.get([]u8, 6) catch "?";
    const branch = row.get([]u8, 7) catch "?";
    const pr_url = row.get(?[]u8, 8) catch null;
    const created_at = row.get(i64, 9) catch 0;
    const updated_at = row.get(i64, 10) catch 0;

    run_result.drain() catch {};

    // Fetch transitions
    var trans_result = conn.query(
        \\SELECT state_from, state_to, actor, reason_code, ts
        \\FROM run_transitions WHERE run_id = $1 ORDER BY ts ASC
    , .{run_id}) catch {
        errorResponse(r, .internal_server_error, "INTERNAL_ERROR", "Database error", req_id);
        return;
    };
    defer trans_result.deinit();

    var transitions: std.ArrayList(std.json.Value) = .empty;

    while (trans_result.next() catch null) |trow| {
        const tf = trow.get([]u8, 0) catch continue;
        const tt = trow.get([]u8, 1) catch continue;
        const ta = trow.get([]u8, 2) catch continue;
        const tc = trow.get([]u8, 3) catch continue;
        const ts = trow.get(i64, 4) catch 0;

        var obj = std.json.ObjectMap.init(alloc);
        obj.put("state_from", .{ .string = tf }) catch continue;
        obj.put("state_to", .{ .string = tt }) catch continue;
        obj.put("actor", .{ .string = ta }) catch continue;
        obj.put("reason_code", .{ .string = tc }) catch continue;
        obj.put("ts", .{ .integer = ts }) catch continue;
        transitions.append(alloc, .{ .object = obj }) catch continue;
    }
    trans_result.drain() catch {};

    // Fetch artifacts (M1_002 Gap 3 + M1_003 Gap 5)
    var artifacts_arr: std.ArrayList(std.json.Value) = .empty;
    fetch_artifacts: {
        var art_result = conn.query(
            \\SELECT artifact_name, object_key, checksum_sha256, producer, attempt, created_at
            \\FROM artifacts WHERE run_id = $1 ORDER BY created_at ASC
        , .{run_id}) catch break :fetch_artifacts;
        defer art_result.deinit();
        while (art_result.next() catch null) |arow| {
            const aname = arow.get([]u8, 0) catch continue;
            const akey = arow.get([]u8, 1) catch continue;
            const achk = arow.get([]u8, 2) catch continue;
            const aprod = arow.get([]u8, 3) catch continue;
            const aattempt = arow.get(i32, 4) catch 1;
            const ats = arow.get(i64, 5) catch 0;

            var obj = std.json.ObjectMap.init(alloc);
            obj.put("artifact_name", .{ .string = aname }) catch continue;
            obj.put("object_key", .{ .string = akey }) catch continue;
            obj.put("checksum_sha256", .{ .string = achk }) catch continue;
            obj.put("producer", .{ .string = aprod }) catch continue;
            obj.put("attempt", .{ .integer = @as(i64, aattempt) }) catch continue;
            obj.put("created_at", .{ .integer = ats }) catch continue;
            artifacts_arr.append(alloc, .{ .object = obj }) catch continue;
        }
    }

    // Fetch policy events (M1_002 Gap 3 + M1_003 Gap 5)
    var policy_events_arr: std.ArrayList(std.json.Value) = .empty;
    fetch_policy_events: {
        var pe_result = conn.query(
            \\SELECT action_class, decision, rule_id, actor, ts
            \\FROM policy_events WHERE run_id = $1 ORDER BY ts ASC
        , .{run_id}) catch break :fetch_policy_events;
        defer pe_result.deinit();
        while (pe_result.next() catch null) |prow| {
            const pclass = prow.get([]u8, 0) catch continue;
            const pdec = prow.get([]u8, 1) catch continue;
            const prule = prow.get([]u8, 2) catch continue;
            const pactor = prow.get([]u8, 3) catch continue;
            const pts = prow.get(i64, 4) catch 0;

            var obj = std.json.ObjectMap.init(alloc);
            obj.put("action_class", .{ .string = pclass }) catch continue;
            obj.put("decision", .{ .string = pdec }) catch continue;
            obj.put("rule_id", .{ .string = prule }) catch continue;
            obj.put("actor", .{ .string = pactor }) catch continue;
            obj.put("ts", .{ .integer = pts }) catch continue;
            policy_events_arr.append(alloc, .{ .object = obj }) catch continue;
        }
    }

    writeJson(r, .ok, .{
        .run_id = rid,
        .workspace_id = workspace_id,
        .spec_id = spec_id,
        .current_state = run_state,
        .attempt = attempt,
        .mode = mode,
        .requested_by = requested_by,
        .branch = branch,
        .pr_url = pr_url,
        .created_at = created_at,
        .updated_at = updated_at,
        .transitions = transitions.items,
        .artifacts = artifacts_arr.items,
        .policy_events = policy_events_arr.items,
        .request_id = req_id,
    });
}

// ── POST /v1/runs/:run_id:retry ───────────────────────────────────────────

pub fn handleRetryRun(ctx: *Context, r: zap.Request, run_id: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const req_id = requestId(alloc);

    if (!authenticate(r, ctx)) {
        errorResponse(r, .unauthorized, "UNAUTHORIZED", "Invalid or missing API key", req_id);
        return;
    }

    const Req = struct {
        reason: []const u8,
        retry_token: []const u8,
    };

    const body = r.body orelse {
        errorResponse(r, .bad_request, "INVALID_REQUEST", "Request body required", req_id);
        return;
    };
    const parsed = std.json.parseFromSlice(Req, alloc, body, .{}) catch {
        errorResponse(r, .bad_request, "INVALID_REQUEST", "Malformed JSON", req_id);
        return;
    };
    defer parsed.deinit();

    var conn = ctx.pool.acquire() catch {
        errorResponse(r, .service_unavailable, "INTERNAL_ERROR", "Database unavailable", req_id);
        return;
    };
    defer ctx.pool.release(conn);

    // Fetch workspace_id for policy event recording
    const workspace_id_for_policy: []const u8 = blk: {
        var wq = conn.query(
            "SELECT workspace_id FROM runs WHERE run_id = $1",
            .{run_id},
        ) catch break :blk @as([]const u8, "");
        defer wq.deinit();
        const wrow = wq.next() catch null orelse break :blk @as([]const u8, "");
        const wid = wrow.get([]u8, 0) catch break :blk @as([]const u8, "");
        break :blk alloc.dupe(u8, wid) catch @as([]const u8, "");
    };

    const current = state.getRunState(conn, run_id) catch |err| switch (err) {
        state.TransitionError.RunNotFound => {
            errorResponse(r, .not_found, "RUN_NOT_FOUND", "Run not found", req_id);
            return;
        },
        else => {
            errorResponse(r, .internal_server_error, "INTERNAL_ERROR", "Database error", req_id);
            return;
        },
    };

    if (!current.state.isRetryable()) {
        errorResponse(r, .unprocessable_content, "INVALID_STATE_TRANSITION", "Run is not in a retryable state", req_id);
        return;
    }

    // Record policy_decision event before state change — sensitive action
    policy.recordPolicyEvent(conn, workspace_id_for_policy, run_id, .sensitive, .allow, "m1.retry_run", "api") catch |err| {
        log.warn("policy event insert failed (non-fatal): {}", .{err});
    };

    // Re-queue: transition back to SPEC_QUEUED
    const now_ms = std.time.milliTimestamp();
    var r2 = conn.query(
        "UPDATE runs SET state = 'SPEC_QUEUED', updated_at = $1 WHERE run_id = $2",
        .{ now_ms, run_id },
    ) catch {
        errorResponse(r, .internal_server_error, "INTERNAL_ERROR", "Database error", req_id);
        return;
    };
    r2.deinit();

    var r3 = conn.query(
        \\INSERT INTO run_transitions (run_id, attempt, state_from, state_to, actor, reason_code, notes, ts)
        \\VALUES ($1, $2, $3, 'SPEC_QUEUED', 'orchestrator', 'MANUAL_RETRY', $4, $5)
    , .{
        run_id, @as(i32, @intCast(current.attempt)),
        current.state.label(), parsed.value.reason, now_ms,
    }) catch {
        errorResponse(r, .internal_server_error, "INTERNAL_ERROR", "Database error", req_id);
        return;
    };
    r3.deinit();

    log.info("run retried run_id={s} reason={s}", .{ run_id, parsed.value.reason });

    writeJson(r, .accepted, .{
        .run_id = run_id,
        .state = "SPEC_QUEUED",
        .attempt = current.attempt,
        .request_id = req_id,
    });
}

// ── POST /v1/workspaces/:workspace_id:pause ───────────────────────────────

pub fn handlePauseWorkspace(ctx: *Context, r: zap.Request, workspace_id: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const req_id = requestId(alloc);

    if (!authenticate(r, ctx)) {
        errorResponse(r, .unauthorized, "UNAUTHORIZED", "Invalid or missing API key", req_id);
        return;
    }

    const Req = struct {
        pause: bool,
        reason: []const u8,
        version: i64,
    };

    const body = r.body orelse {
        errorResponse(r, .bad_request, "INVALID_REQUEST", "Request body required", req_id);
        return;
    };
    const parsed = std.json.parseFromSlice(Req, alloc, body, .{}) catch {
        errorResponse(r, .bad_request, "INVALID_REQUEST", "Malformed JSON", req_id);
        return;
    };
    defer parsed.deinit();

    var conn = ctx.pool.acquire() catch {
        errorResponse(r, .service_unavailable, "INTERNAL_ERROR", "Database unavailable", req_id);
        return;
    };
    defer ctx.pool.release(conn);

    // Record policy_decision event before state change — sensitive action
    policy.recordPolicyEvent(conn, workspace_id, null, .sensitive, .allow, "m1.pause_workspace", "api") catch |err| {
        log.warn("policy event insert failed (non-fatal): {}", .{err});
    };

    const now_ms = std.time.milliTimestamp();
    // Optimistic concurrency via version field
    var upd = conn.query(
        \\UPDATE workspaces
        \\SET paused = $1, paused_reason = $2, version = version + 1, updated_at = $3
        \\WHERE workspace_id = $4 AND version = $5
        \\RETURNING version
    , .{
        parsed.value.pause,
        if (parsed.value.pause) parsed.value.reason else null,
        now_ms,
        workspace_id,
        parsed.value.version,
    }) catch {
        errorResponse(r, .internal_server_error, "INTERNAL_ERROR", "Database error", req_id);
        return;
    };
    defer upd.deinit();

    const row = upd.next() catch null orelse {
        errorResponse(r, .conflict, "WORKSPACE_NOT_FOUND", "Workspace not found or version conflict", req_id);
        return;
    };

    const new_version = row.get(i64, 0) catch 0;
    log.info("workspace {} pause={} workspace_id={s}", .{ parsed.value.pause, parsed.value.pause, workspace_id });

    writeJson(r, .ok, .{
        .workspace_id = workspace_id,
        .paused = parsed.value.pause,
        .version = new_version,
        .request_id = req_id,
    });
}

// ── GET /v1/specs ─────────────────────────────────────────────────────────

pub fn handleListSpecs(ctx: *Context, r: zap.Request) void {
    var arena = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const req_id = requestId(alloc);

    if (!authenticate(r, ctx)) {
        errorResponse(r, .unauthorized, "UNAUTHORIZED", "Invalid or missing API key", req_id);
        return;
    }

    const workspace_id = r.getParamStr(alloc, "workspace_id") catch null orelse {
        errorResponse(r, .bad_request, "INVALID_REQUEST", "workspace_id query param required", req_id);
        return;
    };
    defer alloc.free(workspace_id);
    const wid = workspace_id;

    const limit_str = r.getParamStr(alloc, "limit") catch null;
    defer if (limit_str) |ls| alloc.free(ls);
    const limit: i32 = if (limit_str) |ls|
        std.fmt.parseInt(i32, ls, 10) catch 50
    else
        50;

    var conn = ctx.pool.acquire() catch {
        errorResponse(r, .service_unavailable, "INTERNAL_ERROR", "Database unavailable", req_id);
        return;
    };
    defer ctx.pool.release(conn);

    var result = conn.query(
        \\SELECT spec_id, file_path, title, status, created_at, updated_at
        \\FROM specs WHERE workspace_id = $1
        \\ORDER BY created_at DESC LIMIT $2
    , .{ wid, limit }) catch {
        errorResponse(r, .internal_server_error, "INTERNAL_ERROR", "Database error", req_id);
        return;
    };
    defer result.deinit();

    var specs: std.ArrayList(std.json.Value) = .empty;

    while (result.next() catch null) |row| {
        const spec_id = row.get([]u8, 0) catch continue;
        const file_path = row.get([]u8, 1) catch continue;
        const title = row.get([]u8, 2) catch continue;
        const status = row.get([]u8, 3) catch continue;
        const created_at = row.get(i64, 4) catch 0;
        const updated_at = row.get(i64, 5) catch 0;

        var obj = std.json.ObjectMap.init(alloc);
        obj.put("spec_id", .{ .string = spec_id }) catch continue;
        obj.put("file_path", .{ .string = file_path }) catch continue;
        obj.put("title", .{ .string = title }) catch continue;
        obj.put("status", .{ .string = status }) catch continue;
        obj.put("created_at", .{ .integer = created_at }) catch continue;
        obj.put("updated_at", .{ .integer = updated_at }) catch continue;
        specs.append(alloc, .{ .object = obj }) catch continue;
    }

    writeJson(r, .ok, .{
        .specs = specs.items,
        .total = specs.items.len,
        .request_id = req_id,
    });
}

// ── POST /v1/workspaces/:workspace_id:sync ────────────────────────────────

pub fn handleSyncSpecs(ctx: *Context, r: zap.Request, workspace_id: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const req_id = requestId(alloc);

    if (!authenticate(r, ctx)) {
        errorResponse(r, .unauthorized, "UNAUTHORIZED", "Invalid or missing API key", req_id);
        return;
    }

    var conn = ctx.pool.acquire() catch {
        errorResponse(r, .service_unavailable, "INTERNAL_ERROR", "Database unavailable", req_id);
        return;
    };
    defer ctx.pool.release(conn);

    // Fetch workspace to get repo_url and cache_root
    var ws = conn.query(
        "SELECT repo_url, default_branch FROM workspaces WHERE workspace_id = $1",
        .{workspace_id},
    ) catch {
        errorResponse(r, .internal_server_error, "INTERNAL_ERROR", "Database error", req_id);
        return;
    };
    defer ws.deinit();

    const ws_row = ws.next() catch null orelse {
        errorResponse(r, .not_found, "WORKSPACE_NOT_FOUND", "Workspace not found", req_id);
        return;
    };

    const repo_url = ws_row.get([]u8, 0) catch "";
    _ = repo_url; // used by git sync in full impl

    // In M1, sync discovers PENDING_*.md files from the bare clone.
    // For simplicity, we scan the git tree and upsert specs.
    // Full git scan is deferred — return existing pending specs count.
    var count_result = conn.query(
        "SELECT COUNT(*) FROM specs WHERE workspace_id = $1 AND status = 'pending'",
        .{workspace_id},
    ) catch {
        errorResponse(r, .internal_server_error, "INTERNAL_ERROR", "Database error", req_id);
        return;
    };
    defer count_result.deinit();

    const total_pending: i64 = if (count_result.next() catch null) |crow|
        crow.get(i64, 0) catch 0
    else
        0;

    log.info("sync workspace_id={s} total_pending={d}", .{ workspace_id, total_pending });

    writeJson(r, .ok, .{
        .synced_count = @as(i64, 0),
        .total_pending = total_pending,
        .specs = &[_]u8{},
        .request_id = req_id,
    });
}
