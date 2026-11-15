// SPDX-License-Identifier: MPL-2.0
//
// A reference model of the learned collision memory, written from the text of spec/01-engine.md ENG-R863 and
// nothing else. It serves the memory simulation of QA-R68 (ENG-R877, Tests/CollisionCorpusTests) and is the
// oracle the host's store must agree with: for every sequence of `CollisionSignal` values, the votes of the
// AppCore memory store (SettingsStore, workstream W11-B) MUST equal the votes of this model, entry by entry, and
// so must the decisions of the snapshots both publish. The model covers what ENG-R863 states: two entries per
// word (one per context class, one for any context), corrections and silent acceptances per side, the classes
// the corrections came from, the vote thresholds, the conflict and the any-context two-class rule. Decay, the
// entry cap and storage are the host's (spec/02-platform.md) and are not modelled, so the model and the store are
// compared before the first decay or eviction.
//
// One reading of the text, recorded so that the store makes the same one: an entry whose side X holds a
// correction and reaches the score of 2 but misses the ratio of 3 against the other side, while the other side
// holds no correction, gives no vote (not a conflict), so the lookup falls through to the any-context entry. A
// conflict needs corrections on both sides (ENG-R863: "corrections on both sides and no winner").

public import VietnameseEngine

/// The learned memory of ENG-R863 as a value: signals in, votes and a `CollisionMemorySnapshot` out.
public struct ReferenceCollisionMemory: Sendable, Hashable {
    /// The counters of one entry (ENG-R863).
    public struct Entry: Sendable, Hashable {
        /// Corrections (strong signals) toward the English side.
        public private(set) var englishCorrections = 0.0
        /// Corrections (strong signals) toward the Vietnamese side.
        public private(set) var vietnameseCorrections = 0.0
        /// Silent acceptances (weak signals) of the English side.
        public private(set) var englishAcceptances = 0
        /// Silent acceptances (weak signals) of the Vietnamese side.
        public private(set) var vietnameseAcceptances = 0
        /// The context classes the English corrections came from.
        public private(set) var englishCorrectionContexts: Set<CollisionContext> = []
        /// The context classes the Vietnamese corrections came from.
        public private(set) var vietnameseCorrectionContexts: Set<CollisionContext> = []

        /// An empty entry.
        public init() {}

        /// The entry with one more signal counted.
        func recording(_ signal: CollisionSignal) -> Entry {
            var entry = self
            switch (signal.strength, signal.side) {
            case (.strong, .english):
                entry.englishCorrections += 1
                entry.englishCorrectionContexts.insert(signal.context)
            case (.strong, .vietnamese):
                entry.vietnameseCorrections += 1
                entry.vietnameseCorrectionContexts.insert(signal.context)
            case (.weak, .english):
                entry.englishAcceptances = min(entry.englishAcceptances + 1, Thresholds.storedAcceptanceCap)
            case (.weak, .vietnamese):
                entry.vietnameseAcceptances = min(entry.vietnameseAcceptances + 1, Thresholds.storedAcceptanceCap)
            }
            return entry
        }

        func corrections(_ side: Language) -> Double {
            side == .english ? englishCorrections : vietnameseCorrections
        }

        func acceptances(_ side: Language) -> Int { side == .english ? englishAcceptances : vietnameseAcceptances }

        func correctionContexts(_ side: Language) -> Set<CollisionContext> {
            side == .english ? englishCorrectionContexts : vietnameseCorrectionContexts
        }
    }

    /// The numbers of ENG-R863.
    public enum Thresholds {
        /// "At least one correction toward X".
        public static let minimumCorrections = 1.0
        /// The weight of one silent acceptance.
        public static let acceptanceWeight = 0.25
        /// Own acceptances counted toward a side's score: min(acceptances(X), 4).
        public static let ownAcceptanceCap = 4
        /// The other side's acceptances counted against it: min(acceptances(Y), 64).
        public static let otherAcceptanceCap = 64
        /// The score a side needs.
        public static let minimumScore = 2.0
        /// The score must be at least this many times the other side's.
        public static let ratio = 3.0
        /// The any-context entry votes only with corrections from at least this many classes.
        public static let anyContextClasses = 2
        /// Acceptances are stored up to this count (no vote reads more).
        public static let storedAcceptanceCap = 64
    }

