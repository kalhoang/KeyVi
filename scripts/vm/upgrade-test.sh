#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Release candidate checks of docs/runbooks/release.md section 5 items 2 and 3 and the network egress test of the
# pre-flight checklist, in one command: the upgrade test (QA-R40, PLT-R1108, spec/02-platform.md 13.5), the channel
# switch (beta to stable and back) and the egress test (spec/02-platform.md 13.7), on the notarized artefacts of the
# previous stable and the candidate, inside a throwaway clone of the macOS + Xcode tart VM (VM_DEV,
# docs/runbooks/vm-test-lab.md section 12).
#
# On the host this script only reads the artefacts, writes the run folder and starts the VM: nothing is launched,
# no event is posted, no TCC, network or /etc/hosts change is made on the host. The guest half
# (scripts/vm/guest/upgrade-guest.sh) does all of that inside the VM, and scripts/vm/upgrade-report.py turns the
# evidence into result.json (machine-readable) and summary.txt in VM_LAB_RUNS/<UTC timestamp>-upgrade/.
#
# The apps under test are never modified or re-signed. The release build accepts only its Info.plist feed
# (https://<site host>/appcast.xml), so the guest maps the site host to loopback in the VM's /etc/hosts and serves
# the run's appcast there over HTTPS with a certificate only the VM trusts. The candidate's EdDSA signature comes
# from the published appcast when it lists the same bytes (checked with openssl against SUPublicEDKey), otherwise
# from Sparkle's sign_update with --sign (the key in the login keychain; the script never reads it).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/vm/upgrade-test.sh --previous DIR --candidate DIR [options]

  --previous DIR       dist folder of the previous stable (DMG, the .app, SHA256SUMS, build-info.json)
  --candidate DIR      dist folder of the release candidate (.app, update zip, SHA256SUMS, build-info.json)
  --vm NAME            base VM (default VM_DEV, <slug>-dev); the test runs in the throwaway clone NAME-upgrade
  --output DIR         run folder (default VM_LAB_RUNS/<UTC timestamp>-upgrade)
  --memory MB, --cpus N  VM size (default 4096 MB, 4 CPUs)
  --egress-minutes N   length of each egress phase (default 10, spec/02-platform.md 13.7)
  --no-channel         skip the channel switch check (release.md section 5 item 3)
  --no-egress          skip the egress test
  --appcast FILE       published appcast to find the candidate's signature in (default site/static/appcast.xml)
  --sign               sign an unpublished candidate's zip with Sparkle's sign_update (SPARKLE_SIGN_UPDATE or the
                       copy scripts/publish-release keeps); without it such a candidate stops with exit 6
  --wait-idle MIN      wait up to MIN minutes for an idle host before the VM boots (default 240; 0 = check once)
  --watchdog DIR       run DIR/watchdog.sh beside the VM (default VM_LAB_ROOT/kv-ops when it exists)
  --no-watchdog        no watchdog
  -h, --help           this help

Exit status: 0 PASS, 1 FAIL or incomplete, 2 usage error, 3 refused by a safety rule, 4 the host never became idle,
5 the watchdog stopped the VM (retry later), 6 an artefact problem or no signature for an unpublished candidate.
EOF
}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/vm/lib.sh
source "$HERE/lib.sh"

# Host idle thresholds before a VM boots (the lab's resource rule, vm-test-lab.md section 3).
IDLE_LOAD_MAX="${IDLE_LOAD_MAX:-5}"
IDLE_PRESSURE_MAX="${IDLE_PRESSURE_MAX:-4}"
IDLE_FREE_MIN="${IDLE_FREE_MIN:-45}"
IDLE_POLL="${IDLE_POLL:-120}"
SIGN_TIMEOUT="${SIGN_TIMEOUT:-60}"

