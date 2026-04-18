// Test harness — supertest-style fluent API for in-process HTTP integration tests.
//
// Goal: replace the duplicated TestServer boilerplate in byok_http_integration_test.zig
// and rbac_http_integration_test.zig with one shared module. New integration tests
// (webhook, dashboard, telemetry, …) consume it directly.
//
// Contract:
//   * Runs against the LIVE test database. Never creates temp tables.
//   * Caller wires middleware via `configureRegistry` callback so every suite
//     can plug in only the auth policies it needs.
//   * Fixtures are inserted through `conn()` accessor and MUST be cleaned up
//     explicitly in the test body (not via defer) — mirrors the proven
//     byok/rbac pattern where deferred cleanup leaks connections at pool.deinit.
//
// Shape:
//   var h = try TestHarness.start(alloc, .{ .configureRegistry = myWireFn });
//   defer h.deinit();
//   const r = try h.post("/v1/foo").header("x-sig", sig).json(body).send();
//   defer r.deinit();
//   try r.expectStatus(.accepted);

const std = @import("std");
const pg = @import("pg");
const auth_sessions = @import("../auth/sessions.zig");
const oidc = @import("../auth/oidc.zig");
const queue_redis = @import("../queue/redis.zig");
const auth_mw = @import("../auth/middleware/mod.zig");
const common = @import("handlers/common.zig");
const handler = @import("handler.zig");
const http_server = @import("server.zig");
const telemetry_mod = @import("../observability/telemetry.zig");
const test_port = @import("test_port.zig");

pub const MAX_HEADERS = 16;

pub const Config = struct {
    /// Caller configures the middleware registry. Called AFTER init with pool
    /// already wired into ctx. Caller sets up policies it cares about; unused
    /// policies stay default (stubbed in the helper).
    configureRegistry: *const fn (reg: *auth_mw.MiddlewareRegistry, harness: *TestHarness) anyerror!void,
    /// Optional JWT verification — defaults to a no-op verifier for suites
    /// that don't exercise bearer auth.
    inline_jwks_json: []const u8 = DEFAULT_JWKS,
    issuer: []const u8 = "https://test.invalid",
    audience: []const u8 = "https://test.invalid",
    api_keys: []const u8 = "",
};

const DEFAULT_JWKS =
    \\{"keys":[{"kty":"RSA","n":"2hg972tpbq8H6kzRZ3oVL4wZ9bO-04gJ6gCig68aluyRBzagx-7XXPCiuX80oBHBVj51kvMjT_QDNXfrwzjy4cPbwiVV4HqOGpeIZkPEopfyzs4G7mjiQmx0YuM_5WQUlUjji6Y_DfeaoH-yOhTWBMBVoI0vW_1n66CFaGuEarj3VasdWYxObJTBAM6Jn4XZDcDsBBPNGO4ku7yILkfi11FqXfBP2V8NT0hAGXVAxlWwv-8up1RDzgACp-8JWoC2-kOUJN82fGenDGKq9hW_sumO-4YPNP4U1smnw5jzLlvKa0LBrYG8IgW-3Dniuq2mojhrD_ZQClUd5rF42OyYqw","e":"AQAB","kid":"test-kid-static","use":"sig","alg":"RS256"}]}
;

