// SPDX-License-Identifier: GPL-3.0-or-later
//
// Settings -> `TapSettingsSnapshot` (PLT-R1008, PRD-R27, docs/decisions/0306-engine-bridge.md decision 1). Runs on
// the utility queue, never on the tap: engines are built here (the first `Engine.init` builds tables) and the
// bundled word lists are loaded once (ENG-R1231). The user lists are those of the focused app (ENG-R851,
// ENG-R862, ADR 0320): a focus change republishes only when that app's lists differ. Workstreams W2-A, W5-B.

public import AppModel
public import Diagnostics
internal import Foundation
public import RealtimeSupport
public import SettingsStore
public import VietnameseEngine
internal import VietnameseEngineData

/// The engine-affecting part of the settings: D1, D2, D4, D5, D6, D9, D28, D29, D30, the on or off state of D8, the
/// macros, the two user word lists of the focused app and the never-correct list. The learned collision memory is not
/// part of it: a new memory snapshot bumps only `EngineCatalog.memoryRevision` (ENG-R865). `EngineCatalog.revision`
/// changes exactly when this value changes, so a hotkey, UI-language or update-channel change keeps the word being
/// typed (PRD-R27, the W1-F1 contract on `EngineCatalog.revision`). D8 is an engine input by its on or off state only
/// (ENG-R1119: with the key off no word is corrected): rebinding it to another key keeps the revision and the word.
public struct EngineInputs: Sendable, Hashable {
    public var typingMethod: TypingMethod
    public var tonePlacement: TonePlacement
    public var englishRestore: Bool
    public var telexStandaloneW: Bool
    public var telexBracketKeys: Bool
    public var macrosEnabled: Bool
    /// D28: the engines carry the learned memory (ENG-R865); off, they get the empty snapshot.
    public var learnCollisionChoices: Bool
    /// D29, ANDed per variant with the rule's `features.lookaheadRevision` (ENG-R829, PLT-R357).
    public var lookaheadRevision: Bool
    /// D30, ANDed with D4, D8 on and the variant's `englishRestore` and `restoreHotkey` (ENG-R1119).
    public var typoCorrection: Bool
    /// D8 on or off (`restoreHotkey != nil`); the binding itself stays out (ENG-R1119, PRD-R27).
    public var restoreKeyEnabled: Bool
    /// NFC-normalised (`MacroNormalization`). Content: never logged.
    public var macros: [StoredMacro]
    /// The focused app's lists: the global entries plus the words learned in that app (ENG-R862). Content.
    public var keepAsTyped: Set<String>
    public var keepVietnamese: Set<String>
    /// ENG-R1118: per user, the same in every app, so a focus change never touches it. Content: never logged.
    public var neverCorrect: Set<String>

    /// With the global lists only (no focused app).
    public init(settings: EffectiveSettings, macros: [StoredMacro]) {
        self.init(
            settings: settings, macros: macros,
            wordLists: UserWordLists(keepAsTyped: settings.keepAsTyped, keepVietnamese: settings.keepVietnamese))
    }

    /// `wordLists` are the focused app's (`UserSettings.wordLists(for:)`, ENG-R851, ENG-R862).
    public init(settings: EffectiveSettings, macros: [StoredMacro], wordLists: UserWordLists) {
        typingMethod = settings.typingMethod
        tonePlacement = settings.tonePlacement
        englishRestore = settings.englishRestore
        telexStandaloneW = settings.telexStandaloneW
        telexBracketKeys = settings.telexBracketKeys
        macrosEnabled = settings.macrosEnabled
        learnCollisionChoices = settings.learnCollisionChoices
        lookaheadRevision = settings.lookaheadRevision
        typoCorrection = settings.typoCorrection
        restoreKeyEnabled = settings.restoreHotkey != nil
        self.macros = MacroNormalization.normalized(macros)
        keepAsTyped = wordLists.keepAsTyped
        keepVietnamese = wordLists.keepVietnamese
        neverCorrect = settings.neverCorrect
    }

    var wordLists: UserWordLists { UserWordLists(keepAsTyped: keepAsTyped, keepVietnamese: keepVietnamese) }
}

public enum MacroNormalization {
    /// ENG-R1101 and PLT-R307 ("insert is NFC text"): an expansion pasted from elsewhere may be decomposed, so the
    /// bridge composes it before `MacroTable` sees it. Triggers are printable ASCII (open decision 7) and are
    /// composed too, which leaves them unchanged.
    public static func normalized(_ macros: [StoredMacro]) -> [StoredMacro] {
        macros.map { macro in
            var composed = macro
            composed.trigger = macro.trigger.precomposedStringWithCanonicalMapping
            composed.expansion = macro.expansion.precomposedStringWithCanonicalMapping
            return composed
        }
    }
}

