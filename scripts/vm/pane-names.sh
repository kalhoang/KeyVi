#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Pane-name check of App/Resources/SystemPanes.json (PLT-R704, PRD-R64, ADR 0315; docs/runbooks/vm-test-lab.md
# section 10). In a throwaway clone of a lab VM and for each language (English, then Vietnamese), the guest opens
# every deep link of the table entry for its macOS version plus a few probe links, reads the window that opened
# through the Accessibility API and takes a screenshot of it, and reads the menus of System Settings (System
# Preferences on macOS 12) and of Terminal (PLT-R398C quotes Terminal's Secure Keyboard Entry item).
#
# The language is switched in the guest only (AppleLanguages and AppleLocale of the guest user, then a reboot of
# the clone). The host boots, copies and reads; it never opens a URL, changes a setting or grants anything.
# Where the guest's SIP is disabled (VM_DEV), the guest grants Accessibility and Screen Recording to the SSH
# session with scripts/vm/grant-tcc.sh; with SIP enabled (VM_MONTEREY) the grants must already be in the image
# (vm-test-lab.md section 10). The Accessibility reader (guest/ax-dump.swift) is compiled here on the host, never
# run here, and pushed as a binary: the macOS 12 lab image has no command line tools (guest/smoke-guest.sh).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/vm/pane-names.sh --vm NAME [options]

  --vm NAME              base VM (VM_MONTEREY or VM_DEV); the check runs in the throwaway clone NAME-panes
  --languages LIST       comma-separated guest languages, each en or vi (default en,vi)
  --output DIR           run folder (default VM_LAB_RUNS/<UTC timestamp>-panes-NAME)
  --memory MB, --cpus N  VM size (default per VM, vm-test-lab.md section 3)
  -h, --help             this help

The run folder gets links.tsv, pane-names.log and one folder per language (system.txt, summary.txt, one
<link>.ax.txt and <link>.png per link, settings-menus.ax.txt, terminal-menus.ax.txt, terminal-menu.png).
Exit status: 0 every link was read in every language, 1 otherwise, 2 usage error, 3 refused by a safety rule
(Safari is open on the host, another VM runs, a VM with the clone name exists that the lab did not create).
EOF
}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/vm/lib.sh
source "$HERE/lib.sh"

base_vm=""
languages="en,vi"
run_dir=""
memory=""
cpus=""
bad_usage() {
  printf 'pane-names: %s\n' "$*" >&2
  usage >&2
  exit 2
}
while (($#)); do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --vm | --languages | --output | --memory | --cpus)
      (($# >= 2)) || bad_usage "$1 needs a value"
      case "$1" in
        --vm) base_vm="$2" ;;
        --languages) languages="$2" ;;
        --output) run_dir="$2" ;;
        --memory) memory="$2" ;;
        --cpus) cpus="$2" ;;
      esac
      shift 2
      ;;
    *) bad_usage "unknown option: $1" ;;
  esac
done
[[ -n "$base_vm" ]] || bad_usage "--vm is required"
[[ "$languages" =~ ^(en|vi)(,(en|vi))*$ ]] || bad_usage "--languages takes en and vi, comma separated"
lab_validate_name "$base_vm" || exit
memory="${memory:-$(lab_default_memory "$base_vm")}"
cpus="${cpus:-$(lab_default_cpus "$base_vm")}"
lab_validate_int "memory (MB)" "$memory" 1024 "$VM_LAB_MAX_MEMORY_MB" || exit
lab_validate_int "CPU count" "$cpus" 1 "$VM_LAB_MAX_CPUS" || exit
require_cmd python3 tar swiftc
# tart runs arm64 guests only on Apple silicon; macOS 12.0 is the oldest system the app supports (ADR 0315).
AX_DUMP_TARGET="arm64-apple-macos12.0"

# The maintainer's rule (vm-test-lab.md section 10): Safari open on the host means the Mac is in use, and a VM
# would take its CPU. Checked before every boot.
refuse_if_safari() {
  if pgrep -x Safari >/dev/null 2>&1; then
    lab_err "Safari is open on the host: the Mac is in use, no VM is booted now (try again later)"
    exit 3
  fi
}
refuse_if_safari

# Build the reader before any VM starts, so a compile error never costs a boot.
stage="$(mktemp -d)"
mkdir "$stage/panes"
if ! swiftc -O -target "$AX_DUMP_TARGET" -o "$stage/panes/ax-dump" "$HERE/guest/ax-dump.swift" >"$stage/build.log" 2>&1; then
  cat "$stage/build.log" >&2
  rm -rf "$stage"
  lab_err "could not build ax-dump for $AX_DUMP_TARGET on the host"
  exit 1
fi
rm -f "$stage/build.log"

drop_stage_and_exit() {
  local rc=$?
  rm -rf "$stage"
  exit "$rc"
}
lab_prepare_target "$base_vm" 0 panes || drop_stage_and_exit
vm="$LAB_TARGET"

run_dir="${run_dir:-$VM_LAB_RUNS/$(date -u +%Y%m%dT%H%M%SZ)-panes-$base_vm}"
mkdir -p "$run_dir"
run_dir="$(cd "$run_dir" && pwd)"
exec 2> >(tee -a "$run_dir/pane-names.log" >&2)

