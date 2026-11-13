// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Conversion of event fields into RawKeyEvent (PLT-R304, PLT-R321, PLT-R363), with a value type standing in
// for CGEvent so no event object is ever created. W1-F2.
import AppModel
import CoreGraphics
import RealtimeSupport
import Synchronization
import Testing

@testable import InputHost

/// Field values plus a log of what was read.
private final class FakeFields: TapEventFields, Sendable {
    private let integers: [UInt32: Int64]
    private let unicode: [UInt16]
    private let reported: Int?
    let flagBits: UInt64
    private let reads = Mutex<[String]>([])

    init(integers: [CGEventField: Int64] = [:], flags: UInt64 = 0, unicode: [UInt16] = [], reportedLength: Int? = nil) {
        self.integers = Dictionary(uniqueKeysWithValues: integers.map { ($0.key.rawValue, $0.value) })
        self.flagBits = flags
        self.unicode = unicode
        self.reported = reportedLength
    }

    func integerValue(_ field: CGEventField) -> Int64 {
        reads.withLock { $0.append("field\(field.rawValue)") }
        return integers[field.rawValue] ?? 0
    }

    func copyUnicode(into buffer: UnsafeMutablePointer<UInt16>, capacity: Int) -> Int {
        reads.withLock { $0.append("unicode") }
        for (index, unit) in unicode.prefix(capacity).enumerated() { buffer[index] = unit }
        return reported ?? unicode.count
    }

    var readUnicode: Bool { reads.withLock { $0.contains("unicode") } }
    func read(_ field: CGEventField) -> Bool { reads.withLock { $0.contains("field\(field.rawValue)") } }
}

private let at = MonotonicInstant(nanoseconds: 42)
private let marker: Int64 = 0x5A5A_0000_0001

@Suite struct RawKeyEventExtractionTests {
    @Test func keyDownCopiesEveryKeyboardField() {
        let fields = FakeFields(
            integers: [
                .keyboardEventKeycode: 0x00, .keyboardEventAutorepeat: 1, .keyboardEventKeyboardType: 40,
                .eventSourceUserData: marker,
            ],
            flags: CGEventFlags.maskShift.rawValue, unicode: Array("A".utf16))
        let event = RawKeyEvent(fields, kind: .keyDown, receivedAt: at)
        #expect(event.kind == .keyDown)
        #expect(event.keyCode == KeyCode(rawValue: 0))
        #expect(event.flags == CGEventFlags.maskShift.rawValue)
        #expect(event.autorepeat)
        #expect(event.keyboardType == 40)
        #expect(event.unicode == InlineUTF16("A")!)
        #expect(event.userData == marker, "PLT-R321: the marker is read so echoes are recognised")
        #expect(event.receivedAt == at)
    }

    @Test func keyUpReadsTheUnicodeStringButFlagsChangedDoesNot() {
        let up = FakeFields(integers: [.keyboardEventKeycode: 0x31], unicode: [0x20])
        #expect(RawKeyEvent(up, kind: .keyUp, receivedAt: at).unicode == InlineUTF16(" ")!)
        let modifier = FakeFields(integers: [.keyboardEventKeycode: 0x38], flags: CGEventFlags.maskShift.rawValue)
        let event = RawKeyEvent(modifier, kind: .flagsChanged, receivedAt: at)
        #expect(event.keyCode == KeyCode(rawValue: 0x38))
        #expect(event.unicode == .empty)
        #expect(!modifier.readUnicode)
    }

    @Test func pointerAndScrollEventsCarryOnlyFlagsAndUserData() {
        for kind: RawKeyEvent.Kind in [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel] {
            let fields = FakeFields(
                integers: [.keyboardEventKeycode: 7, .keyboardEventKeyboardType: 40, .eventSourceUserData: 9],
                flags: 0x100)
            let event = RawKeyEvent(fields, kind: kind, receivedAt: at)
            #expect(event.keyCode == KeyCode(rawValue: 0))
            #expect(event.keyboardType == 0)
            #expect(!event.autorepeat)
            #expect(event.flags == 0x100)
            #expect(event.userData == 9)
            #expect(!fields.read(.keyboardEventKeycode) && !fields.readUnicode, "\(kind): no keyboard reads")
        }
    }

    @Test func tapDisabledNotificationsCarryNoFields() {
        for kind: RawKeyEvent.Kind in [.tapDisabledByTimeout, .tapDisabledByUserInput] {
            let fields = FakeFields(integers: [.eventSourceUserData: marker], flags: 0x100)
            let event = RawKeyEvent(fields, kind: kind, receivedAt: at)
            #expect(event.kind == kind)
            #expect(event.flags == 0 && event.userData == 0)
            #expect(!fields.read(.eventSourceUserData))
        }
    }

    @Test func unicodeLongerThanTheInlineCapacityIsCut_PLT_R363() {
        let long = [UInt16](repeating: 0x61, count: 30)
        let fields = FakeFields(unicode: long, reportedLength: 30)
        let event = RawKeyEvent(fields, kind: .keyDown, receivedAt: at)
        #expect(Int(event.unicode.count) == InlineUTF16.capacity)
        let negative = FakeFields(unicode: [], reportedLength: -1)
        #expect(RawKeyEvent(negative, kind: .keyDown, receivedAt: at).unicode == .empty)
    }

    @Test func keyCodeAndKeyboardTypeAreTruncatedNotTrapped() {
        let fields = FakeFields(integers: [.keyboardEventKeycode: 0x1_0024, .keyboardEventKeyboardType: -1])
        let event = RawKeyEvent(fields, kind: .keyDown, receivedAt: at)
        #expect(event.keyCode == KeyCode(rawValue: 0x24))
        #expect(event.keyboardType == UInt32.max)
    }
}

@Suite struct DurationNanosecondsTests {
    @Test func convertsAndSaturates() {
        #expect(Duration.milliseconds(250).nanoseconds == 250_000_000)
        #expect(Duration.seconds(600).nanoseconds == 600_000_000_000)
        #expect(Duration.seconds(-1).nanoseconds == 0)
        #expect(Duration.seconds(Int64.max).nanoseconds == UInt64.max)
    }
}
