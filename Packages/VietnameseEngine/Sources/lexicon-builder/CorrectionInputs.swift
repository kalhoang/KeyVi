// SPDX-License-Identifier: MPL-2.0
//
// The inputs of the typo correction data (spec/01-engine.md 11A, ENG-R1120): the keyboard neighbours table of
// ENG-R1113 (a reviewed input, checked against its derivation from the QWERTY rows), and the unmarked shapes of
// ENG-R1110 (d) and the usual-order Telex keyings of ENG-R1125, both generated from the engine's tier tables like the
// viability structure (ENG-R346), never hand-written. ENG-T56 compares the shapes and keyings with an independent
// computation from the oracle's side (`KeyingOracle`, CorrectionDataTests).

import Foundation
import VietnameseEngine

/// The QWERTY neighbours of the substitution edit (ENG-R1113), 26 entries, symmetric.
enum KeyboardNeighbours {
    /// The three letter rows of the standard ANSI QWERTY layout, top to bottom.
    static let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]

    /// The table computed from `rows`: a key at index `i` of a row neighbours, in this order, indices `i` and `i + 1`
    /// of the row above, its row mates `i - 1` and `i + 1`, and indices `i - 1` and `i` of the row below (the rows
    /// are staggered by half a key). This is the order in which ENG-R1113 writes the table.
    static func derived() -> [Character: String] {
        let letters = rows.map(Array.init)
        func keys(_ row: Int, _ indices: [Int]) -> [Character] {
            guard letters.indices.contains(row) else { return [] }
            return indices.filter { letters[row].indices.contains($0) }.map { letters[row][$0] }
        }
        var table: [Character: String] = [:]
        for (row, keysOfRow) in letters.enumerated() {
            for (index, letter) in keysOfRow.enumerated() {
                let above = keys(row - 1, [index, index + 1])
                let mates = keys(row, [index - 1, index + 1])
                let below = keys(row + 1, [index - 1, index])
                table[letter] = String(above + mates + below)
            }
        }
        return table
    }

    /// Parses `letter<TAB>neighbours` lines (`#` starts a comment); fails with the line number on a malformed line.
    static func load(_ url: URL) throws -> [Character: String] {
        let name = url.lastPathComponent
        var table: [Character: String] = [:]
        for (number, line) in FileIO.contentLines(try FileIO.readUTF8(url)) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 2, fields[0].count == 1, let letter = fields[0].first, isLetter(letter) else {
                throw BuilderError("\(name) line \(number): expected 'letter<TAB>neighbours' with a letter a-z")
            }
            let neighbours = Array(fields[1])
            guard !neighbours.isEmpty, neighbours.allSatisfy(isLetter), Set(neighbours).count == neighbours.count,
                !neighbours.contains(letter)
            else {
                throw BuilderError(
                    "\(name) line \(number): the neighbours of '\(letter)' must be distinct letters a-z other than it")
            }
            guard table.updateValue(fields[1], forKey: letter) == nil else {
                throw BuilderError("\(name) line \(number): duplicate letter '\(letter)'")
            }
        }
        return table
    }

    /// ENG-R1120 (3): the build fails unless the table covers the 26 letters, every neighbour is a letter of the
    /// table, the table is symmetric and it equals `derived()` (compared as sets per letter).
    static func check(_ table: [Character: String]) throws {
        let alphabet = Set("abcdefghijklmnopqrstuvwxyz")
        guard Set(table.keys) == alphabet else {
            let missing = String(alphabet.subtracting(table.keys).sorted())
            throw BuilderError("keyboard neighbours: \(table.count) letters, expected 26 (missing: \(missing))")
        }
        var problems: [String] = []
        for (letter, neighbours) in table.sorted(by: { $0.key < $1.key }) {
            for neighbour in neighbours {
                if !alphabet.contains(neighbour) {
                    problems.append("'\(letter)' lists '\(neighbour)', which is not a letter a-z")
                } else if table[neighbour]?.contains(letter) != true {
                    problems.append("'\(letter)' lists '\(neighbour)' but '\(neighbour)' does not list '\(letter)'")
                }
            }
        }
        let expected = derived()
        for letter in alphabet.sorted() where Set(table[letter] ?? "") != Set(expected[letter] ?? "") {
            problems.append("'\(letter)': \(table[letter] ?? ""), the QWERTY rows give \(expected[letter] ?? "")")
        }
        guard problems.isEmpty else {
            throw BuilderError("keyboard neighbours:\n  " + problems.joined(separator: "\n  "))
        }
    }

    /// The resource file: one `letter<TAB>neighbours` line per letter, sorted by letter, final newline.
    static func resourceText(_ table: [Character: String]) -> String {
        joinedLines(table.keys.sorted().map { "\($0)\t\(table[$0] ?? "")" })
    }

    private static func isLetter(_ character: Character) -> Bool {
        character.isASCII && character.isLowercase && character.isLetter
    }
}

