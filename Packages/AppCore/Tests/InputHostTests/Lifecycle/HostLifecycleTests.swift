// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Table tests of the input host lifecycle (02-platform.md 2.1, contracts.md 10.3). W1-F2.
import AppModel
import Testing
@testable import InputHost

@Suite struct HostLifecycleLaunchTests {
    @Test func launchWithoutPermissionThenGrantStartsAndRuns() {
        var script = LifecycleScript()
        #expect(script.phase == .starting)
        #expect(script.send(.launched) == [])
        #expect(script.send(.permissionsChanged(.denied)) == [.publish(.noPermission)])
        #expect(
            script.send(.permissionsChanged(.granted)) == [
                .publish(.starting), .createTap, .recordHealth(.permissionTransition),
            ])
        #expect(script.send(.tapCreated) == [.publish(.running)])
        #expect(script.phase == .running)
    }

    @Test func launchWithGrantedPermissionCreatesTheTapAtOnce() {
        var script = LifecycleScript()
        #expect(script.send(.permissionsChanged(.granted)) == [])
        #expect(script.send(.launched) == [.createTap])
        #expect(script.send(.tapCreated) == [.publish(.running)])
    }

    @Test func inputsBeforeLaunchOnlyRecordState() {
        var script = LifecycleScript()
        #expect(script.send(.tapCreated) == [])
        #expect(script.send(.retryTimerFired) == [])
        #expect(script.send(.postingBroken) == [])
        #expect(script.send(.sessionActive(false)) == [])
        #expect(script.send(.permissionsChanged(.granted)) == [])
        #expect(script.phase == .starting)
        #expect(script.send(.launched) == [.createTap])
        #expect(script.send(.tapCreated) == [.publish(.sessionInactive), .resetComposition])
    }

    @Test func secondLaunchIsIgnored() {
        var script = LifecycleScript.running()
        #expect(script.send(.launched) == [])
        #expect(script.phase == .running)
    }

    @Test func stalePermissionDoesNotLookGranted() {
        var script = LifecycleScript()
        script.send(.launched)
        #expect(script.send(.permissionsChanged(.stale)) == [.publish(.noPermission)])
    }
}

