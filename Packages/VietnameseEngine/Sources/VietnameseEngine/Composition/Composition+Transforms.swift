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
            setTone(.level, byKey: nil)
            escape(.tone, key: key, at: index)
        } else {
            setTone(newTone, byKey: index)
        }
        return true
    }

    /// ENG-R411. Applies when the token has a tone; otherwise Telex `z` is a letter and VNI `0` a literal
    /// (this covers `qu` with no vowel, REG-01, and every vowel-less token, 7.3).
    mutating func removeTone(at index: Int) -> Bool {
        guard tone != .level else { return false }
        setTone(.level, byKey: index)
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
                letters[offset].letter = currentBase
                escape(.circumflex, key: key, at: index)
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
            removeHornBreveEffect(scope, parse: parse)
            escape(scope.kind, key: key, at: index)
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
    private mutating func removeHornBreveEffect(_ scope: HornBreveScope, parse: SyllableParse) {
        var result: [ComposedLetter] = []
        result.reserveCapacity(letters.count)
        for (offset, var letter) in letters.enumerated() {
            let inVowelGroup = parse.vowelRange.contains(offset)
            if inVowelGroup, scope == .telexW, letter.flags.contains(.standaloneW), letter.letter == .uHorn {
                continue
            }
            if inVowelGroup, scope.isEffect(letter.letter.modifier) { letter.letter = letter.letter.unmodified }
            result.append(letter)
        }
        letters = result
    }

    /// ENG-R415. Applies when the first letter of the token is `d`: an unstroked `d` becomes `đ` if
    /// viable, a stroked one escapes.
    mutating func applyStroke(key: UInt8, at index: Int) -> Bool {
        guard let first = letters.first, first.letter.unmodified == .d else { return false }
        if first.letter == .dStroke {
            letters[0].letter = .d
            escape(.stroke, key: key, at: index)
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
        letters.removeAll(where: madeBySameKey)
        escape(.bracket, key: key, at: index)
        return true
    }
}
