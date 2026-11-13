// SPDX-License-Identifier: LicenseRef-App-Pending
//
// One scenario run (PLT-R530): setup steps, key script, readback, app-state observation, verdict. Every side
// effect goes through a protocol so the runner logic is tested with fakes; the live implementations live in
// CompatHarness/Live and run on the self-hosted runner only.

public import AppModel
internal import RealtimeSupport

/// Performs one setup step (launch, open URL, seed history, focus a field, select an input source, toggle
/// secure input, wait). Live: CompatHarness/Live/LiveSetup.swift.
public protocol ScenarioSetupPerformer: Sendable {
    func perform(_ step: Scenario.SetupStep, for scenario: Scenario) async throws
}

/// Does nothing: the scenario's preconditions are prepared by hand or by an outer script.
public struct NoScenarioSetup: ScenarioSetupPerformer {
    public init() {}
    public func perform(_ step: Scenario.SetupStep, for scenario: Scenario) async throws {}
}

/// App state after the key script, for expectations that are not field text. `nil` = not observable.
public struct ScenarioObservation: Sendable, Hashable {
    public var paused: Bool?
    public var holderBundleId: BundleKey?
    public var firstKeyAfterReleaseComposed: Bool?

    public init(paused: Bool? = nil, holderBundleId: BundleKey? = nil, firstKeyAfterReleaseComposed: Bool? = nil) {
        self.paused = paused
        self.holderBundleId = holderBundleId
        self.firstKeyAfterReleaseComposed = firstKeyAfterReleaseComposed
    }
}

/// Reads the app-under-test state (pause reason, secure-input holder). Provided by W2-E2 on the runner.
public protocol ScenarioStateProbe: Sendable {
    func observe(after scenario: Scenario) async throws -> ScenarioObservation
}

/// Thrown by a readback that needs a person (no terminal attached, `human` readback in CI).
public struct HumanReadbackRequired: Error, Sendable, Hashable {
    public init() {}
}

extension ScenarioRunner {
    func execute(_ scenario: Scenario) async -> ScenarioResult {
        let start = clock.now()
        var observed: String?
        let outcome: ScenarioResult.Outcome
        do {
            for step in Self.steps(of: scenario) { try await setup.perform(step, for: scenario) }
            try await driver.type(scenario.keys, profile: scenario.timing)
            if scenario.expect.text != nil { observed = try await readback.currentText(of: scenario) }
            let observation = try await probe?.observe(after: scenario)
            outcome = ScenarioVerdict.outcome(expect: scenario.expect, text: observed, observation: observation)
        } catch is HumanReadbackRequired {
            outcome = .needsHuman
        } catch {
            outcome = .fail
        }
        let elapsed = clock.now().nanoseconds &- start.nanoseconds
        return ScenarioResult(
            scenario: scenario.id, outcome: outcome, observedText: observed,
            durationSeconds: Double(elapsed) / 1_000_000_000)
    }
}

extension ScenarioRunner {
    /// Setup steps in execution order. A scenario's `layout` is selected first, so no scenario inherits the
    /// keyboard layout or input source a previous one switched to (13.2 layout scenarios).
    static func steps(of scenario: Scenario) -> [Scenario.SetupStep] {
        let layout = scenario.layout.map { [Scenario.SetupStep(action: .selectInputSource, value: $0.rawValue)] } ?? []
        return layout + scenario.setup
    }
}

/// Compares an expectation with what was observed. A mismatch anywhere fails; an expectation nobody could
/// observe (no probe, or the probe returned nil) needs a person; everything matching passes.
public enum ScenarioVerdict {
    public static func outcome(
        expect: Scenario.Expectation, text: String?, observation: ScenarioObservation?
    ) -> ScenarioResult.Outcome {
        // Swift `String ==` is canonical equivalence, so NFC and NFD spellings of the same text match.
        if let expected = expect.text, text != expected { return .fail }
        let checks: [Bool?] = [
            compare(expect.paused, observation?.paused),
            compare(expect.holderBundleId, observation?.holderBundleId),
            compare(expect.firstKeyAfterReleaseComposed, observation?.firstKeyAfterReleaseComposed),
        ]
        if checks.contains(false) { return .fail }
        return checks.contains(nil) ? .needsHuman : .pass
    }

    /// `true` matches or nothing expected, `false` mismatch, `nil` expected but not observed.
    private static func compare<Value: Equatable>(_ expected: Value?, _ observed: Value?) -> Bool? {
        guard let expected else { return true }
        guard let observed else { return nil }
        return expected == observed
    }
}
