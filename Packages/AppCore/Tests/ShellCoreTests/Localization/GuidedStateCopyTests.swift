// SPDX-License-Identifier: GPL-3.0-or-later
//
// PRD-R36, PRD-R66: the Apps pane state that shows a guided test result in force calls the feature by the name the
// menu and the Diagnostics window already give it: vi "thử tự động", en "guided test" (integrator decision of
// 2026-11-14 under Pa's delegation, decision 0005 Q44 row). The radio button, its explanation and its VoiceOver
// label and hint all use that one term, so a VoiceOver user hears the same name everywhere.

import Foundation
import Testing

@testable import ShellCore

@Suite struct GuidedStateCopyTests {
    static let vietnameseTerm = "thử tự động"
    static let englishTerm = "guided test"
    static let vietnameseTitle = "Theo kết quả thử tự động"
    /// The name wave 6 used first; no catalog may bring it back.
    static let retiredVietnameseTerm = "kiểm tra có hướng dẫn"

    /// The Apps pane copy of the guided state: the radio button, its explanation, its VoiceOver label and hint.
    static let appsKeys = [
        AppsText.compatGuidedTest.rawValue, AppsText.compatGuidedTestExplanation.rawValue,
        AppsControl.detailCompatibilityGuided.accessibilityLabelKey,
        AppsControl.detailCompatibilityGuided.accessibilityHintKey,
    ]

    @Test func theStateIsNamedAfterTheGuidedTest_PRDR36() throws {
        let apps = try Catalog(table: .apps)
        for key in [AppsText.compatGuidedTest.rawValue, AppsControl.detailCompatibilityGuided.accessibilityLabelKey] {
            let entry = try #require(apps.entries[key], "\(key) missing")
            #expect(entry.values["vi"] == Self.vietnameseTitle, "\(key)")
        }
    }

    @Test func everyStringOfTheStateUsesTheOneTerm_PRDR66() throws {
        let apps = try Catalog(table: .apps)
        for key in Self.appsKeys {
            let entry = try #require(apps.entries[key], "\(key) missing")
            let vi = try #require(entry.values["vi"], "\(key) [vi]")
            let en = try #require(entry.values["en"], "\(key) [en]")
            #expect(vi.lowercased().contains(Self.vietnameseTerm), "\(key) [vi]: \(vi)")
            #expect(!vi.lowercased().contains("hướng dẫn"), "\(key) [vi] uses the retired name: \(vi)")
            #expect(en.lowercased().contains(Self.englishTerm), "\(key) [en]: \(en)")
        }
    }

    @Test func theMenuAndDiagnosticsUseTheSameTerm() throws {
        // The term is borrowed from the surfaces that run the test; if they rename it, the Apps pane follows.
        let menu = try Catalog(table: .menu)
        let diagnostics = try Catalog(table: .diagnostics)
        let sources: [(Catalog, String)] = [
            (menu, MenuText.iconPausedDiagnosticsTest.rawValue),
            (diagnostics, DiagnosticsText.statePausedDiagnosticsTest.rawValue),
            (diagnostics, DiagnosticsText.guidedOffer.rawValue),
        ]
        for (catalog, key) in sources {
            let entry = try #require(catalog.entries[key], "\(catalog.name): \(key) missing")
            #expect(entry.values["vi"]?.lowercased().contains(Self.vietnameseTerm) == true, "\(catalog.name): \(key)")
            #expect(entry.values["en"]?.lowercased().contains(Self.englishTerm) == true, "\(catalog.name): \(key)")
        }
    }

    @Test(arguments: StringTable.allCases)
    func noCatalogUsesTheRetiredName(table: StringTable) throws {
        for (key, entry) in try Catalog(table: table).entries {
            #expect(
                entry.values["vi"]?.lowercased().contains(Self.retiredVietnameseTerm) != true,
                "\(table.rawValue): \(key)")
        }
    }
}
