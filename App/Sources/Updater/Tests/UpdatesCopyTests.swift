// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Updates String Catalog and the update-failed alert content (PRD-R43, PRD-R53, PRD-R62, PRD-R66): every key
// the code uses exists in vi and en with the same arguments, no dead copy, no brand literal, no dashes, the
// Vietnamese draft of 03-product.md verbatim, labels and hints on every control, download page per language.
// The catalog is read as compiled into this test bundle (project.yml), the same compilation the app gets.

#if UPDATER_TESTS
import AppKit
import AppModel
import Foundation
import ShellCore
import Testing

@Suite struct UpdatesCatalogTests {
    static func referencedKeys() -> Set<String> {
        Set(UpdatesText.allCases.map(\.rawValue))
            .union(UpdateFailureControl.allCases.flatMap { [$0.accessibilityLabelKey, $0.accessibilityHintKey] })
    }

    /// `%@`, `%d`, `%1$@` ... in order of appearance, positional forms normalised. `NSRegularExpression`: Swift
    /// `Regex` needs macOS 13 and this bundle builds for the macOS 12 floor (ADR 0315).
    static func arguments(_ text: String) -> [String] {
        let specifier = try! NSRegularExpression(pattern: #"%(?:\d+\$)?[@dDiuUxXfFeEgGcCsS]"#)
        return specifier.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range, in: text).map { String(text[$0].last ?? "@") }
        }
    }

    static func table(_ language: InterfaceLanguage) throws -> [String: String] {
        try TestResources.updatesTable(language)
    }

    @Test("Every key in vi and en, non-empty, with the same arguments")
    func viAndEnWithMatchingArguments() throws {
        let vi = try Self.table(.vietnamese)
        let en = try Self.table(.english)
        #expect(Set(vi.keys) == Set(en.keys))
        for (key, viValue) in vi {
            let enValue = try #require(en[key], "\(key) has no en value")
            #expect(!viValue.trimmingCharacters(in: .whitespaces).isEmpty, "\(key): empty vi")
            #expect(!enValue.trimmingCharacters(in: .whitespaces).isEmpty, "\(key): empty en")
            #expect(Self.arguments(viValue) == Self.arguments(enValue), "\(key): arguments differ")
        }
    }

    @Test("Every key the code uses exists and no copy is dead")
    func noMissingOrDeadKeys() throws {
        let keys = Set(try Self.table(.vietnamese).keys)
        #expect(Self.referencedKeys().subtracting(keys).isEmpty, "missing: \(Self.referencedKeys().subtracting(keys))")
        #expect(keys.subtracting(Self.referencedKeys()).isEmpty, "dead: \(keys.subtracting(Self.referencedKeys()))")
    }

    @Test("No brand literal (the app name is an argument), no dashes, no sudo")
    func noBrandLiteralsOrDashes() throws {
        let info = try BuiltBundleTests.info()
        let literals = [Brand.InfoKey.displayName, Brand.InfoKey.siteHost, Brand.InfoKey.slug].compactMap {
            info[$0] as? String
        }
        #expect(literals.count == 3 && literals.allSatisfy { !$0.isEmpty })
        for language in InterfaceLanguage.allCases {
            for (key, value) in try Self.table(language) {
                for literal in literals { #expect(!value.contains(literal), "\(key) hard-codes \(literal)") }
                #expect(!value.contains("\u{2014}") && !value.contains("\u{2013}"), "\(key) contains a dash")
                #expect(!value.lowercased().contains("sudo"), "\(key): PLT-R741")
            }
        }
    }
}

@Suite struct UpdateFailureContentTests {
    func content(_ language: InterfaceLanguage) -> UpdateFailureContent {
        UpdateFailureContent(
            localizer: TestResources.localizer(language), appName: UpdaterFixtures.appName,
            version: UpdaterFixtures.version, siteHost: UpdaterFixtures.siteHost)
    }

    @Test("PRD-R43: the Vietnamese copy is the 03-product.md draft, with the running version")
    func vietnameseDraftVerbatim() throws {
        let content = content(.vietnamese)
        #expect(
            "\(content.title) \(content.message)"
                == "Không tải được bản cập nhật. Bạn vẫn đang dùng bản 1.2.3, mọi thứ hoạt động bình thường.")
        #expect(content.buttons.map(\.title) == ["Thử lại", "Tải từ trang web", "Đóng"])
    }

    @Test("English is a faithful translation")
    func englishCopy() throws {
        let content = content(.english)
        #expect(content.title == "The update could not be downloaded.")
        #expect(content.message == "You are still using version 1.2.3, and everything works as usual.")
        #expect(content.buttons.map(\.title) == ["Try Again", "Download from Website", "Close"])
    }

    @Test(
        "PRD-R66: every button has a label and a hint; the download hint names the app",
        arguments: InterfaceLanguage.allCases)
    func labelsAndHints(language: InterfaceLanguage) throws {
        let content = content(language)
        for button in content.buttons {
            #expect(!button.accessibilityLabel.isEmpty && !button.accessibilityLabel.hasPrefix("updates."))
            #expect(!button.accessibilityHint.isEmpty && !button.accessibilityHint.hasPrefix("updates."))
        }
        let download = try #require(content.buttons.first { $0.control == .download })
        #expect(download.accessibilityHint.contains(UpdaterFixtures.appName))
    }

    @Test("The download page follows the interface language and the site's download route")
    func downloadPageMatchesSiteRoute() throws {
        let routes = try TestResources.siteRoutes()
        let line = try #require(routes.split(separator: "\n").first { $0.contains("id: \"download\"") })
        for (language, path) in UpdateFailureContent.downloadPaths {
            #expect(line.contains("\(language.rawValue): \"\(path)\""), "site route changed: \(line)")
        }
        #expect(content(.vietnamese).downloadURL.absoluteString == "https://\(UpdaterFixtures.siteHost)/tai-ve/")
        #expect(content(.english).downloadURL.absoluteString == "https://\(UpdaterFixtures.siteHost)/en/download/")
    }

    @Test("NSAlert responses map back to the button order; anything else closes")
    func alertResponseMapping() throws {
        let buttons = content(.vietnamese).buttons
        let first = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        #expect(AlertUpdateFailurePresenter.choice(for: .alertFirstButtonReturn, buttons: buttons) == .retry)
        #expect(AlertUpdateFailurePresenter.choice(for: .alertSecondButtonReturn, buttons: buttons) == .download)
        #expect(AlertUpdateFailurePresenter.choice(for: .alertThirdButtonReturn, buttons: buttons) == .close)
        #expect(AlertUpdateFailurePresenter.choice(for: .init(rawValue: first + 7), buttons: buttons) == .close)
        #expect(AlertUpdateFailurePresenter.choice(for: .abort, buttons: buttons) == .close)
    }
}
#endif
