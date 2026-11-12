#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-App-Pending
#
# Verifies a release build (QA-R30 steps 3 and 6, PLT-R750, PLT-R908, section 9 acceptance):
#   - codesign --verify --deep --strict
#   - signed by Developer ID Application for the team in Config/Signing.xcconfig, secure timestamp
#   - hardened runtime flag present; entitlements empty (no get-task-allow, no exceptions)
#   - bundle ID equals APP_BUNDLE_ID_RELEASE; universal binary (arm64 + x86_64)
#   - designated requirement equals the expected default requirement for bundle ID + team, and equals
#     the previous release's requirement when given (a change makes macOS re-ask permissions)
#   - after notarisation: stapler validate (app and DMG) and spctl --assess
#   - URL host allowlist (QA-R60)
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/verify-release.sh --app PATH [options]

Options:
  --app PATH            the .app to verify
  --dmg PATH            the signed (and, after notarisation, stapled) DMG
  --previous-dr FILE    designated requirement of the previous release (text from --write-dr)
  --write-dr FILE       write this build's designated requirement to FILE (release asset)
  --pre-notarization    skip stapler and Gatekeeper checks (before notarisation)
  -h, --help            show this help
Exit status: 0 all checks passed, 1 a check failed.
EOF
}

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

app=""
dmg=""
previous_dr=""
write_dr=""
pre=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --app) app="${2:?}"; shift 2 ;;
    --dmg) dmg="${2:?}"; shift 2 ;;
    --previous-dr) previous_dr="${2:?}"; shift 2 ;;
    --write-dr) write_dr="${2:?}"; shift 2 ;;
    --pre-notarization) pre=1; shift ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ -n "$app" && -d "$app" ]] || { usage >&2; exit 2; }
require_cmd codesign lipo spctl xcrun
load_brand
load_team_id

failures=()
check() {
  local name="$1"
  shift
  if "$@"; then
    info "ok: $name"
  else
    failures+=("$name")
    log "FAILED: $name"
  fi
}

normalize_dr() {
  # Drops comments and collapses whitespace so formatting differences do not matter.
  # Team IDs that start with a digit are quoted by codesign; compare them unquoted.
  sed -E 's#/\*[^*]*\*/##g; s/^designated => //; s/= "([A-Z0-9]+)"/= \1/g' | tr -s '[:space:]' ' ' \
    | sed -E 's/^ //; s/ $//'
}

expected_dr() {
  printf 'identifier "%s" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = %s\n' \
    "$APP_BUNDLE_ID_RELEASE" "$APP_TEAM_ID" | normalize_dr
}

actual_dr() {
  codesign --display --requirements - "$app" 2>/dev/null | grep '^designated =>' | normalize_dr
}

info_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$app/Contents/Info.plist" 2>/dev/null; }

check_signature() { codesign --verify --deep --strict --verbose=2 "$app"; }

check_identity() {
  local details
  details="$(codesign --display --verbose=4 "$app" 2>&1)"
  grep -q "^Authority=Developer ID Application: .*($APP_TEAM_ID)$" <<<"$details" \
    && grep -q "^TeamIdentifier=$APP_TEAM_ID$" <<<"$details" \
    && grep -q '^Timestamp=' <<<"$details"
}

check_runtime() {
  local details
  details="$(codesign --display --verbose=4 "$app" 2>&1)"
  grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime' <<<"$details"
}

check_entitlements() {
  local xml
  xml="$(codesign --display --entitlements - --xml "$app" 2>/dev/null || true)"
  py -c '
import plistlib, sys
data = sys.stdin.buffer.read().strip()
if not data:
    sys.exit(0)
entitlements = plistlib.loads(data)
if entitlements:
    print("entitlements present: " + ", ".join(sorted(entitlements)), file=sys.stderr)
    sys.exit(1)' <<<"$xml"
}

check_bundle_id() { [[ "$(info_value CFBundleIdentifier)" == "$APP_BUNDLE_ID_RELEASE" ]]; }

check_universal() {
  local exe archs
  exe="$app/Contents/MacOS/$(info_value CFBundleExecutable)"
  archs="$(lipo -archs "$exe")"
  [[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]]
}

check_dr_expected() {
  local actual expected
  actual="$(actual_dr)"
  expected="$(expected_dr)"
  if [[ "$actual" != "$expected" ]]; then
    log "  actual:   $actual"
    log "  expected: $expected"
    return 1
  fi
}

check_dr_previous() {
  local actual previous
  actual="$(actual_dr)"
  previous="$(normalize_dr <"$previous_dr")"
  if [[ "$actual" != "$previous" ]]; then
    log "  this build: $actual"
    log "  previous:   $previous"
    return 1
  fi
}

check_staple_app() { xcrun stapler validate "$app"; }
check_gatekeeper_app() { spctl --assess --type execute --verbose=4 "$app"; }
check_dmg_signature() { codesign --verify --strict --verbose=2 "$dmg"; }
check_staple_dmg() { xcrun stapler validate "$dmg"; }
check_gatekeeper_dmg() { spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg"; }
check_hosts() { "$REPO_ROOT/scripts/check-url-hosts.sh" "$app"; }

check "codesign --verify --deep --strict" check_signature
check "Developer ID identity, team $APP_TEAM_ID, secure timestamp" check_identity
check "hardened runtime flag" check_runtime
check "no entitlements" check_entitlements
check "bundle ID $APP_BUNDLE_ID_RELEASE" check_bundle_id
check "universal binary (arm64 + x86_64)" check_universal
check "designated requirement equals the expected requirement" check_dr_expected
if [[ -n "$previous_dr" ]]; then
  check "designated requirement unchanged against the previous release" check_dr_previous
else
  info "no previous designated requirement given (first release)"
fi
check "URL host allowlist (QA-R60)" check_hosts
if [[ -n "$dmg" ]]; then
  check "DMG signature" check_dmg_signature
fi
if [[ $pre -eq 0 ]]; then
  check "stapler validate (app)" check_staple_app
  check "spctl --assess (app)" check_gatekeeper_app
  if [[ -n "$dmg" ]]; then
    check "stapler validate (DMG)" check_staple_dmg
    check "spctl --assess (DMG)" check_gatekeeper_dmg
  fi
fi

if [[ -n "$write_dr" ]]; then
  actual_dr >"$write_dr"
  info "designated requirement written to $write_dr"
fi

if [[ ${#failures[@]} -gt 0 ]]; then
  die "release verification failed: ${failures[*]}"
fi
info "release verification passed"
