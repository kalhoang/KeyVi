// SPDX-License-Identifier: LicenseRef-App-Pending
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
            /// `restorePermission`, optionally `@N` to fire after the first N entries of `keys` (QA-R11).
            /// Requested addition to compat/schema/scenario.schema.json (`ScenarioValidator.pendingSchemaActions`).
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

        public init(
            text: String? = nil, paused: Bool? = nil, holderBundleId: BundleKey? = nil,
            firstKeyAfterReleaseComposed: Bool? = nil
        ) {
            self.text = text
            self.paused = paused
            self.holderBundleId = holderBundleId
            self.firstKeyAfterReleaseComposed = firstKeyAfterReleaseComposed
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

    public init(
        id: String, targetBundleId: BundleKey, setup: [SetupStep], keys: [String], timing: TimingProfile,
        method: Method, layout: InputSourceID? = nil, expect: Expectation, readback: Readback
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
    }
}

/// Posts physical-like events (harness process, its own event source) with the timing profile.
public protocol KeyboardDriver: Sendable {
    func type(_ keys: [String], profile: Scenario.TimingProfile) async throws
}

public protocol ScenarioReadback: Sendable {
    func currentText(of scenario: Scenario) async throws -> String
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
