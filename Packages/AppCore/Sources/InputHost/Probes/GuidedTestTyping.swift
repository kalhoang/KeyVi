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
    /// Dedicated thread. Never types into a readable field that already holds text.
    func typeAndVerify(_ candidate: GuidedTestCandidate, field: FieldHandle?) -> GuidedTestCandidateResult {
        if let before = readField(field), !before.isEmpty { return .fieldNotEmpty }
        let environment = GuidedTestEnvironment(runner: self)
        var typedAll = true
        for step in GuidedTestCanary.steps where typedAll {
            typedAll = perform(step, candidate: candidate, field: field, in: environment)
        }
        environment.pause(GuidedTestCanary.settle)
        guard let reading = readField(field) else {
            // No readback: the user judges what is on screen, removal follows the answer.
            return .needsHumanAnswer
        }
        let residue = removeText(reading.typed, candidate: candidate, field: field, in: environment)
        guard typedAll, reading.typed == GuidedTestCanary.text, residue == false else {
            return .failedByReadback(residue: residue ?? false)
        }
        return .passedByReadback
    }

    /// After a human answer: removes the canary length (the field cannot be read) and reports residue if a
    /// readback became possible.
    func remove(_ candidate: GuidedTestCandidate, field: FieldHandle?) -> Bool? {
        let environment = GuidedTestEnvironment(runner: self)
        let known = readField(field)?.typed ?? GuidedTestCanary.text
        return removeText(known, candidate: candidate, field: field, in: environment)
    }

    /// Deletes `text` with the candidate's strategy and returns whether anything (letters or placeholder
    /// residue, PLT-R1206) remains before the caret; nil when unreadable.
    private func removeText(
        _ text: String, candidate: GuidedTestCandidate, field: FieldHandle?, in environment: GuidedTestEnvironment
    ) -> Bool? {
        if !text.isEmpty {
            let job = editJob(
                candidate: candidate, field: field, trigger: "a", replaced: text, insertion: "", now: environment.now)
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
            return environment.typeLiteral(character, keyCode: keys.code(character))
        case .edit(let trigger, let replaced, let insertion):
            let job = editJob(
                candidate: candidate, field: field, trigger: trigger, replaced: replaced, insertion: insertion,
                now: environment.now)
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
        now: MonotonicInstant
    ) -> EditJob {
        EditJob(
            sequence: JobSequence(rawValue: 0), generation: FocusGeneration(rawValue: 0), plan: candidate.plan,
            field: field, kind: .compose, deleteCount: replaced.count, deleteUTF16Count: replaced.utf16.count,
            replacedText: replaced, insertion: insertion, keyCodes: JobKeyCodes(trigger: keys.code(trigger)),
            trigger: nil, verifyBeforeApply: false, wordStartedNearFocusChange: false, createdAt: now, isProbe: true)
    }

    /// The field before the caret (or before a selected suggestion), at most 64 UTF-16 units (PLT-R343); nil
    /// when the field cannot be read.
    func readField(_ field: FieldHandle?) -> FieldReading? {
        guard let field else { return nil }
        guard case .success(let range) = fieldAccess.selectedRange(field, timeout: GuidedTestCanary.axTimeout) else {
            return nil
        }
        let length = min(max(range.location, 0), GuidedTestCanary.maximumAXTextUnits)
        guard length > 0 else { return FieldReading(typed: "", selectionLength: range.length) }
        let window = TextRange(location: range.location - length, length: length)
        guard case .success(let text) = fieldAccess.text(field, in: window, timeout: GuidedTestCanary.axTimeout) else {
            return nil
        }
        return FieldReading(typed: text, selectionLength: range.length)
    }
}

/// What AX shows of the field: the text before the caret and the length of the selection after it (an
/// inline-completion suggestion, 4.3).
struct FieldReading: Sendable, Hashable {
    var typed: String
    var selectionLength: Int
    var isEmpty: Bool { typed.isEmpty && selectionLength == 0 }
}

/// The runner's injection environment: probe-kind marker on every event, absolute-deadline pacing on the
/// runner's clock, no pasteboard (candidates never paste) and no held events to release.
final class GuidedTestEnvironment: InjectionEnvironment {
    private let runner: GuidedTestRunner

    init(runner: GuidedTestRunner) { self.runner = runner }

    var now: MonotonicInstant { runner.clock.now() }
    func sleep(until deadline: MonotonicInstant) { runner.clock.sleep(until: deadline) }

    func post(_ event: SyntheticKeyEvent) throws(PostError) -> UInt32 {
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
