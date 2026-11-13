#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-App-Pending
#
# Hosted-CI check of the compatibility scenarios (docs/architecture/workstreams.md W2-E1 and "Interim
# verification", PLT-R530, QA-R21): `compat-harness run --scenarios compat/scenarios --dry-run` loads every
# scenario and prints the plan WITHOUT posting events. It is the only harness mode allowed on GitHub-hosted
# runners and on Pa's Mac; the real run needs the self-hosted runner (scripts/run-integration.sh compat).
#
# Skipped (exit 0 with a notice) while the product does not exist yet: no compat-harness product in
# Packages/AppCore/Package.swift, or no scenario file (*.json) under compat/scenarios. Once scenarios exist,
# a harness that still prints "not implemented" fails, so the step cannot pass silently.
#
# Inputs: --root (tests). Environment: COMPAT_HARNESS_DRY_RUN_ARGS replaces the harness arguments (the
# platform track owns the command line, ADR 0502); SWIFT_SCRATCH_PATH sets swift run --scratch-path.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/compat-dry-run.sh [--root DIR] [--out FILE]

  --root DIR   repository root (default: this repository)
  --out FILE   also write the harness output (the plan) to FILE
  -h, --help   show this help
Never posts keyboard events: it always passes --dry-run to compat-harness.
EOF
}

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

root="$REPO_ROOT"
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --root) root="${2:?--root needs a value}"; shift 2 ;;
    --out) out="${2:?--out needs a value}"; shift 2 ;;
    *) usage >&2; exit 2 ;;
  esac
done

package="$root/Packages/AppCore"
scenarios="$root/compat/scenarios"
if [[ ! -f "$package/Package.swift" ]] || ! grep -q 'name: *"compat-harness"' "$package/Package.swift"; then
  info "compat-dry-run: skipped (no compat-harness product in Packages/AppCore yet)"
  exit 0
fi
if [[ ! -d "$scenarios" ]] || [[ -z "$(find "$scenarios" -type f -name '*.json' -print -quit)" ]]; then
  info "compat-dry-run: skipped (no scenario files in compat/scenarios yet)"
  exit 0
fi

args=(run --scenarios "$scenarios" --dry-run)
if [[ -n "${COMPAT_HARNESS_DRY_RUN_ARGS:-}" ]]; then
  read -r -a args <<<"$COMPAT_HARNESS_DRY_RUN_ARGS"
  [[ " ${args[*]} " == *" --dry-run "* ]] || die "COMPAT_HARNESS_DRY_RUN_ARGS must contain --dry-run"
fi
scratch=()
[[ -n "${SWIFT_SCRATCH_PATH:-}" ]] && scratch=(--scratch-path "$SWIFT_SCRATCH_PATH")

log_file="$(mktemp)"
trap 'rm -f "$log_file"' EXIT
status=0
swift run --package-path "$package" ${scratch[@]+"${scratch[@]}"} compat-harness "${args[@]}" >"$log_file" 2>&1 \
  || status=$?
cat "$log_file"
[[ -z "$out" ]] || cp "$log_file" "$out"
[[ $status -eq 0 ]] || die "compat-harness --dry-run failed (exit $status)"
if grep -qi 'not implemented' "$log_file"; then
  die "compat-harness reports 'not implemented' while compat/scenarios has scenarios"
fi
info "compat-dry-run: every scenario loaded and planned"
