#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
#
# ENG-T40: builds the engine benchmark in release, runs it (median of 5 runs, 1,000,000 fuzz events for
# the percentiles, a 10,000,000-event fuzz run for the worst case) and compares the result with the
# baseline after calibration (ENG-R1233, QA-R14). Exit status 1 when the gate fails.
# ENG-T55, ENG-R1122: every run also measures the typo correction candidates (`correction`, budget 50 µs at
# p99 and 200 µs in the worst case). The ENG-T40 workloads run with the typo correction off first (comparable
# with the baseline, measured on 1.0), then on; the second result is compared with the first, so the
# percentiles may not move by more than the tolerance the baseline gate applies.
# Both passes and both comparisons always run: a failed comparison with the baseline never skips the on/off check
# of ENG-T55. The script exits 1 when either comparison fails and names each result at the end.
# Usage: Scripts/benchmark.sh [output.json] [extra engine-benchmark arguments...]
set -eu
cd "$(dirname "$0")/.."
output="${1:-.build-release/benchmark-latest.json}"
[ $# -gt 0 ] && shift
swift build -c release --scratch-path .build-release --product engine-benchmark
.build-release/release/engine-benchmark --typo-correction off --output "$output" "$@"
baseline_status=passed
python3 -I Benchmarks/compare.py Benchmarks/baseline.json "$output" || baseline_status=failed
switched="${output%.json}-typo-correction-on.json"
.build-release/release/engine-benchmark --typo-correction on --output "$switched" "$@"
switch_status=passed
python3 -I Benchmarks/compare.py "$output" "$switched" || switch_status=failed
printf 'ENG-T40 against Benchmarks/baseline.json: %s\n' "$baseline_status"
printf 'ENG-T55 switch on against switch off: %s\n' "$switch_status"
[ "$baseline_status" = passed ] && [ "$switch_status" = passed ]
