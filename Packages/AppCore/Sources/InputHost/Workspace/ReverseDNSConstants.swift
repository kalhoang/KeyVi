// SPDX-License-Identifier: GPL-3.0-or-later
//
// Reverse-DNS strings that are NOT bundle identifiers: distributed notification names posted by the system when
// the screen locks and unlocks (PLT-R333). They live only in files named `ReverseDNSConstants.swift` (PLT-R501,
// ARCHITECTURE.md 7); each literal carries the bundle-ID lint marker.

import Foundation

enum ScreenLockNotificationName {
    static let locked = Notification.Name("com.apple.screenIsLocked")  // lint:allow-bundle-id notification-name
    static let unlocked = Notification.Name("com.apple.screenIsUnlocked")  // lint:allow-bundle-id notification-name
}
