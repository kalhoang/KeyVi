# Implementation workstreams

How the platform layer gets built in parallel workstreams. Two waves; at most eight workstreams per wave;
inside a wave no file is owned by two workstreams. Every workstream starts from the compiled contract skeleton
on this branch (`Packages/AppCore`, `project.yml`, `App/`, `TestHost/`, `SpikeIMK/`, `compat/schema/`) and
implements behind the public signatures in [contracts.md](contracts.md). Requirement scope lists are derived
from [traceability.md](traceability.md).

## Rules for every workstream

1. **Read first:** `spec/05-clean-room.md`, `CLAUDE.md`, `ARCHITECTURE.md`, the contract sections for your
   paths, and the spec sections behind your scope IDs. Clean-room rules apply in full (CLR-R1-R5).
2. **Ownership.** Edit only your owned paths. Everything else is read-only for you. These are frozen for the
   whole of wave 1 and change only through the integrator: `Packages/AppCore/Package.swift`, `project.yml`,
   `Config/**`, `App/Info.plist`, `Packages/AppCore/Sources/AppModel/**`,
   `Packages/AppCore/Sources/TestSupport/Fakes/Common/**`, the root `ScaffoldTests.swift` of shared test
   targets, `ARCHITECTURE.md`, `docs/architecture/**`, `docs/decisions/030x-*.md`. Need a change there? Put the
   exact request in your report.
3. **Public signatures are contracts.** Keep them. If one is wrong, change it only inside your own module,
   keep it compiling for every consumer, and list the change in your report so the integrator reruns
   `python3 -I docs/architecture/tools/sync_contracts.py`.
4. **Tests first** (QA-R3), Swift Testing, at least 80 % line coverage of your module (QA-R2). Use a private
   scratch path: `swift build --scratch-path .build-<workstream>` and `swift test --scratch-path
   .build-<workstream>` in `Packages/AppCore`. App targets: `xcodegen generate` then `xcodebuild ...
   CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/<workstream>-dd build`.
5. **Never on Pa's Mac:** launch the app, post synthetic events, create event taps, change input sources,
   System Settings, TCC or permissions, use `sudo`. Code that needs those runs under fakes in tests; the real
   path is verified by W2-E on the self-hosted runner or by Pa (items marked **Pa** in traceability.md).
6. **Privacy and hot path.** No typed content in logs (typed `LogEvent` only, no interpolation); nothing in
   `InputHost/Pipeline`, `InputHost/Tap` or the producer side of `Injection/Queue` may lock, allocate in steady
   state, do I/O or call AX/TIS/AppKit (PLT-R304, PLT-R305).
7. **Brand.** Never hard-code the display name, slug, bundle ID or site host; UI strings take the app name as
   a format argument (CLAUDE.md). Bundle IDs appear only in `compat/*.json` and test fixtures (PLT-R501);
   reverse-DNS constants that are not bundle IDs go in `ReverseDNSConstants.swift`.
8. **Remove `unimplemented()`** from every member you own before you finish; leave none reachable.
9. **Commits:** English Conventional Commits, no AI attribution, on your own branch; the integrator merges.
10. **Report:** what you built, test and coverage numbers, contract changes, requests for frozen files,
    VERIFY items you could not close, and items Pa must test by hand.

## Wave 1: start immediately against the skeleton

### W1-A Realtime primitives and Diagnostics

- **Owned paths:** `Packages/AppCore/Sources/RealtimeSupport/**`, `Packages/AppCore/Sources/Diagnostics/**`,
  `Packages/AppCore/Tests/RealtimeSupportTests/**`, `Packages/AppCore/Tests/DiagnosticsTests/**`,
  `Packages/AppCore/Sources/TestSupport/Fakes/Diagnostics/**`
- **Depends on:** skeleton only.
- **Scope:** PLT-R388, PLT-R801, PLT-R802, PLT-R901, PLT-R902, PLT-R903, PLT-R904, PLT-R905, PLT-R1202, PLT-R1203, PLT-R1206, PRD-R33, PRD-R45, PRD-R46, QA-R44
- **Work:** harden and benchmark the skeleton's `SnapshotCell`, `SPSCRing`, signals and clock (stress tests,
  Thread Sanitizer, allocation counting); implement redaction (salted SHA-256), typed `LogEvent` rendering,
  `DiagnosticsLogger` (JSON lines, 0700/0600, rotation 5 x 1 MB, 14-day retention, `os.Logger` mirror),
  `HealthEventLog`, `Log2Histogram`/`AtomicCounter`/`PerBundleHistograms`/`PlatformMetrics`, `TapLogRing`,
  `DiagnosticsRenderer` (plain text vi/en, JSON, QA-R44 block and its parser), `CaptureController` (time box,
  rings, gap records, rendering, export-then-delete, 24 h purge, excluded from backup), `PlatformSignposts`.
