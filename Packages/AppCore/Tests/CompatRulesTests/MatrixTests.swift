// SPDX-License-Identifier: LicenseRef-App-Pending

import AppModel
import Foundation
import Testing

@testable import CompatRules

@Suite struct MatrixTests {
    private func entry(_ status: MatrixStatus, lastVerified: String?) -> MatrixEntry {
        MatrixEntry(
            bundleId: bundleKey("com.example.editor"), displayName: "Editor", category: "notes", tier: 1,
            status: status, note: LocalizedNote(vi: "Ghi chú", en: "Note"), lastVerified: lastVerified,
            appVersion: "1.0", macOS: "27.1", verifier: "tester")
    }

    /// QA-R19: entries not verified for 120 days display as not verified.
    @Test func displayStatusAgesOutAfter120Days() {
        let today = day("2026-11-13")
        #expect(MatrixStatusResolver.displayStatus(entry(.works, lastVerified: "2026-11-13"), today: today) == .works)
        // 2026-07-16 is 120 days before today; 2026-07-15 is 121.
        #expect(MatrixStatusResolver.displayStatus(entry(.works, lastVerified: "2026-07-16"), today: today) == .works)
        #expect(
            MatrixStatusResolver.displayStatus(entry(.works, lastVerified: "2026-07-15"), today: today) == .notVerified)
        #expect(
            MatrixStatusResolver.displayStatus(entry(.worksWithNotes, lastVerified: "2026-10-01"), today: today)
                == .worksWithNotes)
        #expect(
            MatrixStatusResolver.displayStatus(entry(.knownLimitation, lastVerified: "2026-10-01"), today: today)
                == .knownLimitation)
        #expect(
            MatrixStatusResolver.displayStatus(entry(.knownLimitation, lastVerified: "2025-01-01"), today: today)
                == .notVerified)
        #expect(MatrixStatusResolver.displayStatus(entry(.works, lastVerified: nil), today: today) == .notVerified)
        #expect(MatrixStatusResolver.displayStatus(entry(.works, lastVerified: "VERIFY"), today: today) == .notVerified)
        #expect(
            MatrixStatusResolver.displayStatus(entry(.notVerified, lastVerified: "2026-11-13"), today: today)
                == .notVerified)
        #expect(MatrixStatusResolver.displayStatus(entry(.works, lastVerified: "2026-12-01"), today: today) == .works)
    }

    @Test func displayStatusUsesTheUTCCalendarDay() {
        let lateEvening = day("2026-11-13").addingTimeInterval(86_399)
        #expect(
            MatrixStatusResolver.displayStatus(entry(.works, lastVerified: "2026-07-16"), today: lateEvening) == .works)
        let nextDay = lateEvening.addingTimeInterval(1)
        #expect(
            MatrixStatusResolver.displayStatus(entry(.works, lastVerified: "2026-07-16"), today: nextDay)
                == .notVerified)
    }

    @Test func loaderIsStrictAndNeverTraps() throws {
        #expect(MatrixLoader.load(contentsOf: RepoFiles.matrix)?.entries.isEmpty == false)
        #expect(MatrixLoader.load(contentsOf: URL(fileURLWithPath: "/nonexistent/compat-matrix.json")) == nil)
        #expect(throws: RulesValidationError.unsupportedSchemaVersion(2)) {
            try MatrixLoader.decode(Data(#"{"schemaVersion": 2, "entries": []}"#.utf8))
        }
        let unknown =
            #"{"schemaVersion": 1, "entries": [{"bundleId": "com.a.b", "displayName": "A", "category": "other", "status": "works", "issues": [], "matchedRuleId": "x"}]}"#
        #expect(
            throws: RulesValidationError.decoding(
                path: "$.entries[0].matchedRuleId", reason: "unknown key or null value")
        ) {
            try MatrixLoader.decode(Data(unknown.utf8))
        }
        let badStatus =
            #"{"schemaVersion": 1, "entries": [{"bundleId": "com.a.b", "displayName": "A", "category": "other", "status": "unverified", "issues": []}]}"#
        #expect(throws: RulesValidationError.self) { try MatrixLoader.decode(Data(badStatus.utf8)) }
    }

    @Test func publicInitialisersBuildEveryMatrixValue() throws {
        let cell = MatrixCell(result: .notApplicable, date: "2026-11-01", tester: "tester")
        let checks = MatrixChecks(
            telexBasic: cell, vniBasic: cell, inlineCompletion: cell, burstTyping: cell, backspaceReentry: cell,
            restoreHotkey: cell, perAppMemory: cell, macroExpansion: cell)
        var row = entry(.worksWithNotes, lastVerified: "2026-11-01")
        row.checks = checks
        row.issues = [12]
        let document = MatrixDocument(schemaVersion: 1, entries: [row])
        let data = try JSONEncoder().encode(document)
        #expect(try MatrixLoader.decode(data) == document)
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        let schema = JSONSchemaSubset(try RepoFiles.json(RepoFiles.schema("matrix.schema.json")))
        #expect(schema.errors(json).isEmpty)
        #expect(String(decoding: data, as: UTF8.self).contains(#""result":"n\/a""#))
    }

    /// PRD-R39 (initial tier lists) and QA-R17: every Tier 1 and Tier 2 app has a matrix row with its tier.
    @Test func seededMatrixCoversEveryTieredAppOfPRDR39() throws {
        let tier1 = [
            "Safari", "Google Chrome", "Microsoft Edge", "Firefox", "Arc", "Notes", "TextEdit", "Pages",
            "Microsoft Word",
            "Microsoft Excel", "Microsoft PowerPoint", "Microsoft Outlook", "Google Docs (Chrome)",
            "Google Docs (Safari)",
            "Google Sheets (Chrome)", "Google Sheets (Safari)", "Zalo", "Messenger", "Messenger (web, Chrome)",
            "Telegram",
            "Slack", "Discord", "Notion", "Obsidian", "Visual Studio Code", "Cursor", "Terminal", "iTerm2",
            "IntelliJ IDEA",
            "Spotlight", "Finder (rename)", "Figma",
        ]
        let tier2 = [
            "Raycast", "Alfred", "Ghostty", "WezTerm", "Warp", "tmux (in Terminal)", "Microsoft Teams", "Zoom (chat)",
            "LibreOffice", "Microsoft OneNote", "Anki", "Adobe Illustrator", "Adobe Photoshop", "Adobe InDesign",
            "Affinity",
            "Canva", "DaVinci Resolve", "Logi Options+ (coexistence)", "Windows App (Microsoft Remote Desktop)",
            "Chrome Remote Desktop (web)", "Chess (full-screen game)", "iPhone Mirroring",
        ]
        let rows = Dictionary(try Build.seededMatrix().entries.map { ($0.displayName, $0) }) { first, _ in first }
        for name in tier1 { #expect(rows[name]?.tier == 1, "Tier 1 row missing: \(name)") }
        for name in tier2 { #expect(rows[name]?.tier == 2, "Tier 2 row missing: \(name)") }
        let tiered = rows.values.filter { $0.tier != nil }
        #expect(tiered.count == tier1.count + tier2.count)
    }

    @Test func seededMatrixReferencesOnlyShippedRules() throws {
        let ruleIDs = Set(try Build.seededDocument().rules.map(\.id))
        for row in try Build.seededMatrix().entries {
            if let rule = row.ruleId { #expect(ruleIDs.contains(rule), "unknown rule in matrix: \(rule)") }
        }
    }
}
