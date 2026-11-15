// SPDX-License-Identifier: MPL-2.0

/// The token being committed, as the revision rules see it (ENG-R828).
package struct RevisionEvidence: Sendable {
    package let inputs: CommitInputs
    package let decision: CommitDecision
    /// The text the commit leaves on screen.
    package let text: String
    /// The number of the raw keys in the phrase list (0: in no phrase).
    package let phraseWord: UInt16
    /// The boundary key that commits the token (read only by RV5).
    package let boundary: Character

    package init(
        inputs: CommitInputs, decision: CommitDecision, text: String, phraseWord: UInt16, boundary: Character = " "
    ) {
        self.inputs = inputs
        self.decision = decision
        self.text = text
        self.phraseWord = phraseWord
        self.boundary = boundary
    }

    /// Decided by a rule that reads the token alone (not L9a to L11), so it is evidence of its own language.
    package var isFixed: Bool { decision.rule.map { !$0.isCollisionRule } ?? false }

    /// The committed text in lowercase (the tail-word lists are lowercase).
    var committedLowercased: String { decision.restores ? inputs.rawLowercased : inputs.facts.lowercased }

    /// More than one letter and every letter a capital (`OK`, `USB`): all caps is never evidence.
    var isAllCaps: Bool { Self.isAllCaps(inputs.raw) }

    package static func isAllCaps(_ text: String) -> Bool {
        var letters = 0
        for byte in text.utf8 {
            if ASCII.isLetter(byte) {
                if !ASCII.isUppercaseLetter(byte) { return false }
                letters += 1
            }
        }
        return letters > 0 && text.utf8.count > 1
    }

    /// The first character is a capital letter and the word is not all caps (`Tar`, not `tar` or `TAR`): the capital
    /// that starts a sentence, never a shell command, which is typed in lowercase (RV5 of ENG-R828).
    package static func isSentenceCapital(_ text: String) -> Bool {
        guard let first = text.utf8.first, ASCII.isUppercaseLetter(first) else { return false }
        return text.utf8.contains { ASCII.isLetter($0) && !ASCII.isUppercaseLetter($0) }
    }
}

extension CommitPolicy {
    /// RV1 to RV5 of ENG-R828, first match wins, for `previous` (the newest committed token, followed by
    /// exactly one space) when `next` commits. `beforePrevious` is the token before `previous` when exactly
    /// one space separates them; `chain` is the phrase chain whose nearest token is `previous`. RV1 to RV4 need
    /// `lookaheadRevision` and a token decided by L9c, L10 or L11; RV5 needs the code context's switch and a
    /// token restored by L9. The caller checks the other preconditions (auto restore, nothing between the two
    /// commits).
    package func revision(
        of previous: CommittedToken, beforePrevious: CommittedToken?, next: RevisionEvidence, chain: PhraseChain
    ) -> RevisionReason? {
        guard previous.collision.revision == nil, let rule = previous.decision.rule else { return nil }
        if rule == .codeContext { return lineStartRevision(of: previous, next: next) }
        guard collisionRules, rule.isRevisable else { return nil }
        let word = previous.collision.rawLowercased
        let lists = resources.collision
        if !previous.decision.restores {
            // RV1: the up to two tokens before `previous`, `previous` and `next` start a phrase.
            for older in 1...3 where lists.phrases.startsPhrase(chain.words(last: older, then: next.phraseWord)) {
                return .phrase
            }
            // RV3: an English function word follows a non-particle reading.
            if readingKind(word) != .particle, isStrictEnglish(next), !next.isAllCaps,
                next.inputs.rawLowercased != "it", lists.englishFunctionWords.contains(next.inputs.rawLowercased)
            {
                return .nextEnglish
            }
            return nil
        }
        guard rule == .englishRun || rule == .learned, resources.ambiguity[word] != .english,
            !resources.techAlways.contains(word)
        else { return nil }
        // RV2: a restored boundary particle followed by a Vietnamese tail particle.
        if lists.boundaryParticles.contains(word), next.isFixed, lists.tailParticles.contains(next.committedLowercased)
        {
            return .particleTail
        }
        // RV4: Vietnamese content follows a function word restored by the English run.
        guard isVietnameseEvidence(next), !lists.tailWords.contains(next.committedLowercased),
            lists.englishFunctionWords.contains(word) || readingKind(word) != .content,
            !isPreGuarded(beforePrevious)
        else { return nil }
        return .nextVietnamese
    }

