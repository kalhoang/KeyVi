// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Diagnostics drivers that type into the user's Mac. They exist for the product owner to run by hand from the
// Diagnostics window; automated tests use fakes only. Wave-2 contract (workstream W2-C).
//
// Every event these drivers post carries the probe kind of the event marker (bit 23, PLT-R321): the tap
// processes it as physical and routes its metrics to the probe histograms, so user metrics exclude it
// (PLT-R810), and it can never be mistaken for the worker's own echo (ADR 0311). The blocking pacing runs on a
// dedicated thread, never on the tap or the main thread.

public import AppModel
public import CompatRules
public import Diagnostics
public import Injection
public import RealtimeSupport
internal import Synchronization

/// PLT-R810: posts physical-like key events tagged with the probe marker (processed by the pipeline as
/// physical, excluded from user metrics) into the probe window's text view with the three timing profiles.
public final class LatencyProbeDriver: Sendable {
    let poster: any EventPoster
    let marker: EventMarker
    let clock: any MonotonicClock
    let sequence = ProbeSequence()
    let changes = Mutex<[LatencyProbeObservedChange]>([])
    /// How long after the last key the driver keeps collecting text changes.
    let settle: Duration

    public convenience init(poster: any EventPoster, marker: EventMarker, clock: any MonotonicClock) {
        self.init(poster: poster, marker: marker, clock: clock, settle: .milliseconds(150))
    }

    init(poster: any EventPoster, marker: EventMarker, clock: any MonotonicClock, settle: Duration) {
        self.poster = poster
        self.marker = marker
        self.clock = clock
        self.settle = settle
    }

    /// Pass-through run: types `keys` (key codes from the current layout) with `profile` spacing and returns one
    /// sample per key. Every key changes the text once and the window applies keys in order, so the k-th text
    /// change belongs to the k-th delivered key, however late it arrives (a time window would credit a late
    /// change to the next key in the burst profile). `shouldContinue` is read before every key on the typing
    /// thread; once it returns false nothing more is posted.
    public func run(
        profile: LatencyProbeResult.Profile, keys: [KeyCode],
        shouldContinue: @escaping @Sendable () -> Bool = { true }
    ) async -> [LatencyProbeSample] {
        let (posted, observed) = await type(keys, profile: profile, shouldContinue: shouldContinue)
        return LatencyProbeMath.correlate(posted, changes: observed.map(\.instant))
    }

    /// Measured run: returns the samples of the keys at `edits` (indices into `keys`), each matched in order to
    /// a change that shows the composed character (`LatencyProbeChange.composed`). The deletion half of an
    /// edit and the plain keys around it are not counted (PLT-R810 T4).
    public func run(
        profile: LatencyProbeResult.Profile, keys: [KeyCode], edits: [Int],
        shouldContinue: @escaping @Sendable () -> Bool = { true }
    ) async -> [LatencyProbeSample] {
        let (posted, observed) = await type(keys, profile: profile, shouldContinue: shouldContinue)
        let editKeys = edits.compactMap { posted.indices.contains($0) ? posted[$0] : nil }
        let composed = observed.filter { $0.kind == .composed }.map(\.instant)
        return LatencyProbeMath.correlate(editKeys, changes: composed)
    }

    private func type(
        _ keys: [KeyCode], profile: LatencyProbeResult.Profile, shouldContinue: @escaping @Sendable () -> Bool
    ) async -> ([LatencyProbePostedKey], [LatencyProbeObservedChange]) {
        changes.withLock { $0.removeAll() }
        let posted = await DedicatedThread.run(name: "latency-probe") {
            self.postAll(keys, every: profile.keyInterval, shouldContinue: shouldContinue)
        }
        return (posted, changes.withLock { $0 })
    }

    /// Called by the probe window (main thread) for every text change of its text view; `kind` tells whether
    /// the text now ends with the composed character of the measured run (`LatencyProbeScript.composed`).
    public func textChanged(at instant: MonotonicInstant, kind: LatencyProbeChange = .plain) {
        changes.withLock { $0.append(LatencyProbeObservedChange(instant: instant, kind: kind)) }
    }

