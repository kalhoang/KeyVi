// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Semantic checks shared by the loader (PLT-R503), `RuleSet.init` and the linter: the parts of
// compat/schema/rules.schema.json that Swift types cannot express (ranges, title patterns, group references,
// list cardinality) plus the cross-rule rules (unique ids, PLT-R422 placeholder scope, PLT-R502 user overrides).

import AppModel
import Foundation

/// Parameter caps of 02-platform.md section 4, mirrored by the `params` definition of the JSON Schema.
enum ParameterLimits {
    static let unicodeChunk = 1...ResolvedParams.maximumUnicodeChunk  // PLT-R404
    static let delayUs = 0...ResolvedParams.maximumDelayUs  // PLT-R408
    static let longTextThreshold = 1...4_000  // PLT-R480 maximum macro expansion
    static let restoreDelayMs = 0...5_000  // PLT-R461
    static let titlePatternLength = 200  // PLT-R502
}

/// Reserved names in `bundleGroups` (5.4 example, PLT-R510).
enum ReservedGroup {
    static let terminals = "terminals"
    static let webkitBrowsers = "webkitBrowsers"
}

enum RulesValidator {
    static let supportedSchemaVersion = 1
    static let userOverridePrefix = "user."

    /// Every problem in a shipped document, in document order.
    static func issues(in document: RulesDocument) -> [RulesValidationError] {
        var issues: [RulesValidationError] = []
        if document.schemaVersion != supportedSchemaVersion {
            issues.append(.unsupportedSchemaVersion(document.schemaVersion))
        }
        issues += parameterIssues(document.defaults.params, rule: nil)
        if PlaceholderScope.usesPlaceholder(document.defaults.params) {
            // PLT-R422: never enabled globally.
            issues.append(.parameterOutOfRange(rule: nil, key: "inlineCompletion"))
        }
        var seen = Set<RuleID>()
        for rule in document.rules {
            if !seen.insert(rule.id).inserted { issues.append(.duplicateRuleID(rule.id)) }
            issues += ruleIssues(rule, groups: document.bundleGroups, isUserOverride: false)
        }
        return issues
    }

    /// Problems of one user override (PLT-R522, PLT-R502). Group references are checked by `RuleSet.init`.
    static func overrideIssues(_ rule: Rule) -> [RulesValidationError] {
        ruleIssues(rule, groups: nil, isUserOverride: true)
    }

    /// Throws the first problem of the shipped document or of the overrides (`RuleSet.init`).
    static func validateRuleSet(document: RulesDocument, overrides: [Rule]) throws(RulesValidationError) {
        if let first = issues(in: document).first { throw first }
        var seen = Set(document.rules.map(\.id))
        for rule in overrides {
            if !seen.insert(rule.id).inserted { throw .duplicateRuleID(rule.id) }
            if let first = ruleIssues(rule, groups: document.bundleGroups, isUserOverride: true).first { throw first }
        }
    }

    static func ruleIssues(
        _ rule: Rule, groups: [String: [BundleKey]]?, isUserOverride: Bool
    ) -> [RulesValidationError] {
        var issues: [RulesValidationError] = []
        if isUserOverride && !rule.id.rawValue.hasPrefix(userOverridePrefix) {
            issues.append(.userOverrideIDNotPrefixed(rule.id))
        }
        if let group = rule.match.bundleGroup, let groups, groups[group] == nil {
            issues.append(.unknownBundleGroup(rule: rule.id, group: group))
        }
        if let field = MatchLists.emptyField(in: rule.match) {
            issues.append(.decoding(path: "rule " + rule.id.rawValue + " match." + field, reason: "empty list"))
        }
        issues += titlePatternIssues(rule, isUserOverride: isUserOverride)
        issues += parameterIssues(rule.action.params, rule: rule.id)
        if PlaceholderScope.usesPlaceholder(rule.action.params) && PlaceholderScope.isBroad(rule.match) {
            issues.append(.placeholderInBroadRule(rule.id))
        }
        return issues
    }

