// SPDX-License-Identifier: GPL-3.0-or-later
//
// collision-memory.json, schema version 1 (PLT-R914), and the `collisionMemory` section of a settings export
// (PRD-R72). The file is untrusted on read: every entry is checked on its own and a bad one is dropped, never the
// whole file. Words are checked against the bundled list by the store, not here.
//
//     {
//       "schemaVersion": 1,
//       "writtenBy": "0.1.0",
//       "entries": [
//         { "word": "as", "context": "afterVietnamese", "correctionsEnglish": 0, "correctionsVietnamese": 2,
//           "acceptedEnglish": 0, "acceptedVietnamese": 3, "classesEnglish": 0, "classesVietnamese": 0,
//           "decayDay": 20407, "lastDay": 20407 }
//       ]
//     }
//
// `context` is `any` for the any-context entry. Days are UTC day numbers (`CollisionMemory.day(of:)`).

internal import AppModel
internal import Foundation

enum CollisionMemoryCodec {
    static let schemaVersion = 1
    static let entriesKey = "entries"
    static let anyContext = "any"
    /// Words of the bundled list are short; anything longer cannot be one.
    static let maximumWordLength = 64
    /// Corrections above this are not something a person typed.
    static let maximumCorrections = 1_000_000.0
    /// Day numbers outside this range are not dates of this program's life.
    static let dayRange = 0...200_000

    private struct EntryRecord: Codable {
        var word: String
        var context: String
        var correctionsEnglish: Double
        var correctionsVietnamese: Double
        var acceptedEnglish: Int
        var acceptedVietnamese: Int
        var classesEnglish: Int
        var classesVietnamese: Int
        var decayDay: Int
        var lastDay: Int
    }

    // MARK: Decoding

    /// The entries of a file payload or an export section; invalid entries are left out.
    static func decodeEntries(_ items: [JSONValue]) -> CollisionMemory {
        var entries: [CollisionMemoryKey: CollisionMemoryEntry] = [:]
        for item in items {
            guard let record = JSONSupport.decode(EntryRecord.self, from: item),
                let (key, entry) = validated(record), entries[key] == nil
            else { continue }
            entries[key] = entry
        }
        return CollisionMemory(entries: entries)
    }

    static func decode(_ object: [String: JSONValue]) -> CollisionMemory {
        guard case .array(let items)? = object[entriesKey] else { return .empty }
        return decodeEntries(items)
    }

    private static func validated(_ record: EntryRecord) -> (CollisionMemoryKey, CollisionMemoryEntry)? {
        let word = record.word
        guard !word.isEmpty, word.count <= maximumWordLength, word == word.lowercased(),
            !word.contains(where: \.isWhitespace)
        else { return nil }
        let context: CollisionMemoryContext?
        if record.context == anyContext {
            context = nil
        } else {
            guard let named = CollisionMemoryContext(rawValue: record.context) else { return nil }
            context = named
        }
        let corrections = [record.correctionsEnglish, record.correctionsVietnamese]
        guard corrections.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= maximumCorrections }) else { return nil }
        let accepted = 0...CollisionMemory.acceptanceCap
        guard accepted.contains(record.acceptedEnglish), accepted.contains(record.acceptedVietnamese) else {
            return nil
        }
        let masks = 0...15
        guard masks.contains(record.classesEnglish), masks.contains(record.classesVietnamese) else { return nil }
        guard dayRange.contains(record.decayDay), dayRange.contains(record.lastDay) else { return nil }
        var entry = CollisionMemoryEntry(day: record.lastDay)
        entry.decayDay = record.decayDay
        entry.corrections = CollisionSidePair(
            english: record.correctionsEnglish, vietnamese: record.correctionsVietnamese)
        entry.acceptances = CollisionSidePair(english: record.acceptedEnglish, vietnamese: record.acceptedVietnamese)
        // Class masks belong to the any-context entry only.
        if context == nil {
            entry.correctionClasses = CollisionSidePair(
                english: UInt8(record.classesEnglish), vietnamese: UInt8(record.classesVietnamese))
        }
        return (CollisionMemoryKey(word: word, context: context), entry)
    }

    // MARK: Encoding

    /// The entries in key order, corrections rounded to two decimals.
    static func encodeEntries(_ memory: CollisionMemory) -> [JSONValue] {
        memory.entries.keys.sorted().compactMap { key in
            guard let entry = memory.entries[key] else { return nil }
            let record = EntryRecord(
                word: key.word, context: key.context?.rawValue ?? anyContext,
                correctionsEnglish: rounded(entry.corrections.english),
                correctionsVietnamese: rounded(entry.corrections.vietnamese),
                acceptedEnglish: entry.acceptances.english, acceptedVietnamese: entry.acceptances.vietnamese,
                classesEnglish: Int(entry.correctionClasses.english),
                classesVietnamese: Int(entry.correctionClasses.vietnamese), decayDay: entry.decayDay,
                lastDay: entry.lastDay)
            return JSONSupport.encode(record)
        }
    }

    static func encodeFile(_ memory: CollisionMemory, writtenBy: String) -> [String: JSONValue] {
        [
            EnvelopeKey.schemaVersion: .number(Double(schemaVersion)),
            EnvelopeKey.writtenBy: .string(writtenBy),
            entriesKey: .array(encodeEntries(memory)),
        ]
    }

    private static func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }
}
