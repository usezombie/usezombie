# M5_001: posthog-zig — PostHog Analytics SDK for Zig

Date: Mar 4, 2026
Status: PENDING
Priority: P2
Depends on: None (standalone library; integration into usezombie is M5 scope)

---

## Goal

Ship a standalone, open-source PostHog client library for Zig (`posthog-zig`) that any Zig project can import via `build.zig.zon`. The library must support event capture, user identification, batch flushing, and feature flags via PostHog's HTTP API — with async-safe, non-blocking event emission suitable for high-throughput server workloads.

## Location

Separate repository: `~/Projects/posthog-zig/` → `github.com/usezombie/posthog-zig`

Integration into usezombie is a follow-up task after the library is stable.

## Architecture

```
posthog-zig/
├── build.zig
├── build.zig.zon
├── LICENSE                    # MIT
├── README.md
├── src/
│   ├── root.zig               # Public API re-exports
│   ├── client.zig             # PostHogClient: init, deinit, configure
│   ├── capture.zig            # Event capture + identify + group
│   ├── batch.zig              # In-memory queue + batch envelope builder
│   ├── transport.zig          # HTTP POST to PostHog /batch/ endpoint
│   ├── retry.zig              # Exponential backoff + jitter retry logic
│   ├── flush.zig              # Background flush thread + shutdown drain
│   ├── feature_flags.zig      # GET /decide/ for feature flag evaluation
│   └── types.zig              # Event, Properties, Options structs
└── tests/
    ├── client_test.zig
    ├── batch_test.zig
    ├── transport_test.zig
    ├── retry_test.zig
    └── integration_test.zig   # Requires POSTHOG_API_KEY env var
```

## Disclaimer

