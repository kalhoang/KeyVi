<!-- SPDX-License-Identifier: LicenseRef-App-Pending -->
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
set and the spec 5.6 example rules, and fails when a rule in `compat/rules.json` has no scenario file.

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
- `readback: "human"` scenarios type the keys and then ask the tester to confirm the field. Their `wait` step
  is the time the tester gets to prepare the app (open a sheet, select a shape, connect a remote session). In
  unattended runs they report `needsHuman`, not a failure. They need a `compat/matrix.json` row (PLT-R531).

## What is here

| Group | Scenarios | Covers |
|---|---|---|
| TestHost fields | `testhost.native.*`, `testhost.web.*`, `testhost.addressBar.*`, `testhost.sheetCell.*`, `testhost.password.noTransform` | QA-R10, QA-R21, PLT-R387, inline completion and edit-mode transition (4.3, 6) |
| Layouts and input sources | `testhost.layout.{abc,qwertz,azerty,dvorak}`, `testhost.inputSource.japanese` | 13.2, PLT-R361, PLT-R371 |
| Secure input | `testhost.secureInput.{pause,release}`, `terminal.iterm2.secureKeyboardEntry{,Off}` | PLT-R398B, PLT-R398C |
| Fail-open and tap recovery | `testhost.failOpen.permissionRevoked`, `testhost.tapTimeout.recovery` | 13.2, QA-R11 (manual for now, see below) |
| 13.2 apps | `textedit.*`, `notes.telex.basic`, `browser.{webkit,chromium}.addressBar`, `browser.gecko.urlBar`, `safari.page.textarea`, `chrome.page.textarea`, `terminal.{default,iterm2,ghostty}`, `editor.vscodeFamily`, `launcher.spotlight` | 13.2 minimum automated set |
| Rule scenarios needing a person | `web.googleSheets.*`, `design.shortcutHeavy`, `remote.*`, `office.*`, `electron.default`, `editor.vscode.integratedTerminal`, `jvm.default`, `editor.customTextViews`, `launcher.overlayPanels`, `games.passThrough` | 5.6 examples and section 6 rules |

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
  iTerm2, VS Code, Spotlight, Screen Sharing, Chess). The others are the publicly documented IDs and must be
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

## Not automatable yet

`terminal.iterm2.secureKeyboardEntry` and `terminal.iterm2.secureKeyboardEntryOff` (PLT-R398C) toggle iTerm2's
Secure Keyboard Entry, which the harness can only switch in TestHost until W2-E2 adds an automated toggle. Their
`setSecureInput` step reports `needsHuman` with the reason "switch secure keyboard entry ... by hand" instead of
failing.

`design.shortcutHeavy` (5.6 rule: `defaultMode` EN for shortcut-heavy design apps) uses its 20 s wait for the
tester to select a shape and then click into a text frame of the app. The harness types `d d`; with the rule
applied the app stays in EN mode, so the frame shows "dd" (no "đ"), and the tester also confirms the shape was
not deleted by a backspace.

### Not automatable with the current schema

`testhost.failOpen.permissionRevoked` (revoke Accessibility during the wait) and `testhost.tapTimeout.recovery`
(trigger the tap-timeout test hook during the wait) are `human` scenarios because the schema has no setup
action for a test hook or a permission change. Automating them needs setup actions such as `injectTestHook` and
`revokePermission` in the scenario schema and `Scenario.SetupStep.Action` (requested from the schema owner),
plus the app-side hook (W2-E2).
