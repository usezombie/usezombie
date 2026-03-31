# M20_001: Eliminate Hardcoded Role Constants

**Prototype:** v1.0.0
**Milestone:** M20
**Workstream:** 001
**Date:** Mar 29, 2026
**Status:** IN_PROGRESS
**Branch:** feat/m20-001-eliminate-hardcoded-role-constants
**Priority:** P0 — Hardcoded scout/echo/warden roles prevent custom agent profiles from working end-to-end; blocks workspace-level agent customization
**Batch:** B3
**Depends on:** M16_001 (Gate Loop — DONE), M6_005 (CI Pipeline — DONE)

---

## 1.0 Remove ROLE_SCOUT, ROLE_ECHO, ROLE_WARDEN Constants

**Status:** DONE

The constants `ROLE_SCOUT`, `ROLE_ECHO`, `ROLE_WARDEN` in `topology.zig` and all bare string references to `"scout"`, `"echo"`, `"warden"` as role identifiers must be removed from production code. These are not special roles — they are default agent_ids that get loaded from the pipeline profile config (JSON or DB) when a workspace is first created. Custom profiles define their own role_ids and skill_ids. Any code that checks `== "scout"` or branches on `ROLE_WARDEN` is broken for custom profiles.

**What replaces them:** The default profile JSON (`config/pipeline-default.json` or `agent_config_versions.compiled_profile_json` in DB) defines the stage roles. `defaultProfile()` in `topology.zig` reads from this config file, not from hardcoded constants. The builtin skill registry (`agents.zig`) maps skill_ids to execution backends — skill_ids are resolved at runtime from the profile, not from constants.

**Dimensions:**
- 1.1 ✅ Deleted `pub const ROLE_ECHO`, `ROLE_SCOUT`, `ROLE_WARDEN` from `topology.zig`; `STAGE_PLAN`, `STAGE_IMPLEMENT`, `STAGE_VERIFY` retained (stage IDs, not role assumptions)
- 1.2 ✅ Refactored `defaultProfile()` to load from `config/pipeline-default.json`; falls back to embedded `DEFAULT_PROFILE_JSON` constant if file missing
- 1.3 ✅ Refactored `defaultArtifactName(idx, total)` and `defaultCommitMessage(idx, total)` to use stage position (idx=0→plan, idx=n-1→gate, else→implement)
- 1.4 ✅ Removed `isCoreSkill()`/`isBuiltInSkill()` from `entitlements.zig`, `control_plane.zig`, `proposals_validation.zig`; replaced with dynamic check against `topology.defaultProfile()` skill list

---

## 2.0 Complete SkillRegistry as the Single Resolution Path

**Status:** IN_PROGRESS

The `BUILTIN_SKILLS` array in `agents.zig` must be eliminated — not just made private. Skills are loaded from the active profile at worker startup and registered into a `SkillRegistry`. There is no separate "builtin" vs "custom" category: all skills are equal, all go through the registry.

**Design:** echo/scout/warden runners become default skills preloaded into the registry at startup from `config/pipeline-default.json`. A custom workspace profile with `planner`/`coder`/`reviewer` skill_ids registers its own runners the same way. `resolveBinding()` in `worker_stage_executor.zig` uses only the registry — no BUILTIN_SKILLS fallback.

**Safe implementation sequence:** Write tests first (2.5), then wire registry (2.2), then remove the BUILTIN_SKILLS fallback (2.1), then harden the null guard (2.4). This order ensures the safety net is never removed before the replacement is validated.

