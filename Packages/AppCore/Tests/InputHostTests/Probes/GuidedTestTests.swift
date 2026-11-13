// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PLT-R1205 guided test against fakes only: candidate list, canary typing with each candidate on the simulated
// field, AX readback and removal with residue (PLT-R410), the human fallback, and the rule suggestion
// (`userOverrideRule` of the rules schema, host-level URL prefix only on opt-in, ADR 0312). Section 12
// acceptance: on an inline-completion field the test recommends `axSelection` or `placeholder`, and the
// resulting override fixes the symptom.

import AppModel
import ApplicationServices
import CompatRules
import Foundation
import Injection
import RealtimeSupport
import Testing

@testable import InputHost
@testable import TestSupport

struct GuidedBench {
    static let completionWords = ["dao.vn", "đang"]
    let field: SimulatedTextField
    let access: FakeFocusedFieldAccess
    let poster: FakeEventPoster
    let clock = ManualClock()
    let runner: GuidedTestRunner
    let handle = FieldHandle(pid: 42, token: 7, element: nil)

    init(
        _ behaviour: SimulatedTextField.Behaviour = .cocoa, text: String = "",
        ax: FakeFocusedFieldAccess.Behaviour = .normal
    ) {
        field = SimulatedTextField(behaviour: behaviour, text: text)
        access = FakeFocusedFieldAccess(field: field, behaviour: ax)
        let layout = InjectionTestLayouts.qwerty()
        poster = InjectionFieldWiring.poster(for: field, layout: layout)
        runner = GuidedTestRunner(
            poster: poster, fieldAccess: access, marker: ProbeFixture.marker, clock: clock, layout: layout)
    }

    static func completion() -> GuidedBench { GuidedBench(.inlineCompletion(suggestions: completionWords)) }

    func run(_ candidate: GuidedTestCandidate) async -> GuidedTestCandidateResult {
        await runner.run(candidate, field: handle)
    }
}

enum GuidedFixture {
    static let browser = BundleKey(rawValue: "com.example.Browser")!
    static let plain = GuidedTestCandidate(plan: .default)
    static let axSelection = GuidedTestCandidate(
        strategy: .backspaceReplace, inlineCompletion: .axSelection, interEventDelayUs: 0)

    static func target(
        engine: EngineFingerprint = .chromium, plan: InjectionPlan = .default, secure: Bool = false,
        handle: FieldHandle? = FieldHandle(pid: 42, token: 7, element: nil)
    ) -> MisbehavesTarget {
        MisbehavesTarget(
            app: FocusedApp(pid: 42, bundle: browser, appVersion: LooseVersion("131.0"), engine: engine),
            field: FieldContext(
                axAvailability: .available, role: "AXTextField", subrole: nil, identifier: nil, domClasses: [],
                editable: true, secure: secure),
            fieldHandle: handle, focusGeneration: FocusGeneration(rawValue: 9),
            rule: RuleID(rawValue: "browser.chromium"),
            source: .shipped, plan: plan)
    }

    /// Drives the flow like the App's panel: run the pending candidate until a question or the end.
    static func drive(_ flow: inout MisbehavesFlow, bench: GuidedBench) async {
        while let pending = flow.pendingCandidate {
            flow.record(await bench.run(pending.candidate))
        }
    }

    static func schemaErrors(_ rule: Rule) throws -> [JSONSchemaSubset.Violation] {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: url.appendingPathComponent("project.yml").path) {
            url.deleteLastPathComponent()
        }
        let data = try Data(contentsOf: url.appendingPathComponent("compat/schema/rules.schema.json"))
        guard case .object(var schema) = try JSONDecoder().decode(JSONValue.self, from: data) else { return [] }
        // Validate against `$defs/userOverrideRule` itself.
        schema = ["$defs": schema["$defs"] ?? .object([:]), "$ref": .string("#/$defs/userOverrideRule")]
        let instance = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(rule))
        return JSONSchemaSubset(schema: .object(schema)).validate(instance)
    }
}