/// PLT-R332: tap creation failure enters failOpen(tapUnavailable) and retries 1, 2, 5, 10 s (cap) only while
/// permissions look granted.
@Suite struct HostLifecycleTapUnavailableTests {
    @Test func creationFailureRetriesWithBackoffWhilePermissionsLookGranted_PLT_R332() {
        var script = LifecycleScript()
        script.send(.launched)
        script.send(.permissionsChanged(.granted))
        #expect(
            script.send(.tapCreationFailed) == [
                .publish(.failOpen(.tapUnavailable)), .resetComposition, .scheduleRetry(after: .seconds(1)),
            ])
        var delays: [Duration] = [.seconds(1)]
        for _ in 0..<4 {
            #expect(script.send(.retryTimerFired) == [.createTap])
            let effects = script.send(.tapCreationFailed)
            for case .scheduleRetry(let delay) in effects { delays.append(delay) }
            #expect(effects.count == 1, "staying in failOpen(tapUnavailable) publishes nothing")
        }
        #expect(delays == [.seconds(1), .seconds(2), .seconds(5), .seconds(10), .seconds(10)])
        #expect(script.phase == .failOpen(.tapUnavailable))
    }

    @Test func noRetriesWhilePermissionsDoNotLookGranted_PLT_R332() {
        var script = LifecycleScript()
        script.send(.launched)
        script.send(.permissionsChanged(.granted))
        script.send(.tapCreationFailed)
        #expect(
            script.send(.permissionsChanged(.denied)) == [
                .cancelRetry, .publish(.noPermission), .resetComposition, .recordHealth(.permissionTransition),
            ])
        #expect(script.send(.retryTimerFired) == [], "a timer that fired after cancelRetry is stale")
        #expect(script.send(.tapCreationFailed) == [])
        #expect(script.phase == .noPermission)
    }

    @Test func backoffRestartsAfterPermissionReturns() {
        var script = LifecycleScript()
        script.send(.launched)
        script.send(.permissionsChanged(.granted))
        script.send(.tapCreationFailed)
        script.send(.retryTimerFired)
        script.send(.tapCreationFailed)  // 2 s scheduled
        script.send(.permissionsChanged(.denied))
        script.send(.permissionsChanged(.granted))
        #expect(script.send(.tapCreationFailed).contains(.scheduleRetry(after: .seconds(1))))
    }

    @Test func retrySuccessRunsAndResetsTheBackoff() {
        var script = LifecycleScript()
        script.send(.launched)
        script.send(.permissionsChanged(.granted))
        script.send(.tapCreationFailed)
        script.send(.retryTimerFired)
        script.send(.tapCreationFailed)
        script.send(.retryTimerFired)
        #expect(script.send(.tapCreated) == [.resetComposition, .publish(.running)])
        // A later failure starts again at 1 s.
        script.send(.postingBroken)
        script.send(.permissionsChanged(.denied))
        script.send(.permissionsChanged(.granted))
        #expect(script.send(.tapCreationFailed).contains(.scheduleRetry(after: .seconds(1))))
    }

    @Test func unchangedGrantWhileRetryingKeepsTheBackoff() {
        var script = LifecycleScript()
        script.send(.launched)
        script.send(.permissionsChanged(.granted))
        script.send(.tapCreationFailed)
        #expect(script.send(.permissionsChanged(.grantedListenRequired)) == [])
        #expect(script.send(.retryTimerFired) == [.createTap])
    }

    @Test func duplicateRetryTimerIsIgnored() {
        var script = LifecycleScript()
        script.send(.launched)
        script.send(.permissionsChanged(.granted))
        script.send(.tapCreationFailed)
        #expect(script.send(.retryTimerFired) == [.createTap])
        #expect(script.send(.retryTimerFired) == [], "creation already in progress")
    }
}

/// PLT-R730, PLT-R731: posting broken or trust revoked removes the tap in order; permission back recreates it.
@Suite struct HostLifecycleFailOpenTests {
    @Test func postingBrokenRemovesTheTapInOrderThenRecoversWhenPermissionReturns_PLT_R730_PLT_R731() {
        var script = LifecycleScript.running()
        #expect(
            script.send(.postingBroken) == [
                .publish(.failOpen(.postingBroken)), .requestFlush(.failOpen), .resetComposition, .removeTap,
                .recordHealth(.postingBroken),
            ])
        #expect(
            script.send(.permissionsChanged(.denied)) == [
                .publish(.failOpen(.permissionRevoked)), .resetComposition, .recordHealth(.permissionTransition),
            ])
        #expect(
            script.send(.permissionsChanged(.granted)) == [
                .publish(.starting), .resetComposition, .createTap, .recordHealth(.permissionTransition),
            ])
        #expect(script.send(.tapCreated) == [.publish(.running)])
    }

    @Test func postingBrokenWhilePermissionStillLooksGrantedWaitsForItToReturn() {
        var script = LifecycleScript.running()
        script.send(.postingBroken)
        #expect(script.send(.permissionsChanged(.grantedListenRequired)) == [])
        #expect(script.send(.retryTimerFired) == [])
        #expect(script.phase == .failOpen(.postingBroken))
    }

    @Test func secondPostingBrokenIsIgnored() {
        var script = LifecycleScript.running()
        script.send(.postingBroken)
        #expect(script.send(.postingBroken) == [])
    }

    @Test func trustRevokedWhileRunningRemovesTheTap_PLT_R730() {
        var script = LifecycleScript.running()
        #expect(
            script.send(.permissionsChanged(.denied)) == [
                .publish(.failOpen(.permissionRevoked)), .requestFlush(.failOpen), .resetComposition, .removeTap,
                .recordHealth(.permissionTransition),
            ])
        #expect(script.send(.permissionsChanged(.denied)) == [])
        #expect(
            script.send(.permissionsChanged(.granted)) == [
                .publish(.starting), .resetComposition, .createTap, .recordHealth(.permissionTransition),
            ])
    }

    @Test func revokedThenRecreatedTapThatFailsRetriesWithBackoff() {
        var script = LifecycleScript.running()
        script.send(.permissionsChanged(.denied))
        script.send(.permissionsChanged(.granted))
        #expect(
            script.send(.tapCreationFailed) == [
                .publish(.failOpen(.tapUnavailable)), .resetComposition, .scheduleRetry(after: .seconds(1)),
            ])
    }

    @Test func tapCreatedAfterPermissionLossDuringCreationIsRemoved() {
        var script = LifecycleScript()
        script.send(.launched)
        script.send(.permissionsChanged(.granted))  // createTap in flight
        #expect(script.send(.permissionsChanged(.denied)) == [.publish(.noPermission), .recordHealth(.permissionTransition)])
        #expect(script.send(.tapCreated) == [.removeTap])
        #expect(script.phase == .noPermission)
    }

    @Test func duplicateTapCreatedIsIgnored() {
        var script = LifecycleScript.running()
        #expect(script.send(.tapCreated) == [])
        #expect(script.send(.tapCreationFailed) == [])
    }
}

