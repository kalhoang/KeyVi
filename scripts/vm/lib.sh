# shellcheck shell=bash
# shellcheck disable=SC2034 # LAB_UP_IP, LAB_UP_STARTED and LAB_IP are results read by the sourcing scripts
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Helpers for the tart VM test lab (docs/runbooks/vm-test-lab.md). Source it; do not execute it.
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# Everything lives under VM_LAB_ROOT (default /Volumes/Data/tart): the tart binary, TART_HOME, the lab's own
# SSH key pair and known_hosts file, state (pid files, clone markers) and the run logs. The user's ~/.ssh is
# never read or written: every ssh call passes -F /dev/null, its own identity, known_hosts file and no agent.
#
# Safety rules enforced here:
#   - one VM at a time on this host (a second `up` is refused while any local VM runs);
#   - a VM started by a script is stopped when that script exits, also on failure (lab_install_trap);
#   - only clones created by `lab_clone` (marker in VM_LAB_STATE/clones) can be deleted;
#   - VM names, sizes and remote paths are validated before anything runs.
#
# Functions return 0 on success, 1 on failure, 2 on a usage error and 3 when a safety rule refused the action.
# Bash 3.2 compatible (the system bash of macOS).

if [[ -n "${_VM_LAB_SH_LOADED:-}" ]]; then
  return 0
fi
_VM_LAB_SH_LOADED=1

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_brand

# VM names follow the slug of scripts/brand.env (after scripts/rename-app.sh, rename the VMs with `tart rename`):
# VM_MONTEREY is the macOS 12 guest of the smoke test, VM_DEV the macOS 27 + Xcode guest of the integration suite.
VM_MONTEREY="${VM_MONTEREY:-$APP_SLUG-monterey}"
VM_DEV="${VM_DEV:-$APP_SLUG-dev}"

VM_LAB_ROOT="${VM_LAB_ROOT:-/Volumes/Data/tart}"
TART_BIN="${TART_BIN:-$VM_LAB_ROOT/tart.app/Contents/MacOS/tart}"
TART_HOME="${TART_HOME:-$VM_LAB_ROOT/home}"
export TART_HOME
VM_LAB_KEYS="${VM_LAB_KEYS:-$VM_LAB_ROOT/keys}"
VM_LAB_STATE="${VM_LAB_STATE:-$VM_LAB_ROOT/state}"
VM_LAB_RUNS="${VM_LAB_RUNS:-$VM_LAB_ROOT/runs}"
# Cirrus Labs images log in as admin/admin (public default of the images, not a secret of this project).
VM_SSH_USER="${VM_SSH_USER:-admin}"
VM_SSH_PASSWORD="${VM_SSH_PASSWORD:-admin}"
VM_BOOT_TIMEOUT="${VM_BOOT_TIMEOUT:-420}"
VM_STOP_TIMEOUT="${VM_STOP_TIMEOUT:-60}"
VM_LAB_POLL="${VM_LAB_POLL:-2}"
VM_LAB_MAX_MEMORY_MB="${VM_LAB_MAX_MEMORY_MB:-8192}"
VM_LAB_MAX_CPUS="${VM_LAB_MAX_CPUS:-6}"

# VMs this process started and clones it created; lab_cleanup stops and deletes them on exit.
LAB_UP_IP=""
LAB_UP_STARTED=0
VM_LAB_OWNED=""
VM_LAB_CLONES=""
LAB_SSH_OPTS=()

lab_log() { printf '[vm-lab] %s\n' "$*" >&2; }
lab_err() { printf 'vm-lab: error: %s\n' "$*" >&2; }

# lab_err_ret <code> <message>: prints the message and returns the code (use as `lab_err_ret 3 "..."; return`).
lab_err_ret() {
  local code="$1"
  shift
  lab_err "$*"
  return "$code"
}

lab_validate_name() {
  local name="${1:-}"
  if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]]; then
    lab_err_ret 2 "invalid VM name: '$name' (letters, digits, '.', '_' and '-', starting with a letter or digit)"
    return
  fi
}

