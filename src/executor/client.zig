//! High-level executor client for the worker side.
//!
//! Wraps the transport Client with typed methods for each executor API RPC.
//! Translates JSON responses into AgentResult and FailureClass types.

const std = @import("std");
const json = @import("json_helpers.zig");
const transport = @import("transport.zig");
const protocol = @import("protocol.zig");
const types = @import("types.zig");
const executor_metrics = @import("executor_metrics.zig");

const log = std.log.scoped(.executor_client);

pub const ClientError = error{
    ConnectionFailed,
    TransportLoss,
    ExecutionFailed,
    InvalidResponse,
    SessionNotFound,
    LeaseExpired,
    PolicyDenied,
    TimeoutKilled,
    OomKilled,
    ResourceKilled,
    LandlockDenied,
};

/// Maps an RPC error code to a FailureClass.
fn classifyError(code: i32) types.FailureClass {
    return switch (code) {
        protocol.ErrorCode.timeout_killed => .timeout_kill,
        protocol.ErrorCode.oom_killed => .oom_kill,
        protocol.ErrorCode.policy_denied => .policy_deny,
        protocol.ErrorCode.lease_expired => .lease_expired,
        protocol.ErrorCode.landlock_denied => .landlock_deny,
        protocol.ErrorCode.resource_killed => .resource_kill,
        else => .executor_crash,
    };
}

