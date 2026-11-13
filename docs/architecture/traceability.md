# Traceability matrix

One row per requirement of `spec/02-platform.md` (PLT-R), `spec/03-product.md` (PRD-R),
`spec/04-quality-release.md` (QA-R) and `spec/05-clean-room.md` (CLR-R): the owning module or file, how it is
verified, and the workstream that implements it ([workstreams.md](workstreams.md)). Engine requirements
(ENG-R) are traced by the engine track. Generated on 2026-11-13 and checked against the spec: 340 rows,
no requirement missing, none duplicated.

## Legend

| Code | Verification |
|---|---|
| U | Unit test (`swift test` in `Packages/AppCore`, hosted CI, no permissions) |
| P | Pipeline property test with fakes (13.1: 100,000 random sequences, hosted CI) |
| I | TestHost integration test through the real pipeline (self-hosted runner with granted permissions, QA-R10-R12) |
| C | Compatibility scenario against a real third-party app (`compat/scenarios`, self-hosted runner or manual matrix row) |
| M | Manual check by Pa on a real Mac |
| V | VERIFY item in the spec: must be confirmed on real hardware and the current OS before relying on it |
| L | CI lint or static check (build settings, greps, schema validation, rules lint) |
| R | Release pipeline check (`scripts/verify-release.sh`, notarization, appcast) |
| D | Document or process review (no code) |
| E | Engine track's own tests (corpus, property, fuzz) |

"Workstream" names the implementing workstream (W1-x, W2-x), "skeleton (done)" for what this design commit
already delivers, or another track (engine, engine data, docs, CI and release, site). Revised 2026-11-13 after the
design review: W1-F is split into W1-F1 (pipeline) and W1-F2 (tap, watchdogs, lifecycle state machine); W1-H
moved to wave 2a as W2-E1; the former W2-E is W2-E2 (wave 2b). A **Pa** mark means the
item can only be finished by Pa by hand on Pa's Mac or with Pa's accounts; nothing automated attempts it (no
synthetic events, taps, permission or input-source changes, credentials).

## Items only Pa can verify on this Mac

| Area | Requirements | What Pa does |
|---|---|---|
| Permissions | PLT-R701, PLT-R702, PLT-R710, PLT-R711, PLT-R712, PLT-R730, PLT-R731, PLT-R740, PRD-R40 | Fresh install from the DMG: move offer, grant Accessibility (and Input Monitoring only if asked), typing within 2 s, revoke while typing (keys must pass untouched), re-grant, "Đặt lại quyền" |
| Live typing in third-party apps | PRD-R1, PLT-R531, PLT-R381, PLT-R386, PRD-R22, PLT-R107 | Run `compat/SCRIPT.md` on Tier 1 apps (PRD-R39) on macOS 26 and 27, record rows in `compat/matrix.json`; Spotlight over Terminal; design apps |
| Secure input in iTerm2 | PLT-R396, PLT-R397, PLT-R398B, PLT-R398C, PLT-R333 | Turn iTerm2 Secure Keyboard Entry on/off and trigger its automatic password-prompt mode: menu names iTerm2 with the right hint; first key after release is composed; sleep/lock/resume |
| Spike S1 | PLT-R398D | Build and install `SpikeIMK`, enable it as an input source, test iTerm2 and Terminal with secure keyboard entry, record the result ADR |
| VERIFY on hardware | PLT-R301, PLT-R320, PLT-R323, PLT-R363, PLT-R385, PLT-R462, PLT-R510, PLT-R704, PRD-R17, PRD-R64, PRD-R68 | Confirm echo delivery, suppression defaults, Unicode string presence, AX behaviour, fingerprints, pane names on a Vietnamese system |
| Notarization and signing | PLT-R750, PLT-R752, QA-R31 | Developer ID certificate, App Store Connect API key, approve the protected `release` environment |
| Update key and channel | PLT-R1101, PLT-R1102, PLT-R1103, PLT-R1105, PLT-R1107, PLT-R1108, PRD-R50, PRD-R52, QA-R32, QA-R33, QA-R38, QA-R39, QA-R40 | Generate the EdDSA key pair (fill `SPARKLE_PUBLIC_ED_KEY`), keep backups, publish from Pa's Mac, rehearse rollback, run the upgrade test |
| VoiceOver and accessibility | PLT-R211, PRD-R10, PRD-R12, PRD-R66, PRD-R67, PRD-R68 | VoiceOver labels and announcements, Increase Contrast, Reduce Motion, keyboard-only Settings and onboarding |
| Diagnostics run by hand | PLT-R810, PLT-R905, PLT-R1201, PLT-R1204, PLT-R1205 | Latency probe, typing trace with HUD and review, guided test on a local inline-completion page |
| Accounts and data | PRD-R59, QA-R12, QA-R23, QA-R25, PLT-R205, PRD-R9 | Donation account details and QR images; self-hosted runner; branch protection; login item and icon behaviour on Pa's menu bar |
| Provenance | CLR-R13 | Similarity review by someone allowed to read the other code bases |
| Artwork | CLR-R7, PRD-R9, PRD-R10, PRD-R40, PRD-R59 | Approve or replace the placeholder status-icon glyphs (drawn in code, `App/Sources/Shell/StatusGlyph.swift`), the app icon (the asset catalog is empty), onboarding illustrations (placeholders marked VERIFY) and the donation QR images; record each asset's source |
| Brand data | PRD-R47, PRD-R49, QA-R51, QA-R60, PLT-R903 | Fill `APP_SUPPORT_EMAIL` and `APP_REPOSITORY_URL` in `Config/Brand.xcconfig` (empty hides the email and GitHub buttons); choose the final name before the first public release (the rename appends the old folder to `APP_LEGACY_STORAGE_FOLDER_NAMES`, ADR 0307) |
| Interim verification | every row listed under "Interim verification" below | Until the self-hosted runner exists: the 20-minute checklist in workstreams.md before each alpha build |



## Interim verification (until the self-hosted runner exists)