    /// T2 from the probe decide-to-posted histogram recorded during the measured run (`decideToPosted`), T4 as
    /// the measured text-change latency minus the pass-through baseline of the same profile (02-platform.md
    /// 8.1), both at p50 and p99 in microseconds.
    public func result(
        profile: LatencyProbeResult.Profile, baseline: [LatencyProbeSample], measured: [LatencyProbeSample],
        decideToPosted: HistogramSnapshot
    ) -> LatencyProbeResult.ProfileResult {
        LatencyProbeMath.result(
            profile: profile, baseline: baseline, measured: measured, decideToPosted: decideToPosted)
    }
}

/// What a text change of the probe window shows: the composed character of the measured run (the visible
/// result of an edit) or anything else (a pass-through key, the deletion half of an edit, a space).
public enum LatencyProbeChange: Sendable, Hashable {
    case plain
    case composed

    /// Classifies the probe text view's content after a change.
    public init(text: String) {
        self = text.last == LatencyProbeScript.composed ? .composed : .plain
    }
}

struct LatencyProbeObservedChange: Sendable, Hashable {
    var instant: MonotonicInstant
    var kind: LatencyProbeChange
}

/// A key the driver typed: when, and whether the poster accepted it (an undelivered key has no change).
struct LatencyProbePostedKey: Sendable, Hashable {
    var instant: MonotonicInstant
    var delivered: Bool
}

/// Stop request for a driver that types into the user's Mac (PLT-R1205, PLT-R810, PLT-R387). The main thread
/// sets it (Stop, window closed, app switched); the dedicated typing thread reads the flag before every event
/// and runs the focus check before every step. A failed focus check latches the stop.
public final class ProbeStopSignal: Sendable {
    private let stopped = Atomic<Bool>(false)
    private let stillFocused: @Sendable () -> Bool

    /// `stillFocused` answers whether the field under test still has keyboard focus (bounded AX call,
    /// PLT-R342); it runs on the typing thread, never on the main thread.
    public init(stillFocused: @escaping @Sendable () -> Bool = { true }) {
        self.stillFocused = stillFocused
    }

    public func stop() { stopped.store(true, ordering: .releasing) }

    public var isStopped: Bool { stopped.load(ordering: .acquiring) }

    /// False once stopped; otherwise runs the focus check and stops when it fails.
    public func shouldContinue() -> Bool {
        guard !isStopped else { return false }
        guard stillFocused() else {
            stop()
            return false
        }
        return true
    }
}

/// PLT-R1205 step 3: candidate strategies tried in a field the user confirmed is empty and safe.
public struct GuidedTestCandidate: Sendable, Hashable {
    public var strategy: InjectionStrategy
    public var inlineCompletion: InlineCompletionMode
    public var interEventDelayUs: Int  // 0, 2,000, 5,000
    public init(strategy: InjectionStrategy, inlineCompletion: InlineCompletionMode, interEventDelayUs: Int) {
        self.strategy = strategy
        self.inlineCompletion = inlineCompletion
        self.interEventDelayUs = interEventDelayUs
    }
}

public enum GuidedTestCandidateResult: Sendable, Hashable {
    case passedByReadback
    case failedByReadback(residue: Bool)
    case needsHumanAnswer  // "Do you see 'đá â'? Yes / No"
    case humanSaidYes, humanSaidNo
    /// The readable field was not empty before typing (for example residue of an earlier candidate): nothing
    /// was typed. The test never types into a field with content.
    case fieldNotEmpty
    /// The stop signal fired (Stop, panel closed, focus moved) before the candidate finished: typing ended at
    /// once and nothing was removed, so no backspace can reach another field (PLT-R1205 step 3, PLT-R387).
    case stopped
}

public final class GuidedTestRunner: Sendable {
    let poster: any EventPoster
    let fieldAccess: any FocusedFieldAccess
    let marker: EventMarker
    let clock: any MonotonicClock
    /// Read when a run or removal starts, so a runner kept for the process lifetime follows input source
    /// changes (PLT-R405, PLT-R373).
    let currentLayout: @Sendable () -> LayoutTable?
    let sequence = ProbeSequence()

