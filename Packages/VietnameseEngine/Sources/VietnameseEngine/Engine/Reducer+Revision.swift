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
            // ENG-R864: the strong signal below reports the choice; a later re-commit reports nothing new.
            token.token = token.token.choosing(choice)
            if revised.collision.listWord != nil { token.token = token.token.reportingChoice() }
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

    /// ENG-R1117: a restore toggle right after a commit that corrected its token puts the keys as typed back; the
    /// boundary character stays (one edit over the correction and the boundary, as `undoRevision`). The token becomes
    /// the user's choice (rule L1 if it is re-opened, ENG-R1117), English for the run as a restored token is
    /// (ENG-R823), and the output carries `neverCorrect` with the typed word (ENG-R1118) and no decision. Nil when
    /// the history no longer has that shape (a Return or Tab cleared it; every key that commits a correction is
    /// ASCII, ENG-R1112), so the toggle is handled as usual.
    func undoCorrection(_ state: inout EngineState) -> EngineOutput? {
        guard case .boundary(let boundary)? = state.history.entry(beforeNewest: 0), boundary.asciiValue != nil,
            let corrected = state.history.token(beforeNewest: 1), case .corrected = corrected.decision,
            let word = corrected.token.correctedWord
        else { return nil }
        let raw = corrected.token.rawText
        let tail = String(boundary)
        let edit = DisplayEdit.edit(from: corrected.committedText + tail, to: raw + tail)
        let decision = CommitDecision.restored(.userChoice)
        let language = TokenLanguage.of(
            committed: CommittedTextFacts(raw), decision: decision, rawLowercased: word, resources: resources,
            collisionRules: commitPolicy.collisionRules)
        state.history.updateToken(beforeNewest: 1) { token in
            token.committedText = raw
            token.decision = decision
            token.token = token.token.undoingCorrection(rules: rules)
            token.language = language
        }
        state.recentLanguages.replace(atDistance: 1, with: language)
        return EngineOutput(
            action: .edit(edit, thenPassThrough: false), composingText: "", learning: .neverCorrect(raw: word))
    }
}

extension Engine {
    /// ENG-R706 (REG-42): a restore toggle right after a commit that restored its token because of the tokens before it
    /// (rule L10 or L9b, while the token alone would keep it) puts the composed form `C` back; the boundary character
    /// stays (one edit over the restored keys and the boundary, the shape of `undoRevision`). The token becomes the
    /// user's choice, user-kept (rule L1 if it is re-opened), and the output carries what Backspace, the toggle and the
    /// boundary key would give (ENG-R704): the learning signal of ENG-R861 and, for a word of the collision list, a
    /// strong signal for the Vietnamese side (ENG-R864); the token's weak signal is withdrawn. Nil when the history no
    /// longer has that shape (a Return or Tab cleared it, or the boundary is not ASCII), so the toggle is handled as
    /// usual.
    func undoContextRestore(_ state: inout EngineState) -> EngineOutput? {
        guard case .boundary(let boundary)? = state.history.entry(beforeNewest: 0), boundary.asciiValue != nil,
            let restored = state.history.token(beforeNewest: 1),
            commitPolicy.restoresOnlyInContext(restored.decision, rawLowercased: restored.collision.rawLowercased),
            restored.collision.composed != restored.committedText
        else { return nil }
        let composed = restored.collision.composed
        let tail = String(boundary)
        let edit = DisplayEdit.edit(from: restored.committedText + tail, to: composed + tail)
        let decision = CommitDecision.kept(.userChoice)
        let language = TokenLanguage.of(
            committed: CommittedTextFacts(composed), decision: decision,
            rawLowercased: restored.collision.rawLowercased, resources: resources,
            collisionRules: commitPolicy.collisionRules)
        let learning: LearningSignal? =
            restored.token.choiceSignalled ? nil : .preferredVietnamese(raw: restored.collision.rawLowercased)
        state.history.updateToken(beforeNewest: 1) { token in
            token.committedText = composed
            token.decision = decision
            // ENG-R861, ENG-R864: the signals below report the choice; a later re-commit reports nothing new.
            token.token = token.token.choosing(.kept).omittingWDoublings(false).reportingChoice()
            token.language = language
        }
        state.recentLanguages.replace(atDistance: 1, with: language)
        state.pendingSignals.withdraw(atDistance: 1)
        var signals: [CollisionSignal] = []
        if let word = restored.collision.listWord {
            signals.append(
                CollisionSignal(word: word, context: restored.collision.context, side: .vietnamese, strength: .strong))
        }
        return EngineOutput(
            action: .edit(edit, thenPassThrough: false), composingText: "", learning: learning,
            collisionSignals: signals)
    }
}
