// SPDX-License-Identifier: LicenseRef-App-Pending

public import AppModel
public import Foundation

public enum RulesValidationError: Error, Sendable, Hashable {
    case decoding(path: String, reason: String)
    case unsupportedSchemaVersion(Int)
    case duplicateRuleID(RuleID)
    case unknownBundleGroup(rule: RuleID, group: String)
    case titlePatternWithoutBundleIDs(RuleID)
    case titlePatternTooLong(RuleID)
    case invalidTitlePattern(RuleID)
    case titlePatternInUserOverride(RuleID)  // PLT-R502
    case parameterOutOfRange(rule: RuleID?, key: String)
    case placeholderInBroadRule(RuleID)  // PLT-R422: not global, not title-only
    case userOverrideIDNotPrefixed(RuleID)
}

public struct RulesLoadResult: Sendable {
    public var document: RulesDocument
    /// True when the shipped file was invalid and `EmbeddedRules.minimal` is in use (PLT-R503).
    public var usedEmbeddedDefaults: Bool
    public var error: RulesValidationError?
}

public struct RejectedOverride: Sendable, Hashable {
    public var index: Int
    public var error: RulesValidationError
}

public enum RulesLoader {
    /// Never throws and never crashes on bad input: falls back to the embedded ruleset (PLT-R503).
    public static func load(contentsOf url: URL) -> RulesLoadResult { unimplemented() }
    public static func decode(_ data: Data) throws(RulesValidationError) -> RulesDocument { unimplemented() }
    /// Decodes rule-overrides.json entries; invalid entries are rejected individually.
    public static func decodeOverrides(_ raw: [JSONValue]) -> (rules: [Rule], rejected: [RejectedOverride]) {
        unimplemented()
    }
}

/// Compiled-in known-good ruleset (PLT-R503): the `defaults` block and engine-only rules. It contains no
/// bundle identifiers, so the bundle-ID literal lint (PLT-R501) stays clean.
public enum EmbeddedRules {
    public static var minimal: RulesDocument { unimplemented() }
}
