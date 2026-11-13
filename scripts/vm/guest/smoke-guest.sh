#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Guest half of the macOS 12 smoke test (scripts/vm/smoke-macos12.sh; ADR 0315, PLT-R105, PLT-R106, PLT-R710).
# Runs INSIDE the throwaway macOS 12 VM as the auto-logged-in user, never on the host. Written for the macOS
# system bash 3.2 and for a vanilla image without the command line tools (lipo is used when present, otherwise
# macho-info.pl next to this script).
#
# Steps: record the system, check the slices and minos, install Rosetta when missing, install the app in
# /Applications (PLT-R710 asks for that location), launch the arm64 slice natively and then the x86_64 slice
# under Rosetta, require each to stay alive for the window without dyld or missing-symbol errors and without a
# crash report, collect the unified log of the app's subsystem and process, then quit it.
# Writes everything under --out and summary.txt; exits 0 when every check passes.
set -u

usage() {
  echo "usage: smoke-guest.sh --app PATH --subsystem ID --out DIR [--alive SECONDS]" >&2
  exit 2
}

app=""
subsystem=""
out=""
alive=20
while [ $# -gt 0 ]; do
  case "$1" in
    --app) app="${2:-}"; shift 2 ;;
    --subsystem) subsystem="${2:-}"; shift 2 ;;
    --out) out="${2:-}"; shift 2 ;;
    --alive) alive="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$app" ] && [ -n "$subsystem" ] && [ -n "$out" ] || usage
case "$alive" in '' | *[!0-9]*) usage ;; esac

here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$out"
: >"$out/summary.txt"
failures=0

note() { echo "$*" | tee -a "$out/summary.txt"; }
pass() { note "PASS $*"; }
fail() {
  note "FAIL $*"
  failures=$((failures + 1))
}

plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }

exec_name="$(plist_value "$app" CFBundleExecutable)"
if [ -z "$exec_name" ] || [ ! -f "$app/Contents/MacOS/$exec_name" ]; then
  fail "bundle: no executable in $app"
  exit 1
fi

# 1. The system under test.
{
  sw_vers
  echo "uname: $(uname -a)"
  echo "cpu: $(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
  echo "SIP: $(csrutil status 2>&1)"
  echo "developer dir: $(xcode-select -p 2>&1)"
  echo "console user: $(stat -f %Su /dev/console)"
} >"$out/vm-info.txt" 2>&1
note "system: macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)) on $(uname -m)"

# 2. Install into /Applications (the admin group may write there), replacing an earlier copy.
dest="/Applications/$(basename "$app")"
pkill -f "$dest/Contents/MacOS/$exec_name" 2>/dev/null
sleep 1
rm -rf "$dest"
if ! ditto "$app" "$dest"; then
  fail "install: could not copy the app to $dest"
  exit 1
fi
bin="$dest/Contents/MacOS/$exec_name"
if codesign --verify --deep --strict "$dest" >"$out/codesign.txt" 2>&1; then
  pass "signature: valid (codesign --verify --deep --strict)"
else
  fail "signature: codesign --verify failed (see codesign.txt)"
fi

# 3. Slices and minimum system version.
if xcode-select -p >/dev/null 2>&1 && lipo -archs "$bin" >/dev/null 2>&1; then
  archs="$(lipo -archs "$bin")"
  tool="lipo -archs"
else
  archs="$(perl "$here/macho-info.pl" --archs "$bin")"
  tool="macho-info.pl (no command line tools in this VM, so no lipo -archs)"
fi
perl "$here/macho-info.pl" "$bin" >"$out/macho.txt" 2>&1
note "slices ($tool): $archs"
for arch in arm64 x86_64; do
  case " $archs " in
    *" $arch "*) ;;
    *) fail "slices: $arch missing" ;;
  esac
done
while read -r slice _ minos _; do
  major="${minos%%.*}"
  rest="${minos#*.}"
  minor="${rest%%.*}"
  case "$major$minor" in
    *[!0-9]* | '') fail "minos: $slice has no readable minimum version ($minos)" ;;
    *)
      if [ "$major" -lt 12 ] || { [ "$major" -eq 12 ] && [ "$minor" -eq 0 ]; }; then
        pass "minos: $slice $minos"
      else
        fail "minos: $slice needs macOS $minos, newer than 12.0"
      fi
      ;;
  esac
done <"$out/macho.txt"

# 4. Rosetta for the x86_64 slice.
rosetta_ok=0
if /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
  rosetta_ok=1
  note "rosetta: already installed"
