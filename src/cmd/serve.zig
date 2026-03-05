const std = @import("std");

const db = @import("../db/pool.zig");
const runtime_config = @import("../config/runtime.zig");
const events_bus = @import("../events/bus.zig");
const clerk_auth = @import("../auth/clerk.zig");
const http_server = @import("../http/server.zig");
const http_handler = @import("../http/handler.zig");
const queue_redis = @import("../queue/redis.zig");
const worker = @import("../pipeline/worker.zig");
const git_ops = @import("../git/ops.zig");
const metrics = @import("../observability/metrics.zig");
const obs_log = @import("../observability/logging.zig");
const common = @import("common.zig");

const log = std.log.scoped(.zombied);

var shutdown_requested = std.atomic.Value(bool).init(false);
var stop_server_fn: *const fn () void = http_server.stop;
var stop_server_test_counter: ?*std.atomic.Value(u32) = null;

const SecurityEnvError = error{
    MissingDatabaseUrlApi,
    MissingDatabaseUrlWorker,
    MissingRedisUrlApi,
    MissingRedisUrlWorker,
    SameDatabaseUrlForApiAndWorker,
    SameRedisUrlForApiAndWorker,
    RedisApiTlsRequired,
    RedisWorkerTlsRequired,
};

fn onSignal(sig: i32) callconv(.c) void {
    _ = sig;
    shutdown_requested.store(true, .release);
}

fn installSignalHandlers() void {
    const action = std.posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
    std.posix.sigaction(std.posix.SIG.TERM, &action, null);
}

fn signalWatcher(wstate: *worker.WorkerState) void {
    while (!shutdown_requested.load(.acquire)) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    wstate.running.store(false, .release);
    stop_server_fn();
}

fn validateRoleSeparatedSecurityValues(
    db_api: []const u8,
    db_worker: []const u8,
    redis_api: []const u8,
    redis_worker: []const u8,
) SecurityEnvError!void {
    if (std.mem.trim(u8, db_api, " \t\r\n").len == 0) return SecurityEnvError.MissingDatabaseUrlApi;
    if (std.mem.trim(u8, db_worker, " \t\r\n").len == 0) return SecurityEnvError.MissingDatabaseUrlWorker;
    if (std.mem.trim(u8, redis_api, " \t\r\n").len == 0) return SecurityEnvError.MissingRedisUrlApi;
    if (std.mem.trim(u8, redis_worker, " \t\r\n").len == 0) return SecurityEnvError.MissingRedisUrlWorker;

    if (std.mem.eql(u8, db_api, db_worker)) return SecurityEnvError.SameDatabaseUrlForApiAndWorker;
    if (std.mem.eql(u8, redis_api, redis_worker)) return SecurityEnvError.SameRedisUrlForApiAndWorker;
    if (!std.mem.startsWith(u8, redis_api, "rediss://")) return SecurityEnvError.RedisApiTlsRequired;
    if (!std.mem.startsWith(u8, redis_worker, "rediss://")) return SecurityEnvError.RedisWorkerTlsRequired;
}

fn enforceRoleSeparatedSecurityEnv(alloc: std.mem.Allocator) SecurityEnvError!void {
    const db_api = std.process.getEnvVarOwned(alloc, db.roleEnvVarName(.api)) catch
        return SecurityEnvError.MissingDatabaseUrlApi;
    defer alloc.free(db_api);
    const db_worker = std.process.getEnvVarOwned(alloc, db.roleEnvVarName(.worker)) catch
        return SecurityEnvError.MissingDatabaseUrlWorker;
    defer alloc.free(db_worker);
    if (std.mem.eql(u8, db_api, db_worker)) return SecurityEnvError.SameDatabaseUrlForApiAndWorker;

    const redis_api = std.process.getEnvVarOwned(alloc, queue_redis.roleEnvVarName(.api)) catch
        return SecurityEnvError.MissingRedisUrlApi;
    defer alloc.free(redis_api);
    const redis_worker = std.process.getEnvVarOwned(alloc, queue_redis.roleEnvVarName(.worker)) catch
        return SecurityEnvError.MissingRedisUrlWorker;
    defer alloc.free(redis_worker);
    try validateRoleSeparatedSecurityValues(db_api, db_worker, redis_api, redis_worker);
}