/// PLT-R330, PLT-R331: a disabled tap is re-enabled, the composition reset, held events replayed, the reason
/// recorded, and a notice shown after more than three disables within ten minutes.
@Suite struct HostLifecycleSystemDisableTests {
    @Test func timeoutReenablesResetsFlushesAndRecords_PLT_R330() {
        var script = LifecycleScript.running()
        #expect(
            script.send(.tapDisabledBySystem(byTimeout: true)) == [
                .reenableTap, .resetComposition, .requestFlush(.tapDisabled), .recordHealth(.tapTimeout),
            ])
        #expect(script.phase == .running)
    }

    @Test func userInputDisableRecordsItsOwnReason_PLT_R330() {
        var script = LifecycleScript.running()
        #expect(script.send(.tapDisabledBySystem(byTimeout: false)).last == .recordHealth(.tapDisabledByUserInput))
    }

    @Test func unexpectedlyDisabledRunsTheSameProcedure_PLT_R331() {
        var script = LifecycleScript.running()
        #expect(
            script.send(.watchdogTripped(.unexpectedlyDisabled)) == [
                .reenableTap, .resetComposition, .requestFlush(.tapDisabled), .recordHealth(.tapReenabled),
            ])
    }

    @Test func noticeAfterTheFourthDisableWithinTenMinutes_PLT_R330() {
        var script = LifecycleScript.running()
        for _ in 0..<3 {
            #expect(!script.send(.tapDisabledBySystem(byTimeout: true)).contains(.showTapInstabilityNotice))
            script.advance(by: .seconds(180))
        }
        #expect(script.send(.tapDisabledBySystem(byTimeout: true)).last == .showTapInstabilityNotice)
        // Not repeated while the window that triggered it is still open.
        script.advance(by: .seconds(30))
        #expect(!script.send(.tapDisabledBySystem(byTimeout: false)).contains(.showTapInstabilityNotice))
    }

    @Test func noticeCountsUnexpectedDisablesToo_PLT_R331() {
        var script = LifecycleScript.running()
        script.send(.tapDisabledBySystem(byTimeout: true))
        script.send(.watchdogTripped(.unexpectedlyDisabled))
        script.send(.tapDisabledBySystem(byTimeout: false))
        #expect(script.send(.watchdogTripped(.unexpectedlyDisabled)).last == .showTapInstabilityNotice)
    }

    @Test func disablesSpreadOverMoreThanTenMinutesShowNoNotice() {
        var script = LifecycleScript.running()
        for _ in 0..<8 {
            #expect(!script.send(.tapDisabledBySystem(byTimeout: true)).contains(.showTapInstabilityNotice))
            script.advance(by: .seconds(240))
        }
    }

    @Test func noticeCanReturnOnceTheCooldownHasPassed() {
        var script = LifecycleScript.running()
        for _ in 0..<4 { script.send(.tapDisabledBySystem(byTimeout: true)) }
        script.advance(by: .seconds(601))
        for _ in 0..<3 {
            #expect(!script.send(.tapDisabledBySystem(byTimeout: true)).contains(.showTapInstabilityNotice))
        }
        #expect(script.send(.tapDisabledBySystem(byTimeout: true)).contains(.showTapInstabilityNotice))
    }

    @Test func disableWhileSessionInactiveKeepsThePhase() {
        var script = LifecycleScript.running()
        script.send(.sessionActive(false))
        #expect(script.send(.tapDisabledBySystem(byTimeout: true)).first == .reenableTap)
        #expect(script.phase == .sessionInactive)
    }

    @Test func disableWithoutALiveTapIsIgnored() {
        var script = LifecycleScript.running()
        script.send(.postingBroken)
        #expect(script.send(.tapDisabledBySystem(byTimeout: true)) == [])
        #expect(script.send(.watchdogTripped(.unexpectedlyDisabled)) == [])
    }
}