pub const TestHarness = struct {
    alloc: std.mem.Allocator,
    pool: *pg.Pool,
    session_store: auth_sessions.SessionStore,
    verifier: oidc.Verifier,
    queue: queue_redis.Client,
    telemetry: telemetry_mod.Telemetry,
    registry: auth_mw.MiddlewareRegistry,
    ctx: handler.Context,
    server: *http_server.Server,
    thread: std.Thread,
    port: u16,

    /// Start an in-process server on a free port. Returns `error.SkipZigTest`
    /// when the test DB is not configured (`TEST_DATABASE_URL` unset).
    pub fn start(alloc: std.mem.Allocator, cfg: Config) !*TestHarness {
        const db_ctx = (try common.openHandlerTestConn(alloc)) orelse return error.SkipZigTest;
        db_ctx.pool.release(db_ctx.conn);

        const h = try alloc.create(TestHarness);
        errdefer alloc.destroy(h);
        const port = try test_port.allocFreePort();

        h.* = .{
            .alloc = alloc,
            .pool = db_ctx.pool,
            .session_store = auth_sessions.SessionStore.init(alloc),
            .verifier = oidc.Verifier.init(alloc, .{
                .provider = .clerk,
                .jwks_url = "https://test.invalid/jwks",
                .issuer = cfg.issuer,
                .audience = cfg.audience,
                .inline_jwks_json = cfg.inline_jwks_json,
            }),
            .queue = undefined,
            .telemetry = telemetry_mod.Telemetry.initTest(),
            .registry = undefined,
            .ctx = undefined,
            .server = undefined,
            .thread = undefined,
            .port = port,
        };
        h.ctx = .{
            .pool = h.pool,
            .queue = &h.queue,
            .alloc = alloc,
            .api_keys = cfg.api_keys,
            .oidc = &h.verifier,
            .auth_sessions = &h.session_store,
            .app_url = "http://127.0.0.1",
            .api_in_flight_requests = std.atomic.Value(u32).init(0),
            .api_max_in_flight_requests = 64,
            .ready_max_queue_depth = null,
            .ready_max_queue_age_ms = null,
            .telemetry = &h.telemetry,
        };
        h.registry = defaultRegistry(h, cfg);
        try cfg.configureRegistry(&h.registry, h);
        h.registry.initChains();
        h.server = try http_server.Server.init(&h.ctx, &h.registry, .{
            .port = port,
            .threads = 2,
            .workers = 2,
            .max_clients = 64,
        });
        h.thread = try std.Thread.spawn(.{}, serverThread, .{h.server});
        errdefer {
            h.server.stop();
            h.thread.join();
            h.server.deinit();
        }
        try waitForServer(alloc, port);
        return h;
    }

    pub fn deinit(self: *TestHarness) void {
        self.server.stop();
        self.thread.join();
        self.server.deinit();
        self.verifier.deinit();
        self.session_store.deinit();
        self.pool.deinit();
        self.alloc.destroy(self);
    }

    /// Acquire a connection for fixture insertion / cleanup. Caller releases
    /// back via `pool.release(conn)`.
    pub fn acquireConn(self: *TestHarness) !*pg.Conn {
        return self.pool.acquire();
    }
    pub fn releaseConn(self: *TestHarness, conn: *pg.Conn) void {
        self.pool.release(conn);
    }

    // ── Fluent request API ────────────────────────────────────────────────
    pub fn get(self: *TestHarness, path: []const u8) Request {
        return Request.init(self, .GET, path);
    }
    pub fn post(self: *TestHarness, path: []const u8) Request {
        return Request.init(self, .POST, path);
    }
    pub fn put(self: *TestHarness, path: []const u8) Request {
        return Request.init(self, .PUT, path);
    }
    pub fn delete(self: *TestHarness, path: []const u8) Request {
        return Request.init(self, .DELETE, path);
    }
    pub fn request(self: *TestHarness, method: std.http.Method, path: []const u8) Request {
        return Request.init(self, method, path);
    }
};

fn defaultRegistry(h: *TestHarness, cfg: Config) auth_mw.MiddlewareRegistry {
    return .{
        .bearer_or_api_key = .{ .api_keys = cfg.api_keys, .verifier = &h.verifier },
        .admin_api_key_mw = .{ .api_keys = cfg.api_keys },
        .tenant_api_key_mw = .{ .host = undefined, .lookup = stubTenantApiKey },
        .require_role_admin = .{ .required = .admin },
        .require_role_operator = .{ .required = .operator },
        .slack_sig = .{ .secret = "" },
        .webhook_hmac_mw = .{ .secret = "" },
        .oauth_state_mw = .{ .signing_secret = "", .consume_ctx = &h.queue, .consume_nonce = stubConsumeNonce },
        .webhook_url_secret_mw = .{ .lookup_ctx = &h.queue, .lookup_fn = stubWebhookUrlSecret },
    };
}

fn stubConsumeNonce(_: *anyopaque, _: []const u8) anyerror!bool {
    return false;
}
fn stubWebhookUrlSecret(_: *anyopaque, _: []const u8, _: std.mem.Allocator) anyerror!?[]const u8 {
    return null;
}
fn stubTenantApiKey(_: *anyopaque, _: std.mem.Allocator, _: []const u8) anyerror!?auth_mw.tenant_api_key.LookupResult {
    return null;
}

fn serverThread(srv: *http_server.Server) void {
    srv.listen() catch |err| std.debug.panic("harness server: {s}", .{@errorName(err)});
}

