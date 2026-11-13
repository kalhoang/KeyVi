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

Remaining failures and their next step:

| Scenario | Observed | Root cause (as far as the VM shows) | Next step |
|---|---|---|---|
| `testhost.addressBar.telexStroke` | `dđ` for `đ` | Product, inline completion: after `d` TestHost's simulated address bar completes to `dd.example` with `d.example` selected (Chromium behaviour); on the second `d` the app's edit deletes only the selected completion and inserts `đ`, so the first `d` stays. The focus report shows the right field (`testhost.sim.addressBar`, rule `user.testhost.addressBar` -> `browser.chromium.addressBar`) | Owner of `InputHost`/`Injection` (W6-A): reproduce with a typing trace of this scenario in the dev VM and check how the `inlineCompletion` handling of `browser.chromium.addressBar` counts deletions when a completion is selected (one deletion clears the selection, the base letter needs another) |
| `testhost.addressBar.telexTone` | `aá` for `á` (earlier runs `asia.example`) | Same field and the same missing deletion (`a` completes to `asia.example`; the tone edit clears the selection and appends `á`) | Same as the row above |
| `testhost.privacyCanary.paste` | a space only, for `kanaryzqx ` | Product or VM: the user rule's `paste` strategy runs (user rules count as opted in, `FocusCore`), but nothing reaches TestHost's plain field, so the composed letters disappear and only the space passes. Either the pasteboard is restored before TestHost reads it on the synthetic Command+V (`restoreDelayMs` 400) or macOS 27's pasteboard privacy blocks a paste a synthetic key triggers | In the dev VM: run the scenario alone with `log stream --predicate 'subsystem == "com.apple.pasteboard"'` open; try a profile with a larger `restoreDelayMs`; owner of `Injection` (W6-A) |
| `testhost.perWindowRule.mainWindow`, `testhost.web.editModeTransition` (intermittent: passed in runs 4, 5 and 7 and in `20261113T205703Z`; `web.editModeTransition` failed in run 8 and in `20261113T213424Z`, `perWindowRule.mainWindow` in run 8) | first word after the focus change untransformed (`vieetj việt`, `Dd`) | Same cause as the `web.textarea` row below, but only sometimes: the app's T6 count did not grow within the harness's 2 s wait after Command+1 (back from the second window's pass-through field) or after the page's editor took focus, so the first keys met the previous field's rule | Same as the row below; the harness can only wait for the refresh, not cause it |
| `testhost.web.textarea` | first word untransformed (`tieengs việt`) | Product, focus refresh for web content: after the focus moves from the page's input (previous scenario) to its textarea the app publishes no new focus snapshot within 2 s (the harness waits for its T6 count, the waits time out), so the first word is decided on the previous snapshot; the PLT-R382 idle revalidation on the first key catches up for the second word. Not TestHost: the scenario passes alone on a fresh TestHost and fails after `testhost.web.input` also on a freshly loaded page (control runs above) | Owner of `InputHost` (W6-A): reproduce with `scripts/vm/integration-dev.sh --only testhost.web.input,testhost.web.textarea` and a typing trace; check whether `FocusCore` receives `AXFocusedUIElementChanged` from WebKit, or treats the new element as the same field, when focus moves from one element of a `WKWebView` page to another after a blur (T6 counts in the hooks `state`) |
| `testhost.web.inlineAutocomplete` (intermittent: failed in `20261113T205703Z`, passed in the runs before and after) | `asia.example` or `aá` for `á` | Same inline completion edit as the `addressBar` rows: when the page's simulated completion is selected at the time of the tone key, the edit is one deletion short | Same as the `addressBar` rows |

None of these needs the Apple Development identity or Pa's Mac. The privacy scan has passed (no finding, no unreadable
or vanished file) in every run since the second.

