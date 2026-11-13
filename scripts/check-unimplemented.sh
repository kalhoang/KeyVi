#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Release-build guard (docs/architecture/workstreams.md rule 9, contracts.md): fails when a call to
# `unimplemented(` remains in product code, because such a member traps at run time. Scanned:
# Packages/AppCore/Sources and App/Sources (Swift files). The definition itself,
# Packages/AppCore/Sources/AppModel/Unimplemented.swift, is excluded, and text after `//` on a line is
# ignored so comments may mention the function.
#
# Inputs: none besides --root (tests). No environment variables. release.yml runs it before building.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/check-unimplemented.sh [--root DIR] [--report]

  --root DIR   repository root to scan (default: this repository)
  --report     list the remaining calls but exit 0 (progress report during development)
  -h, --help   show this help
Exit status: 0 no call left (or --report), 1 calls remain.
EOF
}

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

root="$REPO_ROOT"
report=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --root) root="${2:?--root needs a value}"; shift 2 ;;
    --report) report=1; shift ;;
    *) usage >&2; exit 2 ;;
  esac
done

definition="Packages/AppCore/Sources/AppModel/Unimplemented.swift"
findings="$(mktemp)"
trap 'rm -f "$findings"' EXIT
for dir in Packages/AppCore/Sources App/Sources; do
  [[ -d "$root/$dir" ]] || continue
  while IFS= read -r rel; do
    [[ "$dir/$rel" == "$definition" ]] && continue
    awk -v file="$dir/$rel" '
      { code = $0; sub(/\/\/.*/, "", code) }
      code ~ /(^|[^A-Za-z0-9_])unimplemented\(/ { printf "%s:%d: %s\n", file, FNR, $0 }
    ' "$root/$dir/$rel" >>"$findings"
  done < <(swift_files_in "$root/$dir")
done

count="$(wc -l <"$findings" | tr -d ' ')"
if [[ "$count" == "0" ]]; then
  info "check-unimplemented: no unimplemented() call left in product code"
  exit 0
fi
sed -E 's/[[:space:]]+/ /g' "$findings" >&2
if [[ $report -eq 1 ]]; then
  info "check-unimplemented: $count call(s) left (report only)"
  exit 0
fi
die "check-unimplemented: $count unimplemented() call(s) left in product code; a release build must not ship them"
