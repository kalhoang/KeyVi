// SPDX-License-Identifier: GPL-3.0-or-later
//
// The tap's side of focus tracking after events that move the focus without an app activation (PLT-R389: a
// shortcut opens Spotlight or a save sheet, Escape closes Spotlight, a click, Return, Tab, an overlay rule). Driven
// with the pipeline doubles (PipelineFixture, ScriptedEngine).

import AppModel
import Injection
import RealtimeSupport
import TestSupport
import Testing
import VietnameseEngine

@testable import InputHost

private func triggers(_ notices: [AXNotice]) -> Int {
    notices.filter { if case .revalidateFocusAfterTrigger = $0 { true } else { false } }.count
}

private func reads(_ notices: [AXNotice]) -> Int {
    notices.filter { if case .revalidateFocus = $0 { true } else { false } }.count
}

/// A fixture past its first key (which always revalidates, PLT-R382), so the counts below start at zero.
private func typingFixture(focus: FocusSnapshot = PipelineFixtures.focus()) -> (PipelineFixture, Int) {
    let fixture = PipelineFixture(focus: focus)
    fixture.press(Key.space)
    fixture.completeJobs()
    return (fixture, fixture.axNotices().count)
}

@Suite struct FocusTriggerTests {
    /// PLT-R389: Command+Space opens Spotlight, a non-activating panel: no activation notification comes, so the
    /// shortcut itself asks for the trigger settle window (Pa's items 7 and 9, 2026-11-14).
    @Test func aCommandShortcutAsksForTheTriggerWindowPLTR389() {
        let (fixture, before) = typingFixture()
        fixture.clock.advance(byMicroseconds: 50_000)
        fixture.press(Key.space, flags: Flag.command)
        let notices = Array(fixture.axNotices().dropFirst(before))
        #expect(triggers(notices) == 1 && reads(notices) == 0)
    }

    @Test func controlShortcutsEscapeReturnTabAndClicksAreTriggersPLTR389() {
        let (fixture, before) = typingFixture()
        for (key, flags) in [(Key.s, Flag.control), (Key.escape, 0), (Key.returnKey, 0), (Key.tab, 0)] {
            fixture.clock.advance(byMicroseconds: 50_000)
            fixture.press(key, flags: flags)
            fixture.completeJobs()
        }
        fixture.clock.advance(byMicroseconds: 50_000)
        fixture.send(PipelineFixtures.keyEvent(.leftMouseDown, 0))
        let notices = Array(fixture.axNotices().dropFirst(before))
        #expect(triggers(notices) == 5)
    }

    /// PLT-R389: the panel may take the focus after the last settle read; the first keyDown after the trigger asks
    /// for one more read, the keys after it do not (they are within the typing rhythm).
    @Test func theFirstKeyAfterATriggerReadsOnceMorePLTR389() {
        let (fixture, before) = typingFixture()
        fixture.clock.advance(byMicroseconds: 50_000)
        fixture.press(Key.space, flags: Flag.command)
        for key in [Key.d, Key.d, Key.u] {
            fixture.clock.advance(byMicroseconds: 100_000)
            fixture.press(key)
            fixture.completeJobs()
        }
        let notices = Array(fixture.axNotices().dropFirst(before))
        #expect(triggers(notices) == 1 && reads(notices) == 1)
        #expect(fixture.log.feeds.count == 4)  // the space of `typingFixture` and the three letters: nothing waits
    }

    /// PLT-R389: while an overlay rule applies (Spotlight, Raycast, Alfred), every keyDown asks for a read, so the
    /// keys after the panel closed (Escape, a click outside) use the previous app's rules at once.
    @Test func everyKeyReadsWhileAnOverlayRuleAppliesPLTR389() {
        var decision = PipelineFixtures.decision(restoreHotkeyEnabled: false)
        decision.overlay = true
        let (fixture, before) = typingFixture(focus: PipelineFixtures.focus(decision: decision))
        for key in [Key.d, Key.e, Key.x] {
            fixture.clock.advance(byMicroseconds: 80_000)
            fixture.press(key)
            fixture.completeJobs()
        }
        #expect(reads(Array(fixture.axNotices().dropFirst(before))) == 3)
    }

    /// PLT-R389: the focus can move while English mode, a pause or a passThrough rule applies; the request does not
    /// depend on the engine being fed.
    @Test func triggersAskInEnglishModeAndWhilePausedPLTR389() {
        for focus in [
            PipelineFixtures.focus(mode: .english), PipelineFixtures.focus(pause: .noTextFocus),
            PipelineFixtures.focus(decision: PipelineFixtures.decision(strategy: .passThrough)),
        ] {
            let (fixture, before) = typingFixture(focus: focus)
            fixture.clock.advance(byMicroseconds: 50_000)
            fixture.press(Key.space, flags: Flag.command)
            #expect(triggers(Array(fixture.axNotices().dropFirst(before))) == 1)
            #expect(fixture.log.feeds.isEmpty)
        }
    }

    @Test func autorepeatAndOrdinaryKeysAreNoTriggers() {
        let (fixture, before) = typingFixture()
        fixture.clock.advance(byMicroseconds: 50_000)
        fixture.keyDown(Key.returnKey)
        fixture.clock.advance(byMicroseconds: 30_000)
        fixture.keyDown(Key.returnKey, autorepeat: true)
        fixture.keyUp(Key.returnKey)
        fixture.completeJobs()
        for key in [Key.a, Key.left, Key.backspace, Key.f5] {
            fixture.clock.advance(byMicroseconds: 50_000)
            fixture.press(key)
            fixture.completeJobs()
        }
        let notices = Array(fixture.axNotices().dropFirst(before))
        #expect(triggers(notices) == 1)
        #expect(reads(notices) == 1)  // the "a": an autorepeat is not the next key
    }
}
