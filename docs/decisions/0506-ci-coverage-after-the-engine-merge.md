# 0506. CI coverage after the engine merge

- Status: accepted, 2026-11-13
- Requirements: QA-R2, QA-R4, QA-R5, QA-R8, QA-R9, QA-R14, QA-R15, QA-R25, ENG-R301, ENG-R810, ENG-R1201,
  ENG-R1230, ENG-R1233, PLT-R505, PLT-R506, PLT-R521, PLT-R531, PLT-R820, PLT-R822

## Context

The engine, its data and the wave-1 platform modules are on `main`, and each track asked the CI track to run
its gates. Before this record several gates were silent no-ops: `scripts/fuzz.sh` looked for `fuzz-telex` and
`fuzz-vni` products that do not exist and skipped; `scripts/bench-compare.sh` looked for an `engine-benchmark`
product that is not declared and whose JSON is not `formatVersion` 1, so the engine benchmark gate skipped; the
nightly fuzz campaign never set a seed. The generator checks, the traceability check, the data manifest,
`compat-lint`, the engine's core coverage gate and the pipeline benchmark ran nowhere. The names and formats
the scripts expect are in [ADR 0502](0502-fuzz-benchmark-coverage-contracts.md); this record says where each
gate runs and why.

## Decision

| Gate | Command | Workflow, job | Requirement |
|---|---|---|---|
| Generated engine files | `python3 -I Packages/VietnameseEngine/Scripts/<generator>.py --check` for `generate-letter-table`, `extract-spec-examples`, `generate-layout-corpus` | `ci.yml`, Engine on Linux (first steps) | ENG-R301, QA-R4, QA-R6 |
| Traceability rows | `python3 -I Packages/VietnameseEngine/Scripts/check-traceability.py` | `ci.yml`, Engine on Linux | spec/01-engine.md identifiers |
| Engine build and tests on Linux | `swift build` and `swift test` of `Packages/VietnameseEngine` in the pinned `swift:6.4.2-noble` container | `ci.yml`, Engine on Linux | ENG-R1201, QA-R5 |
| libFuzzer, per PR | `scripts/fuzz.sh --seconds 60 --sanitizers fuzzer,address --require` | `ci.yml`, Engine on Linux | QA-R8, QA-R9 |
| libFuzzer, nightly | `scripts/fuzz.sh --seconds 1800 --sanitizers fuzzer,address,undefined --method <telex or vni> --require` | `nightly.yml`, one fuzz job per method | QA-R8 |
| Fuzz campaign, nightly | `ENGINE_FUZZ_EVENTS=100000000 ENGINE_FUZZ_SEED=<UTC date> swift test -c release --filter "Property\|Fuzz\|Invariant"` | `nightly.yml`, property | QA-R8, ENG 13.6 |
| Pinned data inputs | `(cd data && shasum -a 256 -c inputs/MANIFEST.sha256)` | `ci.yml`, macOS lint, tests and coverage | ENG-R810 |
| Bundled data reproducible | `swift run --package-path Packages/VietnameseEngine lexicon-builder check` (already present) | same job | ENG-R810 |
| Coverage | `scripts/coverage.sh` (engine 95 %, AppCore 80 %, already present) plus the engine core gate `Packages/VietnameseEngine/Scripts/coverage.py` on the same export | same job | QA-R2 |
| Compatibility data | `swift run --package-path Packages/AppCore compat-lint` | same job | PLT-R505, PLT-R506, PLT-R521, PLT-R531 |
| Engine benchmark | `Packages/VietnameseEngine/Scripts/benchmark.sh <file.json>` | `ci.yml`, macOS benchmarks (new job) | ENG-R1230, ENG-R1233, QA-R14 |
| Pipeline benchmark | five runs of `PIPELINE_BENCH_OUTPUT=<file> swift test --package-path Packages/AppCore -c release --filter PipelineBenchmark`, then `scripts/bench-compare.sh --threshold 25` | same new job | PLT-R820, PLT-R822 |

