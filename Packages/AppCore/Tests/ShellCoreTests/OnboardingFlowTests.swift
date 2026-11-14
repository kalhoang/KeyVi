// SPDX-License-Identifier: GPL-3.0-or-later
//
// PRD-R40-R42, PLT-R710, PLT-R711: screen order, conditional screens, no skipping screen 2, advance on the first
// poll after the grant, permission-lost variant, location check.

import AppModel
import Foundation
import InputHost
import Testing

@testable import ShellCore

enum Permissions {
    static let granted = PermissionStatus(
        accessibility: .granted, postEvent: .granted, listenEvent: .granted, listenEventRequired: false, health: .ready)
    static let missing = PermissionStatus(
        accessibility: .denied, postEvent: .denied, listenEvent: .unknown, listenEventRequired: false,
        health: .noPermission)
    static let stale = PermissionStatus(
        accessibility: .denied, postEvent: .denied, listenEvent: .unknown, listenEventRequired: false, health: .stale)
    static let needsInputMonitoring = PermissionStatus(
        accessibility: .granted, postEvent: .granted, listenEvent: .denied, listenEventRequired: true,
        health: .noPermission)
}

@Suite struct OnboardingFlowTests {
    let conflict = ConflictingInput.runningApp(bundle: BundleKey(rawValue: "com.example.OtherIME")!, name: "Other")
    let candidate = ImportCandidate(appName: "Other", bundle: BundleKey(rawValue: "com.example.OtherIME"))

    func inputs(
        _ permission: PermissionStatus = Permissions.missing, conflicts: Bool = false, imports: Bool = false,
        lost: Bool = false
    ) -> OnboardingInputs {
        OnboardingInputs(
            permission: permission, conflicts: conflicts ? [conflict] : [],
            importCandidates: imports ? [candidate] : [],
            permissionLostAfterCompletion: lost)
    }

    /// Walks forward with `next` and records the screens shown.
    func walk(_ flow: inout OnboardingFlow, inputs: OnboardingInputs) -> [OnboardingScreen] {
        var shown = [flow.screen]
        while !flow.isFinished {
            flow.next(inputs: inputs)
            if !flow.isFinished { shown.append(flow.screen) }
        }
        return shown
    }

    @Test func allEightScreensWhenEveryConditionHolds() {
        var flow = OnboardingFlow(inputs: inputs())
        let all = inputs(Permissions.granted, conflicts: true, imports: true)
        #expect(walk(&flow, inputs: all) == OnboardingScreen.allCases)
        #expect(flow.isFinished)
    }

