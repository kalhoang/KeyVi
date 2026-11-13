#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-App-Pending
#
# Platform integration layers on the self-hosted macOS runner (QA-R10 to QA-R16, PLT-R821,
# section 13.2). The runner has Accessibility (and, if needed, Input Monitoring) granted to the
# stable Apple Development signing identity of the test build, so builds here are signed normally
# (never ad hoc: a changing signature would lose the grants).
#
# Subcommands:
#   build   the test build: xcodegen configuration Integration (INTEGRATION_HOOKS, dev bundle ID, Apple
#           Development identity, ADR 0502 "Integration hooks") and TestHost, built in $INTEGRATION_DERIVED_DATA
#           (default .build/integration-build) and installed into $INTEGRATION_APP_DIR (default ~/Applications)
#           at the same path every time
#   tests   QA-R11 TestHost suite and privacy canary: compat-harness run --only 'testhost.*' (ADR 0502)
#   compat  compat-harness scenarios (compat/scenarios), results in the output directory
#   soak    nightly soak: 1,000,000 keystrokes through the pipeline (QA-R16); M2 compared with the baseline
#   bench   end-to-end platform metrics T2 to T6, C1, C2, M1, compared with the baseline at 25 % (PLT-R822)
#           by scripts/bench-compare.sh; $COMPAT_HARNESS_BENCH_RUNS runs (default 5, QA-R14)
# CompatHarness command lines are owned by the platform track; override them with
# COMPAT_HARNESS_TESTS_ARGS, COMPAT_HARNESS_RUN_ARGS, COMPAT_HARNESS_SOAK_ARGS and COMPAT_HARNESS_BENCH_ARGS
# (see ADR 0502). PLATFORM_BASELINE overrides perf/platform-baseline.json.
#
# Runner environment (docs/runbooks/self-hosted-runner.md section 3.1):
#   COMPAT_HARNESS_LIVE=1  machine-level opt-in for the harness's live services (posting events, launching
#                          apps, switching input sources) and for installing the test build. Exported only on the
#                          self-hosted runner, from the runner's .env file, never from a workflow. build, tests,
#                          compat, soak and bench stop at once without it; a dry run (--dry-run in the override)
#                          needs no opt-in.
#   chromedriver           webdriver scenarios without a --webdriver BUNDLE=URL entry read back through the
#                          chromedriver default endpoint http://127.0.0.1:9515; start it before compat and soak.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/run-integration.sh build|tests|compat|soak|bench [--out DIR]

  --out DIR   output directory for result bundles and reports (default .build/integration)
  -h, --help  show this help
Requires a Mac with permissions granted to the test build's signing identity (QA-R12) and
COMPAT_HARNESS_LIVE=1 from the runner's .env file (docs/runbooks/self-hosted-runner.md section 3.1).
compat and soak also need chromedriver on http://127.0.0.1:9515.
EOF
}

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

cmd="${1:-}"
case "$cmd" in
  -h | --help) usage; exit 0 ;;
  build | tests | compat | soak | bench) shift ;;
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

# The one string only the INTEGRATION_HOOKS code carries (App/Sources/IntegrationHooks, IntegrationHooksBuild.marker;
# scripts/verify-release.sh fails a release that has it). scripts/tests keep the copies equal.
HOOKS_MARKER="INTEGRATION_HOOKS test build: file-drop integration hooks"
PLATFORM_BASELINE="${PLATFORM_BASELINE:-perf/platform-baseline.json}"
BENCH_RUNS="${COMPAT_HARNESS_BENCH_RUNS:-5}"
[[ "$BENCH_RUNS" =~ ^[1-9][0-9]*$ ]] || die "COMPAT_HARNESS_BENCH_RUNS must be a positive integer: $BENCH_RUNS"

# compat-harness builds live services only when COMPAT_HARNESS_LIVE is exactly 1 and exits 3 otherwise
# (HarnessEnvironment.allowsLive). Checking here saves the release build and names the runbook.
require_live_opt_in() {
  local arg
  for arg in "$@"; do
    [[ "$arg" == "--dry-run" ]] && return 0
  done
  [[ "${COMPAT_HARNESS_LIVE:-}" == "1" ]] && return 0
  die "COMPAT_HARNESS_LIVE=1 is not set: compat-harness refuses live commands without it. Export it only on" \
    "the self-hosted runner, in the runner's .env file (docs/runbooks/self-hosted-runner.md section 3.1)"
}

harness() {
  local args_var="$1"
  shift
  local args=()
  if [[ -n "${!args_var:-}" ]]; then
    read -r -a args <<<"${!args_var}"
  else
    args=("$@")
  fi
  require_live_opt_in ${args[@]+"${args[@]}"}
  [[ -f Packages/AppCore/Package.swift ]] || die "Packages/AppCore not found"
  # `swift run` takes the executable PRODUCT name (compat-harness), not the target name (CompatHarness).
  swift run --package-path Packages/AppCore -c release compat-harness "${args[@]}"
}

