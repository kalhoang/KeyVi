// SPDX-License-Identifier: GPL-3.0-or-later
//
// Field readback for the dev recorder (PLT-R904A, ADR 0007): what the focused field really shows before the caret
// (at most 64 UTF-16 units) and the selection, next to what KeyVi believes it typed. Debug configuration only. Runs
// on the recorder's attention queue, never on the tap, and only in a typing pause: no key or click down and no edit
// job for `quietPeriod`. The first recorder read 300 ms after a commit, that is while the user typed the next word;
// on 2026-11-14 a WebKit editor lost a key that had gone down a few tens of milliseconds before such a read
// (incidents 1 and 10 of that day's trace). KeyVi itself holds keys while a job touches AX; an observer cannot hold
// keys, so it waits until nothing is being typed. A key that still goes down while a read is in flight is flagged
// on the line (`overlap`), and every read records how long its AX calls took and how long it waited.
// Observer rule: the recorder must not change what KeyVi does or what the app sees, so it reads only where the
// app's compat rule lets KeyVi rely on accessibility (never under `requireTextFocus: never`, as for
// `electron.default`), never sets AXEnhancedUserInterface or AXManualAccessibility, and never reads a secure field
// or while secure input is on. It never shares the inject worker's AX element (a private reference from
// `DevReadbackFieldResolver`, so AX's per-element messaging timeout of the worker stays as the worker set it) and
// never reads beside an edit job: a queued or in-flight job postpones it like a key, and a job starting between its
// AX calls stops it.

#if DEV_RECORDER
public import Diagnostics
public import Injection
public import RealtimeSupport
internal import AppModel

public final class DevReadback: Sendable {
    /// A read starts only after this long without a key or click down and without an edit job. Twice PLT-R382's
    /// 500 ms, the spec's bound of continuous typing: a pause that long is neither between two keys of a word nor
    /// between two words typed in a row (incident 10: 64 to 70 ms between keys, 95 ms from the space to the next
    /// word), and a key the app was still handling has long been delivered. Short enough that most pauses to read
    /// or think still get a read.
    public static let quietPeriod: TimeSpan = .seconds(1)
    /// At most one read per this interval (the app answers every AX request on its main thread).
    public static let minimumInterval: TimeSpan = .milliseconds(300)
    /// Short AX messaging timeout for each AX call.
    public static let axTimeout: TimeSpan = .milliseconds(50)
    /// PLT-R343's bound on any read.
    public static let maximumUnits = 64

    /// What the scheduler knew when it confirmed the pause.
    struct Timing {
        var waitMicroseconds: UInt64?
        var idleMicroseconds: UInt64?
        /// `DevInputActivity.count` at that moment: another count after the AX calls means a key or click went down
        /// while they were in flight.
        var inputCount: UInt64
    }

    private struct State {
        var pending: Set<DevReadbackReason> = []
        var firstPendingAt: MonotonicInstant?
        var timer: (any ScheduledTimer)?
        var lastReadAt: MonotonicInstant?
    }

    /// What the AX calls returned.
    private struct FieldRead {
        var status: DevReadbackStatus
        var text: String?
        var selection: TextRange?
        /// The longest single AX call, in microseconds.
        var longestCall: UInt64 = 0

        init(_ status: DevReadbackStatus, text: String? = nil, selection: TextRange? = nil) {
            self.status = status
            self.text = text
            self.selection = selection
        }
    }

    private let recorder: DevRecorder
    private let fieldAccess: any FocusedFieldAccess
    private let fieldResolver: any DevReadbackFieldResolver
    private let isInjectionIdle: @Sendable () -> Bool
    private let focus: @Sendable () -> FocusSnapshot
    private let secureInput: @Sendable () -> SecureInputSnapshot
    private let clock: any MonotonicClock
    private let scheduler: any TimerScheduler
    private let state = Mutex(State())

