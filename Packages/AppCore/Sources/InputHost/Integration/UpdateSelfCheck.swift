// SPDX-License-Identifier: LicenseRef-App-Pending
//
// QA-R42: on the first launch after an update the app checks itself (permission state, tap creation) and, on
// failure, shows the targeted permission screen (PRD-R42) instead of failing silently. PRD-R52: otherwise the
// first launch after an update shows nothing unless a setting's meaning changed. The synthetic round trip in an
// off-screen field is not part of v1 (the platform spec does not provide an off-screen target; VERIFY with the
// runner suites). Workstream W2-A.

public import AppModel
public import SettingsStore

/// Remembers the version of the previous launch in the app's user defaults (as a stable 52-bit fingerprint,
/// because `KeyValueStore` holds numbers only).
public struct UpdateSelfCheck: Sendable {
    public static let lastVersionKey = "launch.lastVersionFingerprint"

    public enum LaunchKind: Sendable, Hashable {
        case firstLaunch
        case sameVersion
        /// An update (or a downgrade): run the self-check.
        case versionChanged
    }

    public enum Verdict: Sendable, Hashable {
        /// Still starting: decide on the next state change.
        case pending
        case passed
        /// PRD-R42 "permission lost" variant of onboarding, at the permission screen.
        case showPermissionScreen
    }

    private let store: any KeyValueStore

    public init(store: any KeyValueStore) { self.store = store }

    /// Records `version` (short version plus build) and classifies this launch.
    public func noteLaunch(version: String) -> LaunchKind {
        let previous = store.integer(forKey: Self.lastVersionKey)
        let current = Self.fingerprint(version)
        store.set(current, forKey: Self.lastVersionKey)
        if previous == 0 { return .firstLaunch }
        return previous == current ? .sameVersion : .versionChanged
    }

    /// The host state after the update: a missing or stale permission or a tap that cannot be created means the
    /// grant did not survive the update (a release-blocking bug, PRD-R52), so the user gets the permission screen.
    public static func verdict(state: HostState, permissions: PermissionStatus.Health) -> Verdict {
        if permissions == .stale { return .showPermissionScreen }
        switch state {
        case .starting: return .pending
        case .noPermission: return .showPermissionScreen
        case .failOpen(let reason):
            switch reason {
            case .permissionRevoked, .tapUnavailable, .postingBroken: return .showPermissionScreen
            case .watchdog, .callbackStuck: return .passed
            }
        case .ready, .paused: return .passed
        }
    }

    /// FNV-1a over the UTF-8 bytes, folded to 52 bits so it round-trips through a `Double` too. Never 0.
    static func fingerprint(_ version: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in version.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let folded = Int(hash & 0x000F_FFFF_FFFF_FFFF)
        return folded == 0 ? 1 : folded
    }
}

/// PRD-R52: settings whose meaning changed in a release (key and the version that changed it). Empty in v1;
/// a non-empty list shows one menu status line for 24 hours, linking to the release notes.
public enum SettingMeaningChanges {
    public struct Entry: Sendable, Hashable {
        public var version: LooseVersion
        public var settingKey: String
    }

    public static let entries: [Entry] = []

    /// Entries introduced after `previous` up to and including `current`.
    public static func between(previous: LooseVersion?, current: LooseVersion) -> [Entry] {
        entries.filter { entry in entry.version <= current && previous.map { entry.version > $0 } ?? false }
    }
}
