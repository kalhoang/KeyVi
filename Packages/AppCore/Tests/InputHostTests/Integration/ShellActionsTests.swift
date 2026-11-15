// SPDX-License-Identifier: GPL-3.0-or-later
//
// Helpers behind menu actions (PLT-R540, PLT-R1205, PLT-R1105). Workstream W2-A.

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
        // The Support pane's "Mở trang hỗ trợ" (Pa, 15/11/2026): the page itself in the interface language.
        #expect(SupportLinks.page(siteURL: site, language: .vietnamese).absoluteString == "https://example.org/ho-tro/")
        #expect(
            SupportLinks.page(siteURL: site, language: .english).absoluteString == "https://example.org/en/support/")
    }

    @MainActor
    @Test func onboardingFastPollingReachesThePermissionMonitor_PLT_R711() async {
        let rig = HostRig()
        await rig.start()
        defer { rig.stop() }
        // The installed tap keeps its own 1 s live Accessibility check (PLT-R721); onboarding adds the 1 s poll.
        func oneSecondTimers() -> Int { rig.scheduler.repeatingIntervals.filter { $0 == .seconds(1) }.count }
        #expect(oneSecondTimers() == 1)
        rig.controller.setPermissionFastPolling(true)
        #expect(oneSecondTimers() == 2)
        rig.controller.setPermissionFastPolling(false)
        #expect(oneSecondTimers() == 1)
    }
}
