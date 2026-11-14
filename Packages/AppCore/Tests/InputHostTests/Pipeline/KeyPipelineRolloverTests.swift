// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R311 amendment of 2026-11-15 (ADR 0322): the keyUp of a key whose keyDown the tap passed unchanged is never
// held, even while a job is in flight. Pa's dev traces of 14 and 15/11/2026: in a WebKit app (a Tauri/WKWebView
// messenger) every key released within a few milliseconds of a tone key got the keyboard's keyDown but a keyUp
// rebuilt by the worker, and the next press of that key never reached the field (5 of 5 checkable cases, 0 of 89
// controls whose keyUp passed). Held keyDowns keep the rule: their keyUp still follows their own replay.

import AppModel
import Injection
import TestSupport
import Testing

@testable import InputHost

@Suite struct KeyPipelineRolloverTests {
    /// The Dokomo shape: `u` goes down and passes, the tone key starts an edit, `u` comes up while that edit is in
    /// flight. The keyUp passes at once; no replay job is queued for it.
    @Test func keyUpOfAPassedKeyPassesWhileAJobIsInFlightPLTR311() {
        let fixture = PipelineFixture()
        #expect(fixture.keyDown(Key.u) == .pass)
        #expect(fixture.lastOutcome == .passed)
        #expect(fixture.keyDown(Key.s) == .swallow)  // "u" + tone key: an edit, in flight until its echo
        #expect(fixture.queue.inFlight > 0)
        #expect(fixture.keyUp(Key.u) == .pass)
        #expect(fixture.lastOutcome == .passed)
        #expect(fixture.popJobs().map(\.kind) == [.edit])
    }

    /// The same key typed again after its passed keyUp starts a fresh pairing: a held keyDown holds its keyUp.
    @Test func aPassedKeyUpDoesNotCarryOverToTheNextPressPLTR311() {
        let fixture = PipelineFixture()
        fixture.keyDown(Key.u)
        fixture.keyDown(Key.s)  // edit in flight
        fixture.keyUp(Key.u)  // passed (above)
        #expect(fixture.keyDown(Key.u) == .swallow)
        #expect(fixture.lastOutcome == .held)
        #expect(fixture.keyUp(Key.u) == .swallow)
        #expect(fixture.lastOutcome == .held)
        let replays = fixture.popJobs().compactMap(\.replayed)
        #expect(replays.map(\.kind) == [.keyDown, .keyUp])
    }

    /// PLT-R311 unchanged for held keys: a keyDown held behind a job keeps its keyUp behind its own replay.
    @Test func keyUpOfAHeldKeyDownStaysHeldPLTR311() {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        fixture.keyDown(Key.a)  // "aa" -> "â": edit in flight
        #expect(fixture.keyDown(Key.d) == .swallow)
        #expect(fixture.lastOutcome == .held)
        #expect(fixture.keyUp(Key.d) == .swallow)
        #expect(fixture.lastOutcome == .held)
        let jobs = fixture.popJobs()
        #expect(jobs.map(\.kind) == [.edit, .replay, .replay])
        #expect(jobs[1].replayed?.kind == .keyDown && jobs[2].replayed?.kind == .keyUp)
    }

    /// A held autorepeat of a passed key: the keyUp follows the replayed repeat, never overtakes it.
    @Test func keyUpAfterAHeldAutorepeatStaysHeldPLTR311() {
        let fixture = PipelineFixture()
        #expect(fixture.keyDown(Key.d) == .pass)
        fixture.press(Key.a)
        fixture.keyDown(Key.a)  // edit in flight
        #expect(fixture.keyDown(Key.d, autorepeat: true) == .swallow)
        #expect(fixture.lastOutcome == .held)
        #expect(fixture.keyUp(Key.d) == .swallow)
        #expect(fixture.lastOutcome == .held)
        let replays = fixture.popJobs().compactMap(\.replayed)
        #expect(replays.map(\.kind) == [.keyDown, .keyUp])
        #expect(replays.first?.autorepeat == true)
    }

