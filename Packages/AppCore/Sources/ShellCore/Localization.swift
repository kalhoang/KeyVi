// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Runtime UI-language switch without restart (PRD-R63, docs/architecture/contracts.md "Localisation").
//
// Strings live in String Catalogs (`App/Resources/Localization/*.xcstrings`, one table per feature area so
// parallel workstreams never edit the same file). Xcode compiles each catalog into `vi.lproj/<Table>.strings`
// and `en.lproj/<Table>.strings(dict)`. Lookup NEVER relies on the process's preferred languages: the
// `Localizer` opens the `.lproj` sub-bundle of the language selected in Settings (D18) and resolves every key
// there, so switching language re-renders immediately and is independent of the macOS language.

public import AppModel
public import Foundation
public import Observation

/// String tables (catalog file names). Owned per workstream (docs/architecture/workstreams.md).
public enum StringTable: String, Sendable, CaseIterable {
    /// Buttons and app-wide words. Named `Localizable` because it is the default table (ADR 0310).
    case common = "Localizable"
    case menu = "Menu"  // status item, menu, HUD, VoiceOver labels (PRD-R10, PRD-R11)
    case status = "Status"  // status lines and error states (PRD-R43), secure-input hints (PLT-R397)
    case onboarding = "Onboarding"  // PRD-R40 screens 1-8
    case settings = "Settings"  // five panes (PRD-R24, PRD-R25)
    case macros = "Macros"  // section 8
    case apps = "Apps"  // section 9
    case diagnostics = "Diagnostics"  // PLT-R1201, PLT-R1205, PRD-R47
    case support = "Support"  // About & Support, donation block (PRD-R59)
    case updates = "Updates"  // PRD-R50-R54
    case composition = "Composition"  // composition root notices: safe mode, move failed, conflicts
}

/// Resolves keys for one language. Immutable; a new instance is created on language change.
public struct Localizer: Sendable {
    public let language: InterfaceLanguage
    public let locale: Locale
    private let selected: Bundle?
    private let fallback: Bundle?

    /// `appBundle` contains `vi.lproj` and `en.lproj`.
    public init(language: InterfaceLanguage, appBundle: Bundle) {
        self.language = language
        locale = Self.locale(for: language)
        selected = Self.languageBundle(language, in: appBundle)
        // ADR 0310: a key missing in the selected language falls back to Vietnamese, the source language.
        fallback = language == .vietnamese ? nil : Self.languageBundle(.vietnamese, in: appBundle)
    }

    /// Looks up `key` in `table` of the selected language's lproj; falls back to Vietnamese, then to the key
    /// itself (a missing key is a test failure, never a crash).
    public func string(_ key: String, table: StringTable) -> String {
        if let value = Self.lookup(key, table: table, in: selected) { return value }
        if let value = Self.lookup(key, table: table, in: fallback) { return value }
        return key
    }

    /// True when the selected language or the Vietnamese fallback defines `key` (data-driven keys such as
    /// secure-input hints are shown only when copy exists, PLT-R397).
    public func contains(_ key: String, table: StringTable) -> Bool {
        Self.lookup(key, table: table, in: selected) != nil || Self.lookup(key, table: table, in: fallback) != nil
    }

    /// Format with arguments (the app name is always an argument, never part of the copy):
    /// `String(format:locale:arguments:)` over the localized format, so `.stringsdict` plural rules apply.
    public func format(_ key: String, table: StringTable, _ arguments: any CVarArg...) -> String {
        format(key, table: table, arguments: arguments)
    }

    /// Array form of `format(_:table:_:)` for callers that hold the arguments as a list (status lines).
    public func format(_ key: String, table: StringTable, arguments: [any CVarArg]) -> String {
        let template = string(key, table: table)
        guard !arguments.isEmpty else { return template }
        return String(format: template, locale: locale, arguments: arguments)
    }

    /// PRD-R65: dates, numbers and versions in the selected language.
    public func formatDate(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .long, time: .omitted, locale: locale))
    }

    public func formatNumber(_ number: Int) -> String {
        number.formatted(IntegerFormatStyle<Int>(locale: locale))
    }

    /// Countdown of the typing-trace HUD (PLT-R905), `m:ss`.
    public func formatCountdown(_ remaining: Duration) -> String {
        let clamped = max(remaining, .zero)
        return clamped.formatted(Duration.TimeFormatStyle(pattern: .minuteSecond).locale(locale))
    }

    static func locale(for language: InterfaceLanguage) -> Locale {
        switch language {
        case .vietnamese: Locale(identifier: "vi_VN")
        case .english: Locale(identifier: "en_US")
        }
    }

    private static func languageBundle(_ language: InterfaceLanguage, in appBundle: Bundle) -> Bundle? {
        appBundle.path(forResource: language.rawValue, ofType: "lproj").flatMap(Bundle.init(path:))
    }

    /// Sentinel returned by `localizedString` when the key is absent, so a translation that happens to equal
    /// its key is still found.
    private static let missing = "\u{1}missing\u{1}"

    private static func lookup(_ key: String, table: StringTable, in bundle: Bundle?) -> String? {
        guard let bundle else { return nil }
        let value = bundle.localizedString(forKey: key, value: missing, table: table.rawValue)
        return value == missing ? nil : value
    }
}

/// Observable current language for SwiftUI views and AppKit controllers (menus rebuild on open).
@MainActor
@Observable
public final class InterfaceLanguageModel {
    public private(set) var localizer: Localizer
    @ObservationIgnored private let appBundle: Bundle

    public init(language: InterfaceLanguage, appBundle: Bundle) {
        self.appBundle = appBundle
        localizer = Localizer(language: language, appBundle: appBundle)
    }

    /// Called when settings change; views observing `localizer` re-render (PRD-R63).
    public func select(_ language: InterfaceLanguage) {
        guard language != localizer.language else { return }
        localizer = Localizer(language: language, appBundle: appBundle)
    }
}
