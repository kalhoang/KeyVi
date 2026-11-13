# Runbook: self-hosted macOS runner for integration tests

Owner: the maintainer. Specification: QA-R10 to QA-R13, QA-R16, QA-R40, spec/02-platform.md sections 8.4 and 13.2. Open decision 16 (which Mac, always on or not) is Pa's.

Platform integration tests post synthetic key events through the real pipeline into `TestHost/`. How to run the
suite, read its results and update the performance baseline: [integration-suite.md](integration-suite.md). That needs Accessibility (and maybe Input Monitoring) permission, which GitHub-hosted runners cannot be assumed to grant, so a Mac under Pa's control runs them (QA-R12). Because that Mac holds granted permissions, it is a sensitive machine (QA-R13).

This runbook does not change any system setting by itself. Steps that change settings are for Pa to do on the runner machine.

## 1. Choose the machine

- Preferred: a dedicated Mac mini (Apple silicon) that stays on, with the newest macOS the project supports (QA-R23). A second Intel or older-macOS machine is optional for the matrix.
- Acceptable: Pa's own Mac overnight, using a separate standard macOS user account for the runner so that Pa's data and the runner's grants stay apart.
- Pin the Xcode version with `xcode-select` to the one recorded in the CI workflow (QA-R23). Install XcodeGen and Swift toolchain components the workflows need.

## 2. Security rules (QA-R13)

The runner MUST only run workflows from `main` and from release tags of this repository, never from pull requests from forks.

1. Register the runner at the repository level (Settings, Actions, Runners, New self-hosted runner), not at an organisation or user level that other repositories can use. Give it exactly the labels `integration.yml` asks for: `self-hosted`, `macOS`, `ARM64`, `tcc-granted` ([ADR 0503](../decisions/0503-release-pipeline.md); `scripts/actionlint.yaml` declares `tcc-granted`).
2. In `integration.yml`, trigger only on `push` to `main`, release tags (`v*`) and `workflow_dispatch`. Never on `pull_request` or `pull_request_target`. Add a guard on every job:

   ```yaml
   if: github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/v')
   ```

3. Repository settings: Actions, General, "Fork pull request workflows from outside collaborators": require approval for all outside collaborators, and do not send secrets to workflows from forks.
4. Run the runner service as a **non-administrator** macOS user. Do not store release secrets, the Sparkle key, notarization keys or signing certificates on this machine. It builds with the Apple Development identity and the `.dev` bundle ID (PLT-R751) only.
5. Pin third-party actions by full commit SHA (QA-R24).
6. Keep the machine patched; update the runner application when GitHub announces a new version.

## 3. Install the runner

