// SPDX-License-Identifier: LicenseRef-App-Pending
//
// compat/matrix.json: verification status (02-platform.md 13.3, QA-R17), a separate file and schema from the
// behaviour rules. Single source for the Apps pane and the website matrix (PRD-R35, PRD-R38).

public import AppModel
public import Foundation

public struct MatrixDocument: Sendable, Hashable, Codable {
    public var schemaVersion: Int
    public var entries: [MatrixEntry]

    public init(schemaVersion: Int, entries: [MatrixEntry]) {
        self.schemaVersion = schemaVersion
        self.entries = entries
    }
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
    /// Absent or `app` for the row that stands for the whole app (one per bundle ID, the Apps pane status);
    /// `webApp` or `inApp` for a row about a web app or a tool inside the host app (same bundle ID).
    public var scope: MatrixScope?

    public init(
        bundleId: BundleKey, displayName: String, category: String, tier: Int? = nil, ruleId: RuleID? = nil,
        status: MatrixStatus, note: LocalizedNote? = nil, lastVerified: String? = nil, appVersion: String? = nil,
        macOS: String? = nil, verifier: String? = nil, issues: [Int] = [], checks: MatrixChecks? = nil,
        scope: MatrixScope? = nil
    ) {
        self.bundleId = bundleId
        self.displayName = displayName
        self.category = category
        self.tier = tier
        self.ruleId = ruleId
        self.status = status
        self.note = note
        self.lastVerified = lastVerified
        self.appVersion = appVersion
        self.macOS = macOS
        self.verifier = verifier
        self.issues = issues
        self.checks = checks
        self.scope = scope
    }
}

/// What a matrix row is about (PRD-R34, PRD-R35): the app itself, a web app inside a browser, or a tool inside
/// the host app (tmux in a terminal, an editor's integrated terminal).
public enum MatrixScope: String, Sendable, Hashable, Codable, CaseIterable {
    case app, webApp, inApp
}

/// User-facing values (PRD-R35).
public enum MatrixStatus: String, Sendable, Hashable, Codable, CaseIterable {
    case works, worksWithNotes, notVerified, knownLimitation
}

public struct LocalizedNote: Sendable, Hashable, Codable {
    public var vi: String
    public var en: String

    public init(vi: String, en: String) {
        self.vi = vi
        self.en = en
    }
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

    public init(
        telexBasic: MatrixCell? = nil, vniBasic: MatrixCell? = nil, inlineCompletion: MatrixCell? = nil,
        burstTyping: MatrixCell? = nil, backspaceReentry: MatrixCell? = nil, restoreHotkey: MatrixCell? = nil,
        perAppMemory: MatrixCell? = nil, macroExpansion: MatrixCell? = nil
    ) {
        self.telexBasic = telexBasic
        self.vniBasic = vniBasic
        self.inlineCompletion = inlineCompletion
        self.burstTyping = burstTyping
        self.backspaceReentry = backspaceReentry
        self.restoreHotkey = restoreHotkey
        self.perAppMemory = perAppMemory
        self.macroExpansion = macroExpansion
    }
}

public struct MatrixCell: Sendable, Hashable, Codable {
    public enum Result: String, Sendable, Hashable, Codable {
        case pass, fail
        case notApplicable = "n/a"
    }

    public var result: Result
    public var date: String
    public var tester: String

    public init(result: Result, date: String, tester: String) {
        self.result = result
        self.date = date
        self.tester = tester
    }
}

public enum MatrixStatusResolver {
    /// Entries not verified for 120 days display as `notVerified` (QA-R19).
    public static func displayStatus(_ entry: MatrixEntry, today: Date) -> MatrixStatus {
        MatrixFreshness.displayStatus(entry, today: today)
    }
}
