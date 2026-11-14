// SPDX-License-Identifier: GPL-3.0-or-later
//
// Focus snapshots for the dev recorder (PLT-R904A, ADR 0007): bundle ID, role, subrole, the compat rule and the
// decision it resolved to, the mode and why. Never window titles or URLs (the snapshot has no field for them). When
// AX names no focused application, the frontmost application's bundle ID from NSWorkspace (format version 3: 685 key
// downs of 15/11/2026 went to an app the trace could not name). Debug configuration only; the ax thread is the focus
// ring's one producer.

#if DEV_RECORDER
public import Diagnostics
public import RealtimeSupport

extension FocusCore {
    func recordDevFocus(_ snapshot: FocusSnapshot, at instant: MonotonicInstant) {
        guard let dev = services.capture?.dev, dev.isActive else { return }
        let frontmost = snapshot.app == nil ? services.processes.frontmostApplication()?.bundle.rawValue : nil
        dev.pushFocus(.focus(DevFocusRecord(snapshot, frontmost: frontmost, at: instant)))
    }
}

extension DevFocusRecord {
    /// The record of a focus snapshot (the App writes the focus in effect when the recorder starts). `frontmost`:
    /// NSWorkspace's frontmost application, given only when the snapshot names no app.
    public init(_ snapshot: FocusSnapshot, frontmost: String? = nil, at instant: MonotonicInstant) {
        let decision = snapshot.decision
        self.init(
            generation: snapshot.generation.rawValue, bundle: snapshot.app?.bundle.rawValue, role: snapshot.field.role,
            subrole: snapshot.field.subrole, rule: decision.rule?.rawValue, strategy: decision.plan.strategy.rawValue,
            requireTextFocus: decision.requireTextFocus.rawValue,
            axAvailability: snapshot.field.axAvailability.rawValue, secure: snapshot.field.secure,
            mode: snapshot.mode.rawValue, modeSource: snapshot.modeSource.rawValue,
            engineContext: String(describing: decision.variant.appContext),
            englishRestore: decision.variant.englishRestore, macros: decision.variant.macros,
            pause: snapshot.pause.map { $0.code.rawValue }, frontmost: snapshot.app == nil ? frontmost : nil,
            at: instant)
    }
}
#endif
