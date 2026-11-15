// SPDX-License-Identifier: GPL-3.0-or-later

import AppModel
import Foundation
import Testing

@testable import CompatRules

@Suite struct LinterTests {
    static let today = day("2026-11-13")
    static let clean = Build.rule("clean.rule", match: RuleMatch(engines: [.qt]))
    static let scenarios: Set<String> = ["clean.rule", "manual.rule", "other.rule"]

    private func lint(
        _ rules: [Rule], matrix: MatrixDocument? = MatrixDocument(schemaVersion: 1, entries: []),
        scenarios: Set<String> = LinterTests.scenarios, gated: Set<String> = [], today: Date = LinterTests.today,
        release: Bool = false, defaults: RuleDefaults = Build.defaults
    ) -> [LintFinding] {
        RulesLinter(
            rules: Build.document(rules, defaults: defaults), matrix: matrix, scenarioIDs: scenarios,
            placeholderGateScenarioIDs: gated, today: today, releaseMode: release
        ).run()
    }

    private func codes(_ findings: [LintFinding], _ severity: LintFinding.Severity? = nil) -> [LintCode] {
        findings.filter { severity == nil || $0.severity == severity }.map(\.code)
    }

    private func verifiedRow(for rule: String, tier: Int? = nil, lastVerified: String = "2026-11-01") -> MatrixEntry {
        MatrixEntry(
            bundleId: bundleKey("com.example.editor"), displayName: "Editor", category: "notes", tier: tier,
            ruleId: ruleID(rule), status: .works, lastVerified: lastVerified, appVersion: "1.0", macOS: "27.1",
            verifier: "tester")
    }

    @Test func cleanRuleHasNoFindings() {
        #expect(lint([Self.clean]).isEmpty)
        #expect(lint([Self.clean], release: true).isEmpty)
    }

