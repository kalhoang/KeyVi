# 0315. Minimum macOS 12.0 with Intel support

- Status: accepted, 2026-11-13
- Requirements: PLT-R104, PLT-R105, PLT-R106, PLT-R107, PLT-R205, PLT-R304, PLT-R305, PLT-R388, PLT-R704,
  PRD-R8, PRD-R64, QA-R2, QA-R3
- Supersedes: the macOS 15 floor of PLT-R106 and PRD-R8 (and its "no API newer than macOS 14 outside
  `Synchronization`" rule)

## Context

Pa decided on 2026-11-13 (answer Q6 to the review checklist): support macOS as old as possible, and Intel
Macs. The oldest system the toolchain and the only dependency allow is **macOS 12.0 Monterey**: Sparkle 2.10.1
declares `LSMinimumSystemVersion` 12.0 (ADR 0304) and the Xcode 27 macOS SDK has `MinimumDeploymentTarget`
12.0. The code targeted macOS 15 (`project.yml`, AppCore `.macOS(.v15)`, engine `.macOS(.v13)`).

Measured before the change (AppCore and App sources): 56 files imported `Synchronization` (`Mutex` 73 uses,
`Atomic` 51, macOS 15), about 186 uses of `Duration` plus `ContinuousClock` (macOS 13), 9 `@Observable` models
and `withObservationTracking` (macOS 14), `SMAppService` (macOS 13), `NSApp.activate()` (macOS 14),
`Task.sleep(for:)`, Swift `Regex`, `URL.appending(path:)` and `TimeZone.gmt` (macOS 13), an actor whose
executor was a `DispatchSerialQueue` (macOS 14) entered with `assumeIsolated` from plain dispatch blocks
(reliable only from macOS 15, `checkIsolated`), and a few SwiftUI modifiers (`contextMenu(forSelectionType:)`,
`TextField(axis:)`, `lineLimit(_:reservesSpace:)`, `onChange(of:initial:)`, `focusEffectDisabled()`,
`keyboardShortcut` with an optional shortcut).

## Decision

### Deployment target

`MACOSX_DEPLOYMENT_TARGET` 12.0 for every Xcode target (App, UpdaterTests, TestHost, SpikeIMK), `.macOS(.v12)`
for AppCore, VietnameseEngine and VietnameseEngineFuzz. The universal binary stays (PLT-R105): Release builds
`$(ARCHS_STANDARD)` (arm64 and x86_64). An API newer than 12.0 is used only behind `if #available` with a
macOS 12 fallback; there are no scattered availability attributes on our own types.

### Synchronization replacements (RealtimeSupport, no new dependency)

PLT-R104 allows no third-party runtime code, so RealtimeSupport provides the primitives itself:

- `CRealtimeSupport` (new C target in AppCore): `static inline`, always-inlined wrappers of the compiler's
  `__atomic` builtins for 8-, 32- and 64-bit words (load, store, exchange, strong compare-exchange with the
  failure order derived from the success order, fetch-add, fetch-sub). Static asserts check that every width
  is lock-free on both slices and that pointers fit 64 bits.
- `Atomic<Value>` and `UnsafeAtomic<Value>` with the call shape of `Synchronization.Atomic`
  (`load(ordering:)`, `store(_:ordering:)`, `exchange`, `compareExchange(expected:desired:ordering:)`,
  `wrappingAdd`, `wrappingSubtract`, `add`, `subtract`, `max`, `min`) and the same ordering names
  (`.relaxed`, `.acquiring`, `.releasing`, `.acquiringAndReleasing`, `.sequentiallyConsistent`). Values:
  `Int`, `UInt`, 8/32/64-bit integers, `Bool`, `Unmanaged`. Call sites only changed their import line.
- `Mutex<Value>` with `withLock` (typed throws, `sending` value) on `os_unfair_lock`, which is what
  `Synchronization.Mutex` uses on Darwin: no allocation after `init`, priority donation, recursion traps.
- Differences, deliberate: both are **copyable handles** to storage allocated once at `init` (a
  `ManagedBuffer`, so the word and the lock never move), not `~Copyable` values. Noncopyable generic types
  depend on runtime support that macOS 12 does not have, and handles keep every call site unchanged. Copies
  share the word or lock. `AtomicUInt64Array` and the test allocation counter use `UnsafeAtomic` on raw
  words, because an array of handles would allocate per slot. The two `~Copyable` private state structs kept
  in a `Mutex` became plain structs.
- Hot path (PLT-R304, PLT-R305, PLT-R388): unchanged rules. Every atomic is created when its owner is
  created; after that no operation allocates, locks or blocks; the tap thread still never takes a `Mutex`.
  The operations are `@inlinable` and the C wrappers always inline, so release builds compile them to the
  single instruction (or LL/SC loop) the ordering asks for. Debug builds keep a few calls per operation; the
  debug micro-benchmarks (`QueueBenchmarkTests`, bound 5 µs per operation) still pass.

### Time

`TimeSpan` (signed nanoseconds in an `Int64`) replaces `Duration`, with the same value spelling at call sites
(`.milliseconds(150)`, `.seconds(2)`, `.zero`, comparisons, `+`, `-`, `*`, `/`). Factories and arithmetic
saturate instead of trapping (about 292 years either way), so a configuration value cannot crash the input
method; `unsignedNanoseconds`, `dispatchInterval` and `inSeconds` replace the ad hoc `components`
conversions. `ManualClock`, `ManualScheduler` and `TimerScheduler` keep their semantics with `TimeSpan`.
Tests measure with `MachClock` and `MonotonicInstant.duration(since:)` instead of `ContinuousClock`;
`Task.sleep(nanoseconds:)` replaces `Task.sleep(for:)`.

### Settings store executor

`SettingsStore` runs on its own `QueueExecutor` (a `SerialExecutor` that runs each job on the utility serial
queue through `enqueue(_: UnownedJob)`, available since macOS 10.15) on every system, instead of the
`DispatchSerialQueue` executor that exists only from macOS 14. Debounce timers enter the store with
`withQueueIsolation`, which checks `dispatchPrecondition(.onQueue(queue))` and then runs the isolated body,
instead of `assumeIsolated`, which cannot recognise a custom executor from a plain dispatch block before
macOS 15. One code path on every system, so the whole SettingsStore suite exercises the macOS 12 behaviour.
`DispatchSerialQueue(label:)` (macOS 14) became `DispatchQueue(label:)`.

### Observation

The nine `@Observable` models became `ObservableObject` with `@Published` stored properties; views hold them
as `@ObservedObject` (including child views that used to hold a plain `let`, because SwiftUI does not
re-render those on a change). A model that owns another observable object (the interface language, the
hotkey recorder) re-publishes its changes with `relayChanges(of:)`, which keeps the `@Observable` behaviour
of nested reads. AppKit controllers that used `withObservationTracking` use `afterChange`, which runs on the
next main-queue turn after `objectWillChange`, when the new value is in place. Window titles keep their
observation as an associated object of the window. `ObservableObject` publishes whole-object changes, so text
the user types in Settings (the practice field and the two word-list add fields) lives in a separate
`SettingsTextDrafts` object observed only by those fields; a keystroke re-renders the field, not every pane
that observes the window model.

### AppKit and SwiftUI fallbacks

- `NSApp.bringToFront()`: `activate()` from macOS 14, `activate(ignoringOtherApps:)` before.
- Practice fields: `TextField(growing:placeholder:)` and `reservingLines(_:)` grow to several lines from
  macOS 13 and stay single-line on macOS 12. The helpers live in `App/Sources/Composition/SwiftUICompatibility
  .swift`, so views keep plain controls that the label-and-hint audit recognises.
- The Apps and Macros tables add their row context menu and double-click from macOS 13; on macOS 12 the Actions
  column and the footer offer the same commands.
- `systemFocusEffectDisabled()` (macOS 14; earlier systems also draw their own focus ring),
  `keyboardShortcut(_:when:)` (an optional shortcut needs 12.3), `onChange(of:) { _ in }`.
- `TimeZone(secondsFromGMT: 0)` instead of `.gmt`, `appendingPathComponent` instead of `appending(path:)`, a
  hand parser instead of `Regex` for `YYYY-MM-DD`, `Array.starts(with:)` instead of `String.contains` without
  Foundation (VietnameseEngineTesting).
- `isolated deinit` stays: for main-actor classes the compiler emits a back-deployed path (it runs the body
  directly on the main thread and hops otherwise) and weak-links `swift_task_deinitOnExecutor`.

### Login items on macOS 12

`SMAppServiceLoginItem` reports the new status `unavailable` below macOS 13, `register()` and `unregister()`
throw `LoginItemUnavailable`, and `openSystemSettings()` opens the macOS 12 `loginItems` deep link (System
Preferences > Users & Groups). The General pane disables the toggle and shows
`settings.general.openAtLogin.manual` ("Trên macOS 12, ... Hãy mở <System Preferences> > <Users & Groups> >
<Login Items>, bấm nút cộng (+) rồi chọn ... trong thư mục Ứng dụng.") with a "Mở <System Preferences>" button;
onboarding's last screen shows `onboarding.done.openAtLoginManual` instead of the checkbox. Pane names in that
copy come from SystemPanes.json in the macOS language (PRD-R64). Nothing fails silently.

### System Preferences on macOS 12 (PLT-R704, PRD-R64)

`SystemPanes.json` has four entries: 12.x (System Preferences: "Security & Privacy > Privacy", Keyboard's "Text" tab,
"Users & Groups" > "Login Items", anchors `com.apple.preference.security?Privacy_Accessibility`,
`...?Privacy_ListenEvent`, `com.apple.preference.keyboard`, `com.apple.preference.keyboard?InputSources`,
`com.apple.preferences.users`), 13.0 to 14.99 (System Settings, Login Items under General), 15.0 to 26.99
and 27 or later (Login Items & Extensions). `SystemPaneNames` gained `usersGroups` and `loginItems`. The three
onboarding VoiceOver hints that named "System Settings" now say "the macOS settings", because the button
titles already name the right app from the table. On macOS 12 the 12.x `privacySecurity` value carries the
Privacy tab too, so the permission instruction reads "System Preferences > Security & Privacy > Privacy >
Accessibility" (PLT-R701). The General pane's macOS 12 login item button takes the System Preferences name from
the table as a format argument ("Mở %@"), so it matches the note above it, and its VoiceOver hint names no
pane. Every Vietnamese name and every macOS 12 to 14 deep link is VERIFY on a real system (the `_verify` notes
in the file).

### Verification

- Every target builds unsigned for Debug, Release (universal) and Integration with deployment target 12.0;
  `lipo -archs` shows `x86_64 arm64` and `otool -l` shows `minos 12.0` for the app, TestHost and SpikeIMK.
- Swift reports unguarded uses of newer APIs as errors at this deployment target, and the build has no
  availability warnings.
- Linked symbols: every strong (non-weak) import of the app, TestHost and SpikeIMK binaries, both slices, is
  exported by the macOS 12.0 SDK's `.tbd` files. The check (`nm -m -u` per slice against the symbol lists of
  the 12.0 SDK) was run by hand for this change with a downloaded MacOSX12.0.sdk; symbols newer than 12.0
  appear only as weak imports (back-deployed or availability-guarded).
- CI (`ci.yml`, job `macos-x86_64`): the AppCore suite is built for the x86_64 slice
  (`swift build --arch x86_64 --build-tests`) and every test bundle runs under Rosetta 2 on the Apple-silicon
  runner with `arch -x86_64 xcrun xctest <bundle>`. `swift test --arch x86_64` cannot do it: the SwiftPM test
  helpers of Xcode 27 are arm64-only and cannot load x86_64 bundles, while `xctest` is universal, runs XCTest
  and Swift Testing tests and exits non-zero on a failure. The queue micro-benchmarks skip themselves under
  translation, as they do under sanitizers; every other test runs.
- CI (`ci.yml`, job `macos-app`): after the universal Debug build, both slices are verified with
  `lipo -verify_arch` and `minos 12.0` with `otool -l`, and `LSMinimumSystemVersion` must be 12.0.

### macOS 12 smoke test

GitHub hosts no macOS 12 runner. Pa approved a tart VM lab on Pa's Mac on 2026-11-13 (answer S6/Q12); the lab is
described in [docs/runbooks/vm-test-lab.md](../runbooks/vm-test-lab.md).

1. tart 2.41.1 (Cirrus Labs, Apple Virtualization framework; macOS 12 is the oldest guest it runs on Apple
   silicon) lives at `/Volumes/Data/tart/tart.app` with `TART_HOME=/Volumes/Data/tart/home`. The macOS 12 guest
   is `keyvi-monterey` from `ghcr.io/cirruslabs/macos-monterey-vanilla:12.7.6`, pinned by digest
   `sha256:4bc904cf8f2447dfa6e6fb9a5eb70eba14196dd0f4236d30fc92aff9c2391842` (macOS 12.7.6, 21H1320).
2. `scripts/vm/smoke-macos12.sh` builds the universal Release app (ad-hoc signed, hardened runtime off for that
   build only, see below) or takes `--app`, checks both slices and `minos 12.0` on the host, and in a throwaway
   clone of the VM: verifies the signature, `lipo -archs` and `minos` per slice, installs Rosetta when missing,
   installs the app into `/Applications`, launches the arm64 slice through LaunchServices and the x86_64 slice
   with `arch -x86_64` under Rosetta, and requires each process to stay alive for 20 s with `Sparkle.framework`
   mapped, no dyld or missing-symbol error and no crash report; it collects the unified log of the app's
   subsystem and the crash reports, then quits the app and deletes the clone. The app never runs on the host.
3. **Result, 2026-11-13: PASS** (run `20261113T144106Z-macos12`, commit `d9976fe`): arm64 natively and x86_64
   under Rosetta each stayed up for 20 s on macOS 12.7.6; the app logged `lifecycle.launched` from its own
   subsystem in both, asked `tccd` for Accessibility as expected, and wrote nothing to standard error and no
   crash report. The deployment target, the RealtimeSupport primitives, the `TimeSpan` and observation
   replacements and the weak imports therefore load and start on macOS 12 for both slices.
4. Found on the way (first run, `20261113T142257Z-macos12`): with an **ad-hoc** signature and the hardened
   runtime, dyld refused the embedded Sparkle framework under Rosetta (`mapped file has no Team ID and is not a
   platform binary`): library validation needs a Team ID. The smoke build therefore turns the hardened runtime
   off. This is no product defect: the Developer ID build signs the app and Sparkle with one Team ID and keeps
   the hardened runtime (PLT-R750). Also, macOS 12's `open` has no `--arch` option.
5. Still manual per release candidate (release checklist): run `scripts/vm/smoke-macos12.sh --app <the
   notarized app>` (the hardened, Team ID signed build, which also covers library validation on macOS 12), then in
   the VM window grant Accessibility, run the onboarding to the end, type the T1 smoke words in TestHost (Telex
   and VNI), open Settings > General and check the Login Items note and button, and check for updates against
   the beta appcast. An Intel Mac (macOS 26 or earlier) repeats these steps when one is available (VERIFY: no
   Intel hardware on hand today); Rosetta covers the x86_64 slice meanwhile.

## Consequences

- Macs that stop at macOS 12, 13 or 14 can run the app; macOS 13 and 14 are covered by the floor and by
  macOS 15 tests but not tested separately (PLT-R107).
- RealtimeSupport owns concurrency primitives that the standard library would otherwise provide; when the
  floor reaches macOS 15 they can be replaced by `Synchronization` with an import change, and `TimeSpan` by
  `Duration` at 13.
- Swift Testing test targets may be built by SwiftPM with a higher deployment target than the library targets;
  the library and app availability is enforced by the 12.0 builds, not by the tests.
- The engine benchmark executable (`Benchmarks/EngineBenchmark/Measurement.swift`, outside this workstream) uses
  `ContinuousClock` and `Duration`; it needs the matching change from the engine workstream before
  `swift build` of the whole engine package passes at macOS 12. Engine tests already build (test targets use
  macOS 14), and ENG-R1201 is updated there too.
