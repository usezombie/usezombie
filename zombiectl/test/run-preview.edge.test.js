/**
 * run-preview happy path, edge cases, error paths, output fidelity — T1, T2, T3, T4
 */
import { describe, test, expect } from "bun:test";
import {
  extractSpecRefs,
  matchRefsToFiles,
  printPreview,
  confIndicator,
  sanitizeDisplay,
  runPreview,
} from "../src/commands/run_preview.js";
import { Writable } from "node:stream";
import { writeFileSync, chmodSync } from "node:fs";
import { join } from "node:path";
import { makeNoop, makeBufferStream, ui } from "./helpers.js";
import { makeTmp, cleanup, writeLine } from "./helpers-fs.js";

// ── T1 Happy Path ─────────────────────────────────────────────────────────────

describe("T1 printPreview happy path", () => {
  test("prints heading and file count", () => {
    const buf = makeBufferStream();
    printPreview(buf.stream, [
      { file: "src/main.go", confidence: "high" },
      { file: "src/util.go", confidence: "medium" },
    ], { writeLine, ui });
    expect(buf.read()).toContain("Predicted file impact");
    expect(buf.read()).toContain("2 file(s)");
  });

  test("prints all confidence levels", () => {
    const buf = makeBufferStream();
    printPreview(buf.stream, [
      { file: "a.go", confidence: "high" },
      { file: "b.go", confidence: "medium" },
      { file: "c.go", confidence: "low" },
    ], { writeLine, ui });
    const out = buf.read();
    expect(out).toContain("a.go");
    expect(out).toContain("b.go");
    expect(out).toContain("c.go");
  });

  test("empty matches shows info message, not heading", () => {
    const buf = makeBufferStream();
    printPreview(buf.stream, [], { writeLine, ui });
    expect(buf.read()).toContain("no file references detected");
    expect(buf.read()).not.toContain("Predicted file impact");
  });
});

// ── T2 Edge Cases — extractSpecRefs ──────────────────────────────────────────

describe("T2 extractSpecRefs edge cases", () => {
  test("empty string returns empty array", () => {
    expect(extractSpecRefs("")).toEqual([]);
  });

  test("whitespace-only returns empty array", () => {
    expect(extractSpecRefs("   \n\t\n  ")).toEqual([]);
  });

  test("only headings returns empty array", () => {
    expect(extractSpecRefs("# Title\n## Section\n### Sub\n")).toEqual([]);
  });

  test("CRLF line endings handled", () => {
    const refs = extractSpecRefs("Edit `src/foo.go`\r\nand `src/bar.go`\r\n");
    expect(refs).toContain("src/foo.go");
    expect(refs).toContain("src/bar.go");
  });

  test("repeated reference is deduplicated to one entry", () => {
    const md = Array.from({ length: 1000 }, () => "`src/core.go`").join(" ");
    expect(extractSpecRefs(md).filter((r) => r === "src/core.go").length).toBe(1);
  });

  test("single-quoted paths extracted", () => {
    const refs = extractSpecRefs("Edit 'lib/utils.js' here.");
    expect(refs.some((r) => r.includes("utils.js"))).toBe(true);
  });

  test("double-quoted paths extracted", () => {
    const refs = extractSpecRefs(`Fix "src/api/handler.go" now.`);
    expect(refs.some((r) => r.includes("handler.go"))).toBe(true);
  });

  test("binary content (null bytes) does not crash", () => {
    expect(() => extractSpecRefs("src/foo.go\x00\x01binary\x00")).not.toThrow();
  });

  test("ReDoS guard: 10,000-char line completes under 500ms", () => {
    const start = performance.now();
    extractSpecRefs("a".repeat(10000));
    expect(performance.now() - start).toBeLessThan(500);
  });

  test("1MB spec file processed under 3 seconds", () => {
    const block = "Edit `src/file.go` and `lib/util.ts`.\n".repeat(20000);
    const start = performance.now();
    const refs = extractSpecRefs(block);
    expect(performance.now() - start).toBeLessThan(3000);
    expect(refs.length).toBeGreaterThan(0);
  });

  test("workers/ and scripts/ prefixes extracted", () => {
    const refs = extractSpecRefs("Update `workers/processor.go` and `scripts/deploy.sh`.");
    expect(refs.some((r) => r.includes("workers/"))).toBe(true);
    expect(refs.some((r) => r.includes("scripts/"))).toBe(true);
  });
});

// ── T2 Edge Cases — matchRefsToFiles ─────────────────────────────────────────

