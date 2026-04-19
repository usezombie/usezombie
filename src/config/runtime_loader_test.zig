// Integration tests for ServeConfig.load via the runtime façade.
//
// Each test sets a deterministic env-var slate, calls load(), and verifies
// the populated ServeConfig matches expectation. setTestEnv/unsetTestEnv
// keep the harness shared. test "..." names are deliberately
// milestone-free (RULE TST-NAM).

const std = @import("std");
const oidc = @import("../auth/oidc.zig");
const runtime = @import("runtime.zig");

const ServeConfig = runtime.ServeConfig;
const ValidationError = runtime.ValidationError;

const test_encryption_master_key = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

fn setTestEnv(env_pairs: []const [2][]const u8) !void {
    for (env_pairs) |entry| try std.posix.setenv(entry[0], entry[1], true);
}

fn unsetTestEnv(env_pairs: []const [2][]const u8) void {
    for (env_pairs) |entry| std.posix.unsetenv(entry[0]);
}

test "ServeConfig.load accepts custom provider" {
    const env_pairs = [_][2][]const u8{
        .{ "OIDC_JWKS_URL", "https://idp.example.com/.well-known/jwks.json" },
        .{ "OIDC_PROVIDER", "custom" },
        .{ "ENCRYPTION_MASTER_KEY", test_encryption_master_key },
    };
    try setTestEnv(&env_pairs);
    defer unsetTestEnv(&env_pairs);

    var cfg = try ServeConfig.load(std.testing.allocator);
    defer cfg.deinit();

    try std.testing.expect(cfg.oidc_enabled);
    try std.testing.expectEqual(oidc.Provider.custom, cfg.oidc_provider);
}

test "ServeConfig.load rejects invalid provider deterministically" {
    const env_pairs = [_][2][]const u8{
        .{ "OIDC_JWKS_URL", "https://idp.example.com/.well-known/jwks.json" },
        .{ "OIDC_PROVIDER", "not-real" },
        .{ "ENCRYPTION_MASTER_KEY", test_encryption_master_key },
    };
    try setTestEnv(&env_pairs);
    defer unsetTestEnv(&env_pairs);

    try std.testing.expectError(ValidationError.InvalidOidcProvider, ServeConfig.load(std.testing.allocator));
}

test "ServeConfig.load rejects provider without required OIDC_JWKS_URL" {
    const env_pairs = [_][2][]const u8{
        .{ "OIDC_PROVIDER", "custom" },
        .{ "ENCRYPTION_MASTER_KEY", test_encryption_master_key },
    };
    try setTestEnv(&env_pairs);
    defer unsetTestEnv(&env_pairs);

    try std.testing.expectError(ValidationError.MissingOidcJwksUrl, ServeConfig.load(std.testing.allocator));
}

test "ServeConfig.load rejects empty OIDC_JWKS_URL" {
    const env_pairs = [_][2][]const u8{
        .{ "OIDC_JWKS_URL", "" },
        .{ "ENCRYPTION_MASTER_KEY", test_encryption_master_key },
    };
    try setTestEnv(&env_pairs);
    defer unsetTestEnv(&env_pairs);

    try std.testing.expectError(ValidationError.MissingOidcJwksUrl, ServeConfig.load(std.testing.allocator));
}

test "ServeConfig.load accepts api key only auth mode" {
    const env_pairs = [_][2][]const u8{
        .{ "API_KEY", "dev-key" },
        .{ "ENCRYPTION_MASTER_KEY", test_encryption_master_key },
    };
    try setTestEnv(&env_pairs);
    defer unsetTestEnv(&env_pairs);

    var cfg = try ServeConfig.load(std.testing.allocator);
    defer cfg.deinit();

    try std.testing.expect(!cfg.oidc_enabled);
    try std.testing.expectEqualStrings("dev-key", cfg.api_keys);
}

test "ServeConfig.load accepts oidc plus api key auth mode" {
    const env_pairs = [_][2][]const u8{
        .{ "OIDC_JWKS_URL", "https://idp.example.com/.well-known/jwks.json" },
        .{ "OIDC_PROVIDER", "custom" },
        .{ "API_KEY", "issued-key" },
        .{ "ENCRYPTION_MASTER_KEY", test_encryption_master_key },
    };
    try setTestEnv(&env_pairs);
    defer unsetTestEnv(&env_pairs);

    var cfg = try ServeConfig.load(std.testing.allocator);
    defer cfg.deinit();

    try std.testing.expect(cfg.oidc_enabled);
    try std.testing.expectEqual(oidc.Provider.custom, cfg.oidc_provider);
    try std.testing.expectEqualStrings("issued-key", cfg.api_keys);
}

