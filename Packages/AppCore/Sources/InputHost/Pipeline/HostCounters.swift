// SPDX-License-Identifier: GPL-3.0-or-later
//
// Content-free observations of the host since launch that the integration hooks report in `AppStateSnapshot`
// (ADR 0502, "Integration hooks") and, for the typo correction, the diagnostics report (PRD-R45, ADR 0323): tap
// recoveries after a timeout and the engine resets that came with them (PLT-R330, QA-R11), whether the first key-down
// after a secure-input release was composed (PLT-R398B), and the corrections the engines made and the ones the
// restore key undid (ENG-R1115, ENG-R1117, 1.1.0; counts only, never words, ENG-R1121). Always on in every build (four
// counters and one byte); written on the tap thread with relaxed atomics only, no lock and no allocation (PLT-R304,
// PLT-R305). Unlike `PlatformMetrics` they are never reset: they count since launch.

internal import Diagnostics
internal import RealtimeSupport

public final class HostCounters: Sendable {
    /// The main thread re-enabled the tap after a `tapDisabledByTimeout` (system or the `tapTimeout` hook).
    let tapRecoveries = AtomicCounter()
    /// The pipeline handled a `tapDisabledByTimeout` and its engine was left reset (QA-R11).
    let engineResetsAfterTapRecovery = AtomicCounter()
    /// A commit the engine decided `corrected` (ENG-R1115).
    let corrections = AtomicCounter()
    /// A restore toggle that undid a correction: its output carried `LearningSignal.neverCorrect` (ENG-R1117).
    let correctionUndos = AtomicCounter()
    /// 0: no secure-input release seen yet; 1: the first key-down after the latest release passed uncomposed;
    /// 2: it was composed.
    private let firstKeyAfterRelease = Atomic<UInt8>(0)

    public init() {}

    public var tapRecoveryCount: UInt64 { tapRecoveries.value }
    public var engineResetsAfterTapRecoveryCount: UInt64 { engineResetsAfterTapRecovery.value }
    public var correctionCount: UInt64 { corrections.value }
    public var correctionUndoCount: UInt64 { correctionUndos.value }

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
