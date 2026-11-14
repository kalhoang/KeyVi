// SPDX-License-Identifier: GPL-3.0-or-later
//
// Readback findings of the scanner (PLT-R904A, ADR 0007): the field does not end with what KeyVi believes it typed
// (d), explained when exactly one character of KeyVi's view is absent from the field or the field holds exactly
// one character more; and readbacks slower than the threshold. Pa's first dev-recorder day (2026-11-14) had two
// incidents in a WebKit editor where a key the tap passed never reached the field while a readback ran next to it,
// so a dropped key is named together with any readback that was in flight when it went down or started right
// after it. After a mismatch the expected text is taken from the field, so one divergence is one finding. Summary
// details hold names and numbers only; the character itself is in the finding's note, which only `show` prints.

internal import Diagnostics
internal import Foundation

/// When a readback's AX calls ran: from its start for its recorded duration.
struct ReadbackWindow {
    var start: Int64
    var end: Int64
    /// False for the first recorder's lines (format version 1), which have no duration.
    var measured: Bool

    /// Readbacks that made AX calls: any with a duration, and the statuses only an AX call can give.
    init?(_ line: TraceLine) {
        let called = line.durUs != nil || ["ok", "timedOut", "failed"].contains(line.status ?? "")
        guard called else { return nil }
        start = line.t
        end = line.t + Int64(line.durUs ?? 0)
        measured = line.durUs != nil
    }
}

enum ReadbackComparison {
    /// The field ends with the expected text (or, when the field holds fewer characters, the expected text ends
    /// with the field's).
    static func matches(_ expected: [Character], _ field: [Character]) -> Bool {
        expected.count <= field.count
            ? field.suffix(expected.count).elementsEqual(expected) : expected.suffix(field.count).elementsEqual(field)
    }

    /// Indices of KeyVi's characters whose absence makes the field agree, compared over a full `compare` window.
    /// Several indices only within one run of equal characters.
    static func missing(believed: [Character], field: [Character], compare: Int) -> [Int] {
        believed.indices.suffix(compare).filter { index in
            var candidate = believed
            candidate.remove(at: index)
            let expected = Array(candidate.suffix(compare))
            return field.count >= expected.count && matches(expected, field)
        }
    }

    /// Index of a field character whose presence alone keeps the field from agreeing.
    static func extra(expected: [Character], field: [Character], compare: Int) -> Int? {
        field.indices.suffix(compare + 1).reversed().first { index in
            var candidate = field
            candidate.remove(at: index)
            return candidate.count >= expected.count && matches(expected, candidate)
        }
    }
}

/// The readback part of the sequential scan: windows of recent readbacks, the comparison and its explanation.
struct ReadbackCheck {
    /// Readbacks remembered for "was one in flight when the key went down".
    static let rememberedWindows = 64
    private var windows: [ReadbackWindow] = []

    /// One readback line. `lastKeyT`: the last key down before it.
    mutating func check(
        _ event: TraceEvent, believed: inout BelievedText, lastKeyT: Int64?, context: TraceContext,
        into found: inout [Finding]
    ) {
        let line = event.line
        remember(line)
        if let slow = Self.slowDetail(line) { found.append(Self.finding(.slowReadback, event, context, slow)) }
        // A selection, a read a key overlapped or a read right after a key may show the field half way through it.
        guard line.status == "ok", let text = line.text, (line.selLen ?? 0) == 0, line.overlap != true,
            lastKeyT.map({ line.t - $0 >= FindingLimits.readbackAfterKey }) ?? true
        else { return }
        let field = Array(text.precomposedStringWithCanonicalMapping)
        guard believed.known else { return believed.rebaseline(field) }
        guard !believed.isEmpty else { return }
        let expected = Array(believed.characters.suffix(FindingLimits.readbackCompare))
        guard !ReadbackComparison.matches(expected, field) else { return }
        found.append(explain(event, believed: believed, field: field, expected: expected, context: context))
        believed.rebaseline(field)
    }

    private mutating func remember(_ line: TraceLine) {
        guard let window = ReadbackWindow(line) else { return }
        windows.append(window)
        if windows.count > Self.rememberedWindows { windows.removeFirst() }
    }

