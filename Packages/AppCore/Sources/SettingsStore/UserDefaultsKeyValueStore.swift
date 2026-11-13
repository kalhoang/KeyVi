// SPDX-License-Identifier: GPL-3.0-or-later
//
// Production `KeyValueStore`: the app's own user defaults domain (contracts.md section 3). Holds the launch
// guard and other non-exported state, never user choices (ADR 0307 "Outside the folder").

internal import Foundation

public struct UserDefaultsKeyValueStore: KeyValueStore {
    /// nil = the app's standard domain. `UserDefaults` is thread-safe but not `Sendable`, so the value type
    /// keeps the suite name and resolves the (shared, cached) defaults object on each call.
    private let suiteName: String?

    /// The app's own domain (`UserDefaults.standard`).
    public init() { suiteName = nil }

    /// A named suite; tests pass a throwaway name and remove the domain afterwards.
    public init(suiteName: String) { self.suiteName = suiteName }

    public func integer(forKey key: String) -> Int { defaults.integer(forKey: key) }
    public func set(_ value: Int, forKey key: String) { defaults.set(value, forKey: key) }
    public func double(forKey key: String) -> Double { defaults.double(forKey: key) }
    public func set(_ value: Double, forKey key: String) { defaults.set(value, forKey: key) }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }
}
