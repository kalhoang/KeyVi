# 0502. Contracts for fuzzing, benchmarks, coverage and the integration harness

- Status: accepted, 2026-11-13; amended 2026-11-13 after the engine and wave-1 merges (fuzz product,
  nightly seed, engine benchmark gate, pipeline benchmark, harness environment); amended 2026-11-13 by W2-E2
  (platform baseline in `perf/`, M2 from the soak, integration hooks, app profiles, privacy canary, egress
  command); amended 2026-11-13 by W3-A (the app side of the hooks in the `Integration` configuration, the release
  check, `testHook` in the scenario schema, gate-aligned histogram sub-buckets, the `build` and `tests` subcommands);
  where each gate runs: [ADR 0506](0506-ci-coverage-after-the-engine-merge.md)
- Requirements: QA-R2, QA-R8, QA-R9, QA-R11, QA-R14, QA-R15, QA-R16, ENG-R1230, ENG-R1231, ENG-R1233, ENG
  section 13.6, PLT-R330, PLT-R398B, PLT-R730, PLT-R801, PLT-R820 to PLT-R822, PLT-R901, PLT-R906, PLT-R909

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
  CI runs) and `perf/platform-baseline.json` (platform; amended by W2-E2, it was
  `Packages/AppCore/Benchmarks/platform-baseline.json`, see "Platform baseline" below).
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

Default command lines (overridable with `COMPAT_HARNESS_TESTS_ARGS`, `COMPAT_HARNESS_RUN_ARGS`,
`COMPAT_HARNESS_SOAK_ARGS`, `COMPAT_HARNESS_BENCH_ARGS`; `COMPAT_HARNESS_BENCH_RUNS` sets the bench runs, default 5).
The executable product is `compat-harness` (target `CompatHarness`); `swift run` needs the product name. The live
commands (`run` without `--dry-run`, `soak`, `bench`) and the `build` subcommand of `scripts/run-integration.sh`
need:

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
- `compat-harness bench --runs 5 --output <file.json>`: `formatVersion` 1 (above), metric names `T2.p99`,
  `T3.p99`, `T4.p99`, `T5.flushes`, `T6.p95`, `C1.cpuPercent`, `C2.cpuPercent`, `M1.footprintMB` from
  `02-platform.md` section 8.1, `budget` = the "Gate" column, `calibrated: false`. Compared at 25 % (PLT-R822)
  against `perf/platform-baseline.json` (the harness itself and `scripts/bench-compare.sh`).
- TestHost integration tests (QA-R11): `compat-harness run --scenarios compat/scenarios --only 'testhost.*'
  --output <dir>`, the `tests` subcommand of `scripts/run-integration.sh` since W3-A (the TestHost scheme has no
  test action, so the earlier `xcodebuild test -scheme TestHost` could not run).
- The test build (W3-A): `scripts/run-integration.sh build` runs `xcodegen generate`, then
  `xcodebuild -scheme App -configuration Integration` and `xcodebuild -scheme TestHost -configuration Debug`
  (both `-disableAutomaticPackageResolution ONLY_ACTIVE_ARCH=YES`: on the command line the setting also reaches the
  SwiftPM package targets, which the xcconfig line does not; derived data in `$INTEGRATION_DERIVED_DATA`, default
  `.build/integration-build`, outside the uploaded artefact), terminates a copy still running from the install path
  (SIGTERM, a bounded wait, then SIGKILL; a signal rather than an Apple Event, which would need an Automation grant),
  installs both into `$INTEGRATION_APP_DIR` (default `~/Applications`) at the same path every time, and fails when
  the installed executable lacks the hooks marker.
  Both `integration.yml` jobs run it before the TestHost suite, so the runner always tests the checked-out commit.
- `bench` compares with `PLATFORM_BASELINE`, default `perf/platform-baseline.json`; `soak` repeats the M2
  comparison with `bench-compare.sh` when `soak-metrics.json` exists. The push-to-`main` job runs one bench run
  (`COMPAT_HARNESS_BENCH_RUNS=1`, 120-minute timeout for a 78-minute budget); the nightly job runs five (QA-R14)
  before the soak, so an overrunning soak never costs the bench result, with a 720-minute timeout for a 618-minute
  budget (build 15, tests 15, bench 90, soak 498). The soak still runs when the bench step fails a regression.
