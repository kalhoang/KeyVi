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
}

public enum LintCode: String, Sendable, Hashable, CaseIterable {
    case schemaInvalid
    case missingProvenance  // PLT-R505
    case missingTest  // PLT-R505
    case noPassingTestedEntry  // 5.4 `tested`: at least one passing entry
    case unknownScenario  // test.scenario has no compat/scenarios file
    case reviewByPassed  // PLT-R506 warning
    case reviewByPassedOver30Days  // PLT-R506 release blocker
    case reviewByMoreThan12Months  // PLT-R506
    case identicalMatchSignature  // PLT-R521
    case placeholderWithoutGateTest  // PLT-R422
    case manualTestWithoutMatrixRow  // PLT-R531
    case tier1MatrixRowOlderThan90Days  // PLT-R531, 13.3 (release mode)
    case matrixRuleUnknown
}

public struct RulesLinter: Sendable {
    public init(
        rules: RulesDocument, matrix: MatrixDocument?, scenarioIDs: Set<String>, today: Date, releaseMode: Bool
    ) { unimplemented() }

    public func run() -> [LintFinding] { unimplemented() }
}
