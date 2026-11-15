// SPDX-License-Identifier: GPL-3.0-or-later
//
// Incident of 15/11/2026 (decision 0005, "Decisions of 15/11/2026"): the Accessibility grant was removed while the
// app ran, macOS disabled the tap about every 10.5 s and the host re-enabled it each time from a cached status, so
// keyboard and clicks stalled for about 35 s. PLT-R330 (amended): a system disable re-enables only after a live
// permission check, and a tap the system keeps disabling is removed by a circuit breaker instead of re-enabled in a
// loop; it comes back only on a backoff, after a fresh check, on probation (PLT-R332).
import AppModel
import RealtimeSupport
import Testing

@testable import InputHost

/// PLT-R330 step 1: "re-enable the tap immediately if permissions are still valid", where valid means a live check.
@Suite struct HostLifecycleLiveReenableTests {
    @Test(arguments: [
        LifecycleInput.tapDisabledBySystem(byTimeout: true), .tapDisabledBySystem(byTimeout: false),
        .watchdogTripped(.unexpectedlyDisabled),
    ])
    func aSystemDisableAsksForALiveCheckBeforeReenabling(_ disable: LifecycleInput) {
        var script = LifecycleScript.running()
        let effects = script.send(disable)
        #expect(!effects.contains(.reenableTap), "never re-enabled on the cached status: \(effects)")
        #expect(effects.contains(.checkPermissionsLive))
        #expect(effects.contains(.resetComposition) && effects.contains(.requestFlush(.tapDisabled)))
        #expect(script.send(.livePermissions(.granted)) == [.reenableTap])
        #expect(script.phase == .running)
    }

    @Test(arguments: [PermissionStatus.denied, .stale])
    func aSystemDisableWithThePermissionGoneRemovesTheTapAndNeverReenables(_ status: PermissionStatus) {
        var script = LifecycleScript.running()
        script.send(.tapDisabledBySystem(byTimeout: true))
        let effects = script.send(.livePermissions(status))
        #expect(!effects.contains(.reenableTap))
        #expect(effects.contains(.removeTap))
        #expect(script.phase == .failOpen(.permissionRevoked))
    }

    @Test func aLiveAnswerWithoutAPendingDisableNeverReenables() {
        var script = LifecycleScript.running()
        #expect(script.send(.livePermissions(.granted)) == [])
    }

    @Test func oneLiveAnswerReenablesOnceForReportsThatCameTogether() {
        var script = LifecycleScript.running()
        script.send(.tapDisabledBySystem(byTimeout: true))
        script.advance(by: .milliseconds(100))
        script.send(.watchdogTripped(.unexpectedlyDisabled))  // the same disable, seen by the watchdog
        #expect(script.send(.livePermissions(.granted)) == [.reenableTap])
        #expect(script.send(.livePermissions(.granted)) == [])
    }

    @Test func aDisableWhileSessionInactiveReenablesAfterTheCheckAndKeepsThePhase() {
        var script = LifecycleScript.running()
        script.send(.sessionActive(false))
        #expect(script.send(.tapDisabledBySystem(byTimeout: true)).contains(.checkPermissionsLive))
        #expect(script.send(.livePermissions(.granted)) == [.reenableTap])
        #expect(script.phase == .sessionInactive)
    }

    @Test func aRevocationThatRemovedTheTapMeanwhileLeavesNothingToReenable() {
        var script = LifecycleScript.running()
        script.send(.tapDisabledBySystem(byTimeout: true))
        script.send(.permissionsChanged(.denied))  // the 1 s live check got there first
        #expect(script.phase == .failOpen(.permissionRevoked))
        #expect(!script.send(.livePermissions(.granted)).contains(.reenableTap))
    }
}

