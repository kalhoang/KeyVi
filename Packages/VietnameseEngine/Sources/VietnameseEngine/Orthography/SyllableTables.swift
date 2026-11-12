// SPDX-License-Identifier: MPL-2.0

/// One onset-rhyme pair of the inventory.
package struct SyllablePair: Sendable, Hashable {
    package let onset: Onset
    package let rhyme: Rhyme
    /// The lowest tier of the pair (`.standard` or `.extended`).
    package let tier: Validity

    /// The lowercase letters of the pair (onset then rhyme).
    package var letters: [Letter] { onset.letters + rhyme.letters }
    package var spelling: String { onset.spelling + rhyme.spelling }
    /// The tones the pair accepts (3.11): sắc and nặng after `c ch p t`, otherwise all six.
    package var tones: [Tone] { Tone.allTones.filter { rhyme.accepts($0) } }
}

/// Tables generated at first use from `RhymeInventory` and `SyllableRules`: every rhyme spelling,
/// the tier of every onset-rhyme pair, and the pair lists used for counts, the viability automaton
/// and the test oracle. Immutable once built (ENG-R1202).
package enum SyllableTables {
    /// Every rhyme spelling that some tier allows after some onset, in inventory order: 3.7, the
    /// extra `qu` rhymes of 3.8, the `gi` rhymes of ENG-R305, the Tier B extra rhymes of 3.12, then
    /// the Tier B `k` variants of the `c` rhymes.
    package static let rhymes: [Rhyme] = {
        var spellings: [String] = []
        var seen = Set<String>()
        func add(_ list: [String]) {
            for spelling in list where seen.insert(spelling).inserted { spellings.append(spelling) }
        }
        add(RhymeInventory.standard)
        add(RhymeInventory.afterQu)
        add(RhymeInventory.afterQuExtended)
        add(RhymeInventory.afterGiExtra)
        add(RhymeInventory.extendedExtra)
        add(
            (RhymeInventory.standard + RhymeInventory.extendedExtra).filter { $0.hasSuffix("c") }.map {
                String($0.dropLast()) + "k"
            })
        return spellings.enumerated().map { Rhyme(id: $0.offset, spelling: $0.element) }
    }()

    private static let rhymeIDByKey: [UInt32: Int] = {
        var table: [UInt32: Int] = [:]
        for rhyme in rhymes {
            guard let key = RhymeKey.make(rhyme.letters) else { preconditionFailure("rhyme longer than four letters") }
            table[key] = rhyme.id
        }
        return table
    }()

    /// The rhyme spelled by `letters`, if it is in the inventory.
    @inline(__always)
    package static func rhyme<C: Collection>(spelledBy letters: C) -> Rhyme? where C.Element == Letter {
        guard let key = RhymeKey.make(letters), let id = rhymeIDByKey[key] else { return nil }
        return rhymes[id]
    }

    /// Tier of every (onset, rhyme) pair, indexed by `onset.rawValue * rhymes.count + rhyme.id`.
    private static let pairTiers: [Validity] = {
        var table = [Validity](repeating: .invalid, count: Onset.allCases.count * rhymes.count)
        for onset in Onset.allCases {
            for rhyme in rhymes {
                let tier: Validity
                if SyllableRules.allows(onset, rhyme, extended: false) {
                    tier = .standard
                } else if SyllableRules.allows(onset, rhyme, extended: true) {
                    tier = .extended
                } else {
                    continue
                }
                // 3.13 is normative: a pair counts only if its spelling parses back into the same onset
                // and rhyme. This drops `g` + `iu`, whose spelling `giu` is the pair `gi` + `u`
                // (ENG-R305/R306; see docs/decisions/0100-engine-syllable-counts.md).
                let letters = onset.letters + rhyme.letters
                let parse = SyllableParser.parse(letters)
                guard parse.onset == onset, parse.vowelStart == onset.letters.count, !parse.hasRemainder else {
                    continue
                }
                table[Int(onset.rawValue) * rhymes.count + rhyme.id] = tier
            }
        }
        return table
    }()

    /// The tier of a pair ignoring tone: `.standard`, `.extended` or `.invalid`.
    @inline(__always)
    package static func tier(_ onset: Onset, _ rhyme: Rhyme) -> Validity {
        pairTiers[Int(onset.rawValue) * rhymes.count + rhyme.id]
    }

    /// Validity of a toned syllable (3.13 step 5): the pair's tier if the rhyme accepts the tone
    /// (ENG-R320, ENG-R321), otherwise invalid.
    @inline(__always)
    package static func validity(_ onset: Onset, _ rhyme: Rhyme, tone: Tone) -> Validity {
        let tier = tier(onset, rhyme)
        guard tier != .invalid, rhyme.accepts(tone) else { return .invalid }
        return tier
    }

    /// Validity of lowercase letters with a tone (3.13): parse, look the pair up, check the tone.
    package static func validity<C: RandomAccessCollection>(of letters: C, tone: Tone) -> Validity
    where C.Element == Letter {
        let parse = SyllableParser.parse(letters)
        return validity(of: letters, parse: parse, tone: tone)
    }

    /// Validity of letters whose parse is already known.
    package static func validity<C: RandomAccessCollection>(of letters: C, parse: SyllableParse, tone: Tone) -> Validity
    where C.Element == Letter {
        guard parse.isWellFormed else { return .invalid }
        let start = letters.index(letters.startIndex, offsetBy: parse.vowelStart)
        let end = letters.index(letters.startIndex, offsetBy: parse.remainderStart)
        guard let rhyme = rhyme(spelledBy: letters[start..<end]) else { return .invalid }
        return validity(parse.onset, rhyme, tone: tone)
    }

    /// All Tier A pairs, in onset order then inventory order.
    package static let standardPairs: [SyllablePair] = pairs { $0 == .standard }

    /// All Tier B pairs, Tier A included, in onset order then inventory order.
    package static let extendedPairs: [SyllablePair] = pairs { $0 != .invalid }

    private static func pairs(where include: (Validity) -> Bool) -> [SyllablePair] {
        var result: [SyllablePair] = []
        for onset in Onset.allCases {
            for rhyme in rhymes {
                let tier = tier(onset, rhyme)
                if tier != .invalid, include(tier) {
                    result.append(SyllablePair(onset: onset, rhyme: rhyme, tier: tier))
                }
            }
        }
        return result
    }
}