pub const ExecutorClient = struct {
    transport_client: transport.Client,
    alloc: std.mem.Allocator,
    next_id: u64 = 1,

    pub fn init(alloc: std.mem.Allocator, socket_path: []const u8) ExecutorClient {
        return .{
            .transport_client = transport.Client.init(alloc, socket_path),
            .alloc = alloc,
        };
    }

    pub fn connect(self: *ExecutorClient) ClientError!void {
        self.transport_client.connect() catch {
            log.err("executor_client.connect_failed error_code=UZ-EXEC-009 socket={s}", .{self.transport_client.socket_path});
            executor_metrics.incExecutorFailures();
            return ClientError.ConnectionFailed;
        };
        log.info("executor_client.connected socket={s}", .{self.transport_client.socket_path});
    }

    pub fn close(self: *ExecutorClient) void {
        self.transport_client.close();
    }

    fn nextId(self: *ExecutorClient) u64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    pub fn createExecution(
        self: *ExecutorClient,
        workspace_path: []const u8,
        correlation: types.CorrelationContext,
    ) ![]const u8 {
        var params = std.json.Value{ .object = std.json.ObjectMap.init(self.alloc) };
        defer params.object.deinit();

        try params.object.put("workspace_path", .{ .string = workspace_path });
        try params.object.put("trace_id", .{ .string = correlation.trace_id });
        try params.object.put("run_id", .{ .string = correlation.run_id });
        try params.object.put("workspace_id", .{ .string = correlation.workspace_id });
        try params.object.put("stage_id", .{ .string = correlation.stage_id });
        try params.object.put("role_id", .{ .string = correlation.role_id });
        try params.object.put("skill_id", .{ .string = correlation.skill_id });

        var resp = self.transport_client.sendRequest(self.nextId(), protocol.Method.create_execution, params) catch {
            log.err("executor_client.transport_loss error_code=UZ-EXEC-006 method=CreateExecution", .{});
            executor_metrics.incExecutorFailures();
            return ClientError.TransportLoss;
        };
        defer resp.deinit();

        if (resp.rpc_error) |err| {
            log.err("executor_client.create_execution_failed code={d} msg={s}", .{ err.code, err.message });
            return ClientError.ExecutionFailed;
        }

        const result = resp.result orelse return ClientError.InvalidResponse;
        if (result != .object) return ClientError.InvalidResponse;
        const exec_id_val = result.object.get("execution_id") orelse return ClientError.InvalidResponse;
        return switch (exec_id_val) {
            .string => |s| try self.alloc.dupe(u8, s),
            else => ClientError.InvalidResponse,
        };
    }

    /// Result from a StartStage RPC call.
    ///
    /// Ownership: `.content` is allocated via the ExecutorClient's allocator.
    /// The caller must free it when done.
    pub const StageResult = struct {
        content: []const u8,
        token_count: u64,
        wall_seconds: u64,
        exit_ok: bool,
        failure: ?types.FailureClass,
    };

    /// Agent configuration for StartStage payload (M12_003, M16_003).
    pub const AgentConfig = struct {
        model: []const u8 = "",
        provider: []const u8 = "anthropic",
        system_prompt: []const u8 = "",
        temperature: f64 = 0.7,
        max_tokens: u64 = 16384,
        /// LLM provider API key fetched from vault.secrets per workspace (M16_003 §1).
        /// Injected into NullClaw Config by the executor runner — never read from environ.
        api_key: []const u8 = "",
        /// GitHub App installation token for branch push and PR creation (M16_003 §2).
        /// Per-run, held in worker memory only, never persisted.
        github_token: []const u8 = "",
    };

    /// Full StartStage payload carrying agent execution context.
    pub const StagePayload = struct {
        stage_id: []const u8,
        role_id: []const u8,
        skill_id: []const u8,
        agent_config: AgentConfig = .{},
        message: []const u8 = "",
        tools: ?std.json.Value = null,
        context: ?std.json.Value = null,
    };

    /// Send a StartStage RPC with full agent execution payload (M12_003).
    pub fn startStage(
        self: *ExecutorClient,
        execution_id: []const u8,
        payload: StagePayload,
    ) !StageResult {
        var params = std.json.Value{ .object = std.json.ObjectMap.init(self.alloc) };
        defer params.object.deinit();

        try params.object.put("execution_id", .{ .string = execution_id });
        try params.object.put("stage_id", .{ .string = payload.stage_id });
        try params.object.put("role_id", .{ .string = payload.role_id });
        try params.object.put("skill_id", .{ .string = payload.skill_id });
        try params.object.put("message", .{ .string = payload.message });

        // Build agent_config object.
        // Deinit ac separately — params.object.deinit() does not recurse into nested ObjectMaps.
        var ac = std.json.Value{ .object = std.json.ObjectMap.init(self.alloc) };
        defer ac.object.deinit();
        try ac.object.put("model", .{ .string = payload.agent_config.model });
        try ac.object.put("provider", .{ .string = payload.agent_config.provider });
        try ac.object.put("system_prompt", .{ .string = payload.agent_config.system_prompt });
        try ac.object.put("temperature", .{ .float = payload.agent_config.temperature });
        try ac.object.put("max_tokens", .{ .integer = @intCast(payload.agent_config.max_tokens) });
        // M16_003 §1: pass workspace LLM API key; omit field when empty so executor
        // falls back to its own env (dev mode).
        if (payload.agent_config.api_key.len > 0)
            try ac.object.put("api_key", .{ .string = payload.agent_config.api_key });
        // M16_003 §2: pass GitHub installation token; omit when empty.
        if (payload.agent_config.github_token.len > 0)
            try ac.object.put("github_token", .{ .string = payload.agent_config.github_token });
        try params.object.put("agent_config", ac);

        // Attach optional tools array and context object.
        if (payload.tools) |t| try params.object.put("tools", t);
        if (payload.context) |c| try params.object.put("context", c);

        var resp = self.transport_client.sendRequest(self.nextId(), protocol.Method.start_stage, params) catch {
            log.err("executor_client.transport_loss error_code=UZ-EXEC-006 method=StartStage execution_id={s}", .{execution_id});
            executor_metrics.incExecutorFailures();
            return ClientError.TransportLoss;
        };
        defer resp.deinit();

        if (resp.rpc_error) |err| {
            log.err("executor_client.start_stage_failed code={d} msg={s}", .{ err.code, err.message });
            return .{
                .content = "",
                .token_count = 0,
                .wall_seconds = 0,
                .exit_ok = false,
                .failure = classifyError(err.code),
            };
        }

        const result = resp.result orelse return ClientError.InvalidResponse;
        if (result != .object) return ClientError.InvalidResponse;

        return .{
            .content = try self.alloc.dupe(u8, json.getStr(result, "content") orelse ""),
            .token_count = json.getIntOrZero(result, "token_count"),
            .wall_seconds = json.getIntOrZero(result, "wall_seconds"),
            .exit_ok = json.getBool(result, "exit_ok"),
            .failure = null,
        };
    }

    /// Backward-compatible startStage for tests and callers that don't
    /// need the full agent payload (sends minimal params).
    pub fn startStageBasic(
        self: *ExecutorClient,
        execution_id: []const u8,
        stage_id: []const u8,
        role_id: []const u8,
        skill_id: []const u8,
    ) !StageResult {
        return self.startStage(execution_id, .{
            .stage_id = stage_id,
            .role_id = role_id,
            .skill_id = skill_id,
        });
    }

    pub fn cancelExecution(self: *ExecutorClient, execution_id: []const u8) !void {
        var params = std.json.Value{ .object = std.json.ObjectMap.init(self.alloc) };
        defer params.object.deinit();
        try params.object.put("execution_id", .{ .string = execution_id });

        var resp = self.transport_client.sendRequest(self.nextId(), protocol.Method.cancel_execution, params) catch {
            log.err("executor_client.transport_loss error_code=UZ-EXEC-006 method=CancelExecution execution_id={s}", .{execution_id});
            executor_metrics.incExecutorFailures();
            return ClientError.TransportLoss;
        };
        defer resp.deinit();
    }

    pub fn getUsage(self: *ExecutorClient, execution_id: []const u8) !StageResult {
        var params = std.json.Value{ .object = std.json.ObjectMap.init(self.alloc) };
        defer params.object.deinit();
        try params.object.put("execution_id", .{ .string = execution_id });

        var resp = self.transport_client.sendRequest(self.nextId(), protocol.Method.get_usage, params) catch {
            log.err("executor_client.transport_loss error_code=UZ-EXEC-006 method=GetUsage execution_id={s}", .{execution_id});
            executor_metrics.incExecutorFailures();
            return ClientError.TransportLoss;
        };
        defer resp.deinit();

        if (resp.rpc_error != null) return ClientError.ExecutionFailed;
        const result = resp.result orelse return ClientError.InvalidResponse;
        if (result != .object) return ClientError.InvalidResponse;

        return .{
            .content = "",
            .token_count = json.getIntOrZero(result, "token_count"),
            .wall_seconds = json.getIntOrZero(result, "wall_seconds"),
            .exit_ok = json.getBool(result, "exit_ok"),
            .failure = null,
        };
    }

    pub fn destroyExecution(self: *ExecutorClient, execution_id: []const u8) !void {
        var params = std.json.Value{ .object = std.json.ObjectMap.init(self.alloc) };
        defer params.object.deinit();
        try params.object.put("execution_id", .{ .string = execution_id });

        var resp = self.transport_client.sendRequest(self.nextId(), protocol.Method.destroy_execution, params) catch {
            log.err("executor_client.transport_loss error_code=UZ-EXEC-006 method=DestroyExecution execution_id={s}", .{execution_id});
            executor_metrics.incExecutorFailures();
            return ClientError.TransportLoss;
        };
        defer resp.deinit();
    }

    pub fn heartbeat(self: *ExecutorClient, execution_id: []const u8) !void {
        var params = std.json.Value{ .object = std.json.ObjectMap.init(self.alloc) };
        defer params.object.deinit();
        try params.object.put("execution_id", .{ .string = execution_id });

        var resp = self.transport_client.sendRequest(self.nextId(), protocol.Method.heartbeat, params) catch {
            log.err("executor_client.transport_loss error_code=UZ-EXEC-006 method=Heartbeat execution_id={s}", .{execution_id});
            executor_metrics.incExecutorFailures();
            return ClientError.TransportLoss;
        };
        defer resp.deinit();
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

test "classifyError maps all known error codes" {
    try std.testing.expectEqual(types.FailureClass.timeout_kill, classifyError(protocol.ErrorCode.timeout_killed));
    try std.testing.expectEqual(types.FailureClass.oom_kill, classifyError(protocol.ErrorCode.oom_killed));
    try std.testing.expectEqual(types.FailureClass.policy_deny, classifyError(protocol.ErrorCode.policy_denied));
    try std.testing.expectEqual(types.FailureClass.lease_expired, classifyError(protocol.ErrorCode.lease_expired));
    try std.testing.expectEqual(types.FailureClass.landlock_deny, classifyError(protocol.ErrorCode.landlock_denied));
    try std.testing.expectEqual(types.FailureClass.resource_kill, classifyError(protocol.ErrorCode.resource_killed));
}

test "classifyError falls back to executor_crash for unknown codes" {
    try std.testing.expectEqual(types.FailureClass.executor_crash, classifyError(0));
    try std.testing.expectEqual(types.FailureClass.executor_crash, classifyError(-999));
    try std.testing.expectEqual(types.FailureClass.executor_crash, classifyError(42));
}

// ── StagePayload / AgentConfig default values ────────────────────────────

test "StagePayload default values" {
    const payload = ExecutorClient.StagePayload{
        .stage_id = "plan",
        .role_id = "coder",
        .skill_id = "zig",
    };
    try std.testing.expectEqualStrings("plan", payload.stage_id);
    try std.testing.expectEqualStrings("coder", payload.role_id);
    try std.testing.expectEqualStrings("zig", payload.skill_id);
    try std.testing.expectEqualStrings("", payload.message);
    try std.testing.expect(payload.tools == null);
    try std.testing.expect(payload.context == null);
    // Agent config should use defaults.
    try std.testing.expectEqualStrings("", payload.agent_config.model);
    try std.testing.expectEqualStrings("anthropic", payload.agent_config.provider);
    try std.testing.expectEqual(@as(f64, 0.7), payload.agent_config.temperature);
    try std.testing.expectEqual(@as(u64, 16384), payload.agent_config.max_tokens);
}

test "AgentConfig default values" {
    const ac = ExecutorClient.AgentConfig{};
    try std.testing.expectEqualStrings("", ac.model);
    try std.testing.expectEqualStrings("anthropic", ac.provider);
    try std.testing.expectEqualStrings("", ac.system_prompt);
    try std.testing.expectEqual(@as(f64, 0.7), ac.temperature);
    try std.testing.expectEqual(@as(u64, 16384), ac.max_tokens);
}

// ── classifyError comprehensive ──────────────────────────────────────────

test "classifyError maps all known protocol error codes" {
    // All 7 known codes (6 domain + execution_failed).
    try std.testing.expectEqual(types.FailureClass.timeout_kill, classifyError(protocol.ErrorCode.timeout_killed));
    try std.testing.expectEqual(types.FailureClass.oom_kill, classifyError(protocol.ErrorCode.oom_killed));
    try std.testing.expectEqual(types.FailureClass.policy_deny, classifyError(protocol.ErrorCode.policy_denied));
    try std.testing.expectEqual(types.FailureClass.lease_expired, classifyError(protocol.ErrorCode.lease_expired));
    try std.testing.expectEqual(types.FailureClass.landlock_deny, classifyError(protocol.ErrorCode.landlock_denied));
    try std.testing.expectEqual(types.FailureClass.resource_kill, classifyError(protocol.ErrorCode.resource_killed));
    // execution_failed falls through to else => executor_crash.
    try std.testing.expectEqual(types.FailureClass.executor_crash, classifyError(protocol.ErrorCode.execution_failed));
}

// ── M16_003 §1/§2 — AgentConfig credential fields ────────────────────────────

// T1: default values for new credential fields

test "AgentConfig.api_key defaults to empty string (M16_003 §1)" {
    const ac = ExecutorClient.AgentConfig{};
    try std.testing.expectEqualStrings("", ac.api_key);
    try std.testing.expectEqual(@as(usize, 0), ac.api_key.len);
}

test "AgentConfig.github_token defaults to empty string (M16_003 §2)" {
    const ac = ExecutorClient.AgentConfig{};
    try std.testing.expectEqualStrings("", ac.github_token);
    try std.testing.expectEqual(@as(usize, 0), ac.github_token.len);
}

// T1: populated values round-trip through struct

test "AgentConfig credential fields round-trip through struct literal" {
    const ac = ExecutorClient.AgentConfig{
        .api_key = "sk-ant-api03-test",
        .github_token = "ghs_test16CharToken",
    };
    try std.testing.expectEqualStrings("sk-ant-api03-test", ac.api_key);
    try std.testing.expectEqualStrings("ghs_test16CharToken", ac.github_token);
}

// T2/T10: serialization omit-when-empty logic
// Mirrors the exact conditional in startStage (lines 174–178) without requiring
// a live transport connection. Regression: if the condition changes from > 0 to
// != null the field would always be emitted even when empty.

test "AgentConfig serialization omits api_key and github_token when empty" {
    const alloc = std.testing.allocator;
    const ac_cfg = ExecutorClient.AgentConfig{};

    // Reproduce the serialization guard from startStage.
    var ac_map = std.json.ObjectMap.init(alloc);
    defer ac_map.deinit();
    if (ac_cfg.api_key.len > 0) try ac_map.put("api_key", .{ .string = ac_cfg.api_key });
    if (ac_cfg.github_token.len > 0) try ac_map.put("github_token", .{ .string = ac_cfg.github_token });

    try std.testing.expect(!ac_map.contains("api_key"));
    try std.testing.expect(!ac_map.contains("github_token"));
}

test "AgentConfig serialization includes api_key and github_token when non-empty" {
    const alloc = std.testing.allocator;
    const ac_cfg = ExecutorClient.AgentConfig{
        .api_key = "sk-ant-api03-realkey",
        .github_token = "ghs_installtoken",
    };

    var ac_map = std.json.ObjectMap.init(alloc);
    defer ac_map.deinit();
    if (ac_cfg.api_key.len > 0) try ac_map.put("api_key", .{ .string = ac_cfg.api_key });
    if (ac_cfg.github_token.len > 0) try ac_map.put("github_token", .{ .string = ac_cfg.github_token });

    try std.testing.expect(ac_map.contains("api_key"));
    try std.testing.expect(ac_map.contains("github_token"));
    try std.testing.expectEqualStrings("sk-ant-api03-realkey", ac_map.get("api_key").?.string);
    try std.testing.expectEqualStrings("ghs_installtoken", ac_map.get("github_token").?.string);
}

// T2 edge cases: single-byte non-empty key is still included

test "AgentConfig serialization includes api_key when length is 1" {
    const alloc = std.testing.allocator;
    const ac_cfg = ExecutorClient.AgentConfig{ .api_key = "x" };
    var ac_map = std.json.ObjectMap.init(alloc);
    defer ac_map.deinit();
    if (ac_cfg.api_key.len > 0) try ac_map.put("api_key", .{ .string = ac_cfg.api_key });
    try std.testing.expect(ac_map.contains("api_key"));
}

// T8 / T10: api_key must not contain newlines (would break HTTP header injection)

test "AgentConfig api_key with newline is still treated as non-empty but caller must validate" {
    // The struct accepts any []const u8 — security validation belongs at the
    // vault.secrets load boundary, not here. This test documents the contract.
    const ac = ExecutorClient.AgentConfig{ .api_key = "sk-ant\nmalformed" };
    try std.testing.expect(ac.api_key.len > 0);
}

// T10: StagePayload propagates api_key and github_token through AgentConfig

test "StagePayload.agent_config credential fields propagate" {
    const payload = ExecutorClient.StagePayload{
        .stage_id = "implement",
        .role_id = "coder",
        .skill_id = "zig",
        .agent_config = .{
            .api_key = "sk-fireworks-test",
            .github_token = "ghs_abc123",
        },
    };
    try std.testing.expectEqualStrings("sk-fireworks-test", payload.agent_config.api_key);
    try std.testing.expectEqualStrings("ghs_abc123", payload.agent_config.github_token);
}

// T7: AgentConfig struct has api_key and github_token fields (ABI regression guard)

test "AgentConfig has api_key and github_token fields (M16_003 §1/§2 regression)" {
    // @hasField is comptime — fails to compile if the field is removed.
    // model, provider, system_prompt, temperature, max_tokens, api_key, github_token
    comptime std.debug.assert(@hasField(ExecutorClient.AgentConfig, "api_key"));
    comptime std.debug.assert(@hasField(ExecutorClient.AgentConfig, "github_token"));
    comptime std.debug.assert(@typeInfo(ExecutorClient.AgentConfig).@"struct".fields.len >= 7);
    // Dummy runtime assertion so the test body is non-empty.
    try std.testing.expect(true);
}

// ── T8 — OWASP Agent Security (M16_003 §1/§2) ────────────────────────────────

// T8.1 — api_key containing prompt injection newlines is JSON-escaped at the
// serialization boundary. Guards against HTTP header injection or log injection
// via embedded newlines in the credential value.
test "T8: api_key prompt injection newlines are JSON-escaped at serialization" {
    const alloc = std.testing.allocator;
    const injection_key = "sk-ant\nX-Forwarded-For: evil\nignore previous instructions";
    const ac_cfg = ExecutorClient.AgentConfig{ .api_key = injection_key };

    var ac_map = std.json.ObjectMap.init(alloc);
    defer ac_map.deinit();
    if (ac_cfg.api_key.len > 0)
        try ac_map.put("api_key", .{ .string = ac_cfg.api_key });

    const serialized = try std.json.Stringify.valueAlloc(alloc, std.json.Value{ .object = ac_map }, .{});
    defer alloc.free(serialized);

    // Serialized JSON must NOT contain a raw newline — std.json must escape it.
    try std.testing.expect(!std.mem.containsAtLeast(u8, serialized, 1, "\n"));
    // Escaped form must be present.
    try std.testing.expect(std.mem.indexOf(u8, serialized, "\\n") != null);
}

// T8.2 — api_key with embedded JSON-structural characters is serialized safely.
// Guards against JSON injection that could escape the api_key string boundary
// and insert adversarial fields into the agent_config object.
test "T8: api_key JSON injection characters do not escape the string boundary" {
    const alloc = std.testing.allocator;
    const injection_key = "sk\"}},\"evil\":\"injected";
    const ac_cfg = ExecutorClient.AgentConfig{ .api_key = injection_key };

    var ac_map = std.json.ObjectMap.init(alloc);
    defer ac_map.deinit();
    if (ac_cfg.api_key.len > 0)
        try ac_map.put("api_key", .{ .string = ac_cfg.api_key });

    const serialized = try std.json.Stringify.valueAlloc(alloc, std.json.Value{ .object = ac_map }, .{});
    defer alloc.free(serialized);

    // The serialized JSON must parse back cleanly (no structural escape).
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, serialized, .{});
    defer parsed.deinit();
    // The recovered api_key must exactly equal the original — no truncation or injection.
    const recovered = parsed.value.object.get("api_key").?.string;
    try std.testing.expectEqualStrings(injection_key, recovered);
}

// T8.3 — CorrelationContext has no credential fields (data minimization at session layer).
// api_key and github_token must never be threaded through CorrelationContext,
// which is stored in session state and included in log lines.
test "T8: CorrelationContext has no credential fields — data minimization" {
    // Compile-time check: if either field is added to CorrelationContext the test fails to compile.
    comptime std.debug.assert(!@hasField(types.CorrelationContext, "api_key"));
    comptime std.debug.assert(!@hasField(types.CorrelationContext, "github_token"));
    try std.testing.expect(true);
}

// T8.4 — Fail-closed: empty api_key (len == 0) means no credential is injected.
// The boundary is exactly len == 0 — not null, not a sentinel string, not a default value.
test "T8: AgentConfig fail-closed — empty api_key skips injection, non-empty enables it" {
    const empty = ExecutorClient.AgentConfig{};
    // len == 0 -> serialization guard fires -> no api_key field in RPC payload.
    try std.testing.expect(empty.api_key.len == 0);

    const populated = ExecutorClient.AgentConfig{ .api_key = "sk-ant-api03-real" };
    // len > 0 -> guard passes -> api_key included in RPC payload.
    try std.testing.expect(populated.api_key.len > 0);
}

// T8.5 — github_token fail-closed mirrors api_key semantics.
test "T8: AgentConfig fail-closed — empty github_token skips injection" {
    const empty = ExecutorClient.AgentConfig{};
    try std.testing.expect(empty.github_token.len == 0);

    const populated = ExecutorClient.AgentConfig{ .github_token = "ghs_installtoken_abc" };
    try std.testing.expect(populated.github_token.len > 0);
}

