// SPDX-License-Identifier: GPL-3.0-or-later
//
// Any-thread copies of focus facts that are not part of the tap snapshot (diagnostics report, PLT-R385 record).

import AppModel
import CompatRules
import RealtimeSupport

final class FocusMirror: Sendable {
    private struct State {
        var decision: ResolvedDecision?
        var manualAccessibility: Set<BundleKey> = []
    }

    private let state = Mutex(State())

    var decision: ResolvedDecision? { state.withLock { $0.decision } }
    var manualAccessibility: Set<BundleKey> { state.withLock { $0.manualAccessibility } }

    func update(decision: ResolvedDecision?) { state.withLock { $0.decision = decision } }
    func recordManualAccessibility(_ bundle: BundleKey) { _ = state.withLock { $0.manualAccessibility.insert(bundle) } }
}
