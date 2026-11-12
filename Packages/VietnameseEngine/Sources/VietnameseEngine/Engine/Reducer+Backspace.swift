// SPDX-License-Identifier: MPL-2.0

extension Engine {
    /// Backspace: inside the active token by 7.4 (ENG-R710 to ENG-R712), otherwise by the history rules
    /// of 10.1 (ENG-R713).
    func backspace(_ state: inout EngineState) -> EngineOutput {
        guard var token = state.active else { return backspaceIntoHistory(&state) }
        state.active = nil
        let action = token.backspace(rules: rules)
        if !token.isEmpty { state.active = token }
        return EngineOutput(action: action, composingText: state.activeDisplay)
    }

    /// ENG-R1002 to ENG-R1004. Backspace with no active token removes the last recorded boundary
    /// character and lets the app delete it (`passThrough`). When that exposes a committed token, the
    /// token is re-opened as the active token with all its raw keys and flags, so the next keys edit it
    /// (`chao`, space, Backspace, `f` -> `chào`, REG-07); this works across `", "`, `". "` and double
    /// spaces because every boundary character is its own entry. ENG-R1004: with an empty history the
    /// Backspace passes through and nothing changes.
    private func backspaceIntoHistory(_ state: inout EngineState) -> EngineOutput {
        guard let last = state.history.last else {
            return EngineOutput(action: .passThrough, composingText: "")
        }
        switch last {
        case .boundary:
            state.history.popLast()
            reopenNewestToken(&state)
            return EngineOutput(action: .passThrough, composingText: state.activeDisplay)
        case .token:
            // A commit always records its boundary after the token, so the newest entry is a token only
            // if something removed that boundary without re-opening; re-open it and delete into it
            // (ENG-R1003) so the engine never loses track of the text.
            reopenNewestToken(&state)
            return state.active == nil ? backspaceIntoHistory(&state) : backspace(&state)
        }
    }

    /// Re-opens the newest history entry if it is a token (ENG-R1002). The run's language window goes
    /// back to what it was before the token (ENG-R823). An expansion that left no text (an empty
    /// expansion) has nothing to edit and is dropped.
    private func reopenNewestToken(_ state: inout EngineState) {
        guard case .token(let committed)? = state.history.last else { return }
        state.history.popLast()
        state.recentLanguages = committed.languagesBefore
        let token = committed.reopened
        state.active = token.isEmpty ? nil : token
    }
}
