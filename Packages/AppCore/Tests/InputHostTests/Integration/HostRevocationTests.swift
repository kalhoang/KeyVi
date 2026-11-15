// SPDX-License-Identifier: GPL-3.0-or-later
//
// Incident of 15/11/2026 end to end (decision 0005, "Decisions of 15/11/2026"): the Accessibility grant removed
// while the app runs must never leave the keyboard or the mouse blocked (PRD-R44, PLT-R730). The live check removes
// the tap within about a second of macOS reporting the loss (PLT-R721), a system disable never re-enables on a cached status and a tap the
// system keeps disabling is removed by the circuit breaker (PLT-R330), and the main thread never waits for a
// permission probe (PRD-R13, PLT-R721).

import AppModel
import Diagnostics
import Dispatch
import Foundation
import Injection
import RealtimeSupport
import TestSupport
import Testing

@testable import InputHost

/// A real serial queue, as production runs the permission probe calls.
private struct QueueRunner: PermissionCheckRunner {
    let queue: DispatchQueue
    func run(_ work: @escaping @Sendable () -> Void) { queue.async(execute: work) }
}

@Suite("Revoking Accessibility while the host runs (PLT-R330, PLT-R721, PLT-R730)")
@MainActor
struct HostRevocationTests {
    @Test func aRevocationRemovesTheTapWithinOneLiveCheck() async throws {
        let rig = HostRig()
        await rig.start()
        defer { rig.stop() }
        let handle = try #require(rig.liveHandles.first)
        rig.permissions.set(trusted: false, post: false, listen: true)  // the user removes the app from the list
        rig.scheduler.advance(by: PermissionMonitor.liveInterval)
        rig.settle()
        #expect(rig.lifecyclePhase == .failOpen(.permissionRevoked))
        #expect(handle.isInvalidated, "the tap is gone from the event route")
        #expect(rig.liveHandles.isEmpty)
        #expect(rig.controller.state == .failOpen(.permissionRevoked))
    }

    /// The watchdog's `CGEventTapIsEnabled` check finds the tap disabled (PLT-R331) after the grant went away and
    /// before any poll noticed: the old procedure re-enabled it on the cached `ready`.
    @Test func aTapFoundDisabledWithThePermissionGoneIsRemovedNotReenabled() async throws {
        let rig = HostRig()
        await rig.start()
        defer { rig.stop() }
        let handle = try #require(rig.liveHandles.first)
        rig.permissions.set(trusted: false, post: false, listen: true)
        handle.systemDisables()  // macOS disabled the untrusted tap
        let enablesBefore = handle.enableCalls.filter { $0 }.count
        rig.controller.session?.watchdog.checkNow()
        rig.settle()
        #expect(handle.enableCalls.filter { $0 }.count == enablesBefore, "never re-enabled")
        #expect(rig.lifecyclePhase == .failOpen(.permissionRevoked))
        #expect(handle.isInvalidated)
    }

    @Test func aTimeoutWithThePermissionGoneIsRemovedNotReenabled() async throws {
        let rig = HostRig()
        await rig.start()
        defer { rig.stop() }
        let handle = try #require(rig.liveHandles.first)
        rig.permissions.set(trusted: false, post: false, listen: true)
        handle.systemDisables()
        let enablesBefore = handle.enableCalls.filter { $0 }.count
        rig.controller.handle(MainNotice.tapDisabled(byTimeout: true))
        rig.settle()
        #expect(handle.enableCalls.filter { $0 }.count == enablesBefore)
        #expect(rig.lifecyclePhase == .failOpen(.permissionRevoked))
        #expect(handle.isInvalidated)
    }

    /// The incident's pattern with a permission check that still says yes: the second disable within 30 s removes
    /// the tap; it comes back after the backoff once the check confirms the grant.
    @Test func theCircuitBreakerRemovesATapTheSystemKeepsDisablingAndBringsItBackLater() async throws {
        let rig = HostRig()
        await rig.start()
        defer { rig.stop() }
        let handle = try #require(rig.liveHandles.first)
        rig.controller.handle(MainNotice.tapDisabled(byTimeout: true))
        rig.settle()
        #expect(handle.isEnabled, "one disable is re-enabled")
        rig.clock.advance(byMicroseconds: 10_500_000)
        rig.controller.handle(MainNotice.tapDisabled(byTimeout: true))
        rig.settle()
        #expect(rig.lifecyclePhase == .failOpen(.tapUnavailable))
        #expect(handle.isInvalidated, "the unstable tap is removed, keys flow")
        #expect(rig.health.recent(limit: 20).contains { $0.kind == .tapUnstable })
        rig.scheduler.advance(by: HostLifecycle.breakerBackoff[0] - .seconds(1))
        rig.settle()
        #expect(rig.liveHandles.isEmpty, "no comeback before the backoff")
        rig.scheduler.advance(by: .seconds(2))
        rig.settle()
        #expect(rig.lifecyclePhase == .running)
        #expect(rig.liveHandles.count == 1)
        #expect(rig.tapFactory.handles.count == 2)
    }

    @Test func aBreakerComebackWaitsForTheGrant() async throws {
        let rig = HostRig()
        await rig.start()
        defer { rig.stop() }
        rig.controller.handle(MainNotice.tapDisabled(byTimeout: true))
        rig.settle()
        rig.clock.advance(byMicroseconds: 5_000_000)
        rig.controller.handle(MainNotice.tapDisabled(byTimeout: false))
        rig.settle()
        #expect(rig.lifecyclePhase == .failOpen(.tapUnavailable))
        rig.permissions.set(trusted: false, post: false, listen: true)
        rig.scheduler.advance(by: HostLifecycle.breakerBackoff[0] + .seconds(1))
        rig.settle()
        #expect(rig.tapFactory.handles.count == 1, "no tap without the grant")
        #expect(rig.controller.state == .noPermission)
    }

