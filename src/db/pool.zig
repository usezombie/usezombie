//! Database connection pool — wraps pg.zig Pool.
//! Owns the pool and provides helpers for common queries.

const std = @import("std");
const pg = @import("pg");
const types = @import("../types.zig");
const log = std.log.scoped(.db);

pub const Pool = pg.Pool;
pub const Conn = pg.Conn;
pub const Row = pg.Row;

pub const Config = struct {
    url: []const u8,
    pool_size: u32 = 4,
    timeout_ms: u32 = 10_000,
};

/// Parse a Postgres connection URL into pg.Pool.Opts.
/// URL format: postgres://user:pass@host:port/dbname
pub fn parseUrl(alloc: std.mem.Allocator, url: []const u8) !pg.Pool.Opts {
    // strip scheme
    const rest = if (std.mem.startsWith(u8, url, "postgres://"))
        url["postgres://".len..]
    else if (std.mem.startsWith(u8, url, "postgresql://"))
        url["postgresql://".len..]
    else
        return error.InvalidDatabaseUrl;

    // user:pass@host:port/dbname
    const at_pos = std.mem.lastIndexOfScalar(u8, rest, '@') orelse return error.InvalidDatabaseUrl;
    const userpass = rest[0..at_pos];
    const hostpath = rest[at_pos + 1 ..];

    // user and password
    var username: []const u8 = "";
    var password: []const u8 = "";
    if (std.mem.indexOfScalar(u8, userpass, ':')) |colon| {
        username = userpass[0..colon];
        password = userpass[colon + 1 ..];
    } else {
        username = userpass;
    }

    // host:port/dbname
    const slash_pos = std.mem.indexOfScalar(u8, hostpath, '/') orelse return error.InvalidDatabaseUrl;
    const hostport = hostpath[0..slash_pos];
    const dbname = hostpath[slash_pos + 1 ..];

    var host: []const u8 = hostport;
    var port: u16 = 5432;
    if (std.mem.lastIndexOfScalar(u8, hostport, ':')) |colon| {
        host = hostport[0..colon];
        port = std.fmt.parseInt(u16, hostport[colon + 1 ..], 10) catch return error.InvalidDatabaseUrl;
    }

    return pg.Pool.Opts{
        .size = 4,
        .connect = .{
            .host = try alloc.dupe(u8, host),
            .port = port,
        },
        .auth = .{
            .username = try alloc.dupe(u8, username),
            .password = try alloc.dupe(u8, password),
            .database = try alloc.dupe(u8, dbname),
            .timeout = 10_000,
        },
    };
}

/// Initialize a pool from DATABASE_URL environment variable.
pub fn initFromEnv(alloc: std.mem.Allocator) !*Pool {
    const url = std.process.getEnvVarOwned(alloc, "DATABASE_URL") catch {
        log.err("DATABASE_URL not set", .{});
        return error.MissingDatabaseUrl;
    };
    defer alloc.free(url);

    // Use an arena for the URL-parsed opts so pg.Pool.init can copy them
    // and we can free everything cleanly afterward.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const opts = try parseUrl(arena.allocator(), url);
    const host_copy = try alloc.dupe(u8, opts.connect.host orelse "127.0.0.1");
    defer alloc.free(host_copy);

    const pool = try pg.Pool.init(alloc, opts);
    log.info("database pool initialized size=4 host={s}", .{host_copy});
    return pool;
}

/// Execute schema migrations from the SQL file.
pub fn runMigrations(pool: *Pool, sql: []const u8) !void {
    var conn = try pool.acquire();
    defer pool.release(conn);

    // Split by `;` and execute each statement
    var it = std.mem.splitSequence(u8, sql, ";\n");
    var count: u32 = 0;
    while (it.next()) |stmt| {
        const trimmed = std.mem.trim(u8, stmt, " \t\r\n");
        if (trimmed.len == 0) continue;
        var result = conn.query(trimmed, .{}) catch |err| {
            log.warn("migration statement error (may be expected on re-run): {}", .{err});
            continue;
        };
        result.deinit();
        count += 1;
    }
    log.info("migrations applied statements={d}", .{count});
}
