#!/usr/bin/env python3
"""Assert (method, path) parity between src/http/route_manifest.zig and
public/openapi.json.

Reads:
  - src/http/route_manifest.zig (canonical server route list; maintained by
    engineers alongside match() in router.zig).
  - public/openapi.json (build artifact produced by `make openapi`).

Fails with a readable diff when either side has a (method, path) the other
does not. Prints `OK` with the parity count on success.

Does NOT enforce operation-level details (operationId, tags, response
shapes) — those live in `scripts/check_openapi_errors.py` and Redocly's
own lint rules (see .redocly.yaml). This script is a pure set-parity
gate on the route surface.
"""

from __future__ import annotations

import json
import pathlib
import re
import sys

MANIFEST_PATH = pathlib.Path("src/http/route_manifest.zig")
SPEC_PATH = pathlib.Path("public/openapi.json")

# Matches `.{ .method = "POST", .path = "/v1/foo/{bar}" },` entries in the
# manifest's initializer list. Whitespace and order are flexible.
ENTRY_RE = re.compile(
    r'\.method\s*=\s*"(?P<method>[A-Z]+)"\s*,\s*\.path\s*=\s*"(?P<path>[^"]+)"'
)

HTTP_METHODS = {"get", "post", "put", "patch", "delete", "head", "options"}


def parse_manifest(src: str) -> "set[tuple[str, str]]":
    return {(m.group("method"), m.group("path")) for m in ENTRY_RE.finditer(src)}


def parse_spec(spec: dict) -> "set[tuple[str, str]]":
    pairs: "set[tuple[str, str]]" = set()
    for path, methods in spec.get("paths", {}).items():
        for method, _op in (methods or {}).items():
            if method.lower() in HTTP_METHODS:
                pairs.add((method.upper(), path))
    return pairs


def main() -> int:
    if not MANIFEST_PATH.exists():
        print(f"FAIL: {MANIFEST_PATH} not found", file=sys.stderr)
        return 1
    if not SPEC_PATH.exists():
        print(f"FAIL: {SPEC_PATH} not found — run `make openapi` first", file=sys.stderr)
        return 1

    manifest_pairs = parse_manifest(MANIFEST_PATH.read_text())
    if not manifest_pairs:
        print(
            f"FAIL: {MANIFEST_PATH} parsed zero entries — check the "
            f"RouteManifestEntry initializer syntax",
            file=sys.stderr,
        )
        return 1

    spec_pairs = parse_spec(json.loads(SPEC_PATH.read_text()))

    missing_in_spec = manifest_pairs - spec_pairs
    missing_in_manifest = spec_pairs - manifest_pairs

    if missing_in_spec or missing_in_manifest:
        if missing_in_spec:
            print("FAIL: server has (method, path) not in public/openapi.json:")
            for method, path in sorted(missing_in_spec):
                print(f"  {method:<6} {path}")
            print(
                "  → fix: add the operation to public/openapi/paths/<tag>.yaml "
                "and run `make openapi`."
            )
        if missing_in_manifest:
            print("FAIL: public/openapi.json has (method, path) not in server:")
            for method, path in sorted(missing_in_manifest):
                print(f"  {method:<6} {path}")
            print(
                "  → fix: add the route to src/http/route_manifest.zig AND wire "
                "match() + handler in router.zig / server.zig."
            )
        return 1

    print(
        f"OK: route_manifest.zig ↔ openapi.json parity "
        f"({len(manifest_pairs)} method/path pairs)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
