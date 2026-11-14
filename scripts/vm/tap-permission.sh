#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Which TCC permission the app's event tap needs, and which checks see a grant made while the app runs
# (PLT-R701, PLT-R702, PLT-R731; docs/runbooks/vm-test-lab.md section 11). In a throwaway clone of the macOS + Xcode
# lab VM (SIP disabled, so scripts/vm/grant-tcc.sh can write TCC), a small probe app (guest/tap-permission-probe.swift)
# keeps trying to install the app's kind of tap (active, key-down, session level) and reports every second what
# AXIsProcessTrusted(), CGPreflightPostEventAccess(), CGPreflightListenEventAccess() and a listen-only tap say, how
# many keys typed by the guest automation its tap received and whether its own posted keys came back. Phases: fresh
# TCC; Accessibility only, same process; Accessibility only, relaunched; Input Monitoring added, same process; both,
# relaunched.
#
# The host builds and signs (ad hoc) the probe, boots, copies and reads; it never runs the probe, posts an event,
# creates a tap or touches TCC. Everything else runs inside the VM through the tart guest agent (the logged-in
# session), in the `guest` mode of this script, which refuses a real Mac.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/vm/tap-permission.sh [options]
       scripts/vm/tap-permission.sh guest --out DIR --bundle PATH.app --typer PATH --grant PATH [--keys N]
       scripts/vm/tap-permission.sh summarize --input FILE

  --vm NAME              base VM (default VM_DEV, <slug>-dev; its SIP must be disabled); the run uses the
                         throwaway clone NAME-tap
  --keys N               keys the guest types per phase (default 10, at most 50)
  --output DIR           run folder (default VM_LAB_RUNS/<UTC timestamp>-tap-permission)
  --memory MB, --cpus N  VM size (default per VM, vm-test-lab.md section 3)
  -h, --help             this help

guest      runs the phases inside the VM (the host mode calls it through the tart guest agent); exits 3 elsewhere.
           TAP_PERMISSION_SETTLE (default 4) and TAP_PERMISSION_DRAIN (default 3) are the seconds it waits after a
           change and after typing.
summarize  prints the per-phase table of a probe.jsonl written by the guest.

The run folder gets tap-permission.log, guest.log and tap-out/ (probe.jsonl, grant logs, tcc-rows.txt, system.txt)
plus summary.txt. Exit status: 0 every phase ran, 1 otherwise, 2 usage error, 3 refused by a safety rule (Safari is
open on the host, another VM runs, a VM with the clone name exists that the lab did not create, not a VM).
EOF
}

# Phases in order: name, then what changes before it (none, grant:<service>, relaunch).
PHASES="fresh:none accessibility-live:grant:kTCCServiceAccessibility accessibility-relaunch:relaunch input-monitoring-live:grant:kTCCServiceListenEvent input-monitoring-relaunch:relaunch"
PROBE_NAME="tap-permission-probe"
APP_BUNDLE_NAME="TapProbe"

