// SPDX-License-Identifier: GPL-3.0-or-later
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
    static let exclamationAllowed: Set<String> = ["onboarding.done.title", paVerbatim]

    /// The donation block's share text is Pa's wording, verbatim (15/11/2026): the user posts it to other people in
    /// their own voice, so its "nè" and "!" stay. The only key exempt from the informal-word check.
    static let paVerbatim = "support.donate.shareText"

    /// Informal, slang or regional words that standard, neutral Vietnamese UI copy avoids (PRD-R62, PRD-R40).
    /// Compared as whole words, case-insensitively. "vô" is not listed: a whole-word check cannot tell the regional
    /// "vô đây" from the standard "vô hiệu hóa" or "vô tình" (review W2-F); copy review catches the former.
    static let informalWords: Set<String> = [
        "nha", "nhé", "nhá", "nghen", "hen", "nè", "hông", "hổng", "dzô", "ơi", "tui", "tớ", "mày", "tao",
        "oke", "okela", "vâng", "ạ", "xịn", "zô",
    ]

    /// Keys whose typed enum case is not referenced by name in the sources, with the reason.
    static let unusedTypedKeyAllowlist: [String: String] = [
        StatusText.hintTerminal.rawValue: "data-driven (PLT-R397): compat-rules.json secureInputHints maps Terminal",
        StatusText.hintITerm2.rawValue: "data-driven (PLT-R397): compat-rules.json secureInputHints maps iTerm2",
        StatusText.hintBrowser.rawValue:
            "data-driven (PLT-R397): compat-rules.json secureInputHints maps the browsers (decision 0005 Q40)",
    ]

    /// Secure-input hint copy that no compat rule uses yet. Empty since the browser rows of decision 0005 Q40
    /// (Cốc Cốc's since 2026-11-14): every hint the catalog has is reachable from a rule.
    static let hintsWithoutRule: Set<String> = []

    @Test func catalogFilesAreExactlyTheStringTables() throws {
        let onDisk = try CatalogInventory.tablesOnDisk()
        #if DEV_RECORDER
        #expect(onDisk == Set(StringTable.allCases.map(\.rawValue)))
        #expect(onDisk.count == 12)  // with DevRecorder (PLT-R904A), a table of Debug builds only
        #else
        #expect(onDisk.subtracting(["DevRecorder"]) == Set(StringTable.allCases.map(\.rawValue)))
        #expect(onDisk.count == 12)
        #endif
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
            let informal = Self.informalWords(in: entry.units["vi"]?.value ?? "")
            if entry.key != Self.paVerbatim {
                #expect(informal.isEmpty, "\(table.rawValue): \(entry.key) uses \(informal.sorted()) (PRD-R62)")
            }
        }
    }

    @Test func informalWordCheckMatchesWholeWordsAndAcceptsStandardOnes() {
        #expect(Self.informalWords(in: "Bấm vào đây nha.") == ["nha"])
        #expect(Self.informalWords(in: "Gõ nhanh hơn").isEmpty, "a whole word, not a prefix")
        #expect(Self.informalWords(in: "Vô hiệu hóa gõ tắt. Vô tình nhấn nhầm.").isEmpty)
    }

    /// The listed informal words that occur in `value`.
    static func informalWords(in value: String) -> Set<String> {
        Set(value.lowercased().split { !$0.isLetter }.map(String.init)).intersection(informalWords)
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
        // cannot survive behind an unused case. Case names such as `cancel`, `settings` or `email` also name
        // SwiftUI roles and other members, so a bare `.caseName` only counts in a file that names the enum or a
        // declaration typed with it (`onboardingAccessibility(_: OnboardingControl, ...)`); anywhere else the use
        // must be qualified (`EnumName.caseName`). Keys built from another value (icon states) are used through it.
        let sources = try CatalogInventory.productionSources().map { SwiftCodeText.strip($0.text) }
        let references = sources.map(CatalogInventory.MemberReferences.init(code:))
        let typedKeys = try CatalogInventory.typedKeys()
        let contexts = CatalogInventory.typedDeclarations(of: Set(typedKeys.map(\.enumName)), in: sources)
        var unused: [String] = []
        for typed in typedKeys where !typed.caseName.isEmpty {
            if Self.unusedTypedKeyAllowlist[typed.key] != nil { continue }
            if CatalogInventory.mirrorsIconState(typed) { continue }
            let context = contexts[typed.enumName, default: []].union([typed.enumName])
            if !references.contains(where: { $0.uses(typed.caseName, of: typed.enumName, context: context) }) {
                unused.append("\(typed.enumName).\(typed.caseName)")
            }
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

    @Test func memberReferenceScanFindsMemberReferencesOnly() {
        let found = CatalogInventory.MemberReferences(
            in: "x(MenuText.quit, .back) // .gone\ncase skip = \"a.b\"\nfoo.`continue`")
        #expect(found.bare.isSuperset(of: ["quit", "back"]))
        #expect(!found.bare.contains("skip") && !found.bare.contains("MenuText") && !found.bare.contains("x"))
        #expect(!found.bare.contains("gone") && !found.bare.contains("b"), "comments and literals are not code")
        #expect(found.qualified.contains("MenuText.quit") && !found.qualified.contains("MenuText.back"))
        #expect(found.names.isSuperset(of: ["MenuText", "x", "foo"]))
    }

    @Test func bareCaseNamesCountOnlyWhereTheEnumIsNamed() {
        // Review W2-F: `role: .cancel` in a file that never names `CommonText` must not keep `CommonText.cancel`.
        func uses(_ source: String, _ context: Set<String> = ["CommonText"]) -> Bool {
            CatalogInventory.MemberReferences(in: source).uses("cancel", of: "CommonText", context: context)
        }
        #expect(!uses("Button(role: .cancel) {}"))
        #expect(uses("let s = text(CommonText.cancel)"))
        #expect(!uses("let s = text(CommonText.cancelHint)"))
        #expect(!uses("case cancel = \"common.cancel\" // CommonText"), "a raw value is not a use")
        #expect(uses("func t(_ k: CommonText) {}\nt(.cancel)"))
        #expect(uses("x.commonAccessibility(.cancel)", ["CommonText", "commonAccessibility"]))
    }

    @Test func declarationsTypedWithAnEnumAreItsContext() {
        let code = SwiftCodeText.strip(
            """
            struct PracticeField: View {
                let control: OnboardingControl
            }
            extension View {
                func onboardingAccessibility(_ control: OnboardingControl, _ l: Localizer) -> some View { self }
                func other(_ value: Int) -> some View { self }
            }
            """)
        let contexts = CatalogInventory.typedDeclarations(of: ["OnboardingControl", "CommonText"], in: [code])
        #expect(contexts["OnboardingControl"] == ["PracticeField", "onboardingAccessibility"])
        #expect(contexts["CommonText", default: []].isEmpty)
    }

    @Test func uiSourcesHaveNoLiteralCopy() throws {
        // PRD-R62: no hard-coded user-visible text in any window; copy is `Text(verbatim:)` of a catalog value.
        let literal =
            /(Text|Button|Toggle|Label|Link|TableColumn|Picker|TextField|Menu)\(\s*"[^"]*"|\.help\(\s*"|setAccessibility(Label|Help)\(\s*"|(messageText|informativeText|title)\s*=\s*"[^"]+"|addButton\(withTitle:\s*"/
        for (path, lines) in try CatalogInventory.uiSources() {
            for (index, line) in lines.enumerated() {
                let code = line.split(separator: "//", maxSplits: 1).first.map(String.init) ?? ""
                #expect(code.firstMatch(of: literal) == nil, "\(path):\(index + 1) has literal copy")
                #expect(!Self.hasVerbatimLiteralCopy(code), "\(path):\(index + 1) has literal copy in Text(verbatim:)")
            }
        }
    }

    /// True when a `Text(verbatim: "...")` literal on the line contains a word of its own (two letters or more
    /// outside interpolations): `Text(verbatim: "Đóng")` is hard-coded copy, `"\(n). \(step)"` is formatting.
    static func hasVerbatimLiteralCopy(_ line: String) -> Bool {
        let interpolation = /\\\((?:[^()]|\([^()]*\))*\)/
        let formatting = line.replacing(interpolation, with: "")
        return formatting.contains(/Text\(verbatim:\s*"[^"]*\p{L}{2,}/)
    }

    @Test func verbatimLiteralScanFlagsWordsButNotFormatting() {
        // Review W2-F: the codebase renders copy with `Text(verbatim:)`, so a literal there is the likely leak.
        #expect(Self.hasVerbatimLiteralCopy(#"Text(verbatim: "Đóng")"#))
        #expect(Self.hasVerbatimLiteralCopy(#"Text(verbatim: "\(count) phút")"#))
        #expect(!Self.hasVerbatimLiteralCopy(#"Text(verbatim: "\(localizer.formatNumber(index + 1)). \(step)")"#))
        #expect(!Self.hasVerbatimLiteralCopy(#"Text(verbatim: "V")"#))
        #expect(!Self.hasVerbatimLiteralCopy("Text(verbatim: localizer.string(CommonText.close))"))
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
    /// Member references in the code of one source file (comments and literals stripped, see `SwiftCodeText`),
    /// collected in one pass: identifiers written after a period (`bare`), the same with the identifier written
    /// before the period (`qualified`, `Type.member`), and every identifier (`names`).
    struct MemberReferences {
        var bare: Set<String> = []
        var qualified: Set<String> = []
        var names: Set<String> = []

        init(in text: String) {
            self.init(code: SwiftCodeText.strip(text))
        }

        /// `code` is already stripped of comments and literals.
        init(code: String) {
            var current = ""
            var previous = ""
            var afterPeriod = false
            for character in code + " " {
                if character.isLetter || character.isNumber || character == "_" {
                    current.append(character)
                    continue
                }
                if !current.isEmpty {
                    names.insert(current)
                    if afterPeriod {
                        bare.insert(current)
                        if !previous.isEmpty { qualified.insert("\(previous).\(current)") }
                    }
                }
                if character == "." {
                    previous = current
                    afterPeriod = true
                } else {
                    previous = ""
                    afterPeriod = false
                }
                current = ""
            }
        }

        /// A case is used when written as `EnumName.caseName`, or as `.caseName` in a file that names one of
        /// `context` (the enum and the declarations typed with it).
        func uses(_ caseName: String, of enumName: String, context: Set<String>) -> Bool {
            qualified.contains("\(enumName).\(caseName)")
                || (bare.contains(caseName) && !names.isDisjoint(with: context))
        }
    }

    /// Per enum, the functions with a parameter of that type and the types with a stored property of that type:
    /// a call such as `onboardingAccessibility(.closeHelp, ...)` or `PracticeField(control: .tryItField)` infers
    /// the enum without naming it. `sources` are stripped code.
    static func typedDeclarations(of enumNames: Set<String>, in sources: [String]) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        let function = /func\s+(\w+)\s*(?:<[^>]*>)?\(([^)]*)\)/
        let typeDeclaration = /(?:struct|class|enum|actor)\s+(\w+)/
        let storedProperty = /(?:let|var)\s+\w+\s*:\s*(\w+)\s*(?:\n|=|$)/
        for code in sources {
            for match in code.matches(of: function) {
                let parameterTypes = match.output.2.split(separator: ",").compactMap { parameter in
                    parameter.split(separator: ":").dropFirst().first?
                        .split { !($0.isLetter || $0.isNumber || $0 == "_") }.first.map(String.init)
                }
                for name in enumNames.intersection(parameterTypes) {
                    result[name, default: []].insert(String(match.output.1))
                }
            }
            for match in code.matches(of: storedProperty) where enumNames.contains(String(match.output.1)) {
                let before = code[..<match.range.lowerBound]
                if let owner = before.matches(of: typeDeclaration).last {
                    result[String(match.output.1), default: []].insert(String(owner.output.1))
                }
            }
        }
        return result
    }

    /// `MenuText.icon*` cases mirror `StatusIconState.accessibilityLabelKey`; the state is what the code uses.
    static func mirrorsIconState(_ typed: TypedKey) -> Bool {
        typed.enumName == "MenuText" && StatusIconState.allCases.map(\.accessibilityLabelKey).contains(typed.key)
    }
}
