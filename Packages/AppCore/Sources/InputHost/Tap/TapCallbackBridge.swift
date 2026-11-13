// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The C callback of the event tap and the copy of `CGEvent` fields into a `RawKeyEvent` (PLT-R301, PLT-R304,
// PLT-R305, ADR 0313). Runs on the tap thread for every event: no locks, no allocation, no I/O. W1-F2.

internal import AppModel
internal import CoreGraphics
internal import RealtimeSupport

/// What the C callback's `userInfo` points at. Non-generic so the `@convention(c)` callback can reach it; the
/// generic subclass holds the handler, so the call into `Handler.handle` is statically dispatched.
class TapCallbackTarget {
    /// Production timestamp base (`CLOCK_UPTIME_RAW`, the same as `KeyPipeline<_, MachClock>`).
    let clock = MachClock()

    func dispatch(_ event: RawKeyEvent) -> TapVerdict { .pass }
}

final class TapCallbackContext<Handler: TapEventHandler>: TapCallbackTarget {
    private let handler: Handler

    init(handler: Handler) { self.handler = handler }

    override func dispatch(_ event: RawKeyEvent) -> TapVerdict { handler.handle(event) }
}

enum TapCallbackBridge {
    /// Event types outside `RawKeyEvent.Kind` are returned unchanged without calling the handler.
    static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo, let kind = RawKeyEvent.Kind(type) else { return Unmanaged.passUnretained(event) }
        let verdict = Unmanaged<TapCallbackTarget>.fromOpaque(userInfo)._withUnsafeGuaranteedRef { target in
            target.dispatch(RawKeyEvent(event, kind: kind, receivedAt: target.clock.now()))
        }
        return verdict == .swallow ? nil : Unmanaged.passUnretained(event)
    }

    /// Hands an already converted event to the thread state behind `userInfo` (no retain, no lock). Tap thread.
    static func deliver(_ event: RawKeyEvent, userInfo: UnsafeMutableRawPointer) -> TapVerdict {
        Unmanaged<TapCallbackTarget>.fromOpaque(userInfo)._withUnsafeGuaranteedRef { $0.dispatch(event) }
    }
}

extension RawKeyEvent.Kind {
    /// The event types of `TapEventMask.standard` plus the two tap-disabled notifications (PLT-R301).
    init?(_ type: CGEventType) {
        switch type {
        case .keyDown: self = .keyDown
        case .keyUp: self = .keyUp
        case .flagsChanged: self = .flagsChanged
        case .leftMouseDown: self = .leftMouseDown
        case .rightMouseDown: self = .rightMouseDown
        case .otherMouseDown: self = .otherMouseDown
        case .scrollWheel: self = .scrollWheel
        case .tapDisabledByTimeout: self = .tapDisabledByTimeout
        case .tapDisabledByUserInput: self = .tapDisabledByUserInput
        default: return nil
        }
    }

    fileprivate var isKeyboard: Bool { self == .keyDown || self == .keyUp || self == .flagsChanged }
    fileprivate var carriesText: Bool { self == .keyDown || self == .keyUp }
}

extension RawKeyEvent {
    /// Reads the fields the pipeline needs ("reading event fields", PLT-R304) into a bitwise-copyable value.
    /// Tap-disabled notifications carry no fields; pointer and scroll events carry flags and user data only.
    init(_ event: CGEvent, kind: Kind, receivedAt: MonotonicInstant) {
        guard kind != .tapDisabledByTimeout, kind != .tapDisabledByUserInput else {
            self.init(
                kind: kind, keyCode: KeyCode(rawValue: 0), flags: 0, autorepeat: false, keyboardType: 0,
                unicode: .empty, userData: 0, receivedAt: receivedAt)
            return
        }
        let keyboard = kind.isKeyboard
        self.init(
            kind: kind,
            keyCode: KeyCode(
                rawValue: keyboard ? UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)) : 0),
            flags: event.flags.rawValue,
            autorepeat: keyboard && event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            keyboardType: keyboard
                ? UInt32(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeyboardType)) : 0,
            unicode: kind.carriesText ? Self.unicodeString(of: event) : .empty,
            userData: event.getIntegerValueField(.eventSourceUserData),
            receivedAt: receivedAt)
    }

    /// `CGEventKeyboardGetUnicodeString` into a stack buffer of `InlineUTF16.capacity` units (no heap).
    private static func unicodeString(of event: CGEvent) -> InlineUTF16 {
        var units:
            (
                UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16,
                UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16
            ) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        return withUnsafeMutableBytes(of: &units) { raw in
            let buffer = raw.bindMemory(to: UInt16.self)
            var length = 0
            event.keyboardGetUnicodeString(
                maxStringLength: buffer.count, actualStringLength: &length, unicodeString: buffer.baseAddress)
            let count = max(0, min(length, buffer.count))
            return InlineUTF16(UnsafeBufferPointer(start: buffer.baseAddress, count: count)) ?? .empty
        }
    }
}
