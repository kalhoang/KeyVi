# Runbook: platform integration suite on the self-hosted runner

Owner: the maintainer. Specification: QA-R10 to QA-R16, QA-R21, PLT-R821, PLT-R822, PLT-R901, PLT-R906,
spec/02-platform.md sections 8.1, 9 and 13.2 to 13.7. Contracts: [ADR 0502](../decisions/0502-fuzz-benchmark-coverage-contracts.md).
Machine setup: [self-hosted-runner.md](self-hosted-runner.md).

The suite posts synthetic key events, launches apps, switches input sources and rewrites the test build's
settings. It runs **only on the self-hosted runner**. On any other Mac, including Pa's, only `--dry-run` is allowed:
without `COMPAT_HARNESS_LIVE=1` (set only in the runner's `.env`) every live command exits 3 before touching
anything.

## 1. What runs where

| Item | Who | When | Command (from the checkout root) | Needs |
|---|---|---|---|---|
| Plan check of every scenario, profile and rule | Hosted CI, any Mac | Every PR | `swift run --package-path Packages/AppCore compat-harness run --dry-run` (also `soak`, `bench`, `egress --dry-run`) | Nothing |
| Test build with the integration hooks, and TestHost | Runner | Before every runner job | `scripts/run-integration.sh build` (configuration `Integration`, section 2 step 6) | Apple Development identity in the runner's keychain |
| Scenario expectations against the real engine | Hosted CI, any Mac | Every PR | `swift test` in `Packages/AppCore` (`ScenarioOracleTests`, `ScenarioFilesTests`) | Nothing |
| QA-R11 TestHost suite and privacy canary | Runner | Every merge to `main`, nightly | `scripts/run-integration.sh tests` = `compat-harness run --only 'testhost.*' --output .build/integration/tests` | Test build, TestHost, grants (section 2) |
| Compatibility scenarios (13.2 minimum set, every rule's scenario) | Runner | Every merge to `main` | `compat-harness run --scenarios compat/scenarios --output .build/integration/compat` | Third-party apps, chromedriver, loopback server |
| Soak, 1,000,000 keystrokes (QA-R16, 13.6) | Runner | Nightly | `compat-harness soak --keystrokes 1000000 --output .build/integration/soak` | About 8.3 hours |
| Platform benchmarks T2 to T6, C1, C2, M1 (PLT-R821) | Runner | One run on every merge to `main`, five nightly (QA-R14) | `compat-harness bench --runs 5 --output .build/integration/platform-bench.json` | About 18 minutes per run |
| Egress test (13.7, PLT-R906) | Runner, started by Pa | Before every release | `compat-harness egress --phase local` then `--phase production` (section 5) | Local appcast, production feed |
| Scenarios that report `needsHuman` | Pa | Before every release | `compat-harness run --only <ids>` in a terminal session on the runner | A person at the runner |
| Upgrade test (QA-R40, 13.5) | Pa | Before every release | [release.md](release.md) section 5 | Previous DMG |

All `compat-harness` commands are run as `swift run --package-path Packages/AppCore -c release compat-harness
<command> ...`; the table drops the prefix.

## 2. One-time preparation (Pa, on the runner machine)

These steps change system settings, so they are Pa's to do on the runner machine, never on Pa's own Mac.

1. Set up the runner as [self-hosted-runner.md](self-hosted-runner.md) sections 1 to 4 describe, including
   `COMPAT_HARNESS_LIVE=1` in the runner's `.env`. `scripts/run-integration.sh` compares with
   `perf/platform-baseline.json` by default (`PLATFORM_BASELINE` overrides it).
2. Use English as the runner user's primary language: the harness finds the "Secure Keyboard Entry" item of the
   Terminal and iTerm2 app menus by its English title (VERIFY on the installed macOS).
3. Turn off text substitutions for the runner user (automatic capitalisation, smart quotes and dashes, spelling
   correction, period with double space), or TextEdit and Notes change the expected text.
4. Enable the input sources the scenarios select: ABC, German, French, Dvorak, Japanese Romaji
   ([compat/scenarios/README.md](../../compat/scenarios/README.md), "Runner prerequisites").
5. Install the third-party apps of the 13.2 set (TextEdit, Notes, Safari, Chrome, Firefox, Terminal, iTerm2,
   Ghostty, VS Code) and chromedriver matching Chrome; start chromedriver and the loopback HTTP server
   (`python3 -m http.server 8000 --bind 127.0.0.1 --directory TestHost/Resources/Pages`) as LaunchAgents of the
   runner user.
6. Build and install the test build once: `COMPAT_HARNESS_LIVE=1 scripts/run-integration.sh build` from the
   runner's checkout. It builds the xcodegen configuration `Integration` (`Config/Integration.xcconfig`: the
   `INTEGRATION_HOOKS` compilation condition, release-like code generation, `APP_BUNDLE_ID_DEV` of
   `scripts/brand.env`, the Apple Development identity) and installs it into `~/Applications/` (or
   `$INTEGRATION_APP_DIR`), always to the same path, so the grants of step 8 survive every rebuild. A copy still
   running from that path (an earlier job, a killed harness, a manual session) is terminated first (SIGTERM, then
   SIGKILL after `$INTEGRATION_QUIT_TIMEOUT` seconds, default 10). It passes `ONLY_ACTIVE_ARCH=YES` on the command
   line so the package targets build for the runner's architecture only. It refuses a build that does not answer the
   hooks (ADR 0502, "Integration hooks"). The workflows run the same step before every
   job, so the runner always tests the commit it checked out. By hand, the build alone is
   `xcodebuild -project App.xcodeproj -scheme App -configuration Integration build` after `xcodegen generate`.
   Never ship this build: `scripts/verify-release.sh` fails any app that contains the hooks.
7. The same `build` step builds TestHost (Debug, ad hoc) into the same folder. It needs no permission.
8. Grant Accessibility (and Input Monitoring if macOS asks) to the test build, and Accessibility to the harness
   binary `Packages/AppCore/.build/release/compat-harness` of the runner's checkout, which posts the events, reads
   fields and presses menu items. VERIFY which process macOS holds responsible when the runner service starts the
   harness: if the grant does not take, grant the runner's `Runner.Worker` as well.
9. Start the test build once by hand and finish its onboarding, so it never shows onboarding during a run (the
   harness keeps the onboarding state when it rewrites the settings).
10. Run the plan check on the runner: `compat-harness run --dry-run`. It must print every scenario, an `app:` line
    per scenario and end without errors.

## 3. Every run (the runner, through `integration.yml`)

1. The workflow checks out `main` (never a pull request, QA-R13) and runs `scripts/run-integration.sh build`
   (section 2 step 6), which replaces the installed test build and TestHost.
2. **Plan check:** `compat-harness run --dry-run` fails fast on an invalid scenario, profile or rule gap.
3. **TestHost suite:** `scripts/run-integration.sh tests`, which runs
   `compat-harness run --scenarios compat/scenarios --only 'testhost.*' --output .build/integration/tests`. For each
   scenario the harness:
   1. applies the scenario's configuration when it differs from the previous one: quits the test build, writes its
      four settings files (factory defaults, the scenario's method, its profile from `compat/scenarios/profiles/`),
      starts it and waits until it is ready; the original files are backed up once in
      `<output>/app-settings-backup/` and restored after the run, also when the run stops on an error (only a
      killed harness process skips the restore, see section 8);
   2. presses TestHost's Reset fields button, then runs the setup steps, types the keys at the scenario's timing
      profile, reads the field back through AX and asks the app for its state;
   3. after the last scenario, scans the app's files and unified log for the canary tokens (section 4).
4. **Compatibility scenarios:** `compat-harness run --scenarios compat/scenarios --output .build/integration/compat`
   runs every scenario the same way, including the third-party apps.
5. **Benchmarks:** `scripts/run-integration.sh bench`: `compat-harness bench --runs 5 --output
   .build/integration/platform-bench.json` nightly (one run, `COMPAT_HARNESS_BENCH_RUNS=1`, on a merge to `main`,
   so that job fits its 120-minute budget), then `scripts/bench-compare.sh --results
   .build/integration/platform-bench.json --threshold 25 --baseline perf/platform-baseline.json`. T2 and T3 come
   from gate-aligned sub-buckets of the app's histograms, so their gate decisions at 3 ms and 15 ms are exact (ADR
   0502, "Platform baseline and measurements"). Each run restarts the app, measures C1 over minutes 5 to 10 and M1 at minute 10,
   types 5 minutes at 10 keys per second for C2, types the T2/T3/T5/T6 workload into TestHost under profile
   `bench-workload`, and runs the app's latency probe for T4 ([perf/README.md](../../perf/README.md)).
6. **Soak (nightly, after the five-run bench):** `compat-harness soak --keystrokes 1000000 --output
   .build/integration/soak`: 8.3 hours of Telex words into TextEdit, a Chrome page and Terminal in turn; then
   `bench-compare.sh` repeats the M2 comparison with `perf/platform-baseline.json` when `soak-metrics.json` was
   written. The nightly job budgets 618 minutes (build 15, tests 15, bench 90, soak 498) under a 720-minute timeout;
   the bench runs first so an overrunning soak never loses it, and the soak still runs after a bench regression.
7. The workflow uploads `.build/integration` as the run's artefact.

## 4. Reading the results

| File | Content | Fails the run when |
|---|---|---|
| `tests/results.json`, `compat/results.json` | One entry per scenario: `pass`, `fail` or `needsHuman`, duration, `observedText`, `reason` (stage and error, never typed text) | Any `fail`, or a privacy finding |
| `tests/privacy-report.json` (also `privacy` in `results.json`) | Files and log bytes scanned, files that could not be read, findings (location, canary token, encoding) | Any finding or unreadable file |
| `tests/app-settings-backup/` | The test build's settings files before the run | Never (restored automatically) |
| `soak/soak-summary.json` | Keystrokes, failed chunks, footprint samples, M2 growth, stuck modifiers, watchdog trips, flushes, app restarted | Failed chunk, M2 over 5 MB/h or 25 % over the baseline, stuck modifier, crash, watchdog trip, flush in the normal profile |
| `soak/soak-metrics.json` | M2 in the ADR 0502 format | (compared by the harness) |
| `platform-bench.json` and `.runs/run-N.json` | Median and per-run values of T2 to T6, C1, C2, M1 | A metric over its gate or 25 % over the baseline; exit 3 when a measurement failed |
| `egress-local.json`, `egress-production.json` | Samples, every remote endpoint with allowed or not | Any endpoint not allowed |

The console prints one line per scenario (`pass`, `fail` or `needsHuman`, duration, reason) and one line per
metric (`C1.cpuPercent 0.120, gate 0.300, baseline 0.300 (placeholder): ok`).

## 5. Egress test (13.7), before every release

1. Phase `local`: serve a local appcast on the loopback server, point the test build's feed at it (VERIFY the
   mechanism with Sparkle 2: `defaults write <APP_BUNDLE_ID_DEV> SUFeedURL http://127.0.0.1:8000/appcast.xml`, or a
   test build whose `SUFeedURL` is the local feed), start the test build, then run
   `compat-harness egress --phase local --minutes 10 --output .build/integration/egress-local.json`. The harness
   asks the app for a forced update check through its hooks; without the hooks build, click Check for Updates in
   the menu within the first minute.
