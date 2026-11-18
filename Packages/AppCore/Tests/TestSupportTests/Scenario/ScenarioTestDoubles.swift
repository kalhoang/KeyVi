// SPDX-License-Identifier: GPL-3.0-or-later
//
// Test doubles and fixtures for the scenario runner and compat-harness tests (W2-E1). Nothing here posts an
// event, opens an app or touches the network.

import AppModel
import Foundation
import RealtimeSupport

@testable import TestSupport

/// Repository root of this checkout, from this file's location.
let repositoryRoot: URL = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 { url.deleteLastPathComponent() }  // Scenario, TestSupportTests, Tests, AppCore, Packages, file
    return url
}()

func bundle(_ raw: String) -> BundleKey { BundleKey(rawValue: raw)! }

func makeScenario(
    id: String = "sample.scenario", target: String = "com.example.Editor", setup: [Scenario.SetupStep] = [],
    keys: [String] = ["d", "d", "i"], timing: Scenario.TimingProfile = .burst, readback: Scenario.Readback = .ax,
    expect: Scenario.Expectation = Scenario.Expectation(text: "đi"), readbackOptions: Scenario.ReadbackOptions? = nil
) -> Scenario {
    Scenario(
        id: id, targetBundleId: bundle(target), setup: setup, keys: keys, timing: timing, method: .telex,
        expect: expect, readback: readback, readbackOptions: readbackOptions)
}

enum TestFailure: Error { case injected }

final class Recorder<Value: Sendable>: Sendable {
    private let values = Mutex<[Value]>([])
    var all: [Value] { values.withLock { $0 } }
    func append(_ value: Value) { values.withLock { $0.append(value) } }
}

struct FakeDriver: KeyboardDriver {
    let typed = Recorder<[String]>()
    var error: (any Error)?
    func type(_ keys: [String], profile: Scenario.TimingProfile) async throws {
        typed.append(keys)
        if let error { throw error }
    }
}

struct FakeReadback: ScenarioReadback {
    var result: Result<String, any Error>
    let calls = Recorder<String>()
    func currentText(of scenario: Scenario) async throws -> String {
        calls.append(scenario.id)
        return try result.get()
    }
}

/// A readback that compares a different text from the field's full text (an `ax` readback that left out a declared
/// completion): returns `readings` in order, then the last one again.
final class FixedReadingReadback: ScenarioReadback, Sendable {
    private let readings: [ScenarioReading]
    private let reads = Mutex(0)
    init(_ readings: [ScenarioReading]) { self.readings = readings }
    func currentText(of scenario: Scenario) async throws -> String { try await currentReading(of: scenario).text }
    func currentReading(of scenario: Scenario) async throws -> ScenarioReading {
        reads.withLock { count in
            defer { count += 1 }
            return readings[min(count, readings.count - 1)]
        }
    }
}

/// A field the app is still writing to: each read returns the next text, then the last one again.
final class ChangingReadback: ScenarioReadback, Sendable {
    private let texts: [String]
    private let reads = Mutex(0)
    init(_ texts: [String]) { self.texts = texts }
    var readCount: Int { reads.withLock { $0 } }
    func currentText(of scenario: Scenario) async throws -> String {
        reads.withLock { count in
            defer { count += 1 }
            return texts[min(count, texts.count - 1)]
        }
    }
}

struct FakeSetup: ScenarioSetupPerformer {
    let steps = Recorder<Scenario.SetupStep>()
    /// The counts `awaitFocusRefresh(after:)` received; `focusRefreshCount()` answers 3.
    let focusWaits = Recorder<UInt64>()
    func focusRefreshCount() async -> UInt64? { 3 }
    func awaitFocusRefresh(after count: UInt64?) async { if let count { focusWaits.append(count) } }
    /// Scenario id of every performed step, in order.
    let scenarios = Recorder<String>()
    var failOn: Scenario.SetupStep.Action?
    var error: any Error = TestFailure.injected
    func perform(_ step: Scenario.SetupStep, for scenario: Scenario) async throws {
        steps.append(step)
        scenarios.append(scenario.id)
        if step.action == failOn { throw error }
    }
}

struct FakeProbe: ScenarioStateProbe {
    var observation: ScenarioObservation
    func observe(after scenario: Scenario) async throws -> ScenarioObservation { observation }
}

/// Clock-advancing driver: each keystroke takes 10 ms of virtual time.
struct TimedDriver: KeyboardDriver {
    let clock: ManualClock
    func type(_ keys: [String], profile: Scenario.TimingProfile) async throws {
        clock.advance(byMicroseconds: UInt64(keys.count) * 10_000)
    }
}

/// In-memory checkout with a brand file and the given scenario documents.
func makeCheckout(scenarios: [String: String], rules: String? = nil) throws -> InMemoryFileSystem {
    let fileSystem = InMemoryFileSystem()
    let root = URL(fileURLWithPath: "/repo")
    try fileSystem.createDirectory(
        at: root.appendingPathComponent("compat/scenarios"), permissions: .ownerOnlyDirectory)
    try fileSystem.createDirectory(at: root.appendingPathComponent("scripts"), permissions: .ownerOnlyDirectory)
    let brand = """
        # test brand
        APP_DISPLAY_NAME="Example App"
        APP_BUNDLE_ID_DEV="org.example.product.dev"
        APP_SITE_HOST="updates.example.org"

        """
    try fileSystem.writeAtomically(
        Data(brand.utf8), to: root.appendingPathComponent("scripts/brand.env"), permissions: .ownerOnlyFile)
    for (name, body) in scenarios {
        try fileSystem.writeAtomically(
            Data(body.utf8), to: root.appendingPathComponent("compat/scenarios/" + name), permissions: .ownerOnlyFile)
    }
    if let rules {
        try fileSystem.writeAtomically(
            Data(rules.utf8), to: root.appendingPathComponent("compat/rules.json"), permissions: .ownerOnlyFile)
    }
    return fileSystem
}

func scenarioJSON(
    id: String, target: String = "com.example.Editor", keys: String = #"["d","d","i"]"#,
    readback: String = "ax", extra: String = "", setup: String = "[]"
) -> String {
    """
    {"id":"\(id)","targetBundleId":"\(target)","setup":\(setup),"keys":\(keys),"timing":"burst",
     "method":"telex","expect":{"text":"đi"},"readback":"\(readback)"\(extra)}
    """
}
