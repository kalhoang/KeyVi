// SPDX-License-Identifier: GPL-3.0-or-later
//
// Expected-text oracle for TestHost scenarios: replays a key script through the real engine, configured from the
// settings files the harness writes for the scenario (AppSettingsDocuments -> SettingsStore -> EngineBridge), and
// applies every engine action to model fields the way the pipeline delivers it into a plain Cocoa field (ABC
// layout). Scenario files then assert the text the app must produce, not text someone guessed: if the engine or a
// profile changes, ScenarioOracleTests names the scenario whose expectation went stale.

import AppModel
import Diagnostics
import Foundation
import InputHost
import SettingsStore
import VietnameseEngine
import VietnameseEngineData

@testable import TestSupport

/// What an Escape that reaches TestHost's escape field shows (EscapeMarkingTextView.marker; PLT-R353).
enum EscapeMarker {
    static let value = "<esc>"
}

struct ScenarioTextOracle {
    static let escapeMarker = EscapeMarker.value

    private(set) var fields: [String: String] = [:]
    private(set) var mode = TypingMode.vietnamese
    /// Toggle-hotkey presses, so tests can check every scenario ends in Vietnamese mode.
    private(set) var toggles = 0
    private var session: Session
    private let restoreHotkeyBound: Bool
    private let passThroughFields: Set<String>
    private var focused: String
    private let focusShortcuts: [String: String]
    /// Fields whose rule turns the restore hotkey off (`features.restoreHotkey: false`, PLT-R353): an Escape there
    /// always passes through.
    private let noRestoreFields: Set<String>
    /// `revokePermission` fired: the host failed open, keys pass untouched until `restorePermission` (PLT-R730).
    private var failedOpen = false

    /// `focusShortcuts`: key name -> field it focuses (TestHost's Command+1 and Command+2).
    init(
        settings: SettingsState, focused: String, passThroughFields: Set<String> = [],
        focusShortcuts: [String: String] = [:], noRestoreFields: Set<String> = []
    ) throws {
        session = Session(engine: try Self.engine(settings: settings))
        restoreHotkeyBound = settings.effective.restoreHotkey == .key(.escape)
        self.passThroughFields = passThroughFields
        self.focused = focused
        self.focusShortcuts = focusShortcuts
        self.noRestoreFields = noRestoreFields
    }

    /// The default-variant engine the app builds from these settings (EngineBridge, ADR 0306).
    static func engine(settings: SettingsState) throws -> Engine {
        let (macros, _) = EngineBridge.macroTable(from: settings.macros)
        let resources = try EngineBridge.resources(settings: settings.effective, macros: macros) {
            try Resources.bundled(userKeepRaw: WordSet([]), userKeepVietnamese: WordSet([]))
        }
        return EngineBridge.catalog(settings: settings.effective, resources: resources).engine(for: .default)
    }

    var text: String { fields[focused] ?? "" }

    func text(of field: String) -> String { fields[field] ?? "" }

    mutating func type(_ keys: [String]) {
        for key in keys { press(key) }
    }

    /// What the app's integration hooks do to the text (ADR 0502): a tap timeout resets the engine (PLT-R330,
    /// ENG-R1010 `eventTapReenabled`); a revoked permission fails open and resets (PLT-R730) until restored.
    mutating func trigger(_ hook: AppTestHook) {
        switch hook {
        case .tapTimeout: _ = session.handle(.reset(.eventTapReenabled))
        case .revokePermission:
            failedOpen = true
            _ = session.handle(.reset(.unknown))
        case .restorePermission: failedOpen = false
        }
    }

    private mutating func press(_ key: String) {
        if let field = focusShortcuts[key] {
            _ = session.handle(.reset(.focusChanged))
            focused = field
            return
        }
        switch key {
        case "control+shift":
            mode = mode == .vietnamese ? .english : .vietnamese
            toggles += 1
            _ = session.handle(.reset(.modeToggled))
        case "backspace": backspace()
        case "escape": escape()
        default:
            guard let character = Self.character(for: key) else { return }
            insert(character)
        }
    }

    private var transforms: Bool { mode == .vietnamese && !failedOpen && !passThroughFields.contains(focused) }

    private mutating func insert(_ character: Character) {
        guard transforms else { return append(String(character)) }
        let output = session.handle(.key(KeyInput(character)))
        apply(output.action, passThrough: { $0.append(String(character)) })
    }

    private mutating func backspace() {
        guard transforms else { return deleteLast() }
        apply(session.handle(.backspace).action, passThrough: { $0.deleteLast() })
    }

    private mutating func escape() {
        if transforms, restoreHotkeyBound, !noRestoreFields.contains(focused) {
            let action = session.handle(.restoreToggle).action
            if case .edit = action { return apply(action, passThrough: { _ in }) }
        }
        _ = session.handle(.reset(.unknown))
        append(Self.escapeMarker)
    }

    private mutating func apply(_ action: KeyAction, passThrough: (inout Self) -> Void) {
        switch action {
        case .passThrough: passThrough(&self)
        case .edit(let edit, let thenPassThrough):
            var current = Array(text)
            current.removeLast(min(edit.deleteCount, current.count))
            fields[focused] = String(current) + edit.insert
            if thenPassThrough { passThrough(&self) }
        }
    }

    private mutating func append(_ string: String) { fields[focused, default: ""] += string }

    private mutating func deleteLast() {
        var current = Array(text)
        if !current.isEmpty { current.removeLast() }
        fields[focused] = String(current)
    }

    /// Characters of the ABC (US) layout for the scenario key names.
    static func character(for key: String) -> Character? {
        let shifted: [Character: Character] = [
            "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
        ]
        let named: [String: Character] = [
            "space": " ", "comma": ",", "period": ".", "semicolon": ";", "slash": "/", "minus": "-", "equal": "=",
            "quote": "'", "leftBracket": "[", "rightBracket": "]", "return": "\n", "tab": "\t",
        ]
        if key.hasPrefix("shift+") {
            let base = String(key.dropFirst(6))
            guard base.count == 1, let first = base.first else { return nil }
            return shifted[first] ?? Character(base.uppercased())
        }
        if key.count == 1, let first = key.first, first.isLetter || first.isNumber { return first }
        return named[key]
    }
}

/// Settings the app loads for a scenario: the harness's documents read back by the real SettingsStore.
enum OracleSettings {
    static func load(_ configuration: AppConfiguration, targets: HarnessTargets) async throws -> SettingsState {
        let rules = try Data(contentsOf: repositoryRoot.appendingPathComponent("compat/rules.json"))
        let documents = AppSettingsDocuments(
            targets: targets, shippedActions: AppSettingsDocuments.shippedActions(rulesData: rules))
        let fileSystem = InMemoryFileSystem()
        let location = StorageLocation(directory: URL(fileURLWithPath: "/support/App"))
        try fileSystem.createDirectory(at: location.directory, permissions: .ownerOnlyDirectory)
        for (file, data) in try documents.documents(for: configuration, onboarding: nil) {
            try fileSystem.writeAtomically(data, to: location.url(for: file), permissions: .ownerOnlyFile)
        }
        let store = SettingsStore(
            location: location, fileSystem: fileSystem, wallClock: FixedWallClock(Date(timeIntervalSince1970: 0)),
            writtenBy: "oracle", queue: DispatchQueue(label: "oracle.settings"),
            launchGuard: LaunchGuard(store: InMemoryKeyValueStore()), onChange: { _ in })
        return await store.load()
    }
}
