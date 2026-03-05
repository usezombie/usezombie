//! State machine — validates transitions and writes to run_transitions.
//! All writes are append-only. The current state is derived from the
//! latest transition for a given run_id.

const std = @import("std");
const pg = @import("pg");
const types = @import("../types.zig");
const events = @import("../events/bus.zig");
const log = std.log.scoped(.state);

pub const TransitionError = error{
    InvalidTransition,
    RunNotFound,
    RunAlreadyTerminal,
    IdempotencyConflict,
};

/// Allowed transitions (from → to). Encodes the state machine contract.
const ALLOWED = [_][2]types.RunState{
    .{ .SPEC_QUEUED, .RUN_PLANNED },
    .{ .RUN_PLANNED, .BLOCKED },
    .{ .RUN_PLANNED, .PATCH_IN_PROGRESS },
    .{ .PATCH_IN_PROGRESS, .BLOCKED },
    .{ .PATCH_IN_PROGRESS, .PATCH_READY },
    .{ .PATCH_READY, .BLOCKED },
    .{ .PATCH_READY, .VERIFICATION_IN_PROGRESS },
    .{ .VERIFICATION_IN_PROGRESS, .PR_PREPARED },
    .{ .VERIFICATION_IN_PROGRESS, .VERIFICATION_FAILED },
    .{ .VERIFICATION_IN_PROGRESS, .BLOCKED },
    .{ .VERIFICATION_FAILED, .PATCH_IN_PROGRESS },
    .{ .VERIFICATION_FAILED, .BLOCKED },
    .{ .PR_PREPARED, .PR_OPENED },
    .{ .PR_OPENED, .NOTIFIED },
    .{ .NOTIFIED, .DONE },
    .{ .BLOCKED, .NOTIFIED_BLOCKED },
};

pub fn isAllowed(from: types.RunState, to: types.RunState) bool {
    for (ALLOWED) |pair| {
        if (pair[0] == from and pair[1] == to) return true;
    }
    return false;
}

/// Fetch the current state and attempt for a run from Postgres.
pub fn getRunState(
    conn: *pg.Conn,
    run_id: []const u8,
) !struct { state: types.RunState, attempt: u32 } {
    var result = try conn.query(
        \\SELECT state, attempt FROM runs WHERE run_id = $1
    , .{run_id});
    defer result.deinit();

    const row = try result.next() orelse return TransitionError.RunNotFound;
    const state_str = try row.get([]u8, 0);
    const attempt = @as(u32, @intCast(try row.get(i32, 1)));
    const state = try types.RunState.fromStr(state_str);
    return .{ .state = state, .attempt = attempt };
}

/// Apply a state transition, validate it, and append to run_transitions.
/// Returns the new attempt number.
pub fn transition(
    conn: *pg.Conn,
    run_id: []const u8,
    to: types.RunState,
    actor: types.Actor,
    reason_code: types.ReasonCode,
    notes: ?[]const u8,
) !u32 {
    const current = try getRunState(conn, run_id);

    if (current.state.isTerminal()) {
        return TransitionError.RunAlreadyTerminal;
    }

    if (!isAllowed(current.state, to)) {
        log.err("invalid transition run_id={s} from={s} to={s}", .{
            run_id,
            current.state.label(),
            to.label(),
        });
        return TransitionError.InvalidTransition;
    }

    const now_ms = std.time.milliTimestamp();
    const attempt = current.attempt;

    // Append transition record
    {
        var r = try conn.query(
            \\INSERT INTO run_transitions
            \\  (run_id, attempt, state_from, state_to, actor, reason_code, notes, ts)
            \\VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
        , .{
            run_id,
            @as(i32, @intCast(attempt)),
            current.state.label(),
            to.label(),
            actor.label(),
            reason_code.label(),
            notes,
            now_ms,
        });
        r.deinit();
    }

    // CAS update run state: fail if another worker moved the state first.
    {
        var r = try conn.query(
            \\UPDATE runs
            \\SET state = $1, updated_at = $2
            \\WHERE run_id = $3 AND state = $4
            \\RETURNING attempt
        , .{ to.label(), now_ms, run_id, current.state.label() });
        defer r.deinit();

        _ = try r.next() orelse {
            log.err("cas transition failed run_id={s} expected={s} to={s}", .{
                run_id,
                current.state.label(),
                to.label(),
            });
            return TransitionError.InvalidTransition;
        };
    }

    var request_id: []const u8 = "-";
    {
        var rq = conn.query("SELECT request_id FROM runs WHERE run_id = $1", .{run_id}) catch null;
        if (rq) |*q| {
            defer q.deinit();
            if ((q.next() catch null)) |rrow| {
                if (rrow.get(?[]u8, 0) catch null) |rid| {
                    if (rid.len > 0) request_id = rid;
                }
            }
        }
    }

    log.info("transition run_id={s} request_id={s} {s}→{s} actor={s}", .{
        run_id,
        request_id,
        current.state.label(),
        to.label(),
        actor.label(),
    });
    var detail_buf: [160]u8 = undefined;
    const detail = std.fmt.bufPrint(
        &detail_buf,
        "request_id={s} from={s} to={s} actor={s} reason={s}",
        .{ request_id, current.state.label(), to.label(), actor.label(), reason_code.label() },
    ) catch "state_transition";
    events.emit("state_transition", run_id, detail);

    return attempt;
}

