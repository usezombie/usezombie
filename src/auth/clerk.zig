//! Clerk JWT verification using JWKS (RS256).

const std = @import("std");

pub const VerifyError = error{
    MissingAuthorization,
    InvalidAuthorization,
    TokenMalformed,
    UnsupportedAlgorithm,
    MissingKeyId,
    MissingSubject,
    MissingIssuer,
    MissingExpiry,
    TokenExpired,
    IssuerMismatch,
    AudienceMismatch,
    JwksFetchFailed,
    JwksParseFailed,
    JwkNotFound,
    SignatureInvalid,
};

pub const Principal = struct {
    subject: []u8,
    issuer: []u8,
    tenant_id: ?[]u8,
    org_id: ?[]u8,
};

pub const Config = struct {
    jwks_url: []const u8,
    issuer: ?[]const u8 = null,
    audience: ?[]const u8 = null,
    inline_jwks_json: ?[]const u8 = null,
    cache_ttl_ms: i64 = 6 * 60 * 60 * 1000,
};

const JwtParts = struct {
    header_b64: []const u8,
    payload_b64: []const u8,
    signature_b64: []const u8,
};

const Header = struct {
    alg: []const u8,
    kid: ?[]const u8 = null,
};

const JwkDoc = struct {
    keys: []const struct {
        kid: ?[]const u8 = null,
        kty: ?[]const u8 = null,
        n: ?[]const u8 = null,
        e: ?[]const u8 = null,
    },
};

const JwkKey = struct {
    kid: []u8,
    modulus: []u8,
    exponent: []u8,
};

const JwksCache = struct {
    fetched_at_ms: i64,
    keys: []JwkKey,

    fn deinit(self: *JwksCache, alloc: std.mem.Allocator) void {
        for (self.keys) |key| {
            alloc.free(key.kid);
            alloc.free(key.modulus);
            alloc.free(key.exponent);
        }
        alloc.free(self.keys);
    }
};

pub const Verifier = struct {
    alloc: std.mem.Allocator,
    jwks_url: []u8,
    issuer: ?[]u8,
    audience: ?[]u8,
    inline_jwks_json: ?[]u8,
    cache_ttl_ms: i64,
    mutex: std.Thread.Mutex = .{},
    cache: ?JwksCache = null,

    pub fn init(alloc: std.mem.Allocator, cfg: Config) Verifier {
        return .{
            .alloc = alloc,
            .jwks_url = alloc.dupe(u8, cfg.jwks_url) catch @panic("oom"),
            .issuer = if (cfg.issuer) |v| alloc.dupe(u8, v) catch @panic("oom") else null,
            .audience = if (cfg.audience) |v| alloc.dupe(u8, v) catch @panic("oom") else null,
            .inline_jwks_json = if (cfg.inline_jwks_json) |v| alloc.dupe(u8, v) catch @panic("oom") else null,
            .cache_ttl_ms = cfg.cache_ttl_ms,
        };
    }

    pub fn deinit(self: *Verifier) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.cache) |*cache| cache.deinit(self.alloc);
        self.cache = null;
        self.alloc.free(self.jwks_url);
        if (self.issuer) |v| self.alloc.free(v);
        if (self.audience) |v| self.alloc.free(v);
        if (self.inline_jwks_json) |v| self.alloc.free(v);
    }

    pub fn verifyAuthorization(self: *Verifier, alloc: std.mem.Allocator, authorization: []const u8) !Principal {
        const token = extractBearerToken(authorization) catch return VerifyError.InvalidAuthorization;
        const parts = splitJwt(token) catch return VerifyError.TokenMalformed;

        const header_raw = try decodeBase64UrlOwned(alloc, parts.header_b64);
        defer alloc.free(header_raw);
        const payload_raw = try decodeBase64UrlOwned(alloc, parts.payload_b64);
        defer alloc.free(payload_raw);
        const signature = try decodeBase64UrlOwned(alloc, parts.signature_b64);
        defer alloc.free(signature);

        const header = try std.json.parseFromSlice(Header, alloc, header_raw, .{});
        defer header.deinit();
        if (!std.mem.eql(u8, header.value.alg, "RS256")) return VerifyError.UnsupportedAlgorithm;
        const kid = header.value.kid orelse return VerifyError.MissingKeyId;

        const key = try self.lookupKey(alloc, kid);
        defer {
            alloc.free(key.kid);
            alloc.free(key.modulus);
            alloc.free(key.exponent);
        }

        const signing_input = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ parts.header_b64, parts.payload_b64 });
        defer alloc.free(signing_input);

        try verifyRs256(signing_input, signature, key.modulus, key.exponent);

        return try parseClaims(alloc, payload_raw, self.issuer, self.audience);
    }

    pub fn checkJwksConnectivity(self: *Verifier) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = try self.refreshCacheLocked();
    }

    fn lookupKey(self: *Verifier, alloc: std.mem.Allocator, kid: []const u8) !JwkKey {
        self.mutex.lock();
        defer self.mutex.unlock();
        const cache = try self.refreshCacheLocked();

        for (cache.keys) |key| {
            if (std.mem.eql(u8, key.kid, kid)) {
                return .{
                    .kid = try alloc.dupe(u8, key.kid),
                    .modulus = try alloc.dupe(u8, key.modulus),
                    .exponent = try alloc.dupe(u8, key.exponent),
                };
            }
        }

        return VerifyError.JwkNotFound;
    }

    fn refreshCacheLocked(self: *Verifier) !*JwksCache {
        const now_ms = std.time.milliTimestamp();
        if (self.cache) |*cache| {
            if (now_ms - cache.fetched_at_ms <= self.cache_ttl_ms) return cache;
            cache.deinit(self.alloc);
            self.cache = null;
        }

        const raw = try self.fetchJwksJson();
        defer self.alloc.free(raw);

        var parsed = try parseJwks(self.alloc, raw);
        parsed.fetched_at_ms = now_ms;
        self.cache = parsed;
        return &self.cache.?;
    }

    fn fetchJwksJson(self: *Verifier) ![]u8 {
        if (self.inline_jwks_json) |raw| return self.alloc.dupe(u8, raw);

        if (std.process.getEnvVarOwned(self.alloc, "CLERK_JWKS_JSON")) |raw| {
            return raw;
        } else |_| {}

        if (self.jwks_url.len == 0) return VerifyError.JwksFetchFailed;

        var client: std.http.Client = .{ .allocator = self.alloc };
        defer client.deinit();

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.alloc);
        var writer = body.writer(self.alloc);

        const result = client.fetch(.{
            .location = .{ .url = self.jwks_url },
            .method = .GET,
            .response_writer = &writer.interface,
        }) catch return VerifyError.JwksFetchFailed;

        if (result.status != .ok) return VerifyError.JwksFetchFailed;
        return body.toOwnedSlice(self.alloc);
    }
};