    static func titlePatternIssues(_ rule: Rule, isUserOverride: Bool) -> [RulesValidationError] {
        guard let pattern = rule.match.titlePattern else { return [] }
        if isUserOverride { return [.titlePatternInUserOverride(rule.id)] }
        var issues: [RulesValidationError] = []
        if rule.match.bundleIds?.isEmpty ?? true { issues.append(.titlePatternWithoutBundleIDs(rule.id)) }
        if pattern.unicodeScalars.count > ParameterLimits.titlePatternLength {
            issues.append(.titlePatternTooLong(rule.id))
        } else if (try? NSRegularExpression(pattern: pattern)) == nil {
            issues.append(.invalidTitlePattern(rule.id))
        }
        return issues
    }

    static func parameterIssues(_ params: StrategyParams?, rule: RuleID?) -> [RulesValidationError] {
        guard let params else { return [] }
        let checks: [(Int?, ClosedRange<Int>, String)] = [
            (params.unicodeChunk, ParameterLimits.unicodeChunk, "unicodeChunk"),
            (params.interEventDelayUs, ParameterLimits.delayUs, "interEventDelayUs"),
            (params.postDeleteSettleUs, ParameterLimits.delayUs, "postDeleteSettleUs"),
            (params.firstEditDelayUs, ParameterLimits.delayUs, "firstEditDelayUs"),
            (params.longTextThreshold, ParameterLimits.longTextThreshold, "longTextThreshold"),
            (params.restoreDelayMs, ParameterLimits.restoreDelayMs, "restoreDelayMs"),
        ]
        return checks.compactMap { value, range, key in
            guard let value, !range.contains(value) else { return nil }
            return .parameterOutOfRange(rule: rule, key: key)
        }
    }
}

/// PLT-R422: where the zero-width placeholder may be enabled. Same definition as scripts/check-rules.py.
enum PlaceholderScope {
    static func usesPlaceholder(_ params: StrategyParams?) -> Bool {
        params?.inlineCompletion == .placeholder || params?.inlineCompletion == .axSelectionThenPlaceholder
    }

    /// Global (no identity and no narrowing field) or title-only (a title pattern without AX or URL narrowing).
    static func isBroad(_ match: RuleMatch) -> Bool {
        let narrowing = MatchLists.hasAXField(match.ax) || !(match.web?.urlPrefixes?.isEmpty ?? true)
        let identity =
            !(match.bundleIds?.isEmpty ?? true) || match.bundleGroup != nil || !(match.engines?.isEmpty ?? true)
        if match.titlePattern != nil && !narrowing { return true }
        return !narrowing && !identity
    }
}

/// Cardinality helpers: the schema requires every present match list to have at least one item.
enum MatchLists {
    static func hasAXField(_ ax: AXMatch?) -> Bool {
        guard let ax else { return false }
        let lists = [ax.roles, ax.subroles, ax.identifiers, ax.domClasses, ax.ancestorRoles]
        return lists.contains { !($0?.isEmpty ?? true) } || ax.editable != nil
    }

    /// Name of the first present-but-empty list, if any.
    static func emptyField(in match: RuleMatch) -> String? {
        let fields: [(String, Int?)] = [
            ("bundleIds", match.bundleIds?.count), ("engines", match.engines?.count),
            ("appCategories", match.appCategories?.count), ("ax.roles", match.ax?.roles?.count),
            ("ax.subroles", match.ax?.subroles?.count), ("ax.identifiers", match.ax?.identifiers?.count),
            ("ax.domClasses", match.ax?.domClasses?.count), ("ax.ancestorRoles", match.ax?.ancestorRoles?.count),
            ("web.urlPrefixes", match.web?.urlPrefixes?.count),
        ]
        return fields.first { $0.1 == 0 }?.0
    }
}
