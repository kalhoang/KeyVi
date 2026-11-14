// SPDX-License-Identifier: GPL-3.0-or-later
//
// "Khôi phục mặc định" per pane and globally (PRD-R26): always confirmed, always offers an export first, and
// never deletes macros unless the user ticks the separate checkbox.

public import SettingsStore

/// The panes with their own reset button. The Support pane hosts the global one.
public enum PaneReset: String, Sendable, Hashable, CaseIterable {
    case general, typing, apps, macros

    public var pane: SettingsPaneKind {
        switch self {
        case .general: .general
        case .typing: .typing
        case .apps: .apps
        case .macros: .macros
        }
    }
}

public enum ResetTarget: Sendable, Hashable {
    case pane(PaneReset)
    case all
}

/// What a confirmed reset does to the store.
public struct ResetPlan: Sendable, Hashable {
    /// The store's own scope, which backs up each affected file first (PLT-R1006). The Macros pane uses
    /// `.macros(includeList:)`: D9 and D10 back to "unset" (PRD-R6), the list emptied only when ticked.
    public var storeScope: ResetScope

    public init(storeScope: ResetScope) { self.storeScope = storeScope }
}

/// State of the confirmation sheet.
public struct ResetRequest: Sendable, Hashable {
    public let target: ResetTarget
    /// PRD-R26: a separate checkbox, unticked by default.
    public var deleteMacros = false
    /// File name of the export made from this sheet, shown as a confirmation.
    public var exportedFileName: String?

    public init(target: ResetTarget) { self.target = target }

    /// PRD-R26: every reset offers an export of the current settings first.
    public var offersExportFirst: Bool { true }

    /// Only the resets that could touch macros show the checkbox.
    public var offersMacroDeletion: Bool {
        switch target {
        case .all, .pane(.macros): true
        case .pane: false
        }
    }

    public func title(_ localizer: Localizer) -> String {
        switch target {
        case .all: localizer.string(SettingsText.resetTitleAll)
        case .pane(let pane): localizer.format(SettingsText.resetTitlePane, localizer.string(pane.pane.title))
        }
    }

    public var body: SettingsText {
        switch target {
        case .all: .resetBodyAll
        case .pane(.general): .resetBodyGeneral
        case .pane(.typing): .resetBodyTyping
        case .pane(.apps): .resetBodyApps
        case .pane(.macros): .resetBodyMacros
        }
    }

    public var plan: ResetPlan {
        let deletes = offersMacroDeletion && deleteMacros
        switch target {
        case .all: return ResetPlan(storeScope: .all(includeMacros: deletes))
        case .pane(.general): return ResetPlan(storeScope: .general)
        case .pane(.typing): return ResetPlan(storeScope: .typing)
        case .pane(.apps): return ResetPlan(storeScope: .apps)
        case .pane(.macros): return ResetPlan(storeScope: .macros(includeList: deletes))
        }
    }
}
