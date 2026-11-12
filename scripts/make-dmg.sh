#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-App-Pending
#
# Creates the distribution disk image (QA-R30 step 4): the app plus an /Applications link, an
# optional background image (packaging/dmg/background.png, see packaging/dmg/README.md), compressed
# UDZO, then signed with the Developer ID identity and a secure timestamp.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/make-dmg.sh <App.app> [options]

Options:
  --out FILE        output DMG (default: <dir of app>/<slug>-<version>.dmg)
  --keychain PATH   keychain holding the identity (CI temporary keychain)
  --identity NAME   signing identity (default: CODE_SIGN_IDENTITY_RELEASE, Config/Signing.xcconfig)
  --no-sign         leave the DMG unsigned (local smoke test only)
  -h, --help        show this help
Prints the DMG path on success.
EOF
}

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

app=""
out=""
keychain=""
identity=""
sign=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --out) out="${2:?}"; shift 2 ;;
    --keychain) keychain="${2:?}"; shift 2 ;;
    --identity) identity="${2:?}"; shift 2 ;;
    --no-sign) sign=0; shift ;;
    -*) usage >&2; exit 2 ;;
    *) app="$1"; shift ;;
  esac
done
[[ -n "$app" ]] || { usage >&2; exit 2; }
[[ -d "$app" && -f "$app/Contents/Info.plist" ]] || die "not an app bundle: $app"
require_cmd hdiutil ditto

load_brand
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
out="${out:-$(cd "$(dirname "$app")" && pwd)/$APP_SLUG-$version.dmg}"

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/$(basename "$app")"
ln -s /Applications "$staging/Applications"
background="$REPO_ROOT/packaging/dmg/background.png"
if [[ -f "$background" ]]; then
  mkdir "$staging/.background"
  cp "$background" "$staging/.background/background.png"
fi

rm -f "$out"
hdiutil create -volname "$APP_DISPLAY_NAME" -srcfolder "$staging" -fs HFS+ -format UDZO \
  -imagekey zlib-level=9 -ov "$out" >/dev/null
hdiutil verify "$out" >/dev/null

if [[ $sign -eq 1 ]]; then
  if [[ -z "$identity" ]]; then
    load_team_id
    base="$(sed -n 's/^[[:space:]]*CODE_SIGN_IDENTITY_RELEASE[[:space:]]*=[[:space:]]*//p' \
      "$REPO_ROOT/Config/Signing.xcconfig" | head -n1)"
    identity="$base"
  fi
  args=(--force --sign "$identity" --timestamp)
  [[ -n "$keychain" ]] && args+=(--keychain "$keychain")
  codesign "${args[@]}" "$out"
  codesign --verify --strict --verbose=2 "$out"
else
  warn "DMG left unsigned (--no-sign)"
fi
info "created $out"
printf '%s\n' "$out"
