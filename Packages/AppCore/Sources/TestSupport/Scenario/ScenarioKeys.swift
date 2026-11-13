// SPDX-License-Identifier: GPL-3.0-or-later
//
// Physical key names of scenario key scripts (PLT-R530). A name is a key POSITION on the ANSI keyboard, not a
// character: on a QWERTZ layout the key named `z` types "y". Values are the public macOS virtual key codes
// (Carbon `Events.h`, kVK_ANSI_* and kVK_*). The accepted names are exactly those of the `keys` pattern in
// compat/schema/scenario.schema.json.

public import AppModel

/// A modifier key the driver presses with `flagsChanged` events.
public enum ScenarioModifier: String, Sendable, Hashable, CaseIterable {
    case shift, control, option, command

    public var keyCode: KeyCode {
        switch self {
        case .shift: .shift
        case .control: .control
        case .option: .option
        case .command: .command
        }
    }

    /// `CGEventFlags` bits a physical left-hand key sets: the device-independent mask plus the left-key
    /// device bit (IOKit `NX_DEVICEL*KEYMASK`), so a hotkey recogniser that tells left from right sees what a
    /// real keyboard sends.
    public var flags: UInt64 {
        switch self {
        case .shift: 0x0002_0000 | 0x0002
        case .control: 0x0004_0000 | 0x0001
        case .option: 0x0008_0000 | 0x0020
        case .command: 0x0010_0000 | 0x0008
        }
    }
}

/// One entry of a key script: an optional modifier held around a key, or a modifier pressed on its own.
public struct KeyStroke: Sendable, Hashable {
    public var modifier: ScenarioModifier?
    public var keyCode: KeyCode
    /// True when the stroke is a modifier on its own (`shift`, or the second key of `control+shift`).
    public var keyIsModifier: Bool

    public init(modifier: ScenarioModifier?, keyCode: KeyCode, keyIsModifier: Bool) {
        self.modifier = modifier
        self.keyCode = keyCode
        self.keyIsModifier = keyIsModifier
    }
}

public enum KeyScriptError: Error, Sendable, Hashable {
    case unknownKey(index: Int, name: String)
    case emptyScript
}

public enum ScenarioKeys {
    /// Base key names (without a modifier prefix) and their virtual key codes.
    public static let keyCodes: [String: KeyCode] = {
        var table: [String: UInt16] = [
            "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
            "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
            "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "equal": 0x18,
            "9": 0x19, "7": 0x1A, "minus": 0x1B, "8": 0x1C, "0": 0x1D, "rightBracket": 0x1E, "o": 0x1F,
            "u": 0x20, "leftBracket": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "quote": 0x27,
            "k": 0x28, "semicolon": 0x29, "comma": 0x2B, "slash": 0x2C, "n": 0x2D, "m": 0x2E, "period": 0x2F,
        ]
        table["return"] = KeyCode.returnKey.rawValue
        table["tab"] = KeyCode.tab.rawValue
        table["space"] = KeyCode.space.rawValue
        table["backspace"] = KeyCode.delete.rawValue  // PLT-R407: the harness never sends forward delete
        table["escape"] = KeyCode.escape.rawValue
        table["left"] = KeyCode.leftArrow.rawValue
        table["right"] = KeyCode.rightArrow.rawValue
        table["down"] = KeyCode.downArrow.rawValue
        table["up"] = KeyCode.upArrow.rawValue
        return table.mapValues { KeyCode(rawValue: $0) }
    }()

    /// Parses one key name: `a`, `space`, `shift`, `shift+a`, `command+v`, `control+shift`.
    public static func stroke(_ name: String) -> KeyStroke? {
        let parts = name.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1:
            if let modifier = ScenarioModifier(rawValue: name) {
                return KeyStroke(modifier: nil, keyCode: modifier.keyCode, keyIsModifier: true)
            }
            return keyCodes[name].map { KeyStroke(modifier: nil, keyCode: $0, keyIsModifier: false) }
        case 2:
            // The schema allows only lowercase names after `+`, so `shift+leftBracket` is not a valid key.
            guard let modifier = ScenarioModifier(rawValue: parts[0]), parts[1].utf8.allSatisfy(isLowercaseASCIIOrDigit)
            else { return nil }
            if let second = ScenarioModifier(rawValue: parts[1]), second != modifier {
                return KeyStroke(modifier: modifier, keyCode: second.keyCode, keyIsModifier: true)
            }
            return keyCodes[parts[1]].map { KeyStroke(modifier: modifier, keyCode: $0, keyIsModifier: false) }
        default:
            return nil
        }
    }

    private static func isLowercaseASCIIOrDigit(_ byte: UInt8) -> Bool {
        (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39)
    }

    /// Parses a whole script; the error names the first invalid entry.
    public static func strokes(_ names: [String]) throws(KeyScriptError) -> [KeyStroke] {
        guard !names.isEmpty else { throw .emptyScript }
        var strokes: [KeyStroke] = []
        strokes.reserveCapacity(names.count)
        for (index, name) in names.enumerated() {
            guard let stroke = stroke(name) else { throw .unknownKey(index: index, name: name) }
            strokes.append(stroke)
        }
        return strokes
    }
}
