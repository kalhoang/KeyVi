# Implementation workstreams

How the platform layer gets built in parallel workstreams. Three waves (wave 2 has two halves); at most
eight workstreams run at once; inside a wave no file is owned by two workstreams. Every workstream starts from
the compiled skeleton on this branch (`Packages/AppCore`, `project.yml`, `App/`, `TestHost/`, `SpikeIMK/`,
`compat/schema/`) and implements behind the public signatures in [contracts.md](contracts.md). Requirement
scope lists are derived from [traceability.md](traceability.md). Revised on 2026-11-13 after an independent
design review (contracts.md, "Review findings: decisions").

## What the skeleton already provides

The skeleton implements, with tests (`*SeamTests.swift`), every piece that more than one workstream needs at the
same time ([ADR 0313](../decisions/0313-testability-seams.md)), so "Depends on: skeleton only" is true in fact:

| Seam | Files (owner may optimise, must keep behaviour and keep the seam tests green) |
|---|---|
| Tap <-> worker state: `JobQueue` (in flight until echo, [ADR 0311](../decisions/0311-in-flight-until-echo.md)), `EchoExpectation`, `InFlightPolicy`, `WorkerFeedback`, `EchoTracker`, `EventMarker`, `CurrentFocusGeneration`, `PasteboardTypeName` | `Injection/Queue.swift`, `Marker.swift`, `ReverseDNSConstants.swift` (W1-D) |
| Hot-path diagnostics sinks: `Log2Histogram`, `AtomicCounter`, `PlatformMetrics`, `PerBundleHistograms`, `HealthEventLog`, `TapLogRing` | `Diagnostics/Metrics.swift`, `Health.swift`, `TapLog.swift` (W1-A) |
| Timers and atomics: `TimerScheduler`, `DispatchTimerScheduler`, `AtomicUInt64Array` | `RealtimeSupport/TimerScheduler.swift`, `AtomicArray.swift` (W1-A) |
| `CallbackWatchdog`, `TapEventMask.cgMask`, `TapSnapshots.reclaimAll` | `InputHost/Tap/CallbackWatchdog.swift`, `TapThread.swift`, `Snapshots/Snapshots.swift` (W1-F2, W1-F1) |
| `Brand.from` (the App reads it at launch) | `ShellCore/Brand.swift` (W1-G) |
| Shared fakes: `SimulatedTextField` (all five behaviours), `ManualScheduler`, `RecordingLogger`, `InMemoryFileSystem`, `ManualClock`, `FixedWallClock`, `InMemoryKeyValueStore` | `TestSupport/Fakes/Common/**` (integrator, frozen) |
| Area fakes implemented now: `FakeEventPoster` (`.delivering`, `.silentlyDropping`, `.failingCreation`), `FakeFocusedFieldAccess`, `FakePasteboard`; `FakeDecisionResolver`; `FakeEventTapFactory`, `FakeEventTapHandle` | `Fakes/Injection/**` (W1-D), `Fakes/Rules/**` (W1-C), `Fakes/Tap/**` (W1-F2) |
| Runnable spike S1 (counts keys, opt-in commit test) and its README for Pa | `SpikeIMK/**` (Pa runs it now) |

## Rules for every workstream

1. **Read first:** `spec/05-clean-room.md`, `CLAUDE.md`, `ARCHITECTURE.md`, the contract sections for your
   paths, and the spec sections behind your scope IDs. Clean-room rules apply in full (CLR-R1-R5).
2. **Ownership.** Edit only your owned paths. Everything else is read-only for you. These are frozen for the
   whole of waves 1 and 2 and change only through the integrator: `Packages/AppCore/Package.swift`,
   `project.yml`, `Config/**` (except `Config/Sparkle.xcconfig`, owned by W2-D), `App/Info.plist`,
   `Packages/AppCore/Sources/AppModel/**`,
   `Packages/AppCore/Sources/TestSupport/Fakes/Common/**`, the `ScaffoldTests.swift` and `*SeamTests.swift`
   files (owners may add tests next to them), `ARCHITECTURE.md`, `docs/architecture/**`,
   `docs/decisions/030x-*.md` and `031x-*.md`. Need a change there? Put the exact request in your report.
3. **Public signatures are contracts.** Keep them. If one is wrong, change it only inside your own module,
   keep it compiling for every consumer, and list the change in your report so the integrator reruns
   `python3 -I docs/architecture/tools/sync_contracts.py`.
4. **Tests first** (QA-R3), Swift Testing, at least 80 % line coverage of your module (QA-R2). Use a private
   scratch path: `swift build --scratch-path .build-<workstream>` and `swift test --scratch-path
   .build-<workstream>` in `Packages/AppCore`. App targets: `xcodegen generate` then `xcodebuild ...
   CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/<workstream>-dd build`. Time-dependent code takes
   `any MonotonicClock` and `any TimerScheduler` and is tested with `ManualClock` and `ManualScheduler`; no test
   sleeps for real except the `DispatchTimerScheduler` seam test.
5. **Never on Pa's Mac:** launch the app, post synthetic events, create event taps, change input sources,
   System Settings, TCC or permissions, use `sudo`. Code that needs those runs under fakes in tests; the real
   path is verified by W2-E2 on the self-hosted runner, or by Pa through the interim checklist below (items
   marked **Pa** in traceability.md).
6. **Privacy and hot path.** No typed content in logs (typed `LogEvent` only, no interpolation); nothing in
   `InputHost/Pipeline`, `InputHost/Tap` or the producer side of `Injection/Queue` may lock, allocate in steady
   state, do I/O or call AX/TIS/AppKit (PLT-R304, PLT-R305).
7. **Brand.** Never hard-code the display name, slug, bundle ID or site host; UI strings take the app name as
   a format argument (CLAUDE.md). Bundle IDs appear only in `compat/*.json` and test fixtures (PLT-R501);
   reverse-DNS constants that are not bundle IDs go in `ReverseDNSConstants.swift`.
8. **Accessibility in every UI workstream** (PRD-R66, PRD-R67): every control you add has an accessibility
   label and hint whose keys live in your own String Catalog, is reachable by keyboard with a visible focus
   ring, conveys nothing by colour alone, and respects Reduce Motion. W2-F audits afterwards; it does not add
   labels for you.