pub fn run(alloc: std.mem.Allocator) !void {
    log.info("starting zombied serve", .{});

    enforceRoleSeparatedSecurityEnv(alloc) catch |err| {
        switch (err) {
            SecurityEnvError.MissingDatabaseUrlApi => std.debug.print("fatal: DATABASE_URL_API not set\n", .{}),
            SecurityEnvError.MissingDatabaseUrlWorker => std.debug.print("fatal: DATABASE_URL_WORKER not set\n", .{}),
            SecurityEnvError.MissingRedisUrlApi => std.debug.print("fatal: REDIS_URL_API not set\n", .{}),
            SecurityEnvError.MissingRedisUrlWorker => std.debug.print("fatal: REDIS_URL_WORKER not set\n", .{}),
            SecurityEnvError.SameDatabaseUrlForApiAndWorker => std.debug.print("fatal: DATABASE_URL_API and DATABASE_URL_WORKER must differ (role separation required)\n", .{}),
            SecurityEnvError.SameRedisUrlForApiAndWorker => std.debug.print("fatal: REDIS_URL_API and REDIS_URL_WORKER must differ (ACL role separation required)\n", .{}),
            SecurityEnvError.RedisApiTlsRequired => std.debug.print("fatal: REDIS_URL_API must use rediss:// (TLS required)\n", .{}),
            SecurityEnvError.RedisWorkerTlsRequired => std.debug.print("fatal: REDIS_URL_WORKER must use rediss:// (TLS required)\n", .{}),
        }
        std.process.exit(1);
    };

    var serve_cfg = runtime_config.ServeConfig.load(alloc) catch |err| {
        switch (err) {
            runtime_config.ValidationError.MissingApiKey,
            runtime_config.ValidationError.InvalidApiKeyList,
            runtime_config.ValidationError.MissingClerkJwksUrl,
            runtime_config.ValidationError.MissingEncryptionMasterKey,
            runtime_config.ValidationError.InvalidEncryptionMasterKey,
            runtime_config.ValidationError.MissingGitHubAppId,
            runtime_config.ValidationError.MissingGitHubAppPrivateKey,
            runtime_config.ValidationError.InvalidPort,
            runtime_config.ValidationError.InvalidMaxAttempts,
            runtime_config.ValidationError.InvalidWorkerConcurrency,
            runtime_config.ValidationError.InvalidRunTimeoutMs,
            runtime_config.ValidationError.InvalidRateLimitCapacity,
            runtime_config.ValidationError.InvalidRateLimitRefillPerSec,
            runtime_config.ValidationError.InvalidReadyMaxQueueDepth,
            runtime_config.ValidationError.InvalidReadyMaxQueueAgeMs,
            => runtime_config.ServeConfig.printValidationError(err),
            else => std.debug.print("fatal: failed to load runtime config: {}\n", .{err}),
        }
        std.process.exit(1);
    };
    defer serve_cfg.deinit();

    const api_pool = db.initFromEnvForRole(alloc, .api) catch |err| {
        std.debug.print("fatal: api database init failed: {}\n", .{err});
        std.process.exit(1);
    };
    defer api_pool.deinit();

    const worker_pool = db.initFromEnvForRole(alloc, .worker) catch |err| {
        std.debug.print("fatal: worker database init failed: {}\n", .{err});
        std.process.exit(1);
    };
    defer worker_pool.deinit();

    var api_queue = queue_redis.Client.connectFromEnv(alloc, .api) catch |err| {
        std.debug.print("fatal: redis queue init failed for api role: {}\n", .{err});
        std.process.exit(1);
    };
    defer api_queue.deinit();
    api_queue.ensureConsumerGroup() catch |err| {
        std.debug.print("fatal: redis queue group init failed: {}\n", .{err});
        std.process.exit(1);
    };

    var worker_queue_check = queue_redis.Client.connectFromEnv(alloc, .worker) catch |err| {
        std.debug.print("fatal: redis queue init failed for worker role: {}\n", .{err});
        std.process.exit(1);
    };
    defer worker_queue_check.deinit();
    worker_queue_check.ensureConsumerGroup() catch |err| {
        std.debug.print("fatal: redis queue group init failed for worker role: {}\n", .{err});
        std.process.exit(1);
    };

    const migrate_on_start = common.migrateOnStartEnabledFromEnv(alloc) catch |err| {
        std.debug.print(
            "fatal: invalid MIGRATE_ON_START value: {} (use 0/1/false/true)\n",
            .{err},
        );
        std.process.exit(1);
    };

    common.enforceServeMigrationSafety(api_pool, migrate_on_start) catch |err| {
        switch (err) {
            common.MigrationGuardError.MigrationPending => std.debug.print(
                "fatal: pending schema migrations; run `zombied migrate` first or set MIGRATE_ON_START=1 for controlled auto-migrate\n",
                .{},
            ),
            common.MigrationGuardError.MigrationFailed => std.debug.print(
                "fatal: unsafe migration failure state detected; inspect schema_migration_failures and rerun `zombied migrate` before serve restart\n",
                .{},
            ),
            common.MigrationGuardError.MigrationSchemaAhead => std.debug.print(
                "fatal: database schema version is ahead of this binary; deploy matching binary before serve startup\n",
                .{},
            ),
            common.MigrationGuardError.MigrationLockUnavailable => std.debug.print(
                "fatal: migration lock unavailable (another node migrating); restart serve after migration finishes\n",
                .{},
            ),
            else => std.debug.print("fatal: schema migration safety check failed: {}\n", .{err}),
        }
        std.process.exit(1);
    };

    std.fs.makeDirAbsolute(serve_cfg.cache_root) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => obs_log.logWarnErr(.zombied, err, "could not create cache root {s}", .{serve_cfg.cache_root}),
    };
    {
        const stats = git_ops.cleanupRuntimeArtifacts(alloc, serve_cfg.cache_root, "/tmp");
        log.info(
            "runtime cleanup startup removed_worktrees={d} failed_worktrees={d} pruned_bare={d} failed_prunes={d}",
            .{ stats.removed_worktrees, stats.failed_worktree_removals, stats.pruned_bare_repos, stats.failed_bare_prunes },
        );
    }

    var wstate = worker.WorkerState.init();

    var ctx = http_handler.Context{
        .pool = api_pool,
        .queue = &api_queue,
        .alloc = alloc,
        .api_keys = serve_cfg.api_keys,
        .clerk = null,
        .worker_state = &wstate,
        .api_in_flight_requests = std.atomic.Value(u32).init(0),
        .api_max_in_flight_requests = serve_cfg.api_max_in_flight_requests,
        .ready_max_queue_depth = serve_cfg.ready_max_queue_depth,
        .ready_max_queue_age_ms = serve_cfg.ready_max_queue_age_ms,
    };
    metrics.setApiInFlightRequests(0);

    var clerk = if (serve_cfg.clerk_enabled) clerk_auth.Verifier.init(alloc, .{
        .jwks_url = serve_cfg.clerk_jwks_url orelse "",
        .issuer = serve_cfg.clerk_issuer,
        .audience = serve_cfg.clerk_audience,
    }) else null;
    defer if (clerk) |*v| v.deinit();
    if (clerk) |*v| ctx.clerk = v;

    const wcfg = worker.WorkerConfig{
        .pool = worker_pool,
        .config_dir = serve_cfg.config_dir,
        .cache_root = serve_cfg.cache_root,
        .github_app_id = serve_cfg.github_app_id,
        .github_app_private_key = serve_cfg.github_app_private_key,
        .pipeline_profile_path = serve_cfg.pipeline_profile_path,
        .max_attempts = serve_cfg.max_attempts,
        .run_timeout_ms = serve_cfg.run_timeout_ms,
        .rate_limit_capacity = serve_cfg.rate_limit_capacity,
        .rate_limit_refill_per_sec = serve_cfg.rate_limit_refill_per_sec,
    };

    shutdown_requested.store(false, .release);
    installSignalHandlers();

    var event_bus = events_bus.Bus.init();
    events_bus.install(&event_bus);
    defer events_bus.uninstall();

    const worker_count: usize = @max(@as(usize, @intCast(serve_cfg.worker_concurrency)), 1);
    var worker_threads = try alloc.alloc(std.Thread, worker_count);
    defer alloc.free(worker_threads);
    var spawned_workers: usize = 0;
    var signal_thread: ?std.Thread = null;
    var event_thread: ?std.Thread = null;
    errdefer {
        wstate.running.store(false, .release);
        shutdown_requested.store(true, .release);
        event_bus.stop();
        if (signal_thread) |*t| t.join();
        if (event_thread) |*t| t.join();
        while (spawned_workers > 0) {
            spawned_workers -= 1;
            worker_threads[spawned_workers].join();
        }
    }
    for (worker_threads) |*t| {
        t.* = try std.Thread.spawn(.{}, worker.workerLoop, .{ wcfg, &wstate });
        spawned_workers += 1;
    }
    signal_thread = try std.Thread.spawn(.{}, signalWatcher, .{&wstate});
    event_thread = try std.Thread.spawn(.{}, events_bus.runThread, .{&event_bus});

    log.info("HTTP server starting port={d} worker_concurrency={d} api_threads={d} api_workers={d} api_max_clients={d} api_max_in_flight={d}", .{
        serve_cfg.port,
        worker_count,
        serve_cfg.api_http_threads,
        serve_cfg.api_http_workers,
        serve_cfg.api_max_clients,
        serve_cfg.api_max_in_flight_requests,
    });
    http_server.serve(&ctx, .{
        .port = serve_cfg.port,
        .threads = serve_cfg.api_http_threads,
        .workers = serve_cfg.api_http_workers,
        .max_clients = @intCast(serve_cfg.api_max_clients),
    }) catch |err| {
        obs_log.logErr(.zombied, err, "http server exited with error", .{});
    };

    wstate.running.store(false, .release);
    shutdown_requested.store(true, .release);
    event_bus.stop();
    for (worker_threads) |*t| t.join();
    if (signal_thread) |*t| t.join();
    if (event_thread) |*t| t.join();
    {
        const stats = git_ops.cleanupRuntimeArtifacts(alloc, serve_cfg.cache_root, "/tmp");
        log.info(
            "runtime cleanup shutdown removed_worktrees={d} failed_worktrees={d} pruned_bare={d} failed_prunes={d}",
            .{ stats.removed_worktrees, stats.failed_worktree_removals, stats.pruned_bare_repos, stats.failed_bare_prunes },
        );
    }
}

