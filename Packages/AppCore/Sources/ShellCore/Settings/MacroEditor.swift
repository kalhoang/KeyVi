// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Macros pane list (PRD-R31): search, sort, add, edit, duplicate, delete, enable or disable one or all.
// Pure value state; the window saves `macros` through `SettingsStore.replaceMacros` after each change. Macro
// content is user data: never logged, never in diagnostics (PRD-R33).

public import Foundation
public import SettingsStore

public enum MacroSortOrder: String, Sendable, Hashable, CaseIterable {
    case orderAdded, shortcut, expansion

    public var title: MacrosText {
        switch self {
        case .orderAdded: .sortOrderAdded
        case .shortcut: .sortShortcut
        case .expansion: .sortExpansion
        }
    }
}

public enum MacroSaveError: Error, Sendable, Hashable {
    /// The draft itself is invalid (PRD-R29); shown under the field.
    case invalid(MacroRowIssue)
    /// The engine rejected the resulting table (ENG-R1103); shown with the row it concerns.
    case rejectedByEngine(MacroTableProblem)
    /// The edited macro no longer exists.
    case notFound
}

public struct MacroListState: Sendable, Hashable {
    /// Stored order is the order added (`orderAdded` sort).
    public private(set) var macros: [StoredMacro]
    public var searchText = ""
    public var sort = MacroSortOrder.orderAdded

    public init(macros: [StoredMacro]) { self.macros = macros }

    /// Filtered by shortcut or text (ignoring case and marks) and sorted.
    public var visible: [StoredMacro] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered =
            query.isEmpty
            ? macros
            : macros.filter { Self.matches($0.trigger, query) || Self.matches($0.expansion, query) }
        switch sort {
        case .orderAdded: return filtered
        case .shortcut: return filtered.sorted { Self.ascending($0.trigger, $1.trigger) }
        case .expansion: return filtered.sorted { Self.ascending($0.expansion, $1.expansion) }
        }
    }

    public var isEmpty: Bool { macros.isEmpty }
    public var allEnabled: Bool { macros.allSatisfy(\.enabled) }
    public var allDisabled: Bool { macros.allSatisfy { !$0.enabled } }

    /// Problems in the stored list (for example after editing macros.json by hand), per row.
    public var rowIssues: [UUID: MacroRowIssue] {
        var issues: [UUID: MacroRowIssue] = [:]
        for macro in macros {
            let others = macros.filter { $0.id != macro.id }
            if let issue = MacroValidator.issue(shortcut: macro.trigger, expansion: macro.expansion, others: others) {
                issues[macro.id] = issue
            }
        }
        return issues
    }

    public func draft(for id: UUID) -> MacroDraft? { macros.first { $0.id == id }.map(MacroDraft.init(editing:)) }

    /// "Nhân bản": a new draft with the same content. Saving it unchanged is refused as a duplicate, so the user
    /// edits the shortcut first (PRD-R31).
    public func duplicateDraft(of id: UUID) -> MacroDraft? {
        guard let macro = macros.first(where: { $0.id == id }) else { return nil }
        return MacroDraft(
            shortcut: macro.trigger, expansion: macro.expansion, adaptCase: macro.adaptCase, enabled: macro.enabled)
    }

    /// Adds or replaces the draft's macro after validating it (PRD-R29) and the resulting table (engine).
    public mutating func save(_ draft: MacroDraft, newID: () -> UUID = UUID.init) -> Result<StoredMacro, MacroSaveError>
    {
        let check = MacroDraftValidator.check(draft, among: macros)
        if let issue = check.issue { return .failure(.invalid(issue)) }
        var next = macros
        let macro = StoredMacro(
            id: draft.id ?? newID(), trigger: draft.shortcut,
            expansion: MacroDraftValidator.normalizedExpansion(draft.expansion), adaptCase: draft.adaptCase,
            enabled: draft.enabled)
        if let id = draft.id {
            guard let index = next.firstIndex(where: { $0.id == id }) else { return .failure(.notFound) }
            next[index] = macro
        } else {
            next.append(macro)
        }
        if let problem = MacroDraftValidator.engineProblem(in: next) { return .failure(.rejectedByEngine(problem)) }
        macros = next
        return .success(macro)
    }

    public mutating func delete(_ id: UUID) { macros.removeAll { $0.id == id } }

    public mutating func setEnabled(_ enabled: Bool, for id: UUID) {
        guard let index = macros.firstIndex(where: { $0.id == id }) else { return }
        macros[index].enabled = enabled
    }

    public mutating func setAllEnabled(_ enabled: Bool) {
        for index in macros.indices { macros[index].enabled = enabled }
    }

    /// Replaces the list with the store's (another window or an import changed it).
    public mutating func replace(with macros: [StoredMacro]) { self.macros = macros }

    private static func matches(_ text: String, _ query: String) -> Bool {
        text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func ascending(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}
