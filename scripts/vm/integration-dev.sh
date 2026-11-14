#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Runs the QA-R11 TestHost integration suite inside a throwaway clone of the macOS + Xcode tart VM (VM_DEV),
# whose SIP is disabled, so TCC is granted by scripts/vm/grant-tcc.sh instead of by hand
# (docs/runbooks/integration-suite.md section 10, docs/runbooks/vm-test-lab.md).
#
# Copies the committed checkout (git archive HEAD) into the VM, then the guest script builds the test build,
# TestHost and compat-harness, grants them, and runs `scripts/run-integration.sh tests` through the tart guest
# agent (the logged-in GUI session). Nothing runs on the host but git, tar and the VM. Logs go to
# VM_LAB_RUNS/<timestamp>-integration/.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/vm/integration-dev.sh [options]

  --vm NAME            base VM (default VM_DEV, <slug>-dev)
  --in-place           run in the base VM itself instead of a throwaway clone (keeps the builds and grants)
  --output DIR         run folder (default VM_LAB_RUNS/<UTC timestamp>-integration)
  --memory MB, --cpus N  VM size (default 6144 MB, 4 CPUs)
  --only ID[,ID...]    run only these TestHost scenarios (IDs or PREFIX* patterns), for a control run
  --probe              run the AX focus probe on TestHost beside the suite (probe.log, integration-suite.md 10.5)
  -h, --help           this help

Only committed files are copied (git archive HEAD). Exit status: 0 suite passed, 1 failed, 2 usage error,
3 refused by a safety rule (another VM runs, a VM with the clone name exists that the lab did not create).
EOF
}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/vm/lib.sh
source "$HERE/lib.sh"

base_vm="$VM_DEV"
in_place=0
run_dir=""
memory=""
cpus=""
only=""
probe=0
bad_usage() {
  printf 'integration-dev: %s\n' "$*" >&2
  usage >&2
  exit 2
}
while (($#)); do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --vm | --output | --memory | --cpus | --only)
      (($# >= 2)) || bad_usage "$1 needs a value"
      case "$1" in
        --vm) base_vm="$2" ;;
        --output) run_dir="$2" ;;
        --memory) memory="$2" ;;
        --cpus) cpus="$2" ;;
        --only)
          # Words of the harness command line in the guest: scenario IDs and PREFIX* patterns only.
          [[ "$2" =~ ^[A-Za-z0-9_][A-Za-z0-9._*-]*(,[A-Za-z0-9_][A-Za-z0-9._*-]*)*$ ]] ||
            bad_usage "--only takes scenario IDs or PREFIX* patterns, comma separated"
          only="$2"
          ;;
      esac
      shift 2
      ;;
    --in-place) in_place=1; shift ;;
    --probe) probe=1; shift ;;
    *) bad_usage "unknown option: $1" ;;
  esac
done

lab_validate_name "$base_vm" || exit
memory="${memory:-$(lab_default_memory "$base_vm")}"
cpus="${cpus:-$(lab_default_cpus "$base_vm")}"
lab_validate_int "memory (MB)" "$memory" 1024 "$VM_LAB_MAX_MEMORY_MB" || exit
lab_validate_int "CPU count" "$cpus" 1 "$VM_LAB_MAX_CPUS" || exit
require_cmd git tar
lab_prepare_target "$base_vm" "$in_place" suite || exit
vm="$LAB_TARGET"

run_dir="${run_dir:-$VM_LAB_RUNS/$(date -u +%Y%m%dT%H%M%SZ)-integration}"
mkdir -p "$run_dir"
run_dir="$(cd "$run_dir" && pwd)"
exec 2> >(tee -a "$run_dir/integration.log" >&2)
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no)" ]]; then
  lab_log "warning: uncommitted changes are not copied (git archive HEAD)"
fi

lab_install_trap
lab_start_target "$base_vm" "$vm" "$memory" "$cpus" || exit
lab_log "copying the checkout ($(git -C "$REPO_ROOT" rev-parse --short HEAD)) into $vm"
git -C "$REPO_ROOT" archive --format=tar HEAD | lab_ssh "$vm" "rm -rf src && mkdir -p src && tar -C src -xf -" || {
  lab_err "could not copy the checkout into $vm"
  exit 1
}
lab_log "building, granting and running the TestHost suite in $vm (about 20 to 40 minutes)"
rc=0
lab_wait_agent "$vm" || rc=$?
guest_args=()
[[ -z "$only" ]] || guest_args=(--only "$only")
((probe == 0)) || guest_args+=(--probe)
# shellcheck disable=SC2016 # expanded by the guest's shell; the extra arguments arrive as "$@"
((rc != 0)) || lab_tart exec "$vm" /bin/bash -c 'cd "$HOME/src" && bash scripts/vm/guest/integration-guest.sh --out "$HOME/integration-out" "$@"' \
  integration-guest ${guest_args[@]+"${guest_args[@]}"} >"$run_dir/guest.log" 2>&1 || rc=$?
lab_pull "$vm" integration-out "$run_dir" || lab_log "warning: could not copy the guest logs back"
cat "$run_dir/integration-out/summary.txt" 2>/dev/null || tail -n 20 "$run_dir/guest.log" 2>/dev/null || true
if ((rc == 0)); then
  printf 'RESULT: PASS (logs: %s)\n' "$run_dir"
  exit 0
fi
printf 'RESULT: FAIL (logs: %s)\n' "$run_dir"
exit 1
