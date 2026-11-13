// SPDX-License-Identifier: GPL-3.0-or-later
//
// The objects the tap, the inject worker, the ax thread and the main thread share for the whole life of the
// process (ARCHITECTURE.md sections 3 and 6): the five snapshot cells, the job queue and its feedback, the
// marker, the focus generation, the tap outboxes and the callback watchdog. Built once by
// `InputHostController`; a recreated tap reuses all of them (PLT-R731). Workstream W2-A.

internal import AppModel
internal import Diagnostics
internal import Foundation
internal import Injection
internal import RealtimeSupport

/// Fan-in for the `WakeSignal`s whose target is created after the signal (the tap watchdog of the current
/// session, the controller itself). `fire()` runs on the signal's queue, never on the tap thread.
final class SignalRelay: Sendable {
    private let target = Mutex<(@Sendable () -> Void)?>(nil)

    func connect(_ handler: (@Sendable () -> Void)?) { target.withLock { $0 = handler } }
    func fire() { target.withLock { $0 }?() }
}

/// Capacities of the tap outboxes. The tap drops a notice when a ring is full (it never blocks, PLT-R305),
/// so they hold several seconds of fast typing.
enum HostChannelCapacity {
    static let mainNotices = 512
    static let axNotices = 256
}

/// Shared tap-side objects. Everything here is `Sendable`; the tap-facing members are lock-free.
final class HostChannels: Sendable {
    let snapshots: TapSnapshots
    let workerSignal = WorkerSignal()
    let queue: JobQueue
    let feedback = WorkerFeedback()
    /// Per-launch random 40-bit tag (PLT-R321).
    let marker: EventMarker
    let focusGeneration = CurrentFocusGeneration()
    let outbox: TapOutbox
    let callbackWatchdog: CallbackWatchdog
    /// Wired by the controller: main outbox drain, ax inbox drain, watchdog arming. The main outbox signal fires
    /// on `mainSignalQueue` (the main queue in production, ADR 0303), so tap notices (the PLT-R330 re-enable, the
    /// switch HUD) never wait behind utility work; its relay hops to the main actor through the controller's
    /// `MainThreadHop`, which runs inline when already on main. The ax and activity signals fire on the utility
    /// queue (ADR 0303: the ax relay hops to the ax run loop).
    let mainRelay = SignalRelay()
    let axRelay = SignalRelay()
    let activityRelay = SignalRelay()

    init(initial: InitialSnapshots, marker: EventMarker, signalQueue: DispatchQueue, mainSignalQueue: DispatchQueue) {
        let epoch = ReaderEpoch()
        snapshots = TapSnapshots(
            epoch: epoch, settings: SnapshotCell(initial.settings, epoch: epoch),
            focus: SnapshotCell(initial.focus, epoch: epoch),
            inputSource: SnapshotCell(initial.inputSource, epoch: epoch),
            secureInput: SnapshotCell(initial.secureInput, epoch: epoch),
            lifecycle: SnapshotCell(initial.lifecycle, epoch: epoch))
        queue = JobQueue(signal: workerSignal)
        self.marker = marker
        let mainRelay = self.mainRelay
        let axRelay = self.axRelay
        let activityRelay = self.activityRelay
        outbox = TapOutbox(
            toMain: SPSCRing(capacity: HostChannelCapacity.mainNotices),
            toAX: SPSCRing(capacity: HostChannelCapacity.axNotices),
            mainSignal: WakeSignal(queue: mainSignalQueue) { mainRelay.fire() },
            axSignal: WakeSignal(queue: signalQueue) { axRelay.fire() })
        // PLT-R803: the watchdog's 250 ms check is armed only by the first callback after 2 s idle.
        callbackWatchdog = CallbackWatchdog(activitySignal: WakeSignal(queue: signalQueue) { activityRelay.fire() })
        focusGeneration.store(initial.focus.generation)
    }

    /// Stops the dispatch sources so no handler runs after the host stopped.
    func cancelSignals() {
        mainRelay.connect(nil)
        axRelay.connect(nil)
        activityRelay.connect(nil)
        outbox.mainSignal.cancel()
        outbox.axSignal.cancel()
    }
}

/// Values the cells hold before the producers publish (the tap is never created before the first settings
/// snapshot, see `InputHostController.start`).
struct InitialSnapshots: Sendable {
    var settings: TapSettingsSnapshot
    var focus: FocusSnapshot
    var inputSource: InputSourceSnapshot
    var secureInput: SecureInputSnapshot
    var lifecycle: LifecycleSnapshot

    /// The default decision of an empty rules document: `backspaceReplace` with the shipped parameter defaults,
    /// no text-focus gating (PLT-R386 `never` until a rule says otherwise).
    static let defaultDecision = HostDecision(
        plan: InjectionPlan(strategy: .backspaceReplace, parameters: .defaults, fallback: [.passThrough]),
        variant: .default, requireTextFocus: .never, verifyReentry: .whenReadable, restoreHotkeyEnabled: true,
        rule: nil, source: .default, specificity: 0)

    static func make(source: InputSourceInfo, settings: TapSettingsSnapshot, globalMode: TypingMode)
        -> InitialSnapshots
    {
        InitialSnapshots(
            settings: settings,
            focus: FocusSnapshot(
                generation: FocusGeneration(rawValue: 0), app: nil, field: .unknown, decision: defaultDecision,
                mode: globalMode, modeSource: .globalMode, appliedToggleSequence: 0, fieldHandle: nil,
                changedAt: .zero, pause: nil),
            inputSource: InputSourceSnapshot(generation: 0, source: source, table: nil, boundMode: nil),
            secureInput: .initial,
            lifecycle: LifecycleSnapshot(
                generation: 0, phase: .starting, userDisabled: false, recorderActive: false, globalMode: globalMode))
    }
}
