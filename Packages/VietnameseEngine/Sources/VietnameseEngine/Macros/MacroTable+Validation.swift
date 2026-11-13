// SPDX-License-Identifier: MPL-2.0

extension MacroTable {
    /// ENG-R1101: an expansion holds at most 4,000 characters.
    package static let maximumExpansionLength = 4_000

    /// Validates `entries` (ENG-R1101, ENG-R1103) and builds the lookup of ENG-R1105. Throws the first
    /// problem found, in entry order: an empty trigger, a character that is not printable ASCII without
    /// whitespace, a trigger longer than 32 characters, an expansion longer than 4,000 characters, a
    /// trigger equal to an earlier one ignoring case, then a trigger that a shorter trigger shadows.
    ///
    /// Shadowing (ENG-R1103): typing `T` passes through every prefix of `T`; a punctuation character
    /// is a boundary, so when `T` continues with punctuation after a prefix `P` that is itself a trigger,
    /// `P` fires first and `T` can never fire (`ad` shadows `ad.` and also `ad.x`). A main-row digit
    /// counts like punctuation (decision of the product owner, 13/11/2026): in Telex it is a boundary,
    /// so `k` shadows `k1`. The check does not depend on the typing method, so a table valid for one
    /// method is valid for all, and the host's editor applies the same rule (PRD-R29).
    ///
    /// The engine does not normalise expansions; the host stores them in NFC (ENG-R1101). Edits that
    /// replace or remove an expansion count grapheme clusters and UTF-16 units separately, so any text
    /// is handled exactly.
    static func validatedLookup(_ entries: [Entry]) throws -> [MacroKey: Int] {
        var lookup: [MacroKey: Int] = [:]
        lookup.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            let key = try validatedKey(entry)
            guard lookup[key] == nil else { throw ValidationError.duplicateTrigger(entry.trigger) }
            lookup[key] = index
        }
        for entry in entries {
            let bytes = Array(entry.trigger.utf8)
            for length in 1..<bytes.count where endsShorterTrigger(bytes[length]) {
                if let key = MacroKey(lowercasing: bytes[0..<length]), let shorter = lookup[key] {
                    throw ValidationError.shadowedByShorterTrigger(
                        trigger: entry.trigger, shorter: entries[shorter].trigger)
                }
            }
        }
        return lookup
    }

    private static func validatedKey(_ entry: Entry) throws -> MacroKey {
        let trigger = entry.trigger
        guard !trigger.isEmpty else { throw ValidationError.emptyTrigger(trigger) }
        guard trigger.utf8.allSatisfy(MacroKey.isTriggerByte) else {
            throw ValidationError.invalidTriggerCharacter(trigger)
        }
        guard trigger.utf8.count <= MacroKey.capacity, let key = MacroKey(lowercasing: trigger.utf8) else {
            throw ValidationError.triggerTooLong(trigger)
        }
        guard entry.expansion.count <= maximumExpansionLength else {
            throw ValidationError.expansionTooLong(trigger)
        }
        return key
    }

    /// Printable ASCII that is not a letter: punctuation, a boundary in every configuration except the
    /// brackets with the Telex bracket option, which count here because they are boundaries by default
    /// (ENG-R104); and digits, a boundary in Telex (ENG-R1103, decision of 13/11/2026).
    @inline(__always)
    private static func endsShorterTrigger(_ byte: UInt8) -> Bool {
        MacroKey.isTriggerByte(byte) && !ASCII.isLetter(byte)
    }

    /// The entry whose trigger equals `key` (ENG-R1105: one hash lookup whatever the table size).
    @inline(__always)
    package func entry(for key: MacroKey) -> Entry? {
        guard let index = lookup[key] else { return nil }
        return entries[index]
    }

    package var isEmpty: Bool { entries.isEmpty }
}