    /// PLT-R505: provenance with reason, evidence, a passing tested entry and addedIn.
    @Test func missingOrIncompleteProvenance() {
        var noProvenance = Self.clean
        noProvenance.provenance = nil
        #expect(codes(lint([noProvenance])) == [.missingProvenance])
        var userShaped = Self.clean
        userShaped.provenance = .userSuggestion(UserProvenance(source: "user-suggestion", date: "2026-11-13"))
        #expect(codes(lint([userShaped])) == [.missingProvenance])
        var thin = Self.clean
        thin.provenance = .shipped(
            Provenance(
                reason: "short", evidence: [],
                tested: [TestedEntry(app: "A", appVersion: "1", macOS: "27", date: "2026-11-01", result: .fail)],
                addedIn: " ", reviewBy: "2027-01-01"))
        #expect(
            codes(lint([thin]), .error) == [
                .missingProvenance, .missingProvenance, .missingProvenance, .noPassingTestedEntry,
            ])
    }

    @Test func missingTestReference() {
        var rule = Self.clean
        rule.test = nil
        #expect(codes(lint([rule])) == [.missingTest])
        rule.test = RuleTest(scenario: " ", automation: .automated)
        #expect(codes(lint([rule])) == [.missingTest])
    }

    @Test func unknownScenarioWarnsAndBlocksRelease() {
        #expect(lint([Self.clean], scenarios: []).map(\.severity) == [.warning])
        #expect(codes(lint([Self.clean], scenarios: [])) == [.unknownScenario])
        #expect(lint([Self.clean], scenarios: [], release: true).map(\.severity) == [.error])
    }

    /// Acceptance: VERIFY dates in `tested` are warnings, release blockers with `--release`.
    @Test func unverifiedTestedEntryWarnsAndBlocksRelease() {
        let rule = Build.rule(
            "clean.rule", match: RuleMatch(engines: [.qt]), provenance: Build.provenance(tested: "VERIFY"))
        let findings = lint([rule])
        #expect(codes(findings) == [.unverifiedTestedEntry])
        #expect(findings.first?.severity == .warning)
        #expect(lint([rule], release: true).first?.severity == .error)
    }

    /// Acceptance, PLT-R506: past reviewBy warns; more than 30 days past is an error with `--release`.
    @Test func reviewByDates() {
        func rule(_ reviewBy: String) -> Rule {
            Build.rule("clean.rule", match: RuleMatch(engines: [.qt]), provenance: Build.provenance(reviewBy: reviewBy))
        }
        #expect(lint([rule("2026-11-13")]).isEmpty)
        let yesterday = lint([rule("2026-11-12")])
        #expect(codes(yesterday) == [.reviewByPassed] && yesterday.first?.severity == .warning)
        #expect(codes(lint([rule("2026-10-14")], release: true)) == [.reviewByPassed])  // 30 days
        let old = lint([rule("2026-10-13")])  // 31 days
        #expect(codes(old) == [.reviewByPassed] && old.first?.severity == .warning)
        let blocked = lint([rule("2026-10-13")], release: true)
        #expect(codes(blocked) == [.reviewByPassedOver30Days] && blocked.first?.severity == .error)
        #expect(codes(lint([rule("2027-11-14")])) == [])  // 366 days ahead
        #expect(codes(lint([rule("2027-11-15")]), .error) == [.reviewByMoreThan12Months])
        #expect(codes(lint([rule("next year")]), .error) == [.schemaInvalid])
    }

    /// Acceptance, PLT-R521: identical signatures fail, whatever the list order.
    @Test func identicalSignaturesFail() {
        let first = Build.rule("clean.rule", match: RuleMatch(engines: [.qt, .gecko], ax: AXMatch(roles: ["a", "b"])))
        let second = Build.rule(
            "other.rule", match: RuleMatch(engines: [.gecko, .qt], ax: AXMatch(roles: ["b", "a"])))
        let findings = lint([first, second])
        #expect(codes(findings) == [.identicalMatchSignature])
        #expect(findings.first?.rule == ruleID("other.rule"))
        #expect(findings.first?.detail == "same match as clean.rule")
    }

    /// Acceptance, PLT-R422: placeholder in a global or title-only rule.
    @Test func placeholderInGlobalOrTitleOnlyRule() {
        let placeholder = RuleAction(
            strategy: .backspaceReplace, params: StrategyParams(inlineCompletion: .placeholder))
        let global = Build.rule("clean.rule", match: RuleMatch(), action: placeholder)
        let titleOnly = Build.rule(
            "other.rule", match: RuleMatch(bundleIds: [bundleKey("com.example.sheet")], titlePattern: "Sheet"),
            action: placeholder)
        let findings = lint([global, titleOnly])
        #expect(codes(findings, .error) == [.placeholderWithoutGateTest, .placeholderWithoutGateTest])
        #expect(findings.compactMap(\.rule) == [ruleID("clean.rule"), ruleID("other.rule")])
        var defaults = Build.defaults
        defaults.params.inlineCompletion = .placeholder
        #expect(codes(lint([Self.clean], defaults: defaults), .error) == [.placeholderWithoutGateTest])
    }

    /// PLT-R422: a manual test can never show 1,000 randomised edits, so the release gate blocks the rule.
    @Test func scopedPlaceholderWithManualTestIsReleaseGated() {
        let rule = Build.rule(
            "manual.rule",
            match: RuleMatch(engines: [.chromium], web: WebMatch(urlPrefixes: ["https://sheet.example/"])),
            action: RuleAction(strategy: .backspaceReplace, params: StrategyParams(inlineCompletion: .placeholder)),
            automation: .manual)
        let matrix = MatrixDocument(schemaVersion: 1, entries: [verifiedRow(for: "manual.rule")])
        let findings = lint([rule], matrix: matrix, gated: ["manual.rule"])
        #expect(codes(findings) == [.placeholderWithoutGateTest])
        #expect(findings.first?.severity == .warning)
        let release = lint([rule], matrix: matrix, gated: ["manual.rule"], release: true)
        #expect(codes(release, .error) == [.placeholderWithoutGateTest])
        #expect(release.first?.detail == "the 1,000-edit placeholder gate needs an automated test")
    }

    /// PLT-R422, section 4 acceptance: an automated test only counts when its scenario declares the gate
    /// (`PlaceholderGate`); both placeholder values are covered.
    @Test func automatedPlaceholderNeedsAScenarioThatDeclaresTheGate() {
        let match = RuleMatch(engines: [.chromium], ax: AXMatch(roles: ["AXTextField"]))
        for value in [InlineCompletionMode.placeholder, .axSelectionThenPlaceholder] {
            let rule = Build.rule(
                "clean.rule", match: match,
                action: RuleAction(strategy: .backspaceReplace, params: StrategyParams(inlineCompletion: value)))
            let ungated = lint([rule])
            #expect(codes(ungated) == [.placeholderWithoutGateTest] && ungated.first?.severity == .warning)
            let release = lint([rule], release: true)
            #expect(codes(release, .error) == [.placeholderWithoutGateTest])
            #expect(release.first?.detail?.hasPrefix("scenario clean.rule does not declare the gate") == true)
            #expect(lint([rule], gated: ["clean.rule"], release: true).isEmpty)
        }
        let axOnly = Build.rule(
            "clean.rule", match: match,
            action: RuleAction(strategy: .backspaceReplace, params: StrategyParams(inlineCompletion: .axSelection)))
        #expect(lint([axOnly], release: true).isEmpty)
    }

    /// The scenario shape that counts as the PLT-R422 gate (twin of compat/schema/scenario.schema.json).
    @Test func placeholderGateDeclaration() throws {
        func scenario(_ repeatBlock: String, expect: String = #""noPlaceholderResidue":true"#, readback: String = "ax")
            throws -> JSONValue
        {
            let text =
                #"{"id":"s","timing":"normal","readback":""# + readback + #"","expect":{"# + expect + "}"
                + (repeatBlock.isEmpty ? "" : #","repeat":"# + repeatBlock) + "}"
            return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        }
        let gate = #"{"words":1000,"seed":1,"timing":"burst","prefix":["command+l"]}"#
        #expect(PlaceholderGate.isDeclared(in: try scenario(gate)))
        #expect(PlaceholderGate.isDeclared(in: try scenario(gate, readback: "webdriver")))
        #expect(!PlaceholderGate.isDeclared(in: try scenario("")))
        #expect(!PlaceholderGate.isDeclared(in: try scenario(gate.replacingOccurrences(of: "1000", with: "999"))))
        #expect(!PlaceholderGate.isDeclared(in: try scenario(gate.replacingOccurrences(of: "burst", with: "fast"))))
        #expect(!PlaceholderGate.isDeclared(in: try scenario(gate, expect: #""noPlaceholderResidue":false"#)))
        #expect(!PlaceholderGate.isDeclared(in: try scenario(gate, expect: #""text":"a""#)))
        #expect(!PlaceholderGate.isDeclared(in: try scenario(gate, readback: "human")))
        #expect(!PlaceholderGate.isDeclared(in: .array([])))
    }

    @Test func pasteNeedsOptIn() {
        let paste = Build.rule("clean.rule", match: RuleMatch(engines: [.qt]), action: RuleAction(strategy: .paste))
        #expect(codes(lint([paste])) == [.pasteWithoutOptIn])
        let optIn = Build.rule(
            "clean.rule", match: RuleMatch(engines: [.qt]),
            action: RuleAction(strategy: .paste, requiresUserOptIn: true))
        #expect(lint([optIn]).isEmpty)
    }

    /// Acceptance, PLT-R531: a manual scenario needs a matrix row; the row needs date, version, macOS, tester.
    @Test func manualScenarioMatrixRows() {
        let manual = Build.rule("manual.rule", match: RuleMatch(engines: [.qt]), automation: .manual)
        let noRow = lint([manual])
        #expect(codes(noRow) == [.manualTestWithoutMatrixRow] && noRow.first?.severity == .error)
        let missingMatrix = lint([manual], matrix: nil)
        #expect(codes(missingMatrix) == [.manualTestWithoutMatrixRow] && missingMatrix.first?.severity == .warning)
        var unverified = verifiedRow(for: "manual.rule")
        unverified.status = .notVerified
        unverified.lastVerified = nil
        let pending = lint([manual], matrix: MatrixDocument(schemaVersion: 1, entries: [unverified]))
        #expect(codes(pending) == [.manualMatrixRowUnverified] && pending.first?.severity == .warning)
        let pendingRelease = lint(
            [manual], matrix: MatrixDocument(schemaVersion: 1, entries: [unverified]), release: true)
        #expect(pendingRelease.first?.severity == .error)
        #expect(
            lint([manual], matrix: MatrixDocument(schemaVersion: 1, entries: [verifiedRow(for: "manual.rule")])).isEmpty
        )
    }

    /// Acceptance, PLT-R531 and 13.3: Tier 1 rows older than 90 days block a release.
    @Test func tier1RowsOlderThan90DaysBlockRelease() {
        let row90 = verifiedRow(for: "clean.rule", tier: 1, lastVerified: "2026-08-15")  // 90 days
        var row91 = verifiedRow(for: "clean.rule", tier: 1, lastVerified: "2026-08-14")  // 91 days
        row91.bundleId = bundleKey("com.example.second")
        var tier2Old = verifiedRow(for: "clean.rule", tier: 2, lastVerified: "2025-01-01")
        tier2Old.bundleId = bundleKey("com.example.third")
        var neverVerified = verifiedRow(for: "clean.rule", tier: 1)
        neverVerified.bundleId = bundleKey("com.example.fourth")
        neverVerified.status = .notVerified
        neverVerified.lastVerified = nil
        let matrix = MatrixDocument(schemaVersion: 1, entries: [row90, row91, tier2Old, neverVerified])
        #expect(lint([Self.clean], matrix: matrix).isEmpty)
        let release = lint([Self.clean], matrix: matrix, release: true)
        #expect(codes(release) == [.tier1MatrixRowOlderThan90Days, .tier1MatrixRowOlderThan90Days])
        #expect(release.allSatisfy { $0.severity == .error })
        #expect(release.map(\.bundle) == [row91.bundleId, neverVerified.bundleId])
    }

    @Test func matrixRowShapeAndReferences() {
        var noDate = verifiedRow(for: "clean.rule")
        noDate.lastVerified = nil
        var noNote = verifiedRow(for: "clean.rule")
        noNote.status = .knownLimitation
        noNote.bundleId = bundleKey("com.example.second")
        var bad = verifiedRow(for: "missing.rule")
        bad.bundleId = bundleKey("com.example.third")
        bad.category = "editor"
        bad.tier = 3
        bad.lastVerified = "VERIFY"
        bad.issues = [0]
        bad.checks = MatrixChecks(telexBasic: MatrixCell(result: .pass, date: "soon", tester: "t"))
        let matrix = MatrixDocument(schemaVersion: 2, entries: [noDate, noNote, bad])
        let findings = lint([Self.clean], matrix: matrix)
        #expect(codes(findings, .error).filter { $0 == .schemaInvalid }.count == 8)
        #expect(codes(findings).contains(.matrixRuleUnknown))
        #expect(findings.contains { $0.detail == "Editor: unknown category" })
    }

    /// PRD-R34, PRD-R35: the Apps pane shows one status per app, so each bundle ID has at most one app row;
    /// web-app and in-app rows of the same bundle ID carry a scope.
    @Test func atMostOneAppRowPerBundlePRDR35() {
        let app = verifiedRow(for: "clean.rule")
        var webApp = verifiedRow(for: "clean.rule")
        webApp.displayName = "Web app (Editor)"
        webApp.scope = .webApp
        var tool = verifiedRow(for: "clean.rule")
        tool.displayName = "Tool (in Editor)"
        tool.scope = .inApp
        #expect(lint([Self.clean], matrix: MatrixDocument(schemaVersion: 1, entries: [app, webApp, tool])).isEmpty)
        var explicitApp = verifiedRow(for: "clean.rule")
        explicitApp.displayName = "Editor again"
        explicitApp.scope = .app
        let findings = lint(
            [Self.clean], matrix: MatrixDocument(schemaVersion: 1, entries: [app, webApp, explicitApp]))
        #expect(
            findings == [
                LintFinding(
                    severity: .error, code: .schemaInvalid, rule: ruleID("clean.rule"), bundle: app.bundleId,
                    detail: "Editor again: a second app row for this bundle ID (set scope webApp or inApp)")
            ])
    }

    @Test func validatorIssuesAreReportedAsSchemaFindings() {
        let grouped = Build.rule("clean.rule", match: RuleMatch(bundleGroup: "nowhere"))
        let findings = lint([grouped, grouped])
        #expect(codes(findings, .error).filter { $0 == .schemaInvalid }.count == 3)
        #expect(findings.contains { $0.detail == "duplicate rule id" })
        #expect(findings.contains { $0.detail == "bundleGroup nowhere is not defined" })
    }

    @Test func documentShapeChecks() {
        var document = Build.document([Build.rule("clean.rule", match: RuleMatch(engines: [.qt]))])
        document.rulesetVersion = "v1"
        document.bundleGroups = ["bad-name": []]
        document.secureInputHints = [SecureInputHint(bundleId: bundleKey("com.example.term"), hintKey: "Bad Key")]
        document.rules[0].summary = ""
        let findings = RulesLinter(
            rules: document, matrix: nil, scenarioIDs: Self.scenarios, today: Self.today, releaseMode: false
        ).run()
        #expect(codes(findings, .error) == [.schemaInvalid, .schemaInvalid, .schemaInvalid, .schemaInvalid])
    }

    /// Acceptance: the seeded files lint without errors (warnings allowed for VERIFY items).
    @Test func seededFilesHaveNoErrors() throws {
        let findings = RulesLinter(
            rules: try Build.seededDocument(), matrix: try Build.seededMatrix(), scenarioIDs: [], today: Self.today,
            releaseMode: false
        ).run()
        #expect(findings.filter { $0.severity == .error }.isEmpty, "\(findings.filter { $0.severity == .error })")
        #expect(
            Set(codes(findings)).isSubset(of: [
                .unverifiedTestedEntry, .unknownScenario, .manualMatrixRowUnverified, .placeholderWithoutGateTest,
            ]))
    }

    /// PLT-R424: `forwardDelete` in defaults or a broad rule is a lint error with its own code.
    @Test func forwardDeleteOutsideAScopedRuleIsAnErrorPLTR424() throws {
        var document = try Build.seededDocument()
        document.defaults.params.inlineCompletion = .forwardDelete
        let findings = RulesLinter(
            rules: document, matrix: try Build.seededMatrix(), scenarioIDs: [], today: Self.today, releaseMode: false
        ).run()
        let forwardDelete = findings.filter { $0.code == .forwardDeleteInBroadRule }
        #expect(forwardDelete.count == 1)
        #expect(forwardDelete.first?.severity == .error && forwardDelete.first?.rule == nil)
        #expect(RulesValidationError.forwardDeleteInBroadRule(nil).ruleID == nil)
    }

    @Test func everyRuleValidationErrorHasDetailAndRuleMapping() {
        let id = ruleID("x.y")
        let errors: [RulesValidationError] = [
            .decoding(path: "$.a", reason: "wrong type"), .unsupportedSchemaVersion(2), .duplicateRuleID(id),
            .unknownBundleGroup(rule: id, group: "g"), .titlePatternWithoutBundleIDs(id), .titlePatternTooLong(id),
            .invalidTitlePattern(id), .titlePatternInUserOverride(id), .parameterOutOfRange(rule: id, key: "k"),
            .placeholderInBroadRule(id), .userOverrideIDNotPrefixed(id), .forwardDeleteInBroadRule(id),
        ]
        for error in errors {
            #expect(!error.detail.isEmpty)
            #expect(
                error.ruleID
                    == (error == .decoding(path: "$.a", reason: "wrong type") || error == .unsupportedSchemaVersion(2)
                        ? nil : id))
        }
        for code in LintCode.allCases { #expect(!code.explanation.isEmpty) }
    }
}
