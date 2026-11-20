// SPDX-License-Identifier: MPL-2.0

// When a transform applies (4.4). Each function returns true when the key was consumed (applied, or
// escaped by 4.7, which appends the key itself) and false when the key falls through to 4.3 step 3.
// ENG-R416: a transform is applied only if the letters stay viable; candidates are tried in place and
// reverted, so no copy of the letters is made (ENG-R1230).

extension Composition {
    /// ENG-R410. Applies when the vowel group is non-empty (the `u` of `qu` and the `i` of a `gi` onset do
    /// not count, which the parse of 3.13 already excludes). The same tone again escapes; another tone
    /// replaces it. Tones never fail because of the coda (3.11 is judged at commit) and do not affect
    /// viability (3.14 ignores tone).
    mutating func applyTone(_ newTone: Tone, key: UInt8, at index: Int) -> Bool {
        guard parse.hasVowelGroup else { return false }
        if tone == newTone {
            // ENG-R711: the escape undid every key that set or removed the tone.
            let undone = toneSources
            setTone(.level, byKey: nil)
            escape(.tone, key: key, at: index, undoing: undone)
        } else {
            setTone(newTone, byKey: index)
        }
        return true
    }

    /// ENG-R411, one layer per press (amended by the product owner on 15/11/2026, REG-34): with a tone the
    /// key removes the tone; otherwise, when a letter carries a vowel mark or the stroke, it removes all of
    /// them at once (`đ` becomes `d`); otherwise Telex `z` is a letter and VNI `0` a literal (this covers
    /// `qu` with no vowel, REG-01, and every vowel-less token, 7.3). Removing marks keeps the letters
    /// viable (the wildcard of ENG-R345), which the check below only confirms. A key that removed something is
    /// recorded as `newestRemoval`, which rule L4a reads at commit (`endsWithRemoval`, REG-39).
    mutating func removeToneOrMarks(at index: Int) -> Bool {
        if tone != .level {
            setTone(.level, byKey: index)
            newestRemoval = index
            return true
        }
        guard hasMarkedLetter else { return false }
        let saved = letters
        for offset in letters.indices where letters[offset].letter.modifier != .none {
            letters[offset].letter = letters[offset].letter.unmodified
        }
        guard isViable else {
            letters = saved
            return false
        }
        markRemovalSources.formUnion(KeySet(index: index))
        newestRemoval = index
        return true
    }

    /// ENG-R412, ENG-R431, ENG-R533. Targets: letters of the vowel group with the key's base (Telex) or
    /// base `a`, `e` or `o` (VNI `6`), rightmost first. A target that already has a circumflex escapes;
    /// otherwise it gets one (replacing a horn or breve, and removing the horn of the `u` before an `o`)
    /// if the result is viable, else the next target is tried.
    mutating func applyCircumflex(_ base: Letter?, key: UInt8, at index: Int) -> Bool {
        let parse = self.parse
        var offset = parse.codaStart - 1
        while offset >= parse.vowelStart {
            defer { offset -= 1 }
            let current = letters[offset].letter
            let currentBase = current.unmodified
            if let base {
                guard currentBase == base else { continue }
            } else {
                guard currentBase == .a || currentBase == .e || currentBase == .o else { continue }
            }
            if current.modifier == .circumflex {
                // ENG-R711: the escape undid every key that marked the target and, on the `o` of a `u o`
                // pair, the horn keys of the `u` whose horn the circumflex removed (ENG-R412, ENG-R533).
                var undone = letters[offset].modifierSources
                if currentBase == .o, offset > parse.vowelStart, letters[offset - 1].letter == .u {
                    undone.formUnion(letters[offset - 1].modifierSources)
                }
                letters[offset].letter = currentBase
                escape(.circumflex, key: key, at: index, undoing: undone)
                return true
            }
            if tryCircumflex(at: offset, parse: parse, key: index) { return true }
        }
        return false
    }

    private mutating func tryCircumflex(at offset: Int, parse: SyllableParse, key index: Int) -> Bool {
        let savedTarget = letters[offset]
        let hasPairedU = offset > parse.vowelStart && letters[offset - 1].letter.unmodified == .u
        let savedU = hasPairedU ? letters[offset - 1] : savedTarget
        guard let modified = savedTarget.letter.unmodified.applying(.circumflex) else { return false }
        letters[offset].modify(to: modified, byKey: index)
        // ENG-R412, ENG-R533: `ươ` + circumflex on the `o` gives `uô`.
        if modified == .oCircumflex, hasPairedU { letters[offset - 1].letter = .u }
        if isViable { return true }
        letters[offset] = savedTarget
        if hasPairedU { letters[offset - 1] = savedU }
        return false
    }

    /// ENG-R413 (Telex `w`) and ENG-R414 (VNI `7`, `8`), with ENG-R530 to ENG-R534.
    mutating func applyHornOrBreve(_ scope: HornBreveScope, standalone: Bool, key: UInt8, at index: Int) -> Bool {
        let parse = self.parse
        // (a) A `u o` pair inside the vowel group: both letters get a horn.
        if scope.horns, let pair = uoPair(parse), tryHornPair(at: pair, key: index) { return true }
        // (b) Single letters from right to left; a letter that already carries the modifier is skipped.
        var offset = parse.codaStart - 1
        while offset >= parse.vowelStart {
            defer { offset -= 1 }
            let current = letters[offset].letter
            guard let target = scope.target(forBase: current.unmodified), target != current else { continue }
            let saved = letters[offset]
            letters[offset].modify(to: target, byKey: index)
            if isViable { return true }
            letters[offset] = saved
        }
        // Escape: the effect is already present (ENG-R440, ENG-R534).
        if parse.vowelRange.contains(where: { scope.isEffect(letters[$0].letter.modifier) }) {
            let removed = removeHornBreveEffect(scope, parse: parse)
            if scope == .telexW {
                recordWDoubling(at: index, undone: removed.undone, standaloneSources: removed.standaloneSources)
            }
            escape(scope.kind, key: key, at: index, undoing: removed.undone)
            return true
        }
        // ENG-R103: `w` with no vowel yet is the vowel `ư` (its case follows the key, ENG-R903).
        if scope == .telexW, standalone, !parse.hasVowelGroup,
            appendProduced(.uHorn, uppercase: ASCII.isUppercaseLetter(key), flags: .standaloneW, at: index)
        {
            return true
        }
        return false
    }

