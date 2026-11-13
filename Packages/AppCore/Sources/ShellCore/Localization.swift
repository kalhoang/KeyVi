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
    case common = "Common"  // buttons, app-wide words
    case menu = "Menu"  // status item, menu, HUD, VoiceOver labels (PRD-R10, PRD-R11)
    case status = "Status"  // status lines and error states (PRD-R43), secure-input hints (PLT-R397)
    case onboarding = "Onboarding"  // PRD-R40 screens 1-8
    case settings = "Settings"  // five panes (PRD-R24, PRD-R25)
    case macros = "Macros"  // section 8
    case apps = "Apps"  // section 9
    case diagnostics = "Diagnostics"  // PLT-R1201, PLT-R1205, PRD-R47
    case support = "Support"  // About & Support, donation block (PRD-R59)
    case updates = "Updates"  // PRD-R50-R54
}

/// Resolves keys for one language. Immutable; a new instance is created on language change.
public struct Localizer: Sendable {
    public let language: InterfaceLanguage
    public let locale: Locale

    /// `appBundle` contains `vi.lproj` and `en.lproj`.
    public init(language: InterfaceLanguage, appBundle: Bundle) { unimplemented() }

    /// Looks up `key` in `table` of the selected language's lproj; falls back to Vietnamese, then to the key
    /// itself (a missing key is a test failure, never a crash).
    public func string(_ key: String, table: StringTable) -> String { unimplemented() }

    /// Format with arguments (the app name is always an argument, never part of the copy):
    /// `String(format:locale:arguments:)` over the localized format, so `.stringsdict` plural rules apply.
    public func format(_ key: String, table: StringTable, _ arguments: any CVarArg...) -> String { unimplemented() }

    /// PRD-R65: dates, numbers and versions in the selected language.
    public func formatDate(_ date: Date) -> String { unimplemented() }
    public func formatNumber(_ number: Int) -> String { unimplemented() }
}

/// Observable current language for SwiftUI views and AppKit controllers (menus rebuild on open).
@MainActor
@Observable
public final class InterfaceLanguageModel {
    public private(set) var localizer: Localizer
    public init(language: InterfaceLanguage, appBundle: Bundle) { unimplemented() }
    /// Called when settings change; views observing `localizer` re-render (PRD-R63).
    public func select(_ language: InterfaceLanguage) { unimplemented() }
}
