// SPDX-License-Identifier: GPL-3.0-or-later
//
// QA-R44 / ADR 0501: the issue block is stable, machine-parseable and round-trips through its parser.

import AppModel
import Foundation
import Testing

@testable import Diagnostics
@testable import TestSupport

@Suite struct IssueBlockTests {
    private static let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/issue-block-v1.txt")

    @Test func parseRoundTripsEveryBlockKey() throws {
        for report in [DiagnosticsFixtures.representativeReport(), DiagnosticsFixtures.minimalReport()] {
            let parsed = try #require(DiagnosticsRenderer.parseIssueBlock(DiagnosticsRenderer.issueBlock(report)))
            let rendered = Dictionary(IssueBlock.fields(report), uniquingKeysWith: { first, _ in first })
            for key in DiagnosticsBlockKey.allCases {
                #expect(parsed[key.rawValue] != nil, "missing \(key.rawValue)")
                #expect(parsed[key.rawValue] == rendered[key.rawValue])
            }
            #expect(parsed == rendered)
        }
    }

    @Test func labellerKeysCarryTheExpectedValues() throws {
        let parsed = try #require(
            DiagnosticsRenderer.parseIssueBlock(
                DiagnosticsRenderer.issueBlock(DiagnosticsFixtures.representativeReport())))
        #expect(parsed["report.bundleId"] == "com.example.Browser")
        #expect(parsed["focus.bundleId"] == "com.example.Browser")
        #expect(parsed["macos.version"] == "27.1")
        #expect(parsed["hw.arch"] == "arm64")
        #expect(parsed["input.method"] == "telex")
        #expect(parsed["report.symptom"] == "duplicated")
        #expect(parsed["report.appVersion"] == "156.0.8078.80")
        #expect(parsed["rule.params"]?.hasPrefix("{\"allowMultiCharEvents\":true") == true)
        #expect(parsed["settings.macroCount"] == "12")
        #expect(parsed["latency.t1.p99Us"] == "33")  // 20 µs samples fall in the bucket ending at 32.767 µs
        #expect(parsed["health.events"] == "3")
        #expect(
            parsed["health.event.03"]?.hasSuffix("secureInputEpisode holderKind=loginWindow durationMs=4000") == true)
    }

    @Test func unknownFormatVersionReturnsNil() {
        let block = DiagnosticsRenderer.issueBlock(DiagnosticsFixtures.minimalReport())
        #expect(
            DiagnosticsRenderer.parseIssueBlock(
                block.replacingOccurrences(of: "-diagnostics v1", with: "-diagnostics v2")) == nil)
        #expect(DiagnosticsRenderer.parseIssueBlock("no block here") == nil)
        #expect(DiagnosticsRenderer.parseIssueBlock("") == nil)
    }

    @Test func headerAcceptsAnySlugShapeFromAnyBuild() {
        #expect(IssueBlock.headerVersion("old-name-diagnostics v1") == 1)
        #expect(IssueBlock.headerVersion("  x2-diagnostics v12  ") == 12)
        #expect(IssueBlock.headerVersion("a-diagnostics-diagnostics v1") == 1)
        #expect(IssueBlock.headerVersion("Upper-diagnostics v1") == nil)
        #expect(IssueBlock.headerVersion("1abc-diagnostics v1") == nil)
        #expect(IssueBlock.headerVersion("-diagnostics v1") == nil)
        #expect(IssueBlock.headerVersion("abc-diagnostics v") == nil)
        #expect(IssueBlock.headerVersion("abc-diagnostics v1000") == nil)
        #expect(IssueBlock.headerVersion("abc-diagnostics vx") == nil)
    }

    @Test func headerUsesTheBundleSlugAndNormalisesOddOnes() {
        #expect(IssueBlock.header(slug: "sample-app") == "sample-app-diagnostics v1")
        #expect(IssueBlock.header(slug: "Sample App") == "sampleapp-diagnostics v1")
        #expect(IssueBlock.header(slug: "9lives") == "app9lives-diagnostics v1")
        #expect(IssueBlock.header(slug: "") == "app-diagnostics v1")
    }

    @Test func parserFollowsADR0501LineRules() throws {
        let text = """
            Pasted by a user:
            ~~~
            sample-app-diagnostics v1

            # comment
            hw.arch: arm64
            hw.arch: x86_64
            not a key line
            Bad.key: value
            input.method :  vni
            empty.value:
            ~~~
            after.fence: ignored
            """
        let parsed = try #require(DiagnosticsRenderer.parseIssueBlock(text))
        #expect(parsed == ["hw.arch": "arm64", "input.method": "vni", "empty.value": ""])
    }

    @Test func keysFollowTheADRPattern() {
        for key in IssueBlock.fields(DiagnosticsFixtures.representativeReport()).map(\.key) {
            #expect(IssueBlock.isKey(key), "bad key \(key)")
        }
        #expect(!IssueBlock.isKey("1abc"))
        #expect(!IssueBlock.isKey("a..b"))
        #expect(!IssueBlock.isKey("a.b-c"))
    }

    @Test func blockNeverExceedsTwoHundredLines() {
        var report = DiagnosticsFixtures.representativeReport()
        report.healthEvents = (0..<500).map {
            HealthEvent(kind: .flush, at: DiagnosticsFixtures.generatedAt.addingTimeInterval(Double($0)))
        }
        let lines = DiagnosticsRenderer.issueBlock(report).split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast()
        #expect(lines.count == IssueBlock.maximumLines)
        #expect(lines.first == "```text")
        #expect(lines.last == "```")
        // The newest events are kept.
        #expect(
            lines.dropLast().last?.contains(DiagnosticsFixtures.generatedAt.addingTimeInterval(499).formatted(.iso8601))
                == true)
    }

    @Test func valuesCannotBreakTheBlock() throws {
        var report = DiagnosticsFixtures.representativeReport()
        report.focus?.role = "AXTextField\n```\nfake.key: injected"
        report.system.modelIdentifier = "~~~Mac15,3"
        let block = DiagnosticsRenderer.issueBlock(report)
        let parsed = try #require(DiagnosticsRenderer.parseIssueBlock(block))
        #expect(parsed["fake.key"] == nil)
        #expect(parsed["focus.role"] == "AXTextField ``` fake.key: injected")
        #expect(parsed["hw.model"] == "Mac15,3")
        #expect(parsed["focus.secure"] == "false")
    }

    @Test func symptomsMapToTheADRValueSet() {
        let allowed: Set = ["missing", "duplicated", "wrongTone", "cannotType", "lag", "other"]
        for symptom in DiagnosticsReport.Symptom.allCases {
            #expect(allowed.contains(BlockFields.blockSymptom(symptom)))
        }
        #expect(BlockFields.blockSymptom(.lostLetters) == "missing")
        #expect(BlockFields.blockSymptom(.nothingTyped) == "cannotType")
    }

    @Test func hotkeysAndDurationsRenderWithoutCharacters() {
        #expect(BlockFields.hotkey(.modifierTap(.controlShift)) == "modifierTap:controlShift")
        #expect(BlockFields.hotkey(.keyCombo(modifiers: [.control, .option], keyCode: .space)) == "keyCombo:3:49")
        #expect(BlockFields.hotkey(.key(.escape)) == "key:53")
        #expect(BlockFields.microseconds(nil) == "")
        #expect(BlockFields.microseconds(1_000) == "1")
        #expect(BlockFields.microseconds(1_001) == "2")
        #expect(BlockFields.microseconds(.max) == String(UInt64.max / 1_000 + 1))
    }

    /// Golden fixture shared with the CI labeller check: `python3 -I scripts/parse-diagnostics.py --file
    /// Packages/AppCore/Tests/DiagnosticsTests/Fixtures/issue-block-v1.txt` prints the four labels. Regenerate
    /// with `UPDATE_GOLDEN=1 swift test --filter IssueBlockTests` after an intended format change.
    @Test func matchesTheGoldenFixture() throws {
        let block = DiagnosticsRenderer.issueBlock(DiagnosticsFixtures.representativeReport())
        if ProcessInfo.processInfo.environment["UPDATE_GOLDEN"] == "1" {
            try Data(block.utf8).write(to: Self.fixtureURL)
        }
        let golden = try String(contentsOf: Self.fixtureURL, encoding: .utf8)
        #expect(block == golden)
    }
}