    /// keyDropped, extraCharacter, or a readbackMismatch with as much of an explanation as the texts give.
    private func explain(
        _ event: TraceEvent, believed: BelievedText, field: [Character], expected: [Character], context: TraceContext
    ) -> Finding {
        let line = event.line
        let readback = (line.reason ?? "?") + " readback"
        let compare = FindingLimits.readbackCompare
        let missing = ReadbackComparison.missing(believed: believed.characters, field: field, compare: compare)
        if let index = choose(missing, origins: believed.origins) {
            return missingFinding(
                event, character: believed.characters[index], origin: believed.origins[index], readback: readback,
                context: context)
        }
        if let index = ReadbackComparison.extra(expected: expected, field: field, compare: compare) {
            let detail = "the field holds one character KeyVi did not type (" + readback + ")"
            var finding = Self.finding(.extraCharacter, event, context, detail)
            let visible = TraceText.visible(String(field[index]))
            finding.note = "extraCharacter: \"" + visible + "\" in the field, not typed by KeyVi"
            return finding
        }
        let detail =
            "field does not end with KeyVi's last " + String(expected.count) + " characters ("
            + (line.reason ?? "readback") + ")"
        return Self.finding(.readbackMismatch, event, context, detail)
    }

    private func missingFinding(
        _ event: TraceEvent, character: Character, origin: CharacterOrigin, readback: String, context: TraceContext
    ) -> Finding {
        let visible = "\"" + TraceText.visible(String(character)) + "\""
        let t = event.t
        switch origin {
        case .passedKey(let keyT):
            let ago = Self.milliseconds(t - keyT)
            let detail =
                "a passed key is absent from the field: it went down " + ago + " before this " + readback + "; "
                + readbackNear(keyT)
            var finding = Self.finding(.keyDropped, event, context, detail)
            finding.note = "keyDropped: " + visible + " passed at -" + ago + ", absent from the field"
            return finding
        case .edit(let editT):
            let ago = Self.milliseconds(t - editT)
            let detail =
                "one character of KeyVi's edit " + ago + " before this " + readback + " is absent from the field"
            var finding = Self.finding(.readbackMismatch, event, context, detail)
            finding.note = "missing: " + visible + " inserted by KeyVi at -" + ago
            return finding
        case .field:
            var finding = Self.finding(
                .readbackMismatch, event, context, "one character is absent from the field (" + readback + ")")
            finding.note = "missing: " + visible
            return finding
        }
    }

    /// Of equally good candidates (one run of equal characters), a passed key a readback was near, then the last
    /// passed key, then the last one.
    private func choose(_ indices: [Int], origins: [CharacterOrigin]) -> Int? {
        let keys = indices.filter { if case .passedKey = origins[$0] { true } else { false } }
        let near = keys.last { index in
            guard case .passedKey(let t) = origins[index] else { return false }
            return nearestReadback(t) != nil
        }
        return near ?? keys.last ?? indices.last
    }

    /// Whether a readback touched the field while the key at `keyT` was on its way to the app.
    private func readbackNear(_ keyT: Int64) -> String {
        nearestReadback(keyT) ?? ("no readback within " + Self.milliseconds(FindingLimits.deliveryWindow) + " of it")
    }

    private func nearestReadback(_ keyT: Int64) -> String? {
        if windows.contains(where: { $0.measured && $0.start <= keyT && keyT <= $0.end }) {
            return "a readback was in flight when it went down"
        }
        if let window = windows.first(where: { $0.start > keyT && $0.start - keyT <= FindingLimits.deliveryWindow }) {
            return "a readback started " + Self.milliseconds(window.start - keyT) + " after it went down"
        }
        if let window = windows.last(where: {
            !$0.measured && $0.start <= keyT && keyT - $0.start <= FindingLimits.unmeasuredReadback
        }) {
            return "a readback started " + Self.milliseconds(keyT - window.start)
                + " before it went down (its duration was not recorded)"
        }
        return nil
    }

    /// A readback that timed out or whose AX calls took longer than the threshold.
    static func slowDetail(_ line: TraceLine) -> String? {
        let readback = (line.reason ?? "?") + " readback"
        if line.status == "timedOut" {
            return readback + " timed out" + (line.durUs.map { " after " + milliseconds(Int64($0)) } ?? "")
        }
        guard let duration = line.durUs, duration > FindingLimits.slowReadback else { return nil }
        return readback + " took " + milliseconds(Int64(duration)) + " (" + (line.status ?? "?") + ")"
    }

    private static func finding(
        _ kind: Finding.Kind, _ event: TraceEvent, _ context: TraceContext, _ detail: String
    ) -> Finding {
        Finding(
            kind: kind, t: event.t, eventIndex: event.index, bundle: context.bundle, rule: context.rule, detail: detail)
    }

    private static func milliseconds(_ microseconds: Int64) -> String { String(microseconds / 1_000) + " ms" }
}
