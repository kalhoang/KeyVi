#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Prepares one tree of the context restore measurement (README.md in this directory): exports
# Packages/VietnameseEngine of COMMIT with git archive into TREE (skipped when TREE already holds the package of that
# same commit, recorded in TREE/.crm-commit; a TREE that holds another commit, or no record, is refused), copies the
# harness ContextRestoreMeasureTests.swift into the test target VietnameseEngineDataTests of that copy and builds the
# package with its tests, under nice, in a private scratch path inside the copy. The repository checkout itself is
# never built.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: prepare-tree.sh [--scratch NAME] COMMIT TREE

  COMMIT          commit whose engine package is measured (for example 28dbd6d0)
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
stamp="$tree/.crm-commit"
sha="$(git -C "$repo" rev-parse --verify "$commit^{commit}")"
if [[ -d "$package" ]]; then
  # Reusing a tree must never measure another commit than the one asked for.
  held="$(cat "$stamp" 2>/dev/null || true)"
  if [[ "$held" != "$sha" ]]; then
    echo "prepare-tree: $package holds ${held:-an unrecorded commit}, not $sha; use an empty TREE" >&2
    exit 1
  fi
  echo "prepare-tree: $package already holds ${sha:0:8}; export skipped"
else
  git -C "$repo" archive "$sha" Packages/VietnameseEngine | tar -x -C "$tree"
  echo "$sha" >"$stamp"
  echo "prepare-tree: exported ${sha:0:8} to $package"
fi
target="$package/Tests/VietnameseEngineDataTests/RealData"
[[ -d "$target" ]] || { echo "prepare-tree: no test target folder $target" >&2; exit 1; }
cp "$here/ContextRestoreMeasureTests.swift" "$target/ContextRestoreMeasureTests.swift"
nice swift build --build-tests --package-path "$package" --scratch-path "$package/$scratch"
