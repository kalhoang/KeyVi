// SPDX-License-Identifier: GPL-3.0-or-later
//
// Helpers behind menu and onboarding actions (PLT-R540, PRD-R32, PRD-R40, PLT-R711). Workstream W2-A.

import AppModel
import CompatRules
import Foundation
import SettingsStore
import TestSupport
import Testing

@testable import InputHost

@Suite("Shell action helpers")
struct ShellActionsTests {
    @Test func textFocusOverrideIsAValidUserOverride_PLT_R540() throws {
        let bundle = try #require(BundleKey(rawValue: "com.example.editor"))
        let rule = try #require(TextFocusOverride.rule(for: bundle, strategy: .backspaceReplace, date: "2026-11-13"))
        let decoded = RulesLoader.decodeOverrides([rule])
        #expect(decoded.rejected.isEmpty)
        #expect(decoded.rules.first?.action.requireTextFocus == .never)
        #expect(decoded.rules.first?.action.strategy == .backspaceReplace)
        #expect(TextFocusOverride.ruleID(for: bundle).rawValue == "user.textfocus.com.example.editor")
        let hex = String(repeating: "ab", count: 32)
        let hashed = try #require(BundleKey.executable(sha256Hex: hex))
        #expect(TextFocusOverride.ruleID(for: hashed).rawValue == "user.textfocus.sha256-" + hex)
    }

    @Test func guidedTestSuggestionIsStoredAsAValidUserOverride_PLT_R1205() throws {
        let bundle = try #require(BundleKey(rawValue: "com.example.editor"))
        let rule = Rule(
            id: try #require(RuleID(rawValue: "user.suggested.com.example.editor")), summary: "Suggested",
            match: RuleMatch(bundleIds: [bundle]), action: RuleAction(strategy: .selectReplace),
            provenance: .userSuggestion(UserProvenance(source: "user-suggestion", date: "2026-11-13")))
        let date = Date(timeIntervalSince1970: 1_794_528_000)
        let stored = try #require(GuidedTestOverride.stored(rule, at: date))
        #expect(stored.createdAt == date)
        let decoded = RulesLoader.decodeOverrides([stored.rule])
        #expect(decoded.rejected.isEmpty)
        #expect(decoded.rules == [rule])
    }

    @Test func keyboardIdleCountsOnlyKeysSinceLaunch_PLT_R1105() {
        #expect(KeyboardIdleReading.secondsSinceLastKey(systemIdleSeconds: 12, secondsSinceLaunch: 600) == 12)
        #expect(KeyboardIdleReading.secondsSinceLastKey(systemIdleSeconds: 900, secondsSinceLaunch: 600) == .infinity)
        #expect(KeyboardIdleReading.secondsSinceLastKey(systemIdleSeconds: 600, secondsSinceLaunch: 600) == .infinity)
        #expect(
            KeyboardIdleReading.secondsSinceLastKey(systemIdleSeconds: .infinity, secondsSinceLaunch: 5) == .infinity)
        #expect(KeyboardIdleReading.secondsSinceLastKey(systemIdleSeconds: .nan, secondsSinceLaunch: 600) == 0)
        #expect(KeyboardIdleReading.secondsSinceLastKey(systemIdleSeconds: -1, secondsSinceLaunch: 600) == 0)
    }

    @Test func provenanceDayIsUTC() {
        #expect(TextFocusOverride.day(Date(timeIntervalSince1970: 1_800_000_000)) == "2027-01-15")
    }

    @Test func onboardingImportKeepsTheUsersMacros_PRD_R32() throws {
        let mine = StoredMacro(trigger: "vn", expansion: "Việt Nam")
        let file = Data("vn\tViet Nam imported\nko\tkhông\n".utf8)
        let merged = try #require(OnboardingMacroImport.merged(data: file, fileExtension: "txt", existing: [mine]))
        #expect(merged.first == mine, "keep mine for duplicates")
        #expect(merged.contains { $0.trigger == "ko" && $0.expansion == "không" })
        #expect(OnboardingMacroImport.merged(data: Data([0xFF, 0x00]), fileExtension: "bin", existing: []) == nil)
        let huge = Data(count: MacroImporter.maxFileBytes + 1)
        #expect(OnboardingMacroImport.merged(data: huge, fileExtension: "txt", existing: []) == nil)
    }

    /// PLT-R912: a file over the cap is rejected without being loaded into memory.
    @Test func importReadsAtMostTheCapFromDisk_PLT_R912() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "w2a-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let small = directory.appendingPathComponent("macros.txt")
        try Data("vn\tViệt Nam\n".utf8).write(to: small)
        #expect(OnboardingMacroImport.read(small) == Data("vn\tViệt Nam\n".utf8))
        let exact = directory.appendingPathComponent("exact.txt")
        try Data(count: MacroImporter.maxFileBytes).write(to: exact)
        #expect(OnboardingMacroImport.read(exact)?.count == MacroImporter.maxFileBytes)
        let large = directory.appendingPathComponent("large.txt")
        try Data(count: MacroImporter.maxFileBytes + 1).write(to: large)
        #expect(OnboardingMacroImport.read(large) == nil)
        #expect(OnboardingMacroImport.read(directory.appendingPathComponent("missing.txt")) == nil)
    }

    @Test func supportLinksPointAtTheSiteSections() throws {
        let site = try #require(URL(string: "https://example.org/"))
        #expect(
            SupportLinks.url(.conflicts, siteURL: site, language: .vietnamese).absoluteString
                == "https://example.org/ho-tro/#bo-go-khac")
        #expect(
            SupportLinks.url(.secureInput, siteURL: site, language: .english).absoluteString
                == "https://example.org/en/support/#secure-input")
        for topic in [SupportLinks.Topic.permission, .appSpecific] {
            for language in InterfaceLanguage.allCases {
                #expect(SupportLinks.url(topic, siteURL: site, language: language).host == "example.org")
            }
        }
    }

    @MainActor
    @Test func onboardingFastPollingReachesThePermissionMonitor_PLT_R711() async {
        let rig = HostRig()
        await rig.start()
        defer { rig.stop() }
        rig.controller.setPermissionFastPolling(true)
        #expect(rig.scheduler.repeatingIntervals.contains(.seconds(1)))
        rig.controller.setPermissionFastPolling(false)
        #expect(!rig.scheduler.repeatingIntervals.contains(.seconds(1)))
    }
}
