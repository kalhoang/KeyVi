// SPDX-License-Identifier: MPL-2.0

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
            // ENG-R1011, ENG-R831: drop the token, the history and the run's language window; edit
            // nothing, commit nothing. ENG-R1012: the next key starts a fresh token like any first key.
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
}