1. Create the runner user and sign in to it once in a normal GUI session.
2. Download the runner package from the repository's "New self-hosted runner" page and verify its SHA-256 as shown there, then configure it as shown there with the repository URL and the registration token (a short-lived token; never commit it).
3. Install it as a service so that it starts at login (`./svc.sh install` and `./svc.sh start` in the runner directory). Event posting needs a logged-in GUI session, so run it as a LaunchAgent of the logged-in runner user, not as a system daemon.
4. For unattended use (Pa's decision, these are system settings on the runner machine): enable automatic login for the runner user, keep the display awake while a job runs, and avoid lock and screen saver during test runs. A locked screen stops synthetic events from reaching the test host.
5. Set the runner environment (section 3.1) and start the helper services (section 3.2).
6. Confirm the workflow `integration.yml` picks up the runner by running it manually with `workflow_dispatch` on `main`.

### 3.1 Runner environment: the live harness opt-in

`compat-harness` posts synthetic events, launches apps and switches input sources only on a machine that opts in. Its `run`, `soak` and `bench` commands build their live services only when the environment contains `COMPAT_HARNESS_LIVE=1` (exactly `1`); otherwise they exit with status 3 before touching anything. `--dry-run` never needs the opt-in. `scripts/run-integration.sh build|tests|compat|soak|bench` checks the variable first (`build` because it replaces the installed test build) and stops with a pointer to this section.

Export the variable **only on this runner**, in the `.env` file of the runner application. The runner reads that file when its service starts, so the opt-in belongs to the machine rather than to a workflow: a job that lands on any other runner, or a copied command line on a development Mac, cannot post events. Do not set it in a workflow `env:` block, a repository or organisation variable, or the shell profile of a development Mac.

1. In the runner directory (the one that contains `config.sh` and `svc.sh`), create or edit `.env` with this line:

   ```sh
   COMPAT_HARNESS_LIVE=1
   ```

   One `NAME=value` per line, without `export` or quotes. The file holds no secret; keep it readable only by the runner user (`chmod 600 .env`). `scripts/run-integration.sh` compares with `perf/platform-baseline.json` by default; a `PLATFORM_BASELINE=...` line is needed only to test another baseline (ADR 0502, "Platform baseline and measurements").
2. Restart the service so the runner reads it: `./svc.sh stop`, then `./svc.sh start`.
3. Check it: run `integration.yml` with `workflow_dispatch` on `main`. If the file was not read, the compatibility step stops at once with "COMPAT_HARNESS_LIVE=1 is not set".

GitHub documents the runner's `.env` file in "Running scripts before or after a job" (self-hosted runners). VERIFY on the runner that the variable reaches the job steps (step 3 shows it).

### 3.2 Helper services for compatibility scenarios

The harness command lines that `scripts/run-integration.sh` runs (contract: [ADR 0502](../decisions/0502-fuzz-benchmark-coverage-contracts.md)), with what each needs from this machine:

```sh
# Environment: COMPAT_HARNESS_LIVE=1 from the runner's .env (section 3.1), never set by a workflow.
# WebDriver readback: chromedriver on its default endpoint http://127.0.0.1:9515 (no flag needed).
scripts/run-integration.sh build   # Integration configuration (INTEGRATION_HOOKS) and TestHost into ~/Applications
swift run --package-path Packages/AppCore -c release compat-harness run --scenarios compat/scenarios --only 'testhost.*' --output <dir>
swift run --package-path Packages/AppCore -c release compat-harness run --scenarios compat/scenarios --output <dir>
swift run --package-path Packages/AppCore -c release compat-harness soak --keystrokes 1000000 --output <dir>
swift run --package-path Packages/AppCore -c release compat-harness bench --runs 5 --output <file.json>
```

- **chromedriver** listening on its default endpoint `http://127.0.0.1:9515`. Every `webdriver` scenario without a `--webdriver BUNDLE=URL` entry reads the page back through that endpoint, and CI passes no `--webdriver`. Install the chromedriver that matches the installed Chrome and keep it running as the runner user before `compat` and `soak` start (for example as a LaunchAgent of the runner user). Other drivers, such as `safaridriver --port N`, need an explicit `--webdriver BUNDLE=URL` passed through `COMPAT_HARNESS_RUN_ARGS` or `COMPAT_HARNESS_SOAK_ARGS`. The harness talks only to loopback endpoints.
- A loopback HTTP server on port 8000 for the `seedHistory` scenarios, plus the enabled input sources, text-substitution settings and app states listed in [compat/scenarios/README.md](../../compat/scenarios/README.md).
- English as the runner user's language (the harness presses the "Secure Keyboard Entry" item of the Terminal and iTerm2 app menus by its title), onboarding of the test build finished once by hand, and the test build of `scripts/run-integration.sh build` (configuration `Integration`, compiled with `INTEGRATION_HOOKS`) so the harness can read the app's state, trigger the tap-timeout and permission hooks and read its histograms. The Apple Development certificate of `Config/Signing.xcconfig` must be in the runner user's login keychain for that build. The complete list: [integration-suite.md](integration-suite.md) section 2.
- The harness rewrites the test build's settings files for each scenario's configuration (`compat/scenarios/profiles/`) and restores them after the run; it touches nothing else of the runner user.

## 4. Pre-grant permissions to the stable-signed test build (TCC)

The test build must be signed with a **stable** signing identity (an Apple Development certificate and the dev bundle ID `vn.kal.<slug>.dev`, never ad-hoc). macOS ties a permission grant to the code's designated requirement; an ad-hoc signature changes with every build and would make the grant disappear after each build (PLT-R750, PLT-R751).

Grant once, by hand, as the runner user:

1. Build the test version of the app and the test runner once on the runner machine, signed with the stable identity: `COMPAT_HARNESS_LIVE=1 scripts/run-integration.sh build` installs the `Integration` build into `~/Applications/` (or `$INTEGRATION_APP_DIR`) and the workflows always rebuild to the same path. Build the harness with `swift build --package-path Packages/AppCore -c release --product compat-harness`.
2. Open System Settings, Privacy & Security, **Accessibility** (called "Device Control and Data Access" on macOS 27; VERIFY the names on each installed macOS) and switch on:
   - the app under test (the dev-signed menu-bar app), and
   - the compatibility harness `Packages/AppCore/.build/release/compat-harness` of the runner's checkout, which posts the events, reads fields through AX and presses menu items (VERIFY whether macOS holds the runner's `Runner.Worker` responsible instead; grant it too if the harness grant does not take). TestHost needs no permission.