2. Remove the feed override (`defaults delete <APP_BUNDLE_ID_DEV> SUFeedURL`) and restart the test build.
3. Phase `production`: `compat-harness egress --phase production --minutes 10 --output
   .build/integration/egress-production.json`. Allowed: loopback and the current addresses of `APP_SITE_HOST`. If
   Pa chooses GitHub Releases for the archives (02-platform.md section 14), add `--allow-hosts
   <site host>,objects.githubusercontent.com,release-assets.githubusercontent.com`.
4. Both reports must say `passed`; attach them to the release checklist.

## 6. Hook scenarios (automated since W3-A)

`compat/schema/scenario.schema.json` lists the `testHook` setup action and the test build answers the hooks, so
the two QA-R11 hook scenarios are automated (`ax` readback, keys unchanged):

- `testhost.tapTimeout.recovery` (keys `d u y e e t j`, `testHook` `tapTimeout@4`): the tap times out after `duye`;
  after the recovery the engine starts a new word, so `etj` becomes `ẹt` and the field reads "duyeẹt" with paused
  false (QA-R11: engine state reset after recovery; PLT-R330).
- `testhost.failOpen.permissionRevoked` (keys `v i e e t j`, `testHook` `revokePermission@4`): the trust check reports
  Accessibility revoked after `viee` (shown as `viê`); the host fails open and the remaining keys pass untouched
  (PLT-R730), so the field reads "viêtj" and the state is paused. The harness restores the permission after the
  scenario, and the host creates its tap again (7.3).

