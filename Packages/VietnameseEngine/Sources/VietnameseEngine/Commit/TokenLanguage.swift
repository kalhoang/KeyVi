// SPDX-License-Identifier: MPL-2.0

/// The language of a committed token (ENG-R823).
package enum TokenLanguage: UInt8, Sendable, Hashable {
    /// Digits, `a`, `the`, `I`: no evidence either way.
    case neutral
    /// The committed text contains a Vietnamese-only letter (`ă â đ ê ô ơ ư` or a toned vowel).
    case vietnamese
    /// Restored (by the user or a rule), or an ASCII word of the English lexicon that is not a valid
    /// Vietnamese syllable.
    case english

    /// ENG-R823 for a token committed by the rules of 8.1.
    ///
    /// "Unchanged ASCII word" is read as "the committed text is ASCII": a token kept by L4 as its
    /// escaped form (`ass` -> `as`, `ddid` -> `did`) is an English word on screen just like an L0 token
    /// (docs/decisions/0103-engine-commit-history-macros.md).
    package static func of(committed facts: CommittedTextFacts, restored: Bool, resources: Resources) -> TokenLanguage {
        if restored { return .english }
        if facts.hasVietnameseOnlyLetter { return .vietnamese }
        if facts.isASCII, facts.validity == .invalid, resources.english.contains(facts.lowercased) { return .english }
        return .neutral
    }

    /// The language of a macro expansion: Vietnamese when it contains a Vietnamese-only letter,
    /// otherwise neutral. An expansion is neither restored nor typed, so it is never English evidence.
    package static func ofExpansion(_ expansion: String) -> TokenLanguage {
        for scalar in expansion.unicodeScalars where scalar.value >= 0x80 {
            if let glyph = LetterTable.glyph(for: scalar), glyph.tone != .level || glyph.letter.modifier != .none {
                return .vietnamese
            }
        }
        return .neutral
    }
}

/// The languages of the three most recent committed tokens of the run, newest first (ENG-R823).
///
/// A missing token and a neutral token are equivalent for the rule "the nearest non-neutral token among
/// the previous three", so the triple starts out neutral and needs no count. Committed tokens keep the
/// triple as it was before them (`CommittedToken.languagesBefore`), so re-opening a token by Backspace
/// or folding tokens into a macro expansion restores the window in O(1).
package struct RecentLanguages: Sendable, Hashable {
    private var newest = TokenLanguage.neutral
    private var middle = TokenLanguage.neutral
    private var oldest = TokenLanguage.neutral

    package init() {}

    /// Records the language of a newly committed token.
    package mutating func push(_ language: TokenLanguage) {
        oldest = middle
        middle = newest
        newest = language
    }

    /// ENG-R823: the run is in English when the nearest non-neutral token among the previous three
    /// committed tokens is English.
    package var isEnglishRun: Bool {
        if newest != .neutral { return newest == .english }
        if middle != .neutral { return middle == .english }
        return oldest == .english
    }
}
