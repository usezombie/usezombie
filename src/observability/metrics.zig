//! In-process metrics registry exposed in Prometheus text format.

const std = @import("std");

const Snapshot = struct {
    runs_created_total: u64,
    runs_completed_total: u64,
    runs_blocked_total: u64,
    run_retries_total: u64,
    worker_errors_total: u64,
    agent_echo_calls_total: u64,
    agent_scout_calls_total: u64,
    agent_warden_calls_total: u64,
    agent_tokens_total: u64,
    backoff_wait_ms_total: u64,
};

var g_runs_created_total = std.atomic.Value(u64).init(0);
var g_runs_completed_total = std.atomic.Value(u64).init(0);
var g_runs_blocked_total = std.atomic.Value(u64).init(0);
var g_run_retries_total = std.atomic.Value(u64).init(0);
var g_worker_errors_total = std.atomic.Value(u64).init(0);
var g_agent_echo_calls_total = std.atomic.Value(u64).init(0);
var g_agent_scout_calls_total = std.atomic.Value(u64).init(0);
var g_agent_warden_calls_total = std.atomic.Value(u64).init(0);
var g_agent_tokens_total = std.atomic.Value(u64).init(0);
var g_backoff_wait_ms_total = std.atomic.Value(u64).init(0);

pub fn incRunsCreated() void {
    _ = g_runs_created_total.fetchAdd(1, .monotonic);
}

pub fn incRunsCompleted() void {
    _ = g_runs_completed_total.fetchAdd(1, .monotonic);
}

pub fn incRunsBlocked() void {
    _ = g_runs_blocked_total.fetchAdd(1, .monotonic);
}

pub fn incRunRetries() void {
    _ = g_run_retries_total.fetchAdd(1, .monotonic);
}

pub fn incWorkerErrors() void {
    _ = g_worker_errors_total.fetchAdd(1, .monotonic);
}

pub fn incAgentEchoCalls() void {
    _ = g_agent_echo_calls_total.fetchAdd(1, .monotonic);
}

pub fn incAgentScoutCalls() void {
    _ = g_agent_scout_calls_total.fetchAdd(1, .monotonic);
}

pub fn incAgentWardenCalls() void {
    _ = g_agent_warden_calls_total.fetchAdd(1, .monotonic);
}

pub fn addAgentTokens(tokens: u64) void {
    _ = g_agent_tokens_total.fetchAdd(tokens, .monotonic);
}

pub fn addBackoffWaitMs(ms: u64) void {
    _ = g_backoff_wait_ms_total.fetchAdd(ms, .monotonic);
}

fn snapshot() Snapshot {
    return .{
        .runs_created_total = g_runs_created_total.load(.acquire),
        .runs_completed_total = g_runs_completed_total.load(.acquire),
        .runs_blocked_total = g_runs_blocked_total.load(.acquire),
        .run_retries_total = g_run_retries_total.load(.acquire),
        .worker_errors_total = g_worker_errors_total.load(.acquire),
        .agent_echo_calls_total = g_agent_echo_calls_total.load(.acquire),
        .agent_scout_calls_total = g_agent_scout_calls_total.load(.acquire),
        .agent_warden_calls_total = g_agent_warden_calls_total.load(.acquire),
        .agent_tokens_total = g_agent_tokens_total.load(.acquire),
        .backoff_wait_ms_total = g_backoff_wait_ms_total.load(.acquire),
    };
}

pub fn renderPrometheus(
    alloc: std.mem.Allocator,
    worker_running: bool,
    queue_depth: ?i64,
    oldest_queued_age_ms: ?i64,
) ![]u8 {
    const s = snapshot();
    const worker_running_gauge: u8 = if (worker_running) 1 else 0;
    const queue_depth_gauge: i64 = queue_depth orelse 0;
    const oldest_age_gauge: i64 = oldest_queued_age_ms orelse 0;

    return std.fmt.allocPrint(alloc,
        \\# HELP zombie_runs_created_total Total runs accepted by API.
        \\# TYPE zombie_runs_created_total counter
        \\zombie_runs_created_total {d}
        \\# HELP zombie_runs_completed_total Total runs completed successfully.
        \\# TYPE zombie_runs_completed_total counter
        \\zombie_runs_completed_total {d}
        \\# HELP zombie_runs_blocked_total Total runs that ended blocked.
        \\# TYPE zombie_runs_blocked_total counter
        \\zombie_runs_blocked_total {d}
        \\# HELP zombie_run_retries_total Total retry attempts across runs.
        \\# TYPE zombie_run_retries_total counter
        \\zombie_run_retries_total {d}
        \\# HELP zombie_worker_errors_total Total worker loop errors.
        \\# TYPE zombie_worker_errors_total counter
        \\zombie_worker_errors_total {d}
        \\# HELP zombie_agent_echo_calls_total Total Echo agent invocations.
        \\# TYPE zombie_agent_echo_calls_total counter
        \\zombie_agent_echo_calls_total {d}
        \\# HELP zombie_agent_scout_calls_total Total Scout agent invocations.
        \\# TYPE zombie_agent_scout_calls_total counter
        \\zombie_agent_scout_calls_total {d}
        \\# HELP zombie_agent_warden_calls_total Total Warden agent invocations.
        \\# TYPE zombie_agent_warden_calls_total counter
        \\zombie_agent_warden_calls_total {d}
        \\# HELP zombie_agent_tokens_total Total tokens consumed by agent calls.
        \\# TYPE zombie_agent_tokens_total counter
        \\zombie_agent_tokens_total {d}
        \\# HELP zombie_backoff_wait_ms_total Total backoff wait time in milliseconds.
        \\# TYPE zombie_backoff_wait_ms_total counter
        \\zombie_backoff_wait_ms_total {d}
        \\# HELP zombie_worker_running Worker liveness gauge (1 running, 0 stopped).
        \\# TYPE zombie_worker_running gauge
        \\zombie_worker_running {d}
        \\# HELP zombie_queue_depth Current queued runs in SPEC_QUEUED.
        \\# TYPE zombie_queue_depth gauge
        \\zombie_queue_depth {d}
        \\# HELP zombie_oldest_queued_age_ms Oldest queued run age in milliseconds.
        \\# TYPE zombie_oldest_queued_age_ms gauge
        \\zombie_oldest_queued_age_ms {d}
        \\
    , .{
        s.runs_created_total,
        s.runs_completed_total,
        s.runs_blocked_total,
        s.run_retries_total,
        s.worker_errors_total,
        s.agent_echo_calls_total,
        s.agent_scout_calls_total,
        s.agent_warden_calls_total,
        s.agent_tokens_total,
        s.backoff_wait_ms_total,
        worker_running_gauge,
        queue_depth_gauge,
        oldest_age_gauge,
    });
}

test "prometheus render includes key metrics" {
    const alloc = std.testing.allocator;
    const body = try renderPrometheus(alloc, true, 3, 1200);
    defer alloc.free(body);

    try std.testing.expect(std.mem.containsAtLeast(u8, body, 1, "zombie_runs_created_total"));
    try std.testing.expect(std.mem.containsAtLeast(u8, body, 1, "zombie_worker_running 1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, body, 1, "zombie_queue_depth 3"));
}
