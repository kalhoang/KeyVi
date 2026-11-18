# Runbook: platform integration suite on the self-hosted runner

Owner: the maintainer. Specification: QA-R10 to QA-R16, QA-R21, PLT-R821, PLT-R822, PLT-R901, PLT-R906,
spec/02-platform.md sections 8.1, 9 and 13.2 to 13.7. Contracts: [ADR 0502](../decisions/0502-fuzz-benchmark-coverage-contracts.md).
Machine setup: [self-hosted-runner.md](self-hosted-runner.md). In the tart VM lab: section 10.

The suite posts synthetic key events, launches apps, switches input sources and rewrites the test build's
settings. It runs **only on the self-hosted runner**. On any other Mac, including Pa's, only `--dry-run` is allowed:
without `COMPAT_HARNESS_LIVE=1` (set only in the runner's `.env`) every live command exits 3 before touching
anything.

## 1. What runs where

| Item | Who | When | Command (from the checkout root) | Needs |
|---|---|---|---|---|
| Plan check of every scenario, profile and rule | Hosted CI, any Mac | Every PR | `swift run --package-path Packages/AppCore compat-harness run --dry-run` (also `soak`, `bench`, `egress --dry-run`) | Nothing |
| Test build with the integration hooks, and TestHost | Runner | Before every runner job | `scripts/run-integration.sh build` (configuration `Integration`, section 2 step 6) VM runner: `INTEGRATION_CODE_SIGN_IDENTITY=-` (ad hoc) and a fresh grant after every build (ADR 0400) |
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

The nightly workflow also runs the whole AppCore suite under ThreadSanitizer on a hosted macOS runner (PLT-R203,
QA-R22). That step sets `TSAN_OPTIONS=suppressions=scripts/sanitizers/tsan-appcore.supp`, which holds one
suppression, `race:SettingsStore.`. Reason: `SettingsStore` is an actor whose executor is a `DispatchSerialQueue`
(PLT-R1003), and ThreadSanitizer cannot see the order in which that queue runs the actor's jobs, so it reports
races on actor state that cannot happen. A local run gave 4 to 5 reports without the suppression and none with
it; `SettingsStoreConcurrencyTests.concurrentUpdatesAllLand` is the proof that updates are serialized. Do not
widen the suppression: a report anywhere else is a real finding.

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
   `scripts/brand.env`, the Apple Development identity unless the ad-hoc override below is set) and installs it into
   `~/Applications/` (or `$INTEGRATION_APP_DIR`), always to the same path. A copy still
   running from that path (an earlier job, a killed harness, a manual session) is terminated first (SIGTERM, then
   SIGKILL after `$INTEGRATION_QUIT_TIMEOUT` seconds, default 10). It passes `ONLY_ACTIVE_ARCH=YES` on the command
   line so the package targets build for the runner's architecture only. It refuses a build that does not answer the
   hooks (ADR 0502, "Integration hooks"). The workflows run the same step before every
   job, so the runner always tests the commit it checked out. The runner is the tart VM
   ([self-hosted-runner.md](self-hosted-runner.md) section 8; by hand, section 10): it has no Apple Development
   identity, which stays in the keychain of Pa's Mac and is never copied into the VM (ADR 0400, Q9), so it sets
   `INTEGRATION_CODE_SIGN_IDENTITY=-` and grants every new build again (step 8). The test build is then signed ad
   hoc with the hardened runtime off (an ad-hoc signature has no Team ID, so library validation would refuse
   Sparkle); any other value stops before the build. Left unset, the build is signed with the Apple Development
   identity of `Config/Integration.xcconfig` and one grant survives every rebuild: that fits only a physical Mac
   runner, which was not chosen and would need its own signing decision (Q9). By hand, the build alone is
   `xcodebuild -project App.xcodeproj -scheme App -configuration Integration build` after `xcodegen generate`.
   Never ship this build: `scripts/verify-release.sh` fails any app that contains the hooks.
7. The same `build` step builds TestHost (Debug, ad hoc) into the same folder. It needs no permission.
8. Grant Accessibility (and Input Monitoring if macOS asks) to the test build, and Accessibility to the harness
   binary `Packages/AppCore/.build/release/compat-harness` of the runner's checkout, which posts the events, reads
   fields and presses menu items. VERIFY which process macOS holds responsible when the runner service starts the
   harness: if the grant does not take, grant the runner's `Runner.Worker` as well. On the VM runner this is
   `sudo scripts/vm/grant-tcc.sh --bundle ... --binary ...` after **every** build (its image has SIP disabled, and the
   grant of an ad-hoc build is tied to that build's cdhash); on a physical Mac it is done once by hand
   ([self-hosted-runner.md](self-hosted-runner.md) section 4).
9. Before the test build's first start, turn its automatic update check and install (D19, D20) off in its
   settings file: the test build carries the production feed, and on factory defaults Sparkle checks at that very
   start and, with D20 on, installs the published release on quit, which turning the switches off in the About pane
   during the start does not cancel (section 10.10). When
   `~/Library/Application Support/<APP_DISPLAY_NAME>/settings.json` does not exist yet, write it with
   `{"schemaVersion":1,"settings":{"automaticallyCheckForUpdates":false,"automaticallyInstallUpdates":false}}`
   (the seed of `scripts/vm/guest/integration-guest.sh` without its onboarding state); when it does, quit the test
   build and set both keys to `false` in its `settings` object. Then start the test build by hand and finish its
   onboarding, so it never shows onboarding during a run (the harness keeps the onboarding state when it rewrites
   the settings).
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
      killed harness process skips the restore, see section 8); after the restore the harness starts the test build
      again only when it was running before the run, because the restored files may turn its automatic updates on
      (section 10.10);
   2. presses TestHost's Reset fields button, then runs the setup steps, types the keys at the scenario's timing
      profile, reads the field back through AX and asks the app for its state;
   3. after the last scenario, quits the app (so its last flush is on disk and nothing is written while the scan
      reads), then scans the app's files and unified log for the canary tokens (section 4).
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
| `tests/privacy-report.json` (also `privacy` in `results.json`) | Files and log bytes scanned, files that could not be read, files listed but gone before they were read (`vanished`), findings (location, canary token, encoding) | Any finding or unreadable file (a vanished file left nothing on disk and does not fail) |
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
| `configure app: quit timed out: <bundle> was still running 10 s after the quit request` | The test build did not exit within 10 s of the quit request. The harness asks the process itself, so this is a real slow quit: look at the screen for a modal panel (the hooks build shows none, section 10) and at the app's diagnostics log for the `lifecycle.terminating` event; the app replies to AppKit at the latest 5 s after it, even when its settings flush hangs |
| `compat-harness: the app did not quit before the privacy scan: ...` | Same cause as the row above; the scan still runs, and a file the app pruned meanwhile shows as `gone before it was read` |
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

## 10. Running the suite in the tart VM

Since 2026-11-13 the VM lab ([vm-test-lab.md](vm-test-lab.md)) has `{{app-slug}}-dev`: macOS 27.2 with Xcode 27.2,
the tart guest agent, passwordless `sudo` and **SIP disabled** in its Cirrus Labs image. That makes the TestHost
suite possible without a dedicated Mac and without touching Pa's Mac:

```sh
scripts/vm/integration-dev.sh    # throwaway clone of {{app-slug}}-dev (6144 MB, 4 CPUs), deleted afterwards
scripts/vm/integration-dev.sh --only testhost.web.textarea    # control run of chosen scenarios (IDs, PREFIX*)
scripts/vm/integration-dev.sh --probe --only testhost.web.textarea    # the same with the AX focus probe (10.5)
```

It copies the committed checkout (`git archive HEAD`) into the clone and runs
`scripts/vm/guest/integration-guest.sh` through `tart exec`, so everything runs in the logged-in GUI session of
`admin`:

1. turns text substitutions off (section 2 step 3); English is the first language of the image;
2. enables every input source a TestHost scenario names (section 2 step 4: ABC, French, German, Dvorak, Japanese
   Romaji), read from `compat/scenarios/testhost.*.json` and enabled through the Text Input Sources API by
   `scripts/vm/guest/enable-input-sources.swift`, which the guest compiles and runs (it refuses a real Mac);
3. runs `scripts/run-integration.sh build` itself with `INTEGRATION_CODE_SIGN_IDENTITY=-` (section 2 step 6):
   XcodeGen, the `Integration` configuration (INTEGRATION_HOOKS) **ad-hoc signed with the hardened runtime off**,
   because the VM has no Apple Development identity (an ad-hoc signature has no Team ID, and library validation
   would refuse Sparkle), TestHost, the install into `~/Applications` and the hooks marker check;
4. builds `compat-harness` (release);
5. grants Accessibility, Input Monitoring and event posting with `sudo scripts/vm/grant-tcc.sh` to the test build,
   TestHost, `compat-harness`, the tart guest agent (which starts the harness) and `sshd-keygen-wrapper` (for runs
   started over SSH); each row carries the client's compiled code requirement, so the grant follows each new
   cdhash;
6. marks onboarding as finished in the test build's settings file (section 2 step 9) and turns its automatic
   update check and install off there (section 10.10);
7. runs the plan check (`compat-harness run --dry-run`), then `COMPAT_HARNESS_LIVE=1 scripts/run-integration.sh
   tests`, and copies `.build/integration/tests`, the app's diagnostics log (event codes only, PLT-R901) and a
   screenshot of the end of the run back.

