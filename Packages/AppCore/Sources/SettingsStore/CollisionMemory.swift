// SPDX-License-Identifier: GPL-3.0-or-later
//
// The learned memory for words of the bundled collision list (spec/01-engine.md ENG-R863, ENG-R864; spec/02-platform.md
// PLT-R914; decision of the product owner, 15/11/2026: per user across all apps, learned from corrections and from
// silent acceptance). Pure values: the counters, the votes the engine reads, decay, deletion and the entry cap. The
// store (`CollisionMemoryStore`) persists them. SettingsStore does not depend on the engine, so the vocabulary here
// mirrors the engine's `CollisionContext`, `CollisionSignal` and `CollisionVote`; InputHost maps between them.
//
// Privacy (PLT-R901, ENG-R866): a word is the lowercased raw keys of a bundled collision word, validated against the
// bundled list, never free text. It is shown in Settings and never logged.

public import Foundation

/// The class of the previous token when a collision word was decided (ENG-R863).
public enum CollisionMemoryContext: String, Sendable, Hashable, CaseIterable, Codable {
    case sentenceStart, afterVietnamese, afterEnglish, afterNeutral

    /// One bit of the 4-bit class masks of the any-context entry.
    var bit: UInt8 {
        switch self {
        case .sentenceStart: 1
        case .afterVietnamese: 2
        case .afterEnglish: 4
        case .afterNeutral: 8
        }
    }
}

/// The reading the user chose or accepted.
public enum CollisionMemorySide: String, Sendable, Hashable, CaseIterable, Codable {
    case english, vietnamese

    var other: CollisionMemorySide { self == .english ? .vietnamese : .english }
}

/// One signal of ENG-R864, as the store records it.
public struct CollisionMemorySignal: Sendable, Hashable {
    public enum Strength: Sendable, Hashable {
        /// A correction (weight 1).
        case strong
        /// A silent acceptance (an acceptance count, worth 0.25 in a vote, at most 4 of them).
        case weak
    }

    /// Lowercased raw keys of a bundled collision word.
    public var word: String
    public var context: CollisionMemoryContext
    public var side: CollisionMemorySide
    public var strength: Strength

    public init(word: String, context: CollisionMemoryContext, side: CollisionMemorySide, strength: Strength) {
        self.word = word
        self.context = context
        self.side = side
        self.strength = strength
    }
}

/// What an entry says (ENG-R863).
public enum CollisionMemoryChoice: String, Sendable, Hashable, Codable {
    case english, vietnamese
    /// Corrections on both sides and no winner: the rules decide; a context entry in conflict also hides the
    /// any-context entry.
    case conflict
}

/// One entry's vote. `context` nil is the any-context entry.
public struct CollisionMemoryVote: Sendable, Hashable {
    public var word: String
    public var context: CollisionMemoryContext?
    public var choice: CollisionMemoryChoice

    public init(word: String, context: CollisionMemoryContext?, choice: CollisionMemoryChoice) {
        self.word = word
        self.context = context
        self.choice = choice
    }
}

/// The bundled collision list (the ambiguity table's words and the collision supplement, ENG-R862) as a membership
/// test: SettingsStore does not see the engine's resources, so InputHost passes the test in (PLT-R914).
public struct CollisionVocabulary: Sendable, ExpressibleByArrayLiteral {
    private let test: @Sendable (String) -> Bool

    public init(contains test: @escaping @Sendable (String) -> Bool) { self.test = test }
    public init(_ words: Set<String>) { test = { words.contains($0) } }
    public init(arrayLiteral words: String...) { self.init(Set(words)) }

    public func contains(_ word: String) -> Bool { test(word) }
}

/// An entry's identity: a word in one context class, or in any context (`context` nil).
public struct CollisionMemoryKey: Sendable, Hashable, Comparable {
    public var word: String
    public var context: CollisionMemoryContext?

    public init(word: String, context: CollisionMemoryContext?) {
        self.word = word
        self.context = context
    }

