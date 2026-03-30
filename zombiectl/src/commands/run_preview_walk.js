import { readdirSync } from "node:fs";
import { join } from "node:path";

const IGNORED_DIRS = new Set(["node_modules", ".git", "vendor", "target", "zig-cache", "zig-out", ".worktrees"]);

/**
 * Walk a directory for the preview feature.
 * Returns absolute file paths up to maxDepth.
 */
export function walkDirForPreview(rootPath, maxDepth = 5) {
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
