#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# tart VM test lab on the maintainer's Mac (docs/runbooks/vm-test-lab.md). Runs macOS guests headless for the
# macOS 12 smoke test (ADR 0315, PLT-R106) and the platform integration suite (QA-R10 to QA-R13).
# Inside a VM, synthetic events, TCC changes and app launches are allowed; on the host they never are.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/vm/lab.sh <command> [arguments]

  up <vm> [--memory MB] [--cpus N]   boot headless, wait for the IP and SSH, install the lab key once
                                     (defaults: keyvi-dev* 6144 MB / 4 CPUs, others 4096 MB / 2 CPUs)
  down <vm> [--timeout S]            guest shutdown, then tart stop, then kill tart run
  status                             local VMs, which one runs, disk use
  ip <vm>                            print the VM's IP address
  ssh <vm> [command...]              shell or command in the guest (key login as admin)
  push <vm> <local> <remote-dir>     copy a file or folder into the guest (tar over SSH, keeps signatures)
  pull <vm> <remote> <local-dir>     copy a file or folder out of the guest
  exec <vm> <command...>             run through the tart guest agent (not in vanilla images)
  probe <vm>                         macOS version, architecture, SIP, Xcode and guest agent of a running VM
  clone <source> <name>              throwaway copy (APFS clone); only such clones can be deleted
  delete <name>                      delete a throwaway clone made by `clone`
  with <vm> [--memory MB] [--cpus N] -- <host command...>
                                     boot, run the host command with VM_NAME and VM_IP set, always stop

Only one VM runs at a time. `up` leaves the VM running for interactive work: stop it with `down`.
Exit status: 0 success, 1 failure, 2 usage error, 3 refused by a safety rule (another VM runs, not a clone,
VM not running, keys folder inside ~/.ssh).

Environment: VM_LAB_ROOT (/Volumes/Data/tart), TART_BIN, TART_HOME, VM_LAB_KEYS, VM_SSH_USER,
VM_SSH_PASSWORD, VM_BOOT_TIMEOUT (420), VM_STOP_TIMEOUT (60), VM_LAB_MAX_MEMORY_MB (8192), VM_LAB_MAX_CPUS (6).
EOF
}

# shellcheck source=scripts/vm/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

die_usage() {
  printf 'vm-lab: %s\n' "$*" >&2
  usage >&2
  exit 2
}

need_args() { # need_args <count> <have> <usage line>
  if (($2 < $1)); then die_usage "missing arguments: $3"; fi
}

