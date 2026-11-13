// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Helpers for injection tests (W1-D) and anyone driving the worker against a `SimulatedTextField`: a small
// US-QWERTY layout table, a poster wired to a field, and a plain `InjectionEnvironment` for strategy tests.
// Key codes are the public macOS virtual key codes (Carbon `Events.h`, kVK_ANSI_*).

public import AppModel
public import Injection
public import InputHost
public import RealtimeSupport

public enum InjectionTestLayouts {
    /// kVK_ANSI_* positions of the letters, digits and space on a US-QWERTY keyboard.
    public static let qwertyKeyCodes: [Character: UInt16] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08,
        "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "1": 0x12,
        "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "9": 0x19, "7": 0x1A, "8": 0x1C, "0": 0x1D,
        "o": 0x1F, "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28, "n": 0x2D, "m": 0x2E,
        " ": 0x31,
    ]

    /// A synthetic table: letters in the four modifier states, digits and space unshifted.
    public static func qwerty() -> LayoutTable {
        let states = LayoutModifierState.allCases.count
        var entries = Array(repeating: LayoutEntry.none, count: LayoutTable.keyCodeCount * states)
        for (character, code) in qwertyKeyCodes {
            let upper = Character(character.uppercased())
            let base = Int(code) * states
            entries[base + LayoutModifierState.none.rawValue] = .character(character)
            entries[base + LayoutModifierState.shift.rawValue] = .character(upper)
            entries[base + LayoutModifierState.capsLock.rawValue] = .character(upper)
            entries[base + LayoutModifierState.shiftCapsLock.rawValue] = .character(character)
        }
        guard let source = InputSourceID(rawValue: "test.layout.qwerty") else { preconditionFailure("source id") }
        return LayoutTable(source: source, keyboardType: 40, entries: entries)
    }

    public static func keyCode(for character: Character) -> KeyCode {
        KeyCode(rawValue: qwertyKeyCodes[Character(character.lowercased())] ?? 0x00)
    }
}

public enum InjectionFieldWiring {
    /// A poster whose delivered events reach `field`: synthetic events as posted, replays like physical keys.
    public static func poster(for field: SimulatedTextField, layout: LayoutTable) -> FakeEventPoster {
        FakeEventPoster { posted in
            switch posted {
            case .synthetic(let event, _): field.apply(event, layout: layout)
            case .replay(let record, _): field.apply(record, layout: layout)
            }
        }
    }

    /// A keyDown record for `character` as the tap would hold it (PLT-R324 fields).
    public static func keyDown(
        _ character: Character, receivedAt: MonotonicInstant, keyboardType: UInt32 = 40, isProbe: Bool = false
    ) -> KeyEventRecord {
        KeyEventRecord(
            kind: .keyDown, keyCode: InjectionTestLayouts.keyCode(for: character), flags: 0, autorepeat: false,
            keyboardType: keyboardType, unicode: InlineUTF16(String(character)) ?? .empty, receivedAt: receivedAt,
            isProbe: isProbe)
    }

    public static func keyUp(_ record: KeyEventRecord) -> KeyEventRecord {
        var copy = record
        copy.kind = .keyUp
        return copy
    }
}

/// A plain environment for strategy tests: posts to `poster` with increasing sequences, paces on `clock`, and
/// counts `releaseHeldEvents` calls (the worker's own environment is tested through `InjectionWorker`).
public final class FakeInjectionEnvironment: InjectionEnvironment {
    public let poster: FakeEventPoster
    public let clock: ManualClock
    public let fieldAccess: any FocusedFieldAccess
    public let pasteboard: any PasteboardAccess
    public private(set) var releaseCount = 0
    public private(set) var sleepDeadlines: [MonotonicInstant] = []
    /// Called on `releaseHeldEvents`, for tests that model held keys.
    public var onRelease: (() -> Void)?
    private var sequence: UInt32 = 0

    public init(
        poster: FakeEventPoster, clock: ManualClock, fieldAccess: any FocusedFieldAccess,
        pasteboard: any PasteboardAccess
    ) {
        self.poster = poster
        self.clock = clock
        self.fieldAccess = fieldAccess
        self.pasteboard = pasteboard
    }

    public var now: MonotonicInstant { clock.now() }

    public func sleep(until deadline: MonotonicInstant) {
        sleepDeadlines.append(deadline)
        clock.sleep(until: deadline)
    }

    public func post(_ event: SyntheticKeyEvent) throws(PostError) -> UInt32 {
        sequence &+= 1
        try poster.post(event, userData: Int64(sequence))
        return sequence
    }

    public func releaseHeldEvents() {
        releaseCount += 1
        onRelease?()
    }
}
