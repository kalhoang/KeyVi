// SPDX-License-Identifier: GPL-3.0-or-later
//
// PRD-R7 (no "not a setting" items), PRD-R24 (five panes, order, Advanced content), PRD-R25 (one explanation per
// setting in vi and en), PRD-R6 (edits are explicit choices).

import AppModel
import Foundation
import SettingsStore
import TestSupport
import Testing

@testable import ShellCore

@Suite struct SettingsCatalogTests {
    @Test func atMostFivePanesInSpecOrder() {
        // PRD-R24
        #expect(SettingsPaneKind.allCases == [.general, .typing, .apps, .macros, .aboutSupport])
        #expect(SettingsPaneKind.allCases.count <= 5)
        #expect(
            SettingsPaneKind.allCases.map(\.title) == [
                .paneGeneral, .paneTyping, .paneApps, .paneMacros, .paneAboutSupport,
            ])
    }

    @Test func paneContentsFollowPRDR24() {
        #expect(
            SettingsCatalog.items(in: .general, advanced: false) == [
                .openAtLogin, .toggleHotkey, .rememberPerApp, .switchIndicator, .interfaceLanguage,
            ])
        #expect(
            SettingsCatalog.items(in: .general, advanced: true) == [.soundOnSwitch, .clickIconToToggle, .layoutBinding])
        #expect(
            SettingsCatalog.items(in: .typing, advanced: false) == [
                .typingMethod, .tonePlacement, .englishRestore, .keepAsTyped, .keepVietnamese,
            ])
        #expect(
            SettingsCatalog.items(in: .typing, advanced: true) == [
                .telexStandaloneW, .telexBracketKeys, .restoreHotkey,
            ])
        #expect(SettingsCatalog.items(in: .macros, advanced: false) == [.macrosEnabled])
        #expect(
            SettingsCatalog.items(in: .aboutSupport, advanced: false) == [
                .updateChannel, .automaticallyCheckForUpdates, .automaticallyInstallUpdates,
            ])
        #expect(SettingsCatalog.items(in: .apps, advanced: false).isEmpty)
        #expect(SettingsPaneKind.general.hasAdvancedSection && SettingsPaneKind.typing.hasAdvancedSection)
        #expect(!SettingsPaneKind.apps.hasAdvancedSection && !SettingsPaneKind.aboutSupport.hasAdvancedSection)
    }

    @Test func notASettingItemsNeverAppear_PRDR7() {
        let shown = Set(SettingItem.allCases.map(\.requirement))
        for hidden in HiddenDefault.allCases {
            #expect(!shown.contains(hidden.rawValue), "\(hidden) must not be in the UI")
        }
        // Every user-facing default of section 4 that is a real setting is shown somewhere.
        let settings = ["D1", "D2", "D4", "D5", "D6", "D8", "D9", "D11", "D12", "D14", "D15", "D16", "D17", "D18"]
        for id in settings + ["D19", "D20", "D21"] { #expect(shown.contains(id), "\(id) has no control") }
        #expect(
            HiddenDefault.allCases.map(\.rawValue) == [
                "D3", "D7", "D10", "D13", "D22", "D23", "D24", "D25", "D26", "D27",
            ])
    }

    @Test func everySettingHasAnExplanationInViAndEn_PRDR25() throws {
        let l = try Localizers()
        for item in SettingItem.allCases {
            for localizer in [l.vi, l.en] {
                let title = localizer.string(item.title)
                let explanation = localizer.string(item.explanation)
                #expect(title != item.title.key, "\(item) title missing")
                #expect(explanation != item.explanation.key, "\(item) explanation missing")
                #expect(!explanation.contains("\n"), "\(item): one line")
                #expect(explanation != title)
            }
        }
        // PRD-R25 example for English restore.
        #expect(l.vi.string(SettingItem.englishRestore.explanation).contains("text"))
    }

    @Test func settingKeysMatchTheSettingsFile() {
        // Every visible setting except D17 and the word lists maps to a settings.json key the store knows.
        let known: Set<String> = [
            "typingMethod", "tonePlacement", "englishRestore", "telexStandaloneW", "telexBracketKeys", "restoreHotkey",
            "macrosEnabled", "toggleHotkey", "rememberPerApp", "showSwitchIndicator", "soundOnSwitch",
            "clickIconToToggle", "interfaceLanguage", "automaticallyCheckForUpdates", "automaticallyInstallUpdates",
            "updateChannel", "layoutBinding", "keepAsTyped", "keepVietnamese",
        ]
        for item in SettingItem.allCases where item != .openAtLogin {
            #expect(item.settingsKey.map(known.contains) == true, "\(item)")
        }
        #expect(SettingItem.openAtLogin.settingsKey == nil)
    }

    @Test func editsAreExplicitChoicesEvenWhenEqualToTheDefault_PRDR6() {
        let edits: [SettingsEdit] = [
            .typingMethod(.telex), .tonePlacement(.traditional), .englishRestore(true), .telexStandaloneW(true),
            .telexBracketKeys(false), .restoreHotkey(.key(.escape)), .macrosEnabled(true),
            .toggleHotkey(.defaultToggle),
            .rememberPerApp(true), .showSwitchIndicator(true), .soundOnSwitch(false), .clickIconToToggle(false),
            .interfaceLanguage(.vietnamese), .automaticallyCheckForUpdates(true), .automaticallyInstallUpdates(true),
            .updateChannel(.stable), .layoutBinding(LayoutModeBinding()),
        ]
        for edit in edits {
            var settings = UserSettings()
            edit.apply(to: &settings)
            #expect(settings.explicitlySetKeys == [edit.item.settingsKey], "\(edit)")
            #expect(settings.resolved() == UserSettings().resolved(), "\(edit) keeps the default value")
        }
        var lists = UserSettings()
        SettingsEdit.keepAsTyped(["text"]).apply(to: &lists)
        SettingsEdit.keepVietnamese(["vieetj"]).apply(to: &lists)
        #expect(lists.keepAsTyped == ["text"] && lists.keepVietnamese == ["vieetj"])
        #expect(
            SettingsEdit.keepAsTyped([]).item == .keepAsTyped && SettingsEdit.keepVietnamese([]).item == .keepVietnamese
        )
    }

    @Test func advancedDisclosureIsCollapsedUntilExpandedAndThenRemembered() {
        // PRD-R24
        let store = InMemoryKeyValueStore()
        let memory = AdvancedDisclosureMemory(store: store)
        #expect(!memory.isExpanded(.general) && !memory.isExpanded(.typing))
        memory.setExpanded(true, for: .general)
        #expect(AdvancedDisclosureMemory(store: store).isExpanded(.general))
        #expect(!memory.isExpanded(.typing))
        memory.setExpanded(false, for: .general)
        #expect(!memory.isExpanded(.general))
        #expect(AdvancedDisclosureMemory.key(for: .typing) == "settings.advancedExpanded.typing")
    }
}
