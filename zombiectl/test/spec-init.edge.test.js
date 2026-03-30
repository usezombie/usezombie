/**
 * spec-init edge cases and error paths — T2, T3
 */
import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { detectLanguages, parseMakeTargets, detectTestPatterns, commandSpecInit } from "../src/commands/spec_init.js";
import { mkdirSync, writeFileSync, chmodSync } from "node:fs";
import { join } from "node:path";
import { makeNoop, makeBufferStream, ui } from "./helpers.js";
import { makeTmp, cleanup, parseFlags, writeLine } from "./helpers-fs.js";

// ── T2 detectLanguages ────────────────────────────────────────────────────────

describe("T2 detectLanguages edge cases", () => {
  test("empty file list returns empty array", () => {
    expect(detectLanguages([])).toEqual([]);
  });

  test("only binary/media files returns empty", () => {
    expect(detectLanguages(["img.png", "data.bin", "font.woff2"])).toEqual([]);
  });

  test("files with no extension returns empty", () => {
    expect(detectLanguages(["Makefile", "Dockerfile", "LICENSE"])).toEqual([]);
  });

  test("case-insensitive extension matching (.GO, .Go)", () => {
    expect(detectLanguages(["main.GO", "lib.Go"])).toEqual(["Go"]);
  });

  test("50/50 language split includes both", () => {
    const files = [
      ...Array.from({ length: 10 }, (_, i) => `a${i}.rs`),
      ...Array.from({ length: 10 }, (_, i) => `b${i}.go`),
    ];
    const langs = detectLanguages(files);
    expect(langs).toContain("Rust");
    expect(langs).toContain("Go");
  });

  test("single language at 80% dominance excludes minority below 20% threshold", () => {
    const files = [
      ...Array.from({ length: 100 }, (_, i) => `a${i}.py`),
      ...Array.from({ length: 5 }, (_, i) => `b${i}.ts`),
    ];
    const langs = detectLanguages(files);
    expect(langs).toContain("Python");
    expect(langs).not.toContain("TypeScript");
  });

  test("unicode filenames do not crash language detection", () => {
    const files = ["src/日本語.go", "lib/café.py", "tests/αβγ.js"];
    expect(() => detectLanguages(files)).not.toThrow();
  });

  test("10,000-file list is deterministic", () => {
    const files = Array.from({ length: 5000 }, (_, i) => `src/f${i}.go`)
      .concat(Array.from({ length: 5000 }, (_, i) => `web/c${i}.ts`));
    const langs = detectLanguages(files);
    expect(langs).toContain("Go");
    expect(langs).toContain("TypeScript");
    // second call is identical
    expect(detectLanguages(files)).toEqual(langs);
  });

  test(".mjs and .cjs counted as JavaScript", () => {
    expect(detectLanguages(["a.mjs", "b.cjs"])).toContain("JavaScript");
  });

  test(".exs counted as Elixir", () => {
    expect(detectLanguages(["mix.exs"])).toContain("Elixir");
  });
});

// ── T2 parseMakeTargets ───────────────────────────────────────────────────────

