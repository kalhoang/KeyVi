# Traceability matrix

One row per requirement of `spec/02-platform.md` (PLT-R), `spec/03-product.md` (PRD-R),
`spec/04-quality-release.md` (QA-R) and `spec/05-clean-room.md` (CLR-R): the owning module or file, how it is
verified, and the workstream that implements it ([workstreams.md](workstreams.md)). Engine requirements
(ENG-R) are traced by the engine track. Generated on 2026-11-13 and checked against the spec: 340 rows (349 with PLT-R397A, PLT-R397B, PLT-R357, PLT-R914, PLT-R423, PLT-R424, QA-R68, PRD-R78 and PRD-R79 of 2026-11-15; planned rows of 2026-11-18 for the typo correction of 1.1.0: PRD-R4A, PRD-R80, PRD-R81 and the host halves of ENG-R1117 to ENG-R1119),
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
| Permissions | PLT-R701, PLT-R702, PLT-R705, PLT-R710, PLT-R711, PLT-R712, PLT-R730, PLT-R731, PLT-R740, PRD-R40 | Fresh install from the DMG: move offer, grant Accessibility (and Input Monitoring only if asked), typing within 2 s, revoke while typing (keys must pass untouched), re-grant, "Đặt lại quyền" |
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
| PLT-R103 | Engine package MPL-2.0, no AppKit/CG/Carbon | `Packages/VietnameseEngine` | L | engine track |  |
| PLT-R104 | Sparkle only runtime dependency, exact pin, resolved file committed | `project.yml`, `Config/Package.resolved`; unit evidence: UpdaterTests `BuiltBundleTests` (run by `ci.yml` macos-app) | L, U | skeleton (done); W2-D |  |
| PLT-R105 | Universal binary (arm64 + x86_64), Intel supported | `Config/Release.xcconfig`, `.github/workflows/ci.yml` job `macos-x86_64` (AppCore suite under Rosetta) | R, U, M | W4-A (ADR 0315); release track (`lipo` check) | **Pa** (Intel smoke test when hardware exists) |
| PLT-R106 | macOS 12.0 minimum; newer APIs only behind `#available`; RealtimeSupport `Atomic`, `Mutex`, `TimeSpan` instead of `Synchronization` and `Duration` | `Package.swift` (AppCore, engine, fuzz), `project.yml`, `RealtimeSupport`, ADR 0315 | L, U | W4-A; every build fails on unguarded newer APIs; strong imports checked against the macOS 12.0 SDK (ADR 0315) |  |
| PLT-R107 | Test matrix macOS 12, 15, 26, 27 plus next beta; macOS 12 smoke test in a tart VM | self-hosted runner, `compat/matrix.json`, `scripts/vm/smoke-macos12.sh`, ADR 0315; macOS 12.7.6 smoke test PASS 2026-11-13 (arm64 + x86_64 under Rosetta), ADR 0315 | M, V | W2-E2; W4-A (plan); W5-E; Pa | **Pa** (per release candidate: the manual onboarding and typing pass of ADR 0315) |
| PLT-R108 | Licence note for rules/injection reuse | `docs/decisions/` (Pa) | D | Pa decision |  |
| PLT-R201 | One process, no daemons, extensions or IMKit bundle; `.accessory`, `.regular` only while a user window is open (amended 15/11/2026) | `App` target; ShellCore `AppPresence` (`AppPresenceCoordinator`), App `WindowPresenceController` | I, R, U (`AppPresenceRuleTests`, `AppPresenceCoordinatorTests`), M | W2-A; release track (bundle check); W17-B | **Pa** |
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
| PLT-R311 | FIFO worker, hold/replay while in flight; the keyUp of a passed keyDown passes (amendment 2026-11-15) | `KeyPipeline`, `ConsumedKeyTable`, `Injection/Queue.swift`, `Worker.swift`, ADR 0311, ADR 0322 | P (ledger: "replayed keyUp of a passed keyDown"), U (`KeyPipelineRolloverTests`), I (`testhost.web.rolloverKeyUp`) | W1-F1, W1-D; W2-A (combined suite); W14-H |  |
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
| PLT-R330 | Tap disabled by system: reset, replay, notice, re-enable after a live permission check; circuit breaker (2 disables within 30 s remove the tap); a live answer 3 s overdue fails open (15/11/2026) | `KeyPipeline`, `HostLifecycle` (`checkPermissionsLive`, `livePermissions`, breaker), `InputHostController`; hook `tapTimeout` (`InputHost/IntegrationHooks/IntegrationHookInstruments.swift`), `compat/scenarios/testhost.tapTimeout.recovery.json` | P, U (`HostHookActionsTests`, `HostLifecycleLiveReenableTests`, `HostLifecycleCircuitBreakerTests`, `HostLifecycleLiveAnswerWaitTests`, `HostRevocationTests`), I (test hook), M (pa-retest item 33) | W1-F2; W3-A; W17-A | **Pa** |
| PLT-R331 | Tap-enabled watchdog every 5 s and on events | `TapWatchdog` | U | W1-F2 |  |
| PLT-R332 | Tap creation failure: failOpen + backoff; breaker comeback 30/60/120/300 s on probation after a live check; creation waits at most 2 s on main, once per hung creation (15/11/2026) | `HostLifecycle`, `InputHostController`, `TapThreadRuntime` | U (`HostLifecycleCircuitBreakerTests`, `TapCreationTimeoutTests`, `HostRevocationTests`) | W1-F2; W17-A |  |
| PLT-R333 | Session inactive, sleep, lock: pause and revalidate | `InputHostController`, `WorkspaceEvents` | U, M | W1-F2, W1-E; Pa | **Pa** |
| PLT-R340 | Hard boundaries list; late focus change keeps the word (same process or after a timed-out read without an app, readable, within 500 ms, verified on the first edit) | `KeyPipeline` (`keepsCompositionAcrossLateFocusChange`, `FocusIdentity.appUnknownAfterTimeout`), `WorkerCore.lateFocusMatches` | P, U (`LateFocusChangeTests`, among them `aCommandTabRoundTripEndsTheWordPLTR340` for retest item 24, `WorkerLateFocusTests`, `LateFocusEndToEndTests`, `KeyPipelineDeleteKeyBoundaryTests`), C (`testhost.sheet.commandS`) | W1-F1, W8-A, W14-H, W17-B; Pa | **Pa** |
| PLT-R341 | Soft boundaries keep re-entry history | engine + `KeyPipeline` | E, I | engine track; W1-F1; W2-E2 |  |
| PLT-R342 | Re-entry verification with bounded AX read; `verifyReentry: never` in terminal rules (16/11/2026) | `InjectionWorker` (`verifyBeforeApply`), `compat/rules.json` (`terminal.default`, `editor.vscode.integratedTerminal`) | U (`SeededDataTests`, `TerminalRevisionTests`) | W1-D, W19-B |  |
| PLT-R343 | Bounded AX reads (64 characters) | `AXFocusedFieldAccess`, `SystemAXProvider` | U, L | W1-D, W1-E |  |
| PLT-R350 | Shift/Caps via table; Command/Control/Option chords | `KeyClassifier` | U | W1-F1 |  |
| PLT-R351 | Autorepeat handling | `KeyPipeline` | U, P | W1-F1 |  |
| PLT-R352 | User backspace reported to engine; delete-key resets; a Backspace edit never exceeds the token | `KeyPipeline` | P, U (`KeyPipelineDeleteKeyTests`, `KeyPipelineBackspaceGuardTests`) | W1-F1, W8-B |  |
| PLT-R353 | Restore hotkey semantics, per-app disable | `HotkeyRecognizer`, `KeyPipeline`; Escape off by rule (`features.restoreHotkey: false`) in terminals, code editors, games and remote desktop clients, and in launchers such as Spotlight, Raycast and Alfred (`compat/rules.json`, D8) | U (`RestoreHotkeyExclusionTests`, `RestoreHotkeyDefaultTests`), I | W1-E, W1-F1; W2-E2; W5-A |  |
| PLT-R354 | Dead keys pass and reset | `UCKeyTranslateLayoutBuilder`, `KeyClassifier` | U | W1-E, W1-F1 |  |
| PLT-R355 | Keypad digits are not VNI tone keys | `KeyClassifier` (`fromKeypad`), engine | U, E | W1-F1; engine track |  |
| PLT-R356 | Navigation keys never edit | `KeyPipeline` | P | W1-F1 |  |
| PLT-R357 | Revision edit job before the replayed boundary key, read-back and fallback, reset on failure; `features.lookaheadRevision` AND D29, sixteen engine variants | `KeyPipeline+Keys` (`.revision` job, `CommittedToken`), `WorkerCore+Edits` (`revisionOutcome`), `EngineSettingsMapping`, `HostDecisionMapping`, `CompiledRuleSet`, `compat/rules.json` | U (`KeyPipelineRevisionTests`, `RevisionEditJobTests`, `EngineBridgeTests`, `RulesFeatureFlagTests`, `HostDecisionMapperTests`, `RevisionReadBackRecorderTests`, `TerminalRevisionTests`: RV5 in a terminal whose Accessibility text cannot verify, the boundaries that still prevent it, a code editor that still verifies, 16/11/2026), P (`RevisionConservationPropertyTests`), L (compat-lint) | W11-B, W19-B |  |
| PLT-R360 | UCKeyTranslate tables per layout, 4 states | `InputSource/InputSources.swift`, `LayoutTable` | U (system layouts read by ID) | W1-E |  |
| PLT-R361 | Layout-produced letters (QWERTZ, AZERTY, Dvorak) | `LayoutTable`, `KeyPipeline` | U, I | W1-E, W1-F1; W2-E2 |  |
| PLT-R362 | Layout ID in diagnostics | `ReportAssembler` | U | W1-G |  |
| PLT-R363 | Debug cross-check with event Unicode string | `KeyPipeline` (debug), `TapLogCode.layoutMismatch` | U, V | W1-F1 | **Pa** |
| PLT-R370 | Observe TIS selection change, publish snapshot | `InputSourceMonitor` | U | W1-E |  |
| PLT-R371 | Pause for input methods and non-ASCII layouts | `InputSourceMonitor`, `HostStateResolver` | U, I (Japanese source on runner) | W1-E, W1-F1; W2-E2 |  |
| PLT-R372 | Pause for a built-in Vietnamese source | `InputSourceMonitor` | U, M | W1-E; Pa | **Pa** |
| PLT-R373 | Optional layout-to-mode binding | `InputSourceMonitor`, `LayoutModeBinding`, `HostStateResolution.effectiveMode` (a bound layout decides the mode; the toggle hotkey does nothing on a bound layout) | U (pipeline tests, HostRig `layoutBindingDecidesTheMode_PLT_R373`), M | W1-E; W2-B (UI) |  |
| PLT-R380 | AX thread observers on focused and overlay apps | `FocusTracker` | U (fake AX) | W1-E |  |
| PLT-R381 | System-wide AX focus is authoritative; frontmost-app fallback when AX names no app (amendment of 2026-11-15) | `FocusTracker` (`FocusCore+Reading.swift` `frontmostReading`), `FocusedAppSource`, `ProcessIdentityProvider.frontmostApplicationPID` | U (`FocusFrontmostFallbackTests`, `LateFocusChangeTests`), C (Spotlight, Raycast, Antigravity) | W1-E, W14-P; Pa | **Pa** |
| PLT-R382 | Idle revalidation flag | `KeyPipeline`, `FocusTracker` | U | W1-F1, W1-E |  |
| PLT-R383 | Focus snapshot contents | `InputHost/Snapshots/Snapshots.swift` (`FocusedApp.source`) | U | W1-E, W14-P |  |
| PLT-R384 | AX 100 ms timeout and circuit breaker | `AXCircuitBreaker`, `SystemAXProvider` | U | W1-E |  |
| PLT-R385 | Never AXEnhancedUserInterface; AXManualAccessibility only by rule | `SystemAXProvider` | L, U, V | W1-E | **Pa** |
| PLT-R386 | requireTextFocus gating | `HostDecisionMapper`, `HostStateResolver` | U, C (design apps) | W1-E, W1-F1; Pa | **Pa** |
| PLT-R387 | Secure fields always pass through | `FocusTracker`, `HostStateResolver` | U, I (password field) | W1-E, W1-F1; W2-E2 |  |
| PLT-R388 | Snapshot via one atomic reference | `RealtimeSupport/SnapshotCell.swift`, ADR 0303 | U, TSan | skeleton (done); W1-A |  |
| PLT-R389 | Revalidation after shortcuts, Escape, Return, Tab, clicks and in overlays; moved-only reads; `launcher.spotlight` lists the Siri app of macOS 27.2 (amended 15/11/2026) | `KeyPipeline` (`KeyPipeline+Focus.swift`), `FocusTracker` (`FocusCore+Settle.swift`), `compat/rules.json` | U (fake AX; `FocusSpotlightSeededRulesTests` with the shipped rules; `SeededDataTests`, `MatrixTests`), C (`testhost.panel.*`, `testhost.sheet.commandS`, `launcher.spotlight.reopen`, `launcher.spotlight.campo{,.reopen}`) | W8-A, W17-B; Pa | **Pa** |
| PLT-R390 | Per-app memory keyed by focus owner, precedence | `AppModeMemory` | U | W1-E |  |
| PLT-R391 | Mode in effect before the next key | `FocusTracker`, `KeyPipeline` toggle sequence | P | W1-E, W1-F1 |  |
| PLT-R392 | LRU 1,000, writes debounced 5 s, bundle and mode only | `AppModeMemory`, `SettingsStore.recordAppModes` | U | W1-E, W1-B |  |
| PLT-R393 | SHA-256 of executable path for bundle-less processes | `ProcessIdentityProvider`, `BundleKey.executable` | U | W1-E |  |
| PLT-R395 | Poll IsSecureEventInputEnabled every 2 s and on menu open | `SecureInputMonitor` | U | W1-E |  |
| PLT-R396 | Likely holder from IOConsoleUsers kCGSSessionSecureInputPID | `SystemSecureInputProbe` | U (parser), M | W1-E; Pa (iTerm2, browser) | **Pa** |
| PLT-R397 | Paused(secureInput) with holder hint, no modals | `SecureInputMonitor`, `Status` table | U, M | W1-E, W1-G; Pa | **Pa** |
| PLT-R397A | A keyUp the tap never saw go down is a hard boundary (input hidden from the tap); engine reset reason `ResetReason.unseenInput` | `KeyPipeline+UnseenInput.swift` (`KeysDown`), `BoundaryReason.unseenInput`, `ResetReason.unseenInput` (engine), `TapLogCode.unseenKeyUp` | U (`KeyPipelineUnseenInputTests`), P (`UnseenInputPropertyTests`) | W14-H, W14-E |  |
| PLT-R397B | Health signal for short secure-input episodes ended while typing; holder and duration in the dev gap line; label and explanation in the Diagnostics window, the report text and the copied block | `HealthEventLog` (`SecureInputBursts`, `secureInputBursts`), `DevRecorder` gap line, `HealthNotice`, `DiagnosticsCopy.notice`, App `HealthNoticeView` | U (`SecureInputEpisodeTests`, `DevRecorderTests`, `HealthNoticeTests`, `DiagnosticsCatalogTests`, `SpecDraftCopyTests`), M | W14-H, W14-P; Pa |  |
| PLT-R398 | Never call EnableSecureEventInput | all | L (grep) | W1-E |  |
| PLT-R398A | P0-1: only OS state and AXSecureTextField pause | `HostStateResolver` | U, L | W1-F1, W1-E |  |
| PLT-R398B | P0-1: resume on the first key after release | `KeyPipeline`, `HostCounters` (reported as `firstKeyAfterSecureInputReleaseComposed`), `compat/scenarios/testhost.secureInput.release.json` | P, U (`FirstKeyAfterSecureReleaseTests`), I, C | W1-F1; W2-E2; W3-A; Pa (iTerm2) | **Pa** |
| PLT-R398C | P0-1: terminal hints incl. iTerm2 automatic secure entry | `compat/rules.json` `secureInputHints`, `Status` table (one iTerm2 sentence, Q38) | U (`SecureInputHintCopyTests`), M, V | W1-C, W1-G; W5-C; Pa | **Pa** |
| PLT-R398D | P0-1: spike S1, IMKit under secure keyboard entry | `SpikeIMK/**` | M | skeleton (done, runnable spike); Pa runs it | **Pa** |
| PLT-R399 | Warn about conflicting input software | `ConflictDetector`, rules `conflictingInputApps`, source registry `compat/conflicting-apps.json` | U | W1-E; W1-G (onboarding screen 5); W2-A (wiring); W5-A (IDs) | The bundle IDs of XKey, PHTV and Gõ Nhanh come from public Homebrew cask metadata (Pa's delegation, 2026-11-13; ADR 0005), never from the installed apps |
| PLT-R401 | EditJob contents | `Injection/Jobs.swift` | U | W1-D |  |
| PLT-R402 | Minimal edits (common prefix trim) | `EditMinimizer` | U | W1-D |  |
| PLT-R403 | NFC insertions, grapheme delete counts | `InjectionWorker` | U | W1-D |  |
| PLT-R404 | One grapheme per event; chunk up to 20 units | `UnicodeChunker` | U | W1-D |  |
| PLT-R405 | Edits, restores and macros type on a letter keycode, never on Delete, Return, Tab or Space; the trigger key follows once | `JobKeyCodes` (`isActionKey`), `KeyPipeline.letterKeyCode`, `SyntheticKeys.unicodeKeyCode`, strategies | U (`BackspaceEditKeyCodeTests`, `KeyPipelineDeleteKeyTests`, `KeyPipelineRealEngineBackspaceTests`, `CommitTriggerKeyCodeTests`, `KeyPipelineCommitTriggerTests`, `KeyPipelineRealEngineCommitTriggerTests`, `KeyCodeFirstComposerOracleTests`), C (`testhost.web.keycodeFirst.backspace`, `testhost.web.keycodeFirst.returnCommit`) | W1-F1, W1-D, W8-B, W8-F |  |
| PLT-R406 | No modifier flags except where required | strategies | U | W1-D |  |
| PLT-R407 | Backspace key; forward delete banned except the scoped `forwardDelete` completion handling (amended 15/11/2026), which posts it only after a read that found the caret at the end or, when a later read times out, while the caret continuity of PLT-R423 holds (16/11/2026) | strategies (`SyntheticKeys`, `CaretAtEndMemory`), `RulesLinter`, `check-no-forward-delete.py` | U (`ForwardDeleteTests`, `CaretContinuityTests`), L | W1-D, W1-C; W17-D, W19-A |  |
| PLT-R408 | Timing parameters, caps, split | strategies, `ResolvedParams` | U | W1-D, W1-C |  |
| PLT-R409 | Pacing on inject thread with absolute deadlines | `InjectionWorker`, `MachClock.sleep` | U | W1-D |  |
| PLT-R410 | Verification modes echo/axReadback/human | `InjectionWorker` | U, I | W1-D; W2-C (human) |  |
| PLT-R420 | Inline completion: axSelection; the read's result on the dev trace's job line (15/11/2026) | strategies (`CompletionPrefix`, `CompletionRead`) | U (`InlineCompletionTests`, `WorkerDevRecorderTests.theInlineCompletionReadIsRecordedPLTR420`), C | W1-D; W2-E2; W17-B |  |
| PLT-R421 | Inline completion: placeholder | strategies | U, C | W1-D; W2-E2 |  |
| PLT-R422 | Placeholder gate: 1,000-edit test, no broad rules | `RulesLinter`, compat scenario | L, C | W1-C; W2-E2 |  |
| PLT-R423 | Inline completion: `forwardDelete` (a Forward Delete before each Backspace when the caret is read at the end of the text; selection keeps PLT-R420; caret before the end or unreadable field gets nothing); `launcher.spotlight` uses it (added 15/11/2026, finding 202); the read has its own 50 ms bound and the job line its duration (amended 16/11/2026, retest items 34 and 40); a read that times out keeps an earlier answer of the caret at the end while the tap saw nothing that can move the caret (caret continuity, second amendment of 16/11/2026) | strategies (`CompletionPrefix`, `CompletionRead`, `SyntheticKeys`, `InjectionTiming.forwardDeleteReadTimeout`, `CaretAtEndMemory`), `JobQueue.breakCaretContinuity`, `EditJob.caretEpoch`, `CaretContinuity` and `hardBoundary` (InputHost pipeline), `FocusedFieldAccess.caret` (`AXFieldCalls`), `compat/rules.json` | U (`ForwardDeleteCompletionTests`, `ForwardDeleteTests`, `WorkerCompletionFallbackTests`, `CompletionReadTimeoutTests`, `CaretContinuityTests`, `KeyPipelineCaretContinuityTests`, `CaretContinuityWorkerPipelineTests`, `WorkerDevRecorderTests`, `AXFieldCallsTests`, `FindingDetectorTests`, `RecorderRoundTripTests`), C (`launcher.spotlight.campo.suggestion`), M | W17-D, W18-A, W19-A | **Pa** |
| PLT-R424 | `forwardDelete` never in defaults, global or title-only rules | `RulesValidator` (`ForwardDeleteScope`), `RulesLinter`, `check-rules.py`, `check-no-forward-delete.py` | U (`LoadingTests`, `LinterTests`, `SeededDataTests`), L | W17-D |  |
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
| PLT-R520 | Specificity scoring; games (`appCategories` with `passThrough`) win over engine-only matches (Q48) | `RuleSet.resolve` | U (`GamesPrecedenceTests`) | W1-C; W5-A |  |
| PLT-R521 | Identical signatures fail CI; runtime tie | `RulesLinter`, `RuleSet` | U, L | W1-C |  |
| PLT-R522 | User overrides outrank shipped rules | `RuleSet` | U | W1-C |  |
| PLT-R523 | Resolution on ax thread on focus change only | `FocusTracker` | U | W1-E |  |
| PLT-R530 | Scenario file format | `TestSupport/Scenario`, `compat/schema/scenario.schema.json`, `compat/scenarios/` | U, C | W2-E1 |  |
| PLT-R531 | Manual scenarios need fresh matrix rows | `RulesLinter`, `compat/matrix.json` | L, M | W1-C; Pa | **Pa** |
| PLT-R540 | Override mechanism and scopes | `CompatibilityModeChoice`, `GuidedTestRunner`, rule import | U | W1-G, W2-B, W2-C |  |
| PLT-R541 | rule-overrides.json listed, exported, in reports | `SettingsStore`, `ReportAssembler`, `ReportedOverride`, ADR 0312 | U | W1-B, W1-G |  |
| PLT-R701 | Accessibility required, decided by AXIsProcessTrusted() alone; macOS 27 label VERIFY | `PermissionProbe`, `PermissionMonitor`, `SystemPanes.json` | U, M, V | W1-E, W1-G, W8-C; Pa | **Pa** |
| PLT-R702 | Input Monitoring only when the tap fails with Accessibility granted; live listen-only check; a status replaced during its delivery is never forwarded or returned | `PermissionMonitor` (`checkNow`), `SystemPermissionProbe.canListenToEventsNow`, `InputHostController.permissionsChanged` | U (`PermissionDeliveryGuardTests`), V | W1-E, W8-C, W8-F; Pa | **Pa** |
| PLT-R703 | No other permissions | `App/Info.plist`, no entitlements | R, L | skeleton; release track |  |
| PLT-R704 | Pane names and deep links from an OS table | `SystemPaneTable`, `App/Resources/SystemPanes.json` | U, V | W1-G; Pa | **Pa** |
| PLT-R705 | Permission screen: one row per needed permission with a live state, button opens the first missing pane | `PermissionScreenContent`, `PermissionNeed`, `OnboardingFlow`, App `PermissionRows` | U, M | W8-C; Pa | **Pa** |
| PLT-R710 | Run from Applications, not translocated; move offer | `AppLocationCheck`, `AppEnvironment` | U, M (launch from DMG) | W1-G, W2-A; Pa | **Pa** |
| PLT-R711 | Onboarding permission flow with 1 s polling | `OnboardingFlow`, `PermissionMonitor` | U, M | W1-G, W1-E; Pa | **Pa** |
| PLT-R712 | Relaunch offer for Input Monitoring | `OnboardingWindowController` | M | W1-G; Pa | **Pa** |
| PLT-R720 | Permission states and stale detection | `PermissionMonitor` | U | W1-E |  |
| PLT-R721 | Polling cadence 2 s / 30 s / on events; 1 s live Accessibility check while a tap is installed; every permission call off the main thread, queued checks coalesce (15/11/2026) | `PermissionMonitor` (`PermissionCheckRunner`), `InputHostController`, `AppEnvironment` | U (`PermissionMonitorLiveCheckTests`, `HostRevocationTests`) | W1-E; W17-A |  |
| PLT-R730 | Fail-open within the same callback; a revoked grant removes the tap within about 1 s of `AXIsProcessTrusted()` reporting it, never re-enabled on a cached status (15/11/2026) | `KeyPipeline`, `InputHostController`, `InjectionWorker`, `PermissionMonitor`; hook `revokePermission` (`RevocablePermissionProbe`), `compat/scenarios/testhost.failOpen.permissionRevoked.json` | P, U (`HostHookActionsTests`, `HostRevocationTests`, `PermissionMonitorLiveCheckTests`), I (revocation on runner), M (pa-retest item 33) | W1-F1, W1-F2; W2-E2; W3-A; W17-A; Pa | **Pa** |
| PLT-R731 | Recreate tap when permission returns | `InputHostController`, `RevocablePermissionProbe.canListenToEventsNow` | U (`RevocablePermissionProbeTests`, `FakePermissionProbeLiveCheckTests`), M | W1-F2, W8-F; Pa | **Pa** |
| PLT-R740 | Re-grant guidance, tccutil reset for own bundle | `PermissionResetting`, `Status` table | U, M | W1-E, W1-G; Pa | **Pa** |
| PLT-R741 | Never suggest sudo or bundle-less tccutil | `Status`/`Onboarding` copy | D | W1-G |  |
| PLT-R750 | Developer ID signing, hardened runtime, notarized | `Config/Signing.xcconfig`, `Config/Release.xcconfig`, release scripts | R, M | release track; Pa (credentials) | **Pa** |
| PLT-R751 | Dev builds use .dev bundle ID and Apple Development | `Config/Debug.xcconfig` | L | skeleton (done) |  |
| PLT-R752 | Updates in place keep identity and trust | Sparkle, release scripts | R, M (13.5) | W2-D; release track; Pa | **Pa** |
| PLT-R760 | MDM / PPPC documentation | `docs/support/managed-macs.md` | D, V | docs track (done; macOS 27 DDM note VERIFY) |  |
| PLT-R801 | Lock-free histograms | `Diagnostics/Metrics.swift` (log2 buckets plus gate-aligned sub-buckets for T2 and T3, `PlatformMetrics.reset()`); echo round trip recorded by `EchoTracker(roundTrip:)` into `metrics.echoRoundTrip` | U (`MetricsPrecisionTests`, `HotPathAllocationTests`, `echoedJobsRecordTheRoundTrip`) | W1-A; W3-A |  |
| PLT-R802 | Signposts around callback, job, AX | `PlatformSignposts`, emitted by `KeyPipeline.handle` (tap callback), `WorkerCore.process` (injection job), `InstrumentedFieldAccess` (worker AX calls) and `FocusCore.timed` (focus AX calls) | U (HostRig `signpostsReachTheTapCallback_PLT_R802`), I, M (Instruments) | W1-A |  |
| PLT-R803 | No steady-state timer faster than 2 s, except the 1 s live Accessibility check while a tap is installed (15/11/2026) | `TapWatchdog`, monitors, ADR 0309 | U (`PermissionMonitorTests`, `PermissionMonitorLiveCheckTests`), I (wakeups) | W1-F2, W1-E; W17-A |  |
| PLT-R810 | Built-in latency probe | `LatencyProbeDriver`, `DiagnosticsWindowController` | U, M | W2-C; Pa runs it | **Pa** |
| PLT-R820 | Hosted CI microbenchmarks with fakes | pipeline benchmark in `Tests/InputHostTests/Pipeline` | L | W1-F1; CI track |  |
| PLT-R821 | Self-hosted metrics T2-T6, C1, C2, M1, M2 | `compat-harness` (`TestSupport/Scenario/AppMetrics.swift`, `PlatformBenchmark.swift`, `Soak.swift`), the app's hooks (`InputHost/IntegrationHooks/`, `App/Sources/IntegrationHooks/`), `perf/platform-baseline.json`, [integration-suite.md](../runbooks/integration-suite.md) sections 3 and 4, ADR 0502 | U (`AppMetricsTests`, `IntegrationHookServerTests`), I | W2-E2; W3-A |  |
| PLT-R822 | Regression gate and baselines | `perf/platform-baseline.json`, `perf/README.md`, `RegressionGate`, `scripts/bench-compare.sh` from `scripts/run-integration.sh bench` and `soak`, [integration-suite.md](../runbooks/integration-suite.md) section 7 | L, U (`RegressionGateTests`, scripts/tests) | CI track; W2-E2; W3-A |  |
| PLT-R901 | Data classes; content never in logs | Diagnostics, all modules; canary: `TestSupport/Scenario/PrivacyCanary.swift`, `compat/scenarios/testhost.privacyCanary.*`, `compat/scenarios/profiles/privacy-canary.json`, [integration-suite.md](../runbooks/integration-suite.md) section 4; hook responses carry codes only (`AppStateSnapshotMappingTests`) | L (canary), U, I | W1-A; W2-E2; W3-A |  |
| PLT-R902 | Typed logging API; interpolation lint | `Diagnostics/LogEvent.swift`, `Redaction.swift` | U, L | W1-A; CI track (lint) |  |
| PLT-R903 | Log location, permissions, rotation, retention | `DiagnosticsLogger`, `LogStorePolicy` | U | W1-A; W1-B (legacy folder move, ADR 0307) |  |
| PLT-R904 | No verbose/debug content mode | Diagnostics | D, L | W1-A |  |
| PLT-R904A | Dev recorder, Debug builds only (ADR 0007) | `DevRecorder` (Diagnostics), `KeyPipeline+DevRecorder`, `DevReadback`, `WorkerCore+DevRecorder`, App `DevRecorderController`, `trace-scan`; `scripts/verify-release.sh` check | U (`DevRecorderTests`, `DevRecorderPipelineTests`, `DevReadbackTests`, `FocusDevRecorderTests`, `WorkerDevRecorderTests`, `DevRecorderShellTests`, `FindingDetectorTests`, `TraceScanCommandTests`, `RecorderRoundTripTests`, `SampleFixtureTests`, `ReadbackDivergenceTests`, `IncidentFixtureTests`, `ReopenedLiteralTests`: the ENG-R1005 regression guard `reopenedLiteral`; the job line's `compl` field of PLT-R420 and the replay of Return and Tab boundaries after their step, 15/11/2026; the job line's `complUs` read duration and the unreadable-completion finding, 16/11/2026; the job line's `forwardDelete kept` with `complKeptJobs` and `complKeptUs`, which is no finding, second amendment of 16/11/2026; the revision job line's `rb` read-back result and the `revisionFellBack` finding, `RevisionReadBackRecorderTests`, 16/11/2026), S (`scripts/tests` release check) | W8-E, W10-B, W16-A, W17-B, W19-A, W19-B; Pa | **Pa** |
| PLT-R905 | Time-boxed capture with HUD, 24 h deletion | `CaptureController`, `CaptureHUDController`; key and engine records from `KeyPipeline+Capture.swift`, focus records from `FocusCore.recordFocusCapture`; confirmation states the chosen duration (`TypingTraceConfirmation`) | U (`KeyPipelineCaptureTests`, HostRig `typingTraceRecordsKeysEngineDecisionsAndFocus_PLT_R905`, `TypingTraceConfirmationTests`), M | W1-A, W2-C; W5-C; Pa | **Pa** |
| PLT-R906 | Egress limited to Sparkle | `App` (URL host allowlist), Sparkle; egress test: `TestSupport/Scenario/EgressCheck.swift` (`compat-harness egress`), hook `checkForUpdates`, [integration-suite.md](../runbooks/integration-suite.md) section 5 | L, I (13.7) | W2-D, W2-E2, W3-A; CI track |  |
| PLT-R907 | No translation feature in v1 | n/a | D | n/a |  |
| PLT-R908 | Hardened runtime, no entitlements, not sandboxed | `project.yml`, `Config/Release.xcconfig` | R | skeleton; release track |  |
| PLT-R909 | No unauthenticated IPC; URL scheme opens Settings only | `URLSchemeRouter`, `AppEnvironment.handle(url:)`; the test build's hooks are owner-only files watched with a vnode source, no socket (`IntegrationHookServer`, ADR 0502), absent from releases (`scripts/verify-release.sh`) | U, R | W1-G, W2-A; W3-A |  |
| PLT-R910 | Supply chain: resolved file, pins, SHA-256 | `Config/Package.resolved`, workflows | L | skeleton; CI track |  |
| PLT-R911 | No retained engine state or raw keys | `KeyPipeline` | U, review | W1-F1 |  |
| PLT-R912 | Settings import treated as untrusted | `SettingsStore.previewImport` | U (malformed and fuzzed files) | W1-B |  |
| PLT-R913 | Reports include only the reported app memory | `ReportAssembler` | U | W1-G |  |
| PLT-R914 | Collision memory file, validation against the bundled list, thresholds, decay, cap, export and import, nothing recorded in secure contexts or with D28 off, weak signals dropped at a reset | `CollisionMemory`, `CollisionMemoryStore` (SettingsStore), `InputHostController+Notices` (`noteCollisionSignals`), `TapSettingsPublisher.collisionMemoryChanged`, `LearningTracker` (ENG-R862 amendment) | U (`CollisionMemoryTests`, `CollisionMemoryStoreTests`, `CollisionSignalRoutingTests`, `LearnedCollisionEntriesReportTests`, `CollisionMemoryStoreParityTests`) | W11-B, W16-A |  |
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
| PLT-R1110 | Homebrew cask auto_updates, depends_on, zap | `packaging/homebrew`; `depends_on macos: ">= :monterey"` since 2026-11-17 (ADR 0315, ADR 0507), tap `kalhoang/homebrew-tap` | R | release track |  |
| PLT-R1201 | Diagnostics window contents and buttons; health notices under the state line | `DiagnosticsWindowController`, `DiagnosticsWindowView` (`HealthNoticeView`), `DiagnosticsCopy.notices` | U (view model, `DiagnosticsCatalogTests`), M | W2-C, W14-P; Pa | **Pa** |
| PLT-R1202 | Environment report contents | `DiagnosticsReport` (`FocusSection.appSource`; `SettingsSection.learnCollisionChoices`, `.lookaheadRevision`, `.learnedCollisionEntries`), `ReportAssembler`; the copied block writes them as `focus.appSource` and `settings.*` keys (ADR 0501) | U (`FocusedAppSourceReportTests`, `LearnedCollisionEntriesReportTests`, `ReportAssemblerTests`, `IssueBlockTests`) | W1-A, W1-G, W14-P, W16-A |  |
| PLT-R1203 | Report exclusions (no content) | `DiagnosticsReport` type | U (canary) | W1-A; W1-G (`reportedOverride` projection, ADR 0312) |  |
| PLT-R1204 | User sees exact report before copying | `BugReportController` | M | W2-C; Pa | **Pa** |
| PLT-R1205 | "This app misbehaves" guided flow; step 6 keyboard focus (Q43) | `GuidedTestRunner`, diagnostics UI; ShellCore `MisbehavesPanelFocus`, `MisbehavesFocusTracker`, `MisbehavesRetarget`; App `MisbehavesPanel` | U (`MisbehavesFocusTests`), M | W2-C; W5-C; Pa | **Pa** |
| PLT-R1206 | Metadata-only health events | `HealthEventLog` | U | W1-A |  |
| PLT-R1207 | Support guidance | `docs/support` | D | docs track |  |

### Engine requirements with platform-side evidence

The engine track traces every ENG-R in `Packages/VietnameseEngine/TRACEABILITY.md`. These rows add the AppCore
evidence for engine requirements whose behaviour depends on the host (decision 0005, wave 5).

| ID | Requirement (short) | Owner module / file | Verification | Workstream | Pa |
|---|---|---|---|---|---|
| ENG-R828 | A commit that revises the previous word is one edit job of kind `revision`, injected before the boundary key | `InputHost/Pipeline/KeyPipeline+Keys.swift`, `Injection/Jobs.swift` (planned, W11-B; engine side W15-A: `EngineOutput.revision`) | U, P (planned by W11-B: the revision edit job and pipeline property tests with revision outputs) | engine track W15-A; W11-B |  |
| ENG-R829 | The host passes `lookaheadRevision`: `features.lookaheadRevision` of the rule ANDed with the D29 switch; and `lineStartRevision` (RV5 of the code context): D29 alone (16/11/2026, REG-36) | `CompatRules` (schema flag), `InputHost/Engine/EngineSettingsMapping.swift` (16 engine variants) (planned, W11-B) | U (planned by W11-B: the rule flag and the 16 engine variants; `EngineBridgeConfigurationTests.lineStartRevisionIsD29Alone`) | engine track W15-A; W11-B; W18-B |  |
| ENG-R850 | The host passes `appContext` from the rule's `action.engineContext` (`code` in terminals, IDEs and code editors); the engine reads the line itself, so rule L9 restores code-only words only outside Vietnamese text (amended 15/11/2026, REG-35), and RV5 revises a word restored at a line start once the next word is Vietnamese (16/11/2026, REG-36); a first word of its line in sentence case committed by a space is decided at its own commit, whatever D29 says, unless it is a capitalized code word such as `host` (product owner, 16/11/2026) | `CompatRules` (`action.engineContext`), `InputHost/Focus/HostDecisionMapping.swift`, `InputHost/Engine/EngineSettingsMapping.swift`; engine `Commit/CodeContext.swift` | U (`EngineBridgeConfigurationTests` (`lineStartRevisionIsD29Alone`), `RestoreHotkeyExclusionTests`, `SeededDataTests`), E (`CodeContextTests`, `CodeContextRealDataTests`, `LineStartSentenceTests`) | engine track W17-C, W18-B |  |
| ENG-R862 | Learned entries stored per app, typed entries global; words of the collision list go to the memory of ENG-R863 instead (amended 15/11/2026) | `SettingsStore/LearnedWords.swift`, `InputHost/Integration/LearningTracker.swift`, `TapSettingsPublisher.focusChanged(to:)`; ADR 0320; the collision-word skip in `LearningTracker` is planned (W11-B) | U (`PerAppLearningTests.swift`: `LearningTrackerTests`, `FocusedAppWordListTests`, `HostPerAppLearningTests`, in particular `HostPerAppLearningTests.aWordTypedBeforeTheFocusMovesBelongsToTheAppWhereItWasTyped`; W11-B adds a test that collision words never reach the per-app lists) | engine track; W5-B; W11-B |  |
| ENG-R863 | Learned memory of collision words, per user across all apps, votes computed by the host | `SettingsStore/CollisionMemory.swift` (votes, thresholds, conflict, any-context rule), `CollisionMemoryStore`; InputHost `CollisionMemoryBridge` maps the votes to the engine's snapshot; the engine reads `Resources.collisionMemory` (W15-A) | U (`CollisionMemoryVoteTests`, `CollisionMemoryUpkeepTests`, `CollisionMemoryStorePersistenceTests`; parity with the engine's reference model and worked cases: `CollisionMemoryStoreParityTests`) | engine track W15-A; W11-B; W16-A |  |
| ENG-R864 | Collision signals drained on the main thread and applied to the memory off the tap thread; nothing recorded under secure input or with `englishRestore: false` | `InputHost` signal routing (planned, W11-B); the engine emits `EngineOutput.collisionSignals` (W15-A) | U (planned by W11-B: signal routing) | engine track W15-A; W11-B |  |
| ENG-R876 | W11 collision targets: no wrong revision, no non-collision change, English at least 75 %, Vietnamese at least 99 % (98.8 % with the tone typed after the vowel), the adversarial sets without a wrong revision | the engine (W15-A); the gate runs in CI: `.github/workflows/ci.yml` engine-linux step "W11 collision corpus gate", macOS engine coverage run, `scripts/run-tests.sh` layer `collision` (QA-R68) | E (`CollisionCorpusTests.corpus`, `CollisionCorpusTests.adversarialSet`, `CollisionCorpusTests.corpusWithoutTheCollisionRules`), L | engine track W15-A; W11-D |  |
| ENG-R877 | A memory fed only by silent acceptance never changes a decision; held-out floor of 1.5 points | `SettingsStore` `CollisionMemoryStore` gives the votes of the reference model `ReferenceCollisionMemory` (VietnameseEngineTesting, from the text of ENG-R863) for every signal sequence before decay or eviction; held-out floor measured at 1.53 points, recorded as a known issue (ADR 0008, open question) | E (`CollisionMemorySimulationTests`, `ReferenceCollisionMemoryTests`), U (`CollisionMemoryStoreParityTests`: the `CollisionMemoryVoteCases` worked cases and 200 seeded signal sequences against the reference model) | W11-D; W11-B; W16-A |  |
| ENG-R906 | Bracket letters uppercase under Caps Lock | `KeyPipeline` reports `KeyInput.capsLock` from the event flags (PLT-R304) | E, U (`KeyPipelineCapsLockTests`) | engine track; W5-A |  |
| ENG-R1103 | Shadowed macro triggers rejected, including a trailing digit | Macros pane editor and importer refuse the pair; ADR 0321 | E, U (`MacroEditorTests`, `MacroEngineAgreementTests`) | engine track; W5-B |  |
| ENG-R1117 | The restore key right after a correction puts the typed word back; the host consumes the key and injects the undo edit like a restore (PLT-R353), with no active word (planned, 1.1.0) | `InputHost` restore path, `Injection/Jobs.swift` (planned) | U, P (planned: the undo edit job and pipeline property tests with corrected outputs) | 1.1.0 typo correction track (planned) |  |
| ENG-R1118 | `neverCorrect` learning signals go to the never-correct list at once, per user, every app; the list is stored, shown, exported and imported with the keep lists and passed as `Resources.userNeverCorrect` (planned, 1.1.0) | `SettingsStore` (`englishRestoreLists.neverCorrect`), `InputHost/Integration/LearningTracker.swift`, Settings Typing pane (planned) | U (planned: the list store, the signal routing, the export and import round trip, the entry validation of PRD-R81) | 1.1.0 typo correction track (planned) |  |
| ENG-R1119 | The host passes `typoCorrection` as D30 AND D4 AND the rule's `features.englishRestore`; the engine turns it off in the `code` context by itself (planned, 1.1.0) | `InputHost/Engine/EngineSettingsMapping.swift`, `DefaultSettings` (D30) (planned) | U (planned: the engine variants and the D30 mapping; the D30 default) | 1.1.0 typo correction track (planned) |  |

