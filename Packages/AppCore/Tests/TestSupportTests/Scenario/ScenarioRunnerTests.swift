// SPDX-License-Identifier: GPL-3.0-or-later
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

    /// The app injects after the last key on its own worker (PLT-R311): a read right after the keys can come
    /// before the last replacement, as the first VM run showed ("xin chào Việt Na"). The field is read again until
    /// it shows the expectation, for at most the settle time.
    @Test func readsAgainUntilTheFieldShowsTheExpectedText() async {
        let clock = ManualClock()
        let field = ChangingReadback(["đ", "đi"])
        let result = await runner(readback: field, clock: clock).run(makeScenario())
        #expect(result.outcome == .pass && result.observedText == "đi")
        #expect(field.readCount == 2)
        #expect(result.durationSeconds == Double(ScenarioRunner.readbackPollNanoseconds) / 1_000_000_000)
    }

    @Test func aFieldThatNeverShowsTheExpectationFailsAfterTheSettleTime() async {
        let clock = ManualClock()
        let field = ChangingReadback(["ddi"])
        let result = await runner(readback: field, clock: clock).run(makeScenario())
        #expect(result.outcome == .fail && result.observedText == "ddi")
        #expect(result.durationSeconds == Double(ScenarioRunner.readbackSettleNanoseconds) / 1_000_000_000)
        #expect(
            field.readCount
                == 1 + Int(ScenarioRunner.readbackSettleNanoseconds / ScenarioRunner.readbackPollNanoseconds))
    }

    /// Command plus a digit moves focus or switches windows (TestHost's Window menu): the keys after it wait for
    /// the shortcut settle, or they reach the old window (the first VM runs lost the first word typed after
    /// Command+1 in testhost.perWindowRule.*). Editing shortcuts such as Command+A do not wait.
    @Test func keysAfterAFocusShortcutWaitForTheShortcutSettle() async {
        let driver = FakeDriver()
        let clock = ManualClock()
        let scenario = makeScenario(keys: ["command+2", "v", "i", "command+1", "command+a", "space", "shift+d"])
        let result = await runner(driver: driver, readback: FakeReadback(result: .success("đi")), clock: clock)
            .run(scenario)
        #expect(driver.typed.all == [["command+2"], ["v", "i", "command+1"], ["command+a", "space", "shift+d"]])
        #expect(result.durationSeconds == 2 * Double(ScenarioRunner.shortcutSettleNanoseconds) / 1_000_000_000)
        #expect(ScenarioRunner.isFocusShortcut("shift+command+1") && !ScenarioRunner.isFocusShortcut("command+a"))
        #expect(!ScenarioRunner.isFocusShortcut("shift+2") && !ScenarioRunner.isFocusShortcut("command+f10"))
        #expect(!ScenarioRunner.isFocusShortcut("1") && !ScenarioRunner.isFocusShortcut("command"))
    }

    /// The reason names what differed, with the observed state next to the expected one, never the typed text.
    @Test func aFailureNamesTheMismatchedExpectations() {
        let expect = Scenario.Expectation(
            text: "duyeetj", paused: true, holderBundleId: bundle("org.example.product.dev.testhost"))
        let observation = ScenarioObservation(paused: false, holderBundleId: bundle("org.example.product.dev.testhost"))
        #expect(
            ScenarioVerdict.reason(for: .fail, expect: expect, text: "duyeetj", observation: observation)
                == "observed state differs from expect (paused expected true, observed false)")
        let other = ScenarioObservation(paused: true, holderBundleId: bundle("com.example.Other"))
        #expect(
            ScenarioVerdict.reason(for: .fail, expect: expect, text: "duyệt", observation: other)
                == "observed state differs from expect (text, holder expected org.example.product.dev.testhost, "
                + "observed com.example.Other)")
        #expect(ScenarioVerdict.reason(for: .pass, expect: expect, text: "duyeetj", observation: nil) == nil)
    }

    /// A person is asked once; only machine readbacks are polled.
    @Test func aHumanReadbackIsAskedOnce() async {
        let clock = ManualClock()
        let field = ChangingReadback(["ddi", "đi"])
        let result = await runner(readback: field, clock: clock).run(makeScenario(readback: .human))
        #expect(result.outcome == .fail && field.readCount == 1 && result.durationSeconds == 0)
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

    /// 13.2 layout scenarios: the scenario's layout is selected before its own setup steps.
    @Test func layoutIsSelectedBeforeTheSetupSteps() async {
        let setup = FakeSetup()
        var scenario = makeScenario(setup: [.init(action: .launch)])
        scenario.layout = InputSourceID(rawValue: "com.apple.keylayout.Dvorak")
        _ = await runner(setup: setup).run(scenario)
        #expect(
            setup.steps.all == [
                .init(action: .selectInputSource, value: "com.apple.keylayout.Dvorak"), .init(action: .launch),
            ])
    }

    @Test func setupFailureFailsWithoutTyping() async {
        let driver = FakeDriver()
        let setup = FakeSetup(failOn: .launch)
        let result = await runner(driver: driver, setup: setup).run(makeScenario(setup: [.init(action: .launch)]))
        #expect(result.outcome == .fail)
        #expect(driver.typed.all.isEmpty)
        // PLT-R530, QA-R21: the report says why (error metadata only, never typed text).
        #expect(result.reason == "setup launch: injected")
    }

    @Test func everyNonPassingOutcomeCarriesAReason() async {
        var failing = FakeDriver()
        failing.error = TestFailure.injected
        #expect(await runner(driver: failing).run(makeScenario()).reason == "typing: injected")
        let broken = FakeReadback(result: .failure(TestFailure.injected))
        #expect(await runner(readback: broken).run(makeScenario()).reason == "readback ax: injected")
        let wrong = FakeReadback(result: .success("ddi"))
        #expect(
            await runner(readback: wrong).run(makeScenario()).reason == "observed state differs from expect (text)")
        let human = FakeReadback(result: .failure(HumanReadbackRequired()))
        #expect(
            await runner(readback: human).run(makeScenario(readback: .human)).reason
                == "needs a person: no tester attached")
        let toggle = FakeSetup(failOn: .setSecureInput, error: HumanReadbackRequired(reason: "toggle by hand"))
        let manual = await runner(setup: toggle).run(makeScenario(setup: [.init(action: .setSecureInput, value: "on")]))
        #expect(manual.outcome == .needsHuman)
        #expect(manual.reason == "needs a person: toggle by hand")
        let expect = Scenario.Expectation(paused: true)
        #expect(
            await runner(probe: nil).run(makeScenario(expect: expect)).reason
                == "needs a person: expectation not observable here")
        #expect(await runner().run(makeScenario()).reason == nil)
    }

    @Test func reasonIsOptionalInTheReportFormat() throws {
        let old = #"{"scenario":"a","outcome":"fail","durationSeconds":1}"#
        let decoded = try JSONDecoder().decode(ScenarioResult.self, from: Data(old.utf8))
        #expect(decoded.reason == nil && decoded.outcome == .fail)
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
