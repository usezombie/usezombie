import { readFileSync, readdirSync, existsSync, statSync, writeFileSync, mkdirSync } from "node:fs";
import { join, extname, dirname } from "node:path";

const LANG_EXTENSIONS = new Map([
  [".go", "Go"],
  [".rs", "Rust"],
  [".ts", "TypeScript"],
  [".tsx", "TypeScript"],
  [".js", "JavaScript"],
  [".jsx", "JavaScript"],
  [".mjs", "JavaScript"],
  [".cjs", "JavaScript"],
  [".py", "Python"],
  [".zig", "Zig"],
  [".rb", "Ruby"],
  [".java", "Java"],
  [".kt", "Kotlin"],
  [".c", "C"],
  [".cc", "C++"],
  [".cpp", "C++"],
  [".cs", "C#"],
  [".php", "PHP"],
  [".swift", "Swift"],
  [".scala", "Scala"],
  [".ex", "Elixir"],
  [".exs", "Elixir"],
]);

const IGNORED_DIRS = new Set(["node_modules", ".git", "vendor", "target", "zig-cache", "zig-out", ".worktrees"]);

const MAKEFILE_TARGET_RE = /^([a-zA-Z][a-zA-Z0-9_-]*)\s*:/m;

/**
 * Walk a directory (non-recursive breadth-limited) and collect file paths.
 * Stops at maxDepth to avoid scanning huge trees.
 */
function walkDir(rootPath, maxDepth = 4) {
  const results = [];
  const queue = [{ path: rootPath, depth: 0 }];

  while (queue.length > 0) {
    const { path: current, depth } = queue.shift();
    if (depth > maxDepth) continue;

    let entries;
    try {
      entries = readdirSync(current, { withFileTypes: true });
    } catch {
      continue;
    }

    for (const entry of entries) {
      if (IGNORED_DIRS.has(entry.name)) continue;
      const fullPath = join(current, entry.name);
      if (entry.isDirectory()) {
        queue.push({ path: fullPath, depth: depth + 1 });
      } else if (entry.isFile()) {
        results.push(fullPath);
      }
    }
  }

  return results;
}

/**
 * Detect primary language(s) by file extension frequency.
 * Returns array of language names sorted by count, descending.
 */
export function detectLanguages(files) {
  const counts = new Map();
  for (const f of files) {
    const lang = LANG_EXTENSIONS.get(extname(f).toLowerCase());
    if (lang) counts.set(lang, (counts.get(lang) || 0) + 1);
  }
  if (counts.size === 0) return [];
  const sorted = [...counts.entries()].sort((a, b) => b[1] - a[1]);
  const top = sorted[0][1];
  // include all languages within 20% of the top count (monorepo)
  return sorted.filter(([, c]) => c >= top * 0.2).map(([lang]) => lang);
}

/**
 * Parse Makefile and return list of target names.
 */
export function parseMakeTargets(repoPath) {
  const makefile = join(repoPath, "Makefile");
  if (!existsSync(makefile)) return [];

  let content;
  try {
    content = readFileSync(makefile, "utf8");
  } catch {
    return [];
  }

  const targets = new Set();
  for (const line of content.split("\n")) {
    const m = line.match(/^([a-zA-Z][a-zA-Z0-9_.-]*)\s*:/);
    if (m && !m[1].startsWith(".")) targets.add(m[1]);
  }
  return [...targets];
}

/**
 * Detect test patterns from file paths.
 */
