const std = @import("std");
const types = @import("types.zig");

const MAX_STDERR_LINES: usize = 200;
const REDACTED = "[REDACTED]";
const NEVER_FLAG_KEYS = [_][]const u8{
    "ENCRYPTION_MASTER_KEY",
    "GITHUB_APP_ID",
    "GITHUB_APP_PRIVATE_KEY",
    "OIDC_PROVIDER",
    "OIDC_JWKS_URL",
    "OIDC_ISSUER",
    "OIDC_AUDIENCE",
    "API_KEY",
    "DATABASE_URL_API",
    "DATABASE_URL_WORKER",
    "REDIS_URL_API",
    "REDIS_URL_WORKER",
    "POSTHOG_API_KEY",
    "RESEND_API_KEY",
};

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

pub fn classifyFailureFromErrorName(error_name: []const u8) ?types.FailureClass {
    if (std.mem.eql(u8, error_name, "RunDeadlineExceeded") or
        std.mem.eql(u8, error_name, "CommandTimedOut") or
        std.mem.eql(u8, error_name, "Timeout") or
        std.mem.eql(u8, error_name, "TimedOut"))
    {
        return .timeout;
    }

    if (std.mem.eql(u8, error_name, "OutOfMemory") or
        std.mem.eql(u8, error_name, "NoSpaceLeft"))
    {
        return .oom;
    }

    if (std.mem.eql(u8, error_name, "MissingConfig") or
        std.mem.eql(u8, error_name, "MissingGitHubInstallation") or
        std.mem.eql(u8, error_name, "MissingMasterKey") or
        std.mem.eql(u8, error_name, "PrAuthFailed") or
        std.mem.eql(u8, error_name, "AuthFailed") or
        std.mem.eql(u8, error_name, "TokenExpired") or
        std.mem.eql(u8, error_name, "Unauthorized") or
        std.mem.eql(u8, error_name, "RedisAuthFailed") or
        std.mem.eql(u8, error_name, "InvalidAuthorization"))
    {
        return .auth_failure;
    }

    if ((containsIgnoreCase(error_name, "context") and
        (containsIgnoreCase(error_name, "overflow") or
            containsIgnoreCase(error_name, "exhaust") or
            containsIgnoreCase(error_name, "window"))) or
        (containsIgnoreCase(error_name, "token") and
            (containsIgnoreCase(error_name, "limit") or
                containsIgnoreCase(error_name, "overflow") or
                containsIgnoreCase(error_name, "exceed"))))
    {
        return .context_overflow;
    }

    if (std.mem.eql(u8, error_name, "FileNotFound") or
        std.mem.eql(u8, error_name, "PathTraversal") or
        std.mem.eql(u8, error_name, "CommandFailed") or
        std.mem.eql(u8, error_name, "InvalidResponse"))
    {
        return .tool_call_failure;
    }

    return null;
}

pub fn classifyFailure(state: *const types.ScoringState) ?types.FailureClass {
    if (state.failure_class_override) |failure_class| return failure_class;
    if (state.failure_error_name) |error_name| {
        if (classifyFailureFromErrorName(error_name)) |failure_class| return failure_class;
    }

    return switch (state.outcome) {
        .done => null,
        .blocked_retries_exhausted => .timeout,
        .blocked_stage_graph => .bad_output_format,
        .error_propagation => .unhandled_exception,
        .pending => .unknown,
    };
}

pub fn scoreTierLabel(score: i32) []const u8 {
    if (score >= 90) return "Elite";
    if (score >= 70) return "Gold";
    if (score >= 40) return "Silver";
    return "Bronze";
}

pub fn scrubSecretAssignments(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayList(u8){};
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < input.len) {
        var matched_key: ?[]const u8 = null;
        for (NEVER_FLAG_KEYS) |key| {
            if (i + key.len + 1 <= input.len and std.mem.eql(u8, input[i .. i + key.len], key) and input[i + key.len] == '=') {
                matched_key = key;
                break;
            }
        }

        if (matched_key) |key| {
            try out.appendSlice(alloc, key);
            try out.append(alloc, '=');
            try out.appendSlice(alloc, REDACTED);
            i += key.len + 1;
            while (i < input.len and input[i] != '\n' and input[i] != '\r' and input[i] != ' ' and input[i] != '\t' and input[i] != '"' and input[i] != '\'') : (i += 1) {}
            continue;
        }

        if (i + "Bearer ".len <= input.len and std.ascii.eqlIgnoreCase(input[i .. i + "Bearer ".len], "Bearer ")) {
            try out.appendSlice(alloc, "Bearer ");
            try out.appendSlice(alloc, REDACTED);
            i += "Bearer ".len;
            while (i < input.len and input[i] != '\n' and input[i] != '\r' and input[i] != ' ' and input[i] != '\t') : (i += 1) {}
            continue;
        }

        if (i + "-----BEGIN".len <= input.len and std.mem.eql(u8, input[i .. i + "-----BEGIN".len], "-----BEGIN")) {
            const end_idx = std.mem.indexOfPos(u8, input, i, "-----END");
            if (end_idx) |end_start| {
                const line_end = std.mem.indexOfScalarPos(u8, input, end_start, '\n') orelse input.len;
                try out.appendSlice(alloc, REDACTED);
                i = line_end;
                continue;
            }
        }

        try out.append(alloc, input[i]);
        i += 1;
    }

    return try out.toOwnedSlice(alloc);
}

fn lastLinesSlice(input: []const u8, max_lines: usize) []const u8 {
    if (input.len == 0) return input;
    var line_count: usize = 0;
    var idx: usize = input.len;
    while (idx > 0) {
        idx -= 1;
        if (input[idx] == '\n') {
            line_count += 1;
            if (line_count >= max_lines) return input[idx + 1 ..];
        }
    }
    return input;
}

pub fn scrubStderrTail(alloc: std.mem.Allocator, raw_tail: ?[]const u8) !?[]const u8 {
    const raw = raw_tail orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    const tail = lastLinesSlice(trimmed, MAX_STDERR_LINES);
    const scrubbed = try scrubSecretAssignments(alloc, tail);
    return scrubbed;
}
