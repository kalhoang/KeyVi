// SPDX-License-Identifier: MPL-2.0

/// The onset of a parsed syllable (spec 3.3). Besides the Tier A and Tier B onsets it has cases for
/// the consonants that the parse of 3.13 can return but that start no syllable in any tier
/// (`f j w`, and `q` without `u`).
package enum Onset: UInt8, CaseIterable, Sendable, Hashable, CustomStringConvertible {
    case none
    // Tier A (3.3), in alphabetical order.
    case b, c, ch, d, dStroke, g, gh, gi, h, k, kh, l, m, n, ng, ngh, nh, p, ph, qu, r, s, t, th, tr, v, x
    // Tier B (3.3): ethnic-minority clusters, teencode `z`, colloquial `dz` (ENG-R316, REG-28).
    case bl, br, dr, dStrokeR, gl, gr, kl, kr, pl, pr, z, dz
    // Parse results that are never an onset in any tier (3.3: `f`, `j`, `w` are not onsets; `q` only as `qu`).
    case f, j, w, q

    /// The lowest tier in which this onset may start a syllable; nil for `f j w q`.
    package var tier: Validity? {
        switch self {
        case .f, .j, .w, .q: return nil
        case .bl, .br, .dr, .dStrokeR, .gl, .gr, .kl, .kr, .pl, .pr, .z, .dz: return .extended
        default: return .standard
        }
    }

    /// The onsets that start Tier A syllables (28 including no onset).
    package static let standardOnsets: [Onset] = allCases.filter { $0.tier == .standard }
    /// The onsets that start Tier B syllables, Tier A ones included.
    package static let extendedOnsets: [Onset] = allCases.filter { $0.tier != nil }

    /// Lowercase spelling, indexed by raw value (same order as the cases above).
    private static let spellings: [String] = [
        "",
        "b", "c", "ch", "d", "đ", "g", "gh", "gi", "h", "k", "kh", "l", "m", "n", "ng", "ngh", "nh", "p",
        "ph", "qu", "r", "s", "t", "th", "tr", "v", "x",
        "bl", "br", "dr", "đr", "gl", "gr", "kl", "kr", "pl", "pr", "z", "dz",
        "f", "j", "w", "q",
    ]

    package var spelling: String { Onset.spellings[Int(rawValue)] }

    package var description: String { spelling }

    package var letters: [Letter] { Letter.letters(spelling)! }

    /// The onset whose spelling is exactly `letters`, if any.
    package static func spelled(_ letters: some Collection<Letter>) -> Onset? {
        bySpelling[Array(letters)]
    }

    private static let bySpelling: [[Letter]: Onset] = {
        var table: [[Letter]: Onset] = [:]
        for onset in allCases { table[onset.letters] = onset }
        return table
    }()

    /// The single-consonant onset for a consonant letter (3.13 step 1, last case).
    package static func single(_ letter: Letter) -> Onset? {
        letter.isConsonant ? singleTable[Int(letter.code)] : nil
    }

    private static let singleTable: [Onset?] = Letter.all.map { letter in
        letter.isConsonant ? bySpelling[[letter]] : nil
    }

    /// Labial onsets after which Tier A forbids a medial glide (3.3, 3.4, ENG-R312), and the Tier B
    /// clusters that start with a labial.
    package var isLabial: Bool {
        switch self {
        case .b, .m, .p, .ph, .v, .bl, .br, .pl, .pr: return true
        default: return false
        }
    }

    /// Onsets after which no tier allows a medial glide: `c k gh ngh` (3.4, ENG-R312) and the
    /// clusters `kl kr` that start with `k` (reading recorded in docs/decisions/0100). `gi` and `qu`
    /// have their own rhyme lists (3.8, 3.9).
    package var forbidsMedial: Bool {
        switch self {
        case .c, .k, .gh, .ngh, .kl, .kr: return true
        default: return false
        }
    }
}