# --- summarize: the table of the run (pure, runs anywhere) ------------------------------------------------------
summarize() {
  local input=""
  while (($#)); do
    case "$1" in
      --input) (($# >= 2)) || { usage >&2; exit 2; }; input="$2"; shift 2 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  [[ -f "$input" ]] || { printf 'tap-permission: no such probe log: %s\n' "$input" >&2; exit 2; }
  python3 -I - "$input" <<'PY'
import json, sys

rows, phase, phases = {}, None, []
for raw in open(sys.argv[1], encoding="utf-8"):
    raw = raw.strip()
    if not raw:
        continue
    try:
        item = json.loads(raw)
    except ValueError:
        continue
    if "phase" in item:
        phase = item["phase"]
        phases.append(phase)
        rows[phase] = {"lines": [], "typed": item.get("typed", 0)}
    elif phase is not None:
        rows[phase]["lines"].append(item)

def yes(value):
    return "yes" if value else "no"

print("phase                      ax   post  listen  activeTap  listenOnlyNow  keys/typed  echoes/posted")
for name in phases:
    lines = rows[name]["lines"]
    if not lines:
        print(f"{name:<26} (no probe line)")
        continue
    last = lines[-1]
    same = [line for line in lines if line["pid"] == last["pid"]]
    keys = last["keys"] - same[0]["keys"]
    echoes = last["echoes"] - same[0]["echoes"]
    posted = last["posted"] - same[0]["posted"]
    print(f"{name:<26} {yes(last['ax']):<4} {yes(last['postPreflight']):<5} {yes(last['listenPreflight']):<7} "
          f"{yes(last['activeTap']):<10} {yes(last['listenOnlyTapNow']):<14} "
          f"{keys}/{rows[name]['typed']:<9} {echoes}/{posted}")
PY
}

# --- guest: the phases, inside the VM only ------------------------------------------------------------------------
guest() {
  # Refuse anywhere but inside a virtual machine, before parsing arguments and before any side effect: this mode
  # resets and writes TCC, uses sudo, starts the probe and posts key events (QA-R13).
  [ "$(sysctl -n kern.hv_vmm_present 2>/dev/null || echo 0)" = 1 ] || {
    echo "refusing: not inside a virtual machine" >&2
    exit 3
  }
  local out="" bundle="" typer="" grant="" keys=10
  while [ $# -gt 0 ]; do
    case "$1" in
      --out | --bundle | --typer | --grant | --keys)
        [ $# -ge 2 ] || { usage >&2; exit 2; }
        case "$1" in
          --out) out="$2" ;;
          --bundle) bundle="$2" ;;
          --typer) typer="$2" ;;
          --grant) grant="$2" ;;
          --keys) keys="$2" ;;
        esac
        shift 2
        ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  [ -n "$out" ] && [ -f "$bundle/Contents/Info.plist" ] && [ -x "$typer" ] && [ -f "$grant" ] || { usage >&2; exit 2; }
  case "$keys" in '' | *[!0-9]*) usage >&2; exit 2 ;; esac
  [ "$keys" -ge 1 ] && [ "$keys" -le 50 ] || { usage >&2; exit 2; }
  local settle="${TAP_PERMISSION_SETTLE:-4}" drain="${TAP_PERMISSION_DRAIN:-3}"
  case "$settle$drain" in '' | *[!0-9]*) usage >&2; exit 2 ;; esac

  mkdir -p "$out"
  local log="$out/probe.jsonl" summary="$out/guest-summary.txt" identifier apps app agent agent_pid
  : >"$log"
  : >"$summary"
  note() { echo "$*" | tee -a "$summary"; }
  {
    sw_vers || true
    csrutil status || true
  } >"$out/system.txt" 2>&1
  note "macOS $(sw_vers -productVersion), $(csrutil status 2>&1 | sed 's/.*: //')"
  identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist")"

  # The probe runs from ~/Applications, started by LaunchServices, so TCC records the bundle (PLT-R710 spirit).
  apps="$HOME/Applications"
  app="$apps/$(basename "$bundle")"
  mkdir -p "$apps"
  rm -rf "$app"
  cp -R "$bundle" "$app"
  tccutil reset All "$identifier" >"$out/tccutil.log" 2>&1 || note "warning: tccutil reset All failed (tccutil.log)"

  # The guest automation types through the tart guest agent (or the typer itself when TCC attributes it so).
  agent_pid="$(pgrep -n -f tart-guest-agent || true)"
  agent=""
  [ -z "$agent_pid" ] || agent="$(ps -o comm= -p "$agent_pid")"
  local typer_clients=(--binary "$typer")
  if [ -n "$agent" ] && [ -x "$agent" ]; then typer_clients+=(--binary "$agent"); fi
  # shellcheck disable=SC2024 # the log files belong to this user on purpose
  sudo -n bash "$grant" --service kTCCServiceAccessibility --service kTCCServicePostEvent "${typer_clients[@]}" \
    >"$out/grant-typer.log" 2>&1 || { note "STOPPED: the typer could not be granted (grant-typer.log)"; exit 1; }

  start_probe() {
    open -n -g -a "$app" --args probe --out "$log" --seconds 900 >>"$out/open.log" 2>&1 ||
      note "warning: open failed (open.log)"
  }
  # By path: `pkill -x` compares the process name, which macOS cuts to 16 characters.
  stop_probe() {
    pkill -f "$app/Contents/MacOS/$PROBE_NAME" 2>/dev/null || true
    sleep "$drain"
  }

  local entry name change rc=0
  for entry in $PHASES; do
    name="${entry%%:*}"
    change="${entry#*:}"
    printf '{"phase":"%s","typed":%s}\n' "$name" "$keys" >>"$log"
    case "$change" in
      none) start_probe ;;
      relaunch) stop_probe; start_probe ;;
      grant:*)
        # shellcheck disable=SC2024 # the log file belongs to this user on purpose
        sudo -n bash "$grant" --service "${change#grant:}" --bundle "$app" >>"$out/grant-probe.log" 2>&1 ||
          { note "phase $name: the grant failed (grant-probe.log)"; rc=1; }
        ;;
    esac
    sleep "$settle"
    "$typer" type --count "$keys" >>"$out/typer.log" 2>&1 || { note "phase $name: the typer failed (typer.log)"; rc=1; }
    sleep "$drain"
    note "phase $name done"
  done
  stop_probe
  # shellcheck disable=SC2024 # the log file belongs to this user on purpose
  sudo -n /usr/bin/sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
    "SELECT service, client, auth_value FROM access WHERE client = '$identifier' ORDER BY service;" \
    >"$out/tcc-rows.txt" 2>&1 || true
  if [ $rc -eq 0 ]; then note "GUEST RESULT: PASS"; else note "GUEST RESULT: FAIL"; fi
  exit $rc
}

