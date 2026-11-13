// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Table tests of the lifecycle recovery paths found in review (W1-F2): a permission flicker while a tap creation
// is in flight, the bounded retry out of failOpen(postingBroken), and one OS disable reported twice.
import AppModel
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

/// PLT-R330 step 5, PLT-R331: the OS disable event and the watchdog's `CGEventTapIsEnabled` check can both
/// report the same disable; each report runs the full procedure, but the instability notice counts it once.
@Suite struct HostLifecycleDisableCoalescingTests {
    @Test func watchdogReportJustAfterTheSystemEventStillRunsTheProcedure_PLT_R331() {
        var script = LifecycleScript.running()
        script.send(.tapDisabledBySystem(byTimeout: true))
        script.advance(by: .milliseconds(100))
        #expect(
            script.send(.watchdogTripped(.unexpectedlyDisabled)) == [
                .reenableTap, .resetComposition, .requestFlush(.tapDisabled), .recordHealth(.tapReenabled),
            ])
    }

    @Test func oneDisableReportedTwiceCountsOnceTowardTheNotice_PLT_R330() {
        var script = LifecycleScript.running()
        for _ in 0..<3 {
            #expect(!script.send(.tapDisabledBySystem(byTimeout: true)).contains(.showTapInstabilityNotice))
            script.advance(by: .milliseconds(100))
            #expect(!script.send(.watchdogTripped(.unexpectedlyDisabled)).contains(.showTapInstabilityNotice))
            script.advance(by: .seconds(60))
        }
        // Reports in the other order coalesce too; this is the fourth distinct disable.
        #expect(script.send(.watchdogTripped(.unexpectedlyDisabled)).last == .showTapInstabilityNotice)
        script.advance(by: .milliseconds(100))
        #expect(!script.send(.tapDisabledBySystem(byTimeout: false)).contains(.showTapInstabilityNotice))
    }

    @Test func disablesFurtherApartThanTheCoalescingWindowCountSeparately() {
        var script = LifecycleScript.running()
        for _ in 0..<3 {
            script.send(.tapDisabledBySystem(byTimeout: true))
            script.advance(by: HostLifecycle.disableCoalescingWindow)
        }
        #expect(script.send(.tapDisabledBySystem(byTimeout: true)).last == .showTapInstabilityNotice)
    }
}