- **Acceptance:**
  - `swift test --filter "RealtimeSupportTests|DiagnosticsTests"` green, also under `--sanitize=thread`;
    coverage of both modules at least 80 %.
  - Snapshot read path and `SPSCRing.push/pop` show zero heap allocations in a malloc-counting test; 10 million
    concurrent publish/read iterations never observe a torn or freed value.
  - Canary test: logging every `LogEvent` case with canary-shaped metadata, plus a full report and issue block,
    never contains the canary string (PLT-R901, PLT-R1203).
  - `parseIssueBlock(issueBlock(report))` round-trips every `DiagnosticsBlockKey`; an unknown format version
    returns nil.
  - Capture refuses more than 180 s, stops by itself, marks secure-input gaps, deletes files older than 24 h and
    right after export; files are 0600 and excluded from backup (checked with `InMemoryFileSystem` and a temp
    directory).

### W1-B SettingsStore and macro importers

- **Owned paths:** `Packages/AppCore/Sources/SettingsStore/**`, `Packages/AppCore/Tests/SettingsStoreTests/**`
  (including `Fixtures/`), `Packages/AppCore/Sources/TestSupport/Fakes/Settings/**`
- **Depends on:** skeleton only.
- **Scope:** PLT-R392, PLT-R541, PLT-R912, PLT-R1001, PLT-R1002, PLT-R1003, PLT-R1004, PLT-R1005, PLT-R1006, PLT-R1007, PLT-R1009, PLT-R1010, PRD-R5, PRD-R6, PRD-R18, PRD-R23, PRD-R26, PRD-R29, PRD-R32, PRD-R69, PRD-R70, PRD-R72, QA-R41
- **Work:** Codable mapping of the four documents exactly as in contracts.md section 7 (absent = unset, `null`
  = explicitly none), raw-object overlay that preserves unknown keys, the store actor on the utility queue
  (load, debounced atomic writes, 5 s app-modes debounce, notices), migrations with backups (newest 5),
  corruption quarantine and recovery, newer-schema read-only, `LaunchGuard`, reset scopes, export/import with
  preview and skipped fields, `MacroImporter` (four formats), `MacroValidator`.
- **Acceptance:**
  - Unknown keys at every level survive load and rewrite; `.unset` vs `.set(default)` round-trips; changing a
    default in `DefaultSettings` changes the effective value only for unset keys (PRD-R6).
  - Fixture per schema version (v1 now) loads, migrates and compares; migration writes a backup first.
  - Truncated `settings.json` -> renamed `.corrupt-<timestamp>`, newest valid backup loaded, notice emitted, no
    overwrite before confirmation; no backup -> defaults in memory, nothing written (PLT-R1006).
  - A file with `schemaVersion` 2 is used read-only for known fields and never rewritten (PLT-R1007).
  - Three launches that do not reach `markSurvived()` within the window enter safe mode without touching
    files (PLT-R1009).
  - Export on v1 then import reproduces the same `SettingsState`; untrusted import fuzz (random bytes, 6 MB
    file, deep nesting) never crashes and is rejected with a reason (PLT-R912).
  - Macro import: each format parses its fixture; invalid rows are reported with line numbers and reasons;
    duplicates resolve with keep-mine/use-imported; the shadowing rule rejects `vn` + `vn.` (PRD-R29).

### W1-C CompatRules, rules data and lint

- **Owned paths:** `Packages/AppCore/Sources/CompatRules/**`, `Packages/AppCore/Sources/CompatLint/**`,
  `Packages/AppCore/Tests/CompatRulesTests/**`, `Packages/AppCore/Sources/TestSupport/Fakes/Rules/**`,
  `compat/rules.json`, `compat/matrix.json`, `compat/schema/**`
- **Depends on:** skeleton only.
- **Scope:** PLT-R398C, PLT-R407, PLT-R408, PLT-R422, PLT-R460, PLT-R501, PLT-R502, PLT-R503, PLT-R504, PLT-R505, PLT-R506, PLT-R510, PLT-R520, PLT-R521, PLT-R522, PLT-R531, PRD-R35, PRD-R38, PRD-R39, QA-R17, QA-R19
- **Work:** `RuleProvenance` coding, loader with validation and embedded fallback (no bundle IDs in Swift),
  `RuleSet` compilation and resolution (specificity, user precedence, ties, opted-in rules, `byEngine`
  resolution, params caps), `EngineFingerprinter`, `MatrixStatusResolver`, `RulesLinter` and the `compat-lint`
  CLI (`compat-lint --rules compat/rules.json --matrix compat/matrix.json --scenarios compat/scenarios
  [--release]`, non-zero exit on errors), seeded `compat/rules.json` (defaults, `terminals` and
  `webkitBrowsers` groups, conflicting input apps, secure-input hints for Terminal and iTerm2, and the rules of
  02-platform.md 5.6 and section 6 with honest `VERIFY` notes), seeded `compat/matrix.json` with every Tier 1
  and Tier 2 app of PRD-R39 as `notVerified`.
