// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// The value types of the collision API (12.2 additions): the phrase list, the memory snapshot, the pending
/// signals and the phrase chain.
@Suite("Collision API values")
struct CollisionAPITests {
    @Test("ENG-R826 PhraseList: prefixes of two to four words, constant-time lookups, invalid phrases ignored")
    func phraseList() {
        let list = PhraseList(["as soon as", "such as", "single", "a b c d e", "been there done that", "such  as"])
        #expect(list.count == 4)
        func starts(_ words: [String]) -> Bool {
            var packed = PhraseWords()
            for word in words { packed.append(list.number(of: word)) }
            return list.startsPhrase(packed)
        }
        #expect(starts(["as", "soon"]) && starts(["as", "soon", "as"]) && starts(["such", "as"]))
        #expect(starts(["been", "there", "done", "that"]))
        #expect(!starts(["soon", "as"]) && !starts(["as"]) && !starts(["single"]))
        #expect(list.number(of: "unknown") == 0 && PhraseList.empty.number(of: "as") == 0)
        #expect(!list.startsPhrase(nil))
        var five = PhraseWords()
        for _ in 0..<5 { five.append(1) }
        #expect(five.count == 4)
    }

    @Test("ENG-R863 CollisionMemorySnapshot: context first, conflict means the rules, later votes win")
    func memorySnapshot() {
        let snapshot = CollisionMemorySnapshot([
            .init(word: "car", context: .afterEnglish, choice: .english),
            .init(word: "car", context: .afterVietnamese, choice: .conflict),
            .init(word: "car", context: nil, choice: .vietnamese),
            .init(word: "as", context: .sentenceStart, choice: .vietnamese),
            .init(word: "as", context: .sentenceStart, choice: .english),
            .init(word: "been", context: nil, choice: .conflict),
        ])
        #expect(!snapshot.isEmpty && CollisionMemorySnapshot.empty.isEmpty)
        #expect(snapshot.vote(word: "car", context: .afterEnglish) == .english)
        #expect(snapshot.vote(word: "car", context: .afterVietnamese) == nil)
        #expect(snapshot.vote(word: "car", context: .afterNeutral) == .vietnamese)
        #expect(snapshot.vote(word: "car", context: .sentenceStart) == .vietnamese)
        #expect(snapshot.vote(word: "as", context: .sentenceStart) == .english)
        #expect(snapshot.vote(word: "as", context: .afterNeutral) == nil)
        #expect(snapshot.vote(word: "been", context: .afterEnglish) == nil)
        #expect(snapshot.vote(word: "test", context: .afterEnglish) == nil)
        #expect(CollisionContext.allCases.count == 4)
    }

    @Test("ENG-R864 PendingSignals: three tokens, the fourth commit makes the oldest final")
    func pendingSignals() {
        func signal(_ word: String) -> CollisionSignal {
            CollisionSignal(word: word, context: .sentenceStart, side: .vietnamese, strength: .weak)
        }
        var pending = PendingSignals()
        pending.popNewest()
        #expect(pending.count == 0)
        #expect(pending.push(signal("a")) == nil && pending.push(nil) == nil && pending.push(signal("c")) == nil)
        #expect(pending.push(signal("d")) == signal("a"))
        pending.withdraw(atDistance: 1)
        pending.withdraw(atDistance: 9)
        #expect(pending.flush() == [signal("c")])
        #expect(pending.count == 0)
        _ = pending.push(signal("x"))
        _ = pending.push(signal("y"))
        pending.popNewest()
        pending.popNewest()
        #expect(pending.flush().isEmpty)
        _ = pending.push(signal("p"))
        _ = pending.push(signal("q"))
        _ = pending.push(signal("r"))
        pending.withdraw(atDistance: 3)
        pending.withdraw(atDistance: 2)
        pending.popNewest()
        #expect(pending.flush().isEmpty)
    }

    @Test("ENG-R826 PhraseChain: single spaces between phrase words, at most three")
    func phraseChain() throws {
        let resources = CollisionFixture.resources(
            lists: CollisionLists(phrases: PhraseList(["a b c d", "x y"])))
        func chain(_ keys: String) throws -> PhraseChain {
            PhraseChain(history: try CollisionFixture.driver(keys, resources: resources).state.history)
        }
        #expect(try chain("a b c ").count == 3)
        #expect(try chain("x a b c ").count == 3)
        #expect(try chain("a b, c ").count == 1)
        #expect(try chain("a b  ").count == 0)
        #expect(try chain("a vieejt ").count == 0)
        #expect(try chain("").count == 0)
        #expect(try chain("a b").count == 1)
    }

    @Test("Rule classes: collision rules, revisable rules and rules that give weak signals")
    func ruleClasses() {
        #expect(CommitRule.boundaryParticle.isCollisionRule && !CommitRule.boundaryParticle.isRevisable)
        #expect(CommitRule.phrase.isCollisionRule && !CommitRule.phrase.givesWeakSignal)
        #expect(CommitRule.learned.isRevisable && CommitRule.learned.givesWeakSignal)
        #expect(!CommitRule.notEnglish.isCollisionRule && CommitRule.notEnglish.givesWeakSignal)
        #expect(!CommitRule.userChoice.isRevisable && !CommitRule.userChoice.givesWeakSignal)
        #expect(CommitDecision.macro.rule == nil && CommitDecision.kept(.escape).rule == .escape)
        #expect(
            RevisionEvidence.isAllCaps("OK") && !RevisionEvidence.isAllCaps("A") && !RevisionEvidence.isAllCaps("Ok"))
        #expect(!RevisionEvidence.isAllCaps("12"))
        // A macro expansion is neither fixed nor evidence of a language (it never reaches a revision).
        let macro = RevisionEvidence(
            inputs: CommitInputs(token: ActiveToken(), style: .traditional), decision: .macro, text: "", phraseWord: 0)
        #expect(!macro.isFixed)
        let policy = CommitPolicy(
            resources: CollisionFixture.resources(), configuration: EngineConfiguration(typoCorrection: false))
        #expect(!policy.isStrictEnglish(macro) && !policy.isVietnameseEvidence(macro))
    }
}
