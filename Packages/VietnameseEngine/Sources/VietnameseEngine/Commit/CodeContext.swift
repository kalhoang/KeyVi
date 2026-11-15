// SPDX-License-Identifier: MPL-2.0

/// Rule L9 follows the line, not the app (ENG-R850 as amended on 15/11/2026, REG-35): terminals and code editors
/// carry Vietnamese prose too (prompts to command-line assistants, commit messages, chat, comments), so in the
/// code context a code-only word is restored only outside Vietnamese text.
extension CommitPolicy {
    /// The number of previous tokens of the line that may show a Vietnamese word, as the window of ENG-R823.
    static let vietnameseTextWindow = 3

    /// ENG-R850: the token about to commit is in Vietnamese text, so rule L9 leaves it to the rules after it.
    ///
    /// Reads the line before the token, that is the history (section 10), which starts empty and is cleared by
    /// Return, Tab and a reset. The token is in Vietnamese text when a Vietnamese word stands among the previous
    /// three tokens of the line, the previous token is neither English (ENG-R823) nor a code-only word shown as
    /// typed, and the boundary characters between the previous token and this one hold a space and no code
    /// character. A token glued to the previous one with no space is a code join (`anh.tar.gz`, `minh@host`),
    /// never prose, where a word is not glued to the next one by `.`, `/` or `@`. The boundary key that ends
    /// the token is not read (P0-3), and neither is `lookaheadRevision` (ENG-R829): the history and the token
    /// languages exist without the collision rules.
    ///
    /// The walk visits at most three tokens' worth of entries (`History.entriesPerToken` each), reads stored
    /// facts only and allocates nothing (ENG-R1232, PLT-R304).
    package func isInVietnameseText(_ history: History) -> Bool {
        var tokens = 0
        var offset = 0
        var sawSpace = false
        let limit = Self.vietnameseTextWindow * History.entriesPerToken
        while offset < limit, let entry = history.entry(beforeNewest: offset) {
            offset += 1
            switch entry {
            case .boundary(let character):
                if tokens == 0 {
                    if Self.isCodeCharacter(character) { return false }
                    if Self.isSpace(character) { sawSpace = true }
                }
            case .token(let token):
                if tokens == 0, !sawSpace || token.language == .english || showsCodeWord(token) { return false }
                if token.language == .vietnamese || token.collision.vietnameseAsTyped { return true }
                tokens += 1
                if tokens == Self.vietnameseTextWindow { return false }
            }
        }
        return false
    }

    /// RV5 of ENG-R828: the decision the rules after L9 give the token, as in the general context (L9a to L11 with
    /// the token's own run, window and memory class), keeps its Vietnamese display. Evaluated once, at the commit
    /// of a token that L9 restored as the first thing typed on its line.
    package func keepsVietnameseAfterCodeRule(_ inputs: CommitInputs, context: CommitContext) -> Bool {
        var general = context
        general.inVietnameseText = true
        return !decide(inputs, context: general).restores
    }

    /// ENG-R850: the characters that mark code between two words, never Vietnamese prose: the backquote (a
    /// Markdown code span, shell command substitution), the vertical bar (a pipe), `&` (`&&`, a background job)
    /// and `$` (a variable). Quotes, brackets, `.`, `,`, `:`, `;` and the hyphen are prose punctuation when a
    /// space follows them.
    @inline(__always)
    static func isCodeCharacter(_ character: Character) -> Bool {
        switch character.asciiValue {
        case 0x60, 0x7C, 0x26, 0x24: return true
        default: return false
        }
    }

    /// ENG-R850 (c): the space and the no-break space, the characters that separate two words of prose.
    @inline(__always)
    static func isSpace(_ character: Character) -> Bool {
        character == " " || character == "\u{00A0}"
    }

    /// The token is a code-only word shown as its keys: typed unchanged or restored (`sudo`); a code-only word
    /// that composed Vietnamese (`chown` kept as `chơn` by L7) is a Vietnamese word on screen.
    private func showsCodeWord(_ token: CommittedToken) -> Bool {
        guard token.decision == .kept(.unchanged) || token.showsRawKeys else { return false }
        return resources.techCodeOnly.contains(token.collision.rawLowercased)
    }

    /// A Vietnamese syllable typed unchanged, the Vietnamese evidence of RV4 (ENG-R828) besides a Vietnamese-only
    /// letter: a Tier A syllable of at least two letters whose raw keys are not English and not all caps (`anh`,
    /// `chim`, `tay`).
    package func isVietnameseAsTyped(_ inputs: CommitInputs) -> Bool {
        let raw = inputs.raw
        return inputs.committed == raw && inputs.facts.validity == .standard && !isEnglish(inputs.rawLowercased)
            && raw.utf8.count >= 2 && raw.utf8.allSatisfy(ASCII.isLetter) && !RevisionEvidence.isAllCaps(raw)
    }
}
