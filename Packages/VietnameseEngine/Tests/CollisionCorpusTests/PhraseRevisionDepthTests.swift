// SPDX-License-Identifier: MPL-2.0
//
// RV1 of ENG-R828 looks back up to two tokens before the token it revises. With the rules alone that depth never
// matters: when the older tokens and the token start a phrase, L9b (ENG-R826) restores the token at its own commit,
// so the corpus only meets RV1 with one older token. The deeper lookup is reached when L9c (ENG-R801, ENG-R863)
// overrides an L6 to L8 decision, which L9b never sees: the memory keeps the Vietnamese display of a word in the
// middle of a phrase, and the next word completes the phrase. These cases pin that depth (QA-R68). With the bundled
// phrase list no word decided by L6 to L8 is the third word of a four-word phrase, so the depth of three tokens is
// not reachable through `Session` and stays covered by the shared phrase chain of L9b.

import Testing
import VietnameseEngine
import VietnameseEngineTesting

@Suite("QA-R68: RV1 revises a memory decision two words into a phrase (ENG-R828)")
struct PhraseRevisionDepthTests {
    /// Strong signals toward the Vietnamese side from two classes: the any-context entry votes for the Vietnamese
    /// display in every class (ENG-R863), while no single class entry reaches a score of 2.
    static func memoryKeepingVietnamese(_ word: String) -> CollisionMemorySnapshot {
        ReferenceCollisionMemory().recording(
            [CollisionContext.afterVietnamese, .afterEnglish].map {
                CollisionSignal(word: word, context: $0, side: .vietnamese, strength: .strong)
            }
        ).snapshot
    }

    static func replay(_ keys: String, memory: CollisionMemorySnapshot) throws -> ReplayResult {
        try HostReplay(engine: try GateResources.engine(memory: memory)).run(try HostInput.parse(keys))
    }

    /// `or` displays `ỏ`, an unattested syllable, so L8 restores it and L9b is never asked; the memory keeps `ỏ`, and
    /// the next word completes `more or less` (or `sooner or later`) with two older tokens: `or less` and `or later`
    /// start no phrase, so RV1 with one older token does not match.
    @Test(
        "A word kept by the memory inside a phrase is restored when the phrase completes",
        arguments: [
            ("more or less{RET}", "or", 1),
            ("sooner or later{RET}", "or", 1),
            ("Minhf thaays more or less ok{RET}", "or", 3),
        ])
    func depthTwo(_ keys: String, word: String, index: Int) throws {
        let memory = Self.memoryKeepingVietnamese(word)
        let plain = try Self.replay(keys, memory: .empty)
        let learned = try Self.replay(keys, memory: memory)
        #expect(plain.tokens[index].decision == .restored(.notAttested))
        #expect(learned.tokens[index].decision == .kept(.learned), "the memory decides the word (L9c)")
        #expect(learned.tokens[index].revision == .phrase, "RV1 with two older tokens revises it")
        #expect(learned.notation == plain.notation)
    }

    @Test("Without the rest of the phrase the memory decision stands")
    func memoryDecisionStands() throws {
        let learned = try Self.replay("more or {RET}", memory: Self.memoryKeepingVietnamese("or"))
        #expect(learned.notation == "more ỏ {RET}")
        #expect(learned.tokens[1].decision == .kept(.learned) && learned.tokens[1].revision == nil)
    }
}
