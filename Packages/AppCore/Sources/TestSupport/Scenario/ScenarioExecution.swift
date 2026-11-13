// SPDX-License-Identifier: GPL-3.0-or-later
//
// One scenario run (PLT-R530): setup steps, key script, readback, app-state observation, verdict. Every side
// effect goes through a protocol so the runner logic is tested with fakes; the live implementations live in
// CompatHarness/Live and run on the self-hosted runner only.

public import AppModel
internal import RealtimeSupport

/// Performs one setup step (launch, open URL, seed history, focus a field, select an input source, toggle
/// secure input, wait). Live: CompatHarness/Live/LiveSetup.swift.
public protocol ScenarioSetupPerformer: Sendable {
    /// Called once before the scenario's first step (TestHost: clear every field, so no scenario reads text a
    /// previous one typed).
    func prepare(_ scenario: Scenario) async throws
    func perform(_ step: Scenario.SetupStep, for scenario: Scenario) async throws
    /// Called once after the scenario, also when it failed: undoes state the scenario changed on purpose (a
    /// revoked permission). Best effort; never fails the scenario.
    func finish(_ scenario: Scenario) async
}

extension ScenarioSetupPerformer {
    public func prepare(_ scenario: Scenario) async throws {}
    public func finish(_ scenario: Scenario) async {}
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

/// Thrown by a step that needs a person: a `human` readback with no terminal attached (CI), or a setup action
/// the runner cannot automate yet. The scenario then reports `needsHuman` with `reason`, not a failure.
public struct HumanReadbackRequired: Error, Sendable, Hashable {
    public var reason: String?
    public init(reason: String? = nil) { self.reason = reason }
}

extension ScenarioRunner {
    func execute(_ scenario: Scenario) async -> ScenarioResult {
        let start = clock.now()
        var observed: String?
        var stage = "setup"
        var outcome: ScenarioResult.Outcome
        var reason: String?
        do {
            stage = "prepare"
            try await setup.prepare(scenario)
            let schedule = ScenarioSchedule(scenario)
            for step in schedule.setup {
                stage = "setup " + step.action.rawValue
                try await setup.perform(step, for: scenario)
            }
            for segment in schedule.segments(of: scenario.keys) {
                stage = "typing"
                if !segment.keys.isEmpty { try await driver.type(Array(segment.keys), profile: scenario.timing) }
                if let step = segment.then {
                    stage = "setup " + step.action.rawValue
                    try await setup.perform(step, for: scenario)
                }
            }
            if scenario.expect.needsReadback {
                stage = "readback " + scenario.readback.rawValue
                observed = try await readback.currentText(of: scenario)
            }
            stage = "state probe"
            let observation = try await probe?.observe(after: scenario)
            outcome = ScenarioVerdict.outcome(expect: scenario.expect, text: observed, observation: observation)
            reason = ScenarioVerdict.reason(for: outcome)
            if outcome == .pass, let repetition = scenario.repetition,
                let failure = try await runRepetition(repetition, of: scenario, stage: &stage)
            {
                (outcome, reason, observed) = (.fail, failure.reason, failure.observed)
            }
        } catch let human as HumanReadbackRequired {
            outcome = .needsHuman
            reason = "needs a person: " + (human.reason ?? "no tester attached")
        } catch {
            // PLT-R530, QA-R21: the failing stage and the error's description (metadata only, PLT-R901).
            outcome = .fail
            reason = stage + ": " + String(describing: error)
        }
        await setup.finish(scenario)
        let elapsed = clock.now().nanoseconds &- start.nanoseconds
        return ScenarioResult(
            scenario: scenario.id, outcome: outcome, observedText: observed,
            durationSeconds: Double(elapsed) / 1_000_000_000, reason: reason)
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
        if expect.noPlaceholderResidue == true, let text, hasPlaceholderResidue(text) { return .fail }
        let checks: [Bool?] = [
            compare(expect.paused, observation?.paused),
            compare(expect.holderBundleId, observation?.holderBundleId),
            compare(expect.firstKeyAfterReleaseComposed, observation?.firstKeyAfterReleaseComposed),
        ]
        if checks.contains(false) { return .fail }
        return checks.contains(nil) ? .needsHuman : .pass
    }

    /// PLT-R421 placeholder (candidate U+200B ZERO WIDTH SPACE, VERIFY per app), the same scalar the injection
    /// worker inserts.
    static let placeholder: Unicode.Scalar = "\u{200B}"

    /// PLT-R422: the text still holds a placeholder the worker inserted.
    static func hasPlaceholderResidue(_ text: String) -> Bool { text.unicodeScalars.contains(placeholder) }

    /// Report text for a verdict outcome; nil for `pass`.
    static func reason(for outcome: ScenarioResult.Outcome) -> String? {
        switch outcome {
        case .pass: nil
        case .fail: "observed state differs from expect"
        case .needsHuman: "needs a person: expectation not observable here"
        }
    }

    /// `true` matches or nothing expected, `false` mismatch, `nil` expected but not observed.
    private static func compare<Value: Equatable>(_ expected: Value?, _ observed: Value?) -> Bool? {
        guard let expected else { return true }
        guard let observed else { return nil }
        return expected == observed
    }
}
