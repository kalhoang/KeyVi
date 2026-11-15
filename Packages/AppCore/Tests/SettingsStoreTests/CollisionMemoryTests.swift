// SPDX-License-Identifier: GPL-3.0-or-later
//
// The learned memory's rules (ENG-R863, ENG-R864; research algorithm section 4, the decision of the product owner of
// 15/11/2026): vote thresholds, conflict, the any-context two-class rule, 90-day decay, 180-day deletion, the
// 2,048-entry cap with its eviction order, merging and validation against the bundled list. Table-driven.

import Foundation
import Testing

@testable import SettingsStore

private func entry(
    english: Double = 0, vietnamese: Double = 0, acceptedEnglish: Int = 0, acceptedVietnamese: Int = 0,
    classesEnglish: UInt8 = 0, classesVietnamese: UInt8 = 0, day: Int = 0
) -> CollisionMemoryEntry {
    var entry = CollisionMemoryEntry(day: day)
    entry.corrections = CollisionSidePair(english: english, vietnamese: vietnamese)
    entry.acceptances = CollisionSidePair(english: acceptedEnglish, vietnamese: acceptedVietnamese)
    entry.correctionClasses = CollisionSidePair(english: classesEnglish, vietnamese: classesVietnamese)
    return entry
}

private func signal(
    _ word: String, _ context: CollisionMemoryContext, _ side: CollisionMemorySide, strong: Bool = true
) -> CollisionMemorySignal {
    CollisionMemorySignal(word: word, context: context, side: side, strength: strong ? .strong : .weak)
}

private let vietnameseClasses = CollisionMemoryContext.afterVietnamese.bit | CollisionMemoryContext.afterNeutral.bit

@Suite("CollisionMemoryStoreTests: votes") struct CollisionMemoryVoteTests {
    struct Row: CustomTestStringConvertible, Sendable {
        var name: String
        var entry: CollisionMemoryEntry
        var anyContext = false
        var expected: CollisionMemoryChoice?
        var testDescription: String { name }
    }

    /// ENG-R863: X wins with >= 1 correction, score >= 2 and score >= 3 x the other side's weight; corrections on both
    /// sides and no winner is a conflict; acceptances alone never vote.
    static let rows: [Row] = [
        Row(name: "one correction is not enough", entry: entry(vietnamese: 1), expected: nil),
        Row(name: "two corrections vote", entry: entry(vietnamese: 2), expected: .vietnamese),
        Row(
            name: "one correction and four acceptances vote", entry: entry(vietnamese: 1, acceptedVietnamese: 4),
            expected: .vietnamese),
        Row(
            name: "acceptances beyond four add nothing", entry: entry(english: 1, acceptedEnglish: 3),
            expected: nil),
        Row(name: "acceptances alone never vote", entry: entry(acceptedVietnamese: 64), expected: nil),
        Row(name: "2 against 1 is a conflict", entry: entry(english: 1, vietnamese: 2), expected: .conflict),
        Row(name: "3 against 1 wins", entry: entry(english: 1, vietnamese: 3), expected: .vietnamese),
        Row(
            name: "other side's acceptances count against", entry: entry(vietnamese: 2, acceptedEnglish: 4),
            expected: nil),
        Row(
            name: "a few acceptances against still lose", entry: entry(vietnamese: 2, acceptedEnglish: 2),
            expected: .vietnamese),
        Row(
            name: "up to 64 acceptances count against",
            entry: entry(vietnamese: 2, acceptedEnglish: 64, acceptedVietnamese: 64), expected: nil),
        Row(name: "English side", entry: entry(english: 2), expected: .english),
        Row(
            name: "any context: one class is not enough",
            entry: entry(vietnamese: 2, classesVietnamese: CollisionMemoryContext.afterVietnamese.bit),
            anyContext: true, expected: nil),
        Row(
            name: "any context: two classes vote", entry: entry(vietnamese: 2, classesVietnamese: vietnameseClasses),
            anyContext: true, expected: .vietnamese),
        Row(
            name: "any context: a correction toward the other side blocks",
            entry: entry(
                english: 1, vietnamese: 4, classesEnglish: CollisionMemoryContext.afterEnglish.bit,
                classesVietnamese: vietnameseClasses),
            anyContext: true, expected: .conflict),
        Row(
            name: "a decayed correction toward the other side no longer blocks",
            entry: entry(english: 0.25, vietnamese: 3, classesVietnamese: vietnameseClasses), anyContext: true,
            expected: .vietnamese),
    ]

    @Test(arguments: rows) func voteFollowsTheThresholds(_ row: Row) {
        #expect(CollisionMemory.vote(row.entry, anyContext: row.anyContext) == row.expected)
    }

