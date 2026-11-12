#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-App-Pending
#
# Coverage-guided fuzzing of the engine with libFuzzer (QA-R8, ENG-T30 to ENG-T37). Runs on Linux,
# where the Swift toolchain ships libFuzzer (`-sanitize=fuzzer`).
#   - per PR: 60 s per fuzz target, AddressSanitizer
#   - nightly: 1800 s per target (one target per input method), AddressSanitizer + UBSan
#
# Contract with the engine track (docs/decisions/0502-fuzz-benchmark-coverage-contracts.md):
#   - package Packages/VietnameseEngineFuzz, one executable product per input method named fuzz-<x>
#     (fuzz-telex, fuzz-vni), each defining LLVMFuzzerTestOneInput
#   - seed corpus (QA-R9) in Packages/VietnameseEngineFuzz/Corpus/<product>/
# Findings: minimised inputs land in <out>/<product>/minimized-*; <out>/findings.txt lists them.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/fuzz.sh [--seconds N] [--sanitizers LIST] [--product NAME]... [--out DIR]

Options:
  --seconds N         time per target (default 60)
  --sanitizers LIST   swiftc -sanitize= list (default fuzzer,address; nightly fuzzer,address,undefined)
  --product NAME      fuzz product to run (repeatable; default every product named fuzz-*)
  --package DIR       fuzz package (default Packages/VietnameseEngineFuzz)
  --out DIR           output directory (default .build/fuzz-out)
  --require           fail when the fuzz package or products are missing (default: skip with a warning)
  -h, --help          show this help
Exit status: 0 no findings, 1 findings or build failure.
EOF
}

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

seconds=60
sanitizers="fuzzer,address"
package="$REPO_ROOT/Packages/VietnameseEngineFuzz"
out="$REPO_ROOT/.build/fuzz-out"
require=0
products=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --seconds) seconds="${2:?}"; shift 2 ;;
    --sanitizers) sanitizers="${2:?}"; shift 2 ;;
    --product) products+=("${2:?}"); shift 2 ;;
    --package) package="${2:?}"; shift 2 ;;
    --out) out="${2:?}"; shift 2 ;;
    --require) require=1; shift ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ "$seconds" =~ ^[1-9][0-9]*$ ]] || die "--seconds must be a positive integer"
[[ "$sanitizers" =~ ^[a-z,]+$ ]] || die "--sanitizers has an invalid value"

skip_or_die() {
  if [[ $require -eq 1 ]]; then die "$1"; fi
  warn "$1; fuzzing skipped"
  exit 0
}

[[ -f "$package/Package.swift" ]] || skip_or_die "fuzz package not found at $package"
if [[ "$(uname -s)" != "Linux" ]]; then
  warn "libFuzzer ships with the Linux Swift toolchain; on $(uname -s) the build may fail"
fi

if [[ ${#products[@]} -eq 0 ]]; then
  while IFS= read -r p; do products+=("$p"); done < <(
    swift package --package-path "$package" describe --type json \
      | py -c 'import json,sys
for p in json.load(sys.stdin).get("products", []):
    if p["name"].startswith("fuzz") and "executable" in p.get("type", {}):
        print(p["name"])'
  )
fi
[[ ${#products[@]} -gt 0 ]] || skip_or_die "no fuzz-* executable products in $package"

mkdir -p "$out"
: >"$out/findings.txt"
status=0
for product in "${products[@]}"; do
  [[ "$product" =~ ^[A-Za-z0-9_-]+$ ]] || die "invalid product name: $product"
  info "building $product with -sanitize=$sanitizers"
  swift build --package-path "$package" -c release --product "$product" \
    -Xswiftc "-sanitize=$sanitizers" -Xswiftc -parse-as-library
  bin="$(swift build --package-path "$package" -c release --show-bin-path)/$product"
  work="$out/$product"
  rm -rf "$work"
  mkdir -p "$work/corpus" "$work/artifacts"
  seeds="$package/Corpus/$product"
  seed_args=()
  [[ -d "$seeds" ]] && seed_args+=("$seeds")
  info "fuzzing $product for ${seconds}s"
  set +e
  "$bin" "$work/corpus" ${seed_args[@]+"${seed_args[@]}"} \
    -max_total_time="$seconds" -timeout=2 -rss_limit_mb=4096 -max_len=4096 \
    -print_final_stats=1 -artifact_prefix="$work/artifacts/" 2>&1 | tee "$work/fuzz.log" | tail -n 40
  rc=${PIPESTATUS[0]}
  set -e
  if [[ $rc -ne 0 ]]; then
    status=1
    for crash in "$work"/artifacts/*; do
      [[ -f "$crash" ]] || continue
      minimized="$work/minimized-$(basename "$crash")"
      info "minimising $(basename "$crash")"
      "$bin" -minimize_crash=1 -runs=200000 -exact_artifact_path="$minimized" "$crash" >/dev/null 2>&1 \
        || cp "$crash" "$minimized"
      [[ -s "$minimized" ]] || cp "$crash" "$minimized"
      printf '%s\t%s\n' "$product" "$minimized" >>"$out/findings.txt"
    done
    warn "$product: libFuzzer exited with status $rc (see $work/fuzz.log)"
  fi
done

if [[ $status -ne 0 ]]; then
  die "fuzzing found problems: $(wc -l <"$out/findings.txt" | tr -d ' ') minimised input(s) in $out"
fi
info "fuzzing: no findings"