9. **Remove `unimplemented()`** from every member you own before you finish; leave none reachable.
10. **Commits:** English Conventional Commits, no AI attribution, on your own branch; the integrator merges.
11. **Report:** what you built, test and coverage numbers, contract changes, requests for frozen files,
    VERIFY items you could not close, and items Pa must test by hand.

## Wave 1: start immediately against the skeleton (8 workstreams)

### W1-A Realtime primitives and Diagnostics

- **Owned paths:** `Packages/AppCore/Sources/RealtimeSupport/**`, `Packages/AppCore/Sources/Diagnostics/**`,
  `Packages/AppCore/Tests/RealtimeSupportTests/**`, `Packages/AppCore/Tests/DiagnosticsTests/**`,
  `Packages/AppCore/Sources/TestSupport/Fakes/Diagnostics/**`
- **Depends on:** skeleton only.
- **Scope:** PLT-R388, PLT-R801, PLT-R802, PLT-R901, PLT-R902, PLT-R903, PLT-R904, PLT-R905, PLT-R1202, PLT-R1203, PLT-R1206, PRD-R33, PRD-R45, PRD-R46, QA-R44
- **Work:** harden and benchmark the skeleton's `SnapshotCell`, `SPSCRing`, signals, clock, `TimerScheduler`,
  `AtomicUInt64Array` and the skeleton metrics/health/tap-log implementations (stress tests, Thread Sanitizer,
  allocation counting); implement redaction (salted SHA-256), typed `LogEvent` rendering, `DiagnosticsLogger`
  (JSON lines, 0700/0600, rotation 5 x 1 MB, 14-day retention, `os.Logger` mirror), the `HealthEventLog`
  log-file mirror, `DiagnosticsRenderer` (plain text vi/en, JSON, QA-R44 block and its parser, the typed
  `ReportedOverride` rendered as rule JSON), `CaptureController` (time box, rings, gap records, rendering,
  export-then-delete, 24 h purge, excluded from backup), `PlatformSignposts`.
- **Acceptance:**
  - `swift test --filter "RealtimeSupportTests|DiagnosticsTests"` green, also under `--sanitize=thread`;
    coverage of both modules at least 80 %.
  - Snapshot read path, `SPSCRing.push/pop`, `Log2Histogram.record` and `TapLogRing.push` show zero heap
    allocations in a malloc-counting test; 10 million concurrent publish/read iterations never observe a torn
    or freed value.
  - Canary test: logging every `LogEvent` case with canary-shaped metadata, plus a full report and issue block,
    never contains the canary string (PLT-R901, PLT-R1203). The report case includes a `ReportedOverride` built
    from an override whose URL prefix, title pattern and summary are canaries (ADR 0312).
  - `parseIssueBlock(issueBlock(report))` round-trips every `DiagnosticsBlockKey`; an unknown format version
    returns nil.
  - Capture refuses more than 180 s, stops by itself, marks secure-input gaps, deletes files older than 24 h and
    right after export; files are 0600 and excluded from backup (checked with `InMemoryFileSystem` and a temp
    directory).

### W1-B SettingsStore, macro importers, legacy folder move

- **Owned paths:** `Packages/AppCore/Sources/SettingsStore/**`, `Packages/AppCore/Tests/SettingsStoreTests/**`
  (including `Fixtures/`), `Packages/AppCore/Sources/TestSupport/Fakes/Settings/**`
- **Depends on:** skeleton only.
- **Scope:** PLT-R392, PLT-R541, PLT-R903, PLT-R912, PLT-R1001, PLT-R1002, PLT-R1003, PLT-R1004, PLT-R1005, PLT-R1006, PLT-R1007, PLT-R1009, PLT-R1010, PRD-R5, PRD-R6, PRD-R18, PRD-R23, PRD-R26, PRD-R29, PRD-R32, PRD-R52, PRD-R69, PRD-R70, PRD-R72, QA-R41
- **Work:** Codable mapping of the four documents exactly as in contracts.md section 7 (absent = unset, `null`
  = explicitly none), raw-object overlay that preserves unknown keys, the store actor on the utility queue
  (load, debounced atomic writes, 5 s app-modes debounce, notices), migrations with backups (newest 5),
  corruption quarantine and recovery, newer-schema read-only, `LaunchGuard`, reset scopes, export/import with
  preview and skipped fields, `MacroImporter` (four formats), `MacroValidator`, `LegacyStorageMigrator`
  ([ADR 0307](../decisions/0307-settings-file-layout.md) amendment).
- **Acceptance:**
  - Unknown keys at every level survive load and rewrite; `.unset` vs `.set(default)` round-trips; changing a
    default in `DefaultSettings` changes the effective value only for unset keys (PRD-R6).
  - Fixture per schema version (v1 now) loads, migrates and compares; migration writes a backup first.
  - Truncated `settings.json` -> renamed `.corrupt-<timestamp>`, newest valid backup loaded, notice emitted, no
    data loss beyond the last 1 s debounce window (every write leaves its bytes as the newest backup; spec
    02-platform.md section 10 acceptance), no overwrite before confirmation; no backup -> defaults in memory,
    nothing written (PLT-R1006).
  - A file with `schemaVersion` 2 is used read-only for known fields and never rewritten (PLT-R1007).
  - Three launches that do not reach `markSurvived()` within the window enter safe mode without touching
    files (PLT-R1009).
  - Export on v1 then import reproduces the same `SettingsState`; untrusted import fuzz (random bytes, 6 MB
    file, deep nesting) never crashes and is rejected with a reason (PLT-R912).
  - Macro import: each format parses its fixture; invalid rows are reported with line numbers and reasons;
    duplicates resolve with keep-mine/use-imported; the shadowing rule rejects `vn` + `vn.` (PRD-R29).
  - Legacy folders: with `InMemoryFileSystem`, a legacy folder moves to the current name in both bases with
    0700 kept; both existing -> `.skippedBothExist` and nothing changes; no legacy -> `.notNeeded`.

### W1-C CompatRules, rules data and lint

- **Owned paths:** `Packages/AppCore/Sources/CompatRules/**`, `Packages/AppCore/Sources/CompatLint/**`,
  `Packages/AppCore/Tests/CompatRulesTests/**`, `Packages/AppCore/Sources/TestSupport/Fakes/Rules/**`,
  `compat/rules.json`, `compat/matrix.json`, `compat/schema/**`
