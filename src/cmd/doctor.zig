const std = @import("std");

const db = @import("../db/pool.zig");
const clerk_auth = @import("../auth/clerk.zig");
const queue_redis = @import("../queue/redis.zig");

pub fn run(alloc: std.mem.Allocator) !void {
    var ok = true;
    var stdout_buf: [8192]u8 = undefined;
    var stdout_w = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_w.interface;

    try stdout.print("zombied doctor\n\n", .{});

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
            try stdout.print("  [FAIL] REDIS_URL_API or REDIS_URL not set/invalid\n", .{});
            ok = false;
            break :redis_api_check;
        };
        defer client.deinit();
        client.ping() catch {
            try stdout.print("  [FAIL] Redis API connectivity (PING)\n", .{});
            ok = false;
            break :redis_api_check;
        };
        try stdout.print("  [OK]   Redis API connectivity\n", .{});
    }

    redis_worker_check: {
        var client = queue_redis.Client.connectFromEnv(alloc, .worker) catch {
            try stdout.print("  [FAIL] REDIS_URL_WORKER or REDIS_URL not set/invalid\n", .{});
            ok = false;
            break :redis_worker_check;
        };
        defer client.deinit();
        client.ping() catch {
            try stdout.print("  [FAIL] Redis worker connectivity (PING)\n", .{});
            ok = false;
            break :redis_worker_check;
        };
        try stdout.print("  [OK]   Redis worker connectivity\n", .{});
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
