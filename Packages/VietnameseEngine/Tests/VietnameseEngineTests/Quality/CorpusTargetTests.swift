// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// The measurable targets of spec 8.8 with the 13.9 fixtures and the prose sample. The same harnesses
/// (`EnglishCorpusCheck`, `ProseCorpusCheck` in VietnameseEngineTesting) run on the bundled lexicon and the
/// prose corpus in `VietnameseEngineDataTests/RealData` (docs/decisions/0202).
@Suite("Measurable targets (8.8) with fixture data")
struct CorpusTargetTests {
    static var englishWords: [String] {
        Array(
            Set(
                SpecFixtures.englishLexicon + SpecFixtures.techAlways + SpecFixtures.techCodeOnly
                    + QACorpus.englishHandList)
        ).sorted()
    }

    static var resources: Resources {
        var resources = SpecFixtures.commitResources()
        resources.english = WordSet(SpecFixtures.englishLexicon + QACorpus.englishHandList)
        return resources
    }

    @Test("ENG-T10, ENG-R871, ENG-R872, ENG-T11: English words in both contexts")
    func englishCorpus() throws {
        let exceptions = EnglishCorpusCheck.exceptions(try CorpusFiles.text("known-exceptions.txt"))
        let report = EnglishCorpusCheck.run(words: Self.englishWords, resources: Self.resources)
        print("[ENG-T10] \(report.words) words; changed in an English run: \(report.changedInEnglishRun)")
        print(
            "[ENG-T10] changed in Vietnamese context (\(report.changedInVietnameseContext.count)): \(report.changedInVietnameseContext)"
        )
        // ENG-R871: at least 99.5 % unchanged in an English run; every failure is a known exception.
        #expect(report.unchangedShareInEnglishRun(exceptions: exceptions) >= 0.995)
        #expect(report.changedInEnglishRun.allSatisfy { exceptions.contains($0.word) })
        // ENG-R872: every change in Vietnamese context is an ambiguity candidate decided vi. The 3 % ceiling
        // is for the real lexicon (VERIFY in 8.8); the fixture lexicon is made of collisions on purpose.
        #expect(report.unexplainedVietnameseChanges(resources: Self.resources).isEmpty)
    }

    @Test("ENG-T20, ENG-R873: prose typed by three typists in both methods", arguments: CorpusMethod.allCases)
    func prose(_ method: CorpusMethod) throws {
        let text =
            try CorpusFiles.text("prose-sample.txt").split(separator: "\n").filter { !$0.hasPrefix("#") }
            .joined(separator: "\n") + "\n"
        for order in ProseCorpusCheck.typists {
            let report = ProseCorpusCheck.run(
                text: text, method: method, order: order, resources: SpecFixtures.commitResources())
            #expect(report.tokens > 200)
            // Every difference must be attributable to an `en` ambiguity row (`tét` typed `test` by the O2
            // typist); everything else is identical, which here is 100 % of the remaining tokens.
            let unexplained = report.differences.filter { $0.decision != .restored(.ambiguityTable) }
            #expect(unexplained.isEmpty, "\(method) \(order): \(unexplained)")
            let explained = report.tokens - unexplained.count
            #expect(Double(explained) / Double(report.tokens) >= 0.9995)
            print(
                "[ENG-R873] \(method) \(order): \(report.tokens) tokens, identical \(report.identicalShare), en rows \(report.differences)"
            )
        }
    }

    @Test("ENG-R874: in VNI, words without digits are never changed")
    func vniWithoutDigits() throws {
        let engine = Engine(configuration: EngineConfiguration(inputMethod: .vni), resources: Self.resources)
        var telexSpellings: [String] = []
        GeneratedCorpus.forEachOrderCase { generated in
            if generated.method == .telex, generated.style == .traditional, generated.kind == .order(.o1) {
                telexSpellings.append(generated.keys)
            }
        }
        var words = Self.englishWords + telexSpellings
        words += words.map { $0.uppercased() }
        for word in words {
            var driver = EngineDriver(engine: engine)
            try driver.type(word + " ")
            #expect(driver.field.string == word + " ", "\(word)")
            #expect(driver.outputs.allSatisfy { $0.action == .passThrough }, "\(word)")
        }
        #expect(words.count > 30_000)
    }

    @Test("ENG-R874 and QA-R7 P7: a VNI stream without digits, toggles or macros only passes keys through")
    func vniStreamsPassThrough() throws {
        var generator = SeededGenerator(seed: 874)
        let keys = FuzzAlphabet.letters + FuzzAlphabet.punctuation + FuzzAlphabet.spaces + FuzzAlphabet.hardBoundaries
        let engine = Engine(configuration: EngineConfiguration(inputMethod: .vni), resources: Self.resources)
        for _ in 0..<50 {
            var driver = EngineDriver(engine: engine)
            var plain = SimulatedTextField()
            for _ in 0..<400 {
                let event: EngineEvent =
                    generator.chance(1, in: 8) ? .backspace : .key(KeyInput(generator.pick(keys)))
                let output = try driver.send(event)
                #expect(output.action == .passThrough)
                try plain.apply(event, EngineOutput(action: .passThrough, composingText: ""))
            }
            #expect(driver.field == plain)
        }
    }

    @Test("Non-goals: no Quick Telex, no auto-capitalisation, no VIQR, no multi-syllable segmentation")
    func nonGoals() throws {
        func typed(_ keys: String, _ configuration: EngineConfiguration = EngineConfiguration()) throws -> String {
            var driver = EngineDriver(configuration: configuration, resources: SpecFixtures.commitResources())
            try driver.type(keys)
            return driver.field.string
        }
        #expect(try typed("cc kkk nn tt ") == "cc kkk nn tt ")  // ENG-R121
        #expect(try typed("xin chaof. tooi ") == "xin chào. tôi ")  // ENG-R123: no capital after the period
        #expect(try typed("vie^.t ") == "vie^.t ")  // ENG-R126: VIQR marks are punctuation boundaries
        #expect(try typed("vieejtnam") == "việtnam")  // ENG-R127: one syllable, then literal
        #expect(try typed("vieejtnam ") == "vieejtnam ")  // and restored at commit (invalid, L5)
    }
}
