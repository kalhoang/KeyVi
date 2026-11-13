// SPDX-License-Identifier: GPL-3.0-or-later
//
// The guided test's diagnostics pass-through in the tap pipeline (PLT-R1205 steps 3-5): every keyboard event
// passes unchanged without reaching the engine, hotkeys neither toggle nor restore (no per-app memory write,
// no manual mode change), and entering and leaving reset the composition (PLT-R210). The flag is read from the
// lifecycle snapshot like every other per-key input (PLT-R304).

import AppModel
import Injection
import RealtimeSupport
import TestSupport
import Testing

@testable import InputHost

@Suite struct KeyPipelinePassThroughTests {
    static func lifecycle(generation: UInt64, passThrough: Bool) -> LifecycleSnapshot {
        LifecycleSnapshot(
            generation: generation, phase: .running, userDisabled: false, recorderActive: false,
            globalMode: .vietnamese, diagnosticsPassThrough: passThrough)
    }

    @Test func passThroughIsItsOwnPauseAboveUserDisable() {
        let focus = PipelineFixtures.focus()
        let resolve = { (lifecycle: LifecycleSnapshot) in
            HostStateResolver.resolve(
                lifecycle: lifecycle, secureInput: .initial, secureResumedGeneration: nil,
                inputSource: PipelineFixtures.inputSource(), focus: focus, effectiveMode: .vietnamese)
        }
        #expect(resolve(Self.lifecycle(generation: 1, passThrough: true)) == .paused(.diagnosticsTest))
        #expect(resolve(Self.lifecycle(generation: 1, passThrough: false)) == .ready(.vietnamese))
        var both = Self.lifecycle(generation: 1, passThrough: true)
        both.userDisabled = true
        #expect(resolve(both) == .paused(.diagnosticsTest))
        both.phase = .failOpen(.watchdog)
        #expect(resolve(both) == .failOpen(.watchdog), "fail-open still wins")
        #expect(PauseReason.diagnosticsTest.code == .diagnosticsTest)
    }

    @Test func everyKeyPassesUnchangedAndNothingReachesTheEngine_PLT_R1205() {
        let fixture = PipelineFixture(lifecycle: Self.lifecycle(generation: 1, passThrough: true))
        for key in [Key.d, Key.d, Key.a, Key.s, Key.space, Key.backspace, Key.returnKey] {
            #expect(fixture.keyDown(key) == .pass)
            #expect(fixture.lastOutcome == .passed)
            #expect(fixture.keyUp(key) == .pass)
        }
        #expect(fixture.log.feeds.isEmpty)
        #expect(fixture.popJobs().isEmpty)
        #expect(fixture.mainNotices().allSatisfy { $0.toggledMode == nil })
    }

    @Test func hotkeysNeitherToggleNorRestoreSoNoMemoryOrModeIsWritten() {
        let restore = HotkeyBinding.key(KeyCode(rawValue: Key.escape))
        let fixture = PipelineFixture(
            settings: PipelineFixtures.settings(restore: restore),
            lifecycle: Self.lifecycle(generation: 1, passThrough: true))
        fixture.flags(Key.control, Flag.control)
        fixture.flags(Key.shift, Flag.control | Flag.shift)
        #expect(fixture.flags(Key.shift, Flag.control) == .pass)
        #expect(fixture.flags(Key.control, 0) == .pass)
        #expect(fixture.keyDown(Key.escape) == .pass, "the restore key is not consumed")
        #expect(fixture.mainNotices().allSatisfy { $0.toggledMode == nil }, "no VI/EN toggle reaches main")
        #expect(fixture.axNotices().isEmpty, "no toggle reaches per-app memory")
        #expect(fixture.log.feeds.isEmpty)
    }

    @Test func enteringAndLeavingResetTheComposition_PLT_R210() {
        let fixture = PipelineFixture()
        _ = fixture.typeKeys([Key.d, Key.d])  // a composition in progress
        fixture.completeJobs()
        #expect(!fixture.log.feeds.isEmpty)
        fixture.publish(lifecycle: Self.lifecycle(generation: 2, passThrough: true))
        fixture.press(Key.a)
        #expect(fixture.log.resets.count == 1, "entering resets the word typed before the test")
        fixture.publish(lifecycle: Self.lifecycle(generation: 3, passThrough: false))
        let feedsBefore = fixture.log.feeds.count
        fixture.press(Key.a)
        #expect(fixture.log.feeds.count == feedsBefore + 1, "typing transforms again after the test")
        #expect(fixture.log.resets.count == 1, "the engine was clean when the test ended, so no second reset")
    }
}
