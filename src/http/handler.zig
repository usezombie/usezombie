//! HTTP request handlers for all 6 control-plane endpoints.
//! Uses Zap's request/response API. All responses follow the M1_002 error contract.

const std = @import("std");
const zap = @import("zap");
const pg = @import("pg");
const clerk = @import("../auth/clerk.zig");
const queue_redis = @import("../queue/redis.zig");
const state = @import("../state/machine.zig");
const policy = @import("../state/policy.zig");
const worker = @import("../pipeline/worker.zig");
const secrets = @import("../secrets/crypto.zig");
const harness_handlers = @import("handlers/harness_control_plane.zig");
const skill_secret_handlers = @import("handlers/skill_secrets.zig");
const metrics = @import("../observability/metrics.zig");
const obs_log = @import("../observability/logging.zig");
const db = @import("../db/pool.zig");
const log = std.log.scoped(.http);
const queue_unavailable_code = "QUEUE_UNAVAILABLE";
const queue_unavailable_message = "Queue unavailable";

// ── Handler context (shared across all handlers) ──────────────────────────

pub const Context = struct {
    pool: *pg.Pool,
    queue: *queue_redis.Client,
    alloc: std.mem.Allocator,
    api_keys: []const u8, // comma-separated API key list from env
    clerk: ?*clerk.Verifier,
    worker_state: *const worker.WorkerState,
    api_in_flight_requests: std.atomic.Value(u32),
    api_max_in_flight_requests: u32,
    ready_max_queue_depth: ?i64,
    ready_max_queue_age_ms: ?i64,
};

// ── JSON helpers ──────────────────────────────────────────────────────────

