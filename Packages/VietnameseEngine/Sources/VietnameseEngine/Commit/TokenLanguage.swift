// SPDX-License-Identifier: MPL-2.0

/// The language of a committed token (ENG-R823).
package enum TokenLanguage: UInt8, Sendable, Hashable {
    /// Digits, `a`, `the`, `I`, and a token kept Vietnamese by rule L11: no evidence either way.
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
    ///
    /// A token kept by rule L11 (its ambiguity row is `vi`, or it has no row and is kept by default) is
    /// neutral: its raw keys are an English word and its display an attested syllable, so it is evidence of
    /// neither language (product owner, 14/11/2026, REG-32). The user's own choices (L1, L2) are evidence.
    /// With auto restore off (ENG-R802) a token an `en` row would have restored is `kept(.ambiguityTable)`
    /// as well, so it is neutral too and the later tokens name the same rule as with auto restore on
    /// (`test and this` keeps `this` by `kept(.englishRun)`).
    ///
    /// The collision rules add three cases (ENG-R823 as amended on 15/11/2026, ENG-R825, ENG-R863): a token
    /// kept by L9a (boundary particle) or L9c (the memory's Vietnamese side), or kept by L9b because auto
    /// restore is off, is neutral like an L11 keep; and a token typed unchanged (L0) whose raw keys are on the
    /// English-lean list (`the`, `my`) is English when `collisionRules` is on.
    package static func of(
        committed facts: CommittedTextFacts, decision: CommitDecision, rawLowercased: String = "",
        resources: Resources, collisionRules: Bool = true
    ) -> TokenLanguage {
        switch decision {
        case .restored: return .english
        case .kept(.ambiguityTable), .kept(.defaultVietnamese), .kept(.boundaryParticle), .kept(.phrase),
            .kept(.learned):
            return .neutral
        case .kept(.unchanged):
            if collisionRules, resources.collision.englishLean.contains(rawLowercased) { return .english }
        case .kept, .macro: break
        }
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
/// A missing token and a neutral token are equivalent for the rule "an English token and no Vietnamese
/// token among the previous three", so the triple starts out neutral and needs no count. Committed tokens keep the
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

    /// Replaces the language of the newest token (`distance` 1) or of the one before it (2): a revision
    /// (ENG-R828) and its undo (ENG-R829) change a token that is already in the window.
    package mutating func replace(atDistance distance: Int, with language: TokenLanguage) {
        switch distance {
        case 1: newest = language
        case 2: middle = language
        default: oldest = language
        }
    }

    /// ENG-R823 (product owner, 14/11/2026, REG-32): the run is in English when the previous three
    /// committed tokens hold at least one English token and no Vietnamese token. One Vietnamese token
    /// means the writer is in Vietnamese and an English one is a loanword (`cũng tricky á`).
    package var isEnglishRun: Bool {
        guard newest != .vietnamese, middle != .vietnamese, oldest != .vietnamese else { return false }
        return newest == .english || middle == .english || oldest == .english
    }
}
