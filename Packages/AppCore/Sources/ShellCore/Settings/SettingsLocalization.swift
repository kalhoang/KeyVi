// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Shared localisation helpers of the Settings window (W2-B): controls with VoiceOver label and hint keys
// (PRD-R66) and a key that may live in any of the four Settings-window tables.

/// A control of the Settings window. Its VoiceOver label and hint are
/// `<prefix>.control.<case>.accessibilityLabel` / `.accessibilityHint` in `table` (PRD-R66).
public protocol AccessibleControl: RawRepresentable, CaseIterable, Sendable, Hashable where RawValue == String {
    static var table: StringTable { get }
    static var keyPrefix: String { get }
}

extension AccessibleControl {
    public var accessibilityLabelKey: String { "\(Self.keyPrefix).control.\(rawValue).accessibilityLabel" }
    public var accessibilityHintKey: String { "\(Self.keyPrefix).control.\(rawValue).accessibilityHint" }
}

/// A key and the table it lives in, for models that mix tables (a setting's title may be in Settings, Macros or
/// Support).
public struct CatalogText: Sendable, Hashable {
    public var key: String
    public var table: StringTable

    public init(key: String, table: StringTable) {
        self.key = key
        self.table = table
    }

    public init<Key: LocalizationKey>(_ key: Key) {
        self.init(key: key.rawValue, table: Key.table)
    }
}

extension Localizer {
    public func string(_ text: CatalogText) -> String { string(text.key, table: text.table) }

    public func format(_ text: CatalogText, _ arguments: any CVarArg...) -> String {
        format(text.key, table: text.table, arguments: arguments)
    }

    public func accessibilityLabel<Control: AccessibleControl>(_ control: Control) -> String {
        string(control.accessibilityLabelKey, table: Control.table)
    }

    public func accessibilityHint<Control: AccessibleControl>(_ control: Control) -> String {
        string(control.accessibilityHintKey, table: Control.table)
    }
}

/// SF Symbol names that the PLT-R501 bundle-ID lint would otherwise read as reverse-DNS identifiers.
public enum SettingsSymbol {
    public static let info = "info.circle"  // lint:allow-bundle-id SF Symbol name, not an app
    public static let infoFill = "info.circle.fill"  // lint:allow-bundle-id SF Symbol name, not an app
}