- **Acceptance:**
  - `compat/rules.json` and `compat/matrix.json` validate against the JSON Schemas and decode with the Swift
    types (both directions, one test).
  - Resolution table tests: every specificity term of PLT-R520, user override beats a more specific shipped
    rule, identical signatures fail the linter, a runtime tie picks the smaller id and reports the loser.
  - A Chromium bundle unknown to the rules (fake inspector) gets the `engines: ["chromium"]` rule.
  - Invalid shipped file -> `usedEmbeddedDefaults == true`, no crash; `EmbeddedRules.minimal` contains no
    bundle-ID-shaped string.
  - Linter: missing provenance/test, `reviewBy` past (warning) and past by more than 30 days (error with
    `--release`), placeholder in a global or title-only rule, manual scenario without a matrix row, Tier 1 row
    older than 90 days in release mode.
  - `swift run compat-lint ...` exits 0 on the seeded files (warnings allowed for `VERIFY` dates).

### W1-D Injection worker and strategies

- **Owned paths:** `Packages/AppCore/Sources/Injection/**`, `Packages/AppCore/Tests/InjectionTests/**`,
  `Packages/AppCore/Sources/TestSupport/Fakes/Injection/**`
- **Depends on:** skeleton only (uses the skeleton `SPSCRing`, `WorkerSignal`, `ManualClock`).
- **Scope:** PLT-R203, PLT-R311, PLT-R313, PLT-R314, PLT-R315, PLT-R316, PLT-R320, PLT-R321, PLT-R322, PLT-R323, PLT-R324, PLT-R342, PLT-R343, PLT-R401, PLT-R402, PLT-R403, PLT-R404, PLT-R405, PLT-R406, PLT-R407, PLT-R408, PLT-R409, PLT-R410, PLT-R420, PLT-R421, PLT-R460, PLT-R461, PLT-R462, PLT-R480
- **Work:** `EventMarker` (CSPRNG tag, layout, classify), `JobQueue`, `WorkerFeedback` (reset counter, 64-entry
  outcome board, posting broken), `EchoTracker`, `CurrentFocusGeneration`, `InjectionWorker` (thread loop and
  `runUntilIdle` step mode, FIFO, generation discard with trigger replay, liveness flush, pairedKeyUp,
  `requestFlush`, echo deadlines), `EditMinimizer`, `UnicodeChunker`, the four strategy executors with inline
  completion, `PasteboardPreserver`, production `CGEventPoster`, `AXFocusedFieldAccess`, `NSPasteboardAccess`
  (pasteboard types in `ReverseDNSConstants.swift`), the fakes.
- **Acceptance:**
  - "nguyen" + `s` produces exactly 2 backspaces and 2 inserted characters (4.10 acceptance) through
    `backspaceReplace` on `SimulatedTextField`-backed fakes.
  - Worker property tests with a scripted producer: FIFO order, held events replayed once and in order, a job
    of an old generation is discarded and its trigger replayed, liveness at 150 ms (1 s for macros) and 256 jobs
    abandons only unstarted edits, pairedKeyUp dropped after execution and replayed after abandonment
    (ADR 0308).
  - Inline completion: with a selected suggestion, `axSelection` deletes it first; on AX timeout
    `axSelectionThenPlaceholder` falls back to the placeholder; placeholder leaves no residue over 1,000
    randomised edits on the simulated field.
  - Pasteboard: multi-item, multi-type snapshot is byte-identical after 100 paste jobs; marker types present;
    `changeCount` guard skips restore after a user copy; file promise or more than 10 MB aborts paste and uses
    the fallback. Run against `FakePasteboard` and against a uniquely named `NSPasteboard` (no general
    pasteboard access in tests).
  - Echo: three consecutive jobs without echo within 200 ms set posting broken.
  - No forward-delete keycode is ever posted by any strategy (static test over the executors).

### W1-E InputHost host services

- **Owned paths:** `Packages/AppCore/Sources/InputHost/Hotkeys/**`, `.../InputHost/InputSource/**`,
  `.../InputHost/SecureInput/**`, `.../InputHost/Focus/**`, `.../InputHost/Memory/**`,
  `.../InputHost/Permissions/**`, `.../InputHost/Workspace/**`, `Packages/AppCore/Tests/InputHostTests/Services/**`,
  `Packages/AppCore/Sources/TestSupport/Fakes/Host/**`
