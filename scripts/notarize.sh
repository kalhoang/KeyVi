#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-App-Pending
#
# Notarises an .app or a .dmg with notarytool (QA-R30 steps 5 and 6), waits for the result, fetches
# the notarisation log and fails on any status other than Accepted or on any issue in the log, then
# staples the ticket and validates it.
#
# Inputs: the .app or .dmg to notarise (an .app is zipped with ditto --keepParent for submission);
# --log-dir (default: the directory of the target), --timeout (notarytool --timeout, default 90m),
# --no-staple, --dry-run (print the plan, contact nobody). Reads scripts/brand.env (APP_SLUG) for the
# default keychain profile name.
#
# Credentials, chosen in this order (values are never printed; QA-R30 wants an App Store Connect API key,
# not an app-specific password):
#   1. App Store Connect API key in the environment (CI, environment `release`):
#        ASC_API_KEY_PATH   path to the AuthKey_<id>.p8 file (written by scripts/ci-signing.sh setup
#                           from the secret ASC_API_KEY_P8_BASE64)
#        ASC_API_KEY_ID     key ID (secret ASC_API_KEY_ID)
#        ASC_API_ISSUER_ID  issuer UUID (secret ASC_API_ISSUER_ID)
#   2. NOTARY_KEYCHAIN_PROFILE: name of a notarytool keychain profile (Pa's Mac).
#   3. Otherwise the keychain profile "<slug>-notary" (APP_SLUG from scripts/brand.env), the name
#      docs/runbooks/notarization-setup.md tells Pa to store with `xcrun notarytool store-credentials`.
#
# Outputs: notarization-<file name>.json (the notary log) in the log directory; the stapled target.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/notarize.sh <App.app | file.dmg> [--no-staple] [--log-dir DIR] [--timeout DURATION] [--dry-run]

An .app is zipped (ditto --keepParent) for submission and the ticket is stapled to the .app.
A .dmg is submitted as is and stapled. --timeout is passed to notarytool --timeout (default 90m).
Credentials: ASC_API_KEY_PATH + ASC_API_KEY_ID + ASC_API_ISSUER_ID, else the keychain profile in
NOTARY_KEYCHAIN_PROFILE, else the keychain profile "<slug>-notary" (see the header of this script).
--dry-run prints which file and which credential source would be used, then exits.
EOF
}

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

target=""
staple=1
log_dir=""
timeout="90m"
dry_run=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --no-staple) staple=0; shift ;;
    --dry-run) dry_run=1; shift ;;
    --log-dir) log_dir="${2:?}"; shift 2 ;;
    --timeout) timeout="${2:?}"; shift 2 ;;
    -*) usage >&2; exit 2 ;;
    *) target="$1"; shift ;;
  esac
done
[[ -n "$target" && -e "$target" ]] || { usage >&2; exit 2; }
require_cmd xcrun ditto

auth=()
if [[ -n "${ASC_API_KEY_PATH:-}" ]]; then
  : "${ASC_API_KEY_ID:?ASC_API_KEY_ID is required with ASC_API_KEY_PATH}"
  : "${ASC_API_ISSUER_ID:?ASC_API_ISSUER_ID is required with ASC_API_KEY_PATH}"
  [[ -f "$ASC_API_KEY_PATH" ]] || die "ASC_API_KEY_PATH does not point to a file"
  auth=(--key "$ASC_API_KEY_PATH" --key-id "$ASC_API_KEY_ID" --issuer "$ASC_API_ISSUER_ID")
  credential="App Store Connect API key (ASC_API_KEY_PATH, ASC_API_KEY_ID, ASC_API_ISSUER_ID)"
else
  if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    profile="$NOTARY_KEYCHAIN_PROFILE"
  else
    load_brand
    profile="$APP_SLUG-notary"
  fi
  auth=(--keychain-profile "$profile")
  credential="notarytool keychain profile \"$profile\""
fi

if [[ $dry_run -eq 1 ]]; then
  case "$target" in
    *.app | *.app/) info "dry run: would zip $(basename "$target") with ditto --keepParent and submit it" ;;
    *) info "dry run: would submit $(basename "$target")" ;;
  esac
  info "dry run: credentials from the $credential; staple: $([[ $staple -eq 1 ]] && echo yes || echo no)"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
log_dir="${log_dir:-$(dirname "$target")}"
mkdir -p "$log_dir"
name="$(basename "$target")"

case "$target" in
  *.app | *.app/)
    submission="$work/${name%.app}.zip"
    ditto -c -k --sequesterRsrc --keepParent "$target" "$submission"
    ;;
  *.dmg | *.zip | *.pkg) submission="$target" ;;
  *) die "unsupported file type: $target" ;;
esac

info "submitting $name to the notary service"
result="$work/submit.json"
if ! xcrun notarytool submit "$submission" "${auth[@]}" --wait --timeout "$timeout" \
  --output-format json >"$result"; then
  warn "notarytool submit returned an error"
fi
read -r submission_id status < <(py -c '
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    data = {}
print(data.get("id", "-"), data.get("status", "unknown"))' "$result")
info "submission $submission_id: $status"

log_file="$log_dir/notarization-${name}.json"
if [[ "$submission_id" != "-" ]]; then
  xcrun notarytool log "$submission_id" "${auth[@]}" "$log_file" >/dev/null || warn "could not fetch the notary log"
fi

issues=0
if [[ -f "$log_file" ]]; then
  issues="$(py - "$log_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    log = json.load(handle)
items = log.get("issues") or []
for item in items:
    severity = item.get("severity", "?")
    path = item.get("path", "?")
    message = item.get("message", "")
    print(f"{severity}: {path}: {message}", file=sys.stderr)
print(len(items))
PY
)"
fi
[[ "$status" == "Accepted" ]] || die "notarisation status for $name is $status (log: $log_file)"
[[ "$issues" == "0" ]] || die "notary log for $name lists $issues issue(s) (QA-R30: any issue fails)"

if [[ $staple -eq 1 ]]; then
  xcrun stapler staple "$target"
  xcrun stapler validate "$target"
fi
if [[ $staple -eq 1 ]]; then info "notarised and stapled: $name"; else info "notarised: $name"; fi