3. If macOS asks for **Input Monitoring** for the tap, grant it the same way (PLT-R702).
4. Do **not** edit the TCC database directly. Doing so needs SIP disabled, which is not acceptable for this project. If the machine is managed, a PPPC configuration profile can pre-approve Accessibility and event posting for the specific code requirement ([managed Macs](../support/managed-macs.md), PLT-R760; a profile for the dev build names the `.dev` bundle ID and its Apple Development requirement); a profile still requires the user's approval in System Settings on an unmanaged Mac.
5. Run the preflight (a workflow step at the start of `integration.yml`) that checks `AXIsProcessTrusted()` and the post-event preflight for the test binaries and fails with the message "permissions not granted to the test build" rather than failing later in a confusing way.

When a grant goes stale (after a macOS update, a changed signing identity, or a moved binary), the symptom is a green start and tests that type nothing. Fix: remove the entry with the minus button, add it again, or reset only the dev bundle's entry: `tccutil reset Accessibility vn.kal.<slug>.dev` (always with the bundle ID; never run it without one, PLT-R741). Then grant again as above and re-run the nightly.

## 5. What runs here

| Workflow | Trigger | Content |
|---|---|---|
| `integration.yml` | push to `main`, release tags, manual | The test build with the integration hooks, platform integration tests (QA-R11) with the privacy canary scan, compatibility scenarios (13.2), end-to-end benchmarks (one run per merge, five nightly, QA-R14), soak of 1,000,000 keystrokes (QA-R16, nightly) |
| Release gate | before every release | Upgrade test (QA-R40, [release](release.md) section 5), egress test (`compat-harness egress`, [integration-suite.md](integration-suite.md) section 5), fresh-install checks |

The integration test list is in QA-R11: the 200 most common Vietnamese words in both methods, English restore, backspace across punctuation, fast typing at 15 keys per second, toggle hotkey, per-app rule switching, macro expansion, restore hotkey rules, Secure Input on and off, tap disable and recovery, and permission revoked mid-session (must fail open).

Only synthetic events targeted at the test host and the app under test are posted. The tests never type into other apps.

## 6. Maintenance

- Weekly: check the nightly results; free disk space (DerivedData, `.build/integration-build` of the checkout, old artefacts); confirm the runner is online in the repository's Runners page.
- After every macOS point release: run the preflight; re-verify the grants (section 4); re-run the Tier 1 compatibility script (QA-R19).
- After every Xcode change: update the pin in the workflow and on the machine together.
- After every Chrome update: update chromedriver to the matching version (section 3.2).
- After reinstalling or re-registering the runner: recreate `.env` with `COMPAT_HARNESS_LIVE=1` and restart the service (section 3.1).
- If the runner is compromised or its owner changes: remove it from the repository's Runners page, rotate nothing else on it (it holds no release secrets), wipe and rebuild.

## 7. GitHub-hosted runners (QA-R12 VERIFY)

Check whether a GitHub-hosted macOS image lets a test binary receive Accessibility or Input Monitoring (some images allow editing the TCC database). If it does, a subset of the integration tests can also run per pull request; record the result and the labels in `docs/decisions/`. Until then, hosted runners run only the permission-free layers.
