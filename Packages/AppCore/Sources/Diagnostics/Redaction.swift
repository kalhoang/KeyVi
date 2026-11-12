// SPDX-License-Identifier: LicenseRef-App-Pending

internal import AppModel

/// Per-install random salt (32 bytes) for hashed redaction (PLT-R902). Stored in the app's user defaults
/// domain (not in the settings folder) so exports never carry it.
public struct RedactionSalt: Sendable, Hashable {
    public let bytes: [UInt8]
    public init(bytes: [UInt8]) {
        precondition(bytes.count == 32, "salt must be 32 bytes")
        self.bytes = bytes
    }

    /// CSPRNG (`SecRandomCopyBytes`).
    public static func random() -> RedactionSalt { unimplemented() }
}

/// The only way a dynamic string enters a log record (PLT-R902). Either a salted, truncated SHA-256
/// (`h:3fa9c1d2e4b5a697`) or a fixed marker. There is no initializer that keeps the original text.
public struct Redacted: Sendable, Hashable, Codable, CustomStringConvertible {
    public let description: String
    private init(description: String) { self.description = description }

    public static func hashed(_ value: some StringProtocol, salt: RedactionSalt) -> Redacted { unimplemented() }
    public static let dropped = Redacted(description: "<dropped>")
}
