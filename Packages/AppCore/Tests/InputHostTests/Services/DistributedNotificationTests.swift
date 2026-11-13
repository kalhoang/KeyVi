// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R370-R372, PLT-R333: a menu-bar agent is almost never the active application, and AppKit suspends
// distributed notification delivery for inactive applications unless the observer asks for immediate delivery.
// A recording `DistributedNotificationCenter` subclass captures the registrations; it never calls super, so
// nothing is registered with (or broadcast on) the system's distributed center.

import Carbon
import Foundation
import RealtimeSupport
import Testing

@testable import InputHost

/// Records every registration and forwards nothing to the system.
final class RecordingDistributedCenter: DistributedNotificationCenter, @unchecked Sendable {
    struct Registration: Equatable {
        var name: Notification.Name
        var behavior: DistributedNotificationCenter.SuspensionBehavior?  // nil: the 4-argument cover method
    }

    private let storage = Mutex<[Registration]>([])
    var registrations: [Registration] { storage.withLock { $0 } }

    override func addObserver(
        _ observer: Any, selector: Selector, name: NSNotification.Name?, object: String?,
        suspensionBehavior: DistributedNotificationCenter.SuspensionBehavior
    ) {
        guard let name else { return }
        storage.withLock { $0.append(Registration(name: name, behavior: suspensionBehavior)) }
    }

    override func addObserver(
        _ observer: Any, selector: Selector, name: NSNotification.Name?, object: String?
    ) {
        guard let name else { return }
        storage.withLock { $0.append(Registration(name: name, behavior: nil)) }
    }

    override func removeObserver(_ observer: Any) {}
    override func removeObserver(_ observer: Any, name: NSNotification.Name?, object: String?) {}
}

@Suite("Distributed notifications are delivered immediately (PLT-R370, PLT-R333)")
@MainActor
struct DistributedNotificationTests {
    @Test func inputSourceChangesAskForImmediateDeliveryPLTR370() {
        let center = RecordingDistributedCenter()
        let token = TISInputSourceProvider(changeCenter: center).observeChanges {}
        defer { token.cancel() }
        #expect(
            center.registrations == [
                .init(
                    name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                    behavior: .deliverImmediately),
                .init(
                    name: Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
                    behavior: .deliverImmediately),
            ])
    }

    @Test func screenLockAsksForImmediateDeliveryPLTR333() {
        let distributed = RecordingDistributedCenter()
        let events = NSWorkspaceEvents(workspaceCenter: NotificationCenter(), distributedCenter: distributed)
        let token = events.observe { _ in }
        defer { token.cancel() }
        #expect(
            distributed.registrations == [
                .init(name: ScreenLockNotificationName.locked, behavior: .deliverImmediately),
                .init(name: ScreenLockNotificationName.unlocked, behavior: .deliverImmediately),
            ])
    }

    @Test func plainCentersKeepTheirOrdinaryRegistration() {
        let center = NotificationCenter()
        let received = Mutex(0)
        let token = NotificationObservationToken.observe(
            [Notification.Name("test.plain")], on: center, extract: { _ in () }, { _ in received.withLock { $0 += 1 } })
        center.post(name: Notification.Name("test.plain"), object: nil)
        token.cancel()
        center.post(name: Notification.Name("test.plain"), object: nil)
        #expect(received.withLock { $0 } == 1)
    }
}
