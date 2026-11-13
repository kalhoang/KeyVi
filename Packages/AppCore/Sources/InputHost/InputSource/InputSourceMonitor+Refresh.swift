// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Input-source snapshot computation on the main thread (PLT-R360, PLT-R370-R373).

import AppModel

/// Cache key: one table per layout and hardware keyboard type (ANSI, ISO and JIS differ on a few keys).
struct LayoutTableKey: Hashable, Sendable {
    var source: InputSourceID
    var keyboardType: UInt32
}

extension InputSourceMonitor {
    func begin() {
        guard observation == nil else { return }
        keyboardType = provider.currentKeyboardType()
        observation = provider.observeChanges { [weak self] in self?.refresh() }
        refresh(force: true)
    }

    func end() {
        observation?.cancel()
        observation = nil
    }

    func adopt(keyboardType seen: UInt32) {
        guard seen != keyboardType else { return }
        keyboardType = seen
        refresh()
    }

    /// Publishes a new snapshot when the selected source, its table or its bound mode changed (a new generation
    /// is a hard boundary for the pipeline, PLT-R340), or unconditionally on start.
    func refresh(force: Bool = false) {
        let source = provider.currentSource()
        // PLT-R371: only ASCII-capable keyboard layouts are transformed, so only they need a table.
        let table = source.kind == .asciiLayout ? currentTable() : nil
        let bound = boundMode(for: source)
        if !force, let last = lastPublished, last.source == source, last.boundMode == bound,
            Self.sameTable(last.table, table)
        {
            return
        }
        generation &+= 1
        let snapshot = InputSourceSnapshot(generation: generation, source: source, table: table, boundMode: bound)
        lastPublished = snapshot
        publish(snapshot)
    }

    private func currentTable() -> LayoutTable? {
        guard let data = provider.currentLayoutData() else { return nil }
        let type = keyboardType ?? provider.currentKeyboardType()
        let key = LayoutTableKey(source: data.source, keyboardType: type)
        if let cached = tables[key] { return cached }
        guard let table = try? builder.build(from: data, keyboardType: type) else { return nil }
        tables[key] = table
        return table
    }

    /// PLT-R373: with the binding enabled, a designated ASCII-capable layout decides the mode.
    private func boundMode(for source: InputSourceInfo) -> TypingMode? {
        guard binding.enabled, source.kind == .asciiLayout else { return nil }
        if binding.vietnamese.contains(source.id) { return .vietnamese }
        if binding.english.contains(source.id) { return .english }
        return nil
    }

    private static func sameTable(_ lhs: LayoutTable?, _ rhs: LayoutTable?) -> Bool {
        lhs?.source == rhs?.source && lhs?.keyboardType == rhs?.keyboardType
    }
}
