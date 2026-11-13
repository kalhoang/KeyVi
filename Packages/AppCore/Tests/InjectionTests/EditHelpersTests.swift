// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Pure helpers shared by every strategy: prefix trimming (PLT-R402) and Unicode chunking (PLT-R404, PLT-R480).

import RealtimeSupport
import Testing

@testable import Injection

@Suite struct EditMinimizerTests {
    /// 4.10 acceptance: "nguyen" + `s` deletes "en" and inserts "ến".
    @Test func nguyenPlusSTrimsCommonPrefixPLTR402() {
        let result = EditMinimizer.minimize(deleteCount: 6, replaced: "nguyen", insertion: "nguyến")
        #expect(result.deleteCount == 2)
        #expect(result.insertion == "ến")
    }

    @Test func unknownReplacedTextKeepsTheEngineEdit() {
        let result = EditMinimizer.minimize(deleteCount: 2, replaced: nil, insertion: "ến")
        #expect(result.deleteCount == 2)
        #expect(result.insertion == "ến")
    }

    @Test func replacedTextLongerThanTheDeletionUsesItsSuffix() {
        // The pipeline may pass the whole active token; only the last `deleteCount` graphemes are replaced.
        let result = EditMinimizer.minimize(deleteCount: 2, replaced: "nguyen", insertion: "ến")
        #expect(result.deleteCount == 2)
        #expect(result.insertion == "ến")
        let trimmed = EditMinimizer.minimize(deleteCount: 3, replaced: "xxaab", insertion: "âb")
        #expect(trimmed.deleteCount == 3)
        #expect(trimmed.insertion == "âb")
    }

    @Test func replacedTextShorterThanTheDeletionIsIgnored() {
        let result = EditMinimizer.minimize(deleteCount: 4, replaced: "en", insertion: "uyến")
        #expect(result.deleteCount == 4)
        #expect(result.insertion == "uyến")
    }

    @Test func identicalTextBecomesAnEmptyEdit() {
        let result = EditMinimizer.minimize(deleteCount: 3, replaced: "abc", insertion: "abc")
        #expect(result.deleteCount == 0)
        #expect(result.insertion.isEmpty)
    }

    @Test func pureDeletionAndPureInsertionAreUnchanged() {
        let deletion = EditMinimizer.minimize(deleteCount: 2, replaced: "ab", insertion: "")
        #expect(deletion.deleteCount == 2 && deletion.insertion.isEmpty)
        let insertion = EditMinimizer.minimize(deleteCount: 0, replaced: "", insertion: "ab")
        #expect(insertion.deleteCount == 0 && insertion.insertion == "ab")
    }

    @Test func comparesWholeGraphemesNotScalars() {
        // "e" is not a prefix of "ế": a grapheme with marks never matches its base letter.
        let result = EditMinimizer.minimize(deleteCount: 2, replaced: "en", insertion: "e\u{0302}\u{0301}n")
        #expect(result.deleteCount == 2)
        let emoji = EditMinimizer.minimize(deleteCount: 2, replaced: "👍🏽a", insertion: "👍🏽b")
        #expect(emoji.deleteCount == 1)
        #expect(emoji.insertion == "b")
    }

    @Test func utf16CountOfTheTrimmedDeletionComesFromTheReplacedText() {
        let edit = MinimalEdit(deleteCount: 3, deleteUTF16Count: 4, replaced: "a👍b", insertion: "a👍c")
        #expect(edit.deleteCount == 1)
        #expect(edit.deleteUTF16Count == 1)
        #expect(edit.insertion == "c")
        let untouched = MinimalEdit(deleteCount: 2, deleteUTF16Count: 3, replaced: nil, insertion: "x")
        #expect(untouched.deleteUTF16Count == 3)
    }
}

@Suite struct UnicodeChunkerTests {
    private func strings(_ chunks: [InlineUTF16]) -> [String] { chunks.map(\.string) }

    @Test func oneGraphemePerEventByDefaultPLTR404() {
        #expect(strings(UnicodeChunker.chunks(of: "ến", maxUTF16: 1, oneGraphemePerEvent: true)) == ["ế", "n"])
        let decomposed = "e\u{0302}\u{0301}x"
        #expect(
            strings(UnicodeChunker.chunks(of: decomposed, maxUTF16: 20, oneGraphemePerEvent: true))
                == ["e\u{0302}\u{0301}", "x"])
    }

    @Test func multiCharChunksNeverSplitAGrapheme() {
        let text = "ab👍🏽cd"
        let chunks = strings(UnicodeChunker.chunks(of: text, maxUTF16: 4, oneGraphemePerEvent: false))
        #expect(chunks == ["ab", "👍🏽", "cd"])
        #expect(chunks.joined() == text)
    }

    @Test func chunkSizeIsCappedAtTwentyUnitsPLTR480() {
        let text = String(repeating: "đ", count: 45)
        let chunks = UnicodeChunker.chunks(of: text, maxUTF16: 100, oneGraphemePerEvent: false)
        #expect(chunks.map(\.count) == [20, 20, 5])
        #expect(strings(chunks).joined() == text)
    }

    @Test func graphemeLongerThanTheCapGoesAloneAndOversizedClustersSplitAtScalars() {
        #expect(
            strings(UnicodeChunker.chunks(of: "a👍b", maxUTF16: 1, oneGraphemePerEvent: false))
                == ["a", "👍", "b"])
        // A pathological cluster over the 20-unit event limit is split at scalar boundaries, never dropped.
        let zalgo = "a" + String(repeating: "\u{0301}", count: 30)
        let chunks = UnicodeChunker.chunks(of: zalgo, maxUTF16: 20, oneGraphemePerEvent: true)
        #expect(chunks.map(\.count) == [20, 11])
        #expect(strings(chunks).joined() == zalgo)
        let flags = String(repeating: "👨‍👩‍👧‍👦", count: 1) + "\u{1F3FD}\u{1F3FD}\u{1F3FD}\u{1F3FD}"
        let pieces = UnicodeChunker.chunks(of: flags, maxUTF16: 20, oneGraphemePerEvent: true)
        #expect(strings(pieces).joined() == flags)
        #expect(pieces.allSatisfy { $0.count <= InlineUTF16.capacity })
    }

    @Test func emptyTextHasNoChunks() {
        #expect(UnicodeChunker.chunks(of: "", maxUTF16: 1, oneGraphemePerEvent: true).isEmpty)
    }
}
