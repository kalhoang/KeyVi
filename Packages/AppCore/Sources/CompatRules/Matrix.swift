// SPDX-License-Identifier: LicenseRef-App-Pending
//
// compat/matrix.json: verification status (02-platform.md 13.3, QA-R17), a separate file and schema from the
// behaviour rules. Single source for the Apps pane and the website matrix (PRD-R35, PRD-R38).

public import AppModel
public import Foundation

public struct MatrixDocument: Sendable, Hashable, Codable {
    public var schemaVersion: Int
    public var entries: [MatrixEntry]
}

public struct MatrixEntry: Sendable, Hashable, Codable {
    public var bundleId: BundleKey
    public var displayName: String
    public var category: String
    public var tier: Int?  // 1 or 2 (PRD-R39)
    public var ruleId: RuleID?
    public var status: MatrixStatus
    public var note: LocalizedNote?
    public var lastVerified: String?  // ISO date
    public var appVersion: String?
    public var macOS: String?
    public var verifier: String?
    public var issues: [Int]
    public var checks: MatrixChecks?
}

/// User-facing values (PRD-R35).
public enum MatrixStatus: String, Sendable, Hashable, Codable, CaseIterable {
    case works, worksWithNotes, notVerified, knownLimitation
}

public struct LocalizedNote: Sendable, Hashable, Codable {
    public var vi: String
    public var en: String
}

/// Columns of 13.3.
public struct MatrixChecks: Sendable, Hashable, Codable {
    public var telexBasic: MatrixCell?
    public var vniBasic: MatrixCell?
    public var inlineCompletion: MatrixCell?
    public var burstTyping: MatrixCell?
    public var backspaceReentry: MatrixCell?
    public var restoreHotkey: MatrixCell?
    public var perAppMemory: MatrixCell?
    public var macroExpansion: MatrixCell?
}

public struct MatrixCell: Sendable, Hashable, Codable {
    public enum Result: String, Sendable, Hashable, Codable {
        case pass, fail
        case notApplicable = "n/a"
    }

    public var result: Result
    public var date: String
    public var tester: String
}

public enum MatrixStatusResolver {
    /// Entries not verified for 120 days display as `notVerified` (QA-R19).
    public static func displayStatus(_ entry: MatrixEntry, today: Date) -> MatrixStatus { unimplemented() }
}