    /// PRD-R13, PLT-R721: the menu-open check runs on the permission runner; the menu reads the state it has.
    @Test func theMenuOpenCheckNeverWaitsForAStalledPermissionCall() async throws {
        let queue = DispatchQueue(label: "test.host.permissions")
        let rig = HostRig(permissionRunner: QueueRunner(queue: queue))
        await rig.start()
        queue.sync {}
        rig.settle()
        defer { rig.stop() }
        rig.permissions.holdAccessibilityChecks()
        let started = Date()
        let shown = rig.controller.refreshPermissions()
        rig.controller.handle(.didWake)
        rig.controller.handle(.sessionBecameActive)
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 0.5, "the main thread waited \(elapsed) s for a stalled permission call")
        #expect(shown.health == .ready)
        #expect(rig.permissions.accessibilityChecksOnMainThread == 0)
        rig.permissions.openAccessibilityGate()
        queue.sync {}
        rig.settle()
        #expect(rig.lifecyclePhase == .running)
    }

    /// PLT-R330 step 1 (amended): a live answer that does not come (the permission runner stuck in a TCC call)
    /// never leaves the host in `running` with a disabled tap; the next watchdog report after `liveCheckOverdue`
    /// removes the tap visibly, and one slower than the coalescing window but within the bound is not a second disable.
    @Test func aStalledLiveAnswerAfterADisableEndsInAVisibleFailOpen() async throws {
        let queue = DispatchQueue(label: "test.host.permissions")
        let rig = HostRig(permissionRunner: QueueRunner(queue: queue))
        await rig.start()
        queue.sync {}
        rig.settle()
        defer { rig.stop() }
        let handle = try #require(rig.liveHandles.first)
        rig.permissions.holdAccessibilityChecks()
        handle.systemDisables()
        let enablesBefore = handle.enableCalls.filter { $0 }.count
        rig.controller.handle(MainNotice.tapDisabled(byTimeout: true))
        rig.settle()
        rig.clock.advance(byMicroseconds: 1_500_000)
        rig.controller.session?.watchdog.checkNow()  // the same disable, seen by the watchdog before the bound
        rig.settle()
        #expect(rig.lifecyclePhase == .running, "a slow answer is not a second disable")
        #expect(!rig.health.recent(limit: 20).contains { $0.kind == .tapUnstable })
        rig.scheduler.advance(by: TapWatchdog.enabledCheckInterval)  // the next periodic report, past the bound
        rig.settle()
        #expect(rig.lifecyclePhase == .failOpen(.tapUnavailable))
        #expect(handle.isInvalidated, "the waiting tap is removed")
        #expect(rig.health.recent(limit: 20).contains { $0.kind == .tapUnstable })
        rig.permissions.openAccessibilityGate()
        queue.sync {}
        rig.settle()
        #expect(handle.enableCalls.filter { $0 }.count == enablesBefore, "the late answer never re-enables the tap")
    }

    /// PLT-R332 (amended): a creation that hangs in the system blocks the main thread once, for the creation timeout;
    /// the retries do not wait for the hung thread again and start no second creation while it hangs.
    @Test func aHungCreationBlocksTheMainThreadOnlyOnce() async throws {
        let rig = HostRig(tapCreationTimeout: .milliseconds(200))
        rig.tapFactory.holdCreation()
        await rig.start()
        defer { rig.stop() }
        #expect(rig.lifecyclePhase == .failOpen(.tapUnavailable))
        #expect(rig.contexts.count == 1)
        var waited: [TimeInterval] = []
        for delay in HostLifecycle.backoff.prefix(3) {
            let started = Date()
            rig.scheduler.advance(by: delay)
            rig.settle()
            waited.append(Date().timeIntervalSince(started))
        }
        #expect(waited.allSatisfy { $0 < 0.5 }, "the retries waited \(waited) s on the main thread")
        #expect(rig.contexts.count == 1, "no second creation while the first hangs")
        #expect(rig.lifecyclePhase == .failOpen(.tapUnavailable))
        rig.tapFactory.releaseCreation()
        #expect(rig.controller.retiredSession?.thread.waitUntilExited(timeout: .seconds(3)) == true)
        #expect(rig.tapFactory.handles.first.map { $0.isInvalidated && !$0.isInstalled } == true, "late tap dropped")
        rig.scheduler.advance(by: HostLifecycle.backoff[3])
        rig.settle()
        #expect(rig.lifecyclePhase == .running, "the next retry after the hang cleared creates the tap")
        #expect(rig.liveHandles.count == 1)
    }

    /// The revocation found by the menu-open check, delivered after the runner answered.
    @Test func aRevocationFoundOnMenuOpenStillRemovesTheTap() async throws {
        let queue = DispatchQueue(label: "test.host.permissions")
        let rig = HostRig(permissionRunner: QueueRunner(queue: queue))
        await rig.start()
        queue.sync {}
        rig.settle()
        defer { rig.stop() }
        rig.permissions.set(trusted: false, post: false, listen: true)
        _ = rig.controller.refreshPermissions()
        queue.sync {}
        rig.settle()
        #expect(rig.lifecyclePhase == .failOpen(.permissionRevoked))
        #expect(rig.liveHandles.isEmpty)
    }
}