## 03-product.md (PRD-R)

| ID | Requirement (short) | Owner module / file | Verification | Workstream | Pa |
|---|---|---|---|---|---|
| PRD-R0 | Any failing P0 test blocks every release | release gate; P0 tests in pipeline suite and engine corpus | R, P, E | CI/release tracks; W1-F1; engine track |  |
| PRD-R1 | Tier 1 top jobs checked every release | `compat/matrix.json`, `compat/SCRIPT.md` | M | Pa; W2-E2 | **Pa** |
| PRD-R2 | v1.0 scope | whole product | D | all |  |
| PRD-R3 | v1.0 non-goals | whole product | D | all |  |
| PRD-R4 | Stage transitions recorded as decisions | `docs/decisions/`; first public release, private testing straight to 1.0.0: ADR 0507 (2026-11-17) | D | Pa |  |
| PRD-R4A | Typo and spelling correction after 1.0: the engine rules are `01-engine.md` section 11A (ENG-R1110 to ENG-R1124), on by default (product owner, 18/11/2026); design note `docs/superpowers/specs/2026-11-18-spelling-correction-design.md` (planned, 1.1.0) | engine `Commit/` (planned); `DefaultSettings` (D30, planned) | E (planned: ENG-T50 to ENG-T56), U (planned: the D30 default), D | 1.1.0 typo correction track (planned) |  |
| PRD-R5 | Ship exactly the listed defaults | `DefaultSettings.v1` | U | W1-B |  |
| PRD-R6 | Unset follows defaults; set preserved forever | `Setting`, `UserSettings` | U | W1-B |  |
| PRD-R7 | "Not a setting" items absent from UI | Settings UI | U (view model), M | W2-B |  |
| PRD-R8 | Minimum macOS 12 with Intel (Q6, ADR 0315) | `Package.swift`, `project.yml` | L | skeleton; W4-A |  |
| PRD-R9 | Status icon always visible (Pa's coloured KV mark, not a template image; S7) | `StatusItemController`, `StatusGlyph`, assets from `scripts/make-app-icon.py menu-bar` | M | W1-G; W4-B; Pa | **Pa** |
| PRD-R10 | Icon states with VoiceOver labels; warning badge for a missing permission (15/11/2026) | `StatusPresentation`, `Menu` table, assets (`scripts/make-app-icon.py`) | U (`StatusIconTests`, `ShellCatalogTests`, `scripts/tests/test_make_app_icon.py`), M (VoiceOver, pa-retest item 33) | W1-G; W2-F; W17-A; Pa | **Pa** |
| PRD-R11 | Menu layout | `MenuModel`, `StatusItemController` | U, M | W1-G |  |
| PRD-R12 | Switch HUD 600 ms, non-activating, Reduce Motion | `SwitchHUDController` | U, M | W1-G; W2-F; Pa | **Pa** |
| PRD-R13 | Menu opens within 100 ms and never blocks typing; menu callbacks only read state, no permission call on main (15/11/2026) | `StatusItemController`, `AppEnvironment+Shell`, `InputHostController.refreshPermissions` | U (`HostRevocationTests`), I, M | W1-G; W2-E2; W17-A |  |
| PRD-R14 | Toggle tap recogniser rules | `HotkeyRecognizer` | U | W1-E |  |
| PRD-R15 | Recorder accepts listed chords in any press order | `HotkeyRecorder` | U | W1-E; W2-B (UI) |  |
| PRD-R16 | Warn about macOS shortcuts, never refuse | `HotkeyRecorder.conflict`, Settings UI | U | W1-E, W2-B |  |
| PRD-R17 | Globe/fn toggle only if reliable (VERIFY) | `HotkeyRecognizer` (deferred) | V | W1-E (deferred) | **Pa** |
| PRD-R18 | Only two configurable hotkeys; Escape is the default restore key (D8, Q14) | `UserSettings`, `HotkeyRole` | U (`RestoreHotkeyDefaultTests` in SettingsStoreTests and InputHostTests) | W1-B, W1-E; W5-A |  |
| PRD-R19 | Remembered mode applies to the first key after activation | `FocusTracker`, `KeyPipeline` | P, I | W1-E, W1-F1; W2-E2 |  |
| PRD-R20 | Manual toggle updates memory | `AppModeMemory.recordToggle` | U | W1-E |  |
| PRD-R21 | Rule precedence ignore > EN > VI > memory > default | `AppModeMemory.resolve` | U | W1-E |  |
| PRD-R22 | Keyed by bundle; overlays have their own memory | `FocusTracker` | U, C (Spotlight over Terminal) | W1-E; Pa | **Pa** |
| PRD-R23 | Memory survives restarts/updates, exported | `SettingsStore` | U | W1-B |  |
| PRD-R24 | Seven panes (Pa, 15/11/2026), Advanced disclosure that opens from its whole row | `SettingsPaneKind`, Settings UI (`AboutPaneView`, `SupportPaneView`, `LicencesPaneView`, `SettingsDisclosureHeader`) | U, M (`SettingsLayoutTests`, `SettingsCatalogTests`; snapshot bundle `AdvancedDisclosureTests`; `test_settings_snapshots.py` observation guard) | W2-B, W8-D, W12-S |  |
| PRD-R25 | One-line explanation per setting | `Settings` table | M, D | W2-B |  |
| PRD-R26 | Reset per pane and global with confirmation and export offer | `SettingsStore.reset`, Settings UI | U, M | W1-B, W2-B |  |
| PRD-R27 | Changes apply immediately without losing the word | `InputHostController.apply` | U, I | W1-F1, W2-A |  |
| PRD-R28 | Settings is a normal window, frame remembered; while a window is open the app is in the Dock, Command+Tab and has a main menu (amended 15/11/2026) | `SettingsWindowController`; ShellCore `AppPresence`, `MainMenuLayout`; App `WindowPresenceController`, `MainMenuController` | U (`AppPresenceRuleTests`, `AppPresenceCoordinatorTests`, `MainMenuLayoutTests`), M | W2-B, W17-B | **Pa** |
| PRD-R29 | Macro shortcut and expansion rules | `MacroValidator`, engine `MacroTable` | U, E | W1-B; engine track |  |
| PRD-R30 | Expansion triggers and case adaptation | engine (ENG-R1103), host macros feature | E, I | engine track; W2-E2 |  |
| PRD-R31 | Macro list features | Macros pane | M | W2-B |  |
| PRD-R32 | Macro import formats with preview | `MacroImporter`, import sheet | U, M | W1-B, W2-B |  |
| PRD-R33 | Macros never sent; count only in diagnostics | `DiagnosticsReport.SettingsSection.macroCount` | U | W1-A, W1-G |  |
| PRD-R34 | Apps pane rows | `AppsPaneModel`, Apps pane | U, M | W1-G, W2-B |  |
| PRD-R35 | Compatibility status from matrix | `MatrixStatusResolver` | U | W1-C, W1-G |  |
| PRD-R36 | At most three compatibility choices under Advanced | `CompatibilityModeChoice` | U (`GuidedOverrideSlotTests.onlyThePlainChoicesAreSelectable`), M | W1-G, W2-B |  |
| PRD-R37 | Report command for every app row (context menu, button under the list) | Apps pane | M | W2-B, W8-D |  |
| PRD-R38 | Both compatibility files ship in the app | `project.yml` copy phase | R | skeleton (done); W1-C |  |
| PRD-R39 | Tier lists | `compat/matrix.json` `tier` | D | W1-C; Pa |  |
| PRD-R40 | Onboarding screens 1-8 | `OnboardingFlow`, `OnboardingWindowController`, `Onboarding` table | U, M | W1-G; Pa (moderated test) | **Pa** |
| PRD-R41 | Closing before permission: warning-badge icon, resume | `OnboardingFlow`, `StatusLine`, `StatusPresentation` | U, M | W1-G; W17-A |  |
| PRD-R42 | Not shown again; permission-lost variant, also shown once when the grant is lost while the app runs, without taking the focus (15/11/2026) | `OnboardingFlow`, `AppEnvironment.showPermissionScreenIfLost` | U, M (pa-retest item 33) | W1-G; W17-A |  |
| PRD-R43 | Error states: what, which, one action | `StatusLine`, `Status` table | U, M | W1-G |  |
| PRD-R44 | Fail open when permission missing or tap down | `KeyPipeline`, `InputHostController` | P, I | W1-F2; W2-E2 |  |
| PRD-R45 | Diagnostics allowed fields only | `DiagnosticsReport` | U | W1-A |  |
| PRD-R46 | Content-free health log; trace the only content artefact | `HealthEventLog`, `CaptureController` | U | W1-A |  |
| PRD-R47 | Bug report sheet | `BugReportComposer`, `BugReportController` | U, M | W1-G, W2-C |  |
| PRD-R48 | Clipboard written only on a button the user clicks (report flow, donation `Sao chép`), stated before writing | `BugReportController`, `SettingsWindowModel.copyToClipboard` | U, M (`DiagnosticsCatalogTests`) | W2-C, W12-S |  |
| PRD-R49 | Works without GitHub; practice field button | `BugReportController` | M | W2-C |  |
| PRD-R50 | Sparkle standard driver configuration | `UpdaterController` | U, M | W2-D; Pa | **Pa** |
| PRD-R51 | Release notes in interface language | appcast, release scripts | M | release track; W2-D |  |
| PRD-R52 | After update: everything intact, nothing shown | `SettingsStore`, 13.5 update tests | I, M | W2-E2; Pa; W1-B (legacy folder move) | **Pa** |
| PRD-R53 | Channel switch without downgrade | `UpdaterController`, About pane | U, M | W2-D, W2-B |  |
| PRD-R54 | Critical updates shown immediately, dismissible | appcast | R | release track |  |
| PRD-R55 | No Sparkle system profiling | `App/Info.plist` `SUEnableSystemProfiling` | L | skeleton (done) |  |
| PRD-R56 | Free; donations are a tip jar | n/a | D | n/a |  |
| PRD-R57 | Donation entry points only those listed (amended 17/11/2026: also the website footer link and the home page closing line) | menu, About pane, site (`/ung-ho`, footer link, home closing line in `site/lib/pages/home/closing.mjs`) | M, U (`node site/test.mjs`: donation entry points only where PRD-R57 allows) | W1-G, W2-B; site track |  |
| PRD-R58 | No nags, counters or locked features | all UI | D, M | all UI workstreams |  |
| PRD-R59 | Donation block content (Pa's copy of 15/11/2026: two columns, account details with copy buttons, share text with the macOS share menu), bundled QR assets | `DonationInfo.details`, `AboutSupportContent.shareText`, `DonationSection` (About pane); the website's `/ung-ho` (`renderDonate` in `site/lib/pages/simple.mjs`, `site/static/assets/copy.js`) | U, M (`SettingsModelsTests`, `SpecDraftCopyTests`, `DonationQRTests`, `node site/test.mjs`) | W2-B, W12-S; Pa | **Pa** |
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
| PRD-R72 | Own export format; the learned words of the import counted only when importable (skipped ones counted), unavailable while the memory is not loaded (amended 15/11/2026) | `SettingsStore` export, `CollisionMemoryImportPreview`, `ImportSummary` (ShellCore), import sheet | U (`CollisionMemoryTransferTests`, `LearnedChoicesPaneTests`, `SpecDraftCopyTests`) | W1-B, W16-A |  |
| PRD-R73 | Website pages; the home page's typing demo is generated from the engine (design of 16/11/2026); amended 17/11/2026: no link to the compatibility page, which is unlisted and `noindex`, and a learning section with the engine's learning demo (design section 9) | `site/`, served by the `deploy/site` container (ADR 0602); home sections `site/lib/pages/home/` (`learning.mjs`); demo script and frames `site/demo/`, written by `site-demo-frames` (`Packages/VietnameseEngine`); the `unlisted` route flag in `site/lib/routes.mjs` | D, U (`node site/test.mjs`), L (`site-demo-frames --check`) | site track; W20 |  |
| PRD-R74 | No trackers on the website | `site/`; optional cookieless self-hosted Umami only when `site/config.json` configures it (Pa, 2026-11-13, Q7; ADR 0602 decision 7), never in the app or on release-notes pages | U (`node site/test.mjs`: no third-party origin without the config, only the Umami origin with it) | site track; Pa decision |  |
| PRD-R75 | Appcast host over HTTPS on a Pa-controlled domain | `deploy/site` on the Kalera Docker Swarm behind Traefik and Cloudflare (ADR 0602, [site deploy](../runbooks/site-deploy.md)), `Config/Sparkle.xcconfig` | R, U (`node deploy/site/test.mjs`), M (first deploy) | release track; Pa | **Pa** |
| PRD-R76 | Success metrics without telemetry | `scripts/metrics.py` | D | CI track |  |
| PRD-R77 | No in-app survey, rating prompt or usage counter | all UI | D | all UI workstreams |  |
| PRD-R78 | Learned-words sheet: entries that vote, rendered in D2, remove per row and `Xóa tất cả`, D8 key in the empty state, cleared by the Typing and full resets; one line and no edit while the memory is not loaded | `App/Sources/Settings/LearnedChoicesSheet.swift`, `SettingsWindowModel+LearnedChoices`, `LearnedChoices` (ShellCore; `LearnedChoicesSheetState.isUnavailable`), `SettingsCommands.learnedChoices`, `CollisionMemoryStore.learnedChoices` | U (`LearnedChoicesPaneTests`), M | W11-C, W16-A | **Pa** |
| PRD-R79 | Copy of D28, D29 and the learned-words sheet, including the line shown when the memory is not loaded; D29 example amended 15/11/2026 | `App/Resources/Localization/Settings.xcstrings` | U (`LearnedChoicesPaneTests`, `SpecDraftCopyTests`; engine `RetestBeta2RealDataTests` pins the example), L (l10n lint) | W11-C, W16-A, W17-B; Pa (copy review before v1) | **Pa** |
| PRD-R80 | D30 switch in the Typing pane under D28, on by default, copy vi/en, disabled while D4 is off, passed to the engine with D4 and the rule switch (planned, 1.1.0) | Settings Typing pane, `DefaultSettings`, `InputHost/Engine/EngineSettingsMapping.swift` (planned) | U, M (planned: the default, the mapping, the copy, the disabled state) | 1.1.0 typo correction track (planned) |  |
| PRD-R81 | Never-correct list with the keep lists: add with validation, remove, learned at once from the restore key, exported and imported with the settings, cleared by the resets (planned, 1.1.0) | `SettingsStore`, Settings Typing pane (planned) | U, M (planned) | 1.1.0 typo correction track (planned) |  |

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
| QA-R29 | Release cadence, 72 h on beta | process; `scripts/publish-release` beta check, `--p0-hotfix`, `--skip-beta-soak DECISION` (a decision record that cites QA-R29 and names the version); waived for 1.0.0 only, ADR 0507 | D, R (`scripts/tests/run.sh`, `test_scripts.py`) | Pa; release track |  |
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
| QA-R68 | W11 collision corpus and its three adversarial sets in CI with the ENG-R876 and ENG-R877 thresholds; any wrong revision fails; list changes that move a number are reviewed with the list | `Packages/VietnameseEngine/Tests/CollisionCorpusTests` (frozen fixtures, host-mode replay, memory simulation; `Fixtures/README.txt`); `.github/workflows/ci.yml` engine-linux step "W11 collision corpus gate"; `scripts/run-tests.sh` layer `collision`; ADR 0008 | E (`CollisionCorpusTests`, `CollisionMemorySimulationTests`, `PhraseRevisionDepthTests`, `HostReplayTests`, `CorpusFixtureTests`), L | W11-D |  |

## 05-clean-room.md (CLR-R)

| ID | Requirement (short) | Owner module / file | Verification | Workstream | Pa |
|---|---|---|---|---|---|
| CLR-R1 | Do not read other Vietnamese IMEs' source | process | D | all |  |
| CLR-R2 | Do not read other open-source engines' source | process | D | all (engine track especially) |  |
| CLR-R3 | Allowed sources only | process | D | all |  |
| CLR-R4 | Discard code that resembles another IME | process | D | all |  |
| CLR-R5 | Behavioural facts allowed, code not | process | D | all |  |
| CLR-R6 | Third-party word lists permissive; own lists under the engine licence (ENG-R109) | engine data | D, L | engine data track |  |
| CLR-R7 | Original or licensed assets with recorded source | `App/Resources/Assets.xcassets`, site | D | W1-G; site track |  |
| CLR-R8 | New, empty memory project | process (a new memory project, empty at the start) | D | done |  |
| CLR-R9 | No research folder in the repository | process | D | all |  |
| CLR-R10 | Clean-room notice in agent instructions | `CLAUDE.md`, `AGENTS.md` | D | done |  |
| CLR-R11 | SPDX header on every source file | all sources | L | all; CI track (lint) |  |
| CLR-R12 | Keep git history intact | process | D | all |  |
| CLR-R13 | Similarity review before first public release and 1.0 | `docs/provenance/` | M | Pa (reviewer allowed to see other code) | **Pa** |
| CLR-R14 | Contributors confirm clean-room rules | `CONTRIBUTING.md`, PR template | D | docs track |  |
