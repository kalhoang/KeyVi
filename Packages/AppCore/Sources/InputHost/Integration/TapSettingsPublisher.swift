// SPDX-License-Identifier: GPL-3.0-or-later
//
// Settings -> `TapSettingsSnapshot` (PLT-R1008, PRD-R27, docs/decisions/0306-engine-bridge.md decision 1). Runs on
// the utility queue, never on the tap: engines are built here (the first `Engine.init` builds tables) and the
// bundled word lists are loaded once (ENG-R1231). Workstream W2-A.

public import AppModel
public import Diagnostics
internal import Foundation
public import RealtimeSupport
public import SettingsStore
public import VietnameseEngine
internal import VietnameseEngineData

/// The engine-affecting part of the settings: D1, D2, D4, D5, D6, D9, the macros and the two user word lists.
/// `EngineCatalog.revision` changes exactly when this value changes, so a hotkey, UI-language or update-channel
/// change keeps the word being typed (PRD-R27, the W1-F1 contract on `EngineCatalog.revision`).
public struct EngineInputs: Sendable, Hashable {
    public var typingMethod: TypingMethod
    public var tonePlacement: TonePlacement
    public var englishRestore: Bool
    public var telexStandaloneW: Bool
    public var telexBracketKeys: Bool
    public var macrosEnabled: Bool
    /// NFC-normalised (`MacroNormalization`). Content: never logged.
    public var macros: [StoredMacro]
    public var keepAsTyped: Set<String>
    public var keepVietnamese: Set<String>

    public init(settings: EffectiveSettings, macros: [StoredMacro]) {
        typingMethod = settings.typingMethod
        tonePlacement = settings.tonePlacement
        englishRestore = settings.englishRestore
        telexStandaloneW = settings.telexStandaloneW
        telexBracketKeys = settings.telexBracketKeys
        macrosEnabled = settings.macrosEnabled
        self.macros = MacroNormalization.normalized(macros)
        keepAsTyped = settings.keepAsTyped
        keepVietnamese = settings.keepVietnamese
    }
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
        var generation: UInt64 = 0
        var revision: UInt64 = 0
        var inputs: EngineInputs?
        var catalog: EngineCatalog?
        var macroIssues: [MacroTableBuildIssue] = []
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

    /// Builds the snapshot for `settings` and publishes it. The engine catalog is rebuilt, and its revision
    /// bumped, only when `EngineInputs` changed (PRD-R27).
    @discardableResult
    public func publish(_ settings: SettingsState) -> TapSettingsPublication {
        let effective = settings.effective
        let inputs = EngineInputs(settings: effective, macros: settings.macros)
        let (snapshot, rebuilt, issues) = state.withLock { state in
            var rebuilt = false
            if state.inputs != inputs || state.catalog == nil {
                state.revision &+= 1
                let (table, issues) = EngineBridge.macroTable(from: inputs.macros)
                let resources = bundledResources(&state)
                let attached = EngineBridge.resources(settings: effective, macros: table) { resources }
                state.catalog = EngineBridge.catalog(settings: effective, resources: attached, revision: state.revision)
                state.inputs = inputs
                state.macroIssues = issues
                rebuilt = true
            }
            state.generation &+= 1
            let snapshot = TapSettingsSnapshot(
                generation: state.generation, engines: state.catalog!, toggleHotkey: effective.toggleHotkey,
                restoreHotkey: effective.restoreHotkey, macrosInEnglishMode: EnglishModeMacros.effective(effective),
                rememberPerApp: effective.rememberPerApp)
            return (snapshot, rebuilt, state.macroIssues)
        }
        cell.publish(snapshot)
        if !issues.isEmpty && rebuilt {
            logger.log(.note("macros rejected by the engine", category: .settings), level: .notice)
        }
        return TapSettingsPublication(snapshot: snapshot, rebuiltEngines: rebuilt, macroIssues: issues)
    }

    private func bundledResources(_ state: inout State) -> Resources {
        if let bundled = state.bundled { return bundled }
        let loaded: Resources
        do {
            loaded = try loadBundled()
        } catch {
            logger.log(.note("bundled word lists failed to load", category: .settings), level: .error)
            loaded = .empty
        }
        state.bundled = loaded
        return loaded
    }
}
