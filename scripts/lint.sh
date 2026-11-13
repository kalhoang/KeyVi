#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-App-Pending
#
# One command for every repository lint (QA-R22, QA-R24, PLT-R501, PLT-R902, PLT-R407, PLT-R503 to
# PLT-R521, QA-R60, CLR-R11). Runs every check, then reports all failures at once.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/lint.sh [--binary APP_OR_BINARY] [--release] [--skip NAME[,NAME]] [--list]

Runs, in order:
  swift-format       swift format lint --strict with .swift-format (needs a Swift 6 toolchain)
  bundle-ids         scripts/lint-bundle-ids.sh          (PLT-R501)
  log-interpolation  scripts/lint-log-interpolation.sh   (PLT-R902)
  forward-delete     scripts/check-no-forward-delete.py  (PLT-R407)
  rules              scripts/check-rules.py               (PLT-R503 to PLT-R531)
  spdx               scripts/check-spdx.sh                (CLR-R11)
  brand-sync         scripts/check-brand-sync.py          (Brand.xcconfig and brand.env agree)
  shellcheck         shellcheck on scripts/ (skipped when shellcheck is not installed)
  url-hosts          scripts/check-url-hosts.sh           (QA-R60; only with --binary)

Options:
  --binary PATH   built .app or binary for the URL host allowlist check
  --release       release mode: overdue rule reviewBy dates block (PLT-R506)
  --skip LIST     comma-separated check names to skip
  --list          list check names and exit
  -h, --help      show this help
EOF
}

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

binary=""
release=0
skip=","
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --binary) binary="${2:?--binary needs a value}"; shift 2 ;;
    --release) release=1; shift ;;
    --skip) skip=",${2:?--skip needs a value},"; shift 2 ;;
    --list) printf '%s\n' swift-format bundle-ids log-interpolation forward-delete rules spdx brand-sync shellcheck url-hosts; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

cd "$REPO_ROOT"
failed=()

run_check() {
  local name="$1"
  shift
  if [[ "$skip" == *",$name,"* ]]; then
    info "$name: skipped"
    return 0
  fi
  info "$name"
  if ! "$@"; then
    failed+=("$name")
  fi
}

swift_format_lint() {
  local files=()
  while IFS= read -r f; do files+=("$f"); done < <(swift_files_in "$REPO_ROOT")
  if [[ ${#files[@]} -eq 0 ]]; then
    log "no Swift files"
    return 0
  fi
  if swift format --version >/dev/null 2>&1; then
    swift format lint --strict --configuration .swift-format --parallel "${files[@]}"
  elif command -v swift-format >/dev/null 2>&1; then
    swift-format lint --strict --configuration .swift-format --parallel "${files[@]}"
  else
    log "swift-format not available (needs the Swift 6 toolchain)"
    return 1
  fi
}

shellcheck_scripts() {
  if ! command -v shellcheck >/dev/null 2>&1; then
    warn "shellcheck not installed; skipped"
    return 0
  fi
  local files=()
  while IFS= read -r f; do files+=("$f"); done < <(
    find scripts -type f \( -name '*.sh' -o -name 'publish-release' \) | sort
  )
  shellcheck -x -P scripts:scripts/lib "${files[@]}"
}

rules_args=()
[[ $release -eq 1 ]] && rules_args+=(--release)

run_check swift-format swift_format_lint
run_check bundle-ids scripts/lint-bundle-ids.sh
run_check log-interpolation scripts/lint-log-interpolation.sh
run_check forward-delete py scripts/check-no-forward-delete.py
run_check rules py scripts/check-rules.py ${rules_args[@]+"${rules_args[@]}"}
run_check spdx scripts/check-spdx.sh
run_check brand-sync py scripts/check-brand-sync.py
run_check shellcheck shellcheck_scripts
if [[ -n "$binary" ]]; then
  run_check url-hosts scripts/check-url-hosts.sh "$binary"
else
  info "url-hosts: skipped (no --binary)"
fi

if [[ ${#failed[@]} -gt 0 ]]; then
  die "lint failed: ${failed[*]}"
fi
info "lint: all checks passed"
