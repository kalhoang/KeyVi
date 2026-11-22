#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Prepares one tree of the w doubling measurement (README.md in this directory): exports Packages/VietnameseEngine of
# COMMIT with git archive into TREE (skipped when TREE already holds the package), copies the harness
# WDoublingMeasureTests.swift into the test target VietnameseEngineDataTests of that copy and builds the package with
# its tests, under nice, in a private scratch path inside the copy. The repository checkout itself is never built.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: prepare-tree.sh [--scratch NAME] COMMIT TREE

  COMMIT          commit whose engine package is measured (for example 0fdb9d98)
  TREE            scratch directory outside the checkout; the package lands in TREE/Packages/VietnameseEngine
  --scratch NAME  SwiftPM scratch directory inside the package copy (default .build-measure)
EOF
}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scratch=".build-measure"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --scratch) scratch="${2:?--scratch needs a value}"; shift 2 ;;
    -*) usage >&2; exit 2 ;;
    *) break ;;
  esac
done
[[ $# -eq 2 ]] || { usage >&2; exit 2; }
commit="$1"
tree="$2"

repo="$(git -C "$here" rev-parse --show-toplevel)"
mkdir -p "$tree"
tree="$(cd "$tree" && pwd)"
case "$tree/" in
  "$repo"/*) echo "prepare-tree: TREE must be outside the checkout ($repo)" >&2; exit 2 ;;
esac
package="$tree/Packages/VietnameseEngine"
if [[ -d "$package" ]]; then
  echo "prepare-tree: $package exists; export skipped"
else
  git -C "$repo" archive "$commit" Packages/VietnameseEngine | tar -x -C "$tree"
  echo "prepare-tree: exported $(git -C "$repo" rev-parse --short "$commit^{commit}") to $package"
fi
target="$package/Tests/VietnameseEngineDataTests/RealData"
[[ -d "$target" ]] || { echo "prepare-tree: no test target folder $target" >&2; exit 1; }
cp "$here/WDoublingMeasureTests.swift" "$target/WDoublingMeasureTests.swift"
nice swift build --build-tests --package-path "$package" --scratch-path "$package/$scratch"
