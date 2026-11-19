// SPDX-License-Identifier: MPL-2.0
//
// The ENG-T54 checks of `InvariantChecker` for the typo correction of section 11A (spec/01-engine.md 11A.5).

import VietnameseEngine

/// What the correction checks need from the state before an event.
struct CorrectionSnapshot {
    /// The active token and the length of its display.
    let token: ActiveToken?
    let displayCount: Int
    /// The previous event was a commit that corrected its token, or revised the token before it, or a toggle.
    let followsCorrection: Bool
    let followsRevision: Bool
    let followsToggle: Bool
    /// The typed word a toggle may name in a never-correct signal: the re-opened corrected token's, or the one of the
    /// correction the previous commit made.
    let undoableWord: String?

    init(_ state: EngineState) {
        token = state.active
        displayCount = state.active?.display.count ?? 0
        followsCorrection = state.previousEventCorrected
        followsRevision = state.previousEventRevised
        followsToggle = state.previousEventWasRestoreToggle
        undoableWord =
            state.active?.correctedWord
            ?? (state.previousEventCorrected ? state.history.token(beforeNewest: 1)?.token.correctedWord : nil)
    }
}

extension InvariantChecker {
    /// ENG-T54 for one output: the switch-off half never corrects; with the switch on a correction is made only
    /// where section 11A allows it and has the shape of ENG-R1115.
    func checkCorrection(
        _ event: EngineEvent, _ output: EngineOutput, before: CorrectionSnapshot, index: Int
    ) throws {
        let configuration = engine.configuration
        guard configuration.typoCorrection else {
            try checkSwitchOff(event, output, before: before, index: index)
            return
        }
        if case .neverCorrect(let word)? = output.learning {
            guard word == before.undoableWord, !word.isEmpty, word.utf8.allSatisfy(ASCII.isLowercaseLetter) else {
                throw violation("ENG-T54", "a neverCorrect signal does not name its token's typed word", index)
            }
        }
        guard case .corrected? = output.decision, let token = before.token else { return }
        if configuration.appContext == .code {
            throw violation("ENG-T54", "a correction in the code context", index)
        }
        if output.revision != nil {
            throw violation("ENG-T54", "a commit both corrects and revises", index)
        }
        switch output.action {
        case .edit(let edit, true):
            if edit.deleteCount > before.displayCount {
                throw violation("ENG-T54", "a correction deletes more than the active token's display", index)
            }
        case .edit(_, false):
            throw violation("ENG-T54", "a correction swallows the committing key", index)
        case .passThrough:
            // Only the re-commit of a re-opened corrected token, which changes nothing on screen (ENG-R1117).
            if token.correctedRule == nil { throw violation("ENG-T54", "a correction without an edit", index) }
        }
        guard token.correctedRule == nil else { return }
        try checkCorrectedWord(token.rawText, index: index)
    }

    /// A freshly corrected typed word: on no list (ENG-R1110 (c)), not one edit from Vietnamese (ENG-R1125), and the
    /// text written is a word of the correction lexicon (ENG-T35 extended), read from the history when the
    /// committing key kept it.
    private func checkCorrectedWord(_ raw: String, index: Int) throws {
        let resources = engine.resources
        let word = raw.lowercased()
        let listed =
            resources.english.contains(word) || resources.techAlways.contains(word)
            || resources.techCodeOnly.contains(word) || resources.correction.guardList.mayContain(word)
            || resources.userKeepRaw.contains(word) || resources.userKeepVietnamese.contains(word)
            || resources.userNeverCorrect.contains(word) || resources.ambiguity[word] != nil
            || resources.collision.supplement.contains(word)
        if listed { throw violation("ENG-T54", "a word of a list was corrected", index) }
        var vietnamese = false
        Array(word.utf8).withUnsafeBufferPointer { bytes in
            edits.forEachEdit(of: bytes, positionRules: false) { edit in
                let text = String(decoding: edit, as: UTF8.self)
                vietnamese =
                    resources.correction.vietnameseKeyings.contains(text)
                    || resources.correction.unmarkedShapes.contains(text)
                return !vietnamese
            }
        }
        if vietnamese { throw violation("ENG-T54", "a typed word one edit from Vietnamese was corrected", index) }
        guard let written = session.state.history.token(beforeNewest: 1)?.committedText.lowercased() else { return }
        if !(resources.english.contains(written) || resources.techAlways.contains(written)) {
            throw violation("ENG-T54", "a correction wrote a word outside the correction lexicon", index)
        }
    }

    /// ENG-R1119: with the switch off nothing carries the correction, and a toggle with no active token answers as
    /// ENG-R703 and ENG-R829 say.
    private func checkSwitchOff(_ event: EngineEvent, _ output: EngineOutput, before: CorrectionSnapshot, index: Int)
        throws
    {
        if case .corrected? = output.decision {
            throw violation("ENG-T54", "a correction with typoCorrection off", index)
        }
        if case .neverCorrect? = output.learning {
            throw violation("ENG-T54", "a neverCorrect signal with typoCorrection off", index)
        }
        guard case .restoreToggle = event, before.token == nil, before.followsToggle || !before.followsRevision
        else { return }
        guard output.action == .passThrough else {
            throw violation("ENG-T54", "a toggle with no active token edited the field", index)
        }
    }

    /// ENG-T32 extended: right after a corrected commit the toggle gives exactly the raw keys typed (probed on a copy
    /// of the session, the field as it is now), and the toggle that does so carries the signal.
    mutating func checkCorrectionUndo(
        _ event: EngineEvent, _ output: EngineOutput, before: CorrectionSnapshot, index: Int
    ) throws {
        // A re-opened correction may be committed again by any key; after a non-ASCII one the toggle passes through
        // (ENG-R829), as after a revision.
        guard engine.configuration.typoCorrection, case .corrected? = output.decision,
            session.state.previousEventCorrected, let token = session.state.history.token(beforeNewest: 1),
            case .boundary(let boundary)? = session.state.history.entry(beforeNewest: 0), boundary.asciiValue != nil
        else { return }
        let raw = token.token.rawText
        var probe = session
        let undo = probe.handle(.restoreToggle)
        guard case .edit(let edit, thenPassThrough: false) = undo.action, edit.deleteCount <= field.count,
            case .neverCorrect? = undo.learning
        else {
            throw violation("ENG-T32", "the toggle after a correction does not undo it", index)
        }
        let tail = String(field.suffix(raw.count + token.committedText.count + 1))
        let undone = String(Array(tail).dropLast(edit.deleteCount)) + edit.insert
        guard undone.hasSuffix(raw + String(boundary)), probe.state.history.token(beforeNewest: 1)?.committedText == raw
        else {
            throw violation("ENG-T32", "the toggle after a correction does not give the raw keys \(raw)", index)
        }
        statistics.restoreChecks += 1
    }
}
