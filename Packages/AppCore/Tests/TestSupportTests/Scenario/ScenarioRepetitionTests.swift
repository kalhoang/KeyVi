// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PLT-R422 and the section 4 acceptance: the scenario `repeat` block types 1,000 randomised corpus words at burst
// speed, reads every word back and fails on a duplicated or lost letter or a leftover placeholder (U+200B).

import AppModel
import CompatRules
import Foundation
import RealtimeSupport
import Testing

@testable import TestSupport

/// Returns the scripted texts in order, then repeats the last one.
private struct ScriptedReadback: ScenarioReadback {
    let texts: [String]
    let calls = Recorder<String>()
    func currentText(of scenario: Scenario) async throws -> String {
        calls.append(scenario.id)
        return texts[min(calls.all.count, texts.count) - 1]
    }
}

/// Fails on the `failOnCall`-th call (1-based).
private struct FailingDriver: KeyboardDriver {
    let failOnCall: Int
    let calls = Recorder<[String]>()
    func type(_ keys: [String], profile: Scenario.TimingProfile) async throws {
        calls.append(keys)
        if calls.all.count == failOnCall { throw TestFailure.injected }
    }
}

private struct FailingReadback: ScenarioReadback {
    let failOnCall: Int
    let texts: [String]
    let calls = Recorder<String>()
    func currentText(of scenario: Scenario) async throws -> String {
        calls.append(scenario.id)
        if calls.all.count == failOnCall { throw TestFailure.injected }
        return texts[min(calls.all.count, texts.count) - 1]
    }
}

private let gate = Scenario.Repetition(words: 3, seed: 7, timing: .burst, prefix: ["command+l"])

private func repeatingScenario(
    _ repetition: Scenario.Repetition = gate,
    expect: Scenario.Expectation = Scenario.Expectation(text: "đi", noPlaceholderResidue: true)
) -> Scenario {
    var scenario = makeScenario(timing: .normal, expect: expect)
    scenario.repetition = repetition
    return scenario
}

private func runner(driver: FakeDriver = FakeDriver(), readback: any ScenarioReadback) -> ScenarioRunner {
    ScenarioRunner(driver: driver, readback: readback, setup: FakeSetup(), probe: nil, clock: ManualClock())
}

@Suite struct ScenarioRepetitionTests {
    @Test func planIsSeededAndDrawsFromTheTelexCorpus() {
        let words = ScenarioRepetitionPlan.words(for: gate)
        #expect(words.count == 3)
        #expect(words == ScenarioRepetitionPlan.words(for: gate))
        let corpus = SoakCorpus.words.map { ScenarioRepetitionWord(keys: $0.keys.map(String.init), text: $0.text) }
        #expect(words.allSatisfy(corpus.contains))
        var other = gate
        other.seed = 8
        other.words = 50
        #expect(ScenarioRepetitionPlan.words(for: other).prefix(3) != words[...])
        #expect(Set(ScenarioRepetitionPlan.words(for: other)).count > 1)
    }

    /// After the key script passes, every word is typed after the prefix at the repeat timing and read back.
    @Test func everyWordIsTypedAfterThePrefixAndReadBack() async {
        let words = ScenarioRepetitionPlan.words(for: gate)
        let driver = FakeDriver()
        let readback = ScriptedReadback(texts: ["đi"] + words.map(\.text))
        let result = await runner(driver: driver, readback: readback).run(repeatingScenario())
        #expect(result.outcome == .pass, "\(result.reason ?? "")")
        #expect(driver.typed.all == [["d", "d", "i"]] + words.map { ["command+l"] + $0.keys })
        #expect(readback.calls.all.count == 4)
    }

    @Test func aLeftoverPlaceholderFailsTheWordThatShowsIt() async {
        let words = ScenarioRepetitionPlan.words(for: gate)
        let readback = ScriptedReadback(texts: ["đi", words[0].text, "\u{200B}" + words[1].text, words[2].text])
        let result = await runner(readback: readback).run(repeatingScenario())
        #expect(result.outcome == .fail)
        #expect(result.reason == "repeat word 2 of 3: leftover placeholder U+200B")
        #expect(readback.calls.all.count == 3)
    }

    @Test func aDuplicatedLetterFailsWithoutNamingTheText() async {
        let words = ScenarioRepetitionPlan.words(for: gate)
        let readback = ScriptedReadback(texts: ["đi", "x" + words[0].text])
        let result = await runner(readback: readback).run(repeatingScenario())
        #expect(result.outcome == .fail)
        #expect(result.reason == "repeat word 1 of 3: observed text differs from the corpus word")
        #expect(result.observedText == "x" + words[0].text)
    }

    @Test func aFailingKeyScriptSkipsTheRepetition() async {
        let driver = FakeDriver()
        let readback = ScriptedReadback(texts: ["dđi"])
        let result = await runner(driver: driver, readback: readback).run(repeatingScenario())
        #expect(result.outcome == .fail && result.reason == "observed state differs from expect")
        #expect(driver.typed.all.count == 1)
    }

    @Test func anErrorDuringTheRepetitionNamesTheWordAndStage() async {
        let words = ScenarioRepetitionPlan.words(for: gate)
        let typing = await ScenarioRunner(
            driver: FailingDriver(failOnCall: 3), readback: ScriptedReadback(texts: ["đi"] + words.map(\.text)),
            setup: FakeSetup(), probe: nil, clock: ManualClock()
        ).run(repeatingScenario())
        #expect(typing.outcome == .fail && typing.reason == "repeat word 2 of 3 typing: injected")
        let reading = await runner(readback: FailingReadback(failOnCall: 2, texts: ["đi"])).run(repeatingScenario())
        #expect(reading.reason == "repeat word 1 of 3 readback ax: injected")
    }

