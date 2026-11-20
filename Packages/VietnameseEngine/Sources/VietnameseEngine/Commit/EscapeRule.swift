// SPDX-License-Identifier: MPL-2.0

/// Rule L4 of 8.1, an escape was used in the token, as amended by the product owner on 17/11/2026
/// (docs/decisions/0005-pa-decisions-2026-11-13.md, REG-37). `C` is the display with the escape, `R` the raw keys. A
/// deliberate escape is a doubling (4.7): the escape key comes right after the key whose effect it removes (`off`,
/// `boooong`, `Karr`); an escape key that comes back after other keys belongs to a word typed through (`costs`,
/// `leecher`, `pajama`).
///
/// | `C` English | `R` English | Result |
/// |---|---|---|
/// | yes | yes | keep when the escape was a doubling that was needed (the keys of `C` alone commit something else) and the context is not English (ENG-R823, ENG-R826); otherwise restore |
/// | yes | no | keep (`tarr` -> `tar`, `ddid` -> `did`) |
/// | no | yes | restore (`password`, `traffic`, `www` of ENG-T12) |
/// | no | no | keep when the escape was a doubling and `C` has one vowel group at most or ends with the escape (`nhâmf`, `booong`, `Ana`); otherwise restore (`leecher`) |
///
/// A `w` doubled out of habit (amended by the product owner on 20/11/2026, docs/decisions/0010-pa-decisions-2026-11-19.md
/// item 7, REG-40): `R′` is `R` without the key of each w doubling (`Composition.wDoublings`). When `R′` differs from
/// `R`, the rows above still decide while `R` or `C` is English; otherwise (c′) `R′` English restores `R′` (`answwer`
/// shows `ánwer` and restores `answer`), before the deliberate form, and the restore of the last row puts back `R′` when
/// the w doublings are a habit, each one removed the `ư` of a standalone `w`, no `w` key follows it and none is a capital
/// right after a lowercase `w` (`wwebview` restores `webview`, `wwwexample` restores `wwwexample`), else `R`
/// (`dowwnload`): English writes `ww` only after a vowel, where a `w` is a horn or breve doubling. Rule L3b restores
/// camel case keys with the habit the same way (`habitDoublingsLeftOut`, ENG-R904; `dwWidth` is no habit and keeps
/// `R`), and a re-opened token that shows `R′` is restored to `R′` by any rule (`CommitPolicy.restoredKeys`,
/// ENG-R1005).
///
/// Every outcome keeps the reason code `escape` (ENG-R801).
extension CommitPolicy {
    func decideEscape(_ inputs: CommitInputs, rawLowercased: String, context: CommitContext) -> CommitDecision {
        switch (isEnglish(inputs.facts.lowercased), isEnglish(rawLowercased)) {
        case (true, true):
            // The product owner's choice "by context": in English the word typed (`and off`, and `turn off the light`,
            // where `turn` is kept as `tủn` but continues the phrase `turn off`); alone or among Vietnamese words the
            // doubling is the deliberate escape to the English collision word (`off` -> `of`, `tắt of đi`), unless
            // the escape was not needed at all (`tôi pass môn`, `dessert`) or was no doubling (`costs`).
            let deliberate =
                !inputs.escapedAcrossKeys && !isEnglishContext(rawLowercased, context: context)
                && escapeWasNeeded(inputs, context: context)
            return deliberate ? .kept(.escape) : restore(.escape)
        case (true, false):
            return .kept(.escape)
        case (false, true):
            return restore(.escape)
        case (false, false):
            // (c′), REG-40: the keys without the doubled `w` are English (`answwer`), whatever the shape of `C`.
            if let keys = inputs.withoutWDoublings, isEnglish(keys.lowercased) { return restore(.escape) }
            return isDeliberateForm(inputs) ? .kept(.escape) : restore(.escape)
        }
    }

    /// REG-40: `R′` when rule L4 restores the token without its w doublings: `R` is not English (else (a) or (c)
    /// restores `R`) and either `R′` is English ((c′)) or the w doublings are a habit ((d),
    /// `Composition.wDoublingsAreHabit`). Read only for a token that L4 restored, so `C` is not English unless `R` is.
    func escapeRestoreWithoutWDoublings(_ inputs: CommitInputs) -> RestoreKeys? {
        guard let keys = inputs.withoutWDoublings, !isEnglish(inputs.rawLowercased) else { return nil }
        return inputs.wDoublingsAreHabit || isEnglish(keys.lowercased) ? keys : nil
    }

    /// REG-40, ENG-R904: `R′` when the w doublings are a habit and `R` is not English (`WwordPress` restores
    /// `WordPress`, the case of the other keys kept), as in (d); read for a token that rule L3b restored.
    func habitDoublingsLeftOut(_ inputs: CommitInputs) -> RestoreKeys? {
        guard let keys = inputs.withoutWDoublings, inputs.wDoublingsAreHabit, !isEnglish(inputs.rawLowercased) else {
            return nil
        }
        return keys
    }

    /// The English context of a word whose two forms are English: the run is English (ENG-R823, the evidence of
    /// rule L10), or the previous tokens and `R` start a bundled phrase (ENG-R826, the evidence of rule L9b, read
    /// only with the collision rules on, ENG-R829).
    private func isEnglishContext(_ rawLowercased: String, context: CommitContext) -> Bool {
        context.runIsEnglish || (collisionRules && continuesPhrase(rawLowercased, chain: context.phrases))
    }

    /// The keys of `C`, typed as a token of their own with the same configuration, resources and context, commit
    /// something other than `C`: doubling was the only way to get `C` (`of` alone commits `ò`, so `off` -> `of` is
    /// deliberate). When they commit `C` (`pas` is restored by L8, `desert` shows `dểt` and is restored by L5), the
    /// doubled key was a letter of the word typed (`pass`, `dessert`). The learned memory is left out: it decides
    /// collision words only (ENG-R862, ENG-R877), and a doubling habit does not change with what it learned. `C` is
    /// English, so it is ASCII and has fewer characters than `R` (every escape undoes a key that leaves no character):
    /// the evaluation, which may meet an escape again, ends.
    private func escapeWasNeeded(_ inputs: CommitInputs, context: CommitContext) -> Bool {
        let composition = Composition(replaying: inputs.committed.utf8, rules: rules)
        let token = ActiveToken(
            composition: composition, display: composition.display(style: rules.toneStyle), userChoice: .none,
            restoredByRule: false)
        let alone = CommitInputs(token: token, style: rules.toneStyle)
        var withoutMemory = context
        withoutMemory.readsMemory = false
        let decision = decide(alone, context: withoutMemory, includeUserChoice: false)
        return (decision.restores ? restoredKeys(alone, decision: decision).raw : alone.committed) != inputs.committed
    }

    /// Neither form is English. `C` is a deliberate form when every escape was a doubling and `C` has the shape of
    /// one syllable, one vowel group at most, as every escape example of 4.7 (`nhaamff` -> `nhâmf`, `boooong` ->
    /// `booong`, `sooocs` -> `soóc`, `ddd` -> `dd`, `Karr` -> `Kar`), or ends with the escape, so the user saw `C`
    /// and committed it as shown (`Kroong Anaa` -> `Krông Ana`). Two vowel groups that went on after the escape
    /// cannot be one Vietnamese syllable (3.13), and an escape that is no doubling belongs to a word typed through:
    /// both restore the keys (`coffeehouse`, `leecher`, `pajama`).
    private func isDeliberateForm(_ inputs: CommitInputs) -> Bool {
        !inputs.escapedAcrossKeys && (inputs.facts.vowelGroups <= 1 || inputs.endsWithEscape)
    }
}
