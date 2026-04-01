/// M17_002: Monthly budget enforcement helpers.
///
/// Extracted from start.zig to keep that file under 500 lines.
/// enforceWorkspaceMonthlyBudget is the only exported symbol; monthStartMs
/// is package-private and tested here.
const std = @import("std");
const pg = @import("pg");

// M17_001 §2: default per-run token ceiling used for workspace budget projection.
const DEFAULT_RUN_MAX_TOKENS: i64 = 100_000;

/// Returns the Unix epoch millisecond timestamp for midnight UTC on the first
/// day of the current calendar month. Passed as $2 to the monthly budget SUM
/// query so PostgreSQL receives a concrete bigint — enabling stable query-plan
/// caching and index use on idx_usage_ledger_workspace. M17_002 §2.1
fn monthStartMs() i64 {
    const now_ms = std.time.milliTimestamp();
    const now_s: u64 = @intCast(@divFloor(@max(now_ms, 0), 1000));
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = now_s };
    const epoch_day = epoch_secs.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    // day_index is 0-based: subtract to land on midnight of the 1st.
    const first_day: i64 = @as(i64, epoch_day.day) - @as(i64, month_day.day_index);
    return first_day * std.time.s_per_day * 1000;
}

/// Check workspace monthly token budget. Caller must hold an open transaction.
/// Returns true if the budget would be exceeded (run should be rejected).
/// Returns false if budget is unlimited (0) or within limit.
/// M17_001 §2.3-2.4: called within the same tx as the run INSERT to close
/// the TOCTOU window — FOR UPDATE lock held until INSERT commits.
pub fn enforceWorkspaceMonthlyBudget(conn: *pg.Conn, workspace_id: []const u8) !bool {
    var lock_q = try conn.query(
        \\SELECT monthly_token_budget FROM workspaces WHERE workspace_id = $1 FOR UPDATE
    , .{workspace_id});
    defer lock_q.deinit();
    const lock_row = (try lock_q.next()) orelse return false;
    const budget: i64 = lock_row.get(i64, 0) catch 0;
    try lock_q.drain();
    if (budget <= 0) return false; // 0 = unlimited

    const month_start: i64 = monthStartMs();
    var usage_q = try conn.query(
        \\SELECT COALESCE(SUM(ul.token_count), 0)
        \\FROM billing.usage_ledger ul
        \\WHERE ul.workspace_id = $1
        \\  AND ul.created_at >= $2
    , .{ workspace_id, month_start });
    defer usage_q.deinit();
    const usage_row = (try usage_q.next()) orelse return false;
    const used: i64 = usage_row.get(i64, 0) catch 0;
    try usage_q.drain();

    return used + DEFAULT_RUN_MAX_TOKENS > budget;
}

// M17_002 §2.3: epoch boundary unit test — no DB required.
test "monthStartMs returns midnight UTC on first day of current month" {
    const ms = monthStartMs();
    // Must be post-epoch.
    try std.testing.expect(ms >= 0);
    // Exactly midnight: divisible by milliseconds-per-day.
    try std.testing.expectEqual(@as(i64, 0), @mod(ms, std.time.s_per_day * 1000));
    // Round-trip: day_index must be 0 (first of month).
    const secs: u64 = @intCast(@divFloor(ms, 1000));
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = secs };
    const epoch_day = epoch_secs.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    try std.testing.expectEqual(@as(u5, 0), month_day.day_index);
}