/// D10 "expand macros in English mode" (docs/decisions/0306-engine-bridge.md "Open issue", open decision D10 in
/// docs/decisions/0001-defaults-for-open-decisions.md): the 12.2 engine API has no literal (non-composing) mode,
/// so the host cannot expand macros without composing Vietnamese. Until the engine offers one, the toggle is
/// hidden and the tap never feeds the engine in EN mode (PLT-R310 step 6), whatever the stored value says.
public enum EnglishModeMacros {
    /// Flip when the engine track ships a literal mode (`EngineConfiguration` flag or `InputMethod.literal`).
    public static let engineSupportsLiteralMode = false
    /// Whether the Settings UI may show the D10 toggle.
    public static var isSettingVisible: Bool { engineSupportsLiteralMode }

    public static func effective(_ settings: EffectiveSettings) -> Bool {
        engineSupportsLiteralMode && settings.macrosInEnglishMode
    }
}

/// What one publication produced, for diagnostics and tests. Macro problems carry IDs only.
public struct TapSettingsPublication: Sendable {
    public var snapshot: TapSettingsSnapshot
    /// True when this publication built a new engine catalog (the engine inputs changed).
    public var rebuiltEngines: Bool
    public var macroIssues: [MacroTableBuildIssue]
}

/// Builds and publishes the tap's settings snapshot. Called on the utility queue (the `SettingsStore` executor,
/// PLT-R203); the lock only serialises callers and is never touched by the tap.
public final class TapSettingsPublisher: Sendable {
    public typealias BundledResourcesLoader = @Sendable () throws -> Resources

    private struct State {
        var bundled: Resources?
        /// The bundled lists failed to load: the engines run with empty lists and there is no collision list.
        var bundledFailed = false
        var generation: UInt64 = 0
        var revision: UInt64 = 0
        var inputs: EngineInputs?
        var catalog: EngineCatalog?
        /// Built from `inputs.macros`; kept when only the word lists change (a focus change, ENG-R862).
        var macroTable: MacroTable?
        var macroIssues: [MacroTableBuildIssue] = []
        /// The last published settings and the focused app whose lists the engines carry (ENG-R851).
        var settings: SettingsState?
        var focusedApp: BundleKey?
        /// The learned collision memory (ENG-R865) and its revision; attached to every catalog built.
        var memory = CollisionMemorySnapshot.empty
        var memoryRevision: UInt64 = 0
        var effective: EffectiveSettings?
    }

    private struct Built {
        var snapshot: TapSettingsSnapshot
        var rebuilt: Bool
        /// The macro table was validated again (its problems are logged once per new table).
        var rebuiltMacros = false
        var issues: [MacroTableBuildIssue]
    }

    private let cell: SnapshotCell<TapSettingsSnapshot>
    private let loadBundled: BundledResourcesLoader
    private let logger: any DiagnosticsLogging
    private let state = Mutex(State())

    /// `loadBundled` is `Resources.bundled` with empty user lists in production; the user lists and macros are
    /// attached per publication.
    public init(
        cell: SnapshotCell<TapSettingsSnapshot>, logger: any DiagnosticsLogging,
        loadBundled: @escaping BundledResourcesLoader
    ) {
        self.cell = cell
        self.logger = logger
        self.loadBundled = loadBundled
    }

    /// Production loader: the word lists shipped in `VietnameseEngineData` (ENG-R810), without user content.
    public static let bundledLoader: BundledResourcesLoader = {
        try Resources.bundled(userKeepRaw: WordSet([]), userKeepVietnamese: WordSet([]))
    }

    /// ENG-R1231: loads the bundled lists once (at most 50 ms), off the main and tap threads. Idempotent; a
    /// failure is logged once and the engines run with empty lists (restore still works for the user's lists).
    public func preloadResources() {
        state.withLock { state in _ = bundledResources(&state) }
    }

    /// ENG-R862, PLT-R914: the bundled collision list (the ambiguity table's words and the collision supplement) as
    /// a membership test, from the bundled lists loaded once. Nil when they failed to load: an empty list would
    /// validate every learned word away and the memory file would be rewritten empty (PLT-R1006). Utility queue.
    public func collisionVocabulary() -> CollisionVocabulary? {
        let loaded: Resources? = state.withLock { state in
            let resources = bundledResources(&state)
            return state.bundledFailed ? nil : resources
        }
        guard let resources = loaded else { return nil }
        let ambiguity = resources.ambiguity
        let supplement = resources.collision.supplement
        return CollisionVocabulary { ambiguity[$0] != nil || supplement.contains($0) }
    }

    /// Builds the snapshot for `settings` and publishes it. The engine catalog is rebuilt, and its revision
    /// bumped, only when `EngineInputs` changed (PRD-R27). The word lists are those of the focused app.
    @discardableResult
    public func publish(_ settings: SettingsState) -> TapSettingsPublication {
        let built = state.withLock { state in
            state.settings = settings
            let inputs = EngineInputs(
                settings: settings.effective, macros: settings.macros,
                wordLists: settings.user.wordLists(for: state.focusedApp))
            return build(&state, inputs: inputs, effective: settings.effective)
        }
        return finish(built)
    }

