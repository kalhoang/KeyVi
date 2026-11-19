// SPDX-License-Identifier: MPL-2.0

public import VietnameseEngine

/// The Vietnamese keyings of spec ENG-R1125 computed from the oracle's side (ENG-T56), independently of
/// `lexicon-builder`'s generator: the usual-order Telex keys of a Tier A syllable with a tone it allows, written with
/// the oracle's key sequences (`KeySequenceGenerator`, ENG-T02 and ENG-T03) and two helpers written here.
///
/// - O1 and O2 of ENG-T02: the letters in order with each mark key right after its letter (`ươ` as `uow`), the tone
///   key last (O1) or right after the vowel group, that is right before the coda (O2);
/// - the `uwow` spelling of `ươ`: O1 from ENG-T03's `explicitUwow` variant, and its O2 form (helper);
/// - the standalone `w` for a leading `ư` after a consonant other than `q` (helper): `thw`, `twngf`, `thwowng`.
///
/// ENG-T02 types the literal `oo` of a loan rhyme (`boong`) with the escape `ooo`; ENG-R1125 writes the keys letter by
/// letter, so the oracle types such a rhyme as its two letters, which are the keys of `ô` (`boong` as `bông`).
public enum KeyingOracle {
    private static let toneKeys: [Tone: String] = [
        .level: "", .acute: "s", .grave: "f", .hook: "r", .tilde: "x", .dot: "j",
    ]
    private static let codaLetters: Set<Character> = ["c", "h", "m", "n", "g", "p", "t"]

    /// Every keying of `onset` + `rhyme` (lowercase spellings as in spec 3.3 and 3.7 to 3.9) with `tone`.
    public static func keyings(onset: String, rhyme: String, tone: Tone) -> Set<String> {
        // The literal `oo` of `ooc` and `oong` typed letter by letter is the keying of `ô` (see above).
        let rhyme = rhyme.hasPrefix("oo") ? "ô" + rhyme.dropFirst(2) : rhyme
        guard let o1 = KeySequenceGenerator.keys(onset: onset, rhyme: rhyme, tone: tone, method: .telex, order: .o1),
            let o2 = KeySequenceGenerator.keys(onset: onset, rhyme: rhyme, tone: tone, method: .telex, order: .o2)
        else { return [] }
        var forms: Set<String> = [o1, o2]
        if let uwow = KeySequenceGenerator.variantKeys(onset: onset, rhyme: rhyme, tone: tone, variant: .explicitUwow) {
            forms.insert(uwow)
            forms.insert(toneBeforeCoda(uwow, rhyme: rhyme, tone: tone))
        }
        if rhyme.first == "ư", !onset.isEmpty, onset != "qu" {
            let onsetKeyCount = onset.count + (onset.contains("đ") ? 1 : 0)
            for form in [o1, o2] { forms.insert(standaloneW(form, onsetKeyCount: onsetKeyCount)) }
        }
        return forms
    }

    /// An O1 keying (tone key last) with the tone key moved right before the coda letters.
    static func toneBeforeCoda(_ o1: String, rhyme: String, tone: Tone) -> String {
        let key = toneKeys[tone] ?? ""
        let coda = rhyme.reversed().prefix(while: { codaLetters.contains($0) }).count
        guard !key.isEmpty, coda > 0, o1.hasSuffix(key) else { return o1 }
        let withoutTone = o1.dropLast(key.count)
        return String(withoutTone.dropLast(coda)) + key + String(withoutTone.suffix(coda))
    }

    /// The keys of a leading `ư` written as `u` then its horn (`uw`, or `u` alone when the horn of `ươ` comes after the
    /// `o`) replaced by the standalone `w`.
    static func standaloneW(_ keys: String, onsetKeyCount: Int) -> String {
        let onset = keys.prefix(onsetKeyCount)
        var rest = keys.dropFirst(onsetKeyCount)
        guard rest.first == "u" else { return keys }
        rest = rest.dropFirst()
        if rest.first == "w" { rest = rest.dropFirst() }
        return onset + "w" + rest
    }
}
