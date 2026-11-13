# 0502. Contracts for fuzzing, benchmarks, coverage and the integration harness

- Status: accepted, 2026-11-13
- Requirements: QA-R2, QA-R8, QA-R9, QA-R14, QA-R15, QA-R16, ENG-R1230, ENG-R1233, ENG section 13.6,
  PLT-R820 to PLT-R822

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
  1,000,000 per PR, ENG 13.6). Nightly runs `ENGINE_FUZZ_EVENTS=100000000 swift test -c release --filter
  "Property|Fuzz|Invariant"`, so suite or test names must contain one of those words.

## Engine benchmark (`scripts/bench-compare.sh`, engine track)

- Executable product `engine-benchmark` in `Packages/VietnameseEngine`, run as
  `engine-benchmark --output <file.json>`, release build. The script runs it 5 times and takes the median
  of each metric (QA-R14).
- Result format (`formatVersion` 1):

```json
{
  "formatVersion": 1,
  "benchmark": "engine",
  "calibration": { "name": "reference-loop", "nanoseconds": 1834000 },
  "metrics": {
    "event.p50": { "value": 1200, "unit": "ns", "budget": 5000 },
    "event.p99": { "value": 9800, "unit": "ns", "budget": 25000 },
    "event.p999": { "value": 41000, "unit": "ns", "budget": 100000 },
    "resources.loadMs": { "value": 21, "unit": "ms", "budget": 50, "calibrated": false }
  }
}
```

- `calibration.nanoseconds` is the time of a fixed reference workload that does not change between
  versions (ENG-R1233). Lower is better for every metric. `budget` is the ENG-R1230 value on the reference
  machine (M1). `calibrated: false` turns off scaling for a metric.
- Gate: fail when a metric is more than 20 % above the baseline after scaling the baseline by
  `calibration(current) / calibration(baseline)`, or when it exceeds its budget by more than 20 % after
  scaling the budget by `calibration(current) / referenceCalibration`.
- Baseline: `Packages/VietnameseEngine/Benchmarks/baseline.json` (same format plus `referenceCalibration`,
  the calibration measured on the M1 reference). It changes only in a PR labelled `perf-baseline`
  (QA-R15), written with `scripts/bench-compare.sh --update-baseline`. Without a baseline the gate warns
  and passes.

## Coverage (`scripts/coverage.sh`)

- Line coverage from `swift test --enable-code-coverage`, counted over `<package>/Sources/` only.
- Engine: at least 95 %, excluding `Sources/lexicon-builder`, `Sources/engine-benchmark` and
  `Sources/VietnameseEngineTesting` (tools and test support, not shipped engine code).
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
- `compat-harness bench --runs 5 --output <file.json>`: same `formatVersion` 1 format as the engine
  benchmark, metric names `T1.p99`, `T2.p99`, ... from `02-platform.md` section 8.1, `budget` = the
  "Gate" column, `calibrated: false`. Compared at 25 % (PLT-R822) against
  `Packages/AppCore/Benchmarks/platform-baseline.json`.
- TestHost integration tests run as `xcodebuild test -scheme TestHost` (override with
  `INTEGRATION_SCHEME`).
