// SPDX-License-Identifier: LicenseRef-App-Pending
//
// "Khôi phục mặc định" per pane and globally (PRD-R26): always confirmed, always offers an export first, and
// never deletes macros unless the user ticks the separate checkbox.

public import SettingsStore

/// The panes with their own reset button. About & Support hosts the global one.
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
    /// The store's own scope (backs up each affected file first, PLT-R1006).
    public var storeScope: ResetScope?
    /// Macros pane: D9 (and the hidden D10) back to "unset" so they follow future defaults (PRD-R6).
    public var unsetsMacroSwitches: Bool
    /// Macros pane with the checkbox ticked: the list is emptied.
    public var deletesMacroList: Bool
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
        case .all:
            return ResetPlan(
                storeScope: .all(includeMacros: deletes), unsetsMacroSwitches: false, deletesMacroList: false)
        case .pane(.general):
            return ResetPlan(storeScope: .general, unsetsMacroSwitches: false, deletesMacroList: false)
        case .pane(.typing): return ResetPlan(storeScope: .typing, unsetsMacroSwitches: false, deletesMacroList: false)
        case .pane(.apps): return ResetPlan(storeScope: .apps, unsetsMacroSwitches: false, deletesMacroList: false)
        case .pane(.macros): return ResetPlan(storeScope: nil, unsetsMacroSwitches: true, deletesMacroList: deletes)
        }
    }
}
