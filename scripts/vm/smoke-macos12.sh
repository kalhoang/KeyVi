#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# macOS 12 smoke test of the universal app in a throwaway clone of the macOS 12 tart VM (VM_MONTEREY)
# (ADR 0315 "macOS 12 smoke test"; PLT-R105 universal binary, PLT-R106 macOS 12 floor).
#
# Builds the app (Release, arm64 + x86_64, ad-hoc signed so it can run) or takes --app, checks the slices on
# the host, boots the VM, installs the app in /Applications inside it, launches the arm64 slice natively and
# the x86_64 slice under Rosetta, and requires each to stay up for the window with no dyld or missing-symbol
# error and no crash report. The app never runs on the host. Logs go to VM_LAB_RUNS/<timestamp>-macos12/.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/vm/smoke-macos12.sh [options]

  --app PATH           test this .app instead of building one
  --vm NAME            base VM (default VM_MONTEREY, <slug>-monterey)
  --in-place           run in the base VM itself instead of a throwaway clone (keeps what the run installs,
                       for example Rosetta)
  --alive-seconds N    how long each slice must stay up (default 20, at least 20)
  --derived-data DIR   xcodebuild derived data for the build (default /tmp/vm-smoke-dd; never on /Volumes/Data)
  --output DIR         run folder (default VM_LAB_RUNS/<UTC timestamp>-macos12)
  --memory MB, --cpus N  VM size (default 4096 MB, 2 CPUs)
  -h, --help           this help

Exit status: 0 PASS, 1 FAIL, 2 usage error, 3 refused by a safety rule (another VM runs, a VM with the clone
name exists that the lab did not create).
EOF
}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$HERE/../lib/common.sh"
# shellcheck source=scripts/vm/lib.sh
source "$HERE/lib.sh"

app=""
base_vm="$VM_MONTEREY"
in_place=0
alive=20
derived="${SMOKE_DERIVED_DATA:-/tmp/vm-smoke-dd}"
run_dir=""
memory=""
cpus=""

bad_usage() {
  printf 'smoke-macos12: %s\n' "$*" >&2
  usage >&2
  exit 2
}

while (($#)); do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --app | --vm | --alive-seconds | --derived-data | --output | --memory | --cpus)
      (($# >= 2)) || bad_usage "$1 needs a value"
      case "$1" in
        --app) app="$2" ;;
        --vm) base_vm="$2" ;;
        --alive-seconds) alive="$2" ;;
        --derived-data) derived="$2" ;;
        --output) run_dir="$2" ;;
        --memory) memory="$2" ;;
        --cpus) cpus="$2" ;;
      esac
      shift 2
      ;;
    --in-place) in_place=1; shift ;;
    *) bad_usage "unknown option: $1" ;;
  esac
done

# --- Arguments and safety checks, before anything is built or booted ---------------------------------------
lab_validate_int "--alive-seconds" "$alive" 20 600 || exit
lab_validate_name "$base_vm" || exit
memory="${memory:-$(lab_default_memory "$base_vm")}"
cpus="${cpus:-$(lab_default_cpus "$base_vm")}"
lab_validate_int "memory (MB)" "$memory" 1024 "$VM_LAB_MAX_MEMORY_MB" || exit
lab_validate_int "CPU count" "$cpus" 1 "$VM_LAB_MAX_CPUS" || exit

app_exec=""
app_id=""
read_bundle() { # read_bundle <app>: sets app_exec and app_id or exits 2
  local bundle="$1"
  if [[ ! -d "$bundle" || ! -f "$bundle/Contents/Info.plist" ]]; then
    lab_err "not an app bundle (no Contents/Info.plist): $bundle"
    exit 2
  fi
  app_exec="$(plutil -extract CFBundleExecutable raw -o - "$bundle/Contents/Info.plist" 2>/dev/null || true)"
  app_id="$(plutil -extract CFBundleIdentifier raw -o - "$bundle/Contents/Info.plist" 2>/dev/null || true)"
  if [[ -z "$app_exec" || -z "$app_id" || ! -f "$bundle/Contents/MacOS/$app_exec" ]]; then
    lab_err "the bundle has no CFBundleExecutable, CFBundleIdentifier or executable: $bundle"
    exit 2
  fi
  if [[ ! "$(basename "$bundle")" =~ ^[A-Za-z0-9._-]+\.app$ ]]; then
    lab_err "unsupported characters in the bundle name: $(basename "$bundle")"
    exit 2
  fi
}
if [[ -n "$app" ]]; then
  read_bundle "$app"
fi

lab_prepare_target "$base_vm" "$in_place" smoke || exit
vm="$LAB_TARGET"

