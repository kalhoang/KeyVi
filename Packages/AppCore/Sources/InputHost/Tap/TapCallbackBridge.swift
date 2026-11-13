// SPDX-License-Identifier: GPL-3.0-or-later
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

/// The event fields the callback reads (PLT-R304 "reading event fields"). `CGEvent` conforms; the conversion
/// below is generic over it, so production reads are direct calls and tests use a value type instead of
/// creating CGEvents.
protocol TapEventFields {
    func integerValue(_ field: CGEventField) -> Int64
    var flagBits: UInt64 { get }
    /// Copies at most `capacity` UTF-16 units into `buffer`; returns the length the event reports.
    func copyUnicode(into buffer: UnsafeMutablePointer<UInt16>, capacity: Int) -> Int
}

extension CGEvent: TapEventFields {
    func integerValue(_ field: CGEventField) -> Int64 { getIntegerValueField(field) }

    var flagBits: UInt64 { flags.rawValue }

    func copyUnicode(into buffer: UnsafeMutablePointer<UInt16>, capacity: Int) -> Int {
        var length = 0
        keyboardGetUnicodeString(maxStringLength: capacity, actualStringLength: &length, unicodeString: buffer)
        return length
    }
}

extension RawKeyEvent {
    /// Reads the fields the pipeline needs into a bitwise-copyable value. Tap-disabled notifications carry no
    /// fields; pointer and scroll events carry flags and user data only; only keyDown and keyUp read the
    /// Unicode string.
    init<Fields: TapEventFields>(_ event: Fields, kind: Kind, receivedAt: MonotonicInstant) {
        guard kind != .tapDisabledByTimeout, kind != .tapDisabledByUserInput else {
            self.init(
                kind: kind, keyCode: KeyCode(rawValue: 0), flags: 0, autorepeat: false, keyboardType: 0,
                unicode: .empty, userData: 0, receivedAt: receivedAt)
            return
        }
        let keyboard = kind.isKeyboard
        let keyCode = keyboard ? UInt16(truncatingIfNeeded: event.integerValue(.keyboardEventKeycode)) : 0
        let keyboardType = keyboard ? UInt32(truncatingIfNeeded: event.integerValue(.keyboardEventKeyboardType)) : 0
        self.init(
            kind: kind, keyCode: KeyCode(rawValue: keyCode), flags: event.flagBits,
            autorepeat: keyboard && event.integerValue(.keyboardEventAutorepeat) != 0, keyboardType: keyboardType,
            unicode: kind.carriesText ? Self.unicodeString(of: event) : .empty,
            userData: event.integerValue(.eventSourceUserData), receivedAt: receivedAt)
    }

    /// `CGEventKeyboardGetUnicodeString` into a stack buffer of `InlineUTF16.capacity` units (no heap). A longer
    /// string is cut to the capacity.
    private static func unicodeString<Fields: TapEventFields>(of event: Fields) -> InlineUTF16 {
        var units:
            (
                UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16,
                UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16
            ) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        return withUnsafeMutableBytes(of: &units) { raw in
            let buffer = raw.bindMemory(to: UInt16.self)
            guard let base = buffer.baseAddress else { return .empty }
            let length = event.copyUnicode(into: base, capacity: buffer.count)
            let count = max(0, min(length, buffer.count))
            return InlineUTF16(UnsafeBufferPointer(start: base, count: count)) ?? .empty
        }
    }
}
