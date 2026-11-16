// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R423 caret continuity (amendment of 16/11/2026, second retest of beta 2): the tap breaks the caret's continuity
// (`JobQueue.breakCaretContinuity`) on every event after which the worker may no longer keep an earlier completion
// read's "caret at the end" when a later read does not answer: every hard boundary (PLT-R340), every keyDown that does
// not type or delete one character at the caret, in every host state (English mode included), and the first keyDown
// after a typing pause (PLT-R382). Every edit job carries the epoch it was built in. The last suite runs the real
// worker behind the pipeline on a Spotlight-like field.

import AppModel
import Diagnostics
import Injection
import RealtimeSupport
import TestSupport
import Testing
import VietnameseEngine

@testable import InputHost

/// Events that can move the caret or select text, as the tap receives them.
enum CaretMover: String, CaseIterable, Sendable {
    case leftMouseDown, rightMouseDown, otherMouseDown
    case leftArrow, shiftLeftArrow, home, end, pageDown, forwardDelete
    case optionBackspace, commandBackspace, commandA, commandV, controlA
    case returnKey, keypadEnter, tab, escape, f5, deadKey, tapDisabled

    func perform(on fixture: PipelineFixture) {
        switch self {
        case .leftMouseDown: fixture.send(PipelineFixtures.keyEvent(.leftMouseDown, 0))
        case .rightMouseDown: fixture.send(PipelineFixtures.keyEvent(.rightMouseDown, 0))
        case .otherMouseDown: fixture.send(PipelineFixtures.keyEvent(.otherMouseDown, 0))
        case .leftArrow: fixture.press(Key.left)
        case .shiftLeftArrow: fixture.press(Key.left, flags: Flag.shift)
        case .home: fixture.press(0x73)
        case .end: fixture.press(0x77)
        case .pageDown: fixture.press(0x79)
        case .forwardDelete: fixture.press(Key.forwardDelete)
        case .optionBackspace: fixture.press(Key.backspace, flags: Flag.option)
        case .commandBackspace: fixture.press(Key.backspace, flags: Flag.command)
        case .commandA: fixture.press(Key.a, flags: Flag.command)
        case .commandV: fixture.press(0x09, flags: Flag.command)
        case .controlA: fixture.press(Key.a, flags: Flag.control)
        case .returnKey: fixture.press(Key.returnKey)
        case .keypadEnter: fixture.press(Key.keypadEnter)
        case .tab: fixture.press(Key.tab)
        case .escape: fixture.press(Key.escape)
        case .f5: fixture.press(Key.f5)
        case .deadKey: fixture.press(Key.azertyDeadKey)
        case .tapDisabled: fixture.send(PipelineFixtures.keyEvent(.tapDisabledByTimeout, 0))
        }
    }
}

/// A fixture past its first keyDown, which counts as idle (PLT-R382) and so breaks the continuity itself.
private func typingFixture(
    focus: FocusSnapshot = PipelineFixtures.focus(), inputSource: InputSourceSnapshot = PipelineFixtures.inputSource()
) -> PipelineFixture {
    let fixture = PipelineFixture(focus: focus, inputSource: inputSource)
    fixture.press(Key.d)
    fixture.completeJobs()
    return fixture
}

@Suite struct KeyPipelineCaretContinuityTests {
    /// Letters (with Shift too), a space, punctuation and a plain Backspace type or delete one character at the caret:
    /// a caret at the end of the text stays there. Key releases and modifier changes move nothing.
    @Test func typingAndAPlainBackspaceKeepTheContinuityPLTR423() {
        let fixture = typingFixture()
        let epoch = fixture.queue.caretEpoch
        fixture.typeKeys([Key.a, Key.s, Key.space, Key.comma, Key.backspace, Key.e, Key.w])
        fixture.press(Key.a, flags: Flag.shift)
        fixture.flags(Key.shift, Flag.shift)
        fixture.flags(Key.shift, 0)
        fixture.completeJobs()
        #expect(fixture.queue.caretEpoch == epoch)
    }