**Dimensions (in implementation order):**
- 2.3 ✅ `SkillKind` enum collapsed to single `.custom` variant; all skills use `.kind = .custom`
- 2.5 PENDING Add `prompt_path: ?[]const u8` to `SkillBinding`; update `resolveSystemPrompt()` in `worker_stage_executor.zig` to read from `binding.prompt_path` if set, fall back to `binding.actor` switch for default skills; add tests covering: default skill uses actor dispatch, custom skill with prompt_path uses the path, custom skill without prompt_path gets empty prompt
- 2.6 PENDING Write registry population tests in `agents_test.zig`: populate registry from a profile doc (echo/scout/warden as defaults, planner/coder/reviewer as custom), verify end-to-end binding resolution for both categories; tests must pass before 2.2 lands
- 2.2 PENDING Populate `SkillRegistry` at worker startup (`serve.zig` and `cmd/worker.zig`) from the active profile: register echo/scout/warden runners for default skill_ids with their prompt paths; `cfg.skill_registry` is non-null in all production paths; pass the loaded profile through to `validateSkillPolicies` and `validateProposedChanges` to eliminate repeated `defaultProfile()` disk reads; both `serve.zig` and `cmd/worker.zig` entry points must populate the registry (not just one)
- 2.1 PENDING After 2.6 tests are green and 2.2 is deployed: remove `BUILTIN_SKILLS` private array and `resolveRole()` bypass from `agents.zig`; registry is the only resolution path; this is an atomic deploy with 2.2 — do not land 2.1 without 2.2
- 2.4 PENDING After 2.1: change `WorkerConfig.skill_registry` from `?*const agents.SkillRegistry` to `*const agents.SkillRegistry` (non-optional); update all call sites including test fixtures; `resolveBinding()` no longer has a null guard

---

## 3.0 Lint Gate: No Hardcoded Role Strings

**Status:** DONE

A CI lint check ensures no future code reintroduces hardcoded role references. This runs as part of `make lint-zig` and fails the build if any production Zig file (excluding test files) contains the banned patterns.

**Dimensions:**
- 3.1 ✅ Added `_hardcoded_role_check` to `make/quality.mk`; greps for `ROLE_SCOUT|ROLE_ECHO|ROLE_WARDEN` constants and `eqlIgnoreCase.*"echo/scout/warden"` dispatch comparisons
- 3.2 ✅ `_hardcoded_role_check` wired into `lint-zig` target chain; `make lint-zig` runs it on every invocation
- 3.3 ✅ "No Hardcoded Roles" section added to `docs/contributing/ZIG_RULES.md`

---

## 4.0 Documentation Cleanup

**Status:** DONE

All docs must stop referring to scout/echo/warden as built-in or special roles. They are default agent_ids loaded from config when a workspace is created.

**Dimensions:**
- 4.1 ✅ Updated `docs/contributing/architecture.md` with profile-driven role model description
- 4.2 ✅ Updated `docs/contributing/ZIG_RULES.md` with "No Hardcoded Roles" rule
- 4.3 PENDING — `docs/done/v1/*.md` scrub (role-neutral language; deferred, not blocking)
- 4.4 PENDING — `docs/spec/v1/*.md` scrub (deferred, not blocking)

---

## 5.0 Acceptance Criteria

**Status:** IN_PROGRESS

- [x] 5.1 `grep -rn 'ROLE_SCOUT\|ROLE_ECHO\|ROLE_WARDEN' src/ --include='*.zig' | grep -v '_test.zig'` returns zero matches ✅
- [x] 5.2 No `eqlIgnoreCase` comparisons against `"echo"/"scout"/"warden"` in production Zig files ✅
- [x] 5.3 `make lint-zig` passes with `_hardcoded_role_check` ✅
- [x] 5.4 `make test` passes — all Zig tests green (exit 0) ✅
- [ ] 5.5 Custom profile with role_ids `planner`/`coder`/`reviewer` and matching skill_ids resolves bindings and executes all stages at runtime — requires 2.1–2.4 (registry wire-up) to be complete
- [x] 5.6 `grep -rni 'scout stage\|warden stage\|echo stage' docs/` returns zero matches ✅
- [ ] 5.7 `cfg.skill_registry` is non-null in all production `WorkerConfig` paths (`serve.zig`, `cmd/worker.zig`) — requires 2.2

---

## 6.0 Out of Scope

- Renaming the default profile's stage names (plan/implement/verify are stage_ids, not roles — they stay)
- Removing the Actor enum (.echo, .scout, .warden, .orchestrator) from types.zig — this is the internal execution backend dispatch; separate refactor if needed
- Prompt resolution for custom skill backends (requires Actor enum removal or prompt_path field on SkillBinding — deferred)
- Multi-profile support per workspace (one active profile is the current model)
- Skill marketplace or clawhub registry integration (future milestone)
- Scrubbing role-neutral language in completed/pending spec docs (4.3, 4.4 — deferred)