fn waitForServer(alloc: std.mem.Allocator, port: u16) !void {
    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}/healthz", .{port});
    defer alloc.free(url);
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        var client: std.http.Client = .{ .allocator = alloc };
        defer client.deinit();
        var buf: std.ArrayList(u8) = .{};
        var writer: std.Io.Writer.Allocating = .fromArrayList(alloc, &buf);
        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = &writer.writer,
        }) catch {
            std.Thread.sleep(25 * std.time.ns_per_ms);
            continue;
        };
        const body = writer.toOwnedSlice() catch &.{};
        alloc.free(body);
        if (@intFromEnum(result.status) == 200) return;
        std.Thread.sleep(25 * std.time.ns_per_ms);
    }
    return error.ServerStartTimeout;
}

/// Fluent request builder. Non-chaining — each method mutates and returns
/// by value. Keep on the caller's stack; `send` consumes.
pub const Request = struct {
    harness: *TestHarness,
    method: std.http.Method,
    path: []const u8,
    hdr_names: [MAX_HEADERS][]const u8 = undefined,
    hdr_values: [MAX_HEADERS][]const u8 = undefined,
    hdr_count: usize = 0,
    body: ?[]const u8 = null,
    bearer_owned: ?[]u8 = null, // owned by send() → freed on Response.deinit

    fn init(h: *TestHarness, method: std.http.Method, path: []const u8) Request {
        return .{ .harness = h, .method = method, .path = path };
    }

    pub fn header(self: Request, name: []const u8, value: []const u8) Request {
        var r = self;
        if (r.hdr_count >= MAX_HEADERS) @panic("Request: too many headers (raise MAX_HEADERS)");
        r.hdr_names[r.hdr_count] = name;
        r.hdr_values[r.hdr_count] = value;
        r.hdr_count += 1;
        return r;
    }

    pub fn bearer(self: Request, token: []const u8) !Request {
        const val = try std.fmt.allocPrint(self.harness.alloc, "Bearer {s}", .{token});
        var r = self.header("authorization", val);
        r.bearer_owned = val;
        return r;
    }

    pub fn json(self: Request, body: []const u8) Request {
        var r = self.header("content-type", "application/json");
        r.body = body;
        return r;
    }

    /// Raw body without content-type — caller sets it via `header`.
    pub fn rawBody(self: Request, body: []const u8) Request {
        var r = self;
        r.body = body;
        return r;
    }

    pub fn send(self: Request) !Response {
        const alloc = self.harness.alloc;
        defer if (self.bearer_owned) |v| alloc.free(v);

        const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}{s}", .{ self.harness.port, self.path });
        defer alloc.free(url);

        var hdrs: [MAX_HEADERS]std.http.Header = undefined;
        var i: usize = 0;
        while (i < self.hdr_count) : (i += 1) {
            hdrs[i] = .{ .name = self.hdr_names[i], .value = self.hdr_values[i] };
        }

        var client: std.http.Client = .{ .allocator = alloc };
        defer client.deinit();
        var buf: std.ArrayList(u8) = .{};
        var writer: std.Io.Writer.Allocating = .fromArrayList(alloc, &buf);
        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = self.method,
            .payload = self.body,
            .extra_headers = hdrs[0..self.hdr_count],
            .response_writer = &writer.writer,
        });
        return .{
            .status = @intFromEnum(result.status),
            .body = try writer.toOwnedSlice(),
            .alloc = alloc,
        };
    }
};

pub const Response = struct {
    status: u16,
    body: []u8,
    alloc: std.mem.Allocator,

    pub fn deinit(self: Response) void {
        self.alloc.free(self.body);
    }

    pub fn expectStatus(self: Response, expected: std.http.Status) !void {
        const got = self.status;
        const want: u16 = @intFromEnum(expected);
        if (got != want) {
            std.debug.print("expectStatus: want {d}, got {d}; body={s}\n", .{ want, got, self.body });
            return error.UnexpectedStatus;
        }
    }

    /// Assert the RFC7807 problem+json error code matches. Tolerant of
    /// surrounding whitespace and field ordering — does a substring match
    /// on "\"code\":\"<code>\"".
    pub fn expectErrorCode(self: Response, code: []const u8) !void {
        const needle = try std.fmt.allocPrint(self.alloc, "\"code\":\"{s}\"", .{code});
        defer self.alloc.free(needle);
        if (std.mem.indexOf(u8, self.body, needle) == null) {
            std.debug.print("expectErrorCode: {s} not in body={s}\n", .{ code, self.body });
            return error.ErrorCodeMismatch;
        }
    }

    pub fn bodyContains(self: Response, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.body, needle) != null;
    }
};
