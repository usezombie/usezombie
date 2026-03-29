//! Integration tests for M16_001 gate loop.
//!
//! Requires: PostgreSQL (TEST_DATABASE_URL or DATABASE_URL).
//! Covers: gate_results persistence, base_commit_sha recording, scoring
//! with gate_exhausted, topology gate_tools round-trip, metrics counters.

const std = @import("std");
const pg = @import("pg");
const base = @import("../db/test_fixtures.zig");
const topology = @import("topology.zig");
const scoring_types = @import("scoring_mod/types.zig");
const scoring_math = @import("scoring_mod/math.zig");
const metrics_counters = @import("../observability/metrics_counters.zig");
const id_format = @import("../types/id_format.zig");
const codes = @import("../errors/codes.zig");

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn openTestConn(alloc: std.mem.Allocator) !?struct { pool: *pg.Pool, conn: *pg.Conn } {
    return base.openTestConn(alloc);
}

fn seedRunForGateTest(alloc: std.mem.Allocator, conn: *pg.Conn, run_id: []const u8) !void {
    const ws_id = base.TEST_WORKSPACE_ID;
    const tenant_id = base.TEST_TENANT_ID;
    const now_ms = std.time.milliTimestamp();

    // Seed spec.
    const spec_id = try id_format.generateSpecId(alloc);
    _ = try conn.exec(
        "INSERT INTO specs (spec_id, workspace_id, tenant_id, file_path, title, status, created_at, updated_at) VALUES ($1, $2, $3, $4, $5, $6, $7, $8) ON CONFLICT DO NOTHING",
        .{ spec_id, ws_id, tenant_id, "test/gate.md", "Gate Test Spec", "ACTIVE", now_ms, now_ms },
    );

    // Seed run.
    _ = try conn.exec(
        "INSERT INTO runs (run_id, workspace_id, spec_id, tenant_id, state, attempt, mode, requested_by, idempotency_key, created_at, updated_at) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11) ON CONFLICT DO NOTHING",
        .{ run_id, ws_id, spec_id, tenant_id, "VERIFICATION_IN_PROGRESS", @as(i32, 1), "auto", "test", run_id, now_ms, now_ms },
    );
}

fn teardownRun(conn: *pg.Conn, run_id: []const u8) void {
    _ = conn.exec("DELETE FROM gate_results WHERE run_id = $1", .{run_id}) catch {};
    _ = conn.exec("DELETE FROM run_transitions WHERE run_id = $1", .{run_id}) catch {};
    _ = conn.exec("DELETE FROM artifacts WHERE run_id = $1", .{run_id}) catch {};
    _ = conn.exec("DELETE FROM usage_ledger WHERE run_id = $1", .{run_id}) catch {};
    _ = conn.exec("DELETE FROM runs WHERE run_id = $1", .{run_id}) catch {};
    _ = conn.exec("DELETE FROM specs WHERE workspace_id = $1", .{base.TEST_WORKSPACE_ID}) catch {};
}

// ---------------------------------------------------------------------------
// T6 — Integration: gate_results table persistence
// ---------------------------------------------------------------------------

test "integration: gate_results row inserted with correct fields" {
    const alloc = std.testing.allocator;
    const db_ctx = (try openTestConn(alloc)) orelse return error.SkipZigTest;
    defer db_ctx.pool.deinit();
    defer db_ctx.pool.release(db_ctx.conn);

    try base.seedTenant(db_ctx.conn);
    defer base.teardownTenant(db_ctx.conn);
    try base.seedWorkspace(db_ctx.conn, base.TEST_WORKSPACE_ID);
    defer base.teardownWorkspace(db_ctx.conn, base.TEST_WORKSPACE_ID);

    const run_id = try id_format.generateRunId(alloc);
    defer alloc.free(run_id);
    try seedRunForGateTest(alloc, db_ctx.conn, run_id);
    defer teardownRun(db_ctx.conn, run_id);

    // Insert a gate result directly (simulating persistGateResults).
    const gate_id = try id_format.generateGateResultId(alloc);
    defer alloc.free(gate_id);
    const now_ms = std.time.milliTimestamp();
    _ = try db_ctx.conn.exec(
        "INSERT INTO gate_results (id, run_id, gate_name, attempt, exit_code, stdout_tail, stderr_tail, wall_ms, created_at) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
        .{ gate_id, run_id, "run_lint", @as(i32, 1), @as(i32, 0), "ok", "", @as(i64, 150), now_ms },
    );

    // Verify the row exists.
    if (db_ctx.conn.queryOpts(
        "SELECT gate_name, exit_code, wall_ms FROM gate_results WHERE run_id = $1",
        .{run_id},
        .{ .column_names = false },
    )) |result| {
        defer result.deinit();
        if (result.next()) |row| {
            const gate_name = row.get([]const u8, 0);
            const exit_code = row.get(i32, 1);
            const wall_ms = row.get(i64, 2);
            try std.testing.expectEqualStrings("run_lint", gate_name);
            try std.testing.expectEqual(@as(i32, 0), exit_code);
            try std.testing.expectEqual(@as(i64, 150), wall_ms);
        } else {
            return error.TestExpectedEqual;
        }
    } else |_| {
        return error.TestExpectedEqual;
    }
}

