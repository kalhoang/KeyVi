// SPDX-License-Identifier: MPL-2.0

/// The inputs of the decision at commit (8.1) for one token.
package struct CommitInputs: Sendable {
    /// `C`: the composed form after the 5.5 normalisation (`Composition.committedText(style:)`).
    package let committed: String
    /// `R`: the raw keys exactly as typed.
    package let raw: String
    /// `R` lowercased (ASCII only, ENG-R905): the key of every word-list lookup.
    package let rawLowercased: String
    package let facts: CommittedTextFacts
    package let escapeUsed: Bool
    package let camelCase: Bool
    package let userChoice: UserChoice
    /// The user's choice was already reported for these raw keys (ENG-R861, ENG-R864).
    package let choiceSignalled: Bool
    /// The side of the revision that last changed the re-opened token (ENG-R864), nil when none did or its
    /// raw keys were edited since.
    package let revisionRestored: Bool?

    package init(token: ActiveToken, style: ToneStyle) {
        // A literal token's commit form is its display (ENG-R532 does not apply to it), which the token
        // already holds: no render pass over a long literal tail (REG-02).
        let reusesDisplay = token.composition.isLiteral && !token.showsRawKeys
        committed = reusesDisplay ? token.display : token.composition.committedText(style: style)
        raw = token.rawText
        rawLowercased = ASCII.string(token.composition.raw, lowercasing: true)
        facts = CommittedTextFacts(committed)
        escapeUsed = token.composition.escapeUsed
        camelCase = token.composition.isCamelCase
        userChoice = token.userChoice
        choiceSignalled = token.choiceSignalled
        revisionRestored = token.revisionRestored
    }
}

extension CommitDecision {
    /// The decision writes the raw keys (`R`) instead of the composed form (`C`).
    package var restores: Bool {
        if case .restored = self { return true }
        return false
    }

    /// The rule that decided, nil for a macro expansion.
    package var rule: CommitRule? {
        switch self {
        case .kept(let rule), .restored(let rule): return rule
        case .macro: return nil
        }
    }
}

/// What the decision at commit reads besides the token itself (8.1).
package struct CommitContext: Sendable {
    /// ENG-R823: the run is in English (rule L10).
    package var runIsEnglish: Bool
    /// The key that ends the token (rule L9a).
    package var boundary: Character
    /// The class of the previous token (rule L9c, ENG-R863).
    package var memoryContext: CollisionContext
    /// The single-space chain of phrase words before the token (rule L9b, ENG-R826).
    package var phrases: PhraseChain
    /// ENG-R850: the token is in Vietnamese text, so rule L9 does not restore it (`CommitPolicy.isInVietnameseText`).
    package var inVietnameseText: Bool

    package init(
        runIsEnglish: Bool, boundary: Character = " ", memoryContext: CollisionContext = .sentenceStart,
        phrases: PhraseChain = PhraseChain(), inVietnameseText: Bool = false
    ) {
        self.runIsEnglish = runIsEnglish
        self.boundary = boundary
        self.memoryContext = memoryContext
        self.phrases = phrases
        self.inVietnameseText = inVietnameseText
    }
}