    /// `fieldAccess` reads only, through the handles `fieldResolver` returns. `isInjectionIdle`: no edit job queued
    /// or in flight (production: `JobQueue.inFlight == 0`, two atomic loads). The pause comes from the recorder's
    /// `inputActivity`, which the tap and the inject thread keep current.
    public init(
        recorder: DevRecorder, fieldAccess: any FocusedFieldAccess, fieldResolver: any DevReadbackFieldResolver,
        isInjectionIdle: @escaping @Sendable () -> Bool, focus: @escaping @Sendable () -> FocusSnapshot,
        secureInput: @escaping @Sendable () -> SecureInputSnapshot, clock: any MonotonicClock,
        scheduler: any TimerScheduler
    ) {
        self.recorder = recorder
        self.fieldAccess = fieldAccess
        self.fieldResolver = fieldResolver
        self.isInjectionIdle = isInjectionIdle
        self.focus = focus
        self.secureInput = secureInput
        self.clock = clock
        self.scheduler = scheduler
    }

    /// Attention from the recorder (a commit, a Backspace that edited, a marker): one read at the next pause, for
    /// every trigger since the last read.
    public func handle(_ reasons: Set<DevReadbackReason>) {
        guard !reasons.isEmpty else { return }
        let now = clock.now()
        state.withLock { state in
            state.pending.formUnion(reasons)
            if state.firstPendingAt == nil { state.firstPendingAt = now }
            schedule(&state, at: earliestRead(state, activity: recorder.inputActivity, now: now), now: now)
        }
    }

    /// The end of the pause (the last key, click or job plus `quietPeriod`) or of the rate limit, whichever is
    /// later; now when both are over.
    private func earliestRead(_ state: State, activity: DevInputActivity, now: MonotonicInstant) -> MonotonicInstant {
        var due = now
        if let latest = activity.latest {
            due = max(due, latest.advanced(byMicroseconds: Self.micros(Self.quietPeriod)))
        }
        if let last = state.lastReadAt {
            due = max(due, last.advanced(byMicroseconds: Self.micros(Self.minimumInterval)))
        }
        return due
    }

    private func schedule(_ state: inout State, at due: MonotonicInstant, now: MonotonicInstant) {
        state.timer?.cancel()
        let delay = due > now ? due.duration(since: now) : .zero
        state.timer = scheduler.schedule(after: delay, leeway: .milliseconds(10)) { [weak self] in self?.fire() }
    }

    /// One read when the pause holds, recorded with the most specific pending reason; otherwise the read moves to
    /// the new end of the pause. A queued or in-flight job counts as input: the read looks again one pause later.
    private func fire() {
        let now = clock.now()
        let taken = state.withLock { state -> (reasons: Set<DevReadbackReason>, timing: Timing)? in
            guard !state.pending.isEmpty else { return nil }
            guard isInjectionIdle() else {
                schedule(&state, at: now.advanced(byMicroseconds: Self.micros(Self.quietPeriod)), now: now)
                return nil
            }
            let activity = recorder.inputActivity
            let due = earliestRead(state, activity: activity, now: now)
            guard due <= now else {
                schedule(&state, at: due, now: now)
                return nil
            }
            let timing = Timing(
                waitMicroseconds: state.firstPendingAt.map { now.nanoseconds(since: $0) / 1_000 },
                idleMicroseconds: activity.latest.map { now.nanoseconds(since: $0) / 1_000 },
                inputCount: activity.count)
            defer { state = State(lastReadAt: now) }
            return (state.pending, timing)
        }
        guard let taken,
            let reason = [DevReadbackReason.marker, .backspaceEdit, .commit].first(where: taken.reasons.contains),
            recorder.isActive
        else { return }
        recorder.note(.readback(read(reason, timing: taken.timing)))
    }