fn testStopServerHook() void {
    if (stop_server_test_counter) |counter| {
        _ = counter.fetchAdd(1, .acq_rel);
    }
}

test "integration: signalWatcher stops worker and invokes server stop hook" {
    var ws = worker.WorkerState.init();
    ws.running.store(true, .release);
    shutdown_requested.store(false, .release);

    var stop_calls = std.atomic.Value(u32).init(0);
    stop_server_test_counter = &stop_calls;
    stop_server_fn = testStopServerHook;
    defer {
        stop_server_fn = http_server.stop;
        stop_server_test_counter = null;
        shutdown_requested.store(false, .release);
    }

    const thread = try std.Thread.spawn(.{}, signalWatcher, .{&ws});
    std.Thread.sleep(15 * std.time.ns_per_ms);
    shutdown_requested.store(true, .release);
    thread.join();

    try std.testing.expect(!ws.running.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), stop_calls.load(.acquire));
}

test "integration: migrate_on_start env parser accepts deterministic values" {
    const alloc = std.testing.allocator;
    try std.posix.setenv("MIGRATE_ON_START", "1", true);
    try std.testing.expect(try common.migrateOnStartEnabledFromEnv(alloc));
    try std.posix.setenv("MIGRATE_ON_START", "0", true);
    try std.testing.expect(!try common.migrateOnStartEnabledFromEnv(alloc));
}

