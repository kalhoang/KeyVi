// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// ENG-R870 / ENG-T02: for every case of the generated corpus (every Tier A toned syllable, O1 to O4, both
/// methods and styles, plus the ENG-T03 variants) the text committed by a space in Vietnamese context
/// (after the seed token `việt`) equals the oracle, 100 %. The only allowed exclusions are raw strings that
/// are `en` rows of the ambiguity table; the test lists them.
///
/// Resources: the 13.9 fixture lexicon, tech lists and ambiguity proposals, with every Tier A syllable
/// attested. The 13.9 list of unattested syllables is "fixture data for this table only" (13.9); with it,
/// rule L8 restores the English raw strings whose display is unattested (`does`, `door`, `her`, `post`,
/// `says`), which ENG-R870 does not allow to exclude. The second test runs that configuration and asserts
/// that those L8 restores are the only other differences, listing them (docs/decisions/0103).
@Suite("Generated corpus committed in Vietnamese context (ENG-R870)")
struct GeneratedCorpusCommitTests {
    static let shardCount = 40
    static let shards = Array(0..<shardCount)
    static let seed = "vieejt "

    /// The 13.9 fixtures with every Tier A syllable attested.
    static let allAttested = Resources(
        english: WordSet(SpecFixtures.englishLexicon), techAlways: WordSet(SpecFixtures.techAlways),
        techCodeOnly: WordSet(SpecFixtures.techCodeOnly), attestedSyllables: WordSet(SpecFixtures.allStandardSyllables),
        ambiguity: Dictionary(uniqueKeysWithValues: SpecFixtures.ambiguityProposals.map { ($0.raw, $0.language) }),
        userKeepRaw: WordSet([]), userKeepVietnamese: WordSet([]))

    static let englishRows = Set(SpecFixtures.ambiguityProposals.filter { $0.language == .english }.map(\.raw))

    /// One engine per (method, style), each with the state after the Vietnamese seed token.
    private struct SeededEngines {
        private let sessions: [EngineConfiguration: Session]

        init(resources: Resources) {
            var sessions: [EngineConfiguration: Session] = [:]
            for method in CorpusMethod.allCases {
                for style in [ToneStyle.traditional, .modern] {
                    let configuration = EngineConfiguration(inputMethod: method.inputMethod, toneStyle: style)
                    var session = Session(engine: Engine(configuration: configuration, resources: resources))
                    for key in GeneratedCorpusCommitTests.seed { _ = session.handle(.key(KeyInput(key))) }
                    sessions[configuration] = session
                }
            }
            self.sessions = sessions
        }

        func session(for configuration: EngineConfiguration) -> Session? { sessions[configuration] }
    }

    /// The text the case commits after the seed, with the decision; nil text on a contract violation.
    private static func commit(_ generated: GeneratedCase, engines: SeededEngines) -> (text: String, decision: CommitDecision?)? {
        guard var session = engines.session(for: generated.configuration) else { return nil }
        var field = SimulatedTextField(text: "việt ")
        var decision: CommitDecision?
        do {
            for event in generated.events + [.key(KeyInput(" "))] {
                let output = session.handle(event)
                try field.apply(event, output)
                decision = output.decision
            }
        } catch {
            return nil
        }
        let text = String(field.string.dropFirst("việt ".count))
        return (text, decision)
    }

    private static func forEachCase(shard: Int, _ body: (GeneratedCase) -> Void) {
        GeneratedCorpus.forEachOrderCase(shard: shard, of: shardCount, body)
        GeneratedCorpus.forEachVariantCase(shard: shard, of: shardCount, body)
    }

    @Test(arguments: shards)
    func committedTextEqualsTheOracle(shard: Int) {
        let engines = SeededEngines(resources: Self.allAttested)
        var cases = 0
        var excluded: Set<String> = []
        var failures: [String] = []
        Self.forEachCase(shard: shard) { generated in
            cases += 1
            let raw = generated.keys.lowercased()
            let result = Self.commit(generated, engines: engines)
            if Self.englishRows.contains(raw) {
                excluded.insert(generated.keys)
                // ENG-R843: an `en` row restores (rule L11) in Vietnamese context.
                if result?.text != generated.keys + " " { failures.append("\(generated.keys): en row not restored") }
                return
            }
            guard let result, result.text == generated.expectedCommitted + " " else {
                failures.append(
                    "\(generated.method) \(generated.style) \(generated.kind) \(generated.keys): committed "
                        + "\(result?.text.debugDescription ?? "violation") (oracle \(generated.expectedCommitted)) "
                        + "\(result?.decision.map { "\($0)" } ?? "")")
                return
            }
        }
        #expect(cases > 0)
        #expect(failures.isEmpty, "shard \(shard): \(failures.count) failures\n\(failures.prefix(25).joined(separator: "\n"))")
        if !excluded.isEmpty {
            print("[ENG-R870] shard \(shard): excluded en rows \(excluded.sorted().joined(separator: " "))")
        }
    }

    @Test(arguments: shards)
    func fullFixturesDifferOnlyByNotAttestedEnglish(shard: Int) {
        // With the 13.9 unattested list, every other difference must be an L8 restore of an English raw
        // string whose display is one of the unattested syllables.
        let engines = SeededEngines(resources: SpecFixtures.commitResources())
        var restoredByL8: Set<String> = []
        var failures: [String] = []
        Self.forEachCase(shard: shard) { generated in
            let raw = generated.keys.lowercased()
            guard !Self.englishRows.contains(raw), let result = Self.commit(generated, engines: engines) else { return }
            if result.text == generated.expectedCommitted + " " { return }
            let unattested = SpecFixtures.unattestedSyllables.contains(generated.expectedCommitted.lowercased())
            if result.decision == .restored(.notAttested), unattested, SpecFixtures.englishLexicon.contains(raw),
                result.text == generated.keys + " "
            {
                restoredByL8.insert(generated.keys)
            } else {
                failures.append("\(generated.keys): \(result.text.debugDescription) \(result.decision.map { "\($0)" } ?? "")")
            }
        }
        #expect(failures.isEmpty, "shard \(shard):\n\(failures.prefix(25).joined(separator: "\n"))")
        if !restoredByL8.isEmpty {
            print("[ENG-R870] shard \(shard): L8 restores with the 13.9 unattested list \(restoredByL8.sorted().joined(separator: " "))")
        }
    }
}