describe("T2 parseMakeTargets edge cases", () => {
  let tmp;
  beforeEach(() => { tmp = makeTmp(); });
  afterEach(() => cleanup(tmp));

  test("empty Makefile returns empty array", () => {
    writeFileSync(join(tmp, "Makefile"), "");
    expect(parseMakeTargets(tmp)).toEqual([]);
  });

  test("comment-only Makefile returns empty array", () => {
    writeFileSync(join(tmp, "Makefile"), "# comment\n# another\n");
    expect(parseMakeTargets(tmp)).toEqual([]);
  });

  test("recipe lines not mistaken for targets", () => {
    writeFileSync(join(tmp, "Makefile"), "build:\n\techo build\n\techo done\n");
    const targets = parseMakeTargets(tmp);
    expect(targets).toContain("build");
    expect(targets.length).toBe(1);
  });

  test(".PHONY declaration excluded from targets", () => {
    writeFileSync(join(tmp, "Makefile"), ".PHONY: all\nall:\n\techo all\n");
    expect(parseMakeTargets(tmp)).not.toContain(".PHONY");
    expect(parseMakeTargets(tmp)).toContain("all");
  });

  test("numeric suffix in target name parsed correctly", () => {
    writeFileSync(join(tmp, "Makefile"), "test1:\n\techo\ntest2:\n\techo\n");
    const t = parseMakeTargets(tmp);
    expect(t).toContain("test1");
    expect(t).toContain("test2");
  });

  test("CRLF line endings handled", () => {
    writeFileSync(join(tmp, "Makefile"), "build:\r\n\techo\r\nlint:\r\n\techo\r\n");
    const t = parseMakeTargets(tmp);
    expect(t).toContain("build");
    expect(t).toContain("lint");
  });

  test("200-target Makefile parsed without crash", () => {
    const content = Array.from({ length: 200 }, (_, i) => `target${i}:\n\techo\n`).join("\n");
    writeFileSync(join(tmp, "Makefile"), content);
    expect(parseMakeTargets(tmp).length).toBe(200);
  });

  test("no Makefile returns empty array without throwing", () => {
    expect(parseMakeTargets(tmp)).toEqual([]);
  });

  test("hyphens and underscores in target names parsed", () => {
    writeFileSync(join(tmp, "Makefile"), "lint-zig:\n\tzig fmt\ntest_unit:\n\tbun test\n");
    const t = parseMakeTargets(tmp);
    expect(t).toContain("lint-zig");
    expect(t).toContain("test_unit");
  });
});

// ── T2 detectTestPatterns ─────────────────────────────────────────────────────

describe("T2 detectTestPatterns edge cases", () => {
  test("empty file list returns empty", () => {
    expect(detectTestPatterns([])).toEqual([]);
  });

  test("deeply nested test dir matched", () => {
    const p = detectTestPatterns(["src/deep/nested/tests/foo_test.go"]);
    expect(p).toContain("tests/ directory");
  });

  test(".spec.ts detected", () => {
    const p = detectTestPatterns(["src/foo.spec.ts"]);
    expect(p.some((x) => x.includes("spec"))).toBe(true);
  });

  test("100 files with same pattern does not produce duplicate entries", () => {
    const files = Array.from({ length: 100 }, (_, i) => `src/f${i}.test.js`);
    const p = detectTestPatterns(files);
    expect(p.filter((x) => x.includes("test")).length).toBeLessThanOrEqual(2);
  });

  test("test/ at repo root matched", () => {
    const p = detectTestPatterns(["test/foo_test.go"]);
    expect(p).toContain("tests/ directory");
  });
});

// ── T3 commandSpecInit error paths ────────────────────────────────────────────

describe("T3 commandSpecInit error paths", () => {
  let tmp;
  beforeEach(() => { tmp = makeTmp(); });
  afterEach(() => cleanup(tmp));

  test("nonexistent --path exits 2 with error message", async () => {
    const errBuf = makeBufferStream();
    const ctx = { stdout: makeNoop(), stderr: errBuf.stream, jsonMode: false };
    const code = await commandSpecInit(["--path", "/nonexistent/xyz"], ctx, {
      parseFlags, writeLine, ui, printJson: () => {},
    });
    expect(code).toBe(2);
    expect(errBuf.read()).toContain("path not found");
  });

  test("unwritable output dir exits 1 gracefully (non-root)", async () => {
    if (process.getuid?.() === 0) return;
    const roDir = join(tmp, "ro");
    mkdirSync(roDir, { recursive: true });
    chmodSync(roDir, 0o555);
    const errBuf = makeBufferStream();
    const ctx = { stdout: makeNoop(), stderr: errBuf.stream, jsonMode: false };
    const code = await commandSpecInit(
      ["--path", tmp, "--output", join(roDir, "sub", "out.md")],
      ctx,
      { parseFlags, writeLine, ui, printJson: () => {} },
    );
    expect(code).toBe(1);
    chmodSync(roDir, 0o755);
  });

  test("missing --path argument falls back to default '.' without crash", async () => {
    const ctx = { stdout: makeNoop(), stderr: makeNoop(), jsonMode: false };
    // Pass no --path flag — should use default "." which exists
    const code = await commandSpecInit(
      ["--output", join(tmp, "out.md")],
      ctx,
      { parseFlags, writeLine, ui, printJson: () => {} },
    );
    expect([0, 1]).toContain(code); // may fail if CWD has no perms, but must not throw
  });
});
