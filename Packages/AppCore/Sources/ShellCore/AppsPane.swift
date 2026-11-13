// SPDX-License-Identifier: GPL-3.0-or-later
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
    /// Name from the matrix row, for apps that are not installed (the App prefers the installed app's name).
    public var matrixDisplayName: String?
    /// When the user chose `compatibilityMode` ("set by you on <date>", PLT-R541); nil for automatic.
    public var compatibilitySetOn: Date?
}

/// PRD-R36: "Chế độ tương thích" under Advanced, at most three plain choices plus automatic. Choosing one writes
/// a user override (scope "this app", PLT-R540) and attaches it to the next bug report for that app.
public enum CompatibilityModeChoice: String, Sendable, Hashable, CaseIterable {
    case automatic  // reset to automatic (removes the override)
    case typeSlower  // backspaceReplace with 5 ms pacing
    case selectThenType  // selectReplace
    case pasteText  // paste, requiresUserOptIn, clipboard explanation (PLT-R460, PLT-R462)

    /// PLT-R408: 5 ms between synthetic events.
    static let slowerPacingMicroseconds = 5_000

    /// Rule JSON for `rule-overrides.json` (02-platform.md 5.4 shape, `id` prefixed `user.`), or nil for
    /// `.automatic`, which means "remove this app's compatibility override". `date` is `YYYY-MM-DD`.
    /// `.pasteText` carries no `requiresUserOptIn` gate: the Apps pane shows the clipboard explanation before the
    /// user picks it, and that choice is the user's opt-in for this app (PLT-R460, PLT-R462).
    public func overrideRule(for bundle: BundleKey, date: String) -> JSONValue? {
        guard let action else { return nil }
        return .object([
            "id": .string(Self.ruleID(for: bundle).rawValue),
            "summary": .string("Compatibility mode chosen in the Apps pane: \(rawValue)"),
            "match": .object(["bundleIds": .array([.string(bundle.rawValue)])]),
            "action": .object(action),
            "provenance": .object(["source": .string("user-suggestion"), "date": .string(date)]),
        ])
    }

    private var action: [String: JSONValue]? {
        switch self {
        case .automatic: nil
        case .typeSlower:
            [
                "strategy": .string(InjectionStrategy.backspaceReplace.rawValue),
                "params": .object(["interEventDelayUs": .number(Double(Self.slowerPacingMicroseconds))]),
            ]
        case .selectThenType: ["strategy": .string(InjectionStrategy.selectReplace.rawValue)]
        case .pasteText: ["strategy": .string(InjectionStrategy.paste.rawValue)]
        }
    }

    /// One compatibility override per app: `user.compat.<bundle>` with characters outside the rule ID alphabet
    /// replaced (`sha256:` keys become `sha256-`), the slot the guided test's "this app" result shares
    /// (`PerAppOverrideSlot.compat`, PLT-R540).
    public static func ruleID(for bundle: BundleKey) -> RuleID { PerAppOverrideSlot.compat.ruleID(for: bundle) }

    /// Reads the choice back from a stored override (the inverse of `overrideRule`).
    init?(overrideRule rule: JSONValue) {
        guard let id = rule["id"]?.stringValue, id.hasPrefix(PerAppOverrideSlot.compat.prefix),
            let strategy = rule["action"]?["strategy"]?.stringValue
        else { return nil }
        switch InjectionStrategy(rawValue: strategy) {
        case .backspaceReplace where rule["action"]?["params"]?["interEventDelayUs"] != nil: self = .typeSlower
        case .selectReplace: self = .selectThenType
        case .paste: self = .pasteText
        default: return nil
        }
    }
}

public enum AppsPaneModel {
    /// Most recent first: apps typed in (memory order) plus apps with explicit rules (PRD-R34), then apps that
    /// only have a compatibility override. The status is the matrix row that stands for the whole app
    /// (`MatrixDocument.appEntry(for:)`) after the 120-day rule; web-app and in-app rows are for the detail view.
    public static func rows(
        appModes: AppModesDocument, overrides: [StoredRuleOverride], matrix: MatrixDocument?, today: Date
    ) -> [AppsPaneRow] {
        let modes = compatibilityModes(overrides)
        let entries = Dictionary(appModes.apps.map { ($0.bundle, $0) }, uniquingKeysWith: { first, _ in first })
        return orderedBundles(appModes: appModes, modes: modes).map { bundle in
            let entry = entries[bundle]
            let matrixEntry = matrix?.appEntry(for: bundle)
            return AppsPaneRow(
                bundle: bundle, rule: entry?.rule ?? .remember, rememberedMode: entry?.mode,
                status: matrixEntry.map { MatrixStatusResolver.displayStatus($0, today: today) } ?? .notVerified,
                note: matrixEntry?.note, compatibilityMode: modes[bundle]?.choice ?? .automatic,
                matrixDisplayName: matrixEntry?.displayName, compatibilitySetOn: modes[bundle]?.createdAt)
        }
    }

