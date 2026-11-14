#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Guest half of scripts/vm/pane-names.sh (docs/runbooks/vm-test-lab.md section 10): in the guest's current
# language, opens each System Settings (macOS 13 and later) or System Preferences (macOS 12) deep link of
# App/Resources/SystemPanes.json, reads the window that opened through the Accessibility API (ax-dump.swift) and
# takes a screenshot of it, then reads the app's menus (its name) and Terminal's menus, whose Secure Keyboard Entry
# item the secure-input hint quotes (PLT-R704, PRD-R64, PLT-R398C, ADR 0315). Runs INSIDE the disposable VM only,
# over SSH as the logged-in user; it exits 3 on a real Mac before it parses an argument.
#
# Usage: pane-names-guest.sh --out DIR --links FILE --tool AX_DUMP [--settle SECONDS]
#   FILE has one "<name><TAB><x-apple.systempreferences: URL>" line per link; <name> is letters, digits and dots.
#   AX_DUMP is the ax-dump executable that pane-names.sh builds on the host (the macOS 12 lab image has no command
#   line tools, see smoke-guest.sh), or ax-dump.swift, compiled here only when the command line tools are installed.
# Exit status: 0 every link opened a window that was read, 1 otherwise, 2 usage error, 3 not a VM.
set -uo pipefail

# Refuse to run anywhere but inside a virtual machine, before parsing arguments and before any side effect: this
# script kills and opens System Settings and Terminal and uses sudo (QA-R13 keeps all of that off a real Mac).
[ "$(sysctl -n kern.hv_vmm_present 2>/dev/null || echo 0)" = 1 ] || {
  echo "refusing: not inside a virtual machine" >&2
  exit 3
}

usage() {
  echo "usage: pane-names-guest.sh --out DIR --links FILE --tool AX_DUMP [--settle SECONDS]" >&2
  exit 2
}
out=""
links=""
tool=""
settle=6
while [ $# -gt 0 ]; do
  case "$1" in
    --out) [ $# -ge 2 ] || usage; out="$2"; shift 2 ;;
    --links) [ $# -ge 2 ] || usage; links="$2"; shift 2 ;;
    --tool) [ $# -ge 2 ] || usage; tool="$2"; shift 2 ;;
    --settle)
      [ $# -ge 2 ] || usage
      case "$2" in '' | *[!0-9]*) usage ;; esac
      [ "$2" -ge 1 ] && [ "$2" -le 60 ] || usage
      settle="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done
[ -n "$out" ] && [ -f "$links" ] && [ -f "$tool" ] || usage
case "$tool" in
  *.swift) ;;
  *) [ -x "$tool" ] || usage ;;
esac
mkdir -p "$out"
summary="$out/summary.txt"
: >"$summary"
note() { echo "$*" | tee -a "$summary"; }

SETTINGS=com.apple.systempreferences
TERMINAL=com.apple.Terminal
uid="$(id -u)"
user="$(id -un)"
# In the logged-in GUI session: the SSH session has its own bootstrap namespace, from which LaunchServices, the
# window server and the Accessibility API do not reach the user's apps.
gui() { sudo -n launchctl asuser "$uid" sudo -n -u "$user" "$@"; }
quit_settings() {
  pkill -x "System Settings" 2>/dev/null
  pkill -x "System Preferences" 2>/dev/null
  sleep 2
}

{
  sw_vers
  echo "AppleLanguages: $(defaults read -g AppleLanguages 2>/dev/null | tr -d ' \n')"
  echo "AppleLocale: $(defaults read -g AppleLocale 2>/dev/null)"
  echo "SIP: $(csrutil status 2>&1)"
} >"$out/system.txt"
note "system: macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(sed -n 's/^AppleLanguages: //p' "$out/system.txt")"

work="$(mktemp -d)"
case "$tool" in
  *.swift)
    # Without the command line tools /usr/bin/swiftc is only the xcode-select shim, which offers to install them.
    if ! xcode-select -p >/dev/null 2>&1; then
      note "STOPPED: no command line tools in this VM to compile $tool; pass the ax-dump binary pane-names.sh builds"
      exit 1
    fi
    bin="$work/ax-dump"
    if ! swiftc -O -o "$bin" "$tool" >"$out/compile.txt" 2>&1; then
      note "STOPPED: ax-dump.swift did not compile (compile.txt)"
      exit 1
    fi
    ;;
  *) bin="$(cd "$(dirname "$tool")" && pwd)/$(basename "$tool")" ;;
esac
trusted=0
gui "$bin" --trusted >"$out/trusted.txt" 2>&1 && trusted=1
note "accessibility: $(cat "$out/trusted.txt")"

failures=0
tab="$(printf '\t')"
while IFS="$tab" read -r name url; do
  [ -n "$name" ] || continue
  case "$name" in *[!A-Za-z0-9.]*) note "skip: bad name $name"; failures=$((failures + 1)); continue ;; esac
  case "$url" in
    x-apple.systempreferences:*) ;;
    *) note "skip $name: not a System Settings URL"; failures=$((failures + 1)); continue ;;
  esac
  quit_settings
  gui /usr/bin/open "$url" >"$out/$name.open.txt" 2>&1 || note "$name: open failed ($(cat "$out/$name.open.txt"))"
  sleep "$settle"
  if ((trusted)) && gui "$bin" --bundle "$SETTINGS" --wait 20 --windows >"$out/$name.ax.txt" 2>&1; then
    note "$name: $url -> $(grep -m 1 'AXWindow' "$out/$name.ax.txt")"
  else
    failures=$((failures + 1))
    note "$name: $url -> window not read ($name.ax.txt)"
  fi
  gui /usr/sbin/screencapture -x "$out/$name.png" 2>/dev/null || note "$name: no screenshot"
done <"$links"

# The app's own name is the title of its application menu.
if ((trusted)); then
  gui "$bin" --bundle "$SETTINGS" --wait 10 --menus --depth 3 >"$out/settings-menus.ax.txt" 2>&1 ||
    note "settings menus not read"
fi
quit_settings

# Terminal: its menus, then a screenshot with the application menu open.
gui /usr/bin/open -b "$TERMINAL" || note "Terminal did not open"
sleep "$settle"
if ((trusted)); then
  gui "$bin" --bundle "$TERMINAL" --wait 20 --menus >"$out/terminal-menus.ax.txt" 2>&1 || note "Terminal menus not read"
  gui "$bin" --bundle "$TERMINAL" --open-menu 1 >"$out/terminal-press.txt" 2>&1
  sleep 2
  gui /usr/sbin/screencapture -x "$out/terminal-menu.png" 2>/dev/null || note "terminal: no screenshot"
  gui "$bin" --bundle "$TERMINAL" --close-menus >/dev/null 2>&1
fi
pkill -9 -x Terminal 2>/dev/null
rm -rf "$work"
note "failures: $failures"
((failures == 0))
