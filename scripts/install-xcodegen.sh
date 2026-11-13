#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Installs the pinned XcodeGen release, verified by SHA-256 (PLT-R910), into .build/tools/ and prints
# the directory that contains the `xcodegen` binary. In GitHub Actions the directory is also appended
# to $GITHUB_PATH. Bump XCODEGEN_VERSION and XCODEGEN_SHA256 together (Dependabot does not track it).
set -euo pipefail

XCODEGEN_VERSION="2.46.0"
XCODEGEN_SHA256="4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"

usage() {
  cat <<EOF
Usage: scripts/install-xcodegen.sh [--prefer-system]

Installs XcodeGen ${XCODEGEN_VERSION} (xcodegen.zip, SHA-256 pinned) into .build/tools/xcodegen and
prints its bin directory.
  --prefer-system   use an xcodegen already on PATH (any version) instead of downloading
  -h, --help        show this help
EOF
}

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

prefer_system=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --prefer-system) prefer_system=1; shift ;;
    *) usage >&2; exit 2 ;;
  esac
done

if [[ $prefer_system -eq 1 ]] && command -v xcodegen >/dev/null 2>&1; then
  dirname "$(command -v xcodegen)"
  exit 0
fi

tools="$REPO_ROOT/.build/tools"
bin_dir="$tools/xcodegen-$XCODEGEN_VERSION/xcodegen/bin"
if [[ ! -x "$bin_dir/xcodegen" ]]; then
  require_cmd unzip
  mkdir -p "$tools"
  archive="$(mktemp "$tools/xcodegen.XXXXXX")"
  info "downloading XcodeGen $XCODEGEN_VERSION"
  fetch_verified "https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip" \
    "$XCODEGEN_SHA256" "$archive"
  rm -rf "$tools/xcodegen-$XCODEGEN_VERSION"
  unzip -q "$archive" -d "$tools/xcodegen-$XCODEGEN_VERSION"
  rm -f "$archive"
fi
"$bin_dir/xcodegen" --version >&2
if [[ -n "${GITHUB_PATH:-}" ]]; then
  printf '%s\n' "$bin_dir" >>"$GITHUB_PATH"
fi
printf '%s\n' "$bin_dir"
