// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Per-app VI/EN memory (PLT-R390-R393, PRD-R19-R23). A value type owned by the ax thread; persisted through
// SettingsStore (`recordAppModes`, 5 s debounce).

public import AppModel
public import SettingsStore

public struct ModeResolution: Sendable, Hashable {
    public var mode: TypingMode
    public var source: ModeSource
    /// "Bỏ qua ứng dụng này": the app sees raw keys and the toggle does nothing (PRD-R21); implemented as a
    /// user override with strategy `passThrough` (PLT-R390).
    public var ignored: Bool
}

public struct AppModeMemory: Sendable, Hashable {
    public init(document: AppModesDocument, rememberPerApp: Bool, firstSeen: FirstSeenMode) { unimplemented() }

    /// PRD-R21: ignore > always English > always Vietnamese > remembered > rule `defaultMode` / D13 > global.
    public func resolve(bundle: BundleKey?, ruleDefault: FirstSeenMode) -> ModeResolution { unimplemented() }

    /// Manual toggle while `bundle` is the focus owner (PRD-R20). Updates the global mode too.
    public mutating func recordToggle(bundle: BundleKey?, mode: TypingMode) { unimplemented() }

    /// Most-recently-used ordering for the Apps pane; LRU eviction at 1,000 remembered entries (PLT-R392).
    public mutating func touch(_ bundle: BundleKey) { unimplemented() }

    public mutating func setRule(_ rule: PerAppRule?, for bundle: BundleKey) { unimplemented() }

    public var globalMode: TypingMode { unimplemented() }
    public func document() -> AppModesDocument { unimplemented() }
}
