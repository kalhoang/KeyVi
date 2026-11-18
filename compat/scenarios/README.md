<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Compatibility scenarios

One JSON file per scenario (PLT-R530), named `<id>.json`, validated against
[`../schema/scenario.schema.json`](../schema/scenario.schema.json). A shipped rule's `test.scenario` names one of
these files (PLT-R505). `compat-harness` runs them on the self-hosted runner only (QA-R12, QA-R13); everywhere
else, including developer Macs and hosted CI, only the dry run is allowed:

```sh
swift run --package-path Packages/AppCore compat-harness run --dry-run   # plan only, posts nothing
swift run --package-path Packages/AppCore compat-harness coverage        # rules without a scenario file
```

`swift test` (`ScenarioFilesTests`) decodes every file, validates it against the schema, checks the 13.2 minimum
set, the QA-R11 suite and the spec 5.6 example rules, and fails when a rule in `compat/rules.json` has no scenario
file. `ScenarioOracleTests` replays every TestHost scenario that types into a plain native field through the real
engine, configured from the files the harness writes for it, and fails when its `expect.text` is not what the engine
produces; `ShortcutOpenedFieldOracleTests` does the same for the save sheet and search panel scenarios, which are read
back through a mirror. The live run on the self-hosted runner is described step by step in
[docs/runbooks/integration-suite.md](../../docs/runbooks/integration-suite.md).

## App profiles (`profiles/`)

Every scenario runs on factory defaults, its `method` (Telex or VNI) and, when a profile in `profiles/` lists it,
that profile: settings (the `settings` object of settings.json), macros and user rule overrides
(`profiles/profile.schema.json`). Every settings file the harness writes also turns the automatic update check and
install off (`automaticallyCheckForUpdates` and `automaticallyInstallUpdates` false, PLT-R1101) unless the profile
sets them: the test build carries the production feed and once updated itself to the published release in the
middle of a run ([integration-suite.md](../../docs/runbooks/integration-suite.md) section 10.10). Before a scenario whose configuration differs from the previous one, the harness
quits the test build, writes its four settings files (backed up once, restored after the run even when it stops on
an error, onboarding state kept), starts it again and waits until it is ready. After the restore the test build is
started again only when it was running before the run. `--no-configure` turns this off.

