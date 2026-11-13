// SPDX-License-Identifier: GPL-3.0-or-later
//
// `backspaceReplace` (4.2), `selectReplace` (4.4) and inline-completion handling (4.3) on `SimulatedTextField`.

import AppModel
import InputHost
import RealtimeSupport
import TestSupport
import Testing

@testable import Injection

private struct Bench {
    let clock = ManualClock()
    let layout = InjectionTestLayouts.qwerty()
    let field: SimulatedTextField
    let poster: FakeEventPoster
    let access: FakeFocusedFieldAccess
    let environment: FakeInjectionEnvironment

    init(field: SimulatedTextField, axBehaviour: FakeFocusedFieldAccess.Behaviour = .normal) {
        self.field = field
        poster = InjectionFieldWiring.poster(for: field, layout: layout)
        access = FakeFocusedFieldAccess(field: field, behaviour: axBehaviour)
        environment = FakeInjectionEnvironment(
            poster: poster, clock: clock, fieldAccess: access, pasteboard: FakePasteboard())
    }

    func run(_ strategy: InjectionStrategy, _ job: EditJob) -> StrategyOutcome {
        StrategyCatalog.executor(for: strategy).execute(job, in: environment)
    }
}

@Suite struct BackspaceReplaceTests {
    /// 4.10 acceptance: "nguyen" + `s` produces exactly 2 backspaces and 2 inserted characters (PLT-R402).
    @Test func nguyenPlusSIsTwoBackspacesAndTwoCharactersPLTR402() {
        let bench = Bench(field: SimulatedTextField(text: "nguyen"))
        let minimized = EditMinimizer.minimize(deleteCount: 6, replaced: "nguyen", insertion: "nguyến")
        let job = Fixture.job(deleteCount: minimized.deleteCount, insertion: minimized.insertion)
        let outcome = bench.run(.backspaceReplace, job)
        guard case .completed = outcome else {
            Issue.record("unexpected \(outcome)")
            return
        }
        #expect(bench.poster.posted.backspaceCount == 2)
        #expect(bench.poster.posted.keyDowns.filter { $0.keyCode != .delete }.count == 2)
        #expect(bench.field.text == "nguyến")
    }

    @Test func eventsArePairsWithExplicitFlagsAndTheTriggerKeycodePLTR405R407() {
        let bench = Bench(field: SimulatedTextField(text: "a"))
        _ = bench.run(.backspaceReplace, Fixture.job(deleteCount: 1, insertion: "á"))
        let events = bench.poster.posted.compactMap(\.synthetic)
        #expect(events.count == 4)
        #expect(events.map(\.isKeyDown) == [true, false, true, false])
        #expect(events.allSatisfy { $0.flags == 0 })
        #expect(events[0].keyCode == .delete && events[0].unicode.count == 0)
        #expect(events[2].keyCode == Fixture.triggerS.keyCode)
        #expect(events[2].unicode.string == "á" && events[3].unicode.string == "á")
        #expect(bench.field.text == "á")
    }

    @Test func macrosAndRestoresUseTheFirstCharacterKeycodePLTR405() {
        let bench = Bench(field: SimulatedTextField())
        let keyCodes = JobKeyCodes(trigger: KeyCode(rawValue: 0x01), firstCharacter: KeyCode(rawValue: 0x11))
        _ = bench.run(
            .backspaceReplace, Fixture.job(deleteCount: 0, insertion: "tôi", kind: .macro, keyCodes: keyCodes))
        #expect(bench.poster.posted.keyDowns.allSatisfy { $0.keyCode == KeyCode(rawValue: 0x11) })
        let restore = Bench(field: SimulatedTextField())
        _ = restore.run(.backspaceReplace, Fixture.job(deleteCount: 0, insertion: "x", kind: .restore))
        #expect(restore.poster.posted.keyDowns.first?.keyCode == Fixture.triggerS.keyCode)
    }

    @Test func pacingUsesAbsoluteDeadlinesAndCapsPLTR408R409() {
        let bench = Bench(field: SimulatedTextField(text: "ab"))
        let parameters = Fixture.parameters {
            $0.interEventDelayUs = 1_000
            $0.postDeleteSettleUs = 70_000  // capped to 50,000
            $0.firstEditDelayUs = 2_000
        }
        let job = Fixture.job(
            deleteCount: 2, insertion: "âb", plan: Fixture.plan(parameters: parameters), nearFocusChange: true)
        _ = bench.run(.backspaceReplace, job)
        let start = Fixture.start.nanoseconds
        let expected: [UInt64] = [2_000_000, 3_000_000, 54_000_000, 55_000_000].map { start + $0 }
        #expect(bench.environment.sleepDeadlines.map(\.nanoseconds) == expected)
        #expect(bench.field.text == "âb")
    }

