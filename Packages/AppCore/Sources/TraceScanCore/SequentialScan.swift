// SPDX-License-Identifier: GPL-3.0-or-later
//
// One pass over a dev trace in time order (PLT-R904A) for findings a to g and i. It follows the token the engine
// shows (`comp` of the last engine step) and KeyVi's view of the text it produced since the last boundary, so a
// boundary can say whether a token was open and a readback can be compared with what KeyVi believes it typed
// (`ReadbackCheck`: dropped keys, extra characters, slow readbacks). Since 2026-11-15 it also follows which keys are
// down: a keyUp whose keyDown the tap never saw is an unseenKey (PLT-R397A), and the first press of a key after its
// keyUp was held and replayed is remembered to name a dropped key (ADR 0322).

internal import Diagnostics
internal import Foundation

struct SequentialScan {
    private var context = TraceContext()
    private var composing = ""
    private var believed = BelievedText()
    private var readbacks = ReadbackCheck()
    private var pendingKey: TraceEvent?
    private var pendingSteps = 0
    private var lastKeyT: Int64?
    private var lastTransformT: Int64?
    private var lastEditT: Int64?
    private var burst: (start: Int64, last: Int64, count: Int, index: Int)?
    private var fallbacks: [UInt64: [String]] = [:]
    /// Keys whose keyDown the trace shows and whose keyUp it does not yet, with the keyDown's outcome.
    private var down: [UInt16: String] = [:]
    /// The end of the last gap, pause or launch start (and the first line read): keys may have gone down unrecorded.
    private var windowEndT: Int64?
    /// Passed keys whose keyUp the tap held: their next press is the ADR 0322 hazard.
    private var heldKeyUps: Set<UInt16> = []
    private var hints = ReadbackHints()
    /// The decision of the last commit since the last boundary (a rule-restored token can be re-opened).
    private var lastCommitDecision: String?

    /// Boundaries the user caused on purpose; any other one with a token open is a finding (e).
    static let intendedReasons: Set<String> = [
        "cursorMoved", "pointerClicked", "shortcut", "forwardDelete", "modeToggled",
    ]
    static let intendedJobs: Set<String> = [
        "navigation", "mouseDown", "commandChord", "returnOrTab", "escape", "modeToggled",
    ]

    mutating func feed(_ event: TraceEvent, into found: inout [Finding]) {
        let line = event.line
        if let pending = pendingKey, line.t != pending.t || (line.type != "engine" && line.type != "boundary") {
            resolvePendingKey()
        }
        context.apply(line)
        // The context lines a `--since` window keeps from before its start carry their old times; the window
        // starts at its first own line, so a key held across that start keeps its grace (PLT-R397A).
        if windowEndT == nil, !TraceStore.contextTypes.contains(line.type) { windowEndT = line.t }
        switch line.type {
        case "start":
            composing = ""
            believed.reset()
            burst = nil
            down = [:]
            windowEndT = line.t
            hints.unseenKeyT = nil
            lastCommitDecision = nil
        case "resume": windowEndT = line.t
        case "key": key(event, into: &found)
        case "engine": engine(event, into: &found)
        case "boundary": boundary(event, into: &found)
        case "readback": readback(event, into: &found)
        case "marker": add(.marker, event, detail: line.src ?? "marker", into: &found)
        case "fallback":
            if let sequence = line.seq {
                let step = (line.from ?? "?") + " -> " + (line.to ?? "?") + " (" + (line.reason ?? "?") + ")"
                fallbacks[sequence, default: []].append(step)
            }
        case "job": job(event, into: &found)
        case "gap":
            if line.reason != "overflow" { believed.reset() }
            windowEndT = line.end ?? line.t
        default: break
        }
    }

    mutating func finish(into found: inout [Finding]) { resolvePendingKey() }

    // MARK: Events

    private mutating func key(_ event: TraceEvent, into found: inout [Finding]) {
        let line = event.line
        if line.isKeyUp { return keyUp(event, into: &found) }
        guard line.isKeyDown else { return }
        if let code = line.kc {
            let reachesApp = line.out == "passed" || line.out == "held"
            if heldKeyUps.remove(code) != nil, reachesApp { noteAfterReplayedKeyUp(line.t) }
            down[code] = line.out ?? "passed"
        }
        lastKeyT = line.t
        if isUndo(line), let edit = lastEditT, line.t - edit <= FindingLimits.undoAfterEdit {
            add(
                .undoAfterEdit, event, detail: "Command+Z " + milliseconds(line.t - edit) + " after an edit",
                into: &found)
        }
        trackBurst(event, into: &found)
        pendingKey = event
        pendingSteps = 0
    }

