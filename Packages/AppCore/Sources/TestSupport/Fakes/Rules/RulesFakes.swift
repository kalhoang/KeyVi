// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Scripted decision resolver so focus tests (W1-E) do not depend on the rules implementation (W1-C).
// Implemented in the skeleton (ADR 0313); W1-C owns this directory and may add helpers.

public import AppModel
public import CompatRules
public import Foundation
public import InputHost
internal import RealtimeSupport

public final class FakeDecisionResolver: FocusDecisionResolving, Sendable {
    private let decisions: [BundleKey: ResolvedDecision]
    private let fallback: ResolvedDecision
    private let fingerprints: [BundleKey: EngineFingerprint]
    private let contexts = Mutex<[MatchContext]>([])
    public let overlayBundles: Set<BundleKey>
    public let titlePatternBundles: Set<BundleKey>

    public init(
        decisions: [BundleKey: ResolvedDecision], fallback: ResolvedDecision, overlayBundles: Set<BundleKey> = [],
        titlePatternBundles: Set<BundleKey> = [], fingerprints: [BundleKey: EngineFingerprint] = [:]
    ) {
        self.decisions = decisions
        self.fallback = fallback
        self.overlayBundles = overlayBundles
        self.titlePatternBundles = titlePatternBundles
        self.fingerprints = fingerprints
    }

    public func resolve(_ context: MatchContext) -> ResolvedDecision {
        contexts.withLock { $0.append(context) }
        return context.bundle.flatMap { decisions[$0] } ?? fallback
    }

    /// Every context passed to `resolve` (W1-E: "resolution happens once per focus change").
    public var resolvedContexts: [MatchContext] { contexts.withLock { $0 } }

    public func fingerprint(bundleURL: URL, bundle: BundleKey) -> EngineFingerprint {
        fingerprints[bundle] ?? .native
    }

    /// A decision equivalent to the 5.4 `defaults` block, with `byEngine` resolved per PLT-R386 (`whenKnown` for
    /// native and Catalyst apps, `never` otherwise).
    public static func defaultDecision(engine: EngineFingerprint) -> ResolvedDecision {
        ResolvedDecision(
            rule: nil, source: .default, specificity: 0, strategy: .backspaceReplace, params: .defaults,
            fallback: [.passThrough], defaultMode: .inherit,
            requireTextFocus: engine == .native || engine == .catalyst ? .whenKnown : .never,
            verifyReentry: .whenReadable, axEnable: .none, overlay: false, requiresUserOptIn: false,
            engineContext: .general, features: .defaults)
    }
}
