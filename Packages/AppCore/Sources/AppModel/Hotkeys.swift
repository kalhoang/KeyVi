// SPDX-License-Identifier: GPL-3.0-or-later
//
// Hotkey bindings (03-product.md PRD-R14 to PRD-R18). Stored in settings.json; recognised by InputHost.

/// Modifier keys, with side-specific bits for the right-side-only taps (PRD-R15).
public struct ModifierKeys: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let control = ModifierKeys(rawValue: 1 << 0)
    public static let option = ModifierKeys(rawValue: 1 << 1)
    public static let shift = ModifierKeys(rawValue: 1 << 2)
    public static let command = ModifierKeys(rawValue: 1 << 3)
    public static let function = ModifierKeys(rawValue: 1 << 4)
    /// Set together with `.command` when the right Command key is the one held.
    public static let rightCommand = ModifierKeys(rawValue: 1 << 5)
    /// Set together with `.option` when the right Option key is the one held.
    public static let rightOption = ModifierKeys(rawValue: 1 << 6)
}

/// Modifier-only taps the recorder accepts (PRD-R15).
public enum ModifierTapChord: String, Sendable, Hashable, Codable, CaseIterable {
    case controlShift, commandShift, optionShift, controlOption, rightCommand, rightOption

    /// The modifier set that must be held (and then fully released) for the tap to fire.
    public var modifiers: ModifierKeys {
        switch self {
        case .controlShift: [.control, .shift]
        case .commandShift: [.command, .shift]
        case .optionShift: [.option, .shift]
        case .controlOption: [.control, .option]
        case .rightCommand: [.command, .rightCommand]
        case .rightOption: [.option, .rightOption]
        }
    }
}

/// What a hotkey is for. Only two configurable global hotkeys exist in v1 (PRD-R18).
public enum HotkeyRole: String, Sendable, Hashable, Codable, CaseIterable { case toggleMode, restoreLastWord }

/// A recorded hotkey. JSON shape (settings.json, schema v1):
/// `{"type":"modifierTap","chord":"controlShift"}`, `{"type":"keyCombo","modifiers":9,"keyCode":49}`,
/// `{"type":"key","keyCode":53}`.
public enum HotkeyBinding: Sendable, Hashable, Codable {
    /// Press and release modifiers only, nothing else in between, within 500 ms (D11, PRD-R14).
    case modifierTap(ModifierTapChord)
    /// At least one modifier plus one key (PRD-R15).
    case keyCombo(modifiers: ModifierKeys, keyCode: KeyCode)
    /// A single key without modifiers. Allowed only for `.restoreLastWord` (Escape is the suggestion, D8).
    case key(KeyCode)

    /// D11 default.
    public static let defaultToggle = HotkeyBinding.modifierTap(.controlShift)

    public func isAllowed(for role: HotkeyRole) -> Bool {
        switch (self, role) {
        case (.key, .toggleMode): false
        case (.keyCombo(let modifiers, _), _): !modifiers.isEmpty
        default: true
        }
    }

    private enum CodingKeys: String, CodingKey { case type, chord, modifiers, keyCode }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "modifierTap":
            self = .modifierTap(try container.decode(ModifierTapChord.self, forKey: .chord))
        case "keyCombo":
            self = .keyCombo(
                modifiers: try container.decode(ModifierKeys.self, forKey: .modifiers),
                keyCode: try container.decode(KeyCode.self, forKey: .keyCode))
        case "key":
            self = .key(try container.decode(KeyCode.self, forKey: .keyCode))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "unknown hotkey type")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .modifierTap(let chord):
            try container.encode("modifierTap", forKey: .type)
            try container.encode(chord, forKey: .chord)
        case .keyCombo(let modifiers, let keyCode):
            try container.encode("keyCombo", forKey: .type)
            try container.encode(modifiers, forKey: .modifiers)
            try container.encode(keyCode, forKey: .keyCode)
        case .key(let keyCode):
            try container.encode("key", forKey: .type)
            try container.encode(keyCode, forKey: .keyCode)
        }
    }
}