@Suite("Guided test candidates (PLT-R1205)")
struct GuidedTestCandidateTests {
    @Test func defaultListRunsFromLeastToMostInvasive() {
        let list = GuidedTestRunner.candidates(isNativeApp: false)
        #expect(
            list.map(\.strategy) == [
                .backspaceReplace, .backspaceReplace, .backspaceReplace, .selectReplace, .backspaceReplace,
                .backspaceReplace,
            ])
        #expect(list.map(\.inlineCompletion) == [.none, .axSelection, .placeholder, .none, .none, .none])
        #expect(list.map(\.interEventDelayUs) == [0, 0, 0, 0, 2_000, 5_000])
    }

    @Test func axReplaceOnlyForNativeApps() {
        #expect(GuidedTestRunner.candidates(isNativeApp: true).contains { $0.strategy == .axReplace })
        #expect(!GuidedTestRunner.candidates(isNativeApp: false).contains { $0.strategy == .axReplace })
        #expect(GuidedTestRunner.isNativeApp(.native) && GuidedTestRunner.isNativeApp(.catalyst))
        #expect(!GuidedTestRunner.isNativeApp(.electron) && !GuidedTestRunner.isNativeApp(nil))
    }

    @Test func currentPlanComesFirstWithoutDuplicates() {
        var parameters = InjectionParameters.defaults
        parameters.inlineCompletion = .placeholder
        let current = InjectionPlan(strategy: .backspaceReplace, parameters: parameters, fallback: [])
        let list = GuidedTestRunner.candidates(current: current, isNativeApp: false)
        #expect(list.first == GuidedTestCandidate(plan: current))
        #expect(Set(list).count == list.count)
        #expect(list.filter { $0.inlineCompletion == .placeholder && $0.interEventDelayUs == 0 }.count == 1)
        #expect(list.suffix(2).allSatisfy { $0.inlineCompletion == .placeholder })  // paced current
    }

    @Test(arguments: [InjectionStrategy.passThrough, .paste])
    func untypableCurrentStrategiesFallBackToTheDefault(strategy: InjectionStrategy) {
        let current = InjectionPlan(strategy: strategy, parameters: .defaults, fallback: [])
        #expect(GuidedTestRunner.candidates(current: current, isNativeApp: false).first == GuidedFixture.plain)
    }

    @Test func pacedCurrentIsNotRepeatedBelowItsOwnPacing() {
        var parameters = InjectionParameters.defaults
        parameters.interEventDelayUs = 5_000
        let current = InjectionPlan(strategy: .selectReplace, parameters: parameters, fallback: [])
        let list = GuidedTestRunner.candidates(current: current, isNativeApp: false)
        #expect(list.filter { $0.strategy == .selectReplace }.map(\.interEventDelayUs) == [5_000, 0])
    }

    @Test func candidatePlanCarriesHandlingAndPacingWithoutFallback() {
        let candidate = GuidedTestCandidate(
            strategy: .selectReplace, inlineCompletion: .placeholder, interEventDelayUs: 2_000)
        #expect(candidate.plan.fallback.isEmpty)
        #expect(candidate.plan.parameters.inlineCompletion == .placeholder)
        #expect(candidate.plan.parameters.interEventDelayUs == 2_000)
        #expect(GuidedTestCandidate(plan: candidate.plan) == candidate)
    }

    @Test func bestIsTheFirstPassInListOrder() {
        let list = GuidedTestRunner.candidates(isNativeApp: false)
        let results: [GuidedTestCandidateResult?] = [
            .failedByReadback(residue: false), .humanSaidNo, .humanSaidYes, .passedByReadback, nil, nil,
        ]
        #expect(GuidedTestRunner.best(of: list, results: results) == list[2])
        #expect(GuidedTestRunner.best(of: list, results: [.fieldNotEmpty]) == nil)
    }
}

