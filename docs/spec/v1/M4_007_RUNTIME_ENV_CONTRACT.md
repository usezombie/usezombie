# M4_007: Define Runtime, Observability, And Config Contracts

**Prototype:** v1.0.0
**Milestone:** M4
**Workstream:** 007
**Date:** Mar 06, 2026
**Status:** IN_PROGRESS
**Priority:** P1 — operator safety baseline
**Batch:** B2 — needs M3_006 done (M3_000, M3_004, M4_004 already DONE)
**Depends on:** M3_006 (Implement Clerk Authentication Contract)

---

## 1.0 Define Environment Contract

**Status:** IN_PROGRESS

Define one authoritative env contract for `zombied` and `zombiectl`.

Resolved policy for "env vs CLI flags" to keep `zombiectl` slim:
- Non-secret operator ergonomics may allow CLI overrides (`--log-level` style).
- Secret/security-critical values remain env-only.
- Deterministic precedence for allowed overrides: `CLI flag > env var > default`.

**Dimensions:**
- 1.1 DONE Publish canonical contract doc at `docs/RUNTIME_ENV_CONTRACT.md`.
- 1.2 DONE Define required core/auth/secrets keys (`API_KEY`, `ENCRYPTION_MASTER_KEY`, GitHub/Clerk keys).
- 1.3 DONE Define role-separated data plane URLs (`DATABASE_URL_API`, `DATABASE_URL_WORKER`, `REDIS_URL_API`, `REDIS_URL_WORKER`) and `rediss://` requirement.
- 1.4 DONE Define runtime knobs/readiness thresholds (`WORKER_CONCURRENCY`, `RUN_TIMEOUT_MS`, `READY_MAX_QUEUE_DEPTH`, `READY_MAX_QUEUE_AGE_MS`).

---

## 2.0 Enforce Validation And Doctor Semantics

**Status:** PENDING

**Dimensions:**
- 2.1 PENDING Fail startup deterministically on invalid/missing critical env values
- 2.2 PENDING Return errors that identify exact key and expected format
- 2.3 PENDING Extend `zombied doctor` to validate DB, Redis, and auth dependency reachability
- 2.4 PENDING Keep doctor output deterministic and machine-parseable

---

## 3.0 Define Telemetry Contract (Schema + Trace Context)

**Status:** PENDING

Consolidate telemetry contract decisions into one versioned schema across API, worker, state machine, and policy evaluation.

**Dimensions:**
- 3.1 PENDING Define versioned event envelope (`event_schema_version`, `event_name`, `occurred_at`, `source`, `payload`).
- 3.2 PENDING Define canonical trace fields (`trace_id`, `span_id`, `request_id`) and rule for `correlation_id` (optional cross-trace join key only).
- 3.3 PENDING Add OTEL export path (`OTEL_EXPORTER_OTLP_ENDPOINT` + headers) without regressing existing Prometheus metrics.
- 3.4 PENDING Define durability/replay boundary for emitted events (outbox or equivalent deterministic replay path).

---

## 4.0 Define Encryption Metadata + Rotation Workflow

**Status:** PENDING

Clarify the two open questions:
- "Key-versioned encryption envelope metadata" means each encrypted value stores *which key version encrypted it*.
- "No-downtime key rotation" means rolling to a new key version without blocking API/worker traffic.

**Dimensions:**
- 4.1 PENDING Define envelope fields (`kek_version`, `alg`, wrapped payload metadata) for encrypted secrets.
- 4.2 PENDING Implement dual-read/single-write behavior during rotation (read old+new; write new only).
- 4.3 PENDING Document operator rotation workflow with rollback guardrails and verification steps.
- 4.4 PENDING Add doctor/health checks to detect unknown key versions or stale rotation state.

---

## 5.0 Canonicalize Documentation

**Status:** IN_PROGRESS

**Dimensions:**
- 5.1 DONE Remove duplicated env references in deployment docs and point to `docs/RUNTIME_ENV_CONTRACT.md`.
- 5.2 DONE Keep `.env.example` and runtime docs consistent with role-separated `rediss://` contract.
- 5.3 PENDING Add operator notes for key rotation windows and migration safety.
- 5.4 PENDING Add validation checklist to prevent env contract drift in future spec/workstream updates.

---

## 6.0 Acceptance Criteria

**Status:** PENDING

- [ ] 6.1 Runtime env contract is singular, explicit, and test-validated
- [ ] 6.2 Doctor checks cover all required operational dependencies
- [ ] 6.3 Telemetry/export context is collector-friendly and replay-safe
- [ ] 6.4 Durable event and config/secret evolution paths are documented and testable
- [ ] 6.5 On-call/operator setup is possible from canonical docs alone

---

## 7.0 Out of Scope

- Cross-region config orchestration
- UI/dashboard observability features
- Full production compliance controls beyond v1