    /// The first `u o` pair (bases `u` and `o`, any modifier) inside the vowel group.
    private func uoPair(_ parse: SyllableParse) -> Int? {
        var offset = parse.vowelStart
        while offset + 1 < parse.codaStart {
            if letters[offset].letter.unmodified == .u, letters[offset + 1].letter.unmodified == .o { return offset }
            offset += 1
        }
        return nil
    }

    private mutating func tryHornPair(at offset: Int, key index: Int) -> Bool {
        let first = letters[offset]
        let second = letters[offset + 1]
        // A set whose letters already carry exactly that modifier is skipped (ENG-R413). The test is on
        // the stored letters, so the explicit `uwow` spelling (ENG-T03) does not escape.
        guard first.letter != .uHorn || second.letter != .oHorn else { return false }
        letters[offset].modify(to: .uHorn, byKey: index)
        letters[offset + 1].modify(to: .oHorn, byKey: index)
        if isViable { return true }
        letters[offset] = first
        letters[offset + 1] = second
        return false
    }

    /// ENG-R413 escape: removes every horn and breve the key could have made in the vowel group (VNI `7`
    /// only horns, VNI `8` only breves) and, for Telex `w`, the `ư` letters a standalone `w` created.
    /// Returns the keys whose effect the escape undid (ENG-R711): the mark keys of every letter it
    /// unmarked and the keys of every `ư` it removed; and the keys of those `ư` letters (ENG-R804, REG-40).
    private mutating func removeHornBreveEffect(_ scope: HornBreveScope, parse: SyllableParse)
        -> (undone: KeySet, standaloneSources: KeySet)
    {
        var undone = KeySet()
        var standaloneSources = KeySet()
        var result: [ComposedLetter] = []
        result.reserveCapacity(letters.count)
        for (offset, var letter) in letters.enumerated() {
            let inVowelGroup = parse.vowelRange.contains(offset)
            if inVowelGroup, scope == .telexW, letter.flags.contains(.standaloneW), letter.letter == .uHorn {
                undone.formUnion(KeySet(index: Int(letter.source)))
                undone.formUnion(letter.modifierSources)
                standaloneSources.formUnion(KeySet(index: Int(letter.source)))
                continue
            }
            if inVowelGroup, scope.isEffect(letter.letter.modifier) {
                letter.letter = letter.letter.unmodified
                undone.formUnion(letter.modifierSources)
            }
            result.append(letter)
        }
        letters = result
        return (undone, standaloneSources)
    }

    /// ENG-R415. Applies when the first letter of the token is `d`: an unstroked `d` becomes `đ` if
    /// viable, a stroked one escapes.
    mutating func applyStroke(key: UInt8, at index: Int) -> Bool {
        guard let first = letters.first, first.letter.unmodified == .d else { return false }
        if first.letter == .dStroke {
            letters[0].letter = .d
            escape(.stroke, key: key, at: index, undoing: first.modifierSources)
            return true
        }
        letters[0].modify(to: .dStroke, byKey: index)
        if isViable { return true }
        letters[0] = first
        return false
    }

    /// ENG-R104 and 4.8: a bracket key appends `ơ` (`[`) or `ư` (`]`) if viable. Doubling escapes: when
    /// the letter cannot be appended and the token holds a letter made by the same key, those letters
    /// are removed and the key itself is appended (`[[` -> `[`). Otherwise the key is a literal. The key
    /// has no case: the letter is uppercase if Caps Lock was on for it (ENG-R906; the all-caps word case is
    /// decided at render time, because later letters change it).
    mutating func applyBracket(_ letter: Letter, key: UInt8, at index: Int) -> Bool {
        if appendProduced(letter, uppercase: nil, flags: .bracket, at: index) {
            if capsLockKeys.contains(index) { letters[letters.count - 1].isUppercase = true }
            return true
        }
        let madeBySameKey: (ComposedLetter) -> Bool = { $0.flags.contains(.bracket) && $0.letter == letter }
        guard letters.contains(where: madeBySameKey) else { return false }
        // ENG-R711: the escape undid the removed letters' keys and their mark keys, except a mark key that
        // still marks a letter that stays (`]ow]` shows `ơ]`: the `w` gave the `ơ` its horn).
        var stillShown = KeySet()
        for kept in letters where !madeBySameKey(kept) && kept.letter.modifier != .none {
            stillShown.formUnion(kept.modifierSources)
        }
        var undone = KeySet()
        for removed in letters where madeBySameKey(removed) {
            undone.formUnion(KeySet(index: Int(removed.source)))
            undone.formUnion(removed.modifierSources.subtracting(stillShown))
        }
        letters.removeAll(where: madeBySameKey)
        escape(.bracket, key: key, at: index, undoing: undone)
        return true
    }
}
