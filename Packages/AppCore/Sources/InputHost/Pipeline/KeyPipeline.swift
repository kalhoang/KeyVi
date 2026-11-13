// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The decision pipeline (PLT-R310) with hold/replay and conservation (PLT-R311-R317), echo (PLT-R323) and the
// secure-input resume rule (PLT-R398B). Runs only on the tap thread; not Sendable on purpose.

public import AppModel
public import Diagnostics
public import Injection
public import RealtimeSupport

/// Shared objects the pipeline reads or pushes to. Every member is Sendable and every tap-side operation on
/// it is an atomic load/store or a lock-free push.
public struct PipelineContext: Sendable {
    public var snapshots: TapSnapshots
    public var queue: JobQueue
    public var feedback: WorkerFeedback
    public var echo: EchoTracker
    public var marker: EventMarker
    public var outbox: TapOutbox
    public var metrics: PlatformMetrics
    public var tapLog: TapLogRing
    public var capture: CaptureController?
    public var watchdog: CallbackWatchdog

    public init(
        snapshots: TapSnapshots, queue: JobQueue, feedback: WorkerFeedback, echo: EchoTracker, marker: EventMarker,
        outbox: TapOutbox, metrics: PlatformMetrics, tapLog: TapLogRing, capture: CaptureController?,
        watchdog: CallbackWatchdog
    ) {
        self.snapshots = snapshots
        self.queue = queue
        self.feedback = feedback
        self.echo = echo
        self.marker = marker
        self.outbox = outbox
        self.metrics = metrics
        self.tapLog = tapLog
        self.capture = capture
        self.watchdog = watchdog
    }
}

/// Tap-thread pipeline. Generic over the engine factory and the clock, so production code
/// (`KeyPipeline<VietnameseCompositionEngineFactory, MachClock>`) has no existential calls on the hot path and
/// tests drive it with a scripted engine and a manual clock. The hotkey recogniser type comes from the factory
/// (`CompositionEngineFactory.Hotkeys`, `HotkeyRecognizer` by default).
///
/// Created on the tap thread by `TapThread`'s handler factory and never shared (`TapEventHandler`, ADR 0313);
/// `init` reads the snapshots once, so it must run on the tap thread too. At callback entry, after step 1, it
/// calls `EchoTracker.settle(now:)`; `.postingBroken` or `WorkerFeedback.isPostingBroken` means fail open within
/// this callback (PLT-R730). Holding while busy uses `JobQueue.inFlight`, which counts a job until its echo is
/// seen (ADR 0311). A `scrollWheel` event only feeds `HotkeyRecognizer.handle(.scroll)` and passes (PLT-R301).
/// Steady state allocates nothing outside the engine call (PLT-R305; `PipelineAllocationTests`).
public final class KeyPipeline<Factory: CompositionEngineFactory, Clock: MonotonicClock>: TapEventHandler {
    let context: PipelineContext
    let factory: Factory
    let clock: Clock
    let consumedKeys = ConsumedKeyTable()
    var engine: Factory.Engine
    /// The engine was fed since its last reset or creation; a reset of a clean engine is skipped.
    var engineDirty = false
    var hotkeys: Factory.Hotkeys
    var seen: ObservedState
    /// Sequence of the tap's last VI/EN toggle. Seeded from the focus snapshot and kept above every sequence
    /// the ax thread applied, so a recreated tap's toggles still outrank stale snapshots (contracts.md 10.4,
    /// PLT-R731).
    var toggleSequence: UInt64 = 0
    var toggleOverride: ToggleOverride?
    var keyState = KeyState()
    var outcome: EventOutcome?
    /// The last job pushed was a `BoundaryJob` (consecutive boundaries need one job).
    var lastPushWasBoundary = false

    public init(context: PipelineContext, factory: Factory, clock: Clock) {
        self.context = context
        self.factory = factory
        self.clock = clock
        let snapshots = context.snapshots
        snapshots.epoch.enter()
        (engine, hotkeys, seen, toggleSequence) = snapshots.readAll {
            settings, focus, inputSource, secureInput, lifecycle in
            let observed = ObservedState(
                settingsGeneration: settings.generation, focus: FocusIdentity(focus),
                engineVariant: focus.decision.variant, inputSourceGeneration: inputSource.generation,
                secureGeneration: secureInput.generation, lifecycleGeneration: lifecycle.generation,
                resetCount: context.feedback.compositionResetCount, stateCode: nil, secureResumedGeneration: nil,
                postingBroken: context.feedback.isPostingBroken,
                pasteKeyCode: inputSource.table?.keyCode(producing: "v"), engineRevision: settings.engines.revision)
            return (
                factory.makeEngine(for: focus.decision.variant, settings: settings),
                Factory.Hotkeys(toggle: settings.toggleHotkey, restore: settings.restoreHotkey), observed,
                focus.appliedToggleSequence
            )
        }
        snapshots.epoch.exit()
    }

    /// The whole of PLT-R310 for one event. Brackets itself with `ReaderEpoch.enter()/exit()` and
    /// `CallbackWatchdog.enter/exit`.
    public func handle(_ event: RawKeyEvent) -> TapVerdict {
        let epoch = context.snapshots.epoch
        epoch.enter()
        let start = clock.now()
        context.watchdog.enter(at: start)
        let (verdict, isProbe) = process(event, now: start)
        // T1 (PLT-R801); latency-probe events stay out of user metrics (PLT-R810).
        if !isProbe { context.metrics.callbackDuration.record(nanoseconds: clock.now().nanoseconds(since: start)) }
        context.watchdog.exit()
        epoch.exit()
        return verdict
    }

    /// Outcome of the last physical keyboard event (nil for echoes, mouse and tap-disabled events). Read by
    /// the conservation ledger in tests and by the capture.
    public var lastOutcome: EventOutcome? { outcome }
}

/// Classification of step 7 (pure, tap-safe).
public enum KeyClassifier {
    public static func classify(_ event: RawKeyEvent, table: LayoutTable?) -> KeyClass {
        KeyClassification.classify(event, table: table)
    }
}

/// Host state per key (2.1), the same pure function the main thread uses for the menu icon.
public enum HostStateResolver {
    /// Precedence: noPermission / failOpen / starting > sessionInactive > diagnosticsTest > userDisabled >
    /// secureInput (unless resumed by key evidence for this generation) > secureField > builtInVietnameseSource >
    /// nonLatinInputSource > passThroughRule > noTextFocus (focus pause or PLT-R386 gating) > ready(mode).
    public static func resolve(
        lifecycle: LifecycleSnapshot, secureInput: SecureInputSnapshot, secureResumedGeneration: UInt64?,
        inputSource: InputSourceSnapshot, focus: FocusSnapshot, effectiveMode: TypingMode
    ) -> HostState {
        HostStateResolution.resolve(
            lifecycle: lifecycle, secureInput: secureInput, secureResumedGeneration: secureResumedGeneration,
            inputSource: inputSource, focus: focus, effectiveMode: effectiveMode)
    }
}