- `compat-harness egress --phase local|production --minutes 10 --output <file.json>`: the 13.7 egress test
  (below). Live only with `COMPAT_HARNESS_LIVE=1`, like `run`, `soak` and `bench`.

## App profiles and per-scenario configuration (W2-E2)

- Every scenario runs on factory defaults plus its `method` plus, when one lists it, a profile from
  `compat/scenarios/profiles/<id>.json` (schema `profile.schema.json` there): the `settings` object of
  settings.json verbatim, macros, user rule overrides (`bundleIds` may name `local.testhost`; `actionFromRule`
  copies a shipped rule's `action` for QA-R21 TestHost reproductions). The scenario schema is unchanged.
- Before a scenario whose configuration differs from the previous one, the harness quits the test build (its quit
  flushes its settings), backs up its four settings files once per run, writes the new ones (owner-only, the
  original `onboarding` object kept), starts it and waits until its hooks report a state other than `starting`
  (or 2 s without hooks; after the first timeout the harness stops asking, so a build without hooks waits 2 s per
  switch, not 12 s). After the run it restores the backup, also when the run stops on an error or the factory
  configuration fails. `--no-configure` turns this off.

## Integration hooks (W2-E2, app side W3-A)

The harness reads app state and triggers test hooks through files, so the app needs no listening socket, XPC
listener or distributed notification (PLT-R909). Only the test build that the self-hosted runner installs answers
them: the App-side adapter (`App/Sources/IntegrationHooks`) is compiled under the `INTEGRATION_HOOKS` condition,
which the Release configuration never sets; AppCore's `IntegrationHookServer`, `PosixHookDirectory`,
`VnodeDirectoryWatcher` and instruments are compiled into every configuration but are never instantiated without
the adapter. `scripts/verify-release.sh` proves the adapter is absent (marker check), not every hooks type.

- Condition (W3-A decision): a third xcodegen configuration, `Integration` (`project.yml` `configs`,
  `Config/Integration.xcconfig`), sets `SWIFT_ACTIVE_COMPILATION_CONDITIONS = INTEGRATION_HOOKS` with release-like
  code generation (`-O`, whole module, so T2 to T6 measure what ships, PLT-R821), the development bundle ID and the
  Apple Development identity the runner's TCC grants are tied to (PLT-R751, QA-R12). Chosen over a command-line
  setting on Debug because Debug is unoptimised and a command-line `SWIFT_ACTIVE_COMPILATION_CONDITIONS` would also
  replace `DEBUG` in every package target. Release and Debug never mention the condition (checked by
  `scripts/tests/test_docs_and_workflows.py`), every file under `App/Sources/IntegrationHooks/` is wrapped in
  `#if INTEGRATION_HOOKS`, and so is the composition root's hook wiring.
- Release check: the hooks' dispatch queue is labelled `IntegrationHooksBuild.marker` ("INTEGRATION_HOOKS test
  build: file-drop integration hooks"), a string no other code carries and which a release therefore never
  contains; `scripts/verify-release.sh` greps the app's executables and frameworks for it and fails ("no integration
  hooks code"). `scripts/run-integration.sh build` requires it in the installed test build.
- Shared definition: `AppTestHook`, `AppHookCommand`, `AppHookErrorCode`, `AppHookRequest`, `AppHookResponse`,
  `AppStateSnapshot` and `IntegrationHookFiles` live in `Diagnostics/IntegrationHooks.swift`; the harness
  (TestSupport) and the app use the same Codable types, and `IntegrationHooksWireTests` pins the JSON byte for byte.
- Directory: `~/Library/Application Support/<storage folder>/IntegrationHooks/` (0700). The harness writes
  `request-<n>.json` atomically (0600); the app watches the directory with a vnode `DispatchSource` (no polling),
  scans it once when the watcher starts (a request written before is answered too), answers with
  `response-<n>.json` written atomically (temporary file, `fsync`, rename, 0600) and never deletes either file; the
  harness polls every 50 ms (10 s timeout, 120 s for `latencyProbe`) and removes both. Sequence numbers start at a
  random multiple of 2^20 per harness process, the harness removes a `response-<n>.json` already present before it
  writes `request-<n>.json`, and it clears leftover `request-*` and `response-*` files when a run starts, so an
  answer written after a killed run is never taken for the current one (PLT-R821). The app answers with the number
  in the file name, which must equal the request's `sequence`, and never answers a number twice (a response file
  already present, or one of the last 256 numbers it handled). A number counts as handled only once its answer is
  on disk: an answer whose write failed is kept and written again by the next scan, without running the command a
  second time. An unusable directory and a failed write are logged with a fixed reason message (symbolic link, not a
  directory, another user, permission denied, disk full, I/O error; no path, PLT-R902).
