// SPDX-License-Identifier: LicenseRef-App-Pending

import AppModel
import Foundation
import TestSupport
import Testing

@testable import CompatRules

@Suite struct LintCommandTests {
    private func run(
        _ arguments: [String], fileSystem: any FileSystem = LocalFileSystem(), environment: [String: String] = [:]
    )
        -> CompatLintCommand.Outcome
    {
        CompatLintCommand.run(
            arguments: arguments, environment: environment, fileSystem: fileSystem, today: referenceDay)
    }

    private var seededArguments: [String] {
        ["--rules", RepoFiles.rules.path, "--matrix", RepoFiles.matrix.path, "--scenarios", RepoFiles.scenarios.path]
    }

    /// Acceptance: `compat-lint` exits 0 on the seeded files (warnings allowed for VERIFY dates).
    @Test func seededFilesPass() {
        let outcome = run(seededArguments)
        #expect(outcome.exitCode == CompatLintCommand.exitClean, "\(outcome.output)")
        #expect(outcome.output.contains("compat-lint: 21 rule(s), 59 matrix row(s), 0 error(s)"))
        #expect(outcome.output.contains("warning: unverifiedTestedEntry [rule terminal.default]"))
    }

    @Test func releaseModeTurnsVERIFYItemsIntoErrors() {
        let outcome = run(seededArguments + ["--release", "--today", "2026-11-13"])
        #expect(outcome.exitCode == CompatLintCommand.exitFindings)
        #expect(
            outcome.output.contains(
                "error: tier1MatrixRowOlderThan90Days [rule browser.webkit.addressBar] [app com.apple.Safari]"))
        let firstError = outcome.output.range(of: "error: ")
        let firstWarning = outcome.output.range(of: "warning: ")
        if let firstError, let firstWarning { #expect(firstError.lowerBound < firstWarning.lowerBound) }
    }

    /// PLT-R422: in release mode the shipped placeholder rules whose test cannot show the 1,000-edit gate block
    /// the release (the two manual spreadsheet rules); the browser rules' scenarios declare it.
    @Test func releaseModeBlocksPlaceholderRulesWithoutTheirGate() {
        let outcome = run(seededArguments + ["--release", "--today", "2026-11-13"])
        for rule in ["web.googleSheets.cellEditor", "office.excel.cellEditor"] {
            #expect(outcome.output.contains("error: placeholderWithoutGateTest [rule " + rule + "]"), "\(rule)")
        }
        for rule in ["browser.chromium.addressBar", "browser.gecko.urlBar"] {
            #expect(!outcome.output.contains("placeholderWithoutGateTest [rule " + rule + "]"), "\(rule)")
        }
    }