    /// RV5 of ENG-R828 (ENG-R850 as amended on 16/11/2026, REG-36): at the start of a line nothing stands before a
    /// token, so rule L9 restored a code-only word there (`Tar`); when the next word shows the line is Vietnamese
    /// text, the word takes the display the rules after L9 give it, as in the general context (`Tả thử`). Guards:
    /// `previous` was restored by L9 as the first thing typed on its line (the history was empty) and the rules after
    /// L9 keep its Vietnamese display (`CollisionFacts.vietnameseAtLineStart`: never an `en` row, L10 or a learned
    /// English vote); `next` is kept by L7 with a Vietnamese-only letter (a syllable typed unchanged is a host, user
    /// or branch name as often: `host minh`); and `next` is committed by a space, Return, `,`, `!` or `?`. A capital
    /// that starts a sentence (`Tar`, never a shell command) widens the last two: `next` may be RV4's whole
    /// evidence (`Tee tay quá`) and its key may also be `.` (`Tả thử.`).
    func lineStartRevision(of previous: CommittedToken, next: RevisionEvidence) -> RevisionReason? {
        guard lineRevision, previous.decision == .restored(.codeContext), previous.collision.vietnameseAtLineStart
        else { return nil }
        // L9 restored the token, so the committed text is its raw keys, with their case.
        let sentence = RevisionEvidence.isSentenceCapital(previous.committedText)
        let evidence =
            sentence
            ? isVietnameseEvidence(next)
            : next.decision == .kept(.notEnglish) && next.inputs.facts.hasVietnameseOnlyLetter
        guard evidence, Self.confirmsVietnameseLine(next.boundary, afterSentenceCapital: sentence) else { return nil }
        return .lineVietnamese
    }

    /// RV5's boundary keys after the next word: a space, Return, `,`, `!` or `?`, and `.` after a sentence capital.
    /// Never `-`, `/`, `_` or another character of a file name or path (`tee nhật.log`, `tee nhật-ký.log`), `.`
    /// after a lowercase word, and never Tab, which completes a file name in a shell.
    package static func confirmsVietnameseLine(_ boundary: Character, afterSentenceCapital: Bool) -> Bool {
        switch boundary.asciiValue {
        case 0x20, 0x0A, 0x0D, 0x2C, 0x21, 0x3F: return true
        case 0x2E: return afterSentenceCapital
        default: return false
        }
    }

    /// The kind of the Vietnamese reading of an ambiguity row; `content` without a row (ENG-R827).
    func readingKind(_ rawLowercased: String) -> VietnameseReadingKind {
        resources.collision.readingKinds[rawLowercased] ?? .content
    }

    /// RV3's strict English evidence: a token fixed by its own keys (not L9a to L11) whose raw keys are English,
    /// typed unchanged or restored, whose display is not a valid Vietnamese syllable; never L4 or L8. (A token
    /// that L9b restores would be evidence too, but then RV1 has already revised the token before it.)
    package func isStrictEnglish(_ token: RevisionEvidence) -> Bool {
        guard token.isFixed, let rule = token.decision.rule, rule != .escape, rule != .notAttested else { return false }
        return isEnglish(token.inputs.rawLowercased) && token.text == token.inputs.raw
            && token.inputs.facts.validity != .standard
    }

    /// RV4's Vietnamese evidence: a Vietnamese-only letter kept by L7, or an unchanged Tier A syllable of at
    /// least two letters whose raw keys are not English and not all caps.
    package func isVietnameseEvidence(_ token: RevisionEvidence) -> Bool {
        let facts = token.inputs.facts
        switch token.decision {
        case .kept(.notEnglish):
            return facts.hasVietnameseOnlyLetter
        case .kept(.unchanged):
            return isVietnameseAsTyped(token.inputs)
        default:
            return false
        }
    }

    /// RV4's guard: the token before is on the pre-guard list and does not show a Vietnamese collision
    /// display (`the car rồi`, `you been ở`).
    func isPreGuarded(_ token: CommittedToken?) -> Bool {
        guard let token, resources.collision.preGuard.contains(token.collision.rawLowercased) else { return false }
        let showsVietnameseCollision = token.decision.rule?.isCollisionRule == true && !token.showsRawKeys
        return !showsVietnameseCollision
    }
}