/// PLT-R333: session resign, sleep or lock pause the host; activation validates the tap and permissions.
@Suite struct HostLifecycleSessionTests {
    @Test func resignPausesAndActivationRevalidates_PLT_R333() {
        var script = LifecycleScript.running()
        #expect(script.send(.sessionActive(false)) == [.publish(.sessionInactive), .resetComposition])
        #expect(script.send(.sessionActive(false)) == [])
        #expect(script.send(.sessionActive(true)) == [.reenableTap, .resetComposition, .publish(.running)])
    }

    @Test func permissionLostWhileInactiveFailsOpenAndActivationKeepsIt_PLT_R333() {
        var script = LifecycleScript.running()
        script.send(.sessionActive(false))
        #expect(script.send(.permissionsChanged(.denied)).contains(.removeTap))
        #expect(script.phase == .failOpen(.permissionRevoked))
        #expect(script.send(.sessionActive(true)) == [])
        #expect(script.phase == .failOpen(.permissionRevoked))
    }

    @Test func tapRecreatedWhileInactiveStaysInactiveUntilActivation() {
        var script = LifecycleScript.running()
        script.send(.sessionActive(false))
        script.send(.permissionsChanged(.denied))
        script.send(.permissionsChanged(.granted))
        #expect(script.send(.tapCreated) == [.publish(.sessionInactive), .resetComposition])
        #expect(script.send(.sessionActive(true)) == [.reenableTap, .resetComposition, .publish(.running)])
    }

    @Test func resignWhileFailOpenIsRememberedOnly() {
        var script = LifecycleScript.running()
        script.send(.postingBroken)
        #expect(script.send(.sessionActive(false)) == [])
        #expect(script.phase == .failOpen(.postingBroken))
    }
}

