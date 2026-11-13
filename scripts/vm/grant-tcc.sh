#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Grants Accessibility, Input Monitoring and event posting (kTCCServiceAccessibility, kTCCServiceListenEvent,
# kTCCServicePostEvent) to the integration test clients by writing rows into the system TCC database.
# Runs ONLY inside a disposable tart VM whose System Integrity Protection is disabled (the Cirrus Labs Xcode
# images, docs/runbooks/vm-test-lab.md); it refuses to run on a real Mac or with SIP enabled. Never run it on
# the maintainer's Mac: permissions there are granted by hand (docs/runbooks/self-hosted-runner.md section 4).
#
# Each row carries the client's code requirement (csreq), compiled from its designated requirement, so the
# grant holds exactly for that signature: an ad-hoc signed client is identified by its cdhash and needs a new
# grant after every rebuild, a client signed with a stable identity keeps it (QA-R12, PLT-R751).
#
# Usage (inside the VM): sudo scripts/vm/grant-tcc.sh [--dry-run] [--service NAME]... \
#                          [--bundle PATH.app]... [--binary PATH]...
#   --bundle PATH.app   client identified by its bundle ID (client_type 0), for the app under test and TestHost
#   --binary PATH       client identified by its absolute path (client_type 1), for compat-harness, the process
#                       that starts it (sshd-keygen-wrapper for SSH, the tart guest agent for `tart exec`) or
#                       the runner's Runner.Worker
#   --service NAME      grant only these services (repeatable; default: the three above)
#   --dry-run           print the SQL instead of writing it
# Exit status: 0 granted, 1 failure, 2 usage error, 3 refused (not a VM, SIP enabled, not root).
set -euo pipefail

SYSTEM_DB="/Library/Application Support/com.apple.TCC/TCC.db"
TCC_DB="${TCC_DB:-$SYSTEM_DB}"
SQLITE3="${SQLITE3:-/usr/bin/sqlite3}"
DEFAULT_SERVICES="kTCCServiceAccessibility kTCCServiceListenEvent kTCCServicePostEvent"

usage() { sed -n '/^# Usage/,/^# Exit status/p' "$0" | sed 's/^# \{0,1\}//'; }
fail() {
  local code="$1"
  shift
  printf 'grant-tcc: %s\n' "$*" >&2
  exit "$code"
}

dry_run=0
services=""
clients=() # entries "<type>|<path>"
while (($#)); do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --dry-run) dry_run=1; shift ;;
    --service | --bundle | --binary)
      (($# >= 2)) || fail 2 "$1 needs a value"
      case "$1" in
        --service)
          [[ "$2" =~ ^kTCCService[A-Za-z]+$ ]] || fail 2 "not a TCC service name: $2"
          services="$services $2"
          ;;
        --bundle) clients+=("0|$2") ;;
        --binary) clients+=("1|$2") ;;
      esac
      shift 2
      ;;
    *) fail 2 "unknown option: $1 (see --help)" ;;
  esac
done
((${#clients[@]})) || fail 2 "no client given (--bundle or --binary)"
services="${services:-$DEFAULT_SERVICES}"

# --- Safety: a disposable VM with SIP disabled, nothing else ------------------------------------------------
[[ "$(uname -s)" == Darwin ]] || fail 3 "refusing: not macOS"
[[ "$(sysctl -n kern.hv_vmm_present 2>/dev/null || echo 0)" == 1 ]] ||
  fail 3 "refusing: this is not a virtual machine; the TCC database of a real Mac is never edited"
case "$(csrutil status 2>&1)" in
  *disabled*) ;;
  *) fail 3 "refusing: System Integrity Protection is enabled, the TCC database is read-only (grant by hand instead)" ;;
esac
if ((!dry_run)) && [[ "$TCC_DB" == "$SYSTEM_DB" ]] && [[ "$(id -u)" != 0 ]]; then
  fail 3 "refusing: writing the system TCC database needs root (sudo inside the VM)"
fi
((dry_run)) || [[ -f "$TCC_DB" ]] || fail 1 "TCC database not found: $TCC_DB"

# --- Clients: identifier and compiled code requirement ----------------------------------------------------------
hex_csreq() { # hex_csreq <code path>: the designated requirement, compiled, as hex (empty when unsigned)
  local requirement blob
  requirement="$(codesign -d -r- "$1" 2>/dev/null | sed -n 's/^#* *designated => //p' | head -n 1)"
  [[ -n "$requirement" ]] || return 0
  blob="$(mktemp)"
  if printf '%s\n' "$requirement" | csreq -r- -b "$blob" 2>/dev/null; then
    xxd -p "$blob" | tr -d '\n'
  fi
  rm -f "$blob"
}

sql_quote() { printf "'%s'" "${1//\'/\'\'}"; }

statements=""
now="$(date +%s)"
for entry in "${clients[@]}"; do
  type="${entry%%|*}"
  path="${entry#*|}"
  [[ "$path" == /* ]] || fail 2 "client paths must be absolute: $path"
  if [[ "$type" == 0 ]]; then
    [[ -d "$path" && -f "$path/Contents/Info.plist" ]] || fail 2 "not an app bundle: $path"
    identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$path/Contents/Info.plist" 2>/dev/null || true)"
    [[ -n "$identifier" ]] || fail 2 "no CFBundleIdentifier in $path"
  else
    [[ -f "$path" && -x "$path" ]] || fail 2 "not an executable file: $path"
    identifier="$path"
  fi
  csreq_hex="$(hex_csreq "$path")"
  if [[ -n "$csreq_hex" ]]; then csreq_sql="X'$csreq_hex'"; else csreq_sql="NULL"; fi
  printf 'grant-tcc: %s (%s) csreq %s\n' "$identifier" "$([[ $type == 0 ]] && echo bundle || echo path)" \
    "$([[ -n $csreq_hex ]] && echo "from its designated requirement" || echo "none (unsigned)")" >&2
  for service in $services; do
    # auth_value 2 = allowed, auth_reason 4 = set by the system, auth_version 1.
    statements+="INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, flags, last_modified) VALUES ($(sql_quote "$service"), $(sql_quote "$identifier"), $type, 2, 4, 1, $csreq_sql, 0, $now);"$'\n'
  done
done

if ((dry_run)); then
  printf '%s' "$statements"
  exit 0
fi
printf 'BEGIN;\n%sCOMMIT;\n' "$statements" | "$SQLITE3" "$TCC_DB" || fail 1 "writing $TCC_DB failed"
# tccd caches decisions: restart it so the new rows count at once (only for the real database, only in the VM).
if [[ "$TCC_DB" == "$SYSTEM_DB" ]]; then
  pkill -x tccd 2>/dev/null || true
fi
printf 'grant-tcc: %d row(s) written to %s\n' "$(printf '%s' "$statements" | grep -c 'INSERT')" "$TCC_DB" >&2