- **Depends on:** skeleton only (focus tests use `FakeDecisionResolver`, not the rules implementation).
- **Scope:** PLT-R203, PLT-R333, PLT-R343, PLT-R353, PLT-R354, PLT-R360, PLT-R361, PLT-R370, PLT-R371, PLT-R372, PLT-R373, PLT-R380, PLT-R381, PLT-R382, PLT-R383, PLT-R384, PLT-R385, PLT-R386, PLT-R387, PLT-R390, PLT-R391, PLT-R392, PLT-R393, PLT-R395, PLT-R396, PLT-R397, PLT-R398, PLT-R398A, PLT-R399, PLT-R510, PLT-R523, PLT-R701, PLT-R702, PLT-R711, PLT-R720, PLT-R721, PLT-R740, PLT-R803, PRD-R14, PRD-R15, PRD-R16, PRD-R17, PRD-R18, PRD-R19, PRD-R20, PRD-R21, PRD-R22
- **Work:** `HotkeyRecognizer` and `HotkeyRecorder` (contracts.md 10.2), `UCKeyTranslateLayoutBuilder`,
  `TISInputSourceProvider`, `InputSourceMonitor` (classification, built-in Vietnamese detection by language
  and kind, layout binding, keyboard types), `SystemSecureInputProbe` (IORegistry `IOConsoleUsers`),
  `SecureInputMonitor` (2 s poll, transition generations, holder naming, hint keys, key evidence),
  `ProcessIdentityProvider`, bundle inspector, `SystemAXProvider`, `AXCircuitBreaker`, `FocusTracker` (observers,
  system-wide authority, overlay apps, idle revalidation, inbox draining, `HostDecisionMapper`, generation
  publication), `RuleSet: FocusDecisionResolving` conformance, `AppModeMemory`, `SystemPermissionProbe`,
  `PermissionMonitor` (cadence, stale), `PermissionResetting`, `NSWorkspaceEvents`, `ConflictDetector`, the
  fakes.
- **Acceptance:**
  - Recogniser table tests: Control+Shift tap toggles on release; cancelled by a key, click or scroll in
    between, by holding longer than 500 ms, and when used with another key; autorepeat ignored; right Command
    tap; combo consumed; restore candidate only for its binding. Recorder captures every PRD-R15 chord in any
    press order and flags the seven PRD-R16 conflicts.
  - Layout tables built from the installed ABC, German, French and Dvorak layouts (read by ID, nothing
    selected): `y`/`z` on QWERTZ, `a`/`q`/`w` on AZERTY, Shift digits on AZERTY, dead keys flagged.
  - Focus with fake AX: a non-activating overlay owns focus, so its memory and rule apply; 3 AX timeouts in
    10 s open the breaker for 60 s; `AXSecureTextField` yields `.secureField`; title and URL never appear in a
    published snapshot; resolution happens once per focus change.
  - Memory: PRD-R21 precedence table, LRU eviction at 1,000 without evicting explicit rules, toggle updates
    memory and global mode, document round-trip.
  - Secure input: generation changes only on transitions; holder mapping for app, `loginwindow` (by process
    name), dead PID, unknown; `keyEvidence` keeps the resumed state until the next transition.
  - Permissions: cadence 2 s / 30 s with fake clock, stale detection on digest change; `tccutil` command built
    only with the app's own bundle ID (never executed in tests).
  - No timer in these services fires more often than every 2 s at rest (test over configured intervals).

### W1-F InputHost pipeline, tap thread and lifecycle

- **Owned paths:** `Packages/AppCore/Sources/InputHost/Snapshots/**`, `.../InputHost/Engine/**`,
  `.../InputHost/Pipeline/**`, `.../InputHost/Tap/**`, `.../InputHost/Lifecycle/**`,
  `Packages/AppCore/Tests/InputHostTests/Pipeline/**`, `Packages/AppCore/Sources/TestSupport/Pipeline/**`
- **Depends on:** skeleton only. Uses `ScriptedEngine` and a reference job consumer in TestSupport/Pipeline;
  the combined suite with the real worker is W2-A.
- **Scope:** PLT-R203, PLT-R208, PLT-R210, PLT-R301, PLT-R302, PLT-R303, PLT-R304, PLT-R305, PLT-R306, PLT-R307, PLT-R310, PLT-R311, PLT-R312, PLT-R313, PLT-R317, PLT-R321, PLT-R323, PLT-R330, PLT-R331, PLT-R332, PLT-R333, PLT-R340, PLT-R341, PLT-R350, PLT-R351, PLT-R352, PLT-R353, PLT-R354, PLT-R355, PLT-R356, PLT-R361, PLT-R363, PLT-R371, PLT-R382, PLT-R386, PLT-R387, PLT-R391, PLT-R398A, PLT-R398B, PLT-R405, PLT-R730, PLT-R731, PLT-R803, PLT-R820, PLT-R911, PLT-R1008, PRD-R0, PRD-R19, PRD-R27, PRD-R44, QA-R14
- **Work:** `KeyPipeline` (PLT-R310 all steps), `KeyClassifier`, `HostStateResolver`, `CallbackWatchdog`,
  `TapThread` and `CGEventTapFactory` (C callback bridge, `RawKeyEvent` extraction), `TapWatchdog`
  (ADR 0309), `EngineCatalog`, `EngineBridge` (configuration, macro table, catalog; resources loader injected),
  `VietnameseCompositionEngine(Factory)`, `TapOutbox` usage, `InputHostController` state machine and fail-open
  orchestration against service protocols, `ScriptedEngine`, `SimulatedTextField`, `ConservationLedger`,
  `RandomEventGenerator`, `PipelineHarness` (with a reference consumer), hosted pipeline microbenchmark.
