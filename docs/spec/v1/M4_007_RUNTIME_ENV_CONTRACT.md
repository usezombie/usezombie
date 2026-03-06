# M4_007: Define Runtime, Observability, And Config Contracts

**Prototype:** v1.0.0
**Milestone:** M4
**Workstream:** 007
**Date:** Mar 06, 2026
**Status:** PENDING
**Priority:** P1 — operator safety baseline
**Batch:** B2 — needs M3_006 done (M3_000, M3_004, M4_004 already DONE)
**Depends on:** M3_006 (Implement Clerk Authentication Contract)

---

## 1.0 Define Environment Contract

**Status:** PENDING

Define one authoritative env contract for `zombied` and `zombiectl` operation.

**Dimensions:**
- 1.1 PENDING Define core runtime variables (`API_KEY`, `ENCRYPTION_MASTER_KEY`, `LOG_LEVEL`)
- 1.2 PENDING Define role-separated DB URLs (`DATABASE_URL_API`, `DATABASE_URL_WORKER`)
- 1.3 PENDING Define Redis queue URLs (`REDIS_URL_API`, `REDIS_URL_WORKER`)
- 1.4 PENDING Define GitHub App variables (`GITHUB_APP_ID`, private key, OAuth client pair)
- 1.5 PENDING Define Clerk variables (`CLERK_SECRET_KEY`, `CLERK_JWKS_URL`, publishable key)
- 1.6 PENDING Define worker/limit knobs (`WORKER_CONCURRENCY`, `RUN_TIMEOUT_MS`, rate limits)
- 1.7 PENDING Define readiness threshold variables (`READY_MAX_QUEUE_DEPTH`, `READY_MAX_QUEUE_AGE_MS`)

---

## 2.0 Enforce Validation And Doctor Semantics

**Status:** PENDING

**Dimensions:**
- 2.1 PENDING Fail startup deterministically on invalid/missing critical env values
- 2.2 PENDING Return errors that identify exact key and expected format
- 2.3 PENDING Extend `zombied doctor` to validate DB, Redis, and auth dependency reachability
- 2.4 PENDING Include security posture checks for role grants and Redis ACL identity
- 2.5 PENDING Keep doctor output deterministic and machine-parseable

---

## 3.0 Harden Deferred Observability And Config Hygiene

**Status:** PENDING

Consolidate deferred D4/D8/D19/D20 dimensions into the runtime contract stream.

**Dimensions:**
- 3.1 PENDING Introduce durable event persistence or outbox-backed replay boundary
- 3.2 PENDING Define versioned event schema for state/policy/agent telemetry payloads
- 3.3 PENDING Define canonical trace context (`trace_id`, `span_id`, `request_id`) across HTTP/worker/state/policy
- 3.4 PENDING Add OTEL/collector export path without regressing Prometheus metrics
- 3.5 PENDING Introduce key-versioned encryption envelope metadata
- 3.6 PENDING Document and verify no-downtime key rotation workflow

---

## 4.0 Canonicalize Documentation

**Status:** PENDING

**Dimensions:**
- 4.1 PENDING Remove duplicated env lists across ad-hoc docs and point to one canonical location
- 4.2 PENDING Keep `.env.example` and runtime docs consistent with this contract
- 4.3 PENDING Add operator notes for key rotation windows and migration safety

---

## 5.0 Acceptance Criteria

**Status:** PENDING

- [ ] 5.1 Runtime env contract is singular, explicit, and test-validated
- [ ] 5.2 Doctor checks cover all required operational dependencies
- [ ] 5.3 Telemetry/export context is collector-friendly and replay-safe
- [ ] 5.4 Durable event and config/secret evolution paths are documented and testable
- [ ] 5.5 On-call/operator setup is possible from canonical docs alone

---

## 6.0 Out of Scope

- Cross-region config orchestration
- UI/dashboard observability features
- Full production compliance controls beyond v1
