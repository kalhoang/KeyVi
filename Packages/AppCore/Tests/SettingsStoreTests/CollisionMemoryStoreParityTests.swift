// SPDX-License-Identifier: GPL-3.0-or-later
//
// Parity of the host's collision memory store with the engine's reference model (ENG-R863, ENG-R877): the store
// (`CollisionMemoryStore`, PLT-R914) and `ReferenceCollisionMemory` (VietnameseEngineTesting, written from the text of
// ENG-R863 alone) must read the requirement the same way. Both are fed the same signals on one day, so neither decay
// nor the entry cap applies (the reference does not model them); the store's votes then go through the same mapping
// InputHost uses (`CollisionMemoryBridge.snapshot`) and must equal the reference's snapshot, entry by entry, and give
// the same lookups. The worked cases of ENG-R863 (`CollisionMemoryVoteCases`) come first, then seeded random signal
// sequences over three words, the four context classes, both sides and both strengths.

import AppModel
import Foundation
import RealtimeSupport
import TestSupport
import Testing
import VietnameseEngine
import VietnameseEngineTesting

@testable import SettingsStore

@Suite("CollisionMemoryStoreParityTests: the store reads ENG-R863 like the reference model")
struct CollisionMemoryStoreParityTests {
    private static let words = ["as", "car", "cos"]
    /// Every word the worked cases sign or look up, so none is dropped as unknown (PLT-R914).
    private static let vocabulary = CollisionVocabulary(
        Set(words + CollisionMemoryVoteCases.all.flatMap { $0.signals.map(\.word) + $0.lookups.map(\.word) }))

    /// ENG-R863 worked cases: the store's per-entry votes and the snapshot's lookups are the ones the text gives.
    @Test(arguments: CollisionMemoryVoteCases.all)
    func theWorkedCasesGiveTheExpectedVotesAndLookups(_ testCase: CollisionMemoryVoteCases.Case) {
        let store = Self.loadedStore()
        store.apply(testCase.signals.map(Self.signal))
        let entries = Dictionary(
            uniqueKeysWithValues: store.votes.map { (CollisionMemoryKey(word: $0.word, context: $0.context), $0) })
        for expected in testCase.votes {
            let key = CollisionMemoryKey(word: expected.word, context: expected.context.map(Self.context))
            #expect(
                entries[key].map { Self.vote($0.choice) } == expected.vote,
                "entry \(expected.word) \(String(describing: expected.context))")
        }
        let snapshot = Self.snapshot(store.votes)
        for lookup in testCase.lookups {
            #expect(
                snapshot.vote(word: lookup.word, context: lookup.context) == lookup.decision,
                "lookup \(lookup.word) \(lookup.context)")
        }
        #expect(snapshot == ReferenceCollisionMemory().recording(testCase.signals).snapshot)
    }

    /// ENG-R877 oracle: 200 seeded sequences of up to 900 signals, applied in batches of random size (the host drains
    /// signals in batches), give the reference's snapshot before any decay or eviction. Long sequences reach the
    /// stored acceptance cap of 64; the coverage counts keep the comparison from passing on empty memories.
    @Test func randomSignalSequencesGiveTheReferenceSnapshot() {
        var generator = SeededGenerator(seed: 0x5EED_C011_15E0)
        var coverage = (votes: 0, conflicts: 0, cappedAcceptances: 0)
        for sequence in 0..<200 {
            let signals = Self.randomSignals(count: Int.random(in: 1...900, using: &generator), using: &generator)
            let store = Self.loadedStore()
            var remaining = signals[...]
            while !remaining.isEmpty {
                let batch = remaining.prefix(Int.random(in: 1...8, using: &generator))
                store.apply(batch.map(Self.signal))
                remaining = remaining.dropFirst(batch.count)
            }
            let reference = ReferenceCollisionMemory().recording(signals)
            #expect(store.entryCount <= CollisionMemory.capacity, "no eviction in sequence \(sequence)")
            #expect(Self.snapshot(store.votes) == reference.snapshot, "sequence \(sequence)")
            let choices = Set(store.votes.map(\.choice))
            if choices.contains(.english) || choices.contains(.vietnamese) { coverage.votes += 1 }
            if choices.contains(.conflict) { coverage.conflicts += 1 }
            let acceptances = store.memory.entries.values.flatMap {
                [$0.acceptances.english, $0.acceptances.vietnamese]
            }
            if acceptances.contains(CollisionMemory.acceptanceCap) { coverage.cappedAcceptances += 1 }
            for word in Self.words {
                for context in CollisionContext.allCases {
                    #expect(
                        Self.snapshot(store.votes).vote(word: word, context: context)
                            == reference.snapshot.vote(word: word, context: context),
                        "sequence \(sequence), lookup \(word) \(context)")
                }
            }
        }
        #expect(coverage.votes > 100 && coverage.conflicts > 50 && coverage.cappedAcceptances > 10, "\(coverage)")
    }

    // MARK: Helpers

    /// A store loaded with the vocabulary on a fixed day: every signal lands on the same day, so nothing decays.
    private static func loadedStore() -> CollisionMemoryStore {
        let harness = SettingsStoreHarness()
        let store = harness.store.collisionMemory
        store.load(vocabulary: vocabulary)
        return store
    }

    /// Each sequence leans its own way (how often English, how often a correction), so some give clear votes, some
    /// conflicts and some acceptances only.
    private static func randomSignals(count: Int, using generator: inout SeededGenerator) -> [CollisionSignal] {
        let englishShare = Double.random(in: 0...1, using: &generator)
        let strongShare = Double.random(in: 0.02...0.6, using: &generator)
        return (0..<count).map { _ in
            CollisionSignal(
                word: words.randomElement(using: &generator) ?? "as",
                context: CollisionContext.allCases.randomElement(using: &generator) ?? .sentenceStart,
                side: Double.random(in: 0..<1, using: &generator) < englishShare ? .english : .vietnamese,
                strength: Double.random(in: 0..<1, using: &generator) < strongShare ? .strong : .weak)
        }
    }

    /// The engine's signal as the store records it (InputHost `CollisionMemoryBridge.signals`).
    private static func signal(_ signal: CollisionSignal) -> CollisionMemorySignal {
        CollisionMemorySignal(
            word: signal.word, context: context(signal.context), side: signal.side == .english ? .english : .vietnamese,
            strength: signal.strength == .strong ? .strong : .weak)
    }

    /// The store's votes as the engine's snapshot (InputHost `CollisionMemoryBridge.snapshot`).
    private static func snapshot(_ votes: [CollisionMemoryVote]) -> CollisionMemorySnapshot {
        CollisionMemorySnapshot(
            votes.map {
                CollisionMemorySnapshot.Vote(word: $0.word, context: $0.context.map(context), choice: vote($0.choice))
            })
    }

    private static func context(_ context: CollisionContext) -> CollisionMemoryContext {
        switch context {
        case .sentenceStart: .sentenceStart
        case .afterVietnamese: .afterVietnamese
        case .afterEnglish: .afterEnglish
        case .afterNeutral: .afterNeutral
        }
    }

    private static func context(_ context: CollisionMemoryContext) -> CollisionContext {
        switch context {
        case .sentenceStart: .sentenceStart
        case .afterVietnamese: .afterVietnamese
        case .afterEnglish: .afterEnglish
        case .afterNeutral: .afterNeutral
        }
    }

    private static func vote(_ choice: CollisionMemoryChoice) -> CollisionVote {
        switch choice {
        case .english: .english
        case .vietnamese: .vietnamese
        case .conflict: .conflict
        }
    }
}