# lab_validate_int <label> <value> <min> <max>
lab_validate_int() {
  local label="$1" value="${2:-}" min="$3" max="$4"
  if [[ ! "$value" =~ ^[0-9]{1,7}$ ]] || ((value < min || value > max)); then
    lab_err_ret 2 "$label must be a whole number from $min to $max (got '$value')"
    return
  fi
}

# Remote paths are passed to the guest's shell inside single quotes, so quotes, backquotes, dollar signs and
# backslashes are refused instead of escaped.
lab_validate_remote_path() {
  local path="${1:-}"
  if [[ -z "$path" || "$path" == *"'"* || "$path" == *'`'* || "$path" == *'$'* || "$path" == *"\\"* ]]; then
    lab_err_ret 2 "unsafe remote path: '$path' (no quotes, backquotes, '\$' or backslashes)"
    return
  fi
}

# Default size per VM (16 GB host shared with other jobs): VM_DEV and its clones 6144 MB and 4 CPUs,
# everything else (VM_MONTEREY and its clones) 4096 MB and 2 CPUs.
lab_default_memory() {
  case "$1" in
    "$VM_DEV" | "$VM_DEV"-*) echo 6144 ;;
    *) echo 4096 ;;
  esac
}
lab_default_cpus() {
  case "$1" in
    "$VM_DEV" | "$VM_DEV"-*) echo 4 ;;
    *) echo 2 ;;
  esac
}

