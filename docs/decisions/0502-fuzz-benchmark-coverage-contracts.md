# 0502. Contracts for fuzzing, benchmarks, coverage and the integration harness

- Status: accepted, 2026-11-13; amended 2026-11-13 after the engine and wave-1 merges (fuzz product,
  nightly seed, engine benchmark gate, pipeline benchmark, harness environment)
- Requirements: QA-R2, QA-R8, QA-R9, QA-R14, QA-R15, QA-R16, ENG-R1230, ENG-R1231, ENG-R1233, ENG section
  13.6, PLT-R820 to PLT-R822

The CI scripts call code that other tracks write. These are the names and formats the scripts expect.

## Fuzzing (`scripts/fuzz.sh`, engine track)

Amended 2026-11-13 after the engine merge: one product with a method switch replaces the two products
(`fuzz-telex`, `fuzz-vni`) of the first version, and the seeds live in one folder.

- Package `Packages/VietnameseEngineFuzz` (MPL-2.0), executable product `engine-fuzz`. Built with `-DLIBFUZZER`
  it defines `LLVMFuzzerTestOneInput`; without the flag it has a `main` that replays files and runs seeded
  mutations (macOS, whose toolchain has no libFuzzer). The first byte of each input selects the method and
  the options (`Packages/VietnameseEngineFuzz/README.md`, "Input format"); `ENGINE_FUZZ_METHOD=telex|vni`
  pins the method.
- Build on Linux (the script passes these flags). VERIFY on the first CI run: the engine track could not link
  libFuzzer on macOS, and whether the toolchain accepts `undefined` next to `fuzzer,address` is open.

```sh
swift build --package-path Packages/VietnameseEngineFuzz -c release --product engine-fuzz \
  -Xswiftc -sanitize=fuzzer,address[,undefined] -Xswiftc -parse-as-library -Xswiftc -DLIBFUZZER
```

- Seed corpus in `Packages/VietnameseEngineFuzz/Corpus/` (QA-R9); a `Corpus/<product>/` folder takes
  precedence if one is ever added. The script copies nothing into the repository; new corpus entries stay in
  `.build/fuzz-out`. libFuzzer options: `-max_len=8192 -timeout=10 -rss_limit_mb=4096` (engine README).
- Per PR (`ci.yml`, job `Engine on Linux`): `scripts/fuzz.sh --seconds 60 --sanitizers fuzzer,address
  --require`, both methods in one run. Nightly (`nightly.yml`): `scripts/fuzz.sh --seconds 1800 --sanitizers
  fuzzer,address,undefined --method <telex|vni> --require`, one job per method (QA-R8: 30 minutes per
  method). Minimised inputs open issues (`scripts/fuzz-report-issue.sh`) named after the run
  (`engine-fuzz-telex`, `engine-fuzz-vni`; `engine-fuzz` for the mixed PR run).
- Without `--require` a missing package only warns. CI passes `--require` now that the package exists, so a
  missing package or a failed build fails the job.

## Property runs (engine track)

- Property and fuzz-invariant suites read the event count from `ENGINE_FUZZ_EVENTS` (default at least
  1,000,000 per PR, ENG 13.6) and a seed offset from `ENGINE_FUZZ_SEED` (default 0, so pull requests replay
  the same streams). Nightly runs `ENGINE_FUZZ_EVENTS=100000000 ENGINE_FUZZ_SEED=<UTC date, YYYYMMDD> swift
  test -c release --filter "Property|Fuzz|Invariant"`, so suite or test names must contain one of those
  words; `FuzzTests` is the suite that reads both variables. A manual run of `nightly.yml` takes the seed of a
  failing night as the `fuzz-seed` input, and the job summary prints the replay command (amended
  2026-11-13: the seed was never set before, so every night replayed the same streams).

## Engine benchmark (`Packages/VietnameseEngine/Scripts/benchmark.sh`, engine track)

Amended 2026-11-13 after the engine merge: the engine benchmark keeps its own, richer result format and its
own calibrated gate. `scripts/bench-compare.sh` no longer runs it (it skipped silently before, because
`engine-benchmark` is an executable target, not a declared product, and its JSON is not `formatVersion` 1).

