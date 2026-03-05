# M4_007: Runtime Environment Contract and Operator Validation

**Prototype:** v1.0.0
**Milestone:** M4
**Workstream:** 007
**Date:** Mar 05, 2026
**Status:** PENDING
**Priority:** P1 — operator safety baseline
**Depends on:** M3_000 (secrets/schema), M3_004 (Redis streams), M3_006 (Clerk auth), M4_004 (guardrails)

---

## 1.0 Environment Contract Baseline

**Status:** PENDING

Define one authoritative env contract for `zombied` and `zombiectl` operation.

**Dimensions:**
- 1.1 PENDING Core runtime variables (`API_KEY`, `ENCRYPTION_MASTER_KEY`, `LOG_LEVEL`)
- 1.2 PENDING Role-separated DB URLs (`DATABASE_URL_API`, `DATABASE_URL_WORKER`)
- 1.3 PENDING Redis queue URLs (`REDIS_URL_API`, `REDIS_URL_WORKER`)
- 1.4 PENDING GitHub App variables (`GITHUB_APP_ID`, private key, OAuth client pair)
- 1.5 PENDING Clerk variables (`CLERK_SECRET_KEY`, `CLERK_JWKS_URL`, publishable key)
- 1.6 PENDING Worker/limits variables (`WORKER_CONCURRENCY`, `RUN_TIMEOUT_MS`, rate-limit knobs)
- 1.7 PENDING Readiness threshold variables (`READY_MAX_QUEUE_DEPTH`, `READY_MAX_QUEUE_AGE_MS`)

---

## 2.0 Validation and Doctor Semantics

**Status:** PENDING

### 2.1 Fail-Fast Validation

**Dimensions:**
- 2.1.1 PENDING Invalid/missing critical env values fail startup deterministically
- 2.1.2 PENDING Error messages identify exact key and expected format

### 2.2 Doctor Coverage

**Dimensions:**
- 2.2.1 PENDING `zombied doctor` validates DB, Redis, and auth dependency reachability
- 2.2.2 PENDING Security posture checks include role grants and Redis ACL identity
- 2.2.3 PENDING Doctor output remains deterministic and machine-parseable

---

## 3.0 Documentation Canonicalization

**Status:** PENDING

**Dimensions:**
- 3.1 PENDING Remove duplicated env lists across ad-hoc docs and point to one canonical location
- 3.2 PENDING Keep `.env.example` and runtime docs consistent with this contract
- 3.3 PENDING Add operator notes for key rotation windows and migration safety

---

## 4.0 Acceptance Criteria

**Status:** PENDING

- [ ] 4.1 Runtime env contract is singular, explicit, and test-validated
- [ ] 4.2 Doctor checks cover all required operational dependencies
- [ ] 4.3 Documentation drift checks are in place for env contract consistency
- [ ] 4.4 On-call/operator setup is possible without reading handoff trackers

---

## 5.0 Out of Scope

- Secrets-manager provider integrations beyond current v1 implementation
- Cross-region config orchestration
- Full production compliance controls beyond v1