    @Test func screensFiveAndSixAreSkippedWhenTheirConditionIsFalse() {
        var flow = OnboardingFlow(inputs: inputs())
        #expect(
            walk(&flow, inputs: inputs(Permissions.granted)) == [
                .welcome, .permission, .typingMethod, .switching, .tryIt, .done,
            ])
        var onlyImport = OnboardingFlow(inputs: inputs())
        #expect(
            walk(&onlyImport, inputs: inputs(Permissions.granted, imports: true))
                == [.welcome, .permission, .typingMethod, .switching, .importFrom, .tryIt, .done])
    }

    @Test func screenTwoCanNeverBeSkippedOrLeftWithoutPermission() {
        var flow = OnboardingFlow(inputs: inputs())
        flow.next(inputs: inputs())
        #expect(flow.screen == .permission)
        #expect(!flow.canSkip)
        flow.skip(inputs: inputs())
        #expect(flow.screen == .permission)
        flow.next(inputs: inputs())
        #expect(flow.screen == .permission)
        flow.next(inputs: inputs(Permissions.stale))
        #expect(flow.screen == .permission)
        flow.next(inputs: inputs(Permissions.needsInputMonitoring))
        #expect(flow.screen == .permission)
        #expect(!flow.isFinished)
    }

    @Test func grantAdvancesWithinOnePermissionPoll() {
        // PRD-R40 "Live state", PLT-R711: the first poll that sees the grant advances.
        var flow = OnboardingFlow(inputs: inputs(), startAt: .permission)
        flow.permissionChanged(Permissions.missing, inputs: inputs())
        #expect(flow.screen == .permission)
        flow.permissionChanged(Permissions.granted, inputs: inputs(Permissions.granted))
        #expect(flow.screen == .typingMethod)
        #expect(flow.advancedByGrant)
        #expect(flow.permissionGranted)
        // A repeated "granted" poll does not advance again.
        flow.permissionChanged(Permissions.granted, inputs: inputs(Permissions.granted))
        #expect(flow.screen == .typingMethod)
        flow.next(inputs: inputs(Permissions.granted))
        #expect(!flow.advancedByGrant)
    }

    @Test func grantOnAnotherScreenOnlyUpdatesTheCheckMark() {
        var flow = OnboardingFlow(inputs: inputs())
        flow.permissionChanged(Permissions.granted, inputs: inputs(Permissions.granted))
        #expect(flow.screen == .welcome)
        #expect(flow.permissionGranted)
    }

    @Test func alreadyGrantedPermissionScreenOffersContinue() {
        var flow = OnboardingFlow(inputs: inputs(Permissions.granted))
        flow.next(inputs: inputs(Permissions.granted))
        #expect(flow.screen == .permission)
        #expect(flow.permissionGranted)
        flow.next(inputs: inputs(Permissions.granted))
        #expect(flow.screen == .typingMethod)
    }

    @Test func backRetracesTheScreensActuallyShown() {
        var flow = OnboardingFlow(inputs: inputs())
        let all = inputs(Permissions.granted, imports: true)
        #expect(!flow.canGoBack)
        flow.back()
        #expect(flow.screen == .welcome)
        for _ in 0..<5 { flow.next(inputs: all) }
        #expect(flow.screen == .tryIt)
        flow.back()
        #expect(flow.screen == .importFrom)
        flow.back()
        #expect(flow.screen == .switching)
        flow.back()
        flow.back()
        #expect(flow.screen == .permission)
        #expect(flow.canGoBack)
    }

    @Test func skipMovesOnFromEveryScreenButPermission() {
        var flow = OnboardingFlow(inputs: inputs(Permissions.granted), startAt: .typingMethod)
        flow.skip(inputs: inputs(Permissions.granted, conflicts: true))
        #expect(flow.screen == .switching)
        flow.skip(inputs: inputs(Permissions.granted, conflicts: true))
        #expect(flow.screen == .conflicts)
        flow.skip(inputs: inputs(Permissions.granted))
        #expect(flow.screen == .tryIt)
        flow.skip(inputs: inputs(Permissions.granted))
        flow.skip(inputs: inputs(Permissions.granted))
        #expect(flow.isFinished)
        flow.skip(inputs: inputs(Permissions.granted))
        flow.back()
        #expect(flow.isFinished)
        #expect(!flow.canGoBack)
    }

    @Test func permissionLostShowsOnlyScreenTwo() {
        // PRD-R42
        let lost = inputs(lost: true)
        var flow = OnboardingFlow(inputs: lost, startAt: .welcome)
        #expect(flow.permissionOnly)
        #expect(flow.screen == .permission)
        #expect(!flow.canGoBack)
        flow.skip(inputs: lost)
        flow.back()
        #expect(flow.screen == .permission)
        // The grant is shown on screen 2 rather than moving to screen 3.
        flow.permissionChanged(Permissions.granted, inputs: inputs(Permissions.granted, lost: true))
        #expect(flow.screen == .permission)
        #expect(flow.permissionGranted)
        flow.next(inputs: inputs(Permissions.granted, lost: true))
        #expect(flow.isFinished)
        #expect(flow.screen == .permission)
    }

    @Test func resumeStartsAtThePermissionScreen() {
        // PRD-R41
        let flow = OnboardingFlow(inputs: inputs(), startAt: .permission)
        #expect(flow.screen == .permission)
        #expect(!flow.permissionOnly)
    }

    /// PLT-R702: the Input Monitoring row, once needed on this screen, stays (as granted) when the need clears, and a
    /// flow that starts while it is needed shows it from the start.
    @Test func theFlowRemembersThatInputMonitoringWasNeeded_PLTR702() {
        var flow = OnboardingFlow(inputs: inputs(), startAt: .permission)
        #expect(!flow.inputMonitoringSeen)
        flow.permissionChanged(Permissions.needsInputMonitoring, inputs: inputs(Permissions.needsInputMonitoring))
        #expect(flow.inputMonitoringSeen)
        #expect(flow.screen == .permission)
        flow.permissionChanged(Permissions.granted, inputs: inputs(Permissions.granted))
        #expect(flow.inputMonitoringSeen)
        let resumed = OnboardingFlow(inputs: inputs(Permissions.needsInputMonitoring), startAt: .permission)
        #expect(resumed.inputMonitoringSeen)
    }

    /// PLT-R702: `CGRequestListenEventAccess()` runs once, the first time the row shows as needed, so macOS lists the
    /// app and shows its own prompt; never before it is needed and never twice in one onboarding.
    @Test func inputMonitoringIsRequestedOnceWhenItsRowFirstAppears_PLTR702() {
        var flow = OnboardingFlow(inputs: inputs(), startAt: .permission)
        var requests = [flow.takeInputMonitoringRequest()]
        flow.permissionChanged(Permissions.needsInputMonitoring, inputs: inputs(Permissions.needsInputMonitoring))
        requests.append(flow.takeInputMonitoringRequest())
        requests.append(flow.takeInputMonitoringRequest())
        flow.permissionChanged(Permissions.missing, inputs: inputs())
        flow.permissionChanged(Permissions.needsInputMonitoring, inputs: inputs(Permissions.needsInputMonitoring))
        requests.append(flow.takeInputMonitoringRequest())
        #expect(requests == [false, true, false, false])
    }

    /// PRD-R40 (screen 2 is never left without permission), PLT-R702: a `ready` status that was already replaced
    /// when it arrived (the tap creation it triggered failed and produced "needs Input Monitoring" in the same
    /// delivery) must not leave the flow on screen 3. The flow returns to screen 2 with the Input Monitoring row,
    /// and "Quay lại" still goes back to the welcome screen.
    @Test func aGrantReplacedByInputMonitoringInTheSameDeliveryReturnsToScreenTwo_PLTR702() {
        var flow = OnboardingFlow(inputs: inputs())
        flow.next(inputs: inputs())
        #expect(flow.screen == .permission)
        flow.permissionChanged(Permissions.granted, inputs: inputs(Permissions.granted))
        #expect(flow.screen == .typingMethod)
        flow.permissionChanged(Permissions.needsInputMonitoring, inputs: inputs(Permissions.needsInputMonitoring))
        #expect(flow.screen == .permission)
        #expect(flow.inputMonitoringSeen)
        #expect(!flow.permissionGranted)
        #expect(!flow.advancedByGrant)
        let requested = flow.takeInputMonitoringRequest()
        #expect(requested)
        flow.back()
        #expect(flow.screen == .welcome)
    }

    /// Once the user moved on by choice, a later permission change only updates the state; the PRD-R42 path
    /// (permission lost after completion) handles a revoked grant.
    @Test func aPermissionLossAfterTheUserMovedOnDoesNotPullTheFlowBack() {
        var flow = OnboardingFlow(inputs: inputs(), startAt: .permission)
        flow.permissionChanged(Permissions.granted, inputs: inputs(Permissions.granted))
        flow.next(inputs: inputs(Permissions.granted))
        #expect(flow.screen == .switching)
        flow.permissionChanged(Permissions.needsInputMonitoring, inputs: inputs(Permissions.needsInputMonitoring))
        #expect(flow.screen == .switching)
        #expect(!flow.permissionGranted)
    }
}