    /// Word, then the any-context entry, then the classes in declaration order (stable file and list order).
    public static func < (lhs: CollisionMemoryKey, rhs: CollisionMemoryKey) -> Bool {
        if lhs.word != rhs.word { return lhs.word < rhs.word }
        return rank(lhs.context) < rank(rhs.context)
    }

    private static func rank(_ context: CollisionMemoryContext?) -> Int {
        guard let context else { return -1 }
        return CollisionMemoryContext.allCases.firstIndex(of: context) ?? 0
    }
}

/// A value per side.
public struct CollisionSidePair<Value: Sendable & Hashable>: Sendable, Hashable {
    public var english: Value
    public var vietnamese: Value

    public init(english: Value, vietnamese: Value) {
        self.english = english
        self.vietnamese = vietnamese
    }

    public subscript(side: CollisionMemorySide) -> Value {
        get { side == .english ? english : vietnamese }
        set {
            if side == .english { english = newValue } else { vietnamese = newValue }
        }
    }
}

/// The counters of one entry (ENG-R863, algorithm section 4).
public struct CollisionMemoryEntry: Sendable, Hashable {
    /// Corrections toward each side; decayed, so fractional.
    public var corrections = CollisionSidePair<Double>(english: 0, vietnamese: 0)
    /// Silent acceptances of each side, at most `CollisionMemory.acceptanceCap`.
    public var acceptances = CollisionSidePair<Int>(english: 0, vietnamese: 0)
    /// The any-context entry only: the classes the corrections toward each side came from (4-bit masks).
    public var correctionClasses = CollisionSidePair<UInt8>(english: 0, vietnamese: 0)
    /// The day the next 90-day halving is counted from: the last correction, the last halving, or the entry's
    /// creation when it has none.
    public var decayDay: Int
    /// The day of the last signal.
    public var lastDay: Int

    public init(day: Int) {
        decayDay = day
        lastDay = day
    }

    /// A correction toward `side` counts while at least half of one is left after decay.
    public func hasCorrections(toward side: CollisionMemorySide) -> Bool {
        corrections[side] >= CollisionMemory.correctionFloor
    }

    /// No correction toward either side: only acceptances (evicted first, never votes).
    public var isAcceptanceOnly: Bool { !hasCorrections(toward: .english) && !hasCorrections(toward: .vietnamese) }
}

/// The learned memory: at most two kinds of entries per word, one per context class and one for any context.
public struct CollisionMemory: Sendable, Hashable {
    /// At most this many entries (algorithm section 4: five full passes over the W11 corpus keep 688).
    public static let capacity = 2_048
    /// Without a new correction for this many days, corrections and acceptances halve.
    public static let decayPeriodDays = 90
    /// An entry with both correction scores under `correctionFloor` and no signal for this many days is deleted.
    public static let deletionDays = 180
    public static let acceptanceCap = 64
    /// Below this a correction no longer counts (one halving keeps a correction, two drop it).
    public static let correctionFloor = 0.5
    /// Vote thresholds (ENG-R863): at least one correction, a score of 2, three times the other side.
    static let minimumCorrections = 1.0
    static let minimumScore = 2.0
    static let dominance = 3.0
    static let acceptanceWeight = 0.25
    static let acceptancesForVote = 4
    /// The any-context entry votes only when its corrections came from at least this many classes.
    static let classesForAnyContext = 2

    public private(set) var entries: [CollisionMemoryKey: CollisionMemoryEntry]

    public init(entries: [CollisionMemoryKey: CollisionMemoryEntry] = [:]) { self.entries = entries }

