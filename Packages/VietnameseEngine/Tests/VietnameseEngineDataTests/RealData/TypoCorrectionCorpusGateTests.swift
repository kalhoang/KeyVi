// SPDX-License-Identifier: MPL-2.0
//
// ENG-T51 and ENG-T57 with the bundled data (spec/01-engine.md 11A.5, the targets of ENG-R1124; plan of 19/11/2026,
// Task 20). With `typoCorrection` on, nothing of the Vietnamese corpora, the W11 corpus or the word lists is
// corrected: the prose corpus by the three typists in both methods and tone styles, the prose corpus without its marks
// typed as plain letters, the generated corpus, the W11 corpus and its three sets, and every word of the English
// lexicon, the tech lists and the guard list. One-key typos of the Vietnamese words of the prose corpus are almost
// never corrected to an English word (at most 0.1 %). Every test prints what was corrected.

import Foundation
import Testing
import VietnameseEngine
import VietnameseEngineTesting

@testable import lexicon_builder

@Suite("ENG-T51, ENG-T57: what the typo correction must leave alone, with the bundled data")
struct TypoCorrectionCorpusGateTests {
    private static let corpus = Result { try RealData.proseCorpus() }

    /// The seed of ENG-T57 (recorded in TRACEABILITY.md).
    static let seed: UInt64 = 18_112_026

    static func configuration(_ method: CorpusMethod = .telex, style: ToneStyle = .traditional)
        -> EngineConfiguration
    {
        EngineConfiguration(inputMethod: method.inputMethod, toneStyle: style, typoCorrection: true)
    }

    // MARK: The prose corpus (13.4)

    @Test(
        "ENG-T51: the prose corpus, three typists, both methods, both tone styles",
        arguments: ProseCorpusGateTests.cases)
    func proseCorpusIsNeverCorrected(_ method: CorpusMethod, _ order: CorpusOrder, _ style: ToneStyle) throws {
        let report = ProseCorpusCheck.run(
            text: try Self.corpus.get(), method: method, order: order, style: style, typoCorrection: true,
            resources: try RealData.resources())
        print(
            "[ENG-T51] prose \(method) \(order) \(style): \(report.tokens) tokens, \(report.corrected.count) corrected"
                + (report.corrected.isEmpty ? "" : ":\n" + RealData.listing(report.corrected)))
        #expect(report.tokens >= 200_000)
        #expect(report.corrected.isEmpty)
    }

    /// The prose corpus with its marks and the stroke removed (ENG-R1110 (d): chat typed without marks), typed as
    /// plain letters: as running text after a space (the stream, a line per paragraph), and each distinct token at
    /// the start of the input, where a sentence-case token is at a sentence start (Q10).
    @Test("ENG-T51: the prose corpus without marks, as plain letters, after a space and at the start of a line")
    func unmarkedProseIsNeverCorrected() throws {
        let resources = try RealData.resources()
        let text = Self.unmarked(try Self.corpus.get())
        let stream = ProseCorpusCheck.run(
            text: text, method: .telex, order: .o1, typoCorrection: true, resources: resources)
        let tokens = Set(text.split { !$0.isLetter }.map(String.init)).sorted()
        var corrected = stream.corrected.map(\.description)
        for method in CorpusMethod.allCases {
            corrected += CorrectionCheck.corrections(
                of: tokens, resources: resources, configuration: Self.configuration(method)
            ).map { "\(method) at the start: \($0)" }
        }
        print(
            "[ENG-T51] unmarked prose: \(stream.tokens) tokens typed as a stream, \(tokens.count) distinct tokens at "
                + "the start of the input in Telex and VNI, \(corrected.count) corrected"
                + (corrected.isEmpty ? "" : ":\n" + RealData.listing(corrected)))
        #expect(stream.tokens >= 200_000 && tokens.count > 1_000)
        #expect(corrected.isEmpty)
    }

    /// `text` without marks: every letter decomposed, its marks dropped, `đ` written `d` (ENG-R1110 (d)).
    static func unmarked(_ text: String) -> String {
        let plain = text.decomposedStringWithCanonicalMapping.unicodeScalars.filter {
            $0.properties.generalCategory != .nonspacingMark
        }
        return String(String.UnicodeScalarView(plain)).replacingOccurrences(of: "đ", with: "d")
            .replacingOccurrences(of: "Đ", with: "D")
    }

    // MARK: The generated corpus (13.2) and the W11 corpus (13.11)

    static let generatedShards = 8

