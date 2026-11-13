#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-App-Pending
#
# Benchmark gate for results in formatVersion 1 (QA-R14, PLT-R822; format in
# docs/decisions/0502-fuzz-benchmark-coverage-contracts.md). Takes the median of several result files
# (--results, or --run builds a product and runs it 5 times) and compares it with the baseline file:
#   - regression: fail when a metric is more than --threshold percent slower than the baseline, after
#     calibration for calibrated metrics (both runs time the same fixed reference workload)
#   - budget: fail when a metric exceeds its budget by more than --threshold percent, after scaling the
#     budget from the reference machine to this one for calibrated metrics
# Users: the PLT-R820 pipeline benchmark on hosted CI (`swift test -c release --filter PipelineBenchmark`
# with PIPELINE_BENCH_OUTPUT, threshold 25 %) and the platform benchmarks of scripts/run-integration.sh.
# The engine benchmark (ENG-T40) writes its own format and has its own calibrated gate:
# Packages/VietnameseEngine/Scripts/benchmark.sh.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/bench-compare.sh [--run | --results FILE...] [options]

Modes:
  --results FILE        use existing formatVersion 1 result files (repeatable; the median is taken)
  --run                 build and run --product of --package (default when no --results is given); the
                        product must write formatVersion 1 with `--output FILE`

Options:
  --package DIR         SwiftPM package of the benchmark product (needed by --run)
  --product NAME        executable product that writes formatVersion 1 (needed by --run, env BENCH_PRODUCT).
                        The engine benchmark is not one: use Packages/VietnameseEngine/Scripts/benchmark.sh
  --runs N              runs for the median (default 5, QA-R14)
  --baseline FILE       baseline JSON (default <package>/Benchmarks/baseline.json; required without --package)
  --threshold PERCENT   allowed regression and budget overshoot (default 20; PLT-R822 uses 25)
  --output FILE         write the median result here (default .build/bench/median.json)
  --update-baseline     write the median as the new baseline (only in a perf-baseline PR, QA-R15)
  --require             fail instead of skipping when the product or baseline is missing
  -h, --help            show this help
EOF
}

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

package=""
product="${BENCH_PRODUCT:-}"
runs=5
baseline=""
threshold=20
output=""
update=0
require=0
results=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --run) shift ;;
    --results) results+=("${2:?}"); shift 2 ;;
    --package) package="${2:?}"; shift 2 ;;
    --product) product="${2:?}"; shift 2 ;;
    --runs) runs="${2:?}"; shift 2 ;;
    --baseline) baseline="${2:?}"; shift 2 ;;
    --threshold) threshold="${2:?}"; shift 2 ;;
    --output) output="${2:?}"; shift 2 ;;
    --update-baseline) update=1; shift ;;
    --require) require=1; shift ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ "$runs" =~ ^[1-9][0-9]*$ ]] || die "--runs must be a positive integer"
usage_error() {
  log "bench-compare: $1"
  exit 2
}
if [[ -z "$baseline" ]]; then
  [[ -n "$package" ]] || usage_error "--baseline is required without --package"
  baseline="$package/Benchmarks/baseline.json"
fi
output="${output:-$REPO_ROOT/.build/bench/median.json}"
mkdir -p "$(dirname "$output")"

skip_or_die() {
  if [[ $require -eq 1 ]]; then die "$1"; fi
  warn "$1; benchmark gate skipped"
  exit 0
}

