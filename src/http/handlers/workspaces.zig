const std = @import("std");
const zap = @import("zap");
const policy = @import("../../state/policy.zig");
const obs_log = @import("../../observability/logging.zig");
const common = @import("common.zig");
const log = std.log.scoped(.http);

pub fn handlePauseWorkspace(ctx: *common.Context, r: zap.Request, workspace_id: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const req_id = common.requestId(alloc);

    const principal = common.authenticate(alloc, r, ctx) catch |err| {
        common.writeAuthError(r, req_id, err);
        return;
    };

    const Req = struct {
        pause: bool,
        reason: []const u8,
        version: i64,
    };

    const body = r.body orelse {
        common.errorResponse(r, .bad_request, "INVALID_REQUEST", "Request body required", req_id);
        return;
    };
    const parsed = std.json.parseFromSlice(Req, alloc, body, .{}) catch {
        common.errorResponse(r, .bad_request, "INVALID_REQUEST", "Malformed JSON", req_id);
        return;
    };
    defer parsed.deinit();

    const conn = ctx.pool.acquire() catch {
        common.errorResponse(r, .service_unavailable, "INTERNAL_ERROR", "Database unavailable", req_id);
        return;
    };
    defer ctx.pool.release(conn);

    if (!common.authorizeWorkspace(conn, principal, workspace_id)) {
        common.errorResponse(r, .forbidden, "FORBIDDEN", "Workspace access denied", req_id);
        return;
    }

    policy.recordPolicyEvent(conn, workspace_id, null, .sensitive, .allow, "m1.pause_workspace", "api") catch |err| {
        obs_log.logWarnErr(.http, err, "policy event insert failed (non-fatal) workspace_id={s}", .{workspace_id});
    };

    const now_ms = std.time.milliTimestamp();
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
        common.errorResponse(r, .internal_server_error, "INTERNAL_ERROR", "Database error", req_id);
        return;
    };
    defer upd.deinit();

    const row = upd.next() catch null orelse {
        common.errorResponse(r, .conflict, "WORKSPACE_NOT_FOUND", "Workspace not found or version conflict", req_id);
        return;
    };

    const new_version = row.get(i64, 0) catch 0;
    log.info("workspace {} pause={} workspace_id={s}", .{ parsed.value.pause, parsed.value.pause, workspace_id });

    common.writeJson(r, .ok, .{
        .workspace_id = workspace_id,
        .paused = parsed.value.pause,
        .version = new_version,
        .request_id = req_id,
    });
}

pub fn handleSyncSpecs(ctx: *common.Context, r: zap.Request, workspace_id: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const req_id = common.requestId(alloc);

    const principal = common.authenticate(alloc, r, ctx) catch |err| {
        common.writeAuthError(r, req_id, err);
        return;
    };

    const conn = ctx.pool.acquire() catch {
        common.errorResponse(r, .service_unavailable, "INTERNAL_ERROR", "Database unavailable", req_id);
        return;
    };
    defer ctx.pool.release(conn);

    if (!common.authorizeWorkspace(conn, principal, workspace_id)) {
        common.errorResponse(r, .forbidden, "FORBIDDEN", "Workspace access denied", req_id);
        return;
    }

    var ws = conn.query(
        "SELECT repo_url, default_branch FROM workspaces WHERE workspace_id = $1",
        .{workspace_id},
    ) catch {
        common.errorResponse(r, .internal_server_error, "INTERNAL_ERROR", "Database error", req_id);
        return;
    };
    defer ws.deinit();

    const ws_row = ws.next() catch null orelse {
        common.errorResponse(r, .not_found, "WORKSPACE_NOT_FOUND", "Workspace not found", req_id);
        return;
    };

    const repo_url = ws_row.get([]u8, 0) catch "";
    _ = repo_url;

    var count_result = conn.query(
        "SELECT COUNT(*) FROM specs WHERE workspace_id = $1 AND status = 'pending'",
        .{workspace_id},
    ) catch {
        common.errorResponse(r, .internal_server_error, "INTERNAL_ERROR", "Database error", req_id);
        return;
    };
    defer count_result.deinit();

    const total_pending: i64 = if (count_result.next() catch null) |crow|
        crow.get(i64, 0) catch 0
    else
        0;

    log.info("sync workspace_id={s} total_pending={d}", .{ workspace_id, total_pending });

    common.writeJson(r, .ok, .{
        .synced_count = @as(i64, 0),
        .total_pending = total_pending,
        .specs = &[_]u8{},
        .request_id = req_id,
    });
}
