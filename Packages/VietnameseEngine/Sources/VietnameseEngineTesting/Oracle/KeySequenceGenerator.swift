// SPDX-License-Identifier: MPL-2.0

public import VietnameseEngine

/// Input method of a generated case (default options for Telex).
public enum CorpusMethod: String, Sendable, Hashable, CaseIterable {
    case telex, vni

    public var inputMethod: InputMethod {
        switch self {
        case .telex: return .telex(TelexOptions())
        case .vni: return .vni
        }
    }
}

/// The key orders of ENG-T02.
public enum CorpusOrder: String, Sendable, Hashable, CaseIterable {
    /// Letters in order, each modifier key right after its letter, the `w` (VNI `7`) of `ươ` after the
    /// `o`, the stroke key right after `d`, tone key last.
    case o1
    /// As O1 with the tone key right after the vowel group.
    case o2
    /// Base letters only, then stroke, modifier keys and tone key after the last letter.
    case o3
    /// Tone key right after the first letter of the vowel group (exercises relocation). Not
    /// generated for the level tone.
    case o4
}

/// The extra Telex O1 variants of ENG-T03.
public enum CorpusVariant: String, Sendable, Hashable, CaseIterable {
    /// First key uppercase.
    case titlecase
    /// Every key uppercase.
    case uppercase
    /// `ươ` typed with its own `w` on each letter (`uwow`).
    case explicitUwow
}

/// Key sequences that type a syllable (ENG-T02, ENG-T03). Spellings are lowercase onset and rhyme
/// strings as in spec 3.3 and 3.7 to 3.9 (`"ngh"`, `"iêng"`); the committed spelling of an open
/// `uơ` is used, so `huơ` is typed `huow`.
public enum KeySequenceGenerator {
    private struct Unit {
        /// Keys for the unmodified letter (Telex types the second `o` of a literal `oo` as `oo`).
        var base: String
        /// Modifier or stroke key typed after the letter in O1; empty if none.
        var modifier: String
        var isStroke: Bool
    }

    private static let vowels: Set<Character> = ["a", "ă", "â", "e", "ê", "i", "o", "ô", "ơ", "u", "ư", "y"]

    private static func toneKey(_ tone: Tone, _ method: CorpusMethod) -> String {
        guard tone != .level else { return "" }
        switch method {
        case .telex: return ["", "s", "f", "r", "x", "j"][tone.rawValue]
        case .vni: return String(tone.rawValue)
        }
    }

    private static func units(_ letters: [Character], method: CorpusMethod, explicitUwow: Bool) -> [Unit] {
        let telex: [Character: (String, String)] = [
            "ă": ("a", "w"), "â": ("a", "a"), "ê": ("e", "e"), "ô": ("o", "o"), "ơ": ("o", "w"), "ư": ("u", "w"),
            "đ": ("d", "d"),
        ]
        let vni: [Character: (String, String)] = [
            "ă": ("a", "8"), "â": ("a", "6"), "ê": ("e", "6"), "ô": ("o", "6"), "ơ": ("o", "7"), "ư": ("u", "7"),
            "đ": ("d", "9"),
        ]
        let map = method == .telex ? telex : vni
        return letters.indices.map { index in
            let letter = letters[index]
            var (base, modifier) = map[letter] ?? (String(letter), "")
            // The horn of an ươ pair is typed once, after the o (ENG-T02 O1), unless the variant asks
            // for the explicit `uwow`.
            if letter == "ư", index + 1 < letters.count, letters[index + 1] == "ơ", !explicitUwow { modifier = "" }
            // ENG-T02: in Telex the literal `oo` of `ooc` / `oong` needs the escape, typed `ooo`.
            if method == .telex, letter == "o", index > 0, letters[index - 1] == "o" { base = "oo" }
            return Unit(base: base, modifier: modifier, isStroke: letter == "đ")
        }
    }

    /// The keys typing `onset` + `rhyme` with `tone` in `order`; nil for O4 with the level tone.
    public static func keys(onset: String, rhyme: String, tone: Tone, method: CorpusMethod, order: CorpusOrder) -> String? {
        let letters = Array(onset) + Array(rhyme)
        let units = units(letters, method: method, explicitUwow: false)
        let vowelStart = onset.count
        var vowelEnd = vowelStart
        while vowelEnd < letters.count, vowels.contains(letters[vowelEnd]) { vowelEnd += 1 }
        let tone = toneKey(tone, method)
        func typed(_ range: Range<Int>) -> String { units[range].map { $0.base + $0.modifier }.joined() }

        switch order {
        case .o1:
            return typed(0..<units.count) + tone
        case .o2:
            return typed(0..<vowelEnd) + tone + typed(vowelEnd..<units.count)
        case .o3:
            let bases = units.map(\.base).joined()
            let stroke = units.filter(\.isStroke).map(\.modifier).joined()
            let modifiers = units.filter { !$0.isStroke }.map(\.modifier).joined()
            return bases + stroke + modifiers + tone
        case .o4:
            guard !tone.isEmpty else { return nil }
            return typed(0..<(vowelStart + 1)) + tone + typed((vowelStart + 1)..<units.count)
        }
    }

    /// The Telex O1 variant of ENG-T03; nil for `explicitUwow` when the rhyme has no `ươ`.
    public static func variantKeys(onset: String, rhyme: String, tone: Tone, variant: CorpusVariant) -> String? {
        switch variant {
        case .titlecase:
            guard let keys = keys(onset: onset, rhyme: rhyme, tone: tone, method: .telex, order: .o1) else { return nil }
            return keys.prefix(1).uppercased() + keys.dropFirst()
        case .uppercase:
            return keys(onset: onset, rhyme: rhyme, tone: tone, method: .telex, order: .o1)?.uppercased()
        case .explicitUwow:
            guard rhyme.contains("ươ") else { return nil }
            let letters = Array(onset) + Array(rhyme)
            return units(letters, method: .telex, explicitUwow: true).map { $0.base + $0.modifier }.joined()
                + toneKey(tone, .telex)
        }
    }
}
