// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R397A (amendment of 2026-11-15): input the app received without the tap. Event taps receive no key events while
// Secure Event Input is on (PLT-R398D), and a burst shorter than the 2 s poll (PLT-R395) is never seen as a pause. In
// Pa's trace of 14/11/2026 a background process toggled secure input in bursts of 55 to 300 ms; the tap missed a Space
// and an "s" that the app received, and a later edit deleted them by count ("hay sao" became "hayayao"). The proof such
// a key leaves behind is a keyUp whose keyDown the tap never saw: the tap then takes a hard boundary, so no later
// edit deletes by a stale count. Tap-safe: a fixed bitset inside `KeyState`, no allocation (PLT-R304).

internal import AppModel
internal import Diagnostics
internal import Injection
internal import RealtimeSupport
internal import VietnameseEngine

/// Key codes the tap saw go down and not yet up: 256 bits inline (virtual key codes are below 128 on every Mac
/// keyboard; larger codes are not tracked and never judged).
struct KeysDown {
    private var low: (UInt64, UInt64) = (0, 0)
    private var high: (UInt64, UInt64) = (0, 0)

    @inline(__always)
    mutating func insert(_ keyCode: KeyCode) {
        guard let (word, bit) = Self.position(keyCode) else { return }
        update(word) { $0 |= bit }
    }

    /// Clears the key; false only when a tracked key was not down.
    @inline(__always)
    mutating func remove(_ keyCode: KeyCode) -> Bool {
        guard let (word, bit) = Self.position(keyCode) else { return true }
        var wasDown = false
        update(word) { value in
            wasDown = value & bit != 0
            value &= ~bit
        }
        return wasDown
    }

    @inline(__always)
    private static func position(_ keyCode: KeyCode) -> (Int, UInt64)? {
        let code = Int(keyCode.rawValue)
        guard code < 256 else { return nil }
        return (code >> 6, UInt64(1) << UInt64(code & 63))
    }

    @inline(__always)
    private mutating func update(_ word: Int, _ body: (inout UInt64) -> Void) {
        switch word {
        case 0: body(&low.0)
        case 1: body(&low.1)
        case 2: body(&high.0)
        default: body(&high.1)
        }
    }
}

enum UnseenInput {
    /// Modifier keys report `flagsChanged`, never keyUp; a keyUp with one of their codes is not judged.
    @inline(__always)
    static func isModifier(_ keyCode: KeyCode) -> Bool {
        keyCode.rawValue >= KeyCode.rightCommand.rawValue && keyCode.rawValue <= KeyCode.function.rawValue
    }
}

extension KeyPipeline {
    /// Every physical keyDown (autorepeat included) marks its key; a keyUp clears it. A keyUp of a non-modifier key
    /// that was not down and that the pipeline did not consume means the app got a keyDown the engine never saw:
    /// a hard boundary with its own job reason, and a content-free tap-log record (the key code only, PLT-R901).
    /// Keys already down when the tap started cost at most one such boundary each.
    func trackKeysDown(_ event: RawKeyEvent, generation: FocusGeneration, now: MonotonicInstant) {
        switch event.kind {
        case .keyDown:
            keyState.keysDown.insert(event.keyCode)
        case .keyUp:
            guard !keyState.keysDown.remove(event.keyCode), !UnseenInput.isModifier(event.keyCode),
                consumedKeys.entry(event.keyCode) == .none
            else { return }
            context.tapLog.push(TapLogRecord(code: .unseenKeyUp, at: now, a: UInt64(event.keyCode.rawValue)))
            // ENG-R1010: the engine has no reason of its own for this yet (`unknown`); the job reason names it.
            hardBoundary(.unknown, job: .unseenInput, generation: generation)
        default:
            break
        }
    }
}