fn extractBearerToken(authorization: []const u8) ![]const u8 {
    const prefix = "Bearer ";
    if (!std.mem.startsWith(u8, authorization, prefix)) return VerifyError.InvalidAuthorization;
    const token = std.mem.trim(u8, authorization[prefix.len..], " \t");
    if (token.len == 0) return VerifyError.InvalidAuthorization;
    return token;
}

fn splitJwt(token: []const u8) !JwtParts {
    var split = std.mem.splitScalar(u8, token, '.');
    const a = split.next() orelse return VerifyError.TokenMalformed;
    const b = split.next() orelse return VerifyError.TokenMalformed;
    const c = split.next() orelse return VerifyError.TokenMalformed;
    if (split.next() != null) return VerifyError.TokenMalformed;
    if (a.len == 0 or b.len == 0 or c.len == 0) return VerifyError.TokenMalformed;
    return .{ .header_b64 = a, .payload_b64 = b, .signature_b64 = c };
}

fn decodeBase64UrlOwned(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    const size = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(text) catch return VerifyError.TokenMalformed;
    const out = try alloc.alloc(u8, size);
    errdefer alloc.free(out);
    std.base64.url_safe_no_pad.Decoder.decode(out, text) catch return VerifyError.TokenMalformed;
    return out;
}

fn parseJwks(alloc: std.mem.Allocator, raw: []const u8) !JwksCache {
    const parsed = std.json.parseFromSlice(JwkDoc, alloc, raw, .{}) catch return VerifyError.JwksParseFailed;
    defer parsed.deinit();

    var keys = std.ArrayList(JwkKey).empty;
    errdefer {
        for (keys.items) |key| {
            alloc.free(key.kid);
            alloc.free(key.modulus);
            alloc.free(key.exponent);
        }
        keys.deinit(alloc);
    }

    for (parsed.value.keys) |key| {
        if (key.kid == null or key.n == null or key.e == null) continue;
        if (key.kty) |kty| {
            if (!std.mem.eql(u8, kty, "RSA")) continue;
        }

        try keys.append(alloc, .{
            .kid = try alloc.dupe(u8, key.kid.?),
            .modulus = try decodeBase64UrlOwned(alloc, key.n.?),
            .exponent = try decodeBase64UrlOwned(alloc, key.e.?),
        });
    }

    if (keys.items.len == 0) return VerifyError.JwksParseFailed;

    return .{
        .fetched_at_ms = 0,
        .keys = try keys.toOwnedSlice(alloc),
    };
}

