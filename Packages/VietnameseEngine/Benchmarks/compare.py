#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Performance gate of ENG-R1233 and QA-R14 for the engine benchmark (ENG-T40).

Usage: python3 -I Benchmarks/compare.py BASELINE.json RESULT.json [--tolerance 1.2]

Calibration: both files carry the median time of a fixed reference loop (`referenceNanoseconds`).
factor = result.reference / baseline.reference (> 1 when the machine running the check is slower).
Every latency of the result is divided by the factor, which expresses it on the baseline machine.

The check fails (exit status 1) when, after calibration:
- p50, p99 or p99.9 exceeds the ENG-R1230 budget by more than the tolerance (20 %, ENG-R1233);
- the re-measured worst case of the fuzz run exceeds 1 ms by more than the tolerance;
- p50, p99 or p99.9 is more than the tolerance slower than the baseline (QA-R14). This comparison uses
  `latencyStable`, the percentiles of each event's fastest time over the runs (the same events replay from
  the same states, so the minimum keeps the engine's cost and drops preemption); tail percentiles of the
  median run move with the machine's load, not with the code. Sub-microsecond percentiles are quantised by
  the clock (about 42 ns on Apple silicon), so a slowdown of at most `--noise-floor` nanoseconds (default
  100) is never a failure;
- the bundled resources, when present, load in more than 50 ms or add more than 8 MB (ENG-R1231);
- the commits of the typo correction candidates (ENG-T55), when the result has them, exceed 50 µs at p99 or
  200 µs in the worst case (ENG-R1122) by more than the tolerance. Both read each commit's fastest time over
  the runs (`p99Stable`, `max`): the candidates are a few thousand commits, so the p99 of one run on a shared
  machine is decided by preemption, not by the engine;
- the result does not come from a release build.

`Scripts/benchmark.sh` also runs this check with the result of `--typo-correction off` as the baseline and the
result of `--typo-correction on` as the result: the ENG-T40 percentiles with the switch on must stay within the
tolerance of those with it off (ENG-R1122, ENG-R1233).
"""

import argparse
import json
import sys


def load(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def microseconds(nanoseconds):
    return f"{nanoseconds / 1000:.3f} µs"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("baseline")
    parser.add_argument("result")
    parser.add_argument("--tolerance", type=float, default=1.2)
    parser.add_argument("--noise-floor", type=float, default=100.0)
    args = parser.parse_args()

    baseline = load(args.baseline)
    result = load(args.result)
    budget = result["budget"]
    tolerance = args.tolerance
    factor = result["referenceNanoseconds"] / baseline["referenceNanoseconds"]
    failures = []

    print(f"baseline: {baseline['machine']['cpu']} ({baseline['date']}); result: {result['machine']['cpu']} ({result['date']})")
    print(f"calibration factor {factor:.3f} (reference loop {result['referenceNanoseconds'] / 1e6:.2f} ms vs "
          f"{baseline['referenceNanoseconds'] / 1e6:.2f} ms)")
    if result.get("configuration") != "release":
        failures.append("the result is not from a release build")

    stable_key = "latencyStable" if "latencyStable" in result and "latencyStable" in baseline else "latency"
    print(f"{'metric':<8} {'result':>12} {'calibrated':>12} {'budget':>12} {'stable':>12} {'baseline':>12}")
    for key, label in (("p50", "p50"), ("p99", "p99"), ("p999", "p99.9")):
        value = result["latency"][key]
        calibrated = value / factor
        stable = result[stable_key][key] / factor
        reference = baseline[stable_key][key]
        print(f"{label:<8} {microseconds(value):>12} {microseconds(calibrated):>12} {microseconds(budget[key]):>12} "
              f"{microseconds(stable):>12} {microseconds(reference):>12}")
        if calibrated > budget[key] * tolerance:
            failures.append(f"{label} {microseconds(calibrated)} exceeds the budget {microseconds(budget[key])} "
                            f"by more than {round((tolerance - 1) * 100)} %")
        elif calibrated > budget[key]:
            print(f"warning: {label} is over the budget within the tolerance")
        allowed = max(reference * tolerance, reference + args.noise_floor)
        if stable > allowed:
            failures.append(f"{label} {microseconds(stable)} is more than {round((tolerance - 1) * 100)} % "
                            f"slower than the baseline {microseconds(reference)} ({stable_key})")

    worst = result["worstCase"]["maxRemeasuredNanoseconds"] / factor
    print(f"{'worst':<8} {microseconds(result['worstCase']['maxRemeasuredNanoseconds']):>12} {microseconds(worst):>12} "
          f"{microseconds(budget['max']):>12}")
    if worst > budget["max"] * tolerance:
        failures.append(f"worst case {microseconds(worst)} exceeds {microseconds(budget['max'])}")

    correction = result.get("correction")
    if correction:
        p99_key = "p99Stable" if "p99Stable" in correction else "p99"
        for key, budget_key, label in ((p99_key, "correctionP99", "p99"), ("max", "correctionMax", "max")):
            calibrated = correction[key] / factor
            limit = budget.get(budget_key, 50_000 if key == "p99" else 200_000)
            print(f"{'corr ' + label:<8} {microseconds(correction[key]):>12} {microseconds(calibrated):>12} "
                  f"{microseconds(limit):>12}")
            if calibrated > limit * tolerance:
                failures.append(f"typo correction {label} {microseconds(calibrated)} exceeds {microseconds(limit)}")
            elif calibrated > limit:
                print(f"warning: typo correction {label} is over the budget within the tolerance")
    else:
        print("note: no typo correction figures; ENG-R1122 not checked")

    resources = result["resources"]
    if resources["available"]:
        if resources["coldLoadMilliseconds"] / factor > budget["resourcesLoadMilliseconds"] * tolerance:
            failures.append(f"Resources.bundled loads in {resources['coldLoadMilliseconds']:.1f} ms")
        if resources["residentBytes"] > budget["resourcesResidentBytes"] * tolerance:
            failures.append(f"resources add {resources['residentBytes']} bytes")
    else:
        print("note: bundled resources not available yet; ENG-R1231 not checked")

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1
    print("OK: within budget and baseline")
    return 0


if __name__ == "__main__":
    sys.exit(main())
