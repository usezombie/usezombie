# M5_006: Enable PostHog Tracking In `zombied`

**Prototype:** v1.0.0
**Milestone:** M5
**Workstream:** 006
**Date:** Mar 06, 2026
**Status:** PENDING
**Priority:** P1 — operational analytics baseline
**Batch:** B2 — needs M5_001 and M5_002
**Depends on:** M5_001 (Build `posthog-zig` Analytics SDK for Zig), M5_002 (Operate Multi-Tenant Harness Control Plane)

---

## 1.0 Singular Function

**Status:** PENDING

Implement one working telemetry function: `zombied` emits deterministic run/control-plane events to PostHog.

**Dimensions:**
- 1.1 PENDING Initialize server-side PostHog client in `zombied` runtime
- 1.2 PENDING Capture lifecycle events (`run_started`, `run_completed`, `run_failed`, `agent_completed`)
- 1.3 PENDING Capture policy events (`entitlement_rejected`, `profile_activated`)
- 1.4 PENDING Add failure-safe async flushing without blocking run execution

---

## 2.0 Verification Units

**Status:** PENDING

**Dimensions:**
- 2.1 PENDING Unit test: event envelope contains required IDs (`workspace_id`, `run_id`)
- 2.2 PENDING Integration test: successful and failed runs emit expected events once
- 2.3 PENDING Integration test: PostHog outage does not fail core run execution path

---

## 3.0 Acceptance Criteria

**Status:** PENDING

- [ ] 3.1 Core `zombied` lifecycle events are visible in PostHog with stable schema
- [ ] 3.2 Analytics path is non-blocking and outage-tolerant
- [ ] 3.3 Demo evidence captured for run lifecycle events in PostHog

---

## 4.0 Out of Scope

- Website analytics instrumentation (tracked in M5_005)
- Advanced attribution modeling
