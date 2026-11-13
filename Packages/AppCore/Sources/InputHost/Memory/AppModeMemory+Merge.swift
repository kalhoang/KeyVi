// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Merging an `app-modes.json` document published by SettingsStore into the live memory on the ax thread.
// The ax thread is the authority on remembered modes (toggles land here first); SettingsStore is the authority
// on explicit rules (the Apps pane and the menu write them there). A published document that only echoes an
// older state of this memory must not roll back newer toggles.

import AppModel
import SettingsStore

extension AppModeMemory {
    /// - `lastEmitted`: the last document this memory handed to SettingsStore (nil before the first one).
    /// - If the incoming remembered modes or global mode differ from `lastEmitted`, they were changed outside
    ///   (import, reset): the incoming document replaces the memory.
    /// - Otherwise only explicit rules are taken from the incoming document; modes and order stay live.
    static func merged(
        current: AppModeMemory, incoming: AppModesDocument, lastEmitted: AppModesDocument?, rememberPerApp: Bool,
        firstSeen: FirstSeenMode
    ) -> AppModeMemory {
        guard let lastEmitted, modeState(of: incoming) == modeState(of: lastEmitted) else {
            return AppModeMemory(document: incoming, rememberPerApp: rememberPerApp, firstSeen: firstSeen)
        }
        let rules = Dictionary(
            incoming.apps.compactMap { entry in isExplicit(entry) ? (entry.bundle, entry.rule) : nil },
            uniquingKeysWith: { first, _ in first })
        var apps = current.entries.compactMap { entry -> AppModeEntry? in
            var entry = entry
            entry.rule = rules[entry.bundle] ?? nil
            return entry.rule == nil && entry.mode == nil ? nil : entry
        }
        let known = Set(apps.map(\.bundle))
        apps += incoming.apps.filter { isExplicit($0) && !known.contains($0.bundle) }
            .map { AppModeEntry(bundle: $0.bundle, rule: $0.rule) }
        let document = AppModesDocument(globalMode: current.global, apps: apps)
        return AppModeMemory(document: document, rememberPerApp: rememberPerApp, firstSeen: firstSeen)
    }

    private struct ModeState: Equatable {
        var global: TypingMode
        var modes: [BundleKey: TypingMode]
    }

    private static func modeState(of document: AppModesDocument) -> ModeState {
        let modes = Dictionary(
            document.apps.compactMap { entry in entry.mode.map { (entry.bundle, $0) } },
            uniquingKeysWith: { first, _ in first })
        return ModeState(global: document.globalMode, modes: modes)
    }
}
