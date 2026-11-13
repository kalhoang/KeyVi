// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The pipeline against host state: P0-1 secure input (PLT-R398A, PLT-R398B), per-app mode and the toggle race
// (PLT-R391, PRD-R19, contracts.md 10.4), live settings (PLT-R1008, PRD-R27), focus and source boundaries
// (PLT-R210, PLT-R340, PLT-R371) and idle revalidation (PLT-R382).

import AppModel
import Dispatch
import Foundation
import Injection
import RealtimeSupport
import TestSupport
import Testing
import VietnameseEngine

@testable import InputHost

@Suite struct SecureInputP0Tests {
    private func secure(_ generation: UInt64, _ enabled: Bool) -> SecureInputSnapshot {
        SecureInputSnapshot(generation: generation, enabled: enabled, holder: nil)
    }

    /// P0-1: secure input on -> paused, nothing reaches the engine (events other than a keyDown cannot be key
    /// evidence).
    @Test func secureInputOnPausesWithoutFeedingTheEngineP0() {
        let fixture = PipelineFixture()
        fixture.publish(secureInput: secure(1, true))
        #expect(fixture.flags(Key.shift, Flag.shift) == .pass)
        #expect(fixture.flags(Key.shift, 0) == .pass)
        #expect(fixture.keyUp(Key.a) == .pass)
        #expect(fixture.log.feeds.isEmpty)
        let state = HostStateResolver.resolve(
            lifecycle: PipelineFixtures.lifecycle(), secureInput: secure(1, true), secureResumedGeneration: nil,
            inputSource: PipelineFixtures.inputSource(), focus: PipelineFixtures.focus(), effectiveMode: .vietnamese)
        #expect(state == .paused(.secureInput(nil)))
    }

    /// PLT-R398B (P0-1): the first keyDown that reaches the tap is composed, no key passes untransformed in
    /// between, and main learns at once instead of at the next poll.
    @Test func firstKeyDownAfterReleaseIsComposedP0() throws {
        let fixture = PipelineFixture()
        fixture.press(Key.d)  // dirty composition before secure input
        fixture.publish(secureInput: secure(1, true))
        fixture.flags(Key.shift, Flag.shift)
        fixture.flags(Key.shift, 0)
        #expect(fixture.keyDown(Key.a) == .pass)  // composed: the engine sees it (and passes it)
        fixture.keyUp(Key.a)
        #expect(fixture.keyDown(Key.a) == .swallow)  // "aa" -> "â": composition started at the first key
        let edit = try #require(fixture.popJobs().first?.edit)
        #expect(edit.insertion == "â")
        #expect(edit.deleteCount == 1)
        #expect(fixture.log.feeds == [.key(KeyInput("d")), .key(KeyInput("a")), .key(KeyInput("a"))])
        #expect(fixture.log.resets.contains(.secureInputChanged))  // fresh composition at the transition
        let resumed = fixture.mainNotices().contains {
            if case .secureInputResumedByKey(let generation) = $0 { return generation == 1 }
            return false
        }
        #expect(resumed)
    }

    /// PLT-R398B episodes: key evidence ends generation N; the next poll that still sees the flag on publishes
    /// N + 1 and pauses again until new key evidence.
    @Test func aNewGenerationPausesAgain() {
        let fixture = PipelineFixture()
        fixture.publish(secureInput: secure(1, true))
        fixture.press(Key.a)
        #expect(fixture.log.feeds.count == 1)
        fixture.publish(secureInput: secure(2, true))
        fixture.flags(Key.shift, Flag.shift)  // not key evidence: still paused
        fixture.flags(Key.shift, 0)
        #expect(fixture.log.feeds.count == 1)
        fixture.keyDown(Key.a)  // key evidence for generation 2
        #expect(fixture.log.feeds.count == 2)
        let generations = fixture.mainNotices().compactMap { notice -> UInt64? in
            if case .secureInputResumedByKey(let generation) = notice { return generation }
            return nil
        }
        #expect(generations == [1, 2])
    }