The hooks answer `tapTimeout` only once the tap is re-enabled and `revokePermission` only once the host failed open,
so the next key lands on the new state. `swift test` checks both expectations against the real engine
(`ScenarioOracleTests`) and through the whole host under fakes (`HostHookActionsTests`); only the live run needs the
runner.

## 7. Updating the baseline

After the first green nightly on the runner, and whenever a deliberate change moves a metric, record a new
baseline in a pull request labelled `perf-baseline` with the reason (QA-R15), as
[perf/README.md](../../perf/README.md) shows. Never loosen a gate itself without Pa's sign-off (8.1).

## 8. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Every live command exits 3 at once | `COMPAT_HARNESS_LIVE=1` missing from the runner's `.env`, or the service was not restarted after editing it |
| `Integration hooks: not answering` | The test build is not the INTEGRATION_HOOKS build, or it is not running. Rebuild with `scripts/run-integration.sh build` (section 2 step 6). If it still does not answer, look in the app's diagnostics log for `integration hooks disabled: ...` (the reason: symbolic link, not a directory, another user, permission denied, disk full, I/O error) and fix `~/Library/Application Support/<storage folder>/IntegrationHooks` accordingly: it must be a real directory owned by the runner user. `a response could not be written` means a full disk or a replaced directory; the next directory change retries the answer |
| `the installed test build does not answer the integration hooks` (from `build`) | The `Integration` configuration lost its `INTEGRATION_HOOKS` condition: check `Config/Integration.xcconfig` and `project.yml` |
| A hook answers `busy` | Another hook was still running, the host did not reach the expected state within 2 s (tap re-enabled, failed open, running again), or the probe window lost focus: look at the app's health events, then rerun |
| `configure app: ...` on a scenario | A profile names an unknown shipped rule, or `scripts/brand.env` cannot resolve `local.testhost`; run the plan check |
| Scenarios type nothing, then fail | Stale grant after a rebuild or macOS update: remove and re-add the entries (self-hosted-runner.md section 4) |
| `no accessibility element with identifier testhost.resetFields` | TestHost is an old build without the Reset fields button: rebuild TestHost |
| `no accessibility element with identifier Secure Keyboard Entry` | The runner user's language is not English, or the terminal renamed the item |
| `input source not enabled: <id>` | Enable the input source for the runner user (section 2 step 4) |
| Privacy finding | A real leak (PLT-R901): file a P0 against the module that wrote the file or log line; never weaken the scan |
| Settings of the test build look wrong after a killed run (job timeout, `kill`) | The harness restores them on every error it sees, but a killed process cannot: copy the files from `<output>/app-settings-backup/` back while the app is not running, before the next run backs up the wrong ones |

## 9. What stays with Pa

- Running the scenarios that report `needsHuman` (the `human` readbacks of the design, remote, office, JVM,
  overlay-panel and game rules; iTerm2's automatic password-prompt mode) and recording their rows in
  `compat/matrix.json` (PLT-R531, PRD-R1).
- The one-time preparation of section 2, re-granting after macOS or Xcode updates, and the egress test of
  section 5 before every release.
- Until the runner exists: the interim checklist of
  [workstreams.md](../architecture/workstreams.md#interim-verification-before-the-self-hosted-runner-exists).
