#!/usr/bin/env -S python3 -I
# SPDX-License-Identifier: LicenseRef-App-Pending
"""Validates compat/matrix.json against compat/schema/matrix.schema.json (QA-R17, PRD-R35).

The schema is the source of truth for the field names and values that the in-app Apps page and the website
matrix read (compat/SCRIPT.md section 5). Also rejects two app-level rows for one bundleId and two scoped
rows with the same bundleId, scope and displayName.
A missing matrix passes (nothing is verified yet) unless --require.

Usage: python3 -I scripts/check-matrix.py [--matrix FILE] [--schema FILE] [--require]
Exit status: 0 valid or absent, 1 invalid.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True  # keep scripts/lib free of __pycache__
sys.path.insert(0, str(REPO_ROOT / "scripts" / "lib"))

import jsonschema_lite  # noqa: E402


def problems(doc: object, schema: dict) -> list[str]:
    """Schema errors plus duplicate rows.

    Each bundleId has at most one app-level row (no scope, or scope "app"); that row drives the in-app Apps
    page (PRD-R34, PRD-R35, MatrixDocument.appEntry). Scoped rows (webApp, inApp) describe a web app or a
    mode inside the app, so several may share a bundleId, but never the same scope and displayName.
    """
    found = jsonschema_lite.validate(doc, schema)
    app_rows: dict[str, int] = {}
    scoped_rows: dict[tuple[str, str, str], int] = {}
    entries = doc.get("entries", []) if isinstance(doc, dict) else []
    for index, entry in enumerate(entries if isinstance(entries, list) else []):
        if not isinstance(entry, dict) or not isinstance(entry.get("bundleId"), str):
            continue
        bundle = entry["bundleId"]
        scope = entry.get("scope") or "app"
        if scope == "app":
            if bundle in app_rows:
                found.append(f"$.entries[{index}]: bundleId {bundle} already used by entries[{app_rows[bundle]}]")
            app_rows.setdefault(bundle, index)
            continue
        key = (bundle, str(scope), str(entry.get("displayName", "")))
        if key in scoped_rows:
            found.append(
                f"$.entries[{index}]: bundleId {bundle} scope {scope} '{key[2]}' already used by "
                f"entries[{scoped_rows[key]}]"
            )
        scoped_rows.setdefault(key, index)
    return found


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Validate compat/matrix.json against its JSON Schema.")
    parser.add_argument("--matrix", default=str(REPO_ROOT / "compat" / "matrix.json"))
    parser.add_argument("--schema", default=str(REPO_ROOT / "compat" / "schema" / "matrix.schema.json"))
    parser.add_argument("--require", action="store_true", help="fail when the matrix file is missing")
    args = parser.parse_args(argv)

    matrix = Path(args.matrix)
    if not matrix.exists():
        print(f"check-matrix: {matrix} not found", file=sys.stderr)
        return 1 if args.require else 0
    try:
        doc = json.loads(matrix.read_text(encoding="utf-8"))
        schema = json.loads(Path(args.schema).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"check-matrix: {error}", file=sys.stderr)
        return 1
    found = problems(doc, schema)
    for problem in found:
        print(f"check-matrix: {problem}", file=sys.stderr)
    count = len(doc.get("entries", [])) if isinstance(doc, dict) else 0
    print(f"check-matrix: {count} entr{'y' if count == 1 else 'ies'}, {len(found)} problem(s)", file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