    /// Lookup order (ENG-R863): the snapshot carries class conflicts so that they hide the any-context entry.
    @Test func votesListConflictsAndSkipAcceptanceOnlyEntries() {
        let memory = CollisionMemory(entries: [
            CollisionMemoryKey(word: "as", context: .afterVietnamese): entry(english: 1, vietnamese: 2),
            CollisionMemoryKey(word: "as", context: nil): entry(vietnamese: 3, classesVietnamese: vietnameseClasses),
            CollisionMemoryKey(word: "cos", context: .sentenceStart): entry(acceptedVietnamese: 10),
            CollisionMemoryKey(word: "car", context: .afterEnglish): entry(english: 2),
        ])
        #expect(
            memory.votes == [
                CollisionMemoryVote(word: "as", context: nil, choice: .vietnamese),
                CollisionMemoryVote(word: "as", context: .afterVietnamese, choice: .conflict),
                CollisionMemoryVote(word: "car", context: .afterEnglish, choice: .english),
            ])
        #expect(memory.learnedChoices.map(\.word) == ["as", "car"])
    }
}

@Suite("CollisionMemoryStoreTests: signals and upkeep") struct CollisionMemoryUpkeepTests {
    /// ENG-R864: a strong signal is one correction, a weak one an acceptance; both update the class entry and the
    /// any-context entry, and only the any-context entry records the class the correction came from.
    @Test func signalsUpdateTheClassAndTheAnyContextEntry() {
        let memory = CollisionMemory.empty.applying(
            [signal("as", .afterVietnamese, .vietnamese), signal("as", .afterNeutral, .vietnamese, strong: false)],
            day: 10)
        let byClass = memory.entries[CollisionMemoryKey(word: "as", context: .afterVietnamese)]
        let any = memory.entries[CollisionMemoryKey(word: "as", context: nil)]
        #expect(byClass?.corrections.vietnamese == 1 && byClass?.correctionClasses.vietnamese == 0)
        #expect(memory.entries[CollisionMemoryKey(word: "as", context: .afterNeutral)]?.acceptances.vietnamese == 1)
        #expect(any?.corrections.vietnamese == 1 && any?.acceptances.vietnamese == 1)
        #expect(any?.correctionClasses.vietnamese == CollisionMemoryContext.afterVietnamese.bit)
        #expect(memory.count == 3)
    }

    /// Silent acceptance creates the entry (the product owner asked to learn from non-corrections) but never votes.
    @Test func weakSignalsCreateEntriesThatNeverVoteAndCapAt64() {
        let signals = Array(repeating: signal("cos", .sentenceStart, .vietnamese, strong: false), count: 70)
        let memory = CollisionMemory.empty.applying(signals, day: 0)
        #expect(memory.entries[CollisionMemoryKey(word: "cos", context: .sentenceStart)]?.acceptances.vietnamese == 64)
        #expect(memory.votes.isEmpty)
    }

    struct DecayRow: CustomTestStringConvertible, Sendable {
        var day: Int
        /// Nil: the entry was deleted (under 0.5 corrections and no signal for 180 days).
        var corrections: Double?
        var acceptances: Int?
        var votes: Bool
        var testDescription: String { "day \(day)" }
    }

    /// Two corrections and nine acceptances on day 0, nothing since: halved after every 90 days, deleted once under
    /// half a correction with no signal for 180 days.
    static let decayRows: [DecayRow] = [
        DecayRow(day: 89, corrections: 2, acceptances: 9, votes: true),
        DecayRow(day: 90, corrections: 1, acceptances: 4, votes: true),
        DecayRow(day: 179, corrections: 1, acceptances: 4, votes: true),
        DecayRow(day: 180, corrections: 0.5, acceptances: 2, votes: false),
        DecayRow(day: 270, corrections: nil, acceptances: nil, votes: false),
    ]

    @Test(arguments: decayRows) func countersHalveEvery90DaysWithoutACorrection(_ row: DecayRow) {
        let key = CollisionMemoryKey(word: "as", context: .afterVietnamese)
        let memory = CollisionMemory(entries: [key: entry(vietnamese: 2, acceptedVietnamese: 9)]).aged(to: row.day)
        let aged = memory.entries[key]
        #expect(aged?.corrections.vietnamese == row.corrections)
        #expect(aged?.acceptances.vietnamese == row.acceptances)
        #expect((memory.votes.first?.choice == .vietnamese) == row.votes)
    }

    /// A new correction restarts the decay clock.
    @Test func aCorrectionRestartsTheDecayClock() {
        let key = CollisionMemoryKey(word: "as", context: .afterVietnamese)
        var memory = CollisionMemory(entries: [key: entry(vietnamese: 2)])
        memory = memory.applying([signal("as", .afterVietnamese, .vietnamese)], day: 80)
        #expect(memory.aged(to: 169).entries[key]?.corrections.vietnamese == 3)
        #expect(memory.aged(to: 170).entries[key]?.corrections.vietnamese == 1.5)
    }

