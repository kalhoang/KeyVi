// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The guided test's canary (PLT-R1205 step 3): literal keys and the engine's edits for "đá â" typed with one
// candidate strategy, AX readback (PLT-R410 `axReadback`, bounded per PLT-R343) and removal with the same
// strategy. The runner plays the engine's part itself, so every candidate is exercised exactly, whatever the
// live rule says; the host passes its probe-kind events unchanged while the test runs (the App pauses
// transformation around it). Content stays in memory: nothing here is logged.

public import AppModel
internal import Foundation
public import Injection
internal import RealtimeSupport

/// Key codes of the canary keys in the current layout (PLT-R405), else the US key positions.
struct GuidedTestKeys: Sendable {
    /// kVK_ANSI_D, kVK_ANSI_A, kVK_ANSI_S, kVK_Space (Carbon `Events.h`).
    static let usPositions: [Character: UInt16] = ["d": 0x02, "a": 0x00, "s": 0x01, " ": 0x31]
    private let codes: [Character: KeyCode]

    init(layout: LayoutTable?) {
        var codes: [Character: KeyCode] = [:]
        for (character, position) in Self.usPositions {
            codes[character] = layout?.keyCode(producing: character) ?? KeyCode(rawValue: position)
        }
        self.codes = codes
    }

    func code(_ character: Character) -> KeyCode { codes[character] ?? KeyCode(rawValue: 0) }
}

/// "đá â" as Telex keys `d d a s space a a`: literal keys reach the field as typed, triggers become the edits
/// the engine would ask for (delete the replaced grapheme, insert the composed one).
enum GuidedTestCanary {
    enum Step: Sendable, Hashable {
        case key(Character)
        case edit(trigger: Character, replaced: String, insertion: String)
    }

    static let text = "đá â"
    static let steps: [Step] = [
        .key("d"), .edit(trigger: "d", replaced: "d", insertion: "đ"), .key("a"),
        .edit(trigger: "s", replaced: "a", insertion: "á"), .key(" "), .key("a"),
        .edit(trigger: "a", replaced: "a", insertion: "â"),
    ]
    /// Pause between two canary steps, so the field handles each one like typing.
    static let stepInterval: Duration = .milliseconds(30)
    /// Wait after the last step before reading back.
    static let settle: Duration = .milliseconds(150)
    /// Bounded AX calls (PLT-R342).
    static let axTimeout: Duration = .milliseconds(100)
    /// PLT-R343: AX string reads are bounded to 64 UTF-16 units.
    static let maximumAXTextUnits = 64
}

extension GuidedTestRunner {
    /// Dedicated thread. Never types into a readable field that already holds text. The stop signal's focus
    /// check runs before every step and before the removal, its flag before every event: if focus moves to
    /// another field mid-candidate, the remaining keys and the removal backspaces are never posted
    /// (PLT-R1205 step 3, PLT-R387).
    func typeAndVerify(_ candidate: GuidedTestCandidate, field: FieldHandle?, stop: ProbeStopSignal)
        -> GuidedTestCandidateResult
    {
        guard stop.shouldContinue() else { return .stopped }
        if let before = readField(field), !before.isEmpty { return .fieldNotEmpty }
        let environment = GuidedTestEnvironment(runner: self, stop: stop)
        var typedAll = true
        for step in GuidedTestCanary.steps where typedAll {
            guard stop.shouldContinue() else { return .stopped }
            typedAll = perform(step, candidate: candidate, field: field, in: environment)
        }
        guard !stop.isStopped else { return .stopped }
        environment.pause(GuidedTestCanary.settle)
        guard let reading = readField(field) else {
            // No readback: the user judges what is on screen, removal follows the answer.
            return .needsHumanAnswer
        }
        guard stop.shouldContinue() else { return .stopped }
        let residue = removeText(reading.typed, candidate: candidate, field: field, in: environment)
        guard !stop.isStopped else { return .stopped }
        guard typedAll, reading.typed == GuidedTestCanary.text, residue == false else {
            return .failedByReadback(residue: residue ?? false)
        }
        return .passedByReadback
    }

    /// After a human answer: removes the canary length (the field cannot be read) and reports residue if a
    /// readback became possible. Nothing is removed once `stop` fired or focus moved (nil).
    func remove(_ candidate: GuidedTestCandidate, field: FieldHandle?, stop: ProbeStopSignal) -> Bool? {
        guard stop.shouldContinue() else { return nil }
        let environment = GuidedTestEnvironment(runner: self, stop: stop)
        let known = readField(field)?.typed ?? GuidedTestCanary.text
        return removeText(known, candidate: candidate, field: field, in: environment)
    }

    /// Deletes `text` with the candidate's strategy and returns whether anything (letters or placeholder
    /// residue, PLT-R1206) remains around the caret; nil when unreadable.
    private func removeText(
        _ text: String, candidate: GuidedTestCandidate, field: FieldHandle?, in environment: GuidedTestEnvironment
    ) -> Bool? {
        if !text.isEmpty {
            let job = editJob(
                candidate: candidate, field: field, trigger: "a", replaced: text, insertion: "", in: environment)
            _ = execute(job, candidate: candidate, in: environment)
            environment.pause(GuidedTestCanary.settle)
        }
        return readField(field).map { !$0.isEmpty }
    }

    private func perform(
        _ step: GuidedTestCanary.Step, candidate: GuidedTestCandidate, field: FieldHandle?,
        in environment: GuidedTestEnvironment
    ) -> Bool {
        defer { environment.pause(GuidedTestCanary.stepInterval) }
        switch step {
        case .key(let character):
            return environment.typeLiteral(character, keyCode: environment.keys.code(character))
        case .edit(let trigger, let replaced, let insertion):
            let job = editJob(
                candidate: candidate, field: field, trigger: trigger, replaced: replaced, insertion: insertion,
                in: environment)
            return execute(job, candidate: candidate, in: environment)
        }
    }