@Suite("Guided test runner (PLT-R1205, PLT-R410)")
struct GuidedTestRunnerTests {
    @Test func plainFieldPassesByReadbackAndIsClearedAgain() async {
        let bench = GuidedBench()
        #expect(await bench.run(GuidedFixture.plain) == .passedByReadback)
        #expect(bench.field.text.isEmpty)
    }

    @Test func everyEventCarriesTheProbeMarker() async {
        let bench = GuidedBench()
        _ = await bench.run(GuidedFixture.axSelection)
        #expect(!bench.poster.posted.isEmpty)
        for posted in bench.poster.posted {
            guard case .probe = ProbeFixture.marker.classify(posted.userData) else {
                Issue.record("guided-test event without the probe marker")
                continue
            }
        }
    }

    @Test func inlineCompletionDuplicatesWithTheDefaultStrategy() async {
        // The 4.3 symptom: the suggestion survives the backspace. Removal deletes what readback showed.
        let bench = GuidedBench.completion()
        #expect(await bench.run(GuidedFixture.plain) == .failedByReadback(residue: false))
        #expect(bench.field.text.isEmpty)
    }

    @Test func neverTypesIntoAFieldWithText() async {
        let bench = GuidedBench(text: "draft")
        #expect(await bench.run(GuidedFixture.plain) == .fieldNotEmpty)
        #expect(bench.poster.posted.isEmpty)
        #expect(bench.field.text == "draft")
    }

    @Test func unreadableFieldAsksTheHumanAndRemovesAfterTheAnswer() async {
        let bench = GuidedBench(ax: .unavailable)
        #expect(await bench.run(GuidedFixture.plain) == .needsHumanAnswer)
        #expect(bench.field.text == "đá â")  // left on screen for the question
        #expect(await bench.runner.removeTestText(GuidedFixture.plain, field: bench.handle) == nil)
        #expect(bench.field.text.isEmpty)
    }

    @Test func noFieldHandleMeansHumanReadback() async {
        let bench = GuidedBench()
        #expect(await bench.runner.run(GuidedFixture.plain, field: nil) == .needsHumanAnswer)
    }

    @Test func remoteClientThatIgnoresUnicodeFails() async {
        let bench = GuidedBench(.ignoresUnicodePayload)
        #expect(await bench.run(GuidedFixture.plain) == .failedByReadback(residue: false))
    }

    @Test func failedPostingFailsTheCandidate() async {
        let bench = GuidedBench()
        bench.poster.setMode(.failingCreation)
        #expect(await bench.run(GuidedFixture.plain) == .failedByReadback(residue: false))
    }

    @Test func textLeftAfterRemovalIsResidue() async {
        // The field reads empty, then shows the canary, then still shows it after the removal (PLT-R1206).
        let access = ScriptedFieldAccess(readings: ["", "đá â", "đá â"])
        let runner = GuidedTestRunner(
            poster: FakeEventPoster(), fieldAccess: access, marker: ProbeFixture.marker, clock: ManualClock())
        let handle = FieldHandle(pid: 1, token: 1, element: nil)
        #expect(await runner.run(GuidedFixture.plain, field: handle) == .failedByReadback(residue: true))
        #expect(await runner.removeTestText(GuidedFixture.plain, field: handle) == true)
    }

    @Test func pacingIsAppliedBetweenEvents() async {
        let bench = GuidedBench()
        let start = bench.clock.now()
        let paced = GuidedTestCandidate(strategy: .backspaceReplace, inlineCompletion: .none, interEventDelayUs: 5_000)
        #expect(await bench.run(paced) == .passedByReadback)
        #expect(bench.clock.now().nanoseconds(since: start) > 7 * 30_000_000)
    }

