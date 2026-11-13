// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Production service wrappers without posting, AX trust or the general pasteboard: CGEvents are built and
// inspected but never posted; AX calls are exercised only on the paths that need no element.

import AppModel
import ApplicationServices
import RealtimeSupport
import TestSupport
import Testing

@testable import Injection

@Suite struct CGEventFactoryTests {
    private let factory = CGEventFactory()

    /// PLT-R320: private state source with a local-events suppression interval of 0.
    @Test func sourceNeverSuppressesHardwareInputPLTR320() {
        #expect(factory.suppressionInterval == 0)
    }

    /// PLT-R320/R321/R404: explicit flags, the marker in `eventSourceUserData`, the Unicode payload.
    @Test func syntheticEventCarriesFlagsMarkerAndUnicode() throws {
        let marker = EventMarker(tag: 0x12_3456_789A)
        let userData = marker.userData(sequence: 77, probe: false)
        let chunk = try #require(InlineUTF16("ường"))
        let event = try factory.makeEvent(
            SyntheticKeyEvent(keyCode: KeyCode(rawValue: 0x01), isKeyDown: true, flags: 0, unicode: chunk), userData: userData)
        #expect(event.type == .keyDown)
        #expect(event.getIntegerValueField(.keyboardEventKeycode) == 0x01)
        #expect(event.flags.rawValue == 0)
        #expect(marker.classify(event.getIntegerValueField(.eventSourceUserData)) == .echo(sequence: 77))
        #expect(unicode(of: event) == "ường")
    }

    @Test func shiftLeftAndCommandVCarryOnlyTheirModifierPLTR406() throws {
        let shiftLeft = try factory.makeEvent(SyntheticKeys.shiftLeft.released, userData: 1)
        #expect(shiftLeft.type == .keyUp)
        #expect(shiftLeft.flags == .maskShift)
        let paste = try factory.makeEvent(SyntheticKeys.paste(keyCode: KeyCode(rawValue: 0x09)), userData: 1)
        #expect(paste.flags == .maskCommand)
        #expect(paste.getIntegerValueField(.keyboardEventKeycode) == 0x09)
    }

    /// PLT-R324: replays keep keycode, flags, autorepeat, keyboard type and Unicode string, plus the marker.
    @Test func replayCopiesEveryRecordedFieldPLTR324() throws {
        let record = KeyEventRecord(
            kind: .keyDown, keyCode: KeyCode(rawValue: 0x00), flags: CGEventFlags.maskAlphaShift.rawValue, autorepeat: true,
            keyboardType: 59, unicode: InlineUTF16("A") ?? .empty, receivedAt: .zero, isProbe: false)
        let event = try factory.makeReplay(record, userData: 99)
        #expect(event.type == .keyDown)
        #expect(event.getIntegerValueField(.keyboardEventKeycode) == 0x00)
        #expect(event.flags == .maskAlphaShift)
        #expect(event.getIntegerValueField(.keyboardEventAutorepeat) == 1)
        #expect(event.getIntegerValueField(.keyboardEventKeyboardType) == 59)
        #expect(event.getIntegerValueField(.eventSourceUserData) == 99)
        #expect(unicode(of: event) == "A")
        var flags = record
        flags.kind = .flagsChanged
        flags.keyCode = .shift
        flags.flags = CGEventFlags.maskShift.rawValue
        flags.unicode = .empty
        flags.autorepeat = false
        let flagsChanged = try factory.makeReplay(flags, userData: 1)
        #expect(flagsChanged.type == .flagsChanged)
        #expect(flagsChanged.getIntegerValueField(.keyboardEventAutorepeat) == 0)
        var up = record
        up.kind = .keyUp
        #expect(try factory.makeReplay(up, userData: 1).type == .keyUp)
    }

    @Test func posterConstructsWithoutPosting() {
        _ = CGEventPoster()
    }

    private func unicode(of event: CGEvent) -> String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 32)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        return String(decoding: buffer.prefix(length), as: UTF16.self)
    }
}

@Suite struct AXFieldCallsTests {
    /// A job without an AX element (tests, AX unavailable at focus time) never reaches the AX API.
    @Test func missingElementIsUnavailable() {
        let access = AXFocusedFieldAccess()
        let field = FieldHandle(pid: 1, token: 1, element: nil)
        let range = Injection.TextRange(location: 0, length: 1)
        #expect(isUnavailable(access.selectedRange(field, timeout: .milliseconds(15))))
        #expect(isUnavailable(access.text(field, in: range, timeout: .milliseconds(15))))
        #expect(isUnavailable(access.setSelectedRange(field, to: range, timeout: .milliseconds(15))))
        #expect(isUnavailable(access.setSelectedText(field, to: "x", timeout: .milliseconds(15))))
    }

    /// PLT-R343: reads never exceed 64 UTF-16 units and never use negative values.
    @Test func readsAreBoundedTo64UnitsPLTR343() {
        let bounded = AXFieldCalls.boundedRange(Injection.TextRange(location: -3, length: 5_000))
        #expect(bounded.location == 0 && bounded.length == 64)
        let small = AXFieldCalls.boundedRange(Injection.TextRange(location: 10, length: -1))
        #expect(small.location == 10 && small.length == 0)
    }

    @Test func errorMapping() {
        #expect(isTimedOut(AXFieldCalls.map(.cannotComplete) as AXCallResult<Void>))
        for error in [AXError.apiDisabled, .invalidUIElement, .attributeUnsupported, .noValue, .notImplemented] {
            #expect(isUnavailable(AXFieldCalls.map(error) as AXCallResult<Void>))
        }
        if case .failed(let code) = AXFieldCalls.map(.illegalArgument) as AXCallResult<Void> {
            #expect(code == AXError.illegalArgument.rawValue)
        } else {
            Issue.record("illegalArgument should map to failed")
        }
    }

    private func isUnavailable<Value>(_ result: AXCallResult<Value>) -> Bool {
        if case .unavailable = result { return true }
        return false
    }

    private func isTimedOut<Value>(_ result: AXCallResult<Value>) -> Bool {
        if case .timedOut = result { return true }
        return false
    }
}
