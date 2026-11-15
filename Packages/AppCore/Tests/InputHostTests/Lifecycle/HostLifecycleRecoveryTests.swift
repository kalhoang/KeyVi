// SPDX-License-Identifier: GPL-3.0-or-later
//
// Table tests of the lifecycle recovery paths found in review (W1-F2): a permission flicker while a tap creation
// is in flight, the bounded retry out of failOpen(postingBroken), and one OS disable reported twice.
import AppModel
import RealtimeSupport
import Testing

@testable import InputHost

/// PLT-R332, PLT-R211, PLT-R731: a permission that is lost and returns while `createTap` is in flight must not
/// strand the host in `noPermission` with permission granted.
@Suite struct HostLifecyclePermissionFlickerTests {
    private static func flickerDuringLaunchCreation() -> LifecycleScript {
        var script = LifecycleScript()
        script.send(.launched)
        script.send(.permissionsChanged(.granted))  // createTap in flight
        script.send(.permissionsChanged(.denied))
        return script
    }

    @Test func grantDuringInFlightCreationPublishesStartingWithoutASecondTap_PLT_R731() {
        var script = Self.flickerDuringLaunchCreation()
        #expect(script.phase == .noPermission)
        #expect(
            script.send(.permissionsChanged(.granted)) == [.publish(.starting), .recordHealth(.permissionTransition)])
        #expect(script.phase == .starting)
    }

    @Test func createdTapAfterTheFlickerRuns_PLT_R731() {
        var script = Self.flickerDuringLaunchCreation()
        script.send(.permissionsChanged(.granted))
        #expect(script.send(.tapCreated) == [.publish(.running)])
        #expect(script.phase == .running)
    }

    @Test func failedCreationAfterTheFlickerSchedulesTheRetry_PLT_R332() {
        var script = Self.flickerDuringLaunchCreation()
        script.send(.permissionsChanged(.granted))
        #expect(
            script.send(.tapCreationFailed) == [
                .publish(.failOpen(.tapUnavailable)), .resetComposition, .scheduleRetry(after: .seconds(1)),
            ])
    }

    @Test func flickerDuringARetryAttemptStillRecovers_PLT_R332() {
        var script = LifecycleScript()
        script.send(.launched)
        script.send(.permissionsChanged(.granted))
        script.send(.tapCreationFailed)
        #expect(script.send(.retryTimerFired) == [.createTap])
        script.send(.permissionsChanged(.denied))
        #expect(script.phase == .noPermission)
        #expect(
            script.send(.permissionsChanged(.granted)) == [.publish(.starting), .recordHealth(.permissionTransition)])
        #expect(script.send(.tapCreated) == [.publish(.running)])
    }
}