- **Acceptance:**
  - Property suite (seeded, at least 100,000 sequences per run) with the reference consumer: conservation
    (PLT-R312), hold-while-busy ordering (PLT-R311), keyUp pairing (PLT-R313), marker never on physical events
    (PLT-R321), fail-open stops swallowing within the same callback (PLT-R730), composition reset on every
    pause/fail-open/focus transition (PLT-R210).
  - P0-1 tests: secure input on -> paused, no engine feed; first keyDown that reaches the pipeline afterwards
    is composed with no passed-through keys in between (PLT-R398B); only OS state and secure field pause
    (PLT-R398A).
  - Step tests: Return and Tab are fed to the engine before the hard boundary; restore hotkey consumed once,
    passed on the second press; Escape passed is a boundary; keypad digits flagged; navigation never edits;
    autorepeat rules; dead keys pass.
  - Toggle race: a focus snapshot resolved concurrently with a tap toggle never reverts the mode
    (`appliedToggleSequence`).
  - Hot path: allocation-counting test over 10,000 steady-state events shows no allocation outside the engine
    call; microbenchmark records T1 with fakes (baseline file proposed for the CI track).
  - `InputHostController` with fakes: noPermission -> starting -> ready; tap creation failure -> failOpen with
    backoff 1, 2, 5, 10 s; watchdog trip -> failOpen(watchdog) and retry after 2 s; settings change rebuilds the
    catalog and applies on the next key.

### W1-G Shell chrome: ShellCore, menu bar, HUDs, onboarding, localisation runtime

- **Owned paths:** `Packages/AppCore/Sources/ShellCore/**`, `Packages/AppCore/Tests/ShellCoreTests/**`,
  `App/Sources/Shell/**`, `App/Sources/Onboarding/**`, `App/Resources/Assets.xcassets/**`,
  `App/Resources/SystemPanes.json`, `App/Resources/Localization/Common.xcstrings`,
  `App/Resources/Localization/Menu.xcstrings`, `App/Resources/Localization/Status.xcstrings`,
  `App/Resources/Localization/Onboarding.xcstrings`
- **Depends on:** skeleton only (host state and permissions through protocols and fakes).
- **Scope:** PLT-R205, PLT-R206, PLT-R211, PLT-R362, PLT-R397, PLT-R398C, PLT-R399, PLT-R540, PLT-R541, PLT-R701, PLT-R704, PLT-R710, PLT-R711, PLT-R712, PLT-R740, PLT-R741, PLT-R909, PLT-R913, PLT-R1202, PRD-R9, PRD-R10, PRD-R11, PRD-R12, PRD-R13, PRD-R33, PRD-R34, PRD-R35, PRD-R36, PRD-R40, PRD-R41, PRD-R42, PRD-R43, PRD-R47, PRD-R57, PRD-R62, PRD-R63, PRD-R64, PRD-R65, CLR-R7
- **Work:** `Brand.from(_:)`, `Localizer` and `InterfaceLanguageModel` (ADR 0310), `SystemPaneTable` and the
  VERIFY-marked `SystemPanes.json` (macOS 15/26 and 27, vi and en), `StatusPresentation`, `StatusLine` (every
  row of PRD-R43), `MenuModel`, `HotkeyDisplay`, `OnboardingFlow`, `AppLocationCheck`, `ReportAssembler`,
  `BugReportComposer`, `SystemInfoReader`, `AppsPaneModel`, `CompatibilityModeChoice`, `URLSchemeRouter`,
  `SMAppServiceLoginItem`, `DonationInfo`; `StatusItemController`, `SwitchHUDController`,
  `CaptureHUDController`, `OnboardingWindowController` with the eight screens; monochrome template icons for
  every `StatusIconState` (original artwork, source recorded per CLR-R7); all copy of PRD-R10, PRD-R11,
  PRD-R40-R43 verbatim in Vietnamese with English equivalents.