- Executable target `engine-benchmark` in `Packages/VietnameseEngine`, built in release
  (`swift build --product engine-benchmark` works in the root package). `Scripts/benchmark.sh [output.json]`
  builds it, runs it (median of 5 runs, 1,000,000 fuzz events for the percentiles, a 10,000,000-event run
  for the worst case) and compares the result with `Benchmarks/baseline.json` through
  `Benchmarks/compare.py`. Exit status 1 fails the gate (ENG-R1233, QA-R14).
- Result format (the fields `Benchmarks/compare.py` reads): `configuration` (must be `release`),
  `referenceNanoseconds` (time of a fixed reference loop, the calibration), `latency` and `latencyStable`
  (`p50`, `p99`, `p999`, `max`, `events`), `worstCase.maxRemeasuredNanoseconds`, `budget` (the ENG-R1230
  values), `resources` (cold load and resident bytes, ENG-R1231) and `machine`.
- Gate: factor = `result.referenceNanoseconds / baseline.referenceNanoseconds`. After dividing by the factor
  it fails when p50, p99 or p99.9 exceeds its budget by more than 20 %, the re-measured worst case exceeds
  1 ms by more than 20 %, a `latencyStable` percentile is more than 20 % slower than the baseline (with a
  100 ns noise floor), the bundled resources load in more than 50 ms or add more than 8 MB, or the result is
  not from a release build.
- CI: job `benchmarks` of `ci.yml` on the `xcode-27` runner class (QA-R14: same runner class every time),
  JSON kept as the `benchmarks` artefact. Baseline: `Packages/VietnameseEngine/Benchmarks/baseline.json`,
  changed only in a `perf-baseline` PR (QA-R15). The committed baseline comes from a development M4 and is
  to be re-recorded on the CI runner class (engine track).

## formatVersion 1 results (`scripts/bench-compare.sh`)

Used by the PLT-R820 pipeline benchmark on hosted CI and by the platform benchmarks of the self-hosted
runner (`compat-harness bench`, below).

```json
{
  "formatVersion": 1,
  "benchmark": "pipeline",
  "calibration": { "name": "reference-loop", "nanoseconds": 1834000 },
  "metrics": {
    "T1.p50": { "value": 1200, "unit": "ns", "calibrated": false },
    "T1.p99": { "value": 9800, "unit": "ns", "budget": 100000, "calibrated": false },
    "T1.p999": { "value": 41000, "unit": "ns", "calibrated": false }
  }
}
```

- `calibration.nanoseconds` is the time of a fixed reference workload that does not change between
  versions. Lower is better for every metric. `budget` is the gate value; `calibrated: false` turns off
  scaling for a metric (platform metrics are never calibrated).
- Gate (`--threshold`, default 20 %, PLT-R822 uses 25 %): fail when a metric is more than the threshold
  above the baseline (scaled by `calibration(current) / calibration(baseline)` for calibrated metrics), or
  when it exceeds its budget by more than the threshold (scaled by `calibration(current) /
  referenceCalibration` for calibrated metrics). The step summary is titled after `benchmark`. Without a
  baseline the comparison warns, and the budgets still gate.
- Baselines: the same format plus `referenceCalibration`, changed only in a `perf-baseline` PR (QA-R15),
  written with `scripts/bench-compare.sh --results <run files> --baseline <file> --update-baseline`.
  `Packages/AppCore/Benchmarks/pipeline-baseline.json` (pipeline; not committed yet, to be recorded from the
  CI runs) and `Packages/AppCore/Benchmarks/platform-baseline.json` (platform).
- `--run --package <dir> --product <name>` builds a product that writes this format with `--output FILE` and
  runs it 5 times; it refuses to run without `--product`.

## Pipeline benchmark (PLT-R820, PLT-R822, platform track)