| Profile | Scenarios | What it sets |
|---|---|---|
| `qa-r11` | `testhost.macro.*`, `testhost.restoreHotkey.twice`, `testhost.perWindowRule.*` | Macros `vn` and `@@`, restore hotkey Escape, `passThrough` for `testhost.second.textField` |
| `testhost-reproductions` | `testhost.addressBar.*`, `testhost.sheetCell.*`, `testhost.panel.*`, `testhost.web.{inlineAutocomplete,editModeTransition,editModeEditor,composer}` | QA-R21: each simulated field gets the action of the shipped rule it reproduces (`actionFromRule`; the search panel gets `launcher.spotlight`'s); the separate-editor page gets the Sheets action with `requireTextFocus: never`, as browser engines resolve `byEngine` |
| `privacy-canary` | `testhost.privacyCanary.*` | One TestHost field per injection strategy |
| `bench-workload` | none (`compat-harness bench`) | `axSelection` for the TestHost address bar, so T3 gets samples |

Overrides name `local.testhost` in `bundleIds`; the harness resolves it like `targetBundleId`. Web pages are matched
by DOM class (`testhost-inline-autocomplete`, `testhost-edit-mode-cell`, `testhost-edit-mode-grid`,
`testhost-composer`).

## Conventions

- `keys` are ANSI key positions (`a`, `shift+a`, `command+l`, `control+shift`), not characters. On a QWERTZ
  layout the key named `z` types "y"; the layout scenarios rely on that.
- `layout` is selected before the setup steps, so no scenario inherits the layout of the previous one. Every
  scenario that assumes US key labels sets `com.apple.keylayout.ABC`.
- `targetBundleId: "local.testhost"` is TestHost of the checkout. The harness resolves it from
  `scripts/brand.env` (`APP_BUNDLE_ID_DEV` + `.testhost`), so files never spell the product's bundle IDs and
  survive `scripts/rename-app.sh`. The same alias works in `expect.holderBundleId` and `launch` values.
- `{pages}` in a setup value is the `file://` URL of `TestHost/Resources/Pages`. `#focus=<element id>` after a
  page name focuses that element on load.
- `focusField` is an accessibility identifier for `ax` scenarios (TestHost field IDs) and a CSS selector for
  `webdriver` scenarios.
- `terminalCapture` scenarios: the harness starts `zsh -f` with a zle (`vared`) loop in the terminal under
  test that appends every entered line to a capture file; keys end with `return`.
- `seedHistory` values are loopback URLs (`http://<word>.localhost:8000/`) that the runner serves locally, so
  the browser's inline autocomplete has a host starting with the typed letters. Nothing leaves the machine.
- `expect.text` is the field's whole value, a selected completion included (PLT-R530).
  `readbackOptions.excludesSelectedCompletion: true` (`ax` readback only) declares that a selection running to the
  end of the value is the app's own completion from user history and leaves it out of the text compared with
  `expect.text` and the `repeat` words; the `noPlaceholderResidue` check still reads the whole value. The
  `launcher.spotlight*` scenarios and the three browser address bars set it, because they expect the typed text.
  TestHost scenarios never set it (`ScenarioFilesTests`): TestHost completes deterministically, and its completion is
  part of the expected text (QA-R21), so `testhost.sheetCell.columnAutocomplete` expects `Đức` with `ức` selected.
- `focusShortcuts` lists chords of `keys` the runner waits after, as it always does after Command plus a digit: it
  types the chord on its own, waits until the app under test published a new focus snapshot (the T6 count of its
  integration hooks), then 300 ms, before the next key. Every entry must be a chord that `keys` types. Only
  `testhost.panel.inlineCompletionTwice` declares one (`command+k`, both openings of the search panel): it proves the
  overlay rule and the inline completion, not the race with the panel's opening, which is the product's to handle
  (integration-suite.md section 10.10). Any other chord types at once: `testhost.sheet.commandS` types right after
  Command+S because T5.5 asks the product to handle that (`ScenarioFilesTests` pins both).
- `readback: "human"` scenarios type the keys and then ask the tester to confirm the field. Their `wait` step
  is the time the tester gets to prepare the app (open a sheet, select a shape, connect a remote session). In
  unattended runs they report `needsHuman`, not a failure. They need a `compat/matrix.json` row (PLT-R531).
- `repeat` is the PLT-R422 placeholder gate (section 4 acceptance). After the key script passes, the harness
  types `words` randomised words of the Telex soak corpus (`seed` makes the sequence reproducible), each after
  the `prefix` keys (which must select or clear the field, `command+l` in an address bar) at the block's own
  `timing`, and reads every word back: it must be exactly the corpus word (no doubled or lost letter) and, with
  `expect.noPlaceholderResidue: true`, hold no U+200B. A rule whose `inlineCompletion` is `placeholder` or
  `axSelectionThenPlaceholder` needs an automated test scenario with `words` of at least 1,000, `timing`
  `burst`, `noPlaceholderResidue` and an `ax` or `webdriver` readback. `compat-lint` reports any other such rule;
  with `--release` the report is an error. Today the two manual spreadsheet rules (`web.googleSheets.cellEditor`,
  `office.excel.cellEditor`) are such release blockers until their gate scenarios run on the runner.

## What is here

| Group | Scenarios | Covers |
|---|---|---|
| TestHost fields | `testhost.native.*`, `testhost.web.*`, `testhost.addressBar.*`, `testhost.sheetCell.*`, `testhost.password.noTransform` | QA-R10, QA-R21, PLT-R387, inline completion and edit-mode transition (4.3, 6) |
| Key-code-first composer | `testhost.web.keycodeFirst.{backspace,returnCommit}` (`keycode-first-composer.html`: deletes on `event.code` "Backspace", sends on "Enter", types on keypress; default rules) | PLT-R405: an edit never types on the keycode of the key that triggered it (Pa's manual tests of 2026-11-14, chat apps) |
| Focus moved without an activation | `testhost.sheet.commandS`, `testhost.panel.{inlineCompletionTwice,toneUndo}`, `testhost.web.editModeEditor`, `launcher.spotlight.reopen`, `launcher.spotlight.campo{,.reopen,.suggestion}` (macOS 27.2 opens Spotlight in the Siri app, retest of 2026-11-15; `.suggestion` types `tieesng` where the field shows its suggestion after the caret, PLT-R423) | PLT-R389, PLT-R340 late focus change (Pa's manual tests of 2026-11-14: Spotlight, T5.5, T5.8) |
| Layouts and input sources | `testhost.layout.{abc,qwertz,azerty,dvorak}`, `testhost.inputSource.japanese` | 13.2, PLT-R361, PLT-R371 |
| Secure input | `testhost.secureInput.{pause,release}`, `terminal.iterm2.secureKeyboardEntry{,Off}` | PLT-R398B, PLT-R398C |
| Fail-open and tap recovery | `testhost.failOpen.permissionRevoked`, `testhost.tapTimeout.recovery` | 13.2, QA-R11 (manual for now, see below) |
| 13.2 apps | `textedit.*`, `notes.telex.basic`, `browser.{webkit,chromium}.addressBar`, `browser.gecko.urlBar`, `safari.page.textarea`, `chrome.page.textarea`, `terminal.{default,iterm2,ghostty}`, `editor.vscodeFamily`, `launcher.spotlight` | 13.2 minimum automated set |
| Rule scenarios needing a person | `web.googleSheets.*`, `design.shortcutHeavy`, `remote.*`, `office.*`, `electron.default`, `editor.vscode.integratedTerminal`, `jvm.default`, `editor.jetbrains`, `editor.customTextViews`, `editor.nativeCodeEditors`, `launcher.overlayPanels`, `games.passThrough` | 5.6 examples and section 6 rules |
| QA-R11 suite | `testhost.commonWords.{telex,vni}` (the 200 most frequent tokens of `data/derived/attested-candidates.tsv` that the engine keeps in both methods; golden files, `UPDATE_SCENARIO_GOLDENS=1`), `testhost.englishRestore.samples`, `testhost.backspace.punctuation`, `testhost.fastTyping` (fast profile, 33 keys per second), `testhost.toggleHotkey`, `testhost.perWindowRule.*`, `testhost.macro.*`, `testhost.restoreHotkey.twice` | QA-R11, PLT-R341, PLT-R353, PRD-R14, PRD-R30 |
| Privacy canary | `testhost.privacyCanary.<strategy>` for all five strategies | Section 9 canary, PLT-R901: after the run the harness scans the app's files and unified log |

The soak (`compat-harness soak`, QA-R16, 13.6) types into `textedit.telex.basic`, `chrome.page.textarea` and
`terminal.default` by default.

## Runner prerequisites (VERIFY when the runner is set up)

- Live runs need the machine-level opt-in `COMPAT_HARNESS_LIVE=1` in the runner's environment (for example a
  line in the `.env` file of the GitHub Actions runner directory, which the runner loads into every job).
  Without it `run`, `soak` and `bench` exit 3 before posting an event, launching an app or changing an input
  source, so a forgotten `--dry-run` on a developer Mac is harmless. Never set it anywhere else.
- Every layout the scenarios select must be enabled for the test user (System Settings, Keyboard, Input
  Sources): ABC (`com.apple.keylayout.ABC`), German, French, Dvorak and Japanese Romaji
  (`com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese`). The harness lists only enabled sources, so a
  missing one fails the scenario at its first step with `input source not enabled: <id>`.
- `results.json` gives a `reason` for every failed or `needsHuman` scenario (failing stage and error, no
  typed text), and the console prints it after the duration.
- Bundle IDs were read from installed apps where present (TextEdit, Notes, Safari, Terminal, Chrome, Firefox,
  iTerm2, VS Code, Spotlight, the Siri app of macOS 27.2 that holds Spotlight (`com.apple.campo`, read with PlistBuddy on 2026-11-15), Screen Sharing, Chess). The others are the publicly documented IDs and must be
  checked against the installed app's `Info.plist` (02-platform.md 5.6): Ghostty `com.mitchellh.ghostty`,
  Affinity Designer 2, Excel, Word, LibreOffice `org.libreoffice.script`, Slack, IntelliJ IDEA, Sublime Text 4,
  Raycast.
- macOS text substitutions (auto-capitalisation, smart quotes, spelling correction) must be off for the test
  user, or TextEdit and Notes alter the expected text.
- TextEdit opens a new empty document at launch (no open panel); Notes has an empty scratch note selected.
- VS Code and Chrome expose their editor and omnibox to AX (VERIFY; 6 warns about `AXManualAccessibility`
  side effects). Safari's WebDriver window blocks physical input, so Safari page scenarios read back through AX.
- A loopback HTTP server on port 8000 for `seedHistory` (for example `python3 -m http.server 8000 --bind
  127.0.0.1 --directory TestHost/Resources/Pages`) and `chromedriver` listening on its default
  `http://127.0.0.1:9515`, which every `webdriver` scenario without a `--webdriver BUNDLE=URL` entry uses. Other
  drivers (for example `safaridriver --port N`) need an explicit `--webdriver`, passed through
  `COMPAT_HARNESS_RUN_ARGS` / `COMPAT_HARNESS_SOAK_ARGS`.
- The soak prepares each target once (launch, page, capture shell) and, for later chunks, only brings the app
  back to the front with a launch request and refocuses the field. VERIFY that activating a running Terminal
  and the chromedriver-started Chrome this way raises the soak's window rather than opening a new one.
- The spreadsheet transition window of TestHost and the edit-mode page (20 ms) is a model, not a measurement:
  VERIFY it against Google Sheets in Safari and tune `firstEditDelayUs` scenarios accordingly.

## Secure Keyboard Entry

`terminal.iterm2.secureKeyboardEntry` and `terminal.iterm2.secureKeyboardEntryOff` (PLT-R398C) toggle iTerm2's
Secure Keyboard Entry. On the runner the harness presses the "Secure Keyboard Entry" item of the app menu through
AX for every app whose `secureInputHints` hint key in `compat/rules.json` ends in `.secureKeyboardEntry` (Terminal,
iTerm2), only when its check mark differs (VERIFY the item title on the runner's macOS language). The paused and
holder expectations are read from the app through its integration hooks; without the hooks build they report
`needsHuman`.

## Needs a person

`design.shortcutHeavy` (5.6 rule: `defaultMode` EN for shortcut-heavy design apps) uses its 20 s wait for the
tester to select a shape and then click into a text frame of the app. The harness types `d d`; with the rule
applied the app stays in EN mode, so the frame shows "dd" (no "đ"), and the tester also confirms the shape was
not deleted by a backspace.

## Integration hooks (automated since W3-A)

`testhost.tapTimeout.recovery` (`tapTimeout@4`, expects "duyeẹt": the engine is reset after the recovery, QA-R11)
and `testhost.failOpen.permissionRevoked` (`revokePermission@4` on `v i e e t j`, expects "viêtj" and paused:
PLT-R730 fail-open) use the `testHook` setup step (`tapTimeout`, `revokePermission`, `restorePermission`, optionally
`@<n>` to fire after the first n keys, so the hook lands mid-word), listed in the scenario schema since W3-A. The app
answers the hooks only in the `Integration` test build (`scripts/run-integration.sh build`, ADR 0502); the harness
restores a revoked permission after the scenario. The PLT-R398B release scenarios keep secure input on for 2.5 s,
longer than one 2 s secure-input poll with leeway, so the app sees the release it reports
(`ScenarioFilesTests.secureInputEpisodesOutlastOnePoll`).
