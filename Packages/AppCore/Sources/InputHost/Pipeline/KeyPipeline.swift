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

/// Per-callback watchdog state (PLT-R306): `enteredAt` written at entry, cleared at exit; the utility watchdog
/// disables the tap if one callback runs longer than 250 ms.
public final class CallbackWatchdog: Sendable {
    public static let callbackLimit: Duration = .milliseconds(250)
    public init(activitySignal: WakeSignal) { unimplemented() }
    @inline(__always) public func enter(at now: MonotonicInstant) { unimplemented() }
    @inline(__always) public func exit() { unimplemented() }
    /// Utility queue.
    public func runningCallbackDuration(now: MonotonicInstant) -> UInt64? { unimplemented() }
}

/// Tap-thread pipeline. Generic over the engine factory and the clock, so production code
/// (`KeyPipeline<VietnameseCompositionEngineFactory, MachClock>`) has no existential calls on the hot path and
/// tests drive it with a scripted engine and a manual clock.
public final class KeyPipeline<Factory: CompositionEngineFactory, Clock: MonotonicClock> {
    public init(context: PipelineContext, factory: Factory, clock: Clock) { unimplemented() }

    /// The whole of PLT-R310 for one event. Brackets itself with `ReaderEpoch.enter()/exit()` and
    /// `CallbackWatchdog.enter/exit`.
    public func handle(_ event: RawKeyEvent) -> TapVerdict { unimplemented() }

    /// Outcome of the last physical keyboard event (nil for echoes, mouse and tap-disabled events). Read by
    /// the conservation ledger in tests and by the capture.
    public var lastOutcome: EventOutcome? { unimplemented() }
}

/// Classification of step 7 (pure, tap-safe).
public enum KeyClassifier {
    public static func classify(_ event: RawKeyEvent, table: LayoutTable?) -> KeyClass { unimplemented() }
}

/// Host state per key (2.1), the same pure function the main thread uses for the menu icon.
public enum HostStateResolver {
    /// Precedence: noPermission / failOpen / starting > sessionInactive > userDisabled > secureInput (unless
    /// resumed by key evidence for this generation) > secureField > nonLatinInputSource >
    /// builtInVietnameseSource > passThroughRule > noTextFocus > ready(mode).
    public static func resolve(
        lifecycle: LifecycleSnapshot, secureInput: SecureInputSnapshot, secureResumedGeneration: UInt64?,
        inputSource: InputSourceSnapshot, focus: FocusSnapshot, effectiveMode: TypingMode
    ) -> HostState { unimplemented() }
}
