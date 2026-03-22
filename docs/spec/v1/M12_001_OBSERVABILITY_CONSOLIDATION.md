# M12_001: Observability Consolidation — Grafana + PostHog (2-Tool Architecture)

**Milestone:** M12
**Workstream:** 1
**Date:** Mar 22, 2026
**Status:** SPEC
**Priority:** P1 — eliminate vendor fragmentation, complete Grafana 3-signal story
**Depends on:** M11_001 (DONE), M11_003 (PostHog events, DONE)

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

## WS2: OTLP Log Exporter to Grafana Cloud (~150 lines new)

**Status:** PENDING

Ship structured logs to Grafana Loki via OTLP/HTTP.

**Dimensions:**
- 2.1 New `src/observability/otel_logs.zig` — async ring buffer + batch POST to `/v1/logs`
- 2.2 Dual-write: `std.log` output goes to stderr (Fly capture) AND OTLP buffer
- 2.3 Config: `GRAFANA_OTLP_ENDPOINT`, `GRAFANA_OTLP_INSTANCE_ID`, `GRAFANA_OTLP_API_KEY` (shared with metrics exporter)
- 2.4 Fire-and-forget: log export failures increment `zombie_otel_log_export_failed_total`, never block
- 2.5 Batch flush: 5s interval or 50 entries, whichever comes first
- 2.6 Graceful shutdown: drain buffer with 5s timeout

**Acceptance:**
- [ ] Logs appear in Grafana Loki with scope, level, and structured key=value fields
- [ ] Log export failure increments counter, does not block request/worker path
- [ ] `make test` passes with unit tests for buffer, flush, and failure paths

---

## WS3: OTLP Trace Propagation + Export (~200 lines across 10+ files)

**Status:** PENDING

Wire the existing `trace.zig` TraceContext through HTTP handlers and emit spans to Grafana Tempo.

**Dimensions:**
- 3.1 Add `trace_ctx: TraceContext` field to `http/handlers/common.zig:Context` struct
- 3.2 In HTTP dispatch: parse `traceparent` header or generate root context, set on ctx
- 3.3 Create child spans for: DB query, Redis operation, LLM/agent call
- 3.4 New `src/observability/otel_traces.zig` — batch span export via OTLP/HTTP POST to `/v1/traces`
- 3.5 Reuse Grafana OTLP auth config from WS2 (shared `GRAFANA_OTLP_*` env vars)
- 3.6 LLM call spans include: `agent.actor`, `agent.tokens`, `agent.model`, `agent.duration_ms`
- 3.7 Fire-and-forget: trace export failures increment counter, never block

**Acceptance:**
- [ ] Request traces appear in Grafana Tempo with parent→child span hierarchy
- [ ] LLM call spans show token count and duration
- [ ] `traceparent` header on incoming requests is respected (trace ID preserved)
- [ ] Missing `traceparent` generates a new root trace

---

## WS4: Docs + Config Cleanup

**Status:** PENDING

Update all documentation and configuration to reflect the 2-tool architecture.

**Dimensions:**
- 4.1 Update `docs/observability/SIGNAL_CONTRACT.md` — remove Langfuse section, add log/trace exporter contracts
- 4.2 Update `docs/OBSERVABILITY.md` — rewrite to 2-tool model (Grafana + PostHog)
- 4.3 Update `playbooks/M2_002_PRIMING_INFRA.md` — remove Langfuse secrets, add Grafana OTLP config
- 4.4 Update vault check script — remove Langfuse items, add Grafana OTLP items
- 4.5 Update `deploy-dev.yml` — remove Langfuse env vars, add Grafana OTLP vars
- 4.6 Create done doc `docs/done/v1/M12_001_OBSERVABILITY_CONSOLIDATION.md`

**Acceptance:**
- [ ] No Langfuse references in any docs, config, or deploy files
- [ ] Grafana OTLP config documented in playbook and vault checks
- [ ] SIGNAL_CONTRACT.md version bumped to 2.0

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