/// The restore policy of spec 8.1, evaluated for one token.
///
/// Mapping of the rules onto `CommitRule` (12.2, ENG-R801):
///
/// | Rule | Kept | Restored |
/// |---|---|---|
/// | L0 `C == R` | `unchanged` | - |
/// | L1 user toggle (7.2) | `userChoice` (user-kept) | `userChoice` (user-restored) |
/// | L2 user lists (8.7) | `userList` (keep-Vietnamese) | `userList` (keep-as-typed) |
/// | L3 no vowel letter | `abbreviation` | - |
/// | L3b camel case (ENG-R904) | - | `camelCase` |
/// | L4 escape used | `escape` | `escape` |
/// | L5 invalid | - | `invalid` |
/// | L6 Tier B only | `extendedSpelling` | `extendedSpelling` |
/// | L7 `R` not English | `notEnglish` | - |
/// | L8 not attested | - | `notAttested` |
/// | L9 code context, outside Vietnamese text (ENG-R850) | - | `codeContext` |
/// | L9a boundary particle (ENG-R825) | `boundaryParticle` | - |
/// | L9b phrase (ENG-R826) | - | `phrase` |
/// | L9c learned memory (ENG-R863) | `learned` | `learned` |
/// | L10 English run | - | `englishRun` |
/// | L11 ambiguity row | `ambiguityTable` (`vi`) | `ambiguityTable` (`en`) |
/// | L11 no row | `defaultVietnamese` | `techList` (tech-always word) |
///
/// ENG-R802: with auto restore off, a rule from L3b to L11 that would restore keeps the token and still
/// names itself (`kept(.invalid)` reads "would have been restored as invalid; auto restore is off").
///
/// L9c also decides a collision word that L6, L7 or L8 would decide, when the memory votes for the other
/// side (ENG-R863): the memory reaches the collision supplement (`cos` -> `có` by L7) and the generated rows
/// that L8 restores. With `lookaheadRevision` off (ENG-R829) L9a, L9b and the `run: vi` exemption of L10
/// never apply.
package struct CommitPolicy: Sendable {
    package let resources: Resources
    package let autoRestore: Bool
    package let appContext: AppContext
    /// ENG-R829: the context rules of the collision words are on.
    package let collisionRules: Bool
    /// RV5 of ENG-R828 is on: the code context with `lineStartRevision` (the user's D29, ENG-R850). It does not
    /// depend on `lookaheadRevision`, which the rules turn off in every code-context app (PLT-R357).
    package let lineRevision: Bool

    package init(resources: Resources, configuration: EngineConfiguration) {
        self.resources = resources
        autoRestore = configuration.autoRestore
        appContext = configuration.appContext
        collisionRules = configuration.lookaheadRevision
        lineRevision = configuration.appContext == .code && configuration.lineStartRevision
    }

    /// "R is English" (8.1): the lowercased word is in the English lexicon or the tech-always list.
    @inline(__always)
    package func isEnglish(_ lowercased: String) -> Bool {
        resources.english.contains(lowercased) || resources.techAlways.contains(lowercased)
    }

    /// The first rule of 8.1 that matches, in exactly the order L0, L1, L2, L3, L3b, L4 ... L11
    /// (ENG-R801). `includeUserChoice: false` evaluates "the rules alone" for the learning signal of
    /// ENG-R861 (L1 skipped).
    package func decide(_ inputs: CommitInputs, context: CommitContext, includeUserChoice: Bool = true)
        -> CommitDecision
    {
        let r = inputs.rawLowercased
        // L0: nothing was transformed.
        if inputs.committed == inputs.raw { return .kept(.unchanged) }
        // L1: the user's toggle (7.2).
        if includeUserChoice {
            switch inputs.userChoice {
            case .restored: return .restored(.userChoice)
            case .kept: return .kept(.userChoice)
            case .none: break
            }
        }
        // L2: the user lists (8.7); keep-as-typed is listed first and wins if a word is in both.
        if resources.userKeepRaw.contains(r) { return .restored(.userList) }
        if resources.userKeepVietnamese.contains(r) { return .kept(.userList) }
        // L3: abbreviations (`đc`, `ĐL`, `ĐHQG`). ENG-R801: L3 never keeps a token in which an escape was
        // used; L4 decides it, so `www` (displayed `ww`) commits as `www` (ENG-T12).
        if !inputs.facts.hasVowel, !inputs.escapeUsed { return .kept(.abbreviation) }
        return decideAutomatic(inputs, rawLowercased: r, context: context)
    }

    /// Rules L3b to L11, the ones that auto restore governs (ENG-R802).
    private func decideAutomatic(_ inputs: CommitInputs, rawLowercased r: String, context: CommitContext)
        -> CommitDecision
    {
        // L3b: camel case (ENG-R904).
        if inputs.camelCase { return restore(.camelCase) }
        // L4: an escape was used.
        if inputs.escapeUsed {
            if isEnglish(inputs.facts.lowercased) { return .kept(.escape) }
            return isEnglish(r) ? restore(.escape) : .kept(.escape)
        }
        switch inputs.facts.validity {
        case .invalid: return restore(.invalid)  // L5
        case .extended:  // L6, unless the memory votes for the other side (L9c)
            let decision = isEnglish(r) ? restore(.extendedSpelling) : .kept(.extendedSpelling)
            return learnedOverride(of: decision, rawLowercased: r, context: context)
        case .standard: break
        }
        // L7: valid Tier A and R is not English (ENG-R316: no word list can restore it); the memory may
        // restore a word of the collision supplement (L9c).
        if !isEnglish(r) { return learnedOverride(of: .kept(.notEnglish), rawLowercased: r, context: context) }
        // L8: the attested-syllable data may only break the tie for English raw keys.
        if !resources.attestedSyllables.contains(inputs.facts.lowercased) {
            return learnedOverride(of: restore(.notAttested), rawLowercased: r, context: context)
        }
        // L9: app context `code`, outside Vietnamese text (ENG-R850 as amended on 15/11/2026, REG-35). In Vietnamese
        // text the rules below decide as in the general context (`chinhs tar` gives `chính tả`).
        if appContext == .code, !context.inVietnameseText, resources.techCodeOnly.contains(r) {
            return restore(.codeContext)
        }
        if collisionRules {
            let phrase = continuesPhrase(r, chain: context.phrases)
            // L9a: a boundary particle before `.`, `!`, `?` or Return (ENG-R825), unless it continues a
            // phrase, which L9b decides (`such as.`).
            if !phrase, resources.collision.boundaryParticles.contains(r), Self.endsSentence(context.boundary) {
                return .kept(.boundaryParticle)
            }
            // L9b: the token continues a bundled phrase with the previous tokens (ENG-R826).
            if phrase { return restore(.phrase) }
        }
        // L9c: the learned memory (ENG-R863).
        if let vote = memoryVote(r, context: context) {
            return vote == .english ? restore(.learned) : .kept(.learned)
        }
        // L10: English run (ENG-R823), except the `run: vi` rows (ENG-R827).
        if context.runIsEnglish, !(collisionRules && resources.collision.runExempt.contains(r)) {
            return restore(.englishRun)
        }
        // L11: the ambiguity table, then the tech-always list.
        switch resources.ambiguity[r] {
        case .english: return restore(.ambiguityTable)
        case .vietnamese: return .kept(.ambiguityTable)
        case nil: return resources.techAlways.contains(r) ? restore(.techList) : .kept(.defaultVietnamese)
        }
    }

    /// ENG-R802: rules L3b to L11 restore only when auto restore is on.
    @inline(__always)
    private func restore(_ rule: CommitRule) -> CommitDecision {
        autoRestore ? .restored(rule) : .kept(rule)
    }

    /// ENG-R861: a learning signal when a token committed by the user's toggle differs from what the
    /// rules alone would have decided. The signal carries the lowercased raw keys, the key of the user
    /// lists (ENG-R860). One toggle gives one signal: a re-commit of a choice already reported for the
    /// same raw keys gives none.
    /// ENG-R864: for a re-opened token that a revision changed, the revision is what the user corrects, so
    /// its side stands for the rules' decision.
    package func learningSignal(_ inputs: CommitInputs, decision: CommitDecision, context: CommitContext)
        -> LearningSignal?
    {
        guard decision == .restored(.userChoice) || decision == .kept(.userChoice), !inputs.choiceSignalled
        else { return nil }
        let rulesAloneRestore =
            inputs.revisionRestored ?? decide(inputs, context: context, includeUserChoice: false).restores
        switch (decision.restores, rulesAloneRestore) {
        case (true, false): return .preferredRaw(raw: inputs.rawLowercased)
        case (false, true): return .preferredVietnamese(raw: inputs.rawLowercased)
        default: return nil
        }
    }
}