/// PLT-R306 and ADR 0309: a callback over 250 ms disables the tap and fails open; recovery only after the
/// callback returned; a callback that never returns leaves the host in failOpen(callbackStuck), no second tap.
@Suite struct HostLifecycleWatchdogTests {
    @Test func overLimitDisablesAndFailsOpenThenRecoversAfterReturn_PLT_R306() {
        var script = LifecycleScript.running()
        #expect(
            script.send(.watchdogTripped(.callbackOverLimit(microseconds: 300_000))) == [
                .publish(.failOpen(.watchdog)), .disableTap, .requestFlush(.failOpen), .resetComposition,
                .recordHealth(.watchdogTrip),
            ])
        #expect(script.send(.watchdogTripped(.callbackOverLimit(microseconds: 400_000))) == [])
        #expect(
            script.send(.callbackExited) == [
                .reenableTap, .resetComposition, .publish(.running), .recordHealth(.tapReenabled),
            ])
    }

    @Test func stuckCallbackNeverCreatesASecondTap_ADR0309() {
        var script = LifecycleScript.running()
        script.send(.watchdogTripped(.callbackOverLimit(microseconds: 300_000)))
        #expect(
            script.send(.watchdogTripped(.callbackStuck(microseconds: 2_300_000))) == [
                .publish(.failOpen(.callbackStuck)), .resetComposition,
            ])
        let attempts: [LifecycleInput] = [
            .permissionsChanged(.denied), .permissionsChanged(.granted), .retryTimerFired, .tapCreationFailed,
            .tapCreated, .postingBroken, .tapDisabledBySystem(byTimeout: true), .sessionActive(false),
            .sessionActive(true), .watchdogTripped(.unexpectedlyDisabled),
            .watchdogTripped(.callbackOverLimit(microseconds: 1)),
        ]
        for input in attempts {
            let effects = script.send(input)
            #expect(!effects.contains(.createTap), "PLT-R302: no second tap while the old thread may be stuck")
            #expect(!effects.contains(.removeTap), "a stuck tap thread is never touched")
            #expect(!effects.contains(.reenableTap))
        }
        #expect(script.phase == .failOpen(.callbackStuck))
    }

    @Test func stuckCallbackThatReturnsLateRecoversTheSameTap() {
        var script = LifecycleScript.running()
        script.send(.watchdogTripped(.callbackOverLimit(microseconds: 300_000)))
        script.send(.watchdogTripped(.callbackStuck(microseconds: 2_300_000)))
        #expect(script.send(.callbackExited).first == .reenableTap)
        #expect(script.phase == .running)
    }

    @Test func permissionLostWhileStuckRemovesTheTapOnlyAfterReturn() {
        var script = LifecycleScript.running()
        script.send(.watchdogTripped(.callbackOverLimit(microseconds: 300_000)))
        #expect(script.send(.permissionsChanged(.denied)) == [.recordHealth(.permissionTransition)])
        #expect(
            script.send(.callbackExited) == [
                .publish(.failOpen(.permissionRevoked)), .requestFlush(.failOpen), .resetComposition, .removeTap,
            ])
    }

    @Test func recoveryWhileSessionInactiveReturnsToSessionInactive() {
        var script = LifecycleScript.running()
        script.send(.sessionActive(false))
        script.send(.watchdogTripped(.callbackOverLimit(microseconds: 300_000)))
        #expect(
            script.send(.callbackExited) == [
                .reenableTap, .publish(.sessionInactive), .resetComposition, .recordHealth(.tapReenabled),
            ])
    }

    @Test func recoveryAfterTheSessionReturnedRuns() {
        var script = LifecycleScript.running()
        script.send(.sessionActive(false))
        script.send(.watchdogTripped(.callbackOverLimit(microseconds: 300_000)))
        #expect(script.send(.sessionActive(true)) == [], "remembered while the watchdog holds the tap")
        #expect(
            script.send(.callbackExited) == [
                .reenableTap, .resetComposition, .publish(.running), .recordHealth(.tapReenabled),
            ])
    }

    @Test func callbackExitedOutsideAWatchdogPhaseIsIgnored() {
        var script = LifecycleScript.running()
        #expect(script.send(.callbackExited) == [])
        #expect(script.send(.watchdogTripped(.callbackStuck(microseconds: 1))) == [])
    }
}

/// PLT-R210: the user-disable pause resets the composition on every change.
@Suite struct HostLifecycleUserDisableTests {
    @Test func togglingUserDisableResetsTheComposition_PLT_R210() {
        var script = LifecycleScript.running()
        #expect(script.send(.userDisabled(true)) == [.resetComposition])
        #expect(script.lifecycle.userDisabled)
        #expect(script.send(.userDisabled(true)) == [])
        #expect(script.send(.userDisabled(false)) == [.resetComposition])
        #expect(!script.lifecycle.userDisabled)
        #expect(script.phase == .running)
    }
}