    /// PLT-R387: a secure field never resumes on keys and never feeds the engine.
    @Test func secureFieldNeverFeedsTheEngine() {
        let fixture = PipelineFixture(focus: PipelineFixtures.focus(field: PipelineFixtures.field(secure: true)))
        fixture.typeKeys([Key.a, Key.a, Key.s])
        #expect(fixture.log.feeds.isEmpty)
        #expect(fixture.popJobs().isEmpty)
    }
}

@Suite struct ModeAndFocusTests {
    private func tapControlShift(_ fixture: PipelineFixture) {
        fixture.flags(Key.control, Flag.control)
        fixture.flags(Key.shift, Flag.control | Flag.shift)
        fixture.flags(Key.shift, Flag.control)
        fixture.flags(Key.control, 0)
    }

    /// Contracts.md 10.4, PLT-R391: a focus snapshot resolved before the ax thread applied the tap's toggle
    /// never reverts the mode; once applied, the snapshot is authoritative again.
    @Test func toggleRaceNeverRevertsTheMode() {
        let fixture = PipelineFixture()
        tapControlShift(fixture)  // tap toggle #1: VI -> EN
        fixture.publish(focus: PipelineFixtures.focus(generation: 2, mode: .vietnamese, appliedToggleSequence: 0))
        fixture.typeKeys([Key.a, Key.a])
        #expect(fixture.log.feeds.isEmpty)  // still EN
        fixture.publish(focus: PipelineFixtures.focus(generation: 3, mode: .english, appliedToggleSequence: 1))
        fixture.typeKeys([Key.a])
        #expect(fixture.log.feeds.isEmpty)
        fixture.publish(focus: PipelineFixtures.focus(generation: 4, mode: .vietnamese, appliedToggleSequence: 1))
        fixture.typeKeys([Key.a])
        #expect(fixture.log.feeds == [.key(KeyInput("a"))])  // the applied snapshot decides again
    }