test "ServeConfig.load rejects empty api key when explicitly configured with oidc" {
    const env_pairs = [_][2][]const u8{
        .{ "OIDC_JWKS_URL", "https://idp.example.com/.well-known/jwks.json" },
        .{ "API_KEY", "   " },
        .{ "ENCRYPTION_MASTER_KEY", test_encryption_master_key },
    };
    try setTestEnv(&env_pairs);
    defer unsetTestEnv(&env_pairs);

    try std.testing.expectError(ValidationError.InvalidApiKeyList, ServeConfig.load(std.testing.allocator));
}

test "ServeConfig.load applies default port" {
    const env_pairs = [_][2][]const u8{
        .{ "API_KEY", "dev-key" },
        .{ "ENCRYPTION_MASTER_KEY", test_encryption_master_key },
    };
    try setTestEnv(&env_pairs);
    defer unsetTestEnv(&env_pairs);

    var cfg = try ServeConfig.load(std.testing.allocator);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u16, 3000), cfg.port);
    try std.testing.expectEqual(@as(i16, 1), cfg.api_http_threads);
    try std.testing.expectEqual(@as(u32, 1024), cfg.api_max_clients);
    try std.testing.expectEqualStrings("/tmp/zombie-git-cache", cfg.cache_root);
    try std.testing.expectEqual(@as(u32, 1), cfg.active_kek_version);
}

test "ServeConfig.load rejects short encryption key" {
    const env_pairs = [_][2][]const u8{
        .{ "API_KEY", "dev-key" },
        .{ "ENCRYPTION_MASTER_KEY", "tooshort" },
    };
    try setTestEnv(&env_pairs);
    defer unsetTestEnv(&env_pairs);

    try std.testing.expectError(ValidationError.InvalidEncryptionMasterKey, ServeConfig.load(std.testing.allocator));
}

test "ServeConfig.load rejects non-hex encryption key" {
    const env_pairs = [_][2][]const u8{
        .{ "API_KEY", "dev-key" },
        .{ "ENCRYPTION_MASTER_KEY", "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg" },
    };
    try setTestEnv(&env_pairs);
    defer unsetTestEnv(&env_pairs);

    try std.testing.expectError(ValidationError.InvalidEncryptionMasterKey, ServeConfig.load(std.testing.allocator));
}

test "ServeConfig.load rejects KEK_VERSION=2 without v2 key" {
    const env_pairs = [_][2][]const u8{
        .{ "API_KEY", "dev-key" },
        .{ "ENCRYPTION_MASTER_KEY", test_encryption_master_key },
        .{ "KEK_VERSION", "2" },
    };
    try setTestEnv(&env_pairs);
    defer unsetTestEnv(&env_pairs);

    try std.testing.expectError(ValidationError.MissingEncryptionMasterKeyV2, ServeConfig.load(std.testing.allocator));
}

test "ServeConfig.load accepts KEK_VERSION=2 with valid v2 key" {
    const v2_key = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const env_pairs = [_][2][]const u8{
        .{ "API_KEY", "dev-key" },
        .{ "ENCRYPTION_MASTER_KEY", test_encryption_master_key },
        .{ "KEK_VERSION", "2" },
        .{ "ENCRYPTION_MASTER_KEY_V2", v2_key },
    };
    try setTestEnv(&env_pairs);
    defer unsetTestEnv(&env_pairs);

    var cfg = try ServeConfig.load(std.testing.allocator);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u32, 2), cfg.active_kek_version);
    try std.testing.expectEqualStrings(v2_key, cfg.encryption_master_key_v2.?);
}

test "ServeConfig.load rejects KEK_VERSION=0" {
    const env_pairs = [_][2][]const u8{
        .{ "API_KEY", "dev-key" },
        .{ "ENCRYPTION_MASTER_KEY", test_encryption_master_key },
        .{ "KEK_VERSION", "0" },
    };
    try setTestEnv(&env_pairs);
    defer unsetTestEnv(&env_pairs);

    try std.testing.expectError(ValidationError.InvalidKekVersion, ServeConfig.load(std.testing.allocator));
}

test "ServeConfig.load rejects negative READY_MAX_QUEUE_DEPTH" {
    const env_pairs = [_][2][]const u8{
        .{ "API_KEY", "dev-key" },
        .{ "ENCRYPTION_MASTER_KEY", test_encryption_master_key },
        .{ "READY_MAX_QUEUE_DEPTH", "-5" },
    };
    try setTestEnv(&env_pairs);
    defer unsetTestEnv(&env_pairs);

    try std.testing.expectError(ValidationError.InvalidReadyMaxQueueDepth, ServeConfig.load(std.testing.allocator));
}
