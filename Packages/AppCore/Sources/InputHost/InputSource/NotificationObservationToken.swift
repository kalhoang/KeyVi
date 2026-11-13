// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Observation token over `NotificationCenter`, shared by the TIS and NSWorkspace wrappers. The token is the
// observer itself (selector-based), so it holds no non-Sendable observer objects.

import Dispatch
import Foundation

final class NotificationObservationToken: NSObject, ObservationToken {
    private let center: NotificationCenter
    private let deliver: @Sendable (Notification) -> Void

    private init(center: NotificationCenter, deliver: @escaping @Sendable (Notification) -> Void) {
        self.center = center
        self.deliver = deliver
        super.init()
    }

    deinit { center.removeObserver(self) }

    func cancel() { center.removeObserver(self) }

    @objc private func received(_ notification: Notification) { deliver(notification) }

    /// Registers `names` on `center`. The handler runs on the main thread (TIS and NSWorkspace notifications are
    /// main-thread work, PLT-R203); `extract` copies the Sendable part of the notification first.
    ///
    /// On a `DistributedNotificationCenter` the observer asks for `.deliverImmediately`: the 4-argument cover
    /// method registers with `.coalesce`, and AppKit suspends distributed delivery while the application is not
    /// active, which a menu-bar agent almost never is. Input source changes and screen lock must arrive at once
    /// (PLT-R370 "delivered immediately", PLT-R371, PLT-R372, PLT-R333).
    static func observe<Payload: Sendable>(
        _ names: [Notification.Name], on center: NotificationCenter,
        extract: @escaping @Sendable (Notification) -> Payload,
        _ handler: @escaping @MainActor @Sendable (Payload) -> Void
    ) -> NotificationObservationToken {
        let token = NotificationObservationToken(center: center) { notification in
            let payload = extract(notification)
            if Thread.isMainThread {
                MainActor.assumeIsolated { handler(payload) }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { handler(payload) } }
            }
        }
        let selector = #selector(received(_:))
        for name in names {
            if let distributed = center as? DistributedNotificationCenter {
                distributed.addObserver(
                    token, selector: selector, name: name, object: nil, suspensionBehavior: .deliverImmediately)
            } else {
                center.addObserver(token, selector: selector, name: name, object: nil)
            }
        }
        return token
    }
}