    @Test func tooLongJobFailsBeforePostingWithoutSplitPLTR408() {
        let bench = Bench(field: SimulatedTextField(text: "abcd"))
        let parameters = Fixture.parameters { $0.interEventDelayUs = 50_000 }
        let job = Fixture.job(deleteCount: 4, insertion: "xyzw", plan: Fixture.plan(parameters: parameters))
        #expect(bench.run(.backspaceReplace, job) == .failedBeforePosting(.jobTooLong))
        #expect(bench.poster.posted.isEmpty)
    }

    @Test func splitReleasesHeldEventsBetweenPartsPLTR408() {
        let bench = Bench(field: SimulatedTextField(text: "abcd"))
        let parameters = Fixture.parameters {
            $0.interEventDelayUs = 50_000
            $0.allowSplit = true
        }
        let job = Fixture.job(deleteCount: 4, insertion: "xyzw", plan: Fixture.plan(parameters: parameters))
        guard case .completed = bench.run(.backspaceReplace, job) else {
            Issue.record("split job did not complete")
            return
        }
        // 7 gaps of 50 ms in parts of at most 150 ms: two releases.
        #expect(bench.environment.releaseCount == 2)
        #expect(bench.field.text == "xyzw")
    }

    @Test func postingFailureIsReportedBeforeOrAfterOutput() {
        let bench = Bench(field: SimulatedTextField(text: "a"))
        bench.poster.setMode(.failingCreation)
        #expect(
            bench.run(.backspaceReplace, Fixture.job(deleteCount: 1, insertion: "á"))
                == .failedBeforePosting(.postingFailed))
    }

    @Test func multiCharacterChunksForLongTextPLTR480() {
        let bench = Bench(field: SimulatedTextField())
        let text = String(repeating: "ư", count: 70)
        let allowed = Fixture.parameters { $0.allowMultiCharEvents = true }
        _ = bench.run(
            .backspaceReplace, Fixture.job(deleteCount: 0, insertion: text, plan: Fixture.plan(parameters: allowed)))
        #expect(bench.poster.posted.keyDowns.map(\.unicode.count) == [20, 20, 20, 10])
        #expect(bench.field.text == text)
        let chunked = Bench(field: SimulatedTextField())
        let rule = Fixture.parameters { $0.unicodeChunk = 4 }
        _ = chunked.run(
            .backspaceReplace, Fixture.job(deleteCount: 0, insertion: "abcdef", plan: Fixture.plan(parameters: rule)))
        #expect(chunked.poster.posted.keyDowns.map(\.unicode.string) == ["abcd", "ef"])
    }
}

@Suite struct InlineCompletionTests {
    private func completionPlan(_ mode: InlineCompletionMode, _ strategy: InjectionStrategy = .backspaceReplace)
        -> InjectionPlan
    {
        Fixture.plan(strategy, parameters: Fixture.parameters { $0.inlineCompletion = mode })
    }

    /// Types `a` into a completion field: the field shows "a" plus the selected suggestion remainder.
    private func completionBench(_ axBehaviour: FakeFocusedFieldAccess.Behaviour = .normal) -> Bench {
        let bench = Bench(
            field: SimulatedTextField(behaviour: .inlineCompletion(suggestions: ["amazon"])), axBehaviour: axBehaviour)
        bench.field.apply(InjectionFieldWiring.keyDown("a", receivedAt: Fixture.start), layout: bench.layout)
        return bench
    }

    @Test func withoutHandlingTheSuggestionDuplicatesTheLetter() {
        let bench = completionBench()
        #expect(bench.field.text == "amazon" && bench.field.selectedText == "mazon")
        _ = bench.run(.backspaceReplace, Fixture.job(deleteCount: 1, insertion: "á"))
        #expect(bench.field.text == "aá")  // the bug 4.3 describes
    }

    @Test func axSelectionDeletesTheSuggestionFirstPLTR420() {
        let bench = completionBench()
        _ = bench.run(
            .backspaceReplace, Fixture.job(deleteCount: 1, insertion: "á", plan: completionPlan(.axSelection)))
        #expect(bench.field.text == "á")
        #expect(bench.poster.posted.backspaceCount == 2)
    }

    @Test func axSelectionWithoutASuggestionAddsNothing() {
        let bench = Bench(field: SimulatedTextField(text: "a"))
        _ = bench.run(
            .backspaceReplace, Fixture.job(deleteCount: 1, insertion: "á", plan: completionPlan(.axSelection)))
        #expect(bench.poster.posted.backspaceCount == 1)
        #expect(bench.field.text == "á")
    }

