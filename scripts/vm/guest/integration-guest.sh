#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Guest half of scripts/vm/integration-dev.sh: builds the INTEGRATION_HOOKS test build, TestHost and
# compat-harness from the copied checkout, grants them TCC with grant-tcc.sh and runs the QA-R11 TestHost suite
# (docs/runbooks/integration-suite.md section 3 step 3). Runs INSIDE the disposable macOS + Xcode VM through the
# tart guest agent, so it is in the logged-in GUI session; never on the host.
#
# The build is `scripts/run-integration.sh build` itself, with INTEGRATION_CODE_SIGN_IDENTITY=-: the VM has no Apple
# Development identity, so the test build is ad-hoc signed with the hardened runtime off (an ad-hoc signature has no
# Team ID, and library validation would refuse Sparkle). Its TCC grant is therefore tied to the cdhash and is
# renewed by this script after every build.
#
# Usage: integration-guest.sh --out DIR [--only ID[,ID...]]   (from the checkout root, inside the VM only; it exits
# 3 on a real Mac). --only runs these scenarios (IDs or PREFIX* patterns of compat-harness) instead of every
# testhost.* one, for a control run (integration-suite.md 10.4). Exit 0 when the suite passed.
set -uo pipefail

# Refuse to run anywhere but inside a virtual machine, before parsing arguments and before any side effect: this
# script replaces apps, changes global settings, uses sudo and launches the built app (QA-R13 keeps all of that
# off a real Mac). grant-tcc.sh carries the same guard.
[ "$(sysctl -n kern.hv_vmm_present 2>/dev/null || echo 0)" = 1 ] || {
  echo "refusing: not inside a virtual machine" >&2
  exit 3
}