    private mutating func engine(_ event: TraceEvent, into found: inout [Finding]) {
        let line = event.line
        let key = pendingKey.flatMap { $0.t == line.t ? $0.line : nil }
        pendingSteps += 1
        let isBackspace = key?.kc == TraceKeys.backspace
        if isBackspace, line.changesText, (line.del ?? 0) > 1 || !(line.ins ?? "").isEmpty {
            let detail = "Backspace deleted " + String(line.del ?? 0) + ", inserted " + String((line.ins ?? "").count)
            add(.backspaceEdit, event, detail: detail, into: &found)
        }
        if isBackspace { noteReopenedRestoredToken(event, into: &found) }
        if let decision = line.dec { lastCommitDecision = decision }
        if line.isEdit {
            let deleteCount = line.del ?? 0
            let changesLetters = Self.changesLetters(of: believed, deleteCount: deleteCount, insert: line.ins ?? "")
            believed.delete(deleteCount)
            believed.append(line.ins ?? "", origin: .edit(t: line.t))
            lastEditT = line.t
            if changesLetters && !isBackspace { lastTransformT = line.t }
        }
        if line.act == "passThrough" || line.act == "editThenPassThrough", let key { deliver(key) }
        composing = line.comp ?? ""
    }

    /// A keyUp: a held keyUp of a passed key arms the ADR 0322 hint; a keyUp whose keyDown the trace never showed is
    /// an unseenKey, unless a gap, a pause or the start of reading ended just before (the recorder may not have
    /// written that keyDown).
    private mutating func keyUp(_ event: TraceEvent, into found: inout [Finding]) {
        let line = event.line
        guard let code = line.kc, !TraceKeys.isModifier(code) else { return }
        if let outcome = down.removeValue(forKey: code) {
            if line.out == "held" && outcome == "passed" { heldKeyUps.insert(code) }
            return
        }
        if let end = windowEndT, line.t - end <= FindingLimits.unseenAfterWindow { return }
        hints.unseenKeyT = line.t
        var finding = Finding(
            kind: .unseenKey, t: line.t, eventIndex: event.index, bundle: context.bundle, rule: context.rule,
            detail: "a key went up that the tap never saw go down: the app received a key KeyVi did not see")
        finding.note = "unseenKey: key " + TraceText.hex(code) + " went up without a key down"
        found.append(finding)
    }

    /// (f) A Backspace that re-opens a token a rule restored at its commit (the engine shows it again).
    private mutating func noteReopenedRestoredToken(_ event: TraceEvent, into found: inout [Finding]) {
        guard composing.isEmpty, !(event.line.comp ?? "").isEmpty, let decision = lastCommitDecision,
            decision.hasPrefix("restored")
        else { return }
        lastCommitDecision = nil
        add(.restoreOrReopen, event, detail: "Backspace re-opened a token committed as " + decision, into: &found)
    }

    /// (c) An edit that changed letters of the word (a tone, a mark, a restore), not one that only added letters
    /// (a standalone "ư") or deleted nothing.
    private static func changesLetters(of believed: BelievedText, deleteCount: Int, insert: String) -> Bool {
        guard deleteCount > 0 else { return false }
        guard believed.characters.count >= deleteCount else { return true }
        return String(believed.characters.suffix(deleteCount)) != insert
    }

    /// Kept for the readback hints; bounded so a long trace keeps a fixed amount.
    private mutating func noteAfterReplayedKeyUp(_ t: Int64) {
        if hints.afterReplayedKeyUp.count >= 256 { hints.afterReplayedKeyUp.removeAll() }
        hints.afterReplayedKeyUp.insert(t)
    }

    private mutating func boundary(_ event: TraceEvent, into found: inout [Finding]) {
        let line = event.line
        let reason = line.reason ?? "unknown"
        let intended = Self.intendedReasons.contains(reason) || line.job.map(Self.intendedJobs.contains) == true
        // PLT-R397A: the tap's own unseen-input boundary is explained by the unseenKey finding of its keyUp.
        if !composing.isEmpty && !intended && line.job != "unseenInput" {
            let detail = reason + (line.job.map { " / " + $0 } ?? "") + ", token of " + String(composing.count)
            add(.resetWithOpenToken, event, detail: detail + " characters open", into: &found)
        }
        if line.job == "mouseDown" { burst = nil }
        composing = ""
        believed.reset()
        hints.unseenKeyT = nil
        lastCommitDecision = nil
    }

