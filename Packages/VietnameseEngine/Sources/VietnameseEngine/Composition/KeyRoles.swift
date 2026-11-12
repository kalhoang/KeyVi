// SPDX-License-Identifier: MPL-2.0

/// The kinds of transform that escape by doubling, sticky for the rest of the token (ENG-R441).
/// `bracket` is not in the spec's list: it implements the bracket doubling of 4.8 (`[[` -> `[`) the
/// same way (docs/decisions/0102-engine-composition-model.md).
package struct EscapeKinds: OptionSet, Sendable, Hashable {
    package let rawValue: UInt8
    package init(rawValue: UInt8) { self.rawValue = rawValue }

    package static let tone = EscapeKinds(rawValue: 1 << 0)
    package static let circumflex = EscapeKinds(rawValue: 1 << 1)
    package static let telexW = EscapeKinds(rawValue: 1 << 2)
    package static let vniHorn = EscapeKinds(rawValue: 1 << 3)
    package static let vniBreve = EscapeKinds(rawValue: 1 << 4)
    package static let stroke = EscapeKinds(rawValue: 1 << 5)
    package static let bracket = EscapeKinds(rawValue: 1 << 6)
}

/// Which letters a horn or breve key acts on (ENG-R413, ENG-R414).
package enum HornBreveScope: UInt8, Sendable, Hashable {
    /// Telex `w`: horn on `o` and `u` (and on a `u o` pair), breve on `a`, standalone `ư`.
    case telexW
    /// VNI `7`: horn on `o` and `u` and on a `u o` pair.
    case vniHorn
    /// VNI `8`: breve on `a`.
    case vniBreve

    package var kind: EscapeKinds {
        switch self {
        case .telexW: return .telexW
        case .vniHorn: return .vniHorn
        case .vniBreve: return .vniBreve
        }
    }

    /// Whether the key puts horns on `o`, `u` and on a `u o` pair.
    package var horns: Bool { self != .vniBreve }

    /// The letter a single target with this base becomes, nil if the key does not act on the base.
    @inline(__always)
    package func target(forBase base: Letter) -> Letter? {
        switch base {
        case .a: return self == .vniHorn ? nil : .aBreve
        case .o: return horns ? .oHorn : nil
        case .u: return horns ? .uHorn : nil
        default: return nil
        }
    }

    /// Whether `modifier` is the effect of this key, for the escape test of ENG-R413. VNI `7` and `8`
    /// look only at their own modifier (ENG-R414 restricts ENG-R413 to their letters).
    @inline(__always)
    package func isEffect(_ modifier: LetterModifier) -> Bool {
        switch modifier {
        case .horn: return horns
        case .breve: return self != .vniHorn
        default: return false
        }
    }
}

/// The transform role of a token key under the active input method (4.1, 4.2).
package enum KeyRole: Sendable, Hashable {
    /// No transform role: the key is a letter (4.3 step 3) or, if it is not a letter, a literal.
    case letter
    /// Telex `s f r x j`, VNI `1`-`5` (ENG-R410).
    case tone(Tone)
    /// Telex `z`, VNI `0` (ENG-R411).
    case toneRemoval
    /// Telex `a e o` (the base it targets) or VNI `6` (nil: `a`, `e` or `o`) (ENG-R412).
    case circumflex(Letter?)
    /// Telex `w`, VNI `7`, VNI `8` (ENG-R413, ENG-R414).
    case hornOrBreve(HornBreveScope)
    /// Telex `d`, VNI `9` (ENG-R415).
    case stroke
    /// Telex `[` and `]` with the bracket option (ENG-R104): the letter `ơ` or `ư`.
    case bracket(Letter)

    /// The escape kind of the role (ENG-R441); nil for `letter`. Tone removal shares the tone kind:
    /// after a tone escape no tone can return, so `z` / `0` would not apply anyway.
    package var escapeKind: EscapeKinds? {
        switch self {
        case .letter: return nil
        case .tone, .toneRemoval: return .tone
        case .circumflex: return .circumflex
        case .hornOrBreve(let scope): return scope.kind
        case .stroke: return .stroke
        case .bracket: return .bracket
        }
    }
}