describe("T2 matchRefsToFiles edge cases", () => {
  test("empty refs + empty files = empty", () => {
    expect(matchRefsToFiles([], [])).toEqual([]);
  });

  test("empty refs with files = empty", () => {
    expect(matchRefsToFiles([], ["src/foo.go"])).toEqual([]);
  });

  test("refs with no matching files = empty", () => {
    expect(matchRefsToFiles(["zzz_nonexistent.go"], ["src/foo.go"])).toEqual([]);
  });

  test("backslash paths normalised before matching", () => {
    const matches = matchRefsToFiles(["src/foo.go"], ["src\\foo.go"]);
    expect(matches.length).toBe(1);
  });

  test("each file appears at most once", () => {
    const matches = matchRefsToFiles(["src/foo.go", "foo.go", "foo"], ["src/foo.go"]);
    const paths = matches.map((m) => m.file);
    expect(paths.length).toBe(new Set(paths).size);
  });

  test("results sorted high → medium → low", () => {
    const matches = matchRefsToFiles(
      ["src/commands/exact.js", "commands", "cmd"],
      ["src/commands/exact.js", "src/commands/other.js", "cmd/main.go"],
    );
    const order = { high: 0, medium: 1, low: 2 };
    for (let i = 1; i < matches.length; i++) {
      expect(order[matches[i].confidence]).toBeGreaterThanOrEqual(order[matches[i - 1].confidence]);
    }
  });

  test("1,000 refs × 1,000 files completes under 5s", () => {
    const refs = Array.from({ length: 1000 }, (_, i) => `nomatch${i}.xyz`);
    const files = Array.from({ length: 1000 }, (_, i) => `src/file${i}.go`);
    const start = performance.now();
    matchRefsToFiles(refs, files);
    expect(performance.now() - start).toBeLessThan(5000);
  });

  test("deeply nested path ref does not cause stack overflow", () => {
    const deep = "src/" + "level/".repeat(100) + "file.go";
    expect(() => matchRefsToFiles([deep], [deep])).not.toThrow();
  });
});

// ── T3 Error Paths — runPreview ───────────────────────────────────────────────

describe("T3 runPreview error paths", () => {
  test("nonexistent spec file returns null and error message", async () => {
    const err = makeBufferStream();
    const result = await runPreview("/no/such/file.md", ".", { stdout: makeNoop(), stderr: err.stream }, { writeLine, ui });
    expect(result).toBeNull();
    expect(err.read()).toContain("spec file not found");
  });

  test("unreadable spec file returns null (non-root)", async () => {
    if (process.getuid?.() === 0) return;
    const tmp = makeTmp();
    const f = join(tmp, "unreadable.md");
    writeFileSync(f, "# spec");
    chmodSync(f, 0o000);
    try {
      const err = makeBufferStream();
      const result = await runPreview(f, tmp, { stdout: makeNoop(), stderr: err.stream }, { writeLine, ui });
      expect(result).toBeNull();
      expect(err.read()).toContain("failed to read");
    } finally { chmodSync(f, 0o644); cleanup(tmp); }
  });

  test("empty spec file returns { matches: [] }, not null", async () => {
    const tmp = makeTmp();
    const f = join(tmp, "empty.md");
    writeFileSync(f, "");
    try {
      const result = await runPreview(f, tmp, { stdout: makeNoop(), stderr: makeNoop() }, { writeLine, ui });
      expect(result).not.toBeNull();
      expect(result.matches).toEqual([]);
    } finally { cleanup(tmp); }
  });

  test("spec file with only whitespace returns empty matches", async () => {
    const tmp = makeTmp();
    const f = join(tmp, "blank.md");
    writeFileSync(f, "   \n\t\n  ");
    try {
      const result = await runPreview(f, tmp, { stdout: makeNoop(), stderr: makeNoop() }, { writeLine, ui });
      expect(result.matches).toEqual([]);
    } finally { cleanup(tmp); }
  });
});

// ── T4 Output Fidelity ────────────────────────────────────────────────────────

describe("T4 confIndicator fidelity", () => {
  test("non-TTY returns bracket labels for all levels", () => {
    const noTTY = { isTTY: false };
    expect(confIndicator("high", noTTY)).toBe("[HIGH]");
    expect(confIndicator("medium", noTTY)).toBe("[MED] ");
    expect(confIndicator("low", noTTY)).toBe("[LOW] ");
  });

  test("TTY returns ANSI escape sequence", () => {
    const saved = process.env.NO_COLOR;
    delete process.env.NO_COLOR;
    try {
      expect(confIndicator("high", { isTTY: true })).toContain("\u001b[");
    } finally {
      if (saved !== undefined) process.env.NO_COLOR = saved;
      else delete process.env.NO_COLOR;
    }
  });

  test("NO_COLOR=1 suppresses ANSI even on TTY", () => {
    const saved = process.env.NO_COLOR;
    process.env.NO_COLOR = "1";
    try {
      expect(confIndicator("high", { isTTY: true })).not.toContain("\u001b[");
    } finally {
      if (saved !== undefined) process.env.NO_COLOR = saved;
      else delete process.env.NO_COLOR;
    }
  });

  test("unknown confidence value does not throw", () => {
    expect(() => confIndicator("unknown", { isTTY: false })).not.toThrow();
  });
});

describe("T4 sanitizeDisplay fidelity", () => {
  test("strips ANSI codes from filenames", () => {
    expect(sanitizeDisplay("\u001b[31mRED\u001b[0m")).toBe("RED");
  });

  test("strips null bytes", () => {
    expect(sanitizeDisplay("foo\x00bar")).toBe("foobar");
  });

  test("passes clean path unchanged", () => {
    const p = "src/commands/core.js";
    expect(sanitizeDisplay(p)).toBe(p);
  });

  test("empty string returns empty string", () => {
    expect(sanitizeDisplay("")).toBe("");
  });

  test("only escape codes returns empty string", () => {
    expect(sanitizeDisplay("\u001b[1m\u001b[31m\u001b[0m")).toBe("");
  });
});