    /// The toggle race under real concurrency: the ax side republishes stale snapshots (toggle not applied yet)
    /// from another thread while the tap types; no key may be composed. Run under TSan as well.
    @Test func concurrentStalePublicationsNeverRevertAToggle() {
        let fixture = PipelineFixture()
        tapControlShift(fixture)
        let cell = fixture.snapshots.focus
        let generation = fixture.focusGeneration
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            for serial in 0..<2_000 {
                var stale = PipelineFixtures.focus(generation: UInt64(2 + serial), mode: .vietnamese)
                stale.fieldHandle = FieldHandle(pid: 100, token: 1, element: nil)
                cell.publish(stale)
                generation.store(stale.generation)
            }
            done.signal()
        }
        var typed = 0
        while done.wait(timeout: .now()) == .timedOut || typed < 200 {
            fixture.press(Key.a)
            typed += 1
        }
        #expect(fixture.log.feeds.isEmpty)
        #expect(fixture.snapshots.focus.load().generation == FocusGeneration(rawValue: 2_001))
    }

    /// ADR 0313: `TapThread` builds the non-Sendable pipeline inside its thread entry from a `@Sendable`
    /// factory; the pipeline is then used only on that thread.
    @Test func pipelineIsBuiltAndUsedOnItsOwnThread() {
        let fixture = PipelineFixture()
        let context = fixture.context
        let factory = ScriptedEngineFactory(log: fixture.log)
        let makeHandler: @Sendable () -> KeyPipeline<ScriptedEngineFactory, MachClock> = {
            KeyPipeline(context: context, factory: factory, clock: MachClock())
        }
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            let pipeline = makeHandler()
            _ = pipeline.handle(PipelineFixtures.keyEvent(.keyDown, Key.a))
            done.signal()
        }
        thread.start()
        done.wait()
        #expect(fixture.log.feeds == [.key(KeyInput("a"))])
    }

    @Test func toggleOverrideAppliesOnlyToTheAppItWasMadeIn() {
        let fixture = PipelineFixture()
        tapControlShift(fixture)
        let other = PipelineFixtures.focus(
            generation: 2, pid: 200, bundle: PipelineFixtures.otherBundle, mode: .vietnamese)
        fixture.publish(focus: other)
        fixture.press(Key.a)
        #expect(fixture.log.feeds == [.key(KeyInput("a"))])
        let notice = fixture.mainNotices().first
        guard case .modeToggled(let sequence, let bundle, let mode)? = notice else {
            Issue.record("expected modeToggled, got \(String(describing: notice))")
            return
        }
        #expect(sequence == 1 && bundle == PipelineFixtures.editorBundle && mode == .english)
        guard case .modeToggled(let axSequence, let axBundle, let axMode)? = fixture.axNotices().first else {
            Issue.record("ax thread was not told about the toggle")
            return
        }
        #expect(axSequence == 1 && axBundle == PipelineFixtures.editorBundle && axMode == .english)
    }

    /// PRD-R19, PLT-R391: the first key typed after activation already uses the app's remembered mode.
    @Test func focusModeAppliesWithinOneKeystroke() {
        let fixture = PipelineFixture()
        fixture.publish(
            focus: PipelineFixtures.focus(generation: 2, pid: 200, bundle: PipelineFixtures.otherBundle, mode: .english)
        )
        fixture.typeKeys([Key.a, Key.a])
        #expect(fixture.log.feeds.isEmpty)
        fixture.publish(focus: PipelineFixtures.focus(generation: 3, mode: .vietnamese))
        fixture.press(Key.a)
        #expect(fixture.log.feeds == [.key(KeyInput("a"))])
    }

    /// PLT-R210, PLT-R340: a focus change resets the composition; a republication for the same focus owner
    /// and decision does not.
    @Test func focusChangeResetsButRepublicationDoesNot() {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        fixture.publish(focus: PipelineFixtures.focus(generation: 1, mode: .vietnamese, appliedToggleSequence: 0))
        var republished = PipelineFixtures.focus(generation: 2)
        republished.fieldHandle = FieldHandle(pid: 100, token: 1, element: nil)
        fixture.publish(focus: republished)
        fixture.press(Key.a)  // still the same word: "aa" -> "â"
        #expect(fixture.popJobs().compactMap(\.edit).first?.insertion == "â")
        #expect(fixture.log.resets.isEmpty)
        fixture.publish(focus: PipelineFixtures.focus(generation: 3, pid: 300))
        fixture.press(Key.a)
        #expect(fixture.log.resets == [.applicationChanged])
        fixture.publish(focus: PipelineFixtures.focus(generation: 4, pid: 300))  // new element, same app
        fixture.press(Key.a)
        #expect(fixture.log.resets == [.applicationChanged, .focusChanged])
    }

    /// PLT-R340: a rule or strategy change for the focused field is a hard boundary.
    @Test func ruleChangeForTheSameFieldResets() {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        var changed = PipelineFixtures.focus(
            generation: 2, decision: PipelineFixtures.decision(strategy: .selectReplace))
        changed.fieldHandle = FieldHandle(pid: 100, token: 1, element: nil)
        fixture.publish(focus: changed)
        fixture.press(Key.a)
        #expect(fixture.log.resets == [.configurationChanged])
    }

    /// ADR 0306 decision 2: a new variant from the focus snapshot builds the matching engine.
    @Test func variantChangeBuildsANewEngine() {
        let fixture = PipelineFixture()
        let code = EngineVariant(appContext: .code, englishRestore: false, macros: false)
        fixture.publish(
            focus: PipelineFixtures.focus(generation: 2, pid: 300, decision: PipelineFixtures.decision(variant: code)))
        fixture.press(Key.a)
        #expect(fixture.log.madeVariants == [.default, code])
    }

    /// PLT-R1008, PRD-R27: settings apply on the next key without restart; the hotkeys follow too.
    @Test func settingsApplyOnTheNextKey() {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        let combo = HotkeyBinding.keyCombo(modifiers: [.control], keyCode: KeyCode(rawValue: Key.space))
        fixture.publish(settings: PipelineFixtures.settings(generation: 2, toggle: combo))
        fixture.press(Key.d)
        #expect(fixture.log.madeVariants.count == 2)
        #expect(fixture.keyDown(Key.space, flags: Flag.control) == .swallow)
        #expect(fixture.lastOutcome == .consumedAsHotkey)
    }

    /// PLT-R340, PLT-R371: an input-source change resets; a non-ASCII source pauses.
    @Test func inputSourceChangesResetAndNonLatinSourcesPause() {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        fixture.publish(inputSource: PipelineFixtures.inputSource(generation: 2))
        fixture.press(Key.a)
        #expect(fixture.log.resets == [.inputSourceChanged])
        fixture.publish(inputSource: PipelineFixtures.inputSource(generation: 3, kind: .inputMethod))
        fixture.typeKeys([Key.a, Key.a])
        #expect(fixture.log.feeds.count == 2)
        #expect(fixture.popJobs().isEmpty)
    }

    @Test func passThroughStrategyAndEnglishModeNeverFeed() {
        let passThrough = PipelineFixture(
            focus: PipelineFixtures.focus(decision: PipelineFixtures.decision(strategy: .passThrough)))
        passThrough.typeKeys([Key.a, Key.a])
        #expect(passThrough.log.feeds.isEmpty)
        let english = PipelineFixture(focus: PipelineFixtures.focus(mode: .english))
        english.typeKeys([Key.a, Key.a])
        #expect(english.log.feeds.isEmpty)
    }

    /// PLT-R382: a keyDown after 500 ms without keyboard input asks the ax thread to revalidate focus; the key
    /// itself is processed at once.
    @Test func idleKeyDownRequestsRevalidation() {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        fixture.clock.advance(byMicroseconds: 400_000)
        fixture.press(Key.d)
        #expect(fixture.axNotices().isEmpty)
        fixture.clock.advance(byMicroseconds: 600_000)
        fixture.press(Key.e)
        #expect(fixture.axNotices().count == 1)
        #expect(fixture.log.feeds.count == 3)
    }

    /// Worker reset requests (ADR 0308) reset the composition at the next callback.
    @Test func workerResetRequestResetsTheComposition() {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        fixture.feedback.requestCompositionReset()
        fixture.press(Key.a)
        #expect(fixture.log.resets == [.unknown])
        #expect(fixture.popJobs().isEmpty)  // the second "a" starts a new word
    }

    /// PLT-R408 `wordStartedNearFocusChange`.
    @Test func wordStartNearAFocusChangeIsFlagged() {
        let fixture = PipelineFixture(focus: PipelineFixtures.focus(changedAt: ManualClock().now()))
        fixture.press(Key.a)
        fixture.press(Key.a)
        #expect(fixture.popJobs().compactMap(\.edit).first?.wordStartedNearFocusChange == true)
        fixture.completeJobs()
        fixture.clock.advance(byMicroseconds: 400_000)
        fixture.press(Key.space)
        fixture.press(Key.a)
        fixture.press(Key.a)
        #expect(fixture.popJobs().compactMap(\.edit).first?.wordStartedNearFocusChange == false)
    }

    /// PLT-R342: a backspace re-composition asks for verification when the rule allows it.
    @Test func backspaceRecomposeAsksForVerification() throws {
        let fixture = PipelineFixture()
        fixture.typeKeys([Key.a, Key.s])  // "á"
        fixture.completeJobs()
        fixture.press(Key.backspace)  // removes the accent: a consumed backspace
        let edit = try #require(fixture.popJobs().compactMap(\.edit).first)
        #expect(edit.kind == .backspaceRecompose)
        #expect(edit.verifyBeforeApply)
        #expect(edit.insertion == "a")
    }
}
