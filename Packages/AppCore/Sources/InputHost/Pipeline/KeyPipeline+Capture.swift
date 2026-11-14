// SPDX-License-Identifier: GPL-3.0-or-later
//
// Typing-trace records from the tap (PLT-R905, PRD-R46, D26): every physical key with its keycode, flags, layout
// character and outcome, and the engine's decision for it. Only while the user's capture runs; never while
// secure input is on or a secure field has focus, decided from the tap's own snapshots so keys typed before
// the main thread opened the capture gap never enter the ring (PLT-R387, PLT-R398A, PLT-R901). One atomic
// load when no capture runs; while one runs, lock-free pushes of values the callback already holds.

internal import AppModel
internal import Diagnostics
internal import RealtimeSupport
internal import VietnameseEngine

/// The engine's edit for the key being processed, kept until its key record is pushed (one callback only).
struct EngineCapture {
    var deleteCount: Int
    var insert: String
    #if DEV_RECORDER
    /// PLT-R904A: every engine call of the key for the dev recorder (two when a restore binding asked first).
    var devSteps = DevEngineSteps()
    /// The PLT-R905 engine line: an edit that changes something.
    var isEdit = true
    #endif
}

extension KeyPipeline {
    /// A capture is recording and nothing secure has focus.
    func captureAllowed(focus: FocusSnapshot, secureInput: SecureInputSnapshot) -> Bool {
        guard let capture = context.capture, capture.isRecording else { return false }
        if focus.field.secure || focus.pause == .secureField { return false }
        return !(secureInput.enabled && seen.secureResumedGeneration != secureInput.generation)
    }

    /// Step 8 output worth a trace line: an edit that changes something.
    func noteEngineCapture(_ output: EngineOutput) {
        #if DEV_RECORDER
        if noteDevEngineStep(output) { return }
        #endif
        guard capturingThisKey, case .edit(let edit, _) = output.action, edit.deleteCount > 0 || !edit.insert.isEmpty
        else { return }
        engineCapture = EngineCapture(deleteCount: edit.deleteCount, insert: edit.insert)
    }

    /// The key line, then the engine line of the same key.
    func recordKeyCapture(_ event: RawKeyEvent, table: LayoutTable?, at now: MonotonicInstant) {
        defer { engineCapture = nil }
        guard let capture = context.capture, let outcome, let kind = Self.captureKind(event.kind) else { return }
        let record = KeyCaptureRecord(
            kind: kind, keyCode: event.keyCode.rawValue, flags: event.flags,
            character: Self.layoutCharacter(event, table: table), outcome: Self.captureOutcome(outcome), at: now)
        #if DEV_RECORDER
        pushCapture(.key(record), to: capture)
        if let engine = engineCapture {
            if engine.isEdit {
                pushCapture(.engine(deleteCount: engine.deleteCount, insert: engine.insert, at: now), to: capture)
            }
            recordDevEngineSteps(engine.devSteps, keyCode: event.keyCode, at: now)
        }
        #else
        _ = capture.tapRecords.push(.key(record))
        if let engine = engineCapture {
            _ = capture.tapRecords.push(.engine(deleteCount: engine.deleteCount, insert: engine.insert, at: now))
        }
        #endif
    }

    /// PLT-R905: a click is part of the trace (it moves the caret and ends the composition).
    func recordPointerCapture(at now: MonotonicInstant) {
        guard let capture = context.capture, capture.isRecording else { return }
        let allowed = context.snapshots.readAll { _, focus, _, secureInput, _ in
            captureAllowed(focus: focus, secureInput: secureInput)
        }
        guard allowed else { return }
        let record = KeyCaptureRecord(
            kind: .mouseDown, keyCode: 0, flags: 0, character: .empty, outcome: .passed, at: now)
        #if DEV_RECORDER
        pushCapture(.key(record), to: capture)
        #else
        _ = capture.tapRecords.push(.key(record))
        #endif
    }

    static func captureKind(_ kind: RawKeyEvent.Kind) -> KeyCaptureRecord.Kind? {
        switch kind {
        case .keyDown: .keyDown
        case .keyUp: .keyUp
        case .flagsChanged: .flagsChanged
        default: nil
        }
    }

    static func captureOutcome(_ outcome: EventOutcome) -> KeyCaptureRecord.Outcome {
        switch outcome {
        case .passed: .passed
        case .held: .held
        case .consumedForEdit: .consumedForEdit
        case .consumedPairedKeyUp: .consumedPairedKeyUp
        case .consumedAsHotkey: .consumedAsHotkey
        }
    }

    /// What the user's layout produces for the key in its modifier state (never field contents), copied into an
    /// inline buffer on the stack.
    static func layoutCharacter(_ event: RawKeyEvent, table: LayoutTable?) -> InlineUTF16 {
        guard event.kind != .flagsChanged, let table,
            case .character(let character) = table.entry(for: event.keyCode, state: EventFlags.layoutState(event.flags))
        else { return .empty }
        return withUnsafeTemporaryAllocation(of: UInt16.self, capacity: InlineUTF16.capacity) { buffer in
            var count = 0
            for unit in character.utf16 where count < buffer.count {
                buffer[count] = unit
                count += 1
            }
            return InlineUTF16(UnsafeBufferPointer(rebasing: buffer[..<count])) ?? .empty
        }
    }
}
