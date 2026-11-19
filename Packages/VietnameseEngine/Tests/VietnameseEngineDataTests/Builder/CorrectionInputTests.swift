// SPDX-License-Identifier: MPL-2.0
//
// The inputs of the typo correction data that lexicon-builder derives (spec/01-engine.md 11A, ENG-R1120): the
// keyboard neighbours table of ENG-R1113, the unmarked shapes of ENG-R1110 (d) and the usual-order Telex keyings of
// ENG-R1125. ENG-T56 compares the shapes and keyings with an independent computation in CorrectionDataTests.

import Foundation
import Testing
import VietnameseEngine

@testable import lexicon_builder

@Suite struct CorrectionInputTests {
    /// The table of ENG-R1113 as the spec writes it.
    static let specTable: [Character: String] = [
        "q": "wa", "w": "qeas", "e": "wrsd", "r": "etdf", "t": "ryfg", "y": "tugh", "u": "yihj", "i": "uojk",
        "o": "ipkl", "p": "ol", "a": "qwsz", "s": "weadzx", "d": "ersfxc", "f": "rtdgcv", "g": "tyfhvb",
        "h": "yugjbn", "j": "uihknm", "k": "iojlm", "l": "opk", "z": "asx", "x": "sdzc", "c": "dfxv", "v": "fgcb",
        "b": "ghvn", "n": "hjbm", "m": "jkn",
    ]

    static var inputFile: URL { TestPaths.dataRoot.appendingPathComponent("inputs/keyboard-neighbours.txt") }

    // MARK: Keyboard neighbours (ENG-R1113, ENG-R1120 (3))

    @Test func theNeighboursTableIsSymmetricCoversTheAlphabetAndEqualsTheDerivation() throws {
        let derived = KeyboardNeighbours.derived()
        #expect(derived == Self.specTable, "the derivation lists each letter's neighbours in the spec's order")
        #expect(derived["q"] == "wa" && derived["s"] == "weadzx" && derived["m"] == "jkn")
        let loaded = try KeyboardNeighbours.load(Self.inputFile)
        #expect(loaded == derived)
        try KeyboardNeighbours.check(loaded)
        // `check` compares as sets per letter: another order of the same keys passes.
        var reordered = derived
        reordered["s"] = "xzdaew"
        try KeyboardNeighbours.check(reordered)
    }

    @Test func anAsymmetricTableFailsTheBuild() throws {
        var asymmetric = KeyboardNeighbours.derived()
        asymmetric["q"] = "w"  // `a` lists `q`, `q` no longer lists `a`
        #expect(throws: BuilderError.self) { try KeyboardNeighbours.check(asymmetric) }
        var missing = KeyboardNeighbours.derived()
        missing["m"] = nil
        missing["j"] = "uihkn"
        missing["k"] = "iojl"
        missing["n"] = "hjb"
        #expect(throws: BuilderError.self, "25 letters") { try KeyboardNeighbours.check(missing) }
        var symmetricButNotQwerty = KeyboardNeighbours.derived()
        symmetricButNotQwerty["q"] = "wap"
        symmetricButNotQwerty["p"] = "olq"
        #expect(throws: BuilderError.self, "differs from the derivation") {
            try KeyboardNeighbours.check(symmetricButNotQwerty)
        }
        var unknownKey = KeyboardNeighbours.derived()
        unknownKey["q"] = "wa1"
        #expect(throws: BuilderError.self) { try KeyboardNeighbours.check(unknownKey) }
    }

    @Test func malformedNeighbourLinesFailWithTheirLineNumber() throws {
        let directory = try TempDirectory.make("neighbours")
        defer { TempDirectory.remove(directory) }
        let file = directory.appendingPathComponent("keyboard-neighbours.txt")
        for (bad, line) in [
            ("# header\nq wa\n", 2), ("q\twa\nq\twa\n", 2), ("Q\twa\n", 1), ("qw\tea\n", 1), ("q\t\n", 1),
            ("q\twA\n", 1), ("q\twaw\n", 1), ("q\tqa\n", 1),
        ] {
            try write(bad, to: file)
            do {
                _ = try KeyboardNeighbours.load(file)
                Issue.record("\(bad.debugDescription) loaded")
            } catch let error as BuilderError {
                #expect(error.description.contains("line \(line)"), "\(bad.debugDescription): \(error)")
            }
        }
    }

    @Test func theResourceListsTheLettersInOrder() {
        let text = KeyboardNeighbours.resourceText(KeyboardNeighbours.derived())
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 26 && text.hasSuffix("\n"))
        #expect(lines.first == "a\tqwsz" && lines.last == "z\tasx")
        #expect(lines.contains("s\tweadzx"))
    }

    // MARK: Unmarked shapes (ENG-R1110 (d), ENG-R1120 (4))

    @Test func shapesHoldTheSpecExamples() {
        let shapes = UnmarkedShapes.generate()
        for shape in ["truong", "nguoi", "khong", "thuong", "chuop", "thach", "gruop", "glong", "chip", "drak", "dzo"] {
            #expect(shapes.contains(shape), "\(shape)")
        }
        for word in ["android", "gramar", "truing", "pair"] { #expect(!shapes.contains(word), "\(word)") }
        #expect(shapes.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { $0 >= 0x61 && $0 <= 0x7A } })
        print("ENG-R1120 unmarked shapes: \(shapes.count)")
    }

    // MARK: Vietnamese keyings (ENG-R1125, ENG-R1120 (5))

    @Test func keyingsHoldTheSpecExamples() {
        let keyings = VietnameseKeyings.generate()
        for keying in ["phair", "phis", "chinhs", "chisnh", "thieeus", "hoanf", "hoafn", "ddi", "quaanf"] {
            #expect(keyings.contains(keying), "\(keying)")
        }
        // thường: ươ as `uwow`, as `uow` and with the standalone `w`; the tone key last or before the coda.
        for keying in ["thuwowngf", "thuowngf", "thwowngf", "thuwowfng", "thuowfng", "thwowfng"] {
            #expect(keyings.contains(keying), "\(keying)")
        }
        // từng and thư: the standalone `w` for a leading ư after a consonant other than `q`.
        for keying in ["twngf", "tuwngf", "twfng", "thw", "thuw", "giwx"] {
            #expect(keyings.contains(keying), "\(keying)")
        }
        // Free order is not the usual order (`gamar` composes gẩm, yet `gramar` must still give `grammar`); no
        // standalone `w` without an onset (`ừ` is `uwf`); the literal `oo` of a loan rhyme is written letter by
        // letter, not with the escape of ENG-T02.
        for word in ["gamar", "wf", "wngs", "booong", "thuongf", "android", "grammar"] {
            #expect(!keyings.contains(word), "\(word)")
        }
        #expect(keyings.contains("uwf") && keyings.contains("boong"))
        #expect(keyings.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { $0 >= 0x61 && $0 <= 0x7A } })
        print("ENG-R1125 Vietnamese keyings: \(keyings.count) (spec 11A quotes 27,367 for the model of 18/11/2026)")
    }

    @Test func keyingsOfOneSyllableFollowTheUsualOrder() {
        // tuyết: onset t, vowels u y ê, coda t, sắc (a stop coda takes sắc or nặng only).
        let keyings = VietnameseKeyings.generate()
        #expect(keyings.contains("tuyeets") && keyings.contains("tuyeest"))
        #expect(keyings.contains("tuyeetj") && !keyings.contains("tuyeetf"))
        // A level tone has no tone key, so no second order.
        #expect(keyings.contains("tuyeen") && keyings.contains("tuyeenf") && keyings.contains("tuyeefn"))
    }
}
