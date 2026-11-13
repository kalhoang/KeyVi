// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PRD-R47 item 1: the bug report picker lists the apps of the Apps pane (PRD-R34, most recent first), bundle IDs
// and display names only, without this app, bounded, and preselects the last frontmost app.

import AppModel
import Foundation
import SettingsStore
import Testing

@testable import ShellCore

@Suite struct RecentReportAppsTests {
    static let own = "invalid.example.app"
    let chat = BundleKey(rawValue: "com.example.Chat")!
    let term = BundleKey(rawValue: "com.example.Term")!
    let editor = BundleKey(rawValue: "com.example.Editor")!
    let ownKey = BundleKey(rawValue: "Invalid.Example.App")!
    let hashed = BundleKey.executable(sha256Hex: String(repeating: "ab", count: 32))!
    let now = Date(timeIntervalSince1970: 1_794_528_000)

    func modes(_ bundles: [BundleKey]) -> AppModesDocument {
        AppModesDocument(globalMode: .vietnamese, apps: bundles.map { AppModeEntry(bundle: $0, mode: .vietnamese) })
    }

    @Test func listsTheAppsPaneAppsMostRecentFirst() throws {
        let override = try #require(CompatibilityModeChoice.selectThenType.overrideRule(for: editor, date: "d"))
        let overrides = [StoredRuleOverride(createdAt: now, rule: override)]
        let document = modes([term, chat])
        let choices = RecentReportApps.choices(
            appModes: document, overrides: overrides, excluding: Self.own,
            name: { ["com.example.Chat": "Chat", "com.example.Term": "Terminal"][$0.rawValue] })
        #expect(choices.map(\.bundle) == AppsPaneModel.orderedBundles(appModes: document, overrides: overrides))
        #expect(
            choices == [
                BugReportAppChoice(bundle: term, name: "Terminal"), BugReportAppChoice(bundle: chat, name: "Chat"),
                BugReportAppChoice(bundle: editor, name: "com.example.Editor"),
            ])
    }

    @Test func leavesOutThisAppAndAppsWithoutABundleID() {
        // The own bundle ID is compared without case: LaunchServices treats bundle IDs case-insensitively.
        let choices = RecentReportApps.choices(
            appModes: modes([ownKey, hashed, chat]), overrides: [], excluding: Self.own, name: { _ in nil })
        #expect(choices.map(\.bundle) == [chat])
        let withoutOwn = RecentReportApps.choices(
            appModes: modes([ownKey, chat]), overrides: [], excluding: nil, name: { _ in nil })
        #expect(withoutOwn.map(\.bundle) == [ownKey, chat])
    }

    @Test func isBoundedToTheLimit() {
        let many = (0..<50).map { BundleKey(rawValue: "com.example.App\($0)")! }
        let choices = RecentReportApps.choices(
            appModes: modes(many), overrides: [], excluding: Self.own, name: { _ in nil })
        #expect(choices.count == RecentReportApps.limit)
        #expect(choices.first?.bundle == many[0])
        let three = RecentReportApps.choices(
            appModes: modes(many), overrides: [], excluding: Self.own, limit: 3, name: { _ in nil })
        #expect(three.map(\.bundle) == Array(many.prefix(3)))
        #expect(
            RecentReportApps.choices(appModes: modes(many), overrides: [], excluding: nil, limit: 0, name: { _ in nil })
                .isEmpty)
    }

    @Test func namesAreOneShortLineOrTheBundleID() {
        let long = String(repeating: "N", count: 300)
        let names = [
            "com.example.Chat": "  Chat\nwith\u{2028}breaks\t ", "com.example.Term": " \n ", "com.example.Editor": long,
        ]
        let choices = RecentReportApps.choices(
            appModes: modes([chat, term, editor]), overrides: [], excluding: Self.own, name: { names[$0.rawValue] })
        #expect(choices[0].name == "Chat with breaks")
        #expect(choices[1].name == "com.example.Term")
        #expect(choices[2].name.count == RecentReportApps.maximumNameLength)
        #expect(choices.allSatisfy { !$0.name.contains(where: \.isNewline) })
    }

    @Test func preselectsTheFocusedAppElseTheMostRecentOther() {
        let recent = [BugReportAppChoice(bundle: chat, name: "Chat"), BugReportAppChoice(bundle: term, name: "Term")]
        // Chosen from the status menu: the focused app is the app the user was typing in.
        #expect(
            RecentReportApps.preselection(focused: editor, recent: recent, excluding: Self.own, name: { _ in "Editor" })
                == BugReportAppChoice(bundle: editor, name: "Editor"))
        // A listed app keeps its listed name.
        #expect(
            RecentReportApps.preselection(focused: term, recent: recent, excluding: Self.own, name: { _ in "Other" })
                == recent[1])
        // Chosen from one of this app's windows: the most recent other app.
        #expect(
            RecentReportApps.preselection(focused: ownKey, recent: recent, excluding: Self.own, name: { _ in nil })
                == recent[0])
        #expect(
            RecentReportApps.preselection(focused: nil, recent: recent, excluding: Self.own, name: { _ in nil })
                == recent[0])
        #expect(
            RecentReportApps.preselection(focused: ownKey, recent: [], excluding: Self.own, name: { _ in nil }) == nil)
        // An app without a bundle ID is not offered.
        #expect(
            RecentReportApps.preselection(focused: hashed, recent: recent, excluding: Self.own, name: { _ in nil })
                == recent[0])
    }

    @Test func pickerStartsWithThePreselectedApp() {
        let recent = RecentReportApps.choices(
            appModes: modes([chat, term]), overrides: [], excluding: Self.own, name: { _ in nil })
        let preselected = RecentReportApps.preselection(
            focused: editor, recent: recent, excluding: Self.own, name: { _ in "Editor" })
        let sheet = BugReportSheet(apps: recent, preselected: preselected, brand: SheetFixtures.brand())
        #expect(sheet.apps.map(\.bundle) == [editor, chat, term])
        #expect(sheet.draft.app == editor && sheet.draft.appName == "Editor")
    }
}