    /// An entry's address: a word of the bundled collision list and a context class, nil for any context.
    public struct Key: Sendable, Hashable {
        /// The collision word (lowercased raw keys, ENG-R866).
        public let word: String
        /// The class of the entry; nil for the any-context entry.
        public let context: CollisionContext?

        /// A key.
        public init(word: String, context: CollisionContext?) {
            self.word = word
            self.context = context
        }
    }

    /// Every entry, created by the first signal for its word and context (a weak signal creates one too; an
    /// entry without a correction never votes).
    public private(set) var entries: [Key: Entry] = [:]

    /// An empty memory.
    public init() {}

    /// The memory with `signals` counted in order: each signal updates its word's class entry and its
    /// any-context entry (ENG-R863).
    public func recording<S: Sequence>(_ signals: S) -> ReferenceCollisionMemory where S.Element == CollisionSignal {
        var memory = self
        for signal in signals {
            for key in [Key(word: signal.word, context: signal.context), Key(word: signal.word, context: nil)] {
                memory.entries[key] = (memory.entries[key] ?? Entry()).recording(signal)
            }
        }
        return memory
    }

    /// The vote of one entry, nil when the entry is missing or does not vote.
    public func vote(word: String, context: CollisionContext?) -> CollisionVote? {
        guard let entry = entries[Key(word: word, context: context)] else { return nil }
        return Self.vote(of: entry, anyContext: context == nil)
    }

    /// ENG-R863: side X wins when it holds at least one correction, corrections(X) + 0.25 x min(acceptances(X), 4)
    /// is at least 2 and that score is at least 3 x [corrections(Y) + 0.25 x min(acceptances(Y), 64)]; the
    /// any-context entry votes only when the winning side's corrections came from at least two classes and none
    /// went to the other side; corrections on both sides and no winner is a conflict.
    public static func vote(of entry: Entry, anyContext: Bool) -> CollisionVote? {
        for side in [Language.english, .vietnamese] where wins(side, entry, anyContext: anyContext) {
            return side == .english ? .english : .vietnamese
        }
        let both =
            entry.englishCorrections >= Thresholds.minimumCorrections
            && entry.vietnameseCorrections >= Thresholds.minimumCorrections
        return both ? .conflict : nil
    }

    private static func wins(_ side: Language, _ entry: Entry, anyContext: Bool) -> Bool {
        let other: Language = side == .english ? .vietnamese : .english
        let own = entry.corrections(side)
        guard own >= Thresholds.minimumCorrections else { return false }
        let score =
            own + Thresholds.acceptanceWeight * Double(min(entry.acceptances(side), Thresholds.ownAcceptanceCap))
        let against =
            entry.corrections(other)
            + Thresholds.acceptanceWeight * Double(min(entry.acceptances(other), Thresholds.otherAcceptanceCap))
        guard score >= Thresholds.minimumScore, score >= Thresholds.ratio * against else { return false }
        guard anyContext else { return true }
        return entry.correctionContexts(side).count >= Thresholds.anyContextClasses
            && entry.correctionContexts(other).isEmpty
    }

    /// Every entry that votes, as the snapshot the engine reads (ENG-R865); its `vote(word:context:)` is the
    /// lookup of ENG-R863 (the class entry first, a class entry in conflict means the rules decide, otherwise the
    /// any-context entry).
    public var snapshot: CollisionMemorySnapshot {
        CollisionMemorySnapshot(
            entries.compactMap { key, entry in
                Self.vote(of: entry, anyContext: key.context == nil).map {
                    CollisionMemorySnapshot.Vote(word: key.word, context: key.context, choice: $0)
                }
            })
    }

    /// The number of entries that vote (`english`, `vietnamese` or `conflict`).
    public var votingEntryCount: Int {
        entries.reduce(0) { count, item in
            count + (Self.vote(of: item.value, anyContext: item.key.context == nil) == nil ? 0 : 1)
        }
    }
}