    @Test func axTimeoutFallsBackToThePlaceholderPLTR420() {
        let bench = completionBench(.timeout)
        _ = bench.run(
            .backspaceReplace,
            Fixture.job(deleteCount: 1, insertion: "á", plan: completionPlan(.axSelectionThenPlaceholder)))
        #expect(bench.field.text == "á")
        #expect(bench.poster.posted.keyDowns.first?.unicode.string == "\u{200B}")
    }

    @Test func axUnavailableWithoutPlaceholderUsesNothing() {
        let bench = completionBench(.unavailable)
        _ = bench.run(
            .backspaceReplace, Fixture.job(deleteCount: 1, insertion: "á", plan: completionPlan(.axSelection)))
        #expect(bench.poster.posted.backspaceCount == 1)
    }

    @Test func placeholderNeedsNoAXPLTR421() {
        let bench = completionBench(.unavailable)
        _ = bench.run(
            .backspaceReplace, Fixture.job(deleteCount: 1, insertion: "á", plan: completionPlan(.placeholder)))
        #expect(bench.field.text == "á")
        #expect(bench.access.callCount == 0)
    }

    @Test func selectReplaceHandlesSuggestionsToo() {
        let ax = completionBench()
        _ = ax.run(
            .selectReplace,
            Fixture.job(deleteCount: 1, insertion: "á", plan: completionPlan(.axSelection, .selectReplace)))
        #expect(ax.field.text == "á")
        let placeholder = completionBench()
        _ = placeholder.run(
            .selectReplace,
            Fixture.job(deleteCount: 1, insertion: "á", plan: completionPlan(.placeholder, .selectReplace)))
        #expect(placeholder.field.text == "á")
    }

    /// PLT-R422: zero leftover placeholders over at least 1,000 randomised edits on the simulated field.
    @Test func placeholderLeavesNoResidueOver1000RandomisedEditsPLTR422() {
        var generator = SplitMix64(seed: 0x5EED_1000)
        let words = ["amazon", "anh", "dien", "duong", "viet", "nguyen", "thuong", "google", "dang"]
        let field = SimulatedTextField(behaviour: .inlineCompletion(suggestions: words))
        let bench = Bench(field: field)
        let letters = Array("adegnhiotuvy")
        let plan = completionPlan(.placeholder)
        for _ in 0..<1_000 {
            field.reset(text: "")
            var expected = ""
            for _ in 0..<Int.random(in: 1...3, using: &generator) {
                let letter = letters[Int.random(in: 0..<letters.count, using: &generator)]
                field.apply(InjectionFieldWiring.keyDown(letter, receivedAt: Fixture.start), layout: bench.layout)
                expected.append(letter)
            }
            // Burst edit: replace the last 1...n graphemes with a random Vietnamese replacement.
            let deleteCount = Int.random(in: 1...expected.count, using: &generator)
            let replacement = ["á", "ư", "ộ", "đ", "ể", "ằn"][Int.random(in: 0..<6, using: &generator)]
            _ = bench.run(.backspaceReplace, Fixture.job(deleteCount: deleteCount, insertion: replacement, plan: plan))
            expected = String(expected.dropLast(deleteCount)) + replacement
            #expect(!field.text.unicodeScalars.contains("\u{200B}"))
            #expect(field.text.hasPrefix(expected))
        }
    }
}

@Suite struct SelectReplaceTests {
    @Test func shiftLeftThenInsertionPLTR406() {
        let bench = Bench(field: SimulatedTextField(text: "nguyen"))
        _ = bench.run(.selectReplace, Fixture.job(deleteCount: 2, insertion: "ến"))
        let downs = bench.poster.posted.keyDowns
        #expect(downs.prefix(2).allSatisfy { $0.keyCode == .leftArrow && $0.flags == SyntheticKeys.shiftFlag })
        #expect(downs.dropFirst(2).allSatisfy { $0.flags == 0 })
        #expect(bench.field.text == "nguyến")
    }

    @Test func pureDeletionRemovesTheSelection() {
        let bench = Bench(field: SimulatedTextField(text: "ab"))
        _ = bench.run(.selectReplace, Fixture.job(deleteCount: 1, insertion: ""))
        #expect(bench.field.text == "a")
    }

    @Test func passThroughExecutorPostsNothing() {
        let bench = Bench(field: SimulatedTextField(text: "a"))
        #expect(
            bench.run(.passThrough, Fixture.job(deleteCount: 1, insertion: "á")) == .failedBeforePosting(.postingFailed)
        )
        #expect(bench.poster.posted.isEmpty)
        #expect(StrategyCatalog.executor(for: .paste).strategy == .paste)
    }
}

/// Deterministic generator so randomised tests are reproducible.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