base_vm="$VM_DEV"
previous=""
candidate=""
run_dir=""
memory=4096
cpus=4
egress_minutes=10
run_channel=1
run_egress=1
sign=0
wait_minutes=240
watchdog_dir="${VM_LAB_WATCHDOG_DIR:-$VM_LAB_ROOT/kv-ops}"
appcast="$REPO_ROOT/site/static/appcast.xml"
bad_usage() {
  printf 'upgrade-test: %s\n' "$*" >&2
  usage >&2
  exit 2
}
while (($#)); do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --previous | --candidate | --vm | --output | --memory | --cpus | --egress-minutes | --wait-idle | --watchdog | \
      --appcast)
      (($# >= 2)) || bad_usage "$1 needs a value"
      case "$1" in
        --previous) previous="$2" ;;
        --candidate) candidate="$2" ;;
        --vm) base_vm="$2" ;;
        --output) run_dir="$2" ;;
        --memory) memory="$2" ;;
        --cpus) cpus="$2" ;;
        --egress-minutes) egress_minutes="$2" ;;
        --wait-idle) wait_minutes="$2" ;;
        --watchdog) watchdog_dir="$2" ;;
        --appcast) appcast="$2" ;;
      esac
      shift 2
      ;;
    --no-channel) run_channel=0; shift ;;
    --no-egress) run_egress=0; shift ;;
    --no-watchdog) watchdog_dir=""; shift ;;
    --sign) sign=1; shift ;;
    *) bad_usage "unknown option: $1" ;;
  esac
done

[[ -n "$previous" && -n "$candidate" ]] || bad_usage "--previous and --candidate are required"
[[ -d "$previous" ]] || bad_usage "no such folder: $previous"
[[ -d "$candidate" ]] || bad_usage "no such folder: $candidate"
[[ -f "$appcast" ]] || bad_usage "no such appcast: $appcast"
lab_validate_name "$base_vm" || exit
lab_validate_int "memory (MB)" "$memory" 1024 "$VM_LAB_MAX_MEMORY_MB" || exit
lab_validate_int "CPU count" "$cpus" 1 "$VM_LAB_MAX_CPUS" || exit
lab_validate_int "egress minutes" "$egress_minutes" 1 60 || exit
lab_validate_int "idle wait (minutes)" "$wait_minutes" 0 1440 || exit
require_cmd git tar python3 shasum
previous="$(cd "$previous" && pwd)"
candidate="$(cd "$candidate" && pwd)"

run_dir="${run_dir:-$VM_LAB_RUNS/$(date -u +%Y%m%dT%H%M%SZ)-upgrade}"
mkdir -p "$run_dir"
run_dir="$(cd "$run_dir" && pwd)"
exec 2> >(tee -a "$run_dir/upgrade.log" >&2)
report() { python3 -I "$HERE/upgrade-report.py" "$@"; }

# Writes result.json for a run that ended before the analysis (no VM, or no evidence), then exits.
early_result() { # early_result <exit code> <verdict> <reason>
  python3 -I - "$run_dir/result.json" "$2" "$3" <<'PY'
import json, sys
json.dump({"schema": 1, "tool": "scripts/vm/upgrade-test.sh", "verdict": sys.argv[2], "reason": sys.argv[3],
           "checks": []}, open(sys.argv[1], "w", encoding="utf-8"), indent=2)
PY
  printf 'RESULT: %s (%s; logs: %s)\n' "$2" "$3" "$run_dir"
  exit "$1"
}

