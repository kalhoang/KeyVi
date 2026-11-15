// SPDX-License-Identifier: MPL-2.0

extension Engine {
    /// ENG-R829: a restore toggle right after a commit that revised the token before it puts that token's
    /// previous text back; the current token, the space between them and the boundary character stay. The
    /// revised token becomes the user's choice (rule L1 if it is re-opened) and the output carries a strong
    /// signal for the side it showed first (ENG-R864). Nil when the history no longer has that shape (a
    /// Return or Tab cleared it, or the boundary is not ASCII), so the toggle is handled as usual.
    func undoRevision(_ state: inout EngineState) -> EngineOutput? {
        guard case .boundary(let boundary)? = state.history.entry(beforeNewest: 0), boundary.asciiValue != nil,
            let next = state.history.token(beforeNewest: 1),
            state.history.entry(beforeNewest: 2) == .boundary(" "),
            let revised = state.history.token(beforeNewest: 3), let reason = revised.collision.revision
        else { return nil }
        let previousText = reason.restores ? revised.collision.composed : revised.token.rawText
        let tail = " " + next.committedText + String(boundary)
        let edit = DisplayEdit.edit(from: revised.committedText + tail, to: previousText + tail)
        let choice: UserChoice = reason.restores ? .kept : .restored
        let decision: CommitDecision = choice == .restored ? .restored(.userChoice) : .kept(.userChoice)
        let language = TokenLanguage.of(
            committed: CommittedTextFacts(previousText), decision: decision,
            rawLowercased: revised.collision.rawLowercased, resources: resources,
            collisionRules: commitPolicy.collisionRules)
        state.history.updateToken(beforeNewest: 3) { token in
            token.committedText = previousText
            token.decision = decision
            token.token = token.token.choosing(choice)
            token.language = language
            token.collision.revision = nil
        }
        state.history.updateToken(beforeNewest: 1) { token in
            token.languagesBefore.replace(atDistance: 1, with: language)
        }
        state.recentLanguages.replace(atDistance: 2, with: language)
        var signals: [CollisionSignal] = []
        if let word = revised.collision.listWord {
            signals.append(
                CollisionSignal(
                    word: word, context: revised.collision.context,
                    side: choice == .restored ? .english : .vietnamese, strength: .strong))
        }
        return EngineOutput(action: .edit(edit, thenPassThrough: false), composingText: "", collisionSignals: signals)
    }
}