The run folder is `/Volumes/Data/tart/runs/<timestamp>-integration/` (`integration.log`, `guest.log`,
`integration-out/` with `summary.txt`, `system.txt`, `input-sources.log`, `build.log`, `build-harness.log`,
`grant.log`, `tcc-rows.txt`, `dry-run.log`, `tests.log`, `results/`, `app-diagnostics.jsonl` and `screen.png`).

### 10.1 First attempt, 2026-11-13

Run `20261113T145511Z-integration` on commit `4553435`, about 17 minutes in all (build of the test build, TestHost
and the harness about 10 minutes, suite about 5 minutes). The path works end to end: XcodeGen, the ad-hoc
`Integration` build with the hooks marker, TestHost, `compat-harness`, 15 TCC rows written by `grant-tcc.sh`
(5 clients by 3 services; `tcc-rows.txt` lists 34 allowed rows in all, the rest being the image's own grants for
`sshd-keygen-wrapper`, the tart guest agent and `osascript`), the plan check, and a live run that
posted events into TestHost. **5 of 40 TestHost scenarios passed** (`testhost.backspace.punctuation`,
`testhost.native.telex`, `testhost.privacyCanary.backspaceReplace`, `testhost.privacyCanary.passThrough`,
`testhost.secureInput.release`); the privacy scan found no canary (13 files, 3.6 MB of log). 35 failed:

| Count | Reason in `results.json` | What it means |
|---|---|---|
| 9 | `configure app: not supported yet: quit of <dev bundle ID>` | The test build did not exit within 10 s of `NSRunningApplication.terminate()`. `LiveAppControl.quit()` reports that timeout as `LiveError.unsupported`, so the message is misleading. Needs a look at the app's termination path in the VM (a modal panel or prompt that blocks the quit Apple Event is the first suspect) and a clearer harness error |
| 7, 2 | `integration hook 'state' timed out`, `'tapTimeout'` and `'revokePermission'` timed out | The hooks did not answer, most likely because the app was left half quit by the row above |
| 12 | `observed state differs from expect` | The app's state after the keys differs from the scenario; with the configuration not applied (first row) these are expected to follow from it. Rerun once the quit works |
| 4 | `input source not enabled` (French, German, Dvorak, Japanese Romaji) | Section 2 step 4 is not done in the image yet; enable them once in the base image (VM window, or a small TIS script in the VM) |
| 1 | `no accessibility element with identifier testhost.secureInput.toggle` | The checkbox exists in `TestHost/Sources/TestHostLayout.swift`; not found at that moment, probably the same state problem. Recheck after the rows above |

