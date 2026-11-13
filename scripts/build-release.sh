#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds the universal Release app (QA-R30 step 2, PLT-R105, PLT-R750, PLT-R908):
#   - XcodeGen project from project.yml, scheme App, configuration Release
#   - arm64 + x86_64, hardened runtime, secure timestamp, Developer ID Application identity,
#     no injected base entitlements (no get-task-allow), no other entitlements
#   - MARKETING_VERSION = <version>, CURRENT_PROJECT_VERSION = <build>
#
# Inputs: <version> (X.Y.Z or X.Y.Z-beta.N; release.yml takes it from the v* tag) and <build> (the
# CFBundleVersion integer from scripts/build-number.sh <version>, ADR 0503). Options: --keychain (CI passes
# $SIGNING_KEYCHAIN, exported by scripts/ci-signing.sh setup), --identity, --out, --unsigned, --dry-run.
# Reads: project.yml (XcodeGen, scripts/install-xcodegen.sh pins the tool), Config/Signing.xcconfig
# (CODE_SIGN_IDENTITY_RELEASE, DEVELOPMENT_TEAM), scripts/brand.env (APP_DISPLAY_NAME, APP_SLUG). The Sparkle
# public key comes from Config/Sparkle.xcconfig through the project; scripts/verify-release.sh checks it.
# Environment: none required. The Developer ID identity must be in the login keychain or in --keychain.
# Nested code (PLT-R750, PLT-R908, PLT-R909): Code Sign On Copy re-signs Sparkle.framework but not the helpers
# inside it, which Sparkle ships ad-hoc signed; only Xcode's Archive and Export would re-sign them (Sparkle
# documentation, "Sandboxing with Sparkle", section Code Signing). This script re-signs them itself, inside out
# and without --deep as that section describes, after copying the app out of the archive:
#   - the XPC services are removed: the app is not sandboxed and sets neither SUEnableInstallerLauncherService
#     nor SUEnableDownloaderService, so they never run, and PLT-R909 allows no XPC listeners (same page,
#     "Removing XPC Services")
#   - Autoupdate and Updater.app, then the framework, then the app last, so its seal covers the new signatures,
#     each with the Developer ID certificate Xcode signed the app with, hardened runtime and a secure timestamp
# scripts/verify-release.sh then checks every nested executable.
# Outputs: dist/<slug>-<version>/<Display Name>.app, App.xcarchive (as Xcode wrote it) and build-info.json
# (commit, Xcode, Swift, macOS, QA-R23). The last line on stdout is the path of the .app.
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

# PLT-R910, ADR 0301: -disableAutomaticPackageResolution makes a drift between project.yml and the committed
# Config/Package.resolved fail the build instead of silently resolving another Sparkle revision.
cmd=(
  xcodebuild archive
  -project App.xcodeproj -scheme App -configuration Release
  -destination 'generic/platform=macOS'
  -archivePath "$archive"
  -disableAutomaticPackageResolution
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO
  "MARKETING_VERSION=$version" "CURRENT_PROJECT_VERSION=$build"
  "${sign_args[@]}"
)

# Sparkle's helpers, signed before the framework (see the header). The XPC services are removed, not signed.
SPARKLE_HELPERS=(Autoupdate Updater.app)

# The leaf certificate Xcode signed the app with; the nested code is re-signed with the same one.
signing_authority() {
  codesign --display --verbose=2 "$1" 2>&1 | sed -n 's/^Authority=//p' | head -n1
}

sign_code() {
  local args=(--force --sign "$sign_identity" --options runtime --timestamp)
  [[ -n "$keychain" ]] && args+=(--keychain "$keychain")
  codesign "${args[@]}" "$@"
}

resign_nested_code() {
  local app="$1" framework="$1/Contents/Frameworks/Sparkle.framework" current version helper
  [[ -d "$framework" ]] || die "Sparkle.framework is missing from $app (PLT-R104)"
  current="$(readlink "$framework/Versions/Current")" || die "Sparkle.framework has no Versions/Current link"
  version="$framework/Versions/$current"
  rm -rf "$version/XPCServices" "$framework/XPCServices"
  for helper in "${SPARKLE_HELPERS[@]}"; do
    [[ -e "$version/$helper" ]] || die "Sparkle helper missing: $version/$helper"
    sign_code "$version/$helper"
  done
  sign_code "$framework"
  sign_code --preserve-metadata=identifier,entitlements,flags "$app"
}

if [[ $dry_run -eq 1 ]]; then
  printf 'xcodegen generate\n'
  printf '%q ' "${cmd[@]}"
  printf '\n'
  if [[ $unsigned -eq 0 ]]; then
    printf 'then, in the copied app: remove Sparkle.framework XPCServices; codesign inside out: %s, Sparkle.framework, the app\n' \
      "${SPARKLE_HELPERS[*]}"
  fi
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

if [[ $unsigned -eq 0 ]]; then
  sign_identity="$(signing_authority "$app")"
  [[ "$sign_identity" =~ ^Developer\ ID\ Application:\ .*\($APP_TEAM_ID\)$ ]] \
    || die "$app is not signed with Developer ID Application for team $APP_TEAM_ID (found: ${sign_identity:-none})"
  resign_nested_code "$app"
fi

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