- **Acceptance:**
  - `Localizer` returns Vietnamese for `.vietnamese` and English for `.english` from the same bundle regardless
    of the process language; switching `InterfaceLanguageModel` changes rendered strings without restart;
    every key in the four owned catalogs exists in vi and en with matching format arguments (catalog test that
    parses the `.xcstrings` files).
  - State-to-icon and state-to-status-line tables cover every `HostState`; menu model matches PRD-R11 order;
    onboarding flow skips screens 5 and 6 when their condition is false, never allows skipping screen 2,
    advances within one permission poll, and shows only screen 2 after permission loss (PRD-R42).
  - `AppLocationCheck` rejects translocated, read-only-volume and outside-Applications paths.
  - Report assembly contains no field outside PLT-R1202 and includes the per-app entry of the reported app
    only (PLT-R913); GitHub URL and mail body never include the diagnostics block content beyond the summary.
  - `xcodebuild -scheme App` builds without warnings in owned files; no `Text("...")` literal for product copy.

### W1-H TestHost, local test pages, CompatHarness, scenarios and spike S1

- **Owned paths:** `TestHost/**`, `SpikeIMK/**`, `Packages/AppCore/Sources/CompatHarness/**`,
  `Packages/AppCore/Sources/TestSupport/Scenario/**`, `Packages/AppCore/Tests/TestSupportTests/**`,
  `compat/scenarios/**`
- **Depends on:** skeleton only.
- **Scope:** PLT-R207, PLT-R398D, PLT-R530, QA-R10, QA-R21
- **Work:** TestHost window with every `TestHostField` (native field and view, WKWebView page with input,
  textarea, contenteditable, simulated address bar with inline autocomplete, simulated spreadsheet cell
  editor, password field), AX identifiers and DOM-to-native mirroring; local pages in
  `TestHost/Resources/Pages/` (inline autocomplete, first-keystroke edit-mode transition, contenteditable
  composer; no network resources); `ScenarioRunner`, scenario loading and schema conformance;
  `compat-harness` CLI with keyboard driver (timing profiles normal 80-150 ms, fast 30 ms, burst 5 ms) and
  readbacks (AX, webdriver, terminal capture, human prompt); scenario files for the 13.2 minimum set and for
  every shipped rule's `test.scenario`; SpikeIMK counters, input menu and `SpikeIMK/README.md` with
  step-by-step instructions for Pa and a result template for `docs/decisions/03xx-spike-s1-result.md`.
- **Acceptance:**
  - `xcodebuild -scheme TestHost` and `-scheme SpikeIMK` build with signing disabled; TestHost unit-level tests
    (in `TestSupportTests`) verify scenario decoding and schema validation of every file in `compat/scenarios`.
  - The harness has a `--dry-run` mode that loads all scenarios and prints the plan without posting events;
    it is the only mode used on Pa's Mac.
  - SpikeIMK never references `CGEvent` posting or tap APIs (static test); README explains build, install into
    `~/Library/Input Methods`, enabling, the iTerm2 and Terminal secure keyboard entry steps, what to observe,
    and how to remove it.
  - Local test pages load from `file://` without network access (checked by a content test that rejects
    `http(s)://` references).

## Wave 2: needs wave 1 merged

Frozen-file rule continues (the integrator updates `Package.swift`/`project.yml` between waves if a
workstream asked for it). Wave-1 owned paths not listed below become read-only again.

### W2-A Composition root, engine bridge with real resources, end-to-end with fakes

- **Owned paths:** `App/Sources/Composition/**`, `Packages/AppCore/Sources/InputHost/Lifecycle/**`,
  `Packages/AppCore/Sources/InputHost/Integration/**`, `Packages/AppCore/Tests/InputHostTests/Integration/**`
- **Depends on:** W1-A to W1-H.
- **Scope:** PLT-R201, PLT-R205, PLT-R307, PLT-R311, PLT-R312, PLT-R314, PLT-R316, PLT-R399, PLT-R710, PLT-R909, PLT-R1008, PLT-R1009, PRD-R27, QA-R42
- **Work:** `AppEnvironment` (launch order, services, window controllers, quit flush, URL scheme), host
  assembly with production services, settings-to-snapshot bridge (engine catalog from
  `Resources.bundled`, user lists, macros, per-app overrides into `RuleSet`), conflicts and learning proposals
  to the shell, first-launch-after-update self-check, the combined pipeline + real worker property suite, the
  D10 decision (hidden until the engine offers literal mode, ADR 0306).
- **Acceptance:**
  - Combined property suite (`PipelineHarness` with the real `InjectionWorker` in step mode, scripted and real
    engine): 100,000 sequences, zero conservation, ordering, liveness, generation-discard or keyUp violations.
  - End-to-end with fakes: Telex "duyeetj" -> "duyệt" under ABC, QWERTZ, AZERTY and Dvorak tables; VNI
    "duye65t" -> "duyệt" under ABC and AZERTY; Japanese source -> no transformation and pause reason; settings
    change applies on the next key without losing the word.
  - Launch path with fakes: safe mode after three crashes; move offer before any permission request when the
    bundle is translocated; S1 ready-after-launch measured with fakes under 300 ms.
  - The app builds in Release (universal) once `compat/rules.json` exists; `codesign` is not run in a workstream.

### W2-B Settings window, macros editor, Apps pane, About & Support

