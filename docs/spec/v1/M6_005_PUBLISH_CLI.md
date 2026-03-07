# M6_005: Publish `zombiectl` npm Package

**Prototype:** v1.0.0
**Milestone:** M6
**Workstream:** 005
**Date:** Mar 06, 2026
**Status:** PENDING
**Priority:** P1 — distribution gate
**Batch:** B7 — deferred after M6_003
**Depends on:** M4_001 (Implement `zombiectl` CLI Runtime)

---

## 1.0 Singular Function

**Status:** PENDING

Implement one working distribution function: publish and verify `zombiectl` as an installable npm CLI.

**Dimensions:**
- 1.1 PENDING Configure package metadata and executable `bin` mapping
- 1.2 PENDING Validate local link/install (`npm link`, `zombiectl --help`)
- 1.3 PENDING Validate publish readiness (`npm pack`, package contents, versioning)
- 1.4 PENDING Publish package and verify global install behavior

---

## 2.0 Verification Units

**Status:** PENDING

**Dimensions:**
- 2.1 PENDING Unit check: `bin/zombiectl.js` executable and entrypoint valid
- 2.2 PENDING Unit check: package tarball contains expected runtime files only
- 2.3 PENDING Integration check: fresh shell can execute installed `zombiectl`

---

## 3.0 Acceptance Criteria

**Status:** PENDING

- [ ] 3.1 `npm install -g zombiectl` exposes working `zombiectl` command
- [ ] 3.2 Published package behavior matches M4_001 command contract
- [ ] 3.3 Demo evidence captured for local link test and global install test

---

## 4.0 Out of Scope

- Feature changes to command semantics
- Alternative package registries