    private func execute(_ job: EditJob, candidate: GuidedTestCandidate, in environment: GuidedTestEnvironment)
        -> Bool
    {
        if case .completed = StrategyCatalog.executor(for: candidate.strategy).execute(job, in: environment) {
            return true
        }
        return false
    }

    private func editJob(
        candidate: GuidedTestCandidate, field: FieldHandle?, trigger: Character, replaced: String, insertion: String,
        in environment: GuidedTestEnvironment
    ) -> EditJob {
        EditJob(
            sequence: JobSequence(rawValue: 0), generation: FocusGeneration(rawValue: 0), plan: candidate.plan,
            field: field, kind: .compose, deleteCount: replaced.count, deleteUTF16Count: replaced.utf16.count,
            replacedText: replaced, insertion: insertion,
            keyCodes: JobKeyCodes(trigger: environment.keys.code(trigger)), trigger: nil, verifyBeforeApply: false,
            wordStartedNearFocusChange: false, createdAt: environment.now, isProbe: true)
    }

    /// The field around the caret: at most 64 UTF-16 units before it (the typed text, PLT-R343), the length of
    /// the selection after it (an inline-completion suggestion, 4.3) and whether any text follows the caret
    /// (one more bounded read). Nil when the field cannot be read.
    func readField(_ field: FieldHandle?) -> FieldReading? {
        guard let field else { return nil }
        guard case .success(let range) = fieldAccess.selectedRange(field, timeout: GuidedTestCanary.axTimeout) else {
            return nil
        }
        let caret = max(range.location, 0)
        let length = min(caret, GuidedTestCanary.maximumAXTextUnits)
        var typed = ""
        if length > 0 {
            let window = TextRange(location: caret - length, length: length)
            guard case .success(let text) = fieldAccess.text(field, in: window, timeout: GuidedTestCanary.axTimeout)
            else { return nil }
            typed = text
        }
        let afterStart = caret + max(range.length, 0)
        let after = TextRange(location: afterStart, length: GuidedTestCanary.maximumAXTextUnits)
        let trailing = fieldAccess.text(field, in: after, timeout: GuidedTestCanary.axTimeout)
        // A field that cannot answer the read after the caret is judged on what precedes it.
        let hasTextAfter = if case .success(let text) = trailing { !text.isEmpty } else { false }
        return FieldReading(typed: typed, selectionLength: range.length, hasTextAfterCaret: hasTextAfter)
    }
}

/// What AX shows of the field: the text before the caret, the length of the selection after it (an
/// inline-completion suggestion, 4.3) and whether text follows the selection.
struct FieldReading: Sendable, Hashable {
    var typed: String
    var selectionLength: Int
    var hasTextAfterCaret = false
    var isEmpty: Bool { typed.isEmpty && selectionLength == 0 && !hasTextAfterCaret }
}

/// The runner's injection environment: probe-kind marker on every event, absolute-deadline pacing on the
/// runner's clock, no pasteboard (candidates never paste) and no held events to release. Once the stop signal
/// is set every post fails before reaching the poster, so the executor ends at its next event.
final class GuidedTestEnvironment: InjectionEnvironment {
    private let runner: GuidedTestRunner
    private let stop: ProbeStopSignal
    /// Resolved once per run or removal from the layout current at that moment (PLT-R405).
    let keys: GuidedTestKeys

    init(runner: GuidedTestRunner, stop: ProbeStopSignal) {
        self.runner = runner
        self.stop = stop
        keys = GuidedTestKeys(layout: runner.currentLayout())
    }

    var now: MonotonicInstant { runner.clock.now() }
    func sleep(until deadline: MonotonicInstant) { runner.clock.sleep(until: deadline) }

    func post(_ event: SyntheticKeyEvent) throws(PostError) -> UInt32 {
        // `PostError` has a single case; the executor treats it as "posting failed" and stops at once.
        guard !stop.isStopped else { throw .eventCreationFailed }
        let sequence = runner.sequence.next()
        try runner.poster.post(event, userData: runner.marker.userData(sequence: sequence, probe: true))
        return sequence
    }

    func releaseHeldEvents() {}
    var fieldAccess: any FocusedFieldAccess { runner.fieldAccess }
    var pasteboard: any PasteboardAccess { UnavailablePasteboard() }

    func pause(_ duration: Duration) {
        sleep(until: now.advanced(byMicroseconds: LatencyProbeMath.microseconds(duration)))
    }

    /// One keyDown and keyUp carrying the character, like a key the user typed.
    func typeLiteral(_ character: Character, keyCode: KeyCode) -> Bool {
        let unicode = InlineUTF16(String(character)) ?? .empty
        do {
            _ = try post(SyntheticKeyEvent(keyCode: keyCode, isKeyDown: true, flags: 0, unicode: unicode))
            _ = try post(SyntheticKeyEvent(keyCode: keyCode, isKeyDown: false, flags: 0, unicode: unicode))
            return true
        } catch {
            return false
        }
    }
}

/// Candidates never use `paste`; a strategy that asks anyway sees an unusable pasteboard and fails before
/// posting.
struct UnavailablePasteboard: PasteboardAccess {
    var changeCount: Int { 0 }
    func snapshot(limits: PasteboardLimits) throws(PasteboardError) -> PasteboardSnapshot { throw .unreadableItem }
    func writeTransient(_ text: String) throws(PasteboardError) -> Int { throw .writeFailed }
    func restore(_ snapshot: PasteboardSnapshot) throws(PasteboardError) { throw .writeFailed }
}
