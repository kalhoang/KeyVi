// SPDX-License-Identifier: GPL-3.0-or-later
//
// Production `InputSourceProvider` over Text Input Sources (PLT-R360, PLT-R370-R372). Read-only: it never
// selects, enables or disables an input source. Thin wrapper: classification is `InputSourceClassifier`.

public import AppModel
import Carbon
import Foundation

@MainActor
public final class TISInputSourceProvider: InputSourceProvider {
    private let changeCenter: NotificationCenter

    /// Observes `DistributedNotificationCenter.default()`.
    public convenience init() { self.init(changeCenter: DistributedNotificationCenter.default()) }

    /// Injectable center for the change notifications, so tests never register with the system center.
    init(changeCenter: NotificationCenter) { self.changeCenter = changeCenter }

    public func currentSource() -> InputSourceInfo {
        InputSourceClassifier.info(from: TISSourceReader.raw(TISCopyCurrentKeyboardInputSource().takeRetainedValue()))
    }

    public func currentLayoutData() -> KeyboardLayoutData? {
        guard let layout = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        return TISSourceReader.layoutData(layout)
    }

    /// Selectable keyboard sources the user enabled (the parent of an input method's modes is not selectable).
    public func enabledSources() -> [InputSourceInfo] {
        let filter: [String: Any] = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsSelectCapable as String: true,
        ]
        return TISSourceReader.list(filter: filter, includeAllInstalled: false)
            .map { InputSourceClassifier.info(from: TISSourceReader.raw($0)) }
    }

    /// Any installed layout by ID, enabled or not; nothing is selected.
    public func layoutData(for id: InputSourceID) -> KeyboardLayoutData? {
        let filter: [String: Any] = [kTISPropertyInputSourceID as String: id.rawValue]
        return TISSourceReader.list(filter: filter, includeAllInstalled: true).lazy
            .compactMap(TISSourceReader.layoutData).first
    }

    public func currentKeyboardType() -> UInt32 { UInt32(LMGetKbdType()) }

    public func observeChanges(_ handler: @escaping @MainActor @Sendable () -> Void) -> any ObservationToken {
        let names = [
            Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
        ]
        return NotificationObservationToken.observe(
            names, on: changeCenter, extract: { _ in () }, { _ in handler() })
    }
}

/// Property access on `TISInputSource` (main thread only, like every TIS call).
@MainActor
enum TISSourceReader {
    static func list(filter: [String: Any], includeAllInstalled: Bool) -> [TISInputSource] {
        guard let list = TISCreateInputSourceList(filter as CFDictionary, includeAllInstalled)?.takeRetainedValue()
        else { return [] }
        return (list as? [TISInputSource]) ?? []
    }

    static func raw(_ source: TISInputSource) -> RawInputSource {
        RawInputSource(
            id: property(source, kTISPropertyInputSourceID) ?? "",
            type: type(property(source, kTISPropertyInputSourceType)),
            asciiCapable: property(source, kTISPropertyInputSourceIsASCIICapable) ?? false,
            languages: property(source, kTISPropertyInputSourceLanguages) ?? [],
            localizedName: property(source, kTISPropertyLocalizedName) ?? "")
    }

    static func layoutData(_ source: TISInputSource) -> KeyboardLayoutData? {
        guard let data: Data = property(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let id = InputSourceClassifier.sanitizedID(property(source, kTISPropertyInputSourceID) ?? "")
        return KeyboardLayoutData(source: id, uchr: data)
    }

    private static func type(_ value: String?) -> RawInputSourceType {
        guard let value else { return .other }
        let name = { (constant: CFString?) in constant.map { $0 as String } }
        if value == name(kTISTypeKeyboardLayout) { return .keyboardLayout }
        if value == name(kTISTypeKeyboardInputMode) { return .inputMode }
        let methods = [name(kTISTypeKeyboardInputMethodWithoutModes), name(kTISTypeKeyboardInputMethodModeEnabled)]
        return methods.contains(value) ? .inputMethod : .other
    }

    /// `TISGetInputSourceProperty` follows the Get rule: the value is not retained for the caller.
    private static func property<Value>(_ source: TISInputSource, _ key: CFString) -> Value? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? Value
    }
}