usage() {
  echo "usage: integration-guest.sh --out DIR [--only ID[,ID...]]" >&2
  exit 2
}
# Scenario IDs and PREFIX* patterns, comma separated: they become words of COMPAT_HARNESS_TESTS_ARGS.
valid_only() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_][A-Za-z0-9._*-]*(,[A-Za-z0-9_][A-Za-z0-9._*-]*)*$'; }
out=""
only=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) [ $# -ge 2 ] || usage; out="$2"; shift 2 ;;
    --only)
      if [ $# -lt 2 ] || ! valid_only "$2"; then usage; fi
      only="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done
[ -n "$out" ] || usage
mkdir -p "$out"
summary="$out/summary.txt"
: >"$summary"
note() { echo "$*" | tee -a "$summary"; }
step() { note "== $*"; }
stop() {
  note "STOPPED: $*"
  exit 1
}

# shellcheck source=scripts/brand.env
. scripts/brand.env
apps="$HOME/Applications"
app="$apps/$APP_DISPLAY_NAME.app"
derived="/tmp/integration-dd"

step "system"
{
  sw_vers
  xcodebuild -version
  csrutil status
  echo "responsible-process candidates:"
  pgrep -lf 'tart-guest-agent|sshd'
  echo "TCC access schema:"
  sudo -n /usr/bin/sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" '.schema access'
} >"$out/system.txt" 2>&1
note "$(sw_vers -productVersion), $(xcodebuild -version | head -n 1), $(csrutil status | sed 's/.*: //')"

step "runner prerequisites (integration-suite.md section 2 steps 2 and 3)"
for key in NSAutomaticCapitalizationEnabled NSAutomaticDashSubstitutionEnabled NSAutomaticPeriodSubstitutionEnabled \
  NSAutomaticQuoteSubstitutionEnabled NSAutomaticSpellingCorrectionEnabled NSAutomaticTextCompletionEnabled; do
  defaults write -g "$key" -bool false
done
note "text substitutions off; languages: $(defaults read -g AppleLanguages 2>/dev/null | tr -d '\n ' | cut -c1-40)"
# Spotlight indexing of the checkout and the derived data kept the 6 GB guest swapping, so slowly that copying the
# logs back after a run took ten minutes; a throwaway VM needs no index.
sudo -n mdutil -a -i off >/dev/null 2>&1 && note "Spotlight indexing off"

step "input sources the scenarios select (section 2 step 4)"
# Every layout a TestHost scenario names, read from the scenarios so the list follows them.
layouts=()
while IFS= read -r layout; do layouts+=("$layout"); done < <(
  sed -n 's/.*"layout": *"\([^"]*\)".*/\1/p' compat/scenarios/testhost.*.json | sort -u)
xcrun swiftc -O -o /tmp/enable-input-sources scripts/vm/guest/enable-input-sources.swift >"$out/input-sources.log" 2>&1 ||
  stop "enable-input-sources.swift did not compile (input-sources.log)"
/tmp/enable-input-sources "${layouts[@]}" >>"$out/input-sources.log" 2>&1 ||
  stop "an input source could not be enabled (input-sources.log)"
note "enabled: ${layouts[*]}"

step "build: scripts/run-integration.sh build (Integration ad hoc, TestHost Debug)"
# run-integration.sh generates the project, builds both apps, ends a copy still running, installs them into
# ~/Applications and refuses a build without the integration hooks (ADR 0502).
COMPAT_HARNESS_LIVE=1 INTEGRATION_CODE_SIGN_IDENTITY=- INTEGRATION_DERIVED_DATA="$derived" INTEGRATION_APP_DIR="$apps" \
  scripts/run-integration.sh build --out "$out/build" >"$out/build.log" 2>&1 ||
  stop "scripts/run-integration.sh build failed (build.log: $(grep -m 1 -E 'error:|ERROR' "$out/build.log"))"
note "installed $app and $apps/TestHost.app"

step "build: compat-harness (release)"
swift build --package-path Packages/AppCore -c release --product compat-harness >"$out/build-harness.log" 2>&1 ||
  stop "compat-harness build failed (build-harness.log)"
harness="$PWD/Packages/AppCore/.build/release/compat-harness"

step "TCC grants (grant-tcc.sh)"
agent_pid="$(pgrep -n -f tart-guest-agent || true)"
agent=""
[ -z "$agent_pid" ] || agent="$(ps -o comm= -p "$agent_pid")"
clients=(--bundle "$app" --bundle "$apps/TestHost.app" --binary "$harness" --binary /usr/libexec/sshd-keygen-wrapper)
if [ -n "$agent" ] && [ -x "$agent" ]; then clients+=(--binary "$agent"); fi
# shellcheck disable=SC2024 # the log files belong to this user on purpose
sudo -n bash scripts/vm/grant-tcc.sh "${clients[@]}" >"$out/grant.log" 2>&1 || stop "grant-tcc.sh failed (grant.log)"
# shellcheck disable=SC2024
sudo -n /usr/bin/sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "SELECT service, client, auth_value FROM access WHERE auth_value = 2 ORDER BY client, service;" >"$out/tcc-rows.txt" 2>&1
note "$(grep -c . "$out/tcc-rows.txt") allowed TCC rows (tcc-rows.txt)"

step "onboarding finished once (section 2 step 9), so it never shows during a run"
support="$HOME/Library/Application Support/$APP_DISPLAY_NAME"
mkdir -p "$support"
if [ ! -f "$support/settings.json" ]; then
  printf '{"schemaVersion":1,"onboarding":{"completedVersion":"0.1.0"}}\n' >"$support/settings.json"
fi

step "plan check: compat-harness run --dry-run"
"$harness" run --dry-run >"$out/dry-run.log" 2>&1 || stop "the plan check failed (dry-run.log)"

step "TestHost suite: scripts/run-integration.sh tests"
# COMPAT_HARNESS_EVIDENCE_DIR: the harness writes a focus report for every failed scenario (VM lab only: frontmost
# app, role and identifier of the focused element, never a value). Not a screenshot: Screen Recording's consent
# prompt then covered the windows of the following scenarios.
mkdir -p "$out/evidence"
if [ -n "$only" ]; then
  # Same command line as run-integration.sh's default for `tests`, with the given selection.
  export COMPAT_HARNESS_TESTS_ARGS="run --scenarios compat/scenarios --only $only --output .build/integration/tests"
  note "only: $only"
fi
COMPAT_HARNESS_LIVE=1 COMPAT_HARNESS_EVIDENCE_DIR="$out/evidence" scripts/run-integration.sh tests >"$out/tests.log" 2>&1
rc=$?
cp -R .build/integration/tests "$out/results" 2>/dev/null
note "run-integration.sh tests exit $rc"
grep -E '^(pass|fail|needsHuman) ' "$out/tests.log" | awk '{print $1}' | sort | uniq -c | while read -r count kind; do
  note "  $kind: $count"
done
grep -E '^fail ' "$out/tests.log" | while read -r line; do note "  $line"; done
# Evidence for the triage (integration-suite.md section 10): the app's own diagnostics log (event codes only, never
# typed text, PLT-R901) and the screen at the end of the run (a modal panel or prompt shows up there).
cp "$HOME/Library/Logs/$APP_DISPLAY_NAME/diagnostics.jsonl" "$out/app-diagnostics.jsonl" 2>/dev/null
screencapture -x "$out/screen.png" 2>/dev/null
if [ $rc -eq 0 ]; then
  note "GUEST RESULT: PASS"
  exit 0
fi
note "GUEST RESULT: FAIL"
exit 1