case "${1:-}" in
  guest) shift; guest "$@" ;;
  summarize) shift; summarize "$@"; exit 0 ;;
esac

# --- host -----------------------------------------------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/vm/lib.sh
source "$HERE/lib.sh"

base_vm="$VM_DEV"
keys=10
run_dir=""
memory=""
cpus=""
bad_usage() {
  printf 'tap-permission: %s\n' "$*" >&2
  usage >&2
  exit 2
}
while (($#)); do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --vm | --keys | --output | --memory | --cpus)
      (($# >= 2)) || bad_usage "$1 needs a value"
      case "$1" in
        --vm) base_vm="$2" ;;
        --keys) keys="$2" ;;
        --output) run_dir="$2" ;;
        --memory) memory="$2" ;;
        --cpus) cpus="$2" ;;
      esac
      shift 2
      ;;
    *) bad_usage "unknown option: $1" ;;
  esac
done
lab_validate_name "$base_vm" || exit
lab_validate_int "--keys" "$keys" 1 50 || exit
memory="${memory:-$(lab_default_memory "$base_vm")}"
cpus="${cpus:-$(lab_default_cpus "$base_vm")}"
lab_validate_int "memory (MB)" "$memory" 1024 "$VM_LAB_MAX_MEMORY_MB" || exit
lab_validate_int "CPU count" "$cpus" 1 "$VM_LAB_MAX_CPUS" || exit
require_cmd python3 tar swiftc codesign

# The maintainer's rule (vm-test-lab.md section 10): Safari open on the host means the Mac is in use, and a VM
# would take its CPU. Checked before every boot.
if pgrep -x Safari >/dev/null 2>&1; then
  lab_err "Safari is open on the host: the Mac is in use, no VM is booted now (try again later)"
  exit 3
fi