    /// Both correction scores under 0.5 and no signal for 180 days: deleted. A side whose corrections decayed below
    /// 0.5 also forgets the classes they came from.
    @Test func staleEntriesAreDeletedAfter180Days() {
        let corrected = CollisionMemoryKey(word: "as", context: nil)
        let accepted = CollisionMemoryKey(word: "cos", context: .sentenceStart)
        let memory = CollisionMemory(entries: [
            corrected: entry(vietnamese: 1, classesVietnamese: vietnameseClasses),
            accepted: entry(acceptedVietnamese: 1),
        ])
        #expect(memory.aged(to: 179).count == 2)
        #expect(memory.aged(to: 179).entries[corrected]?.correctionClasses.vietnamese == vietnameseClasses)
        #expect(memory.aged(to: 180).isEmpty)
        let strong = CollisionMemory(entries: [corrected: entry(vietnamese: 4, day: 0)])
        #expect(strong.aged(to: 270).entries[corrected]?.corrections.vietnamese == 0.5)
        #expect(strong.aged(to: 360).isEmpty)
    }

    /// At most 2,048 entries: acceptance-only entries go first, then the least recently updated.
    @Test func theCapEvictsAcceptanceOnlyEntriesFirstThenTheOldest() {
        var entries: [CollisionMemoryKey: CollisionMemoryEntry] = [:]
        for index in 0..<CollisionMemory.capacity {
            entries[CollisionMemoryKey(word: "w\(index)", context: .afterEnglish)] = entry(english: 1, day: 100 + index)
        }
        entries[CollisionMemoryKey(word: "accepted", context: .afterEnglish)] = entry(acceptedEnglish: 5, day: 9_000)
        entries[CollisionMemoryKey(word: "new", context: .afterEnglish)] = entry(english: 1, day: 9_000)
        let capped = CollisionMemory(entries: entries).capped()
        #expect(capped.count == CollisionMemory.capacity)
        #expect(capped.entries[CollisionMemoryKey(word: "accepted", context: .afterEnglish)] == nil)
        #expect(capped.entries[CollisionMemoryKey(word: "w0", context: .afterEnglish)] == nil)
        #expect(capped.entries[CollisionMemoryKey(word: "w1", context: .afterEnglish)] != nil)
        #expect(capped.entries[CollisionMemoryKey(word: "new", context: .afterEnglish)] != nil)
    }

    /// PLT-R914: only words of the bundled collision list survive a load or an import.
    @Test func validationDropsWordsOutsideTheBundledList() {
        let memory = CollisionMemory.empty.applying(
            [signal("as", .sentenceStart, .vietnamese), signal("hello", .sentenceStart, .english)], day: 1)
        let validated = memory.validated(against: ["as", "cos"])
        #expect(Set(validated.entries.keys.map(\.word)) == ["as"])
    }

    /// PRD-R72: import adds counters; masks join; acceptances stay capped.
    @Test func mergingAddsCounters() {
        let key = CollisionMemoryKey(word: "as", context: nil)
        let mine = CollisionMemory(entries: [
            key: entry(vietnamese: 1, acceptedVietnamese: 60, classesVietnamese: 2, day: 5)
        ])
        let theirs = CollisionMemory(entries: [
            key: entry(english: 1, vietnamese: 1, acceptedVietnamese: 10, classesVietnamese: 8, day: 9)
        ])
        let merged = mine.merging(theirs).entries[key]
        #expect(merged?.corrections == CollisionSidePair(english: 1, vietnamese: 2))
        #expect(merged?.acceptances.vietnamese == 64)
        #expect(merged?.correctionClasses.vietnamese == 10)
        #expect(merged?.lastDay == 9)
    }

    /// Imported counters keep their age: both entries are aged to the later decay day before they are added, so an
    /// old correction from a file does not count in full on the newer entry's clock (research section 4 decay).
    @Test func mergingAgesBothSidesToTheLaterDecayDayFirst() {
        let key = CollisionMemoryKey(word: "as", context: .afterVietnamese)
        let mine = CollisionMemory(entries: [key: entry(english: 1, day: 1_000)])
        let theirs = CollisionMemory(entries: [key: entry(vietnamese: 2, day: 0)])
        let merged = mine.merging(theirs).aged(to: 1_000).entries[key]
        #expect(merged?.corrections.english == 1)
        #expect((merged?.corrections.vietnamese ?? 1) < 0.01, "eleven halvings of 2, not 2")
        #expect(merged?.decayDay == 1_000)
        let reversed = theirs.merging(mine).aged(to: 1_000).entries[key]
        #expect(reversed?.corrections == merged?.corrections)
    }

    @Test func removingOneRowOrAWord() {
        let memory = CollisionMemory.empty.applying([signal("as", .afterVietnamese, .vietnamese)], day: 1)
        #expect(memory.removing(CollisionMemoryKey(word: "as", context: nil)).count == 1)
        #expect(memory.removing(word: "as").isEmpty)
    }

    @Test func dayNumbersAreUTCDays() {
        #expect(CollisionMemory.day(of: Date(timeIntervalSince1970: 86_400 * 3 + 5)) == 3)
        #expect(CollisionMemory.day(of: Date(timeIntervalSince1970: 86_400 - 1)) == 0)
    }
}
