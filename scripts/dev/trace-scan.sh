#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Reads the dev recorder's trace folder (PLT-R904A; docs/decisions/0007-dev-recorder.md, docs/runbooks/dev-recorder.md)
# with `trace-scan`, built in release mode from Packages/AppCore on first use. Without --dir it reads the dev build's
# folder, ~/Library/Logs/<folder>/dev-traces, where <folder> comes from scripts/brand.env (the display name, or the
# slug when the name is not ASCII, PLT-R903). Reads only and prints to standard output; it never writes, moves or
# deletes a trace file and never sends anything anywhere.
#
# Environment: TRACE_SCAN_BIN (a prebuilt trace-scan, tests), TRACE_SCAN_SCRATCH (SwiftPM scratch path, default
# Packages/AppCore/.build-trace-scan), BRAND_ENV (brand file, tests).
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/dev/trace-scan.sh summary [--since 2h | --date YYYY-MM-DD] [--dir PATH] [--no-replay]
       scripts/dev/trace-scan.sh show N [--before 30s] [--after 10s] [--since ... | --date ...] [--dir PATH]
       scripts/dev/trace-scan.sh --print-dir

  summary      metadata only (files, apps, counts, gaps) and the numbered findings, no typed content
  show N       the excerpt around finding N; pass the same --since or --date as the summary that numbered it
  --print-dir  print the default trace folder and exit
  --dir PATH   another trace folder (default: the dev build's, see --print-dir)
USAGE
}

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

case "${1:-}" in
  -h | --help) usage; exit 0 ;;
  "") usage >&2; exit 2 ;;
esac

load_brand
folder="$APP_DISPLAY_NAME"
if LC_ALL=C grep -q '[^ -~]' <<<"$folder"; then folder="$APP_SLUG"; fi
default_dir="$HOME/Library/Logs/$folder/dev-traces"
if [[ "$1" == "--print-dir" ]]; then
  printf '%s\n' "$default_dir"
  exit 0
fi

args=("$@")
has_dir=0
for argument in "$@"; do
  if [[ "$argument" == "--dir" ]]; then has_dir=1; fi
done
if [[ $has_dir -eq 0 ]]; then args+=(--dir "$default_dir"); fi

bin="${TRACE_SCAN_BIN:-}"
if [[ -z "$bin" ]]; then
  require_cmd swift
  scratch="${TRACE_SCAN_SCRATCH:-$REPO_ROOT/Packages/AppCore/.build-trace-scan}"
  swift build -c release --package-path "$REPO_ROOT/Packages/AppCore" --scratch-path "$scratch" \
    --product trace-scan >&2
  bin="$scratch/release/trace-scan"
fi
exec "$bin" "${args[@]}"
