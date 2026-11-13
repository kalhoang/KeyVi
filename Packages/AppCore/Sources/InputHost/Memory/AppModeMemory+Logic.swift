// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Per-app VI/EN memory logic (PLT-R390-R393, PRD-R19-R23).

import AppModel
import SettingsStore

extension AppModeMemory {
    static let rememberedCapacity = AppModesDocument.rememberedCapacity

    /// `ignore`, `alwaysEnglish` or `alwaysVietnamese`: never evicted (PLT-R392).
    static func isExplicit(_ entry: AppModeEntry) -> Bool { entry.rule != nil && entry.rule != .remember }

    /// Drops duplicate bundles (the first, most recent, wins) and applies the LRU limit.
    static func normalized(_ apps: [AppModeEntry]) -> [AppModeEntry] {
        var seen = Set<BundleKey>()
        var entries = apps.filter { seen.insert($0.bundle).inserted }
        evict(&entries)
        return entries
    }

    func resolution(bundle: BundleKey?, ruleDefault: FirstSeenMode) -> ModeResolution {
        guard let bundle else { return ModeResolution(mode: global, source: .globalMode, ignored: false) }
        let entry = entries.first { $0.bundle == bundle }
        switch entry?.rule {
        case .ignore: return ModeResolution(mode: global, source: .ignoreRule, ignored: true)
        case .alwaysEnglish: return ModeResolution(mode: .english, source: .alwaysEnglish, ignored: false)
        case .alwaysVietnamese: return ModeResolution(mode: .vietnamese, source: .alwaysVietnamese, ignored: false)
        case .remember, nil: break
        }
        guard rememberPerApp else { return ModeResolution(mode: global, source: .globalMode, ignored: false) }
        if let mode = entry?.mode { return ModeResolution(mode: mode, source: .remembered, ignored: false) }
        if let mode = Self.mode(ruleDefault) ?? Self.mode(firstSeen) {
            return ModeResolution(mode: mode, source: .ruleDefault, ignored: false)
        }
        return ModeResolution(mode: global, source: .globalMode, ignored: false)
    }

    /// Resolution on focus (FocusTracker): resolves, records an unknown app's first mode and refreshes the MRU
    /// order (PLT-R390 "an app seen for the first time").
    mutating func activate(bundle: BundleKey?, ruleDefault: FirstSeenMode) -> ModeResolution {
        let resolution = resolution(bundle: bundle, ruleDefault: ruleDefault)
        guard let bundle else { return resolution }
        if let index = index(of: bundle) {
            moveToFront(at: index)
        } else if rememberPerApp {
            entries.insert(AppModeEntry(bundle: bundle, mode: resolution.mode), at: 0)
            Self.evict(&entries)
        }
        return resolution
    }

    /// PRD-R20. An ignored app's toggle does nothing (PRD-R21); under "always English/Vietnamese" the toggle is
    /// temporary, so memory is left alone (the rule wins on the next activation).
    mutating func applyToggle(bundle: BundleKey?, mode: TypingMode) {
        let index = bundle.flatMap(index(of:))
        if let index, entries[index].rule == .ignore { return }
        global = mode
        guard rememberPerApp, let bundle else { return }
        if let index {
            guard !Self.isExplicit(entries[index]) else { return }
            entries[index].mode = mode
            moveToFront(at: index)
        } else {
            entries.insert(AppModeEntry(bundle: bundle, mode: mode), at: 0)
            Self.evict(&entries)
        }
    }

    mutating func applyRule(_ rule: PerAppRule?, for bundle: BundleKey) {
        let explicit = rule != nil && rule != .remember
        if let index = index(of: bundle) {
            entries[index].rule = explicit ? rule : nil
            if !explicit, entries[index].mode == nil { entries.remove(at: index) }
        } else if explicit {
            entries.insert(AppModeEntry(bundle: bundle, rule: rule), at: 0)
        }
        Self.evict(&entries)
    }

    mutating func moveToFront(_ bundle: BundleKey) {
        if let index = index(of: bundle) { moveToFront(at: index) }
    }

    private mutating func moveToFront(at index: Int) {
        guard index > 0 else { return }
        entries.insert(entries.remove(at: index), at: 0)
    }

    private func index(of bundle: BundleKey) -> Int? { entries.firstIndex { $0.bundle == bundle } }

    /// Removes the least recently used remembered entries beyond the capacity (PLT-R392).
    static func evict(_ entries: inout [AppModeEntry]) {
        var remembered = entries.reduce(0) { $0 + (isExplicit($1) ? 0 : 1) }
        guard remembered > rememberedCapacity else { return }
        var index = entries.count - 1
        while remembered > rememberedCapacity, index >= 0 {
            if !isExplicit(entries[index]) {
                entries.remove(at: index)
                remembered -= 1
            }
            index -= 1
        }
    }

    private static func mode(_ setting: FirstSeenMode) -> TypingMode? {
        switch setting {
        case .vi: .vietnamese
        case .en: .english
        case .inherit: nil
        }
    }
}
