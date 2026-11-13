// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PLT-R1105 automatic relaunch rule with ManualScheduler and ManualClock (ADR 0313): never in the middle of a
// word, never while secure input is on, one-shot timers only (PLT-R803).

#if UPDATER_TESTS
import RealtimeSupport
import Testing
import TestSupport

@MainActor
@Suite struct RelaunchGateTests {
    let clock = ManualClock()
    let scheduler: ManualScheduler
    let idle: IdleSimulator
    let gate: RelaunchGate

    init() {
        scheduler = ManualScheduler(clock: clock)
        idle = IdleSimulator(clock: clock)
        let idle = idle
        gate = RelaunchGate(idleState: { idle.state }, scheduler: scheduler)
    }

    func advance(seconds: Int) { scheduler.advance(by: .seconds(seconds)) }

    @Test(
        "PLT-R1105 decision table",
        arguments: [
            (
                KeyboardIdleState(secondsSinceLastKey: 0, secureInputOn: false),
                RelaunchGate.Decision.recheck(after: .seconds(60))
            ),
            (KeyboardIdleState(secondsSinceLastKey: 45, secureInputOn: false), .recheck(after: .seconds(15))),
            (KeyboardIdleState(secondsSinceLastKey: 59.9, secureInputOn: false), .recheck(after: .seconds(1))),
            (KeyboardIdleState(secondsSinceLastKey: 60, secureInputOn: false), .installNow),
            (KeyboardIdleState(secondsSinceLastKey: .infinity, secureInputOn: false), .installNow),
            (KeyboardIdleState(secondsSinceLastKey: 600, secureInputOn: true), .recheck(after: .seconds(30))),
            (KeyboardIdleState(secondsSinceLastKey: .nan, secureInputOn: false), .recheck(after: .seconds(60))),
            (KeyboardIdleState(secondsSinceLastKey: -5, secureInputOn: false), .recheck(after: .seconds(60))),
        ])
    func decisionTable(state: KeyboardIdleState, expected: RelaunchGate.Decision) {
        #expect(RelaunchGate.decision(for: state) == expected)
    }

    @Test("Installs after 60 s without a key press, once")
    func installsAfterIdle() {
        var installs = 0
        idle.pressKey()
        gate.arm { installs += 1 }
        #expect(gate.isArmed)
        advance(seconds: 59)
        #expect(installs == 0)
        advance(seconds: 1)
        #expect(installs == 1)
        #expect(!gate.isArmed)
        advance(seconds: 3600)
        #expect(installs == 1)
        #expect(scheduler.pendingCount == 0)
    }

    @Test("A key press restarts the 60 s wait (PRD-R50: never in the middle of a word)")
    func keyPressRestartsWait() {
        var installs = 0
        idle.pressKey()
        gate.arm { installs += 1 }
        advance(seconds: 30)
        idle.pressKey()
        advance(seconds: 30)
        #expect(installs == 0)
        advance(seconds: 29)
        #expect(installs == 0)
        advance(seconds: 1)
        #expect(installs == 1)
    }

    @Test("Secure input blocks the install until it ends")
    func secureInputBlocks() {
        var installs = 0
        idle.secureInputOn = true
        gate.arm { installs += 1 }
        advance(seconds: 600)
        #expect(installs == 0)
        idle.secureInputOn = false
        advance(seconds: 30)
        #expect(installs == 1)
    }

    @Test("Already idle when armed: installs at once")
    func idleAtArm() {
        var installs = 0
        gate.arm { installs += 1 }
        #expect(installs == 1)
        #expect(scheduler.pendingCount == 0)
    }

    @Test("PLT-R803: one one-shot timer at a time, no repeating timer, nothing under one second")
    func timerDiscipline() {
        idle.pressKey()
        gate.arm {}
        for _ in 0..<50 {
            #expect(scheduler.pendingCount <= 1)
            #expect(scheduler.repeatingIntervals.isEmpty)
            if let next = scheduler.nextDeadline {
                #expect(next.nanoseconds(since: clock.now()) >= 1_000_000_000)
            }
            idle.pressKey()
            advance(seconds: 1)
        }
    }

    @Test("A second handler replaces the first; disarm cancels")
    func rearmAndDisarm() {
        var first = 0
        var second = 0
        idle.pressKey()
        gate.arm { first += 1 }
        gate.arm { second += 1 }
        #expect(scheduler.pendingCount == 1)
        advance(seconds: 60)
        #expect(first == 0 && second == 1)
        idle.pressKey()
        gate.arm { first += 1 }
        gate.disarm()
        #expect(!gate.isArmed && scheduler.pendingCount == 0)
        advance(seconds: 600)
        #expect(first == 0)
    }
}
#endif
