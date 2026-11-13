// SPDX-License-Identifier: LicenseRef-App-Pending
//
// System Settings pane names and deep links keyed by macOS version and the MACOS language (PLT-R704, PRD-R64),
// loaded from the resource `SystemPanes.json`. UI copy is in the interface language; pane names quoted inside
// it are in the system language so they match what the user sees in System Settings.
//
// SystemPanes.json shape:
// { "schemaVersion": 1,
//   "entries": [ { "macOS": {"min": "15.0", "max": "26.99"},
//                  "names": { "vi": {"systemSettings": "Cài đặt hệ thống", "privacySecurity": "...",
//                                    "accessibility": "Trợ năng", "inputMonitoring": "...", "keyboard": "...",
//                                    "textReplacements": "..."},
//                             "en": {...} },
//                  "deepLinks": { "accessibility": "x-apple.systempreferences:...", ... } } ] }
// Every entry is VERIFY on a real system in that language and version before release.

public import AppModel
public import Foundation

public enum SystemPane: String, Sendable, Hashable, CaseIterable {
    case accessibility, inputMonitoring, keyboard, inputSources, loginItems
}

public struct SystemPaneNames: Sendable, Hashable {
    public var systemSettings: String
    public var privacySecurity: String
    public var accessibility: String  // "Device Control and Data Access" on macOS 27 (PLT-R701)
    public var inputMonitoring: String
    public var keyboard: String
    public var textReplacements: String
}

public struct SystemPaneTable: Sendable {
    public init(resource: Data) throws { unimplemented() }
    /// `systemLanguage` is the macOS primary language (BCP 47); unknown languages fall back to English.
    public func names(macOS: LooseVersion, systemLanguage: String) -> SystemPaneNames { unimplemented() }
    public func deepLink(_ pane: SystemPane, macOS: LooseVersion) -> URL? { unimplemented() }
}