    /// Every case of the generated corpus (every Tier A toned syllable, orders O1 to O4, both methods and styles, the
    /// ENG-T03 variants), typed after `vieejt ` with the switch on and committed by a space.
    @Test("ENG-T51: the generated corpus", arguments: Array(0..<generatedShards))
    func generatedCorpusIsNeverCorrected(_ shard: Int) throws {
        let resources = try RealData.resources()
        var sessions: [EngineConfiguration: Session] = [:]
        var cases = 0
        var corrected: [String] = []
        func check(_ generated: GeneratedCase) {
            cases += 1
            var configuration = generated.configuration
            configuration.typoCorrection = true
            if sessions[configuration] == nil {
                var session = Session(engine: Engine(configuration: configuration, resources: resources))
                for key in GeneratedCorpusGateTests.seed { _ = session.handle(.key(KeyInput(key))) }
                sessions[configuration] = session
            }
            guard var session = sessions[configuration] else { return }
            for event in generated.events + [.key(KeyInput(" "))] {
                if case .corrected? = session.handle(event).decision {
                    corrected.append("\(generated.method) \(generated.style) \(generated.kind) \(generated.keys)")
                }
            }
        }
        GeneratedCorpus.forEachOrderCase(shard: shard, of: Self.generatedShards, check)
        GeneratedCorpus.forEachVariantCase(shard: shard, of: Self.generatedShards, check)
        print(
            "[ENG-T51] generated corpus shard \(shard): \(cases) cases, \(corrected.count) corrected"
                + (corrected.isEmpty ? "" : ":\n" + RealData.listing(corrected)))
        #expect(cases > 0)
        #expect(corrected.isEmpty)
    }

    /// The W11 corpus in both tone orders and its three adversarial sets (13.11), each sentence typed from an empty
    /// field with the switch on (`{RET}` is Return). The fixtures are read from the checkout, like the prose corpus.
    /// Its developer words (`frontend`, `backend`, `rebase`, `debounce`) were in no bundled list until 19/11/2026 and
    /// were corrected (`frontend` gave `fronted`); the tech-always list now holds them (ADR 0203 section 10).
    @Test(
        "ENG-T51: the W11 corpus and its three sets",
        arguments: ["corpus-tone-last", "corpus-tone-after-vowel", "set-adversarial", "set-stress", "set-held-out"])
    func w11CorpusIsNeverCorrected(_ file: String) throws {
        let resources = try RealData.resources()
        let url = TestPaths.packageRoot.appendingPathComponent("Tests/CollisionCorpusTests/Fixtures/\(file).tsv")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").filter { !$0.hasPrefix("#") }
        var corrected: [String] = []
        for line in lines {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            try #require(columns.count >= 4, "\(file): \(line)")
            let keys = columns[3].replacingOccurrences(of: "{RET}", with: "\n")
            corrected += CorrectionCheck.corrections(
                typing: keys, resources: resources, configuration: Self.configuration()
            ).map { "\(columns[0]) \($0.word) -> \($0.committed)" }
        }
        print(
            "[ENG-T51] W11 \(file): \(lines.count) sentences, \(corrected.count) corrected"
                + (corrected.isEmpty ? "" : ":\n" + RealData.listing(corrected)))
        #expect(lines.count >= 40)
        #expect(corrected.isEmpty, "\(file): \(corrected)")
    }

    /// Developer words a probe of 303 common developer terms (19/11/2026) found corrected to another English word
    /// with the data of that day (`upsert` gave `upset`, `structs` gave `struts`, `esports` gave `exports`), the four
    /// of the W11 corpus among them, with the inflections that were corrected too (ENG-R1124, W11 row; ADR 0203
    /// section 10). None of them is corrected, in Telex and VNI, lowercase after `vieejt ` and in sentence case at
    /// the start of the input.
    static let developerWords = [
        "backend", "bundlers", "debounce", "debounced", "debounces", "debouncing", "diffed", "esports", "frontend",
        "initializers", "rebase", "rebased", "rebases", "rebasing", "structs", "upsert", "upserting", "upserts",
    ]

    @Test("ENG-T51: developer words outside the 1.0 lists are never corrected", arguments: CorpusMethod.allCases)
    func developerWordsAreNeverCorrected(_ method: CorpusMethod) throws {
        let resources = try RealData.resources()
        let configuration = Self.configuration(method)
        let corrected =
            CorrectionCheck.corrections(
                of: Self.developerWords, resources: resources, configuration: configuration, after: "vieejt ")
            + CorrectionCheck.corrections(
                of: Self.developerWords.map { $0.prefix(1).uppercased() + $0.dropFirst() }, resources: resources,
                configuration: configuration)
        print(
            "[ENG-T51] developer words in \(method): \(Self.developerWords.count) words, \(corrected.count) corrected"
                + (corrected.isEmpty ? "" : ":\n" + RealData.listing(corrected)))
        #expect(corrected.isEmpty)
    }

    // MARK: The word lists

    enum WordList: String, CaseIterable, Sendable, CustomStringConvertible {
        case english, techAlways, techCodeOnly, guardInput
        var description: String { rawValue }
    }

    static let wordListCases: [(WordList, CorpusMethod)] = WordList.allCases.flatMap { list in
        CorpusMethod.allCases.map { (list, $0) }
    }

