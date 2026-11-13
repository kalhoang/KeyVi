#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Derives CFBundleVersion from the semantic version (QA-R26, PLT-R1104): a single integer that
# increases with every build published to any channel, without any stored counter.
#   build = MAJOR * 1000000 + MINOR * 10000 + PATCH * 100 + (beta N, or 99 for a stable release)
# Examples: 0.1.0-beta.1 -> 10001, 0.1.0 -> 10099, 1.4.1 -> 1040199.
# Limits: MINOR and PATCH at most 99, beta number 1 to 98. Rationale: docs/decisions/0503.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/build-number.sh <version>

Prints the CFBundleVersion integer for a version such as 1.2.3 or 1.2.3-beta.4 (a leading "v" is
accepted, so a tag name works).
EOF
}

case "${1:-}" in
  -h | --help) usage; exit 0 ;;
  "") usage >&2; exit 2 ;;
esac

version="${1#v}"
if [[ ! "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-beta\.([0-9]+))?$ ]]; then
  printf 'error: not a release version (X.Y.Z or X.Y.Z-beta.N): %s\n' "$1" >&2
  exit 1
fi
major=$((10#${BASH_REMATCH[1]}))
minor=$((10#${BASH_REMATCH[2]}))
patch=$((10#${BASH_REMATCH[3]}))
beta="${BASH_REMATCH[5]:-}"
if ((minor > 99 || patch > 99)); then
  printf 'error: MINOR and PATCH must be at most 99 for the build number scheme\n' >&2
  exit 1
fi
if [[ -n "$beta" ]]; then
  beta=$((10#$beta))
  if ((beta < 1 || beta > 98)); then
    printf 'error: beta number must be between 1 and 98\n' >&2
    exit 1
  fi
  suffix=$beta
else
  suffix=99
fi
printf '%d\n' $((major * 1000000 + minor * 10000 + patch * 100 + suffix))