    /// A passed autorepeat (nothing in flight) keeps the key passed: its keyUp passes during a later job.
    @Test func aPassedAutorepeatKeepsTheKeyUpPassingPLTR311() {
        let fixture = PipelineFixture()
        fixture.keyDown(Key.d)
        #expect(fixture.keyDown(Key.d, autorepeat: true) == .pass)
        fixture.press(Key.a)
        fixture.keyDown(Key.a)  // edit in flight
        #expect(fixture.keyUp(Key.d) == .pass)
        #expect(fixture.lastOutcome == .passed)
    }

    /// A keyDown passed because the ring was full (PLT-R314) reached the app unchanged: its keyUp passes too.
    @Test func keyUpOfAKeyDownPassedOnAFullQueuePassesPLTR311() {
        let fixture = PipelineFixture(queueCapacity: 2)
        fixture.press(Key.a)
        fixture.keyDown(Key.a)  // edit
        fixture.keyUp(Key.a)  // pairedKeyUp: the ring is full
        #expect(fixture.keyDown(Key.d) == .pass)
        #expect(fixture.lastOutcome == .passed)
        #expect(fixture.keyUp(Key.d) == .pass)
        #expect(fixture.lastOutcome == .passed)
    }

    /// A keyDown passed while failing open (PLT-R730) reached the app unchanged: once the tap holds again, its keyUp
    /// still passes.
    @Test func keyUpOfAKeyDownPassedWhileFailingOpenPassesPLTR311() {
        let fixture = PipelineFixture(lifecycle: PipelineFixtures.lifecycle(phase: .starting))
        #expect(fixture.keyDown(Key.d) == .pass)
        fixture.publish(lifecycle: PipelineFixtures.lifecycle(generation: 2))
        fixture.press(Key.a)
        fixture.keyDown(Key.a)  // edit in flight
        #expect(fixture.queue.inFlight > 0)
        #expect(fixture.keyUp(Key.d) == .pass)
        #expect(fixture.lastOutcome == .passed)
    }

    /// A separator replayed after its edit (P0-3, PLT-R405) is a keyDown queued as a replay: the table records it as
    /// held (ADR 0322 decision 1), and its keyUp follows its own replay.
    @Test func keyUpOfASeparatorReplayedAfterAnEditStaysHeldPLTR311() {
        let fixture = PipelineFixture()
        fixture.typeKeys([Key.a, Key.x, Key.s])
        fixture.completeJobs()
        #expect(fixture.keyDown(Key.space) == .swallow)
        #expect(fixture.lastOutcome == .held)
        #expect(fixture.pipeline.consumedKeys.entry(KeyCode(rawValue: Key.space)) == .heldDown)
        #expect(fixture.keyUp(Key.space) == .swallow)
        #expect(fixture.lastOutcome == .held)
        let replays = fixture.popJobs().compactMap(\.replayed)
        #expect(replays.map(\.kind) == [.keyDown, .keyUp])
    }

    /// PLT-R313 is untouched: a keyDown consumed for an edit still consumes its keyUp.
    @Test func keyUpOfAConsumedKeyIsStillConsumedPLTR313() {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        fixture.keyDown(Key.a)  // consumed for the edit
        #expect(fixture.keyUp(Key.a) == .swallow)
        #expect(fixture.lastOutcome == .consumedPairedKeyUp)
    }

    /// Modifier releases keep PLT-R311 (ADR 0322 decision 3): a passed Shift press does not let its release overtake
    /// a held key that was typed with Shift.
    @Test func aModifierReleaseIsStillHeldPLTR311() {
        let fixture = PipelineFixture()
        #expect(fixture.flags(Key.shift, Flag.shift) == .pass)
        fixture.press(Key.a)
        fixture.keyDown(Key.a)  // edit in flight
        #expect(fixture.flags(Key.shift, 0) == .swallow)
        #expect(fixture.lastOutcome == .held)
    }
}
