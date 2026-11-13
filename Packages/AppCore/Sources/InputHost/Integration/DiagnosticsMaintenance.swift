// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The testable part of the W1-A diagnostics wiring request: the maintenance cadence (log rotation at launch and
// every 6 hours, PLT-R903; capture purge at launch and hourly, PLT-R905) and the per-installation redaction salt
// (PLT-R1203). The App target only adapts UserDefaults and passes the real logger and capture controller.
// Workstream W2-A.

public import AppModel
public import Diagnostics
public import Foundation
public import RealtimeSupport

/// Runs log rotation and capture purge once at launch and then on their intervals, on the scheduler's queue.
public struct DiagnosticsMaintenance: Sendable {
    /// PLT-R903 rotation and retention.
    public static let rotationInterval: Duration = .seconds(6 * 3_600)
    /// PLT-R905: captures older than 24 hours are deleted; checked hourly.
    public static let purgeInterval: Duration = .seconds(3_600)

    public let wallClock: any WallClock
    public let rotate: @Sendable () -> Void
    public let purge: @Sendable (Date) -> Void

    public init(
        wallClock: any WallClock, rotate: @escaping @Sendable () -> Void, purge: @escaping @Sendable (Date) -> Void
    ) {
        self.wallClock = wallClock
        self.rotate = rotate
        self.purge = purge
    }

    /// The caller keeps the returned timers (a dispatch timer is cancelled when released). The launch run is a
    /// zero-delay timer, so it never runs on the caller's thread.
    public func start(on scheduler: any TimerScheduler) -> [any ScheduledTimer] {
        let rotate = self.rotate
        let purge = self.purge
        let wallClock = self.wallClock
        return [
            scheduler.schedule(after: .zero, leeway: .zero) {
                rotate()
                purge(wallClock.now())
            },
            scheduler.scheduleRepeating(every: Self.rotationInterval, leeway: Self.rotationInterval / 10) {
                rotate()
            },
            scheduler.scheduleRepeating(every: Self.purgeInterval, leeway: Self.purgeInterval / 10) {
                purge(wallClock.now())
            },
        ]
    }
}

/// Where the salt is kept. Production: the app's user defaults.
public protocol SaltStorage: Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data, forKey key: String)
}

/// The salt that makes redacted values stable across reports of one installation (PLT-R1203).
public enum RedactionSaltStore {
    public static let key = "diagnostics.redactionSalt"
    public static let length = 32

    /// The stored salt, or a new random one (stored) when there is none or the stored value is damaged.
    public static func load(from storage: any SaltStorage) -> RedactionSalt {
        if let bytes = storage.data(forKey: key), bytes.count == length {
            return RedactionSalt(bytes: Array(bytes))
        }
        let salt = RedactionSalt.random()
        storage.set(Data(salt.bytes), forKey: key)
        return salt
    }
}