    /// PLT-R340, PLT-R317, PLT-R389: a click, a navigation key, Forward Delete, a word or line deletion, a selection, a
    /// paste or any Command or Control chord, Return, Tab, Escape, a function key, a dead key and a tap timeout (keys
    /// may pass unseen until the re-enable) each break the continuity.
    @Test(arguments: CaretMover.allCases)
    func everyCaretMovingEventBreaksTheContinuityPLTR423(mover: CaretMover) {
        let table = mover == .deadKey ? PipelineFixtures.azertyTable() : PipelineFixtures.qwertyTable()
        let fixture = typingFixture(inputSource: PipelineFixtures.inputSource(table: table))
        let epoch = fixture.queue.caretEpoch
        mover.perform(on: fixture)
        #expect(fixture.queue.caretEpoch > epoch, "\(mover.rawValue)")
    }

    /// In English mode (and every other state in which keys bypass the engine) no hard boundary is signalled for a
    /// navigation key, yet the caret moves all the same: the keyDown itself breaks the continuity.
    @Test(arguments: [CaretMover.leftArrow, .commandA, .end, .leftMouseDown])
    func caretMovesBreakTheContinuityInEnglishModeToo(mover: CaretMover) {
        let fixture = typingFixture(focus: PipelineFixtures.focus(mode: .english))
        let epoch = fixture.queue.caretEpoch
        fixture.typeKeys([Key.a, Key.s])
        #expect(fixture.queue.caretEpoch == epoch)
        mover.perform(on: fixture)
        #expect(fixture.queue.caretEpoch > epoch, "\(mover.rawValue)")
    }

    /// PLT-R382: the first keyDown after 500 ms without keyboard input breaks the continuity; the remembered answer
    /// bridges continuous typing only.
    @Test func aTypingPauseBreaksTheContinuityPLTR382() {
        let fixture = typingFixture()
        let epoch = fixture.queue.caretEpoch
        fixture.clock.advance(byMicroseconds: 499_000)
        fixture.press(Key.a)
        #expect(fixture.queue.caretEpoch == epoch)
        fixture.clock.advance(byMicroseconds: 500_000)
        fixture.press(Key.s)
        #expect(fixture.queue.caretEpoch > epoch)
    }

    /// A focus change to another app is a hard boundary (PLT-R340): the next key breaks the continuity, besides the
    /// new generation. (A late focus change within the same process may keep the composition without a boundary,
    /// PLT-R340 amendment; its new generation alone keeps the worker from reusing an answer, `CaretContinuityTests`.)
    @Test func aFocusChangeBreaksTheContinuityPLTR340() {
        let fixture = typingFixture()
        let epoch = fixture.queue.caretEpoch
        fixture.publish(focus: PipelineFixtures.focus(generation: 2, pid: 101))
        fixture.press(Key.a)
        #expect(fixture.queue.caretEpoch > epoch)
    }

    /// Every edit job carries the epoch it was built in, so the worker can tell an answer read for a job built before
    /// a break from one built after it.
    @Test func editJobsCarryTheEpochTheyWereBuiltInPLTR423() throws {
        let fixture = typingFixture()
        fixture.press(Key.a)
        fixture.keyDown(Key.a)
        let first = try #require(fixture.completeJobs().compactMap(\.edit).first)
        #expect(first.caretEpoch == fixture.queue.caretEpoch)
        fixture.keyUp(Key.a)
        fixture.press(Key.left)
        fixture.press(Key.a)
        fixture.keyDown(Key.a)
        let second = try #require(fixture.completeJobs().compactMap(\.edit).first)
        #expect(second.caretEpoch == fixture.queue.caretEpoch)
        #expect(second.caretEpoch > first.caretEpoch)
    }
}