    /// The gate is read from the scenario file itself; an unreadable or ungated file does not count.
    @Test func placeholderGateIsReadFromTheScenarioFile() throws {
        let fileSystem = InMemoryFileSystem()
        let action = RuleAction(
            strategy: .backspaceReplace, params: StrategyParams(inlineCompletion: .axSelectionThenPlaceholder))
        let rules = Build.document([
            Build.rule(
                "gated.rule", match: RuleMatch(engines: [.qt], ax: AXMatch(roles: ["AXTextField"])), action: action),
            Build.rule(
                "plain.rule", match: RuleMatch(engines: [.gecko], ax: AXMatch(roles: ["AXTextField"])), action: action),
            Build.rule(
                "broken.rule", match: RuleMatch(engines: [.electron], ax: AXMatch(roles: ["AXTextField"])),
                action: action),
        ])
        try fileSystem.writeAtomically(
            JSONEncoder().encode(rules), to: URL(fileURLWithPath: "/c/rules.json"), permissions: .ownerOnlyFile)
        let gated = #"""
            {"id":"gated.rule","timing":"normal","readback":"ax","expect":{"text":"á","noPlaceholderResidue":true},
             "repeat":{"words":1000,"seed":7,"timing":"burst","prefix":["command+l"]}}
            """#
        let files = [
            "gated.rule": gated, "plain.rule": #"{"id":"plain.rule","expect":{"text":"á"}}"#, "broken.rule": "{",
        ]
        for (id, body) in files {
            try fileSystem.writeAtomically(
                Data(body.utf8), to: URL(fileURLWithPath: "/c/scenarios/" + id + ".json"), permissions: .ownerOnlyFile)
        }
        let outcome = run(
            ["--rules", "/c/rules.json", "--scenarios", "/c/scenarios", "--matrix", "/c/none.json", "--release"],
            fileSystem: fileSystem)
        #expect(!outcome.output.contains("[rule gated.rule]"), "\(outcome.output)")
        #expect(outcome.output.contains("error: placeholderWithoutGateTest [rule plain.rule]"))
        #expect(outcome.output.contains("error: placeholderWithoutGateTest [rule broken.rule]"))
    }

    @Test func usageErrors() {
        #expect(run(["--rules"]).exitCode == CompatLintCommand.exitUsage)
        #expect(run(["--bogus"]).output.hasPrefix("compat-lint: unknown argument --bogus"))
        #expect(run(["--today", "13/11/2026"]).exitCode == CompatLintCommand.exitUsage)
        let help = run(["--help"])
        #expect(help.exitCode == CompatLintCommand.exitClean)
        #expect(help.output == CompatLintCommand.usage)
        #expect(
            run(["--rules", "/nonexistent/rules.json"]).output == "compat-lint: cannot read /nonexistent/rules.json\n")
    }

    @Test func invalidRulesFileIsOneSchemaFinding() throws {
        let fileSystem = InMemoryFileSystem()
        try fileSystem.writeAtomically(
            Data(#"{"schemaVersion": 1}"#.utf8), to: URL(fileURLWithPath: "/r.json"), permissions: .ownerOnlyFile)
        let outcome = run(["--rules", "/r.json"], fileSystem: fileSystem)
        #expect(outcome.exitCode == CompatLintCommand.exitFindings)
        #expect(outcome.output.contains("error: schemaInvalid: $.rulesetVersion: missing required key"))
    }

    @Test func matrixAndScenarioHandling() throws {
        let fileSystem = InMemoryFileSystem()
        let rules = Build.document([
            Build.rule("manual.rule", match: RuleMatch(engines: [.qt]), automation: .manual),
            Build.rule("auto.rule", match: RuleMatch(engines: [.gecko])),
        ])
        try fileSystem.writeAtomically(
            JSONEncoder().encode(rules), to: URL(fileURLWithPath: "/c/rules.json"), permissions: .ownerOnlyFile)
        try fileSystem.writeAtomically(
            Data("{}".utf8), to: URL(fileURLWithPath: "/c/scenarios/auto.rule.json"), permissions: .ownerOnlyFile)
        try fileSystem.writeAtomically(
            Data("x".utf8), to: URL(fileURLWithPath: "/c/scenarios/README.md"), permissions: .ownerOnlyFile)
        let base = ["--rules", "/c/rules.json", "--scenarios", "/c/scenarios"]

        let noMatrix = run(base + ["--matrix", "/c/matrix.json"], fileSystem: fileSystem)
        #expect(noMatrix.exitCode == CompatLintCommand.exitClean)
        #expect(noMatrix.output.contains("note: matrix /c/matrix.json not found"))
        #expect(
            noMatrix.output.contains(
                "warning: manualTestWithoutMatrixRow [rule manual.rule]: compat/matrix.json is missing"))
        #expect(noMatrix.output.contains("warning: unknownScenario [rule manual.rule]"))
        #expect(!noMatrix.output.contains("[rule auto.rule]"))

        try fileSystem.writeAtomically(
            Data("[]".utf8), to: URL(fileURLWithPath: "/c/matrix.json"), permissions: .ownerOnlyFile)
        let badMatrix = run(base + ["--matrix", "/c/matrix.json"], fileSystem: fileSystem)
        #expect(badMatrix.exitCode == CompatLintCommand.exitFindings)
        #expect(badMatrix.output.contains("error: schemaInvalid: matrix $: wrong type"))
    }

    @Test func gitHubActionsAnnotations() {
        let outcome = run(seededArguments, environment: ["GITHUB_ACTIONS": "true"])
        #expect(outcome.output.contains("::warning::unverifiedTestedEntry"))
        #expect(!outcome.output.contains("\nwarning: "))
    }

    @Test func missingScenarioFolderIsANote() {
        let outcome = run(seededArguments.dropLast(2) + ["--scenarios", "/nonexistent/scenarios"])
        #expect(outcome.output.hasPrefix("note: scenario folder /nonexistent/scenarios not found\n"))
    }
}
