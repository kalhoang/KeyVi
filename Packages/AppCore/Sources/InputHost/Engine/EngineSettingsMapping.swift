// SPDX-License-Identifier: GPL-3.0-or-later
//
// Settings -> engine values (docs/decisions/0306-engine-bridge.md, decision 1). Utility queue only.

internal import AppModel
internal import SettingsStore
internal import VietnameseEngine

extension EngineVariant {
    /// Catalog slot: bit 2 = code context, bit 1 = English restore, bit 0 = macros.
    var catalogIndex: Int {
        (appContext == .code ? 4 : 0) | (englishRestore ? 2 : 0) | (macros ? 1 : 0)
    }

    init(catalogIndex index: Int) {
        self.init(
            appContext: index & 4 != 0 ? .code : .general, englishRestore: index & 2 != 0, macros: index & 1 != 0)
    }

    /// Every variant, ordered by `catalogIndex`.
    static let catalogOrder: [EngineVariant] = (0..<8).map { EngineVariant(catalogIndex: $0) }
}

enum EngineSettingsMapping {
    static func configuration(for settings: EffectiveSettings, variant: EngineVariant) -> EngineConfiguration {
        let method: InputMethod =
            switch settings.typingMethod {
            case .telex:
                .telex(TelexOptions(standaloneW: settings.telexStandaloneW, bracketKeys: settings.telexBracketKeys))
            case .vni: .vni
            }
        return EngineConfiguration(
            inputMethod: method,
            toneStyle: settings.tonePlacement == .modern ? .modern : .traditional,
            // D4 is the global switch; a rule's `features.englishRestore: false` turns it off per app.
            autoRestore: settings.englishRestore && variant.englishRestore,
            appContext: variant.appContext == .code ? .code : .general,
            // ENG-R829: off until the host verifies revision edits (PLT-R342) and gates them per app (W11-B);
            // without that, a revision would be applied as an ordinary edit in every app.
            lookaheadRevision: false)
    }

    /// ENG-R1107: a variant carries the macro table only when the variant and D9 both allow macros.
    static func includesMacros(_ variant: EngineVariant, settings: EffectiveSettings) -> Bool {
        variant.macros && settings.macrosEnabled
    }

    static func resources(_ resources: Resources, for variant: EngineVariant, settings: EffectiveSettings) -> Resources
    {
        guard !includesMacros(variant, settings: settings) else { return resources }
        var withoutMacros = resources
        withoutMacros.macros = .empty
        return withoutMacros
    }

    static func catalog(settings: EffectiveSettings, resources: Resources, revision: UInt64? = nil) -> EngineCatalog {
        var engines: [EngineVariant: Engine] = [:]
        for variant in EngineVariant.catalogOrder {
            engines[variant] = Engine(
                configuration: configuration(for: settings, variant: variant),
                resources: self.resources(resources, for: variant, settings: settings))
        }
        return EngineCatalog(engines: engines, revision: revision)
    }
}

/// Builds the macro table from stored macros: disabled entries are left out; entries the engine rejects
/// (ENG-R1101, ENG-R1103) are dropped one at a time and reported, so one bad macro never disables the rest.
enum MacroTableBuilder {
    struct Candidate {
        var id: String
        var entry: MacroTable.Entry
    }

    static func candidates(from macros: [StoredMacro]) -> [Candidate] {
        macros.filter(\.enabled).map {
            Candidate(
                id: $0.id.uuidString,
                entry: MacroTable.Entry(trigger: $0.trigger, expansion: $0.expansion, adaptCase: $0.adaptCase))
        }
    }

    /// `validate` is `MacroTable.init` in production. Each failure costs one validation of the remaining
    /// entries, so a table with k invalid entries is validated k + 1 times.
    static func build(
        from macros: [StoredMacro], validate: ([MacroTable.Entry]) throws -> MacroTable
    ) -> (MacroTable, [MacroTableBuildIssue]) {
        var remaining = candidates(from: macros)
        var issues: [MacroTableBuildIssue] = []
        while true {
            do {
                return (try validate(remaining.map(\.entry)), issues)
            } catch let error as MacroTable.ValidationError {
                guard let index = offendingIndex(of: error, in: remaining) else {
                    // The engine named a trigger that is not in the list: report everything left, keep nothing.
                    issues += remaining.map { .rejected(macroID: $0.id, reason: error) }
                    return (.empty, issues)
                }
                issues.append(.rejected(macroID: remaining[index].id, reason: error))
                remaining.remove(at: index)
            } catch {
                // `MacroTable.init` documents only `ValidationError`; anything else keeps the table empty.
                return (.empty, issues)
            }
        }
    }

    /// The entry an error refers to: the last one with that trigger (a duplicate is the later entry), matched
    /// exactly first and then case-insensitively (triggers match case-insensitively, ENG-R1105).
    static func offendingIndex(of error: MacroTable.ValidationError, in candidates: [Candidate]) -> Int? {
        let trigger = error.offendingTrigger
        if let exact = candidates.lastIndex(where: { $0.entry.trigger == trigger }) { return exact }
        let folded = trigger.lowercased()
        return candidates.lastIndex { $0.entry.trigger.lowercased() == folded }
    }
}

extension MacroTable.ValidationError {
    /// The trigger of the entry to drop; for shadowing, the longer trigger.
    var offendingTrigger: String {
        switch self {
        case .emptyTrigger(let trigger), .triggerTooLong(let trigger), .invalidTriggerCharacter(let trigger),
            .expansionTooLong(let trigger), .duplicateTrigger(let trigger):
            trigger
        case .shadowedByShorterTrigger(let trigger, _):
            trigger
        }
    }
}
