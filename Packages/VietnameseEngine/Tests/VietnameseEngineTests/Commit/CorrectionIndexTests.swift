// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngineTesting

@testable import VietnameseEngine

extension CorrectionIndex {
    fileprivate func mightHold(_ word: String) -> Bool {
        Array(word.utf8).withUnsafeBufferPointer { mightHold($0) }
    }

    fileprivate func lexiconContains(_ word: String) -> Bool {
        Array(word.utf8).withUnsafeBufferPointer { lexiconContains($0) }
    }

    fileprivate func isVietnameseKeyingOrShape(_ word: String) -> Bool {
        Array(word.utf8).withUnsafeBufferPointer { isVietnameseKeyingOrShape($0) }
    }
}

/// The index the typo correction looks edits up in (ENG-R1122): a trigram and edge-bigram prefilter over every word
/// an edit may reach, and byte-keyed membership, shared by every engine of a resources value.
@Suite("Typo correction: the correction index (ENG-R1122)")
struct CorrectionIndexTests {
    private func index(_ words: [String], keyings: [String] = [], shapes: [String] = []) -> CorrectionIndex {
        CorrectionIndex(
            english: WordSet(words), techAlways: WordSet([]),
            correction: CorrectionData(
                guardList: .empty, keyboardNeighbours: [:], unmarkedShapes: WordSet(shapes),
                vietnameseKeyings: WordSet(keyings)))
    }

    @Test func aCandidateWithAnUnseenTrigramIsRejected() {
        let index = index(["android", "about"])
        #expect(!index.mightHold("andxoid"))
        #expect(index.mightHold("android"))
        #expect(index.mightHold("about"))
        // A false "yes" is allowed (`abdroid` would be one), never a false "no".
        #expect(!index.mightHold("andr0id") && !index.mightHold("ANDROID"))
    }

    @Test func edgeBigramsAreChecked() {
        let index = index(["android", "about"])
        #expect(!index.mightHold("ndroid"))  // `^nd` starts no word of the set
        #expect(!index.mightHold("androi"))  // `oi$` ends none
        #expect(!index.mightHold("abou"))  // `ou$` neither
    }

    @Test("The prefilter covers the keyings and the shapes, which the ENG-R1125 pass looks up behind it")
    func thePrefilterCoversTheVietnameseWords() {
        let index = index(["android"], keyings: ["phair"], shapes: ["thach"])
        #expect(index.mightHold("phair") && index.isVietnameseKeyingOrShape("phair"))
        #expect(index.mightHold("thach") && index.isVietnameseKeyingOrShape("thach"))
        #expect(!index.isVietnameseKeyingOrShape("android") && !index.lexiconContains("phair"))
    }

    @Test func theCorrectionLexiconIsTheEnglishWordsAndTheLetterOnlyTechAlwaysEntries() {
        let index = CorrectionIndex(
            english: WordSet(["android", "don't"]), techAlways: WordSet(["oauth", "mp3", "wi-fi"]),
            correction: .empty)
        #expect(index.lexiconContains("android") && index.lexiconContains("oauth"))
        #expect(!index.lexiconContains("mp3") && !index.lexiconContains("wi-fi") && !index.lexiconContains("don't"))
        #expect(!index.lexiconContains("androi") && !index.lexiconContains(""))
    }

    @Test("Words longer than a small string (16 to 31 bytes) are found byte for byte")
    func longWords() {
        let long = "internationalization"  // 20 letters
        let longest = String(repeating: "abcdefghij", count: 3) + "k"  // 31 letters
        let index = index([long, longest, "inter"], keyings: [longest])
        #expect(index.lexiconContains(long) && index.lexiconContains(longest) && index.mightHold(long))
        #expect(!index.lexiconContains("internationalizatio") && !index.lexiconContains(long + "s"))
        #expect(!index.lexiconContains("internationalizatiom"))
        #expect(index.isVietnameseKeyingOrShape(longest) && !index.isVietnameseKeyingOrShape(long))
    }

    @Test func theIndexIsSharedByCopiesOfResources() throws {
        let a = SpecFixtures.correctionResources()
        var b = a
        b.userKeepRaw = WordSet(["androdi"])
        b.userKeepVietnamese = WordSet(["chinhs"])
        b.macros = try MacroTable([MacroTable.Entry(trigger: "vn", expansion: "Việt Nam")])
        b.collisionMemory = .empty
        b.userNeverCorrect = WordSet(["androdi"])
        #expect(ObjectIdentifier(a.correctionIndex) == ObjectIdentifier(b.correctionIndex))
        // The engines of a catalog share it too (Review Focus 5).
        let one = Engine(configuration: EngineConfiguration(typoCorrection: true), resources: b)
        let two = Engine(configuration: EngineConfiguration(appContext: .code, typoCorrection: true), resources: b)
        #expect(ObjectIdentifier(one.resources.correctionIndex) == ObjectIdentifier(two.resources.correctionIndex))
    }

