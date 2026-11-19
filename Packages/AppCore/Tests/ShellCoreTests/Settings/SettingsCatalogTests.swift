// SPDX-License-Identifier: GPL-3.0-or-later
//
// PRD-R7 (no "not a setting" items), PRD-R24 (seven panes, order, Advanced content), PRD-R25 (one explanation per
// setting in vi and en), PRD-R6 (edits are explicit choices).

import AppModel
import Foundation
import SettingsStore
import TestSupport
import Testing

@testable import ShellCore

@Suite struct SettingsCatalogTests {
    @Test func sevenPanesInSpecOrder() {
        // PRD-R24 (Pa, 15/11/2026: About & Support split into About, Support and Licences)
        #expect(SettingsPaneKind.allCases == [.general, .typing, .apps, .macros, .about, .support, .licences])
        #expect(
            SettingsPaneKind.allCases.map(\.title) == [
                .paneGeneral, .paneTyping, .paneApps, .paneMacros, .paneAbout, .paneSupport, .paneLicences,
            ])
        #expect(SettingsPaneKind.allCases.filter { $0.paneReset == nil } == [.about, .support, .licences])
    }

    @Test func catalogIdentifiersAreTheSnapshot() {
        // Every setting the window shows, its defaults-table row and its settings.json key, in catalog order. A new
        // setting changes this list on purpose (W11-C added D28 and D29, decision of the product owner, 15/11/2026;
        // 1.1.0 adds the never-correct list, PRD-R81, and D30, PRD-R80).
        let snapshot = SettingItem.allCases.map { "\($0.rawValue) \($0.requirement) \($0.settingsKey ?? "-")" }
        #expect(
            snapshot == [
                "openAtLogin D17 -", "toggleHotkey D11 toggleHotkey", "rememberPerApp D12 rememberPerApp",
                "switchIndicator D14 showSwitchIndicator", "interfaceLanguage D18 interfaceLanguage",
                "soundOnSwitch D15 soundOnSwitch", "clickIconToToggle D16 clickIconToToggle",
                "layoutBinding PLT-R373 layoutBinding", "typingMethod D1 typingMethod",
                "tonePlacement D2 tonePlacement", "englishRestore D4 englishRestore",
                "keepAsTyped ENG-R860 keepAsTyped", "keepVietnamese ENG-R860 keepVietnamese",
                "neverCorrect PRD-R81 neverCorrect", "learnCollisionChoices D28 learnCollisionChoices",
                "typoCorrection D30 typoCorrection",
                "telexStandaloneW D5 telexStandaloneW", "telexBracketKeys D6 telexBracketKeys",
                "restoreHotkey D8 restoreHotkey", "lookaheadRevision D29 lookaheadRevision",
                "macrosEnabled D9 macrosEnabled", "updateChannel D21 updateChannel",
                "automaticallyCheckForUpdates D19 automaticallyCheckForUpdates",
                "automaticallyInstallUpdates D20 automaticallyInstallUpdates",
            ])
        #expect(SettingItem.learnCollisionChoices.pane == .typing && !SettingItem.learnCollisionChoices.isAdvanced)
        #expect(SettingItem.lookaheadRevision.pane == .typing && SettingItem.lookaheadRevision.isAdvanced)
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
                .typingMethod, .tonePlacement, .englishRestore, .keepAsTyped, .keepVietnamese, .neverCorrect,
                .learnCollisionChoices, .typoCorrection,
            ])
        #expect(
            SettingsCatalog.items(in: .typing, advanced: true) == [
                .telexStandaloneW, .telexBracketKeys, .restoreHotkey, .lookaheadRevision,
            ])
        #expect(SettingsCatalog.items(in: .macros, advanced: false) == [.macrosEnabled])
        #expect(
            SettingsCatalog.items(in: .about, advanced: false) == [
                .updateChannel, .automaticallyCheckForUpdates, .automaticallyInstallUpdates,
            ])
        #expect(SettingsCatalog.items(in: .apps, advanced: false).isEmpty)
        #expect(SettingsCatalog.items(in: .support, advanced: false).isEmpty)
        #expect(SettingsCatalog.items(in: .licences, advanced: false).isEmpty)
        #expect(SettingsPaneKind.general.hasAdvancedSection && SettingsPaneKind.typing.hasAdvancedSection)
        #expect(SettingsPaneKind.allCases.filter(\.hasAdvancedSection) == [.general, .typing])
    }

    @Test func notASettingItemsNeverAppear_PRDR7() {
        let shown = Set(SettingItem.allCases.map(\.requirement))
        for hidden in HiddenDefault.allCases {
            #expect(!shown.contains(hidden.rawValue), "\(hidden) must not be in the UI")
        }
        // Every user-facing default of section 4 that is a real setting is shown somewhere.
        let settings = ["D1", "D2", "D4", "D5", "D6", "D8", "D9", "D11", "D12", "D14", "D15", "D16", "D17", "D18"]
        for id in settings + ["D19", "D20", "D21", "D28", "D29", "D30"] {
            #expect(shown.contains(id), "\(id) has no control")
        }
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
            "updateChannel", "layoutBinding", "keepAsTyped", "keepVietnamese", "learnCollisionChoices",
            "lookaheadRevision", "typoCorrection", "neverCorrect",
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
            .updateChannel(.stable), .layoutBinding(LayoutModeBinding()), .learnCollisionChoices(true),
            .lookaheadRevision(true), .typoCorrection(true),
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
        SettingsEdit.neverCorrect(["androdi"]).apply(to: &lists)
        #expect(lists.keepAsTyped == ["text"] && lists.keepVietnamese == ["vieetj"])
        #expect(lists.neverCorrect == ["androdi"] && lists.explicitlySetKeys.contains("neverCorrect"))
        #expect(
            SettingsEdit.keepAsTyped([]).item == .keepAsTyped && SettingsEdit.keepVietnamese([]).item == .keepVietnamese
        )
        #expect(SettingsEdit.neverCorrect([]).item == .neverCorrect)
    }

    // MARK: 1.1.0: D30 and the never-correct list (PRD-R80, PRD-R81)

    @Test func d30SitsRightUnderD28InTheEnglishSectionAndIsNotAdvanced_PRDR80() throws {
        // PRD-R80: a main row of the English restore section, right under the D28 row, not under the Advanced
        // disclosure, so a user who wants it off finds it.
        let item = SettingItem.typoCorrection
        #expect(item.pane == .typing && !item.isAdvanced)
        #expect(item.requirement == "D30" && item.settingsKey == "typoCorrection")
        #expect(item.title == CatalogText(SettingsText.typoCorrectionTitle))
        #expect(item.explanation == CatalogText(SettingsText.typoCorrectionExplanation))
        let english = try #require(SettingsCatalog.sections(in: .typing).last)
        #expect(english.header == CatalogText(SettingsText.sectionEnglish))
        let d28 = try #require(english.items.firstIndex(of: .learnCollisionChoices))
        #expect(english.items.index(after: d28) == english.items.firstIndex(of: .typoCorrection))
        #expect(english.items.last == .typoCorrection)
    }

    @Test func theNeverCorrectListIsTheThirdListOfTheEnglishSection_PRDR81() throws {
        // PRD-R81: under "Giữ nguyên như đã gõ" and "Giữ là tiếng Việt", with the same controls (UserWordList).
        let item = SettingItem.neverCorrect
        #expect(item.pane == .typing && !item.isAdvanced)
        #expect(item.requirement == "PRD-R81" && item.settingsKey == "neverCorrect")
        #expect(item.title == CatalogText(SettingsText.neverCorrectTitle))
        #expect(item.explanation == CatalogText(SettingsText.neverCorrectExplanation))
        let english = try #require(SettingsCatalog.sections(in: .typing).last)
        let lists = english.items.filter { item in UserWordList.allCases.contains { $0.settingItem == item } }
        #expect(lists == [.keepAsTyped, .keepVietnamese, .neverCorrect])
        #expect(UserWordList.allCases.map(\.settingItem) == [.keepAsTyped, .keepVietnamese, .neverCorrect])
        #expect(english.items.firstIndex(of: .neverCorrect) == english.items.firstIndex(of: .keepVietnamese)! + 1)
        #expect(UserWordList.neverCorrect.fieldControl == .neverCorrectField)
        #expect(UserWordList.neverCorrect.addControl == .neverCorrectAdd)
        #expect(UserWordList.keepAsTyped.fieldControl == .keepAsTypedField)
        #expect(UserWordList.keepVietnamese.addControl == .keepVietnameseAdd)
    }

    @Test func d30IsDisabledWhileD4IsOffWithTheSuffix_PRDR80() {
        // PRD-R80: D30 follows D4, off and shown disabled while English restore is off; its explanation then ends
        // with the suffix. No other setting depends on another.
        var user = UserSettings()
        #expect(SettingItem.typoCorrection.dependsOn == .englishRestore)
        #expect(SettingItem.typoCorrection.isEnabled(in: user.resolved()))
        user.englishRestore = .set(false)
        let off = user.resolved()
        #expect(!SettingItem.typoCorrection.isEnabled(in: off))
        #expect(SettingItem.typoCorrection.disabledSuffix == CatalogText(SettingsText.typoCorrectionDisabledSuffix))
        for item in SettingItem.allCases where item != .typoCorrection {
            #expect(item.dependsOn == nil && item.disabledSuffix == nil, "\(item)")
            #expect(item.isEnabled(in: off), "\(item)")
        }
    }

    @Test func d30AndTheListNameTheRestoreKeyTheWayPRDR78Does() {
        // PRD-R80, PRD-R81: Escape by default, another key in words, or that the key is off, as the learned-words
        // sheet's empty state does (PRD-R78).
        let d30 = SettingItem.typoCorrection
        #expect(d30.explanation(restoreHotkey: .key(.escape)) == CatalogText(SettingsText.typoCorrectionExplanation))
        #expect(
            d30.explanation(restoreHotkey: .keyCombo(modifiers: [.control], keyCode: .space))
                == CatalogText(SettingsText.typoCorrectionExplanationOtherKey))
        #expect(d30.explanation(restoreHotkey: nil) == CatalogText(SettingsText.typoCorrectionExplanationNoKey))
        let list = SettingItem.neverCorrect
        #expect(list.explanation(restoreHotkey: .key(.escape)) == CatalogText(SettingsText.neverCorrectExplanation))
        #expect(
            list.explanation(restoreHotkey: .key(.returnKey))
                == CatalogText(SettingsText.neverCorrectExplanationOtherKey))
        #expect(list.explanation(restoreHotkey: nil) == CatalogText(SettingsText.neverCorrectExplanationNoKey))
        for item in SettingItem.allCases where item != .typoCorrection && item != .neverCorrect {
            #expect(item.explanation(restoreHotkey: nil) == item.explanation, "\(item) does not name the key")
        }
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
