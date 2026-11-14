// SPDX-License-Identifier: GPL-3.0-or-later
//
// Focus snapshots for the dev recorder (PLT-R904A, ADR 0007): bundle ID, role, subrole, the compat rule and the
// decision it resolved to, the mode and why. Never window titles or URLs (the snapshot has no field for them).
// Debug configuration only; the ax thread is the focus ring's one producer.

#if DEV_RECORDER
public import Diagnostics
public import RealtimeSupport

extension FocusCore {
    func recordDevFocus(_ snapshot: FocusSnapshot, at instant: MonotonicInstant) {
        guard let dev = services.capture?.dev, dev.isActive else { return }
        dev.pushFocus(.focus(DevFocusRecord(snapshot, at: instant)))
    }
}

extension DevFocusRecord {
    /// The record of a focus snapshot (the App writes the focus in effect when the recorder starts).
    public init(_ snapshot: FocusSnapshot, at instant: MonotonicInstant) {
        let decision = snapshot.decision
        self.init(
            generation: snapshot.generation.rawValue, bundle: snapshot.app?.bundle.rawValue, role: snapshot.field.role,
            subrole: snapshot.field.subrole, rule: decision.rule?.rawValue, strategy: decision.plan.strategy.rawValue,
            requireTextFocus: decision.requireTextFocus.rawValue,
            axAvailability: snapshot.field.axAvailability.rawValue, secure: snapshot.field.secure,
            mode: snapshot.mode.rawValue, modeSource: snapshot.modeSource.rawValue,
            engineContext: String(describing: decision.variant.appContext),
            englishRestore: decision.variant.englishRestore, macros: decision.variant.macros,
            pause: snapshot.pause.map { $0.code.rawValue }, at: instant)
    }
}
#endif
