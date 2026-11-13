// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PRD-R12, D14: switch HUD timing driven by ManualScheduler (no real sleeps).

import AppModel
import RealtimeSupport
import TestSupport
import Testing
@testable import ShellCore

@MainActor
@Suite struct SwitchIndicatorTests {
    final class Recorder {
        var changes: [SwitchIndicator.Change] = []
    }

    func make() -> (SwitchIndicator, ManualScheduler, Recorder) {
        let scheduler = ManualScheduler(clock: ManualClock())
        let recorder = Recorder()
        let indicator = SwitchIndicator(scheduler: scheduler) { recorder.changes.append($0) }
        return (indicator, scheduler, recorder)
    }

    @Test func showsForSixHundredMilliseconds() {
        let (indicator, scheduler, recorder) = make()
        indicator.modeChanged(to: .english, manual: true, indicatorEnabled: true)
        #expect(recorder.changes == [.show(.english)])
        #expect(indicator.visibleMode == .english)
        scheduler.advance(by: .milliseconds(599))
        #expect(recorder.changes == [.show(.english)])
        scheduler.advance(by: .milliseconds(1))
        #expect(recorder.changes == [.show(.english), .hide])
        #expect(indicator.visibleMode == nil)
        #expect(scheduler.pendingCount == 0)
    }

    @Test func aNewToggleRestartsTheTimer() {
        let (indicator, scheduler, recorder) = make()
        indicator.show(.vietnamese)
        scheduler.advance(by: .milliseconds(400))
        indicator.show(.english)
        scheduler.advance(by: .milliseconds(400))
        #expect(recorder.changes == [.show(.vietnamese), .show(.english)])
        scheduler.advance(by: .milliseconds(200))
        #expect(recorder.changes == [.show(.vietnamese), .show(.english), .hide])
    }

    @Test func automaticSwitchesAndDisabledIndicatorShowNothing() {
        // PRD-R12, D14
        let (indicator, scheduler, recorder) = make()
        indicator.modeChanged(to: .english, manual: false, indicatorEnabled: true)
        indicator.modeChanged(to: .vietnamese, manual: true, indicatorEnabled: false)
        scheduler.advance(by: .seconds(1))
        #expect(recorder.changes.isEmpty)
        #expect(!SwitchIndicator.shouldShow(manual: false, indicatorEnabled: true))
        #expect(SwitchIndicator.shouldShow(manual: true, indicatorEnabled: true))
        #expect(SwitchIndicator.displayDuration == .milliseconds(600))
    }
}
