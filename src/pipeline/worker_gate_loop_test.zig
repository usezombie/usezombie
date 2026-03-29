//! Unit tests for the gate loop module (M16_001).
//!
//! Covers: happy path, edge cases, error paths, scorecard formatting,
//! repair message building, timeout calculation, and output truncation.

const std = @import("std");
const worker_gate_loop = @import("worker_gate_loop.zig");
const topology = @import("topology.zig");

// ---------------------------------------------------------------------------
// T1 — Happy path
// ---------------------------------------------------------------------------

test "truncate keeps short strings intact" {
    const s = "hello";
    try std.testing.expectEqualStrings("hello", worker_gate_loop.truncateOutput(s, 100));
}

test "truncate takes tail of long strings" {
    const s = "abcdefghij";
    try std.testing.expectEqualStrings("fghij", worker_gate_loop.truncateOutput(s, 5));
}

test "buildRepairMessage formats gate failure" {
    const alloc = std.testing.allocator;
    const result = worker_gate_loop.GateToolResult{
        .gate_name = "run_lint",
        .exit_code = 1,
        .stdout = "src/main.zig:5: error",
        .stderr = "lint failed",
        .wall_ms = 100,
        .passed = false,
    };
    const msg = try worker_gate_loop.buildRepairMessage(alloc, result);
    defer alloc.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "run_lint") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "exit code 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "lint failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "Fix the issue") != null);
}

test "formatScorecard produces markdown table" {
    const alloc = std.testing.allocator;
    const results = [_]worker_gate_loop.GateToolResult{
        .{ .gate_name = "run_lint", .exit_code = 0, .stdout = "", .stderr = "", .wall_ms = 100, .passed = true },
        .{ .gate_name = "run_test", .exit_code = 0, .stdout = "", .stderr = "", .wall_ms = 200, .passed = true },
    };
    const card = try worker_gate_loop.formatScorecard(alloc, &results, 0, "test-run-id");
    defer alloc.free(card);
    try std.testing.expect(std.mem.indexOf(u8, card, "Gate Results") != null);
    try std.testing.expect(std.mem.indexOf(u8, card, "run_lint") != null);
    try std.testing.expect(std.mem.indexOf(u8, card, "PASS") != null);
    try std.testing.expect(std.mem.indexOf(u8, card, "300ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, card, "test-run-id") != null);
}

// ---------------------------------------------------------------------------
// T2 — Edge cases
// ---------------------------------------------------------------------------

test "truncate empty string returns empty" {
    try std.testing.expectEqualStrings("", worker_gate_loop.truncateOutput("", 100));
}

test "truncate with zero max returns empty" {
    try std.testing.expectEqualStrings("", worker_gate_loop.truncateOutput("hello", 0));
}

test "truncate exact boundary returns full string" {
    const s = "abcde";
    try std.testing.expectEqualStrings("abcde", worker_gate_loop.truncateOutput(s, 5));
}

test "effectiveTimeout picks minimum of gate and global" {
    const now_ms: i64 = std.time.milliTimestamp();
    const result = worker_gate_loop.effectiveTimeout(60_000, 300_000, now_ms + 600_000);
    try std.testing.expectEqual(@as(u64, 60_000), result);
}

test "effectiveTimeout respects deadline when closer" {
    const now_ms: i64 = std.time.milliTimestamp();
    const result = worker_gate_loop.effectiveTimeout(300_000, 300_000, now_ms + 5_000);
    try std.testing.expect(result <= 5_100);
}

test "effectiveTimeout returns zero when deadline passed" {
    const result = worker_gate_loop.effectiveTimeout(300_000, 300_000, 0);
    try std.testing.expectEqual(@as(u64, 0), result);
}

test "formatScorecard with empty results" {
    const alloc = std.testing.allocator;
    const empty = [_]worker_gate_loop.GateToolResult{};
    const card = try worker_gate_loop.formatScorecard(alloc, &empty, 0, "run-0");
    defer alloc.free(card);
    try std.testing.expect(std.mem.indexOf(u8, card, "Gate Results") != null);
    try std.testing.expect(std.mem.indexOf(u8, card, "0ms") != null);
}

test "formatScorecard with failed gate shows FAIL" {
    const alloc = std.testing.allocator;
    const results = [_]worker_gate_loop.GateToolResult{
        .{ .gate_name = "run_build", .exit_code = 1, .stdout = "", .stderr = "error", .wall_ms = 50, .passed = false },
    };
    const card = try worker_gate_loop.formatScorecard(alloc, &results, 2, "run-fail");
    defer alloc.free(card);
    try std.testing.expect(std.mem.indexOf(u8, card, "FAIL") != null);
    try std.testing.expect(std.mem.indexOf(u8, card, "Repair loops:** 2") != null);
}

// ---------------------------------------------------------------------------
// T3 — Negative / error paths
// ---------------------------------------------------------------------------

test "buildRepairMessage with empty stdout and stderr" {
    const alloc = std.testing.allocator;
    const result = worker_gate_loop.GateToolResult{
        .gate_name = "run_build",
        .exit_code = 127,
        .stdout = "",
        .stderr = "",
        .wall_ms = 0,
        .passed = false,
    };
    const msg = try worker_gate_loop.buildRepairMessage(alloc, result);
    defer alloc.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "exit code 127") != null);
}

// ---------------------------------------------------------------------------
// T10 — Constants policy
// ---------------------------------------------------------------------------

test "MAX_OUTPUT_BYTES is 4096" {
    try std.testing.expectEqual(@as(usize, 4096), worker_gate_loop.MAX_OUTPUT_BYTES);
}

// ---------------------------------------------------------------------------
// T11 — Memory safety
// ---------------------------------------------------------------------------

test "buildRepairMessage allocator leak check" {
    const alloc = std.testing.allocator;
    for (0..50) |_| {
        const result = worker_gate_loop.GateToolResult{
            .gate_name = "run_test",
            .exit_code = 1,
            .stdout = "x" ** 100,
            .stderr = "y" ** 100,
            .wall_ms = 10,
            .passed = false,
        };
        const msg = try worker_gate_loop.buildRepairMessage(alloc, result);
        alloc.free(msg);
    }
}

test "formatScorecard allocator leak check" {
    const alloc = std.testing.allocator;
    const results = [_]worker_gate_loop.GateToolResult{
        .{ .gate_name = "lint", .exit_code = 0, .stdout = "", .stderr = "", .wall_ms = 10, .passed = true },
        .{ .gate_name = "test", .exit_code = 0, .stdout = "", .stderr = "", .wall_ms = 20, .passed = true },
        .{ .gate_name = "build", .exit_code = 0, .stdout = "", .stderr = "", .wall_ms = 30, .passed = true },
    };
    for (0..50) |_| {
        const card = try worker_gate_loop.formatScorecard(alloc, &results, 0, "run-leak-check");
        alloc.free(card);
    }
}