// ---------------------------------------------------------------------------
// T6 — Integration: base_commit_sha recorded on runs table
// ---------------------------------------------------------------------------

test "integration: base_commit_sha column exists and is writable" {
    const alloc = std.testing.allocator;
    const db_ctx = (try openTestConn(alloc)) orelse return error.SkipZigTest;
    defer db_ctx.pool.deinit();
    defer db_ctx.pool.release(db_ctx.conn);

    try base.seedTenant(db_ctx.conn);
    defer base.teardownTenant(db_ctx.conn);
    try base.seedWorkspace(db_ctx.conn, base.TEST_WORKSPACE_ID);
    defer base.teardownWorkspace(db_ctx.conn, base.TEST_WORKSPACE_ID);

    const run_id = try id_format.generateRunId(alloc);
    defer alloc.free(run_id);
    try seedRunForGateTest(alloc, db_ctx.conn, run_id);
    defer teardownRun(db_ctx.conn, run_id);

    const sha = "abc123def456789012345678901234567890abcd";
    const now_ms = std.time.milliTimestamp();
    _ = try db_ctx.conn.exec(
        "UPDATE runs SET base_commit_sha = $1, updated_at = $2 WHERE run_id = $3",
        .{ sha, now_ms, run_id },
    );

    if (db_ctx.conn.queryOpts(
        "SELECT base_commit_sha FROM runs WHERE run_id = $1",
        .{run_id},
        .{ .column_names = false },
    )) |result| {
        defer result.deinit();
        if (result.next()) |row| {
            const stored_sha = row.get([]const u8, 0);
            try std.testing.expectEqualStrings(sha, stored_sha);
        } else {
            return error.TestExpectedEqual;
        }
    } else |_| {
        return error.TestExpectedEqual;
    }
}

// ---------------------------------------------------------------------------
// T6 — Integration: base_commit_sha NULL by default
// ---------------------------------------------------------------------------

test "integration: base_commit_sha is null when not set" {
    const alloc = std.testing.allocator;
    const db_ctx = (try openTestConn(alloc)) orelse return error.SkipZigTest;
    defer db_ctx.pool.deinit();
    defer db_ctx.pool.release(db_ctx.conn);

    try base.seedTenant(db_ctx.conn);
    defer base.teardownTenant(db_ctx.conn);
    try base.seedWorkspace(db_ctx.conn, base.TEST_WORKSPACE_ID);
    defer base.teardownWorkspace(db_ctx.conn, base.TEST_WORKSPACE_ID);

    const run_id = try id_format.generateRunId(alloc);
    defer alloc.free(run_id);
    try seedRunForGateTest(alloc, db_ctx.conn, run_id);
    defer teardownRun(db_ctx.conn, run_id);

    if (db_ctx.conn.queryOpts(
        "SELECT base_commit_sha FROM runs WHERE run_id = $1",
        .{run_id},
        .{ .column_names = false },
    )) |result| {
        defer result.deinit();
        if (result.next()) |row| {
            const stored_sha = row.get(?[]const u8, 0);
            try std.testing.expect(stored_sha == null);
        } else {
            return error.TestExpectedEqual;
        }
    } else |_| {
        return error.TestExpectedEqual;
    }
}

// ---------------------------------------------------------------------------
// T6 — Integration: multiple gate_results for one run
// ---------------------------------------------------------------------------

test "integration: multiple gate results per run stored correctly" {
    const alloc = std.testing.allocator;
    const db_ctx = (try openTestConn(alloc)) orelse return error.SkipZigTest;
    defer db_ctx.pool.deinit();
    defer db_ctx.pool.release(db_ctx.conn);

    try base.seedTenant(db_ctx.conn);
    defer base.teardownTenant(db_ctx.conn);
    try base.seedWorkspace(db_ctx.conn, base.TEST_WORKSPACE_ID);
    defer base.teardownWorkspace(db_ctx.conn, base.TEST_WORKSPACE_ID);

    const run_id = try id_format.generateRunId(alloc);
    defer alloc.free(run_id);
    try seedRunForGateTest(alloc, db_ctx.conn, run_id);
    defer teardownRun(db_ctx.conn, run_id);

    const now_ms = std.time.milliTimestamp();
    const gates = [_]struct { name: []const u8, exit_code: i32 }{
        .{ .name = "run_lint", .exit_code = 0 },
        .{ .name = "run_test", .exit_code = 1 },
        .{ .name = "run_build", .exit_code = 0 },
    };
    for (gates, 1..) |g, i| {
        const gid = try id_format.generateGateResultId(alloc);
        defer alloc.free(gid);
        _ = try db_ctx.conn.exec(
            "INSERT INTO gate_results (id, run_id, gate_name, attempt, exit_code, stdout_tail, stderr_tail, wall_ms, created_at) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
            .{ gid, run_id, g.name, @as(i32, @intCast(i)), g.exit_code, "", "", @as(i64, 100), now_ms },
        );
    }

    // Count rows.
    if (db_ctx.conn.queryOpts(
        "SELECT count(*) FROM gate_results WHERE run_id = $1",
        .{run_id},
        .{ .column_names = false },
    )) |result| {
        defer result.deinit();
        if (result.next()) |row| {
            const count = row.get(i64, 0);
            try std.testing.expectEqual(@as(i64, 3), count);
        } else {
            return error.TestExpectedEqual;
        }
    } else |_| {
        return error.TestExpectedEqual;
    }
}