lab_check_paths() {
  local home_ssh="${HOME:-/nonexistent}/.ssh"
  case "$VM_LAB_KEYS/" in
    "$home_ssh"/*)
      lab_err_ret 3 "VM_LAB_KEYS=$VM_LAB_KEYS is inside $home_ssh: the lab must never use or modify ~/.ssh"
      return
      ;;
  esac
  if [[ ! -x "$TART_BIN" ]]; then
    lab_err_ret 1 "tart not found at $TART_BIN (set TART_BIN; see docs/runbooks/vm-test-lab.md)"
    return
  fi
  mkdir -p "$VM_LAB_STATE/clones" "$VM_LAB_RUNS" || return 1
  if [[ ! -d "$VM_LAB_KEYS" ]]; then
    (umask 077 && mkdir -p "$VM_LAB_KEYS") || return 1
  fi
  chmod 700 "$VM_LAB_KEYS" || return 1
}

# Every tart call goes through here, so TART_HOME is always set.
lab_tart() {
  TART_HOME="$TART_HOME" "$TART_BIN" "$@"
}

# Output is captured before grep: `grep -q` in a pipeline can end the producer with SIGPIPE, which pipefail
# turns into a false "not found".
lab_vm_exists() {
  local names
  names="$(lab_tart list --source local --quiet 2>/dev/null)" || return 1
  grep -qxF -- "$1" <<<"$names"
}

lab_running_vms() {
  lab_tart list --source local 2>/dev/null | awk 'NR > 1 && $NF == "running" { print $2 }'
}

lab_is_running() {
  local running
  running="$(lab_running_vms)"
  grep -qxF -- "$1" <<<"$running"
}

lab_vm_ip() {
  lab_tart ip "$1" 2>/dev/null
}

lab_sleep() { sleep "$VM_LAB_POLL"; }

lab_set_ssh_opts() {
  LAB_SSH_OPTS=(
    -F /dev/null
    -i "$VM_LAB_KEYS/id_ed25519"
    -o IdentitiesOnly=yes
    -o IdentityAgent=none
    -o StrictHostKeyChecking=no
    -o "UserKnownHostsFile=$VM_LAB_KEYS/known_hosts"
    -o GlobalKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=10
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=4
  )
}

lab_ensure_key() {
  local key="$VM_LAB_KEYS/id_ed25519"
  if [[ ! -f "$key" || ! -f "$key.pub" ]]; then
    lab_log "creating the lab SSH key $key"
    ssh-keygen -q -t ed25519 -N '' -C "$APP_SLUG-vm-lab" -f "$key" </dev/null >/dev/null || return 1
  fi
  chmod 600 "$key" || return 1
}

# lab_ssh_probe <ip>: 0 key login works, 10 server answers but refuses the key, 1 no answer.
lab_ssh_probe() {
  local ip="$1" err
  lab_set_ssh_opts
  if err="$(ssh "${LAB_SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=5 "$VM_SSH_USER@$ip" true </dev/null 2>&1 >/dev/null)"; then
    return 0
  fi
  case "$err" in
    *"Permission denied"* | *"Too many authentication failures"*) return 10 ;;
  esac
  return 1
}

# Installs the lab's public key into the guest's ~/.ssh/authorized_keys once, logging in with the password.
# The password reaches ssh only through SSH_ASKPASS (SSH_ASKPASS_REQUIRE=force) and an environment variable:
# it is never written to a file or put on a command line.
lab_install_key() {
  local ip="$1" askpass="$VM_LAB_KEYS/askpass.sh"
  # shellcheck disable=SC2016 # expanded by the askpass helper, not here
  printf '#!/bin/sh\nprintf "%%s\\n" "$VM_LAB_ASKPASS_SECRET"\n' >"$askpass" || return 1
  chmod 700 "$askpass" || return 1
  lab_set_ssh_opts
  lab_log "installing the lab key into $VM_SSH_USER@$ip (one-time password login)"
  # shellcheck disable=SC2016 # runs in the guest's shell
  local remote='umask 077; mkdir -p .ssh; k=$(cat); touch .ssh/authorized_keys; grep -qxF "$k" .ssh/authorized_keys || printf "%s\n" "$k" >> .ssh/authorized_keys'
  if ! DISPLAY="${DISPLAY:-:0}" SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force \
    VM_LAB_ASKPASS_SECRET="$VM_SSH_PASSWORD" \
    ssh "${LAB_SSH_OPTS[@]}" -o BatchMode=no -o PubkeyAuthentication=no \
    -o PreferredAuthentications=keyboard-interactive,password -o NumberOfPasswordPrompts=1 \
    "$VM_SSH_USER@$ip" "$remote" <"$VM_LAB_KEYS/id_ed25519.pub" >/dev/null; then
    lab_err_ret 1 "could not install the lab key with the password login (VM_SSH_USER=$VM_SSH_USER)"
    return
  fi
}

# lab_wait_ssh <ip> <deadline in SECONDS>: waits for sshd, installs the key when needed.
lab_wait_ssh() {
  local ip="$1" deadline="$2" rc
  while :; do
    rc=0
    lab_ssh_probe "$ip" || rc=$?
    case "$rc" in
      0) return 0 ;;
      10)
        lab_install_key "$ip" || return 1
        if lab_ssh_probe "$ip"; then return 0; fi
        lab_err_ret 1 "the lab key was installed but key login still fails on $ip"
        return
        ;;
    esac
    if ((SECONDS >= deadline)); then
      lab_err_ret 1 "no SSH answer from $ip within ${VM_BOOT_TIMEOUT}s"
      return
    fi
    lab_sleep
  done
}

lab_own() { VM_LAB_OWNED="$VM_LAB_OWNED $1"; }
lab_disown() {
  local vm kept=""
  for vm in $VM_LAB_OWNED; do
    [[ "$vm" == "$1" ]] || kept="$kept $vm"
  done
  VM_LAB_OWNED="$kept"
}

lab_lock() {
  local lock="$VM_LAB_STATE/start.lock" holder
  if mkdir "$lock" 2>/dev/null; then
    echo "$$" >"$lock/pid"
    return 0
  fi
  holder="$(cat "$lock/pid" 2>/dev/null || true)"
  if [[ -n "$holder" ]] && ! kill -0 "$holder" 2>/dev/null; then
    rm -rf "$lock"
    if mkdir "$lock" 2>/dev/null; then
      echo "$$" >"$lock/pid"
      return 0
    fi
  fi
  lab_err_ret 3 "another vm-lab command is starting a VM (lock $lock, pid ${holder:-unknown})"
}
lab_unlock() { rm -rf "$VM_LAB_STATE/start.lock"; }

# lab_refuse_if_busy <vm>: 0 when nothing runs, 4 when <vm> itself runs, 3 when another VM runs.
lab_refuse_if_busy() {
  local vm="$1" running
  running="$(lab_running_vms | tr '\n' ' ')"
  running="${running% }"
  if [[ -z "$running" ]]; then
    return 0
  fi
  if [[ " $running " == *" $vm "* ]]; then
    return 4
  fi
  lab_err_ret 3 "refusing to start $vm: $running is running (one VM at a time on this host; stop it with scripts/vm/lab.sh down <vm>)"
}

# lab_up <vm> <memory MB> <cpus>: boots the VM headless, waits for its IP and SSH, installs the key.
# Sets LAB_UP_IP. The VM is recorded as owned while it boots; callers that keep it running call lab_disown.
# When the VM is already running, LAB_UP_STARTED=0 and nothing is changed.
lab_up() {
  local vm="$1" memory="$2" cpus="$3" pid deadline ip rc
  LAB_UP_IP=""
  LAB_UP_STARTED=0
  lab_validate_name "$vm" || return
  lab_validate_int "memory (MB)" "$memory" 1024 "$VM_LAB_MAX_MEMORY_MB" || return
  lab_validate_int "CPU count" "$cpus" 1 "$VM_LAB_MAX_CPUS" || return
  lab_check_paths || return
  if ! lab_vm_exists "$vm"; then
    lab_err_ret 2 "no local VM named $vm (scripts/vm/lab.sh status lists them)"
    return
  fi
  lab_lock || return
  rc=0
  lab_refuse_if_busy "$vm" || rc=$?
  if ((rc == 4)); then
    lab_unlock
    lab_log "$vm is already running; leaving it as it is"
    LAB_UP_IP="$(lab_vm_ip "$vm" || true)"
    return 0
  elif ((rc != 0)); then
    lab_unlock
    return "$rc"
  fi
  lab_ensure_key || {
    lab_unlock
    return 1
  }
  if ! lab_tart set "$vm" --memory "$memory" --cpu "$cpus"; then
    lab_unlock
    lab_err_ret 1 "tart set failed for $vm"
    return
  fi
  lab_log "starting $vm headless ($memory MB, $cpus CPUs), log $VM_LAB_STATE/$vm.log"
  # setsid: tart run keeps running in its own session after this shell exits (`up` without `with`).
  perl -e 'use POSIX qw(setsid); setsid(); exec { $ARGV[0] } @ARGV or die "exec $ARGV[0]: $!\n";' \
    "$TART_BIN" run --no-graphics "$vm" </dev/null >"$VM_LAB_STATE/$vm.log" 2>&1 &
  pid=$!
  echo "$pid" >"$VM_LAB_STATE/$vm.pid"
  lab_own "$vm"
  LAB_UP_STARTED=1
  lab_unlock
  deadline=$((SECONDS + VM_BOOT_TIMEOUT))
  while :; do
    if ! kill -0 "$pid" 2>/dev/null; then
      lab_err_ret 1 "tart run exited while $vm was booting: $(tail -n 5 "$VM_LAB_STATE/$vm.log" | tr '\n' ' ')"
      return
    fi
    ip="$(lab_vm_ip "$vm" || true)"
    [[ -n "$ip" ]] && break
    if ((SECONDS >= deadline)); then
      lab_err_ret 1 "$vm got no IP address within ${VM_BOOT_TIMEOUT}s"
      return
    fi
    lab_sleep
  done
  # Clones share host keys and IPs are reused across VMs: forget the old key of this address.
  if [[ -f "$VM_LAB_KEYS/known_hosts" ]]; then
    ssh-keygen -R "$ip" -f "$VM_LAB_KEYS/known_hosts" >/dev/null 2>&1 || true
  fi
  lab_log "$vm has IP $ip; waiting for SSH"
  lab_wait_ssh "$ip" "$deadline" || return
  echo "$ip" >"$VM_LAB_STATE/$vm.ip"
  LAB_UP_IP="$ip"
  lab_log "$vm is up at $ip"
}

# lab_down <vm>: guest shutdown over SSH, then tart stop, then the tart run process is killed.
lab_down() {
  local vm="$1" ip pid deadline forced=0
  lab_validate_name "$vm" || return
  if ! lab_is_running "$vm"; then
    lab_log "$vm is not running"
    rm -f "$VM_LAB_STATE/$vm.pid" "$VM_LAB_STATE/$vm.ip"
    lab_disown "$vm"
    return 0
  fi
  ip="$(lab_vm_ip "$vm" || true)"
  if [[ -n "$ip" && -f "$VM_LAB_KEYS/id_ed25519" ]]; then
    lab_set_ssh_opts
    lab_log "asking $vm to shut down"
    ssh "${LAB_SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=5 "$VM_SSH_USER@$ip" \
      'sudo -n /sbin/shutdown -h now' </dev/null >/dev/null 2>&1 || true
  fi
  deadline=$((SECONDS + VM_STOP_TIMEOUT))
  while lab_is_running "$vm" && ((SECONDS < deadline)); do
    lab_sleep
  done
  if lab_is_running "$vm"; then
    forced=1
    lab_log "$vm did not shut down within ${VM_STOP_TIMEOUT}s; tart stop"
    lab_tart stop "$vm" --timeout 15 >/dev/null 2>&1 || true
  fi
  if lab_is_running "$vm"; then
    pid="$(cat "$VM_LAB_STATE/$vm.pid" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      lab_log "killing tart run (pid $pid) for $vm"
      kill -TERM "$pid" 2>/dev/null || true
      deadline=$((SECONDS + 10))
      while kill -0 "$pid" 2>/dev/null && ((SECONDS < deadline)); do lab_sleep; done
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  if lab_is_running "$vm"; then
    lab_err_ret 1 "could not stop $vm"
    return
  fi
  rm -f "$VM_LAB_STATE/$vm.pid" "$VM_LAB_STATE/$vm.ip"
  lab_disown "$vm"
  if ((forced)); then lab_log "$vm stopped (forced)"; else lab_log "$vm stopped"; fi
}

# lab_require_running <vm>: sets LAB_IP or returns 3.
lab_require_running() {
  local vm="$1"
  LAB_IP=""
  lab_validate_name "$vm" || return
  lab_check_paths || return
  if ! lab_is_running "$vm"; then
    lab_err_ret 3 "$vm is not running (scripts/vm/lab.sh up $vm)"
    return
  fi
  LAB_IP="$(lab_vm_ip "$vm" || true)"
  if [[ -z "$LAB_IP" ]]; then
    lab_err_ret 1 "$vm runs but has no IP address yet"
    return
  fi
  lab_set_ssh_opts
}

# lab_ssh <vm> <remote command...>: runs a command in the guest (a remote shell string, as with ssh).
lab_ssh() {
  local vm="$1"
  shift
  lab_require_running "$vm" || return
  ssh "${LAB_SSH_OPTS[@]}" -o BatchMode=yes "$VM_SSH_USER@$LAB_IP" "$@"
}

# lab_push <vm> <local path> <remote dir>: copies a file or folder into the remote folder with tar over SSH,
# which keeps symbolic links and code signatures intact (scp -r does not).
lab_push() {
  local vm="$1" src="$2" dest="$3" parent base
  lab_validate_remote_path "$dest" || return
  if [[ ! -e "$src" ]]; then
    lab_err_ret 2 "no such local file or folder: $src"
    return
  fi
  lab_require_running "$vm" || return
  parent="$(cd "$(dirname "$src")" && pwd)"
  base="$(basename "$src")"
  COPYFILE_DISABLE=1 tar -C "$parent" -cf - "$base" |
    ssh "${LAB_SSH_OPTS[@]}" -o BatchMode=yes "$VM_SSH_USER@$LAB_IP" "mkdir -p '$dest' && tar -C '$dest' -xf -"
}

# lab_pull <vm> <remote path> <local dir>
lab_pull() {
  local vm="$1" src="$2" dest="$3" parent base
  lab_validate_remote_path "$src" || return
  lab_require_running "$vm" || return
  mkdir -p "$dest" || return 1
  parent="$(dirname "$src")"
  base="$(basename "$src")"
  ssh "${LAB_SSH_OPTS[@]}" -o BatchMode=yes "$VM_SSH_USER@$LAB_IP" "tar -C '$parent' -cf - '$base'" |
    tar -C "$dest" -xf -
}

lab_clone() {
  local src="$1" dst="$2"
  lab_validate_name "$src" || return
  lab_validate_name "$dst" || return
  lab_check_paths || return
  if ! lab_vm_exists "$src"; then
    lab_err_ret 2 "no local VM named $src"
    return
  fi
  if lab_vm_exists "$dst"; then
    lab_err_ret 3 "a VM named $dst already exists; refusing to overwrite it"
    return
  fi
  # No automatic pruning: a clone must never evict the OCI cache the base VMs came from.
  TART_NO_AUTO_PRUNE=1 lab_tart clone "$src" "$dst" || {
    lab_err_ret 1 "tart clone $src $dst failed"
    return
  }
  printf 'source=%s\ncreated=%s\n' "$src" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$VM_LAB_STATE/clones/$dst"
  lab_log "cloned $src to $dst (throwaway; scripts/vm/lab.sh delete $dst)"
}

lab_is_lab_clone() { [[ -f "$VM_LAB_STATE/clones/$1" ]]; }

lab_delete() {
  local vm="$1"
  lab_validate_name "$vm" || return
  lab_check_paths || return
  if ! lab_is_lab_clone "$vm"; then
    lab_err_ret 3 "refusing to delete $vm: not created by scripts/vm/lab.sh clone (only throwaway clones are deleted)"
    return
  fi
  if lab_is_running "$vm"; then
    lab_err_ret 3 "refusing to delete $vm while it is running (scripts/vm/lab.sh down $vm)"
    return
  fi
  if lab_vm_exists "$vm"; then
    lab_tart delete "$vm" || {
      lab_err_ret 1 "tart delete $vm failed"
      return
    }
  fi
  rm -f "$VM_LAB_STATE/clones/$vm" "$VM_LAB_STATE/$vm.log"
  lab_log "deleted the throwaway clone $vm"
}

# lab_prepare_target <base VM> <in place 0|1> <clone suffix>: preflight of a script that works in a throwaway
# clone <base>-<suffix> (or in the base itself): the base exists, a VM with the clone name that the lab did not
# create is never replaced, and no VM runs. Sets LAB_TARGET. Nothing is cloned or booted here.
lab_prepare_target() {
  local base="$1" in_place="$2" suffix="$3" vm rc=0
  LAB_TARGET=""
  lab_validate_name "$base" || return
  lab_check_paths || return
  if ! lab_vm_exists "$base"; then
    lab_err_ret 2 "no local VM named $base (scripts/vm/lab.sh status)"
    return
  fi
  vm="$base"
  if ((in_place == 0)); then
    vm="$base-$suffix"
    lab_validate_name "$vm" || return
    if lab_vm_exists "$vm" && ! lab_is_lab_clone "$vm"; then
      lab_err_ret 3 "a VM named $vm exists that was not created by scripts/vm/lab.sh clone; refusing to replace it"
      return
    fi
  fi
  lab_refuse_if_busy "$vm" || rc=$?
  if ((rc == 4)); then
    lab_err_ret 3 "$vm is already running; stop it first (scripts/vm/lab.sh down $vm)"
    return
  elif ((rc != 0)); then
    return "$rc"
  fi
  LAB_TARGET="$vm"
}

# lab_start_target <base VM> <target> <memory> <cpus>: clones the base when the target is a clone (replacing a
# stale clone of the lab from an earlier run), registers the clone for deletion on exit and boots the target.
lab_start_target() {
  local base="$1" vm="$2" memory="$3" cpus="$4"
  if [[ "$vm" != "$base" ]]; then
    if lab_vm_exists "$vm"; then
      lab_log "removing the stale throwaway clone $vm from an earlier run"
      lab_delete "$vm" || return
    fi
    lab_clone "$base" "$vm" || return
    VM_LAB_CLONES="$VM_LAB_CLONES $vm"
  fi
  lab_up "$vm" "$memory" "$cpus"
}

# Stops every VM this process started and deletes every clone it created. Installed as the EXIT trap.
lab_cleanup() {
  local rc=$? vm
  trap - EXIT INT TERM HUP
  for vm in $VM_LAB_OWNED; do
    lab_down "$vm" || lab_err "could not stop $vm; stop it with scripts/vm/lab.sh down $vm"
  done
  for vm in $VM_LAB_CLONES; do
    lab_delete "$vm" || true
  done
  exit "$rc"
}

lab_install_trap() {
  trap lab_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
}
