# M18_003 Handoff Notes

**Date:** Mar 31, 2026
**From:** M18_002 session (spec template + preview local implementation)
**To:** M18_003 session (API-backed spec template + SSE preview)

---

## Context

M18_002 shipped `zombiectl spec init` and `zombiectl run --preview` as purely
local CLI features. During review we identified the design problem:

- Language detection was hardcoded extension maps → removed
- Directory ignore lists were hardcoded per-language → removed
- File impact prediction is substring heuristics → should be LLM
- All logic ships in the CLI → server can't improve it without a release

The fix: CLI collects local filesystem facts, server does the thinking.
M18_003 moves both commands to API-backed with SSE streaming for preview.

## What Exists in the CLI (M18_002 state)

Files the new session will modify or remove:

| File | Current role | M18_003 action |
|---|---|---|
| `zombiectl/src/commands/spec_init.js` | local scanner + template generator | keep scanner, remove `generateTemplate()`, add API call |
| `zombiectl/src/commands/run_preview.js` | local ref extractor + matcher | keep `printPreview`/`confIndicator`/`sanitizeDisplay`, remove `extractSpecRefs`/`matchRefsToFiles`, add SSE consumer |
| `zombiectl/src/commands/run_preview_walk.js` | re-exports shared walkDir | keep — CLI still walks local tree |
| `zombiectl/src/lib/walk-dir.js` | shared BFS walker | keep — CLI still needs local file listing |

## Starting Instructions for M18_003 Session

1. Mark `docs/spec/v1/M18_003_API_BACKED_SPEC_PREVIEW.md` as IN_PROGRESS,
   add `**Branch:** m18-003-api-spec-preview`

2. Create worktree and branch from main:
   ```bash
   git worktree add .worktrees/m18-003 -b m18-003-api-spec-preview
   ```

3. Implement server endpoints first (sections 2.1 + 2.2 of the spec),
   then migrate CLI (section 3.0).

4. The SSE consumer in the CLI should use the existing `EventSource` / fetch
   streaming pattern already established in M13/M17 run watch — check
   `zombiectl/src/commands/core.js` commandRunWatch for the pattern.

5. Run full test suite before PR: `bun test zombiectl/test/` — 377 tests
   must pass, new API contract tests must be added.

## API Endpoints to Create on the Server

```
POST /api/spec/template   — returns generated template markdown
POST /api/spec/preview    — SSE stream of { file, confidence } events
```

Both require auth token. Add to server routes before CLI work.

## Current Branch / PR

- Branch: `m18-002-spec-templates-diff-preview`
- PR: usezombie/usezombie#115 (open, all CI passing)
- That PR covers M18_002 only. M18_003 gets its own PR from the new branch.
