#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
#
# Prints per-event latency of the engine in a release build (ENG-R1230 sanity check, not a gate;
# ENG-T40 owns the calibrated benchmark). Uses its own scratch path so it never disturbs debug builds.
# Usage: Scripts/bench-composition.sh   (from Packages/VietnameseEngine or any directory)
set -eu
cd "$(dirname "$0")/.."
swift test -c release --scratch-path .build-release --filter EngineBenchmarkTests 2>&1 | grep -E '\[ENG-R1230\]|error'
