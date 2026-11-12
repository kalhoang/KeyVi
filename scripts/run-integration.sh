#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-App-Pending
#
# Platform integration layers on the self-hosted macOS runner (QA-R10 to QA-R16, PLT-R821,
# section 13.2). The runner has Accessibility (and, if needed, Input Monitoring) granted to the
# stable Apple Development signing identity of the test build, so builds here are signed normally
# (never ad hoc: a changing signature would lose the grants).
#
# Subcommands:
#   tests   TestHost integration tests through xcodebuild (scheme $INTEGRATION_SCHEME, default TestHost)
#   compat  CompatHarness scenarios (compat/scenarios), results in the output directory
#   soak    nightly soak: 1,000,000 keystrokes through the pipeline (QA-R16)
#   bench   end-to-end platform metrics T2 to T6, C1, C2, M1, M2, compared with the baseline at
#           25 % (PLT-R822) by scripts/bench-compare.sh
# CompatHarness command lines are owned by the platform track; override them with
# COMPAT_HARNESS_RUN_ARGS, COMPAT_HARNESS_SOAK_ARGS and COMPAT_HARNESS_BENCH_ARGS (see ADR 0502).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/run-integration.sh tests|compat|soak|bench [--out DIR]

  --out DIR   output directory for result bundles and reports (default .build/integration)
  -h, --help  show this help
Requires a Mac with permissions granted to the test build's signing identity (QA-R12).
EOF
}

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

cmd="${1:-}"
case "$cmd" in
  -h | --help) usage; exit 0 ;;
  tests | compat | soak | bench) shift ;;
  *) usage >&2; exit 2 ;;
esac
out="$REPO_ROOT/.build/integration"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --out) out="${2:?}"; shift 2 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ "$(uname -s)" == "Darwin" ]] || die "integration layers need macOS"
mkdir -p "$out"
cd "$REPO_ROOT"

harness() {
  local args_var="$1"
  shift
  local args=()
  if [[ -n "${!args_var:-}" ]]; then
    read -r -a args <<<"${!args_var}"
  else
    args=("$@")
  fi
  [[ -f Packages/AppCore/Package.swift ]] || die "Packages/AppCore not found"
  swift run --package-path Packages/AppCore -c release CompatHarness "${args[@]}"
}

case "$cmd" in
  tests)
    xcodegen_bin="$(scripts/install-xcodegen.sh --prefer-system)"
    "$xcodegen_bin/xcodegen" generate
    rm -rf "$out/TestHost.xcresult"
    xcodebuild test -project App.xcodeproj -scheme "${INTEGRATION_SCHEME:-TestHost}" \
      -destination 'platform=macOS' -resultBundlePath "$out/TestHost.xcresult"
    ;;
  compat)
    harness COMPAT_HARNESS_RUN_ARGS run --scenarios compat/scenarios --output "$out/compat"
    ;;
  soak)
    harness COMPAT_HARNESS_SOAK_ARGS soak --keystrokes 1000000 --output "$out/soak"
    ;;
  bench)
    harness COMPAT_HARNESS_BENCH_ARGS bench --runs 5 --output "$out/platform-bench.json"
    scripts/bench-compare.sh --results "$out/platform-bench.json" --threshold 25 \
      --baseline "${PLATFORM_BASELINE:-Packages/AppCore/Benchmarks/platform-baseline.json}" \
      --output "$out/platform-bench-median.json"
    ;;
esac
info "integration $cmd: done ($out)"
