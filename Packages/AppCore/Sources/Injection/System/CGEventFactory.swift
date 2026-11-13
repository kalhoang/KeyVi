// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Builds the CGEvents that `CGEventPoster` posts. Creating an event posts nothing, so tests inspect the fields
// here without Accessibility trust and without sending input anywhere.

internal import AppModel
internal import CoreGraphics
internal import RealtimeSupport

/// `CGEventSource` is an immutable CF object after setup and CoreGraphics allows using it from any thread; the
/// factory only reads it, so sharing it across threads is safe (the reason for `@unchecked`).
final class CGEventFactory: @unchecked Sendable {
    private let source: CGEventSource?

    /// PLT-R320: private state (no inherited modifier state) and a local-events suppression interval of 0, so
    /// posting never suppresses the user's hardware input (VERIFY default suppression on macOS 15, 26, 27).
    init() {
        let source = CGEventSource(stateID: .privateState)
        source?.localEventsSuppressionInterval = 0
        self.source = source
    }

    var suppressionInterval: Double? { source?.localEventsSuppressionInterval }

    /// PLT-R320 explicit flags, PLT-R404 Unicode payload (none for backspace, PLT-R407), PLT-R321 marker.
    func makeEvent(_ event: SyntheticKeyEvent, userData: Int64) throws(PostError) -> CGEvent {
        guard
            let cgEvent = CGEvent(
                keyboardEventSource: source, virtualKey: event.keyCode.rawValue, keyDown: event.isKeyDown)
        else { throw .eventCreationFailed }
        cgEvent.flags = CGEventFlags(rawValue: event.flags)
        Self.setUnicode(event.unicode, on: cgEvent)
        cgEvent.setIntegerValueField(.eventSourceUserData, value: userData)
        return cgEvent
    }

    /// PLT-R324: keycode, flags, autorepeat, keyboard type and Unicode string preserved, plus the marker.
    func makeReplay(_ record: KeyEventRecord, userData: Int64) throws(PostError) -> CGEvent {
        let isDown = record.kind == .keyDown
        guard let cgEvent = CGEvent(keyboardEventSource: source, virtualKey: record.keyCode.rawValue, keyDown: isDown)
        else { throw .eventCreationFailed }
        if record.kind == .flagsChanged { cgEvent.type = .flagsChanged }
        cgEvent.flags = CGEventFlags(rawValue: record.flags)
        cgEvent.setIntegerValueField(.keyboardEventAutorepeat, value: record.autorepeat ? 1 : 0)
        cgEvent.setIntegerValueField(.keyboardEventKeyboardType, value: Int64(record.keyboardType))
        Self.setUnicode(record.unicode, on: cgEvent)
        cgEvent.setIntegerValueField(.eventSourceUserData, value: userData)
        return cgEvent
    }

    private static func setUnicode(_ unicode: InlineUTF16, on event: CGEvent) {
        guard unicode.count > 0 else { return }
        unicode.withUnits { units in
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units.baseAddress)
        }
    }
}
