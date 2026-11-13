// SPDX-License-Identifier: LicenseRef-App-Pending
//
// One audit over every String Catalog in App/Resources/Localization (PRD-R62, PRD-R66, ADR 0310, W2-F): the
// files are exactly the `StringTable` cases; every key has a translated vi and en value with the same format
// arguments; no empty, padded or stale value; no hard-coded brand (read from Config/Brand.xcconfig); no em or
// en dash; no exclamation mark except the final onboarding screen (PRD-R40); no slang or regional words in
// Vietnamese (PRD-R62); every key the code refers to exists; no key is orphaned; and every typed key is used by
// the app's sources, so dead copy cannot hide behind an unused enum case.

import Foundation
import Testing

@testable import ShellCore

@Suite struct CatalogAuditTests {
    static let languages: Set<String> = ["vi", "en"]

    /// PRD-R40: "no exclamation marks except the final screen".
    static let exclamationAllowed: Set<String> = ["onboarding.done.title"]

    /// Informal, slang or regional words that standard, neutral Vietnamese UI copy avoids (PRD-R62, PRD-R40).
    /// Compared as whole words, case-insensitively.
    static let informalWords: Set<String> = [
        "nha", "nhé", "nhá", "nghen", "hen", "nè", "vô", "hông", "hổng", "dzô", "ơi", "tui", "tớ", "mày", "tao",
        "oke", "okela", "vâng", "ạ", "xịn", "zô",
    ]

    /// Keys whose typed enum case is not referenced by name in the sources, with the reason.
    static let unusedTypedKeyAllowlist: [String: String] = [
        StatusText.hintTerminal.rawValue: "data-driven (PLT-R397): compat-rules.json secureInputHints maps Terminal",
        StatusText.hintITerm2.rawValue: "data-driven (PLT-R397): compat-rules.json secureInputHints maps iTerm2",
        StatusText.hintBrowser.rawValue:
            "data-driven (PLT-R397): no rule maps a browser yet; the browser hint rows are requested from W1-C",
    ]

    /// Secure-input hint copy that no compat rule uses yet (see `unusedTypedKeyAllowlist`).
    static let hintsWithoutRule: Set<String> = ["browser.passwordField"]

    @Test func catalogFilesAreExactlyTheStringTables() throws {
        let onDisk = try CatalogInventory.tablesOnDisk()
        #expect(onDisk == Set(StringTable.allCases.map(\.rawValue)))
        #expect(onDisk.count == 11)
    }