/// The configuration-dependent part of composition, fixed for the lifetime of an `Engine`
/// (ENG-R1211: a configuration change creates a new engine).
package struct ComposerRules: Sendable, Hashable {
    package let isTelex: Bool
    /// ENG-R103, default on.
    package let standaloneW: Bool
    /// ENG-R104, default off.
    package let bracketKeys: Bool
    package let toneStyle: ToneStyle

    package init(_ configuration: EngineConfiguration) {
        switch configuration.inputMethod {
        case .telex(let options):
            isTelex = true
            standaloneW = options.standaloneW
            bracketKeys = options.bracketKeys
        case .vni:
            isTelex = false
            standaloneW = false
            bracketKeys = false
        }
        toneStyle = configuration.toneStyle
    }

    /// The role of a token key (an ASCII byte accepted by `TokenKey.classify`). ENG-R403: in VNI the
    /// Telex transform letters are plain letters; in Telex digits never reach here (boundaries).
    @inline(__always)
    package func role(of key: UInt8) -> KeyRole {
        isTelex ? Self.telexRole(key) : Self.vniRole(key)
    }

    private static func telexRole(_ key: UInt8) -> KeyRole {
        switch key {
        case ASCII.leftBracket: return .bracket(.oHorn)
        case ASCII.rightBracket: return .bracket(.uHorn)
        default: break
        }
        // ENG-R902 (4.1 "All roles apply to uppercase keys too"): roles ignore the key's case.
        switch ASCII.lowercased(key) {
        case UInt8(ascii: "s"): return .tone(.acute)
        case UInt8(ascii: "f"): return .tone(.grave)
        case UInt8(ascii: "r"): return .tone(.hook)
        case UInt8(ascii: "x"): return .tone(.tilde)
        case UInt8(ascii: "j"): return .tone(.dot)
        case UInt8(ascii: "z"): return .toneRemoval
        case UInt8(ascii: "a"): return .circumflex(.a)
        case UInt8(ascii: "e"): return .circumflex(.e)
        case UInt8(ascii: "o"): return .circumflex(.o)
        case UInt8(ascii: "w"): return .hornOrBreve(.telexW)
        case UInt8(ascii: "d"): return .stroke
        default: return .letter
        }
    }

    private static func vniRole(_ key: UInt8) -> KeyRole {
        switch key {
        case UInt8(ascii: "0"): return .toneRemoval
        case UInt8(ascii: "1"): return .tone(.acute)
        case UInt8(ascii: "2"): return .tone(.grave)
        case UInt8(ascii: "3"): return .tone(.hook)
        case UInt8(ascii: "4"): return .tone(.tilde)
        case UInt8(ascii: "5"): return .tone(.dot)
        case UInt8(ascii: "6"): return .circumflex(nil)
        case UInt8(ascii: "7"): return .hornOrBreve(.vniHorn)
        case UInt8(ascii: "8"): return .hornOrBreve(.vniBreve)
        case UInt8(ascii: "9"): return .stroke
        default: return .letter
        }
    }
}

/// ASCII helpers. Case operations are ASCII only and never depend on the locale (ENG-R905).
package enum ASCII {
    package static let leftBracket = UInt8(ascii: "[")
    package static let rightBracket = UInt8(ascii: "]")

    @inline(__always)
    package static func isUppercaseLetter(_ byte: UInt8) -> Bool { byte >= 65 && byte <= 90 }

    @inline(__always)
    package static func isLowercaseLetter(_ byte: UInt8) -> Bool { byte >= 97 && byte <= 122 }

    @inline(__always)
    package static func isLetter(_ byte: UInt8) -> Bool { isUppercaseLetter(byte) || isLowercaseLetter(byte) }

    @inline(__always)
    package static func isDigit(_ byte: UInt8) -> Bool { byte >= 48 && byte <= 57 }

    @inline(__always)
    package static func lowercased(_ byte: UInt8) -> UInt8 { isUppercaseLetter(byte) ? byte + 32 : byte }
}
