# M12_001: Observability Consolidation — Grafana + PostHog (2-Tool Architecture)

**Prototype:** v1.0.0
**Milestone:** M12
**Workstream:** 001
**Date:** Mar 22, 2026
**Status:** DONE
**Priority:** P1 — eliminate vendor fragmentation, complete Grafana 3-signal story
**Depends on:** M11_001 (DONE), M11_003 (PostHog events, DONE)

## Completion Note

Verified against GitHub PR `#73` (`feat(m12): OTLP trace export + docs — M12_001 WS3+WS4`), merged into `main` on Mar 22, 2026 at 10:27:56 UTC with merge commit `5cb2c22a4055cbd9b8fd463ce6524facbaf5f1af`.

That merge covered the previously open trace and docs work:
- `src/observability/otel_traces.zig`
- HTTP trace propagation updates
- `docs/OBSERVABILITY.md`
- `docs/observability/SIGNAL_CONTRACT.md`
- `playbooks/M2_002_PRIMING_INFRA.md`
- `playbooks/gates/m2_001/section-2-procurement-readiness.sh`
- `.github/workflows/deploy-dev.yml`
- this done-spec file

## Decision

**Drop Langfuse. Keep Grafana + PostHog.**

Langfuse provided LLM trace visualization, but its data (tokens, cost, timing) is already
captured as Grafana metrics (`zombie_agent_tokens_total`, `zombie_agent_duration_seconds`)
and PostHog event properties (`agent_completed.tokens`, `agent_completed.duration_ms`).
Removing it eliminates 1 vendor, 1 billing account, 1 circuit breaker, ~300 lines of Zig code,
and 3 vault credentials (dev/staging/prod).

The prompt-diff UI is the only unique Langfuse capability lost. It was never used in production.

## Architecture

```
AFTER: 2-tool observability
═══════════════════════════════════════════════════════════

          ┌────────────────────────┐
          │     GRAFANA CLOUD      │
          │  ┌──────┬─────┬──────┐ │
          │  │ Loki │Tempo│ Prom │ │
          │  │ logs │trace│ metr │ │
          │  └──▲───┴──▲──┴──▲───┘ │
          │     │      │     │     │
          │  Alerting: error rates,│
          │  latency, token spend  │
          └─────┼──────┼─────┼─────┘
                │      │     │
            OTLP/HTTP (3 signals)
                │      │     │
       ┌────────┴──────┴─────┴──────────┐
       │    zombied (serve + worker)    │
       │  ┌──────────┐ ┌────────────┐  │
       │  │otel_logs │ │otel_export │  │
       │  │ (NEW)    │ │(metrics)   │  │
       │  └──────────┘ └────────────┘  │
       │  ┌──────────┐ ┌────────────┐  │
       │  │otel_trace│ │posthog-zig │──┤──► POSTHOG
       │  │ (NEW)    │ │(product)   │  │
       │  └──────────┘ └────────────┘  │
       │  ┌──────────┐                 │
       │  │metrics   │ /metrics        │
       │  └──────────┘ (Prom scrape)   │
       └───────────────────────────────┘
              ▲          ▲          ▲
           website      app        CLI
           React      Next.js      JS
           posthog-js posthog-js posthog-node
           (Vercel)   (Vercel)   (npm)
                  │          │
                  ▼          ▼
            ┌──────────────────┐
            │     POSTHOG      │
            │ funnels, retain- │
            │ tion, flags,     │
            │ replay, errors   │
            └──────────────────┘
```

## Surface-to-Tool Mapping

| Surface | Grafana (ops) | PostHog (product) |
|---|---|---|
| zombied serve | metrics, logs, traces, alerting | run/workspace/auth/billing events |
| zombied worker | metrics, logs, traces, LLM call spans | agent_completed (tokens, cost, duration), scoring events |
| website (React, Vercel) | — | posthog-js: funnels, conversion, navigation |
| app (Next.js, Vercel) | — | posthog-js: feature usage, retention, session replay |
| CLI (JS, npm) | — | posthog-node: command adoption, errors |

LLM call data is **dual-emitted**:
- Grafana: `zombie_agent_tokens_total` counter + `zombie_agent_duration_seconds` histogram (ops alerting on token spend spikes)
- PostHog: `agent_completed` event properties `tokens`, `duration_ms` (per-user cost attribution)

---

## WS1: Remove Langfuse (~300 lines removed)

**Status:** DONE

Remove the Langfuse async exporter, circuit breaker, and all configuration.

**Dimensions:**
- 1.1 Delete `src/observability/langfuse.zig` (async queue, circuit breaker, HTTP client)
- 1.2 Remove Langfuse imports and calls from `src/pipeline/worker_stage_executor.zig`
- 1.3 Remove Langfuse init from `src/cmd/worker.zig` (configFromEnv, installAsyncExporter)
- 1.4 Remove Langfuse vault items from `playbooks/gates/m2_001/section-2-procurement-readiness.sh`
- 1.5 Remove `LANGFUSE_HOST`, `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY` from deploy pipeline
- 1.6 Remove Langfuse metrics counters: `zombie_langfuse_emit_total`, `zombie_langfuse_emit_failed_total`, `zombie_langfuse_circuit_open_total`, `zombie_langfuse_last_success_at_ms`
- 1.7 Update `docs/observability/SIGNAL_CONTRACT.md` — remove Langfuse ownership section
- 1.8 Update `docs/OBSERVABILITY.md` — remove Langfuse references, update to 2-tool model

**Acceptance:**
- [x] DONE — `zig build` compiles without langfuse references
- [x] DONE — `make test` passes
- [x] DONE — No `LANGFUSE` env vars in deploy or vault checks
- [x] DONE — SIGNAL_CONTRACT.md reflects 2-tool model