    /// The apps of the pane in display order, each once: the per-app memory (most recently used first, PRD-R34),
    /// then the apps that only have a compatibility override. The bug report picker lists the same apps
    /// (PRD-R47 item 1, `RecentReportApps`).
    public static func orderedBundles(appModes: AppModesDocument, overrides: [StoredRuleOverride]) -> [BundleKey] {
        orderedBundles(appModes: appModes, modes: compatibilityModes(overrides))
    }

    private static func orderedBundles(
        appModes: AppModesDocument, modes: [BundleKey: (choice: CompatibilityModeChoice, createdAt: Date)]
    ) -> [BundleKey] {
        var bundles = appModes.apps.map(\.bundle)
        for bundle in modes.keys.sorted() where !bundles.contains(bundle) { bundles.append(bundle) }
        var seen: Set<BundleKey> = []
        return bundles.filter { seen.insert($0).inserted }
    }

    /// Newest compatibility override per app.
    private static func compatibilityModes(_ overrides: [StoredRuleOverride])
        -> [BundleKey: (choice: CompatibilityModeChoice, createdAt: Date)]
    {
        var modes: [BundleKey: (choice: CompatibilityModeChoice, createdAt: Date)] = [:]
        for stored in overrides.sorted(by: { $0.createdAt > $1.createdAt }) {
            guard let choice = CompatibilityModeChoice(overrideRule: stored.rule),
                case .array(let ids)? = stored.rule["match"]?["bundleIds"]
            else { continue }
            for case .string(let raw) in ids {
                guard let bundle = BundleKey(rawValue: raw), modes[bundle] == nil else { continue }
                modes[bundle] = (choice, stored.createdAt)
            }
        }
        return modes
    }
}

/// The app detail sheet (PRD-R35, PRD-R36): status and note of the app row, the web-app and in-app rows of the
/// matrix, and the compatibility mode under Advanced.
public struct AppDetail: Sendable, Hashable {
    public let row: AppsPaneRow
    /// `MatrixDocument.scopedEntries(for:)` with their display status, only shown here.
    public let scoped: [ScopedStatus]
    /// ISO date of the app row's last verification, if any.
    public let lastVerified: String?

    public struct ScopedStatus: Sendable, Hashable {
        public var entry: MatrixEntry
        public var status: MatrixStatus
    }

    public init(row: AppsPaneRow, matrix: MatrixDocument?, today: Date) {
        self.row = row
        scoped = (matrix?.scopedEntries(for: row.bundle) ?? []).map {
            ScopedStatus(entry: $0, status: MatrixStatusResolver.displayStatus($0, today: today))
        }
        lastVerified = matrix?.appEntry(for: row.bundle)?.lastVerified
    }
}

extension CompatibilityModeChoice {
    /// `YYYY-MM-DD` in the user's calendar day.
    static func day(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// PRD-R48, PLT-R462: the paste mode is chosen only after the clipboard explanation.
    public var needsClipboardExplanation: Bool { self == .pasteText }

    public var title: AppsText {
        switch self {
        case .automatic: .compatAutomatic
        case .typeSlower: .compatTypeSlower
        case .selectThenType: .compatSelectThenType
        case .pasteText: .compatPasteText
        }
    }

    /// PRD-R36: one sentence per choice.
    public var explanation: AppsText {
        switch self {
        case .automatic: .compatAutomaticExplanation
        case .typeSlower: .compatTypeSlowerExplanation
        case .selectThenType: .compatSelectThenTypeExplanation
        case .pasteText: .compatPasteTextExplanation
        }
    }
}

extension PerAppRule {
    /// PRD-R34 column labels.
    public var appsTitle: AppsText {
        switch self {
        case .remember: .ruleRemember
        case .alwaysEnglish: .ruleAlwaysEnglish
        case .alwaysVietnamese: .ruleAlwaysVietnamese
        case .ignore: .ruleIgnore
        }
    }
}

extension MatrixStatus {
    /// PRD-R35 labels.
    public var appsTitle: AppsText {
        switch self {
        case .works: .statusWorks
        case .worksWithNotes: .statusWorksWithNotes
        case .notVerified: .statusNotVerified
        case .knownLimitation: .statusKnownLimitation
        }
    }

    /// SF Symbol shown with the label, so the status never relies on colour alone (PRD-R67).
    public var symbolName: String {
        switch self {
        case .works: "checkmark.circle"
        case .worksWithNotes: SettingsSymbol.info
        case .notVerified: "questionmark.circle"
        case .knownLimitation: "exclamationmark.triangle"
        }
    }
}

extension AppsPaneRow {
    /// Remembered mode column (PRD-R34).
    public var rememberedModeTitle: AppsText {
        switch rememberedMode {
        case .vietnamese: .modeVietnamese
        case .english: .modeEnglish
        case nil: .modeNone
        }
    }

    /// The matrix note in the interface language (PRD-R35).
    public func noteText(_ language: InterfaceLanguage) -> String? {
        note.map { language == .vietnamese ? $0.vi : $0.en }
    }
}