test "enforceRoleSeparatedSecurityEnv requires split role URLs and redis TLS" {
    try std.testing.expectError(SecurityEnvError.MissingDatabaseUrlApi, validateRoleSeparatedSecurityValues(
        "",
        "postgres://worker:pw@db.local:5432/worker",
        "rediss://api:pw@cache.local:6379",
        "rediss://worker:pw@cache.local:6379",
    ));

    try std.testing.expectError(SecurityEnvError.SameDatabaseUrlForApiAndWorker, validateRoleSeparatedSecurityValues(
        "postgres://shared:pw@db.local:5432/app",
        "postgres://shared:pw@db.local:5432/app",
        "rediss://api:pw@cache.local:6379",
        "rediss://worker:pw@cache.local:6379",
    ));

    try std.testing.expectError(SecurityEnvError.RedisApiTlsRequired, validateRoleSeparatedSecurityValues(
        "postgres://api:pw@db.local:5432/app",
        "postgres://worker:pw@db.local:5432/worker",
        "redis://api:pw@cache.local:6379",
        "rediss://worker:pw@cache.local:6379",
    ));

    try validateRoleSeparatedSecurityValues(
        "postgres://api:pw@db.local:5432/app",
        "postgres://worker:pw@db.local:5432/worker",
        "rediss://api:pw@cache.local:6379",
        "rediss://worker:pw@cache.local:6379",
    );
}