# --- 1. Artefacts and the candidate's signature (host only, no VM) ---------------------------------------------
openssl_bin() { # an OpenSSL with Ed25519 pkeyutl -rawin (LibreSSL of macOS has none)
  local candidate_bin
  for candidate_bin in "${OPENSSL:-}" /opt/homebrew/opt/openssl@3/bin/openssl /opt/homebrew/bin/openssl \
    /usr/local/opt/openssl@3/bin/openssl openssl; do
    [[ -n "$candidate_bin" ]] || continue
    if "$candidate_bin" version 2>/dev/null | grep -q '^OpenSSL [3-9]'; then
      printf '%s\n' "$candidate_bin"
      return 0
    fi
  done
  return 1
}
sign_update_bin() {
  local path found=""
  if [[ -n "${SPARKLE_SIGN_UPDATE:-}" ]]; then
    printf '%s\n' "$SPARKLE_SIGN_UPDATE"
    return 0
  fi
  # The pinned copy scripts/publish-release downloads (newest version last in glob order).
  for path in "$HOME/Library/Caches/$APP_SLUG-release-tools"/sparkle-*/bin/sign_update; do
    [[ -x "$path" ]] && found="$path"
  done
  [[ -n "$found" ]] && printf '%s\n' "$found"
}
# Signs the candidate's zip as scripts/publish-release does. A keychain prompt would block: the call gets
# SIGN_TIMEOUT seconds, then the path stops and is reported instead of worked around.
sign_candidate() { # prints the EdDSA signature
  local tool zip line signature
  tool="$(sign_update_bin)" || true
  [[ -n "$tool" && -x "$tool" ]] || { lab_err "sign_update not found (set SPARKLE_SIGN_UPDATE)"; return 1; }
  zip="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["candidate"]["zip"]["path"])' \
    "$run_dir/artefacts.json")"
  line="$(perl -e 'alarm shift; exec @ARGV' "$SIGN_TIMEOUT" "$tool" "$zip" </dev/null 2>>"$run_dir/upgrade.log")" || {
    lab_err "sign_update failed or did not finish within ${SIGN_TIMEOUT}s (a keychain prompt?); not worked around"
    return 1
  }
  signature="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$line")"
  [[ -n "$signature" ]] || { lab_err "sign_update printed no signature"; return 1; }
  printf '%s\n' "$signature"
}

openssl="$(openssl_bin)" || early_result 6 ERROR "no OpenSSL 3 for the Ed25519 check (set OPENSSL)"
rc=0
report artefacts --previous "$previous" --candidate "$candidate" --slug "$APP_SLUG" --name "$APP_DISPLAY_NAME" \
  --appcast "$appcast" --openssl "$openssl" --out "$run_dir/artefacts.json" || rc=$?
if ((rc == 6)); then
  ((sign)) || early_result 6 ERROR "the candidate is not in the published appcast; rerun with --sign"
  signature="$(sign_candidate)" || early_result 6 ERROR "signing the candidate failed (see upgrade.log)"
  rc=0
  report artefacts --previous "$previous" --candidate "$candidate" --slug "$APP_SLUG" --name "$APP_DISPLAY_NAME" \
    --appcast "$appcast" --openssl "$openssl" --signature "$signature" \
    --out "$run_dir/artefacts.json" || rc=$?
fi
((rc == 0)) || early_result 6 ERROR "artefact check failed: $(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("error",""))' "$run_dir/artefacts.json" 2>/dev/null)"

field() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d[sys.argv[2]][sys.argv[3]])' \
  "$run_dir/artefacts.json" "$1" "$2"; }
prev_version="$(field previous version)"
prev_build="$(field previous build)"
prev_commit="$(field previous commit)"
cand_version="$(field candidate version)"
cand_build="$(field candidate build)"
[[ "$prev_commit" =~ ^[0-9a-f]{7,40}$ ]] || early_result 6 ERROR "the previous build-info.json has no commit"
git -C "$REPO_ROOT" cat-file -e "$prev_commit^{commit}" 2>/dev/null ||
  early_result 6 ERROR "the previous stable's commit $prev_commit is not in this repository"

# --- 2. The run's inputs: feed, previous DMG, previous AppCore, parameters ------------------------------------------
in_dir="$run_dir/in"
rm -rf "$in_dir"
mkdir -p "$in_dir/feed" "$in_dir/prev-src"
probe_line="$(report feed --artefacts "$run_dir/artefacts.json" --out "$in_dir/feed" --name "$APP_DISPLAY_NAME" \
  --site-host "$APP_SITE_HOST" --release-notes "$REPO_ROOT/site/static/release-notes" --plan "$run_dir/feed.json")"
probe_build="${probe_line#PROBE_BUILD=}"
cp "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["previous"]["dmg"]["path"])' \
  "$run_dir/artefacts.json")" "$in_dir/previous.dmg"
