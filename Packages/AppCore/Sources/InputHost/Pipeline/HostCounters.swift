// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Content-free observations of the host since launch that the integration hooks report in `AppStateSnapshot`
// (ADR 0502, "Integration hooks"): tap recoveries after a timeout and the engine resets that came with them
// (PLT-R330, QA-R11), and whether the first key-down after a secure-input release was composed (PLT-R398B). Always
// on in every build (two counters and one byte); written on the tap thread with relaxed atomics only, no lock and
// no allocation (PLT-R304, PLT-R305). Unlike `PlatformMetrics` they are never reset: they count since launch.

internal import Diagnostics
internal import Synchronization

public final class HostCounters: Sendable {
    /// The main thread re-enabled the tap after a `tapDisabledByTimeout` (system or the `tapTimeout` hook).
    let tapRecoveries = AtomicCounter()
    /// The pipeline handled a `tapDisabledByTimeout` and its engine was left reset (QA-R11).
    let engineResetsAfterTapRecovery = AtomicCounter()
    /// 0: no secure-input release seen yet; 1: the first key-down after the latest release passed uncomposed;
    /// 2: it was composed.
    private let firstKeyAfterRelease = Atomic<UInt8>(0)

    public init() {}

    public var tapRecoveryCount: UInt64 { tapRecoveries.value }
    public var engineResetsAfterTapRecoveryCount: UInt64 { engineResetsAfterTapRecovery.value }

    /// PLT-R398B: nil before the first release of this process.
    public var firstKeyAfterSecureInputReleaseComposed: Bool? {
        switch firstKeyAfterRelease.load(ordering: .relaxed) {
        case 0: nil
        case 1: false
        default: true
        }
    }

    /// Tap thread, once per release (the first key-down after it).
    @inline(__always)
    func recordFirstKeyAfterSecureInputRelease(composed: Bool) {
        firstKeyAfterRelease.store(composed ? 2 : 1, ordering: .relaxed)
    }
}
