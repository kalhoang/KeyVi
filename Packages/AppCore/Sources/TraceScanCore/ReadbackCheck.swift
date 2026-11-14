// SPDX-License-Identifier: GPL-3.0-or-later
//
// Readback findings of the scanner (PLT-R904A, ADR 0007): the field does not end with what KeyVi believes it typed
// (d), explained when exactly one character of KeyVi's view is absent from the field or the field holds exactly
// one character more; and readbacks slower than the threshold. Pa's first dev-recorder day (2026-11-14) had two
// incidents in a WebKit editor where a key the tap passed never reached the field while a readback ran next to it,
// so a dropped key is named together with any readback that was in flight when it went down or started right
// after it. After a mismatch the expected text is taken from the field, so one divergence is one finding. Summary
// details hold names and numbers only; the character itself is in the finding's note, which only `show` prints.
// Since 2026-11-15: app substitutions (smart quotes, the ellipsis, dashes, the double-space period) are not
// mismatches; a dropped key is also found when later edits deleted by count around it, and of several candidates
// the first press of a key after its keyUp was held and replayed is named (ADR 0322); a mismatch after a key the tap
// never saw says so (unseenKey, PLT-R397A).

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

/// What the sequential scan knows that explains a readback: keys pressed right after their own keyUp was held and
/// replayed (ADR 0322, by key-down time) and a key the tap never saw since the last baseline (PLT-R397A).
struct ReadbackHints {
    var afterReplayedKeyUp: Set<Int64> = []
    var unseenKeyT: Int64?
}

enum ReadbackComparison {
    /// Typographic substitutions apps and macOS text substitution make: curly quotes for straight ones, an ellipsis
    /// for three periods, an em or en dash for hyphens, and a period for the first of two spaces. Both texts are
    /// normalised the same way, so text that agrees still agrees.
    static func normalized(_ text: [Character]) -> [Character] {
        var result: [Character] = []
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "\u{2018}", "\u{2019}": result.append("'")
            case "\u{201C}", "\u{201D}": result.append("\"")
            case "\u{2026}": result.append(contentsOf: "...")
            case "\u{2014}": result.append(contentsOf: "--")
            case "\u{2013}": result.append("-")
            default: result.append(character)
            }
        }
        // The double-space period: ". " where two spaces were typed.
        for index in result.indices.dropLast() where result[index] == "." && result[index + 1] == " " {
            result[index] = " "
        }
        return result
    }

    /// The texts agree once app substitutions are undone.
    static func matchesAllowingSubstitutions(_ expected: [Character], _ field: [Character]) -> Bool {
        let normalizedExpected = normalized(expected)
        let normalizedField = normalized(field)
        return matches(Array(normalizedExpected.suffix(FindingLimits.readbackCompare)), normalizedField)
    }

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
        hints: ReadbackHints = ReadbackHints(), into found: inout [Finding]
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
        guard !ReadbackComparison.matchesAllowingSubstitutions(expected, field) else {
            return believed.rebaseline(field)  // the app's own substitution: the field is the new view
        }
        var finding = explain(event, believed: believed, field: field, expected: expected, context: context, hints)
        if let unseen = hints.unseenKeyT {
            finding.detail += "; a key the tap never saw went up " + Self.milliseconds(event.t - unseen) + " before it"
        }
        found.append(finding)
        believed.rebaseline(field)
    }

    private mutating func remember(_ line: TraceLine) {
        guard let window = ReadbackWindow(line) else { return }
        windows.append(window)
        if windows.count > Self.rememberedWindows { windows.removeFirst() }
    }

    /// keyDropped, extraCharacter, or a readbackMismatch with as much of an explanation as the texts give.
    private func explain(
        _ event: TraceEvent, believed: BelievedText, field: [Character], expected: [Character], context: TraceContext,
        _ hints: ReadbackHints
    ) -> Finding {
        let line = event.line
        let readback = (line.reason ?? "?") + " readback"
        let compare = FindingLimits.readbackCompare
        if let dropped = droppedKey(believed: believed, field: field, hints: hints, readback: readback, at: event.t) {
            return Self.finding(.keyDropped, event, context, dropped.detail, note: dropped.note)
        }
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

    /// ADR 0322: the passed keys whose absence alone explains the field, later edits applied by count. Reported only
    /// when the first press of a key after its keyUp was held and replayed is among them (the cause the pipeline no
    /// longer has), or when the simple explanation (one character absent at the end) does not fit: the hole then
    /// sits before a count-based edit.
    private func droppedKey(
        believed: BelievedText, field: [Character], hints: ReadbackHints, readback: String, at readbackT: Int64
    ) -> (detail: String, note: String)? {
        let compare = FindingLimits.readbackCompare
        let candidates = believed.droppedKeyCandidates(limit: 2 * compare) { text in
            let expected = Array(text.suffix(compare))
            return field.count >= expected.count && ReadbackComparison.matches(expected, field)
        }
        guard let last = candidates.last else { return nil }
        let replayed = candidates.last { hints.afterReplayedKeyUp.contains($0.t) }
        let simpleFits = !ReadbackComparison.missing(believed: believed.characters, field: field, compare: compare)
            .isEmpty
        guard replayed != nil || !simpleFits else { return nil }
        let chosen = replayed ?? last
        let ago = Self.milliseconds(readbackT - chosen.t)
        var detail = "a passed key never reached the field (" + readback + "; "
        detail += candidates.count == 1 ? "one passed key fits" : String(candidates.count) + " passed keys fit"
        if replayed != nil {
            detail += ", most likely the first press of a key after its keyUp was held and replayed, ADR 0322"
        }
        detail += "); " + readbackNear(chosen.t)
        let note =
            "keyDropped: \"" + TraceText.visible(String(chosen.character)) + "\" passed " + ago
            + " before the readback, absent from the field"
        return (detail, note)
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

    /// A readback that timed out or one of whose AX calls took longer than the threshold. A line without its
    /// longest call (the first recorder's) is slow only when it timed out.
    static func slowDetail(_ line: TraceLine) -> String? {
        let readback = (line.reason ?? "?") + " readback"
        if line.status == "timedOut" {
            return readback + " timed out" + (line.durUs.map { " after " + milliseconds(Int64($0)) } ?? "")
        }
        guard let longest = line.maxCallUs, longest > FindingLimits.slowReadback else { return nil }
        let total = line.durUs.map { " of " + milliseconds(Int64($0)) } ?? ""
        return readback + ": one AX call took " + milliseconds(Int64(longest)) + total + " (" + (line.status ?? "?")
            + ")"
    }

    private static func finding(
        _ kind: Finding.Kind, _ event: TraceEvent, _ context: TraceContext, _ detail: String, note: String? = nil
    ) -> Finding {
        Finding(
            kind: kind, t: event.t, eventIndex: event.index, bundle: context.bundle, rule: context.rule, detail: detail,
            note: note)
    }

    private static func milliseconds(_ microseconds: Int64) -> String { String(microseconds / 1_000) + " ms" }
}