    /// `noPlaceholderResidue` alone is an expectation: the field is read back and must not hold U+200B.
    @Test func residueExpectationReadsBackWithoutAnExpectedText() async {
        var scenario = makeScenario(expect: Scenario.Expectation(noPlaceholderResidue: true))
        let clean = await runner(readback: ScriptedReadback(texts: ["anything"])).run(scenario)
        #expect(clean.outcome == .pass && clean.observedText == "anything")
        let residue = await runner(readback: ScriptedReadback(texts: ["a\u{200B}"])).run(scenario)
        #expect(residue.outcome == .fail)
        scenario.expect.noPlaceholderResidue = false
        #expect(await runner(readback: ScriptedReadback(texts: ["a\u{200B}"])).run(scenario).outcome == .pass)
    }

    /// The Swift model and CompatRules' file check (`compat-lint`) agree on what counts as the PLT-R422 gate.
    @Test func gateDeclarationMatchesTheLinter() throws {
        var full = gate
        full.words = PlaceholderGate.minimumWords
        let variants: [Scenario] = [
            repeatingScenario(full),
            repeatingScenario(gate),
            repeatingScenario(Scenario.Repetition(words: 1_000, seed: 1, timing: .fast, prefix: ["command+l"])),
            repeatingScenario(full, expect: Scenario.Expectation(text: "đi")),
            makeScenario(expect: Scenario.Expectation(noPlaceholderResidue: true)),
        ]
        var human = repeatingScenario(full)
        human.readback = .human
        var gates: [Bool] = []
        for scenario in variants + [human] {
            let raw = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(scenario))
            #expect(PlaceholderGate.isDeclared(in: raw) == scenario.declaresPlaceholderGate, "\(scenario)")
            gates.append(scenario.declaresPlaceholderGate)
        }
        #expect(gates == [true, false, false, false, false, false])
    }

    @Test func validatorStatesWhatTheRepeatNeeds() {
        var vni = repeatingScenario()
        vni.method = .vni
        #expect(ScenarioValidator.problems(in: vni) == ["repeat needs method telex (Telex soak corpus words)"])
        var human = repeatingScenario()
        human.readback = .human
        #expect(ScenarioValidator.problems(in: human) == ["repeat needs an ax or webdriver readback"])
        for words in [0, ScenarioValidator.maximumRepeatWords + 1] {
            var scenario = repeatingScenario()
            scenario.repetition?.words = words
            #expect(
                ScenarioValidator.problems(in: scenario)
                    == ["repeat.words must be 1 to \(ScenarioValidator.maximumRepeatWords)"])
        }
        var noPrefix = repeatingScenario()
        noPrefix.repetition?.prefix = []
        #expect(ScenarioValidator.problems(in: noPrefix) == ["repeat.prefix must not be empty"])
        var badPrefix = repeatingScenario()
        badPrefix.repetition?.prefix = ["ctrl-l"]
        #expect(ScenarioValidator.problems(in: badPrefix) == ["repeat.prefix[0] 'ctrl-l' is not a physical key name"])
        #expect(ScenarioValidator.problems(in: repeatingScenario()).isEmpty)
        #expect(ScenarioValidator.problems(in: makeScenario(expect: .init(noPlaceholderResidue: true))).isEmpty)
    }

    @Test func decodesTheRepeatBlockStrictly() throws {
        let block = #","repeat":{"words":1000,"seed":3,"timing":"burst","prefix":["command+l"]}"#
        let json = scenarioJSON(id: "g", extra: block)
            .replacingOccurrences(of: #"{"text":"đi"}"#, with: #"{"text":"đi","noPlaceholderResidue":true}"#)
        let scenario = try ScenarioLoader.decode(Data(json.utf8), fileName: "g.json")
        #expect(
            scenario.repetition == Scenario.Repetition(words: 1_000, seed: 3, timing: .burst, prefix: ["command+l"]))
        #expect(scenario.expect.noPlaceholderResidue == true)
        #expect(scenario.declaresPlaceholderGate)
        let extra = json.replacingOccurrences(of: #""seed":3"#, with: #""seed":3,"corpus":"x""#)
        do {
            _ = try ScenarioLoader.decode(Data(extra.utf8), fileName: "g.json")
            Issue.record("expected a load error")
        } catch {
            #expect(error.problems == ["unknown key repeat.corpus"])
        }
    }

    /// The dry run shows the repeat load and counts its keystrokes in the total.
    @Test func dryRunDescribesTheRepetition() throws {
        var full = gate
        full.words = PlaceholderGate.minimumWords
        let scenario = repeatingScenario(full)
        let options = try HarnessCommandLine.parse(["run", "--dry-run"])
        let targets = HarnessTargets(
            testHostBundleID: nil, appUnderTestBundleID: nil, pagesDirectory: URL(fileURLWithPath: "/pages"))
        let lines = HarnessPlans.scenarioPlan([scenario], targets: targets, options: options)
        let keystrokes = ScenarioRepetitionPlan.words(for: full).reduce(0) { $0 + 1 + $1.keys.count }
        let line = try #require(lines.first { $0.hasPrefix("    repeat: ") })
        #expect(
            line.contains("1000 corpus word(s), seed 7, timing burst, prefix command+l, \(keystrokes) keystroke(s)"))
        #expect(line.hasSuffix("read back after every word, PLT-R422 placeholder gate"))
        #expect(lines.contains { $0.contains("expect: text \u{201C}đi\u{201D}, no placeholder residue") })
        #expect(lines.contains { $0.hasPrefix("Total: 1 scenario(s), \(keystrokes + 3) keystroke(s)") })
    }
}
