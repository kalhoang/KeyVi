// SPDX-License-Identifier: GPL-3.0-or-later
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

    public init(mode: TypingMode, source: ModeSource, ignored: Bool) {
        self.mode = mode
        self.source = source
        self.ignored = ignored
    }
}

/// Entries are kept most recently used first, as in `app-modes.json`. "Remembered" entries are those without an
/// explicit rule (`nil` or `.remember`); only they count towards the 1,000 limit and only they are evicted.
/// With `rememberPerApp` off (D12), memory and rule defaults are not used, explicit rules still are. The first
/// focus of an unknown app records the mode it got (D13 "seen for the first time"). Logic:
/// `AppModeMemory+Logic.swift`.
public struct AppModeMemory: Sendable, Hashable {
    var global: TypingMode
    var rememberPerApp: Bool
    var firstSeen: FirstSeenMode
    var entries: [AppModeEntry]

    public init(document: AppModesDocument, rememberPerApp: Bool, firstSeen: FirstSeenMode) {
        global = document.globalMode
        self.rememberPerApp = rememberPerApp
        self.firstSeen = firstSeen
        entries = Self.normalized(document.apps)
    }

    /// PRD-R21: ignore > always English > always Vietnamese > remembered > rule `defaultMode` / D13 > global.
    public func resolve(bundle: BundleKey?, ruleDefault: FirstSeenMode) -> ModeResolution {
        resolution(bundle: bundle, ruleDefault: ruleDefault)
    }

    /// Manual toggle while `bundle` is the focus owner (PRD-R20). Updates the global mode too.
    public mutating func recordToggle(bundle: BundleKey?, mode: TypingMode) { applyToggle(bundle: bundle, mode: mode) }

    /// Most-recently-used ordering for the Apps pane; LRU eviction at 1,000 remembered entries (PLT-R392).
    public mutating func touch(_ bundle: BundleKey) { moveToFront(bundle) }

    public mutating func setRule(_ rule: PerAppRule?, for bundle: BundleKey) { applyRule(rule, for: bundle) }

    public var globalMode: TypingMode { global }
    public func document() -> AppModesDocument { AppModesDocument(globalMode: global, apps: entries) }
}
