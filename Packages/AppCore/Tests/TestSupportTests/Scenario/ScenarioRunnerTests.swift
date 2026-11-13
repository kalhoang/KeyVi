// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PLT-R530 scenario execution with fakes: setup, typing, readback, state probe, verdict, duration.

import AppModel
import Foundation
import RealtimeSupport
import Testing

@testable import TestSupport

@Suite struct ScenarioRunnerTests {
    private func runner(
        driver: any KeyboardDriver = FakeDriver(),
        readback: any ScenarioReadback = FakeReadback(result: .success("đi")),
        setup: any ScenarioSetupPerformer = FakeSetup(), probe: (any ScenarioStateProbe)? = nil,
        clock: any MonotonicClock = ManualClock()
    ) -> ScenarioRunner {
        ScenarioRunner(driver: driver, readback: readback, setup: setup, probe: probe, clock: clock)
    }

    @Test func passesWhenTheFieldShowsTheExpectedText() async {
        let driver = FakeDriver()
        let setup = FakeSetup()
        let scenario = makeScenario(setup: [.init(action: .launch), .init(action: .focusField, value: "f")])
        let result = await runner(driver: driver, setup: setup).run(scenario)
        #expect(
            result
                == ScenarioResult(scenario: "sample.scenario", outcome: .pass, observedText: "đi", durationSeconds: 0))
        #expect(driver.typed.all == [["d", "d", "i"]])
        #expect(setup.steps.all.map(\.action) == [.launch, .focusField])
    }

    @Test func comparesByCanonicalEquivalence() async {
        // A decomposed (NFD) spelling of "việt" matches the precomposed expectation; a different text does not.
        let nfd = FakeReadback(result: .success("vie\u{0323}\u{0302}t"))
        #expect(await runner(readback: nfd).run(makeScenario(expect: .init(text: "việt"))).outcome == .pass)
        let wrong = FakeReadback(result: .success("ddi"))
        let result = await runner(readback: wrong).run(makeScenario())
        #expect(result.outcome == .fail)
        #expect(result.observedText == "ddi")
    }

    @Test func setupFailureFailsWithoutTyping() async {
        let driver = FakeDriver()
        let setup = FakeSetup(failOn: .launch)
        let result = await runner(driver: driver, setup: setup).run(makeScenario(setup: [.init(action: .launch)]))
        #expect(result.outcome == .fail)
        #expect(driver.typed.all.isEmpty)
    }

    @Test func driverOrReadbackErrorsFail() async {
        var failing = FakeDriver()
        failing.error = TestFailure.injected
        #expect(await runner(driver: failing).run(makeScenario()).outcome == .fail)
        let broken = FakeReadback(result: .failure(TestFailure.injected))
        #expect(await runner(readback: broken).run(makeScenario()).outcome == .fail)
    }

    @Test func humanReadbackWithoutATesterNeedsAPerson() async {
        let readback = FakeReadback(result: .failure(HumanReadbackRequired()))
        let result = await runner(readback: readback).run(makeScenario(readback: .human))
        #expect(result.outcome == .needsHuman)
        #expect(result.observedText == nil)
    }

    @Test func noTextExpectationSkipsTheReadback() async {
        let readback = FakeReadback(result: .success("ignored"))
        let probe = FakeProbe(observation: .init(paused: true))
        let result = await runner(readback: readback, probe: probe).run(makeScenario(expect: .init(paused: true)))
        #expect(result.outcome == .pass)
        #expect(readback.calls.all.isEmpty)
    }

    /// PLT-R398B shape: pause, holder and first key after release come from the app-state probe.
    @Test func stateExpectationsUseTheProbe() async {
        let expect = Scenario.Expectation(
            text: "đi", paused: true, holderBundleId: bundle("com.example.Holder"), firstKeyAfterReleaseComposed: true)
        let matching = FakeProbe(
            observation: .init(
                paused: true, holderBundleId: bundle("com.example.Holder"), firstKeyAfterReleaseComposed: true))
        #expect(await runner(probe: matching).run(makeScenario(expect: expect)).outcome == .pass)
        let otherHolder = FakeProbe(observation: .init(paused: true, holderBundleId: bundle("com.example.Other")))
        #expect(await runner(probe: otherHolder).run(makeScenario(expect: expect)).outcome == .fail)
        #expect(await runner(probe: nil).run(makeScenario(expect: expect)).outcome == .needsHuman)
    }

    @Test func durationComesFromTheInjectedClock() async {
        let clock = ManualClock()
        let result = await runner(driver: TimedDriver(clock: clock), clock: clock).run(makeScenario())
        #expect(result.durationSeconds == 0.03)
    }

    @Test func contractInitialiserRunsWithoutSetupOrProbe() async throws {
        let runner = ScenarioRunner(driver: FakeDriver(), readback: FakeReadback(result: .success("đi")))
        let result = await runner.run(makeScenario(setup: [.init(action: .launch)]))
        #expect(result.outcome == .pass)
        #expect(result.durationSeconds >= 0)
        try await NoScenarioSetup().perform(.init(action: .launch), for: makeScenario())  // no effect, no throw
    }
}

@Suite struct ScenarioVerdictTests {
    @Test func verdictTable() {
        let observed = ScenarioObservation(paused: false, holderBundleId: nil, firstKeyAfterReleaseComposed: true)
        #expect(ScenarioVerdict.outcome(expect: .init(text: "a"), text: "a", observation: nil) == .pass)
        #expect(ScenarioVerdict.outcome(expect: .init(text: "a"), text: nil, observation: nil) == .fail)
        #expect(ScenarioVerdict.outcome(expect: .init(paused: false), text: nil, observation: observed) == .pass)
        #expect(ScenarioVerdict.outcome(expect: .init(paused: true), text: nil, observation: observed) == .fail)
        #expect(
            ScenarioVerdict.outcome(
                expect: .init(holderBundleId: bundle("com.example.Holder")), text: nil, observation: observed)
                == .needsHuman)
        // A mismatch wins over an unobservable expectation.
        #expect(
            ScenarioVerdict.outcome(
                expect: .init(paused: true, holderBundleId: bundle("com.example.Holder")), text: nil,
                observation: observed)
                == .fail)
    }
}
