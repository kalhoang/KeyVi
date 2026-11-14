// SPDX-License-Identifier: GPL-3.0-or-later
//
// Field readback for the dev recorder (PLT-R904A, ADR 0007): what the focused field really shows before the caret
// (at most 64 UTF-16 units) and the selection, next to what KeyVi believes it typed. Debug configuration only. Runs
// on the recorder's attention queue, never on the tap: about 300 ms after a Backspace that edited or a committed
// word (debounced, at most one read per 300 ms) and at once for a marker. Observer rule: the recorder must not
// change what KeyVi does or what the app sees, so it reads only where the app's compat rule lets KeyVi rely on
// accessibility (never under `requireTextFocus: never`, as for `electron.default`), never sets
// AXEnhancedUserInterface or AXManualAccessibility, and never reads a secure field or while secure input is on.

#if DEV_RECORDER
public import Diagnostics
public import Injection
public import RealtimeSupport
internal import AppModel

public final class DevReadback: Sendable {
    /// Delay after a Backspace edit or a commit, so the read sees the settled field.
    public static let delay: TimeSpan = .milliseconds(300)
    /// At most one read per this interval (the app answers every AX request on its main thread).
    public static let minimumInterval: TimeSpan = .milliseconds(300)
    /// A trigger never waits longer than this behind later triggers.
    public static let maximumDelay: TimeSpan = .seconds(1)
    /// Short AX messaging timeout for each of the two reads.
    public static let axTimeout: TimeSpan = .milliseconds(50)
    /// PLT-R343's bound on any read.
    public static let maximumUnits = 64

    private struct State {
        var pending: Set<DevReadbackReason> = []
        var firstPendingAt: MonotonicInstant?
        var timer: (any ScheduledTimer)?
        var lastReadAt: MonotonicInstant?
    }

    private let recorder: DevRecorder
    private let fieldAccess: any FocusedFieldAccess
    private let focus: @Sendable () -> FocusSnapshot
    private let secureInput: @Sendable () -> SecureInputSnapshot
    private let clock: any MonotonicClock
    private let scheduler: any TimerScheduler
    private let state = Mutex(State())

    public init(
        recorder: DevRecorder, fieldAccess: any FocusedFieldAccess, focus: @escaping @Sendable () -> FocusSnapshot,
        secureInput: @escaping @Sendable () -> SecureInputSnapshot, clock: any MonotonicClock,
        scheduler: any TimerScheduler
    ) {
        self.recorder = recorder
        self.fieldAccess = fieldAccess
        self.focus = focus
        self.secureInput = secureInput
        self.clock = clock
        self.scheduler = scheduler
    }

    /// Attention from the recorder: a marker reads as soon as the rate limit allows, other reasons 300 ms after the
    /// latest trigger (but at most 1 s after the first).
    public func handle(_ reasons: Set<DevReadbackReason>) {
        guard !reasons.isEmpty else { return }
        let now = clock.now()
        state.withLock { state in
            state.pending.formUnion(reasons)
            let first = state.firstPendingAt ?? now
            state.firstPendingAt = first
            var due = reasons.contains(.marker) ? now : now.advanced(byMicroseconds: Self.micros(Self.delay))
            let latest = first.advanced(byMicroseconds: Self.micros(Self.maximumDelay))
            if due > latest { due = latest }
            if let last = state.lastReadAt {
                let allowed = last.advanced(byMicroseconds: Self.micros(Self.minimumInterval))
                if due < allowed { due = allowed }
            }
            state.timer?.cancel()
            let delay = due > now ? due.duration(since: now) : .zero
            state.timer = scheduler.schedule(after: delay, leeway: .milliseconds(10)) { [weak self] in self?.fire() }
        }
    }

    /// One read now, recorded with the most specific pending reason.
    private func fire() {
        let reasons = state.withLock { state -> Set<DevReadbackReason> in
            defer {
                state.pending = []
                state.firstPendingAt = nil
                state.timer = nil
                state.lastReadAt = clock.now()
            }
            return state.pending
        }
        guard let reason = [DevReadbackReason.marker, .backspaceEdit, .commit].first(where: reasons.contains),
            recorder.isActive
        else { return }
        recorder.note(.readback(read(reason)))
    }

    /// The readback itself, or why it was skipped (tested directly).
    func read(_ reason: DevReadbackReason) -> DevReadbackRecord {
        let snapshot = focus()
        let at = clock.now()
        func record(_ status: DevReadbackStatus, text: String? = nil, selection: TextRange? = nil) -> DevReadbackRecord
        {
            DevReadbackRecord(
                reason: reason, status: status, textBeforeCaret: text, selectionLocation: selection?.location,
                selectionLength: selection?.length, bundle: snapshot.app?.bundle.rawValue,
                rule: snapshot.decision.rule?.rawValue, at: at)
        }
        if snapshot.field.secure || snapshot.pause?.code == .secureField || secureInput().enabled {
            return record(.skippedSecure)
        }
        if snapshot.decision.requireTextFocus == .never { return record(.skippedRule) }
        guard snapshot.field.axAvailability == .available else { return record(.unavailable) }
        guard let field = snapshot.fieldHandle else { return record(.skippedNoField) }
        let selection: TextRange
        switch fieldAccess.selectedRange(field, timeout: Self.axTimeout) {
        case .success(let range): selection = range
        case .timedOut: return record(.timedOut)
        case .unavailable: return record(.unavailable)
        case .failed: return record(.failed)
        }
        let count = min(Self.maximumUnits, max(0, selection.location))
        guard count > 0 else { return record(.ok, text: "", selection: selection) }
        let range = TextRange(location: selection.location - count, length: count)
        switch fieldAccess.text(field, in: range, timeout: Self.axTimeout) {
        case .success(let text): return record(.ok, text: text, selection: selection)
        case .timedOut: return record(.timedOut, selection: selection)
        case .unavailable: return record(.unavailable, selection: selection)
        case .failed: return record(.failed, selection: selection)
        }
    }

    private static func micros(_ span: TimeSpan) -> UInt64 { span.unsignedNanoseconds / 1_000 }
}
#endif