else
  note "rosetta: installing (softwareupdate --install-rosetta --agree-to-license)"
  # The redirect belongs to this user on purpose: only softwareupdate needs root.
  # shellcheck disable=SC2024
  sudo -n /usr/sbin/softwareupdate --install-rosetta --agree-to-license >"$out/rosetta-install.txt" 2>&1
  if /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
    rosetta_ok=1
    note "rosetta: installed"
  else
    fail "rosetta: could not be installed (see rosetta-install.txt)"
  fi
fi

app_pid() { pgrep -n -f "$bin" 2>/dev/null; }

# launch_slice <arch>: launches, watches, collects and quits one slice.
launch_slice() {
  local arch="$1" dir="$out/$1" pid="" seconds=0 translated=no start reasons=""
  mkdir -p "$dir/crash"
  pkill -f "$bin" 2>/dev/null
  sleep 1
  touch "$dir/.started"
  start="$(date '+%Y-%m-%d %H:%M:%S')"
  if ! open -n -g --arch "$arch" --stdout "$dir/stdout.txt" --stderr "$dir/stderr.txt" "$dest" >"$dir/open.txt" 2>&1; then
    # Fallback when open cannot pick the slice: start the binary in the GUI session of this user.
    echo "open --arch failed, falling back to launchctl asuser" >>"$dir/open.txt"
    # shellcheck disable=SC2024 # the log files belong to this user on purpose
    sudo -n launchctl asuser "$(id -u)" sudo -n -u "$(id -un)" /usr/bin/arch "-$arch" "$bin" \
      >"$dir/stdout.txt" 2>"$dir/stderr.txt" &
  fi
  while [ $seconds -lt 15 ]; do
    pid="$(app_pid)"
    [ -n "$pid" ] && break
    sleep 1
    seconds=$((seconds + 1))
  done
  if [ -z "$pid" ]; then
    reasons="did not start within 15 s"
  else
    lsof -p "$pid" >"$dir/lsof.txt" 2>&1
    if grep -Eq 'libRosettaRuntime|/oah/' "$dir/lsof.txt"; then translated=yes; fi
    if [ "$arch" = x86_64 ] && [ "$translated" != yes ]; then reasons="$reasons; not running under Rosetta"; fi
    if [ "$arch" = arm64 ] && [ "$translated" = yes ]; then reasons="$reasons; translated although arm64 was asked for"; fi
    seconds=0
    while [ $seconds -lt "$alive" ] && kill -0 "$pid" 2>/dev/null; do
      sleep 1
      seconds=$((seconds + 1))
    done
    ps -o pid,etime,rss,command -p "$pid" >"$dir/ps.txt" 2>&1
    if kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null
      local waited=0
      while kill -0 "$pid" 2>/dev/null && [ $waited -lt 10 ]; do
        sleep 1
        waited=$((waited + 1))
      done
      kill -KILL "$pid" 2>/dev/null
    else
      reasons="$reasons; exited after $seconds s (window ${alive} s)"
    fi
  fi
  sleep 3 # crash reports and log lines land a little later
  log show --start "$start" --style compact --info --debug \
    --predicate "subsystem == \"$subsystem\" OR process == \"$exec_name\" OR (eventMessage CONTAINS \"$exec_name\" AND (process == \"kernel\" OR process == \"ReportCrash\" OR process == \"amfid\" OR process == \"launchd\"))" \
    >"$dir/unified.log" 2>&1
  if grep -Eiq 'dyld|Symbol not found|Library not loaded|image not found' "$dir/stderr.txt" 2>/dev/null; then
    reasons="$reasons; dyld error on stderr"
  fi
  if grep -Eq 'Symbol not found|Library not loaded|dyld\[[0-9]+\]|DYLD, ' "$dir/unified.log"; then
    reasons="$reasons; dyld error in the unified log"
  fi
  find "$HOME/Library/Logs/DiagnosticReports" /Library/Logs/DiagnosticReports -type f -newer "$dir/.started" \
    -name "${exec_name}*" -exec cp {} "$dir/crash/" \; 2>/dev/null
  if [ -n "$(ls -A "$dir/crash" 2>/dev/null)" ]; then reasons="$reasons; crash report written"; fi
  reasons="${reasons#; }"
  if [ -z "$reasons" ]; then
    pass "launch $arch: alive ${alive} s, translated=$translated, no dyld errors, no crash report"
  else
    fail "launch $arch: $reasons (translated=$translated)"
  fi
}

launch_slice arm64
if [ $rosetta_ok -eq 1 ]; then
  launch_slice x86_64
else
  fail "launch x86_64: skipped, Rosetta missing"
fi

if [ $failures -eq 0 ]; then
  note "GUEST RESULT: PASS"
  exit 0
fi
note "GUEST RESULT: FAIL ($failures check(s))"
exit 1
