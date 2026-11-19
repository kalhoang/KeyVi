// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// The edit model of the typo correction (ENG-R1113) and of the Vietnamese check (ENG-R1125), section 11A.2.
@Suite("Typo correction: the edit model (ENG-R1113, ENG-R1125)")
struct EditModelTests {
    private let model = EditModel(neighbours: SpecFixtures.keyboardNeighbours)

    /// Every edit the model enumerates for `word`, in order, duplicates included.
    private func enumerated(_ word: String, positionRules: Bool) -> [String] {
        var result: [String] = []
        Array(word.utf8).withUnsafeBufferPointer { buffer in
            model.forEachEdit(of: buffer, positionRules: positionRules) { edit in
                result.append(String(decoding: edit, as: UTF8.self))
                return true
            }
        }
        return result
    }

    private func edits(_ word: String, positionRules: Bool = true) -> Set<String> {
        Set(enumerated(word, positionRules: positionRules))
    }

    @Test func transpositionsDeletionsInsertionsAndNeighbourSubstitutions_ENGR1113() {
        #expect(edits("androdi").contains("android"))  // transposition
        #expect(edits("whcih").contains("which"))
        #expect(edits("untill").contains("until"))  // deletion
        #expect(edits("arguement").contains("argument"))
        #expect(edits("gramar").contains("grammar"))  // insertion
        #expect(edits("libary").contains("library"))
        #expect(edits("servet").contains("server"))  // neighbouring key
        #expect(edits("hwllo").contains("hello"))
        // `e` and `a` are not neighbours: `grammer` never reaches `grammar` (S34).
        #expect(!edits("grammer").contains("grammar"))
        // One word reached by two edits is enumerated twice and counts once (ENG-R1114: the caller keeps the
        // distinct words).
        #expect(enumerated("gramar", positionRules: true).filter { $0 == "grammar" }.count == 2)
    }

    @Test func positionRulesProtectFirstAndLastLetters() {
        #expect(!edits("kbang").contains("bang"))  // the first letter, not doubled
        #expect(!edits("xcode").contains("code"))
        #expect(!edits("messi").contains("mess"))  // the last letter, not doubled
        #expect(!edits("biden").contains("bide"))
        #expect(!edits("pajama").contains("pajamas"))  // after the last letter, not repeating it
        #expect(!edits("leecher").contains("leeched"))  // a last `r` after `e` replaced by `d`
        #expect(!edits("absorber").contains("absorbed"))
        #expect(edits("aabout").contains("about"))
        #expect(edits("helpp").contains("help"))
        #expect(edits("committ").contains("commit"))
        // Inserting after the last letter is allowed when it repeats it; `r` to `d` elsewhere is allowed.
        #expect(edits("hel").contains("hell"))
        #expect(edits("ruby").contains("duby"))
    }

    @Test func withoutPositionRulesEveryEditIsEnumerated_ENGR1125() {
        #expect(edits("pahir", positionRules: false).contains("phair"))
        #expect(edits("pehis", positionRules: false).contains("phis"))
        #expect(edits("hoand", positionRules: false).contains("hoanf"))
        #expect(edits("htach", positionRules: false).contains("thach"))
        #expect(edits("chihns", positionRules: false).contains("chinhs"))
        // The position rules protect English words, not Vietnamese ones (ENG-R1125).
        #expect(edits("kbang", positionRules: false).contains("bang"))
        #expect(edits("messi", positionRules: false).contains("mess"))
        #expect(edits("pajama", positionRules: false).contains("pajamas"))
        #expect(edits("leecher", positionRules: false).contains("leeched"))
    }

    @Test("Edit counts follow the model: n - 1 transpositions, n deletions, 26 (n + 1) insertions, the neighbours")
    func countsFollowTheModel() {
        // `abc`: 2 transpositions, 3 deletions, 104 insertions, 4 + 4 + 4 substitutions.
        #expect(enumerated("abc", positionRules: false).count == 2 + 3 + 104 + 12)
        // With the position rules: no deletion of `a` or `c`, insertions after `c` only of `c`.
        #expect(enumerated("abc", positionRules: true).count == 2 + 1 + 79 + 12)
        // Equal neighbouring letters are never swapped (the swap gives the word itself).
        #expect(!enumerated("aab", positionRules: false).contains("aab"))
        // Bytes outside a-z have no neighbours; the model never fails on them.
        #expect(enumerated("a1", positionRules: false).count == 1 + 2 + 78 + 4)
    }

    @Test func enumerationStopsWhenTheBodyReturnsFalse() {
        var calls = 0
        Array("androdi".utf8).withUnsafeBufferPointer { buffer in
            model.forEachEdit(of: buffer, positionRules: true) { _ in
                calls += 1
                return calls < 5
            }
        }
        #expect(calls == 5)
    }

    @Test("Words longer than the scratch (31 letters) and the empty word have no edits")
    func lengthBounds() {
        #expect(enumerated(String(repeating: "a", count: EditModel.maximumLength + 1), positionRules: false).isEmpty)
        #expect(enumerated("", positionRules: false).isEmpty)
        let longest = enumerated(String(repeating: "ab", count: 15) + "c", positionRules: false)
        #expect(longest.contains { $0.utf8.count == 32 })
    }

    @Test(.enabled(if: AllocationCounter.isAvailable, "the malloc hook is missing or a sanitizer replaced malloc"))
    func enumerationAllocatesNothingForWordsUpTo24Letters() {
        let words = ["androdi", "documnets", "qwertyuiopasdfghjklzxcvb"]
        // Steady state: the first call of the process pays one-time runtime costs (metadata, lazy globals).
        Array("warm".utf8).withUnsafeBufferPointer { model.forEachEdit(of: $0, positionRules: false) { _ in true } }
        for word in words {
            let bytes = Array(word.utf8)
            var sum = 0
            let allocations = bytes.withUnsafeBufferPointer { buffer in
                AllocationCounter.count {
                    model.forEachEdit(of: buffer, positionRules: false) { edit in
                        sum &+= Int(edit[0]) &+ edit.count
                        return true
                    }
                    model.forEachEdit(of: buffer, positionRules: true) { edit in
                        sum &+= Int(edit[edit.count - 1])
                        return true
                    }
                }
            }
            #expect(allocations == 0, "\(word.count) letters")
            #expect(sum != 0)
        }
    }
}