run_dir="${run_dir:-$VM_LAB_RUNS/$(date -u +%Y%m%dT%H%M%SZ)-macos12}"
mkdir -p "$run_dir"
run_dir="$(cd "$run_dir" && pwd)"
results="$run_dir/summary.txt"
: >"$results"
# Everything printed on stderr from here on (including the lab's own messages) also goes to smoke.log.
exec 2> >(tee -a "$run_dir/smoke.log" >&2)
say() { printf '%s\n' "$*" >&2; }
record() {
  printf '%s\n' "$*" >>"$results"
  printf '%s\n' "$*" >&2
}
finish() { # finish <PASS|FAIL>
  record "RESULT: $1 (logs: $run_dir)"
  printf 'RESULT: %s\n' "$1"
  [[ "$1" == PASS ]] && exit 0
  exit 1
}

# --- Build (unless --app) -------------------------------------------------------------------------------------
if [[ -z "$app" ]]; then
  case "$derived" in /Volumes/Data/*) bad_usage "--derived-data must not be on /Volumes/Data (xcodebuild times out there)" ;; esac
  require_cmd xcodegen xcodebuild
  load_brand
  say "building the universal Release app, ad-hoc signed, hardened runtime off (log $run_dir/build.log)"
  # ENABLE_HARDENED_RUNTIME=NO: an ad-hoc signature has no Team ID, and the hardened runtime's library
  # validation then refuses the embedded Sparkle.framework (the first run on 2026-11-13: dyld "mapped file has
  # no Team ID and is not a platform binary" for the x86_64 slice). Release builds are signed with the
  # Developer ID (one Team ID for the app and its frameworks) and keep the hardened runtime (PLT-R750).
  if ! (cd "$REPO_ROOT" && xcodegen generate && xcodebuild -project App.xcodeproj -scheme App \
    -configuration Release ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- \
    CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= OTHER_CODE_SIGN_FLAGS= ENABLE_HARDENED_RUNTIME=NO \
    -derivedDataPath "$derived" -jobs 3 build) \
    >"$run_dir/build.log" 2>&1; then
    record "FAIL build: xcodebuild failed (build.log)"
    finish FAIL
  fi
  app="$derived/Build/Products/Release/$APP_DISPLAY_NAME.app"
  read_bundle "$app"
fi
app="$(cd "$(dirname "$app")" && pwd)/$(basename "$app")"
say "app: $app ($app_id)"

# --- Host-side slice check (fails fast, before any VM boots) --------------------------------------------------
host_ok=1
if ! perl "$HERE/macho-info.pl" "$app/Contents/MacOS/$app_exec" >"$run_dir/host-macho.txt" 2>&1; then
  record "FAIL host slices: $(head -n 1 "$run_dir/host-macho.txt")"
  host_ok=0
else
  for arch in arm64 x86_64; do
    if ! grep -q "^$arch minos " "$run_dir/host-macho.txt"; then
      record "FAIL host slices: $arch missing"
      host_ok=0
    fi
  done
  if command -v lipo >/dev/null 2>&1; then
    lipo -archs "$app/Contents/MacOS/$app_exec" >>"$run_dir/host-macho.txt" 2>&1 || true
  fi
fi
if ((host_ok == 0)); then
  finish FAIL
fi
record "PASS host slices: $(tr '\n' ';' <"$run_dir/host-macho.txt" | sed 's/;$//; s/;/; /g')"

# --- VM ---------------------------------------------------------------------------------------------------------
lab_install_trap
lab_start_target "$base_vm" "$vm" "$memory" "$cpus" || {
  record "FAIL vm: $vm did not come up"
  finish FAIL
}

remote="vm-smoke"
lab_ssh "$vm" "rm -rf $remote && mkdir -p $remote/tools" </dev/null || true
tools="$(mktemp -d)"
cp "$HERE/guest/smoke-guest.sh" "$HERE/macho-info.pl" "$tools/"
if ! lab_push "$vm" "$tools/." "$remote/tools" || ! lab_push "$vm" "$app" "$remote"; then
  rm -rf "$tools"
  record "FAIL vm: could not copy the app into $vm"
  finish FAIL
fi
rm -rf "$tools"

say "running the guest checks in $vm (alive window ${alive} s per slice)"
guest_rc=0
lab_ssh "$vm" "bash $remote/tools/smoke-guest.sh --app \"\$HOME/$remote/$(basename "$app")\" --subsystem '$app_id' --out \"\$HOME/$remote/out\" --alive $alive" \
  </dev/null >"$run_dir/guest.log" 2>&1 || guest_rc=$?
if ! lab_pull "$vm" "$remote/out" "$run_dir"; then
  say "warning: could not copy the guest logs back"
fi
if [[ -f "$run_dir/out/summary.txt" ]]; then
  while IFS= read -r line; do record "$line"; done <"$run_dir/out/summary.txt"
else
  while IFS= read -r line; do record "guest: $line"; done <"$run_dir/guest.log"
fi
if ((guest_rc == 0)); then
  finish PASS
fi
finish FAIL