if [[ ${#results[@]} -eq 0 ]]; then
  [[ -f "$package/Package.swift" ]] || skip_or_die "benchmark package not found at ${package:-(no --package)}"
  [[ -n "$product" ]] || usage_error "--run needs --product, a product that writes formatVersion 1 results \
(the engine benchmark has its own gate: Packages/VietnameseEngine/Scripts/benchmark.sh)"
  products="$(swift package --package-path "$package" describe --type json 2>/dev/null \
    | py -c 'import json,sys; print("\n".join(p["name"] for p in json.load(sys.stdin).get("products", [])))' \
    || true)"
  grep -qx "$product" <<<"$products" || skip_or_die "benchmark product '$product' not found in $package"
  info "building $product (release)"
  swift build --package-path "$package" -c release --product "$product"
  bin="$(swift build --package-path "$package" -c release --show-bin-path)/$product"
  rundir="$(dirname "$output")/runs"
  rm -rf "$rundir"
  mkdir -p "$rundir"
  for i in $(seq 1 "$runs"); do
    info "benchmark run $i/$runs"
    "$bin" --output "$rundir/run-$i.json"
    results+=("$rundir/run-$i.json")
  done
fi

if [[ ! -f "$baseline" && $update -eq 0 ]]; then
  [[ $require -eq 1 ]] && die "baseline not found: $baseline"
  warn "baseline not found: $baseline (create it in a perf-baseline PR with --update-baseline)"
fi

py - "$baseline" "$threshold" "$output" "$update" "${results[@]}" <<'PY'
import json
import os
import statistics
import sys

baseline_path, threshold, output, update, *result_files = sys.argv[1:]
threshold = float(threshold) / 100.0


def load(path):
    with open(path, encoding="utf-8") as handle:
        doc = json.load(handle)
    if doc.get("formatVersion") != 1 or not isinstance(doc.get("metrics"), dict):
        raise SystemExit(f"bench-compare: {path} is not a formatVersion 1 benchmark result")
    calibration = float(doc.get("calibration", {}).get("nanoseconds", 0) or 0)
    if calibration <= 0:
        raise SystemExit(f"bench-compare: {path} has no positive calibration.nanoseconds")
    return doc


runs = [load(path) for path in result_files]
names = sorted(set().union(*(run["metrics"].keys() for run in runs)))
median = {
    "formatVersion": 1,
    "benchmark": runs[0].get("benchmark") or "unnamed",
    "runs": len(runs),
    "calibration": {
        "name": runs[0].get("calibration", {}).get("name", "reference"),
        "nanoseconds": statistics.median(float(r["calibration"]["nanoseconds"]) for r in runs),
    },
    "metrics": {},
}
for name in names:
    entries = [r["metrics"][name] for r in runs if name in r["metrics"]]
    first = entries[0]
    metric = {"value": statistics.median(float(e["value"]) for e in entries), "unit": first.get("unit", "ns")}
    for key in ("budget", "calibrated"):
        if key in first:
            metric[key] = first[key]
    median["metrics"][name] = metric
with open(output, "w", encoding="utf-8") as handle:
    json.dump(median, handle, indent=2, sort_keys=True)
    handle.write("\n")

if update == "1":
    if os.path.exists(baseline_path):
        with open(baseline_path, encoding="utf-8") as handle:
            reference = json.load(handle).get("referenceCalibration")
    else:
        reference = None
    new_baseline = dict(median)
    new_baseline["referenceCalibration"] = reference or median["calibration"]
    os.makedirs(os.path.dirname(baseline_path), exist_ok=True)
    with open(baseline_path, "w", encoding="utf-8") as handle:
        json.dump(new_baseline, handle, indent=2, sort_keys=True)
        handle.write("\n")
    print(f"bench-compare: baseline written to {baseline_path} (commit it in a perf-baseline PR, QA-R15)")
    sys.exit(0)

current_cal = median["calibration"]["nanoseconds"]
baseline = None
if os.path.exists(baseline_path):
    baseline = load(baseline_path)
base_cal = float(baseline["calibration"]["nanoseconds"]) if baseline else None
reference = (baseline or {}).get("referenceCalibration") or (baseline or {}).get("calibration")
ref_cal = float(reference["nanoseconds"]) if reference else None

def fmt(value):
    return "n/a" if value is None else f"{value:.1f}"


rows = ["| Metric | Median | Baseline (scaled) | Change | Budget (scaled) | Result |",
        "|---|---|---|---|---|---|"]
failures = []
for name, metric in median["metrics"].items():
    value = metric["value"]
    calibrated = metric.get("calibrated", True)
    scaled_base = change = scaled_budget = None
    verdict = "ok"
    if baseline and name in baseline["metrics"]:
        ratio = current_cal / base_cal if calibrated else 1.0
        scaled_base = float(baseline["metrics"][name]["value"]) * ratio
        if scaled_base > 0:
            change = value / scaled_base - 1.0
            if change > threshold:
                verdict = "REGRESSION"
                failures.append(f"{name}: {change:+.1%} against the calibrated baseline (max +{threshold:.0%})")
    budget = metric.get("budget")
    if budget is not None:
        ratio = current_cal / ref_cal if (calibrated and ref_cal) else 1.0
        scaled_budget = float(budget) * ratio
        if value > scaled_budget * (1.0 + threshold):
            verdict = "OVER BUDGET"
            failures.append(f"{name}: {value:.0f} {metric['unit']} exceeds the scaled budget "
                            f"{scaled_budget:.0f} by more than {threshold:.0%}")
    rows.append(f"| `{name}` | {value:.1f} {metric['unit']} | {fmt(scaled_base)} | "
                f"{'n/a' if change is None else f'{change:+.1%}'} | {fmt(scaled_budget)} | {verdict} |")

title = str(median["benchmark"]).capitalize()
text = (f"### {title} benchmark (median of {len(runs)} runs)\n\n"
        f"Calibration: {current_cal:.0f} ns (baseline {fmt(base_cal)} ns, reference {fmt(ref_cal)} ns).\n\n"
        + "\n".join(rows) + "\n")
print(text)
summary = os.environ.get("GITHUB_STEP_SUMMARY")
if summary:
    with open(summary, "a", encoding="utf-8") as handle:
        handle.write(text)
for failure in failures:
    print(("::error::" if os.environ.get("GITHUB_ACTIONS") else "error: ") + failure, file=sys.stderr)
sys.exit(1 if failures else 0)
PY