# links_for <macOS version>: the deep links of the SystemPanes.json entry that SystemPaneTable picks for that
# version (the range that contains it, else the nearest older one, else the first), then the probe links that
# show the remaining names (Privacy tab and Text tab on macOS 12, Privacy & Security and General from macOS 13).
links_for() {
  python3 -I - "$REPO_ROOT/App/Resources/SystemPanes.json" "$1" <<'PY'
import json, sys

def version(text):
    parts = [int(p) for p in text.split(".")[:3]]
    return tuple(parts + [0] * (3 - len(parts)))

table = json.load(open(sys.argv[1], encoding="utf-8"))
target = version(sys.argv[2])
entries = table["entries"]
def contains(entry):
    low = version(entry["macOS"]["min"])
    high = entry["macOS"].get("max")
    return low <= target and (high is None or target <= version(high))
match = next((e for e in entries if contains(e)), None)
if match is None:
    older = [e for e in entries if e["macOS"].get("max") and version(e["macOS"]["max"]) < target]
    match = max(older, key=lambda e: version(e["macOS"]["max"])) if older else entries[0]
for pane, url in match["deepLinks"].items():
    print(f"{pane}\t{url}")
if target < (13, 0, 0):
    print("probe.privacy\tx-apple.systempreferences:com.apple.preference.security?Privacy")
    print("probe.text\tx-apple.systempreferences:com.apple.preference.keyboard?Text")
else:
    print("probe.privacySecurity\tx-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")
    print("probe.general\tx-apple.systempreferences:com.apple.systempreferences.GeneralSettings")
PY
}

# set_language <en|vi>: the guest user's preferred languages and region, then a reboot of the clone so the login
# session (and every System Settings extension) starts in that language.
set_language() {
  local lang="$1" list locale current
  case "$lang" in
    en) list="en" locale="en_US" ;;
    vi) list="vi en" locale="vi_VN" ;;
  esac
  current="$(lab_ssh "$vm" 'defaults read -g AppleLanguages 2>/dev/null | tr -d " \n"' || true)"
  # shellcheck disable=SC2086 # the language list is two fixed words
  lab_ssh "$vm" "defaults write -g AppleLanguages -array $list && defaults write -g AppleLocale -string $locale" ||
    return 1
  if [[ "$lang" == en && "$current" == '("en'* ]]; then
    lab_log "the guest already starts in English ($current)"
    return 0
  fi
  lab_log "switching the guest to $lang (was $current): rebooting $vm"
  lab_down "$vm" || return 1
  refuse_if_safari
  lab_up "$vm" "$memory" "$cpus"
}

lab_install_trap
lab_start_target "$base_vm" "$vm" "$memory" "$cpus" || drop_stage_and_exit
guest_version="$(lab_ssh "$vm" 'sw_vers -productVersion')"
links_for "$guest_version" >"$run_dir/links.tsv"
lab_log "$vm runs macOS $guest_version; $(wc -l <"$run_dir/links.tsv" | tr -d ' ') links"
cp "$HERE/guest/pane-names-guest.sh" "$HERE/grant-tcc.sh" "$run_dir/links.tsv" "$stage/panes/"
lab_push "$vm" "$stage/panes" inbox || {
  lab_err "could not copy the guest scripts into $vm"
  exit 1
}
rm -rf "$stage"
# shellcheck disable=SC2016 # runs in the guest's shell
if lab_ssh "$vm" 'csrutil status' | grep -q disabled; then
  lab_log "SIP is disabled in $vm: granting Accessibility and Screen Recording to the SSH session"
  lab_ssh "$vm" 'sudo -n bash inbox/panes/grant-tcc.sh --service kTCCServiceAccessibility --service kTCCServiceScreenCapture --binary /usr/libexec/sshd-keygen-wrapper' ||
    lab_log "warning: the grant failed; the Accessibility reads may be refused"
fi

rc=0
IFS=, read -r -a wanted <<<"$languages"
for lang in "${wanted[@]}"; do
  set_language "$lang" || {
    lab_err "could not switch $vm to $lang"
    rc=1
    continue
  }
  lab_log "reading the panes in $lang"
  # shellcheck disable=SC2016 # expanded by the guest's shell
  lab_ssh "$vm" "bash inbox/panes/pane-names-guest.sh --out panes-out/$lang --links inbox/panes/links.tsv --tool inbox/panes/ax-dump" \
    >"$run_dir/guest-$lang.log" 2>&1 || rc=1
  lab_pull "$vm" "panes-out/$lang" "$run_dir" || {
    lab_log "warning: could not copy the $lang results back"
    rc=1
  }
  cat "$run_dir/$lang/summary.txt" 2>/dev/null || tail -n 20 "$run_dir/guest-$lang.log" || true
done
if ((rc == 0)); then
  printf 'RESULT: PASS (run folder: %s)\n' "$run_dir"
  exit 0
fi
printf 'RESULT: FAIL (run folder: %s)\n' "$run_dir"
exit 1