This is a **server-side SDK**. It does not support session recording, autocapture, or any browser DOM interaction — Zig isn't running in your users' browsers (unless you're compiling to WASM, in which case: respect, you absolute menace). WASM support is theoretically possible since Zig has a first-class `wasm32-freestanding` target, but this library assumes `std.http.Client`, `std.Thread`, and a proper OS — none of which exist in browser WASM. A hypothetical WASM build would need a `fetch()`-based transport shim and is firmly out of scope.

Use this SDK for backend services, CLI tools, daemons, and control planes. For frontend analytics, use PostHog's JavaScript SDK like a normal person.

## Design Principles

1. **Zero allocation on hot path** — `capture()` copies event into a pre-allocated ring buffer. No heap allocation per event.
2. **Non-blocking** — `capture()` returns immediately. A background thread owns the flush loop.
3. **Reliable delivery** — Retry with exponential backoff (base 1s, max 30s, jitter). Drop after N retries (configurable, default 3). Events that fail all retries are logged, not silently lost.
4. **Graceful shutdown** — `client.deinit()` flushes remaining queued events with a configurable timeout (default 5s).
5. **No external dependencies** — Uses only `std.http.Client`, `std.Thread`, `std.json`. No C deps, no libc requirement beyond what Zig std uses.
6. **Zig-idiomatic** — Comptime-known config where possible. Error unions, not exceptions. Allocator-aware.

## Public API

```zig
const posthog = @import("posthog");

// ── Init ──────────────────────────────────────────────────────────────
var client = try posthog.init(allocator, .{
    .api_key = "phc_...",
    .host = "https://us.i.posthog.com",  // default
    .flush_interval_ms = 10_000,          // default: 10s
    .flush_at = 20,                       // default: flush when 20 events queued
    .max_queue_size = 1000,               // default: drop oldest if exceeded
    .max_retries = 3,                     // default
    .shutdown_flush_timeout_ms = 5_000,   // default
});
defer client.deinit(); // flushes remaining events

// ── Capture ───────────────────────────────────────────────────────────
try client.capture(.{
    .distinct_id = "user_123",
    .event = "spec_submitted",
    .properties = &.{
        .{ .key = "workspace_id", .value = .{ .string = "ws_abc" } },
        .{ .key = "spec_count", .value = .{ .integer = 3 } },
    },
});

// ── Identify ──────────────────────────────────────────────────────────
try client.identify(.{
    .distinct_id = "user_123",
    .properties = &.{
        .{ .key = "email", .value = .{ .string = "alice@example.com" } },
        .{ .key = "plan", .value = .{ .string = "pro" } },
    },
});

// ── Group ─────────────────────────────────────────────────────────────
try client.group(.{
    .distinct_id = "user_123",
    .group_type = "company",
    .group_key = "company_abc",
    .properties = &.{
        .{ .key = "name", .value = .{ .string = "Acme Corp" } },
    },
});

// ── Feature Flags ─────────────────────────────────────────────────────
const enabled = try client.isFeatureEnabled("new-dashboard", "user_123");
const payload = try client.getFeatureFlagPayload("new-dashboard", "user_123");

// ── Manual flush ──────────────────────────────────────────────────────
try client.flush();
```

## Internal Flow

```
capture() ─────────► Ring Buffer ─────────► Flush Thread ─────────► HTTP POST /batch/
  (non-blocking)     (thread-safe)          (timer or threshold)    (std.http.Client)
                     │                                              │
                     │ if full: drop oldest                         │ on failure:
                     │ + log warning                                │ retry w/ backoff
                     │                                              │ after max_retries:
                     │                                              │ drop + log error
                     ▼                                              ▼
              client.deinit() ──► drain remaining ──► final POST ──► done
```

### Ring Buffer (batch.zig)

- Fixed-capacity circular buffer of serialized event bytes.
- Thread-safe via `std.Thread.Mutex`.
- `enqueue()` returns `error.QueueFull` if at capacity (caller decides: drop or block).
- Default behavior: drop oldest event and log a warning with count of dropped events.

### Flush Thread (flush.zig)

- Spawned on `client.init()`.
- Wakes on:
  1. Timer tick (`flush_interval_ms`).
  2. Queue reaching `flush_at` threshold (signaled via `std.Thread.Condition`).
  3. Shutdown signal from `client.deinit()`.
- Drains the ring buffer into a JSON batch payload and hands off to transport.

### Transport (transport.zig)

- `POST /batch/` with `Content-Type: application/json`.
- Request body:

```json
{
  "api_key": "phc_...",
  "batch": [
    {
      "event": "spec_submitted",
      "properties": {
        "distinct_id": "user_123",
        "workspace_id": "ws_abc",
        "$lib": "posthog-zig",
        "$lib_version": "0.1.0"
      },
      "timestamp": "2026-03-04T10:30:00.000Z"
    }
  ]
}
```

- Expects HTTP 200. Any non-2xx triggers retry logic.
- Sets `User-Agent: posthog-zig/0.1.0`.

### Retry (retry.zig)

- Exponential backoff: `min(base * 2^attempt, max_delay)` + random jitter (0–500ms).
- Default: base=1s, max=30s, max_retries=3.
- Retries on: 5xx, 429 (respects `Retry-After` header), network errors.
- Does NOT retry on: 4xx (except 429). These indicate bad data — log and drop.

### Feature Flags (feature_flags.zig)

- `POST /decide/?v=3` with `{ "api_key": "...", "distinct_id": "..." }`.
- Response cached in-memory with configurable TTL (default 60s).
- Cache is per-distinct_id, bounded to max 1000 entries (LRU eviction).
- `isFeatureEnabled()` returns `bool`. `getFeatureFlagPayload()` returns `?[]const u8`.

## Properties System (types.zig)

```zig
pub const PropertyValue = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
};

pub const Property = struct {
    key: []const u8,
    value: PropertyValue,
};

pub const CaptureOptions = struct {
    distinct_id: []const u8,
    event: []const u8,
    properties: ?[]const Property = null,
    timestamp: ?i64 = null, // epoch ms; null = now
};

pub const IdentifyOptions = struct {
    distinct_id: []const u8,
    properties: ?[]const Property = null,
};

pub const GroupOptions = struct {
    distinct_id: []const u8,
    group_type: []const u8,
    group_key: []const u8,
    properties: ?[]const Property = null,
};
```

## Integration with usezombie (follow-up)

Once `posthog-zig` is stable (v0.1.0+), integrate into the usezombie control plane:

1. Add dependency to `build.zig.zon`.
2. Init client in `src/main.zig` alongside the HTTP server.
3. Capture events from:
   - `handleStartRun` → `"run_started"` with workspace_id, spec_id.
   - `handleRetryRun` → `"run_retried"` with run_id, attempt.
   - `emitNullclawRunEvent` → `"agent_completed"` with actor, tokens, duration.
   - `handlePauseWorkspace` → `"workspace_paused"`.
   - Pipeline completion → `"run_completed"` with verdict, pr_url.
4. Identify users on auth (from Bearer token claims).
5. Shutdown: `defer posthog_client.deinit()` ensures flush before exit.

## Acceptance Criteria

1. `client.capture()` returns in < 1μs (enqueue only, no I/O).
2. Background flush thread delivers batched events to PostHog `/batch/` endpoint.
3. Retry logic handles 5xx and 429 with exponential backoff; drops after `max_retries`.
4. `client.deinit()` drains remaining events within `shutdown_flush_timeout_ms`.
5. `client.identify()` and `client.group()` send correct PostHog envelope shapes.
6. `client.isFeatureEnabled()` returns cached result from `/decide/` endpoint.
7. Ring buffer drops oldest events when full and logs a warning with drop count.
8. No heap allocation on the `capture()` hot path beyond the ring buffer copy.
9. Library compiles with `zig build` on Zig 0.15.x, no external C dependencies.
10. Integration test sends real events to PostHog (gated behind `POSTHOG_API_KEY` env var).
11. Published as a Zig package fetchable via `zig fetch --save`.

## Out of Scope

1. Session recording / autocapture (browser-only concepts).
2. Sentry-style panic handler (use `sentry-zig` for that).
3. Local event persistence / disk queue (events are in-memory only for v0.1).
4. Super properties / middleware chain (v0.2 if needed).
5. WASM or embedded targets (server-side Linux/macOS only for v0.1).

## Prior Art and References

- [getsentry/sentry-zig](https://github.com/getsentry/sentry-zig) — Zig SDK architecture: `client.zig` + `transport.zig` + `types/` pattern. Uses `std.http.Client` for delivery.
- [PostHog /batch/ API](https://posthog.com/docs/api/capture) — Batch capture endpoint spec.
- [PostHog /decide/ API](https://posthog.com/docs/api/decide) — Feature flag evaluation endpoint.
- [posthog-python](https://github.com/PostHog/posthog-python) — Reference implementation: queue + consumer thread + flush-on-shutdown pattern.
- [posthog-rust](https://github.com/PostHog/posthog-rs) — Rust SDK: similar async batch architecture.
- `docs/done/v1/DONE_M1_003_OBSERVABILITY_AND_POLICY.md` — Observability event taxonomy that posthog-zig events will complement.

## Risks and Mitigations

1. **Risk:** `std.http.Client` TLS support varies across Zig versions.
   **Mitigation:** Pin to Zig 0.15.x. Test against PostHog's HTTPS endpoint in CI. Fall back to spawning `curl` as escape hatch if TLS breaks.

2. **Risk:** Ring buffer too small causes event drops under burst load.
   **Mitigation:** Default 1000 events is generous for server workloads. Log drop count so operators can tune `max_queue_size`. Document sizing guidance.

3. **Risk:** PostHog API changes break the SDK.
   **Mitigation:** `/batch/` and `/decide/` are stable, versioned endpoints. Pin to `v=3` for decide. Integration tests catch regressions.

4. **Risk:** Thread safety bugs in ring buffer or flush coordination.
   **Mitigation:** Use `std.Thread.Mutex` + `std.Thread.Condition` (well-tested in Zig std). Unit tests with concurrent producers.

5. **Risk:** Library not adopted because PostHog Zig usage is niche.
   **Mitigation:** Primary consumer is usezombie itself. Community adoption is a bonus, not a requirement.

## Test/Verification Commands

```bash
# Build library
cd ~/Projects/posthog-zig && zig build

# Run unit tests
zig build test

# Run integration tests (requires API key)
POSTHOG_API_KEY=phc_... zig build test -Dintegration=true

# Verify no external C dependencies
zig build -Dtarget=x86_64-linux --summary all 2>&1 | grep -c "link with" && echo "WARN: C deps" || echo "PASS: pure Zig"

# Benchmark capture() hot path latency
zig build bench
```
