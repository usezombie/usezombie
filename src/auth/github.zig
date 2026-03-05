//! GitHub App authentication helpers.
//! Generates RS256 JWTs and exchanges installation tokens.

const std = @import("std");
const log = std.log.scoped(.github_auth);

pub const GitHubAuthError = error{
    MissingConfig,
    OpenSslFailed,
    CurlFailed,
    InvalidResponse,
    CommandTimedOut,
};

pub const TokenCache = struct {
    alloc: std.mem.Allocator,
    app_id: []const u8,
    private_key_pem: []const u8,
    mutex: std.Thread.Mutex = .{},
    cached_token: ?[]u8 = null,
    refresh_deadline_ms: i64 = 0,

    pub fn init(alloc: std.mem.Allocator, app_id: []const u8, private_key_pem: []const u8) TokenCache {
        return .{
            .alloc = alloc,
            .app_id = app_id,
            .private_key_pem = private_key_pem,
        };
    }

    pub fn deinit(self: *TokenCache) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.cached_token) |token| self.alloc.free(token);
        self.cached_token = null;
        self.refresh_deadline_ms = 0;
    }

    pub fn getInstallationToken(
        self: *TokenCache,
        alloc: std.mem.Allocator,
        installation_id: []const u8,
    ) ![]u8 {
        if (self.app_id.len == 0 or self.private_key_pem.len == 0 or installation_id.len == 0) {
            return GitHubAuthError.MissingConfig;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        const now_ms = std.time.milliTimestamp();
        if (self.cached_token) |token| {
            if (now_ms < self.refresh_deadline_ms) {
                return alloc.dupe(u8, token);
            }
        }

        const jwt = try buildAppJwt(alloc, self.app_id, self.private_key_pem);
        defer alloc.free(jwt);

        const fresh_token = try exchangeInstallationToken(alloc, installation_id, jwt);
        errdefer alloc.free(fresh_token);

        if (self.cached_token) |token| self.alloc.free(token);
        self.cached_token = try self.alloc.dupe(u8, fresh_token);

        // GitHub installation tokens expire in ~60 minutes; refresh 5 minutes early.
        self.refresh_deadline_ms = now_ms + (55 * std.time.ms_per_min);

        return fresh_token;
    }
};

fn encodeBase64Url(alloc: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const len = std.base64.url_safe_no_pad.Encoder.calcSize(bytes.len);
    const out = try alloc.alloc(u8, len);
    _ = std.base64.url_safe_no_pad.Encoder.encode(out, bytes);
    return out;
}

fn normalizedPrivateKeyPem(alloc: std.mem.Allocator, pem: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, pem, "\\n") == null) {
        return alloc.dupe(u8, pem);
    }

    var out = std.ArrayList(u8).init(alloc);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < pem.len) : (i += 1) {
        if (pem[i] == '\\' and i + 1 < pem.len and pem[i + 1] == 'n') {
            try out.append('\n');
            i += 1;
            continue;
        }
        try out.append(pem[i]);
    }

    return out.toOwnedSlice();
}

fn randomSuffix() u64 {
    var b: [8]u8 = undefined;
    std.crypto.random.bytes(&b);
    return std.mem.readInt(u64, &b, .little);
}

