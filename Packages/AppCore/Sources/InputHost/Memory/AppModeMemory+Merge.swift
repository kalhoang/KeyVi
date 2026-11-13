// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Merging an `app-modes.json` document published by SettingsStore into the live memory on the ax thread.
// The ax thread is the authority on remembered modes (toggles land here first); SettingsStore is the authority
// on explicit rules (the Apps pane and the menu write them there). A published document that only echoes an
// older state of this memory must not roll back newer toggles (PRD-R20, contracts.md 10.4).

import AppModel
import SettingsStore

extension AppModeMemory {
    /// - `recentlyEmitted`: the mode states this memory recently handed to SettingsStore.
    /// - An incoming document whose remembered modes and global mode match one of them is an echo (SettingsStore
    ///   republishes on every settings change and debounces `recordAppModes`, so it can return any document
    ///   emitted before the latest toggle): only explicit rules are taken from it; modes and order stay live.
    /// - Any other mode state was changed outside (import, reset): the incoming document replaces the memory.
    ///   An import that happens to equal a recently emitted state is indistinguishable from an echo and keeps
    ///   the live modes, which is the state the user just produced anyway.
    static func merged(
        current: AppModeMemory, incoming: AppModesDocument, recentlyEmitted: EmittedModeHistory, rememberPerApp: Bool,
        firstSeen: FirstSeenMode
    ) -> AppModeMemory {
        guard recentlyEmitted.contains(incoming) else {
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

    /// Remembered modes and global mode of a document: what a toggle changes.
    struct ModeState: Equatable {
        var global: TypingMode
        var modes: [BundleKey: TypingMode]

        init(_ document: AppModesDocument) {
            global = document.globalMode
            modes = Dictionary(
                document.apps.compactMap { entry in entry.mode.map { (entry.bundle, $0) } },
                uniquingKeysWith: { first, _ in first })
        }
    }
}

/// The last `capacity` distinct mode states handed to SettingsStore, newest last (echo detection for
/// `AppModeMemory.merged`). Bounded: a toggle burst longer than the store's 5 s debounce window is not
/// realistic at 16 states.
struct EmittedModeHistory {
    static let capacity = 16

    private(set) var states: [AppModeMemory.ModeState] = []

    mutating func record(_ document: AppModesDocument) {
        let state = AppModeMemory.ModeState(document)
        guard states.last != state else { return }
        states.append(state)
        if states.count > Self.capacity { states.removeFirst(states.count - Self.capacity) }
    }

    func contains(_ document: AppModesDocument) -> Bool { states.contains(AppModeMemory.ModeState(document)) }

    /// The store published `document`. InputHost hands its documents to the store in emission order
    /// (`AppModesRecorder`) and the store publishes after each, so once it returned emission i it never returns an
    /// older one again unless the document was changed outside (reset, import). Forgetting the older states keeps
    /// such a change from passing for an echo, in particular a reset to the empty launch state (PRD-R26).
    mutating func acknowledge(_ document: AppModesDocument) {
        guard let index = states.firstIndex(of: AppModeMemory.ModeState(document)), index > 0 else { return }
        states.removeFirst(index)
    }
}
