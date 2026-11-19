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
    /// How many focus snapshots the app under test has published (T6 count of its integration hooks); nil when it
    /// cannot be asked. Taken before a focus change, for `awaitFocusRefresh(after:)`.
    func focusRefreshCount() async -> UInt64?
    /// The count once it held still for a quiet interval, bounded: taken before a focus shortcut, so a snapshot the
    /// keys before it caused (an Escape closing a panel) cannot end the wait for the shortcut's own (PLT-R530).
    func settledFocusRefreshCount() async -> UInt64?
    /// Waits, bounded, until the app published a focus snapshot after `count` (nil: returns at once).
    func awaitFocusRefresh(after count: UInt64?) async
}

extension ScenarioSetupPerformer {
    public func prepare(_ scenario: Scenario) async throws {}
    public func finish(_ scenario: Scenario) async {}
    public func focusRefreshCount() async -> UInt64? { nil }
    public func settledFocusRefreshCount() async -> UInt64? { await focusRefreshCount() }
    public func awaitFocusRefresh(after count: UInt64?) async {}
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
                try await type(Array(segment.keys), profile: scenario.timing, declared: scenario.focusShortcuts ?? [])
                if let step = segment.then {
                    stage = "setup " + step.action.rawValue
                    try await setup.perform(step, for: scenario)
                }
            }
            var fullText: String?
            if scenario.expect.needsReadback {
                stage = "readback " + scenario.readback.rawValue
                let reading = try await settledReading(of: scenario)
                (observed, fullText) = (reading.text, reading.fullText)
            }
            stage = "state probe"
            let observation = try await probe?.observe(after: scenario)
            outcome = ScenarioVerdict.outcome(
                expect: scenario.expect, text: observed, observation: observation, fullText: fullText)
            reason = ScenarioVerdict.reason(
                for: outcome, expect: scenario.expect, text: observed, observation: observation, fullText: fullText)
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

extension ScenarioRunner {
    /// Longest wait for the field to show the expected text after the last key. The app injects on its own worker
    /// after the key events (PLT-R311), so on a slow machine (the tart VM) the first read can come before the last
    /// replacement: the first VM run read "xin chào Việt Na" for "xin chào Việt Nam".
    static let readbackSettleNanoseconds: UInt64 = 2_000_000_000
    static let readbackPollNanoseconds: UInt64 = 100_000_000

    /// Pause after a focus shortcut in a key script before the next key: Command plus a digit moves focus or
    /// switches windows (TestHost's Window menu, a browser's tabs), which the target app and the app under test
    /// handle on their next turns; the first VM runs lost the word typed right after Command+1. Editing shortcuts
    /// (Command+A of every soak chunk) do not wait, nor does any other chord a scenario does not declare in
    /// `focusShortcuts` (PLT-R530).
    static let shortcutSettleNanoseconds: UInt64 = 300_000_000

    /// `command+<digit>`, with any further modifiers.
    static func isFocusShortcut(_ key: String) -> Bool {
        let parts = key.split(separator: "+")
        guard parts.count > 1, let last = parts.last, last.count == 1, last.first?.isNumber == true else {
            return false
        }
        return parts.dropLast().contains("command")
    }

    /// Types `keys`. A focus shortcut (Command plus a digit, or a chord in `declared`, the scenario's
    /// `focusShortcuts`) is typed on its own: the runner waits until the app under test published the new focus
    /// snapshot (`awaitFocusRefresh`), then `shortcutSettleNanoseconds`, before the next key. The count it waits
    /// from is taken once it held still (`settledFocusRefreshCount`), so a snapshot the keys before the shortcut
    /// caused (an Escape closing a panel) does not end the wait for the shortcut's own (PLT-R530).
    func type(_ keys: [String], profile: Scenario.TimingProfile, declared: [String] = []) async throws {
        var run: [String] = []
        for key in keys {
            guard Self.isFocusShortcut(key) || declared.contains(key) else {
                run.append(key)
                continue
            }
            if !run.isEmpty { try await driver.type(run, profile: profile) }
            run = []
            let before = await setup.settledFocusRefreshCount()
            try await driver.type([key], profile: profile)
            await setup.awaitFocusRefresh(after: before)
            clock.sleep(until: MonotonicInstant(nanoseconds: clock.now().nanoseconds &+ Self.shortcutSettleNanoseconds))
        }
        if !run.isEmpty { try await driver.type(run, profile: profile) }
    }