    @Test(arguments: StringTable.allCases)
    func everyEntryIsCompleteTranslatedAndConsistent(table: StringTable) throws {
        let catalog = try AuditedCatalog(table: table)
        #expect(catalog.sourceLanguage == "vi", "\(table.rawValue): source language")
        #expect(catalog.version == "1.0", "\(table.rawValue): catalog format version")
        #expect(!catalog.entries.isEmpty)
        for entry in catalog.entries {
            let location = "\(table.rawValue): \(entry.key)"
            // Keys are typed in code (ADR 0310), so Xcode never extracts them: a stale or extracted entry is an
            // accident.
            #expect(entry.extractionState == "manual", "\(location) extraction state")
            #expect(Set(entry.units.keys) == Self.languages, "\(location) languages")
            for (language, unit) in entry.units {
                #expect(unit.state == "translated", "\(location) [\(language)] state")
                let value = try #require(unit.value, "\(location) [\(language)] has no value")
                #expect(
                    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(location) [\(language)] empty")
                #expect(
                    value == value.trimmingCharacters(in: .whitespacesAndNewlines), "\(location) [\(language)] padded")
                #expect(!value.contains("  "), "\(location) [\(language)] double space")
                #expect(Self.percentSignsAreValid(value), "\(location) [\(language)] stray %")
            }
            let vi = entry.units["vi"]?.value ?? ""
            let en = entry.units["en"]?.value ?? ""
            #expect(FormatSpecifiers.of(vi) == FormatSpecifiers.of(en), "\(location) format arguments differ")
        }
    }

    @Test(arguments: StringTable.allCases)
    func valuesFollowTheWritingRules(table: StringTable) throws {
        let catalog = try AuditedCatalog(table: table)
        let brand = try CatalogInventory.brand()
        for entry in catalog.entries {
            for (language, unit) in entry.units {
                let value = unit.value ?? ""
                let location = "\(table.rawValue): \(entry.key) [\(language)]"
                let lowered = value.lowercased()
                // CLAUDE.md: the name is temporary and always a format argument.
                for literal in [brand.displayName, brand.slug, brand.siteHost] + brand.bundleIDs {
                    #expect(!lowered.contains(literal.lowercased()), "\(location) hard-codes \(literal)")
                }
                #expect(!value.contains("{{"), "\(location) has an unfilled spec placeholder")
                #expect(!value.contains("\u{2014}") && !value.contains("\u{2013}"), "\(location) contains a dash")
                #expect(!value.contains("\u{2026}"), "\(location): the spec writes an ellipsis as three periods")
                #expect(!lowered.contains("sudo"), "\(location): PLT-R741 forbids suggesting sudo")
                if !Self.exclamationAllowed.contains(entry.key) {
                    #expect(!value.contains("!"), "\(location): PRD-R40 allows ! only on the final onboarding screen")
                }
            }
            let vi = entry.units["vi"]?.value ?? ""
            let words = Set(vi.lowercased().split { !$0.isLetter }.map(String.init))
            let informal = words.intersection(Self.informalWords)
            #expect(informal.isEmpty, "\(table.rawValue): \(entry.key) uses \(informal.sorted()) (PRD-R62)")
        }
    }

    @Test func exclamationMarkIsOnlyOnTheFinalOnboardingScreen() throws {
        let catalog = try AuditedCatalog(table: .onboarding)
        let done = try #require(catalog.entries.first { $0.key == "onboarding.done.title" })
        #expect(done.units["vi"]?.value == "Xong rồi!")
    }

    @Test(arguments: StringTable.allCases)
    func everyReferencedKeyExistsAndNoKeyIsOrphaned(table: StringTable) throws {
        let referenced = try #require(
            try CatalogInventory.referencedKeys()[table], "\(table.rawValue) has no typed keys: add its enum")
        let present = Set(try AuditedCatalog(table: table).entries.map(\.key))
        #expect(referenced.subtracting(present).sorted() == [], "missing in \(table.rawValue)")
        #expect(present.subtracting(referenced).sorted() == [], "orphaned in \(table.rawValue)")
    }

    @Test func everyTypedKeyIsUsedByTheApp() throws {
        // A typed case keeps its key "referenced"; this checks the case itself is used somewhere, so dead copy
        // cannot survive behind an unused case. Keys built from another value (icon states) are used through it.
        let used = try CatalogInventory.productionSources().reduce(into: Set<String>()) {
            $0.formUnion(CatalogInventory.dottedIdentifiers(in: $1.text))
        }
        var unused: [String] = []
        for typed in try CatalogInventory.typedKeys() where !typed.caseName.isEmpty {
            if Self.unusedTypedKeyAllowlist[typed.key] != nil { continue }
            if CatalogInventory.mirrorsIconState(typed) { continue }
            if !used.contains(typed.caseName) { unused.append("\(typed.enumName).\(typed.caseName)") }
        }
        #expect(Array(Set(unused)).sorted() == [])
    }

    @Test func secureInputHintsOfTheRulesHaveCopyAndCopyHasARule() throws {
        // PLT-R397: the hint is chosen by `secureInputHints[].hintKey` in compat/rules.json.
        let data = try Data(contentsOf: RepoPaths.url("compat/rules.json"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hints = try #require(object["secureInputHints"] as? [[String: Any]])
        let ruleKeys = Set(hints.compactMap { $0["hintKey"] as? String })
        #expect(!ruleKeys.isEmpty)
        #expect(ruleKeys.subtracting(StatusText.knownSecureInputHintKeys).sorted() == [], "rule hint without copy")
        #expect(
            StatusText.knownSecureInputHintKeys.subtracting(ruleKeys).subtracting(Self.hintsWithoutRule).sorted() == [],
            "hint copy without a rule")
    }

    @Test func sourcesLookUpCopyOnlyThroughTypedKeys() throws {
        // A literal key in code would bypass the typed enums and therefore this audit.
        let literalLookup = /\.(string|format|contains)\(\s*"[a-z][A-Za-z0-9]*\.[A-Za-z0-9.]+"/
        for (path, text) in try CatalogInventory.productionSources() {
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                #expect(line.firstMatch(of: literalLookup) == nil, "\(path):\(index + 1) looks up a literal key")
            }
        }
    }

    @Test func dottedIdentifierScanFindsMemberReferencesOnly() {
        let found = CatalogInventory.dottedIdentifiers(
            in: "x(MenuText.quit, .back) // case skip = \"a.b\"\nfoo.`continue`")
        #expect(found.isSuperset(of: ["quit", "back", "b"]))
        #expect(!found.contains("skip") && !found.contains("MenuText") && !found.contains("x"))
    }

    @Test func uiSourcesHaveNoLiteralCopy() throws {
        // PRD-R62: no hard-coded user-visible text in any window; copy is `Text(verbatim:)` of a catalog value.
        let literal =
            /(Text|Button|Toggle|Label|Link|TableColumn|Picker|TextField|Menu)\(\s*"[^"]*"|\.help\(\s*"|setAccessibility(Label|Help)\(\s*"|(messageText|informativeText|title)\s*=\s*"[^"]+"|addButton\(withTitle:\s*"/
        for (path, lines) in try CatalogInventory.uiSources() {
            for (index, line) in lines.enumerated() {
                let code = line.split(separator: "//", maxSplits: 1).first.map(String.init) ?? ""
                #expect(code.firstMatch(of: literal) == nil, "\(path):\(index + 1) has literal copy")
            }
        }
    }

    @Test func percentSignCheckAcceptsSpecifiersAndRejectsStrays() {
        #expect(Self.percentSignsAreValid("%@ and %1$@, %2$ld, %d, 100%%"))
        #expect(!Self.percentSignsAreValid("tăng 100%."))
        #expect(!Self.percentSignsAreValid("50%"))
    }

    /// Every `%` starts a printf specifier or is the escape `%%`.
    static func percentSignsAreValid(_ value: String) -> Bool {
        let specifier = /%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|L|z|t|j)?[@dDiuUxXoOfFeEgGcCsSpaA]|%%/
        return !value.replacing(specifier, with: "").contains("%")
    }
}

extension CatalogInventory {
    /// Identifiers written after a period (`.caseName`, `Type.caseName`), collected in one pass over the source.
    static func dottedIdentifiers(in text: String) -> Set<String> {
        var result: Set<String> = []
        var current = ""
        var afterPeriod = false
        for character in text {
            if afterPeriod, character.isLetter || character.isNumber || character == "_" {
                current.append(character)
                continue
            }
            if afterPeriod, !current.isEmpty { result.insert(current) }
            current = ""
            afterPeriod = character == "."
        }
        if afterPeriod, !current.isEmpty { result.insert(current) }
        return result
    }

    /// `MenuText.icon*` cases mirror `StatusIconState.accessibilityLabelKey`; the state is what the code uses.
    static func mirrorsIconState(_ typed: TypedKey) -> Bool {
        typed.enumName == "MenuText" && StatusIconState.allCases.map(\.accessibilityLabelKey).contains(typed.key)
    }
}
