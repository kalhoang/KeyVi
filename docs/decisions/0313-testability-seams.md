# 0313. Testability seams provided by the skeleton

- Status: accepted, 2026-11-13
- Requirements: QA-R1 (layer 4), QA-R2, QA-R3, PLT-R101, PLT-R203, PLT-R301, PLT-R303, PLT-R306, PLT-R332,
  PLT-R721, PLT-R803
- Context: wave-1 workstreams run in parallel against the skeleton. The independent design review found that
  three of them declared "skeleton only" but needed fakes another workstream would implement
  (`SimulatedTextField`, `FakeEventPoster`, `FakeDecisionResolver`), that host services pinned `MachClock` and
  `DispatchQueue` so "fake clock" acceptance tests could not run deterministically, that `EventTapFactory`
  leaked `CFMachPort`, and that the contract did not say how the non-Sendable `KeyPipeline` reaches the tap
  thread under Swift 6. Checking further: the pipeline (W1-F1) calls `JobQueue`, `EchoTracker`,
  `WorkerFeedback`, `EventMarker` (W1-D) and records into `PlatformMetrics` and `TapLogRing` (W1-A) on every
  event, so its tests would trap on `unimplemented()` too.

## Decision

1. **Seams implemented in the skeleton, with tests** (files stay with their owning workstream, which may
   optimise but must keep behaviour and keep the `*SeamTests.swift` green):
   - Injection: `JobQueue`, `EchoExpectation`, `InFlightPolicy`, `WorkerFeedback`, `EchoTracker`,
     `EventMarker`, `CurrentFocusGeneration`, `PasteboardTypeName` (W1-D).
   - Diagnostics: `Log2Histogram`, `HistogramSnapshot.percentile`, `AtomicCounter`, `PlatformMetrics`,
     `PerBundleHistograms`, `HealthEventLog` (in memory), `TapLogRing` (W1-A).
   - RealtimeSupport: `TimerScheduler`, `ScheduledTimer`, `DispatchTimerScheduler`, `AtomicUInt64Array` (W1-A).
   - InputHost: `CallbackWatchdog`, `TapEventMask.cgMask`, `TapSnapshots.reclaimAll` (W1-F2).
   - ShellCore: `Brand.from` (the App reads it at launch) (W1-G).
2. **Shared fakes implemented in the skeleton.** Integrator-owned and frozen in wave 1 (`Fakes/Common`):
   `SimulatedTextField` (all five behaviours), `ManualScheduler`, `RecordingLogger`, plus the existing
   `InMemoryFileSystem`, `ManualClock`, `FixedWallClock`, `InMemoryKeyValueStore`. Owned by an area but
   implemented now: `FakeEventPoster` (`.delivering`, `.silentlyDropping`, `.failingCreation`),
   `FakeFocusedFieldAccess`, `FakePasteboard` (W1-D); `FakeDecisionResolver` (W1-C); `FakeEventTapFactory` and
   `FakeEventTapHandle` (W1-F2, moved out of the host fakes).
3. **Time.** Every host service takes `any MonotonicClock` and, if it has periodic or delayed work, an
   `any TimerScheduler` (`PermissionMonitor`, `SecureInputMonitor`, `TapWatchdog`, lifecycle backoff via
   `InputHostDependencies.scheduler`). Production uses `DispatchTimerScheduler(queue: utilityQueue)`; tests use
   `ManualScheduler`, whose `advance(by:)` fires due timers in order and exposes `repeatingIntervals` for the
   PLT-R803 "nothing faster than 2 s at rest" test. The tap pipeline stays generic over its clock
   (`KeyPipeline<_, MachClock>` in production) because it is the hot path.
4. **Event tap handle.** `EventTapFactory.makeTap` returns `any EventTapHandle` (`install(on:)`,
   `setEnabled`, `isEnabled`, `invalidate`). Production wraps the `CFMachPort`; the fake is pure Swift, so
   `TapThread` and `TapWatchdog` tests never message the WindowServer. `TapControl` is the any-thread surface the
   watchdog and lifecycle use.
5. **Tap-thread confinement under Swift 6.** `TapThread<Handler: TapEventHandler>` takes a `@Sendable`
   factory, calls it inside its thread entry, and stores the non-Sendable handler (the `KeyPipeline`) in that
   thread's state, reached from the C callback's `userInfo`. The handler never leaves the tap thread and no
   per-callback check runs. This and `ThreadConfined` are the two audited escape hatches (ARCHITECTURE.md
   section 3). The Sparkle delegate methods are `nonisolated` and use `MainActor.assumeIsolated` because
   Sparkle calls its delegate on the main thread.
6. **Lifecycle as a value.** The 2.1 state machine is `HostLifecycle` (pure: inputs to effects, timers owned by
   the caller), implemented and tested by W1-F2 without services. `InputHostController` composes the real
   services and performs the effects in wave 2 (W2-A).

## Consequences

- Wave-1 workstreams depend only on the skeleton in fact, not just on paper (workstreams.md).
- The skeleton's seam implementations are small and straightforward; anything performance-sensitive is still
  benchmarked by its owner (W1-A for histograms, W1-D for the queue).
