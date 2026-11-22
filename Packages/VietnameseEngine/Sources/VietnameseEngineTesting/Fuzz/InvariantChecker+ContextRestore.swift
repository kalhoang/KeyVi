// SPDX-License-Identifier: MPL-2.0
//
// The ENG-T32 check of `InvariantChecker` for the undo of a context restore (spec/01-engine.md ENG-R706, REG-42).

import VietnameseEngine

extension InvariantChecker {
    /// ENG-T32 extended (ENG-R706): right after a commit that restored its token because of the tokens before it (rule
    /// L10 or L9b, the token alone keeping its composed form), the toggle, probed on a copy of the session with the
    /// field as it is now, consumes the key with one edit that turns the restored keys and the boundary character into
    /// exactly the composed form and the same character, leaves the token user-kept in the history, and the toggle
    /// after it passes through (ENG-R702). The condition is recomputed here from the output and the history, so a
    /// commit the engine forgets to mark is caught too.
    mutating func checkContextRestoreUndo(_ output: EngineOutput, index: Int) throws {
        let state = session.state
        guard output.revision == nil, let decision = output.decision, state.active == nil,
            case .boundary(let boundary)? = state.history.entry(beforeNewest: 0), boundary.asciiValue != nil,
            let token = state.history.token(beforeNewest: 1),
            engine.commitPolicy.restoresOnlyInContext(decision, rawLowercased: token.collision.rawLowercased)
        else { return }
        let composed = token.collision.composed
        let before = token.committedText + String(boundary)
        guard state.previousEventRestoredInContext, field.count >= before.count,
            String(field.suffix(before.count)) == before
        else {
            throw violation(
                "ENG-R706", "a context restore is not marked for the undo, or the field does not end with it", index)
        }
        var probe = session
        let undo = probe.handle(.restoreToggle)
        guard case .edit(let edit, thenPassThrough: false) = undo.action, edit.deleteCount <= before.count,
            String(Array(before).dropLast(edit.deleteCount)) + edit.insert == composed + String(boundary),
            let undone = probe.state.history.token(beforeNewest: 1), undone.committedText == composed,
            undone.decision == .kept(.userChoice)
        else {
            throw violation(
                "ENG-T32", "the toggle after a context restore does not give \(composed.debugDescription)", index)
        }
        guard probe.handle(.restoreToggle).action == .passThrough else {
            throw violation("ENG-R702", "the toggle after the undo of a context restore does not pass through", index)
        }
        statistics.restoreChecks += 1
    }
}