Choices behind the table:

1. The generator and traceability checks are standard-library Python and finish in seconds, so they run first
   in the Linux job, before the build, and cost no macOS minutes.
2. The data manifest runs on macOS right before `lexicon-builder check`: `shasum` is part of macOS, and the
   order tells a reviewer whether the inputs changed or only the outputs drifted.
3. The engine core gate reads the coverage export of the repository-wide engine step instead of running
   `Packages/VietnameseEngine/Scripts/coverage.sh`, which would run the whole engine suite a second time in its
   own scratch path. The threshold (95 %) and the counted files (`Sources/VietnameseEngine`) are the same.
4. Benchmarks get a job of their own on `xcode-27`: the same runner class every time (QA-R14), the same Xcode as
   the other macOS jobs ([ADR 0500](0500-ci-runners-and-toolchain-pins.md)), and no other step competing for
   the CPU while they measure. The artefact `benchmarks` keeps `engine.json`, the five pipeline runs and their
   median for 90 days.
5. Linux jobs stay on the digest-pinned Swift container (ADR 0500).
6. `compat-lint` runs in normal mode (warnings allowed). Its `--release` mode makes VERIFY placeholders,
   overdue `reviewBy` dates and stale Tier 1 rows errors; it is not wired into `release.yml` yet, because for a
   beta it would also block on stale Tier 1 rows, which the existing release gate checks for stable releases
   only (`scripts/compat-stale-report.py --release`). Decide before the first stable release.
7. `scripts/run-integration.sh` stops live harness commands without `COMPAT_HARNESS_LIVE=1` (ADR 0502,
   [runner runbook](../runbooks/self-hosted-runner.md) section 3.1).

## Required checks (QA-R25)

[ADR 0503](0503-release-pipeline.md) lists the `ci.yml` checks that branch protection requires. Every new gate
above is a step of a job that is already required, except the new job `macOS benchmarks (engine ENG-T40,
pipeline PLT-R820)`. Make that job required once `Packages/VietnameseEngine/Benchmarks/baseline.json` has been
re-recorded on the `xcode-27` runner class and `Packages/AppCore/Benchmarks/pipeline-baseline.json` exists
(both in `perf-baseline` PRs, QA-R15); until then a baseline from a different machine could block unrelated
pull requests. Whoever makes it required updates ADR 0503's list in the same change.

## VERIFY on the first CI runs

- The libFuzzer build flags on Linux, and whether `-sanitize=undefined` is accepted next to `fuzzer,address`.
- The engine benchmark against a baseline recorded on a development M4: calibration scales by the reference
  loop, but the `latencyStable` comparison may be tighter than the hosted runner's noise.
- How many minutes the benchmarks job adds (release builds of the engine and of the AppCore test targets).
- Noise in the sub-microsecond pipeline metrics once a baseline exists: `T1.p50` was about 0.3 us locally, so a
  25 % change is under 100 ns and close to the clock's resolution. If the gate flakes, gate only `T1.p99` or
  give `scripts/bench-compare.sh` a noise floor like the engine gate's, in a change to this record.

Checked locally on 2026-11-13 (development Mac): `swift test -c release --filter PipelineBenchmark` builds the
AppCore test targets in release and writes `formatVersion` 1; `scripts/bench-compare.sh` with the CI arguments
passes without a baseline (`T1.p99` about 1.6 us against the 100 us gate); `Scripts/coverage.py` reads the
shared engine export (99.64 % of the core); `compat-lint` reports 0 errors and 38 warnings.

## Consequences

- A stale generated file, a missing traceability row, a changed data input, a compatibility-data error, a
  drop of the engine core below 95 %, an engine regression or a pipeline regression now fails CI instead of
  passing unseen.
- `scripts/tests/test_scripts.py` (`WorkflowCoverageTests`) fails if one of these commands disappears from the
  workflows.
