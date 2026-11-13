// SPDX-License-Identifier: LicenseRef-App-Pending

internal import AppModel
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

    public init(store: any KeyValueStore) { unimplemented() }
    /// Called first thing at launch; returns true when safe mode must be entered.
    public func beginLaunch(now: Double) -> Bool { unimplemented() }
    /// Called 60 s after launch and on clean quit.
    public func markSurvived() { unimplemented() }
    public var recentCrashes: Int { unimplemented() }
}

