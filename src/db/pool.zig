//! Database connection pool — wraps pg.zig Pool.
//! Owns the pool and provides helpers for common queries.

const std = @import("std");
const pg = @import("pg");
const log = std.log.scoped(.db);

pub const Pool = pg.Pool;
pub const Conn = pg.Conn;
pub const Row = pg.Row;

pub const DbRole = enum {
    default,
    api,
    worker,
    callback,
};

pub const Config = struct {
    url: []const u8,
    pool_size: u32 = 4,
    timeout_ms: u32 = 10_000,
};

pub const Migration = struct {
    version: i32,
    sql: []const u8,
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

fn resolveDatabaseUrl(alloc: std.mem.Allocator, role: DbRole) ![]const u8 {
    const primary = switch (role) {
        .api => "DATABASE_URL_API",
        .worker => "DATABASE_URL_WORKER",
        .callback => "DATABASE_URL_CALLBACK",
        .default => "DATABASE_URL",
    };

    if (std.process.getEnvVarOwned(alloc, primary)) |url| {
        return url;
    } else |_| {
        if (role == .default) return error.MissingDatabaseUrl;
        return std.process.getEnvVarOwned(alloc, "DATABASE_URL") catch error.MissingDatabaseUrl;
    }
}

/// Initialize a pool using DATABASE_URL for the selected role.
pub fn initFromEnvForRole(alloc: std.mem.Allocator, role: DbRole) !*Pool {
    const url = resolveDatabaseUrl(alloc, role) catch {
        log.err("database url not set for role={s}", .{@tagName(role)});
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
    log.info("database pool initialized role={s} size=4 host={s}", .{ @tagName(role), host_copy });
    return pool;
}

/// Backward-compatible default initializer.
pub fn initFromEnv(alloc: std.mem.Allocator) !*Pool {
    return initFromEnvForRole(alloc, .default);
}

fn ensureSchemaMigrationsTable(conn: *Conn) !void {
    var result = try conn.query(
        \\CREATE TABLE IF NOT EXISTS schema_migrations (
        \\    version     INTEGER PRIMARY KEY,
        \\    applied_at  BIGINT NOT NULL
        \\)
    , .{});
    result.deinit();
}

fn isMigrationApplied(conn: *Conn, version: i32) !bool {
    var result = try conn.query(
        "SELECT 1 FROM schema_migrations WHERE version = $1",
        .{version},
    );
    defer result.deinit();
    return (try result.next()) != null;
}

fn applySqlStatements(conn: *Conn, sql: []const u8) !u32 {
    var start: usize = 0;
    var i: usize = 0;
    var in_single_quote = false;
    var in_dollar_quote = false;
    var count: u32 = 0;

    while (i < sql.len) : (i += 1) {
        const ch = sql[i];

        if (!in_dollar_quote and ch == '\'') {
            // Skip escaped single quote inside string literal.
            if (in_single_quote and i + 1 < sql.len and sql[i + 1] == '\'') {
                i += 1;
                continue;
            }
            in_single_quote = !in_single_quote;
            continue;
        }

        if (!in_single_quote and i + 1 < sql.len and sql[i] == '$' and sql[i + 1] == '$') {
            in_dollar_quote = !in_dollar_quote;
            i += 1;
            continue;
        }

        if (ch != ';' or in_single_quote or in_dollar_quote) continue;

        const stmt = std.mem.trim(u8, sql[start..i], " \t\r\n");
        if (stmt.len > 0) {
            var result = try conn.query(stmt, .{});
            result.deinit();
            count += 1;
        }

        start = i + 1;
    }

    const tail = std.mem.trim(u8, sql[start..], " \t\r\n");
    if (tail.len > 0) {
        var result = try conn.query(tail, .{});
        result.deinit();
        count += 1;
    }

    return count;
}

fn beginTx(conn: *Conn) !void {
    var tx = try conn.query("BEGIN", .{});
    tx.deinit();
}

fn commitTx(conn: *Conn) !void {
    var tx = try conn.query("COMMIT", .{});
    tx.deinit();
}

fn rollbackTx(conn: *Conn) void {
    var tx = conn.query("ROLLBACK", .{}) catch return;
    tx.deinit();
}

/// Execute versioned schema migrations, once each, in order.
pub fn runMigrations(pool: *Pool, migrations: []const Migration) !void {
    var conn = try pool.acquire();
    defer pool.release(conn);

    try ensureSchemaMigrationsTable(conn);

    for (migrations) |migration| {
        if (try isMigrationApplied(conn, migration.version)) {
            continue;
        }

        try beginTx(conn);
        errdefer rollbackTx(conn);

        const statements = try applySqlStatements(conn, migration.sql);

        var insert = try conn.query(
            "INSERT INTO schema_migrations (version, applied_at) VALUES ($1, $2)",
            .{ migration.version, std.time.milliTimestamp() },
        );
        insert.deinit();

        try commitTx(conn);
        log.info("migration applied version={d} statements={d}", .{ migration.version, statements });
    }
}

test "parseUrl parses host, port, db, credentials" {
    const alloc = std.testing.allocator;
    const opts = try parseUrl(alloc, "postgres://alice:secret@localhost:5433/usezombiedb");
    defer alloc.free(opts.connect.host.?);
    defer alloc.free(opts.auth.username);
    const password = opts.auth.password.?;
    defer alloc.free(password);
    const database = opts.auth.database.?;
    defer alloc.free(database);

    try std.testing.expectEqualStrings("localhost", opts.connect.host.?);
    try std.testing.expectEqual(@as(u16, 5433), opts.connect.port.?);
    try std.testing.expectEqualStrings("alice", opts.auth.username);
    try std.testing.expectEqualStrings("secret", password);
    try std.testing.expectEqualStrings("usezombiedb", database);
}
