#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# PLT-R501: application code MUST NOT contain per-app branches. Fails when a bundle-ID-shaped
# string literal (reverse-DNS such as "com.example.App") appears in Swift code outside
# compat/rules.json, test fixtures and the conflicting-apps list (which lives in compat/rules.json).
#
# Exemptions (documented in docs/decisions/0505-lint-contracts.md):
#   - paths: */Tests/*, *Tests/*, */Fixtures/*, */fixtures/*, Packages/AppCore/Sources/TestSupport/*
#   - identifiers that are not bundle IDs (keyboard layout IDs, pasteboard type names, ...) listed as
#     regular expressions in scripts/lint-bundle-ids.allow
#   - a line carrying the marker `lint:allow-bundle-id <reason>` (reason required)
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/lint-bundle-ids.sh [--root DIR] [FILE...]

Scans Swift sources for bundle-ID-shaped string literals (PLT-R501).
With FILE arguments only those files are scanned (exemption rules still apply).

Options:
  --root DIR   repository root to scan (default: the repository containing this script)
  -h, --help   show this help
Exit status: 0 clean, 1 findings, 2 usage error.
EOF
}

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

root="$REPO_ROOT"
files=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --root) root="${2:?--root needs a value}"; shift 2 ;;
    --) shift; files+=("$@"); break ;;
    -*) usage >&2; exit 2 ;;
    *) files+=("$1"); shift ;;
  esac
done

allow_file="$REPO_ROOT/scripts/lint-bundle-ids.allow"

if [[ ${#files[@]} -eq 0 ]]; then
  while IFS= read -r f; do files+=("$f"); done < <(swift_files_in "$root")
fi

if [[ ${#files[@]} -eq 0 ]]; then
  info "lint-bundle-ids: no Swift files"
  exit 0
fi

py - "$root" "$allow_file" "${files[@]}" <<'PY'
import os
import re
import sys

root, allow_file, *files = sys.argv[1:]

TLDS = ("com|org|net|io|dev|app|vn|me|co|ai|so|sh|tv|us|uk|de|fr|jp|cn|ru|ca|au|eu|nl|se|ch|"
        "info|biz|xyz|tech|cloud|edu|gov")
LITERAL = re.compile(r'"((?:%s)\.[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*)"' % TLDS)
FILE_EXT = {"json", "swift", "plist", "txt", "md", "png", "log", "xml", "strings", "html", "js",
            "css", "yml", "yaml", "sh", "py", "zip", "dmg"}
EXEMPT_PATH = re.compile(r"(^|/)(Tests|[A-Za-z]+Tests|Fixtures|fixtures)/|"
                         r"^Packages/AppCore/Sources/TestSupport/|(^|/)\.build[^/]*/")
MARKER = re.compile(r"lint:allow-bundle-id\s+\S+")

allow = []
if os.path.exists(allow_file):
    with open(allow_file, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if line and not line.startswith("#"):
                allow.append(re.compile(line))

findings = 0
for rel in files:
    rel = rel.removeprefix("./")
    if EXEMPT_PATH.search(rel):
        continue
    path = os.path.join(root, rel)
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.readlines()
    except (OSError, UnicodeDecodeError) as error:
        print(f"{rel}: cannot read ({error})", file=sys.stderr)
        findings += 1
        continue
    for number, line in enumerate(lines, 1):
        stripped = line.lstrip()
        if stripped.startswith("//") or stripped.startswith("///"):
            continue
        for match in LITERAL.finditer(line):
            value = match.group(1)
            parts = value.split(".")
            if len(parts) == 2 and parts[-1].lower() in FILE_EXT:
                continue
            if any(pattern.search(value) for pattern in allow):
                continue
            if MARKER.search(line):
                continue
            print(f"{rel}:{number}: bundle-ID-shaped literal \"{value}\" (PLT-R501: move it to "
                  f"compat/rules.json or a test fixture)")
            findings += 1

if findings:
    print(f"lint-bundle-ids: {findings} finding(s)", file=sys.stderr)
    sys.exit(1)
print("lint-bundle-ids: clean", file=sys.stderr)
PY