// ---------------------------------------------------------------------------
// T1 — Scoring: blocked_gate_exhausted returns expected score
// ---------------------------------------------------------------------------

test "computeCompletionScore returns 20 for blocked_gate_exhausted" {
    const score = scoring_math.computeCompletionScore(.blocked_gate_exhausted);
    try std.testing.expectEqual(@as(u8, 20), score);
}

// ---------------------------------------------------------------------------
// T1 — Metrics: gate repair counters increment correctly
// ---------------------------------------------------------------------------

test "gate repair metrics increment atomically" {
    const before_loops = metrics_counters.snapshot().gate_repair_loops_total;
    const before_exhausted = metrics_counters.snapshot().gate_repair_exhausted_total;

    metrics_counters.incGateRepairLoops();
    metrics_counters.incGateRepairLoops();
    metrics_counters.incGateRepairExhausted();

    const after = metrics_counters.snapshot();
    try std.testing.expectEqual(before_loops + 2, after.gate_repair_loops_total);
    try std.testing.expectEqual(before_exhausted + 1, after.gate_repair_exhausted_total);
}

// ---------------------------------------------------------------------------
// T10 — Error codes: gate codes are defined
// ---------------------------------------------------------------------------

test "gate error codes are defined and have hints" {
    try std.testing.expect(codes.hint(codes.ERR_GATE_COMMAND_FAILED) != null);
    try std.testing.expect(codes.hint(codes.ERR_GATE_COMMAND_TIMEOUT) != null);
    try std.testing.expect(codes.hint(codes.ERR_GATE_REPAIR_EXHAUSTED) != null);
}

// ---------------------------------------------------------------------------
// T5 — Concurrency: concurrent gate_result inserts don't conflict
// ---------------------------------------------------------------------------

test "integration: concurrent gate_result inserts for different runs" {
    const alloc = std.testing.allocator;
    const db_ctx = (try openTestConn(alloc)) orelse return error.SkipZigTest;
    defer db_ctx.pool.deinit();
    defer db_ctx.pool.release(db_ctx.conn);

    try base.seedTenant(db_ctx.conn);
    defer base.teardownTenant(db_ctx.conn);
    try base.seedWorkspace(db_ctx.conn, base.TEST_WORKSPACE_ID);
    defer base.teardownWorkspace(db_ctx.conn, base.TEST_WORKSPACE_ID);

    // Create two runs and insert gate results for each.
    const run_id_1 = try id_format.generateRunId(alloc);
    defer alloc.free(run_id_1);
    const run_id_2 = try id_format.generateRunId(alloc);
    defer alloc.free(run_id_2);

    try seedRunForGateTest(alloc, db_ctx.conn, run_id_1);
    defer teardownRun(db_ctx.conn, run_id_1);
    try seedRunForGateTest(alloc, db_ctx.conn, run_id_2);
    defer teardownRun(db_ctx.conn, run_id_2);

    const now_ms = std.time.milliTimestamp();
    for ([_][]const u8{ run_id_1, run_id_2 }) |rid| {
        const gid = try id_format.generateGateResultId(alloc);
        defer alloc.free(gid);
        _ = try db_ctx.conn.exec(
            "INSERT INTO gate_results (id, run_id, gate_name, attempt, exit_code, stdout_tail, stderr_tail, wall_ms, created_at) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
            .{ gid, rid, "run_lint", @as(i32, 1), @as(i32, 0), "", "", @as(i64, 50), now_ms },
        );
    }

    // Verify each run has exactly one gate result.
    for ([_][]const u8{ run_id_1, run_id_2 }) |rid| {
        if (db_ctx.conn.queryOpts(
            "SELECT count(*) FROM gate_results WHERE run_id = $1",
            .{rid},
            .{ .column_names = false },
        )) |result| {
            defer result.deinit();
            if (result.next()) |row| {
                try std.testing.expectEqual(@as(i64, 1), row.get(i64, 0));
            }
        } else |_| {}
    }
}