    /// The field's reading, read again every poll while its text differs from the expectation, until the settle time
    /// passed. A scenario without an expected text, and a person's readback, are read once.
    func settledReading(of scenario: Scenario) async throws -> ScenarioReading {
        var reading = try await readback.currentReading(of: scenario)
        guard let expected = scenario.expect.text, scenario.readback != .human else { return reading }
        let deadline = clock.now().nanoseconds &+ Self.readbackSettleNanoseconds
        while reading.text != expected, clock.now().nanoseconds < deadline {
            let next = min(deadline, clock.now().nanoseconds &+ Self.readbackPollNanoseconds)
            clock.sleep(until: MonotonicInstant(nanoseconds: next))
            reading = try await readback.currentReading(of: scenario)
        }
        return reading
    }
}

/// Compares an expectation with what was observed. A mismatch anywhere fails; an expectation nobody could
/// observe (no probe, or the probe returned nil) needs a person; everything matching passes.
///
/// `text` is compared with `expect.text`; the PLT-R422 residue check reads `fullText` (the field's whole text, `text`
/// when nil), which differs only where the scenario declares a selected completion the app's own (PLT-R530).
public enum ScenarioVerdict {
    public static func outcome(
        expect: Scenario.Expectation, text: String?, observation: ScenarioObservation?, fullText: String? = nil
    ) -> ScenarioResult.Outcome {
        // Swift `String ==` is canonical equivalence, so NFC and NFD spellings of the same text match.
        if let expected = expect.text, text != expected { return .fail }
        if expect.noPlaceholderResidue == true, let whole = fullText ?? text, hasPlaceholderResidue(whole) {
            return .fail
        }
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

    /// The verdict's reason with, for a failure, what differed: `text` (never the text itself, PLT-R901), the
    /// placeholder residue, and the observed app state next to the expected one (pause, holder bundle ID, first
    /// key after release). Lets the VM triage tell a text mismatch from a state mismatch.
    static func reason(
        for outcome: ScenarioResult.Outcome, expect: Scenario.Expectation, text: String?,
        observation: ScenarioObservation?, fullText: String? = nil
    ) -> String? {
        guard outcome == .fail, let base = reason(for: outcome) else { return reason(for: outcome) }
        let differences = mismatches(expect: expect, text: text, observation: observation, fullText: fullText)
        return differences.isEmpty ? base : base + " (" + differences.joined(separator: ", ") + ")"
    }

    static func mismatches(
        expect: Scenario.Expectation, text: String?, observation: ScenarioObservation?, fullText: String? = nil
    ) -> [String] {
        var differences: [String] = []
        if let expected = expect.text, text != expected { differences.append("text") }
        if expect.noPlaceholderResidue == true, let whole = fullText ?? text, hasPlaceholderResidue(whole) {
            differences.append("placeholder residue")
        }
        func state<Value: Equatable>(_ name: String, _ expected: Value?, _ observed: Value?, _ show: (Value) -> String)
        {
            guard let expected, let observed, expected != observed else { return }
            differences.append(name + " expected " + show(expected) + ", observed " + show(observed))
        }
        state("paused", expect.paused, observation?.paused) { String($0) }
        state("holder", expect.holderBundleId, observation?.holderBundleId) { $0.rawValue }
        state(
            "firstKeyAfterReleaseComposed", expect.firstKeyAfterReleaseComposed,
            observation?.firstKeyAfterReleaseComposed
        ) { String($0) }
        return differences
    }

    /// `true` matches or nothing expected, `false` mismatch, `nil` expected but not observed.
    private static func compare<Value: Equatable>(_ expected: Value?, _ observed: Value?) -> Bool? {
        guard let expected else { return true }
        guard let observed else { return nil }
        return expected == observed
    }
}
