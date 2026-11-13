#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
#
# QA-R2: runs the engine tests with code coverage and fails when the core target's line coverage is
# below 95 %. Uses its own scratch path. Usage: Scripts/coverage.sh [--files]
set -eu
cd "$(dirname "$0")/.."
swift test --enable-code-coverage --scratch-path .build-cov
python3 -I Scripts/coverage.py "$(swift test --enable-code-coverage --scratch-path .build-cov --show-codecov-path)" "$@"
