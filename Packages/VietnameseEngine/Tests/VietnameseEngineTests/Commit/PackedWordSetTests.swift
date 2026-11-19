// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngineTesting

@testable import VietnameseEngine

/// The packed word set of the unmarked shapes and the Vietnamese keyings (ENG-R1120, spec 12.2 sixth amendment):
/// words of 1 to 12 letters `a` to `z` as one `UInt64` each, 5 bits per letter, in a sorted array searched by halves;
/// any other word in an ordinary set beside it.
@Suite("Typo correction: the packed word set (ENG-R1120)")
struct PackedWordSetTests {
    @Test func holdsEveryWordAndNothingElse() {
        let set = PackedWordSet(["phair", "truong", "a", "zzzzzzzzzzzz", "thwowngf"])
        for word in ["phair", "truong", "a", "zzzzzzzzzzzz", "thwowngf"] { #expect(set.contains(word), "\(word)") }
        for word in ["phai", "phairs", "b", "", "truonh", "zzzzzzzzzzzy", "zzzzzzzzzzzzz", "Phair", "phai\u{0309}r"] {
            #expect(!set.contains(word), "\(word)")
        }
        #expect(set.count == 5)
        #expect(set.contains(Substring("xphairx").dropFirst().dropLast()))
    }

    @Test("A prefix, the word and a longer word stay three words (a letter is never the code 0 of the end)")
    func prefixesAreDistinct() {
        let set = PackedWordSet(["ab", "abc"])
        #expect(set.contains("ab") && set.contains("abc") && !set.contains("a") && !set.contains("abca"))
        #expect(PackedWordSet.pack(utf8: "ab".utf8)! < PackedWordSet.pack(utf8: "abc".utf8)!)
        #expect(PackedWordSet.pack(utf8: "abc".utf8)! < PackedWordSet.pack(utf8: "abd".utf8)!)
    }

    @Test("The packed values sort as the words' bytes do, so a sorted file is already the sorted array")
    func packingKeepsTheByteOrder() {
        var generator = SeededGenerator(seed: 19_112_026)
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        let words = (0..<2_000).map { _ in
            let length = Int.random(in: 1...12, using: &generator)
            return String((0..<length).map { _ in letters.randomElement(using: &generator)! })
        }
        let sorted = Set(words).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        let packed = sorted.map { PackedWordSet.pack(utf8: $0.utf8)! }
        #expect(zip(packed, packed.dropFirst()).allSatisfy { $0 < $1 })
        #expect(PackedWordSet(sorted).packed == packed)
        #expect(PackedWordSet(sorted.reversed()).packed == packed)  // any order: sorted once
    }

    @Test func packAndUnpackAreInverse() {
        for word in ["a", "z", "phair", "thwowngf", "abcdefghijkl", "zzzzzzzzzzzz"] {
            let value = PackedWordSet.pack(utf8: word.utf8)!
            var bytes = [UInt8](repeating: 0, count: PackedWordSet.maximumLetters)
            let count = bytes.withUnsafeMutableBufferPointer { PackedWordSet.unpack(value, into: $0) }
            #expect(String(decoding: bytes.prefix(count), as: UTF8.self) == word)
        }
        // Only 1 to 12 letters `a` to `z` fit.
        for word in ["", "abcdefghijklm", "Phair", "truong2", "đi", "well-known"] {
            #expect(PackedWordSet.pack(utf8: word.utf8) == nil, "\(word)")
        }
    }

    @Test("Words that do not fit are kept apart and still found")
    func wordsThatDoNotFitAreKeptApart() {
        let words = ["abcdefghijklm", "Truong", "đi", "a4", "", "phair"]
        let set = PackedWordSet(words)
        for word in words { #expect(set.contains(word), "\(word.debugDescription)") }
        #expect(set.count == words.count && set.packed.count == 1)
        #expect(!set.contains("abcdefghijkl") && !set.contains("truong"))
        #expect(Array("abcdefghijklm".utf8).withUnsafeBufferPointer { set.contains(utf8: $0) })
    }

    @Test func duplicatesCountOnce() {
        let set = PackedWordSet(["phair", "thach", "phair", "abcdefghijklmn", "abcdefghijklmn", "thach"])
        let expected = ["phair", "thach"].map { PackedWordSet.pack(utf8: $0.utf8)! }
        #expect(set.count == 3 && set.packed == expected)
    }

    @Test("The loader's form: packed values in the files' order, sorted only when they are not")
    func fromPackedValues() {
        let values = ["phair", "phis", "thach"].map { PackedWordSet.pack(utf8: $0.utf8)! }
        let set = PackedWordSet(packed: values, others: WordSet(["abcdefghijklmn"]))
        #expect(set.contains("phis") && set.contains("abcdefghijklmn") && !set.contains("phi") && set.count == 4)
        #expect(set.sharesStorage(with: PackedWordSet(packed: set.packed)))
        let unsorted = PackedWordSet(packed: values.reversed() + values)
        #expect(unsorted.packed == values && unsorted.count == 3)
    }

    @Test("The array holds no spare room beyond an exact allocation: its storage is what ENG-R1120 counts")
    func noSpareCapacity() {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        let words = (0..<1_000).map { "w" + String(repeating: "a", count: $0 % 10) + String(letters[$0 % 26]) }
        for set in [PackedWordSet(words), PackedWordSet(words.reversed())] {
            #expect(set.packed.capacity == [UInt64](repeating: 0, count: set.packed.count).capacity)
        }
    }

    @Test func emptyHoldsNothing() {
        #expect(PackedWordSet.empty.count == 0 && !PackedWordSet.empty.contains("a"))
        #expect(!PackedWordSet.empty.contains(""))
        #expect(PackedWordSet([]).count == 0)
    }

    @Test(.enabled(if: AllocationCounter.isAvailable, "the malloc hook is missing or a sanitizer replaced malloc"))
    func byteLookupsAllocateNothing() {
        let set = PackedWordSet(["phair", "thwowngf", "truong"])
        let words = ["phair", "phairs", "truong", String(repeating: "x", count: 24), "abcdefghijklm", "Phair"]
        func lookUp(_ buffer: UnsafeBufferPointer<UInt8>) -> Bool { set.contains(utf8: buffer) }
        for word in words { _ = Array(word.utf8).withUnsafeBufferPointer(lookUp) }
        for word in words {
            let bytes = Array(word.utf8)
            var found = false
            let allocations = bytes.withUnsafeBufferPointer { buffer in
                AllocationCounter.count { found = lookUp(buffer) }
            }
            #expect(allocations == 0, "\(word)")
            #expect(found == (word == "phair" || word == "truong"))
        }
    }
}
