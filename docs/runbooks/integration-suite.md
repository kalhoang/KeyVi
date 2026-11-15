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
6. marks onboarding as finished in the test build's settings file (section 2 step 9);
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
(expect `tiếng`). Their `ax` readback, like `launcher.spotlight`'s, returns the value without a selected
completion that runs to its end (`AXReadbackText`): Spotlight with history shows `text` as `TextEdit` with `Edit`
selected, which is the completion the extra Backspace of PLT-R420 removes, not text that was typed.

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
   forwardDelete skipped unreadable` or `completion selected`; a rule with `axSelection` ends with `completion
   selected`, `completion none` or `completion unreadable` (since 15/11/2026). Letters that still double with
   `forwardDelete skipped notAtEnd` while the caret is at the end mean the field counts its suggestion as text (next:
   `placeholder` after its PLT-R422 test); with `forwardDelete` and doubled letters, the field gives Forward Delete
   another meaning there.

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
