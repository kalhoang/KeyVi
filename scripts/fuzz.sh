#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-App-Pending
#
# Coverage-guided fuzzing of the engine with libFuzzer (QA-R8, QA-R9, ENG-T30 to ENG-T37). Runs on Linux,
# where the Swift toolchain ships libFuzzer (`-sanitize=fuzzer`); the macOS toolchain does not.
#   - per PR: 60 s, AddressSanitizer, both input methods (the first byte of each input picks the method)
#   - nightly: 1800 s per input method (--method telex, --method vni), AddressSanitizer + UBSan
#
# Contract with the engine track (docs/decisions/0502-fuzz-benchmark-coverage-contracts.md and
# Packages/VietnameseEngineFuzz/README.md):
#   - package Packages/VietnameseEngineFuzz, executable product engine-fuzz. Built with -DLIBFUZZER it defines
#     LLVMFuzzerTestOneInput; without it, it has its own main that replays files (macOS).
#   - ENGINE_FUZZ_METHOD=telex|vni pins the input method of every input (nightly runs).
#   - seed corpus (QA-R9) in Packages/VietnameseEngineFuzz/Corpus/, read only: new inputs stay in --out.
# Build flags: -sanitize=<list> -parse-as-library -DLIBFUZZER, from the engine README. VERIFY on the Linux
# runner: the engine track could not link libFuzzer on macOS, so the first CI run confirms these flags and
# that the toolchain accepts `undefined` next to `fuzzer,address` (nightly).
# Findings: minimised inputs land in <out>/<run>/minimized-*, and <out>/findings.txt lists "<run>\t<path>",
# where <run> is the product name plus "-<method>" when a method is pinned (for example engine-fuzz-vni).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/fuzz.sh [--seconds N] [--sanitizers LIST] [--method telex|vni]... [--out DIR]

Options:
  --seconds N         time per run (default 60)
  --sanitizers LIST   swiftc -sanitize= list (default fuzzer,address; nightly fuzzer,address,undefined)
  --method NAME       pin the input method with ENGINE_FUZZ_METHOD (telex or vni; repeatable, one run each;
                      default: one run with both methods)
  --product NAME      fuzz product (default engine-fuzz)
  --package DIR       fuzz package (default Packages/VietnameseEngineFuzz)
  --out DIR           output directory (default .build/fuzz-out)
  --require           fail when the fuzz package is missing (default: skip with a warning)
  -h, --help          show this help
Exit status: 0 no findings, 1 findings or build failure.
EOF
}

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

seconds=60
sanitizers="fuzzer,address"
package="$REPO_ROOT/Packages/VietnameseEngineFuzz"
product="engine-fuzz"
out="$REPO_ROOT/.build/fuzz-out"
require=0
methods=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --seconds) seconds="${2:?}"; shift 2 ;;
    --sanitizers) sanitizers="${2:?}"; shift 2 ;;
    --method) methods+=("${2:?}"); shift 2 ;;
    --product) product="${2:?}"; shift 2 ;;
    --package) package="${2:?}"; shift 2 ;;
    --out) out="${2:?}"; shift 2 ;;
    --require) require=1; shift ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ "$seconds" =~ ^[1-9][0-9]*$ ]] || die "--seconds must be a positive integer"
[[ "$sanitizers" =~ ^[a-z,]+$ ]] || die "--sanitizers has an invalid value"
[[ "$product" =~ ^[A-Za-z0-9_-]+$ ]] || die "invalid product name: $product"
for method in ${methods[@]+"${methods[@]}"}; do
  [[ "$method" == "telex" || "$method" == "vni" ]] || die "--method must be telex or vni, not: $method"
done

if [[ ! -f "$package/Package.swift" ]]; then
  [[ $require -eq 1 ]] && die "fuzz package not found at $package"
  warn "fuzz package not found at $package; fuzzing skipped"
  exit 0
fi
if [[ "$(uname -s)" != "Linux" ]]; then
  warn "libFuzzer ships with the Linux Swift toolchain; on $(uname -s) the build may fail"
fi

seeds=()
if [[ -d "$package/Corpus/$product" ]]; then
  seeds+=("$package/Corpus/$product")
elif [[ -d "$package/Corpus" ]]; then
  seeds+=("$package/Corpus")
fi

info "building $product with -sanitize=$sanitizers"
swift build --package-path "$package" -c release --product "$product" \
  -Xswiftc "-sanitize=$sanitizers" -Xswiftc -parse-as-library -Xswiftc -DLIBFUZZER
bin="$(swift build --package-path "$package" -c release --show-bin-path)/$product"

mkdir -p "$out"
: >"$out/findings.txt"
status=0

# Minimises every crash libFuzzer left in <work>/artifacts and lists it in findings.txt.
record_findings() {
  local run="$1" work="$2" crash minimized
  for crash in "$work"/artifacts/*; do
    [[ -f "$crash" ]] || continue
    minimized="$work/minimized-$(basename "$crash")"
    info "minimising $(basename "$crash")"
    "$bin" -minimize_crash=1 -runs=200000 -exact_artifact_path="$minimized" "$crash" >/dev/null 2>&1 \
      || cp "$crash" "$minimized"
    [[ -s "$minimized" ]] || cp "$crash" "$minimized"
    printf '%s\t%s\n' "$run" "$minimized" >>"$out/findings.txt"
  done
}

# One libFuzzer run; $1 is the pinned method or empty for both.
fuzz_once() {
  local method="$1" run="$product${1:+-$1}" work rc
  work="$out/$run"
  rm -rf "$work"
  mkdir -p "$work/corpus" "$work/artifacts"
  info "fuzzing $run for ${seconds}s"
  set +e
  ENGINE_FUZZ_METHOD="$method" "$bin" "$work/corpus" ${seeds[@]+"${seeds[@]}"} \
    -max_total_time="$seconds" -max_len=8192 -timeout=10 -rss_limit_mb=4096 \
    -print_final_stats=1 -artifact_prefix="$work/artifacts/" 2>&1 | tee "$work/fuzz.log" | tail -n 40
  rc=${PIPESTATUS[0]}
  set -e
  if [[ $rc -ne 0 ]]; then
    status=1
    record_findings "$run" "$work"
    warn "$run: libFuzzer exited with status $rc (see $work/fuzz.log)"
  fi
}

if [[ ${#methods[@]} -eq 0 ]]; then
  fuzz_once ""
else
  for method in "${methods[@]}"; do fuzz_once "$method"; done
fi

if [[ $status -ne 0 ]]; then
  die "fuzzing found problems: $(wc -l <"$out/findings.txt" | tr -d ' ') minimised input(s) in $out"
fi
info "fuzzing: no findings"
