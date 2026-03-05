//! Runtime config loader/validator for zombied serve mode.
//! Centralizes env parsing and validation in one place.

const std = @import("std");

pub const ValidationError = error{
    MissingApiKey,
    InvalidApiKeyList,
    MissingEncryptionMasterKey,
    InvalidEncryptionMasterKey,
    MissingGitHubAppId,
    MissingGitHubAppPrivateKey,
    InvalidPort,
    InvalidMaxAttempts,
    InvalidWorkerConcurrency,
    InvalidRateLimitCapacity,
    InvalidRateLimitRefillPerSec,
};

pub const ServeConfig = struct {
    port: u16,
    api_keys: []u8,
    cache_root: []u8,
    github_app_id: []u8,
    github_app_private_key: []u8,
    config_dir: []u8,
    max_attempts: u32,
    worker_concurrency: u32,
    rate_limit_capacity: u32,
    rate_limit_refill_per_sec: f64,
    encryption_master_key: []u8,

    alloc: std.mem.Allocator,

    pub fn load(alloc: std.mem.Allocator) !ServeConfig {
        const port = try parseU16Env(alloc, "PORT", 3000, ValidationError.InvalidPort);
        const max_attempts = try parseU32Env(alloc, "DEFAULT_MAX_ATTEMPTS", 3, ValidationError.InvalidMaxAttempts);
        const worker_concurrency = try parseU32Env(alloc, "WORKER_CONCURRENCY", 1, ValidationError.InvalidWorkerConcurrency);
        const rate_limit_capacity = try parseU32Env(alloc, "RATE_LIMIT_CAPACITY", 30, ValidationError.InvalidRateLimitCapacity);
        const rate_limit_refill_per_sec = try parseF64Env(alloc, "RATE_LIMIT_REFILL_PER_SEC", 5.0, ValidationError.InvalidRateLimitRefillPerSec);

        if (max_attempts == 0) return ValidationError.InvalidMaxAttempts;
        if (worker_concurrency == 0) return ValidationError.InvalidWorkerConcurrency;
        if (rate_limit_capacity == 0) return ValidationError.InvalidRateLimitCapacity;
        if (!(rate_limit_refill_per_sec > 0)) return ValidationError.InvalidRateLimitRefillPerSec;

        const api_keys = try requiredEnvOwned(alloc, "API_KEY", ValidationError.MissingApiKey);
        errdefer alloc.free(api_keys);
        if (!hasUsableApiKey(api_keys)) return ValidationError.InvalidApiKeyList;

        const encryption_master_key = try requiredEnvOwned(alloc, "ENCRYPTION_MASTER_KEY", ValidationError.MissingEncryptionMasterKey);
        errdefer alloc.free(encryption_master_key);
        if (encryption_master_key.len != 64 or !isHexString(encryption_master_key)) {
            return ValidationError.InvalidEncryptionMasterKey;
        }

        const github_app_id = try requiredEnvOwned(alloc, "GITHUB_APP_ID", ValidationError.MissingGitHubAppId);
        errdefer alloc.free(github_app_id);
        if (github_app_id.len == 0) return ValidationError.MissingGitHubAppId;

        const github_app_private_key = try requiredEnvOwned(alloc, "GITHUB_APP_PRIVATE_KEY", ValidationError.MissingGitHubAppPrivateKey);
        errdefer alloc.free(github_app_private_key);
        if (github_app_private_key.len == 0) return ValidationError.MissingGitHubAppPrivateKey;

        const cache_root = try envOrDefaultOwned(alloc, "GIT_CACHE_ROOT", "/tmp/zombie-git-cache");
        errdefer alloc.free(cache_root);
        const config_dir = try envOrDefaultOwned(alloc, "AGENT_CONFIG_DIR", "./config");
        errdefer alloc.free(config_dir);

        return .{
            .port = port,
            .api_keys = api_keys,
            .cache_root = cache_root,
            .github_app_id = github_app_id,
            .github_app_private_key = github_app_private_key,
            .config_dir = config_dir,
            .max_attempts = max_attempts,
            .worker_concurrency = worker_concurrency,
            .rate_limit_capacity = rate_limit_capacity,
            .rate_limit_refill_per_sec = rate_limit_refill_per_sec,
            .encryption_master_key = encryption_master_key,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *ServeConfig) void {
        self.alloc.free(self.api_keys);
        self.alloc.free(self.cache_root);
        self.alloc.free(self.github_app_id);
        self.alloc.free(self.github_app_private_key);
        self.alloc.free(self.config_dir);
        self.alloc.free(self.encryption_master_key);
    }

    pub fn printValidationError(err: ValidationError) void {
        switch (err) {
            ValidationError.MissingApiKey => std.debug.print("fatal: API_KEY not set\n", .{}),
            ValidationError.InvalidApiKeyList => std.debug.print("fatal: API_KEY has no usable keys\n", .{}),
            ValidationError.MissingEncryptionMasterKey => std.debug.print("fatal: ENCRYPTION_MASTER_KEY not set\n", .{}),
            ValidationError.InvalidEncryptionMasterKey => std.debug.print("fatal: ENCRYPTION_MASTER_KEY must be 64 hex chars\n", .{}),
            ValidationError.MissingGitHubAppId => std.debug.print("fatal: GITHUB_APP_ID not set\n", .{}),
            ValidationError.MissingGitHubAppPrivateKey => std.debug.print("fatal: GITHUB_APP_PRIVATE_KEY not set\n", .{}),
            ValidationError.InvalidPort => std.debug.print("fatal: invalid PORT value\n", .{}),
            ValidationError.InvalidMaxAttempts => std.debug.print("fatal: invalid DEFAULT_MAX_ATTEMPTS value\n", .{}),
            ValidationError.InvalidWorkerConcurrency => std.debug.print("fatal: invalid WORKER_CONCURRENCY value\n", .{}),
            ValidationError.InvalidRateLimitCapacity => std.debug.print("fatal: invalid RATE_LIMIT_CAPACITY value\n", .{}),
            ValidationError.InvalidRateLimitRefillPerSec => std.debug.print("fatal: invalid RATE_LIMIT_REFILL_PER_SEC value\n", .{}),
        }
    }
};

fn requiredEnvOwned(alloc: std.mem.Allocator, name: []const u8, missing_error: ValidationError) ![]u8 {
    return std.process.getEnvVarOwned(alloc, name) catch missing_error;
}

fn envOrDefaultOwned(alloc: std.mem.Allocator, name: []const u8, default_value: []const u8) ![]u8 {
    return std.process.getEnvVarOwned(alloc, name) catch try alloc.dupe(u8, default_value);
}

fn parseU16Env(alloc: std.mem.Allocator, name: []const u8, default_value: u16, invalid_error: ValidationError) !u16 {
    const raw = std.process.getEnvVarOwned(alloc, name) catch return default_value;
    defer alloc.free(raw);
    return std.fmt.parseInt(u16, raw, 10) catch invalid_error;
}

fn parseU32Env(alloc: std.mem.Allocator, name: []const u8, default_value: u32, invalid_error: ValidationError) !u32 {
    const raw = std.process.getEnvVarOwned(alloc, name) catch return default_value;
    defer alloc.free(raw);
    return std.fmt.parseInt(u32, raw, 10) catch invalid_error;
}

fn parseF64Env(alloc: std.mem.Allocator, name: []const u8, default_value: f64, invalid_error: ValidationError) !f64 {
    const raw = std.process.getEnvVarOwned(alloc, name) catch return default_value;
    defer alloc.free(raw);
    return std.fmt.parseFloat(f64, raw) catch invalid_error;
}

fn isHexString(s: []const u8) bool {
    for (s) |ch| {
        if (!std.ascii.isHex(ch)) return false;
    }
    return true;
}

fn hasUsableApiKey(list: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, list, ',');
    while (it.next()) |candidate_raw| {
        if (std.mem.trim(u8, candidate_raw, " \t").len > 0) return true;
    }
    return false;
}

test "hasUsableApiKey validates rotation list" {
    try std.testing.expect(hasUsableApiKey("key1,key2"));
    try std.testing.expect(hasUsableApiKey(" key1 "));
    try std.testing.expect(!hasUsableApiKey(""));
    try std.testing.expect(!hasUsableApiKey(" , , "));
}

test "isHexString validates encryption key format" {
    try std.testing.expect(isHexString("abcdef0123"));
    try std.testing.expect(!isHexString("abcxyz"));
}
