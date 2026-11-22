#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Runs the harness of one prepared tree (prepare-tree.sh) over every input set of INPUTS (generate-inputs.py), with
# typoCorrection off (c0) and on (c1), and writes OUT/LABEL-SET-c0.tsv and -c1.tsv with the test log next to each.
# Sets whose name starts with f_ (the random sequences) also record the field after every event. Exit status 1 when
# a run fails or writes a different number of lines than its input has.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: run-tree.sh [--scratch NAME] [--sets NAME[,NAME]] TREE INPUTS OUT LABEL

  TREE            directory given to prepare-tree.sh
  INPUTS          directory written by generate-inputs.py
  OUT             directory for the outputs (created if missing)
  LABEL           file name prefix of this tree, base or head for compare.py
  --scratch NAME  SwiftPM scratch directory used by prepare-tree.sh (default .build-measure)
  --sets LIST     comma-separated set names to run (default: every .txt file of INPUTS)
EOF
}

scratch=".build-measure"
sets=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --scratch) scratch="${2:?--scratch needs a value}"; shift 2 ;;
    --sets) sets=",${2:?--sets needs a value},"; shift 2 ;;
    -*) usage >&2; exit 2 ;;
    *) break ;;
  esac
done
[[ $# -eq 4 ]] || { usage >&2; exit 2; }
package="$(cd "$1" && pwd)/Packages/VietnameseEngine"
inputs="$(cd "$2" && pwd)"
mkdir -p "$3"
out="$(cd "$3" && pwd)"
label="$4"
[[ -d "$package/$scratch" ]] || { echo "run-tree: no build in $package/$scratch; run prepare-tree.sh" >&2; exit 1; }

failed=0
ran=0
for input in "$inputs"/*.txt; do
  [[ -e "$input" ]] || continue
  name="$(basename "$input" .txt)"
  [[ -z "$sets" || "$sets" == *",$name,"* ]] || continue
  trace=0
  [[ "$name" == f_* ]] && trace=1
  expected="$(wc -l <"$input" | tr -d ' ')"
  for correction in 0 1; do
    tsv="$out/$label-$name-c$correction.tsv"
    status=0
    WDM_INPUT="$input" WDM_OUTPUT="$tsv" WDM_CORRECTION="$correction" WDM_TRACE="$trace" \
      nice swift test --package-path "$package" --scratch-path "$package/$scratch" --skip-build \
      --filter WDoublingMeasureTests >"${tsv%.tsv}.log" 2>&1 || status=$?
    written=0
    [[ -f "$tsv" ]] && written="$(wc -l <"$tsv" | tr -d ' ')"
    printf '%s %s c%s: exit %s, %s of %s lines\n' "$label" "$name" "$correction" "$status" "$written" "$expected"
    if [[ "$status" -ne 0 || "$written" != "$expected" ]]; then
      failed=1
    fi
    ran=$((ran + 1))
  done
done
[[ "$ran" -gt 0 ]] || { echo "run-tree: no input set selected in $inputs" >&2; exit 1; }
exit "$failed"
