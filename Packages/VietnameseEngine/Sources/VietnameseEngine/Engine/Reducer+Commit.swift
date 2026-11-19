// SPDX-License-Identifier: MPL-2.0

/// The result of committing the active token at a boundary (section 8).
package struct CommitResult: Sendable {
    /// The text the token leaves on screen.
    package var text: String
    /// `passThrough` when the text is the display, otherwise an edit with `thenPassThrough` (ENG-R803).
    package var action: KeyAction
    package var decision: CommitDecision
    package var learning: LearningSignal?
    package var language: TokenLanguage
    /// The inputs of the decision; nil for a re-opened macro expansion.
    package var inputs: CommitInputs?
    /// What the collision rules keep about the token (ENG-R825 to ENG-R829).
    package var collision = CollisionFacts()
    /// The strong signal of a collision word committed by the user's toggle against the rules (ENG-R864).
    package var strongSignal: CollisionSignal?
}

extension Engine {
    /// A boundary key (ENG-R910, 9.2): the macro check first (ENG-R1103), otherwise the commit of the
    /// active token by the rules of 8.1, which may also revise the token before it (ENG-R828); then the
    /// boundary is recorded in the history (or, for Return and Tab, the history is cleared, ENG-R912) and the
    /// boundary key is delivered after any edit (`thenPassThrough`, ENG-R803). P0-3: nothing here depends on
    /// which boundary key it is, except whether it clears the history afterwards, whether it ends a macro
    /// span (whitespace), rule L9a (`.`, `!`, `?`, Return), the space of rule L9's sentence condition (ENG-R850)
    /// and the keys that let RV5 revise (ENG-R828).
    func commit(at boundary: Character, isHard: Bool, _ state: inout EngineState) -> EngineOutput {
        let mayRevise = state.newestTokenRevisable
        state.newestTokenRevisable = false
        if let output = expandMacro(at: boundary, isHard: isHard, &state) { return output }
        var output = EngineOutput(action: .passThrough, composingText: "")
        if let token = state.active {
            state.active = nil
            output = commitToken(token, boundary: boundary, mayRevise: mayRevise, &state)
            state.newestTokenRevisable = true
            state.previousEventRevised = output.revision != nil && !isHard
        }
        output.collisionSignals += finishBoundary(boundary, isHard: isHard, &state)
        return output
    }

    /// Commits `token` (8.1), revises the previous token when ENG-R828 applies, records the token and
    /// returns the output without the boundary's own signals.
    private func commitToken(_ token: ActiveToken, boundary: Character, mayRevise: Bool, _ state: inout EngineState)
        -> EngineOutput
    {
        let context = CommitContext(
            runIsEnglish: state.recentLanguages.isEnglishRun, boundary: boundary,
            memoryContext: Self.memoryContext(state.history),
            phrases: commitPolicy.collisionRules ? PhraseChain(history: state.history) : PhraseChain(),
            inVietnameseText: configuration.appContext == .code && commitPolicy.isInVietnameseText(state.history),
            atLineStart: CommitPolicy.isLineStart(state.history),
            characterBefore: commitPolicy.corrector == nil ? nil : CommitContext.characterBefore(state.history))
        var result = commitResult(for: token, context: context)
        // RV5 of ENG-R828 (ENG-R850): a code-only word that L9 restored as the first word of its line (no token since
        // the start of input, Return, Tab or a reset, only spaces and the openers of prose before it) remembers
        // whether the rules after L9 keep its Vietnamese display, decided now with its own run and window.
        if commitPolicy.lineRevision, result.decision == .restored(.codeContext), context.atLineStart,
            let inputs = result.inputs
        {
            result.collision.vietnameseAtLineStart = commitPolicy.keepsVietnameseAfterCodeRule(inputs, context: context)
        }
        // Section 11A: the typo correction, after the decision and before the edit is formed (ENG-R1110). A commit
        // never both corrects and revises (ENG-R1116).
        let corrected = correct(&result, token: token, context: context)
        var action = result.action
        var revision: RevisionReason?
        if mayRevise, !corrected,
            let revised = revisePrevious(result, display: token.display, context: context, &state)
        {
            revision = revised.reason
            action = .edit(revised.edit, thenPassThrough: true)
        }
        // ENG-R861, ENG-R864: a reported choice is not reported again when the token is re-committed.
        let stored = result.learning == nil ? token : token.reportingChoice()
        let committed = CommittedToken(
            token: stored, committedText: result.text, decision: result.decision, language: result.language,
            languagesBefore: state.recentLanguages, collision: result.collision)
        state.history.record(committed, limit: configuration.historyLimit)
        state.recentLanguages.push(result.language)
        var signals: [CollisionSignal] = []
        if let strong = result.strongSignal { signals.append(strong) }
        if let due = state.pendingSignals.push(weakSignal(result)) { signals.append(due) }
        return EngineOutput(
            action: action, composingText: "", decision: result.decision, learning: result.learning,
            revision: revision, collisionSignals: signals)
    }