/// PLT-R330 step 6 and PLT-R332 (amended): the circuit breaker.
@Suite struct HostLifecycleCircuitBreakerTests {
    /// Two disables within `breakerWindow` (the incident had one about every 10.5 s): the second removes the tap.
    @Test func theSecondDisableWithinThirtySecondsRemovesTheTapInsteadOfReenabling() {
        var script = LifecycleScript.running()
        script.send(.tapDisabledBySystem(byTimeout: true))
        script.send(.livePermissions(.granted))
        script.advance(by: .milliseconds(10_500))
        let effects = script.send(.tapDisabledBySystem(byTimeout: true))
        #expect(!effects.contains(.reenableTap))
        #expect(effects.contains(.removeTap))
        #expect(effects.contains(.scheduleRetry(after: HostLifecycle.breakerBackoff[0])))
        #expect(effects.contains(.recordHealth(.tapUnstable)))
        #expect(effects.contains(.checkPermissionsLive), "a revocation shows as such as soon as the check says so")
        #expect(script.phase == .failOpen(.tapUnavailable))
        #expect(!script.send(.livePermissions(.granted)).contains(.reenableTap), "the removed tap stays removed")
    }

    @Test func disablesFurtherApartThanTheWindowAreEachReenabled() {
        var script = LifecycleScript.running()
        for _ in 0..<4 {
            #expect(script.send(.tapDisabledBySystem(byTimeout: true)).contains(.checkPermissionsLive))
            #expect(script.send(.livePermissions(.granted)) == [.reenableTap])
            script.advance(by: HostLifecycle.breakerWindow + .seconds(1))
        }
        #expect(script.phase == .running)
    }

    @Test func oneDisableReportedTwiceCountsOnce() {
        var script = LifecycleScript.running()
        script.send(.tapDisabledBySystem(byTimeout: true))
        script.advance(by: .milliseconds(100))
        #expect(!script.send(.watchdogTripped(.unexpectedlyDisabled)).contains(.removeTap))
        #expect(script.phase == .running)
    }

    @Test func aRemovedUnstableTapComesBackAfterTheBackoffOnProbation() {
        var script = Self.tripped()
        script.advance(by: HostLifecycle.breakerBackoff[0])
        #expect(script.send(.retryTimerFired) == [.createTap])
        #expect(script.send(.tapCreated).contains(.publish(.running)))
        // Probation: one more disable soon after the comeback is enough, with the next, longer delay.
        script.advance(by: .seconds(10))
        let effects = script.send(.tapDisabledBySystem(byTimeout: true))
        #expect(effects.contains(.removeTap))
        #expect(effects.contains(.scheduleRetry(after: HostLifecycle.breakerBackoff[1])))
    }

    @Test func theBackoffGrowsToItsCapAndRestartsAfterAStablePeriod() {
        var script = Self.tripped()
        var delays: [TimeSpan] = []
        for _ in 0..<5 {
            let delay = Self.retryDelay(in: script.lastEffects)
            delays.append(delay)
            script.advance(by: delay)
            script.send(.retryTimerFired)
            script.send(.tapCreated)
            script.advance(by: .seconds(5))
            script.lastEffects = script.send(.tapDisabledBySystem(byTimeout: true))
        }
        #expect(delays == [.seconds(30), .seconds(60), .seconds(120), .seconds(300), .seconds(300)])
        // A tap that stays up for the stable interval starts the backoff again.
        script.advance(by: Self.retryDelay(in: script.lastEffects))
        script.send(.retryTimerFired)
        script.send(.tapCreated)
        script.advance(by: HostLifecycle.breakerStableInterval + .seconds(1))
        script.send(.tapDisabledBySystem(byTimeout: true))
        script.send(.livePermissions(.granted))
        script.advance(by: .seconds(5))
        let effects = script.send(.tapDisabledBySystem(byTimeout: true))
        #expect(effects.contains(.scheduleRetry(after: HostLifecycle.breakerBackoff[0])))
    }

    @Test func noComebackWhileThePermissionIsMissing() {
        var script = Self.tripped()
        let effects = script.send(.livePermissions(.denied))
        #expect(effects.contains(.cancelRetry))
        #expect(script.phase == .noPermission)
        script.advance(by: HostLifecycle.breakerBackoff[0])
        #expect(!script.send(.retryTimerFired).contains(.createTap))
    }

    @Test func aComebackRefusedByTheSystemFallsBackToTheCreationBackoff() {
        var script = Self.tripped()
        script.advance(by: HostLifecycle.breakerBackoff[0])
        script.send(.retryTimerFired)
        #expect(script.send(.tapCreationFailed).contains(.scheduleRetry(after: HostLifecycle.backoff[0])))
        #expect(script.phase == .failOpen(.tapUnavailable))
    }

