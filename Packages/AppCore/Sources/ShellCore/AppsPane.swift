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

    /// PLT-R408: 5 ms between synthetic events.
    static let slowerPacingMicroseconds = 5_000
    static let ruleIDPrefix = "user.compat."

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
    /// replaced (`sha256:` keys become `sha256-`).
    public static func ruleID(for bundle: BundleKey) -> RuleID {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let cleaned = String(bundle.rawValue.map { allowed.contains($0) ? $0 : "-" })
        let segments = cleaned.split(separator: ".", omittingEmptySubsequences: true).joined(separator: ".")
        let candidate = String((ruleIDPrefix + segments).prefix(128))
        let trimmed = candidate.hasSuffix(".") ? String(candidate.dropLast()) : candidate
        return RuleID(rawValue: trimmed) ?? RuleID(rawValue: "user.compat.app")!
    }

    /// Reads the choice back from a stored override (the inverse of `overrideRule`).
    init?(overrideRule rule: JSONValue) {
        guard let id = rule["id"]?.stringValue, id.hasPrefix(Self.ruleIDPrefix),
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
    /// only have a compatibility override.
    public static func rows(
        appModes: AppModesDocument, overrides: [StoredRuleOverride], matrix: MatrixDocument?, today: Date
    ) -> [AppsPaneRow] {
        let modes = compatibilityModes(overrides)
        var bundles = appModes.apps.map(\.bundle)
        for bundle in modes.keys.sorted() where !bundles.contains(bundle) { bundles.append(bundle) }
        let entries = Dictionary(appModes.apps.map { ($0.bundle, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<BundleKey> = []
        return bundles.compactMap { bundle in
            guard seen.insert(bundle).inserted else { return nil }
            let entry = entries[bundle]
            let matrixEntry = matrix?.entries.first { $0.bundleId == bundle }
            return AppsPaneRow(
                bundle: bundle, rule: entry?.rule ?? .remember, rememberedMode: entry?.mode,
                status: matrixEntry.map { MatrixStatusResolver.displayStatus($0, today: today) } ?? .notVerified,
                note: matrixEntry?.note, compatibilityMode: modes[bundle] ?? .automatic)
        }
    }

    /// Newest compatibility override per app.
    private static func compatibilityModes(_ overrides: [StoredRuleOverride]) -> [BundleKey: CompatibilityModeChoice] {
        var modes: [BundleKey: CompatibilityModeChoice] = [:]
        for stored in overrides.sorted(by: { $0.createdAt > $1.createdAt }) {
            guard let choice = CompatibilityModeChoice(overrideRule: stored.rule),
                case .array(let ids)? = stored.rule["match"]?["bundleIds"]
            else { continue }
            for case .string(let raw) in ids {
                guard let bundle = BundleKey(rawValue: raw), modes[bundle] == nil else { continue }
                modes[bundle] = choice
            }
        }
        return modes
    }
}
