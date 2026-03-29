//! Unit tests for GateTool and Profile gate extensions (M16_001).

const std = @import("std");
const topology = @import("topology.zig");

// ---------------------------------------------------------------------------
// T1 — Happy path: profile with gate_tools parses correctly
// ---------------------------------------------------------------------------

test "profile with gate_tools parses three tools" {
    const alloc = std.testing.allocator;
    const json =
        \\{"agent_id":"gated-v1","stages":[
        \\  {"stage_id":"plan","role":"echo"},
        \\  {"stage_id":"implement","role":"scout"},
        \\  {"stage_id":"verify","role":"warden","gate":true,"on_pass":"done","on_fail":"retry"}
        \\],"gate_tools":[
        \\  {"name":"run_lint","command":"make lint"},
        \\  {"name":"run_test","command":"make test","timeout_ms":60000},
        \\  {"name":"run_build","command":"make build"}
        \\],"max_repair_loops":5}
    ;
    var profile = try topology.parseProfileJson(alloc, json);
    defer profile.deinit();

    try std.testing.expectEqual(@as(usize, 3), profile.gate_tools.len);
    try std.testing.expectEqualStrings("run_lint", profile.gate_tools[0].name);
    try std.testing.expectEqualStrings("make lint", profile.gate_tools[0].command);
    try std.testing.expectEqual(@as(u64, 300_000), profile.gate_tools[0].timeout_ms);
    try std.testing.expectEqualStrings("run_test", profile.gate_tools[1].name);
    try std.testing.expectEqual(@as(u64, 60_000), profile.gate_tools[1].timeout_ms);
    try std.testing.expectEqual(@as(u32, 5), profile.max_repair_loops);
}

// ---------------------------------------------------------------------------
// T2 — Edge cases
// ---------------------------------------------------------------------------

test "profile without gate_tools defaults to empty" {
    const alloc = std.testing.allocator;
    const json =
        \\{"agent_id":"no-gates","stages":[
        \\  {"stage_id":"plan","role":"echo"},
        \\  {"stage_id":"implement","role":"scout"},
        \\  {"stage_id":"verify","role":"warden","gate":true,"on_pass":"done","on_fail":"retry"}
        \\]}
    ;
    var profile = try topology.parseProfileJson(alloc, json);
    defer profile.deinit();

    try std.testing.expectEqual(@as(usize, 0), profile.gate_tools.len);
    try std.testing.expectEqual(@as(u32, 3), profile.max_repair_loops);
}

test "default profile has empty gate_tools and max_repair_loops 3" {
    var profile = try topology.defaultProfile(std.testing.allocator);
    defer profile.deinit();

    try std.testing.expectEqual(@as(usize, 0), profile.gate_tools.len);
    try std.testing.expectEqual(@as(u32, 3), profile.max_repair_loops);
}

test "profile with max_repair_loops 0 is accepted" {
    const alloc = std.testing.allocator;
    const json =
        \\{"agent_id":"zero-loops","stages":[
        \\  {"stage_id":"plan","role":"echo"},
        \\  {"stage_id":"implement","role":"scout"},
        \\  {"stage_id":"verify","role":"warden","gate":true}
        \\],"max_repair_loops":0}
    ;
    var profile = try topology.parseProfileJson(alloc, json);
    defer profile.deinit();

    try std.testing.expectEqual(@as(u32, 0), profile.max_repair_loops);
}

test "profile with single gate tool parses correctly" {
    const alloc = std.testing.allocator;
    const json =
        \\{"agent_id":"single-gate","stages":[
        \\  {"stage_id":"plan","role":"echo"},
        \\  {"stage_id":"implement","role":"scout"},
        \\  {"stage_id":"verify","role":"warden","gate":true}
        \\],"gate_tools":[{"name":"run_lint","command":"make lint"}]}
    ;
    var profile = try topology.parseProfileJson(alloc, json);
    defer profile.deinit();

    try std.testing.expectEqual(@as(usize, 1), profile.gate_tools.len);
}

// ---------------------------------------------------------------------------
// T7 — Regression: default profile contract preserved
// ---------------------------------------------------------------------------

test "default profile gate_tools does not break v1 contract" {
    var profile = try topology.defaultProfile(std.testing.allocator);
    defer profile.deinit();

    try std.testing.expectEqual(@as(usize, 3), profile.stages.len);
    try std.testing.expectEqualStrings("default-v1", profile.agent_id);
    try std.testing.expectEqual(@as(usize, 0), profile.gate_tools.len);
}

// ---------------------------------------------------------------------------
// T11 — Memory safety: profile with gate_tools deinit frees everything
// ---------------------------------------------------------------------------

test "profile with gate_tools deinit does not leak" {
    const alloc = std.testing.allocator;
    for (0..20) |_| {
        const json =
            \\{"agent_id":"leak-check","stages":[
            \\  {"stage_id":"plan","role":"echo"},
            \\  {"stage_id":"implement","role":"scout"},
            \\  {"stage_id":"verify","role":"warden","gate":true}
            \\],"gate_tools":[
            \\  {"name":"run_lint","command":"make lint"},
            \\  {"name":"run_build","command":"make build"}
            \\]}
        ;
        var profile = try topology.parseProfileJson(alloc, json);
        profile.deinit();
    }
}
