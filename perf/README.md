<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Platform performance baselines

`platform-baseline.json` is the stored baseline of the self-hosted platform metrics (PLT-R821, PLT-R822,
QA-R14, QA-R15). Its format is the ADR 0502 `formatVersion` 1 result plus `referenceCalibration`
([ADR 0502](../docs/decisions/0502-fuzz-benchmark-coverage-contracts.md), "formatVersion 1 results"), so both
gates read it: `compat-harness bench` and `compat-harness soak` (Swift, `RegressionGate`) and
`scripts/bench-compare.sh` (CI).

## Placeholder values

Nobody has measured these metrics yet: the self-hosted runner does not exist (open question 3/5 for Pa). Until it
records the first real baseline, every value **equals its gate**, every metric and the document carry
`"placeholder": true`, and the note says so. A placeholder baseline is harmless: a value can only exceed it by more
than 25 % after it already exceeded the gate, so only the gates apply. `bench-compare.sh` ignores the
`placeholder` keys.

## Gate (PLT-R822)

A metric fails when it is above its 8.1 gate (no tolerance), or more than 25 % above the stored baseline. Platform
metrics are never calibrated (`calibrated: false`): the comparison is direct. A zero baseline (T5 flushes) has no
relative change; its zero gate decides. The Swift gate prints one line per metric, for example
`C1.cpuPercent 0.200, gate 0.300, baseline 0.100: REGRESSION (more than 25 % above the baseline)`.

## Metrics

Single source of the numbers: `spec/02-platform.md` section 8.1 (the "Gate" column). Targets are for Apple silicon
(M1 class); the runner must be Apple silicon (Intel targets are 1.5 times the values and are not gated here).

| Name in the file | 8.1 | Unit | Gate | Measured by | Procedure |
|---|---|---|---|---|---|
| `T2.p99` | T2 decide to posted | ms | 3 | `bench`, app histogram `decideToPosted` | Reset the app's metrics (hook `resetMetrics`), type the workload (below) at the normal profile, read the histogram (hook `state`), p99 interpolated inside its gate-aligned sub-bucket |
| `T3.p99` | T3 with `axSelection` | ms | 15 | `bench`, histogram `decideToPostedWithAX` | Same run; the workload's address-bar words use `axSelection` (profile `bench-workload`) |
| `T4.p99` | T4 end-to-end delta | ms | 10 | `bench`, the app's latency probe (PLT-R810) | Hook `latencyProbe` with the normal profile; `endToEndDeltaP99Microseconds` |
| `T5.flushes` | T5 held wait | count | 0 | `bench`, counter `flushes` | Same run as T2: flushes during the normal-profile workload |
| `T6.p95` | T6 focus refresh | ms | 60 | `bench`, histogram `focusRefresh` | Same run: the workload changes the focus every 5 words (Command+1, 2, 3) |
| `C1.cpuPercent` | C1 idle CPU | % of one core | 0.3 | `bench`, `proc_pid_rusage` | Restart the app with its windows closed; CPU time over minutes 5 to 10 after launch |
| `C2.cpuPercent` | C2 typing CPU | % of one core | 3 | `bench`, `proc_pid_rusage` | 10 keys per second of Telex words into TestHost's text view for 5 minutes |
| `M1.footprintMB` | M1 memory at rest | MB | 50 | `bench`, `proc_pid_rusage` | `phys_footprint` 10 minutes after launch (end of the C1 window) |
| `M2.growthMBPerHour` | M2 soak growth | MB/h | 5 | `soak`, `proc_pid_rusage` | Least-squares slope of `phys_footprint` over the 1,000,000-keystroke soak (8.3 hours at the fast profile, 13.6) |

The workload of T2, T3, T5 and T6 is `BenchWorkload` (`--workload-keys`, default 600): soak-corpus Telex words into
TestHost's main field, second-window field and address bar, with a focus change every 5 words. T2, T3, T4, T5 and T6
need the app's integration hooks (the INTEGRATION_HOOKS test build); without them `bench` skips those metrics with a
warning and still gates C1, C2 and M1. A `bench` run takes about 18 minutes per run (5 runs by default).

Log2 buckets (PLT-R801) give a percentile only to within a factor of two (the bucket from 2.1 to 4.2 ms straddles
the 3 ms T2 gate). The decide-to-posted histograms (T2, T3) therefore also count values up to 25 ms in fixed linear
sub-buckets (10 µs to 1 ms, 50 µs to 5 ms, 250 µs to 25 ms, upper end included) whose edges include every 8.1 gate
and target, so "p99 over the gate" is decided exactly; the harness interpolates inside the sub-bucket, and only above
25 ms falls back to the log2 estimate (ADR 0502, "Platform baseline and measurements"). T6 (gate 60 ms) still uses
the log2 estimate.

## Updating the baseline (QA-R15)

Only in a pull request labelled `perf-baseline`, with the reason, from runs on the self-hosted runner class:

```sh
scripts/bench-compare.sh --results .build/integration/platform-bench.json \
  --results .build/integration/soak/soak-metrics.json --baseline perf/platform-baseline.json --update-baseline
```

`--update-baseline` writes the median without the placeholder flags and keeps `referenceCalibration`. Check the
diff: every metric of the table above must still be present.
