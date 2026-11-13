// SPDX-License-Identifier: LicenseRef-App-Pending
//
// System Settings (macOS 13 and later) and System Preferences (macOS 12) pane names and deep links keyed by macOS
// version and the MACOS language (PLT-R704, PRD-R64, ADR 0315), loaded from the resource `SystemPanes.json`. UI
// copy is in the interface language; pane names quoted inside it are in the system language so they match what
// the user sees on screen.
//
// SystemPanes.json shape:
// { "schemaVersion": 1,
//   "entries": [ { "macOS": {"min": "13.0", "max": "26.99"},
//                  "names": { "vi": {"systemSettings": "Cài đặt hệ thống", "privacySecurity": "...",
//                                    "accessibility": "Trợ năng", "inputMonitoring": "...", "keyboard": "...",
//                                    "textReplacements": "...", "usersGroups": "...", "loginItems": "..."},
//                             "en": {...} },
//                  "deepLinks": { "accessibility": "x-apple.systempreferences:...", ... } } ] }
// Every entry is VERIFY on a real system in that language and version before release.

public import AppModel
public import Foundation

public enum SystemPane: String, Sendable, Hashable, CaseIterable {
    case accessibility, inputMonitoring, keyboard, inputSources, loginItems
}

public struct SystemPaneNames: Sendable, Hashable, Codable {
    /// "System Settings" from macOS 13, "System Preferences" on macOS 12.
    public var systemSettings: String
    public var privacySecurity: String
    public var accessibility: String  // "Device Control and Data Access" on macOS 27 (PLT-R701)
    public var inputMonitoring: String
    public var keyboard: String
    public var textReplacements: String
    /// The pane that holds Login Items: "Users & Groups" on macOS 12, "General" from macOS 13.
    public var usersGroups: String
    public var loginItems: String

    public init(
        systemSettings: String, privacySecurity: String, accessibility: String, inputMonitoring: String,
        keyboard: String, textReplacements: String, usersGroups: String, loginItems: String
    ) {
        self.systemSettings = systemSettings
        self.privacySecurity = privacySecurity
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring
        self.keyboard = keyboard
        self.textReplacements = textReplacements
        self.usersGroups = usersGroups
        self.loginItems = loginItems
    }
}

/// Why `SystemPanes.json` was rejected (a build error: the resource ships with the app).
public enum SystemPaneTableError: Error, Sendable, Hashable {
    case unsupportedSchema(Int)
    case noEntries
    case missingEnglishNames(entry: Int)
    case invalidDeepLink(entry: Int, pane: String)
}

public struct SystemPaneTable: Sendable {
    public static let schemaVersion = 1
    /// Language used when the macOS language has no names in the table.
    static let fallbackLanguage = "en"

    private struct Document: Decodable {
        var schemaVersion: Int
        var entries: [Entry]
    }

    private struct Entry: Decodable {
        var macOS: VersionRange
        var names: [String: SystemPaneNames]
        var deepLinks: [String: String]
    }

    private let entries: [Entry]

    public init(resource: Data) throws {
        let document = try JSONDecoder().decode(Document.self, from: resource)
        guard document.schemaVersion == Self.schemaVersion else {
            throw SystemPaneTableError.unsupportedSchema(document.schemaVersion)
        }
        guard !document.entries.isEmpty else { throw SystemPaneTableError.noEntries }
        for (index, entry) in document.entries.enumerated() {
            guard entry.names[Self.fallbackLanguage] != nil else {
                throw SystemPaneTableError.missingEnglishNames(entry: index)
            }
            for (pane, link) in entry.deepLinks where URL(string: link)?.scheme == nil {
                throw SystemPaneTableError.invalidDeepLink(entry: index, pane: pane)
            }
        }
        entries = document.entries
    }

    /// `systemLanguage` is the macOS primary language (BCP 47); unknown languages fall back to English.
    public func names(macOS: LooseVersion, systemLanguage: String) -> SystemPaneNames {
        let names = entry(for: macOS).names
        let language = Self.primaryLanguage(systemLanguage)
        // Every entry has English names (checked in `init`).
        return names[language] ?? names[Self.fallbackLanguage]!
    }

    public func deepLink(_ pane: SystemPane, macOS: LooseVersion) -> URL? {
        entry(for: macOS).deepLinks[pane.rawValue].flatMap(URL.init(string:))
    }

    /// The entry whose range contains `macOS`; outside every range, the nearest one (a newer macOS than the
    /// table knows uses the newest entry until the table is updated).
    private func entry(for macOS: LooseVersion) -> Entry {
        if let match = entries.first(where: { $0.macOS.contains(macOS) }) { return match }
        let older = entries.filter { range in range.macOS.max.map { $0 < macOS } ?? false }
        let newest = older.max { ($0.macOS.max ?? macOS) < ($1.macOS.max ?? macOS) }
        return newest ?? entries[0]
    }

    /// "vi-VN" -> "vi", "en_GB" -> "en", "zh-Hant-TW" -> "zh".
    static func primaryLanguage(_ tag: String) -> String {
        let separators = CharacterSet(charactersIn: "-_")
        return tag.components(separatedBy: separators).first?.lowercased() ?? fallbackLanguage
    }
}
