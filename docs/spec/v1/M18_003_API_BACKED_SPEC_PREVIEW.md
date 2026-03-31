# M18_003: API-Backed Spec Template Generation and SSE Preview

**Prototype:** v1.0.0
**Milestone:** M18
**Workstream:** 003
**Date:** Mar 31, 2026
**Status:** PENDING
**Priority:** P1 — move spec init and run preview from local heuristics to server-side agent with SSE streaming
**Batch:** B2 — depends on M18_002 (local implementation, now the reference spec)
**Depends on:** M18_002

---

## 1.0 Problem

M18_002 implemented `spec init` and `run --preview` entirely on the CLI:

- Language detection was hardcoded extension maps — removed because an agent knows better
- Directory ignore lists were hardcoded per-language — removed for the same reason
- File impact prediction is substring heuristics — an LLM does this correctly
- All logic ships in CLI binaries — improvements require a new CLI release
- No server visibility into what specs are being generated or what impact is predicted

The right boundary: **CLI collects local filesystem facts, server does the thinking.**

---

## 2.0 API Design

### 2.1 Spec Template Generation

```
POST /api/spec/template
Authorization: Bearer <token>
Content-Type: application/json

{
  "file_paths": ["src/main.go", "tests/main_test.go", ...],
  "makefile_targets": ["lint", "test", "build"],
  "test_patterns": ["*_test.*", "*.test.*"],
  "project_structure": ["src/", "tests/", "docs/"]
}

→ 200 application/json
{
  "template": "# M{N}_001: {Feature Title}\n\n**Prototype:** v1.0.0\n..."
}
```

The server agent reads manifest files from `file_paths` (`go.mod`, `Cargo.toml`,
`package.json`, `pyproject.toml`, `mix.exs`) to detect language. No extension map.

**Dimensions:**
- 2.1.1 PENDING POST /api/spec/template endpoint — validates input, calls agent, returns template
- 2.1.2 PENDING Agent reads manifest files from file_paths to detect language + ecosystem
- 2.1.3 PENDING Returns structured template matching the canonical spec format from CLAUDE.md

### 2.2 SSE Preview Stream

```
POST /api/spec/preview
Authorization: Bearer <token>
Content-Type: application/json
Accept: text/event-stream

{
  "spec_content": "# Feature\n\nEdit `src/foo.go` and `lib/bar.ts`...",
  "file_paths": ["src/foo.go", "lib/bar.ts", "src/util.go", ...]
}

→ 200 text/event-stream
data: {"file":"src/foo.go","confidence":"high"}
data: {"file":"lib/bar.ts","confidence":"medium"}
data: {"file":"src/util.go","confidence":"low"}
data: [DONE]
```

Agent semantically matches spec intent to file paths. Streams results as each
file is scored — gives real-time feedback for large repos without waiting for
full completion.

**Dimensions:**
- 2.2.1 PENDING POST /api/spec/preview endpoint — SSE response, agent streams matches
- 2.2.2 PENDING Agent uses spec content semantically (not substring) to score each file
- 2.2.3 PENDING Each SSE event: `{ file, confidence }` where confidence ∈ high|medium|low
- 2.2.4 PENDING `[DONE]` event signals stream end; client closes connection

---

## 3.0 CLI Migration

### 3.1 spec init

`commandSpecInit` sends collected local facts to the server, writes the returned template.

**Before (M18_002):** scans repo locally, generates template with string interpolation.
**After (M18_003):** scans repo locally for paths + Makefile + test patterns, POSTs to
`/api/spec/template`, writes returned template to disk.

- Remove `generateTemplate()` from the CLI — server owns template generation
- `spec init` becomes auth-required (add to `requireAuth`, remove from `AUTH_EXEMPT_ROUTES`)
- `commandSpecInit` JSON output: `detected.*` fields come from server response

**Dimensions:**
- 3.1.1 PENDING commandSpecInit: POST collected facts to /api/spec/template
- 3.1.2 PENDING Remove generateTemplate() and local template string from CLI
- 3.1.3 PENDING Move spec.init out of AUTH_EXEMPT_ROUTES — requires token

### 3.2 run --preview

`runPreview` sends spec content + local file tree to `/api/spec/preview` SSE stream,
prints matches as they arrive.

**Before (M18_002):** extractSpecRefs() regex + matchRefsToFiles() substring scoring.
**After (M18_003):** sends spec_content + file_paths, renders SSE events as they stream.

- Remove `extractSpecRefs()` and `matchRefsToFiles()` from the CLI
- `printPreview` is retained — renders the streamed match list
- `confIndicator` / `sanitizeDisplay` retained — output formatting stays client-side
- Preview spinner shown while stream is open

**Dimensions:**
- 3.2.1 PENDING runPreview: POST to /api/spec/preview, consume SSE stream
- 3.2.2 PENDING Print each match as its SSE event arrives (streaming UX, not batch)
- 3.2.3 PENDING Remove extractSpecRefs() and matchRefsToFiles() from CLI
- 3.2.4 PENDING Handle stream errors and partial results gracefully

---

## 4.0 Verification

**Status:** PENDING

**Gates:**
- `make lint`
- `make test`

**Dimensions:**
- 4.1 PENDING POST /api/spec/template returns valid spec markdown for Go, Rust, TS, Python repos
- 4.2 PENDING POST /api/spec/preview streams correct high/medium/low matches for known spec fixtures
- 4.3 PENDING CLI spec init writes server-returned template unchanged to disk
- 4.4 PENDING CLI run --preview renders streamed matches in real-time (not after [DONE])
- 4.5 PENDING spec init without token exits with AUTH_REQUIRED, not a local template

---

## 5.0 Acceptance Criteria

**Status:** PENDING

- [ ] 5.1 `zombiectl spec init` calls `/api/spec/template`, writes returned template — no local generation
- [ ] 5.2 `zombiectl run --spec FILE --preview` streams file matches from `/api/spec/preview` SSE
- [ ] 5.3 Language detection works for Go, Rust, TypeScript, Python, Elixir without any extension map
- [ ] 5.4 `spec init` without auth token exits 1 with AUTH_REQUIRED error
- [ ] 5.5 SSE stream renders each match as it arrives — user sees results before stream completes
- [ ] 5.6 All 377+ existing zombiectl tests pass; new API contract tests added

---

## 6.0 Out of Scope

- File content sent to server — only paths and metadata; contents stay local
- Workspace-scoped file tree caching on the server
- Preview for repos not yet connected to a workspace (requires worktree walk milestone)
- Agent-driven directory ignore list (tracked separately)
