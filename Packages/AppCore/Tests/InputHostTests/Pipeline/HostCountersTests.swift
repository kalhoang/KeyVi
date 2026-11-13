// SPDX-License-Identifier: GPL-3.0-or-later
//
// W3-A: the since-launch observations the integration hooks report (ADR 0502, "Integration hooks"): whether the
// first key-down after a secure-input release was composed (PLT-R398B), and the engine resets and tap recoveries
// after a tap timeout (PLT-R330, QA-R11). The pipeline records with relaxed atomics only (PLT-R304).

import AppModel
import Diagnostics
import Foundation
import Injection
import RealtimeSupport
import TestSupport
import Testing
import VietnameseEngine

@testable import InputHost

@Suite struct FirstKeyAfterSecureReleaseTests {
    private func secure(_ generation: UInt64, _ enabled: Bool) -> SecureInputSnapshot {
        SecureInputSnapshot(generation: generation, enabled: enabled, holder: nil)
    }

    @Test func nothingIsReportedBeforeTheFirstRelease() {
        let fixture = PipelineFixture()
        fixture.typeKeys([Key.a, Key.s])
        #expect(fixture.context.counters.firstKeyAfterSecureInputReleaseComposed == nil)
        fixture.publish(secureInput: secure(1, true))
        fixture.flags(Key.shift, Flag.shift)  // not key evidence
        #expect(fixture.context.counters.firstKeyAfterSecureInputReleaseComposed == nil)
    }

    /// PLT-R398B: the key that proves the release (key evidence) is itself the first key after it, and composed.
    @Test func keyEvidenceMakesThisKeyTheFirstOne() {
        let fixture = PipelineFixture()
        fixture.publish(secureInput: secure(1, true))
        fixture.keyDown(Key.a)
        #expect(fixture.context.counters.firstKeyAfterSecureInputReleaseComposed == true)
        #expect(fixture.log.feeds == [.key(KeyInput("a"))])
    }

    /// A poll saw the flag go off: the first key-down after it is reported, even when this pipeline never saw the
    /// episode begin (no keyboard event reached the tap while secure input was on).
    @Test func aReleaseSeenByThePollCountsToo() {
        let seen = PipelineFixture()
        seen.publish(secureInput: secure(1, true))
        seen.flags(Key.shift, Flag.shift)
        seen.flags(Key.shift, 0)
        seen.publish(secureInput: secure(2, false))
        seen.keyUp(Key.a)  // not a key-down: still waiting
        #expect(seen.context.counters.firstKeyAfterSecureInputReleaseComposed == nil)
        seen.keyDown(Key.a)
        #expect(seen.context.counters.firstKeyAfterSecureInputReleaseComposed == true)

        let unseen = PipelineFixture()
        unseen.publish(secureInput: secure(1, true))
        unseen.publish(secureInput: secure(2, false))
        unseen.keyDown(Key.d)
        #expect(unseen.context.counters.firstKeyAfterSecureInputReleaseComposed == true)
    }

    /// A key-down that does not reach the engine (English mode here) is reported as not composed, and only the
    /// first key after each release is recorded.
    @Test func onlyTheFirstKeyAfterEachReleaseIsRecorded() {
        let fixture = PipelineFixture()
        fixture.publish(focus: PipelineFixtures.focus(generation: 2, mode: .english))
        fixture.publish(secureInput: secure(1, true))
        fixture.publish(secureInput: secure(2, false))
        fixture.keyDown(Key.a)
        #expect(fixture.context.counters.firstKeyAfterSecureInputReleaseComposed == false)
        fixture.publish(focus: PipelineFixtures.focus(generation: 3, mode: .vietnamese))
        fixture.keyDown(Key.a)
        #expect(fixture.context.counters.firstKeyAfterSecureInputReleaseComposed == false)
        fixture.publish(secureInput: secure(3, true))
        fixture.publish(secureInput: secure(4, false))
        fixture.keyDown(Key.s)
        #expect(fixture.context.counters.firstKeyAfterSecureInputReleaseComposed == true)
    }

    /// PLT-R398B: after key evidence ends the episode, the next poll publishes the "off" generation. That poll is
    /// the same release, not a new one: it neither resets the word being typed nor records a second first key.
    @Test func thePollAfterKeyEvidenceIsTheSameRelease() {
        let fixture = PipelineFixture()
        fixture.publish(secureInput: secure(1, true))
        fixture.press(Key.a)  // key evidence: the first key after the release
        fixture.press(Key.s)
        let resetsBeforePoll = fixture.log.resets
        fixture.publish(secureInput: secure(2, false))
        fixture.press(Key.d)
        #expect(fixture.log.resets == resetsBeforePoll)
        #expect(!fixture.log.resets.contains(.secureInputChanged))
        #expect(fixture.log.feeds == [.key(KeyInput("a")), .key(KeyInput("s")), .key(KeyInput("d"))])
        #expect(fixture.context.counters.firstKeyAfterSecureInputReleaseComposed == true)
        fixture.keyDown(Key.left)  // not composed: would overwrite the answer if the poll had re-armed the flag
        #expect(fixture.context.counters.firstKeyAfterSecureInputReleaseComposed == true)
    }