- **Depends on:** skeleton only.
- **Scope:** PLT-R398C, PLT-R407, PLT-R408, PLT-R422, PLT-R460, PLT-R501, PLT-R502, PLT-R503, PLT-R504, PLT-R505, PLT-R506, PLT-R510, PLT-R520, PLT-R521, PLT-R522, PLT-R531, PRD-R35, PRD-R38, PRD-R39, QA-R17, QA-R19
- **Work:** `RuleProvenance` coding, loader with validation and embedded fallback (no bundle IDs in Swift),
  `RuleSet` compilation and resolution (specificity, user precedence, ties, opted-in rules, `byEngine`
  resolution, params caps, `ResolvedDecision.userOverride` set for user wins), `EngineFingerprinter`,
  `MatrixStatusResolver`, `RulesLinter` and the `compat-lint` CLI (`compat-lint --rules compat/rules.json
  --matrix compat/matrix.json --scenarios compat/scenarios [--release]`, non-zero exit on errors), seeded
  `compat/rules.json` (defaults, `terminals` and `webkitBrowsers` groups, conflicting input apps with their sources in `compat/conflicting-apps.json`, secure-input
  hints for Terminal and iTerm2, the rules of 02-platform.md 5.6 and section 6 with honest `VERIFY` notes,
  including `requireTextFocus: never` for custom text views), seeded `compat/matrix.json` with every Tier 1 and
  Tier 2 app of PRD-R39 as `notVerified`.
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
- **Depends on:** skeleton only (skeleton `JobQueue`/`EchoTracker`/`EventMarker`, `SimulatedTextField`, the
  injection fakes, `ManualClock`, `ManualScheduler`, metrics).
- **Scope:** PLT-R203, PLT-R311, PLT-R313, PLT-R314, PLT-R315, PLT-R316, PLT-R320, PLT-R321, PLT-R322, PLT-R323, PLT-R324, PLT-R342, PLT-R343, PLT-R401, PLT-R402, PLT-R403, PLT-R404, PLT-R405, PLT-R406, PLT-R407, PLT-R408, PLT-R409, PLT-R410, PLT-R420, PLT-R421, PLT-R460, PLT-R461, PLT-R462, PLT-R480
- **Work:** `InjectionWorker` (thread loop and `runUntilIdle` step mode, FIFO, marker event sequence, echo
  expectations through `JobQueue.finished(_:expectation:)`, generation discard with trigger replay, liveness
  flush, pairedKeyUp, `requestFlush`, nothing posted while posting is broken with counted losses),
  `EditMinimizer`, `UnicodeChunker`, the four strategy executors with inline completion,
  `PasteboardPreserver`, production `CGEventPoster`, `AXFocusedFieldAccess`, `NSPasteboardAccess`; benchmarks of
  the skeleton queue.
- **Acceptance:**
  - "nguyen" + `s` produces exactly 2 backspaces and 2 inserted characters (4.10 acceptance) through
    `backspaceReplace` on `SimulatedTextField`-backed fakes.
  - Worker property tests with a scripted producer: FIFO order, held events replayed once and in order, a job
    of an old generation is discarded and its trigger replayed, liveness at 150 ms (1 s for macros) and 256 jobs
    abandons only unstarted edits, pairedKeyUp dropped after execution and replayed after abandonment
    (ADR 0308); every job ends with exactly one `finished` call, with an expectation iff it posted.
  - Inline completion: with a selected suggestion, `axSelection` deletes it first; on AX timeout
    `axSelectionThenPlaceholder` falls back to the placeholder; placeholder leaves no residue over 1,000
    randomised edits on the simulated field.
  - Pasteboard: multi-item, multi-type snapshot is byte-identical after 100 paste jobs; marker types present;
    `changeCount` guard skips restore after a user copy; file promise or more than 10 MB aborts paste and uses
    the fallback. Run against `FakePasteboard` and against a uniquely named `NSPasteboard` (no general
    pasteboard access in tests).
  - Posting broken: with `FakeEventPoster.setMode(.silentlyDropping)` and `isPostingBroken` set, the worker
    posts nothing further, `lostWhilePostingBroken` equals the undeliverable events and one `postingBroken`
    health event carries the count (ADR 0311).
  - No forward-delete keycode is ever posted by any strategy (static test over the executors).

### W1-E InputHost host services

- **Owned paths:** `Packages/AppCore/Sources/InputHost/Hotkeys/**`, `.../InputHost/InputSource/**`,
  `.../InputHost/SecureInput/**`, `.../InputHost/Focus/**`, `.../InputHost/Memory/**`,
  `.../InputHost/Permissions/**`, `.../InputHost/Workspace/**`, `Packages/AppCore/Tests/InputHostTests/Services/**`,
  `Packages/AppCore/Sources/TestSupport/Fakes/Host/**`
- **Depends on:** skeleton only (`FakeDecisionResolver`, `ManualClock`, `ManualScheduler`).
- **Scope:** PLT-R203, PLT-R333, PLT-R343, PLT-R353, PLT-R354, PLT-R360, PLT-R361, PLT-R370, PLT-R371, PLT-R372, PLT-R373, PLT-R380, PLT-R381, PLT-R382, PLT-R383, PLT-R384, PLT-R385, PLT-R386, PLT-R387, PLT-R390, PLT-R391, PLT-R392, PLT-R393, PLT-R395, PLT-R396, PLT-R397, PLT-R398, PLT-R398A, PLT-R399, PLT-R510, PLT-R523, PLT-R701, PLT-R702, PLT-R711, PLT-R720, PLT-R721, PLT-R740, PLT-R803, PRD-R14, PRD-R15, PRD-R16, PRD-R17, PRD-R18, PRD-R19, PRD-R20, PRD-R21, PRD-R22
- **Work:** `HotkeyRecognizer` and `HotkeyRecorder` (contracts.md 10.2), `UCKeyTranslateLayoutBuilder`,
  `TISInputSourceProvider`, `InputSourceMonitor` (classification, built-in Vietnamese detection by language
  and kind, layout binding, keyboard types), `SystemSecureInputProbe` (IORegistry `IOConsoleUsers`),
  `SecureInputMonitor` (2 s poll through the scheduler, transition generations, episode end on key evidence,
  holder naming, hint keys), `ProcessIdentityProvider`, bundle inspector, `SystemAXProvider`,
  `AXCircuitBreaker`, `FocusTracker` (observers, system-wide authority, overlay apps, idle revalidation, inbox
  draining, `HostDecisionMapper`, generation publication), `RuleSet: FocusDecisionResolving` conformance,
  `AppModeMemory`, `SystemPermissionProbe`, `PermissionMonitor` (cadence through the scheduler, stale),
  `PermissionResetting`, `NSWorkspaceEvents`, `ConflictDetector`, the fakes.