fn writeJson(r: zap.Request, status: zap.http.StatusCode, value: anytype) void {
    var buf: [64 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const json = std.json.Stringify.valueAlloc(fba.allocator(), value, .{}) catch {
        r.setStatus(.internal_server_error);
        r.sendBody("{}") catch |err| obs_log.logWarnErr(.http, err, "writeJson fallback send failed", .{});
        return;
    };
    r.setStatus(status);
    r.setContentType(.JSON) catch |err| obs_log.logWarnErr(.http, err, "setContentType failed", .{});
    r.sendBody(json) catch |err| obs_log.logWarnErr(.http, err, "sendBody failed", .{});
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

pub const SkillSecretRoute = skill_secret_handlers.Route;

pub fn parseSkillSecretRoute(path: []const u8) ?SkillSecretRoute {
    return skill_secret_handlers.parseRoute(path);
}

const AuthMode = enum {
    api_key,
    clerk_jwt,
};

const AuthPrincipal = struct {
    mode: AuthMode,
    tenant_id: ?[]const u8 = null,
};

const AuthError = error{
    Unauthorized,
    TokenExpired,
    AuthServiceUnavailable,
};

/// Validate Authorization header: "Bearer <api_key>".
/// Supports key rotation via `API_KEY=key1,key2,...`.
fn authenticateApiKey(r: zap.Request, ctx: *Context) bool {
    const auth = r.getHeader("authorization") orelse return false;
    const prefix = "Bearer ";
    if (!std.mem.startsWith(u8, auth, prefix)) return false;
    const provided = auth[prefix.len..];

    var it = std.mem.tokenizeScalar(u8, ctx.api_keys, ',');
    while (it.next()) |candidate_raw| {
        const candidate = std.mem.trim(u8, candidate_raw, " \t");
        if (candidate.len == 0) continue;
        if (std.mem.eql(u8, provided, candidate)) return true;
    }
    return false;
}

fn authenticate(alloc: std.mem.Allocator, r: zap.Request, ctx: *Context) AuthError!AuthPrincipal {
    if (ctx.clerk) |verifier| {
        const auth = r.getHeader("authorization") orelse return AuthError.Unauthorized;
        const principal = verifier.verifyAuthorization(alloc, auth) catch |err| return mapClerkVerifyError(err);
        return .{ .mode = .clerk_jwt, .tenant_id = principal.tenant_id };
    }

    if (!authenticateApiKey(r, ctx)) return AuthError.Unauthorized;
    return .{ .mode = .api_key };
}

fn writeAuthError(r: zap.Request, req_id: []const u8, err: AuthError) void {
    switch (err) {
        AuthError.TokenExpired => errorResponse(r, .unauthorized, "token_expired", "token expired", req_id),
        AuthError.Unauthorized => errorResponse(r, .unauthorized, "UNAUTHORIZED", "Invalid or missing token", req_id),
        AuthError.AuthServiceUnavailable => errorResponse(r, .service_unavailable, "AUTH_UNAVAILABLE", "Authentication service unavailable", req_id),
    }
}

fn mapClerkVerifyError(err: clerk.VerifyError) AuthError {
    return switch (err) {
        .TokenExpired => AuthError.TokenExpired,
        .JwksFetchFailed, .JwksParseFailed => AuthError.AuthServiceUnavailable,
        else => AuthError.Unauthorized,
    };
}

fn authorizeWorkspace(conn: *pg.Conn, principal: AuthPrincipal, workspace_id: []const u8) bool {
    if (principal.mode == .api_key) return true;
    const tenant_id = principal.tenant_id orelse return false;

    var q = conn.query(
        "SELECT 1 FROM workspaces WHERE workspace_id = $1 AND tenant_id = $2",
        .{ workspace_id, tenant_id },
    ) catch return false;
    defer q.deinit();
    return (q.next() catch null) != null;
}

fn beginApiRequest(ctx: *Context) bool {
    const prev = ctx.api_in_flight_requests.fetchAdd(1, .acq_rel);
    if (prev >= ctx.api_max_in_flight_requests) {
        const reverted = ctx.api_in_flight_requests.fetchSub(1, .acq_rel);
        std.debug.assert(reverted > 0);
        metrics.incApiBackpressureRejections();
        return false;
    }

    metrics.setApiInFlightRequests(ctx.api_in_flight_requests.load(.acquire));
    return true;
}

fn endApiRequest(ctx: *Context) void {
    const prev = ctx.api_in_flight_requests.fetchSub(1, .acq_rel);
    std.debug.assert(prev > 0);
    metrics.setApiInFlightRequests(ctx.api_in_flight_requests.load(.acquire));
}

fn compensateStartRunQueueFailure(conn: *pg.Conn, run_id: []const u8) void {
    _ = conn.query(
        "DELETE FROM runs WHERE run_id = $1 AND state = 'SPEC_QUEUED'",
        .{run_id},
    ) catch {};
}

fn compensateRetryQueueFailure(
    conn: *pg.Conn,
    run_id: []const u8,
    previous_state: []const u8,
    transition_ts: i64,
) void {
    _ = conn.query(
        "UPDATE runs SET state = $1, updated_at = $2 WHERE run_id = $3",
        .{ previous_state, std.time.milliTimestamp(), run_id },
    ) catch {};
    _ = conn.query(
        "DELETE FROM run_transitions WHERE run_id = $1 AND reason_code = 'MANUAL_RETRY' AND ts = $2",
        .{ run_id, transition_ts },
    ) catch {};
}

// ── Healthz ───────────────────────────────────────────────────────────────

fn databaseHealthy(ctx: *Context) bool {
    const conn = ctx.pool.acquire() catch return false;
    defer ctx.pool.release(conn);

    var ping = conn.query("SELECT 1", .{}) catch return false;
    defer ping.deinit();

    return (ping.next() catch null) != null;
}

const QueueHealth = struct {
    queued_count: i64,
    oldest_queued_age_ms: ?i64,
};

const ReadyInputs = struct {
    db_ok: bool,
    worker_ok: bool,
    queue_dependency_ok: bool,
    queue_depth_breached: bool,
    queue_age_breached: bool,
};

fn queueHealth(ctx: *Context) ?QueueHealth {
    const conn = ctx.pool.acquire() catch return null;
    defer ctx.pool.release(conn);

    var q = conn.query(
        \\SELECT COUNT(*)::BIGINT, MIN(created_at)::BIGINT
        \\FROM runs
        \\WHERE state = 'SPEC_QUEUED'
    , .{}) catch return null;
    defer q.deinit();

    const row = (q.next() catch null) orelse return null;
    const queued_count = row.get(i64, 0) catch return null;
    const oldest_created_ms = row.get(?i64, 1) catch return null;
    const now_ms = std.time.milliTimestamp();
    const oldest_age_ms = if (oldest_created_ms) |ts| now_ms - ts else null;
    return .{
        .queued_count = queued_count,
        .oldest_queued_age_ms = oldest_age_ms,
    };
}

fn queueDependencyHealthy(ctx: *Context) bool {
    ctx.queue.readyCheck() catch |err| {
        obs_log.logWarnErr(.http, err, "readyz: redis queue dependency check failed", .{});
        return false;
    };
    return true;
}

fn readyDecision(inputs: ReadyInputs) bool {
    return inputs.db_ok and
        inputs.worker_ok and
        inputs.queue_dependency_ok and
        !inputs.queue_depth_breached and
        !inputs.queue_age_breached;
}

pub fn handleHealthz(ctx: *Context, r: zap.Request) void {
    const db_ok = databaseHealthy(ctx);
    if (!db_ok) {
        writeJson(r, .service_unavailable, .{
            .status = "degraded",
            .service = "zombied",
            .database = "down",
        });
        return;
    }

    writeJson(r, .ok, .{
        .status = "ok",
        .service = "zombied",
        .database = "up",
    });
}

pub fn handleReadyz(ctx: *Context, r: zap.Request) void {
    const db_ok = databaseHealthy(ctx);
    const worker_ok = ctx.worker_state.running.load(.acquire);
    const queue_dependency_ok = queueDependencyHealthy(ctx);
    const qh = if (db_ok) queueHealth(ctx) else null;

    var queue_depth_breached = false;
    var queue_age_breached = false;
    if (qh) |v| {
        if (ctx.ready_max_queue_depth) |limit| {
            queue_depth_breached = v.queued_count > limit;
        }
        if (ctx.ready_max_queue_age_ms) |limit| {
            if (v.oldest_queued_age_ms) |age| {
                queue_age_breached = age > limit;
            }
        }
    }

    if (!readyDecision(.{
        .db_ok = db_ok,
        .worker_ok = worker_ok,
        .queue_dependency_ok = queue_dependency_ok,
        .queue_depth_breached = queue_depth_breached,
        .queue_age_breached = queue_age_breached,
    })) {
        writeJson(r, .service_unavailable, .{
            .ready = false,
            .database = db_ok,
            .worker = worker_ok,
            .queue_dependency = queue_dependency_ok,
            .queue_depth = if (qh) |v| v.queued_count else null,
            .oldest_queued_age_ms = if (qh) |v| v.oldest_queued_age_ms else null,
            .queue_depth_breached = queue_depth_breached,
            .queue_age_breached = queue_age_breached,
            .queue_depth_limit = ctx.ready_max_queue_depth,
            .queue_age_limit_ms = ctx.ready_max_queue_age_ms,
        });
        return;
    }

    writeJson(r, .ok, .{
        .ready = true,
        .database = true,
        .worker = true,
        .queue_dependency = true,
        .queue_depth = if (qh) |v| v.queued_count else @as(i64, 0),
        .oldest_queued_age_ms = if (qh) |v| v.oldest_queued_age_ms else null,
        .queue_depth_breached = false,
        .queue_age_breached = false,
        .queue_depth_limit = ctx.ready_max_queue_depth,
        .queue_age_limit_ms = ctx.ready_max_queue_age_ms,
    });
}

pub fn handleMetrics(ctx: *Context, r: zap.Request) void {
    const qh = queueHealth(ctx);
    const body = metrics.renderPrometheus(
        ctx.alloc,
        ctx.worker_state.running.load(.acquire),
        if (qh) |v| v.queued_count else null,
        if (qh) |v| v.oldest_queued_age_ms else null,
    ) catch {
        r.setStatus(.internal_server_error);
        r.sendBody("") catch |err| obs_log.logWarnErr(.http, err, "metrics send failed", .{});
        return;
    };
    defer ctx.alloc.free(body);

    r.setStatus(.ok);
    r.setContentType(.TEXT) catch |err| obs_log.logWarnErr(.http, err, "setContentType TEXT failed", .{});
    r.sendBody(body) catch |err| obs_log.logWarnErr(.http, err, "metrics body send failed", .{});
}

// ── POST /v1/runs ─────────────────────────────────────────────────────────

pub fn handleStartRun(ctx: *Context, r: zap.Request) void {
    var arena = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    const req_id = requestId(alloc);

    const principal = authenticate(alloc, r, ctx) catch |err| {
        writeAuthError(r, req_id, err);
        return;
    };

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

    if (!beginApiRequest(ctx)) {
        errorResponse(r, .service_unavailable, "API_SATURATED", "Server overloaded; retry shortly", req_id);
        return;
    }
    defer endApiRequest(ctx);

    const conn = ctx.pool.acquire() catch {
        errorResponse(r, .service_unavailable, "INTERNAL_ERROR", "Database unavailable", req_id);
        return;
    };
    defer ctx.pool.release(conn);

    if (!authorizeWorkspace(conn, principal, req.workspace_id)) {
        errorResponse(r, .forbidden, "FORBIDDEN", "Workspace access denied", req_id);
        return;
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
        \\   requested_by, idempotency_key, request_id, branch, created_at, updated_at)
        \\SELECT $1, $2, $3, tenant_id, 'SPEC_QUEUED', 1, $4, $5, $6, $7, $8, $9, $9
        \\FROM workspaces WHERE workspace_id = $2
        \\ON CONFLICT (workspace_id, idempotency_key) DO UPDATE
        \\SET updated_at = runs.updated_at
        \\RETURNING run_id, state, attempt, (xmax = 0) AS inserted
    , .{ run_id, req.workspace_id, req.spec_id, req.mode, req.requested_by, req.idempotency_key, req_id, branch, now_ms }) catch {
        errorResponse(r, .internal_server_error, "INTERNAL_ERROR", "Failed to create run", req_id);
        return;
    };
    defer insert.deinit();

    const inserted_row = insert.next() catch null orelse {
        errorResponse(r, .internal_server_error, "INTERNAL_ERROR", "Failed to upsert run", req_id);
        return;
    };
    const final_run_id = inserted_row.get([]u8, 0) catch run_id;
    const final_state = inserted_row.get([]u8, 1) catch "SPEC_QUEUED";
    const final_attempt = inserted_row.get(i32, 2) catch 1;
    const was_inserted = inserted_row.get(bool, 3) catch false;

    if (was_inserted) {
        // Record policy_decision event — sensitive action, M1 permissive mode (always allow)
        policy.recordPolicyEvent(conn, req.workspace_id, final_run_id, .sensitive, .allow, "m1.start_run", req.requested_by) catch |err| {
            obs_log.logWarnErr(.http, err, "policy event insert failed (non-fatal) run_id={s}", .{final_run_id});
        };

        log.info("run created run_id={s} workspace_id={s} spec_id={s}", .{
            final_run_id, req.workspace_id, req.spec_id,
        });
        ctx.queue.xaddRun(final_run_id, 0, req.workspace_id) catch |err| {
            obs_log.logWarnErr(.http, err, "queue enqueue failed run_id={s} workspace_id={s}", .{
                final_run_id,
                req.workspace_id,
            });
            compensateStartRunQueueFailure(conn, final_run_id);
            errorResponse(r, .service_unavailable, queue_unavailable_code, queue_unavailable_message, req_id);
            return;
        };
        metrics.incRunsCreated();
    } else {
        log.info("run idempotent replay run_id={s} workspace_id={s}", .{ final_run_id, req.workspace_id });
    }

    writeJson(r, .accepted, .{
        .run_id = final_run_id,
        .state = final_state,
        .attempt = @as(u32, @intCast(final_attempt)),
        .request_id = req_id,
    });
}

// ── GET /v1/runs/:run_id ──────────────────────────────────────────────────

pub fn handleGetRun(ctx: *Context, r: zap.Request, run_id: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const req_id = requestId(alloc);

    const principal = authenticate(alloc, r, ctx) catch |err| {
        writeAuthError(r, req_id, err);
        return;
    };

    const conn = ctx.pool.acquire() catch {
        errorResponse(r, .service_unavailable, "INTERNAL_ERROR", "Database unavailable", req_id);
        return;
    };
    defer ctx.pool.release(conn);

    // Fetch run
    var run_result = conn.query(
        \\SELECT run_id, workspace_id, spec_id, state, attempt, mode,
        \\       requested_by, branch, pr_url, request_id, created_at, updated_at
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
    const run_request_id = row.get(?[]u8, 9) catch null;
    const created_at = row.get(i64, 10) catch 0;
    const updated_at = row.get(i64, 11) catch 0;

    if (!authorizeWorkspace(conn, principal, workspace_id)) {
        errorResponse(r, .forbidden, "FORBIDDEN", "Workspace access denied", req_id);
        return;
    }

    run_result.drain() catch |err| obs_log.logWarnErr(.http, err, "run query drain failed run_id={s}", .{run_id});

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
    trans_result.drain() catch |err| obs_log.logWarnErr(.http, err, "transitions query drain failed run_id={s}", .{run_id});

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
        .run_request_id = run_request_id,
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

    const principal = authenticate(alloc, r, ctx) catch |err| {
        writeAuthError(r, req_id, err);
        return;
    };

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

    const conn = ctx.pool.acquire() catch {
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

    if (workspace_id_for_policy.len > 0 and !authorizeWorkspace(conn, principal, workspace_id_for_policy)) {
        errorResponse(r, .forbidden, "FORBIDDEN", "Workspace access denied", req_id);
        return;
    }

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
        obs_log.logWarnErr(.http, err, "policy event insert failed (non-fatal) run_id={s}", .{run_id});
    };

    // Re-queue: transition back to SPEC_QUEUED
    const now_ms = std.time.milliTimestamp();
    var r2 = conn.query(
        "UPDATE runs SET state = 'SPEC_QUEUED', request_id = $1, updated_at = $2 WHERE run_id = $3",
        .{ req_id, now_ms, run_id },
    ) catch {
        errorResponse(r, .internal_server_error, "INTERNAL_ERROR", "Database error", req_id);
        return;
    };
    r2.deinit();

    var r3 = conn.query(
        \\INSERT INTO run_transitions (run_id, attempt, state_from, state_to, actor, reason_code, notes, ts)
        \\VALUES ($1, $2, $3, 'SPEC_QUEUED', 'orchestrator', 'MANUAL_RETRY', $4, $5)
    , .{
        run_id,                @as(i32, @intCast(current.attempt)),
        current.state.label(), parsed.value.reason,
        now_ms,
    }) catch {
        errorResponse(r, .internal_server_error, "INTERNAL_ERROR", "Database error", req_id);
        return;
    };
    r3.deinit();

    log.info("run retried run_id={s} reason={s}", .{ run_id, parsed.value.reason });
    ctx.queue.xaddRun(run_id, current.attempt + 1, workspace_id_for_policy) catch |err| {
        obs_log.logWarnErr(.http, err, "queue enqueue failed for retry run_id={s}", .{run_id});
        compensateRetryQueueFailure(conn, run_id, current.state.label(), now_ms);
        errorResponse(r, .service_unavailable, queue_unavailable_code, queue_unavailable_message, req_id);
        return;
    };

    writeJson(r, .accepted, .{
        .run_id = run_id,
        .state = "SPEC_QUEUED",
        .attempt = current.attempt,
        .request_id = req_id,
    });
}

test "integration: beginApiRequest enforces max in-flight limit" {
    var ws = worker.WorkerState.init();
    var ctx = Context{
        .pool = undefined,
        .queue = undefined,
        .alloc = std.testing.allocator,
        .api_keys = "",
        .clerk = null,
        .worker_state = &ws,
        .api_in_flight_requests = std.atomic.Value(u32).init(0),
        .api_max_in_flight_requests = 2,
        .ready_max_queue_depth = null,
        .ready_max_queue_age_ms = null,
    };

    try std.testing.expect(beginApiRequest(&ctx));
    try std.testing.expect(beginApiRequest(&ctx));
    try std.testing.expect(!beginApiRequest(&ctx));
    try std.testing.expectEqual(@as(u32, 2), ctx.api_in_flight_requests.load(.acquire));
}

test "integration: endApiRequest decrements in-flight counter deterministically" {
    var ws = worker.WorkerState.init();
    var ctx = Context{
        .pool = undefined,
        .queue = undefined,
        .alloc = std.testing.allocator,
        .api_keys = "",
        .clerk = null,
        .worker_state = &ws,
        .api_in_flight_requests = std.atomic.Value(u32).init(0),
        .api_max_in_flight_requests = 1,
        .ready_max_queue_depth = null,
        .ready_max_queue_age_ms = null,
    };

    try std.testing.expect(beginApiRequest(&ctx));
    endApiRequest(&ctx);
    try std.testing.expectEqual(@as(u32, 0), ctx.api_in_flight_requests.load(.acquire));
}

test "integration: ready decision fails closed when redis queue dependency is degraded" {
    try std.testing.expect(!readyDecision(.{
        .db_ok = true,
        .worker_ok = true,
        .queue_dependency_ok = false,
        .queue_depth_breached = false,
        .queue_age_breached = false,
    }));
}

test "integration: ready decision fails during worker restart window" {
    try std.testing.expect(!readyDecision(.{
        .db_ok = true,
        .worker_ok = false,
        .queue_dependency_ok = true,
        .queue_depth_breached = false,
        .queue_age_breached = false,
    }));
}

test "integration: ready decision passes when dependencies and guardrails are healthy" {
    try std.testing.expect(readyDecision(.{
        .db_ok = true,
        .worker_ok = true,
        .queue_dependency_ok = true,
        .queue_depth_breached = false,
        .queue_age_breached = false,
    }));
}

fn openHandlerTestConn(alloc: std.mem.Allocator) !?struct { pool: *db.Pool, conn: *pg.Conn } {
    const url = std.process.getEnvVarOwned(alloc, "HANDLER_DB_TEST_URL") catch
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

test "integration: start-run queue failure compensation removes only SPEC_QUEUED row" {
    const db_ctx = (try openHandlerTestConn(std.testing.allocator)) orelse return error.SkipZigTest;
    defer db_ctx.pool.release(db_ctx.conn);
    defer db_ctx.pool.deinit();

    {
        var q = try db_ctx.conn.query(
            \\CREATE TEMP TABLE runs (
            \\  run_id TEXT PRIMARY KEY,
            \\  state TEXT NOT NULL,
            \\  updated_at BIGINT NOT NULL
            \\) ON COMMIT DROP
        , .{});
        q.deinit();
    }

    const now_ms = std.time.milliTimestamp();
    {
        var q = try db_ctx.conn.query(
            "INSERT INTO runs (run_id, state, updated_at) VALUES ($1, 'SPEC_QUEUED', $2)",
            .{ "run-delete", now_ms },
        );
        q.deinit();
    }
    {
        var q = try db_ctx.conn.query(
            "INSERT INTO runs (run_id, state, updated_at) VALUES ($1, 'RUN_PLANNED', $2)",
            .{ "run-keep", now_ms },
        );
        q.deinit();
    }

    compensateStartRunQueueFailure(db_ctx.conn, "run-delete");
    compensateStartRunQueueFailure(db_ctx.conn, "run-keep");

    {
        var q = try db_ctx.conn.query("SELECT COUNT(*)::BIGINT FROM runs WHERE run_id = 'run-delete'", .{});
        defer q.deinit();
        const row = (q.next() catch null) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(i64, 0), row.get(i64, 0) catch -1);
    }
    {
        var q = try db_ctx.conn.query("SELECT COUNT(*)::BIGINT FROM runs WHERE run_id = 'run-keep'", .{});
        defer q.deinit();
        const row = (q.next() catch null) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(i64, 1), row.get(i64, 0) catch -1);
    }
}

test "integration: retry queue failure compensation restores state and removes retry transition" {
    const db_ctx = (try openHandlerTestConn(std.testing.allocator)) orelse return error.SkipZigTest;
    defer db_ctx.pool.release(db_ctx.conn);
    defer db_ctx.pool.deinit();

    {
        var q = try db_ctx.conn.query(
            \\CREATE TEMP TABLE runs (
            \\  run_id TEXT PRIMARY KEY,
            \\  state TEXT NOT NULL,
            \\  updated_at BIGINT NOT NULL
            \\) ON COMMIT DROP
        , .{});
        q.deinit();
    }
    {
        var q = try db_ctx.conn.query(
            \\CREATE TEMP TABLE run_transitions (
            \\  run_id TEXT NOT NULL,
            \\  reason_code TEXT NOT NULL,
            \\  ts BIGINT NOT NULL
            \\) ON COMMIT DROP
        , .{});
        q.deinit();
    }

    const now_ms = std.time.milliTimestamp();
    const transition_ts = now_ms + 1;
    {
        var q = try db_ctx.conn.query(
            "INSERT INTO runs (run_id, state, updated_at) VALUES ($1, 'SPEC_QUEUED', $2)",
            .{ "run-retry", now_ms },
        );
        q.deinit();
    }
    {
        var q = try db_ctx.conn.query(
            "INSERT INTO run_transitions (run_id, reason_code, ts) VALUES ($1, 'MANUAL_RETRY', $2)",
            .{ "run-retry", transition_ts },
        );
        q.deinit();
    }

    compensateRetryQueueFailure(db_ctx.conn, "run-retry", "RUN_FAILED", transition_ts);

    {
        var q = try db_ctx.conn.query("SELECT state FROM runs WHERE run_id = $1", .{"run-retry"});
        defer q.deinit();
        const row = (q.next() catch null) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("RUN_FAILED", row.get([]const u8, 0) catch "");
    }
    {
        var q = try db_ctx.conn.query(
            "SELECT COUNT(*)::BIGINT FROM run_transitions WHERE run_id = $1 AND reason_code = 'MANUAL_RETRY' AND ts = $2",
            .{ "run-retry", transition_ts },
        );
        defer q.deinit();
        const row = (q.next() catch null) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(i64, 0), row.get(i64, 0) catch -1);
    }
}

