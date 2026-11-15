// SPDX-License-Identifier: MPL-2.0

extension CommitRule {
    /// The rule decides a word that is both English and Vietnamese from its context (L9a, L9b, L9c, L10,
    /// L11): the token "has a side" (ENG-R825 to ENG-R828). Every other rule is fixed by the token alone.
    package var isCollisionRule: Bool {
        switch self {
        case .boundaryParticle, .phrase, .learned, .englishRun, .ambiguityTable, .techList, .defaultVietnamese:
            return true
        default:
            return false
        }
    }

    /// A token decided by this rule may be revised by the next commit (ENG-R828: L9c, L10 and L11).
    package var isRevisable: Bool {
        switch self {
        case .learned, .englishRun, .ambiguityTable, .techList, .defaultVietnamese: return true
        default: return false
        }
    }

    /// A collision word decided by this rule becomes a weak signal when it stays untouched (ENG-R864: L6 to
    /// L8 for the memory's reach, L9c, L10 and L11; never L9a or L9b).
    package var givesWeakSignal: Bool {
        switch self {
        case .extendedSpelling, .notEnglish, .notAttested, .learned, .englishRun, .ambiguityTable, .techList,
            .defaultVietnamese:
            return true
        default:
            return false
        }
    }
}

extension CommitPolicy {
    /// L9a's boundary keys: `.`, `!`, `?` and Return (an ellipsis is three `.` keys and the first one
    /// commits the token, ENG-R825).
    package static func endsSentence(_ boundary: Character) -> Bool {
        switch boundary.asciiValue {
        case 0x2E, 0x21, 0x3F, 0x0A, 0x0D: return true
        default: return false
        }
    }

    /// The raw keys are on the bundled collision list: an ambiguity row or the collision supplement
    /// (ENG-R862, ENG-R863).
    package func isCollisionWord(_ rawLowercased: String) -> Bool {
        resources.ambiguity[rawLowercased] != nil || resources.collision.supplement.contains(rawLowercased)
    }

    /// The string of the bundled list equal to `rawLowercased` (ENG-R866: a signal carries the list's word,
    /// never other text), nil when the word is not on the collision list.
    package func listWord(_ rawLowercased: String) -> String? {
        if let index = resources.ambiguity.index(forKey: rawLowercased) { return resources.ambiguity[index].key }
        return resources.collision.supplement.member(rawLowercased)
    }

    /// L9b (ENG-R826): for some p in 1...3, the previous p tokens of the chain and this token are the first
    /// p + 1 words of a bundled phrase.
    func continuesPhrase(_ rawLowercased: String, chain: PhraseChain) -> Bool {
        let phrases = resources.collision.phrases
        let number = phrases.number(of: rawLowercased)
        guard number != 0 else { return false }
        for older in 1...3 where phrases.startsPhrase(chain.words(last: older, then: number)) { return true }
        return false
    }

    /// L9c (ENG-R863): the memory's vote for a collision word in the current context, nil when the rules
    /// decide.
    func memoryVote(_ rawLowercased: String, context: CommitContext) -> Language? {
        guard !resources.collisionMemory.isEmpty, isCollisionWord(rawLowercased) else { return nil }
        return resources.collisionMemory.vote(word: rawLowercased, context: context.memoryContext)
    }

    /// L6, L7 or L8 decided `decision`; the memory replaces it only when it votes for the other side, so a
    /// vote that agrees leaves the rule (and the token's language) as it was.
    func learnedOverride(of decision: CommitDecision, rawLowercased: String, context: CommitContext)
        -> CommitDecision
    {
        guard let vote = memoryVote(rawLowercased, context: context) else { return decision }
        let restores = vote == .english
        guard restores != decision.restores else { return decision }
        return restores ? (autoRestore ? .restored(.learned) : .kept(.learned)) : .kept(.learned)
    }
}
