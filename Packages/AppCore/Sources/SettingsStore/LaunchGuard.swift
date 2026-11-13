// SPDX-License-Identifier: LicenseRef-App-Pending

internal import AppModel
internal import Synchronization
//
// Crash-loop safe mode (PLT-R1009): three launches that did not survive 60 s within a short window start the
// app with defaults in memory, without touching files.

/// Small key-value persistence for the guard (the app's user defaults domain in production, so the settings
/// folder holds only the four documented files).
public protocol KeyValueStore: Sendable {
    func integer(forKey key: String) -> Int
    func set(_ value: Int, forKey key: String)
    func double(forKey key: String) -> Double
    func set(_ value: Double, forKey key: String)
}

public final class LaunchGuard: Sendable {
    public static let crashThreshold = 3
    public static let survivalSeconds: Double = 60
    /// The crashed launches of one streak all started within this many seconds of the first (the "short
    /// window"). A launch that crashes once a day at login is not a crash loop; three tries in a row are.
    public static let crashWindowSeconds: Double = 600

    enum Key {
        static let inProgressSince = "launchGuard.inProgressSince"
        static let recentCrashes = "launchGuard.recentCrashes"
        static let firstCrashAt = "launchGuard.firstCrashAt"
    }

    private let store: any KeyValueStore
    private let safeModeFlag = Atomic<Bool>(false)

    public init(store: any KeyValueStore) { self.store = store }

    /// Called first thing at launch; returns true when safe mode must be entered.
    ///
    /// `now` is wall-clock seconds since 1970 (monotonic time restarts at boot). A launch that is still marked
    /// in progress never reached `markSurvived()`, so it crashed or was killed within 60 s of starting.
    public func beginLaunch(now: Double) -> Bool {
        let previousStart = store.double(forKey: Key.inProgressSince)
        if previousStart > 0 { recordCrash(launchedAt: previousStart) }
        store.set(now, forKey: Key.inProgressSince)
        let enter = recentCrashes >= Self.crashThreshold
        safeModeFlag.store(enter, ordering: .sequentiallyConsistent)
        return enter
    }

    /// Called 60 s after launch and on clean quit. In safe mode the crash count is kept, so the next launch is
    /// safe again until the user resets or leaves safe mode (`reset()`).
    public func markSurvived() {
        store.set(0.0, forKey: Key.inProgressSince)
        guard !isSafeModeActive else { return }
        clearStreak()
    }

    public var recentCrashes: Int { store.integer(forKey: Key.recentCrashes) }

    /// True after `beginLaunch` decided on safe mode, until `reset()`. `SettingsStore.load` reads it.
    public var isSafeModeActive: Bool { safeModeFlag.load(ordering: .sequentiallyConsistent) }

    /// Leaves safe mode and forgets the streak (`SettingsStore.exitSafeMode`, reset from the safe-mode notice).
    /// The current launch stays in progress until it survives.
    public func reset() {
        clearStreak()
        safeModeFlag.store(false, ordering: .sequentiallyConsistent)
    }

    private func recordCrash(launchedAt start: Double) {
        let crashes = recentCrashes
        let first = store.double(forKey: Key.firstCrashAt)
        let continuesStreak = crashes > 0 && start >= first && start - first <= Self.crashWindowSeconds
        if continuesStreak {
            store.set(crashes + 1, forKey: Key.recentCrashes)
        } else {
            store.set(1, forKey: Key.recentCrashes)
            store.set(start, forKey: Key.firstCrashAt)
        }
    }

    private func clearStreak() {
        store.set(0, forKey: Key.recentCrashes)
        store.set(0.0, forKey: Key.firstCrashAt)
    }
}
