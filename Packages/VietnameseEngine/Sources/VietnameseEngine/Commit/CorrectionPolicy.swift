// SPDX-License-Identifier: MPL-2.0
//
// The constants of the typo correction of section 11A, and the ONE place for each of its two open choices, Q10 and
// Q11 of spec section 15 (open on 19/11/2026; the recommendations are built). Every text that follows a choice is
// checked against these constants instead of carrying the choice on its own: rows S23, S24 and S26 of 13.12
// (`TypoCorrectionExampleTests.theSpecRowsFollowThePolicy`), the D30 copy of PRD-R80 and the D30 row of
// spec/03-product.md (`scripts/tests/test_correction_policy.py`, which parses `sentenceStart` and `commitKeys` from
// this file with a regular expression: keep each on one line, `package static let <name>: <Type> = .<case>`).

/// The rules of section 11A that are plain values (ENG-R1110 to ENG-R1114).
package enum CorrectionPolicy {
    /// Q10: whether a word in sentence case is corrected where it starts a sentence (ENG-R1111).
    package enum SentenceStart: Sendable, Hashable {
        /// `Androdi` at a sentence start gives `Android`; inside a sentence a capital is a name and stays.
        case corrected
        /// No word with a capital letter is ever corrected.
        case neverCorrected
    }

    /// Q10, the recommendation of 18/11/2026: the first word of a sentence is a word as often as any other.
    package static let sentenceStart: SentenceStart = .corrected

    /// Q11: which committing keys may commit a correction (ENG-R1112, ENG-R1116).
    package enum CommitKeys: Sendable, Hashable {
        /// Whitespace, Return, Tab and the closers of prose, the rule of P0-3 (13.9.1).
        case everyCommitKey
        /// A space and the closers of prose only: the user sees the word before Return or Tab sends it.
        case spaceAndPunctuationOnly
    }

    /// Q11, the recommendation of 18/11/2026: every key that commits, as restore and the revisions do.
    package static let commitKeys: CommitKeys = .everyCommitKey

    /// ENG-R1111: a candidate has 5 to 24 letters; ENG-R1114: a word that fits has at least 4.
    package static let minimumLetters = 5, maximumLetters = 24, minimumFitLetters = 4

    /// ENG-R1112: the closers of prose that may commit a correction, all ASCII so that the undo of ENG-R1117 always
    /// applies; whitespace, Return and Tab commit one too, as `commitKeys` allows.
    package static let closers: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "\""]

    /// ENG-R1112: the characters that may stand right before a candidate's first letter (a space, a no-break space,
    /// an opening bracket or quote); at the start of a line only spaces and tabs may stand before it.
    package static let openers: Set<Character> = [" ", "\u{00A0}", "(", "[", "{", "\"", "\u{201C}", "\u{2018}", "'"]

    /// ENG-R1110 (b): the onset clusters of the Tier B place names whose token, kept by L6, is a candidate (`gramar`).
    package static let clusterOnsets: Set<String> = ["bl", "br", "dr", "đr", "gl", "gr", "kl", "kr", "pl", "pr"]
}