@Suite struct AppLocationCheckTests {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    func evaluate(_ path: String, readOnly: Bool = false) -> AppLocationCheck.Result {
        AppLocationCheck.evaluate(
            bundleURL: URL(fileURLWithPath: path, isDirectory: true), homeDirectory: home, isOnReadOnlyVolume: readOnly)
    }

    @Test func applicationsFoldersAreAccepted() {
        #expect(evaluate("/Applications/Example.app") == .ok)
        #expect(evaluate("/Applications/Utilities/Example.app") == .ok)
        #expect(evaluate("/Users/example/Applications/Example.app") == .ok)
    }

    @Test func translocatedPathsAreRejectedFirst() {
        let path = "/private/var/folders/xy/abc/T/AppTranslocation/1234-ABCD/d/Example.app"
        #expect(evaluate(path, readOnly: true) == .mustMove(reason: .translocated))
    }

    @Test func readOnlyVolumesAreRejected() {
        #expect(evaluate("/Volumes/Example/Example.app", readOnly: true) == .mustMove(reason: .readOnlyVolume))
        #expect(evaluate("/Applications/Example.app", readOnly: true) == .mustMove(reason: .readOnlyVolume))
    }

    @Test func otherLocationsAreRejected() {
        #expect(evaluate("/Users/example/Downloads/Example.app") == .mustMove(reason: .outsideApplications))
        #expect(evaluate("/Users/example/Desktop/Example.app") == .mustMove(reason: .outsideApplications))
        #expect(evaluate("/Applications") == .mustMove(reason: .outsideApplications))
        #expect(evaluate("/ApplicationsOld/Example.app") == .mustMove(reason: .outsideApplications))
        #expect(evaluate("/Users/other/Applications/Example.app") == .mustMove(reason: .outsideApplications))
        #expect(
            evaluate("/Applications/../Users/example/Downloads/Example.app") == .mustMove(reason: .outsideApplications))
    }
}