    private mutating func readback(_ event: TraceEvent, into found: inout [Finding]) {
        readbacks.check(event, believed: &believed, lastKeyT: lastKeyT, context: context, hints: hints, into: &found)
        if event.line.status == "ok" { hints.unseenKeyT = nil }
    }

    private mutating func job(_ event: TraceEvent, into found: inout [Finding]) {
        let line = event.line
        var problems: [String] = []
        if let outcome = line.out, outcome != "executed" { problems.append("outcome " + outcome) }
        if let sequence = line.seq, let steps = fallbacks.removeValue(forKey: sequence) {
            problems += steps.map { "fallback " + $0 }
        }
        if let total = line.totalUs, total > FindingLimits.slowJob {
            problems.append("slow " + milliseconds(Int64(total)))
        }
        let label = "job " + String(line.seq ?? 0) + " " + (line.kind ?? "?") + " " + (line.strat ?? "?")
        if !problems.isEmpty {
            add(.injectionProblem, event, detail: label + ": " + problems.joined(separator: "; "), into: &found)
        }
        switch line.kind {
        case "restore": add(.restoreOrReopen, event, detail: "restore (" + label + ")", into: &found)
        case "reentry": add(.restoreOrReopen, event, detail: "history re-open (" + label + ")", into: &found)
        default: break
        }
    }

    // MARK: Helpers

    /// A key with no engine step reached the app as typed (English mode, paused, a passThrough rule).
    private mutating func resolvePendingKey() {
        defer { pendingKey = nil }
        guard let key = pendingKey, pendingSteps == 0 else { return }
        let outcome = key.line.out ?? "passed"
        guard outcome == "passed" || outcome == "held" else { return }
        deliver(key.line)
    }

    /// What the app does with a key it receives.
    private mutating func deliver(_ key: TraceLine) {
        if key.kc == TraceKeys.backspace {
            if key.isPlainBackspaceDown { believed.delete(1) }  // a word or line deletion is a boundary (PLT-R352)
            return
        }
        guard !key.hasCommandOrControl, key.flags & TraceKeys.option == 0, let character = key.ch,
            !character.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { return }
        believed.append(character, origin: .passedKey(t: key.t))
    }

    /// (c) Three Backspaces within 1.5 s, starting within 2 s of a transform, then retyping within 2 s. Only plain
    /// Backspaces count: Option+Backspace and Command+Backspace delete a word or a line and end the burst.
    private mutating func trackBurst(_ event: TraceEvent, into found: inout [Finding]) {
        let line = event.line
        if line.kc == TraceKeys.backspace && !line.isPlainBackspaceDown {
            burst = nil
            return
        }
        if line.isPlainBackspaceDown {
            if var current = burst, line.t - current.start <= FindingLimits.burstWindow {
                current.count += 1
                current.last = line.t
                burst = current
            } else if let transform = lastTransformT, line.t - transform <= FindingLimits.burstAfterTransform {
                burst = (line.t, line.t, 1, event.index)
            } else {
                burst = nil
            }
            return
        }
        defer { burst = nil }
        guard let current = burst, current.count >= FindingLimits.burstBackspaces, !line.hasCommandOrControl,
            line.ch != nil, line.t - current.last <= FindingLimits.retypeAfterBurst
        else { return }
        found.append(
            Finding(
                kind: .correctionBurst, t: current.start, eventIndex: current.index, bundle: context.bundle,
                rule: context.rule,
                detail: String(current.count) + " Backspaces after a transform, then retyping"))
    }

    private func isUndo(_ line: TraceLine) -> Bool {
        let shift: UInt64 = 0x0002_0000
        guard line.flags & TraceKeys.command != 0, line.flags & (shift | TraceKeys.control | TraceKeys.option) == 0
        else { return false }
        return line.ch.map { $0.lowercased() == "z" } ?? (line.kc == TraceKeys.zKey)
    }

    private func add(_ kind: Finding.Kind, _ event: TraceEvent, detail: String, into found: inout [Finding]) {
        found.append(
            Finding(
                kind: kind, t: event.t, eventIndex: event.index, bundle: context.bundle, rule: context.rule,
                detail: detail))
    }

    private func milliseconds(_ microseconds: Int64) -> String { String(microseconds / 1_000) + " ms" }
}