- **Acceptance:**
  - Recogniser table tests: Control+Shift tap toggles on release; cancelled by a key, click or scroll in
    between, by holding longer than 500 ms, and when used with another key; autorepeat ignored; right Command
    tap; combo consumed; restore candidate only for its binding. Recorder captures every PRD-R15 chord in any
    press order and flags the seven PRD-R16 conflicts.
  - Layout tables built from the installed ABC, German, French and Dvorak layouts (read by ID, nothing
    selected): `y`/`z` on QWERTZ, `a`/`q`/`w` on AZERTY, Shift digits on AZERTY, dead keys flagged.
  - Focus with fake AX: a non-activating overlay owns focus, so its memory and rule apply; 3 AX timeouts in
    10 s open the breaker for 60 s (`ManualClock`); `AXSecureTextField` yields `.secureField`; title and URL never
    appear in a published snapshot; resolution happens once per focus change
    (`FakeDecisionResolver.resolvedContexts`).
  - Memory: PRD-R21 precedence table, LRU eviction at 1,000 without evicting explicit rules, toggle updates
    memory and global mode, document round-trip.
  - Secure input: generation changes on transitions; holder mapping for app, `loginwindow` (by process name),
    dead PID, unknown; `keyEvidence` keeps the resumed state until the next poll; the sequence on -> off -> key
    evidence -> on within one poll interval yields a new generation at the next poll (the tap pauses again).
  - Permissions: cadence 2 s / 30 s / 1 s (onboarding) with `ManualScheduler`, stale detection on digest change;
    `tccutil` command built only with the app's own bundle ID (never executed in tests).
  - No repeating timer in these services is shorter than 2 s at rest (`ManualScheduler.repeatingIntervals`).

### W1-F1 InputHost pipeline, engine bridge and property suite

- **Owned paths:** `Packages/AppCore/Sources/InputHost/Snapshots/**`, `.../InputHost/Engine/**`,
  `.../InputHost/Pipeline/**`, `Packages/AppCore/Tests/InputHostTests/Pipeline/**`,
  `Packages/AppCore/Sources/TestSupport/Pipeline/**`
- **Depends on:** skeleton only. Uses `ScriptedEngine`, the skeleton `JobQueue`/`EchoTracker`/metrics,
  `SimulatedTextField`, `FakeEventPoster` and a reference job consumer it writes in TestSupport/Pipeline; the
  combined suite with the real worker is W2-A.
- **Scope:** PLT-R210, PLT-R304, PLT-R305, PLT-R307, PLT-R310, PLT-R311, PLT-R312, PLT-R313, PLT-R317, PLT-R321, PLT-R323, PLT-R340, PLT-R341, PLT-R350, PLT-R351, PLT-R352, PLT-R353, PLT-R354, PLT-R355, PLT-R356, PLT-R361, PLT-R363, PLT-R371, PLT-R382, PLT-R386, PLT-R387, PLT-R391, PLT-R398A, PLT-R398B, PLT-R405, PLT-R730, PLT-R820, PLT-R911, PLT-R1008, PRD-R0, PRD-R19, PRD-R27, QA-R14
- **Work:** `KeyPipeline` (PLT-R310 all steps, `EchoTracker.settle` at entry, scroll handling,
  `TapEventHandler` conformance), `KeyClassifier`, `HostStateResolver`, `EngineCatalog`, `EngineBridge`
  (configuration, macro table, catalog; resources loader injected), `VietnameseCompositionEngine(Factory)`,
  `TapOutbox` usage, `ScriptedEngine`, `SimulatedWindowServer`, `ConservationLedger`, `RandomEventGenerator`,
  `PipelineHarness` (with a reference consumer), hosted pipeline microbenchmark.
- **Acceptance:**
  - Property suite (seeded, at least 100,000 sequences per run, both `SimulatedWindowServer` modes) with the
    reference consumer: conservation (PLT-R312), hold-while-busy ordering (PLT-R311) including keys queued at
    the server before a post, keyUp pairing (PLT-R313), marker never on physical events (PLT-R321), fail-open
    stops swallowing within the same callback (PLT-R730), composition reset on every pause/fail-open/focus
    transition (PLT-R210). Self-check: with `InFlightPolicy.untilPosted` and `.lagging`, the suite finds
    ordering violations (the model can see the bug ADR 0311 fixes).
  - Posting broken mid-sequence (`.postingWorks(false)` steps): no event is lost before the switch; losses after
    it are recorded as `lostWhilePostingBroken` and equal the metric.
  - P0-1 tests: secure input on -> paused, no engine feed; first keyDown that reaches the pipeline afterwards
    is composed with no passed-through keys in between (PLT-R398B); only OS state and secure field pause
    (PLT-R398A).
  - Step tests: Return and Tab are fed to the engine before the hard boundary; restore hotkey consumed once,
    passed on the second press; Escape passed is a boundary; keypad digits flagged; navigation never edits;
    autorepeat rules; dead keys pass; a scroll event between Control+Shift press and release cancels the toggle
    and is passed unchanged.
  - Toggle race: a focus snapshot resolved concurrently with a tap toggle never reverts the mode
    (`appliedToggleSequence`).
  - Hot path: allocation-counting test over 10,000 steady-state events shows no allocation outside the engine
    call; microbenchmark records T1 with fakes (baseline file proposed for the CI track).

### W1-F2 Tap thread, watchdogs and the lifecycle state machine

- **Owned paths:** `Packages/AppCore/Sources/InputHost/Tap/**`,
  `Packages/AppCore/Sources/InputHost/Lifecycle/HostLifecycle.swift`,
  `Packages/AppCore/Tests/InputHostTests/Tap/**`, `Packages/AppCore/Tests/InputHostTests/Lifecycle/**`,
  `Packages/AppCore/Sources/TestSupport/Fakes/Tap/**`
- **Depends on:** skeleton only (`FakeEventTapFactory`, `CallbackWatchdog`, `ManualScheduler`, a trivial
  `TapEventHandler` written in its tests). `InputHostController.swift` stays a skeleton until W2-A.