The rows below are verified by I (TestHost integration) or C (compatibility scenario), which need the
self-hosted runner (open question 3/5 for Pa). Until it exists their verification is **M (interim)**: Pa runs
the checklist in [workstreams.md](workstreams.md#interim-verification-before-the-self-hosted-runner-exists)
before each alpha build, and hosted CI runs `compat-harness --dry-run` over every scenario. When the runner is
online, W2-E2 turns them back into I/C and this section is deleted.

PLT-R201, PLT-R203, PLT-R204, PLT-R301, PLT-R303, PLT-R304, PLT-R305, PLT-R306, PLT-R320, PLT-R322, PLT-R323, PLT-R324, PLT-R330, PLT-R341, PLT-R353, PLT-R361, PLT-R371, PLT-R381, PLT-R386, PLT-R387, PLT-R398B, PLT-R410, PLT-R420, PLT-R421, PLT-R422, PLT-R530, PLT-R730, PLT-R802, PLT-R803, PLT-R821, PLT-R906, PLT-R1008, PLT-R1108, PRD-R13, PRD-R19, PRD-R22, PRD-R27, PRD-R30, PRD-R44, PRD-R52, QA-R10, QA-R11, QA-R12, QA-R16, QA-R21, QA-R40, QA-R42

## 02-platform.md (PLT-R)

| ID | Requirement (short) | Owner module / file | Verification | Workstream | Pa |
|---|---|---|---|---|---|
| PLT-R101 | Swift 6 strict concurrency, pinned toolchain | `Packages/AppCore/Package.swift`, `project.yml` | L | all (integrator); CI track pins Xcode |  |
| PLT-R102 | SwiftPM targets and responsibilities | `Packages/AppCore/Package.swift`, ADR 0302 | D | skeleton (done) |  |
| PLT-R103 | Engine package permissive, no AppKit/CG/Carbon | `Packages/VietnameseEngine` | L | engine track |  |
| PLT-R104 | Sparkle only runtime dependency, exact pin, resolved file committed | `project.yml`, `Config/Package.resolved`; unit evidence: UpdaterTests `BuiltBundleTests` (run by `ci.yml` macos-app) | L, U | skeleton (done); W2-D |  |
| PLT-R105 | Universal binary | `Config/Release.xcconfig` | R | skeleton (done); release track (`lipo` check) |  |
| PLT-R106 | macOS 15 minimum, no API newer than 14 outside Synchronization | `Package.swift`, `project.yml` | L | all; CI track (availability lint) |  |
| PLT-R107 | Test matrix macOS 15, 26, 27 plus next beta | self-hosted runner, `compat/matrix.json` | M, V | W2-E2; Pa | **Pa** |
| PLT-R108 | Licence note for rules/injection reuse | `docs/decisions/` (Pa) | D | Pa decision |  |
| PLT-R201 | One process, no daemons, extensions or IMKit bundle | `App` target | I, R | W2-A; release track (bundle check) |  |
| PLT-R202 | Logical components | ARCHITECTURE.md section 2 | D | skeleton (done) |  |
| PLT-R203 | Thread map | `InputHost/Tap`, `Injection/Worker`, `InputHost/Focus`, `RealtimeSupport/Threads` | U, I | W1-F2, W1-D, W1-E |  |
| PLT-R204 | Nothing outlives the process | `InputHost/Tap` | I (kill -9 on runner) | W2-E2 |  |
| PLT-R205 | Launch at login via SMAppService.mainApp | `ShellCore/Services.swift` `SMAppServiceLoginItem` | U, M | W1-G; W2-A (onboarding checkbox wiring); Pa | **Pa** |
| PLT-R206 | No IMKit bundle in v1, honest fallback copy | `project.yml` (SpikeIMK not embedded), `Status` table | R, D | skeleton; W1-G |  |
| PLT-R207 | Constraints for a future IMKit bundle | `SpikeIMK/**` | D | skeleton (done, `SpikeIMK` never taps or posts) |  |
| PLT-R208 | Single-transformer invariant | `InputHost/Pipeline` (built-in Vietnamese source pause) | P | W1-F2 |  |
| PLT-R210 | Composition reset on pause/fail-open/focus transitions | `InputHost/Pipeline/KeyPipeline.swift` | P | W1-F1, W1-F2 |  |
| PLT-R211 | Menu and icon reflect state and pause reason | `ShellCore/StatusPresentation.swift`, `App/Sources/Shell` | U, M | W1-G; W2-F; Pa (VoiceOver) | **Pa** |
| PLT-R301 | Session-level head-insert default tap, event mask | `InputHost/Tap/TapThread.swift`, `TapEventMask.standard` (scroll on), ADR 0313 | U, I, V | W1-F2; VERIFY (a) echo delivery (b) coexistence on hardware | **Pa** |
| PLT-R302 | No second or listen-only tap | `InputHost/Tap` | L, U | W1-F2 |  |
| PLT-R303 | Dedicated tap thread with only the tap source | `TapThread` | I (instrumented) | W1-F2 |  |
| PLT-R304 | Allowed operations in the callback | `InputHost/Pipeline` | U, I (instrumented 30 min) | W1-F1 |  |
| PLT-R305 | Forbidden operations in the callback | `InputHost/Pipeline`, `RealtimeSupport` | I (debug assertion layer), L | W1-F1 |  |
| PLT-R306 | Callback watchdog 250 ms, fail-open, retry 2 s | `TapWatchdog`, `CallbackWatchdog`, ADR 0309 (recovery only after the callback returned); soak counter `InputHostController.recordHealth(.watchdogTrip)` increments `watchdogTrips`; echoes lost around the re-enable are forgiven (`EchoTracker.forgiveLostEchoes`, ADR 0311) | U (`watchdogTripDisablesAndTheReturnedCallbackReenables_PLT_R306`, `jobsPostedAroundAWatchdogTripDoNotBreakPosting_PLT_R306`), I (test hook) | W1-F2 |  |
| PLT-R307 | Engine contract | `InputHost/Engine/EngineBridge.swift`, ADR 0306 | U, E | W1-F1; W2-A (catalog from bundled resources); engine track |  |
| PLT-R310 | Decision pipeline steps 1-10 | `KeyPipeline` | P, U | W1-F1 |  |
| PLT-R311 | FIFO worker, hold/replay while in flight | `KeyPipeline`, `Injection/Queue.swift`, `Worker.swift`, ADR 0311 | P | W1-F1, W1-D; W2-A (combined suite) |  |
| PLT-R312 | Event conservation invariant | `KeyPipeline`, `TestSupport/Pipeline` ledger, ADR 0308, ADR 0308, ADR 0311 | P (100,000 sequences) | W1-F1; W2-A (combined suite with the real worker) |  |
| PLT-R313 | Consumed keyDown implies consumed keyUp | `KeyPipeline`, `WorkerFeedback` | P | W1-F1, W1-D |  |
| PLT-R314 | Liveness ceiling 150 ms / 256 jobs, flush | `InjectionWorker` | P, U | W1-D; W2-A |  |
| PLT-R315 | Worker never waits on main or tap | `InjectionWorker` | U, review | W1-D |  |
| PLT-R316 | Focus-generation discard | `InjectionWorker`, `CurrentFocusGeneration` | P | W1-D; W2-A |  |
| PLT-R317 | Clicks during a paced job are not held | `KeyPipeline` | P | W1-F1 |  |
| PLT-R320 | privateState source, explicit flags, suppression 0 | `CGEventPoster` | I, V (default suppression on 15/26/27) | W1-D; W2-E2 | **Pa** |
| PLT-R321 | Marker tag + sequence; physical events untouched | `EventMarker`, `KeyPipeline` | U, P | W1-D, W1-F1 |  |
| PLT-R322 | Post at kCGSessionEventTap | `CGEventPoster` | I | W1-D |  |
| PLT-R323 | Echo liveness, posting broken after 3 misses | `EchoTracker`, `KeyPipeline`, ADR 0311 | U, I, V | W1-D (skeleton seam), W1-F1; VERIFY echo delivery (else `InFlightPolicy.untilPosted`) | **Pa** |
| PLT-R324 | Replays copy keycode, flags, autorepeat, keyboard type, Unicode | `KeyEventRecord`, `CGEventPoster.replay` | U, I | W1-D |  |
| PLT-R330 | Tap disabled by system: re-enable, reset, replay, notice | `KeyPipeline`, `InputHostController`; hook `tapTimeout` (`InputHost/IntegrationHooks/IntegrationHookInstruments.swift`), `compat/scenarios/testhost.tapTimeout.recovery.json` | P, U (`HostHookActionsTests`), I (test hook) | W1-F2; W3-A |  |
| PLT-R331 | Tap-enabled watchdog every 5 s and on events | `TapWatchdog` | U | W1-F2 |  |
| PLT-R332 | Tap creation failure: failOpen + backoff | `InputHostController` | U | W1-F2 |  |
| PLT-R333 | Session inactive, sleep, lock: pause and revalidate | `InputHostController`, `WorkspaceEvents` | U, M | W1-F2, W1-E; Pa | **Pa** |
| PLT-R340 | Hard boundaries list | `KeyPipeline` | P, U | W1-F1 |  |
| PLT-R341 | Soft boundaries keep re-entry history | engine + `KeyPipeline` | E, I | engine track; W1-F1; W2-E2 |  |
| PLT-R342 | Re-entry verification with bounded AX read | `InjectionWorker` (`verifyBeforeApply`) | U | W1-D |  |
| PLT-R343 | Bounded AX reads (64 characters) | `AXFocusedFieldAccess`, `SystemAXProvider` | U, L | W1-D, W1-E |  |
| PLT-R350 | Shift/Caps via table; Command/Control/Option chords | `KeyClassifier` | U | W1-F1 |  |
| PLT-R351 | Autorepeat handling | `KeyPipeline` | U, P | W1-F1 |  |
| PLT-R352 | User backspace reported to engine | `KeyPipeline` | P | W1-F1 |  |
| PLT-R353 | Restore hotkey semantics, per-app disable | `HotkeyRecognizer`, `KeyPipeline` | U, I | W1-E, W1-F1; W2-E2 |  |
| PLT-R354 | Dead keys pass and reset | `UCKeyTranslateLayoutBuilder`, `KeyClassifier` | U | W1-E, W1-F1 |  |
| PLT-R355 | Keypad digits are not VNI tone keys | `KeyClassifier` (`fromKeypad`), engine | U, E | W1-F1; engine track |  |
| PLT-R356 | Navigation keys never edit | `KeyPipeline` | P | W1-F1 |  |
| PLT-R360 | UCKeyTranslate tables per layout, 4 states | `InputSource/InputSources.swift`, `LayoutTable` | U (system layouts read by ID) | W1-E |  |
| PLT-R361 | Layout-produced letters (QWERTZ, AZERTY, Dvorak) | `LayoutTable`, `KeyPipeline` | U, I | W1-E, W1-F1; W2-E2 |  |
| PLT-R362 | Layout ID in diagnostics | `ReportAssembler` | U | W1-G |  |
| PLT-R363 | Debug cross-check with event Unicode string | `KeyPipeline` (debug), `TapLogCode.layoutMismatch` | U, V | W1-F1 | **Pa** |
| PLT-R370 | Observe TIS selection change, publish snapshot | `InputSourceMonitor` | U | W1-E |  |
| PLT-R371 | Pause for input methods and non-ASCII layouts | `InputSourceMonitor`, `HostStateResolver` | U, I (Japanese source on runner) | W1-E, W1-F1; W2-E2 |  |
| PLT-R372 | Pause for a built-in Vietnamese source | `InputSourceMonitor` | U, M | W1-E; Pa | **Pa** |
| PLT-R373 | Optional layout-to-mode binding | `InputSourceMonitor`, `LayoutModeBinding`, `HostStateResolution.effectiveMode` (a bound layout decides the mode; the toggle hotkey does nothing on a bound layout) | U (pipeline tests, HostRig `layoutBindingDecidesTheMode_PLT_R373`), M | W1-E; W2-B (UI) |  |
| PLT-R380 | AX thread observers on focused and overlay apps | `FocusTracker` | U (fake AX) | W1-E |  |
| PLT-R381 | System-wide AX focus is authoritative | `FocusTracker` | U, C (Spotlight, Raycast) | W1-E; Pa | **Pa** |
| PLT-R382 | Idle revalidation flag | `KeyPipeline`, `FocusTracker` | U | W1-F1, W1-E |  |
| PLT-R383 | Focus snapshot contents | `InputHost/Snapshots/Snapshots.swift` | U | W1-E |  |
| PLT-R384 | AX 100 ms timeout and circuit breaker | `AXCircuitBreaker`, `SystemAXProvider` | U | W1-E |  |
| PLT-R385 | Never AXEnhancedUserInterface; AXManualAccessibility only by rule | `SystemAXProvider` | L, U, V | W1-E | **Pa** |
| PLT-R386 | requireTextFocus gating | `HostDecisionMapper`, `HostStateResolver` | U, C (design apps) | W1-E, W1-F1; Pa | **Pa** |
| PLT-R387 | Secure fields always pass through | `FocusTracker`, `HostStateResolver` | U, I (password field) | W1-E, W1-F1; W2-E2 |  |
| PLT-R388 | Snapshot via one atomic reference | `RealtimeSupport/SnapshotCell.swift`, ADR 0303 | U, TSan | skeleton (done); W1-A |  |
| PLT-R390 | Per-app memory keyed by focus owner, precedence | `AppModeMemory` | U | W1-E |  |
| PLT-R391 | Mode in effect before the next key | `FocusTracker`, `KeyPipeline` toggle sequence | P | W1-E, W1-F1 |  |
| PLT-R392 | LRU 1,000, writes debounced 5 s, bundle and mode only | `AppModeMemory`, `SettingsStore.recordAppModes` | U | W1-E, W1-B |  |
| PLT-R393 | SHA-256 of executable path for bundle-less processes | `ProcessIdentityProvider`, `BundleKey.executable` | U | W1-E |  |
| PLT-R395 | Poll IsSecureEventInputEnabled every 2 s and on menu open | `SecureInputMonitor` | U | W1-E |  |
| PLT-R396 | Likely holder from IOConsoleUsers kCGSSessionSecureInputPID | `SystemSecureInputProbe` | U (parser), M | W1-E; Pa (iTerm2, browser) | **Pa** |
| PLT-R397 | Paused(secureInput) with holder hint, no modals | `SecureInputMonitor`, `Status` table | U, M | W1-E, W1-G; Pa | **Pa** |
| PLT-R398 | Never call EnableSecureEventInput | all | L (grep) | W1-E |  |
| PLT-R398A | P0-1: only OS state and AXSecureTextField pause | `HostStateResolver` | U, L | W1-F1, W1-E |  |
| PLT-R398B | P0-1: resume on the first key after release | `KeyPipeline`, `HostCounters` (reported as `firstKeyAfterSecureInputReleaseComposed`), `compat/scenarios/testhost.secureInput.release.json` | P, U (`FirstKeyAfterSecureReleaseTests`), I, C | W1-F1; W2-E2; W3-A; Pa (iTerm2) | **Pa** |
| PLT-R398C | P0-1: terminal hints incl. iTerm2 automatic secure entry | `compat/rules.json` `secureInputHints`, `Status` table | U, M, V | W1-C, W1-G; Pa | **Pa** |
| PLT-R398D | P0-1: spike S1, IMKit under secure keyboard entry | `SpikeIMK/**` | M | skeleton (done, runnable spike); Pa runs it | **Pa** |
| PLT-R399 | Warn about conflicting input software | `ConflictDetector`, rules `conflictingInputApps`, source registry `compat/conflicting-apps.json` | U | W1-E; W1-G (onboarding screen 5); W2-A (wiring) |  |
| PLT-R401 | EditJob contents | `Injection/Jobs.swift` | U | W1-D |  |
| PLT-R402 | Minimal edits (common prefix trim) | `EditMinimizer` | U | W1-D |  |
| PLT-R403 | NFC insertions, grapheme delete counts | `InjectionWorker` | U | W1-D |  |
| PLT-R404 | One grapheme per event; chunk up to 20 units | `UnicodeChunker` | U | W1-D |  |
| PLT-R405 | Unicode events use the triggering keycode | `JobKeyCodes`, `KeyPipeline`, strategies | U | W1-F1, W1-D |  |
| PLT-R406 | No modifier flags except where required | strategies | U | W1-D |  |
| PLT-R407 | Backspace key; forward delete banned | strategies, `RulesLinter` | U, L | W1-D, W1-C |  |
| PLT-R408 | Timing parameters, caps, split | strategies, `ResolvedParams` | U | W1-D, W1-C |  |
| PLT-R409 | Pacing on inject thread with absolute deadlines | `InjectionWorker`, `MachClock.sleep` | U | W1-D |  |
| PLT-R410 | Verification modes echo/axReadback/human | `InjectionWorker` | U, I | W1-D; W2-C (human) |  |
| PLT-R420 | Inline completion: axSelection | strategies | U, C | W1-D; W2-E2 |  |
| PLT-R421 | Inline completion: placeholder | strategies | U, C | W1-D; W2-E2 |  |
| PLT-R422 | Placeholder gate: 1,000-edit test, no broad rules | `RulesLinter`, compat scenario | L, C | W1-C; W2-E2 |  |
| PLT-R460 | paste only opt-in or long text | strategies, rules `requiresUserOptIn` | U | W1-D, W1-C |  |
| PLT-R461 | Full clipboard preservation | `PasteboardPreserver`, `NSPasteboardAccess` | U (unique pasteboard) | W1-D |  |
| PLT-R462 | Paste failure modes in UI; NSPasteboard threading VERIFY | `NSPasteboardAccess`, Apps pane copy | V, D | W1-D, W2-B | **Pa** |
| PLT-R480 | Long text and macro limits | `InjectionWorker`, `WorkerConfiguration` | U | W1-D |  |
| PLT-R501 | No per-app branches; bundle-ID literal lint | all code; `ReverseDNSConstants.swift` allowlist | L | W1-C; CI track (`scripts/lint.sh`) |  |
| PLT-R502 | No localized-string matching; titlePattern limits | `RulesLoader`, `RuleSet` | U | W1-C |  |
| PLT-R503 | Schema-validated rules, embedded fallback | `RulesLoader`, `EmbeddedRules`, `compat/schema/rules.schema.json` | U, L | W1-C |  |
| PLT-R504 | No remote rule fetching | `RulesLoader` | L (egress test) | W1-C; W2-E2 |  |
| PLT-R505 | Provenance and test reference per shipped rule | `RulesLinter` | L | W1-C |  |
| PLT-R506 | reviewBy within 12 months; release block after 30 days | `RulesLinter` | L | W1-C |  |
| PLT-R510 | Engine fingerprinting | `EngineFingerprinter`, bundle inspector | U, V | W1-C, W1-E | **Pa** |
| PLT-R520 | Specificity scoring | `RuleSet.resolve` | U | W1-C |  |
| PLT-R521 | Identical signatures fail CI; runtime tie | `RulesLinter`, `RuleSet` | U, L | W1-C |  |
| PLT-R522 | User overrides outrank shipped rules | `RuleSet` | U | W1-C |  |
| PLT-R523 | Resolution on ax thread on focus change only | `FocusTracker` | U | W1-E |  |
| PLT-R530 | Scenario file format | `TestSupport/Scenario`, `compat/schema/scenario.schema.json`, `compat/scenarios/` | U, C | W2-E1 |  |
| PLT-R531 | Manual scenarios need fresh matrix rows | `RulesLinter`, `compat/matrix.json` | L, M | W1-C; Pa | **Pa** |
| PLT-R540 | Override mechanism and scopes | `CompatibilityModeChoice`, `GuidedTestRunner`, rule import | U | W1-G, W2-B, W2-C |  |
| PLT-R541 | rule-overrides.json listed, exported, in reports | `SettingsStore`, `ReportAssembler`, `ReportedOverride`, ADR 0312 | U | W1-B, W1-G |  |
| PLT-R701 | Accessibility required; macOS 27 label VERIFY | `PermissionProbe`, `SystemPanes.json` | U, M, V | W1-E, W1-G; Pa | **Pa** |
| PLT-R702 | Input Monitoring only if the OS demands it | `PermissionMonitor` | U, V | W1-E; Pa | **Pa** |
| PLT-R703 | No other permissions | `App/Info.plist`, no entitlements | R, L | skeleton; release track |  |
| PLT-R704 | Pane names and deep links from an OS table | `SystemPaneTable`, `App/Resources/SystemPanes.json` | U, V | W1-G; Pa | **Pa** |
| PLT-R710 | Run from Applications, not translocated; move offer | `AppLocationCheck`, `AppEnvironment` | U, M (launch from DMG) | W1-G, W2-A; Pa | **Pa** |
| PLT-R711 | Onboarding permission flow with 1 s polling | `OnboardingFlow`, `PermissionMonitor` | U, M | W1-G, W1-E; Pa | **Pa** |
| PLT-R712 | Relaunch offer for Input Monitoring | `OnboardingWindowController` | M | W1-G; Pa | **Pa** |
| PLT-R720 | Permission states and stale detection | `PermissionMonitor` | U | W1-E |  |
| PLT-R721 | Polling cadence 2 s / 30 s / on events | `PermissionMonitor` | U | W1-E |  |
| PLT-R730 | Fail-open within the same callback | `KeyPipeline`, `InputHostController`, `InjectionWorker`; hook `revokePermission` (`RevocablePermissionProbe`), `compat/scenarios/testhost.failOpen.permissionRevoked.json` | P, U (`HostHookActionsTests`), I (revocation on runner), M | W1-F1, W1-F2; W2-E2; W3-A; Pa | **Pa** |
| PLT-R731 | Recreate tap when permission returns | `InputHostController` | U, M | W1-F2; Pa | **Pa** |
| PLT-R740 | Re-grant guidance, tccutil reset for own bundle | `PermissionResetting`, `Status` table | U, M | W1-E, W1-G; Pa | **Pa** |
| PLT-R741 | Never suggest sudo or bundle-less tccutil | `Status`/`Onboarding` copy | D | W1-G |  |
| PLT-R750 | Developer ID signing, hardened runtime, notarized | `Config/Signing.xcconfig`, `Config/Release.xcconfig`, release scripts | R, M | release track; Pa (credentials) | **Pa** |
| PLT-R751 | Dev builds use .dev bundle ID and Apple Development | `Config/Debug.xcconfig` | L | skeleton (done) |  |
| PLT-R752 | Updates in place keep identity and trust | Sparkle, release scripts | R, M (13.5) | W2-D; release track; Pa | **Pa** |
| PLT-R760 | MDM / PPPC documentation | `docs/support/managed-macs.md` | D, V | docs track (done; macOS 27 DDM note VERIFY) |  |
| PLT-R801 | Lock-free histograms | `Diagnostics/Metrics.swift` (log2 buckets plus gate-aligned sub-buckets for T2 and T3, `PlatformMetrics.reset()`); echo round trip recorded by `EchoTracker(roundTrip:)` into `metrics.echoRoundTrip` | U (`MetricsPrecisionTests`, `HotPathAllocationTests`, `echoedJobsRecordTheRoundTrip`) | W1-A; W3-A |  |
| PLT-R802 | Signposts around callback, job, AX | `PlatformSignposts`, emitted by `KeyPipeline.handle` (tap callback), `WorkerCore.process` (injection job), `InstrumentedFieldAccess` (worker AX calls) and `FocusCore.timed` (focus AX calls) | U (HostRig `signpostsReachTheTapCallback_PLT_R802`), I, M (Instruments) | W1-A |  |
| PLT-R803 | No steady-state timer faster than 2 s | `TapWatchdog`, monitors, ADR 0309 | U, I (wakeups) | W1-F2, W1-E |  |
| PLT-R810 | Built-in latency probe | `LatencyProbeDriver`, `DiagnosticsWindowController` | U, M | W2-C; Pa runs it | **Pa** |
| PLT-R820 | Hosted CI microbenchmarks with fakes | pipeline benchmark in `Tests/InputHostTests/Pipeline` | L | W1-F1; CI track |  |
| PLT-R821 | Self-hosted metrics T2-T6, C1, C2, M1, M2 | `compat-harness` (`TestSupport/Scenario/AppMetrics.swift`, `PlatformBenchmark.swift`, `Soak.swift`), the app's hooks (`InputHost/IntegrationHooks/`, `App/Sources/IntegrationHooks/`), `perf/platform-baseline.json`, [integration-suite.md](../runbooks/integration-suite.md) sections 3 and 4, ADR 0502 | U (`AppMetricsTests`, `IntegrationHookServerTests`), I | W2-E2; W3-A |  |
| PLT-R822 | Regression gate and baselines | `perf/platform-baseline.json`, `perf/README.md`, `RegressionGate`, `scripts/bench-compare.sh` from `scripts/run-integration.sh bench` and `soak`, [integration-suite.md](../runbooks/integration-suite.md) section 7 | L, U (`RegressionGateTests`, scripts/tests) | CI track; W2-E2; W3-A |  |
| PLT-R901 | Data classes; content never in logs | Diagnostics, all modules; canary: `TestSupport/Scenario/PrivacyCanary.swift`, `compat/scenarios/testhost.privacyCanary.*`, `compat/scenarios/profiles/privacy-canary.json`, [integration-suite.md](../runbooks/integration-suite.md) section 4; hook responses carry codes only (`AppStateSnapshotMappingTests`) | L (canary), U, I | W1-A; W2-E2; W3-A |  |
| PLT-R902 | Typed logging API; interpolation lint | `Diagnostics/LogEvent.swift`, `Redaction.swift` | U, L | W1-A; CI track (lint) |  |
| PLT-R903 | Log location, permissions, rotation, retention | `DiagnosticsLogger`, `LogStorePolicy` | U | W1-A; W1-B (legacy folder move, ADR 0307) |  |
| PLT-R904 | No verbose/debug content mode | Diagnostics | D, L | W1-A |  |
| PLT-R905 | Time-boxed capture with HUD, 24 h deletion | `CaptureController`, `CaptureHUDController`; key and engine records from `KeyPipeline+Capture.swift`, focus records from `FocusCore.recordFocusCapture` | U (`KeyPipelineCaptureTests`, HostRig `typingTraceRecordsKeysEngineDecisionsAndFocus_PLT_R905`), M | W1-A, W2-C; Pa | **Pa** |
| PLT-R906 | Egress limited to Sparkle | `App` (URL host allowlist), Sparkle; egress test: `TestSupport/Scenario/EgressCheck.swift` (`compat-harness egress`), hook `checkForUpdates`, [integration-suite.md](../runbooks/integration-suite.md) section 5 | L, I (13.7) | W2-D, W2-E2, W3-A; CI track |  |
| PLT-R907 | No translation feature in v1 | n/a | D | n/a |  |
| PLT-R908 | Hardened runtime, no entitlements, not sandboxed | `project.yml`, `Config/Release.xcconfig` | R | skeleton; release track |  |
| PLT-R909 | No unauthenticated IPC; URL scheme opens Settings only | `URLSchemeRouter`, `AppEnvironment.handle(url:)`; the test build's hooks are owner-only files watched with a vnode source, no socket (`IntegrationHookServer`, ADR 0502), absent from releases (`scripts/verify-release.sh`) | U, R | W1-G, W2-A; W3-A |  |
| PLT-R910 | Supply chain: resolved file, pins, SHA-256 | `Config/Package.resolved`, workflows | L | skeleton; CI track |  |
| PLT-R911 | No retained engine state or raw keys | `KeyPipeline` | U, review | W1-F1 |  |
| PLT-R912 | Settings import treated as untrusted | `SettingsStore.previewImport` | U (malformed and fuzzed files) | W1-B |  |
| PLT-R913 | Reports include only the reported app memory | `ReportAssembler` | U | W1-G |  |
| PLT-R1001 | Settings location and four files | `SettingsStore`, `StorageLocation`, `Brand` | U | W1-B |  |
| PLT-R1002 | schemaVersion, writtenBy, unknown keys preserved | `DocumentEnvelope` | U | W1-B |  |
| PLT-R1003 | Atomic, debounced, serialized writes | `SettingsStore`, `LocalFileSystem` | U | W1-B |  |
| PLT-R1004 | Only explicit choices persisted | `Setting`, `UserSettings` | U | W1-B |  |
| PLT-R1005 | Pure chained migrations with backups and fixtures | `MigrationChain` | U (fixtures) | W1-B |  |
| PLT-R1006 | Never wipe: quarantine, backup, notice | `SettingsStore` | U | W1-B |  |
| PLT-R1007 | Newer schema read-only | `SettingsStore` | U | W1-B |  |
| PLT-R1008 | Live application via snapshots | `InputHostController.apply` | U, I | W1-F1, W2-A |  |
| PLT-R1009 | Crash-loop safe mode | `LaunchGuard`, `AppEnvironment` | U | W1-B, W2-A |  |
| PLT-R1010 | Export and import | `SettingsStore` export/import, Settings UI | U, M | W1-B, W2-B |  |
| PLT-R1011 | iCloud sync later, opt-in | n/a in v1 | D | n/a |  |
| PLT-R1012 | Storage paths for zap and uninstall page | ADR 0307, cask | D | release track; docs track |  |
| PLT-R1101 | Sparkle feed and beta channel | `UpdaterController`, `App/Info.plist`; unit evidence: UpdaterTests `UpdatePolicyTests` and `BuiltBundleTests` (run by `ci.yml` macos-app) | U, M | W2-D; Pa | **Pa** |
| PLT-R1102 | EdDSA mandatory, HTTPS, verify before extraction | `App/Info.plist`, `Config/Sparkle.xcconfig`; unit evidence: UpdaterTests `BuiltBundleTests` (run by `ci.yml` macos-app) | U, R, V | W2-D; release track | **Pa** |
| PLT-R1103 | EdDSA key custody on Pa's Mac | `scripts/publish-release` | M | release track; Pa | **Pa** |
| PLT-R1104 | Semver short version, integer build | `project.yml`, release scripts | L, R | release track |  |
| PLT-R1105 | Daily check, background download, install on quit, idle relaunch | `UpdaterController`, `RelaunchGate`; unit evidence: UpdaterTests `RelaunchGateTests`, `UpdatePolicyTests` (run by `ci.yml` macos-app) | U, M | W2-D; Pa | **Pa** |
| PLT-R1106 | Phased rollout, critical flag only for security | appcast scripts | R | release track |  |
| PLT-R1107 | Rollback procedure | runbooks | M (drill) | docs/release tracks; Pa | **Pa** |
| PLT-R1108 | Update tests before publication | self-hosted runner (13.5) | I, M | W2-E2; Pa | **Pa** |
| PLT-R1109 | minimumSystemVersion and minimumAutoupdateVersion | appcast scripts | R | release track |  |
| PLT-R1110 | Homebrew cask auto_updates, depends_on, zap | `packaging/homebrew` | R | release track |  |
| PLT-R1201 | Diagnostics window contents and buttons | `DiagnosticsWindowController` | U (view model), M | W2-C; Pa | **Pa** |
| PLT-R1202 | Environment report contents | `DiagnosticsReport`, `ReportAssembler` | U | W1-A, W1-G |  |
| PLT-R1203 | Report exclusions (no content) | `DiagnosticsReport` type | U (canary) | W1-A; W1-G (`reportedOverride` projection, ADR 0312) |  |
| PLT-R1204 | User sees exact report before copying | `BugReportController` | M | W2-C; Pa | **Pa** |
| PLT-R1205 | "This app misbehaves" guided flow | `GuidedTestRunner`, diagnostics UI | U, M | W2-C; Pa | **Pa** |
| PLT-R1206 | Metadata-only health events | `HealthEventLog` | U | W1-A |  |
| PLT-R1207 | Support guidance | `docs/support` | D | docs track |  |

## 03-product.md (PRD-R)

| ID | Requirement (short) | Owner module / file | Verification | Workstream | Pa |
|---|---|---|---|---|---|
| PRD-R0 | Any failing P0 test blocks every release | release gate; P0 tests in pipeline suite and engine corpus | R, P, E | CI/release tracks; W1-F1; engine track |  |
| PRD-R1 | Tier 1 top jobs checked every release | `compat/matrix.json`, `compat/SCRIPT.md` | M | Pa; W2-E2 | **Pa** |
| PRD-R2 | v1.0 scope | whole product | D | all |  |
| PRD-R3 | v1.0 non-goals | whole product | D | all |  |
| PRD-R4 | Stage transitions recorded as decisions | `docs/decisions/` | D | Pa |  |
| PRD-R5 | Ship exactly the listed defaults | `DefaultSettings.v1` | U | W1-B |  |
| PRD-R6 | Unset follows defaults; set preserved forever | `Setting`, `UserSettings` | U | W1-B |  |
| PRD-R7 | "Not a setting" items absent from UI | Settings UI | U (view model), M | W2-B |  |
| PRD-R8 | Minimum macOS 15 | `Package.swift`, `project.yml` | L | skeleton (done) |  |
| PRD-R9 | Monochrome template icon always visible | `StatusItemController`, assets | M | W1-G; Pa | **Pa** |
| PRD-R10 | Icon states with VoiceOver labels | `StatusPresentation`, `Menu` table, assets | U, M (VoiceOver) | W1-G; W2-F; Pa | **Pa** |
| PRD-R11 | Menu layout | `MenuModel`, `StatusItemController` | U, M | W1-G |  |
| PRD-R12 | Switch HUD 600 ms, non-activating, Reduce Motion | `SwitchHUDController` | U, M | W1-G; W2-F; Pa | **Pa** |
| PRD-R13 | Menu opens within 100 ms and never blocks typing | `StatusItemController` | I, M | W1-G; W2-E2 |  |
| PRD-R14 | Toggle tap recogniser rules | `HotkeyRecognizer` | U | W1-E |  |
| PRD-R15 | Recorder accepts listed chords in any press order | `HotkeyRecorder` | U | W1-E; W2-B (UI) |  |
| PRD-R16 | Warn about macOS shortcuts, never refuse | `HotkeyRecorder.conflict`, Settings UI | U | W1-E, W2-B |  |
| PRD-R17 | Globe/fn toggle only if reliable (VERIFY) | `HotkeyRecognizer` (deferred) | V | W1-E (deferred) | **Pa** |
| PRD-R18 | Only two configurable hotkeys | `UserSettings`, `HotkeyRole` | U | W1-B, W1-E |  |
| PRD-R19 | Remembered mode applies to the first key after activation | `FocusTracker`, `KeyPipeline` | P, I | W1-E, W1-F1; W2-E2 |  |
| PRD-R20 | Manual toggle updates memory | `AppModeMemory.recordToggle` | U | W1-E |  |
| PRD-R21 | Rule precedence ignore > EN > VI > memory > default | `AppModeMemory.resolve` | U | W1-E |  |
| PRD-R22 | Keyed by bundle; overlays have their own memory | `FocusTracker` | U, C (Spotlight over Terminal) | W1-E; Pa | **Pa** |
| PRD-R23 | Memory survives restarts/updates, exported | `SettingsStore` | U | W1-B |  |
| PRD-R24 | At most five panes, Advanced disclosure | Settings UI | M | W2-B |  |
| PRD-R25 | One-line explanation per setting | `Settings` table | M, D | W2-B |  |
| PRD-R26 | Reset per pane and global with confirmation and export offer | `SettingsStore.reset`, Settings UI | U, M | W1-B, W2-B |  |
| PRD-R27 | Changes apply immediately without losing the word | `InputHostController.apply` | U, I | W1-F1, W2-A |  |
| PRD-R28 | Settings is a normal window, frame remembered | `SettingsWindowController` | M | W2-B |  |
| PRD-R29 | Macro shortcut and expansion rules | `MacroValidator`, engine `MacroTable` | U, E | W1-B; engine track |  |
| PRD-R30 | Expansion triggers and case adaptation | engine (ENG-R1103), host macros feature | E, I | engine track; W2-E2 |  |
| PRD-R31 | Macro list features | Macros pane | M | W2-B |  |
| PRD-R32 | Macro import formats with preview | `MacroImporter`, import sheet | U, M | W1-B, W2-B |  |
| PRD-R33 | Macros never sent; count only in diagnostics | `DiagnosticsReport.SettingsSection.macroCount` | U | W1-A, W1-G |  |
| PRD-R34 | Apps pane rows | `AppsPaneModel`, Apps pane | U, M | W1-G, W2-B |  |
| PRD-R35 | Compatibility status from matrix | `MatrixStatusResolver` | U | W1-C, W1-G |  |
| PRD-R36 | At most three compatibility choices under Advanced | `CompatibilityModeChoice` | U, M | W1-G, W2-B |  |
| PRD-R37 | Report button per app row | Apps pane | M | W2-B |  |
| PRD-R38 | Both compatibility files ship in the app | `project.yml` copy phase | R | skeleton (done); W1-C |  |
| PRD-R39 | Tier lists | `compat/matrix.json` `tier` | D | W1-C; Pa |  |
| PRD-R40 | Onboarding screens 1-8 | `OnboardingFlow`, `OnboardingWindowController`, `Onboarding` table | U, M | W1-G; Pa (moderated test) | **Pa** |
| PRD-R41 | Closing before permission: slashed icon, resume | `OnboardingFlow`, `StatusLine` | U, M | W1-G |  |
| PRD-R42 | Not shown again; permission-lost variant | `OnboardingFlow` | U | W1-G |  |
| PRD-R43 | Error states: what, which, one action | `StatusLine`, `Status` table | U, M | W1-G |  |
| PRD-R44 | Fail open when permission missing or tap down | `KeyPipeline`, `InputHostController` | P, I | W1-F2; W2-E2 |  |
| PRD-R45 | Diagnostics allowed fields only | `DiagnosticsReport` | U | W1-A |  |
| PRD-R46 | Content-free health log; trace the only content artefact | `HealthEventLog`, `CaptureController` | U | W1-A |  |
| PRD-R47 | Bug report sheet | `BugReportComposer`, `BugReportController` | U, M | W1-G, W2-C |  |
| PRD-R48 | Clipboard use stated before writing | `BugReportController` | M | W2-C |  |
| PRD-R49 | Works without GitHub; practice field button | `BugReportController` | M | W2-C |  |
| PRD-R50 | Sparkle standard driver configuration | `UpdaterController` | U, M | W2-D; Pa | **Pa** |
| PRD-R51 | Release notes in interface language | appcast, release scripts | M | release track; W2-D |  |
| PRD-R52 | After update: everything intact, nothing shown | `SettingsStore`, 13.5 update tests | I, M | W2-E2; Pa; W1-B (legacy folder move) | **Pa** |
| PRD-R53 | Channel switch without downgrade | `UpdaterController`, About pane | U, M | W2-D, W2-B |  |
| PRD-R54 | Critical updates shown immediately, dismissible | appcast | R | release track |  |
| PRD-R55 | No Sparkle system profiling | `App/Info.plist` `SUEnableSystemProfiling` | L | skeleton (done) |  |
| PRD-R56 | Free; donations are a tip jar | n/a | D | n/a |  |
| PRD-R57 | Donation entry points only those listed | menu, About pane, site | M | W1-G, W2-B; site track |  |
| PRD-R58 | No nags, counters or locked features | all UI | D, M | all UI workstreams |  |
| PRD-R59 | Donation block content, bundled QR assets | `DonationInfo`, About pane | M (account VERIFY) | W2-B; Pa | **Pa** |
| PRD-R60 | No Polar.sh or Buy Me a Coffee | site, docs | D | site track |  |
| PRD-R61 | Optional public sponsor list | site | D | site track; Pa |  |
| PRD-R62 | String Catalogs vi + en, neutral copy | `App/Resources/Localization/*.xcstrings` | L (l10n lint), D | W1-G, W2-B, W2-C, W2-D, W2-F |  |
| PRD-R63 | Language change applies without restart | `Localizer`, `InterfaceLanguageModel`, ADR 0310 | U, M | W1-G |  |
| PRD-R64 | Pane names match macOS language and version | `SystemPaneTable` | U, V | W1-G; Pa (Vietnamese system) | **Pa** |
| PRD-R65 | Date, number, version formats follow the selected language | `Localizer` | U | W1-G |  |
| PRD-R66 | VoiceOver labels and hints, HUD announcement | all UI | M (VoiceOver) | W1-G, W2-B, W2-C, W2-D (labels, hints, keyboard in their windows); W2-F (audit) | **Pa** |
| PRD-R67 | Keyboard navigation, contrast, Reduce Motion | all UI | M | W1-G, W2-B, W2-C, W2-D (labels, hints, keyboard in their windows); W2-F (audit) | **Pa** |
| PRD-R68 | VoiceOver with injected edits (VERIFY) | n/a (observation) | V, M | W2-F; Pa | **Pa** |
| PRD-R69 | No silent reading of other apps' data | `MacroImporter` (user-chosen files only) | D, L | W1-B |  |
| PRD-R70 | Tolerant importers | `MacroImporter` | U | W1-B |  |
| PRD-R71 | Website migration pages | `site/` | D | site track |  |
| PRD-R72 | Own export format | `SettingsStore` export | U | W1-B |  |
| PRD-R73 | Website pages | `site/`, served by the `deploy/site` container (ADR 0602) | D, U (`node site/test.mjs`) | site track |  |
| PRD-R74 | No trackers on the website | `site/`; optional cookieless PostHog only when `site/config.json` sets a key (Pa, 2026-11-13, Q7; ADR 0602), never in the app or on release-notes pages | U (`node site/test.mjs`: no third-party origin without a key, only the PostHog hosts with one) | site track; Pa decision |  |
| PRD-R75 | Appcast host over HTTPS on a Pa-controlled domain | `deploy/site` on the Kalera Docker Swarm behind Traefik and Cloudflare (ADR 0602, [site deploy](../runbooks/site-deploy.md)), `Config/Sparkle.xcconfig` | R, U (`node deploy/site/test.mjs`), M (first deploy) | release track; Pa | **Pa** |
| PRD-R76 | Success metrics without telemetry | `scripts/metrics.py` | D | CI track |  |
| PRD-R77 | No in-app survey, rating prompt or usage counter | all UI | D | all UI workstreams |  |

## 04-quality-release.md (QA-R)

| ID | Requirement (short) | Owner module / file | Verification | Workstream | Pa |
|---|---|---|---|---|---|
| QA-R1 | Test layers with one command each | `CONTRIBUTING.md`, package layout | D | docs track; all |  |
| QA-R2 | Coverage: engine 95 %, app logic 80 % | CI coverage report | L | CI track; every workstream meets it |  |
| QA-R3 | Bug fixes start with a failing test | process | D | all |  |
| QA-R4 | Engine corpus files | engine package | E | engine track |  |
| QA-R5 | Corpus on macOS and Linux | CI | E, L | engine track; CI track |  |
| QA-R6 | corpus-change label for expected output changes | process | D | engine track |  |
| QA-R7 | Engine property tests P1-P7 | engine package | E | engine track |  |
| QA-R8 | Fuzzing per PR and nightly | CI | E, L | engine track; CI track |  |
| QA-R9 | Fuzz seed corpus stored and minimised | engine package | E | engine track |  |
| QA-R10 | Test host app with listed fields | `TestHost/**` | I | W2-E1 |  |
| QA-R11 | Integration tests through the real pipeline | `compat/scenarios/testhost.*` (with `profiles/qa-r11.json`), `compat-harness` (`scripts/run-integration.sh tests`), the hooks test build (`scripts/run-integration.sh build`), [integration-suite.md](../runbooks/integration-suite.md) sections 3 and 6 | U (`ScenarioOracleTests`, `HostHookActionsTests`), I | W2-E2; W3-A |  |
| QA-R12 | Integration tests on a self-hosted runner | self-hosted runner | I, M | W2-E2; CI track; Pa (runner) | **Pa** |
| QA-R13 | Self-hosted runner only for main and tags | workflows | L | CI track |  |
| QA-R14 | Performance gates and baselines | CI, pipeline benchmark | L | CI track; W1-F1; W2-E2 |  |
| QA-R15 | perf-baseline label | process | D | CI track |  |
| QA-R16 | Nightly 1,000,000-keystroke soak | `compat-harness soak` (`TestSupport/Scenario/Soak.swift`), `perf/platform-baseline.json` (M2), `integration.yml` nightly job, [integration-suite.md](../runbooks/integration-suite.md) section 3 | U (`SoakRunnerTests`, `SoakCountersTests`), I | W2-E2; W3-A |  |
| QA-R17 | Two compatibility files, matrix fields | `compat/rules.json`, `compat/matrix.json` | L | W1-C |  |
| QA-R18 | Standard compatibility script | `compat/SCRIPT.md` | D | docs track |  |
| QA-R19 | Verification cadence; 120-day expiry | `MatrixStatusResolver` | U | W1-C |  |
| QA-R20 | Community verifications via issue form | issue forms | D | docs track |  |
| QA-R21 | New profile needs a test-host reproduction | `TestHost`, `compat/scenarios`, `compat/scenarios/profiles/testhost-reproductions.json`, [integration-suite.md](../runbooks/integration-suite.md) section 3 | C, U (`ScenarioFilesTests` rule coverage) | W2-E1, W2-E2 |  |
| QA-R22 | Workflows | `.github/workflows` | L | CI track |  |
| QA-R23 | Pinned Xcode, newest macOS tested | CI | L, M | CI track; Pa (self-hosted) | **Pa** |
| QA-R24 | Supply-chain hygiene | `Config/Package.resolved`, workflows | L | skeleton; CI track |  |
| QA-R25 | Branch protection on main | GitHub settings | M | Pa | **Pa** |
| QA-R26 | SemVer and integer build | release scripts, `project.yml` | R | release track |  |
| QA-R27 | Engine versioned separately | engine package | D | engine track |  |
| QA-R28 | Stable and beta channels | `UpdaterController`, appcast | U, R | W2-D; release track |  |
| QA-R29 | Release cadence, 72 h on beta | process | D | Pa |  |
| QA-R30 | Release workflow steps | `scripts/build-release.sh`, `notarize.sh`, `verify-release.sh` | R | release track |  |
| QA-R31 | Signing only in the protected release environment | workflows | M | CI/release tracks; Pa approves | **Pa** |
| QA-R32 | EdDSA signing on Pa's Mac | `scripts/publish-release` | M | release track; Pa | **Pa** |
| QA-R33 | EdDSA public key and feed fixed from first public build | `Config/Sparkle.xcconfig` | M | W2-D; Pa generates the key | **Pa** |
| QA-R34 | Appcast entry fields | release scripts | R | release track |  |
| QA-R35 | Phased rollout | release scripts | R | release track |  |
| QA-R36 | Homebrew cask | `packaging/homebrew` | R | release track |  |
| QA-R37 | Same script updates appcast, site and changelog | release scripts | R | release track |  |
| QA-R38 | Rollback steps | runbooks | M | docs track; Pa | **Pa** |
| QA-R39 | Rehearsed rollback before public beta | runbooks | M | Pa | **Pa** |
| QA-R40 | Upgrade test before every release | self-hosted runner or VM | I, M | W2-E2; Pa | **Pa** |
| QA-R41 | Versioned migrations with backups and fixtures | `MigrationChain`, fixtures | U | W1-B |  |
| QA-R42 | Self-check on first launch after update | `AppEnvironment`, `InputHostController` | U, I | W2-A |  |
| QA-R43 | Issue forms | `.github/ISSUE_TEMPLATE` | D | docs track |  |
| QA-R44 | Machine-parseable diagnostics block with format version | `DiagnosticsRenderer.issueBlock` | U | W1-A; CI track (labeller) |  |
| QA-R45 | Label set | `scripts/sync-labels.sh` | D | CI track |  |
| QA-R46 | Issue lifecycle | process | D | Pa |  |
| QA-R47 | Bot rules | workflows | L | CI track |  |
| QA-R48 | setting-workaround tagging | process | D | Pa |  |
| QA-R49 | No verbose logs as a first step | process, support docs | D | docs track |  |
| QA-R50 | Monthly metrics script | `scripts/metrics.py` | D | CI track |  |
| QA-R51 | Support channels | site, docs | D | docs/site tracks; Pa (email VERIFY) |  |
| QA-R52 | Response targets | site | D | site track |  |
| QA-R53 | Weekly routine and saved replies | `docs/support/replies.md` | D | docs track |  |
| QA-R54 | Absence banner | process | D | Pa |  |
| QA-R55 | Support conversations become issues | process | D | Pa |  |
| QA-R56 | SECURITY.md | `SECURITY.md` | D | docs track |  |
| QA-R57 | Security response process | process | D | Pa |  |
| QA-R58 | Security scope | `SECURITY.md` | D | docs track |  |
| QA-R59 | Security review checklist for sensitive PRs | PR template | D | docs track; all workstreams |  |
| QA-R60 | New endpoints need ADR; URL host allowlist check | `scripts/lint.sh` | L | CI track; all |  |
| QA-R61 | DCO or CLA | `CONTRIBUTING.md` | D | docs track; Pa decision |  |
| QA-R62 | Clean-room attestation in PR template | PR template | D | docs track |  |
| QA-R63 | PR rules | process | D | all |  |
| QA-R64 | AI-assisted contributions | process | D | all |  |
| QA-R65 | Code of conduct | `CODE_OF_CONDUCT.md` | D | docs track |  |
| QA-R66 | Required documents incl. ARCHITECTURE.md | `ARCHITECTURE.md` (this track), others; engine API docs (DocC) per ADR 0402 | D | platform design (done); docs track; CI and release (nightly DocC artifact) |  |
| QA-R67 | Docs are part of done | process | D | all |  |

## 05-clean-room.md (CLR-R)

| ID | Requirement (short) | Owner module / file | Verification | Workstream | Pa |
|---|---|---|---|---|---|
| CLR-R1 | Do not read other Vietnamese IMEs' source | process | D | all |  |
| CLR-R2 | Do not read other open-source engines' source | process | D | all (engine track especially) |  |
| CLR-R3 | Allowed sources only | process | D | all |  |
| CLR-R4 | Discard code that resembles another IME | process | D | all |  |
| CLR-R5 | Behavioural facts allowed, code not | process | D | all |  |
| CLR-R6 | Permissive word lists only | engine data | D, L | engine data track |  |
| CLR-R7 | Original or licensed assets with recorded source | `App/Resources/Assets.xcassets`, site | D | W1-G; site track |  |
| CLR-R8 | New, empty memory project | process (a new memory project, empty at the start) | D | done |  |
| CLR-R9 | No research folder in the repository | process | D | all |  |
| CLR-R10 | Clean-room notice in agent instructions | `CLAUDE.md`, `AGENTS.md` | D | done |  |
| CLR-R11 | SPDX header on every source file | all sources | L | all; CI track (lint) |  |
| CLR-R12 | Keep git history intact | process | D | all |  |
| CLR-R13 | Similarity review before first public release and 1.0 | `docs/provenance/` | M | Pa (reviewer allowed to see other code) | **Pa** |
| CLR-R14 | Contributors confirm clean-room rules | `CONTRIBUTING.md`, PR template | D | docs track |  |
