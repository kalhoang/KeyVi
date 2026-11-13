// SPDX-License-Identifier: MPL-2.0

public import VietnameseEngine

/// Random macro tables for the fuzz campaign (spec 13.6: "a macro table of 1,000 random triggers,
/// including punctuation-only triggers").
public enum RandomMacroTable {
    /// Characters of letter-and-digit triggers. A small alphabet so that random streams hit triggers.
    private static let wordAlphabet: [Character] = Array("abdnovwkAN1")
    /// Characters of punctuation-only triggers (`@@`, `;;`, `.,`).
    private static let punctuationAlphabet: [Character] = Array("@.,;!-~#")

    /// `count` valid entries drawn from `seed`: punctuation-only triggers of three characters (several
    /// hundred) and triggers of 1 to 6 characters that start with a letter or digit and mix in punctuation. Candidates that the table would reject
    /// (a duplicate ignoring case, or a trigger shadowed by a shorter one, ENG-R1103) are skipped, so the
    /// result always validates. Expansions are NFC and stay in the Basic Multilingual Plane, so every
    /// edit keeps `deleteCount == deleteUTF16Count` (ENG-T34): plain ASCII, Vietnamese text, text with a
    /// newline, an empty expansion, and one expansion of the maximum 4,000 characters (ENG-R1101).
    public static func entries(count: Int, seed: UInt64) -> [MacroTable.Entry] {
        var generator = SeededGenerator(seed: seed)
        var candidates: [String] = []
        var seen = Set<String>()
        let mixedAlphabet = wordAlphabet + punctuationAlphabet.prefix(3)
        // Four candidates per entry: digits and punctuation after a shorter trigger both shadow (ENG-R1103), so
        // three were not enough for the benchmark's 10,000 entries.
        while candidates.count < count * 4 {
            let trigger: String
            if generator.chance(1, in: 3) {
                // Punctuation-only triggers all have three characters: a shorter one would shadow every
                // longer one that starts with it (ENG-R1103), and so would a single punctuation character.
                trigger = String((0..<3).map { _ in generator.pick(punctuationAlphabet) })
            } else {
                // Other triggers start with a letter or digit and may contain punctuation (`ad.`, `k1`).
                let rest = (0..<generator.nextInt(below: 6)).map { _ in generator.pick(mixedAlphabet) }
                trigger = String([generator.pick(wordAlphabet)] + rest)
            }
            if seen.insert(trigger.lowercased()).inserted { candidates.append(trigger) }
        }
        // Shortest first: a trigger can only be shadowed by a shorter one, so checking the accepted set is
        // enough.
        candidates.sort { ($0.count, $0) < ($1.count, $1) }
        var accepted = Set<String>()
        var entries: [MacroTable.Entry] = []
        for trigger in candidates where entries.count < count {
            let characters = Array(trigger.lowercased())
            let shadowed = (1..<max(1, characters.count)).contains { length in
                endsShorterTrigger(characters[length]) && accepted.contains(String(characters[..<length]))
            }
            guard !shadowed else { continue }
            accepted.insert(String(characters))
            entries.append(
                MacroTable.Entry(
                    trigger: trigger, expansion: expansion(index: entries.count, using: &generator),
                    adaptCase: !generator.chance(1, in: 5)))
        }
        return entries
    }

    /// A validated table of `count` random entries.
    public static func table(count: Int = 1_000, seed: UInt64 = 0x5EED_00AC_0001) throws -> MacroTable {
        try MacroTable(entries(count: count, seed: seed))
    }

    /// Punctuation or a digit after a shorter trigger: the shorter one fires there (ENG-R1103).
    private static func endsShorterTrigger(_ character: Character) -> Bool {
        guard let byte = character.asciiValue else { return false }
        return byte > 0x20 && byte < 0x7F && !character.isLetter
    }

    private static func expansion(index: Int, using generator: inout SeededGenerator) -> String {
        switch index {
        case 0: return String(repeating: "ă", count: 4_000)
        case 1: return ""
        default: break
        }
        switch generator.nextInt(below: 5) {
        case 0: return "Việt Nam \(index)"
        case 1: return "x\(index)\ny"
        case 2: return "được"
        case 3: return "(\(index)) ừ"
        default: return "kal\(index)@example.com"
        }
    }
}
