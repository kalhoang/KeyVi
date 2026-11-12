// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Apps pane model (PRD-R34-R38).

public import AppModel
public import CompatRules
public import Foundation
public import SettingsStore

public struct AppsPaneRow: Sendable, Hashable, Identifiable {
    public var id: BundleKey { bundle }
    public var bundle: BundleKey
    public var rule: PerAppRule  // Nhớ lựa chọn / Luôn tiếng Anh / Luôn tiếng Việt / Bỏ qua
    public var rememberedMode: TypingMode?
    public var status: MatrixStatus  // after the 120-day rule (QA-R19)
    public var note: LocalizedNote?
    public var compatibilityMode: CompatibilityModeChoice
}

/// PRD-R36: "Chế độ tương thích" under Advanced, at most three plain choices plus automatic. Choosing one writes
/// a user override (scope "this app", PLT-R540) and attaches it to the next bug report for that app.
public enum CompatibilityModeChoice: String, Sendable, Hashable, CaseIterable {
    case automatic  // reset to automatic (removes the override)
    case typeSlower  // backspaceReplace with 5 ms pacing
    case selectThenType  // selectReplace
    case pasteText  // paste, requiresUserOptIn, clipboard explanation (PLT-R460, PLT-R462)

    public func overrideRule(for bundle: BundleKey, date: String) -> JSONValue? { unimplemented() }
}

public enum AppsPaneModel {
    /// Most recent first: apps typed in (memory order) plus apps with explicit rules (PRD-R34).
    public static func rows(
        appModes: AppModesDocument, overrides: [StoredRuleOverride], matrix: MatrixDocument?, today: Date
    ) -> [AppsPaneRow] { unimplemented() }
}
