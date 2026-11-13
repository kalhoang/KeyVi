// SPDX-License-Identifier: GPL-3.0-or-later
//
// Validated metadata identifiers. They are the only string-like values the typed logger accepts without
// redaction (PLT-R902): their character set and length make it impossible to carry typed content in them.

/// Bundle identifier of a focus owner, or the SHA-256 of the executable path for processes without a bundle
/// identifier (PLT-R393). Never constructed from a string literal in application code (PLT-R501).
public struct BundleKey: RawRepresentable, Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    /// Key for a process without a bundle identifier: `sha256:<64 lowercase hex>` (PLT-R393).
    public static func executable(sha256Hex: String) -> BundleKey? {
        let hex = sha256Hex.lowercased()
        guard hex.utf8.count == 64, hex.utf8.allSatisfy(Self.isHexDigit) else { return nil }
        return BundleKey(rawValue: "sha256:" + hex)
    }

    public var isExecutableHash: Bool { rawValue.hasPrefix("sha256:") }
    public var description: String { rawValue }
    public static func < (lhs: BundleKey, rhs: BundleKey) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let key = BundleKey(rawValue: raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "invalid bundle key"))
        }
        self = key
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func isValid(_ raw: String) -> Bool {
        if raw.hasPrefix("sha256:") {
            let hex = raw.utf8.dropFirst(7)
            return hex.count == 64 && hex.allSatisfy(isHexDigit)
        }
        guard (1...255).contains(raw.utf8.count) else { return false }
        return raw.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2E || byte == 0x2D || byte == 0x5F
        }
    }

    static func isHexDigit(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
    }
}

/// Stable dotted rule identifier (02-platform.md 5.4 `id`), for example `terminal.default` or `user.ignore.3`.
public struct RuleID: RawRepresentable, Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard (1...128).contains(rawValue.utf8.count) else { return nil }
        let segments = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        let valid = segments.allSatisfy { segment in
            !segment.isEmpty
                && segment.utf8.allSatisfy { byte in
                    (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
                        || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D || byte == 0x5F
                }
        }
        guard valid else { return nil }
        self.rawValue = rawValue
    }

    public var isUserOverride: Bool { rawValue.hasPrefix("user.") }
    public var description: String { rawValue }
    public static func < (lhs: RuleID, rhs: RuleID) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let id = RuleID(rawValue: raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "invalid rule id"))
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Text Input Source identifier of a keyboard layout or input method (PLT-R362), for example the ABC layout.
public struct InputSourceID: RawRepresentable, Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard BundleKey.isValid(rawValue), !rawValue.hasPrefix("sha256:") else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// Virtual key code (`CGKeyCode`). Layout-independent position of a physical key.
public struct KeyCode: RawRepresentable, Sendable, Hashable, Codable, Comparable, BitwiseCopyable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static func < (lhs: KeyCode, rhs: KeyCode) -> Bool { lhs.rawValue < rhs.rawValue }

    // Layout-independent keys used by the platform (Carbon kVK_* values; positions, not characters).
    public static let returnKey = KeyCode(rawValue: 0x24)
    public static let tab = KeyCode(rawValue: 0x30)
    public static let space = KeyCode(rawValue: 0x31)
    public static let delete = KeyCode(rawValue: 0x33)  // backspace (PLT-R407)
    public static let escape = KeyCode(rawValue: 0x35)
    public static let rightCommand = KeyCode(rawValue: 0x36)
    public static let command = KeyCode(rawValue: 0x37)
    public static let shift = KeyCode(rawValue: 0x38)
    public static let capsLock = KeyCode(rawValue: 0x39)
    public static let option = KeyCode(rawValue: 0x3A)
    public static let control = KeyCode(rawValue: 0x3B)
    public static let rightShift = KeyCode(rawValue: 0x3C)
    public static let rightOption = KeyCode(rawValue: 0x3D)
    public static let rightControl = KeyCode(rawValue: 0x3E)
    public static let function = KeyCode(rawValue: 0x3F)
    public static let forwardDelete = KeyCode(rawValue: 0x75)
    public static let home = KeyCode(rawValue: 0x73)
    public static let end = KeyCode(rawValue: 0x77)
    public static let pageUp = KeyCode(rawValue: 0x74)
    public static let pageDown = KeyCode(rawValue: 0x79)
    public static let leftArrow = KeyCode(rawValue: 0x7B)
    public static let rightArrow = KeyCode(rawValue: 0x7C)
    public static let downArrow = KeyCode(rawValue: 0x7D)
    public static let upArrow = KeyCode(rawValue: 0x7E)
    public static let keypadEnter = KeyCode(rawValue: 0x4C)
}

/// Monotonic counter of focus contexts (PLT-R316, PLT-R383). Every job records the generation it was built for.
public struct FocusGeneration: RawRepresentable, Sendable, Hashable, Comparable, Codable, BitwiseCopyable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static let initial = FocusGeneration(rawValue: 0)
    public var next: FocusGeneration { FocusGeneration(rawValue: rawValue &+ 1) }
    public static func < (lhs: FocusGeneration, rhs: FocusGeneration) -> Bool { lhs.rawValue < rhs.rawValue }
}
