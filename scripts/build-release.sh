#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-App-Pending
#
# Builds the universal Release app (QA-R30 step 2, PLT-R105, PLT-R750, PLT-R908):
#   - XcodeGen project from project.yml, scheme App, configuration Release
#   - arm64 + x86_64, hardened runtime, secure timestamp, Developer ID Application identity,
#     no injected base entitlements (no get-task-allow), no other entitlements
#   - MARKETING_VERSION = <version>, CURRENT_PROJECT_VERSION = <build>
# Output: dist/<slug>-<version>/<Display Name>.app plus build-info.json (Xcode version, QA-R23).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/build-release.sh <version> <build> [options]

  <version>   X.Y.Z or X.Y.Z-beta.N (CFBundleShortVersionString)
  <build>     CFBundleVersion integer (see scripts/build-number.sh)

Options:
  --keychain PATH   keychain holding the Developer ID identity (CI temporary keychain)
  --identity NAME   signing identity (default: CODE_SIGN_IDENTITY_RELEASE from Config/Signing.xcconfig)
  --out DIR         output directory (default dist/<slug>-<version>)
  --unsigned        build without signing (local smoke test; never for distribution)
  --dry-run         print the xcodebuild command without running it
  -h, --help        show this help
EOF
}

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

version=""
build=""
keychain=""
identity=""
out=""
unsigned=0
dry_run=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --keychain) keychain="${2:?}"; shift 2 ;;
    --identity) identity="${2:?}"; shift 2 ;;
    --out) out="${2:?}"; shift 2 ;;
    --unsigned) unsigned=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    -*) usage >&2; exit 2 ;;
    *)
      if [[ -z "$version" ]]; then version="$1"; elif [[ -z "$build" ]]; then build="$1"; else usage >&2; exit 2; fi
      shift
      ;;
  esac
done
[[ -n "$version" && -n "$build" ]] || { usage >&2; exit 2; }
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?$ ]] || die "invalid version: $version"
[[ "$build" =~ ^[1-9][0-9]*$ ]] || die "invalid build number: $build"

load_brand
load_team_id
if [[ -z "$identity" ]]; then
  identity="$(sed -n 's/^[[:space:]]*CODE_SIGN_IDENTITY_RELEASE[[:space:]]*=[[:space:]]*//p' \
    "$REPO_ROOT/Config/Signing.xcconfig" | head -n1)"
fi
[[ -n "$identity" ]] || die "no signing identity configured"

out="${out:-$REPO_ROOT/dist/$APP_SLUG-$version}"
archive="$out/App.xcarchive"

cd "$REPO_ROOT"
[[ -f project.yml ]] || die "project.yml not found (app track)"

sign_args=()
if [[ $unsigned -eq 1 ]]; then
  warn "unsigned build: for local smoke tests only"
  sign_args=(CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY='')
else
  codesign_flags="--timestamp --options=runtime"
  [[ -n "$keychain" ]] && codesign_flags="$codesign_flags --keychain $keychain"
  sign_args=(
    CODE_SIGN_STYLE=Manual
    "CODE_SIGN_IDENTITY=$identity"
    "DEVELOPMENT_TEAM=$APP_TEAM_ID"
    ENABLE_HARDENED_RUNTIME=YES
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
    "OTHER_CODE_SIGN_FLAGS=$codesign_flags"
  )
fi

cmd=(
  xcodebuild archive
  -project App.xcodeproj -scheme App -configuration Release
  -destination 'generic/platform=macOS'
  -archivePath "$archive"
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO
  "MARKETING_VERSION=$version" "CURRENT_PROJECT_VERSION=$build"
  "${sign_args[@]}"
)

if [[ $dry_run -eq 1 ]]; then
  printf 'xcodegen generate\n'
  printf '%q ' "${cmd[@]}"
  printf '\n'
  exit 0
fi

xcodegen_bin="$(scripts/install-xcodegen.sh --prefer-system)"
"$xcodegen_bin/xcodegen" generate
rm -rf "$out"
mkdir -p "$out"
"${cmd[@]}"

app_src=""
for candidate in "$archive/Products/Applications/"*.app; do
  [[ -d "$candidate" ]] && app_src="$candidate"
done
[[ -n "$app_src" ]] || die "no .app in $archive/Products/Applications"
app="$out/$APP_DISPLAY_NAME.app"
ditto "$app_src" "$app"

actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
actual_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
[[ "$actual_version" == "$version" ]] || die "Info.plist version $actual_version != $version"
[[ "$actual_build" == "$build" ]] || die "Info.plist build $actual_build != $build"

py - "$out/build-info.json" "$version" "$build" "$REPO_ROOT" <<'PY'
import datetime
import json
import subprocess
import sys

out, version, build, repo = sys.argv[1:]


def run(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True, check=False).stdout.strip()
info = {
    "version": version,
    "build": int(build),
    "commit": run("git", "-C", repo, "rev-parse", "HEAD"),
    "xcode": run("xcodebuild", "-version").replace("\n", " "),
    "swift": run("swift", "--version").splitlines()[0] if run("swift", "--version") else "",
    "macOS": run("sw_vers", "-productVersion"),
    "builtAt": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat(),
}
with open(out, "w", encoding="utf-8") as handle:
    json.dump(info, handle, indent=2)
    handle.write("\n")
PY
info "built $app"
printf '%s\n' "$app"