/// The real worker behind the pipeline, sharing its queue as in the app, on a field that shows a suggestion after the
/// caret (Spotlight on macOS 27.2) and answers the completion read late.
private final class SpotlightRig {
    let fixture: PipelineFixture
    let field = SimulatedTextField(
        behaviour: .suggestionAfterCaret(suggestions: ["ab.example", "âm.example", "ấp.example"]))
    let access: FakeFocusedFieldAccess
    let poster: FakeEventPoster
    let worker: InjectionWorker
    let health = HealthEventLog()
    private let layout = PipelineFixtures.qwertyTable()

    init() {
        var decision = PipelineFixtures.decision()
        decision.plan.parameters.inlineCompletion = .forwardDelete
        fixture = PipelineFixture(focus: PipelineFixtures.focus(decision: decision), policy: .untilPosted)
        access = FakeFocusedFieldAccess(field: field)
        poster = InjectionFieldWiring.poster(for: field, layout: layout)
        worker = InjectionWorker(
            queue: fixture.queue, signal: WorkerSignal(), feedback: fixture.feedback, marker: fixture.marker,
            focusGeneration: fixture.focusGeneration,
            services: InjectionServices(
                poster: poster, fieldAccess: access, pasteboard: FakePasteboard(), clock: fixture.clock,
                metrics: fixture.metrics, health: health, logger: RecordingLogger(), capture: nil))
    }

    /// One keyDown and keyUp; a key the tap passes reaches the field as it reaches the app.
    func press(_ keyCode: UInt16, _ character: Character) {
        if fixture.keyDown(keyCode) == .pass {
            field.apply(InjectionFieldWiring.keyDown(character, receivedAt: fixture.clock.now()), layout: layout)
        }
        fixture.keyUp(keyCode)
    }

    var forwardDeletes: Int {
        poster.posted.filter {
            if case .synthetic(let event, _) = $0 { return event.isKeyDown && event.keyCode == .forwardDelete }
            return false
        }.count
    }
}

@Suite struct CaretContinuityWorkerPipelineTests {
    /// `aa` then `s`: the first read answers in 3 ms, the second only after the 50 ms bound. Nothing moved the caret in
    /// between, so the second edit still clears the suggestion first and the word comes out right.
    @Test func aLateReadKeepsTheForwardDeleteAcrossThePipelinePLTR423() {
        let rig = SpotlightRig()
        rig.press(Key.a, "a")
        rig.access.setReadLatency(.milliseconds(3), clock: rig.fixture.clock)
        rig.press(Key.a, "a")
        rig.worker.runUntilIdle()
        #expect(rig.field.text == "â")
        #expect(rig.field.suggestionShown == "m.example")
        rig.access.setReadLatency(.milliseconds(60), clock: rig.fixture.clock)
        rig.press(Key.s, "s")
        rig.worker.runUntilIdle()
        #expect(rig.field.text == "ấ")
        #expect(rig.forwardDeletes == 2)
        #expect(rig.health.recent(limit: 16).isEmpty)
    }

    /// The same keys with a click that reaches the app while the second edit waits in the queue (PLT-R317): the tap
    /// breaks the continuity at the click, so the edit whose read does not answer adds no Forward Delete (PLT-R407).
    /// The suggestion then takes the Backspace (the old symptom), and no character after the caret is deleted.
    @Test func aClickWhileTheEditWaitsStopsTheKeptForwardDeletePLTR407() {
        let rig = SpotlightRig()
        rig.press(Key.a, "a")
        rig.access.setReadLatency(.milliseconds(3), clock: rig.fixture.clock)
        rig.press(Key.a, "a")
        rig.worker.runUntilIdle()
        rig.access.setReadLatency(.milliseconds(60), clock: rig.fixture.clock)
        rig.press(Key.s, "s")
        rig.fixture.send(PipelineFixtures.keyEvent(.leftMouseDown, 0))
        rig.worker.runUntilIdle()
        #expect(rig.forwardDeletes == 1)
        #expect(rig.field.text == "âấ")
        #expect(rig.health.recent(limit: 16).map(\.kind) == [.fallbackActivated])
    }
}