    @Test func textAfterTheCaretCountsAsContent() async {
        // PLT-R1205 step 3: a caret parked at the start of a non-empty field is not an empty field.
        let bench = GuidedBench(text: "draft")
        bench.field.axSetSelectedRange(Injection.TextRange(location: 0, length: 0))
        #expect(await bench.run(GuidedFixture.plain) == .fieldNotEmpty)
        #expect(bench.poster.posted.isEmpty && bench.field.text == "draft")
    }

    @Test func aStopBeforeTheRunTypesNothing() async {
        let bench = GuidedBench()
        let stop = ProbeStopSignal()
        stop.stop()
        #expect(await bench.runner.run(GuidedFixture.plain, field: bench.handle, stop: stop) == .stopped)
        #expect(bench.poster.posted.isEmpty)
        #expect(await bench.runner.removeTestText(GuidedFixture.plain, field: bench.handle, stop: stop) == nil)
        #expect(bench.poster.posted.isEmpty)
    }

    /// The focus check answers true `checks` times, then false; the poster count at that moment is kept.
    final class FocusFlip: Sendable {
        private let state: Mutex<(left: Int, postedAtFlip: Int?)>
        private let poster: FakeEventPoster
        init(after checks: Int, poster: FakeEventPoster) {
            state = Mutex((checks, nil))
            self.poster = poster
        }
        var postedAtFlip: Int? { state.withLock { $0.postedAtFlip } }
        func stillFocused() -> Bool {
            state.withLock { state in
                guard state.left > 0 else {
                    if state.postedAtFlip == nil { state.postedAtFlip = poster.posted.count }
                    return false
                }
                state.left -= 1
                return true
            }
        }
    }

    @Test(arguments: [3, 5, 8])
    func focusMovingMidCandidateStopsTypingAtOnce(checks: Int) async throws {
        // PLT-R1205 step 3, PLT-R387: one check before the run, one before each of the 7 steps and one before
        // the removal. After the flip not a single event (canary key or removal backspace) is posted.
        let bench = GuidedBench()
        let flip = FocusFlip(after: checks, poster: bench.poster)
        let stop = ProbeStopSignal { flip.stillFocused() }
        #expect(await bench.runner.run(GuidedFixture.plain, field: bench.handle, stop: stop) == .stopped)
        let atFlip = try #require(flip.postedAtFlip)
        #expect(bench.poster.posted.count == atFlip)
        #expect(stop.isStopped)
        #expect(!bench.field.text.isEmpty)  // the partial canary stays: no blind backspaces
    }

    @Test func focusLostBeforeTheRemovalPostsNoBackspace() async throws {
        let bench = GuidedBench()
        let flip = FocusFlip(after: 8, poster: bench.poster)  // the whole canary, then the removal check fails
        let stop = ProbeStopSignal { flip.stillFocused() }
        #expect(await bench.runner.run(GuidedFixture.plain, field: bench.handle, stop: stop) == .stopped)
        #expect(bench.poster.posted.count == (try #require(flip.postedAtFlip)))
        #expect(bench.field.text == "đá â")
    }

    @Test func removalAfterTheHumanAnswerNeedsTheFocus() async {
        let bench = GuidedBench(ax: .unavailable)
        #expect(await bench.run(GuidedFixture.plain) == .needsHumanAnswer)
        let before = bench.poster.posted.count
        let stop = ProbeStopSignal { false }
        #expect(await bench.runner.removeTestText(GuidedFixture.plain, field: bench.handle, stop: stop) == nil)
        #expect(bench.poster.posted.count == before)
        #expect(bench.field.text == "đá â")
    }

    @Test func aStopSetDuringAnEditEndsItBeforeTheNextEvent() async {
        // The flag is read before every event, so a stop from the main thread cuts an executor short.
        let stop = ProbeStopSignal()
        let poster = FakeEventPoster { _ in stop.stop() }
        let runner = GuidedTestRunner(
            poster: poster, fieldAccess: ScriptedFieldAccess(readings: [""]), marker: ProbeFixture.marker,
            clock: ManualClock())
        let result = await runner.run(
            GuidedFixture.plain, field: FieldHandle(pid: 1, token: 1, element: nil), stop: stop)
        #expect(result == .stopped)
        #expect(poster.posted.count == 1)
    }

