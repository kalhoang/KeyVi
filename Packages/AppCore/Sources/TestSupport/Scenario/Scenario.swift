// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Compatibility scenario files (PLT-R530): `compat/scenarios/<id>.json`, schema
// compat/schema/scenario.schema.json. Executed by `compat-harness` on the self-hosted runner only.

public import AppModel
public import Foundation

public struct Scenario: Sendable, Hashable, Codable {
    public enum TimingProfile: String, Sendable, Hashable, Codable { case normal, fast, burst }
    public enum Readback: String, Sendable, Hashable, Codable { case ax, webdriver, terminalCapture, human }
    public enum Method: String, Sendable, Hashable, Codable { case telex, vni }

    public struct SetupStep: Sendable, Hashable, Codable {
        public enum Action: String, Sendable, Hashable, Codable {
            case launch, openURL, seedHistory, focusField, selectInputSource, setSecureInput, wait
        }

        public var action: Action
        public var value: String?
    }

    public struct Expectation: Sendable, Hashable, Codable {
        public var text: String?
        public var paused: Bool?
        public var holderBundleId: BundleKey?
        public var firstKeyAfterReleaseComposed: Bool?
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
}

public struct ScenarioRunner: Sendable {
    public init(driver: any KeyboardDriver, readback: any ScenarioReadback) { unimplemented() }
    public func run(_ scenario: Scenario) async -> ScenarioResult { unimplemented() }
    public static func load(directory: URL) throws -> [Scenario] { unimplemented() }
}