// ── POST /v1/workspaces/:workspace_id:pause ───────────────────────────────

pub fn handlePauseWorkspace(ctx: *Context, r: zap.Request, workspace_id: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const req_id = requestId(alloc);

    const principal = authenticate(alloc, r, ctx) catch |err| {
        writeAuthError(r, req_id, err);
        return;
    };

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

    const conn = ctx.pool.acquire() catch {
        errorResponse(r, .service_unavailable, "INTERNAL_ERROR", "Database unavailable", req_id);
        return;
    };
    defer ctx.pool.release(conn);

    if (!authorizeWorkspace(conn, principal, workspace_id)) {
        errorResponse(r, .forbidden, "FORBIDDEN", "Workspace access denied", req_id);
        return;
    }

    // Record policy_decision event before state change — sensitive action
    policy.recordPolicyEvent(conn, workspace_id, null, .sensitive, .allow, "m1.pause_workspace", "api") catch |err| {
        obs_log.logWarnErr(.http, err, "policy event insert failed (non-fatal) workspace_id={s}", .{workspace_id});
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

    const principal = authenticate(alloc, r, ctx) catch |err| {
        writeAuthError(r, req_id, err);
        return;
    };

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

    const conn = ctx.pool.acquire() catch {
        errorResponse(r, .service_unavailable, "INTERNAL_ERROR", "Database unavailable", req_id);
        return;
    };
    defer ctx.pool.release(conn);

    if (!authorizeWorkspace(conn, principal, wid)) {
        errorResponse(r, .forbidden, "FORBIDDEN", "Workspace access denied", req_id);
        return;
    }

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

    const principal = authenticate(alloc, r, ctx) catch |err| {
        writeAuthError(r, req_id, err);
        return;
    };

    const conn = ctx.pool.acquire() catch {
        errorResponse(r, .service_unavailable, "INTERNAL_ERROR", "Database unavailable", req_id);
        return;
    };
    defer ctx.pool.release(conn);

    if (!authorizeWorkspace(conn, principal, workspace_id)) {
        errorResponse(r, .forbidden, "FORBIDDEN", "Workspace access denied", req_id);
        return;
    }

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

// ── PUT /v1/workspaces/{workspace_id}/harness/source ─────────────────────

pub fn handlePutHarnessSource(ctx: *Context, r: zap.Request, workspace_id: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const req_id = requestId(alloc);

    const principal = authenticate(alloc, r, ctx) catch |err| {
        writeAuthError(r, req_id, err);
        return;
    };

    const Req = harness_handlers.PutSourceInput;
    const body = r.body orelse {
        errorResponse(r, .bad_request, "INVALID_REQUEST", "Request body required", req_id);
        return;
    };
    const parsed = std.json.parseFromSlice(Req, alloc, body, .{}) catch {
        errorResponse(r, .bad_request, "INVALID_REQUEST", "Malformed JSON", req_id);
        return;
    };
    defer parsed.deinit();

    const conn = ctx.pool.acquire() catch {
        errorResponse(r, .service_unavailable, "INTERNAL_ERROR", "Database unavailable", req_id);
        return;
    };
    defer ctx.pool.release(conn);
    if (!authorizeWorkspace(conn, principal, workspace_id)) {
        errorResponse(r, .forbidden, "FORBIDDEN", "Workspace access denied", req_id);
        return;
    }

    const out = harness_handlers.putSource(conn, alloc, workspace_id, parsed.value) catch |err| {
        switch (err) {
            error.InvalidRequest => errorResponse(r, .bad_request, "INVALID_REQUEST", "Invalid harness source payload", req_id),
            error.WorkspaceNotFound => errorResponse(r, .not_found, "WORKSPACE_NOT_FOUND", "Workspace not found", req_id),
            else => errorResponse(r, .internal_server_error, "INTERNAL_ERROR", "Failed to store harness source", req_id),
        }
        return;
    };

    writeJson(r, .ok, .{
        .workspace_id = workspace_id,
        .profile_id = out.profile_id,
        .profile_version_id = out.profile_version_id,
        .version = out.version,
        .status = "DRAFT",
        .request_id = req_id,
    });
}

// ── POST /v1/workspaces/{workspace_id}/harness/compile ───────────────────

pub fn handleCompileHarness(ctx: *Context, r: zap.Request, workspace_id: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const req_id = requestId(alloc);

    const principal = authenticate(alloc, r, ctx) catch |err| {
        writeAuthError(r, req_id, err);
        return;
    };

    const Req = harness_handlers.CompileInput;
    const body = r.body orelse {
        errorResponse(r, .bad_request, "INVALID_REQUEST", "Request body required", req_id);
        return;
    };
    const parsed = std.json.parseFromSlice(Req, alloc, body, .{}) catch {
        errorResponse(r, .bad_request, "INVALID_REQUEST", "Malformed JSON", req_id);
        return;
    };
    defer parsed.deinit();

    const conn = ctx.pool.acquire() catch {
        errorResponse(r, .service_unavailable, "INTERNAL_ERROR", "Database unavailable", req_id);
        return;
    };
    defer ctx.pool.release(conn);

    if (!authorizeWorkspace(conn, principal, workspace_id)) {
        errorResponse(r, .forbidden, "FORBIDDEN", "Workspace access denied", req_id);
        return;
    }

    const out = harness_handlers.compileProfile(conn, alloc, workspace_id, parsed.value) catch |err| {
        switch (err) {
            error.ProfileNotFound => errorResponse(r, .not_found, "PROFILE_NOT_FOUND", "No harness profile source found for workspace", req_id),
            error.CompileFailed => errorResponse(r, .internal_server_error, "INTERNAL_ERROR", "Harness compile failed", req_id),
            else => errorResponse(r, .internal_server_error, "INTERNAL_ERROR", "Failed to compile harness profile", req_id),
        }
        return;
    };

    writeJson(r, .ok, .{
        .compile_job_id = out.compile_job_id,
        .workspace_id = workspace_id,
        .profile_id = out.profile_id,
        .profile_version_id = out.profile_version_id,
        .is_valid = out.is_valid,
        .validation_report_json = out.validation_report_json,
        .request_id = req_id,
    });
}

// ── POST /v1/workspaces/{workspace_id}/harness/activate ──────────────────

pub fn handleActivateHarness(ctx: *Context, r: zap.Request, workspace_id: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const req_id = requestId(alloc);

    const principal = authenticate(alloc, r, ctx) catch |err| {
        writeAuthError(r, req_id, err);
        return;
    };

    const Req = harness_handlers.ActivateInput;
    const body = r.body orelse {
        errorResponse(r, .bad_request, "INVALID_REQUEST", "Request body required", req_id);
        return;
    };
    const parsed = std.json.parseFromSlice(Req, alloc, body, .{}) catch {
        errorResponse(r, .bad_request, "INVALID_REQUEST", "Malformed JSON", req_id);
        return;
    };
    defer parsed.deinit();

    const conn = ctx.pool.acquire() catch {
        errorResponse(r, .service_unavailable, "INTERNAL_ERROR", "Database unavailable", req_id);
        return;
    };
    defer ctx.pool.release(conn);

    if (!authorizeWorkspace(conn, principal, workspace_id)) {
        errorResponse(r, .forbidden, "FORBIDDEN", "Workspace access denied", req_id);
        return;
    }

    const out = harness_handlers.activateProfile(conn, workspace_id, parsed.value) catch |err| {
        switch (err) {
            error.ProfileNotFound => errorResponse(r, .not_found, "PROFILE_NOT_FOUND", "Profile version not found", req_id),
            error.ProfileInvalid => errorResponse(r, .conflict, "PROFILE_INVALID", "Invalid profile cannot be activated", req_id),
            else => errorResponse(r, .internal_server_error, "INTERNAL_ERROR", "Failed to activate profile", req_id),
        }
        return;
    };

    writeJson(r, .ok, .{
        .workspace_id = workspace_id,
        .profile_version_id = out.profile_version_id,
        .activated_by = out.activated_by,
        .activated_at = out.activated_at,
        .request_id = req_id,
    });
}

// ── GET /v1/workspaces/{workspace_id}/harness/active ─────────────────────

pub fn handleGetHarnessActive(ctx: *Context, r: zap.Request, workspace_id: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const req_id = requestId(alloc);

    const principal = authenticate(alloc, r, ctx) catch |err| {
        writeAuthError(r, req_id, err);
        return;
    };

    const conn = ctx.pool.acquire() catch {
        errorResponse(r, .service_unavailable, "INTERNAL_ERROR", "Database unavailable", req_id);
        return;
    };
    defer ctx.pool.release(conn);

    if (!authorizeWorkspace(conn, principal, workspace_id)) {
        errorResponse(r, .forbidden, "FORBIDDEN", "Workspace access denied", req_id);
        return;
    }

    const out = harness_handlers.getActiveProfile(conn, alloc, workspace_id) catch {
        errorResponse(r, .internal_server_error, "INTERNAL_ERROR", "Failed to resolve active profile", req_id);
        return;
    };
    defer alloc.free(out.profile_json);

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, out.profile_json, .{}) catch {
        errorResponse(r, .internal_server_error, "INTERNAL_ERROR", "Failed to render profile JSON", req_id);
        return;
    };
    defer parsed.deinit();
    writeJson(r, .ok, .{
        .workspace_id = workspace_id,
        .source = out.source,
        .profile_version_id = out.profile_version_id,
        .profile = parsed.value,
        .request_id = req_id,
    });
}

// ── PUT|DELETE /v1/workspaces/{workspace_id}/skills/{skill_ref}/secrets/{key_name}

pub fn handlePutWorkspaceSkillSecret(
    ctx: *Context,
    r: zap.Request,
    workspace_id: []const u8,
    skill_ref_encoded: []const u8,
    key_name_encoded: []const u8,
) void {
    var arena = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const req_id = requestId(alloc);

    const principal = authenticate(alloc, r, ctx) catch |err| {
        writeAuthError(r, req_id, err);
        return;
    };

    const Req = skill_secret_handlers.PutInput;
    const body = r.body orelse {
        errorResponse(r, .bad_request, "INVALID_REQUEST", "Request body required", req_id);
        return;
    };
    const parsed = std.json.parseFromSlice(Req, alloc, body, .{}) catch {
        errorResponse(r, .bad_request, "INVALID_REQUEST", "Malformed JSON", req_id);
        return;
    };
    defer parsed.deinit();
    const conn = ctx.pool.acquire() catch {
        errorResponse(r, .service_unavailable, "INTERNAL_ERROR", "Database unavailable", req_id);
        return;
    };
    defer ctx.pool.release(conn);

    if (!authorizeWorkspace(conn, principal, workspace_id)) {
        errorResponse(r, .forbidden, "FORBIDDEN", "Workspace access denied", req_id);
        return;
    }

    const out = skill_secret_handlers.put(conn, alloc, workspace_id, skill_ref_encoded, key_name_encoded, parsed.value) catch |err| {
        switch (err) {
            error.InvalidRequest => errorResponse(r, .bad_request, "INVALID_REQUEST", "Invalid skill secret payload", req_id),
            error.MissingMasterKey => errorResponse(r, .internal_server_error, "INTERNAL_ERROR", "ENCRYPTION_MASTER_KEY is missing", req_id),
            else => errorResponse(r, .internal_server_error, "INTERNAL_ERROR", "Failed to store skill secret", req_id),
        }
        return;
    };

    writeJson(r, .ok, .{
        .workspace_id = workspace_id,
        .skill_ref = out.skill_ref,
        .key_name = out.key_name,
        .scope = out.scope.label(),
        .request_id = req_id,
    });
}

pub fn handleDeleteWorkspaceSkillSecret(
    ctx: *Context,
    r: zap.Request,
    workspace_id: []const u8,
    skill_ref_encoded: []const u8,
    key_name_encoded: []const u8,
) void {
    var arena = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const req_id = requestId(alloc);

    const principal = authenticate(alloc, r, ctx) catch |err| {
        writeAuthError(r, req_id, err);
        return;
    };

    const conn = ctx.pool.acquire() catch {
        errorResponse(r, .service_unavailable, "INTERNAL_ERROR", "Database unavailable", req_id);
        return;
    };
    defer ctx.pool.release(conn);

    if (!authorizeWorkspace(conn, principal, workspace_id)) {
        errorResponse(r, .forbidden, "FORBIDDEN", "Workspace access denied", req_id);
        return;
    }

    const out = skill_secret_handlers.delete(conn, alloc, workspace_id, skill_ref_encoded, key_name_encoded) catch {
        errorResponse(r, .internal_server_error, "INTERNAL_ERROR", "Failed to delete skill secret", req_id);
        return;
    };

    writeJson(r, .ok, .{
        .workspace_id = workspace_id,
        .skill_ref = out.skill_ref,
        .key_name = out.key_name,
        .deleted = true,
        .request_id = req_id,
    });
}

// ── GET /v1/github/callback ───────────────────────────────────────────────

pub fn handleGitHubCallback(ctx: *Context, r: zap.Request) void {
    var arena = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const req_id = requestId(alloc);

    const installation_id = r.getParamStr(alloc, "installation_id") catch null orelse {
        errorResponse(r, .bad_request, "INVALID_REQUEST", "installation_id query param required", req_id);
        return;
    };
    defer alloc.free(installation_id);

    const workspace_id = r.getParamStr(alloc, "state") catch null orelse {
        errorResponse(r, .bad_request, "INVALID_REQUEST", "state query param required", req_id);
        return;
    };
    defer alloc.free(workspace_id);

    const conn = ctx.pool.acquire() catch {
        errorResponse(r, .service_unavailable, "INTERNAL_ERROR", "Database unavailable", req_id);
        return;
    };
    defer ctx.pool.release(conn);

    const now_ms = std.time.milliTimestamp();

    // Bootstrap a synthetic tenant/workspace pair for callback-only flows.
    {
        var t = conn.query(
            \\INSERT INTO tenants (tenant_id, name, api_key_hash, created_at)
            \\VALUES ('github_app', 'GitHub App', 'callback', $1)
            \\ON CONFLICT (tenant_id) DO NOTHING
        , .{now_ms}) catch {
            errorResponse(r, .internal_server_error, "INTERNAL_ERROR", "Failed to upsert tenant", req_id);
            return;
        };
        t.deinit();
    }

    {
        const repo_url_opt = r.getParamStr(alloc, "repo_url") catch null;
        const repo_url = repo_url_opt orelse "https://github.com/unknown/unknown";
        defer if (repo_url_opt) |v| alloc.free(v);

        const default_branch_opt = r.getParamStr(alloc, "default_branch") catch null;
        const default_branch = default_branch_opt orelse "main";
        defer if (default_branch_opt) |v| alloc.free(v);

        var w = conn.query(
            \\INSERT INTO workspaces
            \\  (workspace_id, tenant_id, repo_url, default_branch, paused, version, created_at, updated_at)
            \\VALUES ($1, 'github_app', $2, $3, false, 1, $4, $4)
            \\ON CONFLICT (workspace_id) DO UPDATE
            \\SET repo_url = EXCLUDED.repo_url,
            \\    default_branch = EXCLUDED.default_branch,
            \\    updated_at = EXCLUDED.updated_at
        , .{ workspace_id, repo_url, default_branch, now_ms }) catch {
            errorResponse(r, .internal_server_error, "INTERNAL_ERROR", "Failed to upsert workspace", req_id);
            return;
        };
        w.deinit();
    }

    const kek = secrets.loadKek(alloc) catch {
        errorResponse(r, .internal_server_error, "INTERNAL_ERROR", "ENCRYPTION_MASTER_KEY is missing", req_id);
        return;
    };

    secrets.store(
        alloc,
        conn,
        workspace_id,
        "github_app_installation_id",
        installation_id,
        kek,
    ) catch {
        errorResponse(r, .internal_server_error, "INTERNAL_ERROR", "Failed to store installation secret", req_id);
        return;
    };

    writeJson(r, .ok, .{
        .workspace_id = workspace_id,
        .installation_id = installation_id,
        .request_id = req_id,
    });
}

test "mapClerkVerifyError maps expired token to token_expired response path" {
    try std.testing.expectEqual(AuthError.TokenExpired, mapClerkVerifyError(clerk.VerifyError.TokenExpired));
}

test "mapClerkVerifyError maps jwks failures to auth unavailable" {
    try std.testing.expectEqual(AuthError.AuthServiceUnavailable, mapClerkVerifyError(clerk.VerifyError.JwksFetchFailed));
    try std.testing.expectEqual(AuthError.AuthServiceUnavailable, mapClerkVerifyError(clerk.VerifyError.JwksParseFailed));
}

test "mapClerkVerifyError maps signature failures to unauthorized" {
    try std.testing.expectEqual(AuthError.Unauthorized, mapClerkVerifyError(clerk.VerifyError.SignatureInvalid));
}

test "parseSkillSecretRoute extracts workspace, skill_ref, and key_name" {
    const route = skill_secret_handlers.parseRoute("/v1/workspaces/ws_123/skills/clawhub%3A%2F%2Fopenclaw%2Freviewer%401.2.0/secrets/API_KEY") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("ws_123", route.workspace_id);
    try std.testing.expectEqualStrings("clawhub%3A%2F%2Fopenclaw%2Freviewer%401.2.0", route.skill_ref_encoded);
    try std.testing.expectEqualStrings("API_KEY", route.key_name_encoded);
}

test "decodePathSegment decodes percent-encoded path segments" {
    const decoded = try skill_secret_handlers.decodePathSegment(std.testing.allocator, "clawhub%3A%2F%2Fopenclaw%2Freviewer%401.2.0");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("clawhub://openclaw/reviewer@1.2.0", decoded);
}
