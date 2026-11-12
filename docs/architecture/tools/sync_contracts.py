#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-App-Pending
"""Splice compile-checked contract sources into docs/architecture/contracts.md.

Markers in the Markdown:
    <!-- include: Packages/AppCore/Sources/AppModel/Identifiers.swift -->
    ...generated fenced block...
    <!-- /include -->
Optional `until="text"` stops before the first line containing `text`.

Usage: python3 -I docs/architecture/tools/sync_contracts.py [--check]
--check exits 1 when contracts.md is stale (for CI).
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
DOC = ROOT / "docs" / "architecture" / "contracts.md"
PATTERN = re.compile(
    r'(<!-- include: (?P<path>[^ ]+?)(?: until="(?P<until>[^"]+)")? -->\n)(?P<body>.*?)(<!-- /include -->)',
    re.S,
)


def render(match: re.Match) -> str:
    path = ROOT / match.group("path")
    lines = path.read_text(encoding="utf-8").splitlines()
    until = match.group("until")
    if until:
        for index, line in enumerate(lines):
            if until in line:
                lines = lines[:index]
                break
    while lines and not lines[-1].strip():
        lines.pop()
    language = "swift" if path.suffix == ".swift" else ("xml" if path.suffix == ".plist" else "")
    block = "```" + language + "\n" + "\n".join(lines) + "\n```\n"
    return match.group(1) + block + match.group(5)


def main() -> int:
    original = DOC.read_text(encoding="utf-8")
    updated = PATTERN.sub(render, original)
    if "--check" in sys.argv:
        if updated != original:
            print("contracts.md is stale: run docs/architecture/tools/sync_contracts.py", file=sys.stderr)
            return 1
        return 0
    DOC.write_text(updated, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
