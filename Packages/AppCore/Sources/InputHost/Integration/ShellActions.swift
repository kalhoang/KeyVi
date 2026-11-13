// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Pure helpers behind menu and onboarding actions of the composition root: the "type here anyway" user
// override (PLT-R540, 02-platform.md section 6 custom text views), the onboarding macro import (PRD-R40 screen 6,
// PRD-R32) and the support links. Kept here so they are tested without AppKit. Workstream W2-A.

public import AppModel
public import CompatRules
public import Foundation
public import SettingsStore

/// The status line's "paused: no text field detected" action writes one user override for the app with
/// `requireTextFocus: never` and the strategy the app resolves to today, so nothing else changes (PLT-R540).
public enum TextFocusOverride {
    static let ruleIDPrefix = "user.textfocus."

    public static func ruleID(for bundle: BundleKey) -> RuleID {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let cleaned = String(bundle.rawValue.map { allowed.contains($0) ? $0 : "-" })
        let segments = cleaned.split(separator: ".", omittingEmptySubsequences: true).joined(separator: ".")
        let candidate = String((ruleIDPrefix + segments).prefix(128))
        let trimmed = candidate.hasSuffix(".") ? String(candidate.dropLast()) : candidate
        return RuleID(rawValue: trimmed) ?? RuleID(rawValue: "user.textfocus.app")!
    }

    /// `rule-overrides.json` entry (02-platform.md 5.4, user-suggestion provenance). `date` is `YYYY-MM-DD`.
    public static func rule(for bundle: BundleKey, strategy: InjectionStrategy, date: String) -> JSONValue? {
        let rule = Rule(
            id: ruleID(for: bundle), summary: "Typing without a detected text field, chosen from the menu",
            match: RuleMatch(bundleIds: [bundle]), action: RuleAction(strategy: strategy, requireTextFocus: .never),
            provenance: .userSuggestion(UserProvenance(source: "user-suggestion", date: date)))
        guard let data = try? JSONEncoder().encode(rule) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// `YYYY-MM-DD` in UTC, the provenance date format.
    public static func day(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }
}

/// "Use this for me now" of the guided test (PLT-R1205 step 5, PLT-R540): the suggested rule, stored as a user
/// override in `rule-overrides.json`. It applies on the next keystroke.
public enum GuidedTestOverride {
    public static func stored(_ rule: Rule, at date: Date) -> StoredRuleOverride? {
        guard let data = try? JSONEncoder().encode(rule),
            let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }
        return StoredRuleOverride(createdAt: date, rule: json)
    }
}

/// Onboarding screen 6: macros from a file the user picked, merged without touching the user's own macros
/// ("keep mine" for duplicates, PRD-R32). Nil when the format is not recognised or the file is too large.
public enum OnboardingMacroImport {
    /// Reads the picked file, at most `MacroImporter.maxFileBytes` (PLT-R912): one byte more is read only to
    /// detect an oversized file, so a huge file is never loaded into memory. Nil when unreadable or too large.
    public static func read(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data: Data
        do { data = try handle.read(upToCount: MacroImporter.maxFileBytes + 1) ?? Data() } catch { return nil }
        return data.count <= MacroImporter.maxFileBytes ? data : nil
    }

    public static func merged(data: Data, fileExtension: String?, existing: [StoredMacro]) -> [StoredMacro]? {
        guard data.count <= MacroImporter.maxFileBytes,
            let format = MacroImporter.detectFormat(data, fileExtension: fileExtension)
        else { return nil }
        let preview = MacroImporter.preview(MacroImporter.parse(data, format: format), existing: existing)
        return MacroImporter.merge(preview, into: existing, resolution: .keepMine)
    }
}

/// Help pages on the site (support page sections). The host comes from the brand; paths from site/lib/routes.mjs.
public enum SupportLinks {
    public enum Topic: Sendable, Hashable { case permission, secureInput, conflicts, appSpecific }

    public static func url(_ topic: Topic, siteURL: URL, language: InterfaceLanguage) -> URL {
        let path = language == .vietnamese ? "ho-tro/" : "en/support/"
        let anchor: String
        switch (topic, language) {
        case (.permission, .vietnamese): anchor = "quyen"
        case (.permission, .english): anchor = "permission"
        case (.secureInput, .vietnamese): anchor = "nhap-bao-mat"
        case (.secureInput, .english): anchor = "secure-input"
        case (.conflicts, .vietnamese): anchor = "bo-go-khac"
        case (.conflicts, .english): anchor = "conflicts"
        case (.appSpecific, .vietnamese): anchor = "ung-dung-cu-the"
        case (.appSpecific, .english): anchor = "app-specific"
        }
        return URL(string: path + "#" + anchor, relativeTo: siteURL)?.absoluteURL ?? siteURL
    }
}
