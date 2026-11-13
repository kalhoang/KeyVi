// SPDX-License-Identifier: LicenseRef-App-Pending

import Foundation
import TestSupport
import Testing

@testable import SettingsStore

@Suite struct LaunchGuardTests {
    private let start = 1_800_000_000.0

    @Test func threeUnsurvivedLaunchesEnterSafeModePLTR1009() {
        let store = InMemoryKeyValueStore()
        for index in 0..<3 {
            #expect(!LaunchGuard(store: store).beginLaunch(now: start + Double(index) * 20))
        }
        let fourth = LaunchGuard(store: store)
        #expect(fourth.beginLaunch(now: start + 60))
        #expect(fourth.recentCrashes == 3)
        #expect(fourth.isSafeModeActive)
    }

    @Test func survivingClearsTheStreak() {
        let store = InMemoryKeyValueStore()
        _ = LaunchGuard(store: store).beginLaunch(now: start)
        _ = LaunchGuard(store: store).beginLaunch(now: start + 10)
        let survivor = LaunchGuard(store: store)
        #expect(!survivor.beginLaunch(now: start + 20))
        #expect(survivor.recentCrashes == 2)
        survivor.markSurvived()
        #expect(survivor.recentCrashes == 0)
        let next = LaunchGuard(store: store)
        #expect(!next.beginLaunch(now: start + 200))
        #expect(next.recentCrashes == 0)
    }

    @Test func crashesOutsideTheWindowStartANewStreak() {
        let store = InMemoryKeyValueStore()
        _ = LaunchGuard(store: store).beginLaunch(now: start)
        _ = LaunchGuard(store: store).beginLaunch(now: start + 30)
        _ = LaunchGuard(store: store).beginLaunch(now: start + LaunchGuard.crashWindowSeconds + 100)
        // Crashed launches started at +0, +30 and +700: the third is outside the window of the first, so the
        // streak restarts with it.
        let guardian = LaunchGuard(store: store)
        #expect(!guardian.beginLaunch(now: start + LaunchGuard.crashWindowSeconds + 200))
        #expect(guardian.recentCrashes == 1)
    }

    @Test func clockGoingBackwardsStartsANewStreak() {
        let store = InMemoryKeyValueStore()
        _ = LaunchGuard(store: store).beginLaunch(now: start)
        _ = LaunchGuard(store: store).beginLaunch(now: start + 10)
        _ = LaunchGuard(store: store).beginLaunch(now: start - 500)
        let guardian = LaunchGuard(store: store)
        #expect(!guardian.beginLaunch(now: start - 490))
        #expect(guardian.recentCrashes == 1)
    }

    @Test func safeModePersistsUntilResetEvenAfterACleanQuit() {
        let store = InMemoryKeyValueStore()
        for index in 0..<3 { _ = LaunchGuard(store: store).beginLaunch(now: start + Double(index)) }
        let safe = LaunchGuard(store: store)
        #expect(safe.beginLaunch(now: start + 5))
        safe.markSurvived()
        #expect(safe.recentCrashes == 3)
        let again = LaunchGuard(store: store)
        #expect(again.beginLaunch(now: start + 100))
        again.reset()
        #expect(!again.isSafeModeActive)
        #expect(again.recentCrashes == 0)
        again.markSurvived()
        #expect(!LaunchGuard(store: store).beginLaunch(now: start + 200))
    }

    @Test func userDefaultsStoreRoundTrips() {
        let suite = "settings-store-tests-" + UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = UserDefaultsKeyValueStore(suiteName: suite)
        #expect(store.integer(forKey: "a") == 0)
        store.set(3, forKey: "a")
        store.set(2.5, forKey: "b")
        #expect(store.integer(forKey: "a") == 3)
        #expect(store.double(forKey: "b") == 2.5)
        let guardian = LaunchGuard(store: store)
        _ = guardian.beginLaunch(now: start)
        #expect(store.double(forKey: LaunchGuard.Key.inProgressSince) == start)
        _ = UserDefaultsKeyValueStore().integer(forKey: "settings-store-tests-unused-key")
    }
}