- **Scope:** PLT-R203, PLT-R208, PLT-R210, PLT-R301, PLT-R302, PLT-R303, PLT-R306, PLT-R330, PLT-R331, PLT-R332, PLT-R333, PLT-R730, PLT-R731, PLT-R803, PRD-R44
- **Work:** `TapThread` (thread entry creating the handler, C callback bridge with `RawKeyEvent` extraction,
  `userInfo` to thread state, run loop with only the tap source), `CGEventTapFactory` and its `CFMachPort`
  handle, `TapWatchdog` (250 ms check armed by activity, 5 s enabled check and `reclaimAll`, recovery only after
  the callback returned, `callbackStuck`), `HostLifecycle` (every input and effect of contracts.md 10).
- **Acceptance:**
  - `HostLifecycle` table tests: launch -> noPermission -> starting -> running on grant and tap created; tap
    creation failure -> `failOpen(tapUnavailable)` with retries at 1, 2, 5, 10, 10 s while permissions look
    granted and none while they do not; posting broken -> `removeTap` effects in PLT-R730 order then
    recovery when permission returns (PLT-R731); system disable -> re-enable, reset, flush, health, and the
    instability notice after the fourth disable within 10 minutes; session resign/sleep -> sessionInactive;
    every transition into or out of paused/failOpen carries `resetComposition` (PLT-R210).
  - Watchdog with `ManualScheduler` and a `CallbackWatchdog` driven by the test: over 250 ms -> trip,
    `disableTap`, `failOpen(watchdog)`; callback returned at 2 s -> recovery; still inside at 2 s ->
    `callbackStuck`, and no second handle is ever requested from the factory (PLT-R302); no repeating timer
    while idle; `reclaimAll` called on the 5 s tick.
  - `TapThread` with `FakeEventTapFactory`: `start()` false when creation fails; the handler factory runs on the
    tap thread; `stop()` invalidates the handle and the thread's run loop exits; the standard mask includes
    scroll.

### W1-G Shell chrome: ShellCore, menu bar, HUDs, onboarding, localisation runtime

- **Owned paths:** `Packages/AppCore/Sources/ShellCore/**` (in wave 2 `AppsPane.swift` and `Services.swift`
  pass to W2-B and `BugReport.swift` to W2-C), `Packages/AppCore/Tests/ShellCoreTests/**`, `App/Sources/Shell/**`,
  `App/Sources/Onboarding/**`, `App/Resources/Assets.xcassets/**`, `App/Resources/SystemPanes.json`,
  `App/Resources/Localization/Localizable.xcstrings`, `App/Resources/Localization/Menu.xcstrings`,
  `App/Resources/Localization/Status.xcstrings`, `App/Resources/Localization/Onboarding.xcstrings`
- **Depends on:** skeleton only (host state and permissions through protocols and fakes).
- **Scope:** PLT-R205, PLT-R206, PLT-R211, PLT-R362, PLT-R397, PLT-R398C, PLT-R399, PLT-R540, PLT-R541, PLT-R701, PLT-R704, PLT-R710, PLT-R711, PLT-R712, PLT-R740, PLT-R741, PLT-R909, PLT-R913, PLT-R1202, PRD-R9, PRD-R10, PRD-R11, PRD-R12, PRD-R13, PRD-R33, PRD-R34, PRD-R35, PRD-R36, PRD-R40, PRD-R41, PRD-R42, PRD-R43, PRD-R47, PRD-R57, PRD-R62, PRD-R63, PRD-R64, PRD-R65, PRD-R66, PRD-R67, CLR-R7
- **Work:** `Localizer` and `InterfaceLanguageModel` (ADR 0310), `SystemPaneTable` and the VERIFY-marked
  `SystemPanes.json` (macOS 15/26 and 27, vi and en), `StatusPresentation`, `StatusLine` (every row of PRD-R43,
  including "App in Known limitation list" from `FrontmostAppStatus`, "paused: no text field detected" with
  `.overrideTextFocus`, the tap-re-enabled notice and `failOpen(callbackStuck)` with `.reopenApp`), `MenuModel`,
  `HotkeyDisplay`, `OnboardingFlow`, `AppLocationCheck`, `ReportAssembler` (including
  `reportedOverride(from:)`), `BugReportComposer` (GitHub URL from `Brand.repositoryURL`, `MailDraft`,
  `mailtoURL`), `SystemInfoReader`, `AppsPaneModel`, `CompatibilityModeChoice`, `URLSchemeRouter`,
  `SMAppServiceLoginItem`, `DonationInfo`; `StatusItemController` (replacing the skeleton's
  `BootstrapStatusItem`), `SwitchHUDController`, `CaptureHUDController`, `OnboardingWindowController` with the
  eight screens; monochrome template icons for every `StatusIconState` (start from the skeleton's programmatic
  `StatusGlyph`; placeholders with recorded source and a VERIFY flag for Pa, CLR-R7); placeholder onboarding
  illustrations marked VERIFY; all copy of PRD-R10, PRD-R11, PRD-R40-R43 verbatim in Vietnamese with English
  equivalents.
- **Acceptance:**
  - `Localizer` returns Vietnamese for `.vietnamese` and English for `.english` from the same bundle regardless
    of the process language; switching `InterfaceLanguageModel` changes rendered strings without restart;
    every key in the four owned catalogs exists in vi and en with matching format arguments (catalog test that
    parses the `.xcstrings` files).
  - State-to-icon and state-to-status-line tables cover every `HostState`; `StatusLine` precedence covers
    host state > tap notice > known limitation, and `noTextFocus` offers `.overrideTextFocus(bundle:)`; menu
    model matches PRD-R11 order; onboarding flow skips screens 5 and 6 when their condition is false, never
    allows skipping screen 2, advances within one permission poll, and shows only screen 2 after permission
    loss (PRD-R42).
  - `AppLocationCheck` rejects translocated, read-only-volume and outside-Applications paths.
  - Report assembly contains no field outside PLT-R1202 and includes the per-app entry of the reported app
    only (PLT-R913); `reportedOverride(from:)` of a canary override contains no canary (ADR 0312); GitHub URL
    and mail body never include the diagnostics block content beyond the summary; with no repository URL or
    support email the respective path is unavailable.
  - Every control in owned windows has an accessibility label and hint key in an owned catalog (PRD-R66).
  - `xcodebuild -scheme App` builds without warnings in owned files; no `Text("...")` literal for product copy.

