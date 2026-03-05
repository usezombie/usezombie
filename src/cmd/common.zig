const db = @import("../db/pool.zig");

pub fn runCanonicalMigrations(pool: *db.Pool) !void {
    const schema = @import("schema");
    const migrations = [_]db.Migration{
        .{ .version = 1, .sql = schema.initial_sql },
        .{ .version = 2, .sql = schema.vault_sql },
        .{ .version = 3, .sql = schema.request_correlation_sql },
        .{ .version = 4, .sql = schema.side_effect_ledger_sql },
    };
    try db.runMigrations(pool, &migrations);
}