git -C "$REPO_ROOT" archive --format=tar "$prev_commit" Packages/AppCore Packages/VietnameseEngine |
  tar -C "$in_dir/prev-src" -xf -
seed_channel=stable
[[ "$cand_version" == *-beta.* ]] && seed_channel=beta
cat >"$in_dir/params.env" <<EOF
PREV_VERSION=$prev_version
PREV_BUILD=$prev_build
CAND_VERSION=$cand_version
CAND_BUILD=$cand_build
PROBE_BUILD=$probe_build
SEED_CHANNEL=$seed_channel
EGRESS_MINUTES=$egress_minutes
RUN_CHANNEL=$run_channel
RUN_EGRESS=$run_egress
EOF
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no)" ]]; then
  lab_log "warning: uncommitted changes are not copied (git archive HEAD)"
fi
lab_log "upgrade $prev_version ($prev_build) -> $cand_version ($cand_build); run folder $run_dir"

# --- 3. An idle host, then the VM with the watchdog beside it ---------------------------------------------------
IDLE_LINE=""
host_idle() {
  local load1 level free vms xcode
  load1="$(sysctl -n vm.loadavg | awk '{ print $2 }')"
  level="$(sysctl -n kern.memorystatus_vm_pressure_level)"
  free="$(memory_pressure -Q | awk -F': ' '/percentage/ { gsub("%", "", $2); print $2 + 0 }')"
  vms="$(lab_running_vms | grep -c . || true)"
  if pgrep -x xcodebuild >/dev/null 2>&1; then xcode=1; else xcode=0; fi
  IDLE_LINE="load1=$load1 pressure=$level free=$free% runningVMs=$vms xcodebuild=$xcode"
  awk -v l="$load1" -v max="$IDLE_LOAD_MAX" 'BEGIN { exit !(l < max) }' && ((level < IDLE_PRESSURE_MAX)) &&
    ((free >= IDLE_FREE_MIN)) && ((vms == 0)) && ((xcode == 0))
}
wait_for_idle() {
  local deadline=$((SECONDS + wait_minutes * 60))
  until host_idle; do
    lab_log "host busy ($IDLE_LINE); next check in ${IDLE_POLL}s"
    ((SECONDS + IDLE_POLL <= deadline)) || return 1
    sleep "$IDLE_POLL"
  done
  lab_log "host idle ($IDLE_LINE)"
}
wait_for_idle || early_result 4 SKIPPED "the host was not idle within $wait_minutes minutes ($IDLE_LINE)"

WATCHDOG_PID=""
WATCHDOG_LINES=0
# Runs watchdog.sh as run-lab.sh does (watchdog.stop removed, the script in the background, watchdog.stop touched at
# the end) and starts it again if it ends while this run's VM still runs: every lab script shares the stop file, and
# on 2026-11-23 another one touched it two seconds after this run's watchdog started, which left the VM unguarded.
watchdog_keeper() {
  local pid
  while [[ ! -e "$run_dir/.watchdog-done" ]]; do
    rm -f "$watchdog_dir/watchdog.stop"
    "$watchdog_dir/watchdog.sh" >>"$watchdog_dir/watchdog.log" 2>&1 &
    pid=$!
    wait "$pid" 2>/dev/null || true
    [[ -e "$run_dir/.watchdog-done" ]] && break
    printf '%s watchdog.sh ended while the VM ran; started again\n' "$(date '+%F %T')" >>"$run_dir/watchdog-restarts.txt"
    sleep 1
  done
}
start_watchdog() {
  if [[ -z "$watchdog_dir" || ! -x "$watchdog_dir/watchdog.sh" ]]; then
    lab_log "warning: no watchdog (--watchdog DIR with watchdog.sh); the VM runs without one"
    return 0
  fi
  rm -f "$run_dir/.watchdog-done"
  WATCHDOG_LINES="$(wc -l <"$watchdog_dir/watchdog.log" 2>/dev/null | tr -d ' ' || echo 0)"
  watchdog_keeper &
  WATCHDOG_PID=$!
  printf '%s\n' "$watchdog_dir/watchdog.sh" >"$run_dir/watchdog-used.txt"
  lab_log "watchdog $watchdog_dir/watchdog.sh running beside the VM"
}
# shellcheck disable=SC2329 # called from upgrade_cleanup, the EXIT trap
stop_watchdog() {
  [[ -n "$WATCHDOG_PID" ]] || return 0
  touch "$run_dir/.watchdog-done" "$watchdog_dir/watchdog.stop"
  wait "$WATCHDOG_PID" 2>/dev/null || true
  rm -f "$run_dir/.watchdog-done"
  WATCHDOG_PID=""
}
watchdog_stops() { # the watchdog's stop lines of this run
  [[ -n "$watchdog_dir" && -f "$watchdog_dir/watchdog.log" ]] || return 0
  tail -n +"$((WATCHDOG_LINES + 1))" "$watchdog_dir/watchdog.log" | grep ': stop ' || true
}
# Stops the VM, deletes the clone, then stops the watchdog (it guards the VM until the VM is down).
# shellcheck disable=SC2329 # the EXIT trap
upgrade_cleanup() {
  local rc=$? vm_name
  trap - EXIT INT TERM HUP
  for vm_name in $VM_LAB_OWNED; do
    lab_down "$vm_name" || lab_err "could not stop $vm_name; stop it with scripts/vm/lab.sh down $vm_name"
  done
  for vm_name in $VM_LAB_CLONES; do lab_delete "$vm_name" || true; done
  stop_watchdog
  exit "$rc"
}

