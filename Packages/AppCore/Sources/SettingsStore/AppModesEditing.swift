// SPDX-License-Identifier: GPL-3.0-or-later
//
// Pure edits of `AppModesDocument` used by the store (PRD-R21, PRD-R23, PLT-R390-R392). Every result is
// `normalized()`: one entry per bundle, at most 1,000 memory-only entries, explicit rules never evicted.

internal import AppModel

extension AppModesDocument {
    /// Sets or clears (`nil` or `.remember`) the explicit rule of `bundle`. A new rule goes to the front; an
    /// entry left with neither a rule nor a remembered mode is removed. Position is otherwise kept: choosing a
    /// rule in the Apps pane is not "using" the app.
    func settingRule(_ rule: PerAppRule?, for bundle: BundleKey) -> AppModesDocument {
        let explicit = rule == .remember ? nil : rule
        var apps = self.apps
        if let index = apps.firstIndex(where: { $0.bundle == bundle }) {
            apps[index].rule = explicit
            if apps[index].rule == nil, apps[index].mode == nil { apps.remove(at: index) }
        } else if let explicit {
            apps.insert(AppModeEntry(bundle: bundle, rule: explicit), at: 0)
        }
        return AppModesDocument(globalMode: globalMode, apps: apps).normalized()
    }

    /// Takes the global mode, the most-recently-used order and the remembered modes from InputHost's copy and
    /// keeps the rules this document holds (rules change only through `settingRule`). Entries with a rule that
    /// the copy does not list stay, after the listed ones.
    func recordingMemory(from memory: AppModesDocument) -> AppModesDocument {
        let rules = Dictionary(
            apps.compactMap { entry in entry.rule.map { (entry.bundle, $0) } }, uniquingKeysWith: { first, _ in first })
        var listed = Set<BundleKey>()
        var merged: [AppModeEntry] = memory.apps.map { entry in
            listed.insert(entry.bundle)
            return AppModeEntry(bundle: entry.bundle, rule: rules[entry.bundle], mode: entry.mode)
        }
        merged += apps.filter { $0.rule != nil && !listed.contains($0.bundle) }
        return AppModesDocument(globalMode: memory.globalMode, apps: merged).normalized()
    }

    /// Import (PRD-R23): imported entries first and authoritative for their bundles, then this document's other
    /// entries; the global mode comes from the import.
    func merging(imported: AppModesDocument) -> AppModesDocument {
        let importedBundles = Set(imported.apps.map(\.bundle))
        let kept = apps.filter { !importedBundles.contains($0.bundle) }
        return AppModesDocument(globalMode: imported.globalMode, apps: imported.apps + kept).normalized()
    }
}
