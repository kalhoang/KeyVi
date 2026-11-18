// SPDX-License-Identifier: GPL-3.0-or-later
//
// Compatibility scenario files (PLT-R530): `compat/scenarios/<id>.json`, schema
// compat/schema/scenario.schema.json. Executed by `compat-harness` on the self-hosted runner only.

public import AppModel
public import Foundation
public import RealtimeSupport

public struct Scenario: Sendable, Hashable, Codable {
    public enum TimingProfile: String, Sendable, Hashable, Codable { case normal, fast, burst }
    public enum Readback: String, Sendable, Hashable, Codable { case ax, webdriver, terminalCapture, human }
    public enum Method: String, Sendable, Hashable, Codable { case telex, vni }

    public struct SetupStep: Sendable, Hashable, Codable {
        public enum Action: String, Sendable, Hashable, Codable, CaseIterable {
            case launch, openURL, seedHistory, focusField, selectInputSource, setSecureInput, wait
            /// Triggers an integration hook of the app under test: `tapTimeout`, `revokePermission` or
            /// `restorePermission`, optionally `@N` to fire after the first N entries of `keys` (QA-R11). Answered
            /// only by the app's INTEGRATION_HOOKS test build (ADR 0502).
            case testHook
        }

        public var action: Action
        public var value: String?

        public init(action: Action, value: String? = nil) {
            self.action = action
            self.value = value
        }
    }

    public struct Expectation: Sendable, Hashable, Codable {
        public var text: String?
        public var paused: Bool?
        public var holderBundleId: BundleKey?
        public var firstKeyAfterReleaseComposed: Bool?
        /// PLT-R422: no read-back text (the key script's, and every `repeat` word's) holds the placeholder U+200B.
        public var noPlaceholderResidue: Bool?

        public init(
            text: String? = nil, paused: Bool? = nil, holderBundleId: BundleKey? = nil,
            firstKeyAfterReleaseComposed: Bool? = nil, noPlaceholderResidue: Bool? = nil
        ) {
            self.text = text
            self.paused = paused
            self.holderBundleId = holderBundleId
            self.firstKeyAfterReleaseComposed = firstKeyAfterReleaseComposed
            self.noPlaceholderResidue = noPlaceholderResidue
        }
    }

    /// `readbackOptions` in the file: how the readback reads the field (PLT-R530, amended 19/11/2026).
    public struct ReadbackOptions: Sendable, Hashable, Codable {
        /// `ax` readback only: a selection that runs to the end of the value is the app's own completion, from user
        /// history (Spotlight, a browser's address bar), and is left out of the text compared with `expect.text` and
        /// the `repeat` words (`AXReadbackText`). The PLT-R422 residue check still reads the whole value. Never on a
        /// TestHost scenario: TestHost completes deterministically, and its completion is part of the expected field
        /// text (QA-R21).
        public var excludesSelectedCompletion: Bool?

        public init(excludesSelectedCompletion: Bool? = nil) {
            self.excludesSelectedCompletion = excludesSelectedCompletion
        }
    }

    /// `repeat` in the file (PLT-R422 gate, section 4 acceptance): after the key script passes, `words`
    /// randomised words of the Telex soak corpus drawn with `seed`, each typed after `prefix` at `timing` and
    /// read back on its own; every word must read back as exactly its corpus text.
    public struct Repetition: Sendable, Hashable, Codable {
        public var words: Int
        public var seed: UInt64
        public var timing: TimingProfile
        /// Typed before every word; must leave the field empty or its content selected, so the word replaces it
        /// (`command+l` in an address bar).
        public var prefix: [String]

        public init(words: Int, seed: UInt64, timing: TimingProfile, prefix: [String]) {
            self.words = words
            self.seed = seed
            self.timing = timing
            self.prefix = prefix
        }
    }

    public var id: String
    public var targetBundleId: BundleKey
    public var setup: [SetupStep]
    /// Physical key names (`a`, `shift`, `space`, `return`, `backspace`, ...), layout-independent positions.
    public var keys: [String]
    public var timing: TimingProfile
    public var method: Method
    public var layout: InputSourceID?
    public var expect: Expectation
    public var readback: Readback
    public var readbackOptions: ReadbackOptions?
    public var repetition: Repetition?
    /// Chords of `keys` the runner waits after, like Command plus a digit (PLT-R530): it types the chord on its own,
    /// waits until the app under test published a new focus snapshot, then `shortcutSettleNanoseconds`. For a
    /// shortcut that opens a panel or moves focus where the scenario proves what happens after the opening, not the
    /// race with it (`testhost.panel.inlineCompletionTwice`, integration-suite.md section 10.10).
    public var focusShortcuts: [String]?

