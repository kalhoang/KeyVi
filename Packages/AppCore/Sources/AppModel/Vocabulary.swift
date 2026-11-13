// SPDX-License-Identifier: GPL-3.0-or-later
//
// Shared enumerations. Raw values are the JSON spellings used in settings files and in compat/rules.json
// (02-platform.md 5.4), so they MUST NOT change without a schema migration (PLT-R1005).

/// VI/EN mode of the input host (03-product.md D11-D13).
public enum TypingMode: String, Sendable, Hashable, Codable, CaseIterable {
    case vietnamese = "vi"
    case english = "en"

    public var toggled: TypingMode { self == .vietnamese ? .english : .vietnamese }
}

/// D1.
public enum TypingMethod: String, Sendable, Hashable, Codable, CaseIterable { case telex, vni }

/// D2.
public enum TonePlacement: String, Sendable, Hashable, Codable, CaseIterable { case traditional, modern }

/// D18. Selected interface language, independent of the macOS language (PRD-R63).
public enum InterfaceLanguage: String, Sendable, Hashable, Codable, CaseIterable {
    case vietnamese = "vi"
    case english = "en"
}

/// D21.
public enum UpdateChannel: String, Sendable, Hashable, Codable, CaseIterable { case stable, beta }

/// D13 and the rule field `defaultMode` (02-platform.md 5.4).
public enum FirstSeenMode: String, Sendable, Hashable, Codable, CaseIterable {
    case inherit, vi, en
}

/// Explicit per-app rule chosen by the user (PRD-R21). Precedence: ignore > alwaysEnglish > alwaysVietnamese
/// > remembered > first-seen default.
public enum PerAppRule: String, Sendable, Hashable, Codable, CaseIterable {
    case remember, alwaysEnglish, alwaysVietnamese, ignore
}

/// Engine fingerprint of the focused app's UI technology (PLT-R510).
public enum EngineFingerprint: String, Sendable, Hashable, Codable, CaseIterable {
    case electron, chromium, cef, gecko, jvm, qt, catalyst, ios, webkitBrowser, native
}

/// Generic injection strategies (02-platform.md section 4). Shared by CompatRules (as data) and Injection
/// (as behaviour) so the two never drift.
public enum InjectionStrategy: String, Sendable, Hashable, Codable, CaseIterable {
    case backspaceReplace, selectReplace, axReplace, paste, passThrough
}

/// Inline-completion handling (PLT-R420-R422).
public enum InlineCompletionMode: String, Sendable, Hashable, Codable, CaseIterable {
    case none, axSelection, placeholder, axSelectionThenPlaceholder
}

/// Text-context gating (PLT-R386). `byEngine` is resolved to a concrete value before it reaches the tap.
public enum RequireTextFocus: String, Sendable, Hashable, Codable, CaseIterable {
    case never, whenKnown, always, byEngine
}

/// Re-entry verification (PLT-R342).
public enum VerifyReentry: String, Sendable, Hashable, Codable, CaseIterable { case never, whenReadable }

/// `action.engineContext` (ENG-R850).
public enum EngineContextKind: String, Sendable, Hashable, Codable, CaseIterable { case general, code }

/// `action.axEnable` (PLT-R385).
public enum AXEnableMode: String, Sendable, Hashable, Codable, CaseIterable { case none, manual }

/// Availability of Accessibility data for the focused app (PLT-R383).
public enum AXAvailability: String, Sendable, Hashable, Codable { case available, unavailable, timedOut }

/// Where a resolved decision came from (PLT-R383).
public enum DecisionSource: String, Sendable, Hashable, Codable { case shipped, user, `default` }

/// Permission states (PLT-R720).
public enum PermissionState: String, Sendable, Hashable, Codable { case granted, denied, unknown }

/// Permissions the app may need (PLT-R701, PLT-R702).
public enum PermissionKind: String, Sendable, Hashable, Codable, CaseIterable {
    case accessibility, postEvent, listenEvent
}
