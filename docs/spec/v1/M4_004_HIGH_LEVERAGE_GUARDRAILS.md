# M4_004: High-Leverage Guardrails (Deferred from M3_001)

**Prototype:** v1.0.0
**Milestone:** M4
**Workstream:** 004
**Date:** Mar 05, 2026
**Status:** IN_PROGRESS
**Priority:** P0 — Must complete before CLI freeze
**Depends on:** M3_001 (closure baseline), M3_004 (Redis streams), M3_006 (Clerk auth)

---

## 1.0 Scope Mapping (M3_001 Deferred Dimensions)

**Status:** IN_PROGRESS

This workstream contains the must-have reliability and safety guardrails deferred when closing M3_001.

**Dimensions:**
- 1.1 PENDING D2 Allocation normalization (per-run allocator model + reduced manual free churn)
- 1.2 PENDING D3 Async/API throughput model (beyond thread-level parallelism)
- 1.3 PENDING D5 Reliability wrappers + durable outbox/dead-letter baseline
- 1.4 DONE D6 Rate-limit policy hardening (tenant + provider semantics)
- 1.5 DONE D7 Backoff standardization with full `Retry-After` plumbing
- 1.6 PENDING D9 Error-context logging consistency across all critical boundaries
- 1.7 DONE D10 Error classification harmonization (worker + API)
- 1.8 PENDING D11 Secure execution boundary hardening
- 1.9 PENDING D12 Graceful shutdown and stale runtime cleanup
- 1.10 DONE D13 Exactly-once transactional correctness closure (run creation upsert + idempotent replay path)
- 1.11 DONE D14 Side-effect idempotency ledger completion (`run_side_effects` + PR side-effect claim/done tracking)
- 1.12 PENDING D15 Cooperative cancellation for long-running calls
- 1.13 PENDING D16 Thread-safety and allocator guardrails
- 1.14 PENDING D17 Migration safety policy (`serve` gating + robust migration handling)
- 1.15 PENDING D18 Readiness depth hardening
- 1.16 DONE D21 Coverage measurement and test-depth gates (test inventory thresholds + integration filter gate)

---

## 2.0 Execution Tracks

**Status:** IN_PROGRESS

### 2.1 Reliability Track

**Dimensions:**
- 2.1.1 DONE Complete retry/error-classification coverage for all external side effects
- 2.1.2 PENDING Add durable outbox/dead-letter and reconcile with run-state transitions
- 2.1.3 DONE Standardize retry/backoff metrics for operator visibility

### 2.2 Safety Track

**Dimensions:**
- 2.2.1 PENDING Close execution-boundary gaps (path, hooks, env exposure)
- 2.2.2 IN_PROGRESS Complete exactly-once + idempotency protections for all side effects (PR path done, remaining side effects pending)
- 2.2.3 PENDING Enforce shutdown, cancellation, and thread/allocator correctness invariants

### 2.3 Verification Track

**Dimensions:**
- 2.3.1 IN_PROGRESS Add coverage instrumentation and minimum thresholds (test-depth thresholds live; line-coverage threshold pending)
- 2.3.2 DONE Expand unit tests for pure logic modules
- 2.3.3 DONE Add integration tests for claim/transition/idempotency flows

---

## 3.0 Acceptance Criteria

**Status:** IN_PROGRESS

- [ ] 3.1 All D2/D3/D5/D6/D7/D9/D10 guardrails have verified implementation notes and passing tests
- [ ] 3.2 All D11–D18 safety-critical items are resolved with explicit evidence in tests/runbooks
- [ ] 3.3 Coverage tooling is enabled and enforced in CI with visible artifacts
- [ ] 3.4 M3_001 deferred items mapped to this spec are marked DONE with links to commits/tests

---

## 4.0 Out of Scope

- Event bus durability/replay redesign (tracked in M4_005)
- Observer backend expansion and telemetry export model (tracked in M4_005)
- Secret/versioning evolution beyond guardrail minimum (tracked in M4_005)
