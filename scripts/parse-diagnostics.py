#!/usr/bin/env -S python3 -I
# SPDX-License-Identifier: LicenseRef-App-Pending
"""Parses the diagnostics block of an issue body and prints the labels to apply (QA-R44).

Format (docs/decisions/0501-diagnostics-block-format.md): a fenced code block whose first non-empty
line is the header `<slug>-diagnostics v<N>`, followed by `key: value` lines. Labels derived:
  app:<bundle ID>      from report.bundleId, else focus.bundleId
  macos:<major>        from macos.version
  arch:arm64|x86_64    from hw.arch
  method:telex|vni     from input.method
The issue body is untrusted input: values are validated against strict patterns and anything that
does not match is ignored. Only format version 1 is understood; newer versions yield no labels
except a `diagnostics:v<N>` note on stderr.

Usage: python3 -I scripts/parse-diagnostics.py [--body-env NAME | --file PATH] [--json]
Reads the body from the environment variable ISSUE_BODY by default (never from the command line,
so the body cannot be interpreted by a shell). Prints one label per line (or JSON with --json).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys

HEADER = re.compile(r"^(?P<slug>[a-z][a-z0-9-]{0,40})-diagnostics v(?P<version>[0-9]{1,3})\s*$")
FENCE = re.compile(r"^\s{0,3}(`{3,}|~{3,})")
KEY_VALUE = re.compile(r"^(?P<key>[a-z][A-Za-z0-9]*(?:\.[A-Za-z0-9]+)*)\s*:\s?(?P<value>.*)$")
BUNDLE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$")
MACOS_VERSION = re.compile(r"^(?P<major>[1-9][0-9]?)(\.[0-9]+){0,2}")
ARCHES = {"arm64": "arm64", "x86_64": "x86_64", "intel": "x86_64", "apple-silicon": "arm64"}
METHODS = {"telex": "telex", "vni": "vni"}
LABEL_MAX = 50  # GitHub label name limit
MAX_BODY = 65536 * 4
SUPPORTED_VERSION = 1


def find_block(body: str) -> tuple[int, dict[str, str]] | None:
    """Returns (format version, fields) of the first diagnostics block, or None."""
    lines = body.splitlines()
    index = 0
    while index < len(lines):
        line = lines[index].strip()
        match = HEADER.match(line)
        if match:
            fields: dict[str, str] = {}
            for raw in lines[index + 1:]:
                if FENCE.match(raw):
                    break
                stripped = raw.strip()
                if not stripped or stripped.startswith("#"):
                    continue
                pair = KEY_VALUE.match(stripped)
                if pair and pair.group("key") not in fields:
                    fields[pair.group("key")] = pair.group("value").strip()
            return int(match.group("version")), fields
        index += 1
    return None


def labels_for(fields: dict[str, str]) -> list[str]:
    labels: list[str] = []
    bundle = fields.get("report.bundleId") or fields.get("focus.bundleId") or ""
    if BUNDLE_ID.match(bundle) and len("app:" + bundle) <= LABEL_MAX:
        labels.append("app:" + bundle)
    version = MACOS_VERSION.match(fields.get("macos.version", ""))
    if version:
        labels.append("macos:" + version.group("major"))
    arch = ARCHES.get(fields.get("hw.arch", "").lower())
    if arch:
        labels.append("arch:" + arch)
    method = METHODS.get(fields.get("input.method", "").lower())
    if method:
        labels.append("method:" + method)
    return labels


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Print labels from an issue's diagnostics block (QA-R44).")
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--body-env", default="ISSUE_BODY", help="environment variable holding the body")
    source.add_argument("--file", help="read the body from a file (tests)")
    parser.add_argument("--json", action="store_true", help="print a JSON object instead of lines")
    args = parser.parse_args(argv)

    if args.file:
        with open(args.file, encoding="utf-8", errors="replace") as handle:
            body = handle.read(MAX_BODY)
    else:
        body = os.environ.get(args.body_env, "")[:MAX_BODY]

    block = find_block(body)
    if block is None:
        result = {"found": False, "version": None, "labels": []}
    else:
        version, fields = block
        labels = labels_for(fields) if version == SUPPORTED_VERSION else []
        if version != SUPPORTED_VERSION:
            print(f"parse-diagnostics: unsupported format version v{version}", file=sys.stderr)
        result = {"found": True, "version": version, "labels": labels}

    if args.json:
        print(json.dumps(result))
    else:
        for label in result["labels"]:
            print(label)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
