// SPDX-License-Identifier: LicenseRef-App-Pending
//
// CI checks over compat/rules.json and compat/matrix.json (13.1 "Rules"), run by `compat-lint`.

public import AppModel
public import Foundation

public struct LintFinding: Sendable, Hashable {
    public enum Severity: String, Sendable, Hashable { case error, warning }
    public var severity: Severity
    public var code: LintCode
    public var rule: RuleID?
    public var bundle: BundleKey?
    /// Human-readable specifics (a decoding path, the other rule of a duplicate); never typed content.
    public var detail: String?

    public init(
        severity: Severity, code: LintCode, rule: RuleID? = nil, bundle: BundleKey? = nil, detail: String? = nil
    ) {
        self.severity = severity
        self.code = code
        self.rule = rule
        self.bundle = bundle
        self.detail = detail
    }
}

public enum LintCode: String, Sendable, Hashable, CaseIterable {
    case schemaInvalid
    case missingProvenance  // PLT-R505
    case missingTest  // PLT-R505
    case noPassingTestedEntry  // 5.4 `tested`: at least one passing entry
    case unverifiedTestedEntry  // a `tested` entry without an ISO date (VERIFY); release blocker
    case unknownScenario  // test.scenario has no compat/scenarios file
    case reviewByPassed  // PLT-R506 warning
    case reviewByPassedOver30Days  // PLT-R506 release blocker
    case reviewByMoreThan12Months  // PLT-R506
    case identicalMatchSignature  // PLT-R521
    case placeholderWithoutGateTest  // PLT-R422
    case manualTestWithoutMatrixRow  // PLT-R531
    case manualMatrixRowUnverified  // PLT-R531: row lacks date, app version, macOS or tester; release blocker
    case tier1MatrixRowOlderThan90Days  // PLT-R531, 13.3 (release mode)
    case matrixRuleUnknown
    case pasteWithoutOptIn  // PLT-R460
}

public struct RulesLinter: Sendable {
    /// `placeholderGateScenarioIDs`: the scenarios whose file declares the PLT-R422 gate (`PlaceholderGate`).
    public init(
        rules: RulesDocument, matrix: MatrixDocument?, scenarioIDs: Set<String>,
        placeholderGateScenarioIDs: Set<String> = [], today: Date, releaseMode: Bool
    ) {
        context = LintContext(
            rules: rules, matrix: matrix, scenarioIDs: scenarioIDs,
            placeholderGateScenarioIDs: placeholderGateScenarioIDs,
            today: ISODay(today), releaseMode: releaseMode)
    }

    let context: LintContext

    public func run() -> [LintFinding] { LintEngine(context: context).run() }
}