    /// Section 11A: replaces the decided result with the typo correction when there is one (ENG-R1115: one edit of
    /// the display, the correction followed by the committing key; `corrected(rule)`; ENG-R1116: English for the
    /// run, no collision signal and no learning signal). Returns whether it did.
    private func correct(_ result: inout CommitResult, token: ActiveToken, context: CommitContext) -> Bool {
        guard let corrector = commitPolicy.corrector, let inputs = result.inputs,
            let correction = corrector.correction(
                for: inputs, decision: result.decision, token: token, context: context)
        else { return false }
        result.text = correction.text
        result.decision = .corrected(correction.rule)
        result.action = .edit(DisplayEdit.edit(from: token.display, to: correction.text), thenPassThrough: true)
        result.language = .english
        result.learning = nil
        result.strongSignal = nil
        result.collision.listWord = nil
        return true
    }

    /// ENG-R864: the weak signal a committed token gives once its decision is final untouched, nil when the
    /// word is not on the collision list or its rule gives none.
    private func weakSignal(_ result: CommitResult) -> CollisionSignal? {
        guard let word = result.collision.listWord, result.decision.rule?.givesWeakSignal == true,
            let inputs = result.inputs, inputs.committed != inputs.raw
        else { return nil }
        return CollisionSignal(
            word: word, context: result.collision.context, side: result.decision.restores ? .english : .vietnamese,
            strength: .weak)
    }

    /// ENG-R828: when the newest committed token is followed by exactly one space and the token being
    /// committed shows its language, the newest token is revised once, inside this commit's edit. Updates
    /// the history and the language window and returns the reason and the one edit that covers the previous
    /// token, the space and the current token (ENG-R803). RV1 to RV4 need `lookaheadRevision`, RV5 the code
    /// context's `lineStartRevision` (ENG-R829); every revision needs auto restore.
    private func revisePrevious(
        _ current: CommitResult, display: String, context: CommitContext, _ state: inout EngineState
    ) -> (reason: RevisionReason, edit: TextEdit)? {
        guard configuration.lookaheadRevision || commitPolicy.lineRevision, configuration.autoRestore,
            let inputs = current.inputs, state.history.entry(beforeNewest: 0) == .boundary(" "),
            let previous = state.history.token(beforeNewest: 1)
        else { return nil }
        let beforePrevious =
            state.history.entry(beforeNewest: 2) == .boundary(" ") ? state.history.token(beforeNewest: 3) : nil
        let evidence = RevisionEvidence(
            inputs: inputs, decision: current.decision, text: current.text, phraseWord: current.collision.phraseWord,
            boundary: context.boundary)
        guard
            let reason = commitPolicy.revision(
                of: previous, beforePrevious: beforePrevious, next: evidence, chain: context.phrases)
        else { return nil }
        let newText = reason.restores ? previous.token.rawText : previous.collision.composed
        let edit = DisplayEdit.edit(from: previous.committedText + " " + display, to: newText + " " + current.text)
        let language: TokenLanguage = reason.restores ? .english : .neutral
        state.history.updateToken(beforeNewest: 1) { token in
            token.committedText = newText
            token.language = language
            token.collision.revision = reason
        }
        state.recentLanguages.replace(atDistance: 1, with: language)
        state.pendingSignals.withdraw(atDistance: 1)
        return (reason, edit)
    }

    /// ENG-R910, ENG-R912: record the boundary character, or clear the history after Return and Tab. The
    /// run continues across Return and Tab (they are not resets), so the language window is kept. Returns
    /// the weak signals that Return and Tab make final (ENG-R864).
    func finishBoundary(_ boundary: Character, isHard: Bool, _ state: inout EngineState) -> [CollisionSignal] {
        if isHard {
            state.history.clear()
            return state.pendingSignals.flush()
        }
        state.history.record(boundary: boundary, limit: configuration.historyLimit)
        return []
    }