    /// The two-disable trip with the first re-enabled; `lastEffects` holds the trip's effects.
    private static func tripped() -> LifecycleScript {
        var script = LifecycleScript.running()
        script.send(.tapDisabledBySystem(byTimeout: true))
        script.send(.livePermissions(.granted))
        script.advance(by: .seconds(10))
        script.lastEffects = script.send(.tapDisabledBySystem(byTimeout: true))
        #expect(script.phase == .failOpen(.tapUnavailable))
        return script
    }

    private static func retryDelay(in effects: [LifecycleEffect]) -> TimeSpan {
        for effect in effects { if case .scheduleRetry(let delay) = effect { return delay } }
        Issue.record("no retry in \(effects)")
        return .zero
    }
}

/// PLT-R330 step 1 (amended): the wait for the live answer. The tap stays disabled meanwhile, so the watchdog's
/// enabled check (PLT-R331) reports it again; that report is the same disable, never a second one for the breaker,
/// and an answer that does not come within `liveCheckOverdue` turns into a visible fail-open instead of a host that
/// sits in `running` with a disabled tap.
@Suite struct HostLifecycleLiveAnswerWaitTests {
    @Test func aWatchdogReportWhileTheAnswerIsPendingIsNotASecondDisable() {
        var script = LifecycleScript.running()
        script.send(.tapDisabledBySystem(byTimeout: true))
        script.advance(by: .milliseconds(1_500))  // past the coalescing window, before the overdue bound
        let effects = script.send(.watchdogTripped(.unexpectedlyDisabled))
        #expect(!effects.contains(.removeTap), "\(effects)")
        #expect(!effects.contains(.recordHealth(.tapUnstable)))
        #expect(script.phase == .running)
        #expect(script.send(.livePermissions(.granted)) == [.reenableTap])
    }

    @Test func anAnswerThatNeverComesBecomesAVisibleFailOpen() {
        var script = LifecycleScript.running()
        script.send(.tapDisabledBySystem(byTimeout: true))
        script.advance(by: HostLifecycle.liveCheckOverdue + .seconds(2))  // the next 5 s watchdog report
        let effects = script.send(.watchdogTripped(.unexpectedlyDisabled))
        #expect(effects.contains(.removeTap))
        #expect(effects.contains(.recordHealth(.tapUnstable)))
        #expect(effects.contains(.scheduleRetry(after: HostLifecycle.backoff[0])))
        #expect(script.phase == .failOpen(.tapUnavailable))
        #expect(!script.send(.livePermissions(.granted)).contains(.reenableTap), "the removed tap stays removed")
        script.advance(by: HostLifecycle.backoff[0])
        #expect(script.send(.retryTimerFired) == [.createTap], "it comes back on a fresh check, like a failed creation")
    }

    @Test func aSessionActivationThatReenabledTheTapEndsTheWait() {
        var script = LifecycleScript.running()
        script.send(.tapDisabledBySystem(byTimeout: true))
        script.send(.sessionActive(false))
        #expect(script.send(.sessionActive(true)).contains(.reenableTap))
        script.advance(by: HostLifecycle.breakerWindow + .seconds(1))
        let effects = script.send(.watchdogTripped(.unexpectedlyDisabled))
        #expect(effects.contains(.checkPermissionsLive), "a new disable of the re-enabled tap: \(effects)")
        #expect(!effects.contains(.removeTap))
    }

    /// A disable counted for a tap that a revocation then removed never pairs with the first disable of the next tap.
    @Test func aRecreatedTapStartsWithoutTheDisablesOfThePreviousOne() {
        var script = LifecycleScript.running()
        script.send(.tapDisabledBySystem(byTimeout: true))
        script.send(.livePermissions(.denied))
        #expect(script.phase == .failOpen(.permissionRevoked))
        #expect(script.send(.permissionsChanged(.granted)).contains(.createTap))
        script.send(.tapCreated)
        script.advance(by: .seconds(5))
        let effects = script.send(.tapDisabledBySystem(byTimeout: true))
        #expect(!effects.contains(.removeTap), "\(effects)")
        #expect(effects.contains(.checkPermissionsLive))
    }
}
