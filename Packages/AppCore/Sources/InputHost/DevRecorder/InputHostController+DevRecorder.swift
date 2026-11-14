// SPDX-License-Identifier: GPL-3.0-or-later
//
// The running app's hooks into the dev recorder (PLT-R904A, ADR 0007): the field readback, which reads the focus
// and secure-input snapshots off the tap, and the focus in effect when the recorder starts. Debug configuration
// only.

#if DEV_RECORDER
public import Diagnostics
public import Foundation
public import Injection
internal import RealtimeSupport

extension InputHostController {
    /// Starts the readback on `queue` (the recorder's attention queue) and connects it to the recorder's requests;
    /// also gives the recorder the focus in effect when a pause or a secure gap ends. Nil without a capture
    /// controller (tests). The readback never shares the worker's field access or AX element (review W8-E finding
    /// 1): it reads through its own `AXFocusedFieldAccess` on the private reference `fieldResolver` returns, and
    /// only while the injection queue is idle.
    @discardableResult
    public func startDevReadback(
        queue: DispatchQueue, fieldAccess: any FocusedFieldAccess = AXFocusedFieldAccess(),
        fieldResolver: any DevReadbackFieldResolver = AXDevReadbackFieldResolver()
    ) -> DevReadback? {
        guard let capture = dependencies.capture else { return nil }
        let snapshots = channels.snapshots
        let jobs = channels.queue
        let readback = DevReadback(
            recorder: capture.dev, fieldAccess: fieldAccess, fieldResolver: fieldResolver,
            isInjectionIdle: { jobs.inFlight == 0 }, focus: { snapshots.focus.load() },
            secureInput: { snapshots.secureInput.load() }, clock: tapClock,
            scheduler: DispatchTimerScheduler(queue: queue))
        capture.dev.addAttentionListener { reasons in readback.handle(reasons) }
        capture.dev.setFocusSource { at in DevFocusRecord(snapshots.focus.load(), at: at) }
        let recorder = capture.dev
        queue.async {  // ADR 0007 decision 13: the engine identity for the file lines, off the main thread
            if let identity = DevEngineIdentity.ofLinkedEngine() { recorder.setEngineIdentity(identity) }
        }
        return readback
    }

    /// The focus in effect, for the top of the trace when the recorder starts.
    public func devFocusRecord() -> DevFocusRecord { DevFocusRecord(currentFocus(), at: tapClock.now()) }
}
#endif
