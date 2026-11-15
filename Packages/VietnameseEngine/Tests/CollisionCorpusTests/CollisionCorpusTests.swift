// SPDX-License-Identifier: MPL-2.0
//
// QA-R68 (spec/04-quality-release.md): the W11 collision corpus and its three adversarial sets (spec/01-engine.md
// 13.11) run through the engine with the bundled data, in host mode, against the thresholds of ENG-R876; any wrong
// revision fails the build. The expected outputs were generated once with the W11 replay kit, reviewed by hand on
// a sample and frozen (Fixtures/README.txt): a change that moves a number fails here until the fixture is updated
// and reviewed with the change (QA-R6). The prose-corpus part of ENG-R876 (no change, no revision) is
// `ProseCorpusGateTests.collisionRulesLeaveProseUnchanged` in VietnameseEngineDataTests; the memory part
// (ENG-R877) is `CollisionMemorySimulationTests`.

import Testing
import VietnameseEngine
import VietnameseEngineData

@Suite("W11 collision corpus (QA-R68, ENG-R876)")
struct CollisionCorpusTests {
    @Test("The bundled resources carry the collision lists the corpus gate reads")
    func bundledCollisionLists() throws {
        let resources = try GateResources.bundled()
        #expect(resources.collision.phrases.count > 0)
        #expect(resources.collision.boundaryParticles.contains("as"))
        #expect(resources.collisionMemory.isEmpty)
    }

    /// ENG-R876 on the corpus. The 75 % and 99 % floors are stated for the habit 13.11 measures first (tone typed at
    /// the end of the word); with the tone typed after the vowel 13.11 records 98.8 % (501 of 507) for the Vietnamese
    /// side, which is that habit's own floor here, so it holds even when the fixture is regenerated. Every other
    /// condition (no wrong revision, no non-collision change, English at least 75 %) applies to both habits.
    @Test(
        "ENG-R876: the corpus meets the targets and matches its frozen outputs",
        arguments: [
            CorpusFixture.toneLast, .toneAfterVowel,
        ])
    func corpus(_ fixture: CorpusFixture) throws {
        let runs = try FixtureRuns.of(fixture)
        let score = runs.score
        print(score.report(title: "\(fixture) with the collision rules"))
        try runs.recordIfRequested()
        #expect(score.alignmentErrors.isEmpty, "\(score.alignmentErrors.joined(separator: "\n"))")
        #expect(score.sentences == 1_206)
        #expect(score.collisions.english.total == 720, "13.11: 720 English-intent collisions")
        #expect(
            score.badRevisions.isEmpty,
            "ENG-R876, any wrong revision fails:\n\(score.badRevisions.joined(separator: "\n"))")
        #expect(score.nonCollisionChanges.isEmpty, "\(score.nonCollisionChanges.joined(separator: "\n"))")
        #expect(score.collisions.english.share >= 0.75)
        #expect(score.hidden.right == score.hidden.total, "hidden collisions are never changed by a rule")
        if fixture == .toneLast {
            #expect(score.collisions.vietnamese.total == 623, "13.11: 623 Vietnamese-intent collisions")
            #expect(score.collisions.vietnamese.share >= 0.99)
        } else {
            #expect(score.collisions.vietnamese.total == 507, "13.11: 507 Vietnamese-intent collisions")
            #expect(score.collisions.vietnamese.share >= Self.toneAfterVowelVietnameseFloor)
        }
        let mismatches =
            "\(score.mismatches.count) sentences differ from the frozen fixture (update it with COLLISION_CORPUS_RECORD "
            + "and review, Fixtures/README.txt):\n\(score.mismatches.prefix(30).joined(separator: "\n"))"
        #expect(score.mismatches.isEmpty, "\(mismatches)")
    }

    /// 13.11 for the tone typed after the vowel: 501 of 507 (98.8 %), the measured share rounded down.
    static let toneAfterVowelVietnameseFloor = 0.988

    /// ENG-R829: without the collision rules the engine decides as it did before them (13.11: 58.5 % and 94.5 %,
    /// no revision), so the gain of the rules is measured against a fixed baseline.
    @Test("ENG-R829: the corpus without the collision rules gives the baseline of 13.11")
    func corpusWithoutTheCollisionRules() throws {
        let runs = try FixtureRuns.of(.toneLast)
        let off = try #require(runs.off)
        let score = CorpusScore.score(runs.sentences, off, baseline: nil)
        print(score.report(title: "\(CorpusFixture.toneLast) without the collision rules"))
        #expect(score.alignmentErrors.isEmpty)
        #expect(score.revisions == 0)
        #expect(score.collisions.english.right == 421 && score.collisions.english.total == 720)
        #expect(score.collisions.vietnamese.right == 589 && score.collisions.vietnamese.total == 623)
        #expect(score.exactSentences == 876)
    }

    @Test(
        "ENG-R876: the adversarial sets make no wrong revision and match their frozen outputs",
        arguments: CorpusFixture.sets)
    func adversarialSet(_ fixture: CorpusFixture) throws {
        let runs = try FixtureRuns.of(fixture)
        let score = runs.score
        print(score.report(title: "\(fixture) with the collision rules"))
        try runs.recordIfRequested()
        #expect(score.alignmentErrors.isEmpty, "\(score.alignmentErrors.joined(separator: "\n"))")
        #expect(
            score.badRevisions.isEmpty,
            "ENG-R876, any wrong revision fails:\n\(score.badRevisions.joined(separator: "\n"))")
        #expect(score.revisions > 0, "the set exercises the revision rules")
        let mismatches = score.mismatches.prefix(30).joined(separator: "\n")
        #expect(
            score.mismatches.isEmpty,
            "\(score.mismatches.count) sentences differ from the frozen fixture:\n\(mismatches)")
    }

    /// ENG-R864, ENG-R866: every collision signal of the corpus names a word of the bundled collision list (the
    /// ambiguity table or the collision supplement), never other text, and a replay without corrections gives only
    /// weak signals (silent acceptance).
    @Test("ENG-R866: corpus signals name only bundled collision words")
    func signalsNameOnlyBundledWords() throws {
        let resources = try GateResources.bundled()
        let runs = try FixtureRuns.of(.toneLast)
        let signals = runs.on.flatMap(\.signals)
        let foreign = signals.filter {
            resources.ambiguity[$0.word] == nil && !resources.collision.supplement.contains($0.word)
        }
        print("[ENG-R866] \(signals.count) collision signals in the corpus replay, \(foreign.count) outside the list")
        #expect(!signals.isEmpty)
        #expect(foreign.isEmpty)
        #expect(signals.allSatisfy { $0.strength == .weak })
    }
}