export function detectTestPatterns(files) {
  const patterns = new Set();
  for (const f of files) {
    const base = f.replace(/\\/g, "/");
    if (/(^|\/)tests?\//.test(base)) patterns.add("tests/ directory");
    if (/\.(test|spec)\.[a-z]+$/.test(base)) patterns.add("*.test.* / *.spec.*");
    if (/_test\.[a-z]+$/.test(base)) patterns.add("*_test.*");
    if (/\.test\.[a-z]+$/.test(base)) patterns.add("*.test.*");
  }
  return [...patterns];
}

/**
 * Detect project structure indicators.
 */
export function detectProjectStructure(repoPath) {
  const indicators = [];
  for (const dir of ["src", "tests", "test", "docs", "lib", "pkg", "cmd", "internal"]) {
    if (existsSync(join(repoPath, dir))) indicators.push(`${dir}/`);
  }
  return indicators;
}

/**
 * Scan a repo and return detected context.
 */
export function scanRepo(repoPath) {
  const files = walkDir(repoPath);
  return {
    languages: detectLanguages(files),
    makeTargets: parseMakeTargets(repoPath),
    testPatterns: detectTestPatterns(files),
    projectStructure: detectProjectStructure(repoPath),
    fileCount: files.length,
  };
}

function currentDateStr() {
  const d = new Date();
  const months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
  return `${months[d.getMonth()]} ${String(d.getDate()).padStart(2,"0")}, ${d.getFullYear()}`;
}

/**
 * Generate a spec template markdown string from scan results.
 */
export function generateTemplate(scan) {
  const { languages, makeTargets, testPatterns, projectStructure } = scan;

  const langStr = languages.length > 0 ? languages.join(", ") : "Unknown";
  const isMonorepo = languages.length > 1;

  // Gates section — only include targets that are relevant lint/test/build targets
  const GATE_TARGETS = new Set(["lint","test","build","check","fmt","format","verify","qa","qa-smoke"]);
  const detectedGates = makeTargets.filter((t) => GATE_TARGETS.has(t));

  const gatesBlock = detectedGates.length > 0
    ? detectedGates.map((t) => `- \`make ${t}\``).join("\n")
    : "- _(no Makefile gates detected)_";

  const structureBlock = projectStructure.length > 0
    ? projectStructure.map((d) => `- \`${d}\``).join("\n")
    : "- _(empty or minimal repo)_";

  const langNote = isMonorepo
    ? `Monorepo detected (${langStr}). Scope implementation to the relevant component.`
    : `${langStr} project. Implement the feature below.`;

  return `# M{N}_001: {Feature Title}

**Prototype:** v1.0.0
**Milestone:** M{N}
**Workstream:** 001
**Date:** ${currentDateStr()}
**Status:** PENDING
**Priority:** P1 — {one-line description of what this workstream delivers}
**Batch:** B1
**Depends on:** —

---

## 1.0 Implementation

**Status:** PENDING

${langNote}

**Detected project structure:**
${structureBlock}

**Dimensions:**
- 1.1 PENDING {First implementation step}
- 1.2 PENDING {Second implementation step}
- 1.3 PENDING {Write or update tests}
- 1.4 PENDING {Handle edge cases}

---

## 2.0 Verification

**Status:** PENDING

**Detected gates:**
${gatesBlock}

**Test patterns detected:** ${testPatterns.length > 0 ? testPatterns.join(", ") : "none"}

**Dimensions:**
- 2.1 PENDING All detected gates pass
- 2.2 PENDING New tests cover the feature path
- 2.3 PENDING No regressions in existing tests

---

## 3.0 Acceptance Criteria

**Status:** PENDING

- [ ] 3.1 {Primary success criterion}
- [ ] 3.2 {Secondary success criterion}
- [ ] 3.3 All detected gates pass with no new failures

---

## 4.0 Out of Scope

- {Item not in scope}
- {Another out of scope item}
`;
}

/**
 * commandSpecInit: implement `zombiectl spec init [--path DIR] [--output PATH]`
 */
export async function commandSpecInit(args, ctx, deps) {
  const { parseFlags, writeLine, ui, printJson } = deps;
  const parsed = parseFlags(args);
  const repoPath = parsed.options.path || ".";
  const outputPath = parsed.options.output || "docs/spec/new-feature.md";

  if (!existsSync(repoPath)) {
    writeLine(ctx.stderr, ui.err(`path not found: ${repoPath}`));
    return 2;
  }

  const scan = scanRepo(repoPath);
  const template = generateTemplate(scan);

  // Ensure output directory exists
  const outDir = dirname(outputPath);
  try {
    mkdirSync(outDir, { recursive: true });
    writeFileSync(outputPath, template, "utf8");
  } catch (err) {
    writeLine(ctx.stderr, ui.err(`failed to write template: ${err.message}`));
    return 1;
  }

  if (ctx.jsonMode) {
    printJson(ctx.stdout, {
      output: outputPath,
      detected: {
        languages: scan.languages,
        make_targets: scan.makeTargets,
        test_patterns: scan.testPatterns,
        project_structure: scan.projectStructure,
        file_count: scan.fileCount,
      },
    });
  } else {
    writeLine(ctx.stdout, ui.ok(`template written → ${outputPath}`));
    writeLine(ctx.stdout);
    const rows = [];
    if (scan.languages.length > 0)       rows.push(["languages",       scan.languages.join(", ")]);
    if (scan.makeTargets.length > 0)     rows.push(["make targets",    scan.makeTargets.join(", ")]);
    if (scan.testPatterns.length > 0)    rows.push(["test patterns",   scan.testPatterns.join(", ")]);
    if (scan.projectStructure.length > 0) rows.push(["structure",      scan.projectStructure.join("  ")]);
    if (rows.length > 0) {
      const w = Math.max(...rows.map(([k]) => k.length));
      const sep = ui.dim("  ·  ");
      for (const [k, v] of rows) {
        writeLine(ctx.stdout, `  ${ui.dim(k.padEnd(w))}${sep}${v}`);
      }
      writeLine(ctx.stdout);
    }
    writeLine(ctx.stdout, ui.dim(`${scan.fileCount} file(s) scanned`));
  }

  return 0;
}