- **Owned paths:** `App/Sources/Settings/**`, `App/Resources/Donation.xcassets/**`,
  `App/Resources/Localization/Settings.xcstrings`, `Macros.xcstrings`, `Apps.xcstrings`, `Support.xcstrings`,
  `Packages/AppCore/Sources/ShellCore/AppsPane.swift`, `Packages/AppCore/Sources/ShellCore/Services.swift`,
  `Packages/AppCore/Tests/ShellCoreTests/Settings/**`
- **Depends on:** W1-B, W1-C, W1-E, W1-G.
- **Scope:** PLT-R373, PLT-R462, PLT-R540, PLT-R1010, PRD-R7, PRD-R15, PRD-R16, PRD-R24, PRD-R25, PRD-R26, PRD-R28, PRD-R31, PRD-R32, PRD-R34, PRD-R36, PRD-R37, PRD-R53, PRD-R57, PRD-R59, PRD-R62
- **Work:** five panes in PRD-R24 order with one-line explanations and Advanced disclosures (remembered),
  practice field, tone placement preview, user lists, hotkey recorder UI with conflict warnings, layout
  binding (General > Advanced), per-pane and global reset with export offer, export/import sheets with
  summary, macros editor (search, sort, add, edit, duplicate, delete, enable/disable all, validation messages)
  and import preview, Apps pane (rows, rule picker, status, Advanced compatibility mode, report button),
  About & Support (version, channel, update controls through `UpdaterControlling`, diagnostics entry, privacy
  summary, licences, donation block with placeholder QR images marked VERIFY).
- **Acceptance:**
  - View-model tests: "not a setting" items never appear (PRD-R7); every setting has an explanation key in vi
    and en; reset offers export first and keeps macros unless ticked; import summary lists changes and skipped
    fields.
  - Macro editor rejects invalid shortcuts with the PRD-R29 reasons; import preview counts match W1-B.
  - Compatibility mode choices write and remove the expected user override JSON (PLT-R540).
  - Catalog test for the four owned tables; no pane scrolls at default size except Apps and Macros (manual
    check by Pa listed in the report).

### W2-C Diagnostics window, bug report, guided test, typing trace, latency probe

- **Owned paths:** `App/Sources/Diagnostics/**`, `App/Resources/Localization/Diagnostics.xcstrings`,
  `Packages/AppCore/Sources/InputHost/Probes/**`, `Packages/AppCore/Tests/InputHostTests/Probes/**`,
  `Packages/AppCore/Sources/ShellCore/BugReport.swift`, `Packages/AppCore/Tests/ShellCoreTests/BugReport/**`
- **Depends on:** W1-A, W1-D, W1-F, W1-G.
- **Scope:** PLT-R410, PLT-R540, PLT-R810, PLT-R905, PLT-R1201, PLT-R1204, PLT-R1205, PRD-R47, PRD-R48, PRD-R49, PRD-R62
- **Work:** diagnostics window (PLT-R1201), report preview before copy/save (PLT-R1204), bug report sheet with
  GitHub, email and save paths and the clipboard notice (PRD-R47-R49), "This app misbehaves" flow with
  `GuidedTestRunner` candidates, human fallback question and rule suggestion (PLT-R1205), typing trace
  confirmation, HUD, review rendering and export (PLT-R905), latency probe window and driver (PLT-R810).
- **Acceptance:**
  - Guided test with fakes on a simulated inline-completion field recommends `axSelection` or `placeholder`,
    and the resulting override fixes the simulated symptom (12 acceptance).
  - Suggestion JSON validates against `userOverrideRule` of the rules schema; a URL prefix appears only when the
    user opted in and is cut to host level.
  - A report generated during a canary session contains no canary; a first-time user reaches "Copy report" in
    at most 3 clicks from the menu (view-model test of the navigation path).
  - Probe driver result math tested with synthetic timestamps; no probe code runs in tests against the real
    poster.

### W2-D Sparkle updater

- **Owned paths:** `App/Sources/Updater/**`, `App/Resources/Localization/Updates.xcstrings`,
  `Config/Sparkle.xcconfig`
- **Depends on:** W1-B, W1-G.
- **Scope:** PLT-R104, PLT-R752, PLT-R906, PLT-R1101, PLT-R1102, PLT-R1105, PRD-R50, PRD-R51, PRD-R53, PRD-R62, QA-R28, QA-R33
- **Work:** `UpdaterController` over `SPUStandardUpdaterController` (manual start), settings D19-D21 applied
  at launch and on change, beta channel delegate, install-on-quit with the idle relaunch rule, no system
  profiling, update-failed copy (PRD-R43), documentation of the EdDSA key step for Pa in the report.
