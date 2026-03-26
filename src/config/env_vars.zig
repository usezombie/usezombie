const std = @import("std");

const db = @import("../db/pool.zig");
const queue_redis = @import("../queue/redis.zig");

pub const EnvVarsErrors = error{
    MissingDatabaseUrlApi,
    MissingDatabaseUrlWorker,
    MissingRedisUrlApi,
    MissingRedisUrlWorker,
    SameDatabaseUrlForApiAndWorker,
    SameRedisUrlForApiAndWorker,
    RedisApiTlsRequired,
    RedisWorkerTlsRequired,
};

pub const EnvVars = struct {
    db_api: ?[]u8,
    db_worker: ?[]u8,
    redis_api: ?[]u8,
    redis_worker: ?[]u8,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *EnvVars) void {
        if (self.db_api) |v| self.alloc.free(v);
        if (self.db_worker) |v| self.alloc.free(v);
        if (self.redis_api) |v| self.alloc.free(v);
        if (self.redis_worker) |v| self.alloc.free(v);
    }
};

pub const CheckMode = enum {
    api,
    worker,
    both,
};

pub fn loadFromEnv(alloc: std.mem.Allocator) EnvVars {
    return .{
        .db_api = std.process.getEnvVarOwned(alloc, db.roleEnvVarName(.api)) catch null,
        .db_worker = std.process.getEnvVarOwned(alloc, db.roleEnvVarName(.worker)) catch null,
        .redis_api = std.process.getEnvVarOwned(alloc, queue_redis.roleEnvVarName(.api)) catch null,
        .redis_worker = std.process.getEnvVarOwned(alloc, queue_redis.roleEnvVarName(.worker)) catch null,
        .alloc = alloc,
    };
}

pub fn validateRoleSeparatedValues(
    db_api: []const u8,
    db_worker: []const u8,
    redis_api: []const u8,
    redis_worker: []const u8,
) EnvVarsErrors!void {
    if (std.mem.trim(u8, db_api, " \t\r\n").len == 0) return EnvVarsErrors.MissingDatabaseUrlApi;
    if (std.mem.trim(u8, db_worker, " \t\r\n").len == 0) return EnvVarsErrors.MissingDatabaseUrlWorker;
    if (std.mem.trim(u8, redis_api, " \t\r\n").len == 0) return EnvVarsErrors.MissingRedisUrlApi;
    if (std.mem.trim(u8, redis_worker, " \t\r\n").len == 0) return EnvVarsErrors.MissingRedisUrlWorker;

    if (std.mem.eql(u8, db_api, db_worker)) return EnvVarsErrors.SameDatabaseUrlForApiAndWorker;
    // TODO(infra): once Upstash ACL users are available on our plan, replace the temporary
    // same-backend URL variants with truly role-separated Redis credentials.
    if (std.mem.eql(u8, redis_api, redis_worker)) return EnvVarsErrors.SameRedisUrlForApiAndWorker;
    if (!std.mem.startsWith(u8, redis_api, "rediss://")) return EnvVarsErrors.RedisApiTlsRequired;
    if (!std.mem.startsWith(u8, redis_worker, "rediss://")) return EnvVarsErrors.RedisWorkerTlsRequired;
}

pub fn validateLoaded(urls: EnvVars) EnvVarsErrors!void {
    const db_api = urls.db_api orelse return EnvVarsErrors.MissingDatabaseUrlApi;
    const db_worker = urls.db_worker orelse return EnvVarsErrors.MissingDatabaseUrlWorker;
    const redis_api = urls.redis_api orelse return EnvVarsErrors.MissingRedisUrlApi;
    const redis_worker = urls.redis_worker orelse return EnvVarsErrors.MissingRedisUrlWorker;
    try validateRoleSeparatedValues(db_api, db_worker, redis_api, redis_worker);
}

pub fn validateLoadedWithMode(urls: EnvVars, mode: CheckMode) EnvVarsErrors!void {
    switch (mode) {
        .api => {
            const db_api = urls.db_api orelse return EnvVarsErrors.MissingDatabaseUrlApi;
            const redis_api = urls.redis_api orelse return EnvVarsErrors.MissingRedisUrlApi;
            if (std.mem.trim(u8, db_api, " \t\r\n").len == 0) return EnvVarsErrors.MissingDatabaseUrlApi;
            if (std.mem.trim(u8, redis_api, " \t\r\n").len == 0) return EnvVarsErrors.MissingRedisUrlApi;
            if (!std.mem.startsWith(u8, redis_api, "rediss://")) return EnvVarsErrors.RedisApiTlsRequired;
        },
        .worker => {
            const db_worker = urls.db_worker orelse return EnvVarsErrors.MissingDatabaseUrlWorker;
            const redis_worker = urls.redis_worker orelse return EnvVarsErrors.MissingRedisUrlWorker;
            if (std.mem.trim(u8, db_worker, " \t\r\n").len == 0) return EnvVarsErrors.MissingDatabaseUrlWorker;
            if (std.mem.trim(u8, redis_worker, " \t\r\n").len == 0) return EnvVarsErrors.MissingRedisUrlWorker;
            if (!std.mem.startsWith(u8, redis_worker, "rediss://")) return EnvVarsErrors.RedisWorkerTlsRequired;
        },
        .both => try validateLoaded(urls),
    }
}

