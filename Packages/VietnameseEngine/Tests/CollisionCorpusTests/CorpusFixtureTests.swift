// SPDX-License-Identifier: MPL-2.0
//
// The QA-R68 fixture files parse, carry their licence header and provenance pointer, and keep the shape the
// gate relies on (spec/01-engine.md 13.11: 1,206 corpus sentences, sets of 57, 42 and 81 lines).

import Testing
import VietnameseEngine

@Suite("QA-R68 fixtures")
struct CorpusFixtureTests {
    @Test(
        "Every fixture file parses, starts with its SPDX line and points at the provenance note",
        arguments: CorpusFixture.allCases)
    func fileShape(_ fixture: CorpusFixture) throws {
        let (header, sentences) = try fixture.load()
        #expect(header.first == "# SPDX-License-Identifier: MPL-2.0")
        #expect(header.contains { $0.contains("README.txt") })
        let expectedCount: Int =
            switch fixture {
            case .toneLast, .toneAfterVowel: 1_206
            case .adversarial: 57
            case .stress: 42
            case .heldOut: 81
            }
        #expect(sentences.count == expectedCount)
        for sentence in sentences {
            #expect(
                MemorySimulation.wordsOfNotation(sentence.expected).count == sentence.words.count,
                "\(sentence.id): expected field and token list differ in length")
            #expect(sentence.revised.keys.allSatisfy { $0 < sentence.words.count }, "\(sentence.id)")
        }
    }

    @Test("The two corpus files hold the same sentences, the held-out halves and the same intended words")
    func corpusFilesAgree() throws {
        let main = try CorpusFixture.toneLast.load().sentences
        let alternative = try CorpusFixture.toneAfterVowel.load().sentences
        #expect(main.map(\.id) == alternative.map(\.id))
        #expect(main.map(\.half) == alternative.map(\.half))
        #expect(main.map { $0.words.map(\.intended) } == alternative.map { $0.words.map(\.intended) })
        #expect(Set(main.map(\.half)) == ["A", "B"])
        #expect(Set(main.map(\.group)) == ["mixed", "pure-vi", "pure-en"])
    }

    @Test("Malformed lines are rejected with their line number")
    func malformedLines() {
        let good = "S1\tset\t-\tas{RET}\tá{RET}\t-\tá/V/set/-"
        #expect(throws: Never.self) { try CorpusFixture.parse(good, file: "t") }
        for bad in [
            "S1\tset\t-\tas{RET}\tá{RET}\t-",  // six columns
            "S1\tset\tC\tas{RET}\tá{RET}\t-\tá",  // half
            "S1\tset\t-\tas{RET}\tá{RET}\t0:guess\tá",  // revision reason
            "S1\tset\t-\tas{RET}\tá{RET}\t-\tá/X/set/-",  // language
            "S1\tset\t-\tas{RET}\tá{RET}\t-\tá1",  // not letters
            good + "\n" + good,  // duplicate id
        ] {
            #expect(throws: FixtureFormatError.self, "\(bad)") { try CorpusFixture.parse(bad, file: "t") }
        }
        #expect(throws: Never.self) { try CorpusFixture.parse("# comment\n\n" + good + "\n", file: "t") }
    }

    @Test("Token labels: plain, hidden and collision with language, category and positions")
    func labels() throws {
        let (_, sentences) = try CorpusFixture.parse(
            "PA02\tmixed\tB\tk{RET}\te{RET}\t1:phrase\tnó/H tricky á/V/enkeys-row-vi/after-en-1,before-period",
            file: "t")
        let words = try #require(sentences.first?.words)
        #expect(words[0] == LabelledWord(intended: "nó", label: .hidden))
        #expect(words[1] == LabelledWord(intended: "tricky", label: .plain))
        #expect(
            words[2]
                == LabelledWord(
                    intended: "á",
                    label: .collision(
                        intended: .vietnamese, category: "enkeys-row-vi", positions: ["after-en-1", "before-period"])))
        #expect(sentences.first?.revised == [1: "phrase"])
    }
}
