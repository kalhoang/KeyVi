// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R702, PRD-R40 screen 2: a permission status replaced during its own delivery never reaches the shell. The case
// that matters: Accessibility is granted while Input Monitoring is missing, so the `ready` it gives allows a tap that
// fails at once, and the monitor queues `noPermission` plus `listenEventRequired` while `ready` is still being
// delivered. Forwarding that `ready` would tell onboarding the step is done (or, when the replacement nests inside it,
// leave the screen on `ready` for good). PLT-R331: a replaced status still checks the tap. W8-C request, W8-F.

import AppModel
import Foundation
import Injection
import TestSupport
import Testing

@testable import InputHost

@Suite("Permission delivery guard (PLT-R702, PRD-R40)")
@MainActor
struct PermissionDeliveryGuardTests {
    /// How the main hop delivers the replacement: `queued` behind the replaced status (the check ran on the main
    /// thread; tests' `ManualMainHop`), or `nested` inside it (the check ran on a background queue, so the replaced
    /// status arrives through a queued hop while the replacement is produced on main and runs at once, as with
    /// production's `DispatchMainHop`).
    enum Delivery: String, CaseIterable, Sendable { case queued, nested }

    private static func forwarded(_ events: [HostEvent]) -> [PermissionStatus] {
        events.compactMap { event in
            if case .permissionsChanged(let status) = event { return status }
            return nil
        }
    }

    @Test(arguments: Delivery.allCases)
    func aReadyThatTheFailedTapReplacedIsNeverForwarded(delivery: Delivery) async throws {
        let rig = HostRig(
            permissions: FakePermissionProbe(trusted: false, post: false, listen: false),
            nestedHops: delivery == .nested)
        rig.tapFactory.setFailCreation(true)  // the tap a `ready` allows cannot be created (Input Monitoring off)
        await rig.start()
        defer { rig.stop() }
        #expect(rig.lifecyclePhase == .noPermission)
        rig.events.removeAll()
        let monitor = try #require(rig.controller.permissionMonitor)
        rig.permissions.set(trusted: true, post: false, listen: false)  // the user turns Accessibility on
        switch delivery {
        case .queued: _ = monitor.checkNow()
        case .nested: DispatchQueue.global(qos: .utility).sync { _ = monitor.checkNow() }
        }
        rig.settle()
        let statuses = Self.forwarded(rig.events)
        #expect(!statuses.isEmpty, "the replacement is forwarded")
        #expect(!statuses.contains { $0.health == .ready }, "\(statuses.map(\.health))")
        let last = try #require(statuses.last)
        #expect(last.health == .noPermission && last.listenEventRequired)
        #expect(last.accessibility == .granted && last.listenEvent == .denied)
        // The controller never keeps the replaced status either: the report shows what onboarding shows.
        #expect(rig.controller.latestPermissions == last)
        #expect(rig.controller.reportContext().permissions == last)
        #expect(rig.tapFactory.requestedMasks.count == 1, "one attempt; the backoff retries later (PLT-R332)")
    }

    /// The grant above while the replacement nests inside the check (production's inline main hop): the monitor's
    /// own callers on main (`refreshPermissions` on menu open, `feedFreshPermissions` on wake) keep the replacement,
    /// never the `ready` that `check()` computed before its delivery replaced it (PLT-R702, PLT-R721).
    private static func grantedWithoutInputMonitoringOnMain() async -> HostRig {
        let rig = HostRig(
            permissions: FakePermissionProbe(trusted: false, post: false, listen: false), nestedHops: true)
        rig.tapFactory.setFailCreation(true)
        await rig.start()
        rig.events.removeAll()
        rig.permissions.set(trusted: true, post: false, listen: false)
        return rig
    }

    @Test func refreshPermissionsReturnsTheReplacement() async throws {
        let rig = await Self.grantedWithoutInputMonitoringOnMain()
        defer { rig.stop() }
        let returned = rig.controller.refreshPermissions()
        rig.settle()
        #expect(returned.health == .noPermission && returned.listenEventRequired, "\(returned)")
        #expect(rig.controller.latestPermissions == returned)
        #expect(rig.controller.reportContext().permissions == returned)
        #expect(rig.tapFactory.requestedMasks.count == 1)
    }

    @Test func wakeNeverReopensTheTapOnAReplacedReady() async throws {
        let rig = await Self.grantedWithoutInputMonitoringOnMain()
        defer { rig.stop() }
        rig.controller.handle(.didWake)
        rig.settle()
        let latest = try #require(rig.controller.latestPermissions)
        #expect(latest.health == .noPermission && latest.listenEventRequired, "\(latest)")
        #expect(rig.lifecyclePhase == .noPermission, "\(rig.lifecyclePhase)")
        #expect(rig.tapFactory.requestedMasks.count == 1, "one attempt; a stale `ready` would open a second tap")
        #expect(!Self.forwarded(rig.events).contains { $0.health == .ready })
    }

    /// The same grant once Input Monitoring is on as well: nothing replaces `ready`, so it is forwarded.
    @Test(arguments: Delivery.allCases)
    func aReadyThatStaysReadyIsForwarded(delivery: Delivery) async throws {
        let rig = HostRig(
            permissions: FakePermissionProbe(trusted: false, post: false, listen: false),
            nestedHops: delivery == .nested)
        await rig.start()
        defer { rig.stop() }
        rig.events.removeAll()
        let monitor = try #require(rig.controller.permissionMonitor)
        rig.permissions.set(trusted: true, post: true, listen: true)
        switch delivery {
        case .queued: _ = monitor.checkNow()
        case .nested: DispatchQueue.global(qos: .utility).sync { _ = monitor.checkNow() }
        }
        rig.settle()
        #expect(Self.forwarded(rig.events).map(\.health) == [.ready])
        #expect(rig.lifecyclePhase == .running)
    }

    /// PLT-R331: a status dropped because a newer one is queued behind it still runs the watchdog's check, so a tap
    /// the system left disabled during the change is re-enabled at once. The newer status, already recorded as the
    /// controller's latest, is the only one forwarded.
    @Test func aReplacedStatusStillChecksTheTap_PLT_R331() async throws {
        let rig = HostRig()
        await rig.start()
        defer { rig.stop() }
        let handle = try #require(rig.liveHandles.first)
        let monitor = try #require(rig.controller.permissionMonitor)
        rig.events.removeAll()
        handle.setEnabled(false)  // disabled by the system during the change
        rig.permissions.set(trusted: true, post: true, listen: false)
        let replaced = monitor.checkNow()
        rig.permissions.set(trusted: true, post: true, listen: true)
        let replacement = monitor.checkNow()  // queued behind `replaced` before the main hop runs
        #expect(replaced != replacement)
        rig.settle()
        #expect(handle.isEnabled, "PLT-R330 step 1 ran for the replaced status")
        #expect(Self.forwarded(rig.events) == [replacement])
        #expect(rig.controller.latestPermissions == replacement)
        #expect(rig.lifecyclePhase == .running)
    }
}
