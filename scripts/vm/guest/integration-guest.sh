#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Guest half of scripts/vm/integration-dev.sh: builds the INTEGRATION_HOOKS test build, TestHost and
# compat-harness from the copied checkout, grants them TCC with grant-tcc.sh and runs the QA-R11 TestHost suite
# (docs/runbooks/integration-suite.md section 3 step 3). Runs INSIDE the disposable macOS + Xcode VM through the
# tart guest agent, so it is in the logged-in GUI session; never on the host.
#
# The build mirrors `scripts/run-integration.sh build` with one difference: the VM has no Apple Development
# identity, so the test build is ad-hoc signed with the hardened runtime off (an ad-hoc signature has no Team ID,
# and library validation would refuse Sparkle). Its TCC grant is therefore tied to the cdhash and is renewed by
# this script after every build.
#
# Usage: integration-guest.sh --out DIR   (from the checkout root, inside the VM only; it exits 3 on a real Mac).
# Exit 0 when the suite passed.
set -uo pipefail

# Refuse to run anywhere but inside a virtual machine, before parsing arguments and before any side effect: this
# script replaces apps, changes global settings, uses sudo and launches the built app (QA-R13 keeps all of that
# off a real Mac). grant-tcc.sh carries the same guard.
[ "$(sysctl -n kern.hv_vmm_present 2>/dev/null || echo 0)" = 1 ] || {
  echo "refusing: not inside a virtual machine" >&2
  exit 3
}

out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out="${2:-}"; shift 2 ;;
    *) echo "usage: integration-guest.sh --out DIR" >&2; exit 2 ;;
  esac
done
[ -n "$out" ] || { echo "usage: integration-guest.sh --out DIR" >&2; exit 2; }
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
# The marker string only the INTEGRATION_HOOKS code carries; kept equal to HOOKS_MARKER of scripts/run-integration.sh
# by scripts/tests/test_vm_lab.py (ADR 0502).
HOOKS_MARKER="INTEGRATION_HOOKS test build: file-drop integration hooks"

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

step "xcodegen"
xcodegen_bin="$(scripts/install-xcodegen.sh --prefer-system 2>"$out/xcodegen.log")" || stop "install-xcodegen.sh failed (xcodegen.log)"
"$xcodegen_bin/xcodegen" generate >>"$out/xcodegen.log" 2>&1 || stop "xcodegen generate failed (xcodegen.log)"

step "build: App (Integration, ad-hoc, hardened runtime off) and TestHost (Debug)"
sign=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= OTHER_CODE_SIGN_FLAGS= ENABLE_HARDENED_RUNTIME=NO)
xcodebuild -project App.xcodeproj -scheme App -configuration Integration -derivedDataPath "$derived" \
  -disableAutomaticPackageResolution ONLY_ACTIVE_ARCH=YES "${sign[@]}" build >"$out/build-app.log" 2>&1 ||
  stop "App Integration build failed (build-app.log: $(grep -m 1 'error:' "$out/build-app.log"))"
xcodebuild -project App.xcodeproj -scheme TestHost -configuration Debug -derivedDataPath "$derived" \
  -disableAutomaticPackageResolution ONLY_ACTIVE_ARCH=YES build >"$out/build-testhost.log" 2>&1 ||
  stop "TestHost build failed (build-testhost.log)"
mkdir -p "$apps"
pkill -x "$APP_DISPLAY_NAME" 2>/dev/null
pkill -x TestHost 2>/dev/null
rm -rf "$app" "$apps/TestHost.app"
ditto "$derived/Build/Products/Integration/$APP_DISPLAY_NAME.app" "$app" || stop "install of the test build failed"
ditto "$derived/Build/Products/Debug/TestHost.app" "$apps/TestHost.app" || stop "install of TestHost failed"
LC_ALL=C grep -a -F -q -- "$HOOKS_MARKER" "$app/Contents/MacOS/$APP_DISPLAY_NAME" ||
  stop "the installed test build has no integration hooks"
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
COMPAT_HARNESS_LIVE=1 scripts/run-integration.sh tests >"$out/tests.log" 2>&1
rc=$?
cp -R .build/integration/tests "$out/results" 2>/dev/null
note "run-integration.sh tests exit $rc"
grep -E '^(pass|fail|needsHuman) ' "$out/tests.log" | awk '{print $1}' | sort | uniq -c | while read -r count kind; do
  note "  $kind: $count"
done
grep -E '^fail ' "$out/tests.log" | head -n 15 | while read -r line; do note "  $line"; done
if [ $rc -eq 0 ]; then
  note "GUEST RESULT: PASS"
  exit 0
fi
note "GUEST RESULT: FAIL"
exit 1
