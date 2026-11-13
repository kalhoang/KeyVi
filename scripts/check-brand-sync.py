#!/usr/bin/env -S python3 -I
# SPDX-License-Identifier: GPL-3.0-or-later
"""Checks that Config/Brand.xcconfig and scripts/brand.env carry the same brand values (CLAUDE.md "Name
(temporary)"). The xcconfig is what the app reads; brand.env is what scripts and the site read. Both list
the same APP_* keys: display name, slug, bundle IDs, site host, and the optional APP_SUPPORT_EMAIL,
APP_REPOSITORY_URL and APP_LEGACY_STORAGE_FOLDER_NAMES (ADR 0307). scripts/rename-app.sh keeps them in sync;
this check catches a hand edit of one file only (for example Pa filling the support address).

xcconfig rules handled: `//` starts a comment, so URLs are written `https:/$()/host/...`; the empty
`$()` is removed before comparing.

Usage: python3 -I scripts/check-brand-sync.py [--xcconfig FILE] [--env FILE]
Exit status: 0 in sync, 1 a key differs or is missing in one file.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
KEY_LINE = re.compile(r"^\s*(?:export\s+)?(APP_[A-Z0-9_]+)\s*=\s*(.*?)\s*$")


def parse_xcconfig(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.split("//", 1)[0]
        match = KEY_LINE.match(line)
        if match:
            values[match.group(1)] = match.group(2).replace("$()", "").strip()
    return values


def parse_env(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in text.splitlines():
        if raw.lstrip().startswith("#"):
            continue
        match = KEY_LINE.match(raw)
        if match:
            value = match.group(2)
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            values[match.group(1)] = value
    return values


def differences(xcconfig: dict[str, str], env: dict[str, str]) -> list[str]:
    problems = []
    for key in sorted(set(xcconfig) | set(env)):
        if key not in env:
            problems.append(f"{key} is in Brand.xcconfig but missing from brand.env")
        elif key not in xcconfig:
            problems.append(f"{key} is in brand.env but missing from Brand.xcconfig")
        elif xcconfig[key] != env[key]:
            problems.append(f"{key} differs: Brand.xcconfig {xcconfig[key]!r}, brand.env {env[key]!r}")
    return problems


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Check that Brand.xcconfig and brand.env agree.")
    parser.add_argument("--xcconfig", default=str(REPO_ROOT / "Config" / "Brand.xcconfig"))
    parser.add_argument("--env", default=str(REPO_ROOT / "scripts" / "brand.env"))
    args = parser.parse_args(argv)
    try:
        xcconfig = parse_xcconfig(Path(args.xcconfig).read_text(encoding="utf-8"))
        env = parse_env(Path(args.env).read_text(encoding="utf-8"))
    except OSError as error:
        print(f"check-brand-sync: {error}", file=sys.stderr)
        return 1
    problems = differences(xcconfig, env)
    for problem in problems:
        print(f"check-brand-sync: {problem}", file=sys.stderr)
    if problems:
        print("check-brand-sync: edit both files, or use scripts/rename-app.sh for the name", file=sys.stderr)
        return 1
    print(f"check-brand-sync: {len(env)} brand value(s) in sync", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