    public static let empty = CollisionMemory()

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    /// UTC day number of `date` (days since 1970-01-01), the memory's only clock.
    public static func day(of date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    // MARK: Signals

    /// The memory after `signals` on `day`: each signal updates the word's class entry and its any-context entry
    /// (a missing entry is created, also by a weak signal), after decay, then the cap applies.
    public func applying(_ signals: [CollisionMemorySignal], day: Int) -> CollisionMemory {
        var copy = self
        for signal in signals where !signal.word.isEmpty {
            copy.record(signal, key: CollisionMemoryKey(word: signal.word, context: signal.context), day: day)
            copy.record(signal, key: CollisionMemoryKey(word: signal.word, context: nil), day: day)
        }
        return copy.capped()
    }

    private mutating func record(_ signal: CollisionMemorySignal, key: CollisionMemoryKey, day: Int) {
        var entry = entries[key].map { Self.aged($0, to: day) } ?? CollisionMemoryEntry(day: day)
        switch signal.strength {
        case .strong:
            entry.corrections[signal.side] += 1
            entry.decayDay = day
            if key.context == nil { entry.correctionClasses[signal.side] |= signal.context.bit }
        case .weak:
            entry.acceptances[signal.side] = min(entry.acceptances[signal.side] + 1, Self.acceptanceCap)
        }
        entry.lastDay = max(entry.lastDay, day)
        entries[key] = entry
    }

    // MARK: Votes

    /// Every entry that votes or is in conflict, in key order. Acceptance-only entries never vote.
    public var votes: [CollisionMemoryVote] {
        entries.keys.sorted().compactMap { key in
            guard let entry = entries[key], let choice = Self.vote(entry, anyContext: key.context == nil) else {
                return nil
            }
            return CollisionMemoryVote(word: key.word, context: key.context, choice: choice)
        }
    }

    /// The votes the Settings sheet lists: entries that vote for a side (no conflicts, no counters).
    public var learnedChoices: [CollisionMemoryVote] { votes.filter { $0.choice != .conflict } }

    /// ENG-R863: side X wins when it holds a correction, corrections(X) + 0.25 x min(acceptances(X), 4) >= 2 and
    /// that score is at least 3 x [corrections(Y) + 0.25 x min(acceptances(Y), 64)]. The any-context entry also
    /// needs corrections from two classes and none toward Y. Corrections on both sides and no winner: conflict.
    public static func vote(_ entry: CollisionMemoryEntry, anyContext: Bool) -> CollisionMemoryChoice? {
        for side in CollisionMemorySide.allCases where wins(side, entry, anyContext: anyContext) {
            return side == .english ? .english : .vietnamese
        }
        if entry.hasCorrections(toward: .english) && entry.hasCorrections(toward: .vietnamese) { return .conflict }
        return nil
    }

    private static func wins(_ side: CollisionMemorySide, _ entry: CollisionMemoryEntry, anyContext: Bool) -> Bool {
        let corrections = entry.corrections[side]
        guard corrections >= minimumCorrections else { return false }
        let score = corrections + acceptanceWeight * Double(min(entry.acceptances[side], acceptancesForVote))
        let other = side.other
        let against = entry.corrections[other] + acceptanceWeight * Double(min(entry.acceptances[other], acceptanceCap))
        guard score >= minimumScore, score >= dominance * against else { return false }
        guard anyContext else { return true }
        return entry.correctionClasses[side].nonzeroBitCount >= classesForAnyContext
            && !entry.hasCorrections(toward: other)
    }

    // MARK: Upkeep

    /// Decay to `day`, then deletion of stale entries (algorithm section 4 "Upkeep").
    public func aged(to day: Int) -> CollisionMemory {
        var kept: [CollisionMemoryKey: CollisionMemoryEntry] = [:]
        for (key, entry) in entries {
            let aged = Self.aged(entry, to: day)
            if !aged.hasCorrections(toward: .english) && !aged.hasCorrections(toward: .vietnamese)
                && day - aged.lastDay >= Self.deletionDays
            {
                continue
            }
            kept[key] = aged
        }
        return CollisionMemory(entries: kept)
    }

    /// After every 90 days without a new correction both correction scores and both acceptance counts halve; a
    /// side whose corrections fell under the floor forgets the classes they came from.
    static func aged(_ entry: CollisionMemoryEntry, to day: Int) -> CollisionMemoryEntry {
        let periods = (day - entry.decayDay) / decayPeriodDays
        guard periods > 0 else { return entry }
        var aged = entry
        let halvings = min(periods, 64)
        let factor = pow(0.5, Double(halvings))
        for side in CollisionMemorySide.allCases {
            aged.corrections[side] *= factor
            aged.acceptances[side] >>= halvings
            if !aged.hasCorrections(toward: side) { aged.correctionClasses[side] = 0 }
        }
        aged.decayDay += periods * decayPeriodDays
        return aged
    }

    /// At most `capacity` entries: acceptance-only entries go first, then the least recently updated; ties by key.
    public func capped() -> CollisionMemory {
        guard entries.count > Self.capacity else { return self }
        let order = entries.sorted { lhs, rhs in
            if lhs.value.isAcceptanceOnly != rhs.value.isAcceptanceOnly { return lhs.value.isAcceptanceOnly }
            if lhs.value.lastDay != rhs.value.lastDay { return lhs.value.lastDay < rhs.value.lastDay }
            return lhs.key < rhs.key
        }
        var kept = entries
        for (key, _) in order.prefix(entries.count - Self.capacity) { kept.removeValue(forKey: key) }
        return CollisionMemory(entries: kept)
    }

    // MARK: Editing

    /// Only words of `vocabulary` (the bundled collision list): anything else is dropped (PLT-R914).
    public func validated(against vocabulary: CollisionVocabulary) -> CollisionMemory {
        CollisionMemory(entries: entries.filter { vocabulary.contains($0.key.word) })
    }

    /// Every day no later than `day` (PLT-R912): an imported entry dated in the future (a wrong clock, a crafted
    /// export) would otherwise age the local counters to that day when merged, or freeze their decay until then.
    public func dated(notAfter day: Int) -> CollisionMemory {
        CollisionMemory(
            entries: entries.mapValues { entry in
                var dated = entry
                dated.decayDay = min(entry.decayDay, day)
                dated.lastDay = min(entry.lastDay, day)
                return dated
            })
    }

    /// Without the entry `key` (one row of the learned-words sheet).
    public func removing(_ key: CollisionMemoryKey) -> CollisionMemory {
        var copy = entries
        copy.removeValue(forKey: key)
        return CollisionMemory(entries: copy)
    }

    /// Without any entry of `word`.
    public func removing(word: String) -> CollisionMemory {
        CollisionMemory(entries: entries.filter { $0.key.word != word })
    }

    /// Import (PRD-R72): counters of the same entry are added after both are aged to the later decay day
    /// (acceptances capped), class masks joined, days kept at the later one; then the cap applies. The older side
    /// loses the phase of its current 90-day period when its decay clock moves to the later day, so merging and
    /// ageing in either order differ by at most one halving of that side.
    public func merging(_ other: CollisionMemory) -> CollisionMemory {
        var merged = entries
        for (key, theirs) in other.entries {
            guard let mine = merged[key] else {
                merged[key] = theirs
                continue
            }
            // Both are aged to the later decay day first, so counters keep their own age.
            let day = max(mine.decayDay, theirs.decayDay)
            var entry = Self.aged(mine, to: day)
            let incoming = Self.aged(theirs, to: day)
            for side in CollisionMemorySide.allCases {
                entry.corrections[side] += incoming.corrections[side]
                entry.acceptances[side] = min(entry.acceptances[side] + incoming.acceptances[side], Self.acceptanceCap)
                entry.correctionClasses[side] |= incoming.correctionClasses[side]
            }
            entry.decayDay = max(entry.decayDay, incoming.decayDay)
            entry.lastDay = max(entry.lastDay, incoming.lastDay)
            merged[key] = entry
        }
        return CollisionMemory(entries: merged).capped()
    }
}