# parse_size <vm> <args...>: sets SIZE_MEMORY, SIZE_CPUS and REST (arguments after the size options).
parse_size() {
  local vm="$1"
  shift
  SIZE_MEMORY="$(lab_default_memory "$vm")"
  SIZE_CPUS="$(lab_default_cpus "$vm")"
  REST=()
  while (($#)); do
    case "$1" in
      --memory)
        (($# >= 2)) || die_usage "--memory needs a value in MB"
        SIZE_MEMORY="$2"
        shift 2
        ;;
      --cpus)
        (($# >= 2)) || die_usage "--cpus needs a value"
        SIZE_CPUS="$2"
        shift 2
        ;;
      --)
        shift
        REST=("$@")
        return 0
        ;;
      *) die_usage "unknown option: $1" ;;
    esac
  done
}

cmd_up() {
  need_args 1 $# "up <vm>"
  local vm="$1"
  shift
  lab_validate_name "$vm" || exit
  parse_size "$vm" "$@"
  lab_install_trap
  lab_up "$vm" "$SIZE_MEMORY" "$SIZE_CPUS" || exit
  # Interactive use: the VM stays up after this command; stop it with `down`.
  lab_disown "$vm"
  printf '%s %s\n' "$vm" "$LAB_UP_IP"
}

cmd_down() {
  need_args 1 $# "down <vm>"
  local vm="$1"
  shift
  while (($#)); do
    case "$1" in
      --timeout)
        (($# >= 2)) || die_usage "--timeout needs seconds"
        lab_validate_int "timeout" "$2" 1 3600 || exit
        VM_STOP_TIMEOUT="$2"
        shift 2
        ;;
      *) die_usage "unknown option: $1" ;;
    esac
  done
  lab_validate_name "$vm" || exit
  lab_check_paths || exit
  lab_down "$vm" || exit
}

cmd_status() {
  lab_check_paths || exit
  echo "Local VMs (TART_HOME=$TART_HOME):"
  lab_tart list --source local
  local running vm
  running="$(lab_running_vms | tr '\n' ' ')"
  echo
  if [[ -n "${running// /}" ]]; then
    for vm in $running; do
      printf 'running: %s ip %s pid %s\n' "$vm" "$(lab_vm_ip "$vm" || echo '?')" \
        "$(cat "$VM_LAB_STATE/$vm.pid" 2>/dev/null || echo 'not started by the lab')"
    done
  else
    echo "running: none"
  fi
  echo
  if [[ -d "$TART_HOME" ]]; then
    df -h "$TART_HOME" | awk 'NR == 1 || NR == 2'
  fi
}

cmd_ip() {
  need_args 1 $# "ip <vm>"
  lab_require_running "$1" || exit
  echo "$LAB_IP"
}

cmd_ssh() {
  need_args 1 $# "ssh <vm> [command...]"
  local vm="$1"
  shift
  lab_require_running "$vm" || exit
  if (($# == 0)); then
    exec ssh "${LAB_SSH_OPTS[@]}" -o BatchMode=yes -t "$VM_SSH_USER@$LAB_IP"
  fi
  exec ssh "${LAB_SSH_OPTS[@]}" -o BatchMode=yes "$VM_SSH_USER@$LAB_IP" "$@"
}

cmd_push() {
  need_args 3 $# "push <vm> <local> <remote-dir>"
  lab_validate_name "$1" || exit
  lab_push "$1" "$2" "$3" || exit
}

cmd_pull() {
  need_args 3 $# "pull <vm> <remote> <local-dir>"
  lab_validate_name "$1" || exit
  lab_pull "$1" "$2" "$3" || exit
}

cmd_exec() {
  need_args 2 $# "exec <vm> <command...>"
  local vm="$1" rc=0
  shift
  lab_require_running "$vm" || exit
  lab_tart exec "$vm" "$@" || rc=$?
  if ((rc != 0)); then
    lab_err "tart exec failed (status $rc). It needs the tart guest agent, which the Cirrus Labs vanilla images lack; use scripts/vm/lab.sh ssh $vm instead"
    exit "$rc"
  fi
}

cmd_probe() {
  need_args 1 $# "probe <vm>"
  local vm="$1"
  lab_require_running "$vm" || exit
  # shellcheck disable=SC2016 # runs in the guest's shell
  ssh "${LAB_SSH_OPTS[@]}" -o BatchMode=yes "$VM_SSH_USER@$LAB_IP" '
    echo "macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
    echo "arch: $(uname -m)"
    echo "SIP: $(csrutil status 2>&1)"
    if xcode-select -p >/dev/null 2>&1; then echo "developer dir: $(xcode-select -p)"; else echo "developer dir: none"; fi
    if [ -x /usr/bin/xcodebuild ] && xcodebuild -version >/dev/null 2>&1; then echo "Xcode: $(xcodebuild -version | tr "\n" " ")"; else echo "Xcode: none"; fi
    if sudo -n true 2>/dev/null; then echo "passwordless sudo: yes"; else echo "passwordless sudo: no"; fi
    echo "console user: $(stat -f %Su /dev/console)"
    if /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then echo "Rosetta: installed"; else echo "Rosetta: missing"; fi
  ' || exit
  if lab_tart exec "$vm" /usr/bin/true >/dev/null 2>&1; then
    echo "tart guest agent: works (tart exec)"
  else
    echo "tart guest agent: not available"
  fi
}

cmd_clone() {
  need_args 2 $# "clone <source> <name>"
  lab_clone "$1" "$2" || exit
}

cmd_delete() {
  need_args 1 $# "delete <name>"
  lab_delete "$1" || exit
}

cmd_with() {
  need_args 1 $# "with <vm> [--memory MB] [--cpus N] -- <command...>"
  local vm="$1" rc=0
  shift
  lab_validate_name "$vm" || exit
  parse_size "$vm" "$@"
  ((${#REST[@]})) || die_usage "with needs a host command after --"
  lab_install_trap
  lab_up "$vm" "$SIZE_MEMORY" "$SIZE_CPUS" || exit
  # A VM that was already running is not ours to stop.
  if ((LAB_UP_STARTED == 0)); then lab_disown "$vm"; fi
  VM_NAME="$vm" VM_IP="$LAB_UP_IP" "${REST[@]}" || rc=$?
  exit "$rc"
}

(($#)) || die_usage "missing command"
command="$1"
shift
case "$command" in
  -h | --help | help) usage ;;
  up) cmd_up "$@" ;;
  down) cmd_down "$@" ;;
  status) cmd_status ;;
  ip) cmd_ip "$@" ;;
  ssh) cmd_ssh "$@" ;;
  push) cmd_push "$@" ;;
  pull) cmd_pull "$@" ;;
  exec) cmd_exec "$@" ;;
  probe) cmd_probe "$@" ;;
  clone) cmd_clone "$@" ;;
  delete) cmd_delete "$@" ;;
  with) cmd_with "$@" ;;
  *) die_usage "unknown command: $command" ;;
esac
