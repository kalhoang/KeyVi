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
    }
}

extension CommitDecision {
    /// The decision writes the raw keys (`R`) instead of the composed form (`C`).
    package var restores: Bool {
        if case .restored = self { return true }
        return false
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
/// | L9 code context | - | `codeContext` |
/// | L10 English run | - | `englishRun` |
/// | L11 ambiguity row | `ambiguityTable` (`vi`) | `ambiguityTable` (`en`) |
/// | L11 no row | `defaultVietnamese` | `techList` (tech-always word) |
///
/// ENG-R802: with auto restore off, a rule from L3b to L11 that would restore keeps the token and still
/// names itself (`kept(.invalid)` reads "would have been restored as invalid; auto restore is off").
package struct CommitPolicy: Sendable {
    package let resources: Resources
    package let autoRestore: Bool
    package let appContext: AppContext

    package init(resources: Resources, configuration: EngineConfiguration) {
        self.resources = resources
        autoRestore = configuration.autoRestore
        appContext = configuration.appContext
    }

    /// "R is English" (8.1): the lowercased word is in the English lexicon or the tech-always list.
    @inline(__always)
    package func isEnglish(_ lowercased: String) -> Bool {
        resources.english.contains(lowercased) || resources.techAlways.contains(lowercased)
    }

    /// The first rule of 8.1 that matches, in exactly the order L0, L1, L2, L3, L3b, L4 ... L11
    /// (ENG-R801). `includeUserChoice: false` evaluates "the rules alone" for the learning signal of
    /// ENG-R861 (L1 skipped).
    package func decide(_ inputs: CommitInputs, runIsEnglish: Bool, includeUserChoice: Bool = true) -> CommitDecision {
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
        // L3: abbreviations (`đc`, `ĐL`, `ĐHQG`). Reading: L3 does not apply to a token in which an
        // escape was used, so L4 decides it; otherwise `www` would commit as `ww`, which ENG-T12
        // forbids (docs/decisions/0103-engine-commit-history-macros.md).
        if !inputs.facts.hasVowel, !inputs.escapeUsed { return .kept(.abbreviation) }
        return decideAutomatic(inputs, rawLowercased: r, runIsEnglish: runIsEnglish)
    }

    /// Rules L3b to L11, the ones that auto restore governs (ENG-R802).
    private func decideAutomatic(_ inputs: CommitInputs, rawLowercased r: String, runIsEnglish: Bool) -> CommitDecision
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
        case .extended: return isEnglish(r) ? restore(.extendedSpelling) : .kept(.extendedSpelling)  // L6
        case .standard: break
        }
        // L7: valid Tier A and R is not English (ENG-R316: no word list can restore it).
        if !isEnglish(r) { return .kept(.notEnglish) }
        // L8: the attested-syllable data may only break the tie for English raw keys.
        if !resources.attestedSyllables.contains(inputs.facts.lowercased) { return restore(.notAttested) }
        // L9: app context `code` (ENG-R850).
        if appContext == .code, resources.techCodeOnly.contains(r) { return restore(.codeContext) }
        // L10: English run (ENG-R823).
        if runIsEnglish { return restore(.englishRun) }
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
    /// lists (ENG-R860).
    package func learningSignal(_ inputs: CommitInputs, decision: CommitDecision, runIsEnglish: Bool) -> LearningSignal?
    {
        guard decision == .restored(.userChoice) || decision == .kept(.userChoice) else { return nil }
        let rulesAlone = decide(inputs, runIsEnglish: runIsEnglish, includeUserChoice: false)
        switch (decision.restores, rulesAlone.restores) {
        case (true, false): return .preferredRaw(raw: inputs.rawLowercased)
        case (false, true): return .preferredVietnamese(raw: inputs.rawLowercased)
        default: return nil
        }
    }
}
