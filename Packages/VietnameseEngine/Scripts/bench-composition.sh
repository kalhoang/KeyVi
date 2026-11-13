#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
#
# Quick per-event latency figures from the debug-test microbenchmark in a release build (a sanity check,
# not the gate). The calibrated ENG-T40 benchmark and its gate are Scripts/benchmark.sh.
# Usage: Scripts/bench-composition.sh   (from Packages/VietnameseEngine or any directory)
set -eu
cd "$(dirname "$0")/.."
swift test -c release --scratch-path .build-release --filter EngineBenchmarkTests 2>&1 | grep -E '\[ENG-R1230\]|error'
