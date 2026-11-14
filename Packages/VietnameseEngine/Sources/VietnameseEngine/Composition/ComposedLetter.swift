// SPDX-License-Identifier: MPL-2.0

/// A set of raw-key indices of a composing token, as a bit mask.
///
/// Composition handles at most `Composition.composingKeyLimit` (64) keys before the token goes literal
/// (ENG-R641), so every key that can create, modify or tone a letter has an index below 64 and fits.
/// The raw keys themselves stay in growable storage (ENG-R640); this mask is only the per-letter record
/// that Backspace needs (ENG-R710).
package struct KeySet: Sendable, Hashable {
    package private(set) var bits: UInt64 = 0

    package init() {}

    /// The set holding `index`. Swift's smart shift yields an empty set for an index of 64 or more,
    /// which cannot occur while composing.
    @inline(__always)
    package init(index: Int) { bits = UInt64(1) << UInt64(truncatingIfNeeded: index) }

    @inline(__always)
    package func contains(_ index: Int) -> Bool { index < 64 && bits & (UInt64(1) << UInt64(index)) != 0 }

    @inline(__always)
    package mutating func formUnion(_ other: KeySet) { bits |= other.bits }

    /// The set holds no key.
    package var isEmpty: Bool { bits == 0 }

    /// The keys of this set that are not in `other`.
    @inline(__always)
    package func subtracting(_ other: KeySet) -> KeySet {
        var result = KeySet()
        result.bits = bits & ~other.bits
        return result
    }

    /// The set holding only the highest index of this set (the newest key); empty if this set is.
    package var newest: KeySet {
        guard bits != 0 else { return KeySet() }
        return KeySet(index: 63 - bits.leadingZeroBitCount)
    }

    /// The keys in both sets.
    @inline(__always)
    package func intersection(_ other: KeySet) -> KeySet {
        var result = KeySet()
        result.bits = bits & other.bits
        return result
    }
}

/// One letter of a composing token: its identity, its case, and the keys that made it (6.1).
package struct ComposedLetter: Sendable, Hashable {
    package struct Flags: OptionSet, Sendable, Hashable {
        package let rawValue: UInt8
        package init(rawValue: UInt8) { self.rawValue = rawValue }

        /// Appended by an escape (4.7); Backspace removes only its key (ENG-R711).
        package static let escape = Flags(rawValue: 1 << 0)
        /// The `ư` of a standalone Telex `w` (ENG-R103); a `w` escape removes it (ENG-R413).
        package static let standaloneW = Flags(rawValue: 1 << 1)
        /// The `ơ` / `ư` of a bracket key (ENG-R104); bracket doubling removes it (4.8).
        package static let bracket = Flags(rawValue: 1 << 2)
    }

    /// Lowercase identity, modifier included (`ơ`, `đ`). Display normalisation (5.5) and the tone are
    /// applied at render time, never stored (ENG-R501).
    package var letter: Letter
    /// ENG-R901, ENG-R903: the case of the key that produced the letter.
    package var isUppercase: Bool
    package var flags: Flags
    /// Raw index of the key that produced the letter.
    package var source: UInt8
    /// Raw indices of every modifier or stroke key that targeted the letter (ENG-R710).
    package var modifierSources = KeySet()

    package init(_ letter: Letter, uppercase: Bool, flags: Flags = [], source: Int) {
        self.letter = letter
        self.isUppercase = uppercase
        self.flags = flags
        self.source = UInt8(truncatingIfNeeded: source)
    }

    /// Sets the letter's modifier (or stroke) on behalf of the key `index`.
    @inline(__always)
    package mutating func modify(to newLetter: Letter, byKey index: Int) {
        letter = newLetter
        modifierSources.formUnion(KeySet(index: index))
    }
}

/// ENG-R904 bookkeeping: a lowercase letter, later an uppercase letter, later another lowercase letter.
///
/// Only keys whose case shows in the output count: keys appended as letters (including escape
/// letters and the standalone `ư`) and ASCII letters appended in literal mode. Transform keys whose
/// case is ignored (ENG-R902) do not count, so `dDaf` -> `đà` (W205) is not camel case while
/// `useState` is. The tracker stores the raw index of each of the three transitions, so dropping the
/// last key of a literal token restores the previous stage exactly (replay equivalence, ENG-R601).
package struct CamelCaseTracker: Sendable, Hashable {
    private var lowercaseAt: Int32 = -1
    private var uppercaseAt: Int32 = -1
    private var camelAt: Int32 = -1

    package init() {}

    /// Whether a visible letter of this case would complete the pattern.
    @inline(__always)
    package func completes(uppercase: Bool) -> Bool { !uppercase && uppercaseAt >= 0 && camelAt < 0 }

    /// The raw keys contain the camel-case pattern (rule L3b of 8.1 uses this).
    package var isCamelCase: Bool { camelAt >= 0 }

    /// Records a visible letter typed by key `index`.
    @inline(__always)
    package mutating func observe(uppercase: Bool, at index: Int) {
        let position = Int32(truncatingIfNeeded: index)
        if uppercase {
            if lowercaseAt >= 0, uppercaseAt < 0 { uppercaseAt = position }
        } else if lowercaseAt < 0 {
            lowercaseAt = position
        } else if uppercaseAt >= 0, camelAt < 0 {
            camelAt = position
        }
    }

    /// Records a key appended in literal mode; only ASCII letters count.
    @inline(__always)
    package mutating func observeLiteral(_ key: UInt8, at index: Int) {
        guard ASCII.isLetter(key) else { return }
        observe(uppercase: ASCII.isUppercaseLetter(key), at: index)
    }

    /// Undoes every transition made by the key `index` (the last key of the token).
    package mutating func forget(_ index: Int) {
        let position = Int32(truncatingIfNeeded: index)
        if camelAt == position { camelAt = -1 }
        if uppercaseAt == position { uppercaseAt = -1 }
        if lowercaseAt == position { lowercaseAt = -1 }
    }
}

/// The letters of a composition as engine letters, for the generic orthography functions.
package struct LetterView: RandomAccessCollection, Sendable {
    package let storage: [ComposedLetter]

    @inline(__always)
    package init(_ storage: [ComposedLetter]) { self.storage = storage }

    package var startIndex: Int { 0 }
    package var endIndex: Int { storage.count }

    @inline(__always)
    package subscript(position: Int) -> Letter { storage[position].letter }
}

/// The display letters of a composition (5.5, ENG-R530): horns completed on a `u o` pair.
package struct DisplayLetterView: RandomAccessCollection, Sendable {
    package let letters: LetterView
    package let parse: SyllableParse

    @inline(__always)
    package init(_ letters: LetterView, parse: SyllableParse) {
        self.letters = letters
        self.parse = parse
    }

    package var startIndex: Int { 0 }
    package var endIndex: Int { letters.endIndex }

    @inline(__always)
    package subscript(position: Int) -> Letter {
        HornNormalisation.displayLetter(at: position, in: letters, parse: parse)
    }
}
