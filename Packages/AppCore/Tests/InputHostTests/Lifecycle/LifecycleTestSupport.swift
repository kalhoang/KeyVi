// SPDX-License-Identifier: GPL-3.0-or-later
//
// Helpers for the HostLifecycle table tests (W1-F2).
import AppModel
import RealtimeSupport

@testable import InputHost

extension PermissionStatus {
    static let granted = PermissionStatus(
        accessibility: .granted, postEvent: .granted, listenEvent: .granted, listenEventRequired: false,
        health: .ready)
    static let denied = PermissionStatus(
        accessibility: .denied, postEvent: .denied, listenEvent: .unknown, listenEventRequired: false,
        health: .noPermission)
    /// Granted once for this signing identity, failing now (PLT-R720): does not look granted.
    static let stale = PermissionStatus(
        accessibility: .denied, postEvent: .denied, listenEvent: .unknown, listenEventRequired: false,
        health: .stale)
    /// Same health as `granted` but a different field: the monitor reports it as a change.
    static let grantedListenRequired = PermissionStatus(
        accessibility: .granted, postEvent: .granted, listenEvent: .denied, listenEventRequired: true,
        health: .ready)
}

/// Feeds a `HostLifecycle` with inputs on a virtual monotonic timeline.
struct LifecycleScript {
    private(set) var lifecycle = HostLifecycle()
    private(set) var now = MonotonicInstant(nanoseconds: 1_000_000_000)
    /// Effects a test keeps for a later step (for example the retry delay of a circuit-breaker trip).
    var lastEffects: [LifecycleEffect] = []

    var phase: LifecycleSnapshot.Phase { lifecycle.phase }

    @discardableResult
    mutating func send(_ input: LifecycleInput) -> [LifecycleEffect] {
        lifecycle.handle(input, at: now)
    }

    mutating func advance(by duration: TimeSpan) {
        now = MonotonicInstant(nanoseconds: now.nanoseconds + duration.unsignedNanoseconds)
    }

    /// launch, permissions granted, tap created: the common starting point of most tables.
    static func running() -> LifecycleScript {
        var script = LifecycleScript()
        script.send(.launched)
        script.send(.permissionsChanged(.granted))
        script.send(.tapCreated)
        return script
    }
}

extension LifecycleSnapshot.Phase {
    /// Phases in which the effective host state is paused or fail-open (PLT-R210).
    var holdsComposition: Bool {
        switch self {
        case .failOpen, .sessionInactive: true
        case .noPermission, .starting, .running: false
        }
    }
}