    @Test func keyCodesComeFromTheLayoutOrTheUSPositions() {
        let layout = InjectionTestLayouts.qwerty()
        #expect(GuidedTestKeys(layout: layout).code("s") == InjectionTestLayouts.keyCode(for: "s"))
        #expect(GuidedTestKeys(layout: nil).code(" ") == KeyCode(rawValue: 0x31))
        #expect(GuidedTestKeys(layout: nil).code("x") == KeyCode(rawValue: 0))
    }
}

@Suite("Guided test focus check (PLT-R1205 step 3, PLT-R387)")
struct GuidedTestFocusTests {
    static let attributes = FocusAttributes(
        role: "AXTextField", subrole: nil, identifier: nil, domClasses: [], editable: true, ancestorRoles: [],
        documentURL: nil, windowTitle: nil)

    @Test func theTargetAppMustKeepTheFocus() {
        let ax = FakeAXProvider()
        ax.focusWithoutElement(pid: 42, notify: nil)
        let check = GuidedTestFocus.check(ax: ax, pid: 42, field: FieldHandle(pid: 42, token: 7, element: nil))
        #expect(check())
        ax.focusWithoutElement(pid: 43, notify: nil)  // the user switched apps
        #expect(!check())
    }

    @Test func theConfirmedElementMustKeepTheFocus() {
        // The fake's focused element of pid N is N's application element, so a handle for another element fails.
        let ax = FakeAXProvider()
        ax.focus(pid: 42, attributes: Self.attributes, notify: nil)
        let same = FieldHandle(pid: 42, token: 7, element: AXElementReference(AXUIElementCreateApplication(42)))
        let other = FieldHandle(pid: 42, token: 8, element: AXElementReference(AXUIElementCreateApplication(99)))
        #expect(GuidedTestFocus.check(ax: ax, pid: 42, field: same)())
        #expect(!GuidedTestFocus.check(ax: ax, pid: 42, field: other)())
        ax.focusWithoutElement(pid: 42, notify: nil)  // focus left every element of the app
        #expect(!GuidedTestFocus.check(ax: ax, pid: 42, field: same)())
    }

    @Test func doubtCountsAsMovedFocus() {
        let ax = FakeAXProvider()
        ax.focus(pid: 42, attributes: Self.attributes, notify: nil)
        ax.setTimingOut(pid: 42, true)
        let handle = FieldHandle(pid: 42, token: 7, element: AXElementReference(AXUIElementCreateApplication(42)))
        #expect(!GuidedTestFocus.check(ax: ax, pid: 42, field: handle)())
    }

    @Test func aSwitchMidCandidateStopsTheRunnerThroughTheSignal() async {
        let bench = GuidedBench()
        let ax = FakeAXProvider()
        ax.focusWithoutElement(pid: 42, notify: nil)
        let poster = bench.poster
        let posts = Mutex(0)
        let check = GuidedTestFocus.check(ax: ax, pid: 42, field: bench.handle)
        let stop = ProbeStopSignal {
            // After the third step the user clicks into another app.
            posts.withLock { count in
                count += 1
                if count == 4 { ax.focusWithoutElement(pid: 43, notify: nil) }
            }
            return check()
        }
        #expect(await bench.runner.run(GuidedFixture.plain, field: bench.handle, stop: stop) == .stopped)
        let typed = poster.posted.count
        #expect(typed > 0 && bench.field.text == "đ")  // "d", then the edit to "đ"; nothing after the switch
    }
}

