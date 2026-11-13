// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The checks behind `RulesLinter` (02-platform.md 13.1 "Rules", PLT-R503 to PLT-R531). They mirror
// scripts/check-rules.py so compat-lint stands on its own, and add the matrix checks of PLT-R531 and QA-R17.
// "Release-gated" findings are warnings during development and errors with `--release`: they mark VERIFY items
// that must be closed before shipping.

import AppModel
import Foundation

struct LintContext: Sendable {
    let rules: RulesDocument
    let matrix: MatrixDocument?
    let scenarioIDs: Set<String>
    let today: ISODay
    let releaseMode: Bool

    var releaseGated: LintFinding.Severity { releaseMode ? .error : .warning }
}

enum LintLimits {
    static let reviewMaxAheadDays = 366  // PLT-R506 "at most 12 months ahead", same as check-rules.py
    static let reviewBlockAfterDays = 30  // PLT-R506
    static let tier1MaxAgeDays = 90  // PLT-R531, 13.3
    static let minimumReasonLength = 10  // schema: provenance.reason minLength
    static let summaryLength = 1...200  // schema: summary
}

struct LintEngine {
    let context: LintContext

    func run() -> [LintFinding] {
        var findings = DocumentChecks(context: context).findings()
        for rule in context.rules.rules {
            findings += RuleChecks(context: context, rule: rule).findings()
        }
        findings += signatureFindings()
        findings += MatrixRowChecks(context: context).findings()
        return findings
    }

    /// PLT-R521: identical match signatures fail CI; the later rule is reported.
    private func signatureFindings() -> [LintFinding] {
        var firstBySignature: [String: RuleID] = [:]
        var findings: [LintFinding] = []
        for rule in context.rules.rules {
            let signature = RuleSet.signature(of: rule.match)
            if let original = firstBySignature[signature] {
                findings.append(
                    LintFinding(
                        severity: .error, code: .identicalMatchSignature, rule: rule.id,
                        detail: "same match as " + original.rawValue))
            } else {
                firstBySignature[signature] = rule.id
            }
        }
        return findings
    }
}

/// Validator issues plus the schema patterns Swift types do not enforce.
struct DocumentChecks {
    let context: LintContext

    func findings() -> [LintFinding] {
        RulesValidator.issues(in: context.rules).map(Self.finding(for:)) + shapeFindings()
    }

    static func finding(for issue: RulesValidationError) -> LintFinding {
        switch issue {
        case .placeholderInBroadRule(let rule):
            return LintFinding(severity: .error, code: .placeholderWithoutGateTest, rule: rule, detail: issue.detail)
        case .parameterOutOfRange(nil, "inlineCompletion"):
            return LintFinding(
                severity: .error, code: .placeholderWithoutGateTest, detail: "defaults enable the placeholder globally")
        default:
            return LintFinding(severity: .error, code: .schemaInvalid, rule: issue.ruleID, detail: issue.detail)
        }
    }

    private func shapeFindings() -> [LintFinding] {
        let document = context.rules
        var findings: [LintFinding] = []
        if !LintPattern.rulesetVersion.matches(document.rulesetVersion) {
            findings.append(schemaInvalid(detail: "rulesetVersion must look like 2026.11.0"))
        }
        for name in document.bundleGroups.keys.sorted() where !LintPattern.groupName.matches(name) {
            findings.append(schemaInvalid(detail: "bundle group name " + name + " is not an identifier"))
        }
        for hint in document.secureInputHints where !LintPattern.hintKey.matches(hint.hintKey) {
            findings.append(
                LintFinding(severity: .error, code: .schemaInvalid, bundle: hint.bundleId, detail: "invalid hintKey"))
        }
        for rule in document.rules where !LintLimits.summaryLength.contains(rule.summary.count) {
            findings.append(schemaInvalid(rule: rule.id, detail: "summary must be 1 to 200 characters"))
        }
        return findings
    }

    private func schemaInvalid(rule: RuleID? = nil, detail: String) -> LintFinding {
        LintFinding(severity: .error, code: .schemaInvalid, rule: rule, detail: detail)
    }
}

/// Per-rule checks: provenance and review date (PLT-R505, PLT-R506), test reference and matrix row (PLT-R505,
/// PLT-R531), placeholder gate (PLT-R422) and paste opt-in (PLT-R460).
struct RuleChecks {
    let context: LintContext
    let rule: Rule