# Build, bundle and sign the probe before any VM starts, so a compile error never costs a boot. tart runs arm64
# guests only on Apple silicon; macOS 12.0 is the oldest system the app supports (ADR 0315).
stage="$(mktemp -d)"
tap="$stage/tap"
bundle="$tap/$APP_BUNDLE_NAME.app"
mkdir -p "$bundle/Contents/MacOS"
if ! swiftc -O -target arm64-apple-macos12.0 -o "$bundle/Contents/MacOS/$PROBE_NAME" \
  "$HERE/guest/tap-permission-probe.swift" >"$stage/build.log" 2>&1; then
  cat "$stage/build.log" >&2
  rm -rf "$stage"
  lab_err "could not build $PROBE_NAME on the host"
  exit 1
fi
cat >"$bundle/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$APP_BUNDLE_ID_DEV.tapprobe</string>
  <key>CFBundleExecutable</key><string>$PROBE_NAME</string>
  <key>CFBundleName</key><string>$APP_BUNDLE_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
cp "$bundle/Contents/MacOS/$PROBE_NAME" "$tap/tap-typer"
if ! codesign --force --sign - "$bundle" >"$stage/sign.log" 2>&1 ||
  ! codesign --force --sign - "$tap/tap-typer" >>"$stage/sign.log" 2>&1; then
  cat "$stage/sign.log" >&2
  rm -rf "$stage"
  lab_err "could not sign the probe (ad hoc) on the host"
  exit 1
fi
cp "$HERE/grant-tcc.sh" "${BASH_SOURCE[0]}" "$tap/"
rm -f "$stage/build.log" "$stage/sign.log"

drop_stage_and_exit() {
  local rc=$?
  rm -rf "$stage"
  exit "$rc"
}
lab_prepare_target "$base_vm" 0 tap || drop_stage_and_exit
vm="$LAB_TARGET"

run_dir="${run_dir:-$VM_LAB_RUNS/$(date -u +%Y%m%dT%H%M%SZ)-tap-permission}"
mkdir -p "$run_dir"
run_dir="$(cd "$run_dir" && pwd)"
exec 2> >(tee -a "$run_dir/tap-permission.log" >&2)

lab_install_trap
lab_start_target "$base_vm" "$vm" "$memory" "$cpus" || drop_stage_and_exit
# Captured before the test: `grep -q` in a pipeline can end ssh with SIGPIPE, which pipefail reads as a failure.
sip="$(lab_ssh "$vm" 'csrutil status' 2>/dev/null || true)"
if [[ "$sip" != *disabled* ]]; then
  rm -rf "$stage"
  lab_err "SIP is enabled in $vm: grant-tcc.sh cannot write TCC there (use $VM_DEV, vm-test-lab.md section 9)"
  exit 3
fi
lab_push "$vm" "$tap" inbox || {
  rm -rf "$stage"
  lab_err "could not copy the probe into $vm"
  exit 1
}
rm -rf "$stage"
rc=0
lab_wait_agent "$vm" || rc=$?
lab_log "running the phases in $vm (about two minutes)"
# shellcheck disable=SC2016 # expanded by the guest's shell
((rc != 0)) || lab_tart exec "$vm" /bin/bash -c 'cd "$HOME/inbox/tap" && bash ./tap-permission.sh guest --out "$HOME/tap-out" --bundle "$PWD/'"$APP_BUNDLE_NAME"'.app" --typer "$PWD/tap-typer" --grant "$PWD/grant-tcc.sh" --keys '"$keys" \
  >"$run_dir/guest.log" 2>&1 || rc=$?
lab_pull "$vm" tap-out "$run_dir" || {
  lab_log "warning: could not copy the guest logs back"
  rc=1
}
if [[ -f "$run_dir/tap-out/probe.jsonl" ]]; then
  bash "${BASH_SOURCE[0]}" summarize --input "$run_dir/tap-out/probe.jsonl" | tee "$run_dir/summary.txt"
fi
cat "$run_dir/tap-out/guest-summary.txt" 2>/dev/null || tail -n 20 "$run_dir/guest.log" 2>/dev/null || true
if ((rc == 0)); then
  printf 'RESULT: PASS (run folder: %s)\n' "$run_dir"
  exit 0
fi
printf 'RESULT: FAIL (run folder: %s)\n' "$run_dir"
exit 1
