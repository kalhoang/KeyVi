// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Diagnostics drivers that type into the user's Mac. They exist for the product owner to run by hand from the
// Diagnostics window; automated tests use fakes only. Wave-2 contract (workstream W2-C).

public import AppModel
public import CompatRules
public import Diagnostics
public import Injection
public import RealtimeSupport

/// PLT-R810: posts physical-like key events tagged with the probe marker (processed by the pipeline as
/// physical, excluded from user metrics) into the probe window's text view with the three timing profiles.
public final class LatencyProbeDriver: Sendable {
    public init(poster: any EventPoster, marker: EventMarker, clock: any MonotonicClock) { unimplemented() }
    /// Types `keys` (key codes from the current layout) with `profile` spacing; the probe window reports
    /// text-change times through `textChanged(at:)`.
    public func run(profile: LatencyProbeResult.Profile, keys: [KeyCode]) async -> [MonotonicInstant] {
        unimplemented()
    }
    public func textChanged(at instant: MonotonicInstant) { unimplemented() }
    public func result(baseline: [MonotonicInstant], measured: [MonotonicInstant], metrics: PlatformMetrics)
        -> LatencyProbeResult.ProfileResult
    { unimplemented() }
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
}

public final class GuidedTestRunner: Sendable {
    public static func candidates(isNativeApp: Bool) -> [GuidedTestCandidate] { unimplemented() }
    public init(
        poster: any EventPoster, fieldAccess: any FocusedFieldAccess, marker: EventMarker, clock: any MonotonicClock
    ) {
        unimplemented()
    }
    public func run(_ candidate: GuidedTestCandidate, field: FieldHandle?) async -> GuidedTestCandidateResult {
        unimplemented()
    }
    /// Rule suggestion in the 5.4 schema (PLT-R1205 step 4); a URL prefix only if the user ticked "include page
    /// address" and edited it down to a host-level prefix. The suggestion is shown and copied on its own; the
    /// diagnostics report never contains its URL (ADR 0312).
    public static func suggestion(
        context: MatchContext, best: GuidedTestCandidate, appVersion: String?, macOS: String, date: String,
        includeURLPrefix: String?
    ) -> Rule { unimplemented() }
}
