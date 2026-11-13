// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Catalog test for the four shell-owned String Catalogs (PRD-R62, PRD-R66, ADR 0310): every key in vi and en
// with matching format arguments, no empty values, no hard-coded brand, no dashes, every key the code uses
// present, and no dead copy. W2-F extends this to all ten tables.

import AppModel
import Foundation
import Testing
@testable import ShellCore

@Suite struct ShellCatalogTests {
    static let ownedTables: [StringTable] = [.common, .menu, .status, .onboarding]

    /// Keys the code refers to, per table.
    static func referencedKeys() -> [StringTable: Set<String>] {
        var keys: [StringTable: Set<String>] = [:]
        keys[.common] = Set(CommonText.allCases.map(\.rawValue))
        keys[.menu] = Set(MenuText.allCases.map(\.rawValue))
            .union(StatusIconState.allCases.map(\.accessibilityLabelKey))
        keys[.status] = Set(StatusText.allCases.map(\.rawValue))
        keys[.onboarding] = Set(OnboardingText.allCases.map(\.rawValue))
            .union(OnboardingControl.allCases.flatMap { [$0.accessibilityLabelKey, $0.accessibilityHintKey] })
        return keys
    }

    @Test(arguments: ownedTables)
    func everyKeyHasViAndEnWithMatchingArguments(table: StringTable) throws {
        let catalog = try Catalog(table: table)
        #expect(catalog.sourceLanguage == "vi")
        #expect(!catalog.entries.isEmpty)
        for (key, entry) in catalog.entries {
            let vi = try #require(entry.values["vi"], "\(table.rawValue): \(key) has no vi value")
            let en = try #require(entry.values["en"], "\(table.rawValue): \(key) has no en value")
            #expect(!vi.trimmingCharacters(in: .whitespaces).isEmpty, "\(key): empty vi")
            #expect(!en.trimmingCharacters(in: .whitespaces).isEmpty, "\(key): empty en")
            #expect(FormatSpecifiers.of(vi) == FormatSpecifiers.of(en), "\(table.rawValue): \(key) arguments differ")
        }
    }

    @Test(arguments: ownedTables)
    func noBrandLiteralsAndNoDashes(table: StringTable) throws {
        let catalog = try Catalog(table: table)
        let brand = try BrandFiles.values()
        for (key, entry) in catalog.entries {
            for value in entry.values.values {
                for literal in [brand.displayName, brand.siteHost, brand.bundleID] {
                    #expect(!value.contains(literal), "\(key) hard-codes \(literal); pass the brand as an argument")
                }
                #expect(!value.contains("\u{2014}") && !value.contains("\u{2013}"), "\(key) contains a dash")
                #expect(!value.lowercased().contains("sudo"), "\(key): PLT-R741 forbids suggesting sudo")
            }
        }
    }

    @Test(arguments: ownedTables)
    func everyReferencedKeyExistsAndNoCopyIsDead(table: StringTable) throws {
        let catalog = try Catalog(table: table)
        let referenced = Self.referencedKeys()[table] ?? []
        let present = Set(catalog.entries.keys)
        #expect(referenced.subtracting(present).sorted() == [], "missing in \(table.rawValue)")
        #expect(present.subtracting(referenced).sorted() == [], "unused in \(table.rawValue)")
    }

    @Test func everyOnboardingControlHasLabelAndHint() throws {
        // PRD-R66
        let catalog = try Catalog(table: .onboarding)
        for control in OnboardingControl.allCases {
            #expect(catalog.entries[control.accessibilityLabelKey] != nil, "\(control) label")
            #expect(catalog.entries[control.accessibilityHintKey] != nil, "\(control) hint")
        }
    }

    @Test func iconLabelsAreVerbatimFromPRDR10() throws {
        let app = try TemporaryAppBundle(catalogs: [.menu])
        let vi = Localizer(language: .vietnamese, appBundle: app.bundle)
        let en = Localizer(language: .english, appBundle: app.bundle)
        let expected: [StatusIconState: (String, String)] = [
            .vietnamese: ("Đang gõ tiếng Việt", "Vietnamese typing on"),
            .english: ("Đang gõ tiếng Anh", "English typing"),
            .ignoredApp: ("Bỏ qua ứng dụng này", "Ignored in this app"),
            .secureInputVietnamese: ("Ô bảo mật đang bật", "Secure input active"),
            .secureInputEnglish: ("Ô bảo mật đang bật", "Secure input active"),
            .paused: ("Tạm dừng: đang dùng bộ gõ khác", "Paused: another input source is active"),
            .notWorking: ("Chưa gõ được: cần cấp quyền", "Not working: permission needed"),
        ]
        for (state, (viLabel, enLabel)) in expected {
            #expect(vi.string(state.accessibilityLabelKey, table: .menu) == viLabel)
            #expect(en.string(state.accessibilityLabelKey, table: .menu) == enLabel)
        }
    }

    @Test func shellSourcesHaveNoLiteralProductCopy() throws {
        // Acceptance: no `Text("...")` literal for product copy in owned App sources (ADR 0310).
        let folders = ["App/Sources/Shell", "App/Sources/Onboarding"]
        let pattern = /(Text|Button|Toggle|Label|Link)\(\s*"[^"]+"|\.help\(\s*"|setAccessibility(Label|Help)\(\s*"|title:\s*"[^"]+"/
        for folder in folders {
            let directory = RepoPaths.url(folder)
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let code = line.split(separator: "//", maxSplits: 1).first.map(String.init) ?? ""
                    #expect(code.firstMatch(of: pattern) == nil, "\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
    }
}

/// Brand values from the brand files, so tests never hard-code the temporary name either.
enum BrandFiles {
    struct Values {
        var displayName: String
        var siteHost: String
        var bundleID: String
    }

    static func values() throws -> Values {
        let text = try String(contentsOf: RepoPaths.url("scripts/brand.env"), encoding: .utf8)
        var map: [String: String] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            map[parts[0]] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return Values(
            displayName: try #require(map["APP_DISPLAY_NAME"]), siteHost: try #require(map["APP_SITE_HOST"]),
            bundleID: try #require(map["APP_BUNDLE_ID_RELEASE"]))
    }
}
