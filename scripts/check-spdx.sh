#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# CLR-R11: every source file carries an SPDX licence header within its first 5 lines.
#   - Engine packages (Packages/VietnameseEngine/, Packages/VietnameseEngineFuzz/), the data pipeline
#     that builds their bundled resources (data/, ENG-R810) and the reference model (spec/reference-model/):
#     MPL-2.0 (ADR 0006 as amended on 2026-11-15; MIT until then, before any release)
#   - Everything else: GPL-3.0-or-later (ADR 0006, chosen by Pa on 2026-11-13)
# Source files: *.swift, *.sh, *.bash, *.py, *.mjs, *.js, *.ts, *.css, *.rb, *.template,
# *.xcconfig, workflow YAML under .github/, and extensionless executables under scripts/ with a
# shebang. Excluded: spec/ (the specification, imported as is) except spec/reference-model/, generated
# output (dist/, .build*/, site/dist/, node_modules/), JSON and Markdown (no comment syntax or not source).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/check-spdx.sh [--root DIR] [--list]

Checks SPDX licence headers (CLR-R11).
Options:
  --root DIR   repository root (default: this repository)
  --list       print every checked file with its licence
  -h, --help   show this help
Exit status: 0 clean, 1 missing or wrong headers, 2 usage error.
EOF
}

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

root="$REPO_ROOT"
list=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --root) root="${2:?--root needs a value}"; shift 2 ;;
    --list) list=1; shift ;;
    *) usage >&2; exit 2 ;;
  esac
done

file_list="$(mktemp)"
trap 'rm -f "$file_list"' EXIT
if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  (cd "$root" && git ls-files --cached --others --exclude-standard) >"$file_list"
else
  (cd "$root" && find . -type f -not -path './.git/*' | sed 's|^\./||') >"$file_list"
fi

py - "$root" "$list" "$file_list" <<'PY'
import os
import re
import sys

root, list_flag, file_list = sys.argv[1:]
SOURCE_EXT = re.compile(r"\.(swift|sh|bash|py|mjs|cjs|js|ts|css|rb|template|xcconfig)$")
WORKFLOW = re.compile(r"^\.github/.*\.ya?ml$")
EXCLUDED = re.compile(r"^(spec/(?!reference-model/)|dist/|site/dist/)|(^|/)(\.build[^/]*|node_modules|DerivedData)/|"
                      r"\.xcodeproj/|(^|/)__pycache__/")
MPL_PATH = re.compile(r"^(Packages/VietnameseEngine(Fuzz)?|data|spec/reference-model)/")
HEADER = re.compile(r"SPDX-License-Identifier:\s*([A-Za-z0-9.+-]+)")


def is_source(rel, path):
    if SOURCE_EXT.search(rel) or WORKFLOW.search(rel):
        return True
    if rel.startswith("scripts/") and "." not in os.path.basename(rel):
        try:
            with open(path, "rb") as handle:
                return handle.read(2) == b"#!"
        except OSError:
            return False
    return False


bad = 0
checked = 0
with open(file_list, encoding="utf-8") as handle:
    files = [line.strip() for line in handle if line.strip()]
for rel in sorted(set(files)):
    path = os.path.join(root, rel)
    if EXCLUDED.search(rel) or not os.path.isfile(path) or not is_source(rel, path):
        continue
    checked += 1
    expected = "MPL-2.0" if MPL_PATH.search(rel) else "GPL-3.0-or-later"
    try:
        with open(path, encoding="utf-8", errors="replace") as source:
            head = "".join(source.readline() for _ in range(5))
    except OSError as error:
        print(f"{rel}: cannot read ({error})")
        bad += 1
        continue
    match = HEADER.search(head)
    found = match.group(1) if match else None
    if list_flag == "1":
        print(f"{found or '-':<24} {rel}")
    if found is None:
        print(f"{rel}: missing SPDX-License-Identifier (expected {expected}, CLR-R11)")
        bad += 1
    elif found != expected:
        print(f"{rel}: SPDX licence {found}, expected {expected} (CLR-R11)")
        bad += 1

print(f"check-spdx: {checked} file(s) checked, {bad} problem(s)", file=sys.stderr)
sys.exit(1 if bad else 0)
PY