    /// Current strategy first, then the PLT-R1205 list: `backspaceReplace` with `axSelection`, with
    /// `placeholder`, `selectReplace`, `axReplace` for native apps, then the current strategy paced at 2 and
    /// 5 ms. Without a known current strategy the default plan stands in for it.
    public static func candidates(isNativeApp: Bool) -> [GuidedTestCandidate] {
        GuidedTestPlans.candidates(current: nil, isNativeApp: isNativeApp)
    }

    /// Same list with the focused field's current plan first (PLT-R1205 step 3 "current strategy").
    public static func candidates(current: InjectionPlan?, isNativeApp: Bool) -> [GuidedTestCandidate] {
        GuidedTestPlans.candidates(current: current, isNativeApp: isNativeApp)
    }

    public convenience init(
        poster: any EventPoster, fieldAccess: any FocusedFieldAccess, marker: EventMarker, clock: any MonotonicClock
    ) {
        self.init(poster: poster, fieldAccess: fieldAccess, marker: marker, clock: clock, layout: nil)
    }

    /// `layout` supplies the key codes of the canary keys (PLT-R405); without it the US positions are used.
    public convenience init(
        poster: any EventPoster, fieldAccess: any FocusedFieldAccess, marker: EventMarker, clock: any MonotonicClock,
        layout: LayoutTable?
    ) {
        self.init(poster: poster, fieldAccess: fieldAccess, marker: marker, clock: clock, currentLayout: { layout })
    }

    /// `currentLayout` is read at the start of every run and removal, so the canary's key codes match the layout
    /// in use at that moment (PLT-R405); nil falls back to the US positions.
    public init(
        poster: any EventPoster, fieldAccess: any FocusedFieldAccess, marker: EventMarker, clock: any MonotonicClock,
        currentLayout: @escaping @Sendable () -> LayoutTable?
    ) {
        self.poster = poster
        self.fieldAccess = fieldAccess
        self.marker = marker
        self.clock = clock
        self.currentLayout = currentLayout
    }

    /// Types the canary "đá â" with `candidate`, reads it back through AX when possible and removes it again
    /// with the same strategy, reporting residue (PLT-R1205 step 3, PLT-R410). When the field cannot be read the
    /// text stays for the user to judge: the result is `.needsHumanAnswer` and `removeTestText` follows the
    /// answer. `stop` is checked before every event and its focus check before every step and before the
    /// removal; once it fires the result is `.stopped` and nothing more is posted.
    public func run(
        _ candidate: GuidedTestCandidate, field: FieldHandle?, stop: ProbeStopSignal = ProbeStopSignal()
    ) async -> GuidedTestCandidateResult {
        await DedicatedThread.run(name: "guided-test") { self.typeAndVerify(candidate, field: field, stop: stop) }
    }

    /// Removes the canary after a human answer. Returns whether text remained (nil when the field cannot be
    /// read, or when `stop` fired and nothing was removed).
    public func removeTestText(
        _ candidate: GuidedTestCandidate, field: FieldHandle?, stop: ProbeStopSignal = ProbeStopSignal()
    ) async -> Bool? {
        await DedicatedThread.run(name: "guided-test") { self.remove(candidate, field: field, stop: stop) }
    }

    /// Rule suggestion in the 5.4 schema (PLT-R1205 step 4); a URL prefix only if the user ticked "include page
    /// address" and edited it down to a host-level prefix. The suggestion is shown and copied on its own; the
    /// diagnostics report never contains its URL (ADR 0312).
    public static func suggestion(
        context: MatchContext, best: GuidedTestCandidate, appVersion: String?, macOS: String, date: String,
        includeURLPrefix: String?
    ) -> Rule {
        GuidedTestSuggestion.rule(
            context: context, best: best, appVersion: appVersion, macOS: macOS, date: date,
            includeURLPrefix: includeURLPrefix)
    }
}

/// Probe-kind marker sequence shared by one driver's events (23 bits, wraps).
final class ProbeSequence: Sendable {
    private let value = Atomic<UInt32>(0)
    func next() -> UInt32 { value.wrappingAdd(1, ordering: .relaxed).newValue & EventMarker.sequenceMask }
}