fn runWithInput(
    alloc: std.mem.Allocator,
    argv: []const []const u8,
    stdin_data: ?[]const u8,
    timeout_ms: u64,
) ![]u8 {
    var child = std.process.Child.init(argv, alloc);
    child.stdin_behavior = if (stdin_data != null) .Pipe else .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    if (stdin_data) |in| {
        if (child.stdin) |*stdin_pipe| {
            try stdin_pipe.writeAll(in);
            stdin_pipe.close();
            child.stdin = null;
        }
    }

    const start_ms = std.time.milliTimestamp();
    const term = while (true) {
        if (try child.tryWait()) |t| break t;
        if (std.time.milliTimestamp() - start_ms > @as(i64, @intCast(timeout_ms))) {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            return GitHubAuthError.CommandTimedOut;
        }
        std.Thread.sleep(50 * std.time.ns_per_ms);
    };

    const stdout = if (child.stdout) |*s|
        try s.readToEndAlloc(alloc, 1024 * 1024)
    else
        try alloc.dupe(u8, "");
    const stderr = if (child.stderr) |*s|
        try s.readToEndAlloc(alloc, 1024 * 1024)
    else
        try alloc.dupe(u8, "");
    defer alloc.free(stderr);

    switch (term) {
        .Exited => |code| if (code != 0) {
            log.err("command failed code={d} argv[0]={s} stderr={s}", .{ code, argv[0], stderr });
            alloc.free(stdout);
            if (std.mem.eql(u8, argv[0], "curl")) return GitHubAuthError.CurlFailed;
            return GitHubAuthError.OpenSslFailed;
        },
        else => {
            alloc.free(stdout);
            if (std.mem.eql(u8, argv[0], "curl")) return GitHubAuthError.CurlFailed;
            return GitHubAuthError.OpenSslFailed;
        },
    }

    return stdout;
}

fn signRs256(
    alloc: std.mem.Allocator,
    signing_input: []const u8,
    private_key_pem: []const u8,
) ![]u8 {
    const normalized = try normalizedPrivateKeyPem(alloc, private_key_pem);
    defer alloc.free(normalized);

    const key_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/usezombie-gh-app-key-{x}.pem",
        .{randomSuffix()},
    );
    defer alloc.free(key_path);
    defer std.fs.deleteFileAbsolute(key_path) catch {};

    {
        const f = try std.fs.createFileAbsolute(key_path, .{ .mode = 0o600 });
        defer f.close();
        try f.writeAll(normalized);
    }

    return runWithInput(
        alloc,
        &.{ "openssl", "dgst", "-sha256", "-sign", key_path },
        signing_input,
        10_000,
    );
}

fn buildAppJwt(alloc: std.mem.Allocator, app_id: []const u8, private_key_pem: []const u8) ![]u8 {
    const now = std.time.timestamp();

    const header_json = "{\"alg\":\"RS256\",\"typ\":\"JWT\"}";
    const payload_json = try std.fmt.allocPrint(
        alloc,
        "{{\"iss\":\"{s}\",\"iat\":{d},\"exp\":{d}}}",
        .{ app_id, now - 30, now + 540 },
    );
    defer alloc.free(payload_json);

    const header_b64 = try encodeBase64Url(alloc, header_json);
    defer alloc.free(header_b64);
    const payload_b64 = try encodeBase64Url(alloc, payload_json);
    defer alloc.free(payload_b64);

    const signing_input = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ header_b64, payload_b64 });
    defer alloc.free(signing_input);

    const signature = try signRs256(alloc, signing_input, private_key_pem);
    defer alloc.free(signature);

    const sig_b64 = try encodeBase64Url(alloc, signature);
    defer alloc.free(sig_b64);

    return std.fmt.allocPrint(alloc, "{s}.{s}", .{ signing_input, sig_b64 });
}

fn exchangeInstallationToken(
    alloc: std.mem.Allocator,
    installation_id: []const u8,
    app_jwt: []const u8,
) ![]u8 {
    const url = try std.fmt.allocPrint(
        alloc,
        "https://api.github.com/app/installations/{s}/access_tokens",
        .{installation_id},
    );
    defer alloc.free(url);

    const auth = try std.fmt.allocPrint(alloc, "Authorization: Bearer {s}", .{app_jwt});
    defer alloc.free(auth);

    const body = try runWithInput(alloc, &.{
        "curl",                                "-sS",
        "--connect-timeout",                   "10",
        "--max-time",                          "30",
        "--fail-with-body",                    "-X",
        "POST",                                "-H",
        "Accept: application/vnd.github+json", "-H",
        auth,                                  url,
    }, null, 30_000);
    defer alloc.free(body);

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        log.err("invalid github token response: {s}", .{body});
        return GitHubAuthError.InvalidResponse;
    };
    defer parsed.deinit();

    const token_val = parsed.value.object.get("token") orelse {
        log.err("token field missing in response: {s}", .{body});
        return GitHubAuthError.InvalidResponse;
    };

    return alloc.dupe(u8, token_val.string);
}
