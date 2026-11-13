// SPDX-License-Identifier: LicenseRef-App-Pending

import Foundation
import Testing

@testable import SettingsStore

@Suite struct MacroValidatorTests {
    private func issue(_ shortcut: String, _ expansion: String = "x", others: [String] = []) -> MacroRowIssue? {
        MacroValidator.issue(
            shortcut: shortcut, expansion: expansion,
            others: others.map { StoredMacro(trigger: $0, expansion: "y") })
    }

    @Test func acceptsPrintableASCIIShortcutsUpTo32() {
        #expect(issue("vn") == nil)
        #expect(issue("@@") == nil)
        #expect(issue("k1") == nil)
        #expect(issue("a;b.c~") == nil)
        #expect(issue(String(repeating: "a", count: 32)) == nil)
    }

    @Test func rejectsEmptyAndTooLongShortcutPRDR29() {
        #expect(issue("") == .emptyShortcut)
        #expect(issue(String(repeating: "a", count: 33)) == .shortcutTooLong)
    }

    @Test func rejectsWhitespaceInShortcut() {
        #expect(issue("v n") == .shortcutHasWhitespace)
        #expect(issue("vn\t") == .shortcutHasWhitespace)
        #expect(issue("vn\u{00A0}") == .shortcutHasWhitespace)
    }

    @Test func rejectsVietnameseLettersAndNonASCIIPRDR29() {
        #expect(issue("đc") == .shortcutNotPrintableASCII)
        #expect(issue("việt") == .shortcutNotPrintableASCII)
        #expect(issue("a\u{7F}") == .shortcutNotPrintableASCII)
        #expect(issue("😀") == .shortcutNotPrintableASCII)
    }

    @Test func expansionLimitsCountCharacters() {
        #expect(issue("vn", "") == .emptyExpansion)
        #expect(issue("vn", String(repeating: "ệ", count: 4_000)) == nil)
        #expect(issue("vn", String(repeating: "a", count: 4_001)) == .expansionTooLong)
        #expect(issue("vn", "dòng 1\ndòng 2") == nil)
    }

    @Test func duplicatesAreCaseInsensitiveENGR1101() {
        #expect(issue("VN", others: ["vn"]) == .duplicate(of: "vn"))
        #expect(issue("vn", others: ["Vn"]) == .duplicate(of: "Vn"))
    }

    @Test func shadowingRejectsTrailingPunctuationPairPRDR29() {
        #expect(issue("vn.", others: ["vn"]) == .shadowedBy(shorter: "vn"))
        #expect(issue("VN!?", others: ["vn"]) == .shadowedBy(shorter: "vn"))
        #expect(issue("vn", others: ["vn."]) == .shadows(longer: "vn."))
        // A letter or digit right after the shorter shortcut is a different word, not shadowing. Digits are left
        // alone because they are boundaries in Telex but transform keys in VNI (method-dependent).
        #expect(issue("vnx", others: ["vn"]) == nil)
        #expect(issue("vn1", others: ["vn"]) == nil)
    }

    /// ENG-R1103: the punctuation key right after a complete trigger is a boundary at which that trigger already
    /// expands, so whatever follows it can never be typed as part of a longer trigger (`vn.x` behind `vn`).
    @Test func shadowingRejectsAnyContinuationAfterABoundaryENGR1103() {
        #expect(issue("vn.x", others: ["vn"]) == .shadowedBy(shorter: "vn"))
        #expect(issue("@@.x", others: ["@@"]) == .shadowedBy(shorter: "@@"))
        // A letter right after `@@` is not a boundary, so `@@x` is typed in one span and stays reachable.
        #expect(issue("@@x", others: ["@@"]) == nil)
        #expect(issue("Vn;1a", others: ["vn"]) == .shadowedBy(shorter: "vn"))
        #expect(issue("vn", others: ["vn.x"]) == .shadows(longer: "vn.x"))
        // The shorter trigger ends in punctuation and is followed by a letter: no boundary fires it early.
        #expect(issue("vn.x", others: ["vn."]) == nil)
        #expect(MacroValidator.shadowedBy("ab.c", among: ["ab", "zz"]) == .shadowedBy(shorter: "ab"))
    }

    @Test func punctuationClassification() {
        for scalar in "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".unicodeScalars {
            #expect(MacroValidator.isASCIIPunctuation(scalar))
        }
        for scalar in "aZ09 é".unicodeScalars { #expect(!MacroValidator.isASCIIPunctuation(scalar)) }
    }

    /// The editor agrees with the engine contract `MacroTable.ValidationError` on every macro fixture row:
    /// each row the validator accepts satisfies the engine's documented rules (ENG-R1101, ENG-R1103).
    @Test func acceptedFixtureRowsSatisfyEngineRules() {
        let rows =
            MacroImporter.parse(Data(MacroFixtures.tabSeparated.utf8), format: .tabSeparated)
            + MacroImporter.parse(Data(MacroFixtures.csv.utf8), format: .csv)
            + MacroImporter.parse(Data(MacroFixtures.textReplacementsXML.utf8), format: .textReplacementsPlist)
            + MacroImporter.parse(Data(MacroFixtures.appExport.utf8), format: .appExport)
        let accepted = MacroImporter.preview(rows, existing: []).new
        #expect(!accepted.isEmpty)
        for macro in accepted {
            #expect((1...32).contains(macro.trigger.unicodeScalars.count))
            #expect(macro.trigger.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) })
            #expect(macro.expansion.count <= 4_000)
        }
        let keys = accepted.map { $0.trigger.lowercased() }
        #expect(Set(keys).count == keys.count)
        for shorter in keys {
            for longer in keys where longer != shorter { #expect(!MacroValidator.isShadowed(longer, by: shorter)) }
        }
    }
}