    /// Every word of the English lexicon, the tech-always and code-only lists and the guard list's input words (the
    /// SCOWL words and names of the 26 files, lowercase, five letters or more, outside the correction lexicon), in
    /// Telex and VNI: lowercase after `vieejt `, and in sentence case at the start of the input.
    @Test(
        "ENG-T51: every word list, lowercase after a Vietnamese word and in sentence case at the start",
        arguments: wordListCases)
    func everyWordListIsNeverCorrected(_ list: WordList, _ method: CorpusMethod) throws {
        let resources = try RealData.resources()
        let words = try Self.words(list)
        let configuration = Self.configuration(method)
        let lowercase = CorrectionCheck.corrections(
            of: words, resources: resources, configuration: configuration, after: "vieejt ")
        let sentenceCase = CorrectionCheck.corrections(
            of: words.map { $0.prefix(1).uppercased() + $0.dropFirst() }, resources: resources,
            configuration: configuration)
        let corrected = lowercase + sentenceCase
        print(
            "[ENG-T51] \(list) in \(method): \(words.count) words, \(corrected.count) corrected"
                + (corrected.isEmpty ? "" : ":\n" + RealData.listing(corrected)))
        #expect(words.count > 100)
        #expect(corrected.isEmpty)
    }

    static func words(_ list: WordList) throws -> [String] {
        func file(_ name: String) throws -> [String] {
            try String(contentsOf: TestPaths.committedResources.appendingPathComponent(name), encoding: .utf8)
                .split(separator: "\n").map(String.init)
        }
        switch list {
        case .english: return try file("english.txt")
        case .techAlways: return try file("tech-always.txt")
        case .techCodeOnly: return try file("tech-code-only.txt")
        case .guardInput:
            let layout = Layout(dataRoot: TestPaths.dataRoot, resources: TestPaths.committedResources)
            return try GuardList.words(layout, lexicon: try Builder.correctionLexicon(layout)).sorted()
        }
    }

    // MARK: ENG-T57: one-key typos of Vietnamese words

    enum TypoRun: String, CaseIterable, Sendable, CustomStringConvertible {
        /// Telex in the usual order with the tone key last.
        case telexToneLast
        /// The unmarked shapes typed as plain letters, each distinct shape once.
        case plainLetters
        var description: String { rawValue }
    }

    /// Every distinct word of the prose corpus that is Tier A or Tier B, typed in Telex with the tone key last and, as
    /// the second run, as plain letters (each distinct unmarked shape once), receives one random edit of each kind of
    /// ENG-T57 (transposition, omission, insertion, neighbouring key; seed 18112026) and is typed after `vieejt `.
    /// Among the typos of five keys or more, at most 0.1 % are corrected; the plain-letter run counts, as the
    /// reference model does, the typos that are neither a word of a list nor a shape (those are never candidates).
    @Test("ENG-T57: one-key typos of Vietnamese words are almost never corrected", arguments: TypoRun.allCases)
    func vietnameseTyposAreAlmostNeverCorrectedToEnglish_ENGT57(_ run: TypoRun) throws {
        let resources = try RealData.resources()
        let sources = Set(try Self.corpus.get().split { !$0.isLetter }.map { $0.lowercased() })
            .filter { Orthography.validity(of: $0) != .invalid }.sorted()
        let typedForms: [String]
        switch run {
        case .telexToneLast: typedForms = sources.compactMap(CorrectionCheck.telexKeysToneLast)
        case .plainLetters: typedForms = Set(sources.map(Self.unmarked)).sorted()
        }
        var generator = TypoGenerator(seed: Self.seed, neighbours: resources.correction.keyboardNeighbours)
        var typos: [String] = []
        var origin: [String: String] = [:]
        for keys in typedForms {
            for kind in TypoKind.vietnameseKinds {
                guard let typo = generator.typo(of: keys, kind: kind), typo != keys, typo.utf8.count >= 5 else {
                    continue
                }
                if run == .plainLetters, Self.isOnAListOrAShape(typo, resources) { continue }
                typos.append(typo)
                origin[typo] = origin[typo] ?? keys
            }
        }
        let corrected = CorrectionCheck.corrections(
            of: typos, resources: resources, configuration: Self.configuration(), after: "vieejt ")
        let share = Double(corrected.count) / Double(max(1, typos.count))
        print(
            "[ENG-T57] \(run), seed \(Self.seed): \(sources.count) Tier A or B words, \(typedForms.count) typed "
                + "forms, \(typos.count) typos of five keys or more, \(corrected.count) corrected ("
                + String(format: "%.3f %%", share * 100) + ")"
                + (corrected.isEmpty
                    ? "" : ":\n" + RealData.listing(corrected.map { "\($0) from \(origin[$0.word] ?? "")" })))
        #expect(typos.count > 500)
        #expect(share <= 0.001, "\(corrected.count) of \(typos.count) typos corrected")
    }

    static func isOnAListOrAShape(_ word: String, _ resources: Resources) -> Bool {
        resources.english.contains(word) || resources.techAlways.contains(word) || resources.techCodeOnly.contains(word)
            || resources.correction.guardList.mayContain(word) || resources.correction.unmarkedShapes.contains(word)
            || resources.ambiguity[word] != nil || resources.collision.supplement.contains(word)
    }
}
