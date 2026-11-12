#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-App-Pending
#
# QA-R2 line coverage gate for one SwiftPM package: engine at least 95 %, app logic at least 80 %,
# and a drop of more than 1 point against a baseline summary fails.
#
# Runs `swift test --enable-code-coverage` (unless --no-test), reads the llvm-cov JSON export that
# SwiftPM writes, and counts only files under <package>/Sources/ minus --exclude (executables and
# test-support targets that are not product code).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/coverage.sh --package DIR --min PERCENT [options]

Options:
  --package DIR        SwiftPM package directory (for example Packages/VietnameseEngine)
  --min PERCENT        minimum line coverage, for example 95
  --exclude REGEX      extended regex of source paths to leave out (relative to the package)
  --baseline FILE      previous summary JSON; fail when coverage drops by more than --max-drop
  --max-drop POINTS    allowed drop against the baseline (default 1.0, QA-R2)
  --summary-out FILE   write the summary JSON here (default: <package>/.build/coverage-summary.json)
  --scratch-path DIR   pass --scratch-path to swift test
  --no-test            do not run the tests; reuse the last coverage export
  -h, --help           show this help

Environment: SWIFT_TEST_ARGS adds arguments to `swift test` (for example "--parallel").
EOF
}

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

package=""
min=""
exclude=""
baseline=""
max_drop="1.0"
summary_out=""
scratch=()
run_tests=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --package) package="${2:?}"; shift 2 ;;
    --min) min="${2:?}"; shift 2 ;;
    --exclude) exclude="${2:?}"; shift 2 ;;
    --baseline) baseline="${2:?}"; shift 2 ;;
    --max-drop) max_drop="${2:?}"; shift 2 ;;
    --summary-out) summary_out="${2:?}"; shift 2 ;;
    --scratch-path) scratch=(--scratch-path "${2:?}"); shift 2 ;;
    --no-test) run_tests=0; shift ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ -n "$package" && -n "$min" ]] || { usage >&2; exit 2; }
[[ -f "$package/Package.swift" ]] || die "not a SwiftPM package: $package"
package="$(cd "$package" && pwd)"
summary_out="${summary_out:-$package/.build/coverage-summary.json}"

extra=()
if [[ -n "${SWIFT_TEST_ARGS:-}" ]]; then
  read -r -a extra <<<"$SWIFT_TEST_ARGS"
fi

if [[ $run_tests -eq 1 ]]; then
  info "swift test --enable-code-coverage ($package)"
  swift test --package-path "$package" ${scratch[@]+"${scratch[@]}"} --enable-code-coverage \
    ${extra[@]+"${extra[@]}"}
fi
codecov_json="$(swift test --package-path "$package" ${scratch[@]+"${scratch[@]}"} --show-codecov-path)"
[[ -f "$codecov_json" ]] || die "coverage export not found: $codecov_json (run without --no-test)"
mkdir -p "$(dirname "$summary_out")"

py - "$codecov_json" "$package" "$min" "$exclude" "$baseline" "$max_drop" "$summary_out" <<'PY'
import json
import os
import re
import sys

codecov, package, minimum, exclude, baseline, max_drop, summary_out = sys.argv[1:]
minimum = float(minimum)
max_drop = float(max_drop)
sources = os.path.join(package, "Sources") + os.sep
exclude_re = re.compile(exclude) if exclude else None

with open(codecov, encoding="utf-8") as handle:
    export = json.load(handle)
files = []
for block in export.get("data", []):
    for entry in block.get("files", []):
        name = entry.get("filename", "")
        real = os.path.realpath(name)
        if not real.startswith(os.path.realpath(sources)):
            continue
        rel = os.path.relpath(real, package)
        if exclude_re and exclude_re.search(rel):
            continue
        lines = entry.get("summary", {}).get("lines", {})
        files.append((rel, int(lines.get("count", 0)), int(lines.get("covered", 0))))

total = sum(count for _, count, _ in files)
covered = sum(cov for _, _, cov in files)
percent = 100.0 * covered / total if total else 100.0
summary = {"package": os.path.basename(package), "linesTotal": total, "linesCovered": covered,
           "percent": round(percent, 2), "files": len(files)}
with open(summary_out, "w", encoding="utf-8") as handle:
    json.dump(summary, handle, indent=2)
    handle.write("\n")

worst = sorted(files, key=lambda item: (item[2] / item[1]) if item[1] else 1.0)[:10]
report = [f"### Coverage: {summary['package']}", "",
          f"Line coverage **{percent:.2f} %** ({covered}/{total} lines, {len(files)} files), "
          f"minimum {minimum:.0f} %.", "", "| Lowest files | Lines | Covered |", "|---|---|---|"]
report += [f"| `{rel}` | {count} | {100.0 * cov / count:.1f} % |" for rel, count, cov in worst if count]
failures = []
if total and percent + 1e-9 < minimum:
    failures.append(f"line coverage {percent:.2f} % is below the minimum {minimum:.0f} % (QA-R2)")
if baseline and os.path.exists(baseline):
    with open(baseline, encoding="utf-8") as handle:
        previous = float(json.load(handle).get("percent", 0.0))
    report.append("")
    report.append(f"Baseline {previous:.2f} %, change {percent - previous:+.2f} points.")
    if previous - percent > max_drop + 1e-9:
        failures.append(f"coverage dropped {previous - percent:.2f} points (max {max_drop}, QA-R2)")
elif baseline:
    report.append("")
    report.append("No baseline summary available; drop check skipped.")

text = "\n".join(report) + "\n"
print(text)
step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
if step_summary:
    with open(step_summary, "a", encoding="utf-8") as handle:
        handle.write(text)
for failure in failures:
    prefix = "::error::" if os.environ.get("GITHUB_ACTIONS") else "error: "
    print(prefix + failure, file=sys.stderr)
if total == 0:
    print("warning: no source lines found under Sources/ (nothing measured)", file=sys.stderr)
sys.exit(1 if failures else 0)
PY