fn verifyRs256(message: []const u8, signature: []const u8, modulus: []const u8, exponent: []const u8) !void {
    switch (modulus.len) {
        inline 128, 256, 384, 512 => |mod_len| {
            if (signature.len != mod_len) return VerifyError.SignatureInvalid;
            const public_key = std.crypto.Certificate.rsa.PublicKey.fromBytes(exponent, modulus) catch return VerifyError.SignatureInvalid;
            var sig: [mod_len]u8 = undefined;
            @memcpy(sig[0..], signature);
            std.crypto.Certificate.rsa.PKCS1v1_5Signature.verify(mod_len, sig, message, public_key, std.crypto.hash.sha2.Sha256) catch {
                return VerifyError.SignatureInvalid;
            };
        },
        else => return VerifyError.SignatureInvalid,
    }
}

fn parseClaims(
    alloc: std.mem.Allocator,
    payload_raw: []const u8,
    expected_issuer: ?[]const u8,
    expected_audience: ?[]const u8,
) !Principal {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, payload_raw, .{}) catch return VerifyError.TokenMalformed;
    defer parsed.deinit();

    if (parsed.value != .object) return VerifyError.TokenMalformed;
    const obj = parsed.value.object;

    const subject = getString(obj, "sub") orelse return VerifyError.MissingSubject;
    const issuer = getString(obj, "iss") orelse return VerifyError.MissingIssuer;

    if (expected_issuer) |want| {
        if (!std.mem.eql(u8, issuer, want)) return VerifyError.IssuerMismatch;
    }

    if (expected_audience) |want_aud| {
        if (!audienceMatches(obj, want_aud)) return VerifyError.AudienceMismatch;
    }

    const exp = getInt(obj, "exp") orelse return VerifyError.MissingExpiry;
    const now_s = std.time.timestamp();
    if (exp <= now_s) return VerifyError.TokenExpired;

    const org_id = getString(obj, "org_id");
    const tenant_id = getTenantId(obj);

    return .{
        .subject = try alloc.dupe(u8, subject),
        .issuer = try alloc.dupe(u8, issuer),
        .tenant_id = if (tenant_id) |v| try alloc.dupe(u8, v) else null,
        .org_id = if (org_id) |v| try alloc.dupe(u8, v) else null,
    };
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn getInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |i| i,
        else => null,
    };
}

fn getTenantId(obj: std.json.ObjectMap) ?[]const u8 {
    if (getString(obj, "tenant_id")) |v| return v;

    const metadata = obj.get("metadata") orelse return null;
    if (metadata != .object) return null;
    return getString(metadata.object, "tenant_id");
}

fn audienceMatches(obj: std.json.ObjectMap, wanted: []const u8) bool {
    const aud = obj.get("aud") orelse return false;
    switch (aud) {
        .string => |value| return std.mem.eql(u8, value, wanted),
        .array => |arr| {
            for (arr.items) |item| {
                if (item == .string and std.mem.eql(u8, item.string, wanted)) return true;
            }
            return false;
        },
        else => return false,
    }
}

const TEST_JWKS =
    \\\{"keys":[{"kty":"RSA","kid":"test-kid-static","use":"sig","alg":"RS256","n":"kEge9Llezx-onM-jdO1fw85yTFmDDHWaZVdihVqMVAvRDGFvHbyoPrp5F-ZaDTqVEd1_pH12HM3abE6HRyYwSRxPcSKf2GlGWBVPtFbidOezLupgspHs8-yXBFKkGQEGBTWspJ4Obd0g9u1EX-cQqzy-lXiGd8gt1oK8Rxx5YBohNbaQMs5dbJ61J9c0afrG0dx-xOOx2tb95izx_m-sB83-aj7mX_r3ClpbZYcOY8ZKA3QNwR9tattkTiowpgzBZ0PGw5wuzrQayjWQRooolW4kzYMVWOI5K4GVPoabBDZDPs2nfet290iFHkNRu8cc2xPDmty0cDIhbS9Mq33qsQ","e":"AQAB"}]}