lab_prepare_target "$base_vm" 0 upgrade || exit
vm="$LAB_TARGET"
trap upgrade_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
start_watchdog
lab_start_target "$base_vm" "$vm" "$memory" "$cpus" || exit
lab_log "copying the checkout ($(git -C "$REPO_ROOT" rev-parse --short HEAD)) and the run's inputs into $vm"
git -C "$REPO_ROOT" archive --format=tar HEAD | lab_ssh "$vm" "rm -rf src && mkdir -p src && tar -C src -xf -" || {
  lab_err "could not copy the checkout into $vm"
  exit 1
}
lab_ssh "$vm" "rm -rf upgrade upgrade-out" || exit 1
lab_push "$vm" "$in_dir" upgrade || { lab_err "could not copy the inputs into $vm"; exit 1; }
lab_log "running the upgrade test in $vm (about 45 to 60 minutes with the egress test)"
guest_rc=0
lab_wait_agent "$vm" || guest_rc=$?
# shellcheck disable=SC2016 # expanded by the guest's shell
((guest_rc != 0)) || lab_tart exec "$vm" /bin/bash -c \
  'cd "$HOME/src" && bash scripts/vm/guest/upgrade-guest.sh --in "$HOME/upgrade/in" --out "$HOME/upgrade-out"' \
  >"$run_dir/guest.log" 2>&1 || guest_rc=$?
lab_pull "$vm" upgrade-out "$run_dir" || lab_log "warning: could not copy the guest's evidence back"
watchdog_stops >"$run_dir/watchdog-stops.txt"
[[ -s "$run_dir/watchdog-stops.txt" ]] && lab_log "the watchdog stopped the VM: $(head -n 1 "$run_dir/watchdog-stops.txt")"
lab_log "guest exit $guest_rc"

# --- 4. Verdict ---------------------------------------------------------------------------------------------------
analyse_args=(--run "$run_dir" --artefacts "$run_dir/artefacts.json" --feed "$run_dir/feed.json"
  --brand-env "${BRAND_ENV:-$REPO_ROOT/scripts/brand.env}" --out "$run_dir/result.json"
  --summary "$run_dir/summary.txt" --watchdog-log "$run_dir/watchdog-stops.txt" --egress-minutes "$egress_minutes")
((run_channel)) || analyse_args+=(--no-channel)
((run_egress)) || analyse_args+=(--no-egress)
verdict_rc=0
report analyse "${analyse_args[@]}" || verdict_rc=$?
printf 'logs: %s\n' "$run_dir"
exit "$verdict_rc"
