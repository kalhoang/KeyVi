// SPDX-License-Identifier: GPL-3.0-or-later
//
// PRD-R63, PRD-R65, ADR 0310: lookup per selected language, independent of the process language.

import AppModel
import Combine
import Foundation
import Testing

@testable import ShellCore

@Suite struct LocalizerTests {
    private func fixture() throws -> TemporaryAppBundle {
        try TemporaryAppBundle(tables: [
            "Menu": [
                "vi": ["menu.quit": "Thoát %@", "only.vi": "Chỉ có tiếng Việt", "same": "same"],
                "en": ["menu.quit": "Quit %@", "same": "same"],
            ],
            "Localizable": ["vi": ["common.back": "Quay lại"], "en": ["common.back": "Back"]],
        ])
    }

    @Test func selectedLanguageWinsRegardlessOfProcessLanguage() throws {
        let app = try fixture()
        let vi = Localizer(language: .vietnamese, appBundle: app.bundle)
        let en = Localizer(language: .english, appBundle: app.bundle)
        #expect(vi.format("menu.quit", table: .menu, "Example") == "Thoát Example")
        #expect(en.format("menu.quit", table: .menu, "Example") == "Quit Example")
        // `Localizable` is the common table (ADR 0310 renamed it from `Common`).
        #expect(vi.string("common.back", table: .common) == "Quay lại")
        #expect(en.string("common.back", table: .common) == "Back")
    }

    @Test func missingKeyFallsBackToVietnameseThenToKey() throws {
        let app = try fixture()
        let en = Localizer(language: .english, appBundle: app.bundle)
        #expect(en.string("only.vi", table: .menu) == "Chỉ có tiếng Việt")
        #expect(en.string("nowhere", table: .menu) == "nowhere")
        #expect(en.string("menu.quit", table: .status) == "menu.quit")
        // A translation equal to its key is still a hit.
        #expect(en.string("same", table: .menu) == "same")
        #expect(en.contains("same", table: .menu))
        #expect(en.contains("only.vi", table: .menu))
        #expect(!en.contains("nowhere", table: .menu))
    }

    @Test func missingLanguageBundleReturnsKey() throws {
        let app = try TemporaryAppBundle(tables: [:])
        let localizer = Localizer(language: .english, appBundle: app.bundle)
        #expect(localizer.string("x", table: .menu) == "x")
        #expect(localizer.format("x", table: .menu, "a") == "x")
    }

    @Test func formatWithoutArgumentsLeavesPercentSignsAlone() throws {
        let app = try TemporaryAppBundle(tables: ["Menu": ["vi": ["pct": "100%"]]])
        let localizer = Localizer(language: .vietnamese, appBundle: app.bundle)
        #expect(localizer.format("pct", table: .menu, arguments: []) == "100%")
    }

    @Test func numbersAndDatesFollowTheSelectedLanguage() throws {
        // PRD-R65
        let app = try fixture()
        let vi = Localizer(language: .vietnamese, appBundle: app.bundle)
        let en = Localizer(language: .english, appBundle: app.bundle)
        #expect(vi.formatNumber(1_234_567) == "1.234.567")
        #expect(en.formatNumber(1_234_567) == "1,234,567")
        let date = Date(timeIntervalSince1970: 1_794_528_000)  // 2026-11-13 UTC
        #expect(vi.formatDate(date) != en.formatDate(date))
        #expect(en.formatDate(date).contains("2026"))
        #expect(vi.formatDate(date).contains("2026"))
        #expect(vi.locale.language.languageCode?.identifier == "vi")
        #expect(en.locale.language.languageCode?.identifier == "en")
    }

    @Test func countdownIsMinutesAndSeconds() throws {
        let app = try fixture()
        let localizer = Localizer(language: .vietnamese, appBundle: app.bundle)
        #expect(localizer.formatCountdown(.seconds(65)) == "1:05")
        #expect(localizer.formatCountdown(.seconds(180)) == "3:00")
        #expect(localizer.formatCountdown(.seconds(-3)) == "0:00")
    }

    @Test func typedKeysResolveThroughTheirTable() throws {
        let app = try TemporaryAppBundle(catalogs: [.menu, .common])
        let vi = Localizer(language: .vietnamese, appBundle: app.bundle)
        let en = Localizer(language: .english, appBundle: app.bundle)
        #expect(vi.format(MenuText.quit, "Example") == "Thoát Example")
        #expect(en.format(MenuText.quit, "Example") == "Quit Example")
        #expect(vi.string(MenuText.modeVietnamese) == "Tiếng Việt")
        #expect(en.string(CommonText.back) == "Back")
    }
}

@MainActor
@Suite struct InterfaceLanguageModelTests {
    @Test func switchingLanguageChangesRenderedStringsWithoutRestart() throws {
        // PRD-R63
        let app = try TemporaryAppBundle(catalogs: [.menu])
        let model = InterfaceLanguageModel(language: .vietnamese, appBundle: app.bundle)
        #expect(model.localizer.string(MenuText.modeEnglish) == "Tiếng Anh")
        model.select(.english)
        #expect(model.localizer.language == .english)
        #expect(model.localizer.string(MenuText.modeEnglish) == "English")
        model.select(.vietnamese)
        #expect(model.localizer.string(MenuText.modeEnglish) == "Tiếng Anh")
    }

    @Test func selectingTheSameLanguageDoesNotNotifyObservers() throws {
        let app = try TemporaryAppBundle(catalogs: [.menu])
        let model = InterfaceLanguageModel(language: .english, appBundle: app.bundle)
        let changed = ChangeFlag()
        let observation = model.objectWillChange.sink { _ in changed.set() }
        model.select(.english)
        #expect(!changed.value)
        model.select(.vietnamese)
        #expect(changed.value)
        observation.cancel()
    }
}

/// Records that a change notification arrived.
final class ChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
