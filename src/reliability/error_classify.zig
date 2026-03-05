//! Error classification for external calls and retry decisions.

const std = @import("std");
const types = @import("../types.zig");

pub const ErrorClass = enum {
    rate_limited,
    timeout,
    context_exhausted,
    auth,
    invalid_request,
    server_error,
    unknown,
};

pub const Classified = struct {
    class: ErrorClass,
    retryable: bool,
    retry_after_ms: ?u64,
    reason_code: types.ReasonCode,
};

fn parseRetryAfterMs(detail: []const u8) ?u64 {
    const needle = "Retry-After:";
    const idx = std.mem.indexOf(u8, detail, needle) orelse return null;

    var rest = detail[idx + needle.len ..];
    rest = std.mem.trimLeft(u8, rest, " \t");

    var end: usize = 0;
    while (end < rest.len and rest[end] >= '0' and rest[end] <= '9') : (end += 1) {}
    if (end == 0) return null;

    const seconds = std.fmt.parseInt(u64, rest[0..end], 10) catch return null;
    return seconds * std.time.ms_per_s;
}

fn fromDetail(detail: []const u8) ?Classified {
    if (std.mem.indexOf(u8, detail, "429") != null or std.mem.indexOf(u8, detail, "rate limit") != null) {
        return .{
            .class = .rate_limited,
            .retryable = true,
            .retry_after_ms = parseRetryAfterMs(detail),
            .reason_code = .AGENT_TIMEOUT,
        };
    }

    if (std.mem.indexOf(u8, detail, "401") != null or std.mem.indexOf(u8, detail, "403") != null) {
        return .{
            .class = .auth,
            .retryable = false,
            .retry_after_ms = null,
            .reason_code = .AGENT_CRASH,
        };
    }

    if (std.mem.indexOf(u8, detail, "context") != null and std.mem.indexOf(u8, detail, "exhaust") != null) {
        return .{
            .class = .context_exhausted,
            .retryable = false,
            .retry_after_ms = null,
            .reason_code = .SPEC_MISMATCH,
        };
    }

    return null;
}

pub fn classify(err: anyerror, detail: ?[]const u8) Classified {
    if (detail) |d| {
        if (fromDetail(d)) |c| return c;
    }

    const name = @errorName(err);

    if (std.mem.eql(u8, name, "CommandTimedOut") or
        std.mem.eql(u8, name, "Timeout") or
        std.mem.eql(u8, name, "TimedOut"))
    {
        return .{
            .class = .timeout,
            .retryable = true,
            .retry_after_ms = null,
            .reason_code = .AGENT_TIMEOUT,
        };
    }

    if (std.mem.eql(u8, name, "CurlFailed") or
        std.mem.eql(u8, name, "FetchFailed") or
        std.mem.eql(u8, name, "PushFailed") or
        std.mem.eql(u8, name, "PrFailed") or
        std.mem.eql(u8, name, "CommandFailed") or
        std.mem.eql(u8, name, "ConnectFailed"))
    {
        return .{
            .class = .server_error,
            .retryable = true,
            .retry_after_ms = null,
            .reason_code = .AGENT_TIMEOUT,
        };
    }

    if (std.mem.eql(u8, name, "MissingConfig") or
        std.mem.eql(u8, name, "MissingGitHubInstallation") or
        std.mem.eql(u8, name, "MissingMasterKey"))
    {
        return .{
            .class = .auth,
            .retryable = false,
            .retry_after_ms = null,
            .reason_code = .AGENT_CRASH,
        };
    }

    if (std.mem.eql(u8, name, "InvalidRequest") or std.mem.eql(u8, name, "InvalidResponse")) {
        return .{
            .class = .invalid_request,
            .retryable = false,
            .retry_after_ms = null,
            .reason_code = .AGENT_CRASH,
        };
    }

    return .{
        .class = .unknown,
        .retryable = false,
        .retry_after_ms = null,
        .reason_code = .AGENT_CRASH,
    };
}

test "classify timeout errors as retryable" {
    const c = classify(error.CommandTimedOut, null);
    try std.testing.expectEqual(ErrorClass.timeout, c.class);
    try std.testing.expect(c.retryable);
}

test "classify detail-based rate limit and retry-after" {
    const c = classify(error.CurlFailed, "HTTP 429\nRetry-After: 7\n");
    try std.testing.expectEqual(ErrorClass.rate_limited, c.class);
    try std.testing.expect(c.retryable);
    try std.testing.expectEqual(@as(?u64, 7_000), c.retry_after_ms);
}