    /// ENG-R851, ENG-R862: the focused app changed (`nil`: unknown). The engines get the global entries plus the
    /// words learned in `app`; a snapshot is published only when those lists differ from the current ones, so
    /// switching between apps without learned words never touches the word being typed. Utility queue only
    /// (PLT-R304, PLT-R305). Returns nil when nothing was published.
    @discardableResult
    public func focusChanged(to app: BundleKey?) -> TapSettingsPublication? {
        let built: Built? = state.withLock { state in
            guard state.focusedApp != app else { return nil }
            state.focusedApp = app
            guard let settings = state.settings, var inputs = state.inputs else { return nil }
            let lists = settings.user.wordLists(for: app)
            guard lists != inputs.wordLists else { return nil }
            inputs.keepAsTyped = lists.keepAsTyped
            inputs.keepVietnamese = lists.keepVietnamese
            return build(&state, inputs: inputs, effective: settings.effective)
        }
        return built.map(finish)
    }

    /// ENG-R865: the learned memory's votes changed (utility queue). The catalog is rebuilt with the same settings
    /// revision and a new memory revision, so the tap swaps engines at its next hard boundary and the word being
    /// typed is kept. Nothing is published while D28 is off (the engines carry the empty snapshot then) or before the
    /// first settings publication. Returns nil when nothing was published.
    @discardableResult
    public func collisionMemoryChanged(_ memory: CollisionMemorySnapshot) -> TapSettingsPublication? {
        let built: Built? = state.withLock { state in
            guard memory != state.memory else { return nil }
            state.memory = memory
            state.memoryRevision &+= 1
            guard let inputs = state.inputs, inputs.learnCollisionChoices, let effective = state.effective else {
                return nil
            }
            return build(&state, inputs: inputs, effective: effective, memoryOnly: true)
        }
        return built.map(finish)
    }

    /// Rebuilds the catalog when `inputs` changed (the macro table only when the macros changed) and returns the
    /// next snapshot. Called with the lock held. `memoryOnly`: same inputs, new learned memory (ENG-R865).
    private func build(
        _ state: inout State, inputs: EngineInputs, effective: EffectiveSettings, memoryOnly: Bool = false
    ) -> Built {
        var rebuilt = false
        var rebuiltMacros = false
        state.effective = effective
        if memoryOnly, let table = state.macroTable {
            let attached = attachedResources(&state, inputs: inputs, macros: table)
            state.catalog = EngineBridge.catalog(
                settings: effective, resources: attached, revision: state.revision, memoryRevision: state.memoryRevision
            )
            rebuilt = true
        } else if state.inputs != inputs || state.catalog == nil {
            state.revision &+= 1
            let table: MacroTable
            if let cached = state.macroTable, state.inputs?.macros == inputs.macros {
                table = cached
            } else {
                let (built, issues) = EngineBridge.macroTable(from: inputs.macros)
                table = built
                state.macroTable = built
                state.macroIssues = issues
                rebuiltMacros = true
            }
            let attached = attachedResources(&state, inputs: inputs, macros: table)
            state.catalog = EngineBridge.catalog(
                settings: effective, resources: attached, revision: state.revision, memoryRevision: state.memoryRevision
            )
            state.inputs = inputs
            rebuilt = true
        }
        state.generation &+= 1
        let snapshot = TapSettingsSnapshot(
            generation: state.generation, engines: state.catalog!, toggleHotkey: effective.toggleHotkey,
            restoreHotkey: effective.restoreHotkey, macrosInEnglishMode: EnglishModeMacros.effective(effective),
            rememberPerApp: effective.rememberPerApp)
        return Built(snapshot: snapshot, rebuilt: rebuilt, rebuiltMacros: rebuiltMacros, issues: state.macroIssues)
    }

    /// The bundled lists with the user's lists (the focused app's keep lists, the never-correct list), the macros and
    /// the learned memory attached. One value for the whole catalog: the engines share it (ENG-R1120).
    private func attachedResources(_ state: inout State, inputs: EngineInputs, macros: MacroTable) -> Resources {
        let bundled = bundledResources(&state)
        var attached = EngineBridge.resources(
            wordLists: inputs.wordLists, neverCorrect: inputs.neverCorrect, macros: macros
        ) { bundled }
        attached.collisionMemory = state.memory
        return attached
    }

    private func finish(_ built: Built) -> TapSettingsPublication {
        cell.publish(built.snapshot)
        if !built.issues.isEmpty && built.rebuiltMacros {
            logger.log(.note("macros rejected by the engine", category: .settings), level: .notice)
        }
        return TapSettingsPublication(
            snapshot: built.snapshot, rebuiltEngines: built.rebuilt, macroIssues: built.issues)
    }

    private func bundledResources(_ state: inout State) -> Resources {
        if let bundled = state.bundled { return bundled }
        let loaded: Resources
        do {
            loaded = try loadBundled()
        } catch {
            logger.log(.note("bundled word lists failed to load", category: .settings), level: .error)
            loaded = .empty
            state.bundledFailed = true
        }
        state.bundled = loaded
        return loaded
    }
}