# A copy left running by an earlier job, a killed harness or a manual session keeps the old bundle mapped, and the
# harness could attach to it instead of the new build. Terminate the copy running from this path before replacing
# it: SIGTERM, a bounded wait, then SIGKILL. A signal, not an Apple Event quit: sending Apple Events would need an
# Automation grant on the runner and could stall on its consent prompt. Only a process whose executable lives under
# the installed path is touched.
quit_installed_app() {
  local app="$1" pattern waited=0
  local limit="${INTEGRATION_QUIT_TIMEOUT:-10}"
  # pgrep -f takes an extended regular expression: escape the path's metacharacters (the dots in ".app").
  pattern="^$(printf '%s' "$app/Contents/MacOS/" | sed 's/[][\\.^$*+?(){}|]/\\&/g')"
  pgrep -f -- "$pattern" >/dev/null 2>&1 || return 0
  info "terminating the running copy of $app"
  pkill -TERM -f -- "$pattern" || true
  while pgrep -f -- "$pattern" >/dev/null 2>&1; do
    if (( waited >= limit * 5 )); then
      warn "$app did not exit within ${limit}s: killing it"
      pkill -KILL -f -- "$pattern" || true
      sleep 1
      break
    fi
    sleep 0.2
    waited=$((waited + 1))
  done
  ! pgrep -f -- "$pattern" >/dev/null 2>&1 || die "a copy of $app is still running; quit it and run build again"
}

# Replaces the installed copy at the same path (the TCC grant follows the signature and bundle ID, not the files).
install_app() {
  local source="$1" destination="$2"
  [[ -d "$source" ]] || die "built app not found: $source"
  mkdir -p "$(dirname "$destination")"
  rm -rf "$destination.installing"
  ditto "$source" "$destination.installing"
  rm -rf "$destination"
  mv "$destination.installing" "$destination"
  info "installed $destination"
}

build_test_apps() {
  require_live_opt_in
  require_cmd xcodebuild ditto pgrep pkill
  load_brand
  local xcodegen_bin derived apps app
  xcodegen_bin="$(scripts/install-xcodegen.sh --prefer-system)"
  "$xcodegen_bin/xcodegen" generate
  # Outside the output directory: the workflows upload that one as the run's artefact.
  derived="${INTEGRATION_DERIVED_DATA:-$REPO_ROOT/.build/integration-build}"
  # Integration = INTEGRATION_HOOKS + dev bundle ID + Apple Development identity (Config/Integration.xcconfig).
  # ONLY_ACTIVE_ARCH on the command line: unlike the xcconfig line, it also reaches the SwiftPM package targets,
  # which would otherwise compile for arm64 and x86_64.
  xcodebuild -project App.xcodeproj -scheme App -configuration Integration -derivedDataPath "$derived" \
    -disableAutomaticPackageResolution ONLY_ACTIVE_ARCH=YES build
  xcodebuild -project App.xcodeproj -scheme TestHost -configuration Debug -derivedDataPath "$derived" \
    -disableAutomaticPackageResolution ONLY_ACTIVE_ARCH=YES build
  apps="${INTEGRATION_APP_DIR:-$HOME/Applications}"
  app="$apps/$APP_DISPLAY_NAME.app"
  quit_installed_app "$app"
  quit_installed_app "$apps/TestHost.app"
  install_app "$derived/Build/Products/Integration/$APP_DISPLAY_NAME.app" "$app"
  install_app "$derived/Build/Products/Debug/TestHost.app" "$apps/TestHost.app"
  # A test build without the hooks would leave testHook steps and T2 to T6 unanswered (runbook section 8).
  LC_ALL=C grep -a -F -q -- "$HOOKS_MARKER" "$app/Contents/MacOS/$APP_DISPLAY_NAME" \
    || die "the installed test build does not answer the integration hooks (INTEGRATION_HOOKS missing)"
}

case "$cmd" in
  build)
    build_test_apps
    ;;
  tests)
    harness COMPAT_HARNESS_TESTS_ARGS run --scenarios compat/scenarios --only 'testhost.*' --output "$out/tests"
    ;;
  compat)
    harness COMPAT_HARNESS_RUN_ARGS run --scenarios compat/scenarios --output "$out/compat"
    ;;
  soak)
    harness COMPAT_HARNESS_SOAK_ARGS soak --keystrokes 1000000 --output "$out/soak"
    # The harness gates M2 itself; this repeats the baseline comparison in the shared format (PLT-R822).
    if [[ -f "$out/soak/soak-metrics.json" ]]; then
      scripts/bench-compare.sh --results "$out/soak/soak-metrics.json" --threshold 25 \
        --baseline "$PLATFORM_BASELINE" --output "$out/soak/soak-metrics-median.json"
    fi
    ;;
  bench)
    harness COMPAT_HARNESS_BENCH_ARGS bench --runs "$BENCH_RUNS" --output "$out/platform-bench.json"
    scripts/bench-compare.sh --results "$out/platform-bench.json" --threshold 25 \
      --baseline "$PLATFORM_BASELINE" --output "$out/platform-bench-median.json"
    ;;
esac
info "integration $cmd: done ($out)"
