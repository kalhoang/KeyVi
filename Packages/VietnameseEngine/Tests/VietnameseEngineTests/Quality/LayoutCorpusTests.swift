// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// REG-16 and spec section 2: the `layouts` corpus types the same intent on five keyboard layouts. The
/// QA-R4 loader checks every row's output; this suite checks that the rows of a case agree and that the
/// corpus has teeth: reading the physical keys as US QWERTY key codes (what a key-code-based engine does)
/// changes the output on every other layout.
@Suite("Keyboard layouts (REG-16)")
struct LayoutCorpusTests {
    static let cases: [QACorpusCase] = QACorpusTests.load("layouts.tsv")

    /// US key positions (as in Scripts/generate-layout-corpus.py) and the US QWERTY characters on them.
    static let positions: [String] =
        "`1234567890-=qwertyuiop[]\\asdfghjkl;'".map(String.init) + ["iso"] + "zxcvbnm,./".map(String.init) + ["␣"]
    static let plain = Array("`1234567890-=qwertyuiop[]\\asdfghjkl;'\0zxcvbnm,./ ")
    static let shifted = Array("~!@#$%^&*()_+QWERTYUIOP{}|ASDFGHJKL:\"\0ZXCVBNM<>? ")

    /// The characters a key-code-based engine would see for the physical keys of a row: the US QWERTY
    /// character of each position (Option ignored).
    static func asQWERTYKeyCodes(_ note: String) -> String? {
        guard note.hasPrefix("physical: ") else { return nil }
        var text = ""
        for label in note.dropFirst("physical: ".count).split(separator: " ") {
            var name = Substring(label)
            var shift = false
            if name.first == "⇧" {
                shift = true
                name = name.dropFirst()
            } else if name.first == "⌥" {
                name = name.dropFirst()
            }
            guard let index = positions.firstIndex(of: String(name)) else { return nil }
            text.append(shift ? shifted[index] : plain[index])
        }
        return text
    }

    static func layoutName(_ corpusCase: QACorpusCase) -> String {
        String(corpusCase.id.split(separator: "-").last ?? "")
    }
    static func caseName(_ corpusCase: QACorpusCase) -> String { String(corpusCase.id.split(separator: "-")[1]) }

    @Test func everyLayoutGivesTheSameOutput() {
        let groups = Dictionary(grouping: Self.cases, by: Self.caseName)
        #expect(groups.count >= 10)
        for (name, rows) in groups {
            #expect(Set(rows.map(Self.layoutName)) == ["qwerty", "qwertz", "azerty", "dvorak", "colemak"], "\(name)")
            #expect(Set(rows.map(\.keys)).count == 1 && Set(rows.map(\.expected)).count == 1, "\(name)")
        }
    }

    @Test func keyCodesWouldTypeSomethingElse() throws {
        var differs: [String: Int] = [:]
        for corpusCase in Self.cases {
            let keyCodes = try #require(Self.asQWERTYKeyCodes(corpusCase.note), "\(corpusCase)")
            var driver = EngineDriver(
                configuration: corpusCase.configuration, resources: corpusCase.resources(macros: .empty))
            try driver.type(keyCodes)
            let layout = Self.layoutName(corpusCase)
            if layout == "qwerty" {
                #expect(driver.field.string == corpusCase.expected, "\(corpusCase)")
            } else if driver.field.string != corpusCase.expected {
                differs[layout, default: 0] += 1
            }
        }
        for layout in ["qwertz", "azerty", "dvorak", "colemak"] {
            #expect(differs[layout, default: 0] > 0, "\(layout): key codes give the same text")
        }
    }
}
