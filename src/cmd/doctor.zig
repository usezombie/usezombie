const std = @import("std");

const db = @import("../db/pool.zig");
const clerk_auth = @import("../auth/clerk.zig");
const queue_redis = @import("../queue/redis.zig");

fn redisUrlUsesTls(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "rediss://");
}

fn redisUsernameFromUrl(url: []const u8) ?[]const u8 {
    const rest = if (std.mem.startsWith(u8, url, "redis://"))
        url["redis://".len..]
    else if (std.mem.startsWith(u8, url, "rediss://"))
        url["rediss://".len..]
    else
        return null;
    const at = std.mem.lastIndexOfScalar(u8, rest, '@') orelse return null;
    const userpass = rest[0..at];
    const colon = std.mem.indexOfScalar(u8, userpass, ':') orelse return null;
    if (colon == 0) return null;
    return userpass[0..colon];
}

pub fn run(alloc: std.mem.Allocator) !void {
    var ok = true;
    var stdout_buf: [8192]u8 = undefined;
    var stdout_w = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_w.interface;

    try stdout.print("zombied doctor\n\n", .{});

    const db_api_url = std.process.getEnvVarOwned(alloc, db.roleEnvVarName(.api)) catch null;
    defer if (db_api_url) |v| alloc.free(v);
    const db_worker_url = std.process.getEnvVarOwned(alloc, db.roleEnvVarName(.worker)) catch null;
    defer if (db_worker_url) |v| alloc.free(v);
    const redis_api_url = std.process.getEnvVarOwned(alloc, queue_redis.roleEnvVarName(.api)) catch null;
    defer if (redis_api_url) |v| alloc.free(v);
    const redis_worker_url = std.process.getEnvVarOwned(alloc, queue_redis.roleEnvVarName(.worker)) catch null;
    defer if (redis_worker_url) |v| alloc.free(v);

    role_env_check: {
        if (db_api_url == null or db_worker_url == null) {
            try stdout.print("  [FAIL] DATABASE_URL_API and DATABASE_URL_WORKER required (no shared fallback)\n", .{});
            ok = false;
            break :role_env_check;
        }
        if (std.mem.eql(u8, db_api_url.?, db_worker_url.?)) {
            try stdout.print("  [FAIL] DATABASE_URL_API and DATABASE_URL_WORKER must differ\n", .{});
            ok = false;
            break :role_env_check;
        }

        if (redis_api_url == null or redis_worker_url == null) {
            try stdout.print("  [FAIL] REDIS_URL_API and REDIS_URL_WORKER required (no shared fallback)\n", .{});
            ok = false;
            break :role_env_check;
        }
        if (std.mem.eql(u8, redis_api_url.?, redis_worker_url.?)) {
            try stdout.print("  [FAIL] REDIS_URL_API and REDIS_URL_WORKER must differ\n", .{});
            ok = false;
            break :role_env_check;
        }
        if (!redisUrlUsesTls(redis_api_url.?)) {
            try stdout.print("  [FAIL] REDIS_URL_API must use rediss://\n", .{});
            ok = false;
            break :role_env_check;
        }
        if (!redisUrlUsesTls(redis_worker_url.?)) {
            try stdout.print("  [FAIL] REDIS_URL_WORKER must use rediss://\n", .{});
            ok = false;
            break :role_env_check;
        }

        try stdout.print("  [OK]   Role-separated DB/Redis URLs configured with Redis TLS\n", .{});
    }

    db_check: {
        const pool = db.initFromEnvForRole(alloc, .api) catch {
            try stdout.print("  [FAIL] DATABASE_URL_API or DATABASE_URL not set/invalid\n", .{});
            ok = false;
            break :db_check;
        };
        pool.deinit();
        try stdout.print("  [OK]   API database config\n", .{});
    }

    worker_db_check: {
        const pool = db.initFromEnvForRole(alloc, .worker) catch {
            try stdout.print("  [FAIL] DATABASE_URL_WORKER or DATABASE_URL not set/invalid\n", .{});
            ok = false;
            break :worker_db_check;
        };
        pool.deinit();
        try stdout.print("  [OK]   Worker database config\n", .{});
    }

    redis_api_check: {
        var client = queue_redis.Client.connectFromEnv(alloc, .api) catch {
            try stdout.print("  [FAIL] REDIS_URL_API not set/invalid\n", .{});
            ok = false;
            break :redis_api_check;
        };
        defer client.deinit();
        client.readyCheck() catch {
            try stdout.print("  [FAIL] Redis API readiness (PING + XGROUP)\n", .{});
            ok = false;
            break :redis_api_check;
        };
        const expected = if (redis_api_url) |u| redisUsernameFromUrl(u) else null;
        if (expected) |user| {
            const actual = client.aclWhoAmI() catch {
                try stdout.print("  [FAIL] Redis API ACL identity probe failed (ACL WHOAMI)\n", .{});
                ok = false;
                break :redis_api_check;
            };
            defer alloc.free(actual);
            if (!std.mem.eql(u8, actual, user)) {
                try stdout.print("  [FAIL] Redis API ACL user mismatch expected={s} actual={s}\n", .{ user, actual });
                ok = false;
                break :redis_api_check;
            }
        }
        try stdout.print("  [OK]   Redis API readiness + ACL identity\n", .{});
    }

    redis_worker_check: {
        var client = queue_redis.Client.connectFromEnv(alloc, .worker) catch {
            try stdout.print("  [FAIL] REDIS_URL_WORKER not set/invalid\n", .{});
            ok = false;
            break :redis_worker_check;
        };
        defer client.deinit();
        client.readyCheck() catch {
            try stdout.print("  [FAIL] Redis worker readiness (PING + XGROUP)\n", .{});
            ok = false;
            break :redis_worker_check;
        };
        const expected = if (redis_worker_url) |u| redisUsernameFromUrl(u) else null;
        if (expected) |user| {
            const actual = client.aclWhoAmI() catch {
                try stdout.print("  [FAIL] Redis worker ACL identity probe failed (ACL WHOAMI)\n", .{});
                ok = false;
                break :redis_worker_check;
            };
            defer alloc.free(actual);
            if (!std.mem.eql(u8, actual, user)) {
                try stdout.print("  [FAIL] Redis worker ACL user mismatch expected={s} actual={s}\n", .{ user, actual });
                ok = false;
                break :redis_worker_check;
            }
        }
        try stdout.print("  [OK]   Redis worker readiness + ACL identity\n", .{});
    }

    {
        const key = std.process.getEnvVarOwned(alloc, "ENCRYPTION_MASTER_KEY") catch null;
        if (key) |k| {
            defer alloc.free(k);
            if (k.len == 64) {
                try stdout.print("  [OK]   ENCRYPTION_MASTER_KEY set\n", .{});
            } else {
                try stdout.print("  [FAIL] ENCRYPTION_MASTER_KEY must be 64 hex chars\n", .{});
                ok = false;
            }
        } else {
            try stdout.print("  [FAIL] ENCRYPTION_MASTER_KEY not set\n", .{});
            ok = false;
        }
    }

    {
        const app_id = std.process.getEnvVarOwned(alloc, "GITHUB_APP_ID") catch null;
        if (app_id) |id| {
            defer alloc.free(id);
            if (id.len > 0) {
                try stdout.print("  [OK]   GITHUB_APP_ID set\n", .{});
            } else {
                try stdout.print("  [FAIL] GITHUB_APP_ID is empty\n", .{});
                ok = false;
            }
        } else {
            try stdout.print("  [FAIL] GITHUB_APP_ID not set\n", .{});
            ok = false;
        }
    }

    {
        const key = std.process.getEnvVarOwned(alloc, "GITHUB_APP_PRIVATE_KEY") catch null;
        if (key) |k| {
            defer alloc.free(k);
            if (k.len > 0) {
                try stdout.print("  [OK]   GITHUB_APP_PRIVATE_KEY set\n", .{});
            } else {
                try stdout.print("  [FAIL] GITHUB_APP_PRIVATE_KEY is empty\n", .{});
                ok = false;
            }
        } else {
            try stdout.print("  [FAIL] GITHUB_APP_PRIVATE_KEY not set\n", .{});
            ok = false;
        }
    }

    {
        const config_dir = std.process.getEnvVarOwned(alloc, "AGENT_CONFIG_DIR") catch
            try alloc.dupe(u8, "./config");
        defer alloc.free(config_dir);

        const required_files = [_][]const u8{
            "echo-prompt.md",        "scout-prompt.md", "warden-prompt.md",
            "echo.json",             "scout.json",      "warden.json",
            "pipeline-default.json",
        };
        for (required_files) |fname| {
            const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ config_dir, fname });
            defer alloc.free(path);
            if (std.fs.accessAbsolute(path, .{})) |_| {
                try stdout.print("  [OK]   config/{s}\n", .{fname});
            } else |_| {
                try stdout.print("  [FAIL] config/{s} missing\n", .{fname});
                ok = false;
            }
        }
    }

    {
        const clerk_secret = std.process.getEnvVarOwned(alloc, "CLERK_SECRET_KEY") catch null;
        if (clerk_secret) |secret| {
            defer alloc.free(secret);
            if (std.mem.trim(u8, secret, " \t\r\n").len > 0) {
                try stdout.print("  [OK]   CLERK_SECRET_KEY set\n", .{});
                const jwks_url = std.process.getEnvVarOwned(alloc, "CLERK_JWKS_URL") catch null;
                if (jwks_url) |url| {
                    defer alloc.free(url);
                    if (url.len == 0) {
                        try stdout.print("  [FAIL] CLERK_JWKS_URL is empty\n", .{});
                        ok = false;
                    } else {
                        var verifier = clerk_auth.Verifier.init(alloc, .{
                            .jwks_url = url,
                        });
                        defer verifier.deinit();
                        var jwks_ok = true;
                        verifier.checkJwksConnectivity() catch {
                            try stdout.print("  [FAIL] CLERK JWKS fetch failed\n", .{});
                            ok = false;
                            jwks_ok = false;
                        };
                        if (jwks_ok) {
                            try stdout.print("  [OK]   Clerk JWKS reachable\n", .{});
                        }
                    }
                } else {
                    try stdout.print("  [FAIL] CLERK_JWKS_URL not set\n", .{});
                    ok = false;
                }
            } else {
                try stdout.print("  [FAIL] CLERK_SECRET_KEY is empty\n", .{});
                ok = false;
            }
        } else {
            const key = std.process.getEnvVarOwned(alloc, "API_KEY") catch null;
            if (key) |k| {
                defer alloc.free(k);
                try stdout.print("  [OK]   API_KEY set (dev fallback)\n", .{});
            } else {
                try stdout.print("  [FAIL] API_KEY not set (required when Clerk is disabled)\n", .{});
                ok = false;
            }
        }
    }

    try stdout.print("\n{s}\n", .{
        if (ok) "All checks passed." else "Some checks failed — fix before running serve.",
    });
    try stdout.flush();
    if (!ok) std.process.exit(1);
}

test "redisUsernameFromUrl parses user for redis and rediss" {
    try std.testing.expectEqualStrings("api_user", redisUsernameFromUrl("redis://api_user:pw@cache.local:6379").?);
    try std.testing.expectEqualStrings("worker_user", redisUsernameFromUrl("rediss://worker_user:pw@cache.local:6379").?);
    try std.testing.expect(redisUsernameFromUrl("rediss://cache.local:6379") == null);
}

test "redisUrlUsesTls enforces rediss scheme" {
    try std.testing.expect(redisUrlUsesTls("rediss://api:pw@cache.local:6379"));
    try std.testing.expect(!redisUrlUsesTls("redis://api:pw@cache.local:6379"));
}
