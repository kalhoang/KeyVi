// SPDX-License-Identifier: GPL-3.0-or-later
//
// The running app's hooks into the dev recorder (PLT-R904A, ADR 0007): the field readback, which reads the focus
// and secure-input snapshots off the tap, and the focus in effect when the recorder starts. Debug configuration
// only.

#if DEV_RECORDER
public import Diagnostics
public import Foundation
internal import RealtimeSupport

extension InputHostController {
    /// Starts the readback on `queue` (the recorder's attention queue) and connects it to the recorder's requests.
    /// Nil without a capture controller (tests).
    @discardableResult
    public func startDevReadback(queue: DispatchQueue) -> DevReadback? {
        guard let capture = dependencies.capture else { return nil }
        let snapshots = channels.snapshots
        let readback = DevReadback(
            recorder: capture.dev, fieldAccess: dependencies.fieldAccess, focus: { snapshots.focus.load() },
            secureInput: { snapshots.secureInput.load() }, clock: tapClock,
            scheduler: DispatchTimerScheduler(queue: queue))
        capture.dev.addAttentionListener { reasons in readback.handle(reasons) }
        return readback
    }

    /// The focus in effect, for the top of the trace when the recorder starts.
    public func devFocusRecord() -> DevFocusRecord { DevFocusRecord(currentFocus(), at: tapClock.now()) }
}
#endif
