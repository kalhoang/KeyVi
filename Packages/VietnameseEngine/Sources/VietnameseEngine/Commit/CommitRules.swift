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
    /// The last key was an escape (`Composition.endsWithEscape`, rule L4).
    package let endsWithEscape: Bool
    /// An escape was not a doubling (`Composition.escapedAcrossKeys`, rule L4).
    package let escapedAcrossKeys: Bool
    /// The last key is a tone-removal key that removed the tone or the letter marks (`Composition.endsWithRemoval`,
    /// rule L4a, REG-39).
    package let endsWithRemoval: Bool
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
        endsWithEscape = token.composition.endsWithEscape
        escapedAcrossKeys = token.composition.escapedAcrossKeys
        endsWithRemoval = token.composition.endsWithRemoval
        camelCase = token.composition.isCamelCase
        userChoice = token.userChoice
        choiceSignalled = token.choiceSignalled
        revisionRestored = token.revisionRestored
    }
}

extension CommitDecision {
    /// The decision writes the raw keys (`R`) instead of the composed form (`C`). False for a typo correction, which
    /// writes a word of the lexicon (ENG-R1115).
    package var restores: Bool {
        if case .restored = self { return true }
        return false
    }

    /// The rule that decided, nil for a macro expansion; for a typo correction the rule of 8.1 that would have
    /// decided the token (ENG-R1115).
    package var rule: CommitRule? {
        switch self {
        case .kept(let rule), .restored(let rule), .corrected(let rule): return rule
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
    /// ENG-R850 (d): the token is the first word of its line (`CommitPolicy.isLineStart`), for rule L9's sentence
    /// condition (`CommitPolicy.startsSentence`) and RV5 of ENG-R828.
    package var atLineStart: Bool
    /// Rule L9c may read the learned memory (ENG-R863). Off only where rule L4 asks what the keys of an escaped form
    /// commit on their own: the memory decides collision words, never an escape (ENG-R877, REG-37).
    package var readsMemory = true

    package init(
        runIsEnglish: Bool, boundary: Character = " ", memoryContext: CollisionContext = .sentenceStart,
        phrases: PhraseChain = PhraseChain(), inVietnameseText: Bool = false, atLineStart: Bool = false
    ) {
        self.runIsEnglish = runIsEnglish
        self.boundary = boundary
        self.memoryContext = memoryContext
        self.phrases = phrases
        self.inVietnameseText = inVietnameseText
        self.atLineStart = atLineStart
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
/// | L4a the last key removed the tone or the marks (ENG-R411) | `toneRemoval` | `toneRemoval` (R English) |
/// | L5 invalid | - | `invalid` |
/// | L6 Tier B only | `extendedSpelling` | `extendedSpelling` |
/// | L7 `R` not English | `notEnglish` | - |
/// | L8 not attested | - | `notAttested` |
/// | L9 code context, outside Vietnamese text, not starting a sentence (ENG-R850; right after L5 when R is not English) | - | `codeContext` |
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
/// For a code-only word whose keys are not English, L9 is evaluated right after L5, before L6 and L7 (ENG-R801, ENG-R850
/// as decided by the product owner on 18/11/2026, REG-38), so it reaches `chown`, `ef` and `awk` as well as the English
/// `tar`, which reaches it in its place after L8. L9c also decides a collision word that L6, L7 or L8 would decide, when the memory votes for
/// the other side (ENG-R863): the memory reaches the collision supplement (`cos` -> `có` by L7) and the generated
/// rows that L8 restores. With `lookaheadRevision` off (ENG-R829) L9a, L9b and the `run: vi` exemption of L10
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

    /// The composition rules of the configuration: rule L4 composes the keys of an escaped form to learn whether
    /// the escape was needed (amended by the product owner on 17/11/2026, REG-37).
    let rules: ComposerRules

    package init(resources: Resources, configuration: EngineConfiguration) {
        self.resources = resources
        rules = ComposerRules(configuration)
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

    /// The first rule of 8.1 that matches, in exactly the order L0, L1, L2, L3, L3b, L4 ... L11, except that L9 comes
    /// right after L5 for a code-only word whose keys are not English (ENG-R801, ENG-R850). `includeUserChoice: false` evaluates "the rules alone" for the learning signal of
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
        if inputs.escapeUsed { return decideEscape(inputs, rawLowercased: r, context: context) }
        // L4a: the last key is a tone-removal key that removed the tone or the marks (ENG-R411). The user saw what it left
        // and committed it, so it is kept, syllable or not, unless the raw keys are English, as an escape keeps its form
        // (decided by the product owner on 18/11/2026, Q9 of section 15, REG-39): `dduwowngfzz` keeps `duong`, `quartz`
        // is restored. A removal that more letters follow belongs to a word typed through (`Amazon`): L5 onwards decide.
        if inputs.endsWithRemoval { return isEnglish(r) ? restore(.toneRemoval) : .kept(.toneRemoval) }
        // L5: the display is not a syllable.
        if inputs.facts.validity == .invalid { return restore(.invalid) }
        // L9 reads the line (ENG-R850): app context `code`, a code-only word outside Vietnamese text (amended on
        // 15/11/2026, REG-35) that does not start a sentence (amended by the product owner on 16/11/2026). In Vietnamese
        // text and at the start of a sentence the rules below decide as in the general context (`chinhs tar` gives
        // `chính tả`, `vieejt chown` gives `việt chơn`).
        let codeWord = appContext == .code && !context.inVietnameseText && resources.techCodeOnly.contains(r)
        let restoresCodeWord = codeWord && !startsSentence(inputs, context: context)
        // L9 for a code-only word whose keys are not English, evaluated right after L5, before L6 and L7 would keep it
        // (decided by the product owner on 18/11/2026, REG-38): it follows the line as `tar` does, so `sudo chown -R`
        // keeps `chown`, which L7 used to keep as `chơn` in every context.
        let english = isEnglish(r)
        if restoresCodeWord, !english { return restore(.codeContext) }
        // L6, unless the memory votes for the other side (L9c).
        if inputs.facts.validity == .extended {
            let decision = english ? restore(.extendedSpelling) : .kept(.extendedSpelling)
            return learnedOverride(of: decision, rawLowercased: r, context: context)
        }
        // L7: valid Tier A and R is not English (ENG-R316: no word list can restore it); the memory may
        // restore a word of the collision supplement (L9c).
        if !english { return learnedOverride(of: .kept(.notEnglish), rawLowercased: r, context: context) }
        // L8: the attested-syllable data may only break the tie for English raw keys.
        if !resources.attestedSyllables.contains(inputs.facts.lowercased) {
            return learnedOverride(of: restore(.notAttested), rawLowercased: r, context: context)
        }
        // L9 in its place for a code-only word whose keys are English (`tar`, `tee`, `host`).
        guard codeWord else { return decideAfterCodeRule(inputs, rawLowercased: r, context: context) }
        if restoresCodeWord { return restore(.codeContext) }
        // A word in sentence case that starts a line opens a new sentence, so the English run of the line before, which
        // survives Return (ENG-R823), does not reach it: `git status`, Return, `Tar` and a space give `Tả` (review of
        // 16/11/2026).
        var sentence = context
        sentence.runIsEnglish = false
        return decideAfterCodeRule(inputs, rawLowercased: r, context: sentence)
    }

    /// Rules L9a to L11, after rule L9 (ENG-R850).
    private func decideAfterCodeRule(_ inputs: CommitInputs, rawLowercased r: String, context: CommitContext)
        -> CommitDecision
    {
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
    func restore(_ rule: CommitRule) -> CommitDecision {
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