    /// A later, separate episode still counts: on, evidence, off, then on and off again.
    @Test func aLaterEpisodeAfterKeyEvidenceStillCounts() {
        let fixture = PipelineFixture()
        fixture.publish(secureInput: secure(1, true))
        fixture.press(Key.a)
        fixture.publish(secureInput: secure(2, false))
        fixture.publish(secureInput: secure(3, true))
        fixture.publish(secureInput: secure(4, false))
        fixture.keyDown(Key.left)
        #expect(fixture.context.counters.firstKeyAfterSecureInputReleaseComposed == false)
    }

    /// The flag reports whether the first key reached the engine, not whether it could have: a toggle hotkey or a
    /// navigation key as the first key after a release is not composed.
    @Test func aFirstKeyThatNeverReachesTheEngineIsNotComposed() {
        let hotkey = PipelineFixture()
        let pipeline = KeyPipeline(
            context: hotkey.context, factory: RepeatingComboFactory(engines: ScriptedEngineFactory(log: hotkey.log)),
            clock: hotkey.clock)
        hotkey.publish(secureInput: secure(1, true))
        #expect(pipeline.handle(PipelineFixtures.keyEvent(.keyDown, Key.space, flags: Flag.control)) == .swallow)
        #expect(pipeline.lastOutcome == .consumedAsHotkey)
        #expect(hotkey.context.counters.firstKeyAfterSecureInputReleaseComposed == false)

        let navigation = PipelineFixture()
        navigation.publish(secureInput: secure(1, true))
        navigation.publish(secureInput: secure(2, false))
        navigation.keyDown(Key.left)
        #expect(navigation.context.counters.firstKeyAfterSecureInputReleaseComposed == false)
    }

    /// Fail-open (posting broken) passes the key untransformed: not composed.
    @Test func aFailedOpenTapIsNotComposed() {
        let fixture = PipelineFixture()
        fixture.publish(lifecycle: PipelineFixtures.lifecycle(generation: 2, phase: .failOpen(.permissionRevoked)))
        fixture.publish(secureInput: secure(1, true))
        fixture.keyDown(Key.a)
        #expect(fixture.context.counters.firstKeyAfterSecureInputReleaseComposed == false)
    }

    @Test(.enabled(if: AllocationCounter.isAvailable, "sanitizer runtimes replace malloc and never call the hook"))
    func recordingAllocatesNothing() {
        let counters = HostCounters()
        var composed = false
        func record() {
            counters.recordFirstKeyAfterSecureInputRelease(composed: composed)
            counters.engineResetsAfterTapRecovery.increment()
            composed.toggle()
        }
        record()  // warm-up: lazy metadata
        // A `while` loop: in unoptimised builds `for ... in` over a range allocates an iterator per iteration.
        let count = AllocationCounter.count {
            var index = 0
            while index < 1_000 {
                record()
                index += 1
            }
        }
        #expect(count == 0)
        #expect(counters.engineResetsAfterTapRecoveryCount == 1_001)
    }
}

@Suite struct TapTimeoutEngineResetTests {
    /// QA-R11: a timeout with a word in progress leaves the engine reset, and the pipeline counts it. A tap
    /// disabled by user input is not a timeout.
    @Test func aTimeoutResetsTheEngineAndCountsIt() {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        fixture.send(PipelineFixtures.keyEvent(.tapDisabledByTimeout, 0))
        #expect(fixture.log.resets == [.eventTapReenabled])
        #expect(fixture.context.counters.engineResetsAfterTapRecoveryCount == 1)
        fixture.send(PipelineFixtures.keyEvent(.tapDisabledByTimeout, 0))  // engine already clean: still reset
        fixture.send(PipelineFixtures.keyEvent(.tapDisabledByUserInput, 0))
        #expect(fixture.context.counters.engineResetsAfterTapRecoveryCount == 2)
        #expect(fixture.context.counters.tapRecoveryCount == 0)  // re-enabling is the main thread's job
    }
}

@Suite("Tap recoveries counted by the host")
@MainActor
struct TapRecoveryCountTests {
    /// PLT-R330: the main thread re-enables the tap after the timeout notice and counts the recovery; the
    /// pipeline counted the engine reset on the tap thread.
    @Test func aTimeoutIsRecoveredAndCounted() async throws {
        let rig = HostRig()
        await rig.start()
        defer { rig.stop() }
        let (handle, userInfo) = try #require(rig.echoLoop.route.current)
        rig.type("vie")
        let timeout = RawKeyEvent(
            kind: .tapDisabledByTimeout, keyCode: KeyCode(rawValue: 0), flags: 0, autorepeat: false, keyboardType: 0,
            unicode: .empty, userData: 0, receivedAt: MachClock().now())
        handle.setEnabled(false)  // macOS disables the tap first
        _ = HostRig.deliverOnTap(timeout, handle: handle, userInfo: userInfo)
        rig.controller.drainMainOutbox()
        rig.settle()
        #expect(handle.isEnabled)
        #expect(rig.controller.counters.tapRecoveryCount == 1)
        #expect(rig.controller.counters.engineResetsAfterTapRecoveryCount == 1)
        let byUser = RawKeyEvent(
            kind: .tapDisabledByUserInput, keyCode: KeyCode(rawValue: 0), flags: 0, autorepeat: false,
            keyboardType: 0, unicode: .empty, userData: 0, receivedAt: MachClock().now())
        _ = HostRig.deliverOnTap(byUser, handle: handle, userInfo: userInfo)
        rig.controller.drainMainOutbox()
        rig.settle()
        #expect(rig.controller.counters.tapRecoveryCount == 1)
    }
}
