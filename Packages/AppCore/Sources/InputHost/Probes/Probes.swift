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
    let changes = Mutex<[MonotonicInstant]>([])
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

    /// Types `keys` (key codes from the current layout) with `profile` spacing and returns one sample per key:
    /// when it was posted and when the probe window last reported a text change before the next key (the
    /// window reports text changes through `textChanged(at:)`).
    public func run(profile: LatencyProbeResult.Profile, keys: [KeyCode]) async -> [LatencyProbeSample] {
        changes.withLock { $0.removeAll() }
        let posted = await DedicatedThread.run(name: "latency-probe") { self.postAll(keys, every: profile.keyInterval) }
        let observed = changes.withLock { $0 }
        return LatencyProbeMath.correlate(posted: posted, changes: observed, settle: settle)
    }

    /// Called by the probe window (main thread) for every text change of its text view.
    public func textChanged(at instant: MonotonicInstant) {
        changes.withLock { $0.append(instant) }
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
}

public final class GuidedTestRunner: Sendable {
    let poster: any EventPoster
    let fieldAccess: any FocusedFieldAccess
    let marker: EventMarker
    let clock: any MonotonicClock
    let keys: GuidedTestKeys
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
    public init(
        poster: any EventPoster, fieldAccess: any FocusedFieldAccess, marker: EventMarker, clock: any MonotonicClock,
        layout: LayoutTable?
    ) {
        self.poster = poster
        self.fieldAccess = fieldAccess
        self.marker = marker
        self.clock = clock
        keys = GuidedTestKeys(layout: layout)
    }

    /// Types the canary "đá â" with `candidate`, reads it back through AX when possible and removes it again
    /// with the same strategy, reporting residue (PLT-R1205 step 3, PLT-R410). When the field cannot be read the
    /// text stays for the user to judge: the result is `.needsHumanAnswer` and `removeTestText` follows the
    /// answer.
    public func run(_ candidate: GuidedTestCandidate, field: FieldHandle?) async -> GuidedTestCandidateResult {
        await DedicatedThread.run(name: "guided-test") { self.typeAndVerify(candidate, field: field) }
    }

    /// Removes the canary after a human answer. Returns whether text remained (nil when the field cannot be
    /// read).
    public func removeTestText(_ candidate: GuidedTestCandidate, field: FieldHandle?) async -> Bool? {
        await DedicatedThread.run(name: "guided-test") { self.remove(candidate, field: field) }
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
