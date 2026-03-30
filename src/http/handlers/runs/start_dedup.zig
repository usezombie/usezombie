/// M16_002 §2.1: Dedup key computation for run submissions.
///
/// Dedup key = hex(sha256(spec_markdown || workspace_id || base_commit_sha_or_empty)).
/// This module is extracted from start.zig to keep that file under 500 lines.
const std = @import("std");

/// Compute the dedup key for a run submission.
/// Returns an owned 64-char hex string (sha256 digest). Caller must free.
pub fn computeDedupKey(
    alloc: std.mem.Allocator,
    spec_markdown: []const u8,
    workspace_id: []const u8,
    base_commit_sha: ?[]const u8,
) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(spec_markdown);
    hasher.update(workspace_id);
    if (base_commit_sha) |sha| hasher.update(sha);
    const digest = hasher.finalResult();
    return std.fmt.allocPrint(alloc, "{}", .{std.fmt.fmtSliceHexLower(&digest)});
}

// ── Unit tests (T7, T8) ──────────────────────────────────────────────────────

// T7: computeDedupKey is deterministic — same inputs produce same output.
test "T7: computeDedupKey produces same output for identical inputs" {
    const alloc = std.testing.allocator;
    const k1 = try computeDedupKey(alloc, "spec content", "ws-123", "abc123sha");
    defer alloc.free(k1);
    const k2 = try computeDedupKey(alloc, "spec content", "ws-123", "abc123sha");
    defer alloc.free(k2);
    try std.testing.expectEqualStrings(k1, k2);
    // Output must be 64 hex chars (sha256 = 32 bytes × 2).
    try std.testing.expectEqual(@as(usize, 64), k1.len);
}

// T7: computeDedupKey with null base_commit_sha is stable.
test "T7: computeDedupKey without base_commit_sha is deterministic" {
    const alloc = std.testing.allocator;
    const k1 = try computeDedupKey(alloc, "spec", "ws-1", null);
    defer alloc.free(k1);
    const k2 = try computeDedupKey(alloc, "spec", "ws-1", null);
    defer alloc.free(k2);
    try std.testing.expectEqualStrings(k1, k2);
}

// T8: computeDedupKey differs when any input changes.
test "T8: computeDedupKey differs when spec changes" {
    const alloc = std.testing.allocator;
    const k1 = try computeDedupKey(alloc, "spec A", "ws-1", "sha1");
    defer alloc.free(k1);
    const k2 = try computeDedupKey(alloc, "spec B", "ws-1", "sha1");
    defer alloc.free(k2);
    try std.testing.expect(!std.mem.eql(u8, k1, k2));
}

test "T8: computeDedupKey differs when workspace_id changes" {
    const alloc = std.testing.allocator;
    const k1 = try computeDedupKey(alloc, "spec", "ws-A", "sha1");
    defer alloc.free(k1);
    const k2 = try computeDedupKey(alloc, "spec", "ws-B", "sha1");
    defer alloc.free(k2);
    try std.testing.expect(!std.mem.eql(u8, k1, k2));
}

test "T8: computeDedupKey differs when base_commit_sha changes" {
    const alloc = std.testing.allocator;
    const k1 = try computeDedupKey(alloc, "spec", "ws-1", "sha-old");
    defer alloc.free(k1);
    const k2 = try computeDedupKey(alloc, "spec", "ws-1", "sha-new");
    defer alloc.free(k2);
    try std.testing.expect(!std.mem.eql(u8, k1, k2));
}

test "T8: computeDedupKey differs when sha is null vs non-null" {
    const alloc = std.testing.allocator;
    const k1 = try computeDedupKey(alloc, "spec", "ws-1", null);
    defer alloc.free(k1);
    const k2 = try computeDedupKey(alloc, "spec", "ws-1", "sha");
    defer alloc.free(k2);
    try std.testing.expect(!std.mem.eql(u8, k1, k2));
}

// Regression: verify output is 64 lowercase hex chars for any fixed input.
test "T7: computeDedupKey regression — output is 64 hex chars" {
    const alloc = std.testing.allocator;
    const k = try computeDedupKey(alloc, "spec content", "ws-123", "abc123sha");
    defer alloc.free(k);
    try std.testing.expectEqual(@as(usize, 64), k.len);
    for (k) |ch| {
        try std.testing.expect((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'));
    }
}
