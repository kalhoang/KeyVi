#!/usr/bin/env -S python3 -I
# SPDX-License-Identifier: LicenseRef-App-Pending
"""Nightly dependency audit (QA-R24, PLT-R104, PLT-R910).

For every committed Package.resolved (SwiftPM pins of the engine, AppCore and the app):
  - every pin must be an exact version (a `version` in the pin state), not a branch or bare revision
  - the shipping app may depend on Sparkle only (PLT-R104): any other pin in Config/Package.resolved, the
    app's resolved file that project.yml copies into the generated project, fails the audit (the packages'
    own Package.resolved files may hold test-only dependencies)
  - each pinned version is checked against the GitHub Advisory Database (ecosystem swift) through
    `gh api /advisories`; any advisory affecting the pinned version fails the audit
Also reports Package.swift manifests without a committed Package.resolved next to them when they
declare remote dependencies (local path dependencies have no pins).

Usage: python3 -I scripts/dependency-audit.py [--offline] [--root DIR]
--offline skips the advisory query (pin hygiene only).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
RUNTIME_ALLOWED = {"sparkle"}
APP_RESOLVED = Path("Config") / "Package.resolved"
SKIP_DIRS = {".git", ".build", "node_modules", "DerivedData", "dist"}


def find_files(root: Path, name: str) -> list[Path]:
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not d.startswith(".build")
                       and not d.endswith(".xcodeproj")]
        if name in filenames:
            found.append(Path(dirpath) / name)
    return sorted(found)


def pins_of(path: Path) -> list[dict]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if "pins" in data:
        return data["pins"]
    return data.get("object", {}).get("pins", [])


def advisories(location: str, version: str) -> list[dict]:
    match = re.match(r"^(?:https?://)?(github\.com/[^/]+/[^/.]+?)(?:\.git)?/?$", location)
    if not match:
        return []
    package = match.group(1)
    result = subprocess.run(
        ["gh", "api", "-X", "GET", "/advisories", "-f", "ecosystem=swift", "-f", f"affects={package}@{version}",
         "-f", "per_page=100"],
        capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise SystemExit(f"advisory query failed for {package}: {result.stderr.strip()}")
    return json.loads(result.stdout or "[]")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="SwiftPM dependency audit (QA-R24).")
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--root", default=str(REPO_ROOT))
    args = parser.parse_args(argv)
    root = Path(args.root)

    problems = []
    rows = []
    resolved_files = find_files(root, "Package.resolved")
    for manifest in find_files(root, "Package.swift"):
        text = manifest.read_text(encoding="utf-8")
        # Local `.package(path:)` dependencies are never pinned; only remote ones need a Package.resolved.
        if re.search(r"\.package\s*\(\s*(?:name:\s*\"[^\"]*\"\s*,\s*)?(?:url|id):", text) \
                and not (manifest.parent / "Package.resolved").exists():
            problems.append(f"{manifest.relative_to(root)} declares dependencies but has no committed Package.resolved")
    for path in resolved_files:
        rel = path.relative_to(root)
        for pin in pins_of(path):
            identity = (pin.get("identity") or pin.get("package") or "?").lower()
            location = pin.get("location") or pin.get("repositoryURL") or ""
            state = pin.get("state", {})
            version = state.get("version")
            if not version:
                problems.append(f"{rel}: {identity} is pinned to a branch or revision, not an exact version")
                rows.append((str(rel), identity, state.get("branch") or state.get("revision", "?")[:12], "unpinned"))
                continue
            status = "ok"
            if not args.offline:
                found = advisories(location, version)
                if found:
                    ids = ", ".join(a.get("ghsa_id", "?") for a in found)
                    problems.append(f"{rel}: {identity} {version} is affected by {ids}")
                    status = f"ADVISORY {ids}"
            if rel == APP_RESOLVED and identity not in RUNTIME_ALLOWED:
                problems.append(f"{rel}: {identity} is a runtime dependency of the app; PLT-R104 allows Sparkle only")
                status += " (not Sparkle, PLT-R104)"
            rows.append((str(rel), identity, version, status))

    lines = ["### Dependency audit", "", "| Package.resolved | Package | Version | Status |", "|---|---|---|---|"]
    lines += [f"| `{a}` | {b} | {c} | {d} |" for a, b, c, d in rows] or ["| (none) | | | |"]
    text = "\n".join(lines) + "\n"
    print(text)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(text)
    for problem in problems:
        print(("::error::" if os.environ.get("GITHUB_ACTIONS") else "error: ") + problem, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
