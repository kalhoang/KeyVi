#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
#
# ENG-T40: builds the engine benchmark in release, runs it (median of 5 runs, 1,000,000 fuzz events for
# the percentiles, a 10,000,000-event fuzz run for the worst case) and compares the result with the
# baseline after calibration (ENG-R1233, QA-R14). Exit status 1 when the gate fails.
# Usage: Scripts/benchmark.sh [output.json] [extra engine-benchmark arguments...]
set -eu
cd "$(dirname "$0")/.."
output="${1:-.build-release/benchmark-latest.json}"
[ $# -gt 0 ] && shift
swift build -c release --scratch-path .build-release --product engine-benchmark
.build-release/release/engine-benchmark --output "$output" "$@"
python3 -I Benchmarks/compare.py Benchmarks/baseline.json "$output"
