// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Input-source awareness (PLT-R360-R373). TIS calls run on the main thread only; `UCKeyTranslate` is a pure
// function over `uchr` bytes and may run anywhere off the tap.

public import AppModel
public import Foundation

/// Raw `uchr` data of a keyboard layout (`kTISPropertyUnicodeKeyLayoutData`).
public struct KeyboardLayoutData: Sendable, Hashable {
    public var source: InputSourceID
    public var uchr: Data
    public init(source: InputSourceID, uchr: Data) {
        self.source = source
        self.uchr = uchr
    }
}

public protocol ObservationToken: AnyObject, Sendable {
    func cancel()
}

/// Production (`TISInputSourceProvider`): `TISCopyCurrentKeyboardInputSource`,
/// `TISCopyCurrentKeyboardLayoutInputSource` + `TISGetInputSourceProperty(kTISPropertyUnicodeKeyLayoutData)`,
/// `TISCreateInputSourceList` (enabled sources), `LMGetKbdType()`, and `DistributedNotificationCenter`
/// observers for `kTISNotifySelectedKeyboardInputSourceChanged` and
/// `kTISNotifyEnabledKeyboardInputSourcesChanged`. Read-only: never selects or enables a source.
@MainActor
public protocol InputSourceProvider: Sendable {
    func currentSource() -> InputSourceInfo
    func currentLayoutData() -> KeyboardLayoutData?
    func enabledSources() -> [InputSourceInfo]
    /// Layout data of any installed layout by ID (tests build QWERTZ/AZERTY/Dvorak tables without selecting).
    func layoutData(for id: InputSourceID) -> KeyboardLayoutData?
    func currentKeyboardType() -> UInt32
    func observeChanges(_ handler: @escaping @MainActor @Sendable () -> Void) -> any ObservationToken
}

/// Builds the 128 x 4 table with `UCKeyTranslate(layout, keyCode, kUCKeyActionDown, modifierState,
/// keyboardType, 0, &deadKeyState, ...)` for the states none, Shift, Caps Lock, Shift+Caps Lock (PLT-R360).
public protocol LayoutTableBuilding: Sendable {
    func build(from data: KeyboardLayoutData, keyboardType: UInt32) throws -> LayoutTable
}

/// Throws `LayoutTableError` when the `uchr` data is not a keyboard layout or `UCKeyTranslate` rejects it. A
/// control character (Return, Tab, arrows, function keys) is `.none`; a key that only changes the dead-key state
/// is `.deadKey` (PLT-R354). Logic: `UCKeyTranslateTable.swift`.
public struct UCKeyTranslateLayoutBuilder: LayoutTableBuilding {
    public init() {}
    public func build(from data: KeyboardLayoutData, keyboardType: UInt32) throws -> LayoutTable {
        try UCKeyTranslateTable.build(from: data, keyboardType: keyboardType)
    }
}

public enum LayoutTableError: Error, Sendable, Hashable {
    case invalidLayoutData
    case translationFailed(status: Int32)
}

/// Main thread: on every source change builds (or reuses) the table, classifies the source (PLT-R371,
/// PLT-R372), applies the PLT-R373 binding and publishes an `InputSourceSnapshot`; signals a hard boundary.
/// A snapshot (with a new generation) is published only when the source, its table or its bound mode changed.
/// Logic: `InputSourceMonitor+Refresh.swift`.
@MainActor
public final class InputSourceMonitor {
    let provider: any InputSourceProvider
    let builder: any LayoutTableBuilding
    let publish: @Sendable (InputSourceSnapshot) -> Void
    var binding = LayoutBindingConfiguration(enabled: false, vietnamese: [], english: [])
    var keyboardType: UInt32?
    var tables: [LayoutTableKey: LayoutTable] = [:]
    var lastPublished: InputSourceSnapshot?
    var generation: UInt64 = 0
    var observation: (any ObservationToken)?

    public init(
        provider: any InputSourceProvider, builder: any LayoutTableBuilding,
        publish: @escaping @Sendable (InputSourceSnapshot) -> Void
    ) {
        self.provider = provider
        self.builder = builder
        self.publish = publish
    }

    public func start() { begin() }
    public func stop() { end() }
    public func apply(binding: LayoutBindingConfiguration) {
        self.binding = binding
        refresh()
    }

    /// The tap saw a keyboard type without a table (ISO/ANSI/JIS): build one.
    public func keyboardTypeSeen(_ keyboardType: UInt32) { adopt(keyboardType: keyboardType) }
}

public struct LayoutBindingConfiguration: Sendable, Hashable {
    public var enabled: Bool
    public var vietnamese: Set<InputSourceID>
    public var english: Set<InputSourceID>
    public init(enabled: Bool, vietnamese: Set<InputSourceID>, english: Set<InputSourceID>) {
        self.enabled = enabled
        self.vietnamese = vietnamese
        self.english = english
    }
}
