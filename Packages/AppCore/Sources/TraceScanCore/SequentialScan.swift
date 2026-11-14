// SPDX-License-Identifier: GPL-3.0-or-later
//
// One pass over a dev trace in time order (PLT-R904A) for findings a to g and i. It follows the token the engine
// shows (`comp` of the last engine step) and KeyVi's view of the text it produced since the last boundary, so a
// boundary can say whether a token was open and a readback can be compared with what KeyVi believes it typed.

internal import Foundation

/// The text KeyVi produced since the last boundary, as the engine and the passed keys say. Unknown once a
/// Backspace reaches past it (the field then holds text KeyVi did not see typed).
struct BelievedText {
    private(set) var text = ""
    private(set) var known = true

    mutating func reset() {
        text = ""
        known = true
    }

    mutating func delete(_ count: Int) {
        guard count > 0 else { return }
        if text.count >= count {
            text.removeLast(count)
        } else {
            text = ""
            known = false
        }
    }

    mutating func append(_ addition: String) {
        text += addition
        if text.count > 256 { text = String(text.suffix(128)) }
    }
}

struct SequentialScan {
    private var context = TraceContext()
    private var composing = ""
    private var believed = BelievedText()
    private var pendingKey: TraceEvent?
    private var pendingSteps = 0
    private var lastKeyT: Int64?
    private var lastTransformT: Int64?
    private var lastEditT: Int64?
    private var burst: (start: Int64, last: Int64, count: Int, index: Int)?
    private var fallbacks: [UInt64: [String]] = [:]

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
        switch line.type {
        case "start":
            composing = ""
            believed.reset()
            burst = nil
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
        default: break
        }
    }

    mutating func finish(into found: inout [Finding]) { resolvePendingKey() }

    // MARK: Events

    private mutating func key(_ event: TraceEvent, into found: inout [Finding]) {
        let line = event.line
        guard line.isKeyDown else { return }
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
        if line.isEdit {
            believed.delete(line.del ?? 0)
            believed.append(line.ins ?? "")
            lastEditT = line.t
            if line.changesText && !isBackspace { lastTransformT = line.t }
        }
        if line.act == "passThrough" || line.act == "editThenPassThrough", let key { deliver(key) }
        composing = line.comp ?? ""
    }

    private mutating func boundary(_ event: TraceEvent, into found: inout [Finding]) {
        let line = event.line
        let reason = line.reason ?? "unknown"
        let intended = Self.intendedReasons.contains(reason) || line.job.map(Self.intendedJobs.contains) == true
        if !composing.isEmpty && !intended {
            let detail = reason + (line.job.map { " / " + $0 } ?? "") + ", token of " + String(composing.count)
            add(.resetWithOpenToken, event, detail: detail + " characters open", into: &found)
        }
        if line.job == "mouseDown" { burst = nil }
        composing = ""
        believed.reset()
    }

    private mutating func readback(_ event: TraceEvent, into found: inout [Finding]) {
        let line = event.line
        guard line.status == "ok", let field = line.text, (line.selLen ?? 0) == 0, believed.known,
            !believed.text.isEmpty, lastKeyT.map({ line.t - $0 >= 100_000 }) ?? true
        else { return }
        let expected = String(believed.text.suffix(FindingLimits.readbackCompare)).precomposedStringWithCanonicalMapping
        let shown = field.precomposedStringWithCanonicalMapping
        let matches = expected.count <= shown.count ? shown.hasSuffix(expected) : expected.hasSuffix(shown)
        guard !matches else { return }
        let detail =
            "field does not end with KeyVi's last " + String(expected.count) + " characters ("
            + (line.reason ?? "readback") + ")"
        add(.readbackMismatch, event, detail: detail, into: &found)
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
            believed.delete(1)
            return
        }
        guard !key.hasCommandOrControl, key.flags & TraceKeys.option == 0, let character = key.ch,
            !character.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { return }
        believed.append(character)
    }

    /// (c) Three Backspaces within 1.5 s, starting within 2 s of a transform, then retyping within 2 s.
    private mutating func trackBurst(_ event: TraceEvent, into found: inout [Finding]) {
        let line = event.line
        if line.kc == TraceKeys.backspace {
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