/// PLT-R323, PLT-R730, PLT-R731: failOpen(postingBroken) retries the tap on a bounded backoff while permissions
/// still look granted (echo loss and OS policy do not change the permission status), and recreates it at once
/// when permission returns after a real revocation.
@Suite struct HostLifecyclePostingBrokenRecoveryTests {
    @Test func postingBrokenSchedulesABoundedRetryAfterTheOrderedTeardown_PLT_R730() {
        var script = LifecycleScript.running()
        #expect(
            script.send(.postingBroken) == [
                .publish(.failOpen(.postingBroken)), .requestFlush(.failOpen), .resetComposition, .removeTap,
                .recordHealth(.postingBroken), .scheduleRetry(after: .seconds(30)),
            ])
    }

    @Test func retryRecreatesTheTapWithoutLeavingFailOpenUntilItExists() {
        var script = LifecycleScript.running()
        script.send(.postingBroken)
        script.advance(by: .seconds(30))
        #expect(script.send(.retryTimerFired) == [.createTap])
        #expect(script.phase == .failOpen(.postingBroken), "no menu flicker during the attempt")
        #expect(script.send(.retryTimerFired) == [], "creation already in progress")
        #expect(script.send(.tapCreated) == [.resetComposition, .publish(.running)])
    }

    @Test func repeatedBreaksDoubleTheDelayUpToFiveMinutes() {
        var script = LifecycleScript.running()
        var delays: [TimeSpan] = []
        for _ in 0..<6 {
            for case .scheduleRetry(let delay) in script.send(.postingBroken) { delays.append(delay) }
            script.advance(by: delays.last ?? .zero)
            script.send(.retryTimerFired)
            script.send(.tapCreated)
            script.advance(by: .seconds(5))  // the recreated tap breaks again soon
        }
        #expect(delays == [30, 60, 120, 240, 300, 300].map { TimeSpan.seconds($0) })
    }

    @Test func aTapThatKeepsPostingResetsTheBackoff() {
        var script = LifecycleScript.running()
        script.send(.postingBroken)
        script.advance(by: .seconds(30))
        script.send(.retryTimerFired)
        script.send(.tapCreated)
        script.advance(by: .seconds(5))
        #expect(script.send(.postingBroken).last == .scheduleRetry(after: .seconds(60)))
        script.advance(by: .seconds(60))
        script.send(.retryTimerFired)
        script.send(.tapCreated)
        script.advance(by: HostLifecycle.postingBrokenStableInterval)
        #expect(script.send(.postingBroken).last == .scheduleRetry(after: .seconds(30)))
    }

    @Test func revocationWhileWaitingCancelsTheRetryAndAGrantRecreatesAtOnce_PLT_R731() {
        var script = LifecycleScript.running()
        script.send(.postingBroken)
        #expect(
            script.send(.permissionsChanged(.denied)) == [
                .cancelRetry, .publish(.failOpen(.permissionRevoked)), .resetComposition,
                .recordHealth(.permissionTransition),
            ])
        #expect(script.send(.retryTimerFired) == [], "a timer that fired after cancelRetry is stale")
        #expect(
            script.send(.permissionsChanged(.granted)) == [
                .publish(.starting), .resetComposition, .createTap, .recordHealth(.permissionTransition),
            ])
    }

    @Test func unchangedGrantWhileWaitingKeepsTheTimer() {
        var script = LifecycleScript.running()
        script.send(.postingBroken)
        #expect(script.send(.permissionsChanged(.grantedListenRequired)) == [])
        #expect(script.send(.retryTimerFired) == [.createTap])
    }

    @Test func failedRecreationFallsBackToTheTapUnavailableBackoff_PLT_R332() {
        var script = LifecycleScript.running()
        script.send(.postingBroken)
        script.send(.retryTimerFired)
        #expect(
            script.send(.tapCreationFailed) == [
                .publish(.failOpen(.tapUnavailable)), .resetComposition, .scheduleRetry(after: .seconds(1)),
            ])
    }

    @Test func recreationWhileTheSessionIsInactiveStaysInactive_PLT_R333() {
        var script = LifecycleScript.running()
        script.send(.postingBroken)
        script.send(.sessionActive(false))
        script.send(.retryTimerFired)
        #expect(script.send(.tapCreated) == [.publish(.sessionInactive), .resetComposition])
    }
}

/// PLT-R330 step 5, PLT-R331: the OS disable event and the watchdog's `CGEventTapIsEnabled` check can both
/// report the same disable; each report runs the procedure, but the instability notice counts it once and, while the
/// live answer is pending, the second report asks for no second check (PLT-R330 amended 15/11/2026).
@Suite struct HostLifecycleDisableCoalescingTests {
    @Test func watchdogReportJustAfterTheSystemEventStillRunsTheProcedure_PLT_R331() {
        var script = LifecycleScript.running()
        script.send(.tapDisabledBySystem(byTimeout: true))
        script.advance(by: .milliseconds(100))
        #expect(
            script.send(.watchdogTripped(.unexpectedlyDisabled)) == [
                .resetComposition, .requestFlush(.tapDisabled), .recordHealth(.tapReenabled),
            ])
        #expect(script.send(.livePermissions(.granted)) == [.reenableTap])
    }

    @Test func oneDisableReportedTwiceCountsOnceTowardTheNotice_PLT_R330() {
        var script = LifecycleScript.running()
        for _ in 0..<3 {
            #expect(!script.send(.tapDisabledBySystem(byTimeout: true)).contains(.showTapInstabilityNotice))
            script.advance(by: .milliseconds(100))
            #expect(!script.send(.watchdogTripped(.unexpectedlyDisabled)).contains(.showTapInstabilityNotice))
            script.send(.livePermissions(.granted))
            script.advance(by: .seconds(60))
        }
        // Reports in the other order coalesce too; this is the fourth distinct disable.
        #expect(script.send(.watchdogTripped(.unexpectedlyDisabled)).contains(.showTapInstabilityNotice))
        script.advance(by: .milliseconds(100))
        #expect(!script.send(.tapDisabledBySystem(byTimeout: false)).contains(.showTapInstabilityNotice))
    }

    /// Counted separately, two disables one coalescing window apart reach the circuit breaker's threshold.
    @Test func disablesFurtherApartThanTheCoalescingWindowCountSeparately() {
        var script = LifecycleScript.running()
        script.send(.tapDisabledBySystem(byTimeout: true))
        script.send(.livePermissions(.granted))
        script.advance(by: HostLifecycle.disableCoalescingWindow)
        #expect(script.send(.tapDisabledBySystem(byTimeout: true)).contains(.recordHealth(.tapUnstable)))
    }
}
