// SPDX-License-Identifier: GPL-3.0-or-later

internal import AppModel
internal import CryptoKit
internal import Security

/// Per-install random salt (32 bytes) for hashed redaction (PLT-R902). Stored in the app's user defaults
/// domain (not in the settings folder) so exports never carry it.
public struct RedactionSalt: Sendable, Hashable {
    public let bytes: [UInt8]
    public init(bytes: [UInt8]) {
        precondition(bytes.count == 32, "salt must be 32 bytes")
        self.bytes = bytes
    }

    /// CSPRNG (`SecRandomCopyBytes`). Falls back to the system generator (`arc4random_buf`, also a CSPRNG) in
    /// the practically impossible case that Security reports an error.
    public static func random() -> RedactionSalt {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        if status != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            bytes = bytes.map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return RedactionSalt(bytes: bytes)
    }
}

/// The only way a dynamic string enters a log record (PLT-R902). Either a salted, truncated SHA-256
/// (`h:3fa9c1d2e4b5a697`) or a fixed marker. There is no initializer that keeps the original text.
public struct Redacted: Sendable, Hashable, Codable, CustomStringConvertible {
    public let description: String
    private init(description: String) { self.description = description }

    /// HMAC-SHA-256 keyed with the install salt (the salted SHA-256 construction that is not open to length
    /// extension), truncated to 8 bytes and written as `h:` plus 16 lowercase hex digits. The same value hashes
    /// to the same marker within one install, so logs can correlate events without revealing the value.
    public static func hashed(_ value: some StringProtocol, salt: RedactionSalt) -> Redacted {
        let code = HMAC<SHA256>.authenticationCode(for: Array(value.utf8), using: SymmetricKey(data: salt.bytes))
        return Redacted(description: "h:" + HexEncoding.lowercase(code.prefix(8)))
    }

    public static let dropped = Redacted(description: "<dropped>")
}

enum HexEncoding {
    static func lowercase(_ bytes: some Sequence<UInt8>) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var output: [UInt8] = []
        for byte in bytes {
            output.append(digits[Int(byte >> 4)])
            output.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: output, as: UTF8.self)
    }
}

/// Sanitising of the few free `String` fields that typed metadata still carries (bundle metadata, AX roles,
/// version strings). Logs accept only token-shaped values (PLT-R902); reports keep metadata but never let a
/// value break the line format (ADR 0501 rule 2).
enum MetadataText {
    /// The value if it is a metadata token (ASCII letters, digits and `. _ - + :`, at most `maxLength`
    /// characters), else nil. Spaces, non-ASCII letters and punctuation are rejected, so prose cannot pass.
    static func token(_ value: String, maxLength: Int = 64) -> String? {
        guard !value.isEmpty, value.utf8.count <= maxLength else { return nil }
        let allowed = value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2E || byte == 0x5F || byte == 0x2D || byte == 0x2B || byte == 0x3A
        }
        return allowed ? value : nil
    }

    /// `token` or the fixed drop marker, for log fields.
    static func logToken(_ value: String) -> String {
        token(value) ?? Redacted.dropped.description
    }

    /// One line of at most `maxLength` characters: control characters and line or paragraph separators
    /// (everything Python's `splitlines` breaks on) become spaces, surrounding whitespace is trimmed and
    /// leading backticks or tildes are removed so a value can never close a fenced block.
    static func singleLine(_ value: String, maxLength: Int = 200) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: scalars.append(" ")
            default: scalars.append(scalar)
            }
        }
        var line = Substring(String(scalars).prefix(maxLength))
        while let first = line.first, first == "`" || first == "~" || first.isWhitespace { line = line.dropFirst() }
        while let last = line.last, last.isWhitespace { line = line.dropLast() }
        return String(line)
    }
}