- App-side file rules (`PosixHookDirectory`): an existing directory must be a real directory of the current user
  (a link or another user's directory disables the hooks for the run) and is tightened to 0700; a request is opened
  with `O_NOFOLLOW | O_NONBLOCK` and checked with `fstat` on the descriptor, so links, other users' files, FIFOs and
  directories are refused without an answer; requests above 4 KiB are answered `unsupported`. A deleted or renamed
  directory is created and watched again.
- Request: `{"formatVersion": 1, "sequence": <n>, "command": "<name>", "profile": "normal"}` (`profile` only for
  `latencyProbe`). Commands: `state`; `resetMetrics` (`PlatformMetrics.reset()`: atomic stores of zero into every
  histogram, sub-bucket and counter, safe while the tap records; the per-bundle AX histograms are emptied);
  `tapTimeout` (the instrumented tap factory disables the tap as macOS does after a callback timeout and delivers
  `tapDisabledByTimeout` to the tap callback on the tap thread, so the normal recovery runs and resets the engine,
  PLT-R330, QA-R11; answered once the main thread re-enabled the tap); `revokePermission` (the instrumented trust
  check reports Accessibility and posting as denied until `restorePermission`, the host is asked to check at once,
  and the answer comes once it failed open, PLT-R730); `restorePermission` (answered once the host runs again, 7.3);
  `latencyProbe` (the built-in latency probe, PLT-R810, with that profile, in a plain text view of its own);
  `checkForUpdates` (the updater's check, 13.7). One command runs at a time.
- Response: `{"formatVersion": 1, "sequence": <n>, "ok": true|false, "error": "<code>", "state": {...},
  "latencyProbe": {...}}`. `latencyProbe` is `LatencyProbeResult` (Diagnostics) as JSON. `state`:
  `processIdentifier`, `state` (`noPermission`, `starting`, `ready`, `paused`, `failOpen`), `mode` (`vi`, `en`, only
  while `ready`), `pauseReason` (`PauseCode`), `failOpenReason` (`FailOpenReason`), `secureInputHolderBundleId`
  (only while paused for secure input), `firstKeyAfterSecureInputReleaseComposed` (PLT-R398B, nil before the first
  release: set by the pipeline on the first key-down after a release, which is key evidence or a new secure-input
  generation with the flag off; composed means the key was fed to the engine, so a hotkey, a navigation key, English
  mode, a passThrough strategy or a fail-open pass is not composed. The poll that publishes the "off" generation
  right after key evidence belongs to the same release: no second boundary, no second first key),
  `tapRecoveries` (main-thread re-enables after a timeout), `engineResetsAfterTapRecovery` (timeouts after which the
  pipeline's engine was reset), `metrics` (`MetricsSnapshot` as JSON). Metadata only: no text, titles or URLs; the
  input source name and the holder's display name of `HostState` are dropped (PLT-R901). Error codes:
  `unknownCommand` (a name outside the contract); `unsupported` (another `formatVersion`, a malformed, mismatched or
  oversized request, `latencyProbe` without a profile or without a Latin layout, no tap to time out, no updater
  yet); `busy` (another command is running, the host did not reach the expected state within 2 s, or the probe
  window lost focus).
- Scenario side: the `testHook` setup step (`tapTimeout`, `revokePermission`, `restorePermission`, optionally
  `@<n>` to fire after the first n keys) is in `compat/schema/scenario.schema.json` since W3-A
  (`ScenarioValidator.pendingSchemaActions` is empty). `testhost.tapTimeout.recovery` (`tapTimeout@4`, expects
  "duyeẹt") and `testhost.failOpen.permissionRevoked` (`revokePermission@4` on `v i e e t j`, expects "viêtj" and
  paused) use it; the text oracle models both hooks against the real engine. A scenario that revoked the permission
  gets it restored afterwards.
- Code: `InputHost/IntegrationHooks/` (server, directory, instruments, host actions; `swift test` covers them,
  including both scenarios end to end on `HostRig`) and `App/Sources/IntegrationHooks/` (thin adapter: composition,
  probe window).

## Platform baseline and measurements (W2-E2)

- `perf/platform-baseline.json` holds every self-hosted 8.1 metric: the eight `bench` metrics above and
  `M2.growthMBPerHour` (`soak`). Until the runner measures, every value equals its gate and carries
  `"placeholder": true` (and so does the document); `perf/README.md` defines each metric and the procedure.
- `soak` writes `soak-summary.json` and, when growth was measured, `soak-metrics.json` (`formatVersion` 1,
  benchmark `platform-soak`, metric `M2.growthMBPerHour`), compared with the same baseline at 25 %. The soak also
  fails on a crash (process changed), a watchdog trip, or a flush in the normal profile (13.6), read through the
  hooks.
- T2, T3, T5, T6 come from the app's histograms after a TestHost workload typed under profile `bench-workload`;
  T4 from the latency probe; C1 and M1 share one 10-minute window after a restart; C2 types 10 keys per second for
  5 minutes. Without the hooks the app metrics are skipped with a warning.
- Histogram precision (W3-A, the W1-A request): the decide-to-posted histograms (`decideToPosted`,
  `decideToPostedWithAX`, `probeDecideToPosted`) also count values up to 25 ms in fixed linear sub-buckets
  (`LatencySubBuckets`: 10 µs to 1 ms, 50 µs to 5 ms, 250 µs to 25 ms; bucket (lower, upper], upper end included),
  so every 8.1 value below 25 ms (T2 0.5, 2 and 3 ms, T3 2, 8 and 15 ms, T4 10 ms, the Intel 4.5 and 22.5 ms) is a
  bucket edge and "p99 over the gate" is decided exactly. Recording stays two relaxed atomic increments, no lock, no
  allocation, fixed memory. `HistogramSnapshot` carries them as an optional, self-describing `subBuckets` field
  (`segments` with `upToNanoseconds` and `widthNanoseconds`, `counts`): JSON written before still decodes, and a
  histogram without sub-buckets encodes as before, so `MetricsSnapshot` keeps no version field. The harness
  (`HistogramPercentile`) interpolates inside the sub-bucket (a value in (lower, upper]) and falls back to the log2
  estimate, never below 25 ms, above that range; the latency probe reports the sub-bucket's upper end; the issue
  block keeps its log2 values (`HistogramSnapshot.percentile`).
- The harness applies the gate itself (`RegressionGate`: over the gate, or more than 25 % above the baseline);
  `scripts/run-integration.sh bench` repeats the baseline comparison with `bench-compare.sh` against
  `PLATFORM_BASELINE`, default `perf/platform-baseline.json` (W3-A), and `soak` does the same for M2.

## Privacy canary and egress (W2-E2)

- `compat-harness run` scans after a run that included a `testhost.privacyCanary.*` scenario: every regular file
  below the app's Application Support and Logs folders (not `Logs/<folder>/captures/`, PLT-R905), its preferences
  plist, caches, HTTP storage and saved state, plus `log show --style ndjson --info --debug` of the app process
  since the run started, for every canary token in UTF-8 (NFC and NFD), UTF-16 (both byte orders), upper case and
  JSON `\uXXXX` escapes. Findings go to `results.json` (`privacy`) and `privacy-report.json` and fail the run.
- `compat-harness egress` samples `lsof -nP -a -p <pid> -i -F pPn` of the running test build every `--interval`
  seconds for `--minutes`; phase `local` allows loopback only, phase `production` loopback plus the current
  addresses of `--allow-hosts` (default: `APP_SITE_HOST` of scripts/brand.env). It asks for a forced update check
  through the hooks at the start. Report: `egress-<phase>.json`.
