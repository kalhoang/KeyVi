#!/usr/bin/env -S python3 -I
# SPDX-License-Identifier: GPL-3.0-or-later
"""Static check: no shipped compatibility rule emits forward delete (PLT-R407, section 4 acceptance).

The rules schema has no forward-delete strategy. This check fails if any value or key in the rules
file (defaults, rules, actions, params) mentions forward delete in any spelling, refers to the
forward-delete virtual keycode (kVK_ForwardDelete, 0x75 = 117) through a key-code style parameter,
or sets a delete direction/key other than backspace.

Usage: python3 -I scripts/check-no-forward-delete.py [RULES_JSON]
Default RULES_JSON: compat/rules.json. A missing file is reported and passes (nothing ships yet),
unless --require is given.
Exit status: 0 clean, 1 findings, 2 usage or parse error.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
FORWARD_WORDS = re.compile(r"forward[\s_-]*delete|fwd[\s_-]*del|forwarddelete|kVK_ForwardDelete", re.I)
KEYCODE_KEYS = re.compile(r"(key[_-]?code|deleteKey|deleteKeycode|virtualKey)$", re.I)
DIRECTION_KEYS = re.compile(r"^(deleteDirection|deleteKey|deleteMode)$", re.I)
FORWARD_DELETE_KEYCODE = 0x75


def walk(node, path, findings):
    if isinstance(node, dict):
        for key, value in node.items():
            child = f"{path}.{key}" if path else key
            if FORWARD_WORDS.search(key):
                findings.append(f"{child}: key names forward delete")
            if KEYCODE_KEYS.search(key) and value in (FORWARD_DELETE_KEYCODE, "0x75", "117"):
                findings.append(f"{child}: forward-delete keycode {value!r}")
            if DIRECTION_KEYS.match(key) and isinstance(value, str) and value.lower() not in (
                "backspace",
                "backward",
            ):
                findings.append(f"{child}: delete direction {value!r} is not backspace")
            walk(value, child, findings)
    elif isinstance(node, list):
        for index, value in enumerate(node):
            walk(value, f"{path}[{index}]", findings)
    elif isinstance(node, str) and FORWARD_WORDS.search(node):
        findings.append(f"{path}: value mentions forward delete ({node!r})")


def rule_label(document, path):
    match = re.match(r"rules\[(\d+)\]", path)
    if match and isinstance(document.get("rules"), list):
        index = int(match.group(1))
        if index < len(document["rules"]) and isinstance(document["rules"][index], dict):
            return f" (rule {document['rules'][index].get('id', '?')})"
    return ""


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("rules", nargs="?", default=str(REPO_ROOT / "compat" / "rules.json"))
    parser.add_argument("--require", action="store_true", help="fail when the rules file is missing")
    args = parser.parse_args(argv)

    path = Path(args.rules)
    if not path.exists():
        print(f"check-no-forward-delete: {path} not found", file=sys.stderr)
        return 1 if args.require else 0
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"check-no-forward-delete: cannot parse {path}: {error}", file=sys.stderr)
        return 2
    if not isinstance(document, dict):
        print(f"check-no-forward-delete: {path} is not a JSON object", file=sys.stderr)
        return 2

    findings: list[str] = []
    walk(document, "", findings)
    # Provenance text may describe the symptom ("a stray forward delete") without emitting one.
    findings = [item for item in findings if ".provenance." not in item and ".summary" not in item]
    for item in findings:
        print(f"{path.name}: {item}{rule_label(document, item)} (PLT-R407)")
    if findings:
        print(f"check-no-forward-delete: {len(findings)} finding(s)", file=sys.stderr)
        return 1
    print("check-no-forward-delete: clean", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