    public init(
        id: String, targetBundleId: BundleKey, setup: [SetupStep], keys: [String], timing: TimingProfile,
        method: Method, layout: InputSourceID? = nil, expect: Expectation, readback: Readback,
        readbackOptions: ReadbackOptions? = nil, repetition: Repetition? = nil, focusShortcuts: [String]? = nil
    ) {
        self.id = id
        self.targetBundleId = targetBundleId
        self.setup = setup
        self.keys = keys
        self.timing = timing
        self.method = method
        self.layout = layout
        self.expect = expect
        self.readback = readback
        self.readbackOptions = readbackOptions
        self.repetition = repetition
        self.focusShortcuts = focusShortcuts
    }

    enum CodingKeys: String, CodingKey {
        case id, targetBundleId, setup, keys, timing, method, layout, expect, readback, readbackOptions, focusShortcuts
        case repetition = "repeat"
    }
}

/// Posts physical-like events (harness process, its own event source) with the timing profile.
public protocol KeyboardDriver: Sendable {
    func type(_ keys: [String], profile: Scenario.TimingProfile) async throws
}

public protocol ScenarioReadback: Sendable {
    func currentText(of scenario: Scenario) async throws -> String
    /// The compared text and the field's full text from one read; by default `currentText(of:)` for both.
    func currentReading(of scenario: Scenario) async throws -> ScenarioReading
}

extension ScenarioReadback {
    public func currentReading(of scenario: Scenario) async throws -> ScenarioReading {
        ScenarioReading(text: try await currentText(of: scenario))
    }
}

/// One read of the field (PLT-R530): `text` is compared with `expect.text` and the `repeat` words; `fullText` is the
/// field's whole text, which the PLT-R422 residue check reads. They differ only where the scenario declares a
/// selected completion the app's own (`readbackOptions.excludesSelectedCompletion`).
public struct ScenarioReading: Sendable, Hashable {
    public var text: String
    public var fullText: String

    public init(text: String, fullText: String? = nil) {
        self.text = text
        self.fullText = fullText ?? text
    }
}

public struct ScenarioResult: Sendable, Hashable, Codable {
    public enum Outcome: String, Sendable, Hashable, Codable { case pass, fail, needsHuman }
    public var scenario: String
    public var outcome: Outcome
    public var observedText: String?
    public var durationSeconds: Double
    /// Why the outcome is `fail` or `needsHuman` (failing stage and error description: bundle ids, identifiers,
    /// error names, never typed text, PLT-R901); nil on `pass`. Optional in `results.json` (PLT-R530, QA-R21).
    public var reason: String?

    public init(
        scenario: String, outcome: Outcome, observedText: String?, durationSeconds: Double, reason: String? = nil
    ) {
        self.scenario = scenario
        self.outcome = outcome
        self.observedText = observedText
        self.durationSeconds = durationSeconds
        self.reason = reason
    }
}

public struct ScenarioRunner: Sendable {
    let driver: any KeyboardDriver
    let readback: any ScenarioReadback
    let setup: any ScenarioSetupPerformer
    let probe: (any ScenarioStateProbe)?
    let clock: any MonotonicClock

    public init(driver: any KeyboardDriver, readback: any ScenarioReadback) {
        self.init(driver: driver, readback: readback, setup: NoScenarioSetup(), probe: nil, clock: MachClock())
    }

    /// Full form used by `compat-harness`: performs the setup steps, asks `probe` for the app state the
    /// expectation names (paused, holder, first key after release) and times the run with `clock`.
    public init(
        driver: any KeyboardDriver, readback: any ScenarioReadback, setup: any ScenarioSetupPerformer,
        probe: (any ScenarioStateProbe)?, clock: any MonotonicClock
    ) {
        self.driver = driver
        self.readback = readback
        self.setup = setup
        self.probe = probe
        self.clock = clock
    }

    public func run(_ scenario: Scenario) async -> ScenarioResult { await execute(scenario) }

    /// Every `*.json` file of `directory`, sorted by file name, decoded strictly and validated
    /// (`ScenarioLoader`). Throws `ScenarioLoadError` naming the first invalid file.
    public static func load(directory: URL) throws -> [Scenario] {
        try ScenarioLoader().load(directory: directory)
    }
}