    /// The readback itself, or why it was skipped (tested directly; without `timing` the pause counts as confirmed
    /// at the call).
    func read(_ reason: DevReadbackReason, timing: Timing? = nil) -> DevReadbackRecord {
        let snapshot = focus()
        let inputCount = timing?.inputCount ?? recorder.inputActivity.count
        var record = DevReadbackRecord(
            reason: reason, status: .ok, bundle: snapshot.app?.bundle.rawValue,
            rule: snapshot.decision.rule?.rawValue, at: clock.now())
        record.waitMicroseconds = timing?.waitMicroseconds
        record.idleMicroseconds = timing?.idleMicroseconds
        if let skipped = skipReason(snapshot) {
            record.status = skipped
            return record
        }
        guard let shared = snapshot.fieldHandle else {
            record.status = .skippedNoField
            return record
        }
        guard isInjectionIdle() else {
            record.status = .skippedBusy
            return record
        }
        let started = clock.now()
        let field = readField(shared)
        record.durationMicroseconds = clock.now().nanoseconds(since: started) / 1_000
        record.longestCallMicroseconds = field.longestCall
        record.overlap = recorder.inputActivity.count != inputCount
        record.status = field.status
        record.textBeforeCaret = field.text
        record.selectionLocation = field.selection?.location
        record.selectionLength = field.selection?.length
        return record
    }

    /// Why nothing may be read here (observer rule), before any AX call.
    private func skipReason(_ snapshot: FocusSnapshot) -> DevReadbackStatus? {
        if snapshot.field.secure || snapshot.pause?.code == .secureField || secureInput().enabled {
            return .skippedSecure
        }
        if snapshot.decision.requireTextFocus == .never { return .skippedRule }
        return snapshot.field.axAvailability == .available ? nil : .unavailable
    }

    /// The AX calls with the longest of them: the scanner compares it with the inject worker's per-call timeout
    /// (PLT-R311 timing row), which the sum of up to three calls would overstate.
    private func readField(_ shared: FieldHandle) -> FieldRead {
        var longest: UInt64 = 0
        var read = readCalls(shared, longest: &longest)
        read.longestCall = longest
        return read
    }

    /// One AX call; its duration becomes `longest` when it is the longest so far.
    private func timed<Result>(_ longest: inout UInt64, _ call: () -> Result) -> Result {
        let started = clock.now()
        defer { longest = max(longest, clock.now().nanoseconds(since: started) / 1_000) }
        return call()
    }

    /// The AX calls: the private element reference, the selection, then at most 64 units before the caret. Stops
    /// as soon as an edit job is queued.
    private func readCalls(_ shared: FieldHandle, longest: inout UInt64) -> FieldRead {
        let field: FieldHandle
        switch timed(&longest, { fieldResolver.privateHandle(for: shared, timeout: Self.axTimeout) }) {
        case .success(let resolved?): field = resolved
        case .success(nil): return FieldRead(.skippedNoField)
        case .timedOut: return FieldRead(.timedOut)
        case .unavailable: return FieldRead(.unavailable)
        case .failed: return FieldRead(.failed)
        }
        guard isInjectionIdle() else { return FieldRead(.skippedBusy) }
        let selection: TextRange
        switch timed(&longest, { fieldAccess.selectedRange(field, timeout: Self.axTimeout) }) {
        case .success(let range): selection = range
        case .timedOut: return FieldRead(.timedOut)
        case .unavailable: return FieldRead(.unavailable)
        case .failed: return FieldRead(.failed)
        }
        let count = min(Self.maximumUnits, max(0, selection.location))
        guard count > 0 else { return FieldRead(.ok, text: "", selection: selection) }
        guard isInjectionIdle() else { return FieldRead(.skippedBusy, selection: selection) }
        let range = TextRange(location: selection.location - count, length: count)
        switch timed(&longest, { fieldAccess.text(field, in: range, timeout: Self.axTimeout) }) {
        case .success(let text): return FieldRead(.ok, text: text, selection: selection)
        case .timedOut: return FieldRead(.timedOut, selection: selection)
        case .unavailable: return FieldRead(.unavailable, selection: selection)
        case .failed: return FieldRead(.failed, selection: selection)
        }
    }

    private static func micros(_ span: TimeSpan) -> UInt64 { span.unsignedNanoseconds / 1_000 }
}
#endif