- **Acceptance:**
  - Delegate tests: channels `[]` for stable and `["beta"]` after opt-in; immediate installation only after
    60 s idle with secure input off; `SUEnableSystemProfiling` false and feed URL derived from the site host
    (Info.plist test on the built bundle).
  - URL host allowlist: the built binary contains no host other than the site host, GitHub and the mail
    domain (input for the CI track's check).

### W2-E Platform integration suites, soak and performance on the self-hosted runner

- **Owned paths:** `compat/scenarios/**`, `Packages/AppCore/Sources/CompatHarness/**`,
  `Packages/AppCore/Sources/TestSupport/Scenario/**`, `Packages/AppCore/Tests/TestSupportTests/**`,
  `TestHost/**`, `perf/**`
- **Depends on:** W1-H, W1-D, W1-E, W1-F; runs green only after W2-A merges.
- **Scope:** PLT-R107, PLT-R204, PLT-R320, PLT-R341, PLT-R353, PLT-R361, PLT-R371, PLT-R387, PLT-R398B, PLT-R420, PLT-R421, PLT-R422, PLT-R504, PLT-R730, PLT-R821, PLT-R822, PLT-R901, PLT-R906, PLT-R1108, PRD-R1, PRD-R13, PRD-R19, PRD-R30, PRD-R44, PRD-R52, QA-R11, QA-R12, QA-R14, QA-R16, QA-R21, QA-R40
- **Work:** QA-R11 integration scenarios against TestHost (200 common words in both methods, English restore,
  backspace across punctuation, 15 keys per second, toggle, per-app switching between two windows, macros `vn`
  and `@@`, restore hotkey twice, secure input on/off, tap disable and recovery, permission revoked mid-session),
  13.2 third-party scenarios, privacy canary over written files and unified log, egress check procedure,
  1,000,000-keystroke soak, T2-T6/C1/C2/M1/M2 measurement with `proc_pid_rusage`, baselines in `perf/`.
- **Acceptance:**
  - Every scenario passes `--dry-run` on hosted CI; the full suite is documented to run only on the self-hosted
    runner (QA-R12, QA-R13) and is never executed directly on Pa's Mac.
  - Baseline file format agreed with the CI track; the gate script fails on more than 25 % regression
    (PLT-R822).
  - Report lists exactly which scenarios Pa must run by hand and which need the runner.

### W2-F Localisation completion and accessibility

- **Owned paths:** `App/Sources/Shell/**`, `App/Sources/Onboarding/**`, `App/Resources/Assets.xcassets/**`,
  `App/Resources/SystemPanes.json`, `App/Resources/Localization/Common.xcstrings`, `Menu.xcstrings`,
  `Status.xcstrings`, `Onboarding.xcstrings`, `Packages/AppCore/Sources/ShellCore/Localization.swift`,
  `SystemPanes.swift`, `StatusPresentation.swift`, `Onboarding.swift`, `Brand.swift`,
  `Packages/AppCore/Tests/ShellCoreTests/Localization/**`
- **Depends on:** W1-G.
- **Scope:** PLT-R211, PRD-R10, PRD-R12, PRD-R62, PRD-R66, PRD-R67, PRD-R68
- **Work:** a catalog test over all ten tables (keys in vi and en, placeholder parity, no empty values, no
  hard-coded app name), copy review against 03-product.md, VoiceOver labels and hints on every control in the
  owned windows, HUD announcements, keyboard navigation and focus rings, Increase Contrast and Reduce Motion
  behaviour, PRD-R68 observation notes for Pa.
- **Acceptance:**
  - Catalog test green for all tables (it reads tables owned by W2-B, W2-C and W2-D but does not edit them;
    failures are reported to their owners).
  - Accessibility audit checklist per window committed in the report with the items Pa must check with
    VoiceOver.

## Coverage of 02, 03 and 04 by workstream

| Area | Workstreams |
|---|---|
| Diagnostics, privacy, capture, report format | W1-A, W2-C |
| Settings, migrations, export/import, macro import | W1-B, W2-B |
| Compatibility rules, schema, matrix, fingerprinting, lint | W1-C |
| Injection worker, strategies, pasteboard preservation | W1-D |
| Tap, decision pipeline, ordering, conservation, fail-open, watchdogs | W1-F, W2-A |
| Layout tables, input sources, secure input, focus/AX, per-app memory, hotkeys, permissions | W1-E |
| Menu bar and icon states, HUDs, onboarding (8 screens) | W1-G, W2-F |
| Settings (5 panes), macros editor, Apps pane, About & Support with donation block | W2-B |
| Bug report, diagnostics window, latency probe, typing trace, guided test | W2-C |
| Localisation (vi + en, runtime switch, pane names) | W1-G, W2-B/C/D (own tables), W2-F |
| Sparkle updater | W2-D |
| TestHost, local test pages, CompatHarness, scenarios | W1-H, W2-E |
| Spike S1 | W1-H (Pa runs it) |
| CI workflows, release scripts, Homebrew, website, project docs | other tracks (see traceability "Workstream") |
