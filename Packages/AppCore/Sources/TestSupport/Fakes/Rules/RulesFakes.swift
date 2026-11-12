// SPDX-License-Identifier: LicenseRef-App-Pending

public import AppModel
public import CompatRules
public import Foundation
public import InputHost

/// Scripted decision resolver so focus tests do not depend on the rules implementation.
public final class FakeDecisionResolver: FocusDecisionResolving, Sendable {
    public init(decisions: [BundleKey: ResolvedDecision], fallback: ResolvedDecision) { unimplemented() }
    public func resolve(_ context: MatchContext) -> ResolvedDecision { unimplemented() }
    public var overlayBundles: Set<BundleKey> { unimplemented() }
    public var titlePatternBundles: Set<BundleKey> { unimplemented() }
    public func fingerprint(bundleURL: URL, bundle: BundleKey) -> EngineFingerprint { unimplemented() }
    /// A default decision equivalent to the 5.4 `defaults` block.
    public static func defaultDecision(engine: EngineFingerprint) -> ResolvedDecision { unimplemented() }
}
