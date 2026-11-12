#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-App-Pending
#
# Notarises an .app or a .dmg with notarytool (QA-R30 steps 5 and 6), waits for the result, fetches
# the notarisation log and fails on any status other than Accepted or on any issue in the log, then
# staples the ticket and validates it.
#
# Credentials (never printed):
#   App Store Connect API key (QA-R30: not an app-specific password):
#     ASC_API_KEY_PATH   path to the AuthKey_<id>.p8 file
#     ASC_API_KEY_ID     key ID
#     ASC_API_ISSUER_ID  issuer UUID
#   or a notarytool keychain profile created with `xcrun notarytool store-credentials`:
#     NOTARY_KEYCHAIN_PROFILE  profile name (Pa's Mac)
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/notarize.sh <App.app | file.dmg> [--no-staple] [--log-dir DIR] [--timeout DURATION]

An .app is zipped (ditto --keepParent) for submission and the ticket is stapled to the .app.
A .dmg is submitted as is and stapled. Credentials come from the environment (see the header of
this script). --timeout is passed to notarytool --timeout (default 90m).
EOF
}

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

target=""
staple=1
log_dir=""
timeout="90m"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --no-staple) staple=0; shift ;;
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
elif [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  auth=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
else
  die "no notarisation credentials: set ASC_API_KEY_PATH/ASC_API_KEY_ID/ASC_API_ISSUER_ID or NOTARY_KEYCHAIN_PROFILE"
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