    /// The decision at commit for one token (8.1) and the text it leaves on screen: the raw keys when it
    /// is restored, otherwise the composed form `C` (with the ENG-R532 spelling of an open `ươ`). A
    /// re-opened macro expansion that the user did not restore keeps its text (`CommitDecision.macro`).
    func commitResult(for token: ActiveToken, context: CommitContext) -> CommitResult {
        if token.isMacro {
            return CommitResult(
                text: token.display, action: .passThrough, decision: .macro, learning: nil,
                language: TokenLanguage.ofExpansion(token.display))
        }
        let inputs = CommitInputs(token: token, style: rules.toneStyle)
        let decision = commitPolicy.decide(inputs, context: context)
        let learning = commitPolicy.learningSignal(inputs, decision: decision, context: context)
        let restored = decision.restores
        let text = restored ? inputs.raw : inputs.committed
        let action: KeyAction =
            text == token.display
            ? .passThrough : .edit(DisplayEdit.edit(from: token.display, to: text), thenPassThrough: true)
        let language = TokenLanguage.of(
            committed: inputs.facts, decision: decision, rawLowercased: inputs.rawLowercased, resources: resources,
            collisionRules: commitPolicy.collisionRules)
        var result = CommitResult(
            text: text, action: action, decision: decision, learning: learning, language: language, inputs: inputs)
        result.collision = collisionFacts(inputs, context: context)
        if learning != nil, let word = result.collision.listWord {
            result.strongSignal = CollisionSignal(
                word: word, context: context.memoryContext, side: restored ? .english : .vietnamese, strength: .strong)
        }
        return result
    }

    /// The collision facts recorded with a committed token.
    private func collisionFacts(_ inputs: CommitInputs, context: CommitContext) -> CollisionFacts {
        var facts = CollisionFacts()
        facts.rawLowercased = inputs.rawLowercased
        facts.composed = inputs.committed
        facts.context = context.memoryContext
        facts.listWord = commitPolicy.listWord(inputs.rawLowercased)
        // Read only by rule L9, which only the code context reaches; the configuration is fixed per engine.
        facts.vietnameseAsTyped = configuration.appContext == .code && commitPolicy.isVietnameseAsTyped(inputs)
        if commitPolicy.collisionRules {
            facts.phraseWord = resources.collision.phrases.number(of: inputs.rawLowercased)
        }
        return facts
    }

    /// ENG-R1103: on a boundary key, before rule L0, a span equal to a trigger (ignoring case) is replaced
    /// by the expansion, adapted to the case of the span, and the boundary key is delivered after the
    /// edit. The span's tokens and boundary characters leave the history and one literal token takes
    /// their place, raw keys = the span as typed, display = the expansion (ENG-R1104).
    ///
    /// Not checked when the active token is user-restored: the user asked for the keys as typed, and the
    /// toggle that brings a span back (ENG-R1104) would otherwise be undone by the next boundary.
    private func expandMacro(at boundary: Character, isHard: Bool, _ state: inout EngineState) -> EngineOutput? {
        guard !resources.macros.isEmpty, state.active?.userChoice != .restored,
            let span = MacroSpan(active: state.active, history: state.history),
            let entry = resources.macros.entry(for: span.key)
        else { return nil }
        let expansion = MacroCase.adapt(entry.expansion, toTyped: span.typed, adaptCase: entry.adaptCase)
        var old = ""
        for historyEntry in state.history.entries.suffix(span.historyEntryCount) { old += historyEntry.text }
        old += state.activeDisplay
        let edit = DisplayEdit.graphemeEdit(from: old, to: expansion)
        // The span's tokens are no longer committed tokens of the run: the language window goes back to
        // what it was before the oldest of them, and their weak signals are withdrawn (ENG-R864).
        for _ in 0..<span.historyEntryCount {
            if case .token(let committed)? = state.history.popLast() {
                state.recentLanguages = committed.languagesBefore
                state.pendingSignals.popNewest()
            }
        }
        state.active = nil
        let language = TokenLanguage.ofExpansion(expansion)
        let macroToken = CommittedToken(
            token: ActiveToken(macroSpan: span.typed, expansion: expansion), committedText: expansion,
            decision: .macro, language: language, languagesBefore: state.recentLanguages)
        state.history.record(macroToken, limit: configuration.historyLimit)
        state.recentLanguages.push(language)
        var signals: [CollisionSignal] = []
        if let due = state.pendingSignals.push(nil) { signals.append(due) }
        signals += finishBoundary(boundary, isHard: isHard, &state)
        let isEmptyEdit = edit.deleteCount == 0 && edit.insert.isEmpty
        return EngineOutput(
            action: isEmptyEdit ? .passThrough : .edit(edit, thenPassThrough: true), composingText: "",
            decision: .macro, collisionSignals: signals)
    }
}