## Wave 2a: needs wave 1 merged (5 workstreams)

Frozen-file rule continues (the integrator updates `Package.swift`/`project.yml` between waves if a
workstream asked for it). Wave-1 owned paths not listed below become read-only again.

### W2-A Composition root, host controller, end-to-end with fakes

- **Owned paths:** `App/Sources/Composition/**`, `Packages/AppCore/Sources/InputHost/Lifecycle/InputHostController.swift`,
  `Packages/AppCore/Sources/InputHost/Integration/**`, `Packages/AppCore/Tests/InputHostTests/Integration/**`,
  `App/Resources/Localization/Composition.xcstrings` (added at the wave 2a merge: safe-mode, move-failed and
  conflict-notice copy; since wave 2b its keys are ShellCore's `CompositionText`, `StringTable.composition`)
- **Depends on:** W1-A to W1-G.
- **Scope:** PLT-R201, PLT-R205, PLT-R307, PLT-R311, PLT-R312, PLT-R314, PLT-R316, PLT-R399, PLT-R710, PLT-R909, PLT-R1008, PLT-R1009, PRD-R27, PRD-R52, QA-R42
- **Work:** `InputHostController` (performs `HostLifecycle` effects with the real services, timers through
  `InputHostDependencies.scheduler`), `AppEnvironment` (launch order with `LegacyStorageMigrator` before
  `SettingsStore.load`, services, window controllers, quit flush, URL scheme), removal of the skeleton's
  `BootstrapStatusItem` from the launch path, host assembly with production services, settings-to-snapshot
  bridge (engine catalog from `Resources.bundled`, user lists, macros, per-app overrides into `RuleSet`),
  conflicts and learning proposals to the shell, first-launch-after-update self-check, the combined pipeline +
  real worker property suite, the D10 decision (hidden until the engine offers literal mode, ADR 0306).
- **Acceptance:**
  - Combined property suite (`PipelineHarness` with the real `InjectionWorker` in step mode, scripted and real
    engine, both window-server modes): 100,000 sequences, zero conservation, ordering, liveness,
    generation-discard or keyUp violations.
  - End-to-end with fakes: Telex "duyeetj" -> "duyệt" under ABC, QWERTZ, AZERTY and Dvorak tables; VNI
    "duye65t" -> "duyệt" under ABC and AZERTY; Japanese source -> no transformation and pause reason; settings
    change applies on the next key without losing the word.
  - Launch path with fakes: safe mode after three crashes; move offer before any permission request when the
    bundle is translocated; legacy folder moved before load; S1 ready-after-launch measured with fakes under
    300 ms; `InputHostController` with fakes follows the `HostLifecycle` tables end to end.
  - The app builds in Release (universal) once `compat/rules.json` exists; `codesign` is not run in a workstream.

### W2-B Settings window, macros editor, Apps pane, About & Support

- **Owned paths:** `App/Sources/Settings/**`, `App/Resources/Donation.xcassets/**`,
  `App/Resources/Localization/Settings.xcstrings`, `Macros.xcstrings`, `Apps.xcstrings`, `Support.xcstrings`,
  `Packages/AppCore/Sources/ShellCore/AppsPane.swift`, `Packages/AppCore/Sources/ShellCore/Services.swift`,
  `Packages/AppCore/Sources/ShellCore/Settings/**` (view models, ADR 0305; added at the wave 2a merge),
  `Packages/AppCore/Tests/ShellCoreTests/Settings/**`
- **Depends on:** W1-B, W1-C, W1-E, W1-G.
- **Scope:** PLT-R373, PLT-R462, PLT-R540, PLT-R1010, PRD-R7, PRD-R15, PRD-R16, PRD-R24, PRD-R25, PRD-R26, PRD-R28, PRD-R31, PRD-R32, PRD-R34, PRD-R36, PRD-R37, PRD-R53, PRD-R57, PRD-R59, PRD-R62, PRD-R66, PRD-R67
- **Work:** five panes in PRD-R24 order with one-line explanations and Advanced disclosures (remembered),
  practice field, tone placement preview, user lists, hotkey recorder UI with conflict warnings, layout
  binding (General > Advanced), per-pane and global reset with export offer, export/import sheets with
  summary, macros editor (search, sort, add, edit, duplicate, delete, enable/disable all, validation messages)
  and import preview, Apps pane (rows, rule picker, status, Advanced compatibility mode, report button),
  About & Support (version, channel, update controls through `UpdaterControlling`, diagnostics entry, privacy
  summary, licences, donation block with placeholder QR images marked VERIFY); VoiceOver labels and hints and
  full keyboard navigation for every control (rule 8).
- **Acceptance:**
  - View-model tests: "not a setting" items never appear (PRD-R7); every setting has an explanation key in vi
    and en; reset offers export first and keeps macros unless ticked; import summary lists changes and skipped
    fields.
  - Macro editor rejects invalid shortcuts with the PRD-R29 reasons; import preview counts match W1-B.
  - Compatibility mode choices write and remove the expected user override JSON (PLT-R540).
  - Every control has an accessibilityLabel and hint key in the four owned catalogs (catalog test); the tab
    order reaches every control.
  - Catalog test for the four owned tables; no pane scrolls at default size except Apps, Macros and About & Support (manual
    check by Pa listed in the report).

### W2-C Diagnostics window, bug report, guided test, typing trace, latency probe

- **Owned paths:** `App/Sources/Diagnostics/**`, `App/Resources/Localization/Diagnostics.xcstrings`,
  `Packages/AppCore/Sources/InputHost/Probes/**`, `Packages/AppCore/Tests/InputHostTests/Probes/**`,
  `Packages/AppCore/Sources/ShellCore/BugReport.swift`, `Packages/AppCore/Tests/ShellCoreTests/BugReport/**`,
  and since the wave 2a merge `ShellCore/BugReportSummary.swift`, `ShellCore/ReportAssembly.swift`, and since
  wave 2b `ShellCore/DiagnosticsText.swift` (the Diagnostics keys, controls and copy helpers, split out of
  `BugReportSummary.swift` by W2-H)
- **Depends on:** W1-A, W1-D, W1-F1, W1-G.
- **Scope:** PLT-R410, PLT-R540, PLT-R810, PLT-R905, PLT-R1201, PLT-R1204, PLT-R1205, PRD-R47, PRD-R48, PRD-R49, PRD-R62, PRD-R66, PRD-R67
- **Work:** diagnostics window (PLT-R1201), report preview before copy/save (PLT-R1204), bug report sheet with
  GitHub, email and save paths and the clipboard notice (PRD-R47-R49); "Gửi qua email" uses
  `NSSharingService(named: .composeEmail)` with recipients, subject, body and the JSON report file as an
  attachment, falling back to `BugReportComposer.mailtoURL` (no attachment) plus "Lưu tệp..." when no mail
  service is available; "This app misbehaves" flow with `GuidedTestRunner` candidates, human fallback question
  and rule suggestion shown on its own (PLT-R1205, ADR 0312), typing trace confirmation, HUD, review rendering
  and export (PLT-R905), latency probe window and driver (PLT-R810); VoiceOver labels, hints and keyboard
  navigation (rule 8).
- **Acceptance:**
  - Guided test with fakes on a simulated inline-completion field recommends `axSelection` or `placeholder`,
    and the resulting override fixes the simulated symptom (12 acceptance).
  - Suggestion JSON validates against `userOverrideRule` of the rules schema; a URL prefix appears only when the
    user opted in and is cut to host level; the report generated afterwards contains no URL (ADR 0312).
  - A report generated during a canary session contains no canary; a first-time user reaches "Copy report" in
    at most 3 clicks from the menu (view-model test of the navigation path).
  - Probe driver result math tested with synthetic timestamps (`ManualClock`); no probe code runs in tests
    against the real poster.
  - Every control has an accessibilityLabel and hint key in the owned catalog.

### W2-D Sparkle updater

- **Owned paths:** `App/Sources/Updater/**`, `App/Resources/Localization/Updates.xcstrings`,
  `Config/Sparkle.xcconfig`
- **Depends on:** W1-B, W1-G.
- **Scope:** PLT-R104, PLT-R752, PLT-R906, PLT-R1101, PLT-R1102, PLT-R1105, PRD-R50, PRD-R51, PRD-R53, PRD-R62, PRD-R66, PRD-R67, QA-R28, QA-R33
- **Work:** `UpdaterController` over `SPUStandardUpdaterController` (manual start), settings D19-D21 applied
  at launch and on change, beta channel delegate (`MainActor.assumeIsolated` inside the `nonisolated` delegate
  methods), install-on-quit with the idle relaunch rule, no system profiling, update-failed copy (PRD-R43),
  accessible custom controls if any (rule 8), documentation of the EdDSA key step for Pa in the report
  (ADR 0304 runbook note).
- **Acceptance:**
  - Delegate tests: channels `[]` for stable and `["beta"]` after opt-in; immediate installation only after
    60 s idle with secure input off; `SUEnableSystemProfiling` false and feed URL derived from the site host
    (Info.plist test on the built bundle).
  - URL host allowlist: the built binary contains no host other than the site host, GitHub and the mail
    domain (input for the CI track's check).

### W2-E1 TestHost, local test pages, CompatHarness and scenarios (was W1-H)

- **Owned paths:** `TestHost/**`, `Packages/AppCore/Sources/CompatHarness/**`,
  `Packages/AppCore/Sources/TestSupport/Scenario/**`, `Packages/AppCore/Tests/TestSupportTests/Scenario/**`,
  `compat/scenarios/**`
- **Depends on:** skeleton only in code; starts in wave 2a because wave 1 is full (it can start earlier as soon
  as a wave-1 slot frees). Reads W1-C's scenario schema.
- **Scope:** PLT-R530, QA-R10, QA-R21 (PLT-R207 and PLT-R398D are covered by the skeleton's `SpikeIMK`)
- **Work:** TestHost window with every `TestHostField` (native field and view, WKWebView page with input,
  textarea, contenteditable, simulated address bar with inline autocomplete, simulated spreadsheet cell
  editor, password field), AX identifiers and DOM-to-native mirroring; local pages in
  `TestHost/Resources/Pages/` (inline autocomplete, first-keystroke edit-mode transition, contenteditable
  composer; no network resources); `ScenarioRunner`, scenario loading and schema conformance;
  `compat-harness` CLI with keyboard driver (timing profiles normal 80-150 ms, fast 30 ms, burst 5 ms),
  readbacks (AX, webdriver, terminal capture, human prompt) and `--dry-run`; scenario files for the 13.2
  minimum set and for every shipped rule's `test.scenario`.
- **Acceptance:**
  - `xcodebuild -scheme TestHost` builds with signing disabled; `TestSupportTests/Scenario` verify scenario
    decoding and schema validation of every file in `compat/scenarios`.
  - `compat-harness --dry-run` loads all scenarios and prints the plan without posting events; it is the only
    mode used on Pa's Mac and the mode hosted CI runs.
  - Local test pages load from `file://` without network access (checked by a content test that rejects
    `http(s)://` references).

## Wave 2b: needs wave 2a merged (2 workstreams)

### W2-E2 Platform integration suites, soak and performance on the self-hosted runner

- **Owned paths:** `compat/scenarios/**`, `Packages/AppCore/Sources/CompatHarness/**`,
  `Packages/AppCore/Sources/TestSupport/Scenario/**`, `Packages/AppCore/Tests/TestSupportTests/**`,
  `TestHost/**`, `perf/**`, `docs/runbooks/self-hosted-runner.md`, `docs/runbooks/integration-*.md`,
  `docs/decisions/0502-*.md`
- **Depends on:** W2-A, W2-E1, W1-D, W1-E, W1-F1, W1-F2; runs green only on the self-hosted runner.
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
- **Delivered (2026-11-13):** QA-R11 scenarios against TestHost (the 200 words in both methods as golden files
  checked against the engine, English restore, backspace across punctuation, fast typing, toggle, per-window rule,
  macros, restore hotkey twice), privacy canary scenarios for every strategy, app profiles with per-scenario
  configuration of the test build, the harness side of the integration hooks (`testHook` steps, state probe, app
  histograms, latency probe, soak counters), `compat-harness egress`, the PLT-R822 gate and
  `perf/platform-baseline.json` (placeholders). Runbook: `docs/runbooks/integration-suite.md`. The open items
  (app-side hooks, `testHook` in the scenario schema, `scripts/run-integration.sh`) were delivered by W3-A.

### W2-F Localisation completion and accessibility audit

- **Owned paths:** `Packages/AppCore/Tests/ShellCoreTests/Localization/**`, plus label/hint-only edits in
  `App/Sources/**` and every `App/Resources/Localization/*.xcstrings` (no logic, no layout, no new keys outside
  `*.accessibilityLabel` / `*.accessibilityHint`); safe because W2-B, W2-C and W2-D have merged
- **Depends on:** W1-G, W2-B, W2-C, W2-D (runs after them, so there is something to audit).
- **Scope:** PLT-R211, PRD-R10, PRD-R12, PRD-R62, PRD-R66, PRD-R67, PRD-R68
- **Work:** a catalog test over all ten tables (keys in vi and en, placeholder parity, no empty values, no
  hard-coded app name), copy review against 03-product.md, audit of VoiceOver labels and hints on every control
  of every window, HUD announcements, keyboard navigation and focus rings, Increase Contrast and Reduce Motion
  behaviour, fixes limited to labels and hints, PRD-R68 observation notes for Pa.
- **Acceptance:**
  - Catalog test green for all tables.
  - Accessibility audit checklist per window in the report, with the items Pa must check with VoiceOver;
    every finding outside labels and hints is filed for its owner, not fixed here.

## Wave 3 (3 workstreams)

### W3-A Integration hooks in the test build, end to end

- **Owned paths:** `App/Sources/IntegrationHooks/**`, the hook wiring in `App/Sources/Composition/**`,
  `Packages/AppCore/Sources/{Diagnostics,InputHost,AppModel}/**` (in Diagnostics: metrics, histograms, counters and
  `IntegrationHooks.swift`), `TestSupport/Scenario/**`, `CompatHarness/**`, `project.yml`, `Config/*.xcconfig`
  except Brand and Sparkle, the scenario schema and scenarios, `scripts/run-integration.sh`,
  `scripts/verify-release.sh`, `scripts/tests/**`, `integration.yml`, `perf/**`, ADR 0502, the integration and
  runner runbooks, traceability.
- **Scope:** QA-R11, QA-R16, PLT-R330, PLT-R398B, PLT-R730, PLT-R801, PLT-R821, PLT-R822, PLT-R901, PLT-R909
- **Delivered (2026-11-13):** the `Integration` xcodegen configuration (`INTEGRATION_HOOKS`, release-like code
  generation, dev bundle ID, Apple Development identity) and the release check on the hooks' marker; one shared
  Codable wire definition (`Diagnostics/IntegrationHooks.swift`); the hooks server, directory rules, instruments
  (tap timeout, revocable trust check) and host actions in `InputHost/IntegrationHooks/` with a thin App adapter;
  `HostCounters` (tap recoveries, engine resets, first key after a secure-input release); `PlatformMetrics.reset()`
  and gate-aligned sub-buckets for T2 and T3; `testHook` in the scenario schema and the two automated QA-R11 hook
  scenarios; `scripts/run-integration.sh build` and `tests` through the harness, the default platform baseline, the
  soak comparison and one bench run per merge; traceability for the integration rows. Everything that needs the
  runner is listed in the runbook (sections 2 and 8).

## Interim verification before the self-hosted runner exists

The runner is open question 3/5 for Pa. Until it exists, every traceability row verified by I (TestHost
integration) or C (compatibility scenario) is verified as **M** by Pa on Pa's Mac, with these reduced steps
(traceability.md lists the affected rows). No workstream posts events, creates taps or changes input sources
on that Mac.

1. **Hosted CI, every PR:** `swift test` in `Packages/AppCore` (layer 4, including the 100,000-sequence
   property suites with both window-server modes), `compat-lint`, and `compat-harness --dry-run` over
   `compat/scenarios` (schema and plan check, no events).
2. **Pa, before each alpha build (about 20 minutes):**
   - Install the build from the DMG; grant Accessibility; type in TestHost's native field: Telex `duyeetj` ->
     `duyệt`, VNI `duye65t` -> `duyệt`, Control+Shift toggles VI/EN with the HUD.
   - P0-1 secure input: in Terminal turn on Secure Keyboard Entry -> the menu names Terminal with the hint;
     turn it off -> the very first word typed is composed.
   - P0-2 ordering: type `nguyeenx nguyeenx nguyeenx` as fast as possible in Zalo's or Messenger's search box
     and in TestHost -> no garbled words.
   - P0-3 fail-open: revoke Accessibility while typing in TextEdit -> keys keep arriving unchanged; re-grant ->
     typing resumes without relaunch.
   - Run `compat/SCRIPT.md` (docs track) on the Tier 1 apps (PRD-R39) that changed since the last build and
     record rows in `compat/matrix.json`.
3. **Pa, once:** spike S1 with `SpikeIMK/README.md`.

The private alpha (0.1) gate "all Tier 1 apps pass the compatibility script" is met by step 2's script runs;
the beta gate needs the runner.

## Coverage of 02, 03 and 04 by workstream

| Area | Workstreams |
|---|---|
| Diagnostics, privacy, capture, report format | W1-A, W1-G (assembly), W2-C |
| Settings, migrations, export/import, macro import, legacy folder move | W1-B, W2-B |
| Compatibility rules, schema, matrix, fingerprinting, lint | W1-C |
| Injection worker, strategies, pasteboard preservation | W1-D |
| Decision pipeline, ordering, conservation, echo, engine bridge | W1-F1, W2-A |
| Tap thread, watchdogs, lifecycle state machine, fail-open orchestration | W1-F2, W2-A |
| Layout tables, input sources, secure input, focus/AX, per-app memory, hotkeys, permissions | W1-E |
| Menu bar and icon states, HUDs, onboarding (8 screens) | W1-G, W2-F |
| Settings (5 panes), macros editor, Apps pane, About & Support with donation block | W2-B |
| Bug report, diagnostics window, latency probe, typing trace, guided test | W2-C |
| Localisation (vi + en, runtime switch, pane names) | W1-G, W2-B/C/D (own tables), W2-F |
| Accessibility (labels, keyboard, contrast, motion) | each UI workstream (rule 8), W2-F audit |
| Sparkle updater | W2-D |
| TestHost, local test pages, CompatHarness, scenarios | W2-E1, W2-E2 |
| Spike S1 | skeleton (done); Pa runs it |
| CI workflows, release scripts, Homebrew, website, project docs | other tracks (see traceability "Workstream") |