Also, the privacy report listed one unreadable file (`backups/app-modes.json.v1.<timestamp>.json` in the test
build's folder), which by itself fails the run (section 4). Nothing in this list needs a signing identity: the VM
builds the test build ad hoc and grants it itself, as the VM runner does by decision (ADR 0400: the Apple
Development identity stays in the keychain of Pa's Mac and is never copied into the VM, Q9). What the VM lacks for
a full runner job is only the prerequisites of section 2 steps 4 and 5 (input sources, third-party apps,
chromedriver, the loopback server), which the TestHost subset does not need except for the four input-source
scenarios.

### 10.2 Grants by hand, and why the signature must be stable

In an image with SIP enabled (the macOS 12 image, or a future Xcode image) the TCC database is read-only and the
grants are made once by hand, inside the VM, never on Pa's Mac:

1. Stop the VM if it runs (`scripts/vm/lab.sh down <vm>`), then open its window:
   `TART_HOME=/Volumes/Data/tart/home /Volumes/Data/tart/tart.app/Contents/MacOS/tart run <vm>` (it logs in as
   `admin` by itself).
2. In the VM: System Settings > Privacy & Security > Accessibility, then Input Monitoring: click +, add the test
   build in `~/Applications`, `compat-harness` (Packages/AppCore/.build/release of the checkout in the VM) and the
   process that starts it (the runner's `Runner.Worker`, or `/usr/libexec/sshd-keygen-wrapper` for SSH), and
   switch each on. VERIFY the pane names on the installed macOS.
3. Shut the VM down from its Apple menu. The grants are stored on the VM's disk, so every later clone of it has
   them.

TCC stores each grant together with the client's **code requirement**. An ad-hoc signed client's requirement is
its `cdhash`, which changes with every build, so a rebuilt test build no longer matches the grant and the
symptom is a green start and tests that type nothing (section 8). A client signed with a stable identity keeps
its requirement across builds: with the Apple Development certificate of `Config/Signing.xcconfig` it is
`identifier "<dev bundle ID>" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development:
..." and certificate 1[field.1.2.840.113635.100.6.2.1] exists`, the same for every build signed with that
certificate, so one grant lasts until the certificate is replaced (PLT-R751, self-hosted-runner.md section 4).
That identity stays in the keychain of Pa's Mac and is never imported into a VM (ADR 0400, Q9). A VM image with
SIP enabled that needs a stable signature can use a self-signed code-signing certificate created inside the VM to
sign the test build and the harness (the requirement is anchored on that certificate; the hardened runtime must
stay off, because a self-signed certificate has no Team ID). With SIP disabled none of this is needed:
`grant-tcc.sh` simply grants the new cdhash after each build.

### 10.3 Triage of the first attempt (W6-B, 2026-11-13)

Every row of 10.1 was reproduced in a clone of `{{app-slug}}-dev` and traced to its cause:

| First-attempt symptom | Root cause | Fix |
|---|---|---|
| 9 x `quit of <dev bundle ID>` timed out | Not the app: it exits 0.2 s after the quit request (measured in the VM). `LiveAppControl.quit()` polled a cached `NSRunningApplication`, whose `isTerminated` refreshes only when the harness's main run loop turns, which it never does in `compat-harness` | The harness asks the process itself (`kill(pid, 0)`); a real timeout is `AppQuitTimeout` (`quit timed out: <bundle> was still running 10 s after the quit request`) |
| 9 x hook `state`, `tapTimeout`, `revokePermission` timed out | Follow-on of the row above: the next scenario started the app again while the harness still believed it was quitting | Same fix |
| `no accessibility element with identifier testhost.secureInput.toggle` | `launch` returns once the process runs, before TestHost's window exists | Setup lookups by identifier retry for up to 5 s |
| 4 x `input source not enabled` | The image enables only ABC | The guest enables every layout a TestHost scenario names (`scripts/vm/guest/enable-input-sources.swift`) |
| Privacy scan: `backups/app-modes.json.v1.<timestamp>.json` unreadable | Not a file mode or format problem: the app was still running and a debounced `app-modes.json` write rotated the backups (newest five kept, PLT-R1005) between the scan's listing and its read, so the file was gone | The harness quits the app before the scan (its last flush is scanned too and nothing changes while the scan reads); a file listed but gone is reported as `vanished`, not as unreadable |
| 12 x `observed state differs from expect` | Several harness and TestHost causes: a scenario that focused the field the previous one used continued the previous word (the reset is invisible to the app's tap); TestHost's web mirrors did not forward an AX focus request into the page, so web scenarios typed into the native field; a field of the second window took AX focus without its window becoming key; a shortcut that focused a text field selected all its text; the readback raced the last replacement | Reset fields leaves no field focused and reloads `fields.html`; mirrors forward AX focus; `focusField` raises the field's window and waits until the focused element takes text, then 300 ms; 300 ms after Command plus a digit; caret at the end after a focus shortcut; the readback is repeated for up to 2 s while it differs from the expectation |

While reproducing the quit, a real defect of the app showed up: the quit reply came from a main-actor task, so a quit
requested from inside a main-queue job (`NSApp.terminate` from a task, the relaunch after a stuck callback, the launch
sequence's quit) or while a modal alert opened from `DispatchQueue.main.async` was up (safe mode, the conflict notice)
never completed (with the safe-mode alert up, the app was still running 30 s after `terminate()`). The flush now runs
off the main actor and the reply goes through the main run loop, at the latest 5 s after the request
(`QuitCoordinator`, PLT-R1003). The integration hooks build never opens those modal notices or the move offer.

### 10.4 Runs after the fixes (W6-B, 2026-11-13)

Each run is `scripts/vm/integration-dev.sh` in a throwaway clone of `{{app-slug}}-dev` (6144 MB, 4 CPUs), about 25 to
35 minutes in all, on the commits of branch `fix/w6b-lifecycle-vm-suite`. Run folders under
`/Volumes/Data/tart/runs/`.

| Run | Commit | Pass | Fail | What it showed |
|---|---|---|---|---|
| `20261113T145511Z-integration` | `4553435` | 5 | 35 | First attempt (10.1) |
| `20261113T172115Z-integration` | `dbb6872` | 23 | 17 | Quit, hooks, input sources and the privacy scan fixed (no quit timeout, no unreadable file); web scenarios typed into the native field; the second window's fields never became key; first words untransformed |
| `20261113T175822Z-integration` | `8e4cd51` | 32 | 8 | TestHost focus and reset fixed. The screenshot evidence of this run raised Screen Recording's consent prompt, which covered the windows of the following scenarios (replaced by a text focus report) |
| `20261113T182546Z-integration` | `c4b2adc` | 33 | 7 | Focus reports per failure; a focus shortcut no longer selects the field's text |
| `20261113T185210Z-integration` | `5527e61` | 35 | 5 | The harness waits until the app published the new focus (its T6 count, through the hooks) before the first key |
| `20261113T191620Z-integration` | `9be7e9e` | - | - | Did not start: `tart exec` right after boot found no guest agent yet; `integration-dev.sh` now waits for it (`VM_AGENT_TIMEOUT`, default 180 s) |
| `20261113T192215Z-integration` | `e875936` | 35 | 5 | TestHost moves the page focus before the web view becomes first responder (web edit-mode transition passes); one transient `prepare: press failed with AXError -25204` on Reset fields (now retried) |
| `20261113T194227Z-integration` | `bdb803c` | 34 | 6 | Last run of W6-B. The Reset fields retry held (`testhost.layout.abc` passes); `testhost.perWindowRule.mainWindow` and `testhost.web.editModeTransition` failed again after passing in earlier runs (intermittent, see below) |
| `20261113T204207Z-integration` | `02613e3` | 1 | 0 | Control run, `--only testhost.web.textarea`: on a freshly launched TestHost the scenario passes |
| `20261113T205703Z-integration` | `abbf586` | 35 | 5 | Trial: Reset fields reloaded `fields.html` every time. `testhost.web.textarea` still failed; `testhost.web.inlineAutocomplete` failed (`asia.example`) for the first time since run 3 |
| `20261113T211740Z-integration` | `abbf586` | 1 | 2 | Control run, `--only testhost.web.inlineAutocomplete,testhost.web.input,testhost.web.textarea`: `web.input` passes, `web.textarea` fails right after it on a freshly loaded page; `web.inlineAutocomplete` as the first scenario gives `aá` |
| `20261113T212628Z-integration` | `065e076` | 1 | 2 | The same control run with the reload reverted: `web.textarea` fails after `web.input` in the same way; `web.inlineAutocomplete` as the first scenario of a fresh TestHost found no `testhost.web.input` element at readback (a first-scenario effect, not seen in a full run) |
| `20261113T213424Z-integration` | `065e076` | 35 | 5 | Final run of W6-B (harness: bounded focus refresh wait, no window title in focus reports). `testhost.web.inlineAutocomplete` passes again; `testhost.web.editModeTransition` failed (`Dd`, intermittent) |

Result: from 5 of 40 to **35 of 40** (`20261113T185210Z-integration`, `20261113T192215Z-integration`,
`20261113T205703Z-integration` and the final run `20261113T213424Z-integration` on `065e076`); one run passed 34
because timing-dependent scenarios failed again. Not all 40 are green yet: what is left is in the app's input
pipeline (W6-A), not in the harness, TestHost or the VM.

Control runs (`scripts/vm/integration-dev.sh --only ...`) separated TestHost state from the app for
`testhost.web.textarea`: alone on a fresh TestHost it passes; right after `testhost.web.input` it fails, with or without
a fresh load of `fields.html` on Reset fields (the reload was tried and reverted, `065e076`). TestHost's state before
`web.input` (after another web scenario) and before `web.textarea` (after `web.input`) is the same, and `web.input`
passes, so the difference lies in what the app remembers from the previous field of the same page.

Outcome: the five failures left after W6-B, and the two intermittent ones, were traced by W7-A to the app's focus
tracking (an early WebKit focus notification, an observer refused by a just launched app) and to two TestHost
fixtures (no Edit menu, a page that moved the focus between two keys). Root causes, fixes and runs: section 10.5.
None of them needs the Apple Development identity or Pa's Mac. The privacy scan has passed (no finding, no unreadable
or vanished file) in every run since the second.

### 10.5 Root causes of the last failures (W7-A, 2026-11-14)

Method: control runs in a throwaway clone of `{{app-slug}}-dev` with an AX probe running in the guest's session next
to the harness (`scripts/vm/guest/ax-focus-probe.swift`, how to use it below). The probe logs every focus, window,
selection and value notification of TestHost with the role, identifier and hash of the notified element and of the
app's focused element at that moment, and every pasteboard change (change count and types, never a value). The two
probe logs cited in the table come from an earlier, uncommitted revision of the probe (`probe-source.swift` in the
same run folders): its lines read `NOTE ... vsPrev=` and `PASTEBOARD ... len=` instead of `focus=same|changed` and
`pasteboard change=... types=...`, and it counted the bytes of the pasteboard's text, which the committed probe does
not read at all.

| Scenario | Root cause | Fix | Test |
|---|---|---|---|
| `testhost.web.textarea`, and the intermittent `testhost.web.inlineAutocomplete` and `testhost.perWindowRule.mainWindow` | WebKit posts `AXFocusedUIElementChanged` for the page's textarea (the notification names a group of the WebContent process) while the app's `AXFocusedUIElement` still reads none; 13 ms later the textarea is the focused element, and no second notification follows (`20261113T222941Z-w7a-webpair/probe-1.log`, 7.043 s and 7.056 s). `FocusCore` read the focus once per notification, so it published "no text focus" and kept it until the PLT-R382 revalidation on the first key: the first word passed untransformed (`tieengs việt`; on the completion page `asia.example`, both keys passed). | Settle re-reads: 40, 120 and 400 ms after every focus notification and every activation, `FocusCore` reads the focus again and publishes only a change; a timeout ends the window, and a notification whose own read timed out opens none, so a focus change of a slow app
costs one PLT-R384 breaker count as before; a deferred publication wakes the main thread like a notification does (`FocusCore+Settle.swift`, PLT-R380, PLT-R391). | `FocusSettleTests` |
| `testhost.addressBar.telexStroke` (`dđ`), `testhost.addressBar.telexTone` (`asia.example`, `aá`) | Not the deletion count: the inline-completion handling of the edit (`axSelectionThenPlaceholder`, one extra Backspace when a suggestion is selected, `KeyStrategies.swift`) is right whenever the snapshot carries the address bar's rule; `testhost.addressBar.vni` passes in every run with the same field and rule. These two scenarios are the first after TestHost's launch. A just launched app answers `AXObserverAddNotification` with `kAXErrorCannotComplete` (-25204) for about 400 ms (the probe's own observer, both runs below), and `FocusCore` never asked again, so (inferred: the probe's observer was refused, and `FocusCore` registers the same
way at the same moment) no focus notification of TestHost arrived: the keys met a stale snapshot (another field's rule gives `dđ`, no text focus gives `asia.example`). Their 5 to 8 s durations (2 s of them the harness's focus-refresh wait timing out) match. | A refused observer is retried 100, 200, 400, 800, 1,600 and 3,200 ms later while the app owns the focus, and a late registration reads the focus it missed; `SystemAXProvider` adds an observer's notifications all together or not at all (`AXObserverRegistration`), so a refusal halfway is retried too; the last retry keeps what the app accepts, so one name refused for good does not cost the others. The PLT-R382 revalidation also runs on the first key after the app starts: before, that key never counted as idle, which is why `telexStroke` composed both keys on the stale snapshot while `telexTone`, one scenario later, got the revalidation on its first key. | `FocusSettleTests`, `AXObserverRegistrationTests`, `KeyPipelineHostTests.firstKeyDownAfterStartRequestsRevalidation` |
| `testhost.privacyCanary.paste` (a space only) | TestHost had no Edit menu. AppKit turns Command+V into `paste:` only through a menu key equivalent, so the `paste` strategy's synthetic Command+V reached no field: every edit's deletions ran and its insertion never came, which left the space alone. The pasteboard side worked: the probe logged the transient item with the nspasteboard.org marker types and each restore (changes 2 to 6 in `20261113T222633Z-w7a-reproduction/probe-1.log`), so neither the 400 ms restore delay nor macOS 27 pasteboard privacy was involved, and nothing typed was logged or persisted (privacy scan clean). | TestHost gets the standard Edit menu (Cut, Copy, Paste, Select All). | `TestHostSourcesTests.editMenuHasTheStandardKeyEquivalents` |
| `testhost.web.editModeTransition` (`Dd`, intermittent) | The local page moved the DOM focus from a grid cell (a `div`) to a hidden editor after the first key. A focus change is a hard boundary (PLT-R340), so with the host tracking it "D" and "d" are two compositions and give `Dd`; the scenario passed only when the app published the editor's focus after the second key had been decided, a race that the settle re-reads would end for good. Not a harness timing problem. | The cell is one input that keeps the focus from the first key on; it still drops the keys of its 20 ms edit-mode transition and autocompletes from its column. | `LocalPagesTests.editModeCellKeepsTheFocusFromTheFirstKey` |

**Limit of the edit-mode fix (answered by Pa on 2026-11-14).** The old page was the suite's only model of a grid whose
first key opens a separate editor element. Under PLT-R340 as written then, a focus change between the first two keys of
a word was a hard boundary, so Telex `Dd` stayed `Dd` there. Pa's manual test T5.5 of 2026-11-14 hit the same class of
bug in TextEdit's save sheet (Command+S, then `dduongwf` typed at once gave `ddường`) and reported it as a bug, which
answers the question in favour of keeping the word: PLT-R340 now keeps the composition across a focus change discovered
late within the same process (500 ms window, verified by the first job's bounded read). W8-A re-added the old page as
`edit-mode-editor.html` (scenario `testhost.web.editModeEditor`, `Đức`) next to the single-element page of W7-A
(section 10.6).

Runs of W7-A (clone `{{app-slug}}-dev-w7a`, 6144 MB, 4 CPUs; folders under `/Volumes/Data/tart/runs/`):

| Run | Commit | Pass | Fail | What it showed |
|---|---|---|---|---|
| `20261113T222633Z-w7a-reproduction` (`--only` the five, plus `testhost.addressBar.vni`, `testhost.web.input`, `testhost.web.inlineAutocomplete`) | `877ed58` | 3 | 5 | Reproduction on the starting commit: `dđ`, `asia.example`, ` `, `Dd`, `tieengs việt`. The probe's observer on the just launched TestHost was refused (-25204) and, never retried, saw no notification at all; the paste strategy's pasteboard writes and restores were logged |
| `20261113T222941Z-w7a-webpair` (`--only testhost.web.input,testhost.web.textarea`, probe retrying its observer) | `877ed58` | 1 | 1 | The probe's observer was refused for 390 ms after TestHost's launch, then registered; the early WebKit focus notification of the textarea (row 1 above) |

VM verification of the fixes is **open**, and until it exists the table above is a diagnosis, not proof: no VM run
contains any of the fixes. A first build with them was starting in the clone when the host's Safari guard stopped the
VM (2026-11-14 05:34 host time, `/Volumes/Data/tart/safari-guard.log`), and Safari then stayed open beyond the
90-minute limit of Pa's VM rule, so the clone was deleted unverified. The review follow-up waited again from 07:31 to
09:02 with Safari open throughout and booted no VM. Next step, in this order, with Safari closed:

1. `scripts/vm/integration-dev.sh` (the full suite: expect 44 of 44 and a clean privacy scan; 40 before W8-A added
   the four scenarios of section 10.6);
2. three times `scripts/vm/integration-dev.sh --probe --only testhost.addressBar.telexStroke,testhost.addressBar.telexTone,testhost.privacyCanary.paste,testhost.web.input,testhost.web.textarea,testhost.web.editModeTransition`
   (`testhost.web.input` runs before the textarea on purpose; the probe's log shows TestHost's observer refusals right
   after launch next to the addressBar results, and is the first run of the committed probe);
3. five times `scripts/vm/integration-dev.sh --only testhost.web.editModeTransition`.

Record every run (folder, commit, pass and fail) in the table above. If a scenario still fails, read its focus report
in `integration-out/evidence/` and the probe's log of the same run.

The probe runs inside the VM only (it refuses a real Mac). `scripts/vm/integration-dev.sh --probe` (with or without
`--only`) has the guest compile it, grant it with the other TCC clients, start it on TestHost's dev bundle ID right
before the suite and end it after; its log is `integration-out/probe.log` in the run folder (`probe-build.log` if it
did not compile):

```sh
scripts/vm/integration-dev.sh --probe --only testhost.web.input,testhost.web.textarea
```

The typing trace (PLT-R905) is not used in these runs: it starts only after the user confirms it in the app, and the
text it records would be a finding of the privacy scan.

### 10.6 Focus after panels, sheets and late focus changes (W8-A, 2026-11-14)

Pa's manual tests of 2026-11-14 (items 7 to 9 of that day's feedback; the decision is recorded in
`docs/decisions/0005-pa-decisions-2026-11-13.md`, and the symptoms are quoted in the table) found three focus bugs on
macOS 27.2, none of which the suite covered:

| Report | Root cause (from the code, with fakes) | Fix | Unit tests |
|---|---|---|---|
| Spotlight: `tex` gave `teẽ`, then `xt` gave `teẽext`; `vieejt` gave `vieêệt` (item 7) | Every first deletion was absorbed by Spotlight's field, so the edits ran without `launcher.spotlight` (no `axSelection`). *Correction of 15/11/2026 (retest of beta 2, dev trace 16:37 to 16:38): on macOS 27.2 the panel belongs to the Siri app (`com.apple.campo`), found 66 ms after Command+Space with a fresh snapshot and no rule (`rule -`), because the rule listed only `com.apple.Spotlight`; it now lists both. The stale snapshot below was real but not the whole cause.* Spotlight is a non-activating panel: Command+Space and Escape post no activation, and nothing made `FocusCore` read the system-wide focus before the first keys unless the pause before them reached the 500 ms of PLT-R382 | PLT-R389: a Command or Control shortcut, Escape, Return, Tab or a click asks for reads 25 to 400 ms later, the next key for one more, and every key reads while an overlay rule applies; these reads ask for the element's attributes only when the focused app or element moved | `FocusTriggerSettleTests`, `FocusTriggerTests` |
| T5.8: on the second opening, Escape gave `vieêệeejt` (item 9) | The same stale snapshot: the previous app's rule has the restore hotkey, so Escape restored `việt` through the absorbed first deletion. *Correction of 15/11/2026: on macOS 27.2 the default decision of the unlisted `com.apple.campo` kept the restore key (the retest gave `vieệeejt`)* | The same; `launcher.spotlight` (`restoreHotkey: false`) applies on every opening and stops when Spotlight closes | `FocusTriggerSettleTests.spotlightAppliesOnEveryOpenAndStopsOnCloseT58` |
| T5.5 step 3: Command+S, then `dduongwf` gave `ddường` (item 8) | The first `d` went into the sheet's name field on the document's snapshot; the field change was published after it (the PLT-R382 read that very key asked for) and PLT-R340 made it a hard boundary | PLT-R340 amendment: same process, readable element, observed within 500 ms of the token's last key: the word is kept; the first job checks the field's text before the caret (`EditJob.verifyLateFocus`) | `LateFocusChangeTests`, `WorkerLateFocusTests`, `LateFocusEndToEndTests` |

New TestHost scenarios (the suite goes from 40 to 44):

| Scenario | TestHost | Expect |
|---|---|---|
| `testhost.sheet.commandS` | File > Save… (Command+S) attaches a sheet to the second window; its name field holds `Untitled`, selected; the keys follow at `normal` timing; read back through `testhost.sheet.mirror` | `đường` |
| `testhost.panel.inlineCompletionTwice` | Window > Show Search Panel (Command+K) shows a non-activating panel whose field completes inline like Spotlight's (diacritics ignored); Escape closes it and appends the query and `<esc>` to the transcript read through `testhost.panel.mirror`; opened twice; profile `testhost-reproductions` gives the field `launcher.spotlight`'s action | `việt<esc>việt<esc>` |
| `testhost.panel.toneUndo` | The same panel, `tex` then `xt` | `text<esc>` |
| `testhost.web.editModeEditor` | `edit-mode-editor.html`: the original page of section 10.5 (a grid cell that moves the DOM focus to a separate editor after the first key); profile `testhost-reproductions` gives it the Sheets action with `requireTextFocus: never`, as browser engines get by `byEngine` | `Đức` |

The panel lives in TestHost's own process, so its focus change reaches `FocusCore` through TestHost's
AXFocusedUIElementChanged as well: it proves that the overlay rule applies on every opening, that Escape passes there
and that the word survives the inline completion twice, not that a panel of another process is found without a
notification. That part is the unit tests' (fake AX posts nothing) and the Spotlight check below.

`launcher.spotlight.reopen` (runner only, `targetBundleId` Spotlight) types `vieejt`, Escape twice, then opens Spotlight
again and types `tex` then `xt`; `launcher.spotlight.campo` and `launcher.spotlight.campo.reopen` do the same with
`targetBundleId` `com.apple.campo`, the panel of macOS 27.2, and `launcher.spotlight.campo.suggestion` types `tieesng`
(expect `tiếng`). These four and `launcher.spotlight` declare `readbackOptions.excludesSelectedCompletion`, so their
`ax` readback leaves out a selected completion that runs to the end of the value (`AXReadbackText`): Spotlight with
history shows `text` as `TextEdit` with `Edit` selected, which is the completion the extra Backspace of PLT-R420
removes, not text that was typed. *Correction of 19/11/2026:* from commit `5c7b8b27` (14/11/2026) the readback left
such a selection out of every `ax` scenario, which broke `testhost.sheetCell.columnAutocomplete`; since PLT-R530 was
amended it does so only where the scenario declares it, and no TestHost scenario does (QA-R21, section 10.10).

*Correction of 15/11/2026, evening (W17-D, dev build 20261115f):* with `launcher.spotlight` applied to
`com.apple.campo`, `tiee` still gave `tieê`. Finding 202 of that day's dev trace (`trace-scan.sh show 202 --date
2026-11-15`) shows the first edit as `job 1 compose backspaceReplace executed delete 1 insert 1 4 events completion
none` and the commit readback `tieếng ` (selection 7+0) after `tieesng`: the first Backspace of the first edit went
to the suggestion. By hand, with {{AppName}} switched to English, Pa saw the suggestion in grey after the caret; one
Backspace removed only the suggestion, Shift with the arrow keys selected nothing (so `selectReplace` is no way out),
and Forward Delete (Globe+Delete) removed the suggestion, after which a Backspace left `ti`. `AXSelectedTextRange` has
length 0 while the suggestion shows, so `axSelection` never added its deletion. The rule now uses `forwardDelete`
(PLT-R423): one read of `AXSelectedTextRange` and `AXNumberOfCharacters` per deleting edit; with the caret at the end of
the text a Forward Delete goes before each Backspace (a delete-1 job posts 6 events, delete 2 posts 12 with a
two-character insertion), a selection still gets the extra Backspace, and a caret before the end or an unreadable field
gets nothing (unit tests: `ForwardDeleteCompletionTests`, `ForwardDeleteTests`, `WorkerCompletionFallbackTests`).

Proof plan of W8-A, in this order, with Safari closed (Pa's VM rule) and the VM lock taken:

1. `scripts/vm/integration-dev.sh` (expect 46 of 46 and a clean privacy scan; 44 before W8-F added the two key-code-first
   composer scenarios of section 10.7);
2. three times `scripts/vm/integration-dev.sh --probe --only testhost.addressBar.telexStroke,testhost.addressBar.telexTone,testhost.privacyCanary.paste,testhost.web.input,testhost.web.textarea,testhost.web.editModeTransition,testhost.web.editModeEditor`;
3. five times `scripts/vm/integration-dev.sh --only testhost.web.editModeTransition,testhost.web.editModeEditor,testhost.sheet.commandS,testhost.panel.*`;
4. Spotlight, macOS 27.2: `scripts/vm/integration-dev.sh --only launcher.spotlight` twice in a row in one clone is not
   possible (each run is a fresh clone), so the check is done by hand in a clone of `{{app-slug}}-dev` after the full
   run: with the test build running, open Spotlight with Command+Space, type `vieejt` and `tex` then `xt`, press
   Escape, open it again and repeat; expect `việt`, `text` and an Escape that clears or closes Spotlight each time; then
   read the field with `ax-dump --bundle com.apple.campo --windows` (macOS 27.2; `com.apple.Spotlight` before it)
   while a suggestion is shown, to confirm that the field leaves the suggestion out of `AXValue` and
   `AXNumberOfCharacters` (the `forwardDelete` handling of `launcher.spotlight` relies on it). Also type a word, move
   the caret left with the arrow key and type `ees`: nothing to the right of the caret may disappear. The dev trace
   answers the same question on any Mac: each job line of a rule with `forwardDelete` ends with `completion
   forwardDelete` (6 events for a delete-1 edit), `completion forwardDelete skipped notAtEnd`, `completion
   forwardDelete skipped unreadable`, `completion forwardDelete kept` (the read did not answer and the caret
   continuity of PLT-R423 kept an earlier answer, since the second retest of 16/11/2026) or `completion selected`; a
   rule with `axSelection` ends with `completion
   selected`, `completion none` or `completion unreadable` (since 15/11/2026; `completion unreadable then placeholder`
   with `axSelectionThenPlaceholder`, since 16/11/2026), each followed by the read's duration
   (`read 23.4 ms`, since 16/11/2026). Letters that still double with
   `forwardDelete skipped notAtEnd` while the caret is at the end mean the field counts its suggestion as text (next:
   `placeholder` after its PLT-R422 test); with `forwardDelete` and doubled letters, the field gives Forward Delete
   another meaning there. Type the first word right after Command+Space too: Spotlight answers slowly while it opens
   (16 to 21 ms at the retest of 16/11/2026, past the 15 ms bound the read had then), so `forwardDelete skipped
   unreadable` with a read of 50 ms there means the 50 ms bound of PLT-R423 is still too short for that Mac. Then type
   a long query quickly (`tieesng vieejt nam`) and Command+A with `vieejt` over it: later reads slow down while
   Spotlight searches (3.2, 14.6, 27.2 and more than 50 ms at the second retest of 16/11/2026), and their jobs should
   say `completion forwardDelete kept`; only the first deleting edit after a click, an arrow, a Command chord or a
   pause longer than 500 ms may still say `skipped unreadable`.

Runs of W8-A (folders under `/Volumes/Data/tart/runs/`):

| Run | Commit | Pass | Fail | What it showed |
|---|---|---|---|---|
| none yet | | | | Safari stayed open on the host from 17:07 to 18:56 host time on 2026-11-14 (checked before and during W8-A's 60-minute wait, Pa's VM rule), so no VM was booted and the lock was never taken; the four steps above are open |

### 10.7 Key-code-first composers (W8-F, 2026-11-14)

Wave 8 changed which keycode an edit types on (PLT-R405, amended by W8-B and W8-F): no Unicode event rides on a key
whose keycode carries an action of its own (Backspace, Return, keypad Enter, Tab, Space, Escape). An edit one of them
triggers (a Backspace re-composition, the commit at Return, Tab or Space, a restore on the Escape hotkey) types on the
keycode of a letter of the edit, and the trigger key follows once, as the replay of the physical key. The reason is
Chromium's (and WebKit's) key conversion: the DOM `code`, and for a non-ASCII character also the legacy `keyCode`,
come from the virtual keycode, so a chat composer that sends on `keyCode` 13 received the `ở` of an ENG-R532 commit at
Return as one more Return and sent the message before the word was finished.

`keycode-first-composer.html` models such a composer in TestHost's web view: its keydown listener deletes on
`event.code === "Backspace"` and sends on `event.code === "Enter"` whatever character the event carries, it types on
keypress, and it refuses every other edit. A send appends the marker `<send>` to the field (instead of clearing it), so
the readback shows each send once, in order. Both scenarios run on the default rules (no profile).

New TestHost scenarios (the suite goes from 44 to 46):

| Scenario | Keys | Expect | What a regression shows |
|---|---|---|---|
| `testhost.web.keycodeFirst.backspace` | `hoafn`, Backspace | `hòa` | an empty field: the `òa` of the W240 tone relocation rode on `kVK_Delete` and deleted (fixed by W8-B) |
| `testhost.web.keycodeFirst.returnCommit` | `thuowr`, Return | `thuở<send>` | `th<send><send><send>`: `u` and `ở` rode on `kVK_Return` (fixed by W8-F) |

`KeyCodeFirstComposerOracleTests` checks the two expectations against the real engine on every `swift test`;
`CommitTriggerKeyCodeTests` and `BackspaceEditKeyCodeTests` (Injection) model the same composer with fakes, per
trigger and strategy. VERIFY in the first VM run that WebKit's event conversion behaves like Chromium's for these
events (the page relies on `event.code` coming from the virtual keycode): the red run in step 2 below shows it.

Proof plan of W8-F, with Safari closed on the host (Pa's VM rule) and the VM lock taken:

1. `scripts/vm/integration-dev.sh` from this branch (expect 46 of 46 and a clean privacy scan);
2. the red run: from a throwaway worktree at the commit that adds the page and the scenarios, which comes before the
   PLT-R405 fix on this branch (`git log --oneline --reverse main..fix/w8f-integration-followups` lists it as
   `test(testhost): ...`), run `scripts/vm/integration-dev.sh --only 'testhost.web.keycodeFirst.*'` and expect
   `testhost.web.keycodeFirst.returnCommit` to fail with `th<send><send><send>` and the backspace scenario to pass
   (W8-B's fix is already in that commit);
3. three times `scripts/vm/integration-dev.sh --only 'testhost.web.keycodeFirst.*,testhost.web.composer'` from this
   branch, all passing.

Runs of W8-F (folders under `/Volumes/Data/tart/runs/`):

| Run | Commit | Pass | Fail | What it showed |
|---|---|---|---|---|
| none yet | | | | Pa was using the Mac (wave 8 integration, 2026-11-14), so no VM was booted; the three steps above are open |

### 10.8 A key released during the tone key's edit (W14-H, 2026-11-15)

Pa's dev traces of 14 and 15/11/2026 showed keys lost in a WKWebView messenger: when a key went up within one or two
milliseconds of the tone key, the tap held its keyUp while the tone key's edit was in flight and the worker replayed a
rebuilt keyUp; the next press of that key never reached the field. PLT-R311 is amended so the keyUp of a passed keyDown
always passes ([ADR 0322](../decisions/0322-passed-keyup-is-never-held.md)). `TestHost/Scenarios/rollover-keyup.json`
(`testhost.web.rolloverKeyUp`) reproduces the timing in TestHost: `d`, `u` down, `f` down 30 ms later, `u` up 0.3 ms
after `f` down, then `mucj` and Space, 50 trials, in the web textarea, the contenteditable and the native text view
(control), with a test-only rule for `local.testhost` that sets `interEventDelayUs` to 10 ms so the release lands inside
the edit on any machine.

The scenario schema has no raw-event step yet (`KeyEventPlan` makes fixed holds only), so `compat-harness` cannot run
it. Until it can, it is run by hand inside a test VM: post each event of the trial list from a `.hidSystemState` source at
`.cghidEventTap` with `userData` 0, at the listed offsets, into the focused field; read the field through AX after the
last trial; expect "dù mục " 50 times in each field. Run the build before ADR 0322 once (the red run: losses expected
in the web fields only) and the fixed build three times. Record the runs here.

| Run | Commit | Fields | Result | What it showed |
|---|---|---|---|---|
| none yet | | | | written by W14-H; not run (Pa was using the Mac, 2026-11-15) |

### 10.9 First full run since 13/11 (1.0.1-beta.1, 2026-11-19)

The first full run in the VM since 13/11 (clone `{{app-slug}}-dev-suite`, 4096 MB, 4 CPUs, started by the host's
resource watchdog) ran at `851a7c55`, the commit of 1.0.1-beta.1. The five failures of section 10.5 pass, which is the
first VM proof of the W7-A fixes. Three scenarios failed, and a control run with the probe followed (folders under
`/Volumes/Data/tart/runs/`):

| Run | Commit | Pass | Fail | What it showed |
|---|---|---|---|---|
| `20261118T182610Z-integration` (full suite) | `851a7c55` | 43 | 3 | `testhost.native.textView` gave `tieengs việt`, `testhost.panel.inlineCompletionTwice` gave `vieejt<esc>việt<esc>`, `testhost.sheetCell.columnAutocomplete` gave `Đ` (expect `Đức`) |
| `20261118T184158Z-integration` (`--probe --only testhost.native.telex,testhost.native.textView,testhost.native.vni,testhost.panel.inlineCompletionTwice,testhost.sheet.commandS,testhost.sheetCell.columnAutocomplete`) | `851a7c55` | 4 | 2 | `testhost.native.textView` gave `tieéng việt` and `testhost.sheetCell.columnAutocomplete` `Đ` again; the panel passed, with 43 ms between its focus notification and the first key reaching its field; the probe's observer on the freshly launched TestHost was refused for about 5 s, and {{AppName}} logged no state change for TestHost's reset or the text view |

Root causes, from the run logs, the probe and scratch HostRig reproductions, each checked a second time
independently; the product rows are fixed on branch `fix/v101-late-focus` (1.0.1-beta.2):

| Scenario | Root cause | Fix | Unit tests |
|---|---|---|---|
| `testhost.native.textView`, full run | A regression of the PLT-R340 late focus amendment (W8-A, after the run of 13/11). `testhost.native.telex` ends without a separator, so its word stays active, and the harness then focuses the text view through AX, with no key the tap sees. The change was observed within 500 ms of that word's last key, so the word was kept; the worker's check failed and the reset landed one key late, so the next word restarted at its second key (`ieengs` is no syllable and stays as typed) | When the previous snapshot named an element of the same process, the change must also be observed within 500 ms of the word's first key; after a previous snapshot without an element (a timed-out read, the PLT-R381 frontmost fallback) the last-key window stays alone (PLT-R340 amendment of 19/11/2026) | `LateFocusChangeTests` (`aWordThatStartedBeforeTheWindowIsAHardBoundaryPLTR340`, `aWordReopenedByBackspaceIsMeasuredFromItsFirstKeyPLTR340`, `aRealSnapshotAfterATimedOutReadKeepsAnOlderWordPLTR340`, `theFrontmostFallbackKeepsAnOlderWordPLTR340`) |
| `testhost.native.textView`, control run | TestHost, launched by the run's first scenario, refused observers for about 5 s on the loaded guest. The retries (about 6.3 s) ended, or were dropped while TestHost was momentarily not the owner, so none of TestHost's notifications arrived: the text view reached the tap only through the PLT-R382 read of the first key, which published it after the second key (`tieéng`) | After the scheduled attempts the app is asked every 2 s, at most 30 more times, while its observation is wanted; a skipped attempt keeps the chain; no call while its breaker is open; a publication of an unobserved owner asks again, once per activation; a best-effort observer without focused-element changes (the probe saw TestHost refuse that name alone while it accepted the others) keeps the chain going, with best-effort attempts, until a result with that name replaces it (PLT-R380 amendment of 19/11/2026) | `FocusSettleTests` |
| `testhost.panel.inlineCompletionTwice`, intermittent | A PLT-R389 trigger race: the scenario typed `v` 80 to 150 ms after Command+K, which the runner did not treat as a focus shortcut until the scenario declared it (section 10.10, `focusShortcuts`), and the panel's field was published after `v`. The field takes `launcher.spotlight`'s action, whose `lookaheadRevision` is off, so its variant differed from the mirror field's and the late keep was refused. Corrected on 19/11/2026 (second diagnosis): a hard boundary at `i` gives `v` + `iệt` = `việt`, so `vieejt` means that the second `e` itself went through raw (the panel field found at that key, with no edit to apply); the variant fix covers a case other than the one observed and does no harm. The `vieêjt` of the runs at `28aaa256` is a third case: the panel field was published only after the second `e`, whose edit was applied with the previous snapshot's plan (no inline-completion handling), so its Backspace removed the selected suggestion instead of `e`; no small product change repairs an edit already applied with the old plan, a limitation recorded with the lossless restart (fix B) | A kept late focus change into a variant that differs only in `lookaheadRevision` continues the word with the new variant's engine when that engine has committed nothing since its last reset (ENG-R1211 amendment of 19/11/2026, ADR 0306) | `LateFocusChangeTests` (`aChangeOfLookaheadRevisionAloneKeepsTheWordPLTR340` and the guards after it), `LookaheadRevisionContinuationTests`, `EngineCatalogTests` |
| `testhost.sheetCell.columnAutocomplete` | Not the product: since `5c7b8b27` (14/11) the `ax` readback leaves out a selection that runs to the end of the value in every scenario, and the cell rightly ends as `Đức` with `ức` selected (the control run's `screen.png`) | The harness (branch `fix/v101-ax-readback`, section 10.10): the readback leaves the selection out only where a scenario asks for it | `ReadbackRouterTests`, `ScenarioFilesTests` |

Left for later: a late check that fails still resets the word one key late (PLT-R340, "the hard boundary, applied one
key late"), so the next word can restart in its middle wherever a late keep is wrong; restarting at the key that
carried the check is the follow-up. A panel of another process (Spotlight on macOS 27.2, `com.apple.campo`) published
after the first key is still an application change.

Content-free records added for these runs (`integration-out/app-diagnostics.jsonl`, PLT-R901). Since `fix/v101-focus-identity`
the `at` of a record the tap wrote (the two late focus codes and the tap's notes) is the time of the event, converted
from the tap's monotonic clock when the record is drained, not the time of the drain (records are often drained in one
batch at terminate), so lines can appear out of order: sort by `at` to read a session. The `reason` field is new with
that branch too; a record written before it has none.

| Code | Fields | Written when |
|---|---|---|
| `focus.lateFocusKept` | `sinceLastKeyUs`, `sinceWordStartUs`, `reason` | a focus change found after keys of the active word kept it; microseconds from the word's last and first key to the new snapshot's `changedAt` (0 when it came before the key); `reason`: `window` (a readable element within the windows, checked by the first job), `trigger` (the same, with the first-key window waived after a Command or Control shortcut or a click, PLT-R389), `unreadable` (a snapshot of the same process without a readable element, no check), `sameElement` (the element the word is in, found again after a snapshot without it: no focus change), `backFromNoElement` (the same element found again after Accessibility answered that no element had the focus, with keys of the word composed meanwhile: checked by the first job) |
| `focus.lateFocusRefused` | `sinceLastKeyUs`, `sinceWordStartUs`, `reason` | such a change ended the word; `reason` names the check: `otherProcess`, `noElement` or `axUnavailable` (no readable element where one is needed, after a timed-out read without an app), `paused`, `variant`, `lastKeyWindow` (more than 500 ms after the word's last key), `firstKeyWindow` (more than 500 ms after its first key, after an element of the same process and without a trigger before the word) |
| `focus.lateFocusCheckFailed` | none | the worker found the new element without the kept word; the key passed and the word was reset |
| `focus.observerAttempt` | `pid`, `attempt`, `result` (`installed`, `installedBestEffort`, `refused`, `notWanted`, `breakerOpen`) | one observer attempt; a first attempt that installs is not logged, and of the slow attempts only an install and the chain's last attempt are; `installedBestEffort` may lack some names, and when it lacks focused-element changes the chain goes on until an install with them replaces it (`installed` when it has every name, `installedBestEffort` when it lacks another one); a best-effort result without them over such an observer is logged as `refused` |

Proof plan of `fix/v101-late-focus`, with the VM rules of this section (resource check and watchdog), in this order:

1. twice `scripts/vm/integration-dev.sh`: expect 45 of 46 with this branch alone (`testhost.sheetCell.columnAutocomplete`
   is the harness row) and 46 of 46 with the harness branch (section 10.10) merged too, and a clean privacy scan;
2. three times `scripts/vm/integration-dev.sh --probe --only testhost.native.burst,testhost.native.telex,testhost.native.textView,testhost.panel.inlineCompletionTwice`
   (TestHost warm, as in the full run): `testhost.native.textView` passes, its first key leaves either no late focus
   record or a `focus.lateFocusRefused` with `sinceWordStartUs` above 500000, and no `focus.lateFocusCheckFailed`
   follows;
3. three times the control run's command above (TestHost launched by the first scenario): `testhost.native.textView`
   passes; when TestHost refuses its observer, `focus.observerAttempt` lines with its pid end with `installed` (or
   `installedBestEffort` not followed by further attempts), and `host.state` lines follow TestHost's reset and the text view;
4. five times `scripts/vm/integration-dev.sh --only testhost.panel.inlineCompletionTwice,testhost.panel.toneUndo,testhost.sheet.commandS,testhost.web.editModeEditor`:
   every run passes; a panel field published after the first key shows `focus.lateFocusKept` and no
   `focus.lateFocusCheckFailed`.

| Run | Commit | Pass | Fail | What it showed |
|---|---|---|---|---|
| `20261118T213407Z-integration` (full suite) | `28aaa256` | 46 | 0 | first full pass of the suite in the VM; `testhost.sheet.commandS` logged `focus.lateFocusKept` with `sinceLastKeyUs` 122643 and `sinceWordStartUs` 228300, found at `u` (228 of the 500 ms of the first-key window used) |
| `20261118T214901Z-integration` (full suite) | `28aaa256` | 44 | 2 | `testhost.panel.inlineCompletionTwice` gave `vieêjt` (`focus.lateFocusKept` with `sinceLastKeyUs` 0 and `sinceWordStartUs` 247386, then `focus.lateFocusCheckFailed`); `testhost.sheet.commandS` gave `đuơngf` with no late focus record for the sheet's field (its only record was the previous scenario's word, refused at `sinceWordStartUs` 1184179: fix A working as intended) |
| `20261118T220253Z-integration` (`--probe --only` of step 2 above) | `28aaa256` | 3 | 1 | the panel passed; `testhost.native.burst` gave `nguyễn nguyeẽn nguyễn` (`focus.lateFocusKept` with both intervals at 653 µs, then `focus.lateFocusCheckFailed`); the next run, `20261118T221229Z`, broke on infrastructure (the development build had updated itself to 1.0.0) and is no evidence |

Root causes of the failures at `28aaa256`, from the run logs, the probe and the fixed key plan of seed 1592642302
(every run types the same keys at the same planned times, so all variation between runs is the guest's latency), each
checked against the code; fixed on branch `fix/v101-focus-identity`:

| Scenario | Root cause | Fix | Unit tests |
|---|---|---|---|
| `testhost.native.burst` (`nguyeẽn`), probe run | Older than fixes A, C and D (it comes from the W8-A keep and its check). TestHost had just been launched by the run and was busy: the notification read after the harness's `focusField` timed out and still published a snapshot without the field. The first key's read (PLT-R382) found the same field, which the `ax` thread then published under a new identity, because it compared only with the last publication; the tap took it for a focus change, kept the word (last-key window, 0.65 ms) and queued the check. The check read the field about 5 ms after the tap passed `n` through, before TestHost had inserted it (or got no answer), and failed; the reset, applied at the next key the tap handled, landed on the second `e` of the second word | The same element is no focus change: the `ax` thread keeps the last element, its identity and focus time across publications without an element of the same process or no process; the tap keeps the last element identity across snapshots without one, and the same identity again is the same owner (no boundary, no check, decision compared with the element's own). The check reads once more after 50 ms when it found the caret before the word, other text or no answer (PLT-R340 second amendment of 19/11/2026) | `FocusSnapshotPublicationTests` (`theSameElementAfterATimedOutReadKeepsItsTokenPLTR340` and the three after it), `LateFocusIdentityTests` (`theSameElementAgainAfterAnUnreadableSnapshotIsNoFocusChangePLTR340` and the guards after it), `WorkerLateFocusTests` (`aFieldStillCatchingUpIsReadAgainAfterTheSettleWindowPLTR340` and the two after it) |
| `testhost.sheet.commandS` (`đuơngf`), full run | Not fix A. TestHost's focus notification read hit the 100 ms timeout while it attached the sheet (or AX named no focused element at that moment) and published a snapshot of TestHost without an element between `u` and `o`. The keep checks refused it before anything was logged, an unlogged hard boundary at `o`; the timeout also cancelled the settle and trigger reads, so the sheet's field never reached the tap before `f` | A snapshot of the same process without a readable element that pauses nothing keeps the word within the windows, without a check, and the next snapshot is judged against the element the word began in. Hidden risk of fix A on a slow guest (the sheet's field published more than 500 ms after `d`, which would give `đươngf`): a word that began within 500 ms after a Command or Control shortcut or a click (PLT-R389) the tap saw after the previous element was observed is measured from its last key only, with the check (PLT-R340 second amendment of 19/11/2026; Return, Tab and Escape do not count since the review of the same day) | `LateFocusIdentityTests` (`aSameProcessSnapshotWithoutAReadableElementKeepsTheWordPLTR340`, `aWordTypedAfterATriggerIsMeasuredFromItsLastKeyPLTR340`, `theSheetFieldAfterATimedOutReadAndATriggerKeepsTheWordPLTR340`, and the guards `aWordThatStartedBeforeTheWindowIsAHardBoundaryAfterAnUnreadableSnapshotPLTR340`, `aTriggerThatDidNotPrecedeTheWordDoesNotWaiveTheFirstKeyWindowPLTR340`) |
| `testhost.panel.inlineCompletionTwice` (`vieêjt`), full run | The panel's field was published only after the second `e`, whose edit had been applied with the main field's plan (see the corrected row above); the word was kept at `j`, its check expected `viê` and read `…ieê` | None in the product (fix B's limitation). The harness side: the scenario now declares `command+k` as its focus shortcut (section 10.10; section 10.6: the scenario proves the overlay rule and the completion handling, not the trigger race) | none |

Diagnostics added with the fix: every refusal by the keep checks now names its check in `reason` (until now a refusal
by the process, element, pause or variant check left no record at all, which hid the cause of `đuơngf`), and the `at`
of these records is the time of the key that found the change.

Review of the branch (19/11/2026), each point with a unit test in `LateFocusIdentityTests` or `WorkerLateFocusTests`:

- Only a Command or Control shortcut or a click waives the first-key window (`FocusRevalidation.mayMoveFocusLater`).
  Return, Tab and Escape move the focus at once, so the read they ask for already finds their element, and most often
  they move nothing: Return, a word right after it, and an Accessibility move into another field of the same process
  660 ms into that word had been kept with `reason` `trigger` and a failing check, the `tieengs` shape of the
  `textView` row (`aTriggerThatMovesTheFocusAtOnceDoesNotWaiveTheFirstKeyWindowPLTR340`).
- The element found again after Accessibility answered that no element had the focus (an available snapshot without
  one: no focused element, the PLT-R381 frontmost fallback), with a key of the word composed after that answer, is kept
  with a check (`reason` `backFromNoElement`), because that key may not have gone into it and the next edit's Backspace
  would delete the field's own text. Timed-out and failed reads teach nothing and still give `sameElement` without a
  check, which is the `testhost.native.burst` case.
- A failed system-wide read without an app keeps the last element on the tap as it does on the `ax` thread
  (`FocusIdentity.appUnknown` next to `FocusCore.keepsLastElement`), so the element found again is no application
  change.
- A check still due when a snapshot without a readable element keeps the word waits for a readable snapshot, instead
  of running against no field and logging `focus.lateFocusCheckFailed` without a read.
- The check's settle window is judged when its first read starts: a slow first read (two bounded calls, the second
  timing out, about 60 ms) is read again at once when it ended at most 30 ms after the window, 140 ms after the key at
  most (PLT-R314).

Trade-off kept (review point): the first-key window also applies to a snapshot of the word's own process without a
readable element when the word began in an element of that process. A notification read that times out more than
500 ms after the word's first key, with no shortcut or click before the word, therefore still ends the word with
`reason` `firstKeyWindow` (at about 100 ms per key, from the sixth key on), although the element may not have changed.
The alternative, the last-key window alone for such snapshots and the first-key window judged later against the
word's element, would keep the word of the `textView` case typed on until the new field shows up and reset it one
key late, which `aWordThatStartedBeforeTheWindowIsAHardBoundaryAfterAnUnreadableSnapshotPLTR340` forbids. The fix of
`đuơngf` therefore covers a timed-out read within 500 ms of the word's first key, or after a shortcut or click; a later
one splits the word as before this branch. A run that shows `focus.lateFocusRefused` with `reason` `firstKeyWindow`
right after a timed-out read inside a scenario's own word is this case.

Proof plan of `fix/v101-focus-identity`, with the VM rules of this section, in this order:

1. three times `scripts/vm/integration-dev.sh --probe --only testhost.native.burst,testhost.native.telex,testhost.native.textView,testhost.panel.inlineCompletionTwice`
   (each run is a throwaway clone, so the burst runs right after TestHost's launch, as in `20261118T220253Z`):
   `testhost.native.burst` passes; when a timed-out read precedes the burst, its first word shows
   `focus.lateFocusKept` with `reason` `sameElement` and no `focus.lateFocusCheckFailed` follows;
2. five times `scripts/vm/integration-dev.sh --probe --only testhost.sheet.commandS,testhost.native.textView`:
   both pass; a sheet field found late shows `focus.lateFocusKept` with `reason` `window` or `trigger` (with
   `sinceWordStartUs` above 500000 for `trigger`), a timed-out read in the sheet shows `reason` `unreadable` before
   it, and `testhost.native.textView` shows either no late focus record or `focus.lateFocusRefused` with `reason`
   `firstKeyWindow`;
3. twice `scripts/vm/integration-dev.sh`: 46 of 46 and a clean privacy scan; `testhost.panel.inlineCompletionTwice`
   may still fail with `vieêjt` until the harness change of the row above lands (that failure shows
   `focus.lateFocusKept` with `reason` `window` and a small `sinceLastKeyUs`, then `focus.lateFocusCheckFailed`); no
   `focus.lateFocusRefused` with `reason` `otherProcess`, `noElement`, `axUnavailable`, `paused` or `variant` should
   fall inside a scenario's own word.

### 10.10 Readback of a selected completion (2026-11-19)

The first full run of the suite in the VM since 13/11/2026 (`20261118T182610Z-integration`, 19/11/2026 at 01:26 host
time, commit `851a7c55`, the 1.0.1-beta.1 release, 4096 MB) passed 43 of 46. `testhost.native.textView` and
`testhost.panel.inlineCompletionTwice` failed in the app's input pipeline and are fixed separately; the third failure
was the harness:

| Scenario | Root cause | Fix | Tests |
|---|---|---|---|
| `testhost.sheetCell.columnAutocomplete` (`Đ` for `Đức`, 2 runs of 2; it passed on 13/11/2026 at `db9e6a1`) | Not the app. The cell completed `D` to `Dức` with `ức` selected; the `axSelection` edit added its extra Backspace for the selection, removed `D` and inserted `Đ`, and the cell completed again to `Đức` with `ức` selected (the control run's probe ends with `selection=1,2 characters=3` on the cell; its `screen.png`, taken after this last scenario, shows `Đức` with `ức` selected and `Dropped keys: 0`). Commit `5c7b8b27` (14/11/2026), written for Spotlight's history completion, made `LiveAXFieldReader` leave a selection running to the end of the value out of every `ax` scenario, so the readback returned `Đ`. No suite run reached the VM between that commit and this run. | `LiveAXFieldReader` returns the whole value and the selection; `ReadbackRouter` leaves the selection out only for a scenario that declares `readbackOptions.excludesSelectedCompletion` (PLT-R530, amended 19/11/2026): the five `launcher.spotlight*` scenarios and the three browser address bars with seeded history (runner only, never run in a VM). The PLT-R422 residue check reads the whole value either way. The failure focus report now ends with `focused selection: <location>,<length>` and `focused characters: <n>` (numbers only), so the next mismatch tells a left-out completion (3 characters, `1,2`) from a lost one (1 character, `1,0`) without the probe. | `ReadbackRouterTests`, `ScenarioFilesTests.noTestHostScenarioExcludesASelectedCompletionQaR21`, `ScenarioFilesTests.historyCompletionsAreDeclaredByTheLaunchersAndAddressBarsPltR530`, `ScenarioRunnerTests.theResidueCheckReadsTheFullTextPltR422`, `AXReadbackTextTests.focusReportLinesCarryNumbersOnlyPltR901` |

The runs of 19/11/2026 are in the table of section 10.9. Proof plan, with the VM rules of this section:

1. `scripts/vm/integration-dev.sh --memory 4096 --only testhost.addressBar.telexStroke,testhost.addressBar.telexTone,testhost.addressBar.vni,testhost.sheetCell.columnAutocomplete`:
   expect 4 of 4, the cell read back as `Đức` in about 2 s, and a final `screen.png` showing `Đức` with `ức` selected
   (the address bars end without a selection, so the whole-value readback leaves them as they were);
2. the full suite of section 10.9 step 1 covers the rest. Record every run in the table of section 10.9. A mismatch's
   evidence file now gives the selection and character count of the focused field.

#### The test build updated itself in the middle of a run (2026-11-19)

Run `20261118T221229Z-integration`: the `Integration` build (bundle ID `APP_BUNDLE_ID_DEV`, version 0.1.0, build 1)
found 1.0.0 (build 1000099) on the production appcast at launch, installed it and relaunched as the release app
(`APP_BUNDLE_ID`, 1.0.0), and every scenario after it failed with `no application with bundle id` of the test build.
`Config/Integration.xcconfig` and `Config/Debug.xcconfig` include `Config/Sparkle.xcconfig`, whose feed is the
production appcast, and `App/Info.plist` sets `SUEnableAutomaticChecks` and `SUAutomaticallyUpdate`; on factory
defaults D19 and D20 are on. Since 1.0.0 was published on 18/11/2026 any run can hit it, racing the harness's
relaunches.

| Part | Change | Tests |
|---|---|---|
| Harness | Every settings file the harness writes (`AppSettingsDocuments.documents(for:onboarding:)`, factory configuration and every profile) sets `automaticallyCheckForUpdates` and `automaticallyInstallUpdates` to `false` (`AppSettingsDocuments.harnessDefaults`); a profile that sets either keeps its value | `AppSettingsDocumentsTests.everyDocumentTurnsTheAutomaticUpdateCheckAndInstallOffPltR1101`, `AppSettingsDocumentsTests.aProfileThatSetsAnUpdateSwitchKeepsItsValuePltR1101`, `RepositoryProfileTests.settingsStoreReadsTheUpdateSwitchesOffPltR1101` (read back by the real SettingsStore) |
| VM guest | `scripts/vm/guest/integration-guest.sh` seeds `settings.json` with both switches off beside the onboarding state when the file does not exist yet, for a launch before the harness's first apply, a run with `--no-configure` and the settings the harness restores after the run. A file that predates the seed (a disk image snapshotted after a launch of the app) keeps its switches | `IntegrationGuestTests.test_the_seeded_settings_turn_the_automatic_update_check_and_install_off` |
| Harness restore | `SettingsFileAppConfigurator.restore()` puts the backed-up files back and starts the test build again only when it was running before the first apply, so the harness adds no launch with the restored switches after the run (the VM guest script does not start the test build before the suite) | `SettingsFileAppConfiguratorTests.restoreLeavesTheAppStoppedWhenItWasNotRunningBeforeTheRunPltR1101`, `SettingsFileAppConfiguratorTests.applyBacksUpOnceWritesAndRestartsThenRestorePutsEverythingBack` |
| Runner setup | Section 2 step 9 turns both switches off in the settings file before the test build's first start: once Sparkle has found an update at a start with D20 on, turning the switches off in the About pane no longer stops the install on quit | none (a manual step) |

Why that is enough: the launch sequence loads the settings before it starts the updater
(`Packages/AppCore/Sources/InputHost/Integration/LaunchSequence.swift` lines 97 and 108); `startUpdater` applies the
stored D19 to D21 and only then starts Sparkle (`App/Sources/Composition/AppEnvironment.swift` lines 302 and 303);
`UpdaterController.start()` pushes them into the driver (`App/Sources/Updater/UpdaterController.swift` line 92, the
setters at lines 159 and 162) before `driver.start()` (line 94). Sparkle starts with automatic checks off, so it
schedules no check. Forced checks keep working: the egress test's `checkForUpdates` hook (section 5) calls
`UpdaterController.checkForUpdates()`, which calls Sparkle's user-initiated `checkForUpdates()` (lines 133 to 136);
Sparkle runs it whatever D19 and D20 say, and shows its update window instead of installing silently. Safe mode
(PLT-R1009) reads no files, so a test build that starts in safe mode still has both switches on; a guard in the
product for development builds is not part of this change.

Proof, with the VM rules of this section: the full suite (section 10.9 step 1) must keep the test build's bundle ID
from the first scenario to the last: no `no application with bundle id` reason in `tests.log`; in
`app-diagnostics.jsonl` no `update.checkStarted` record with `"manual":false` (an automatic check), no
`update.updateFound` and no `update.installingNow`; and the test build in `~/Applications` still at version 0.1.0
after the run.

#### The search panel scenario waits for each opening (2026-11-19)

`testhost.panel.inlineCompletionTwice` typed `v` 80 to 150 ms after Command+K, because the runner waited only after
Command plus a digit, and the panel's field was sometimes published after `v` (the intermittent row of section
10.9). As section 10.6 says, the scenario proves the overlay rule and the inline completion handling on both
openings, not the trigger race; the race itself stays a product limitation, recorded with that row's fix (an edit
already applied with the previous snapshot's plan cannot be repaired).

| Part | Change | Tests |
|---|---|---|
| Scenario schema and runner | A scenario may list chords of its `keys` in `focusShortcuts` (`compat/schema/scenario.schema.json`, `Scenario.focusShortcuts`); the runner treats each like Command plus a digit: typed on its own, then a wait for the app's next focus snapshot and 300 ms. `ScenarioValidator` accepts only chords that `keys` types, each once; the dry-run plan prints a `focus shortcuts:` line for such a scenario | `ScenarioRunnerTests.aDeclaredFocusShortcutWaitsLikeCommandDigitPltR530`, `ScenarioLoadingTests.decodesFocusShortcuts`, `ScenarioLoadingTests.focusShortcutsMustBeChordsOfTheKeyScript`, `HarnessDryRunTests.dryRunShowsDeclaredFocusShortcuts`, `ScenarioFilesTests.validatorKeysAreTheSchemaProperties` |
| Scenarios | `testhost.panel.inlineCompletionTwice` declares `command+k`, so both openings wait; `testhost.sheet.commandS` declares nothing and keeps typing right after Command+S (T5.5: the product must handle it, PLT-R340 late focus change); `testhost.panel.toneUndo` declares nothing on purpose and keeps typing `t` right after Command+K: with `inlineCompletionTwice` waiting, it is the one panel scenario left where the field can be published after the first key, so it keeps the product side of that race covered (the PLT-R340 keep into the `launcher.spotlight` variant and the ENG-R1211 continuation of 19/11/2026, proof step 4 of section 10.9: `focus.lateFocusKept`, no `focus.lateFocusCheckFailed`); it has no inline completion for a late field to break | `ScenarioFilesTests.onlyThePanelReopeningWaitsForItsFocusShortcutT55` |

Proof, with the VM rules of this section: five times `scripts/vm/integration-dev.sh --only
testhost.panel.inlineCompletionTwice,testhost.sheet.commandS`: both pass every time, `dry-run.log` shows `focus
shortcuts: command+k` under the panel scenario only; with `--probe`, each focus notification of the panel's field in
`probe.log` comes at least 300 ms before the first change of that field.
