// SPDX-License-Identifier: MPL-2.0

/// The result of committing the active token at a boundary (section 8).
package struct CommitResult: Sendable, Hashable {
    /// The text the token leaves on screen.
    package var text: String
    /// `passThrough` when the text is the display, otherwise an edit with `thenPassThrough` (ENG-R803).
    package var action: KeyAction
    package var decision: CommitDecision
    package var learning: LearningSignal?
    package var language: TokenLanguage
}

extension Engine {
    /// A boundary key (ENG-R910, 9.2): the macro check first (ENG-R1103), otherwise the commit of the
    /// active token by the rules of 8.1; then the boundary is recorded in the history (or, for Return and
    /// Tab, the history is cleared, ENG-R912) and the boundary key is delivered after any edit
    /// (`thenPassThrough`, ENG-R803). P0-3: nothing here depends on which boundary key it is, except
    /// whether it clears the history afterwards and whether it ends a macro span (whitespace).
    func commit(at boundary: Character, isHard: Bool, _ state: inout EngineState) -> EngineOutput {
        if let output = expandMacro(at: boundary, isHard: isHard, &state) { return output }
        var output = EngineOutput(action: .passThrough, composingText: "")
        if let token = state.active {
            state.active = nil
            let result = commitResult(for: token, runIsEnglish: state.recentLanguages.isEnglishRun)
            let committed = CommittedToken(
                token: token, committedText: result.text, decision: result.decision, language: result.language,
                languagesBefore: state.recentLanguages)
            state.history.record(committed, limit: configuration.historyLimit)
            state.recentLanguages.push(result.language)
            output = EngineOutput(
                action: result.action, composingText: "", decision: result.decision, learning: result.learning)
        }
        finishBoundary(boundary, isHard: isHard, &state)
        return output
    }

    /// ENG-R910, ENG-R912: record the boundary character, or clear the history after Return and Tab. The
    /// run continues across Return and Tab (they are not resets), so the language window is kept.
    private func finishBoundary(_ boundary: Character, isHard: Bool, _ state: inout EngineState) {
        if isHard {
            state.history.clear()
        } else {
            state.history.record(boundary: boundary, limit: configuration.historyLimit)
        }
    }

    /// The decision at commit for one token (8.1) and the text it leaves on screen: the raw keys when it
    /// is restored, otherwise the composed form `C` (with the ENG-R532 spelling of an open `ươ`). A
    /// re-opened macro expansion that the user did not restore keeps its text (`CommitDecision.macro`).
    func commitResult(for token: ActiveToken, runIsEnglish: Bool) -> CommitResult {
        if token.isMacro {
            return CommitResult(
                text: token.display, action: .passThrough, decision: .macro, learning: nil,
                language: TokenLanguage.ofExpansion(token.display))
        }
        let inputs = CommitInputs(token: token, style: rules.toneStyle)
        let decision = commitPolicy.decide(inputs, runIsEnglish: runIsEnglish)
        let learning = commitPolicy.learningSignal(inputs, decision: decision, runIsEnglish: runIsEnglish)
        let restored = decision.restores
        let text = restored ? inputs.raw : inputs.committed
        let action: KeyAction =
            text == token.display
            ? .passThrough : .edit(DisplayEdit.edit(from: token.display, to: text), thenPassThrough: true)
        let language = TokenLanguage.of(committed: inputs.facts, restored: restored, resources: resources)
        return CommitResult(text: text, action: action, decision: decision, learning: learning, language: language)
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
        // what it was before the oldest of them.
        for _ in 0..<span.historyEntryCount {
            if case .token(let committed)? = state.history.popLast() {
                state.recentLanguages = committed.languagesBefore
            }
        }
        state.active = nil
        let language = TokenLanguage.ofExpansion(expansion)
        let macroToken = CommittedToken(
            token: ActiveToken(macroSpan: span.typed, expansion: expansion), committedText: expansion,
            decision: .macro, language: language, languagesBefore: state.recentLanguages)
        state.history.record(macroToken, limit: configuration.historyLimit)
        state.recentLanguages.push(language)
        finishBoundary(boundary, isHard: isHard, &state)
        let isEmptyEdit = edit.deleteCount == 0 && edit.insert.isEmpty
        return EngineOutput(
            action: isEmptyEdit ? .passThrough : .edit(edit, thenPassThrough: true), composingText: "",
            decision: .macro)
    }
}