    @Test func mutatingAnInputAfterInitRebuildsTheIndex() {
        var resources = SpecFixtures.correctionResources(correction: .empty)
        var before = ObjectIdentifier(resources.correctionIndex)
        #expect(!resources.correctionIndex.isVietnameseKeyingOrShape("phair"))
        resources.correction = SpecFixtures.correctionData
        #expect(resources.correctionIndex.isVietnameseKeyingOrShape("phair"))
        #expect(ObjectIdentifier(resources.correctionIndex) != before)

        before = ObjectIdentifier(resources.correctionIndex)
        #expect(!resources.correctionIndex.lexiconContains("androids"))
        resources.english = WordSet(["androids"])
        #expect(
            resources.correctionIndex.lexiconContains("androids") && resources.correctionIndex.mightHold("androids"))
        #expect(!resources.correctionIndex.lexiconContains("android"))
        #expect(ObjectIdentifier(resources.correctionIndex) != before)

        before = ObjectIdentifier(resources.correctionIndex)
        resources.techAlways = WordSet(["kubectl"])
        #expect(resources.correctionIndex.lexiconContains("kubectl"))
        #expect(ObjectIdentifier(resources.correctionIndex) != before)
    }

    @Test(.enabled(if: AllocationCounter.isAvailable, "the malloc hook is missing or a sanitizer replaced malloc"))
    func lexiconLookupsAreByteKeyedAndAllocateNothing() {
        let long = "internationalization"
        let index = index([long, "android"], keyings: ["phair"], shapes: ["thach"])
        let words = [long, "internationalizatiom", "android", "androdi", "phair", String(repeating: "x", count: 31)]
        func lookUp(_ buffer: UnsafeBufferPointer<UInt8>) -> Int {
            (index.mightHold(buffer) ? 1 : 0) + (index.lexiconContains(buffer) ? 2 : 0)
                + (index.isVietnameseKeyingOrShape(buffer) ? 4 : 0)
        }
        // Steady state: the first call of the process pays one-time runtime costs (metadata, lazy globals).
        for word in words { _ = Array(word.utf8).withUnsafeBufferPointer(lookUp) }
        for word in words {
            let bytes = Array(word.utf8)
            var found = 0
            let allocations = bytes.withUnsafeBufferPointer { buffer in
                AllocationCounter.count { found = lookUp(buffer) }
            }
            #expect(allocations == 0, "\(word.count) letters")
            #expect((found & 2 != 0) == (word == long || word == "android"))
        }
    }

    /// Spec 12.2 (sixth amendment): the index reads the shapes and keyings of the correction data in place and owns
    /// only its prefilter and the byte-keyed tables of the words longer than a small string (ENG-R1120).
    @Test func theIndexReadsThePackedSetsInPlaceAndOwnsOnlyItsTables() {
        let data = SpecFixtures.correctionData
        let index = CorrectionIndex(english: WordSet(["android"]), techAlways: WordSet([]), correction: data)
        #expect(index.shapes.sharesStorage(with: data.unmarkedShapes))
        #expect(index.keyings.sharesStorage(with: data.vietnameseKeyings))
        let tables = (26 * 26 * 26 + 63) / 64 * 8 + 2 * (26 * 26 + 63) / 64 * 8
        #expect(index.ownedByteCount >= tables && index.ownedByteCount < tables + 1_024)
        #expect(index.longVietnameseByteCount == 0)
        let long = String(repeating: "abcdefghij", count: 3) + "k"
        let withLong = CorrectionIndex(
            english: WordSet([]), techAlways: WordSet([]),
            correction: CorrectionData(
                guardList: .empty, keyboardNeighbours: [:], unmarkedShapes: PackedWordSet([long]),
                vietnameseKeyings: .empty))
        #expect(withLong.longVietnameseByteCount > long.utf8.count)
    }

    @Test func emptyResourcesHaveAnEmptyIndex() {
        let index = Resources.empty.correctionIndex
        #expect(!index.mightHold("android") && !index.lexiconContains("android"))
        #expect(!index.isVietnameseKeyingOrShape("phair"))
        #expect(!CorrectionIndex.empty.mightHold("about"))
    }
}
