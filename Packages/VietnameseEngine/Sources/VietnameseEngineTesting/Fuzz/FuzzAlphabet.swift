// SPDX-License-Identifier: MPL-2.0

public import VietnameseEngine

extension SeededGenerator {
    /// A value in `0..<bound` by multiply-shift on the next 64 bits. Unlike `Int.random(in:using:)`, whose
    /// algorithm belongs to the standard library, this is fixed here, so a seed replays the same stream on
    /// every toolchain and platform (a failure seen on the Linux fuzz runner reproduces on a Mac).
    public mutating func nextInt(below bound: Int) -> Int {
        precondition(bound > 0, "bound must be positive")
        return Int(next().multipliedFullWidth(by: UInt64(bound)).high)
    }

    /// True with probability `numerator / denominator`.
    public mutating func chance(_ numerator: Int, in denominator: Int) -> Bool {
        nextInt(below: denominator) < numerator
    }

    /// A uniformly chosen element of a non-empty collection.
    public mutating func pick<C: RandomAccessCollection>(_ elements: C) -> C.Element where C.Index == Int {
        elements[elements.startIndex + nextInt(below: elements.count)]
    }
}

/// The event alphabet of spec 13.6 and QA-R7: ASCII letters in both cases, main-row and keypad digits,
/// every ASCII punctuation and symbol character, space and other whitespace, Return, Tab, a few non-ASCII
/// letters (including a decomposed one and one outside the Basic Multilingual Plane), Backspace, the
/// restore toggle and every reset reason.
///
/// It also defines the byte encoding of the coverage-guided fuzzer and its seed corpus
/// (`Packages/VietnameseEngineFuzz`, QA-R9), chosen so that a seed file is readable text: a printable
/// ASCII byte is that key, `\n` `\r` `\t` are Return and Tab, BS is Backspace, ESC is the restore
/// toggle; the remaining control bytes and DEL are resets and keypad digits (DEL is the last reset
/// reason, `unseenInput`, since 15/11/2026; it was a second Backspace before); bytes from 0x80 are
/// non-ASCII letters and whitespace.
public enum FuzzAlphabet {
    /// Every reset reason of 10.2, in declaration order.
    public static let resetReasons: [ResetReason] = [
        .cursorMoved, .pointerClicked, .focusChanged, .applicationChanged, .inputSourceChanged,
        .secureInputChanged, .eventTapReenabled, .shortcut, .forwardDelete, .modeToggled,
        .configurationChanged, .unknown, .unseenInput,
    ]

    /// ASCII letters, both cases.
    public static let letters: [Character] = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

    /// Letters that compose often (vowels, Telex transform letters, frequent onsets and codas), so that
    /// random tokens exercise transforms, relocation, escapes and Backspace.
    public static let composingLetters: [Character] = Array("aeiouyaeoowwdddsfrxjzngchtmpqklbv")

    /// Main-row digits.
    public static let digits: [Character] = Array("0123456789")

    /// Every printable ASCII character that is neither a letter nor a digit (the brackets included).
    public static let punctuation: [Character] = Array("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")

    /// Whitespace boundaries other than Return and Tab: space (twice, so it dominates), no-break space,
    /// ideographic space.
    public static let spaces: [Character] = [" ", " ", "\u{00A0}", "\u{3000}"]

    /// Hard boundaries (ENG-R912): Return as `\n`, `\r` and `\r\n`, and Tab.
    public static let hardBoundaries: [Character] = ["\n", "\r", "\r\n", "\t"]

    /// Letters from other layouts and precomposed Vietnamese letters, all boundaries (9.2): a decomposed
    /// `é` (two scalars, one character) and a letter outside the Basic Multilingual Plane are included to
    /// check that the engine never counts them as its own text (ENG-R630).
    public static let nonASCIILetters: [Character] = [
        "é", "ß", "ñ", "ü", "ø", "ç", "λ", "ж", "ư", "ơ", "Đ", "Ấ", "ạ", "ầ", "e\u{0301}", "\u{1D400}",
    ]

    // MARK: - Byte encoding (coverage-guided fuzzing, seed corpus)

    /// The event that `byte` encodes (see the type documentation).
    public static func event(forByte byte: UInt8) -> EngineEvent {
        switch byte {
        case 0x20...0x7E: return .key(KeyInput(Character(Unicode.Scalar(byte))))
        case 0x0A: return .key(KeyInput("\n"))
        case 0x0D: return .key(KeyInput("\r"))
        case 0x09: return .key(KeyInput("\t"))
        case 0x08: return .backspace
        case 0x7F: return .reset(resetReasons[12])
        case 0x1B: return .restoreToggle
        case 0x00...0x07: return .reset(resetReasons[Int(byte)])
        case 0x0B, 0x0C: return .reset(resetReasons[Int(byte) - 0x0B + 8])
        case 0x0E, 0x0F: return .reset(resetReasons[Int(byte) - 0x0E + 10])
        case 0x10...0x19: return .key(KeyInput(digits[Int(byte) - 0x10], fromKeypad: true))
        case 0x1A: return .key(KeyInput("\r\n"))
        case 0x1C...0x1F: return .key(KeyInput(spaces[Int(byte) - 0x1C]))
        default: return .key(KeyInput(nonASCIILetters[Int(byte - 0x80) % nonASCIILetters.count]))
        }
    }

    /// The events a byte string encodes.
    public static func events(forBytes bytes: some Sequence<UInt8>) -> [EngineEvent] {
        bytes.map(event(forByte:))
    }
}