    func findings() -> [LintFinding] {
        provenanceFindings() + testFindings() + placeholderFindings() + pasteFindings()
    }

    private func finding(_ severity: LintFinding.Severity, _ code: LintCode, _ detail: String) -> LintFinding {
        LintFinding(severity: severity, code: code, rule: rule.id, detail: detail)
    }

    private func provenanceFindings() -> [LintFinding] {
        guard case .shipped(let provenance) = rule.provenance else {
            return [finding(.error, .missingProvenance, "shipped rules need the 5.4 provenance object")]
        }
        var findings: [LintFinding] = []
        if provenance.reason.trimmingCharacters(in: .whitespacesAndNewlines).count < LintLimits.minimumReasonLength {
            findings.append(finding(.error, .missingProvenance, "reason must state the symptom and its cause"))
        }
        if provenance.evidence.isEmpty {
            findings.append(finding(.error, .missingProvenance, "evidence needs at least one entry"))
        }
        if provenance.addedIn.trimmingCharacters(in: .whitespaces).isEmpty {
            findings.append(finding(.error, .missingProvenance, "addedIn is missing"))
        }
        if !provenance.tested.contains(where: { $0.result == .pass }) {
            findings.append(finding(.error, .noPassingTestedEntry, "tested needs at least one passing entry"))
        }
        let unverified = provenance.tested.filter { ISODay($0.date) == nil }.count
        if unverified > 0 {
            let noun = unverified == 1 ? " tested entry has" : " tested entries have"
            let detail = String(unverified) + noun + " no ISO date (VERIFY placeholder)"
            findings.append(finding(context.releaseGated, .unverifiedTestedEntry, detail))
        }
        return findings + reviewByFindings(provenance.reviewBy)
    }

    private func reviewByFindings(_ raw: String) -> [LintFinding] {
        guard let reviewBy = ISODay(raw) else {
            return [finding(.error, .schemaInvalid, "reviewBy is not an ISO date")]
        }
        let ahead = reviewBy.days(since: context.today)
        if ahead > LintLimits.reviewMaxAheadDays {
            return [finding(.error, .reviewByMoreThan12Months, "reviewBy is " + String(ahead) + " days ahead")]
        }
        let overdue = -ahead
        let detail = "reviewBy passed " + String(overdue) + " days ago"
        if overdue > LintLimits.reviewBlockAfterDays && context.releaseMode {
            return [finding(.error, .reviewByPassedOver30Days, detail)]
        }
        return overdue > 0 ? [finding(.warning, .reviewByPassed, detail)] : []
    }

    private func testFindings() -> [LintFinding] {
        guard let test = rule.test, !test.scenario.trimmingCharacters(in: .whitespaces).isEmpty else {
            return [finding(.error, .missingTest, "test.scenario is missing")]
        }
        var findings: [LintFinding] = []
        if !context.scenarioIDs.contains(test.scenario) {
            let detail = "no compat/scenarios/" + test.scenario + ".json"
            findings.append(finding(context.releaseGated, .unknownScenario, detail))
        }
        if test.automation == .manual { findings += matrixRowFindings() }
        return findings
    }

    private func matrixRowFindings() -> [LintFinding] {
        guard let matrix = context.matrix else {
            return [finding(.warning, .manualTestWithoutMatrixRow, "compat/matrix.json is missing")]
        }
        let rows = matrix.entries.filter { $0.ruleId == rule.id }
        if rows.isEmpty {
            return [finding(.error, .manualTestWithoutMatrixRow, "manual scenario without a matrix row")]
        }
        guard rows.contains(where: MatrixRowChecks.isVerified) else {
            let detail = "no matrix row records date, app version, macOS and tester yet"
            return [finding(context.releaseGated, .manualMatrixRowUnverified, detail)]
        }
        return []
    }

    private func placeholderFindings() -> [LintFinding] {
        guard PlaceholderScope.usesPlaceholder(rule.action.params), rule.test?.automation == .manual else { return [] }
        let detail = "the 1,000-edit placeholder gate needs an automated test"
        return [finding(.warning, .placeholderWithoutGateTest, detail)]
    }

    private func pasteFindings() -> [LintFinding] {
        guard rule.action.strategy == .paste, rule.action.requiresUserOptIn != true else { return [] }
        return [finding(.error, .pasteWithoutOptIn, "strategy paste requires requiresUserOptIn: true")]
    }
}
