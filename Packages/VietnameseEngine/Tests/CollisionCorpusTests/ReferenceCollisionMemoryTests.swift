// SPDX-License-Identifier: MPL-2.0
//
// The reference vote model of the memory simulation follows the text of ENG-R863: the worked cases of
// `CollisionMemoryVoteCases` (the same table the host's store runs for parity), plus the properties the
// simulation relies on (ENG-R877: silent acceptance never votes; ENG-R1202: the snapshot is a value).

import Testing
import VietnameseEngine
import VietnameseEngineTesting

@Suite("ENG-R863: the reference vote model of the memory simulation")
struct ReferenceCollisionMemoryTests {
    @Test("Every worked case of ENG-R863", arguments: CollisionMemoryVoteCases.all)
    func workedCase(_ example: CollisionMemoryVoteCases.Case) {
        let memory = ReferenceCollisionMemory().recording(example.signals)
        for expected in example.votes {
            #expect(
                memory.vote(word: expected.word, context: expected.context) == expected.vote,
                "\(example.name): entry \(expected.context.map { "\($0)" } ?? "any context")")
        }
        let snapshot = memory.snapshot
        for lookup in example.lookups {
            #expect(
                snapshot.vote(word: lookup.word, context: lookup.context) == lookup.decision,
                "\(example.name): lookup in \(lookup.context)")
        }
    }

    @Test("Each signal updates the class entry and the any-context entry; acceptances are stored up to 64")
    func entriesAndCounters() {
        let signals =
            [CollisionSignal(word: "as", context: .afterEnglish, side: .english, strength: .strong)]
            + Array(
                repeating: CollisionSignal(word: "as", context: .afterEnglish, side: .vietnamese, strength: .weak),
                count: 70)
        let memory = ReferenceCollisionMemory().recording(signals)
        #expect(memory.entries.count == 2)
        let classEntry = memory.entries[.init(word: "as", context: .afterEnglish)]
        let anyEntry = memory.entries[.init(word: "as", context: nil)]
        #expect(classEntry == anyEntry)
        #expect(classEntry?.englishCorrections == 1)
        #expect(classEntry?.vietnameseAcceptances == ReferenceCollisionMemory.Thresholds.storedAcceptanceCap)
        #expect(classEntry?.englishCorrectionContexts == [.afterEnglish])
    }

    @Test("Recording returns a new memory and leaves the old one as it was")
    func recordingIsAValue() {
        let empty = ReferenceCollisionMemory()
        let signal = CollisionSignal(word: "car", context: .sentenceStart, side: .english, strength: .strong)
        let once = empty.recording([signal])
        let twice = once.recording([signal])
        #expect(empty.entries.isEmpty)
        #expect(once.votingEntryCount == 0)
        #expect(twice.votingEntryCount == 1)
        #expect(twice.snapshot.vote(word: "car", context: .sentenceStart) == .english)
        #expect(once.snapshot.isEmpty)
    }

    @Test("ENG-R877: any number of silent acceptances, in any context, never makes a vote")
    func acceptanceAloneNeverVotes() {
        var generator = SeededGenerator(seed: 877)
        let words = ["as", "car", "been", "its", "cos"]
        let signals = (0..<5_000).map { _ in
            CollisionSignal(
                word: words.randomElement(using: &generator)!,
                context: CollisionContext.allCases.randomElement(using: &generator)!,
                side: Bool.random(using: &generator) ? .english : .vietnamese, strength: .weak)
        }
        let memory = ReferenceCollisionMemory().recording(signals)
        #expect(memory.entries.count == words.count * 5)
        #expect(memory.votingEntryCount == 0)
        #expect(memory.snapshot.isEmpty)
    }
}
