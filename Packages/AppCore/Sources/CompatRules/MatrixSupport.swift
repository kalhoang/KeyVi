// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Loading and display rules for compat/matrix.json (QA-R17, QA-R19, PRD-R35).

public import Foundation

/// Reads compat-matrix.json from the app bundle or compat/matrix.json in CI.
public enum MatrixLoader {
    public static let supportedSchemaVersion = 1

    /// Strict decode: unknown keys and other schema versions are rejected.
    public static func decode(_ data: Data) throws(RulesValidationError) -> MatrixDocument {
        let document = try StrictJSON.decode(
            MatrixDocument.self, from: data, allowedRootKeys: RulesDecoding.allowedRootKeys)
        guard document.schemaVersion == supportedSchemaVersion else {
            throw .unsupportedSchemaVersion(document.schemaVersion)
        }
        return document
    }

    /// Nil when the file is missing or invalid: every app then shows as not verified (PRD-R35).
    public static func load(contentsOf url: URL) -> MatrixDocument? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decode(data)
    }
}

/// QA-R19: entries not verified for 120 days display as not verified.
enum MatrixFreshness {
    static let staleAfterDays = 120

    static func displayStatus(_ entry: MatrixEntry, today: Date) -> MatrixStatus {
        guard entry.status != .notVerified, let raw = entry.lastVerified, let verified = ISODay(raw) else {
            return .notVerified
        }
        return ISODay(today).days(since: verified) > staleAfterDays ? .notVerified : entry.status
    }
}