@Suite("Guided test acceptance (02-platform.md section 12)")
struct GuidedTestAcceptanceTests {
    @Test func inlineCompletionFieldGetsAxSelectionOrPlaceholderAndTheOverrideFixesIt() async throws {
        let bench = GuidedBench.completion()
        var flow = MisbehavesFlow(target: GuidedFixture.target())
        flow.symptom = .duplicatedLetters
        flow.requestGuidedTest()
        flow.confirmFieldIsEmptyAndSafe()
        await GuidedFixture.drive(&flow, bench: bench)
        #expect(flow.step == .finished)
        let best = try #require(flow.best)
        #expect(best.inlineCompletion == .axSelection || best.inlineCompletion == .placeholder)
        #expect(flow.results.first == .failedByReadback(residue: false))  // the symptom with the current plan

        // "Use this for me now": the suggestion becomes a user override; the next keystroke resolves it.
        let rule = try #require(flow.suggestion(macOS: "27.1", date: "2026-11-13"))
        #expect(try GuidedFixture.schemaErrors(rule).isEmpty)
        // Stored in rule-overrides.json and read back through the loader that validates user overrides.
        let raw = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(rule))
        let decoded = RulesLoader.decodeOverrides([raw])
        #expect(decoded.rejected.isEmpty && decoded.rules == [rule])
        let rules = try RuleSet(document: EmbeddedRules.minimal, overrides: decoded.rules, optedIn: [])
        let decision = rules.resolve(flow.target.matchContext(macOS: "27.1"))
        #expect(decision.source == .user && decision.rule == rule.id)
        let plan = HostDecisionMapping.map(decision, engine: .chromium, optedIntoPaste: false).plan
        let fresh = GuidedBench.completion()
        #expect(await fresh.run(GuidedTestCandidate(plan: plan)) == .passedByReadback)
        #expect(fresh.field.text.isEmpty)
    }

    @Test func humanAnswersDriveTheFlowWhenAXIsUnavailable() async throws {
        let bench = GuidedBench(ax: .unavailable)
        var flow = MisbehavesFlow(target: GuidedFixture.target())
        flow.requestGuidedTest()
        flow.confirmFieldIsEmptyAndSafe()
        await GuidedFixture.drive(&flow, bench: bench)
        #expect(flow.step == .askHuman(0))
        let asked = try #require(flow.questionCandidate)
        flow.answer(seesCanary: false)
        _ = await bench.runner.removeTestText(asked, field: bench.handle)
        #expect(flow.step == .testing(1))
        await GuidedFixture.drive(&flow, bench: bench)
        flow.answer(seesCanary: true)
        #expect(flow.step == .finished)
        #expect(flow.best == flow.candidates[1])
        #expect(flow.results.prefix(2) == [.humanSaidNo, .humanSaidYes])
    }
}

/// AX surface that answers successive reads from a script (each `selectedRange` call starts a new reading).
final class ScriptedFieldAccess: FocusedFieldAccess, Sendable {
    private let readings: [String]
    private let index = Mutex(-1)

    init(readings: [String]) { self.readings = readings }

    private var current: String { readings[min(max(index.withLock { $0 }, 0), readings.count - 1)] }

    func selectedRange(_ field: FieldHandle, timeout: TimeSpan) -> AXCallResult<Injection.TextRange> {
        index.withLock { $0 += 1 }
        return .success(Injection.TextRange(location: current.utf16.count, length: 0))
    }

    func text(_ field: FieldHandle, in range: Injection.TextRange, timeout: TimeSpan) -> AXCallResult<String> {
        let text = current
        return .success(range.location >= text.utf16.count ? "" : text)  // nothing after the caret
    }

    func setSelectedRange(_ field: FieldHandle, to range: Injection.TextRange, timeout: TimeSpan) -> AXCallResult<Void>
    {
        .success(())
    }

    func setSelectedText(_ field: FieldHandle, to text: String, timeout: TimeSpan) -> AXCallResult<Void> {
        .success(())
    }
}