;
const TEST_VALID_TOKEN = "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6InRlc3Qta2lkLXN0YXRpYyJ9.eyJzdWIiOiJ1c2VyX3Rlc3QiLCJpc3MiOiJodHRwczovL2NsZXJrLmRldi51c2V6b21iaWUuY29tIiwiYXVkIjoiaHR0cHM6Ly9hcGkudXNlem9tYmllLmNvbSIsImlhdCI6MTcwNDA2NzIwMCwib3JnX2lkIjoib3JnXzEiLCJtZXRhZGF0YSI6eyJ0ZW5hbnRfaWQiOiJ0ZW5hbnRfYSJ9LCJleHAiOjQxMDI0NDQ4MDB9.R5EaetratAEMN3VcDRDyR3KM9dKU3FYGEvzajPdmMUB_3T3qE0G0xZ_IoqyNilvjuMcbdSF-YQL1ylcMPTyBeFUWYAUlMjWBju-Bt3FF0Abqdte5-a64oPb_Ev0ogZyJcI8DDt9yT4kUjH7S2jp4fu9hQaEDMW_6tcASagCHTIjw2h0A41_Y8PI4CrgglIFqEKGim5PUEWM_KzZxs9pjv7-_HsZTovfZTcKeiJkGiFQvyR3oKfudvjLNyyGtdYKiSjfOWtLfJkxGt0CKPkbDbrnj_cSmwCt-X_v_OmG5vm07h7iDKrKhXiav0Djn7W3zZ8EcwjhlvMSsKZ3Uy9Nk2g";
const TEST_EXPIRED_TOKEN = "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6InRlc3Qta2lkLXN0YXRpYyJ9.eyJzdWIiOiJ1c2VyX3Rlc3QiLCJpc3MiOiJodHRwczovL2NsZXJrLmRldi51c2V6b21iaWUuY29tIiwiYXVkIjoiaHR0cHM6Ly9hcGkudXNlem9tYmllLmNvbSIsImlhdCI6MTcwNDA2NzIwMCwib3JnX2lkIjoib3JnXzEiLCJtZXRhZGF0YSI6eyJ0ZW5hbnRfaWQiOiJ0ZW5hbnRfYSJ9LCJleHAiOjE3MDQwNjczMDB9.CCjR252liw1fHwmo4kBmHH0nw1uPUBtibZx9BSPKPdzU_4oDmSrJyFP4LJtd9THDIVV8JyE5r1I9a8nuyLe66Wfr_N_tiiNAzYQ0voN_B2AQ-iy8DHhVAJibflv5eaGRXxh4pfn7uV3vY1ZGGDxwyjOXWPy_ULwSwtaDGDQNeWWYgVaaKp1B0-l__oIiMmRgsCiMOE6qyU2SFCQKG05vF54fgg7Pp4hpOgR9guE-rYKoLo39qE0RJvnaf5MTz2WbsPRxrvGurJ1lgnPrxGSXDMT2xJATkof6hP3Hv3QuSRlfCQwLEvlHKZG5ANpe7dxQ00KGf3RJiv0ly9mPapsD5g";

test "verifyAuthorization validates RS256 token and extracts tenant" {
    var verifier = Verifier.init(std.testing.allocator, .{
        .jwks_url = "https://clerk.dev.usezombie.com/.well-known/jwks.json",
        .issuer = "https://clerk.dev.usezombie.com",
        .audience = "https://api.usezombie.com",
        .inline_jwks_json = TEST_JWKS,
    });
    defer verifier.deinit();

    const auth = "Bearer " ++ TEST_VALID_TOKEN;
    const principal = try verifier.verifyAuthorization(std.testing.allocator, auth);
    defer {
        std.testing.allocator.free(principal.subject);
        std.testing.allocator.free(principal.issuer);
        if (principal.tenant_id) |v| std.testing.allocator.free(v);
        if (principal.org_id) |v| std.testing.allocator.free(v);
    }

    try std.testing.expectEqualStrings("user_test", principal.subject);
    try std.testing.expectEqualStrings("https://clerk.dev.usezombie.com", principal.issuer);
    try std.testing.expectEqualStrings("tenant_a", principal.tenant_id.?);
    try std.testing.expectEqualStrings("org_1", principal.org_id.?);
}

test "verifyAuthorization rejects expired token" {
    var verifier = Verifier.init(std.testing.allocator, .{
        .jwks_url = "https://clerk.dev.usezombie.com/.well-known/jwks.json",
        .issuer = "https://clerk.dev.usezombie.com",
        .audience = "https://api.usezombie.com",
        .inline_jwks_json = TEST_JWKS,
    });
    defer verifier.deinit();

    const auth = "Bearer " ++ TEST_EXPIRED_TOKEN;
    try std.testing.expectError(VerifyError.TokenExpired, verifier.verifyAuthorization(std.testing.allocator, auth));
}

test "integration: audience mismatch is rejected" {
    var verifier = Verifier.init(std.testing.allocator, .{
        .jwks_url = "https://clerk.dev.usezombie.com/.well-known/jwks.json",
        .issuer = "https://clerk.dev.usezombie.com",
        .audience = "https://api.other.example",
        .inline_jwks_json = TEST_JWKS,
    });
    defer verifier.deinit();

    const auth = "Bearer " ++ TEST_VALID_TOKEN;
    try std.testing.expectError(VerifyError.AudienceMismatch, verifier.verifyAuthorization(std.testing.allocator, auth));
}
