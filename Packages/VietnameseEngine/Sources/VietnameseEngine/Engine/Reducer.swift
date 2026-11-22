// SPDX-License-Identifier: MPL-2.0

extension Engine {
    /// Builds the generated tables that composition and commit read (the viability automaton of 3.14,
    /// the syllable tables of section 3, the letter table of ENG-R301) by composing and committing one
    /// word. Their construction runs once per process; doing it when an engine is created keeps it off
    /// the first keystroke, which must stay within the per-event budget (ENG-R1230; the host creates
    /// engines at launch and on configuration changes, ENG-R1211). Returns a value derived from every
    /// table so the work is not optimised away.
    package static func prepareSharedTables(_ rules: ComposerRules) -> Int {
        let composition = Composition(replaying: Array("Dduwowngf".utf8), rules: rules)
        let facts = CommittedTextFacts(composition.committedText(style: rules.toneStyle))
        return ViabilityAutomaton.shared.stateCount &+ facts.lowercased.utf8.count
            &+ (facts.validity == .standard ? 1 : 0)
    }

    /// `reduce` working in place: `Session` calls this so that the state's buffers stay uniquely
    /// referenced and grow without copies (ENG-R1230, ENG-R640). Deterministic and side-effect free
    /// (ENG-R1210).
    package func process(_ state: inout EngineState, _ event: EngineEvent) -> EngineOutput {
        let followsToggle = state.previousEventWasRestoreToggle
        let followsRevision = state.previousEventRevised
        let followsCorrection = state.previousEventCorrected
        let followsContextRestore = state.previousEventRestoredInContext
        state.previousEventWasRestoreToggle = false
        state.previousEventRevised = false
        state.previousEventCorrected = false
        state.previousEventRestoredInContext = false
        switch event {
        case .key(let input):
            switch TokenKey.classify(input, rules: rules) {
            case .token(let key): return appendKey(key, capsLock: input.capsLock, to: &state)
            case .boundary(let isHard): return commit(at: input.character, isHard: isHard, &state)
            }
        case .backspace:
            // ENG-R828: a Backspace into the history (not inside the next token) ends the chance to revise.
            if state.active == nil { state.newestTokenRevisable = false }
            return backspace(&state)
        case .restoreToggle:
            state.previousEventWasRestoreToggle = true
            state.newestTokenRevisable = false
            if followsRevision, !followsToggle, state.active == nil, let undo = undoRevision(&state) { return undo }
            if followsCorrection, !followsToggle, state.active == nil, let undo = undoCorrection(&state) { return undo }
            if followsContextRestore, !followsToggle, state.active == nil, let undo = undoContextRestore(&state) {
                return undo
            }
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
    private func appendKey(_ key: UInt8, capsLock: Bool, to state: inout EngineState) -> EngineOutput {
        var token = state.active ?? ActiveToken()
        state.active = nil
        let action = token.append(key, capsLock: capsLock, rules: rules)
        state.active = token
        return EngineOutput(action: action, composingText: token.display)
    }

    /// The restore toggle (7.2). ENG-R702: right after another toggle it passes through and changes
    /// nothing. ENG-R703: with no active token, or when neither branch of ENG-R701 applies, it passes
    /// through so the key keeps its normal meaning (the undos right after a commit, ENG-R706, ENG-R829 and
    /// ENG-R1117, are tried before this). ENG-R1117: on a re-opened typo correction it brings the
    /// keys as typed back and carries the never-correct signal of the typed word (ENG-R1118).
    private func toggleRestore(_ state: inout EngineState, followsToggle: Bool) -> EngineOutput {
        guard !followsToggle, var token = state.active else {
            return EngineOutput(action: .passThrough, composingText: state.activeDisplay)
        }
        state.active = nil
        let correctedWord = token.correctedWord
        let action = token.toggleRestore(rules: rules)
        state.active = token
        var output = EngineOutput(action: action ?? .passThrough, composingText: token.display)
        if action != nil, let correctedWord { output.learning = .neverCorrect(raw: correctedWord) }
        return output
    }
}
