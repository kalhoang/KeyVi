// SPDX-License-Identifier: GPL-3.0-or-later
//
// The tap's side of the dev recorder (PLT-R904A, ADR 0007). Debug configuration only. Every engine call with the
// token's display after it, every hard boundary with its reasons, the marker chord, and the time of every key or
// click down (the field readback reads only in a pause of that input). Only when the recorder is active and the
// key itself may be recorded (`capturingThisKey`, the PLT-R905 secure rules); one atomic load otherwise. Pushes
// are lock-free into fixed rings and copy values the callback already holds (PLT-R304, PLT-R305). The recorder
// observes: apart from consuming its own marker chord it never changes a verdict.

#if DEV_RECORDER
public import AppModel
internal import Diagnostics
internal import Injection
internal import RealtimeSupport
internal import VietnameseEngine

/// PLT-R904A marker chord, consumed in dev builds only: Control+Option+Command+Semicolon. Control+Option+Command+B,
/// the first idea, is VoiceOver's documented "find next bold text" (VO-Command-B); VoiceOver leaves Semicolon
/// unmapped at that level and macOS documents no shortcut on it.
public enum DevMarkerChord {
    /// kVK_ANSI_Semicolon.
    public static let keyCode = KeyCode(rawValue: 0x29)
    public static let modifiers: ModifierKeys = [.control, .option, .command]
    public static var binding: HotkeyBinding { .keyCombo(modifiers: modifiers, keyCode: keyCode) }

    /// Exactly Control, Option and Command (either side), no Shift.
    @inline(__always)
    static func matches(_ event: RawKeyEvent) -> Bool {
        guard event.kind == .keyDown, event.keyCode == keyCode else { return false }
        let held = EventFlags.modifierKeys(event.flags).subtracting([.rightCommand, .rightOption])
        return held == modifiers
    }
}

/// Up to two engine calls for one key: a restore binding that edited nothing, then the key itself. Fixed size, so
/// the tap never grows an array.
struct DevEngineSteps {
    var first: DevEngineStep?
    var second: DevEngineStep?

    mutating func append(_ step: DevEngineStep) {
        if first == nil { first = step } else { second = step }
    }
}

/// A boundary within this long of the current event's start belongs to that event (reconciliation runs before the
/// key's engine call); later ones (tap re-enable, fail-open) are stamped when they happen.
private let devEventWindowNanoseconds: UInt64 = 20_000_000

extension KeyPipeline {
    /// The recorder, when it records right now (one atomic load).
    @inline(__always)
    var activeDevRecorder: DevRecorder? {
        guard let dev = context.capture?.dev, dev.isActive else { return nil }
        return dev
    }

    /// Keeps the engine's output for the key line; true when the dev recorder took it (the PLT-R905 edit is kept
    /// alongside, so a running time-boxed capture writes exactly what it always wrote).
    func noteDevEngineStep(_ output: EngineOutput) -> Bool {
        guard capturingThisKey, activeDevRecorder != nil else { return false }
        var capture = engineCapture ?? EngineCapture(deleteCount: 0, insert: "", isEdit: false)
        switch output.action {
        case .passThrough:
            capture.devSteps.append(
                DevEngineStep(
                    action: .passThrough, deleteCount: 0, insert: "", composing: output.composingText,
                    decision: output.decision, revision: output.revision, at: .zero))
        case .edit(let edit, let thenPassThrough):
            capture.devSteps.append(
                DevEngineStep(
                    action: thenPassThrough ? .editThenPassThrough : .edit, deleteCount: edit.deleteCount,
                    insert: edit.insert, composing: output.composingText, decision: output.decision,
                    revision: output.revision, at: .zero))
            if edit.deleteCount > 0 || !edit.insert.isEmpty {
                capture.deleteCount = edit.deleteCount
                capture.insert = edit.insert
                capture.isEdit = true
            }
        }
        engineCapture = capture
        return true
    }

    /// After the key line: the engine steps of the key, and the readbacks they call for (a Backspace that edited,
    /// a committed word).
    func recordDevEngineSteps(_ steps: DevEngineSteps, keyCode: KeyCode, at now: MonotonicInstant) {
        guard let dev = activeDevRecorder else { return }
        if var step = steps.first {
            step.at = now
            recordDevEngineStep(step, keyCode: keyCode, dev: dev)
        }
        if var step = steps.second {
            step.at = now
            recordDevEngineStep(step, keyCode: keyCode, dev: dev)
        }
    }

    private func recordDevEngineStep(_ step: DevEngineStep, keyCode: KeyCode, dev: DevRecorder) {
        let decision = step.decision != nil
        let backspaceEdit = step.action != .passThrough && VirtualKeyGroup.of(keyCode) == .backspace
        dev.pushTap(.engine(step))
        if decision { dev.requestAttention(.commit) }
        if backspaceEdit { dev.requestAttention(.backspaceEdit) }
    }

    /// A PLT-R905 record into the shared ring; a full ring is counted for the dev recorder's gap line. A key down or
    /// a click also tells the recorder when input last went down: its readback waits for a pause (PLT-R904A).
    @inline(__always)
    func pushCapture(_ record: consuming CaptureRecord, to capture: CaptureController) {
        if let instant = record.inputDownAt { capture.dev.noteInputDown(at: instant) }
        if !capture.tapRecords.push(record) { capture.dev.noteOverflow() }
    }

    /// PLT-R340 boundary with its reset and job reasons (names only, no content).
    func recordDevBoundary(_ reason: ResetReason, job: BoundaryReason?) {
        guard let dev = activeDevRecorder else { return }
        dev.pushTap(.boundary(reason: reason, job: job, at: devEventInstant()))
    }

    /// The marker chord (PLT-R904A): consumed like a hotkey (its keyUp too), a marker record when the key may be
    /// recorded, and a confirmation request. Nil for every other key. The chord notes its own key down before the
    /// request (its key record notes it again later in this callback): the marker's read waits for the pause after
    /// the chord (ADR 0007 decision 10) even when the attention queue runs before the key record is pushed.
    func devMarkerVerdict(_ event: RawKeyEvent, now: MonotonicInstant) -> TapVerdict? {
        guard DevMarkerChord.matches(event), let dev = context.capture?.dev, dev.isStarted else { return nil }
        if !event.autorepeat, capturingThisKey, dev.isActive {
            dev.pushTap(.marker(source: .chord, at: now))
            dev.noteInputDown(at: now)
            dev.requestAttention(.marker)
        }
        return consumeAsHotkey(event)
    }

    /// The start of the event being processed, when the boundary belongs to it.
    private func devEventInstant() -> MonotonicInstant {
        let now = clock.now()
        var start = keyState.lastKeyboardEventAt ?? .zero
        if let click = keyState.lastPointerDownAt, click > start { start = click }
        return start <= now && now.nanoseconds(since: start) <= devEventWindowNanoseconds ? start : now
    }
}

extension CaptureRecord {
    /// The time of a key down or a click (a borrow, so a consuming push can still move the record).
    fileprivate var inputDownAt: MonotonicInstant? {
        guard case .key(let key) = self, key.kind == .keyDown || key.kind == .mouseDown else { return nil }
        return key.at
    }
}
#endif
