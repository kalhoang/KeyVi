// SPDX-License-Identifier: GPL-3.0-or-later
//
// Input-source classification (PLT-R371, PLT-R372). Pure: the TIS wrapper reads the raw properties, this file
// decides what they mean, so the decision is unit-tested without Text Input Sources.

import AppModel

/// `kTISPropertyInputSourceType`, reduced to what classification needs.
enum RawInputSourceType: Sendable, Hashable {
    case keyboardLayout
    case inputMethod  // kTISTypeKeyboardInputMethodWithoutModes or ...ModeEnabled
    case inputMode
    case other
}

/// The TIS properties of one source, copied out of the `TISInputSource`.
struct RawInputSource: Sendable, Hashable {
    var id: String
    var type: RawInputSourceType
    var asciiCapable: Bool
    var languages: [String]
    var localizedName: String
}

enum InputSourceClassifier {
    static func info(from raw: RawInputSource) -> InputSourceInfo {
        let kind = kind(type: raw.type, asciiCapable: raw.asciiCapable)
        return InputSourceInfo(
            id: sanitizedID(raw.id), kind: kind, localizedName: raw.localizedName, languages: raw.languages,
            isBuiltInVietnamese: isVietnameseTransformer(kind: kind, languages: raw.languages))
    }

    /// PLT-R371: anything that is not an ASCII-capable keyboard layout pauses (unknown types included).
    static func kind(type: RawInputSourceType, asciiCapable: Bool) -> InputSourceKind {
        switch type {
        case .keyboardLayout: asciiCapable ? .asciiLayout : .nonASCIILayout
        case .inputMethod, .other: .inputMethod
        case .inputMode: .inputMode
        }
    }

    /// PLT-R372 without an ID literal: the source's primary language is Vietnamese and it is not a plain
    /// ASCII-capable layout (so it transforms keys or produces Vietnamese letters itself, and a second
    /// transformer would conflict).
    static func isVietnameseTransformer(kind: InputSourceKind, languages: [String]) -> Bool {
        guard kind != .asciiLayout, let primary = languages.first?.lowercased() else { return false }
        return primary == "vi" || primary.hasPrefix("vi-") || primary.hasPrefix("vi_")
    }

    /// Text Input Source IDs are normally reverse-DNS; third-party layouts may contain other characters. Those
    /// are replaced so the ID stays a valid metadata identifier (PLT-R362, PLT-R902).
    static func sanitizedID(_ raw: String) -> InputSourceID {
        if let id = InputSourceID(rawValue: raw) { return id }
        let allowed = raw.unicodeScalars.map { scalar -> Character in
            let value = scalar.value
            let valid =
                (value >= 0x30 && value <= 0x39) || (value >= 0x41 && value <= 0x5A) || (value >= 0x61 && value <= 0x7A)
                || value == 0x2E || value == 0x2D || value == 0x5F
            return valid ? Character(scalar) : "_"
        }
        let cleaned = String(String(allowed).prefix(255))
        return InputSourceID(rawValue: cleaned.isEmpty ? "unknown" : cleaned) ?? InputSourceID(rawValue: "unknown")!
    }
}