/// Increment attempt counter (for retry flows).
pub fn incrementAttempt(conn: *pg.Conn, run_id: []const u8) !u32 {
    const now_ms = std.time.milliTimestamp();
    var r = try conn.query(
        \\UPDATE runs SET attempt = attempt + 1, updated_at = $1
        \\WHERE run_id = $2
        \\RETURNING attempt
    , .{ now_ms, run_id });
    defer r.deinit();

    const row = try r.next() orelse return TransitionError.RunNotFound;
    return @as(u32, @intCast(try row.get(i32, 0)));
}

/// Write usage ledger entry after an agent call completes.
pub fn writeUsage(
    conn: *pg.Conn,
    run_id: []const u8,
    attempt: u32,
    actor: types.Actor,
    token_count: u64,
    agent_seconds: u64,
) !void {
    const now_ms = std.time.milliTimestamp();
    var r = try conn.query(
        \\INSERT INTO usage_ledger
        \\  (run_id, attempt, actor, token_count, agent_seconds, created_at)
        \\VALUES ($1, $2, $3, $4, $5, $6)
    , .{
        run_id,
        @as(i32, @intCast(attempt)),
        actor.label(),
        @as(i64, @intCast(token_count)),
        @as(i64, @intCast(agent_seconds)),
        now_ms,
    });
    r.deinit();
}

/// Register an artifact in the artifacts table.
pub fn registerArtifact(
    conn: *pg.Conn,
    run_id: []const u8,
    attempt: u32,
    artifact_name: []const u8,
    object_key: []const u8,
    checksum_sha256: []const u8,
    producer: types.Actor,
) !void {
    const now_ms = std.time.milliTimestamp();
    var r = try conn.query(
        \\INSERT INTO artifacts
        \\  (run_id, attempt, artifact_name, object_key, checksum_sha256, producer, created_at)
        \\VALUES ($1, $2, $3, $4, $5, $6, $7)
        \\ON CONFLICT (run_id, attempt, artifact_name) DO UPDATE
        \\  SET object_key = EXCLUDED.object_key,
        \\      checksum_sha256 = EXCLUDED.checksum_sha256,
        \\      created_at = EXCLUDED.created_at
    , .{
        run_id,
        @as(i32, @intCast(attempt)),
        artifact_name,
        object_key,
        checksum_sha256,
        producer.label(),
        now_ms,
    });
    r.deinit();
}

test "isAllowed covers all configured transitions" {
    const valid = [_][2]types.RunState{
        .{ .SPEC_QUEUED, .RUN_PLANNED },
        .{ .RUN_PLANNED, .BLOCKED },
        .{ .RUN_PLANNED, .PATCH_IN_PROGRESS },
        .{ .PATCH_IN_PROGRESS, .BLOCKED },
        .{ .PATCH_IN_PROGRESS, .PATCH_READY },
        .{ .PATCH_READY, .BLOCKED },
        .{ .PATCH_READY, .VERIFICATION_IN_PROGRESS },
        .{ .VERIFICATION_IN_PROGRESS, .PR_PREPARED },
        .{ .VERIFICATION_IN_PROGRESS, .VERIFICATION_FAILED },
        .{ .VERIFICATION_IN_PROGRESS, .BLOCKED },
        .{ .VERIFICATION_FAILED, .PATCH_IN_PROGRESS },
        .{ .VERIFICATION_FAILED, .BLOCKED },
        .{ .PR_PREPARED, .PR_OPENED },
        .{ .PR_OPENED, .NOTIFIED },
        .{ .NOTIFIED, .DONE },
        .{ .BLOCKED, .NOTIFIED_BLOCKED },
    };
    for (valid) |pair| {
        try std.testing.expect(isAllowed(pair[0], pair[1]));
    }
    // Invalid transitions must be rejected
    try std.testing.expect(!isAllowed(.DONE, .SPEC_QUEUED));
    try std.testing.expect(!isAllowed(.SPEC_QUEUED, .DONE));
}
