// SPDX-License-Identifier: MPL-2.0

/// The result of committing the active token at a boundary (section 8).
package struct CommitResult: Sendable, Hashable {
    /// The text the token leaves on screen.
    package var text: String
    /// `passThrough` when the text is the display, otherwise an edit with `thenPassThrough` (ENG-R803).
    package var action: KeyAction
    package var decision: CommitDecision?
}

extension Engine {
    /// `reduce` working in place: `Session` calls this so that the state's buffers stay uniquely
    /// referenced and grow without copies (ENG-R1230, ENG-R640). Deterministic and side-effect free
    /// (ENG-R1210).
    package func process(_ state: inout EngineState, _ event: EngineEvent) -> EngineOutput {
        let followsToggle = state.previousEventWasRestoreToggle
        state.previousEventWasRestoreToggle = false
        switch event {
        case .key(let input):
            switch TokenKey.classify(input, rules: rules) {
            case .token(let key): return appendKey(key, to: &state)
            case .boundary(let isHard): return commit(at: input.character, isHard: isHard, &state)
            }
        case .backspace:
            return backspace(&state)
        case .restoreToggle:
            state.previousEventWasRestoreToggle = true
            return toggleRestore(&state, followsToggle: followsToggle)
        case .reset:
            // ENG-R1011, ENG-R831: drop the token and the history, edit nothing, commit nothing.
            state = .initial
            return EngineOutput(action: .passThrough, composingText: "")
        }
    }

    /// A key of the token (sections 4 to 6). The token is moved out of the state while it changes so
    /// that its storage is uniquely referenced.
    private func appendKey(_ key: UInt8, to state: inout EngineState) -> EngineOutput {
        var token = state.active ?? ActiveToken()
        state.active = nil
        let action = token.append(key, rules: rules)
        state.active = token
        return EngineOutput(action: action, composingText: token.display)
    }

    /// Backspace (7.4). ENG-R713: with no active token the history rules of section 10 apply.
    private func backspace(_ state: inout EngineState) -> EngineOutput {
        guard var token = state.active else {
            // E3 PLUG-IN (ENG-R1002 to ENG-R1004): remove the last boundary character from the history and
            // re-open the token before it. Until then the Backspace reaches the app unchanged.
            return EngineOutput(action: .passThrough, composingText: "")
        }
        state.active = nil
        let action = token.backspace(rules: rules)
        if !token.isEmpty { state.active = token }
        return EngineOutput(action: action, composingText: state.active?.display ?? "")
    }

    /// The restore toggle (7.2). ENG-R702: right after another toggle it passes through and changes
    /// nothing. ENG-R703: with no active token, or when neither branch of ENG-R701 applies, it passes
    /// through so the key keeps its normal meaning.
    private func toggleRestore(_ state: inout EngineState, followsToggle: Bool) -> EngineOutput {
        guard !followsToggle, var token = state.active else {
            return EngineOutput(action: .passThrough, composingText: state.activeDisplay)
        }
        state.active = nil
        let action = token.toggleRestore(rules: rules)
        state.active = token
        return EngineOutput(action: action ?? .passThrough, composingText: token.display)
    }

    /// A boundary key (ENG-R910): commit the active token, record it and the boundary in the history,
    /// deliver the boundary key, start a fresh token (the next token key creates it).
    private func commit(at boundary: Character, isHard: Bool, _ state: inout EngineState) -> EngineOutput {
        var result = CommitResult(text: "", action: .passThrough, decision: nil)
        if let token = state.active {
            state.active = nil
            result = commitResult(for: token, boundary: boundary, history: state.history)
            let committed = CommittedToken(token: token, committedText: result.text, decision: result.decision)
            state.history.record(committed, limit: configuration.historyLimit)
        }
        if isHard {
            state.history.clear()  // ENG-R912: commit, then clear the history.
        } else {
            state.history.record(boundary: boundary, limit: configuration.historyLimit)
        }
        return EngineOutput(action: result.action, composingText: "", decision: result.decision)
    }

    /// E3 PLUG-IN (section 8, ENG-R1103): the commit decision. E2 commits every token unchanged: the
    /// display stays, the boundary key passes through and no decision is reported. E3 replaces this
    /// body with the macro check (ENG-R1103, before L0), the rules L0 to L11 of 8.1 (inputs:
    /// `token.display`, `token.rawText`, `token.composition.escapeUsed`, `token.composition.isCamelCase`,
    /// `token.userChoice`, `token.restoredByRule`, the language of `history`), the ENG-R532 form
    /// (`token.composition.committedText(style:)`) when the composed form is kept, and an edit with
    /// `thenPassThrough: true` when the committed text differs from the display (ENG-R803).
    private func commitResult(for token: ActiveToken, boundary: Character, history: History) -> CommitResult {
        CommitResult(text: token.display, action: .passThrough, decision: nil)
    }
}