/// The unmarked shapes of ENG-R1110 (d): every Tier A and Tier B syllable, tone ignored, with `ă â` -> `a`, `ê` ->
/// `e`, `ô ơ` -> `o`, `ư` -> `u` and `đ` -> `d` (ENG-R1120 (4)).
enum UnmarkedShapes {
    static let plainLetters: [Character: Character] = [
        "ă": "a", "â": "a", "ê": "e", "ô": "o", "ơ": "o", "ư": "u", "đ": "d",
    ]

    static func generate() -> Set<String> {
        Set(SyllableTables.extendedPairs.map { unmarked($0.spelling) })
    }

    static func unmarked(_ spelling: String) -> String {
        String(spelling.map { plainLetters[$0] ?? $0 })
    }
}

/// The Vietnamese keyings of ENG-R1125: for each Tier A syllable (onset, rhyme, a tone the rhyme allows), (i) the
/// onset keys (`đ` as `dd`); (ii) the vowel letters each as its keys, a marked letter as its two keys
/// (`aa aw ee oo ow uw`), with `ươ` written both as `uwow` and as `uow`; (iii) when the rhyme's first vowel letter is
/// `ư` and the onset is a consonant other than `q`, also that `ư` as `w` alone (`thw`, `twngf`, `thwowng`); (iv) the
/// coda letters; (v) the tone key (`s f r x j`, none for the level tone) last and, when a coda exists, also right
/// before the coda. Every combination of (ii), (iii) and (v) is a keying; nothing else is (free orders such as
/// `gamar` are not the usual order). The literal `oo` of a loan rhyme (`boong`) is written letter by letter, which is
/// also the keying of `ô` (docs/decisions/0203-correction-data.md).
enum VietnameseKeyings {
    static let markKeys: [Character: String] = [
        "ă": "aw", "â": "aa", "ê": "ee", "ô": "oo", "ơ": "ow", "ư": "uw", "đ": "dd",
    ]

    static func toneKey(_ tone: Tone) -> String {
        switch tone {
        case .level: ""
        case .acute: "s"
        case .grave: "f"
        case .hook: "r"
        case .tilde: "x"
        case .dot: "j"
        }
    }

    static func generate() -> Set<String> {
        var keyings = Set<String>()
        for pair in SyllableTables.standardPairs {
            let onset = keys(pair.onset.spelling)
            let rhyme = Array(pair.rhyme.spelling)
            let vowels = Array(rhyme.prefix(pair.rhyme.vowelCount))
            let coda = String(rhyme.dropFirst(pair.rhyme.vowelCount))
            let standaloneW = pair.onset != .none && pair.onset != .qu
            for vowelKeys in vowelForms(vowels, standaloneW: standaloneW) {
                for tone in pair.tones {
                    let tone = toneKey(tone)
                    keyings.insert(onset + vowelKeys + coda + tone)
                    if !coda.isEmpty && !tone.isEmpty { keyings.insert(onset + vowelKeys + tone + coda) }
                }
            }
        }
        return keyings
    }

    /// The ways (ii) and (iii) write a vowel group.
    static func vowelForms(_ vowels: [Character], standaloneW: Bool) -> [String] {
        guard vowels.first == "ư" else { return [keys(String(vowels))] }
        let hornPair = vowels.count > 1 && vowels[1] == "ơ"
        let rest = keys(String(vowels.dropFirst(hornPair ? 2 : 1)))
        var leads = hornPair ? ["uwow", "uow"] : ["uw"]
        if standaloneW { leads.append(hornPair ? "wow" : "w") }
        return leads.map { $0 + rest }
    }

    static func keys(_ spelling: String) -> String {
        spelling.map { markKeys[$0] ?? String($0) }.joined()
    }
}