---

## WS2: OTLP Log Exporter to Grafana Cloud (341 lines new)

**Status:** DONE

Ship structured logs to Grafana Loki via OTLP/HTTP.

**Dimensions:**
- 2.1 DONE New `src/observability/otel_logs.zig` — async ring buffer (2048 capacity) + batch POST to `/v1/logs`
- 2.2 DONE Dual-write: `zombiedLog` in `main.zig` writes to stderr AND calls `otel_logs.enqueue()`
- 2.3 DONE Config: `GRAFANA_OTLP_ENDPOINT`, `GRAFANA_OTLP_INSTANCE_ID`, `GRAFANA_OTLP_API_KEY` via `configFromEnv()`
- 2.4 DONE Fire-and-forget: export errors caught in flush loop, never block callers
- 2.5 DONE Batch flush: 5s interval, 50 entries per batch
- 2.6 DONE Graceful shutdown: drain buffer with 5s timeout on `uninstall()`

**Acceptance:**
- [x] DONE OTLP JSON payload format with severityText, body, scope attributes
- [x] DONE Log export is fire-and-forget (ring buffer enqueue is non-blocking)
- [x] DONE `make test` passes with unit tests: ring buffer push/pop, full buffer drops, truncation, no-op when not installed

---

## WS3: OTLP Trace Propagation + Export (~200 lines across 10+ files)

**Status:** DONE

Wire the existing `trace.zig` TraceContext through HTTP handlers and emit spans to Grafana Tempo.

**Dimensions:**
- 3.1 DONE Add `trace_ctx: TraceContext` field to HTTP request context
- 3.2 DONE Parse `traceparent` header or generate root context during dispatch
- 3.3 DONE Create child spans for request and execution paths
- 3.4 DONE Add `src/observability/otel_traces.zig` for OTLP/HTTP trace export
- 3.5 DONE Reuse shared OTLP auth config
- 3.6 DONE Include LLM/agent attributes on emitted spans
- 3.7 DONE Keep trace export fire-and-forget

**Acceptance:**
- [x] Request traces appear in Grafana Tempo with parent→child span hierarchy
- [x] LLM call spans show token count and duration
- [x] `traceparent` header on incoming requests is respected (trace ID preserved)
- [x] Missing `traceparent` generates a new root trace

---

## WS4: Docs + Config Cleanup

**Status:** DONE

Update all documentation and configuration to reflect the 2-tool architecture.

**Dimensions:**
- 4.1 DONE Update `docs/observability/SIGNAL_CONTRACT.md`
- 4.2 DONE Update `docs/OBSERVABILITY.md`
- 4.3 DONE Update `playbooks/M2_002_PRIMING_INFRA.md`
- 4.4 DONE Update procurement/vault readiness checks
- 4.5 DONE Update `deploy-dev.yml`
- 4.6 DONE Create done doc `docs/done/v1/M12_001_OBSERVABILITY_CONSOLIDATION.md`

**Acceptance:**
- [x] Active observability docs/config/deploy paths were updated in the verified merge
- [x] Grafana OTLP config is documented in playbook and vault checks
- [x] SIGNAL_CONTRACT.md was updated as part of the verified merge

---

## Env Var Consolidation

**Before (7 observability env vars):**
```
POSTHOG_API_KEY          → posthog-zig SDK
LANGFUSE_HOST            → Langfuse endpoint        ← REMOVE
LANGFUSE_PUBLIC_KEY      → Langfuse auth             ← REMOVE
LANGFUSE_SECRET_KEY      → Langfuse auth             ← REMOVE
OTEL_EXPORTER_OTLP_ENDPOINT → Grafana metrics
OTEL_SERVICE_NAME        → service identifier
```

**After (5 observability env vars):**
```
POSTHOG_API_KEY              → posthog-zig SDK
GRAFANA_OTLP_ENDPOINT        → Grafana Cloud gateway (logs + metrics + traces)
GRAFANA_OTLP_INSTANCE_ID     → Grafana Cloud instance
GRAFANA_OTLP_API_KEY          → Grafana Cloud API key
OTEL_SERVICE_NAME             → service identifier (default: zombied)
```

Note: `GRAFANA_OTLP_*` replaces `OTEL_EXPORTER_OTLP_*` for clarity. The OTLP endpoint
is Grafana-specific (requires Basic auth with instance_id:api_key), not a generic OTLP collector.

---

## Vault Items

**Remove:**
```
op://$VAULT_DEV/langfuse-dev/host
op://$VAULT_DEV/langfuse-dev/public-key
op://$VAULT_DEV/langfuse-dev/secret-key
op://$VAULT_PROD/langfuse-prod/host
op://$VAULT_PROD/langfuse-prod/public-key
op://$VAULT_PROD/langfuse-prod/secret-key
```

**Add:**
```
op://$VAULT_DEV/grafana-dev/otlp-endpoint
op://$VAULT_DEV/grafana-dev/instance-id
op://$VAULT_DEV/grafana-dev/api-key
op://$VAULT_PROD/grafana-prod/otlp-endpoint
op://$VAULT_PROD/grafana-prod/instance-id
op://$VAULT_PROD/grafana-prod/api-key
```

---

## Execution Order

```
WS1 (Remove Langfuse) ──► WS2 (OTLP Logs) ──► WS3 (OTLP Traces) ──► WS4 (Docs)
     │                          │                    │
     │ unblocks                 │ establishes         │ threads through
     │ clean compile            │ shared auth config  │ handlers
     ▼                          ▼                    ▼
  -300 lines                 +150 lines           +200 lines
```

Net code change: ~+50 lines (remove 300, add 350). One fewer vendor. Three Grafana signals operational.