pub fn enforceFromEnv(alloc: std.mem.Allocator) EnvVarsErrors!void {
    var urls = loadFromEnv(alloc);
    defer urls.deinit();
    try validateLoaded(urls);
}

pub fn enforceFromEnvWithMode(alloc: std.mem.Allocator, mode: CheckMode) EnvVarsErrors!void {
    var urls = loadFromEnv(alloc);
    defer urls.deinit();
    try validateLoadedWithMode(urls, mode);
}

test "validateRoleSeparatedValues enforces split role URLs and redis TLS" {
    try std.testing.expectError(EnvVarsErrors.MissingDatabaseUrlApi, validateRoleSeparatedValues(
        "",
        "postgres://worker:pw@db.local:5432/worker",
        "rediss://api:pw@cache.local:6379",
        "rediss://worker:pw@cache.local:6379",
    ));

    try std.testing.expectError(EnvVarsErrors.SameDatabaseUrlForApiAndWorker, validateRoleSeparatedValues(
        "postgres://shared:pw@db.local:5432/app",
        "postgres://shared:pw@db.local:5432/app",
        "rediss://api:pw@cache.local:6379",
        "rediss://worker:pw@cache.local:6379",
    ));

    try std.testing.expectError(EnvVarsErrors.RedisApiTlsRequired, validateRoleSeparatedValues(
        "postgres://api:pw@db.local:5432/app",
        "postgres://worker:pw@db.local:5432/worker",
        "redis://api:pw@cache.local:6379",
        "rediss://worker:pw@cache.local:6379",
    ));

    try validateRoleSeparatedValues(
        "postgres://api:pw@db.local:5432/app",
        "postgres://worker:pw@db.local:5432/worker",
        "rediss://api:pw@cache.local:6379",
        "rediss://worker:pw@cache.local:6379",
    );
}

// --- Per-role mode validation (validateLoadedWithMode) ---

test "validateLoadedWithMode worker rejects missing worker DB URL" {
    const urls = EnvVars{
        .db_api = null,
        .db_worker = null,
        .redis_api = null,
        .redis_worker = @constCast("rediss://worker:pw@cache.local:6379"),
        .alloc = std.testing.allocator,
    };
    try std.testing.expectError(EnvVarsErrors.MissingDatabaseUrlWorker, validateLoadedWithMode(urls, .worker));
}

test "validateLoadedWithMode worker rejects missing worker Redis URL" {
    const urls = EnvVars{
        .db_api = null,
        .db_worker = @constCast("postgres://worker:pw@db.local:5432/worker"),
        .redis_api = null,
        .redis_worker = null,
        .alloc = std.testing.allocator,
    };
    try std.testing.expectError(EnvVarsErrors.MissingRedisUrlWorker, validateLoadedWithMode(urls, .worker));
}

test "validateLoadedWithMode worker rejects non-TLS Redis" {
    const urls = EnvVars{
        .db_api = null,
        .db_worker = @constCast("postgres://worker:pw@db.local:5432/worker"),
        .redis_api = null,
        .redis_worker = @constCast("redis://worker:pw@cache.local:6379"),
        .alloc = std.testing.allocator,
    };
    try std.testing.expectError(EnvVarsErrors.RedisWorkerTlsRequired, validateLoadedWithMode(urls, .worker));
}

test "validateLoadedWithMode worker accepts valid worker URLs" {
    const urls = EnvVars{
        .db_api = null,
        .db_worker = @constCast("postgres://worker:pw@db.local:5432/worker"),
        .redis_api = null,
        .redis_worker = @constCast("rediss://worker:pw@cache.local:6379"),
        .alloc = std.testing.allocator,
    };
    try validateLoadedWithMode(urls, .worker);
}

test "validateLoadedWithMode api rejects missing API DB URL" {
    const urls = EnvVars{
        .db_api = null,
        .db_worker = null,
        .redis_api = @constCast("rediss://api:pw@cache.local:6379"),
        .redis_worker = null,
        .alloc = std.testing.allocator,
    };
    try std.testing.expectError(EnvVarsErrors.MissingDatabaseUrlApi, validateLoadedWithMode(urls, .api));
}

test "validateLoadedWithMode api rejects non-TLS Redis" {
    const urls = EnvVars{
        .db_api = @constCast("postgres://api:pw@db.local:5432/api"),
        .db_worker = null,
        .redis_api = @constCast("redis://api:pw@cache.local:6379"),
        .redis_worker = null,
        .alloc = std.testing.allocator,
    };
    try std.testing.expectError(EnvVarsErrors.RedisApiTlsRequired, validateLoadedWithMode(urls, .api));
}

test "validateLoadedWithMode api accepts valid API URLs" {
    const urls = EnvVars{
        .db_api = @constCast("postgres://api:pw@db.local:5432/api"),
        .db_worker = null,
        .redis_api = @constCast("rediss://api:pw@cache.local:6379"),
        .redis_worker = null,
        .alloc = std.testing.allocator,
    };
    try validateLoadedWithMode(urls, .api);
}

test "validateLoadedWithMode worker rejects whitespace-only DB URL" {
    const urls = EnvVars{
        .db_api = null,
        .db_worker = @constCast("  \t\n"),
        .redis_api = null,
        .redis_worker = @constCast("rediss://worker:pw@cache.local:6379"),
        .alloc = std.testing.allocator,
    };
    try std.testing.expectError(EnvVarsErrors.MissingDatabaseUrlWorker, validateLoadedWithMode(urls, .worker));
}
