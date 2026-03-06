# M5_005: Enable PostHog Tracking In Website

**Prototype:** v1.0.0
**Milestone:** M5
**Workstream:** 005
**Date:** Mar 06, 2026
**Status:** PENDING
**Priority:** P1 — product analytics baseline
**Batch:** B1 — uses PostHog JS SDK, not posthog-zig
**Depends on:** None

---

## 1.0 Singular Function

**Status:** PENDING

Implement one working telemetry function: website emits PostHog events for core conversion and navigation actions.

**Dimensions:**
- 1.1 PENDING Initialize PostHog client with environment-gated config
- 1.2 PENDING Capture core events (`signup_started`, `signup_completed`, `team_pilot_booking_started`)
- 1.3 PENDING Enforce event schema naming and required properties
- 1.4 PENDING Add privacy-safe guardrails for event payloads

---

## 2.0 Verification Units

**Status:** PENDING

**Dimensions:**
- 2.1 PENDING Unit test: event helper emits expected schema
- 2.2 PENDING Integration test: core CTA clicks produce PostHog requests
- 2.3 PENDING Integration test: disabled analytics mode emits no external calls

---

## 3.0 Acceptance Criteria

**Status:** PENDING

- [ ] 3.1 Core website conversion events arrive in PostHog reliably
- [ ] 3.2 Event payloads are schema-consistent and privacy-safe
- [ ] 3.3 Demo evidence captured for live event emission from website actions

---

## 4.0 Out of Scope

- Zombied runtime event tracking (tracked in M5_006)
- Complex analytics dashboard design