- `PipelineBenchmarkTests` (`Packages/AppCore/Tests/InputHostTests/Pipeline/PipelineHotPathTests.swift`)
  times the tap callback (T1) with the fake engine factory, the fake poster side and the real seams over
  20,000 events, and writes `formatVersion` 1 (`benchmark: pipeline`; metrics `T1.p50`, `T1.p99` with the
  100 microsecond gate of 02-platform.md 8.1, `T1.p999`, `T1.edit.p50`, `T1.edit.p99`, all
  `calibrated: false`) to `PIPELINE_BENCH_OUTPUT` when it is set.
- CI (`ci.yml` job `benchmarks`): five runs of
  `PIPELINE_BENCH_OUTPUT=<run-N.json> swift test --package-path Packages/AppCore -c release --filter PipelineBenchmark`,
  then `scripts/bench-compare.sh --results <the five files> --threshold 25 --baseline
  Packages/AppCore/Benchmarks/pipeline-baseline.json`.

## Coverage (`scripts/coverage.sh`)

- Line coverage from `swift test --enable-code-coverage`, counted over `<package>/Sources/` only.
- Engine: at least 95 %, excluding `Sources/lexicon-builder`, `Sources/engine-benchmark` and
  `Sources/VietnameseEngineTesting` (tools and test support, not shipped engine code). The engine's own
  core gate, `Packages/VietnameseEngine/Scripts/coverage.py` (95 % of `Sources/VietnameseEngine`, the gate
  of `Scripts/coverage.sh`), reads the same coverage export, so the engine tests run once.
- AppCore: at least 80 %, excluding `Sources/CompatHarness` and `Sources/TestSupport`.
- On PRs the summary of the latest green `main` run (artifact `coverage-summary`) is the baseline; a drop
  of more than 1 point fails (QA-R2).

## Integration harness (`scripts/run-integration.sh`, platform track)

Default command lines (overridable with `COMPAT_HARNESS_RUN_ARGS`, `COMPAT_HARNESS_SOAK_ARGS`,
`COMPAT_HARNESS_BENCH_ARGS`). The executable product is `compat-harness` (target `CompatHarness`);
`swift run` needs the product name. The live commands (`run` without `--dry-run`, `soak`, `bench`) need:

- `COMPAT_HARNESS_LIVE=1` in the environment, exported only on the self-hosted macOS runner and preferably
  from the runner's own `.env` file, never from a workflow (runner runbook section 3.1). It ties the opt-in to
  the machine: without it the harness exits 3 before it posts an event, launches an app or changes an input
  source, and `scripts/run-integration.sh` stops before the release build.
- chromedriver on its default endpoint `http://127.0.0.1:9515`: every `webdriver` scenario without a
  `--webdriver BUNDLE=URL` entry uses it, and the command lines below pass no `--webdriver`. Other drivers
  need `--webdriver` through the override variables (runner runbook section 3.2,
  `compat/scenarios/README.md`).

```sh
# Self-hosted runner only. Environment: COMPAT_HARNESS_LIVE=1 (runner .env). WebDriver: http://127.0.0.1:9515.
swift run --package-path Packages/AppCore -c release compat-harness run --scenarios compat/scenarios --output <dir>
swift run --package-path Packages/AppCore -c release compat-harness soak --keystrokes 1000000 --output <dir>
swift run --package-path Packages/AppCore -c release compat-harness bench --runs 5 --output <file.json>
```

- `compat-harness run --scenarios compat/scenarios --output <dir>`
- `compat-harness run --scenarios compat/scenarios --dry-run`: hosted CI (`scripts/compat-dry-run.sh`,
  step of `ci.yml` skipped until `compat/scenarios` exists; override with `COMPAT_HARNESS_DRY_RUN_ARGS`,
  which must keep `--dry-run`). Loads every scenario and prints the plan, posts no event.
- `compat-harness soak --keystrokes 1000000 --output <dir>`
- `compat-harness bench --runs 5 --output <file.json>`: `formatVersion` 1 (above), metric names `T1.p99`, `T2.p99`, ... from `02-platform.md` section 8.1, `budget` = the
  "Gate" column, `calibrated: false`. Compared at 25 % (PLT-R822) against
  `Packages/AppCore/Benchmarks/platform-baseline.json`.
- TestHost integration tests run as `xcodebuild test -scheme TestHost` (override with
  `INTEGRATION_SCHEME`).
