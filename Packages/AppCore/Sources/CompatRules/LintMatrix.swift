// SPDX-License-Identifier: GPL-3.0-or-later
//
// Matrix checks of the linter (QA-R17, PLT-R531, 13.3) and the small helpers shared by the lint files.

import AppModel
import Foundation

struct MatrixRowChecks {
    let context: LintContext

    /// Values of the `category` enum in compat/schema/matrix.schema.json.
    static let categories: Set<String> = [
        "browser", "office", "chat", "notes", "developer", "terminal", "design", "launcher", "remote", "game",
        "system", "other",
    ]
    static let tiers: Set<Int> = [1, 2]  // PRD-R39

    /// A row that records a real verification: date, app version, macOS and tester (PLT-R531).
    static func isVerified(_ entry: MatrixEntry) -> Bool {
        entry.lastVerified.flatMap(ISODay.init) != nil && entry.appVersion != nil && entry.macOS != nil
            && entry.verifier != nil
    }

    func findings() -> [LintFinding] {
        guard let matrix = context.matrix else { return [] }
        var findings: [LintFinding] = []
        if matrix.schemaVersion != MatrixLoader.supportedSchemaVersion {
            findings.append(LintFinding(severity: .error, code: .schemaInvalid, detail: "matrix schemaVersion"))
        }
        let ruleIDs = Set(context.rules.rules.map(\.id))
        for entry in matrix.entries {
            findings += shapeFindings(entry) + referenceFindings(entry, ruleIDs: ruleIDs) + freshnessFindings(entry)
        }
        return findings + duplicateAppRowFindings(matrix.entries)
    }

    /// PRD-R34, PRD-R35: one app row per bundle ID, so the Apps pane has a single status to show.
    private func duplicateAppRowFindings(_ entries: [MatrixEntry]) -> [LintFinding] {
        var seen = Set<BundleKey>()
        return entries.filter(\.isAppRow).compactMap { entry in
            if seen.insert(entry.bundleId).inserted { return nil }
            return LintFinding(
                severity: .error, code: .schemaInvalid, rule: entry.ruleId, bundle: entry.bundleId,
                detail: entry.displayName + ": a second app row for this bundle ID (set scope webApp or inApp)")
        }
    }

    private func shapeFindings(_ entry: MatrixEntry) -> [LintFinding] {
        var problems: [String] = []
        if !Self.categories.contains(entry.category) { problems.append("unknown category") }
        if let tier = entry.tier, !Self.tiers.contains(tier) { problems.append("tier must be 1 or 2") }
        if entry.status == .works || entry.status == .worksWithNotes,
            entry.lastVerified == nil || entry.appVersion == nil || entry.macOS == nil || entry.verifier == nil
        {
            problems.append("a verified status needs lastVerified, appVersion, macOS and verifier")
        }
        if entry.status == .worksWithNotes || entry.status == .knownLimitation, entry.note == nil {
            problems.append("this status needs a note in vi and en")
        }
        if let date = entry.lastVerified, ISODay(date) == nil { problems.append("lastVerified is not an ISO date") }
        if Self.cells(entry.checks).contains(where: { ISODay($0.date) == nil }) {
            problems.append("a check date is not an ISO date")
        }
        if entry.issues.contains(where: { $0 < 1 }) { problems.append("issue numbers start at 1") }
        return problems.map { problem in
            LintFinding(
                severity: .error, code: .schemaInvalid, rule: entry.ruleId, bundle: entry.bundleId,
                detail: entry.displayName + ": " + problem)
        }
    }

    private func referenceFindings(_ entry: MatrixEntry, ruleIDs: Set<RuleID>) -> [LintFinding] {
        guard let rule = entry.ruleId, !ruleIDs.contains(rule) else { return [] }
        return [
            LintFinding(
                severity: .error, code: .matrixRuleUnknown, rule: rule, bundle: entry.bundleId,
                detail: entry.displayName + ": ruleId is not a shipped rule")
        ]
    }

    /// 13.3: Tier 1 rows at most 90 days old at release time. Checked only in release mode.
    private func freshnessFindings(_ entry: MatrixEntry) -> [LintFinding] {
        guard context.releaseMode, entry.tier == 1 else { return [] }
        if let verified = entry.lastVerified.flatMap(ISODay.init),
            context.today.days(since: verified) <= LintLimits.tier1MaxAgeDays
        {
            return []
        }
        return [
            LintFinding(
                severity: .error, code: .tier1MatrixRowOlderThan90Days, rule: entry.ruleId, bundle: entry.bundleId,
                detail: entry.displayName + ": not verified in the last 90 days")
        ]
    }

    private static func cells(_ checks: MatrixChecks?) -> [MatrixCell] {
        guard let checks else { return [] }
        return [
            checks.telexBasic, checks.vniBasic, checks.inlineCompletion, checks.burstTyping, checks.backspaceReentry,
            checks.restoreHotkey, checks.perAppMemory, checks.macroExpansion,
        ].compactMap { $0 }
    }
}

/// Anchored patterns from the JSON Schemas.
struct LintPattern: Sendable {
    let regex: NSRegularExpression

    init(_ pattern: String) {
        guard let regex = try? NSRegularExpression(pattern: "^(?:" + pattern + ")$") else {
            preconditionFailure("invalid lint pattern")
        }
        self.regex = regex
    }

    func matches(_ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
    }

    static let rulesetVersion = LintPattern("[0-9]{4}\\.[0-9]{1,2}\\.[0-9]+")
    static let groupName = LintPattern("[A-Za-z][A-Za-z0-9]*")
    static let hintKey = LintPattern("[a-z][A-Za-z0-9]*(\\.[a-z][A-Za-z0-9]*)+")
}

extension RulesValidationError {
    var ruleID: RuleID? {
        switch self {
        case .decoding, .unsupportedSchemaVersion: nil
        case .duplicateRuleID(let rule), .titlePatternWithoutBundleIDs(let rule), .titlePatternTooLong(let rule),
            .invalidTitlePattern(let rule), .titlePatternInUserOverride(let rule), .placeholderInBroadRule(let rule),
            .userOverrideIDNotPrefixed(let rule):
            rule
        case .unknownBundleGroup(let rule, _): rule
        case .parameterOutOfRange(let rule, _): rule
        }
    }

    /// Plain English for lint output; names keys and ids only.
    var detail: String {
        switch self {
        case .decoding(let path, let reason): path + ": " + reason
        case .unsupportedSchemaVersion(let version): "unsupported schemaVersion " + String(version)
        case .duplicateRuleID: "duplicate rule id"
        case .unknownBundleGroup(_, let group): "bundleGroup " + group + " is not defined"
        case .titlePatternWithoutBundleIDs: "titlePattern requires bundleIds (PLT-R502)"
        case .titlePatternTooLong: "titlePattern is longer than 200 characters (PLT-R502)"
        case .invalidTitlePattern: "titlePattern does not compile"
        case .titlePatternInUserOverride: "user overrides cannot use titlePattern (PLT-R502)"
        case .parameterOutOfRange(_, let key): key + " is outside its allowed range (section 4)"
        case .placeholderInBroadRule: "placeholder in a global or title-only rule (PLT-R422)"
        case .userOverrideIDNotPrefixed: "user override ids start with user."
        }
    }
}
